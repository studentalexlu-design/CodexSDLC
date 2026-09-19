"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const strict_1 = __importDefault(require("node:assert/strict"));
const node_test_1 = require("node:test");
const contract_1 = require("../src/contract");
const status_1 = require("../src/status");
const fixtures_1 = require("./fixtures");
function doctor(mutate = () => { }) {
    const data = (0, fixtures_1.doctorFixture)();
    mutate(data);
    return (0, contract_1.parseDoctor)((0, contract_1.parseEnvelope)(JSON.stringify({ schema: contract_1.SUPPORTED_SCHEMA, command: 'doctor', exit: 0, data, warnings: [], output: [] }), 'doctor'));
}
const now = new Date('2026-09-13T08:00:00Z');
(0, node_test_1.test)('一切正常 → 綠的版本號', () => {
    const v = (0, status_1.statusFromDoctor)(doctor(), now);
    strict_1.default.equal(v.level, 'ok');
    strict_1.default.equal(v.text, '$(check) SDLC 4.8.0');
});
(0, node_test_1.test)('改了設定沒 apply → 立刻看到漂移', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => { d.tuning = { status: 'stale', stale: ['reviewer.toml'] }; }), now);
    strict_1.default.equal(v.level, 'warn');
    strict_1.default.match(v.text, /調校未套用/);
    strict_1.default.ok(v.tooltip.some((l) => l.includes('reviewer.toml')));
});
(0, node_test_1.test)('調校漂移時 agent-lint 的同一條違規不重複報（狀態列要顯示能動手的那一句）', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => {
        d.tuning = { status: 'stale', stale: ['reviewer.toml'] };
        d.lint = { ran: true, passed: false, violations: [{ rule: 'tuning-block-stale', detail: 'reviewer.toml', fix: 'apply' }] };
    }), now);
    strict_1.default.match(v.text, /調校未套用$/);
    strict_1.default.doesNotMatch(v.text, /agent-lint/);
});
(0, node_test_1.test)('其他 agent-lint 違規照樣報', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => {
        d.lint = { ran: true, passed: false, violations: [{ rule: 'hook-exit-code-swallowed', detail: 'x', fix: 'y' }] };
    }), now);
    strict_1.default.equal(v.level, 'error');
    strict_1.default.match(v.text, /agent-lint/);
});
(0, node_test_1.test)('hooks 沒被信任 → 紅，而且說去哪裡按', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => { d.hooks = { status: 'untrusted', codex: 'codex', counts: { total: 4, trusted: 2, untrusted: 1, modified: 1, disabled: 0 } }; }), now);
    strict_1.default.equal(v.level, 'error');
    strict_1.default.match(v.text, /hooks 未信任/);
    strict_1.default.ok(v.tooltip.some((l) => l.includes('Hooks need review')));
});
(0, node_test_1.test)('專案本身沒被信任 → 紅', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => { d.hooks = { status: 'project-untrusted', codex: 'codex', counts: { total: 0, trusted: 0, untrusted: 0, modified: 0, disabled: 0 } }; }), now);
    strict_1.default.equal(v.level, 'error');
});
(0, node_test_1.test)('查不到 codex 不算問題（但 tooltip 要講）', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => { d.hooks = { status: 'unknown', reason: 'codex-not-found', codex: null }; }), now);
    strict_1.default.equal(v.level, 'ok');
    strict_1.default.ok(v.tooltip.some((l) => l.includes('無法確認')));
});
(0, node_test_1.test)('有新版而且沒看過 → 顯示；看過 → 安靜', () => {
    const unseen = (0, status_1.statusFromDoctor)(doctor((d) => { d.update = { ...d.update, cached: true, newer: true, latest: '4.9.0', seen: false }; }), now);
    strict_1.default.match(unseen.text, /\$\(arrow-up\) 4\.9\.0/);
    const seen = (0, status_1.statusFromDoctor)(doctor((d) => { d.update = { ...d.update, cached: true, newer: true, latest: '4.9.0', seen: true }; }), now);
    strict_1.default.doesNotMatch(seen.text, /arrow-up/);
});
(0, node_test_1.test)('多個問題 → 最嚴重的放前面，其餘用 +N', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => {
        d.tuning = { status: 'stale', stale: ['a.toml'] };
        d.hooks = { status: 'project-untrusted', codex: 'codex', counts: { total: 0, trusted: 0, untrusted: 0, modified: 0, disabled: 0 } };
    }), now);
    strict_1.default.match(v.text, /專案未信任 \+1/);
});
(0, node_test_1.test)('失敗狀態有人看得懂的一句話', () => {
    const v = (0, status_1.statusFromFailure)('pwsh-missing', '找不到 PowerShell 7（pwsh）');
    strict_1.default.equal(v.level, 'error');
    strict_1.default.match(v.text, /pwsh/);
});
(0, node_test_1.test)('修正輪上限寫壞了 → 提示實際照幾輪算，而且不跟 agent-lint 的同一條重複報', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => {
        d.review = { maxRounds: 3, source: 'default', valid: false };
        d.lint = { ran: true, passed: false, violations: [{ rule: 'review-max-rounds-invalid', detail: 'x', fix: 'y' }] };
    }), now);
    strict_1.default.match(v.text, /修正輪上限寫壞了$/);
    strict_1.default.doesNotMatch(v.text, /agent-lint/);
    strict_1.default.ok(v.tooltip.some((l) => l.includes('照預設 3 輪算')));
});
(0, node_test_1.test)('tooltip 顯示實際生效的修正輪上限與來源', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => { d.review = { maxRounds: 5, source: 'config', valid: true }; }), now);
    strict_1.default.ok(v.tooltip.some((l) => l === '審核修正輪上限：5 輪（sdlc.config.json 的 review.maxRounds）'));
});
(0, node_test_1.test)('設定檔有註解 → 警告（下一次寫入會不見），不算錯', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => { d.config = { exists: true, parsable: true, comments: true, schemaRef: true }; }), now);
    strict_1.default.equal(v.level, 'warn');
    strict_1.default.match(v.text, /設定檔有註解/);
});
(0, node_test_1.test)('update.check 打錯 → 自己一條看得懂的警告，不是泛泛的 agent-lint', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => {
        d.lint = { ran: true, passed: false, violations: [{ rule: 'update-check-invalid', detail: 'update.check 是 "nevr"', fix: 'x' }] };
    }), now);
    strict_1.default.match(v.text, /更新檢查頻率寫壞了$/);
    strict_1.default.doesNotMatch(v.text, /agent-lint/);
});
(0, node_test_1.test)('沒有 hooks.json → 錯誤等級（整層強制不存在，比「沒信任」更嚴重）', () => {
    const v = (0, status_1.statusFromDoctor)(doctor((d) => { d.hooks = { status: 'no-hooks', codex: null }; d.problems = 1; }), now);
    strict_1.default.equal(v.level, 'error');
    strict_1.default.match(v.text, /沒有 hooks\.json/);
    strict_1.default.ok(v.issues.some((i) => /update/.test(i.detail)), '沒說怎麼補回來');
});
