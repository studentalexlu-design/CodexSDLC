import assert from 'node:assert/strict';
import { test } from 'node:test';
import { dlpOutcome, groupByFile, guidelineOutcome } from '../src/diagnostics';

test('guideline：block → error、warn → warning，帶規則 id 與修法', () => {
  const o = guidelineOutcome({
    status: 'scanned', files: ['src/q.sql'], problems: [],
    hits: [
      { rule: 'sql-no-nolock', severity: 'block', file: 'src/q.sql', line: 2, message: '禁止 NOLOCK', fix: '改用快照隔離' },
      { rule: 'sql-no-select-star', severity: 'warn', file: 'src/q.sql', line: 5, message: '不要 SELECT *', fix: '' },
    ],
  });
  assert.equal(o.records[0].severity, 'error');
  assert.equal(o.records[0].code, 'sql-no-nolock');
  assert.match(o.records[0].message, /修法：改用快照隔離/);
  assert.equal(o.records[1].severity, 'warning');
  assert.equal(o.records[1].message, '不要 SELECT *');
});

test('guideline：被關掉時留一句話（不是某一行的事，但不能安靜）', () => {
  const o = guidelineOutcome({ status: 'disabled', files: [], problems: [], hits: [] });
  assert.match(o.note ?? '', /\.gate-disabled/);
});

test('DLP：每個類別的每一行一筆，訊息只有類別', () => {
  const o = dlpOutcome({ disabled: false, scanned: ['bdd-docs/f/notes.md'], findings: [{ file: 'bdd-docs/f/notes.md', categories: [{ type: 'email', count: 2, lines: [2, 7] }, { type: 'connstring', count: 1, lines: [9] }] }] });
  assert.deepEqual(o.records.map((r) => [r.line, r.code]), [[2, 'dlp-email'], [7, 'dlp-email'], [9, 'dlp-connstring']]);
});

test('掃過但乾淨的檔也要出現在分組裡（才清得掉上一次的診斷）', () => {
  const o = guidelineOutcome({ status: 'scanned', files: ['src/a.sql', 'src/b.sql'], problems: [], hits: [{ rule: 'r', severity: 'warn', file: 'src/b.sql', line: 1, message: 'm', fix: '' }] });
  const g = groupByFile(o, ['src/a.sql', 'src/b.sql', 'docs/readme.md']);
  assert.deepEqual(g.get('src/a.sql'), []);
  assert.equal(g.get('src/b.sql')?.length, 1);
  assert.deepEqual(g.get('docs/readme.md'), [], 'gate 沒掃（被排除）的檔也要清掉舊的診斷');
});
