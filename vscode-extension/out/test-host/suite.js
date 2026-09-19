"use strict";
// 在**真的** VS Code extension host 裡驗打包出來的 vsix（計畫 M1／M1.5 的驗收）。
// 由 scripts/run-host-test.js 啟動：vsix 裝進一個隔離的 extensions 目錄，工作區是一個剛 install 好的暫存專案。
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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.run = run;
const strict_1 = __importDefault(require("node:assert/strict"));
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const vscode = __importStar(require("vscode"));
async function waitFor(what, cond, timeoutMs = 90_000) {
    const start = Date.now();
    while (!cond()) {
        if (Date.now() - start > timeoutMs)
            throw new Error(`等不到：${what}`);
        await new Promise((r) => setTimeout(r, 250));
    }
}
async function run() {
    const log = (m) => console.log(`[host-test] ${m}`);
    const workspace = process.env.CODEX_SDLC_HOST_WORKSPACE;
    const version = process.env.CODEX_SDLC_HOST_VERSION;
    strict_1.default.ok(workspace && version, '缺 CODEX_SDLC_HOST_WORKSPACE／CODEX_SDLC_HOST_VERSION');
    const ext = vscode.extensions.getExtension('codex-sdlc.codex-sdlc');
    strict_1.default.ok(ext, 'vsix 沒有裝進 extension host');
    strict_1.default.equal(ext.packageJSON.version, version, '裝進去的不是這一版的 vsix');
    const api = await ext.activate();
    log(`activated ${ext.packageJSON.version}; roots=${JSON.stringify(api.roots())}`);
    // 1. 狀態列出現版本
    await api.refresh();
    const first = api.status();
    log(`status: ${first?.text}`);
    strict_1.default.ok(first, '沒有狀態');
    strict_1.default.match(first.text, new RegExp(`SDLC ${version.replace(/\./g, '\\.')}`), `狀態列沒有版本：${first.text} / ${first.tooltip.join(' | ')}`);
    // 2. 改 sdlc.config.json 不 apply → 立刻看到漂移（靠 file watcher，不是我們手動 refresh）
    const cfg = path.join(workspace, 'sdlc.config.json');
    const json = JSON.parse(fs.readFileSync(cfg, 'utf8'));
    json.agents.reviewer.effort = 'high';
    fs.writeFileSync(cfg, JSON.stringify(json, null, 2));
    await waitFor('改了設定之後狀態列顯示漂移', () => /調校未套用/.test(api.status()?.text ?? ''));
    log(`status after edit: ${api.status()?.text}`);
    // 3. 按 apply（真的指令）→ doctor 綠（SDLC-TUNING sha 對得上）
    await vscode.commands.executeCommand('codexSdlc.apply');
    await waitFor('apply 之後調校一致', () => api.doctor()?.tuning.status === 'in-sync');
    log(`status after apply: ${api.status()?.text}`);
    strict_1.default.doesNotMatch(api.status().text, /調校未套用/);
    // 4. 存檔 → Problems 出現規範違規
    const sql = path.join(workspace, 'src', 'q.sql');
    fs.mkdirSync(path.dirname(sql), { recursive: true });
    fs.writeFileSync(sql, 'SELECT 1\nSELECT Id FROM Orders WITH (NOLOCK)\n');
    const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(sql));
    await vscode.window.showTextDocument(doc);
    await api.scan(doc.uri);
    await waitFor('Problems 出現 sql-no-nolock', () => api.diagnostics(doc.uri).some((d) => d.code === 'sql-no-nolock'), 60_000);
    const hit = api.diagnostics(doc.uri).find((d) => d.code === 'sql-no-nolock');
    log(`diagnostic: line ${hit.range.start.line + 1} ${vscode.DiagnosticSeverity[hit.severity]} ${hit.message}`);
    strict_1.default.equal(hit.range.start.line, 1);
    strict_1.default.equal(hit.severity, vscode.DiagnosticSeverity.Error);
    strict_1.default.match(hit.message, /禁止 NOLOCK/);
    // ---- 設定體驗（docs/settings-ux-plan.md 的 S0–S4）----
    const cfgUri = vscode.Uri.file(cfg);
    const rulesPath = path.join(workspace, 'guidelines', 'rules.json');
    const rulesUri = vscode.Uri.file(rulesPath);
    const lineOf = (file, needle) => fs.readFileSync(file, 'utf8').split(/\r?\n/).findIndex((l) => l.includes(needle));
    const schemaDiag = (uri, line) => vscode.languages.getDiagnostics(uri).find((d) => d.range.start.line === line && !String(d.source ?? '').startsWith('SDLC'));
    // 5. 動手前要先驗證的第 1 件：VS Code 認不認 $schema 的相對路徑 —— 沒有任何 extension 幫忙（我們沒有註冊 jsonValidation）。
    const goodCfg = fs.readFileSync(cfg, 'utf8');
    strict_1.default.match(goodCfg, /"\$schema": "\.\/\.codex\/bdd-workflow\/sdlc\.config\.schema\.json"/, 'install 沒寫 $schema');
    fs.writeFileSync(cfg, goodCfg.replace(/("sa-analyst":\s*\{[^}]*"effort":\s*)"[a-z]+"/, '$1"hgih"'));
    const cfgDoc = await vscode.workspace.openTextDocument(cfgUri);
    await vscode.window.showTextDocument(cfgDoc);
    const badLine = lineOf(cfg, '"hgih"');
    strict_1.default.ok(badLine >= 0, '測試自己沒把 hgih 寫進去');
    await waitFor('sdlc.config.json 的 hgih 出現 schema 的波浪線', () => !!schemaDiag(cfgUri, badLine), 60_000);
    log(`schema diagnostic (config): line ${badLine + 1} ${schemaDiag(cfgUri, badLine).message}`);
    const goodRules = fs.readFileSync(rulesPath, 'utf8');
    strict_1.default.match(goodRules, /"\$schema": "\.\.\/\.codex\/bdd-workflow\/rules\.schema\.json"/, 'rules.json 骨架沒有 $schema');
    fs.writeFileSync(rulesPath, goodRules.replace('"severity": "block"', '"severity": "blok"'));
    const rulesDoc = await vscode.workspace.openTextDocument(rulesUri);
    await vscode.window.showTextDocument(rulesDoc);
    const blokLine = lineOf(rulesPath, '"blok"');
    await waitFor('rules.json 的 blok 出現 schema 的波浪線（../ 的相對路徑）', () => !!schemaDiag(rulesUri, blokLine), 60_000);
    log(`schema diagnostic (rules): line ${blokLine + 1} ${schemaDiag(rulesUri, blokLine).message}`);
    // 6. rules.json 存檔 → 我們自己的 Problems（guideline-gate -Validate 判、extension 只定位）落在同一行
    await api.scan(rulesUri);
    await waitFor('rules.json 的問題進了 Problems', () => api.diagnostics(rulesUri).some((d) => d.source === 'SDLC 規範'), 60_000);
    const ruleHit = api.diagnostics(rulesUri).find((d) => d.source === 'SDLC 規範');
    strict_1.default.equal(ruleHit.range.start.line, blokLine, `問題沒有落在寫壞的那一行：${ruleHit.message}`);
    fs.writeFileSync(rulesPath, goodRules);
    fs.writeFileSync(cfg, goodCfg);
    await waitFor('設定檔改回來之後波浪線消失', () => !schemaDiag(cfgUri, badLine), 60_000);
    // 7. 設定面板：在裝了工作流的工作區出現（context key ＋ when ＋ 面板註冊，三者一起驗）
    await vscode.commands.executeCommand('codexSdlc.openSettings');
    await waitFor('設定面板打開', () => api.settingsViewVisible(), 30_000);
    await api.refresh();
    const tree = api.settingsTree();
    strict_1.default.deepEqual(tree.map((n) => n.label), ['狀態', 'Agent 調校', '審核', '更新', '規範', '這台機器']);
    log(`settings tree: ${tree.map((n) => `${n.label}${n.description ? `(${n.description})` : ''}`).join(' / ')}`);
    // 8. 改三個值 → apply 只跑一次（計畫 S2 的驗收）；順便量「現況」與「S2」各等多久（動手前要先驗證的第 3 件）
    const flat = (nodes) => nodes.flatMap((n) => [n, ...flat(n.children ?? [])]);
    const values = ['agents.reviewer.effort', 'agents.sa-analyst.effort', 'agents.implementer.effort'];
    let t0 = Date.now();
    for (const [i, key] of values.entries()) {
        await api.writeSettings([`${key}=${['low', 'medium', 'high'][i]}`], { apply: true, quiet: true });
        await api.refresh();
    }
    const oldFlowMs = Date.now() - t0;
    const before = api.calls();
    t0 = Date.now();
    for (const [i, key] of values.entries()) {
        const d = await api.writeSettings([`${key}=${['medium', 'low', 'inherit'][i]}`], { quiet: true });
        strict_1.default.equal(d?.error, null, `set 失敗：${JSON.stringify(d)}`);
    }
    const writesMs = Date.now() - t0;
    const pendingNode = flat(api.settingsTree()).find((n) => n.id === 'agents');
    strict_1.default.equal(pendingNode.contextValue, 'tuningPending', '寫完沒標未套用 —— 面板上看不出要按套用');
    strict_1.default.match(pendingNode.description ?? '', /3 項未套用/);
    await vscode.commands.executeCommand('codexSdlc.apply');
    await waitFor('套用之後調校一致', () => api.doctor()?.tuning.status === 'in-sync');
    const newFlowMs = Date.now() - t0;
    const after = api.calls();
    strict_1.default.equal((after.apply ?? 0) - (before.apply ?? 0), 1, '改三個值卻 apply 了不只一次');
    strict_1.default.equal((after.set ?? 0) - (before.set ?? 0), 3);
    strict_1.default.equal(flat(api.settingsTree()).find((n) => n.id === 'agents').contextValue, undefined, '套用完還掛著「套用」按鈕');
    log(`timing: 現況（每個值 set+apply+doctor）${oldFlowMs} ms；S2（三次 set 共 ${writesMs} ms，之後一次 apply+doctor）${newFlowMs} ms`);
    const reviewerToml = fs.readFileSync(path.join(workspace, '.codex/agents/reviewer.toml'), 'utf8');
    strict_1.default.match(reviewerToml, /model_reasoning_effort = "medium"/);
    // 9. set 擋下不合法的值：檔案不動
    const cfgBefore = fs.readFileSync(cfg, 'utf8');
    const bad = await api.writeSettings(['review.maxRounds=9'], { quiet: true });
    strict_1.default.equal(bad?.error, 'invalid');
    strict_1.default.equal(fs.readFileSync(cfg, 'utf8'), cfgBefore);
    // 10. CodeLens：tune 的建議掛在那個 agent 上，按下去只套那一個
    const proposalPath = path.join(workspace, 'bdd-docs/.sdlc/tuning-proposal.json');
    fs.mkdirSync(path.dirname(proposalPath), { recursive: true });
    fs.writeFileSync(proposalPath, JSON.stringify({
        'generated-at': new Date().toISOString(),
        signals: {},
        proposal: [
            { agent: 'reviewer', effort: 'high', reason: '判斷密度高', signal: '一律' },
            { agent: 'implementer', effort: 'max', reason: '測試用', signal: '—' },
        ],
    }));
    let lenses = [];
    await waitFor('tune 的建議出現在 CodeLens', () => {
        void vscode.commands.executeCommand('vscode.executeCodeLensProvider', cfgUri).then((l) => { lenses = l ?? []; });
        return lenses.some((l) => l.command?.command === 'codexSdlc.applyProposalFor' && (l.command.arguments ?? [])[1] === 'reviewer');
    }, 30_000);
    const lens = lenses.find((l) => l.command?.command === 'codexSdlc.applyProposalFor' && (l.command.arguments ?? [])[1] === 'reviewer');
    log(`codelens: line ${lens.range.start.line + 1} ${lens.command.title}`);
    await vscode.commands.executeCommand(lens.command.command, ...(lens.command.arguments ?? []));
    const cfgAfter = JSON.parse(fs.readFileSync(cfg, 'utf8'));
    strict_1.default.equal(cfgAfter.agents.reviewer.effort, 'high');
    strict_1.default.equal(cfgAfter.agents.implementer.effort, 'inherit', 'CodeLens 只該套那一個 agent');
    // 11. 引導與信任按鈕叫得起來（這台測試機上沒有 codex → 只會說找不到，不會卡住）
    await vscode.commands.executeCommand('codexSdlc.openWalkthrough');
    await vscode.commands.executeCommand('codexSdlc.trustHooks');
    log('all host checks passed');
}
