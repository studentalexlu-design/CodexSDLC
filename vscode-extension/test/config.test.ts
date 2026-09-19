import assert from 'node:assert/strict';
import { test } from 'node:test';
import { agentLine, ConfigReadError, countRules, readConfig, ruleLine } from '../src/config';

const cfg = [
  '{',
  '  "$schema": "./.codex/bdd-workflow/sdlc.config.schema.json",',
  '  "update": { "source": "", "check": "nevr" },',
  '  "review": { "maxRounds": "3" },',
  '  "agents": {',
  '    "orchestrator": { "model": "inherit", "effort": "high" },',
  '    "sa-analyst": { "effort": "low" },',
  '    "reviewer": {',
  '      "model": "gpt-5.5",',
  '      "effort": "high"',
  '    }',
  '  }',
  '}',
].join('\n');

test('讀出面板要顯示的值；寫壞的值原樣給（對錯由 doctor 判）', () => {
  const c = readConfig(cfg);
  assert.equal(c.hasSchemaRef, true);
  assert.equal(c.updateCheck, 'nevr');
  assert.equal(c.reviewMaxRounds, '3', '字串 "3" 要原樣給，面板才說得出它寫壞了');
  assert.deepEqual(c.agents.map((a) => [a.name, a.effort, a.model]), [
    ['sa-analyst', 'low', 'inherit'],
    ['reviewer', 'high', 'gpt-5.5'],
    ['orchestrator', 'high', 'inherit'],
  ], 'orchestrator 排最後（只是記錄）；沒寫的 model 讀成 inherit');
});

test('JSON 壞了 → ConfigReadError（面板顯示這一句，不顯示一棵空樹）', () => {
  assert.throws(() => readConfig('{ "agents": '), ConfigReadError);
});

test('CodeLens 的位置：agent 那個 key 所在的行', () => {
  assert.equal(agentLine(cfg, 'reviewer'), 7);
  assert.equal(agentLine(cfg, 'sa-analyst'), 6);
  assert.equal(agentLine(cfg, 'nobody'), undefined);
});

const rules = [
  '{',
  '  "rules": [',
  '    { "id": "a", "pattern": "x" },',
  '    {',
  '      "id": "b",',
  '      "pattern": "y",',
  '      "severity": "blok"',
  '    }',
  '  ]',
  '}',
].join('\n');

test('rules.json 的問題定位到那一條、那個欄位；欄位不存在就停在規則開頭', () => {
  assert.equal(ruleLine(rules, 2, 'severity'), 6);
  assert.equal(ruleLine(rules, 2, 'fix'), 3);
  assert.equal(ruleLine(rules, 1), 2);
  assert.equal(ruleLine(rules, 9), undefined);
  assert.equal(countRules(rules), 2);
  assert.equal(countRules('{}'), undefined);
});
