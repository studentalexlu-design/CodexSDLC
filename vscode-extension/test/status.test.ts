import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseDoctor, parseEnvelope, SUPPORTED_SCHEMA, type DoctorData } from '../src/contract';
import { statusFromDoctor, statusFromFailure } from '../src/status';
import { doctorFixture } from './fixtures';

function doctor(mutate: (d: Record<string, any>) => void = () => {}): DoctorData {
  const data = doctorFixture() as Record<string, any>;
  mutate(data);
  return parseDoctor(parseEnvelope(JSON.stringify({ schema: SUPPORTED_SCHEMA, command: 'doctor', exit: 0, data, warnings: [], output: [] }), 'doctor'));
}
const now = new Date('2026-09-13T08:00:00Z');

test('一切正常 → 綠的版本號', () => {
  const v = statusFromDoctor(doctor(), now);
  assert.equal(v.level, 'ok');
  assert.equal(v.text, '$(check) SDLC 4.8.0');
});

test('改了設定沒 apply → 立刻看到漂移', () => {
  const v = statusFromDoctor(doctor((d) => { d.tuning = { status: 'stale', stale: ['reviewer.toml'] }; }), now);
  assert.equal(v.level, 'warn');
  assert.match(v.text, /調校未套用/);
  assert.ok(v.tooltip.some((l) => l.includes('reviewer.toml')));
});

test('調校漂移時 agent-lint 的同一條違規不重複報（狀態列要顯示能動手的那一句）', () => {
  const v = statusFromDoctor(doctor((d) => {
    d.tuning = { status: 'stale', stale: ['reviewer.toml'] };
    d.lint = { ran: true, passed: false, violations: [{ rule: 'tuning-block-stale', detail: 'reviewer.toml', fix: 'apply' }] };
  }), now);
  assert.match(v.text, /調校未套用$/);
  assert.doesNotMatch(v.text, /agent-lint/);
});

test('其他 agent-lint 違規照樣報', () => {
  const v = statusFromDoctor(doctor((d) => {
    d.lint = { ran: true, passed: false, violations: [{ rule: 'hook-exit-code-swallowed', detail: 'x', fix: 'y' }] };
  }), now);
  assert.equal(v.level, 'error');
  assert.match(v.text, /agent-lint/);
});

// 信任狀態整條拿掉了：doctor 4.10.0 起預設就不問，回 skipped。
// 這三條守的是「拿掉之後不會又冒出來」—— 舊工作流回的 untrusted／unknown 都不得再變成使用者要處理的事。
test('沒查信任狀態 → 不是問題，也不佔 tooltip 一行', () => {
  const v = statusFromDoctor(doctor((d) => { d.hooks = { status: 'skipped', codex: null }; }), now);
  assert.equal(v.level, 'ok');
  assert.ok(!v.tooltip.some((l) => /信任|機械強制層/.test(l)));
});

test('就算 doctor 回了未信任（舊工作流，或有人加了 -CheckHookTrust），狀態列也不報', () => {
  const v = statusFromDoctor(doctor((d) => { d.hooks = { status: 'untrusted', codex: 'codex', counts: { total: 4, trusted: 2, untrusted: 1, modified: 1, disabled: 0 } }; }), now);
  assert.equal(v.level, 'ok');
  assert.ok(!v.issues.some((i) => /信任/.test(i.detail)));
});

test('查不到 codex 不算問題', () => {
  const v = statusFromDoctor(doctor((d) => { d.hooks = { status: 'unknown', reason: 'codex-not-found', codex: null }; }), now);
  assert.equal(v.level, 'ok');
});

test('有新版而且沒看過 → 顯示；看過 → 安靜', () => {
  const unseen = statusFromDoctor(doctor((d) => { d.update = { ...d.update, cached: true, newer: true, latest: '4.9.0', seen: false }; }), now);
  assert.match(unseen.text, /\$\(arrow-up\) 4\.9\.0/);
  const seen = statusFromDoctor(doctor((d) => { d.update = { ...d.update, cached: true, newer: true, latest: '4.9.0', seen: true }; }), now);
  assert.doesNotMatch(seen.text, /arrow-up/);
});

test('多個問題 → 最嚴重的放前面，其餘用 +N', () => {
  const v = statusFromDoctor(doctor((d) => {
    d.tuning = { status: 'stale', stale: ['a.toml'] };
    d.hooks = { status: 'no-hooks', codex: null };
  }), now);
  assert.match(v.text, /沒有 hooks\.json \+1/);
});

test('失敗狀態有人看得懂的一句話', () => {
  const v = statusFromFailure('pwsh-missing', '找不到 PowerShell 7（pwsh）');
  assert.equal(v.level, 'error');
  assert.match(v.text, /pwsh/);
});

test('修正輪上限寫壞了 → 提示實際照幾輪算，而且不跟 agent-lint 的同一條重複報', () => {
  const v = statusFromDoctor(doctor((d) => {
    d.review = { maxRounds: 3, source: 'default', valid: false };
    d.lint = { ran: true, passed: false, violations: [{ rule: 'review-max-rounds-invalid', detail: 'x', fix: 'y' }] };
  }), now);
  assert.match(v.text, /修正輪上限寫壞了$/);
  assert.doesNotMatch(v.text, /agent-lint/);
  assert.ok(v.tooltip.some((l) => l.includes('照預設 3 輪算')));
});

test('tooltip 顯示實際生效的修正輪上限與來源', () => {
  const v = statusFromDoctor(doctor((d) => { d.review = { maxRounds: 5, source: 'config', valid: true }; }), now);
  assert.ok(v.tooltip.some((l) => l === '審核修正輪上限：5 輪（sdlc.config.json 的 review.maxRounds）'));
});

test('設定檔有註解 → 警告（下一次寫入會不見），不算錯', () => {
  const v = statusFromDoctor(doctor((d) => { d.config = { exists: true, parsable: true, comments: true, schemaRef: true }; }), now);
  assert.equal(v.level, 'warn');
  assert.match(v.text, /設定檔有註解/);
});

test('update.check 打錯 → 自己一條看得懂的警告，不是泛泛的 agent-lint', () => {
  const v = statusFromDoctor(doctor((d) => {
    d.lint = { ran: true, passed: false, violations: [{ rule: 'update-check-invalid', detail: 'update.check 是 "nevr"', fix: 'x' }] };
  }), now);
  assert.match(v.text, /更新檢查頻率寫壞了$/);
  assert.doesNotMatch(v.text, /agent-lint/);
});

test('沒有 hooks.json → 錯誤等級（整層強制不存在），而且有一顆按得下去的按鈕', () => {
  const v = statusFromDoctor(doctor((d) => { d.hooks = { status: 'no-hooks', codex: null }; d.problems = 1; }), now);
  assert.equal(v.level, 'error');
  assert.match(v.text, /沒有 hooks\.json/);
  assert.equal(v.issues.find((i) => /hooks\.json/.test(i.badge))?.fix?.command?.command, 'codexSdlc.repair', '沒有補回工具檔的按鈕');
});
