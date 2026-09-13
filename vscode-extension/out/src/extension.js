"use strict";
// Codex SDLC 的駕駛艙。**它是 sdlc.ps1 與各 gate 的殼，不是第二份實作。**
//
// 刻意不做的三件事（也寫在 README）：
//   1. 不推測「現在在流程的第幾步」—— 流程狀態活在對話裡，靠檔案反推會猜錯。
//   2. 不自己實作任何 lint／gate／sha 邏輯 —— 狀態一律來自 sdlc.ps1 -Json 的 data，違規一律來自 gate 的 -Json。
//   3. 不把工作流設定存進 VS Code settings —— 那裡每機器一份、不進版控、團隊看不到。
//      唯一真相是 sdlc.config.json；這裡的 settings 只有「pwsh 在哪」這類機器上的事。
//
// 這支檔是唯一 import vscode 的地方。能在純 Node 底下測的邏輯都在 pwsh／contract／status／diagnostics／tuning。
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.activate = activate;
exports.deactivate = deactivate;
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const vscode = __importStar(require("vscode"));
const contract_1 = require("./contract");
const diagnostics_1 = require("./diagnostics");
const pwsh_1 = require("./pwsh");
const status_1 = require("./status");
const tuning_1 = require("./tuning");
const VERSION_REL = '.codex/bdd-workflow/bdd-workflow-version.json';
const SDLC_REL = '.codex/scripts/sdlc.ps1';
const GUIDELINE_GATE_REL = '.codex/scripts/guideline-gate.ps1';
const DLP_GATE_REL = '.codex/scripts/dlp-gate.ps1';
const CONFIG_REL = 'sdlc.config.json';
const UPDATE_INTERVAL_MS = 60 * 60 * 1000; // 只是「問 sdlc.ps1 到期了沒」—— 真的連網與否由 update.check 決定
const samePath = (a, b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
class Cockpit {
    context;
    output = vscode.window.createOutputChannel('Codex SDLC');
    item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
    guidelineDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-guideline');
    dlpDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-dlp');
    states = new Map();
    disposables = [];
    pwshCache;
    pwshWarned = false;
    bundledCodex;
    updateTimer;
    constructor(context) {
        this.context = context;
        this.item.command = 'codexSdlc.menu';
        this.disposables.push(this.output, this.item, this.guidelineDiag, this.dlpDiag);
    }
    // ---- 生命週期 ----
    start() {
        const reg = (id, fn) => this.disposables.push(vscode.commands.registerCommand(id, fn));
        reg('codexSdlc.menu', () => this.menu());
        reg('codexSdlc.refresh', () => this.withRoot((r) => this.refresh(r)));
        reg('codexSdlc.doctor', () => this.withRoot((r) => this.doctorCommand(r)));
        reg('codexSdlc.apply', () => this.withRoot((r) => this.applyCommand(r)));
        reg('codexSdlc.editTuning', () => this.withRoot((r) => this.editTuningCommand(r)));
        reg('codexSdlc.tune', () => this.withRoot((r) => this.tuneCommand(r)));
        reg('codexSdlc.whatsnew', () => this.withRoot((r) => this.whatsNewCommand(r)));
        reg('codexSdlc.checkUpdate', () => this.withRoot((r) => this.checkUpdateCommand(r)));
        reg('codexSdlc.showOutput', () => this.output.show());
        this.disposables.push(vscode.workspace.onDidSaveTextDocument((d) => this.queueScan(d.uri)), vscode.workspace.onDidOpenTextDocument((d) => this.queueScan(d.uri)), vscode.window.onDidChangeActiveTextEditor(() => this.render()), vscode.workspace.onDidChangeWorkspaceFolders(() => this.syncRoots()), vscode.workspace.onDidChangeConfiguration((e) => {
            if (e.affectsConfiguration('codexSdlc.pwshPath')) {
                this.pwshCache = undefined;
                this.pwshWarned = false;
            }
            if (e.affectsConfiguration('codexSdlc')) {
                this.render();
                for (const s of this.states.values())
                    this.schedule(s, 0);
            }
        }));
        // 工作流的檔一變就重新健檢：改了設定、apply 寫了 toml、升級換了版本檔、check-update 寫了快取、hooks.json 被改。
        const watcher = vscode.workspace.createFileSystemWatcher('**/{sdlc.config.json,.codex/agents/*.toml,.codex/hooks.json,.codex/bdd-workflow/bdd-workflow-version.json,bdd-docs/.sdlc/update-cache.json,guidelines/*}');
        const onFile = (uri) => {
            if (uri.fsPath.replace(/\\/g, '/').endsWith(VERSION_REL))
                this.syncRoots();
            const s = this.stateFor(uri);
            if (s)
                this.schedule(s, 800);
        };
        this.disposables.push(watcher, watcher.onDidChange(onFile), watcher.onDidCreate(onFile), watcher.onDidDelete(onFile));
        this.syncRoots();
        for (const doc of vscode.workspace.textDocuments)
            this.queueScan(doc.uri);
        // 背景刷新更新快取。這是這個 extension 唯一買得到、腳本層買不到的東西：沒有任何使用者動作也會發生。
        // 要不要真的連網由 sdlc.ps1 看 update.check 決定（never = 一條連線都沒有），這裡只負責定時問。
        const tick = () => { for (const s of this.states.values())
            void this.backgroundUpdateCheck(s.root); };
        setTimeout(tick, 5_000);
        this.updateTimer = setInterval(tick, UPDATE_INTERVAL_MS);
    }
    dispose() {
        if (this.updateTimer)
            clearInterval(this.updateTimer);
        for (const s of this.states.values()) {
            if (s.timer)
                clearTimeout(s.timer);
            if (s.scanTimer)
                clearTimeout(s.scanTimer);
        }
        for (const d of this.disposables)
            d.dispose();
    }
    api = {
        roots: () => [...this.states.keys()],
        status: (root) => this.pick(root)?.view,
        doctor: (root) => this.pick(root)?.doctor,
        refresh: async (root) => {
            const targets = root ? [this.pick(root)].filter((x) => !!x) : [...this.states.values()];
            await Promise.all(targets.map((s) => this.refresh(s.root)));
        },
        scan: async (uri) => {
            const s = this.stateFor(uri);
            if (!s)
                return;
            this.queueScan(uri, 0);
            await new Promise((r) => setTimeout(r, 20));
            while (s.scanTimer || s.scanning) {
                if (s.scanning)
                    await s.scanning;
                else
                    await new Promise((r) => setTimeout(r, 20));
            }
        },
        diagnostics: (uri) => [...(this.guidelineDiag.get(uri) ?? []), ...(this.dlpDiag.get(uri) ?? [])],
    };
    // ---- 工作區 ----
    syncRoots() {
        const found = (vscode.workspace.workspaceFolders ?? [])
            .map((f) => f.uri.fsPath)
            .filter((p) => fs.existsSync(path.join(p, VERSION_REL)));
        for (const key of [...this.states.keys()])
            if (!found.some((f) => samePath(f, key)))
                this.states.delete(key);
        for (const root of found) {
            if ([...this.states.keys()].some((k) => samePath(k, root)))
                continue;
            const s = { root, again: false, scanPending: new Set() };
            this.states.set(root, s);
            this.schedule(s, 0);
        }
        this.render();
    }
    stateFor(uri) {
        if (uri.scheme !== 'file')
            return undefined;
        let best;
        for (const s of this.states.values()) {
            const rel = path.relative(s.root, uri.fsPath);
            if (rel.startsWith('..') || path.isAbsolute(rel))
                continue;
            if (!best || s.root.length > best.root.length)
                best = s;
        }
        return best;
    }
    pick(root) {
        if (root)
            return [...this.states.values()].find((s) => samePath(s.root, root));
        const editor = vscode.window.activeTextEditor;
        return (editor && this.stateFor(editor.document.uri)) ?? this.states.values().next().value;
    }
    async withRoot(fn) {
        const s = this.pick();
        if (!s) {
            void vscode.window.showInformationMessage('這個工作區沒有安裝 Codex SDLC 工作流（找不到 .codex/bdd-workflow/bdd-workflow-version.json）。');
            return;
        }
        await fn(s.root);
    }
    // ---- 執行 ----
    pwsh() {
        if (!this.pwshCache) {
            const setting = vscode.workspace.getConfiguration('codexSdlc').get('pwshPath') ?? '';
            this.pwshCache = (0, pwsh_1.resolvePwsh)({ setting, env: process.env, platform: process.platform, exists: (p) => { try {
                    return fs.statSync(p).isFile();
                }
                catch {
                    return false;
                } } });
        }
        return this.pwshCache;
    }
    pwshFailure() {
        const r = this.pwsh();
        if (r.ok)
            return undefined;
        if (!this.pwshWarned) {
            this.pwshWarned = true;
            void vscode.window.showErrorMessage(r.message, '安裝 PowerShell 7', '打開設定').then((choice) => {
                if (choice === '安裝 PowerShell 7')
                    void vscode.env.openExternal(vscode.Uri.parse(pwsh_1.INSTALL_URL));
                if (choice === '打開設定')
                    void vscode.commands.executeCommand('workbench.action.openSettings', 'codexSdlc.pwshPath');
            });
        }
        this.log(`✖ ${r.message}`);
        return (0, status_1.statusFromFailure)('pwsh-missing', r.message);
    }
    log(line) {
        this.output.appendLine(`[${new Date().toLocaleTimeString()}] ${line}`);
    }
    // 只讀版本檔（現成的檔），不跑任何腳本。
    tooOld(root) {
        let version = '';
        try {
            version = String(JSON.parse(fs.readFileSync(path.join(root, VERSION_REL), 'utf8'))['contract-version'] ?? '');
        }
        catch {
            return undefined;
        }
        if (!version || (0, contract_1.compareVersions)(version, contract_1.MIN_WORKFLOW_VERSION) >= 0)
            return undefined;
        return (0, status_1.statusFromFailure)('workflow-too-old', `這個專案的工作流是 ${version}，這個 extension 需要 ${contract_1.MIN_WORKFLOW_VERSION} 以上（結構化的 -Json 從那一版開始）。升級工作流：把新版發佈物解壓到別處，跑 sdlc.ps1 update -Target <專案>。`);
    }
    async runSdlc(root, command, params = [], timeoutMs = 180_000) {
        const old = this.tooOld(root);
        if (old)
            return { ok: false, view: old };
        const failure = this.pwshFailure();
        if (failure)
            return { ok: false, view: failure };
        const pw = this.pwsh();
        const script = path.join(root, SDLC_REL);
        const run = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.fileArgs)(script, [command, '-Target', root, '-Json', ...params]), { cwd: root, timeoutMs });
        if (run.spawnError || run.timedOut) {
            const msg = run.timedOut ? `sdlc.ps1 ${command} 超過 ${Math.round(timeoutMs / 1000)} 秒沒有結束` : `啟動 pwsh 失敗：${run.spawnError}`;
            this.log(`✖ ${msg}`);
            return { ok: false, view: (0, status_1.statusFromFailure)('script-failed', msg), run };
        }
        try {
            return { ok: true, env: (0, contract_1.parseEnvelope)(run.stdout, command), run };
        }
        catch (e) {
            const view = this.contractFailure(root, e, run);
            return { ok: false, view, run };
        }
    }
    contractFailure(root, e, run) {
        const message = e instanceof Error ? e.message : String(e);
        this.log(`✖ ${message}`);
        if (run.stderr.trim())
            this.log(run.stderr.trim());
        if (e instanceof contract_1.ContractError && /schema/.test(message)) {
            let version = '未知';
            try {
                version = JSON.parse(fs.readFileSync(path.join(root, VERSION_REL), 'utf8'))['contract-version'] ?? version;
            }
            catch { /* 讀不到就說未知 */ }
            if (/太舊/.test(message)) {
                return (0, status_1.statusFromFailure)('workflow-too-old', `這個專案的工作流是 ${version}，沒有結構化的 -Json —— 這個 extension 需要 4.8.0 以上的工作流。升級工作流，或裝跟它同版的 extension。`);
            }
            return (0, status_1.statusFromFailure)('schema-mismatch', `${message}（專案的工作流是 ${version}）—— 裝跟工作流同一版發佈物附的 vsix。`);
        }
        return (0, status_1.statusFromFailure)('script-failed', `sdlc.ps1 的輸出讀不懂：${message}`);
    }
    codexParam() {
        const setting = (vscode.workspace.getConfiguration('codexSdlc').get('codexPath') ?? '').trim();
        if (setting)
            return ['-CodexPath', setting];
        // PATH 上有 codex 就交給 sdlc.ps1 自己找；沒有的話，看 OpenAI 的 VS Code extension 有沒有內附一支 ——
        // 只用 IDE 裡的 Codex 的人，hooks 信任狀態一樣記在 ~/.codex/config.toml，一樣問得到。
        const exe = process.platform === 'win32' ? ['codex.exe', 'codex.cmd'] : ['codex'];
        const onPath = ((0, pwsh_1.envValue)(process.env, 'PATH') ?? '').split(path.delimiter).some((d) => d && exe.some((x) => fs.existsSync(path.join(d, x))));
        if (onPath)
            return [];
        if (this.bundledCodex === undefined) {
            this.bundledCodex = null;
            for (const ext of vscode.extensions.all.filter((x) => x.id.toLowerCase().startsWith('openai.'))) {
                const found = findFile(ext.extensionPath, process.platform === 'win32' ? 'codex.exe' : 'codex', 5);
                if (found) {
                    this.bundledCodex = found;
                    break;
                }
            }
        }
        return this.bundledCodex ? ['-CodexPath', this.bundledCodex] : [];
    }
    // ---- 狀態 ----
    schedule(s, delayMs) {
        if (s.timer)
            clearTimeout(s.timer);
        s.timer = setTimeout(() => { s.timer = undefined; void this.refresh(s.root); }, delayMs);
    }
    async refresh(root) {
        const s = this.pick(root);
        if (!s)
            return;
        if (s.running) {
            s.again = true;
            await s.running;
            return;
        }
        s.running = (async () => {
            do {
                s.again = false;
                const call = await this.runSdlc(s.root, 'doctor', this.codexParam());
                if (call.ok) {
                    try {
                        s.doctor = (0, contract_1.parseDoctor)(call.env);
                        s.view = (0, status_1.statusFromDoctor)(s.doctor, new Date());
                    }
                    catch (e) {
                        s.doctor = undefined;
                        s.view = this.contractFailure(s.root, e, call.run);
                    }
                }
                else {
                    s.doctor = undefined;
                    s.view = call.view;
                }
                this.render();
            } while (s.again);
        })();
        try {
            await s.running;
        }
        finally {
            s.running = undefined;
        }
    }
    render() {
        const enabled = vscode.workspace.getConfiguration('codexSdlc').get('statusBar.enabled') ?? true;
        const s = this.pick();
        if (!enabled || !s) {
            this.item.hide();
            return;
        }
        const view = s.view;
        if (!view) {
            this.item.text = '$(sync~spin) SDLC';
            this.item.tooltip = '正在跑 sdlc.ps1 doctor…';
            this.item.backgroundColor = undefined;
        }
        else {
            this.item.text = view.text;
            const md = new vscode.MarkdownString(view.tooltip.map((l) => l.replace(/[\\`*_{}[\]()#+\-.!|]/g, '\\$&')).join('  \n'));
            md.appendMarkdown(`  \n\n_${path.basename(s.root)} · 點一下打開選單_`);
            this.item.tooltip = md;
            this.item.backgroundColor = view.level === 'error' ? new vscode.ThemeColor('statusBarItem.errorBackground')
                : view.level === 'warn' ? new vscode.ThemeColor('statusBarItem.warningBackground') : undefined;
        }
        this.item.show();
    }
    async backgroundUpdateCheck(root) {
        if (this.pwshFailure())
            return;
        const call = await this.runSdlc(root, 'check-update', ['-IfDue']);
        if (!call.ok)
            return;
        try {
            const d = (0, contract_1.parseCheckUpdate)(call.env);
            this.log(`背景檢查更新：${d.status}${d.latest ? `（最新 ${d.latest}）` : ''}`);
        }
        catch (e) {
            this.log(`✖ check-update 的輸出讀不懂：${e.message}`);
        }
        // 快取檔若有變，watcher 會觸發重新健檢；這裡不跳通知 —— 更新提示不得變成一個要處理的待辦。
    }
    // ---- Problems：存檔時跑 gate ----
    queueScan(uri, delayMs = 700) {
        if (!(vscode.workspace.getConfiguration('codexSdlc').get('problems.enabled') ?? true))
            return;
        const s = this.stateFor(uri);
        if (!s)
            return;
        s.scanPending.add(path.relative(s.root, uri.fsPath).replace(/\\/g, '/'));
        if (s.scanTimer)
            clearTimeout(s.scanTimer);
        s.scanTimer = setTimeout(() => { s.scanTimer = undefined; void this.drainScans(s); }, delayMs);
    }
    async drainScans(s) {
        if (s.scanning)
            return; // 正在跑的那一輪結束後會再看一次 pending
        s.scanning = (async () => {
            while (s.scanPending.size > 0) {
                const batch = [...s.scanPending];
                s.scanPending.clear();
                await this.scanBatch(s.root, batch);
            }
        })();
        try {
            await s.scanning;
        }
        finally {
            s.scanning = undefined;
        }
    }
    async scanBatch(root, rels) {
        if (this.tooOld(root) || this.pwshFailure())
            return;
        const pw = this.pwsh();
        const gate = async (rel, extra, parse, collection) => {
            const script = path.join(root, rel);
            if (!fs.existsSync(script))
                return;
            const run = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.encodedCommandArgs)((0, pwsh_1.gateInvocation)(script, rels, extra)), { cwd: root, timeoutMs: 60_000 });
            let outcome;
            try {
                outcome = parse(run.stdout);
            }
            catch (e) {
                this.log(`✖ ${path.basename(rel)} 的輸出讀不懂：${e.message}${run.stderr ? ` / ${run.stderr.trim()}` : ''}`);
                return;
            }
            if (outcome.note)
                this.log(`⚠ ${outcome.note}`);
            for (const [file, records] of (0, diagnostics_1.groupByFile)(outcome, rels)) {
                collection.set(vscode.Uri.file(path.join(root, file)), records.map(toDiagnostic));
            }
        };
        await Promise.all([
            gate(GUIDELINE_GATE_REL, ['-MaxReport', '500'], (o) => (0, diagnostics_1.guidelineOutcome)((0, contract_1.parseGuidelineGate)(o)), this.guidelineDiag),
            gate(DLP_GATE_REL, [], (o) => (0, diagnostics_1.dlpOutcome)((0, contract_1.parseDlpGate)(o)), this.dlpDiag),
        ]);
    }
    // ---- 指令 ----
    async menu() {
        const s = this.pick();
        const items = [
            { label: '$(refresh) 重新整理狀態', id: 'codexSdlc.refresh' },
            { label: '$(checklist) doctor', description: '完整健檢，結果寫進輸出面板', id: 'codexSdlc.doctor' },
            { label: '$(sync) apply', description: '把 sdlc.config.json 套到 agent 定義', id: 'codexSdlc.apply' },
            { label: '$(settings-gear) 調整 agent 的 effort／model', description: '改 sdlc.config.json，然後自動 apply', id: 'codexSdlc.editTuning' },
            { label: '$(lightbulb) tune', description: '依 repo 現況給調校提議，你決定要不要套用', id: 'codexSdlc.tune' },
            { label: '$(book) whatsnew', description: '這一版／新版的變更說明', id: 'codexSdlc.whatsnew' },
            { label: '$(cloud-download) 立即檢查更新', id: 'codexSdlc.checkUpdate' },
            { label: '$(output) 顯示輸出', id: 'codexSdlc.showOutput' },
        ];
        const issues = s?.view?.issues ?? [];
        const pick = await vscode.window.showQuickPick([...issues.map((i) => ({ label: `${i.level === 'error' ? '$(error)' : '$(warning)'} ${i.badge.replace(/^\$\([^)]+\)\s*/, '')}`, detail: i.detail })), ...items], { title: s ? `Codex SDLC —— ${path.basename(s.root)}` : 'Codex SDLC', matchOnDetail: true });
        if (pick && 'id' in pick && pick.id)
            await vscode.commands.executeCommand(pick.id);
        else if (pick)
            this.output.show();
    }
    report(call, title) {
        if (!call.ok) {
            void vscode.window.showErrorMessage(`${title}：${call.view.tooltip[0]}`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
            return undefined;
        }
        this.log(`── ${title}（exit ${call.env.exit}）`);
        for (const l of call.env.output)
            this.output.appendLine(l);
        for (const w of call.env.warnings)
            this.output.appendLine(`⚠ ${w}`);
        return call.env;
    }
    async doctorCommand(root) {
        const env = this.report(await this.runSdlc(root, 'doctor', this.codexParam()), 'doctor');
        if (!env)
            return;
        const d = (0, contract_1.parseDoctor)(env);
        const s = this.pick(root);
        if (s) {
            s.doctor = d;
            s.view = (0, status_1.statusFromDoctor)(d, new Date());
            this.render();
        }
        if (d.problems === 0)
            void vscode.window.showInformationMessage('doctor：沒有問題。');
        else
            void vscode.window.showWarningMessage(`doctor：${d.problems} 個問題。`, '看詳細').then((c) => { if (c)
                this.output.show(); });
    }
    async applyCommand(root) {
        const env = this.report(await this.runSdlc(root, 'apply'), 'apply');
        if (!env)
            return;
        if (env.exit !== 0) {
            void vscode.window.showErrorMessage(`apply 失敗：${env.warnings[0] ?? '見輸出面板'}`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
            return;
        }
        const d = (0, contract_1.parseApply)(env);
        void vscode.window.showInformationMessage(d.changed.length > 0 ? `apply：更新了 ${d.changed.join('、')}` : 'apply：沒有變更，agent 定義已經跟設定檔一致。');
        await this.refresh(root);
    }
    async editTuningCommand(root) {
        const configUri = vscode.Uri.file(path.join(root, CONFIG_REL));
        if (!fs.existsSync(configUri.fsPath)) {
            void vscode.window.showWarningMessage('這個專案沒有 sdlc.config.json —— 先用 sdlc.ps1 install 建一份（或 install -Adopt 接管既有安裝）。');
            return;
        }
        const doc = await vscode.workspace.openTextDocument(configUri);
        let agents;
        try {
            agents = (0, tuning_1.readAgents)(doc.getText());
        }
        catch (e) {
            void vscode.window.showErrorMessage(e.message);
            return;
        }
        const currentRounds = (0, tuning_1.readReviewMaxRounds)(doc.getText());
        const picked = await vscode.window.showQuickPick([
            {
                label: '$(debug-restart) 審核修正輪上限',
                description: `review.maxRounds=${currentRounds === undefined ? '（沒設，預設 3）' : JSON.stringify(currentRounds)}`,
                detail: '⑤ 審核 FAIL 之後最多回頭修幾輪（1–5，預設 3）。handoff-lint 每次現讀，不需要 apply。',
                review: true,
            },
            { label: 'agent', kind: vscode.QuickPickItemKind.Separator },
            ...agents.map((a) => ({
                label: a.name,
                description: `effort=${a.effort} · model=${a.model}`,
                detail: a.name === 'orchestrator' ? '它沒有 agent 定義檔（就是 AGENTS.md），這裡只是記錄 —— 要生效得在啟動 codex 時自己下' : undefined,
            })),
        ], { title: '要調什麼？', placeHolder: '值寫進 sdlc.config.json' });
        if (!picked)
            return;
        if (picked.review) {
            const rounds = await vscode.window.showQuickPick(tuning_1.REVIEW_ROUNDS.map((n) => ({
                label: String(n),
                description: n === 3 ? '預設' : undefined,
                picked: n === currentRounds,
            })), { title: '審核最多修幾輪？', placeHolder: '到了上限還 FAIL，會停下來交回你決定（可以選「指定重點再跑一輪」）' });
            if (!rounds)
                return;
            const before = doc.getText();
            const after = (0, tuning_1.setReviewMaxRounds)(before, Number(rounds.label));
            if (after !== before) {
                const edit = new vscode.WorkspaceEdit();
                edit.replace(configUri, new vscode.Range(doc.positionAt(0), doc.positionAt(before.length)), after);
                await vscode.workspace.applyEdit(edit);
                await doc.save();
            }
            await this.refresh(root);
            const d = this.pick(root)?.doctor;
            if (d && d.review.valid && d.review.maxRounds === Number(rounds.label)) {
                void vscode.window.showInformationMessage(`審核修正輪上限改成 ${rounds.label} 輪 —— 下一次委派修正輪時 handoff-lint 就照這個算。`);
            }
            else {
                void vscode.window.showWarningMessage(`寫進去了，但 doctor 說實際上限是 ${d?.review.maxRounds ?? '未知'} 輪。`, '顯示輸出').then((c) => { if (c)
                    this.output.show(); });
            }
            return;
        }
        const agent = picked;
        const key = await vscode.window.showQuickPick([{ label: 'effort', description: '推理深度' }, { label: 'model', description: '模型 —— 這個 key 尚未在本工作流驗證過' }], { title: `${agent.label}：改哪一項？` });
        if (!key)
            return;
        let value;
        if (key.label === 'effort') {
            const hints = {
                inherit: '預設 —— 不釘，交給 Codex CLI 決定。大型 repo 維持這個',
                minimal: '最淺',
                low: 'repo 很大時 sa-analyst 的建議值（它的失敗模式是逾時，不是想得不夠深）',
                medium: '',
                high: agent.label === 'sa-analyst' ? '⚠ sa-analyst 釘 high 正是大型 legacy repo 分析逾時的成因' : 'reviewer 唯一值得的位置（輸入小、判斷密度高）',
            };
            const picked = await vscode.window.showQuickPick(tuning_1.EFFORTS.map((e) => ({ label: e, description: hints[e] || undefined, picked: e === agent.description?.match(/effort=(\S+)/)?.[1] })), { title: `${agent.label} 的 effort` });
            value = picked?.label;
        }
        else {
            value = await vscode.window.showInputBox({
                title: `${agent.label} 的 model`,
                value: agent.description?.match(/model=(\S+)/)?.[1] ?? 'inherit',
                prompt: 'inherit = 不寫這一行。這個 key 尚未在本工作流驗證過 —— Codex 若忽略它，會靜默地用預設模型跑。',
            });
        }
        if (value === undefined || value.trim() === '')
            return;
        const before = doc.getText();
        const after = (0, tuning_1.setAgentValue)(before, agent.label, key.label, value.trim());
        if (after !== before) {
            const edit = new vscode.WorkspaceEdit();
            edit.replace(configUri, new vscode.Range(doc.positionAt(0), doc.positionAt(before.length)), after);
            await vscode.workspace.applyEdit(edit);
            await doc.save();
        }
        const applied = this.report(await this.runSdlc(root, 'apply'), 'apply');
        if (!applied)
            return;
        await this.refresh(root);
        const d = this.pick(root)?.doctor;
        if (agent.label === 'orchestrator') {
            void vscode.window.showInformationMessage(`已記錄 orchestrator 的 ${key.label}=${value}。它強制不了 —— 啟動 codex 時要自己帶。`);
        }
        else if (d?.tuning.status === 'in-sync') {
            void vscode.window.showInformationMessage(`已套用：${agent.label} 的 ${key.label}=${value}（agent 定義與設定檔一致）。`);
        }
        else {
            void vscode.window.showWarningMessage(`設定寫進去了，但 doctor 說調校區塊仍不一致（${d?.tuning.status ?? '未知'}）。`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
        }
    }
    async tuneCommand(root) {
        const env = this.report(await this.runSdlc(root, 'tune'), 'tune');
        if (!env)
            return;
        const t = (0, contract_1.parseTune)(env);
        if (t.proposal.length === 0) {
            void vscode.window.showWarningMessage('tune 沒有產出提議 —— 見輸出面板。');
            return;
        }
        const applyItem = { label: '$(check) 套用這份提議', description: '寫回 sdlc.config.json，接著 apply', apply: true };
        const choice = await vscode.window.showQuickPick([
            applyItem,
            { label: '提議', kind: vscode.QuickPickItemKind.Separator },
            ...t.proposal.map((p) => ({
                label: `${p.current === p.proposed ? '$(circle-small)' : '$(arrow-right)'} ${p.agent}：${p.current} → ${p.proposed}`,
                detail: `理由：${p.reason}　訊號：${p.signal}`,
            })),
        ], { title: 'tune 的提議（這是提議不是動作 —— 套用要你按）', matchOnDetail: true });
        if (!choice || !('apply' in choice))
            return;
        const applied = this.report(await this.runSdlc(root, 'tune', ['-ApplyProposal']), 'tune -ApplyProposal');
        if (!applied)
            return;
        void vscode.window.showInformationMessage('已套用 tune 的提議。');
        await this.refresh(root);
    }
    async whatsNewCommand(root) {
        const env = this.report(await this.runSdlc(root, 'whatsnew'), 'whatsnew');
        if (!env)
            return;
        const w = (0, contract_1.parseWhatsNew)(env);
        this.output.show(true);
        if (w.source === 'cache' && w.latest)
            void vscode.window.showInformationMessage(`新版 ${w.latest} 的說明在輸出面板。升級：把新版發佈物解壓到別處，跑 sdlc.ps1 update -Target <專案>。`);
        await this.refresh(root);
    }
    async checkUpdateCommand(root) {
        const env = this.report(await this.runSdlc(root, 'check-update'), 'check-update');
        if (!env)
            return;
        const d = (0, contract_1.parseCheckUpdate)(env);
        const text = {
            newer: `有新版 ${d.latest}（你在 ${d.installed}）。`,
            'up-to-date': `已是最新（${d.installed}）。`,
            disabled: '設定為不檢查更新（sdlc.config.json 的 update.check = never）。',
            unreachable: '檢查不到更新（離線或來源不可達）。不影響任何流程。',
            'unsupported-source': 'update.source 不是可辨識的 GitHub repo，無法自動檢查。',
        };
        void vscode.window.showInformationMessage(text[d.status] ?? `check-update：${d.status}`);
        await this.refresh(root);
    }
}
function toDiagnostic(r) {
    const line = Math.max(0, r.line - 1);
    const d = new vscode.Diagnostic(new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER), r.message, r.severity === 'error' ? vscode.DiagnosticSeverity.Error : vscode.DiagnosticSeverity.Warning);
    d.source = r.source;
    d.code = r.code;
    return d;
}
function findFile(dir, name, depth) {
    if (depth < 0)
        return undefined;
    let entries;
    try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
    }
    catch {
        return undefined;
    }
    for (const e of entries)
        if (e.isFile() && e.name.toLowerCase() === name.toLowerCase())
            return path.join(dir, e.name);
    for (const e of entries) {
        if (!e.isDirectory() || e.name === 'node_modules')
            continue;
        const hit = findFile(path.join(dir, e.name), name, depth - 1);
        if (hit)
            return hit;
    }
    return undefined;
}
let cockpit;
function activate(context) {
    cockpit = new Cockpit(context);
    context.subscriptions.push(cockpit);
    cockpit.start();
    return cockpit.api;
}
function deactivate() {
    cockpit?.dispose();
    cockpit = undefined;
}
