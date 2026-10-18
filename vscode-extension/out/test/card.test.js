"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
// 狀態卡片的 HTML。每一條守的是 webview 會出事的一種：字被當成 HTML、按鈕叫到不該叫的指令、CSP 開了洞。
const strict_1 = __importDefault(require("node:assert/strict"));
const node_test_1 = require("node:test");
const card_1 = require("../src/card");
const base = { state: 'ok', items: [], quiet: 3, project: 'shop', version: '4.16.3', checkedAt: '09:41' };
const opts = { nonce: 'N0NCE', cspSource: 'vscode-webview://x' };
(0, node_test_1.test)('一切正常：一句話、專案與版本、幾點檢查過；健檢是主要按鈕', () => {
    const r = (0, card_1.renderCard)(base, opts);
    strict_1.default.match(r.html, /一切正常/);
    strict_1.default.match(r.html, /shop · 工作流 4\.16\.3/);
    strict_1.default.match(r.html, /09:41 檢查過/);
    strict_1.default.deepEqual(r.actions.map((a) => a.command), ['codexSdlc.doctor', 'codexSdlc.checkUpdate']);
    strict_1.default.match(r.html, /class="primary" data-a="0">健檢</);
});
(0, node_test_1.test)('有事：件數、每件一顆按鈕，按鈕只帶索引（指令留在 extension 那邊）', () => {
    const r = (0, card_1.renderCard)({ ...base, state: 'attention', items: [
            { level: 'error', title: 'AGENTS.md.new 還沒合併', detail: '合併前流程不會照新版跑', action: { label: '合併', command: 'codexSdlc.mergeAgents', arguments: ['C:/p'] } },
            { level: 'warn', title: '設定檔有註解' },
        ] }, opts);
    strict_1.default.match(r.html, /<span class="count">2<\/span>/);
    strict_1.default.match(r.html, /其他 3 項正常/);
    strict_1.default.equal(r.actions.length, 1);
    strict_1.default.deepEqual(r.actions[0].arguments, ['C:/p']);
    strict_1.default.doesNotMatch(r.html, /codexSdlc\.mergeAgents|C:\/p/, '指令或路徑寫進了 webview');
});
(0, node_test_1.test)('所有文字都先跳脫 —— 檔名、doctor 的訊息不能變成 HTML', () => {
    const r = (0, card_1.renderCard)({ ...base, state: 'attention', project: '<img src=x onerror=alert(1)>', items: [{ level: 'error', title: '"><script>x</script>', detail: "a'b" }] }, opts);
    strict_1.default.doesNotMatch(r.html, /<img src=x|<script>x/);
    strict_1.default.match(r.html, /&lt;script&gt;/);
    strict_1.default.match(r.html, /a&#39;b/);
});
(0, node_test_1.test)('CSP：什麼都不准，只開帶 nonce 的 style 與 script', () => {
    const r = (0, card_1.renderCard)(base, opts);
    strict_1.default.match(r.html, /default-src 'none'/);
    strict_1.default.match(r.html, /script-src 'nonce-N0NCE'/);
    strict_1.default.equal((r.html.match(/<script/g) ?? []).length, 1);
    strict_1.default.match(r.html, /<script nonce="N0NCE">/);
    strict_1.default.doesNotMatch(r.html, /style="/, '有 inline style —— CSP 會把它擋掉');
});
(0, node_test_1.test)('新版是卡片外的一顆膠囊，不算件數', () => {
    const r = (0, card_1.renderCard)({ ...base, upgrade: { version: '4.17.0', action: { label: '升級', command: 'codexSdlc.upgrade' } } }, opts);
    strict_1.default.match(r.html, /class="pill"/);
    strict_1.default.match(r.html, /有新版 4\.17\.0/);
    strict_1.default.match(r.html, /一切正常/);
    strict_1.default.ok(r.actions.some((a) => a.command === 'codexSdlc.upgrade'));
});
(0, node_test_1.test)('健檢沒跑起來 → 說原因，給「再試一次」與「看輸出」；檢查中 → 沒有按鈕', () => {
    const f = (0, card_1.renderCard)({ ...base, state: 'failed', failure: '找不到 PowerShell 7' }, opts);
    strict_1.default.match(f.html, /健檢沒跑起來/);
    strict_1.default.match(f.html, /找不到 PowerShell 7/);
    strict_1.default.deepEqual(f.actions.map((a) => a.command), ['codexSdlc.refresh', 'codexSdlc.showOutput']);
    strict_1.default.equal((0, card_1.renderCard)({ ...base, state: 'checking' }, opts).actions.length, 0);
});
