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
    log('all host checks passed');
}
