// Codex SDLC 的駕駛艙。**它是 sdlc.ps1 與各 gate 的殼，不是第二份實作。**
//
// 刻意不做的三件事（也寫在 README）：
//   1. 不推測「現在在流程的第幾步」—— 流程狀態活在對話裡，靠檔案反推會猜錯。
//   2. 不自己實作任何 lint／gate／sha 邏輯 —— 狀態一律來自 sdlc.ps1 -Json 的 data，違規一律來自 gate 的 -Json。
//      改設定也一樣：寫檔只經過 `sdlc.ps1 set`（它先依 schema 驗完才寫），選項與說明只讀專案裡的 schema。
//   3. 不把工作流設定存進 VS Code settings —— 那裡每機器一份、不進版控、團隊看不到。
//      唯一真相是 sdlc.config.json；這裡的 settings 只有「pwsh 在哪」這類機器上的事。
//
// 這支檔是唯一 import vscode 的地方。能在純 Node 底下測的邏輯都在
// pwsh／contract／status／diagnostics／config／schema／tree／codelens。

import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { configLenses } from './codelens';
import { ConfigReadError, countRules, readConfig, type ConfigSnapshot } from './config';
import {
  compareVersions, ContractError, MIN_SETTINGS_VERSION, MIN_WORKFLOW_VERSION, parseApply, parseCheckUpdate, parseDlpGate, parseDoctor,
  parseEnvelope, parseGuidelineGate, parseRulesValidation, parseSet, parseTune, parseWhatsNew, type DoctorData, type Envelope, type SetData,
} from './contract';
import { dlpOutcome, groupByFile, guidelineOutcome, RULES_REL, rulesOutcome, type DiagnosticRecord, type ScanOutcome } from './diagnostics';
import {
  encodedCommandArgs, envValue, fileArgs, gateInvocation, INSTALL_URL, psQuote, resolvePwsh, runPwsh,
  type PwshResolution, type RunResult,
} from './pwsh';
import { CONFIG_SCHEMA_REL, matchesPattern, readSettingsSchema, type Choice, type SettingsSchema } from './schema';
import { statusFromDoctor, statusFromFailure, type StatusView } from './status';
import {
  buildSettingsTree, pendingAgentsOf, type EditTarget, type MachineInfo, type SettingNode, type StoredProposalItem, type Tone, type TreeInput,
} from './tree';

const VERSION_REL = '.codex/bdd-workflow/bdd-workflow-version.json';
const PROFILES_REL = '.codex/bdd-workflow/tuning-profiles.json';
const SDLC_REL = '.codex/scripts/sdlc.ps1';
const GUIDELINE_GATE_REL = '.codex/scripts/guideline-gate.ps1';
const DLP_GATE_REL = '.codex/scripts/dlp-gate.ps1';
const CONFIG_REL = 'sdlc.config.json';
const PROPOSAL_REL = 'bdd-docs/.sdlc/tuning-proposal.json';
const GATE_MARKER_REL = 'guidelines/.gate-disabled';
const SETTINGS_VIEW = 'codexSdlc.settings';
const WALKTHROUGH = 'codexSdlc.start';
const UPDATE_INTERVAL_MS = 60 * 60 * 1000;   // 只是「問 sdlc.ps1 到期了沒」—— 真的連網與否由 update.check 決定

export interface WriteOptions { apply?: boolean; yes?: boolean; preset?: string; preview?: boolean; quiet?: boolean; root?: string }

export interface CockpitApi {
  roots(): string[];
  status(root?: string): StatusView | undefined;
  doctor(root?: string): DoctorData | undefined;
  refresh(root?: string): Promise<void>;
  scan(uri: vscode.Uri): Promise<void>;
  diagnostics(uri: vscode.Uri): readonly vscode.Diagnostic[];
  // 設定面板（host 測試用；面板本身也走同一條路）
  settingsTree(root?: string): SettingNode[];
  writeSettings(assignments: string[], opts?: WriteOptions): Promise<SetData | undefined>;
  calls(): Record<string, number>;
  settingsViewVisible(): boolean;
}

interface RootState {
  root: string;
  view?: StatusView;
  doctor?: DoctorData;
  running?: Promise<void>;
  again: boolean;
  timer?: NodeJS.Timeout;
  scanPending: Set<string>;
  scanTimer?: NodeJS.Timeout;
  scanning?: Promise<void>;
  // 寫了 agents.*、doctor 還沒回來確認的 agent。doctor 回來之後以它的 tuning.stale 為準。
  pendingAgents: Set<string>;
  lastWrite: number;
}

type SdlcCall =
  | { ok: true; env: Envelope; run: RunResult }
  | { ok: false; view: StatusView; run?: RunResult };

const samePath = (a: string, b: string) =>
  process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;

const toneColor: Record<Tone, string> = {
  ok: 'testing.iconPassed',
  warn: 'list.warningForeground',
  error: 'list.errorForeground',
  pending: 'charts.orange',
  muted: 'disabledForeground',
};

function toTreeItem(n: SettingNode): vscode.TreeItem {
  const state = n.children && n.children.length > 0
    ? (n.expanded ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed)
    : vscode.TreeItemCollapsibleState.None;
  const item = new vscode.TreeItem(n.label, state);
  item.id = n.id;
  item.description = n.description;
  item.tooltip = n.tooltip;
  item.contextValue = n.contextValue;
  if (n.icon) item.iconPath = new vscode.ThemeIcon(n.icon, n.tone ? new vscode.ThemeColor(toneColor[n.tone]) : undefined);
  if (n.command) item.command = n.command;
  return item;
}

function isEditTarget(x: unknown): x is EditTarget {
  return typeof x === 'object' && x !== null && 'kind' in x && 'key' in x;
}

class Cockpit implements vscode.Disposable {
  private readonly output = vscode.window.createOutputChannel('Codex SDLC');
  private readonly item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  private readonly guidelineDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-guideline');
  private readonly dlpDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-dlp');
  private readonly rulesDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-rules');
  private readonly treeChanged = new vscode.EventEmitter<void>();
  private readonly lensChanged = new vscode.EventEmitter<void>();
  private readonly states = new Map<string, RootState>();
  private readonly disposables: vscode.Disposable[] = [];
  private readonly callCount: Record<string, number> = {};
  private pwshCache?: PwshResolution;
  private pwshWarned = false;
  private bundledCodex?: string | null;
  private updateTimer?: NodeJS.Timeout;
  private lastPicked?: string;
  private settingsView?: vscode.TreeView<SettingNode>;

  constructor(private readonly context: vscode.ExtensionContext) {
    this.item.command = 'codexSdlc.menu';
    this.disposables.push(this.output, this.item, this.guidelineDiag, this.dlpDiag, this.rulesDiag, this.treeChanged, this.lensChanged);
  }

  // ---- 生命週期 ----

  start(): void {
    const reg = (id: string, fn: (...args: any[]) => unknown) => this.disposables.push(vscode.commands.registerCommand(id, fn));
    reg('codexSdlc.menu', () => this.menu());
    reg('codexSdlc.refresh', () => this.withRoot((r) => this.refresh(r)));
    reg('codexSdlc.doctor', () => this.withRoot((r) => this.doctorCommand(r)));
    reg('codexSdlc.apply', () => this.withRoot((r) => this.applyCommand(r)));
    reg('codexSdlc.tune', () => this.withRoot((r) => this.tuneCommand(r)));
    reg('codexSdlc.whatsnew', () => this.withRoot((r) => this.whatsNewCommand(r)));
    reg('codexSdlc.checkUpdate', () => this.withRoot((r) => this.checkUpdateCommand(r)));
    reg('codexSdlc.showOutput', () => this.output.show());
    // 設定面板
    reg('codexSdlc.openSettings', () => vscode.commands.executeCommand(`${SETTINGS_VIEW}.focus`));
    reg('codexSdlc.editSetting', (arg: unknown) => this.withRoot((r) => this.editSettingCommand(r, arg)));
    reg('codexSdlc.applyPreset', () => this.withRoot((r) => this.applyPresetCommand(r)));
    reg('codexSdlc.applyProposalFor', (root: string, agent: string) => this.applyProposal(root, [agent]));
    reg('codexSdlc.trustHooks', () => this.withRoot((r) => this.trustHooksCommand(r)));
    reg('codexSdlc.toggleGate', () => this.withRoot((r) => this.toggleGateCommand(r)));
    reg('codexSdlc.pickPwsh', () => this.pickExecutable('pwshPath', '選擇 PowerShell 7（pwsh）'));
    reg('codexSdlc.pickCodex', () => this.pickExecutable('codexPath', '選擇 codex 執行檔'));
    reg('codexSdlc.openFile', (file: string) => vscode.window.showTextDocument(vscode.Uri.file(file)));
    reg('codexSdlc.openWalkthrough', () => vscode.commands.executeCommand('workbench.action.openWalkthrough', `${this.context.extension.id}#${WALKTHROUGH}`, false));

    const tree: vscode.TreeDataProvider<SettingNode> = {
      onDidChangeTreeData: this.treeChanged.event,
      getTreeItem: (n) => toTreeItem(n),
      getChildren: (n) => (n ? n.children ?? [] : this.settingsTree()),
    };
    this.disposables.push(
      (this.settingsView = vscode.window.createTreeView(SETTINGS_VIEW, { treeDataProvider: tree, showCollapseAll: true })),
      vscode.languages.registerCodeLensProvider({ pattern: `**/${CONFIG_REL}` }, {
        onDidChangeCodeLenses: this.lensChanged.event,
        provideCodeLenses: (doc) => this.codeLenses(doc),
      }),
    );

    this.disposables.push(
      vscode.workspace.onDidSaveTextDocument((d) => this.queueScan(d.uri)),
      vscode.workspace.onDidOpenTextDocument((d) => this.queueScan(d.uri)),
      vscode.window.onDidChangeActiveTextEditor(() => this.render()),
      vscode.workspace.onDidChangeWorkspaceFolders(() => this.syncRoots()),
      vscode.workspace.onDidChangeConfiguration((e) => {
        if (e.affectsConfiguration('codexSdlc.pwshPath')) { this.pwshCache = undefined; this.pwshWarned = false; }
        if (e.affectsConfiguration('codexSdlc')) { this.render(); this.refreshViews(); for (const s of this.states.values()) this.schedule(s, 0); }
      }),
    );

    // 工作流的檔一變就重新健檢：改了設定、apply 寫了 toml、升級換了版本檔、check-update 寫了快取、hooks.json 被改、規範檔或開關變了。
    const watcher = vscode.workspace.createFileSystemWatcher(
      '**/{sdlc.config.json,.codex/agents/*.toml,.codex/hooks.json,.codex/bdd-workflow/bdd-workflow-version.json,bdd-docs/.sdlc/update-cache.json,guidelines/*,guidelines/.gate-disabled}',
    );
    const onFile = (uri: vscode.Uri) => {
      const p = uri.fsPath.replace(/\\/g, '/');
      if (p.endsWith(VERSION_REL)) this.syncRoots();
      const s = this.stateFor(uri);
      if (!s) return;
      // rules.json 在編輯器外被改（git checkout、腳本）→ 也要重驗，不然 Problems 會停在舊的那一份。
      if (p.endsWith(`/${RULES_REL}`) && fs.existsSync(uri.fsPath)) void this.validateRules(s.root, uri);
      if (p.endsWith(`/${RULES_REL}`) && !fs.existsSync(uri.fsPath)) this.rulesDiag.delete(uri);
      this.refreshViews();
      this.schedule(s, 800);
    };
    // tune 的提議與 schema 只影響面板與 CodeLens，不必重跑 doctor。
    const viewWatcher = vscode.workspace.createFileSystemWatcher('**/{bdd-docs/.sdlc/tuning-proposal.json,.codex/bdd-workflow/*.schema.json}');
    const onViewFile = () => this.refreshViews();
    this.disposables.push(
      watcher, watcher.onDidChange(onFile), watcher.onDidCreate(onFile), watcher.onDidDelete(onFile),
      viewWatcher, viewWatcher.onDidChange(onViewFile), viewWatcher.onDidCreate(onViewFile), viewWatcher.onDidDelete(onViewFile),
    );

    this.syncRoots();
    for (const doc of vscode.workspace.textDocuments) this.queueScan(doc.uri);

    // 背景刷新更新快取。這是這個 extension 唯一買得到、腳本層買不到的東西：沒有任何使用者動作也會發生。
    // 要不要真的連網由 sdlc.ps1 看 update.check 決定（never = 一條連線都沒有），這裡只負責定時問。
    const tick = () => { for (const s of this.states.values()) void this.backgroundUpdateCheck(s.root); };
    setTimeout(tick, 5_000);
    this.updateTimer = setInterval(tick, UPDATE_INTERVAL_MS);

    // 第一次在這台機器上啟動：打開四步引導。「裝好了卻不知道介面在哪」是這個 extension 被回報過的第一個問題。
    const shownKey = 'codexSdlc.walkthroughShown';
    if (this.states.size > 0 && !this.context.globalState.get<boolean>(shownKey)) {
      void this.context.globalState.update(shownKey, true);
      void vscode.commands.executeCommand('codexSdlc.openWalkthrough');
    }
  }

  dispose(): void {
    if (this.updateTimer) clearInterval(this.updateTimer);
    for (const s of this.states.values()) { if (s.timer) clearTimeout(s.timer); if (s.scanTimer) clearTimeout(s.scanTimer); }
    for (const d of this.disposables) d.dispose();
  }

  readonly api: CockpitApi = {
    roots: () => [...this.states.keys()],
    status: (root) => this.pick(root)?.view,
    doctor: (root) => this.pick(root)?.doctor,
    refresh: async (root) => {
      const targets = root ? [this.pick(root)].filter((x): x is RootState => !!x) : [...this.states.values()];
      await Promise.all(targets.map((s) => this.refresh(s.root)));
    },
    scan: async (uri) => {
      const s = this.stateFor(uri);
      if (!s) return;
      this.queueScan(uri, 0);
      await new Promise((r) => setTimeout(r, 20));
      while (s.scanTimer || s.scanning) {
        if (s.scanning) await s.scanning; else await new Promise((r) => setTimeout(r, 20));
      }
    },
    diagnostics: (uri) => [...(this.guidelineDiag.get(uri) ?? []), ...(this.dlpDiag.get(uri) ?? []), ...(this.rulesDiag.get(uri) ?? [])],
    settingsTree: (root) => this.settingsTree(root),
    writeSettings: async (assignments, opts = {}) => {
      const s = this.pick(opts.root);
      return s ? this.writeSettings(s.root, assignments, opts) : undefined;
    },
    calls: () => ({ ...this.callCount }),
    settingsViewVisible: () => this.settingsView?.visible ?? false,
  };

  // ---- 工作區 ----

  private syncRoots(): void {
    const found = (vscode.workspace.workspaceFolders ?? [])
      .map((f) => f.uri.fsPath)
      .filter((p) => fs.existsSync(path.join(p, VERSION_REL)));
    for (const key of [...this.states.keys()]) if (!found.some((f) => samePath(f, key))) this.states.delete(key);
    for (const root of found) {
      if ([...this.states.keys()].some((k) => samePath(k, root))) continue;
      const s: RootState = { root, again: false, scanPending: new Set(), pendingAgents: new Set(), lastWrite: 0 };
      this.states.set(root, s);
      this.schedule(s, 0);
    }
    // 設定面板只在裝了工作流的工作區出現 —— 沒有的話活動列不該多一個空圖示。
    void vscode.commands.executeCommand('setContext', 'codexSdlc.active', this.states.size > 0);
    this.render();
    this.refreshViews();
  }

  private stateFor(uri: vscode.Uri): RootState | undefined {
    if (uri.scheme !== 'file') return undefined;
    let best: RootState | undefined;
    for (const s of this.states.values()) {
      const rel = path.relative(s.root, uri.fsPath);
      if (rel.startsWith('..') || path.isAbsolute(rel)) continue;
      if (!best || s.root.length > best.root.length) best = s;
    }
    return best;
  }

  private pick(root?: string): RootState | undefined {
    if (root) return [...this.states.values()].find((s) => samePath(s.root, root));
    const editor = vscode.window.activeTextEditor;
    return (editor && this.stateFor(editor.document.uri)) ?? this.states.values().next().value;
  }

  private async withRoot(fn: (root: string) => Promise<unknown>): Promise<void> {
    const s = this.pick();
    if (!s) {
      void vscode.window.showInformationMessage('這個工作區沒有安裝 Codex SDLC 工作流（找不到 .codex/bdd-workflow/bdd-workflow-version.json）。');
      return;
    }
    await fn(s.root);
  }

  // ---- 執行 ----

  private pwsh(): PwshResolution {
    if (!this.pwshCache) {
      const setting = vscode.workspace.getConfiguration('codexSdlc').get<string>('pwshPath') ?? '';
      this.pwshCache = resolvePwsh({ setting, env: process.env, platform: process.platform, exists: (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } } });
    }
    return this.pwshCache;
  }

  private pwshFailure(): StatusView | undefined {
    const r = this.pwsh();
    if (r.ok) return undefined;
    if (!this.pwshWarned) {
      this.pwshWarned = true;
      void vscode.window.showErrorMessage(r.message, '安裝 PowerShell 7', '選擇 pwsh…').then((choice) => {
        if (choice === '安裝 PowerShell 7') void vscode.env.openExternal(vscode.Uri.parse(INSTALL_URL));
        if (choice === '選擇 pwsh…') void vscode.commands.executeCommand('codexSdlc.pickPwsh');
      });
    }
    this.log(`✖ ${r.message}`);
    return statusFromFailure('pwsh-missing', r.message);
  }

  private log(line: string): void {
    this.output.appendLine(`[${new Date().toLocaleTimeString()}] ${line}`);
  }

  private workflowVersion(root: string): string | undefined {
    try { return String(JSON.parse(fs.readFileSync(path.join(root, VERSION_REL), 'utf8'))['contract-version'] ?? '') || undefined; } catch { return undefined; }
  }

  // 只讀版本檔（現成的檔），不跑任何腳本。
  private tooOld(root: string): StatusView | undefined {
    const version = this.workflowVersion(root);
    if (!version || compareVersions(version, MIN_WORKFLOW_VERSION) >= 0) return undefined;
    return statusFromFailure('workflow-too-old', `這個專案的工作流是 ${version}，這個 extension 需要 ${MIN_WORKFLOW_VERSION} 以上（結構化的 -Json 從那一版開始）。升級工作流：把新版發佈物解壓到別處，跑 sdlc.ps1 update -Target <專案>。`);
  }

  private async runSdlc(root: string, command: string, params: string[] = [], timeoutMs = 180_000): Promise<SdlcCall> {
    const old = this.tooOld(root);
    if (old) return { ok: false, view: old };
    const failure = this.pwshFailure();
    if (failure) return { ok: false, view: failure };
    const pw = this.pwsh() as Extract<PwshResolution, { ok: true }>;
    const script = path.join(root, SDLC_REL);
    this.callCount[command] = (this.callCount[command] ?? 0) + 1;
    const run = await runPwsh(pw.path, fileArgs(script, [command, '-Target', root, '-Json', ...params]), { cwd: root, timeoutMs });
    if (run.spawnError || run.timedOut) {
      const msg = run.timedOut ? `sdlc.ps1 ${command} 超過 ${Math.round(timeoutMs / 1000)} 秒沒有結束` : `啟動 pwsh 失敗：${run.spawnError}`;
      this.log(`✖ ${msg}`);
      return { ok: false, view: statusFromFailure('script-failed', msg), run };
    }
    try {
      return { ok: true, env: parseEnvelope(run.stdout, command), run };
    } catch (e) {
      const view = this.contractFailure(root, e, run);
      return { ok: false, view, run };
    }
  }

  private contractFailure(root: string, e: unknown, run: RunResult): StatusView {
    const message = e instanceof Error ? e.message : String(e);
    this.log(`✖ ${message}`);
    if (run.stderr.trim()) this.log(run.stderr.trim());
    if (e instanceof ContractError && /schema/.test(message)) {
      const version = this.workflowVersion(root) ?? '未知';
      if (/太舊/.test(message)) {
        return statusFromFailure('workflow-too-old', `這個專案的工作流是 ${version}，沒有結構化的 -Json —— 這個 extension 需要 ${MIN_WORKFLOW_VERSION} 以上的工作流。升級工作流，或裝跟它同版的 extension。`);
      }
      return statusFromFailure('schema-mismatch', `${message}（專案的工作流是 ${version}）—— 裝跟工作流同一版發佈物附的 vsix。`);
    }
    return statusFromFailure('script-failed', `sdlc.ps1 的輸出讀不懂：${message}`);
  }

  // codex 執行檔在哪：設定 → PATH → OpenAI 的 VS Code extension 內附的那一支。
  // 只用 IDE 裡的 Codex 的人，hooks 信任狀態一樣記在 ~/.codex/config.toml，一樣問得到。
  private codexInfo(): MachineInfo['codex'] {
    const setting = (vscode.workspace.getConfiguration('codexSdlc').get<string>('codexPath') ?? '').trim();
    if (setting) return { source: 'setting', path: setting };
    const exe = process.platform === 'win32' ? ['codex.exe', 'codex.cmd'] : ['codex'];
    for (const d of (envValue(process.env, 'PATH') ?? '').split(path.delimiter)) {
      for (const x of exe) if (d && fs.existsSync(path.join(d, x))) return { source: 'path', path: path.join(d, x) };
    }
    if (this.bundledCodex === undefined) {
      this.bundledCodex = null;
      for (const ext of vscode.extensions.all.filter((x) => x.id.toLowerCase().startsWith('openai.'))) {
        const found = findFile(ext.extensionPath, process.platform === 'win32' ? 'codex.exe' : 'codex', 5);
        if (found) { this.bundledCodex = found; break; }
      }
    }
    return this.bundledCodex ? { source: 'bundled', path: this.bundledCodex } : { source: 'none' };
  }

  private codexParam(): string[] {
    const c = this.codexInfo();
    // PATH 上的交給 sdlc.ps1 自己找（它就是這樣找的）；另外兩種要明講。
    return (c.source === 'setting' || c.source === 'bundled') && c.path ? ['-CodexPath', c.path] : [];
  }

  // ---- 狀態 ----

  private schedule(s: RootState, delayMs: number): void {
    if (s.timer) clearTimeout(s.timer);
    s.timer = setTimeout(() => { s.timer = undefined; void this.refresh(s.root); }, delayMs);
  }

  async refresh(root: string): Promise<void> {
    const s = this.pick(root);
    if (!s) return;
    if (s.running) { s.again = true; await s.running; return; }
    s.running = (async () => {
      do {
        s.again = false;
        const started = Date.now();
        this.refreshViews();
        const call = await this.runSdlc(s.root, 'doctor', this.codexParam());
        if (call.ok) {
          try {
            s.doctor = parseDoctor(call.env);
            s.view = statusFromDoctor(s.doctor, new Date());
            // 這次 doctor 是在最後一次寫檔之後才開始的 → 它的 tuning.stale 已經算進那次寫檔，本地的標記可以放掉。
            if (started >= s.lastWrite) s.pendingAgents.clear();
          } catch (e) {
            s.doctor = undefined;
            s.view = this.contractFailure(s.root, e, call.run);
          }
        } else {
          s.doctor = undefined;
          s.view = call.view;
        }
        this.render();
      } while (s.again);
    })();
    try { await s.running; } finally { s.running = undefined; this.refreshViews(); }
  }

  private render(): void {
    const enabled = vscode.workspace.getConfiguration('codexSdlc').get<boolean>('statusBar.enabled') ?? true;
    const s = this.pick();
    // 換到另一個專案的檔 → 面板要跟著換。
    if (s?.root !== this.lastPicked) { this.lastPicked = s?.root; this.refreshViews(); }
    if (!enabled || !s) { this.item.hide(); return; }
    const view = s.view;
    if (!view) {
      this.item.text = '$(sync~spin) SDLC';
      this.item.tooltip = '正在跑 sdlc.ps1 doctor…';
      this.item.backgroundColor = undefined;
    } else {
      this.item.text = view.text;
      const md = new vscode.MarkdownString(view.tooltip.map((l) => l.replace(/[\\`*_{}[\]()#+\-.!|]/g, '\\$&')).join('  \n'));
      md.appendMarkdown(`  \n\n_${path.basename(s.root)} · 點一下打開選單_`);
      this.item.tooltip = md;
      this.item.backgroundColor = view.level === 'error' ? new vscode.ThemeColor('statusBarItem.errorBackground')
        : view.level === 'warn' ? new vscode.ThemeColor('statusBarItem.warningBackground') : undefined;
    }
    this.item.show();
  }

  private refreshViews(): void {
    this.treeChanged.fire();
    this.lensChanged.fire();
  }

  private async backgroundUpdateCheck(root: string): Promise<void> {
    if (this.pwshFailure()) return;
    const call = await this.runSdlc(root, 'check-update', ['-IfDue']);
    if (!call.ok) return;
    try {
      const d = parseCheckUpdate(call.env);
      this.log(`背景檢查更新：${d.status}${d.latest ? `（最新 ${d.latest}）` : ''}`);
    } catch (e) { this.log(`✖ check-update 的輸出讀不懂：${(e as Error).message}`); }
    // 快取檔若有變，watcher 會觸發重新健檢；這裡不跳通知 —— 更新提示不得變成一個要處理的待辦。
  }

  // ---- 設定面板 ----

  private canEdit(root: string): { ok: boolean; reason?: string; schema?: SettingsSchema } {
    const version = this.workflowVersion(root);
    if (!version || compareVersions(version, MIN_SETTINGS_VERSION) < 0) {
      return { ok: false, reason: `這個專案的工作流是 ${version ?? '未知版本'} —— 升到 ${MIN_SETTINGS_VERSION} 以上才能在這裡改（之前請手改 sdlc.config.json 再 apply）` };
    }
    let schema: SettingsSchema | undefined;
    try { schema = readSettingsSchema(root); } catch (e) { return { ok: false, reason: `${(e as Error).message} —— 重跑 sdlc.ps1 update 補回工具檔` }; }
    if (!schema) return { ok: false, reason: `找不到 ${CONFIG_SCHEMA_REL} —— 重跑 sdlc.ps1 update 補回工具檔` };
    if (!this.pwsh().ok) return { ok: false, reason: '找不到 PowerShell 7 —— 見「這台機器」', schema };
    return { ok: true, schema };
  }

  private readProposal(root: string): StoredProposalItem[] | undefined {
    try {
      const raw = JSON.parse(fs.readFileSync(path.join(root, PROPOSAL_REL), 'utf8'));
      if (!Array.isArray(raw?.proposal)) return undefined;
      return raw.proposal
        .filter((p: any) => typeof p?.agent === 'string' && typeof p?.effort === 'string')
        .map((p: any) => ({ agent: p.agent, effort: p.effort, reason: typeof p.reason === 'string' ? p.reason : '' }));
    } catch { return undefined; }
  }

  private treeInput(s: RootState): TreeInput {
    const edit = this.canEdit(s.root);
    let config: ConfigSnapshot | undefined;
    let configError: string | undefined;
    const cfgPath = path.join(s.root, CONFIG_REL);
    if (fs.existsSync(cfgPath)) {
      try { config = readConfig(fs.readFileSync(cfgPath, 'utf8')); } catch (e) { configError = e instanceof ConfigReadError ? e.message : String(e); }
    }
    // 還沒有設定檔時，agent 名冊來自工作流自己的 agent 定義（orchestrator 排最後 —— 它只是記錄）。
    let knownAgents: string[] = [];
    try {
      knownAgents = [
        ...fs.readdirSync(path.join(s.root, '.codex/agents')).filter((f) => f.endsWith('.toml')).map((f) => f.replace(/\.toml$/, '')).sort(),
        'orchestrator',
      ];
    } catch { /* 沒有 agent 目錄就不列 */ }
    const gdir = path.join(s.root, 'guidelines');
    const gExists = fs.existsSync(gdir);
    let files: string[] = [];
    try { files = gExists ? fs.readdirSync(gdir, { withFileTypes: true }).filter((e) => e.isFile()).map((e) => e.name).sort() : []; } catch { /* 讀不到就當沒有 */ }
    const rulesPath = path.join(s.root, RULES_REL);
    let ruleCount: number | undefined;
    try { ruleCount = countRules(fs.readFileSync(rulesPath, 'utf8')); } catch { /* 沒有或讀不到 */ }
    const pw = this.pwsh();
    return {
      rootName: path.basename(s.root),
      rootPath: s.root,
      workflowVersion: this.workflowVersion(s.root),
      schema: edit.schema,
      canEdit: edit.ok,
      editBlockedReason: edit.reason,
      config,
      configError,
      knownAgents,
      doctor: s.doctor,
      checking: !!s.running,
      pendingAgents: [...s.pendingAgents],
      proposal: this.readProposal(s.root),
      guidelines: { dir: gExists, files, rulesExists: fs.existsSync(rulesPath), ruleCount, gateDisabled: fs.existsSync(path.join(s.root, GATE_MARKER_REL)) },
      machine: {
        pwsh: pw.ok ? { ok: true, path: pw.path } : { ok: false, message: pw.message },
        codex: this.codexInfo(),
        extensionVersion: String(this.context.extension.packageJSON.version ?? ''),
      },
    };
  }

  private settingsTree(root?: string): SettingNode[] {
    const s = this.pick(root);
    return s ? buildSettingsTree(this.treeInput(s)) : [];
  }

  private codeLenses(doc: vscode.TextDocument): vscode.CodeLens[] {
    const s = this.stateFor(doc.uri);
    if (!s || !samePath(path.dirname(doc.uri.fsPath), s.root)) return [];
    const specs = configLenses(doc.getText(), {
      rootPath: s.root,
      pendingAgents: pendingAgentsOf({ doctor: s.doctor, pendingAgents: [...s.pendingAgents] }),
      proposal: this.readProposal(s.root),
      canEdit: this.canEdit(s.root).ok,
    });
    return specs.map((l) => new vscode.CodeLens(new vscode.Range(l.line, 0, l.line, 0), { title: l.title, command: l.command, arguments: l.arguments, tooltip: l.tooltip }));
  }

  // 單選清單：現值預先選好、點到別處不會消失。
  private pickOne<T extends vscode.QuickPickItem>(items: T[], opts: { title: string; placeholder?: string; active?: T }): Promise<T | undefined> {
    return new Promise((resolve) => {
      const qp = vscode.window.createQuickPick<T>();
      qp.title = opts.title;
      qp.placeholder = opts.placeholder;
      qp.items = items;
      qp.ignoreFocusOut = true;
      qp.matchOnDescription = true;
      if (opts.active) qp.activeItems = [opts.active];
      let done = false;
      qp.onDidAccept(() => { done = true; resolve(qp.selectedItems[0]); qp.hide(); });
      qp.onDidHide(() => { if (!done) resolve(undefined); qp.dispose(); });
      qp.show();
    });
  }

  private async editSettingCommand(root: string, arg: unknown): Promise<void> {
    const target = isEditTarget(arg) ? arg : isEditTarget((arg as SettingNode | undefined)?.edit) ? (arg as SettingNode).edit : undefined;
    if (!target) { await vscode.commands.executeCommand('codexSdlc.openSettings'); return; }
    let value: string | undefined;
    if (target.kind === 'choice') {
      type Item = vscode.QuickPickItem & { value: string };
      const items = target.choices.map<Item>((c) => ({
        label: c.label === c.value ? c.value : `${c.label}（${c.value}）`,
        description: [c.value === target.current ? '目前' : '', c.description].filter(Boolean).join(' · '),
        value: c.value,
      }));
      value = (await this.pickOne(items, { title: target.title, placeholder: target.placeholder, active: items.find((x) => x.value === target.current) }))?.value;
    } else {
      value = await this.askText(target);
    }
    if (value === undefined || value === target.current) return;
    await this.writeSettings(root, [`${target.key}=${value}`], {});
  }

  private async askText(t: Extract<EditTarget, { kind: 'text' }>): Promise<string | undefined> {
    if (t.suggestions.length > 0) {
      type Item = vscode.QuickPickItem & { value?: string };
      const items: Item[] = [
        ...t.suggestions.map<Item>((c: Choice) => ({ label: c.value, description: [c.value === t.current ? '目前' : '', c.description].filter(Boolean).join(' · '), value: c.value })),
        { label: '$(edit) 輸入其他值…', value: undefined },
      ];
      const picked = await this.pickOne(items, { title: t.title, placeholder: t.prompt, active: items.find((x) => x.value === t.current) });
      if (!picked) return undefined;
      if (picked.value !== undefined) return picked.value;
    }
    return vscode.window.showInputBox({
      title: t.title,
      prompt: t.prompt,
      value: t.current,
      ignoreFocusOut: true,
      validateInput: (v) => {
        if (!v && !t.allowEmpty) return '不能是空的';
        if (!matchesPattern(t.pattern, v)) return t.patternError;
        return undefined;
      },
    });
  }

  // 使用者在編輯器裡有沒存的修改時，sdlc.ps1 寫磁碟上的檔會跟它打架 —— 先問、先存。
  private async saveConfigIfDirty(root: string): Promise<boolean> {
    const doc = vscode.workspace.textDocuments.find((d) => d.uri.scheme === 'file' && samePath(d.uri.fsPath, path.join(root, CONFIG_REL)));
    if (!doc?.isDirty) return true;
    const choice = await vscode.window.showWarningMessage('sdlc.config.json 有還沒存的修改。先存檔再改？', { modal: true }, '存檔並繼續');
    if (choice !== '存檔並繼續') return false;
    return doc.save();
  }

  private async writeSettings(root: string, assignments: string[], opts: WriteOptions): Promise<SetData | undefined> {
    const s = this.pick(root);
    if (!s) return undefined;
    const edit = this.canEdit(root);
    if (!edit.ok) { void vscode.window.showWarningMessage(edit.reason ?? '這個專案不能在這裡改設定。'); return undefined; }
    if (!opts.preview && !(await this.saveConfigIfDirty(root))) return undefined;

    const params = [
      ...(opts.preset ? ['-Preset', opts.preset] : []),
      ...(opts.apply ? ['-Apply'] : []),
      ...(opts.yes ? ['-Yes'] : []),
      ...(opts.preview ? ['-Preview'] : []),
      ...assignments,
    ];
    const env = this.report(await this.runSdlc(root, 'set', params), opts.preview ? 'set（預覽）' : 'set');
    if (!env) return undefined;
    let d: SetData;
    try { d = parseSet(env); } catch (e) { void vscode.window.showErrorMessage(`set 的輸出讀不懂：${(e as Error).message}`); return undefined; }

    if (d.error === 'has-comments' && !opts.yes) {
      const choice = await vscode.window.showWarningMessage(
        'sdlc.config.json 裡有註解。',
        { modal: true, detail: '這個檔不支援註解，寫入會把它們移除（原檔會先備份到 bdd-docs/.sdlc/）。要留的說明請搬進 _note。' },
        '移除註解並寫入', '開啟設定檔',
      );
      if (choice === '移除註解並寫入') return this.writeSettings(root, assignments, { ...opts, yes: true });
      if (choice === '開啟設定檔') void vscode.window.showTextDocument(vscode.Uri.file(path.join(root, CONFIG_REL)));
      return d;
    }
    if (d.error) {
      const first = d.errors[0];
      const msg = first ? `${first.key}：${first.message}` : (env.warnings[0] ?? `set 沒有寫入（${d.error}）`);
      if (first?.suggestion && !opts.quiet) {
        void vscode.window.showErrorMessage(`${msg}。一個值都沒寫。`, `改用 ${first.suggestion}`).then((c) => {
          if (c) void this.writeSettings(root, [first.suggestion!], opts);
        });
      } else if (!opts.quiet || d.error !== 'cancelled') {
        void vscode.window.showErrorMessage(`${msg}。一個值都沒寫。`, '顯示輸出').then((c) => { if (c) this.output.show(); });
      }
      return d;
    }
    if (opts.preview) return d;

    const changed = d.changes.filter((c) => c.changed);
    if (d.written) {
      s.lastWrite = Date.now();
      for (const c of changed) {
        const m = /^agents\.([^.]+)\./.exec(c.key);
        if (m && c.needsApply) s.pendingAgents.add(m[1]);
      }
    }
    if (d.applied) s.pendingAgents.clear();
    if (!opts.quiet && changed.length > 0) {
      const pending = !d.applied && changed.some((c) => c.needsApply);
      const summary = changed.map((c) => `${c.key.replace(/^agents\./, '')} → ${c.to || '（空）'}`).join('、');
      const created = d.configCreated ? '已建立 sdlc.config.json；' : '';
      vscode.window.setStatusBarMessage(`$(check) ${created}已寫入：${summary}${pending ? '（還沒套用）' : ''}`, 6000);
    }
    this.refreshViews();
    this.schedule(s, 300);
    return d;
  }

  private async applyPresetCommand(root: string): Promise<void> {
    const edit = this.canEdit(root);
    if (!edit.ok) { void vscode.window.showWarningMessage(edit.reason ?? '這個專案不能在這裡改設定。'); return; }
    let presets: Record<string, Record<string, { effort?: string; model?: string }>> = {};
    try { presets = JSON.parse(fs.readFileSync(path.join(root, PROFILES_REL), 'utf8')).presets ?? {}; } catch { /* 下面會說 */ }
    const names = Object.keys(presets);
    if (names.length === 0) { void vscode.window.showWarningMessage(`讀不到預設組合（${PROFILES_REL}）。`); return; }
    type Item = vscode.QuickPickItem & { name: string };
    const items = names.map<Item>((n) => ({
      label: n,
      description: Object.entries(presets[n]).map(([a, v]) => `${a} ${v.effort ?? 'inherit'}`).join(' · '),
      name: n,
    }));
    const picked = await this.pickOne(items, { title: '換成哪一組？', placeholder: '下一步會先列出會改哪些值，確認了才寫' });
    if (!picked) return;
    const preview = await this.writeSettings(root, [], { preset: picked.name, preview: true, quiet: true });
    if (!preview || preview.error) return;
    const changed = preview.changes.filter((c) => c.changed);
    if (changed.length === 0) { void vscode.window.showInformationMessage(`現在的設定已經是 ${picked.name} 這一組。`); return; }
    const detail = changed.map((c) => `${c.key}：${c.from ?? '（沒設）'} → ${c.to}`).join('\n');
    const ok = await vscode.window.showInformationMessage(`換成 ${picked.name}？會改 ${changed.length} 個值並套用。`, { modal: true, detail }, '換成這組並套用');
    if (ok !== '換成這組並套用') return;
    const d = await this.writeSettings(root, [], { preset: picked.name, yes: true, apply: true });
    if (d && !d.error) void vscode.window.showInformationMessage(`已換成 ${picked.name} 並套用。`);
  }

  private async applyProposal(root: string, agents: string[]): Promise<void> {
    const edit = this.canEdit(root);
    if (!edit.ok) { void vscode.window.showWarningMessage(edit.reason ?? '這個專案不能在這裡改設定。'); return; }
    if (!(await this.saveConfigIfDirty(root))) return;
    const env = this.report(await this.runSdlc(root, 'tune', ['-ApplyProposal', '-Only', agents.join(',')]), 'tune -ApplyProposal');
    if (!env) return;
    if (env.exit !== 0) {
      void vscode.window.showErrorMessage(`套用建議失敗：${env.warnings[0] ?? '見輸出面板'}`, '顯示輸出').then((c) => { if (c) this.output.show(); });
      return;
    }
    const s = this.pick(root);
    if (s) { s.lastWrite = Date.now(); s.pendingAgents.clear(); }
    void vscode.window.showInformationMessage(`已套用 tune 的建議：${agents.join('、')}。`);
    this.refreshViews();
    await this.refresh(root);
  }

  private async trustHooksCommand(root: string): Promise<void> {
    const c = this.codexInfo();
    if (c.source === 'none' || !c.path) {
      void vscode.window.showWarningMessage('找不到 codex 執行檔 —— 先裝 Codex CLI，或指定它的位置。', '選擇 codex 執行檔…').then((x) => {
        if (x) void vscode.commands.executeCommand('codexSdlc.pickCodex');
      });
      return;
    }
    const pw = this.pwsh();
    const name = 'Codex（信任 hooks）';
    // 用 pwsh 開，不靠使用者預設的 shell —— 引號規則才是確定的。-NoExit：Codex 結束後終端機留著，看得到它說了什麼。
    const term = pw.ok
      ? vscode.window.createTerminal({ name, cwd: root, shellPath: pw.path, shellArgs: ['-NoLogo', '-NoExit', '-Command', `& ${psQuote(c.path)}`] })
      : vscode.window.createTerminal({ name, cwd: root });
    if (!pw.ok) term.sendText(`"${c.path}"`);
    term.show();
    const closed = vscode.window.onDidCloseTerminal((t) => { if (t === term) { closed.dispose(); void this.refresh(root); } });
    this.disposables.push(closed);
    void vscode.window.showInformationMessage(
      '在 Codex 的畫面裡：先信任這個資料夾，出現「Hooks need review」時選 Trust all and continue。做完再按「重新檢查」（關掉終端機也會自動檢查）。',
      '重新檢查',
    ).then((x) => { if (x) void this.refresh(root); });
  }

  private async toggleGateCommand(root: string): Promise<void> {
    const marker = path.join(root, GATE_MARKER_REL);
    if (fs.existsSync(marker)) {
      fs.rmSync(marker, { force: true });
      void vscode.window.showInformationMessage('規範的機械層打開了 —— 寫檔後會再用 guidelines/rules.json 掃。');
    } else {
      const ok = await vscode.window.showWarningMessage(
        '關掉規範的機械層？',
        { modal: true, detail: '關掉之後 guidelines/rules.json 一條都不會擋，包括標成 block 的規則。這個開關是 guidelines/.gate-disabled 這個檔 —— 它會活過每一次升級，doctor 會一直提醒到你刪掉它為止。' },
        '關閉機械層',
      );
      if (ok !== '關閉機械層') return;
      fs.mkdirSync(path.dirname(marker), { recursive: true });
      fs.writeFileSync(marker, `由 VS Code 的 Codex SDLC 設定面板於 ${new Date().toISOString()} 建立。刪掉這個檔 = 打開規範的機械層。\n`);
    }
    const s = this.pick(root);
    this.refreshViews();
    if (s) this.schedule(s, 300);
  }

  private async pickExecutable(setting: 'pwshPath' | 'codexPath', title: string): Promise<void> {
    const uris = await vscode.window.showOpenDialog({
      title,
      canSelectMany: false,
      openLabel: '使用這個檔',
      filters: process.platform === 'win32' ? { 執行檔: ['exe', 'cmd'] } : undefined,
    });
    if (!uris?.[0]) return;
    // 機器上的路徑，寫進使用者層級的 VS Code 設定 —— 不進專案、不進 sdlc.config.json。
    await vscode.workspace.getConfiguration('codexSdlc').update(setting, uris[0].fsPath, vscode.ConfigurationTarget.Global);
    if (setting === 'codexPath') this.bundledCodex = undefined;
    void vscode.window.showInformationMessage(`已設定 codexSdlc.${setting}：${uris[0].fsPath}`);
  }

  // ---- Problems：存檔時跑 gate ----

  private queueScan(uri: vscode.Uri, delayMs = 700): void {
    if (!(vscode.workspace.getConfiguration('codexSdlc').get<boolean>('problems.enabled') ?? true)) return;
    const s = this.stateFor(uri);
    if (!s) return;
    const rel = path.relative(s.root, uri.fsPath).replace(/\\/g, '/');
    // rules.json 本身不給 gate 掃（gate 本來就排除 guidelines/），改成驗它自己。
    if (rel === RULES_REL) { void this.validateRules(s.root, uri); return; }
    s.scanPending.add(rel);
    if (s.scanTimer) clearTimeout(s.scanTimer);
    s.scanTimer = setTimeout(() => { s.scanTimer = undefined; void this.drainScans(s); }, delayMs);
  }

  private async validateRules(root: string, uri: vscode.Uri): Promise<void> {
    if (this.tooOld(root) || this.pwshFailure()) return;
    const gate = path.join(root, GUIDELINE_GATE_REL);
    if (!fs.existsSync(gate)) return;
    const pw = this.pwsh() as Extract<PwshResolution, { ok: true }>;
    const run = await runPwsh(pw.path, fileArgs(gate, ['-Validate', '-Json', '-RulesFile', uri.fsPath]), { cwd: root, timeoutMs: 60_000 });
    let text = '';
    try { text = fs.readFileSync(uri.fsPath, 'utf8'); } catch { /* 讀不到就全部放第一行 */ }
    try {
      const outcome = rulesOutcome(parseRulesValidation(run.stdout), text);
      this.rulesDiag.set(uri, outcome.records.map(toDiagnostic));
    } catch (e) {
      this.log(`✖ guideline-gate -Validate 的輸出讀不懂：${(e as Error).message}${run.stderr ? ` / ${run.stderr.trim()}` : ''}`);
    }
  }

  private async drainScans(s: RootState): Promise<void> {
    if (s.scanning) return;   // 正在跑的那一輪結束後會再看一次 pending
    s.scanning = (async () => {
      while (s.scanPending.size > 0) {
        const batch = [...s.scanPending];
        s.scanPending.clear();
        await this.scanBatch(s.root, batch);
      }
    })();
    try { await s.scanning; } finally { s.scanning = undefined; }
  }

  private async scanBatch(root: string, rels: string[]): Promise<void> {
    if (this.tooOld(root) || this.pwshFailure()) return;
    const pw = this.pwsh() as Extract<PwshResolution, { ok: true }>;
    const gate = async (rel: string, extra: string[], parse: (out: string) => ScanOutcome, collection: vscode.DiagnosticCollection) => {
      const script = path.join(root, rel);
      if (!fs.existsSync(script)) return;
      const run = await runPwsh(pw.path, encodedCommandArgs(gateInvocation(script, rels, extra)), { cwd: root, timeoutMs: 60_000 });
      let outcome: ScanOutcome;
      try {
        outcome = parse(run.stdout);
      } catch (e) {
        this.log(`✖ ${path.basename(rel)} 的輸出讀不懂：${(e as Error).message}${run.stderr ? ` / ${run.stderr.trim()}` : ''}`);
        return;
      }
      if (outcome.note) this.log(`⚠ ${outcome.note}`);
      for (const [file, records] of groupByFile(outcome, rels)) {
        collection.set(vscode.Uri.file(path.join(root, file)), records.map(toDiagnostic));
      }
    };
    await Promise.all([
      gate(GUIDELINE_GATE_REL, ['-MaxReport', '500'], (o) => guidelineOutcome(parseGuidelineGate(o)), this.guidelineDiag),
      gate(DLP_GATE_REL, [], (o) => dlpOutcome(parseDlpGate(o)), this.dlpDiag),
    ]);
  }

  // ---- 指令 ----

  private async menu(): Promise<void> {
    const s = this.pick();
    const items: (vscode.QuickPickItem & { id?: string })[] = [
      { label: '$(settings-gear) 開啟設定面板', description: '一眼看到全部設定；改值、套用、換預設組合', id: 'codexSdlc.openSettings' },
      { label: '$(refresh) 重新整理狀態', id: 'codexSdlc.refresh' },
      { label: '$(checklist) doctor', description: '完整健檢，結果寫進輸出面板', id: 'codexSdlc.doctor' },
      { label: '$(sync) apply', description: '把 sdlc.config.json 套到 agent 定義', id: 'codexSdlc.apply' },
      { label: '$(lightbulb) tune', description: '依 repo 現況給調校建議，你勾選要套用哪幾個', id: 'codexSdlc.tune' },
      { label: '$(book) whatsnew', description: '這一版／新版的變更說明', id: 'codexSdlc.whatsnew' },
      { label: '$(cloud-download) 立即檢查更新', id: 'codexSdlc.checkUpdate' },
      { label: '$(rocket) 開始使用', description: '四步引導：信任 hooks、選預設組合、健檢、設定在哪', id: 'codexSdlc.openWalkthrough' },
      { label: '$(output) 顯示輸出', id: 'codexSdlc.showOutput' },
    ];
    const issues = s?.view?.issues ?? [];
    const pick = await vscode.window.showQuickPick(
      [...issues.map((i) => ({ label: `${i.level === 'error' ? '$(error)' : '$(warning)'} ${i.badge.replace(/^\$\([^)]+\)\s*/, '')}`, detail: i.detail })), ...items],
      { title: s ? `Codex SDLC —— ${path.basename(s.root)}` : 'Codex SDLC', matchOnDetail: true },
    );
    if (pick && 'id' in pick && pick.id) await vscode.commands.executeCommand(pick.id);
    else if (pick) this.output.show();
  }

  private report(call: SdlcCall, title: string): Envelope | undefined {
    if (!call.ok) {
      void vscode.window.showErrorMessage(`${title}：${call.view.tooltip[0]}`, '顯示輸出').then((c) => { if (c) this.output.show(); });
      return undefined;
    }
    this.log(`── ${title}（exit ${call.env.exit}）`);
    for (const l of call.env.output) this.output.appendLine(l);
    for (const w of call.env.warnings) this.output.appendLine(`⚠ ${w}`);
    return call.env;
  }

  private async doctorCommand(root: string): Promise<void> {
    const env = this.report(await this.runSdlc(root, 'doctor', this.codexParam()), 'doctor');
    if (!env) return;
    const d = parseDoctor(env);
    const s = this.pick(root);
    if (s) { s.doctor = d; s.view = statusFromDoctor(d, new Date()); this.render(); this.refreshViews(); }
    if (d.problems === 0) void vscode.window.showInformationMessage('doctor：沒有問題。');
    else void vscode.window.showWarningMessage(`doctor：${d.problems} 個問題。`, '看詳細').then((c) => { if (c) this.output.show(); });
  }

  private async applyCommand(root: string): Promise<void> {
    if (!(await this.saveConfigIfDirty(root))) return;
    const env = this.report(await this.runSdlc(root, 'apply'), 'apply');
    if (!env) return;
    if (env.exit !== 0) {
      void vscode.window.showErrorMessage(`apply 失敗：${env.warnings[0] ?? '見輸出面板'}`, '顯示輸出').then((c) => { if (c) this.output.show(); });
      return;
    }
    const d = parseApply(env);
    void vscode.window.showInformationMessage(d.changed.length > 0 ? `apply：更新了 ${d.changed.join('、')}` : 'apply：沒有變更，agent 定義已經跟設定檔一致。');
    await this.refresh(root);
  }

  private async tuneCommand(root: string): Promise<void> {
    const env = this.report(await this.runSdlc(root, 'tune'), 'tune');
    if (!env) return;
    const t = parseTune(env);
    if (t.proposal.length === 0) { void vscode.window.showWarningMessage('tune 沒有產出建議 —— 見輸出面板。'); return; }
    this.refreshViews();
    const diffs = t.proposal.filter((p) => p.current !== p.proposed);
    if (diffs.length === 0) {
      void vscode.window.showInformationMessage('現在的設定已經跟 tune 的建議一致。', '看理由').then((c) => { if (c) this.output.show(); });
      return;
    }
    if (!this.canEdit(root).ok) {
      void vscode.window.showInformationMessage(`tune 有 ${diffs.length} 項建議（見輸出面板）。${this.canEdit(root).reason ?? ''}`, '顯示輸出').then((c) => { if (c) this.output.show(); });
      return;
    }
    type Item = vscode.QuickPickItem & { agent: string };
    const picks = await vscode.window.showQuickPick<Item>(
      diffs.map((p) => ({ label: `${p.agent}：${p.current} → ${p.proposed}`, detail: `理由：${p.reason}　訊號：${p.signal}`, picked: true, agent: p.agent })),
      { title: 'tune 的建議 —— 勾選要套用的（這是提議，不會自己套用）', canPickMany: true, ignoreFocusOut: true, matchOnDetail: true },
    );
    if (!picks || picks.length === 0) return;
    await this.applyProposal(root, picks.map((p) => p.agent));
  }

  private async whatsNewCommand(root: string): Promise<void> {
    const env = this.report(await this.runSdlc(root, 'whatsnew'), 'whatsnew');
    if (!env) return;
    const w = parseWhatsNew(env);
    this.output.show(true);
    if (w.source === 'cache' && w.latest) void vscode.window.showInformationMessage(`新版 ${w.latest} 的說明在輸出面板。升級：把新版發佈物解壓到別處，跑 sdlc.ps1 update -Target <專案>。`);
    await this.refresh(root);
  }

  private async checkUpdateCommand(root: string): Promise<void> {
    const env = this.report(await this.runSdlc(root, 'check-update'), 'check-update');
    if (!env) return;
    const d = parseCheckUpdate(env);
    const text: Record<string, string> = {
      newer: `有新版 ${d.latest}（你在 ${d.installed}）。`,
      'up-to-date': `已是最新（${d.installed}）。`,
      disabled: '設定為不檢查更新（sdlc.config.json 的 update.check = never）。',
      unreachable: '檢查不到更新（離線或來源不可達）。不影響任何流程。',
      'unsupported-source': '更新來源沒有設定（或不是 GitHub repo 的網址）—— 在設定面板的「更新 → 來源」填上。',
    };
    const choice = d.status === 'unsupported-source' ? '開啟設定面板' : undefined;
    void vscode.window.showInformationMessage(text[d.status] ?? `check-update：${d.status}`, ...(choice ? [choice] : [])).then((c) => {
      if (c) void vscode.commands.executeCommand('codexSdlc.openSettings');
    });
    await this.refresh(root);
  }
}

function toDiagnostic(r: DiagnosticRecord): vscode.Diagnostic {
  const line = Math.max(0, r.line - 1);
  const d = new vscode.Diagnostic(
    new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER),
    r.message,
    r.severity === 'error' ? vscode.DiagnosticSeverity.Error : vscode.DiagnosticSeverity.Warning,
  );
  d.source = r.source;
  d.code = r.code;
  return d;
}

function findFile(dir: string, name: string, depth: number): string | undefined {
  if (depth < 0) return undefined;
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return undefined; }
  for (const e of entries) if (e.isFile() && e.name.toLowerCase() === name.toLowerCase()) return path.join(dir, e.name);
  for (const e of entries) {
    if (!e.isDirectory() || e.name === 'node_modules') continue;
    const hit = findFile(path.join(dir, e.name), name, depth - 1);
    if (hit) return hit;
  }
  return undefined;
}

let cockpit: Cockpit | undefined;

export function activate(context: vscode.ExtensionContext): CockpitApi {
  cockpit = new Cockpit(context);
  context.subscriptions.push(cockpit);
  cockpit.start();
  return cockpit.api;
}

export function deactivate(): void {
  cockpit?.dispose();
  cockpit = undefined;
}
