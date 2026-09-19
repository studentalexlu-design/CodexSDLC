// 面板的選項從專案裡的 schema 來。這一組守兩件事：讀得懂**真的那一份** schema、形狀不對時明講而不是猜。
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';
import { ContractError } from '../src/contract';
import { effortChoicesFor, matchesPattern, parseSettingsSchema } from '../src/schema';

const repo = path.resolve(__dirname, '..', '..', '..');
const real = fs.readFileSync(path.join(repo, '.codex/bdd-workflow/sdlc.config.schema.json'), 'utf8');

test('真的 schema：effort、修正輪、更新檢查的選項都讀得出來', () => {
  const s = parseSettingsSchema(real);
  assert.equal(s.effort.choices[0].value, 'inherit', 'inherit 要排第一個 —— 它是每個 agent 的預設');
  assert.ok(s.effort.choices.every((c) => c.description.length > 0), '每個 effort 選項都要有說明');
  assert.deepEqual([s.reviewRounds.min, s.reviewRounds.max, s.reviewRounds.default], [1, 5, 3]);
  assert.deepEqual(s.updateCheck.choices.map((c) => [c.value, c.label]), [['daily', '每天'], ['never', '不檢查']]);
  assert.ok(s.model.examples.includes('inherit'));
});

test('某個 agent 的 effort 選項會疊上 schema 給它的提醒（sa-analyst 不要 high）', () => {
  const s = parseSettingsSchema(real);
  const sa = effortChoicesFor(s, 'sa-analyst').find((c) => c.value === 'high')!;
  assert.match(sa.description, /^⚠.*逾時/);
  const other = effortChoicesFor(s, 'implementer').find((c) => c.value === 'high')!;
  assert.doesNotMatch(other.description, /逾時/, '提醒不該漏到別的 agent 身上');
});

test('schema 缺了面板要的值 → ContractError，說得出缺哪一個', () => {
  const broken = JSON.parse(real);
  delete broken.properties.review.properties.maxRounds.maximum;
  assert.throws(() => parseSettingsSchema(JSON.stringify(broken)), (e: Error) => e instanceof ContractError && /maxRounds\.maximum/.test(e.message));
  const noEnum = JSON.parse(real);
  noEnum.definitions.effort.enum = 'inherit';
  assert.throws(() => parseSettingsSchema(JSON.stringify(noEnum)), /effort\.enum/);
  assert.throws(() => parseSettingsSchema('{ not json'), ContractError);
});

test('只是說明文字缺了 → 照樣能用（不因為少一句話就讓整個面板不能改）', () => {
  const lean = JSON.parse(real);
  delete lean.definitions.effort.enumDescriptions;
  delete lean.properties.update.properties.check['x-labels'];
  const s = parseSettingsSchema(JSON.stringify(lean));
  assert.equal(s.effort.choices[0].description, '');
  assert.equal(s.updateCheck.choices[0].label, 'daily');
});

test('輸入框的即時提示用 schema 的 pattern（寫不寫得進去仍由 set 判）', () => {
  const s = parseSettingsSchema(real);
  assert.ok(matchesPattern(s.updateSource.pattern, 'https://github.com/owner/repo.git'));
  assert.ok(!matchesPattern(s.updateSource.pattern, 'https://example.com/x'));
  assert.ok(!matchesPattern(s.model.pattern, 'gpt 5'));
  assert.ok(matchesPattern(undefined, 'anything'));
  assert.ok(matchesPattern('([', 'x'), 'pattern 本身壞掉時不擋人，交給 set 判');
});
