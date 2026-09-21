"use strict";
// Codex SDLC 的駕駛艙。**它是 sdlc.ps1 與各 gate 的殼，不是第二份實作。**
//
// 刻意不做的三件事（也寫在 README）：
//   1. 不推測「現在在流程的第幾步」—— 流程狀態活在對話裡，靠檔案反推會猜錯。
//   2. 不自己實作任何 lint／gate／sha 邏輯 —— 狀態一律來自 sdlc.ps1 -Json 的 data，違規一律來自 gate 的 -Json。
//      改設定也一樣：寫檔只經過 `sdlc.ps1 set`（它先依 schema 驗完才寫），選項與說明只讀專案裡的 schema。
//   3. 不把工作流設定存進 VS Code settings —— 那裡每機器一份、不進版控、團隊看不到。
//      唯一真相是 sdlc.config.json；這裡的 settings 只有「pwsh 在哪」這類機器上的事。
//
// 4.10.0 起它也是**安裝入口**（面板永遠在，沒裝工作流時顯示安裝按鈕）。這不違反第 2 條：
// 找發佈物 = `sdlc.ps1 fetch`（連網、下載、解壓、驗 sha 全在腳本那一側，這裡一個 socket 都不開），
// 裝 = 發佈物自己的 `sdlc.ps1 install`，補工具檔 = 它的 `update`。vsix 內附的那一份 payload 是
// pack.ps1 同一次建置複製進去的，所以「兩份 payload 分岔」在構造上不會發生。
//
// 這支檔是唯一 import vscode 的地方。能在純 Node 底下測的邏輯都在
// pwsh／contract／status／diagnostics／config／schema／tree／codelens。
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
const codelens_1 = require("./codelens");
const config_1 = require("./config");
const contract_1 = require("./contract");
const diagnostics_1 = require("./diagnostics");
const pwsh_1 = require("./pwsh");
const schema_1 = require("./schema");
const status_1 = require("./status");
const tree_1 = require("./tree");
const VERSION_REL = '.codex/bdd-workflow/bdd-workflow-version.json';
const PROFILES_REL = '.codex/bdd-workflow/tuning-profiles.json';
const SDLC_REL = '.codex/scripts/sdlc.ps1';
const GUIDELINE_GATE_REL = '.codex/scripts/guideline-gate.ps1';
const DLP_GATE_REL = '.codex/scripts/dlp-gate.ps1';
const CONFIG_REL = 'sdlc.config.json';
const AGENTS_REL = 'AGENTS.md';
const PROPOSAL_REL = 'bdd-docs/.sdlc/tuning-proposal.json';
const GATE_MARKER_REL = 'guidelines/.gate-disabled';
const SETTINGS_VIEW = 'codexSdlc.settings';
const WALKTHROUGH = 'codexSdlc.start';
// vsix 內附的那一份發佈物（pack.ps1 打包時放進來的）。沒有它也能跑，安裝那條路會退回「選擇發佈物…」。
const PAYLOAD_DIR = 'payload';
// 這裡**沒有**任何跟 Codex 信任狀態有關的參數，而且刻意不加：4.10.0 起 doctor 預設就不問
// （問它要另外叫起一個 codex 子行程，而答案在這個介面裡按不動）。要查的人在終端機加 -CheckHookTrust。
// hooks.json 在不在照樣會查 —— 那是工具檔缺了，有得修。
const UPDATE_INTERVAL_MS = 60 * 60 * 1000; // 只是「問 sdlc.ps1 到期了沒」—— 真的連網與否由 update.check 決定
const samePath = (a, b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
const toneColor = {
    ok: 'testing.iconPassed',
    warn: 'list.warningForeground',
    error: 'list.errorForeground',
    pending: 'charts.orange',
    muted: 'disabledForeground',
};
function toTreeItem(n) {
    const state = n.children && n.children.length > 0
        ? (n.expanded ? vscode.TreeItemCollapsibleState.Expanded : vscode.TreeItemCollapsibleState.Collapsed)
        : vscode.TreeItemCollapsibleState.None;
    const item = new vscode.TreeItem(n.label, state);
    item.id = n.id;
    item.description = n.description;
    item.tooltip = n.tooltip;
    item.contextValue = n.contextValue;
    if (n.icon)
        item.iconPath = new vscode.ThemeIcon(n.icon, n.tone ? new vscode.ThemeColor(toneColor[n.tone]) : undefined);
    if (n.command)
        item.command = n.command;
    return item;
}
function isEditTarget(x) {
    return typeof x === 'object' && x !== null && 'kind' in x && 'key' in x;
}
class Cockpit {
    context;
    output = vscode.window.createOutputChannel('Codex SDLC');
    item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
    guidelineDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-guideline');
    dlpDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-dlp');
    rulesDiag = vscode.languages.createDiagnosticCollection('codex-sdlc-rules');
    treeChanged = new vscode.EventEmitter();
    lensChanged = new vscode.EventEmitter();
    states = new Map();
    disposables = [];
    callCount = {};
    pwshCache;
    pwshWarned = false;
    updateTimer;
    lastPicked;
    settingsView;
    constructor(context) {
        this.context = context;
        this.item.command = 'codexSdlc.menu';
        this.disposables.push(this.output, this.item, this.guidelineDiag, this.dlpDiag, this.rulesDiag, this.treeChanged, this.lensChanged);
    }
    // ---- 生命週期 ----
    start() {
        const reg = (id, fn) => this.disposables.push(vscode.commands.registerCommand(id, fn));
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
        reg('codexSdlc.editSetting', (arg) => this.withRoot((r) => this.editSettingCommand(r, arg)));
        reg('codexSdlc.applyPreset', () => this.withRoot((r) => this.applyPresetCommand(r)));
        reg('codexSdlc.applyProposalFor', (root, agent) => this.applyProposal(root, [agent]));
        reg('codexSdlc.toggleGate', () => this.withRoot((r) => this.toggleGateCommand(r)));
        reg('codexSdlc.pickPwsh', () => this.pickPwsh());
        // 安裝與修復：這三條在**還沒裝工作流**的工作區也要能叫得動。
        reg('codexSdlc.install', () => this.installCommand());
        reg('codexSdlc.installFrom', () => this.installCommand({ pickSource: true }));
        reg('codexSdlc.repair', () => this.withRoot((r) => this.repairCommand(r)));
        reg('codexSdlc.mergeAgents', (root) => this.mergeAgentsCommand(root));
        reg('codexSdlc.openFile', (file) => vscode.window.showTextDocument(vscode.Uri.file(file)));
        reg('codexSdlc.openWalkthrough', () => vscode.commands.executeCommand('workbench.action.openWalkthrough', `${this.context.extension.id}#${WALKTHROUGH}`, false));
        const tree = {
            onDidChangeTreeData: this.treeChanged.event,
            getTreeItem: (n) => toTreeItem(n),
            getChildren: (n) => (n ? n.children ?? [] : this.settingsTree()),
        };
        this.disposables.push((this.settingsView = vscode.window.createTreeView(SETTINGS_VIEW, { treeDataProvider: tree, showCollapseAll: true })), vscode.languages.registerCodeLensProvider({ pattern: `**/${CONFIG_REL}` }, {
            onDidChangeCodeLenses: this.lensChanged.event,
            provideCodeLenses: (doc) => this.codeLenses(doc),
        }));
        this.disposables.push(vscode.workspace.onDidSaveTextDocument((d) => this.queueScan(d.uri)), vscode.workspace.onDidOpenTextDocument((d) => this.queueScan(d.uri)), vscode.window.onDidChangeActiveTextEditor(() => this.render()), vscode.workspace.onDidChangeWorkspaceFolders(() => this.syncRoots()), vscode.workspace.onDidChangeConfiguration((e) => {
            if (e.affectsConfiguration('codexSdlc.pwshPath')) {
                this.pwshCache = undefined;
                this.pwshWarned = false;
            }
            if (e.affectsConfiguration('codexSdlc')) {
                this.render();
                this.refreshViews();
                for (const s of this.states.values())
                    this.schedule(s, 0);
            }
        }));
        // 工作流的檔一變就重新健檢：改了設定、apply 寫了 toml、升級換了版本檔、check-update 寫了快取、hooks.json 被改、規範檔或開關變了。
        const watcher = vscode.workspace.createFileSystemWatcher('**/{sdlc.config.json,.codex/agents/*.toml,.codex/hooks.json,.codex/bdd-workflow/bdd-workflow-version.json,bdd-docs/.sdlc/update-cache.json,guidelines/*,guidelines/.gate-disabled,AGENTS.md.new}');
        const onFile = (uri) => {
            const p = uri.fsPath.replace(/\\/g, '/');
            if (p.endsWith(VERSION_REL))
                this.syncRoots();
            const s = this.stateFor(uri);
            if (!s)
                return;
            // rules.json 在編輯器外被改（git checkout、腳本）→ 也要重驗，不然 Problems 會停在舊的那一份。
            if (p.endsWith(`/${diagnostics_1.RULES_REL}`) && fs.existsSync(uri.fsPath))
                void this.validateRules(s.root, uri);
            if (p.endsWith(`/${diagnostics_1.RULES_REL}`) && !fs.existsSync(uri.fsPath))
                this.rulesDiag.delete(uri);
            this.refreshViews();
            this.schedule(s, 800);
        };
        // tune 的提議與 schema 只影響面板與 CodeLens，不必重跑 doctor。
        const viewWatcher = vscode.workspace.createFileSystemWatcher('**/{bdd-docs/.sdlc/tuning-proposal.json,.codex/bdd-workflow/*.schema.json}');
        const onViewFile = () => this.refreshViews();
        this.disposables.push(watcher, watcher.onDidChange(onFile), watcher.onDidCreate(onFile), watcher.onDidDelete(onFile), viewWatcher, viewWatcher.onDidChange(onViewFile), viewWatcher.onDidCreate(onViewFile), viewWatcher.onDidDelete(onViewFile));
        this.syncRoots();
        for (const doc of vscode.workspace.textDocuments)
            this.queueScan(doc.uri);
        // 背景刷新更新快取。這是這個 extension 唯一買得到、腳本層買不到的東西：沒有任何使用者動作也會發生。
        // 要不要真的連網由 sdlc.ps1 看 update.check 決定（never = 一條連線都沒有），這裡只負責定時問。
        const tick = () => { for (const s of this.states.values())
            void this.backgroundUpdateCheck(s.root); };
        setTimeout(tick, 5_000);
        this.updateTimer = setInterval(tick, UPDATE_INTERVAL_MS);
        // 第一次在這台機器上啟動：打開四步引導。「裝好了卻不知道介面在哪」是這個 extension 被回報過的第一個問題。
        const shownKey = 'codexSdlc.walkthroughShown';
        if (this.states.size > 0 && !this.context.globalState.get(shownKey)) {
            void this.context.globalState.update(shownKey, true);
            void vscode.commands.executeCommand('codexSdlc.openWalkthrough');
        }
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
            const s = { root, again: false, scanPending: new Set(), pendingAgents: new Set(), lastWrite: 0 };
            this.states.set(root, s);
            this.schedule(s, 0);
        }
        // 設定面板只在裝了工作流的工作區出現 —— 沒有的話活動列不該多一個空圖示。
        void vscode.commands.executeCommand('setContext', 'codexSdlc.active', this.states.size > 0);
        this.render();
        this.refreshViews();
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
            // 以前這裡只說「沒裝」就結束 —— 而使用者在這一刻要的就是「那就裝啊」。
            void vscode.window.showInformationMessage('這個工作區沒有安裝 Codex SDLC 工作流（找不到 .codex/bdd-workflow/bdd-workflow-version.json）。', '安裝到這個工作區', '選擇發佈物…').then((c) => {
                if (c === '安裝到這個工作區')
                    void vscode.commands.executeCommand('codexSdlc.install');
                if (c === '選擇發佈物…')
                    void vscode.commands.executeCommand('codexSdlc.installFrom');
            });
            return;
        }
        await fn(s.root);
    }
    // 有開、但還沒裝工作流的資料夾 —— 安裝的候選。
    installableFolders() {
        return (vscode.workspace.workspaceFolders ?? [])
            .map((f) => f.uri.fsPath)
            .filter((p) => !fs.existsSync(path.join(p, VERSION_REL)));
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
            void vscode.window.showErrorMessage(r.message, '安裝 PowerShell 7', '選擇 pwsh…').then((choice) => {
                if (choice === '安裝 PowerShell 7')
                    void vscode.env.openExternal(vscode.Uri.parse(pwsh_1.INSTALL_URL));
                if (choice === '選擇 pwsh…')
                    void vscode.commands.executeCommand('codexSdlc.pickPwsh');
            });
        }
        this.log(`✖ ${r.message}`);
        return (0, status_1.statusFromFailure)('pwsh-missing', r.message);
    }
    log(line) {
        this.output.appendLine(`[${new Date().toLocaleTimeString()}] ${line}`);
    }
    workflowVersion(root) {
        try {
            return String(JSON.parse(fs.readFileSync(path.join(root, VERSION_REL), 'utf8'))['contract-version'] ?? '') || undefined;
        }
        catch {
            return undefined;
        }
    }
    // 只讀版本檔（現成的檔），不跑任何腳本。
    tooOld(root) {
        const version = this.workflowVersion(root);
        if (!version || (0, contract_1.compareVersions)(version, contract_1.MIN_WORKFLOW_VERSION) >= 0)
            return undefined;
        return (0, status_1.statusFromFailure)('workflow-too-old', `這個專案的工作流是 ${version}，這個 extension 需要 ${contract_1.MIN_WORKFLOW_VERSION} 以上（結構化的 -Json 從那一版開始）。升級工作流：把新版發佈物解壓到別處，跑 sdlc.ps1 update -Target <專案>。`);
    }
    async runSdlc(root, command, params = [], timeoutMs = 180_000) {
        const old = this.tooOld(root);
        if (old)
            return { ok: false, view: old };
        return this.runSdlcScript(root, root, command, ['-Target', root, '-Json', ...params], timeoutMs);
    }
    // 用**發佈物自己的** sdlc.ps1 對一個目標資料夾動手（install／update／fetch）。
    // 目標可能根本還沒有 .codex/ —— 所以腳本不能從目標身上拿，版本檢查也不適用。
    async runSdlcFrom(payload, target, command, params = [], timeoutMs = 300_000) {
        return this.runSdlcScript(payload, target, command, ['-Source', payload, '-Target', target, '-Json', ...params], timeoutMs);
    }
    async runSdlcScript(scriptRoot, cwd, command, args, timeoutMs) {
        const failure = this.pwshFailure();
        if (failure)
            return { ok: false, view: failure };
        const pw = this.pwsh();
        const script = path.join(scriptRoot, SDLC_REL);
        this.callCount[command] = (this.callCount[command] ?? 0) + 1;
        const run = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.fileArgs)(script, [command, ...args]), { cwd, timeoutMs });
        if (run.spawnError || run.timedOut) {
            const msg = run.timedOut ? `sdlc.ps1 ${command} 超過 ${Math.round(timeoutMs / 1000)} 秒沒有結束` : `啟動 pwsh 失敗：${run.spawnError}`;
            this.log(`✖ ${msg}`);
            return { ok: false, view: (0, status_1.statusFromFailure)('script-failed', msg), run };
        }
        try {
            return { ok: true, env: (0, contract_1.parseEnvelope)(run.stdout, command), run };
        }
        catch (e) {
            const view = this.contractFailure(scriptRoot, e, run);
            return { ok: false, view, run };
        }
    }
    contractFailure(root, e, run) {
        const message = e instanceof Error ? e.message : String(e);
        this.log(`✖ ${message}`);
        if (run.stderr.trim())
            this.log(run.stderr.trim());
        if (e instanceof contract_1.ContractError && /schema/.test(message)) {
            const version = this.workflowVersion(root) ?? '未知';
            if (/太舊/.test(message)) {
                return (0, status_1.statusFromFailure)('workflow-too-old', `這個專案的工作流是 ${version}，沒有結構化的 -Json —— 這個 extension 需要 ${contract_1.MIN_WORKFLOW_VERSION} 以上的工作流。升級工作流，或裝跟它同版的 extension。`);
            }
            return (0, status_1.statusFromFailure)('schema-mismatch', `${message}（專案的工作流是 ${version}）—— 裝跟工作流同一版發佈物附的 vsix。`);
        }
        return (0, status_1.statusFromFailure)('script-failed', `sdlc.ps1 的輸出讀不懂：${message}`);
    }
    // ---- 發佈物（安裝的來源）----
    // vsix 內附的那一份。pack.ps1 打包時才放進去，所以開發模式（F5）下不存在 —— 不存在是合法狀態。
    bundledPayload() {
        const dir = path.join(this.context.extensionPath, PAYLOAD_DIR);
        return fs.existsSync(path.join(dir, VERSION_REL)) ? dir : undefined;
    }
    payloadVersion() {
        const dir = this.bundledPayload();
        return dir ? this.workflowVersion(dir) : undefined;
    }
    // 「這次要拿哪一份發佈物來裝」由 sdlc.ps1 fetch 決定：先問 update source，沒有才用內附的。
    // 連網、下載、解壓、驗 sha 全部在腳本那一側 —— extension 自己一個 socket 都不開。
    async resolvePayload(target, opts = {}) {
        const bundled = this.bundledPayload();
        // fetch 本身也要有一支 sdlc.ps1 才跑得起來：內附的優先，其次是這個工作區裡已經裝好的那一份。
        const runner = bundled ?? (fs.existsSync(path.join(target, SDLC_REL)) ? target : undefined);
        if (!runner)
            return undefined;
        const source = (vscode.workspace.getConfiguration('codexSdlc').get('releaseSource') ?? '').trim();
        const params = ['-Bundled', bundled ?? '', '-CacheDir', this.context.globalStorageUri.fsPath, ...(source ? ['-SourceUrl', source] : [])];
        const call = await this.runSdlcScript(runner, target, 'fetch', ['-Target', target, '-Json', ...params], 180_000);
        const env = opts.quiet ? (call.ok ? call.env : undefined) : this.report(call, 'fetch —— 找一份發佈物');
        if (!env)
            return undefined;
        try {
            return (0, contract_1.parseFetch)(env);
        }
        catch (e) {
            this.log(`✖ fetch 的輸出讀不懂：${e.message}`);
            return undefined;
        }
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
                const started = Date.now();
                this.refreshViews();
                const call = await this.runSdlc(s.root, 'doctor');
                if (call.ok) {
                    try {
                        s.doctor = (0, contract_1.parseDoctor)(call.env);
                        s.view = (0, status_1.statusFromDoctor)(s.doctor, new Date());
                        // 這次 doctor 是在最後一次寫檔之後才開始的 → 它的 tuning.stale 已經算進那次寫檔，本地的標記可以放掉。
                        if (started >= s.lastWrite)
                            s.pendingAgents.clear();
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
            this.refreshViews();
        }
    }
    render() {
        const enabled = vscode.workspace.getConfiguration('codexSdlc').get('statusBar.enabled') ?? true;
        const s = this.pick();
        // 換到另一個專案的檔 → 面板要跟著換。
        if (s?.root !== this.lastPicked) {
            this.lastPicked = s?.root;
            this.refreshViews();
        }
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
    refreshViews() {
        this.treeChanged.fire();
        this.lensChanged.fire();
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
    // ---- 設定面板 ----
    canEdit(root) {
        const version = this.workflowVersion(root);
        if (!version || (0, contract_1.compareVersions)(version, contract_1.MIN_SETTINGS_VERSION) < 0) {
            return { ok: false, reason: `這個專案的工作流是 ${version ?? '未知版本'} —— 升到 ${contract_1.MIN_SETTINGS_VERSION} 以上才能在這裡改（之前請手改 sdlc.config.json 再 apply）` };
        }
        let schema;
        try {
            schema = (0, schema_1.readSettingsSchema)(root);
        }
        catch (e) {
            return { ok: false, reason: `${e.message} —— 重跑 sdlc.ps1 update 補回工具檔` };
        }
        if (!schema)
            return { ok: false, reason: `找不到 ${schema_1.CONFIG_SCHEMA_REL} —— 重跑 sdlc.ps1 update 補回工具檔` };
        if (!this.pwsh().ok)
            return { ok: false, reason: '找不到 PowerShell 7 —— 見「這台機器」', schema };
        return { ok: true, schema };
    }
    readProposal(root) {
        try {
            const raw = JSON.parse(fs.readFileSync(path.join(root, PROPOSAL_REL), 'utf8'));
            if (!Array.isArray(raw?.proposal))
                return undefined;
            return raw.proposal
                .filter((p) => typeof p?.agent === 'string' && typeof p?.effort === 'string')
                .map((p) => ({ agent: p.agent, effort: p.effort, reason: typeof p.reason === 'string' ? p.reason : '' }));
        }
        catch {
            return undefined;
        }
    }
    treeInput(s) {
        const edit = this.canEdit(s.root);
        let config;
        let configError;
        const cfgPath = path.join(s.root, CONFIG_REL);
        if (fs.existsSync(cfgPath)) {
            try {
                config = (0, config_1.readConfig)(fs.readFileSync(cfgPath, 'utf8'));
            }
            catch (e) {
                configError = e instanceof config_1.ConfigReadError ? e.message : String(e);
            }
        }
        // 還沒有設定檔時，agent 名冊來自工作流自己的 agent 定義（orchestrator 排最後 —— 它只是記錄）。
        let knownAgents = [];
        try {
            knownAgents = [
                ...fs.readdirSync(path.join(s.root, '.codex/agents')).filter((f) => f.endsWith('.toml')).map((f) => f.replace(/\.toml$/, '')).sort(),
                'orchestrator',
            ];
        }
        catch { /* 沒有 agent 目錄就不列 */ }
        const gdir = path.join(s.root, 'guidelines');
        const gExists = fs.existsSync(gdir);
        let files = [];
        try {
            files = gExists ? fs.readdirSync(gdir, { withFileTypes: true }).filter((e) => e.isFile()).map((e) => e.name).sort() : [];
        }
        catch { /* 讀不到就當沒有 */ }
        const rulesPath = path.join(s.root, diagnostics_1.RULES_REL);
        let ruleCount;
        try {
            ruleCount = (0, config_1.countRules)(fs.readFileSync(rulesPath, 'utf8'));
        }
        catch { /* 沒有或讀不到 */ }
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
            agentsNewExists: fs.existsSync(path.join(s.root, `${AGENTS_REL}.new`)),
            machine: {
                pwsh: pw.ok ? { ok: true, path: pw.path } : { ok: false, message: pw.message },
                extensionVersion: String(this.context.extension.packageJSON.version ?? ''),
                payloadVersion: this.payloadVersion(),
            },
        };
    }
    settingsTree(root) {
        const s = this.pick(root);
        return s ? (0, tree_1.buildSettingsTree)(this.treeInput(s)) : [];
    }
    codeLenses(doc) {
        const s = this.stateFor(doc.uri);
        if (!s || !samePath(path.dirname(doc.uri.fsPath), s.root))
            return [];
        const specs = (0, codelens_1.configLenses)(doc.getText(), {
            rootPath: s.root,
            pendingAgents: (0, tree_1.pendingAgentsOf)({ doctor: s.doctor, pendingAgents: [...s.pendingAgents] }),
            proposal: this.readProposal(s.root),
            canEdit: this.canEdit(s.root).ok,
        });
        return specs.map((l) => new vscode.CodeLens(new vscode.Range(l.line, 0, l.line, 0), { title: l.title, command: l.command, arguments: l.arguments, tooltip: l.tooltip }));
    }
    // 單選清單：現值預先選好、點到別處不會消失。
    pickOne(items, opts) {
        return new Promise((resolve) => {
            const qp = vscode.window.createQuickPick();
            qp.title = opts.title;
            qp.placeholder = opts.placeholder;
            qp.items = items;
            qp.ignoreFocusOut = true;
            qp.matchOnDescription = true;
            if (opts.active)
                qp.activeItems = [opts.active];
            let done = false;
            qp.onDidAccept(() => { done = true; resolve(qp.selectedItems[0]); qp.hide(); });
            qp.onDidHide(() => { if (!done)
                resolve(undefined); qp.dispose(); });
            qp.show();
        });
    }
    async editSettingCommand(root, arg) {
        const target = isEditTarget(arg) ? arg : isEditTarget(arg?.edit) ? arg.edit : undefined;
        if (!target) {
            await vscode.commands.executeCommand('codexSdlc.openSettings');
            return;
        }
        let value;
        if (target.kind === 'choice') {
            const items = target.choices.map((c) => ({
                label: c.label === c.value ? c.value : `${c.label}（${c.value}）`,
                description: [c.value === target.current ? '目前' : '', c.description].filter(Boolean).join(' · '),
                value: c.value,
            }));
            value = (await this.pickOne(items, { title: target.title, placeholder: target.placeholder, active: items.find((x) => x.value === target.current) }))?.value;
        }
        else {
            value = await this.askText(target);
        }
        if (value === undefined || value === target.current)
            return;
        await this.writeSettings(root, [`${target.key}=${value}`], {});
    }
    async askText(t) {
        if (t.suggestions.length > 0) {
            const items = [
                ...t.suggestions.map((c) => ({ label: c.value, description: [c.value === t.current ? '目前' : '', c.description].filter(Boolean).join(' · '), value: c.value })),
                { label: '$(edit) 輸入其他值…', value: undefined },
            ];
            const picked = await this.pickOne(items, { title: t.title, placeholder: t.prompt, active: items.find((x) => x.value === t.current) });
            if (!picked)
                return undefined;
            if (picked.value !== undefined)
                return picked.value;
        }
        return vscode.window.showInputBox({
            title: t.title,
            prompt: t.prompt,
            value: t.current,
            ignoreFocusOut: true,
            validateInput: (v) => {
                if (!v && !t.allowEmpty)
                    return '不能是空的';
                if (!(0, schema_1.matchesPattern)(t.pattern, v))
                    return t.patternError;
                return undefined;
            },
        });
    }
    // 使用者在編輯器裡有沒存的修改時，sdlc.ps1 寫磁碟上的檔會跟它打架 —— 先問、先存。
    async saveConfigIfDirty(root) {
        const doc = vscode.workspace.textDocuments.find((d) => d.uri.scheme === 'file' && samePath(d.uri.fsPath, path.join(root, CONFIG_REL)));
        if (!doc?.isDirty)
            return true;
        const choice = await vscode.window.showWarningMessage('sdlc.config.json 有還沒存的修改。先存檔再改？', { modal: true }, '存檔並繼續');
        if (choice !== '存檔並繼續')
            return false;
        return doc.save();
    }
    async writeSettings(root, assignments, opts) {
        const s = this.pick(root);
        if (!s)
            return undefined;
        const edit = this.canEdit(root);
        if (!edit.ok) {
            void vscode.window.showWarningMessage(edit.reason ?? '這個專案不能在這裡改設定。');
            return undefined;
        }
        if (!opts.preview && !(await this.saveConfigIfDirty(root)))
            return undefined;
        const params = [
            ...(opts.preset ? ['-Preset', opts.preset] : []),
            ...(opts.apply ? ['-Apply'] : []),
            ...(opts.yes ? ['-Yes'] : []),
            ...(opts.preview ? ['-Preview'] : []),
            ...assignments,
        ];
        const env = this.report(await this.runSdlc(root, 'set', params), opts.preview ? 'set（預覽）' : 'set');
        if (!env)
            return undefined;
        let d;
        try {
            d = (0, contract_1.parseSet)(env);
        }
        catch (e) {
            void vscode.window.showErrorMessage(`set 的輸出讀不懂：${e.message}`);
            return undefined;
        }
        if (d.error === 'has-comments' && !opts.yes) {
            const choice = await vscode.window.showWarningMessage('sdlc.config.json 裡有註解。', { modal: true, detail: '這個檔不支援註解，寫入會把它們移除（原檔會先備份到 bdd-docs/.sdlc/）。要留的說明請搬進 _note。' }, '移除註解並寫入', '開啟設定檔');
            if (choice === '移除註解並寫入')
                return this.writeSettings(root, assignments, { ...opts, yes: true });
            if (choice === '開啟設定檔')
                void vscode.window.showTextDocument(vscode.Uri.file(path.join(root, CONFIG_REL)));
            return d;
        }
        if (d.error) {
            const first = d.errors[0];
            const msg = first ? `${first.key}：${first.message}` : (env.warnings[0] ?? `set 沒有寫入（${d.error}）`);
            if (first?.suggestion && !opts.quiet) {
                void vscode.window.showErrorMessage(`${msg}。一個值都沒寫。`, `改用 ${first.suggestion}`).then((c) => {
                    if (c)
                        void this.writeSettings(root, [first.suggestion], opts);
                });
            }
            else if (!opts.quiet || d.error !== 'cancelled') {
                void vscode.window.showErrorMessage(`${msg}。一個值都沒寫。`, '顯示輸出').then((c) => { if (c)
                    this.output.show(); });
            }
            return d;
        }
        if (opts.preview)
            return d;
        const changed = d.changes.filter((c) => c.changed);
        if (d.written) {
            s.lastWrite = Date.now();
            for (const c of changed) {
                const m = /^agents\.([^.]+)\./.exec(c.key);
                if (m && c.needsApply)
                    s.pendingAgents.add(m[1]);
            }
        }
        if (d.applied)
            s.pendingAgents.clear();
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
    async applyPresetCommand(root) {
        const edit = this.canEdit(root);
        if (!edit.ok) {
            void vscode.window.showWarningMessage(edit.reason ?? '這個專案不能在這裡改設定。');
            return;
        }
        let presets = {};
        try {
            presets = JSON.parse(fs.readFileSync(path.join(root, PROFILES_REL), 'utf8')).presets ?? {};
        }
        catch { /* 下面會說 */ }
        const names = Object.keys(presets);
        if (names.length === 0) {
            void vscode.window.showWarningMessage(`讀不到預設組合（${PROFILES_REL}）。`);
            return;
        }
        const items = names.map((n) => ({
            label: n,
            description: Object.entries(presets[n]).map(([a, v]) => `${a} ${v.effort ?? 'inherit'}`).join(' · '),
            name: n,
        }));
        const picked = await this.pickOne(items, { title: '換成哪一組？', placeholder: '下一步會先列出會改哪些值，確認了才寫' });
        if (!picked)
            return;
        const preview = await this.writeSettings(root, [], { preset: picked.name, preview: true, quiet: true });
        if (!preview || preview.error)
            return;
        const changed = preview.changes.filter((c) => c.changed);
        if (changed.length === 0) {
            void vscode.window.showInformationMessage(`現在的設定已經是 ${picked.name} 這一組。`);
            return;
        }
        const detail = changed.map((c) => `${c.key}：${c.from ?? '（沒設）'} → ${c.to}`).join('\n');
        const ok = await vscode.window.showInformationMessage(`換成 ${picked.name}？會改 ${changed.length} 個值並套用。`, { modal: true, detail }, '換成這組並套用');
        if (ok !== '換成這組並套用')
            return;
        const d = await this.writeSettings(root, [], { preset: picked.name, yes: true, apply: true });
        if (d && !d.error)
            void vscode.window.showInformationMessage(`已換成 ${picked.name} 並套用。`);
    }
    async applyProposal(root, agents) {
        const edit = this.canEdit(root);
        if (!edit.ok) {
            void vscode.window.showWarningMessage(edit.reason ?? '這個專案不能在這裡改設定。');
            return;
        }
        if (!(await this.saveConfigIfDirty(root)))
            return;
        const env = this.report(await this.runSdlc(root, 'tune', ['-ApplyProposal', '-Only', agents.join(',')]), 'tune -ApplyProposal');
        if (!env)
            return;
        if (env.exit !== 0) {
            void vscode.window.showErrorMessage(`套用建議失敗：${env.warnings[0] ?? '見輸出面板'}`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
            return;
        }
        const s = this.pick(root);
        if (s) {
            s.lastWrite = Date.now();
            s.pendingAgents.clear();
        }
        void vscode.window.showInformationMessage(`已套用 tune 的建議：${agents.join('、')}。`);
        this.refreshViews();
        await this.refresh(root);
    }
    async toggleGateCommand(root) {
        const marker = path.join(root, GATE_MARKER_REL);
        if (fs.existsSync(marker)) {
            fs.rmSync(marker, { force: true });
            void vscode.window.showInformationMessage('規範的機械層打開了 —— 寫檔後會再用 guidelines/rules.json 掃。');
        }
        else {
            const ok = await vscode.window.showWarningMessage('關掉規範的機械層？', { modal: true, detail: '關掉之後 guidelines/rules.json 一條都不會擋，包括標成 block 的規則。這個開關是 guidelines/.gate-disabled 這個檔 —— 它會活過每一次升級，doctor 會一直提醒到你刪掉它為止。' }, '關閉機械層');
            if (ok !== '關閉機械層')
                return;
            fs.mkdirSync(path.dirname(marker), { recursive: true });
            fs.writeFileSync(marker, `由 VS Code 的 Codex SDLC 設定面板於 ${new Date().toISOString()} 建立。刪掉這個檔 = 打開規範的機械層。\n`);
        }
        const s = this.pick(root);
        this.refreshViews();
        if (s)
            this.schedule(s, 300);
    }
    async pickPwsh() {
        const uris = await vscode.window.showOpenDialog({
            title: '選擇 PowerShell 7（pwsh）',
            canSelectMany: false,
            openLabel: '使用這個檔',
            filters: process.platform === 'win32' ? { 執行檔: ['exe', 'cmd'] } : undefined,
        });
        if (!uris?.[0])
            return;
        // 機器上的路徑，寫進使用者層級的 VS Code 設定 —— 不進專案、不進 sdlc.config.json。
        await vscode.workspace.getConfiguration('codexSdlc').update('pwshPath', uris[0].fsPath, vscode.ConfigurationTarget.Global);
        void vscode.window.showInformationMessage(`已設定 codexSdlc.pwshPath：${uris[0].fsPath}`);
    }
    // ---- Problems：存檔時跑 gate ----
    queueScan(uri, delayMs = 700) {
        if (!(vscode.workspace.getConfiguration('codexSdlc').get('problems.enabled') ?? true))
            return;
        const s = this.stateFor(uri);
        if (!s)
            return;
        const rel = path.relative(s.root, uri.fsPath).replace(/\\/g, '/');
        // rules.json 本身不給 gate 掃（gate 本來就排除 guidelines/），改成驗它自己。
        if (rel === diagnostics_1.RULES_REL) {
            void this.validateRules(s.root, uri);
            return;
        }
        s.scanPending.add(rel);
        if (s.scanTimer)
            clearTimeout(s.scanTimer);
        s.scanTimer = setTimeout(() => { s.scanTimer = undefined; void this.drainScans(s); }, delayMs);
    }
    async validateRules(root, uri) {
        if (this.tooOld(root) || this.pwshFailure())
            return;
        const gate = path.join(root, GUIDELINE_GATE_REL);
        if (!fs.existsSync(gate))
            return;
        const pw = this.pwsh();
        const run = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.fileArgs)(gate, ['-Validate', '-Json', '-RulesFile', uri.fsPath]), { cwd: root, timeoutMs: 60_000 });
        let text = '';
        try {
            text = fs.readFileSync(uri.fsPath, 'utf8');
        }
        catch { /* 讀不到就全部放第一行 */ }
        try {
            const outcome = (0, diagnostics_1.rulesOutcome)((0, contract_1.parseRulesValidation)(run.stdout), text);
            this.rulesDiag.set(uri, outcome.records.map(toDiagnostic));
        }
        catch (e) {
            this.log(`✖ guideline-gate -Validate 的輸出讀不懂：${e.message}${run.stderr ? ` / ${run.stderr.trim()}` : ''}`);
        }
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
        if (!s) {
            const items = [
                { label: '$(cloud-download) 安裝到這個工作區', description: '先看發佈物來源有沒有新版，沒有就用這個 extension 內附的那一份', id: 'codexSdlc.install' },
                { label: '$(folder-opened) 選擇發佈物…', description: '自己指一份已解壓的資料夾或 .zip', id: 'codexSdlc.installFrom' },
                { label: '$(rocket) 這是什麼', id: 'codexSdlc.openWalkthrough' },
                { label: '$(output) 顯示輸出', id: 'codexSdlc.showOutput' },
            ];
            const pick = await vscode.window.showQuickPick(items, { title: 'Codex SDLC —— 這個工作區還沒安裝' });
            if (pick)
                await vscode.commands.executeCommand(pick.id);
            return;
        }
        const items = [
            { label: '$(settings-gear) 開啟設定面板', description: '一眼看到全部設定；改值、套用、換預設組合', id: 'codexSdlc.openSettings' },
            { label: '$(refresh) 重新整理狀態', id: 'codexSdlc.refresh' },
            { label: '$(checklist) doctor', description: '完整健檢，結果寫進輸出面板', id: 'codexSdlc.doctor' },
            { label: '$(sync) apply', description: '把 sdlc.config.json 套到 agent 定義', id: 'codexSdlc.apply' },
            { label: '$(lightbulb) tune', description: '依 repo 現況給調校建議，你勾選要套用哪幾個', id: 'codexSdlc.tune' },
            { label: '$(book) whatsnew', description: '這一版／新版的變更說明', id: 'codexSdlc.whatsnew' },
            { label: '$(cloud-download) 立即檢查更新', id: 'codexSdlc.checkUpdate' },
            { label: '$(tools) 補回工具檔', description: '用發佈物重跑 update —— .codex/ 少了東西時用這個', id: 'codexSdlc.repair' },
            { label: '$(rocket) 開始使用', description: '四步引導：安裝、選預設組合、健檢、設定在哪', id: 'codexSdlc.openWalkthrough' },
            { label: '$(output) 顯示輸出', id: 'codexSdlc.showOutput' },
        ];
        const issues = s?.view?.issues ?? [];
        const pick = await vscode.window.showQuickPick([...issues.map((i) => ({ label: `${i.level === 'error' ? '$(error)' : '$(warning)'} ${i.badge.replace(/^\$\([^)]+\)\s*/, '')}`, detail: i.detail })), ...items], { title: s ? `Codex SDLC —— ${path.basename(s.root)}` : 'Codex SDLC', matchOnDetail: true });
        if (pick && 'id' in pick && pick.id)
            await vscode.commands.executeCommand(pick.id);
        else if (pick)
            this.output.show();
    }
    // ---- 安裝與修復 ----
    //
    // 這一段是「還沒裝工作流的資料夾」唯一的入口。它照樣不自己實作任何東西：
    // 找發佈物 = sdlc.ps1 fetch，裝 = 發佈物自己的 sdlc.ps1 install，補工具檔 = 它的 update。
    async pickInstallTarget() {
        const folders = this.installableFolders();
        if (folders.length === 0) {
            if ((vscode.workspace.workspaceFolders ?? []).length === 0) {
                void vscode.window.showInformationMessage('先開一個資料夾（檔案 → 開啟資料夾），才有地方可以裝。');
                return undefined;
            }
            void vscode.window.showInformationMessage('這個工作區的每個資料夾都已經裝好 Codex SDLC 了。', '補回工具檔', '升級（whatsnew）')
                .then((c) => {
                if (c === '補回工具檔')
                    void vscode.commands.executeCommand('codexSdlc.repair');
                if (c === '升級（whatsnew）')
                    void vscode.commands.executeCommand('codexSdlc.whatsnew');
            });
            return undefined;
        }
        if (folders.length === 1)
            return folders[0];
        const picked = await this.pickOne(folders.map((f) => ({ label: path.basename(f), description: f, value: f })), { title: '裝進哪一個資料夾？' });
        return picked?.value;
    }
    // 一份都找不到時**不要停在這裡**：讓他當場指一份，或去填來源。
    noPayload(f, retryWithPicked) {
        const why = !f
            ? '這個 extension 沒有內附發佈物（開發模式下裝的？），而這個資料夾裡也沒有一份可以用的。'
            : f.remote.reason === 'no-source'
                ? '找不到發佈物：extension 沒有內附，也沒有設定發佈物來源。'
                : `找不到可用的發佈物（遠端：${f.remote.reason ?? '沒有回應'}）。`;
        void vscode.window.showWarningMessage(why, '選擇發佈物…', '設定發佈物來源…').then((c) => {
            if (c === '選擇發佈物…')
                retryWithPicked();
            if (c === '設定發佈物來源…')
                void vscode.commands.executeCommand('workbench.action.openSettings', 'codexSdlc.releaseSource');
        });
    }
    // 使用者自己指一份發佈物：資料夾（已解壓）或 .zip。兩種都交給 fetch -NoRemote 驗過才用 ——
    // 驗證只有那一份實作，而且「我明明指定了這一份」時不該偷偷跑去連網拿別的。
    async pickReleaseOnDisk(target) {
        const what = await this.pickOne([
            { label: '$(folder) 已解壓的發佈物資料夾', description: '裡面有 .codex/、.agents/、AGENTS.md', dir: true },
            { label: '$(file-zip) 發佈物的 .zip', description: 'codex-sdlc-<版本>.zip —— 會先解壓到快取再驗', dir: false },
        ], { title: '發佈物在哪裡？' });
        if (!what)
            return undefined;
        const uris = await vscode.window.showOpenDialog({
            title: what.dir ? '選擇已解壓的發佈物資料夾' : '選擇發佈物的 .zip',
            canSelectMany: false,
            canSelectFiles: !what.dir,
            canSelectFolders: what.dir,
            openLabel: '用這一份安裝',
            filters: what.dir ? undefined : { 發佈物: ['zip'] },
        });
        if (!uris?.[0])
            return undefined;
        const runner = this.bundledPayload() ?? (what.dir ? uris[0].fsPath : undefined)
            ?? (fs.existsSync(path.join(target, SDLC_REL)) ? target : undefined);
        if (!runner) {
            void vscode.window.showWarningMessage('要先有一支 sdlc.ps1 才能驗這份 zip —— 改選「已解壓的發佈物資料夾」。');
            return undefined;
        }
        const call = await this.runSdlcScript(runner, target, 'fetch', [
            '-Target', target, '-Json', '-NoRemote', '-Bundled', uris[0].fsPath, '-CacheDir', this.context.globalStorageUri.fsPath,
        ], 180_000);
        const env = call.ok ? this.report(call, 'fetch —— 驗這份發佈物') : undefined;
        if (env) {
            try {
                const f = (0, contract_1.parseFetch)(env);
                if (!f.path) {
                    void vscode.window.showWarningMessage(`那不是一份能用的發佈物：${env.warnings[0] ?? uris[0].fsPath}`);
                    return undefined;
                }
                return f;
            }
            catch (e) {
                this.log(`✖ fetch 的輸出讀不懂：${e.message}`);
            }
        }
        // 手上每一支 sdlc.ps1 都比 fetch 舊（4.10.0 以前沒有這個子命令）—— 他指的是資料夾的話照樣裝得起來，
        // 只是沒有人替他比對 sha。**這件事要講**，不要靜默降級。
        const version = what.dir ? this.workflowVersion(uris[0].fsPath) : undefined;
        if (!version) {
            void vscode.window.showWarningMessage(`那不是一份能用的發佈物：${uris[0].fsPath}`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
            return undefined;
        }
        const ok = await vscode.window.showWarningMessage(`這份發佈物是 ${version}，它的 sdlc.ps1 還沒有 fetch —— 沒辦法替你比對 manifest 的 sha256。`, { modal: true, detail: '照樣可以拿它安裝，只是「這份東西沒被動過」這件事這次沒有人驗。' }, '照樣用這一份');
        if (ok !== '照樣用這一份')
            return undefined;
        return {
            chosen: 'bundled', version, path: uris[0].fsPath, cacheDir: this.context.globalStorageUri.fsPath,
            remote: { checked: false, reachable: false, latest: null, url: null, reason: 'skipped' },
            bundled: { version, path: uris[0].fsPath },
        };
    }
    async pickPreset(source) {
        let presets = {};
        try {
            presets = JSON.parse(fs.readFileSync(path.join(source, PROFILES_REL), 'utf8')).presets ?? {};
        }
        catch { /* 下面退回三個名字 */ }
        const items = [
            { label: '全部 inherit', description: '不寫 model／effort，交給 Codex CLI 決定（預設，之後隨時可以在面板改）', value: '' },
            ...Object.keys(presets).map((n) => ({
                label: n,
                description: Object.entries(presets[n]).map(([a, v]) => `${a} ${v.effort ?? 'inherit'}`).join(' · '),
                value: n,
            })),
        ];
        const picked = await this.pickOne(items, { title: '裝好之後用哪一組調校？' });
        return picked?.value;
    }
    async installCommand(opts = {}) {
        const target = opts.target ?? await this.pickInstallTarget();
        if (!target)
            return;
        const f = opts.pickSource
            ? await this.pickReleaseOnDisk(target)
            : await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: '找一份 Codex SDLC 發佈物…' }, () => this.resolvePayload(target));
        if (!opts.pickSource && !f?.path) {
            this.noPayload(f, () => void this.installCommand({ pickSource: true, target }));
            return;
        }
        if (!f?.path)
            return; // 使用者自己選的那條路已經說過原因了
        const source = f.path;
        const how = { remote: `GitHub 發佈頁的 ${f.version}`, cached: `下載過的 ${f.version}（快取）`, bundled: `本機的 ${f.version}` }[f.chosen] ?? String(f.chosen);
        const hasAgents = fs.existsSync(path.join(target, AGENTS_REL));
        const hasGuidelines = fs.existsSync(path.join(target, 'guidelines'));
        const ok = await vscode.window.showInformationMessage(`把 Codex SDLC ${f.version} 裝進 ${path.basename(target)}？`, {
            modal: true,
            detail: [
                `來源：${how}`,
                '寫入 .codex/（腳本、agent 定義、hooks）、.agents/（skills）與 AGENTS.md。',
                hasAgents
                    ? '你已經有一份 AGENTS.md —— **不會覆蓋**，新版寫成 AGENTS.md.new，裝完會開左右對照讓你合併（合併之前整套流程不會啟動）。'
                    : '會建立 AGENTS.md —— 它就是 orchestrator 本身。',
                hasGuidelines ? 'guidelines/ 已經有了，完全不碰。' : 'guidelines/ 會放一份骨架 —— 那份是你的，升級永遠不會覆蓋。',
                '會建立 sdlc.config.json。不動 .git、不動你的程式碼。',
            ].join('\n'),
        }, '安裝', '選一組調校再裝…');
        if (!ok)
            return;
        let preset = '';
        if (ok === '選一組調校再裝…') {
            preset = await this.pickPreset(source);
            if (preset === undefined)
                return;
        }
        const call = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: `安裝 Codex SDLC ${f.version} 到 ${path.basename(target)}…` }, () => this.runSdlcFrom(source, target, 'install', preset ? ['-Preset', preset] : []));
        const env = this.report(call, 'install');
        if (!env)
            return;
        let d;
        try {
            d = (0, contract_1.parseInstall)(env);
        }
        catch (e) {
            void vscode.window.showErrorMessage(`install 的輸出讀不懂：${e.message}`);
            return;
        }
        if (d.error) {
            const why = {
                'not-a-release': '選到的不是一份完整的發佈物。',
                'same-path': '發佈物跟目標是同一個資料夾。',
                'nothing-to-adopt': '這個資料夾沒有 .codex/ 可以接管。',
            };
            void vscode.window.showErrorMessage(`沒有安裝：${why[d.error] ?? d.error}`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
            return;
        }
        this.syncRoots();
        await this.refresh(target);
        const actions = [
            ...(d.needsMerge.includes(AGENTS_REL) ? ['比對並合併 AGENTS.md'] : []),
            ...(d.lint.passed ? [] : ['顯示輸出']),
            '開啟設定面板',
        ];
        const merge = d.needsMerge.length > 0;
        const headline = merge
            ? `裝好了 ${d.version}，但 ${d.needsMerge.join('、')} 你已經有一份 —— 沒有覆蓋，新版寫成 .new。合併之前整套流程不會啟動。`
            : `裝好了 ${d.version}（${d.written} 個檔）。在專案裡開 Codex，直接說你要什麼即可。`;
        const chosen = merge
            ? await vscode.window.showWarningMessage(headline, ...actions)
            : await vscode.window.showInformationMessage(headline, ...actions);
        if (chosen === '比對並合併 AGENTS.md')
            await this.mergeAgentsCommand(target);
        else if (chosen === '顯示輸出')
            this.output.show();
        else if (chosen === '開啟設定面板')
            await vscode.commands.executeCommand('codexSdlc.openSettings');
    }
    async repairCommand(root, pickSource = false) {
        const f = pickSource
            ? await this.pickReleaseOnDisk(root)
            : await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: '找一份 Codex SDLC 發佈物…' }, () => this.resolvePayload(root));
        if (!f?.path) {
            if (!pickSource)
                this.noPayload(f, () => void this.repairCommand(root, true));
            return;
        }
        const ok = await vscode.window.showWarningMessage(`用 ${f.version} 補回 ${path.basename(root)} 的工具檔？`, {
            modal: true,
            detail: '走的是 sdlc.ps1 update：改過的工具檔會先備份再覆蓋，guidelines/ 與 sdlc.config.json 不會被動。',
        }, '補回工具檔');
        if (ok !== '補回工具檔')
            return;
        const env = this.report(await this.runSdlcFrom(f.path, root, 'update', ['-Yes']), 'update —— 補回工具檔');
        if (!env)
            return;
        const d = (0, contract_1.parseUpdate)(env);
        if (d.error === 'not-managed') {
            void vscode.window.showWarningMessage('這個資料夾還沒被 sdlc.ps1 接管過（沒有 sdlc.config.json）—— update 分不出哪些檔是你改過的。', '改用安裝').then((c) => { if (c)
                void this.installCommand({ target: root }); });
            return;
        }
        if (d.error) {
            void vscode.window.showErrorMessage(`沒有補成：${env.warnings[0] ?? d.error}`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
            return;
        }
        if (d.result === 'up-to-date')
            void vscode.window.showInformationMessage('工具檔本來就是齊的，一個檔都沒動。');
        else
            void vscode.window.showInformationMessage(`工具檔補回來了（${d.from ?? '？'} → ${d.to ?? '？'}）${d.backup ? `，原檔備份在 ${d.backup}` : ''}。`);
        this.syncRoots();
        await this.refresh(root);
    }
    async mergeAgentsCommand(root) {
        const r = root ?? this.pick()?.root;
        if (!r)
            return;
        const mine = path.join(r, AGENTS_REL);
        const fresh = `${mine}.new`;
        if (!fs.existsSync(fresh)) {
            void vscode.window.showInformationMessage(`沒有 ${AGENTS_REL}.new —— 沒有要合併的東西。`);
            return;
        }
        await vscode.commands.executeCommand('vscode.diff', vscode.Uri.file(mine), vscode.Uri.file(fresh), 'AGENTS.md（你的） ↔ AGENTS.md.new（新版）');
        const c = await vscode.window.showInformationMessage('把新版的流程那幾節合進左邊那一份（你的 AGENTS.md）。合完刪掉 .new —— 留著的話 doctor 會一直提醒。', '合好了，刪掉 .new');
        if (c) {
            await vscode.workspace.fs.delete(vscode.Uri.file(fresh), { useTrash: true });
            this.refreshViews();
            await this.refresh(r);
        }
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
        const env = this.report(await this.runSdlc(root, 'doctor'), 'doctor');
        if (!env)
            return;
        const d = (0, contract_1.parseDoctor)(env);
        const s = this.pick(root);
        if (s) {
            s.doctor = d;
            s.view = (0, status_1.statusFromDoctor)(d, new Date());
            this.render();
            this.refreshViews();
        }
        if (d.problems === 0)
            void vscode.window.showInformationMessage('doctor：沒有問題。');
        else
            void vscode.window.showWarningMessage(`doctor：${d.problems} 個問題。`, '看詳細').then((c) => { if (c)
                this.output.show(); });
    }
    async applyCommand(root) {
        if (!(await this.saveConfigIfDirty(root)))
            return;
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
    async tuneCommand(root) {
        const env = this.report(await this.runSdlc(root, 'tune'), 'tune');
        if (!env)
            return;
        const t = (0, contract_1.parseTune)(env);
        if (t.proposal.length === 0) {
            void vscode.window.showWarningMessage('tune 沒有產出建議 —— 見輸出面板。');
            return;
        }
        this.refreshViews();
        const diffs = t.proposal.filter((p) => p.current !== p.proposed);
        if (diffs.length === 0) {
            void vscode.window.showInformationMessage('現在的設定已經跟 tune 的建議一致。', '看理由').then((c) => { if (c)
                this.output.show(); });
            return;
        }
        if (!this.canEdit(root).ok) {
            void vscode.window.showInformationMessage(`tune 有 ${diffs.length} 項建議（見輸出面板）。${this.canEdit(root).reason ?? ''}`, '顯示輸出').then((c) => { if (c)
                this.output.show(); });
            return;
        }
        const picks = await vscode.window.showQuickPick(diffs.map((p) => ({ label: `${p.agent}：${p.current} → ${p.proposed}`, detail: `理由：${p.reason}　訊號：${p.signal}`, picked: true, agent: p.agent })), { title: 'tune 的建議 —— 勾選要套用的（這是提議，不會自己套用）', canPickMany: true, ignoreFocusOut: true, matchOnDetail: true });
        if (!picks || picks.length === 0)
            return;
        await this.applyProposal(root, picks.map((p) => p.agent));
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
            'unsupported-source': '更新來源沒有設定（或不是 GitHub repo 的網址）—— 在設定面板的「更新 → 來源」填上。',
        };
        const choice = d.status === 'unsupported-source' ? '開啟設定面板' : undefined;
        void vscode.window.showInformationMessage(text[d.status] ?? `check-update：${d.status}`, ...(choice ? [choice] : [])).then((c) => {
            if (c)
                void vscode.commands.executeCommand('codexSdlc.openSettings');
        });
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
