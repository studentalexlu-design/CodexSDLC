// 狀態卡片的 HTML。每一條守的是 webview 會出事的一種：字被當成 HTML、按鈕叫到不該叫的指令、CSP 開了洞。
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { renderCard } from '../src/card';
import type { StatusCard } from '../src/tree';

const base: StatusCard = { state: 'ok', items: [], quiet: 3, project: 'shop', version: '4.16.3', checkedAt: '09:41' };
const opts = { nonce: 'N0NCE', cspSource: 'vscode-webview://x' };

test('一切正常：一句話、專案與版本、幾點檢查過；健檢是主要按鈕', () => {
  const r = renderCard(base, opts);
  assert.match(r.html, /一切正常/);
  assert.match(r.html, /shop · 工作流 4\.16\.3/);
  assert.match(r.html, /09:41 檢查過/);
  assert.deepEqual(r.actions.map((a) => a.command), ['codexSdlc.doctor', 'codexSdlc.checkUpdate']);
  assert.match(r.html, /class="primary" data-a="0">健檢</);
});

test('有事：件數、每件一顆按鈕，按鈕只帶索引（指令留在 extension 那邊）', () => {
  const r = renderCard({ ...base, state: 'attention', items: [
    { level: 'error', title: 'AGENTS.md.new 還沒合併', detail: '合併前流程不會照新版跑', action: { label: '合併', command: 'codexSdlc.mergeAgents', arguments: ['C:/p'] } },
    { level: 'warn', title: '設定檔有註解' },
  ] }, opts);
  assert.match(r.html, /<span class="count">2<\/span>/);
  assert.match(r.html, /其他 3 項正常/);
  assert.equal(r.actions.length, 1);
  assert.deepEqual(r.actions[0].arguments, ['C:/p']);
  assert.doesNotMatch(r.html, /codexSdlc\.mergeAgents|C:\/p/, '指令或路徑寫進了 webview');
});

test('所有文字都先跳脫 —— 檔名、doctor 的訊息不能變成 HTML', () => {
  const r = renderCard({ ...base, state: 'attention', project: '<img src=x onerror=alert(1)>', items: [{ level: 'error', title: '"><script>x</script>', detail: "a'b" }] }, opts);
  assert.doesNotMatch(r.html, /<img src=x|<script>x/);
  assert.match(r.html, /&lt;script&gt;/);
  assert.match(r.html, /a&#39;b/);
});

test('CSP：什麼都不准，只開帶 nonce 的 style 與 script', () => {
  const r = renderCard(base, opts);
  assert.match(r.html, /default-src 'none'/);
  assert.match(r.html, /script-src 'nonce-N0NCE'/);
  assert.equal((r.html.match(/<script/g) ?? []).length, 1);
  assert.match(r.html, /<script nonce="N0NCE">/);
  assert.doesNotMatch(r.html, /style="/, '有 inline style —— CSP 會把它擋掉');
});

test('新版是卡片外的一顆膠囊，不算件數', () => {
  const r = renderCard({ ...base, upgrade: { version: '4.17.0', action: { label: '升級', command: 'codexSdlc.upgrade' } } }, opts);
  assert.match(r.html, /class="pill"/);
  assert.match(r.html, /有新版 4\.17\.0/);
  assert.match(r.html, /一切正常/);
  assert.ok(r.actions.some((a) => a.command === 'codexSdlc.upgrade'));
});

test('健檢沒跑起來 → 說原因，給「再試一次」與「看輸出」；檢查中 → 沒有按鈕', () => {
  const f = renderCard({ ...base, state: 'failed', failure: '找不到 PowerShell 7' }, opts);
  assert.match(f.html, /健檢沒跑起來/);
  assert.match(f.html, /找不到 PowerShell 7/);
  assert.deepEqual(f.actions.map((a) => a.command), ['codexSdlc.refresh', 'codexSdlc.showOutput']);
  assert.equal(renderCard({ ...base, state: 'checking' }, opts).actions.length, 0);
});
