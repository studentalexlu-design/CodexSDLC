import assert from 'node:assert/strict';
import { test } from 'node:test';
import { configLenses } from '../src/codelens';

const text = [
  '{',
  '  "agents": {',
  '    "sa-analyst": { "model": "inherit", "effort": "inherit" },',
  '    "reviewer": { "model": "inherit", "effort": "medium" }',
  '  }',
  '}',
].join('\n');
const proposal = [
  { agent: 'reviewer', effort: 'high', reason: '判斷密度高' },
  { agent: 'sa-analyst', effort: 'inherit', reason: '規模不大' },
  { agent: 'implementer', effort: 'medium', reason: '檔裡沒有這個 agent' },
];

test('有未套用 → 檔案最上面一個「套用」；一律有「在設定面板開啟」', () => {
  const l = configLenses(text, { rootPath: 'R', pendingAgents: ['reviewer'], canEdit: true });
  assert.deepEqual(l.map((x) => [x.line, x.command]), [[0, 'codexSdlc.apply'], [0, 'codexSdlc.openSettings']]);
  assert.match(l[0].title, /1 個 agent 未套用/);
  assert.deepEqual(configLenses(text, { rootPath: 'R', pendingAgents: [], canEdit: true }).map((x) => x.command), ['codexSdlc.openSettings']);
});

test('tune 的建議掛在那個 agent 上，只給跟現值不一樣的；按下去只套那一個', () => {
  const l = configLenses(text, { rootPath: 'R', pendingAgents: [], proposal, canEdit: true }).filter((x) => x.command === 'codexSdlc.applyProposalFor');
  assert.equal(l.length, 1);
  assert.equal(l[0].line, 3);
  assert.deepEqual(l[0].arguments, ['R', 'reviewer']);
  assert.match(l[0].title, /high/);
});

test('不能改的專案（工作流太舊）→ 不給「採用」', () => {
  const l = configLenses(text, { rootPath: 'R', pendingAgents: [], proposal, canEdit: false });
  assert.ok(!l.some((x) => x.command === 'codexSdlc.applyProposalFor'));
});

test('檔案寫壞了 → 只剩「在設定面板開啟」，不丟例外', () => {
  const l = configLenses('{ "agents": ', { rootPath: 'R', pendingAgents: [], proposal, canEdit: true });
  assert.deepEqual(l.map((x) => x.command), ['codexSdlc.openSettings']);
});
