import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readAgents, setAgentValue } from '../src/tuning';

const withComments = [
  '{',
  '    // 團隊約定：reviewer 一律 high',
  '    "workflow-version": "4.8.0",',
  '    "agents": {',
  '        "sa-analyst": { "model": "inherit", "effort": "inherit" }, /* 大 repo 別動 */',
  '        "reviewer":   { "model": "inherit", "effort": "medium" }',
  '    }',
  '}',
  '',
].join('\n');

test('只改那一個值：註解、縮排、其他欄位一個字不動', () => {
  const after = setAgentValue(withComments, 'reviewer', 'effort', 'high');
  assert.equal(after, withComments.replace('"effort": "medium"', '"effort": "high"'));
});

test('設定檔裡還沒有那個 agent（升級新增的）→ 補上，其餘不動', () => {
  const after = setAgentValue(withComments, 'implementer', 'effort', 'low');
  assert.ok(after.includes('// 團隊約定：reviewer 一律 high'), '註解被吃掉了');
  assert.deepEqual(readAgents(after).find((a) => a.name === 'implementer'), { name: 'implementer', model: 'inherit', effort: 'low' });
});

test('沒寫的值讀成 inherit', () => {
  assert.deepEqual(readAgents('{ "agents": { "reviewer": {} } }'), [{ name: 'reviewer', model: 'inherit', effort: 'inherit' }]);
});

test('壞掉的 JSON 不動它', () => {
  assert.throws(() => setAgentValue('{ "agents": ', 'reviewer', 'effort', 'high'), /解析不了/);
});

test('保留 CRLF', () => {
  const crlf = '{\r\n  "agents": {\r\n    "reviewer": { "effort": "medium" }\r\n  }\r\n}\r\n';
  const after = setAgentValue(crlf, 'reviewer', 'effort', 'high');
  assert.equal(after, crlf.replace('medium', 'high'));
});

test('修正輪上限：只改 review.maxRounds，註解與其他值不動；沒有這一節就補上', async () => {
  const { readReviewMaxRounds, setReviewMaxRounds } = await import('../src/tuning');
  const withReview = withComments.replace('"workflow-version": "4.8.0",', '"workflow-version": "4.8.0",\n    "review": { "maxRounds": 3 },');
  const after = setReviewMaxRounds(withReview, 5);
  assert.equal(after, withReview.replace('"maxRounds": 3', '"maxRounds": 5'));
  assert.equal(readReviewMaxRounds(after), 5);

  const added = setReviewMaxRounds(withComments, 2);
  assert.ok(added.includes('// 團隊約定：reviewer 一律 high'), '補 review 時註解被吃掉了');
  assert.equal(readReviewMaxRounds(added), 2);
  assert.equal(readReviewMaxRounds(withComments), undefined);
});

test('修正輪上限一定寫成整數（字串 "3" hook 不採用）', async () => {
  const { setReviewMaxRounds } = await import('../src/tuning');
  assert.throws(() => setReviewMaxRounds('{ "agents": {} }', 2.5), /整數/);
  assert.match(setReviewMaxRounds('{ "agents": {} }', 4), /"maxRounds": 4\b/);
});
