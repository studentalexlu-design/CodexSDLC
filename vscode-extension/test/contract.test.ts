import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  compareVersions, ContractError, MIN_WORKFLOW_VERSION, parseDlpGate, parseDoctor, parseEnvelope, parseGuidelineGate, parseRulesValidation, parseSet, SUPPORTED_SCHEMA,
} from '../src/contract';
import { doctorFixture } from './fixtures';

const envelope = (command: string, data: unknown, extra: Record<string, unknown> = {}) =>
  JSON.stringify({ schema: SUPPORTED_SCHEMA, command, exit: 0, data, warnings: [], output: ['一句給人看的話'], ...extra });

test('合法的 doctor 輸出解析得出來', () => {
  const d = parseDoctor(parseEnvelope(envelope('doctor', doctorFixture()), 'doctor'));
  assert.equal(d.version.contract, '4.8.0');
  assert.equal(d.hooks.counts?.trusted, 4);
});

test('4.8.0 以前的輸出（沒有 schema）→ 明講工作流太舊，不去解析句子', () => {
  assert.throws(() => parseEnvelope(JSON.stringify({ command: 'doctor', exit: 0, output: ['版本 4.7.0'] }), 'doctor'), (e: Error) => e instanceof ContractError && /太舊/.test(e.message));
});

test('schema 版本不同 → 明講不相容', () => {
  assert.throws(() => parseEnvelope(envelope('doctor', doctorFixture(), { schema: 2 }), 'doctor'), /schema 2/);
});

test('欄位改名 → 紅，而且說得出是哪一個欄位', () => {
  const data = doctorFixture();
  data.tuningState = data.tuning;
  delete data.tuning;
  assert.throws(() => parseDoctor(parseEnvelope(envelope('doctor', data), 'doctor')), /\$\.data\.tuning/);
});

test('型別改了 → 紅', () => {
  const data = doctorFixture();
  data.problems = '0';
  assert.throws(() => parseDoctor(parseEnvelope(envelope('doctor', data), 'doctor')), /\$\.data\.problems 應為 number/);
});

test('output 的句子怎麼改都不影響解析（extension 從來不讀它）', () => {
  const a = parseDoctor(parseEnvelope(envelope('doctor', doctorFixture(), { output: ['版本 4.8.0（最低相容 4.2.0）'] }), 'doctor'));
  const b = parseDoctor(parseEnvelope(envelope('doctor', doctorFixture(), { output: ['Version 4.8.0 — completely reworded'] }), 'doctor'));
  assert.deepEqual(a, b);
});

test('指令對不上 → 紅（避免把 apply 的輸出當成 doctor）', () => {
  assert.throws(() => parseEnvelope(envelope('apply', { changed: [], warnings: [] }), 'doctor'), /預期 doctor/);
});

test('guideline-gate：舊版沒有 status 的輸出 → 明講太舊', () => {
  assert.throws(() => parseGuidelineGate(JSON.stringify({ passed: false, hits: [] })), /太舊/);
});

test('guideline-gate：合法輸出', () => {
  const r = parseGuidelineGate(JSON.stringify({
    passed: false, status: 'scanned', rules_file: 'guidelines/rules.json', problems: [], files: ['src/q.sql'], scanned_files: 1, block_count: 1, warn_count: 0,
    hits: [{ rule: 'sql-no-nolock', severity: 'block', file: 'src/q.sql', line: 2, message: '禁止 NOLOCK', fix: '改用快照隔離' }],
  }));
  assert.equal(r.hits[0].line, 2);
});

test('dlp-gate：合法輸出', () => {
  const r = parseDlpGate(JSON.stringify({ passed: false, disabled: false, scanned: ['bdd-docs/f/notes.md'], findings: [{ file: 'bdd-docs/f/notes.md', categories: [{ type: 'email', count: 1, lines: [2] }], lines: [2] }] }));
  assert.equal(r.findings[0].categories[0].lines[0], 2);
});

test('版本比較：4.7.0 太舊、4.8.0 與之後可以（數字比，不是字串比）', () => {
  assert.equal(MIN_WORKFLOW_VERSION, '4.8.0');
  assert.equal(compareVersions('4.7.0', MIN_WORKFLOW_VERSION), -1);
  assert.equal(compareVersions('4.8.0', MIN_WORKFLOW_VERSION), 0);
  assert.equal(compareVersions('4.10.0', MIN_WORKFLOW_VERSION), 1, '字串比的話 4.10 會小於 4.8');
  assert.equal(compareVersions('5.0', '4.99.99'), 1);
});

test('4.8 的 doctor（沒有 config.comments／schemaRef）照樣讀得懂，讀成 false', () => {
  const d = parseDoctor(parseEnvelope(envelope('doctor', doctorFixture()), 'doctor'));
  assert.equal(d.config.comments, false);
  assert.equal(d.config.schemaRef, false);
  const data = doctorFixture() as Record<string, any>;
  data.config = { exists: true, parsable: true, comments: true, schemaRef: true };
  assert.equal(parseDoctor(parseEnvelope(envelope('doctor', data), 'doctor')).config.comments, true);
  data.config.comments = 'yes';
  assert.throws(() => parseDoctor(parseEnvelope(envelope('doctor', data), 'doctor')), /config\.comments/);
});

test('set 的結果：變更、錯誤、有沒有寫、有沒有套用；整數值讀成字串給畫面用', () => {
  const ok = parseSet(parseEnvelope(envelope('set', {
    changes: [
      { key: 'review.maxRounds', from: 3, to: 4, changed: true, needsApply: false },
      { key: 'agents.reviewer.effort', from: null, to: 'high', changed: true, needsApply: true },
    ],
    errors: [], written: true, applied: false, preview: false, backup: null,
  }), 'set'));
  assert.equal(ok.error, null);
  assert.deepEqual(ok.changes.map((c) => [c.from, c.to]), [['3', '4'], [null, 'high']]);
  assert.equal(ok.written, true);

  const bad = parseSet(parseEnvelope(envelope('set', {
    error: 'invalid', changes: [], written: false, applied: false, preview: false, backup: null,
    errors: [{ key: 'agents.reviewer.effort', value: 'hgih', message: '不是合法值', suggestion: 'agents.reviewer.effort=high' }],
  }, { exit: 2 }), 'set'));
  assert.equal(bad.error, 'invalid');
  assert.equal(bad.errors[0].suggestion, 'agents.reviewer.effort=high');

  // 在讀設定檔之前就停下來的錯誤沒有 changes／errors —— 不該因此解析失敗。
  const early = parseSet(parseEnvelope(envelope('set', { error: 'schema-unreadable' }, { exit: 2 }), 'set'));
  assert.equal(early.error, 'schema-unreadable');
  assert.deepEqual(early.changes, []);

  assert.throws(() => parseSet(parseEnvelope(envelope('set', { changes: [{ key: 'x', from: true, to: 'y', changed: true, needsApply: false }] }), 'set')), /from/);
});

test('rules.json 的驗證結果：新版帶「第幾條、哪個欄位」；舊版只有句子 → 一律當檔案層級（不從句子裡猜）', () => {
  const v = parseRulesValidation(JSON.stringify({
    passed: false, rules_file: 'guidelines/rules.json', exists: true, rule_count: 1, block_count: 0,
    problems: ['b: severity 必須是 block 或 warn'],
    rule_problems: [{ index: 2, id: 'b', field: 'severity', message: 'b: severity 必須是 block 或 warn' }],
  }));
  assert.deepEqual(v.ruleProblems[0], { index: 2, id: 'b', field: 'severity', message: 'b: severity 必須是 block 或 warn' });
  const old = parseRulesValidation(JSON.stringify({ passed: false, rules_file: 'r', exists: true, rule_count: 1, block_count: 0, problems: ['b: 缺 pattern'] }));
  assert.deepEqual(old.ruleProblems, [{ index: null, id: null, field: null, message: 'b: 缺 pattern' }]);
});
