// 設定面板的樹。每一條守的是「畫面跟真相對不上」的一種：看到的值不是檔裡的、該標未套用沒標、不該改的給改。
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';
import { readConfig } from '../src/config';
import { parseDoctor, parseEnvelope, SUPPORTED_SCHEMA, type DoctorData } from '../src/contract';
import { parseSettingsSchema } from '../src/schema';
import { buildSettingsTree, flatten, pendingAgentsOf, type SettingNode, type TreeInput } from '../src/tree';
import { doctorFixture } from './fixtures';

const repo = path.resolve(__dirname, '..', '..', '..');
const schema = parseSettingsSchema(fs.readFileSync(path.join(repo, '.codex/bdd-workflow/sdlc.config.schema.json'), 'utf8'));

const configText = JSON.stringify({
  $schema: './.codex/bdd-workflow/sdlc.config.schema.json',
  update: { source: '', check: 'daily' },
  review: { maxRounds: 4 },
  agents: {
    orchestrator: { model: 'inherit', effort: 'inherit' },
    'sa-analyst': { model: 'inherit', effort: 'high' },
    implementer: { model: 'inherit', effort: 'inherit' },
    reviewer: { model: 'gpt-5.5', effort: 'medium' },
  },
});

function doctor(mutate: (d: Record<string, any>) => void = () => {}): DoctorData {
  const data = doctorFixture() as Record<string, any>;
  data.version.contract = '4.9.0';
  data.review = { maxRounds: 4, source: 'config', valid: true };
  mutate(data);
  return parseDoctor(parseEnvelope(JSON.stringify({ schema: SUPPORTED_SCHEMA, command: 'doctor', exit: 0, data, warnings: [], output: [] }), 'doctor'));
}

function input(over: Partial<TreeInput> = {}): TreeInput {
  return {
    rootName: 'shop', rootPath: 'C:/work/shop', workflowVersion: '4.9.0', schema, canEdit: true,
    config: readConfig(configText), knownAgents: [], doctor: doctor(), checking: false, pendingAgents: [],
    guidelines: { dir: true, files: ['README.md', 'coding.md', 'rules.json', 'sql.md'], rulesExists: true, ruleCount: 8, gateDisabled: false },
    machine: { pwsh: { ok: true, path: 'C:/pwsh/pwsh.exe' }, codex: { source: 'path', path: 'C:/bin/codex.exe' }, extensionVersion: '4.9.0' },
    ...over,
  };
}
const nodes = (i: TreeInput) => new Map(flatten(buildSettingsTree(i)).map((n) => [n.id, n] as [string, SettingNode]));

test('六個區段，順序固定（人找東西靠位置）', () => {
  assert.deepEqual(buildSettingsTree(input()).map((n) => n.label), ['狀態', 'Agent 調校', '審核', '更新', '規範', '這台機器']);
});

test('ID 不重複（VS Code 的樹靠它記住展開狀態，重複會直接丟錯）', () => {
  const all = flatten(buildSettingsTree(input({ pendingAgents: ['reviewer'], proposal: [{ agent: 'reviewer', effort: 'high', reason: 'r' }] })));
  assert.equal(new Set(all.map((n) => n.id)).size, all.length);
});

test('看到的值就是設定檔裡的值', () => {
  const n = nodes(input());
  assert.match(n.get('agents/reviewer')!.description!, /effort medium · model gpt-5\.5/);
  assert.equal(n.get('agents/reviewer/model')!.description, 'gpt-5.5 · 未驗證');
  assert.match(n.get('review/maxRounds')!.description!, /^4 輪 · 下一次委派就生效/);
  assert.equal(n.get('update/check')!.description, '每天');
  assert.match(n.get('update/source')!.description!, /未設定/);
});

test('每個可改的值都帶著 set 用的 key 與 schema 的選項', () => {
  const n = nodes(input());
  const effort = n.get('agents/sa-analyst/effort')!;
  assert.equal(effort.contextValue, 'editable');
  assert.equal(effort.command?.command, 'codexSdlc.editSetting');
  assert.equal(effort.edit?.kind, 'choice');
  assert.equal(effort.edit?.key, 'agents.sa-analyst.effort');
  if (effort.edit?.kind === 'choice') {
    assert.deepEqual(effort.edit.choices.map((c) => c.value), schema.effort.choices.map((c) => c.value), '選項不是從 schema 來的');
  }
  const rounds = n.get('review/maxRounds')!.edit!;
  assert.equal(rounds.key, 'review.maxRounds');
  if (rounds.kind === 'choice') assert.deepEqual(rounds.choices.map((c) => c.value), ['1', '2', '3', '4', '5']);
  assert.equal(n.get('update/source')!.edit?.kind, 'text');
});

test('sa-analyst 釘 high → 那一行直接標警告（逾時的成因）', () => {
  const n = nodes(input());
  assert.equal(n.get('agents/sa-analyst/effort')!.tone, 'warn');
  assert.match(n.get('agents/sa-analyst/effort')!.description!, /逾時/);
});

test('未套用：doctor 說的 ∪ 剛寫、doctor 還沒回來的；orchestrator 永遠不算', () => {
  const d = doctor((x) => { x.tuning = { status: 'stale', stale: ['reviewer.toml'] }; });
  assert.deepEqual(pendingAgentsOf({ doctor: d, pendingAgents: ['implementer', 'orchestrator'] }), ['implementer', 'reviewer']);
  const n = nodes(input({ doctor: d, pendingAgents: ['implementer'] }));
  const agents = n.get('agents')!;
  assert.equal(agents.contextValue, 'tuningPending', '沒有「套用」按鈕');
  assert.equal(agents.description, '2 項未套用');
  assert.match(n.get('agents/implementer')!.description!, /未套用/);
  assert.doesNotMatch(n.get('agents/sa-analyst')!.description!, /未套用/);
});

test('都套用了 → 沒有「套用」按鈕，寫明已套用', () => {
  const agents = nodes(input()).get('agents')!;
  assert.equal(agents.contextValue, undefined);
  assert.equal(agents.description, '已套用');
});

test('orchestrator 說清楚「只是記錄，強制不了」', () => {
  assert.match(nodes(input()).get('agents/orchestrator')!.description!, /只是記錄，強制不了/);
});

test('工作流太舊（沒有 set／schema）→ 只顯示、不給改，並說要升到哪一版', () => {
  const n = nodes(input({ canEdit: false, schema: undefined, workflowVersion: '4.8.0', editBlockedReason: '升到 4.9.0 以上才能在這裡改' }));
  assert.ok([...n.values()].every((x) => !x.edit && x.contextValue !== 'editable'), '不能改的專案出現了修改按鈕');
  assert.match(n.get('agents/blocked')!.label, /4\.9\.0/);
  assert.match(n.get('agents/reviewer')!.description!, /effort medium/, '不能改也要看得到值');
});

test('hooks 沒信任 → 那一行紅、帶「在終端機信任」；找不到 codex → 帶「選擇 codex」', () => {
  const untrusted = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'untrusted', codex: 'c', counts: { total: 4, trusted: 2, untrusted: 1, modified: 1, disabled: 0 } }; }) }));
  const h = untrusted.get('status/hooks')!;
  assert.equal(h.tone, 'error');
  assert.equal(h.contextValue, 'hooksUntrusted');
  assert.equal(h.command?.command, 'codexSdlc.trustHooks');
  assert.match(h.label, /1 條未信任、1 條改過待重審/);
  assert.ok(![...untrusted.keys()].some((k) => k.startsWith('status/issues/') && /信任/.test(untrusted.get(k)!.label)), 'hooks 的問題重複列了兩次');

  const unknown = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'unknown', reason: 'codex-not-found', codex: null }; }) })).get('status/hooks')!;
  assert.equal(unknown.contextValue, 'hooksUnknown');
  assert.equal(unknown.command?.command, 'codexSdlc.pickCodex');
  assert.notEqual(unknown.tone, 'ok', '查不到不能顯示成綠的');
});

test('doctor 的其他問題列在「需要處理」底下', () => {
  const n = nodes(input({ doctor: doctor((x) => { x.config.comments = true; x.problems = 0; }) }));
  const issues = n.get('status/issues')!;
  assert.equal(issues.children!.length, 1);
  assert.match(issues.children![0].label, /註解/);
});

test('修正輪寫壞 → 說照預設幾輪算', () => {
  const n = nodes(input({ doctor: doctor((x) => { x.review = { maxRounds: 3, source: 'default', valid: false }; }), config: readConfig(configText.replace('"maxRounds":4', '"maxRounds":"4"')) }));
  const r = n.get('review/maxRounds')!;
  assert.equal(r.tone, 'warn');
  assert.match(r.description!, /寫壞了.*照預設 3 輪算/);
});

test('update.check 不認得的值 → 說會照每天算、會連網', () => {
  const n = nodes(input({ config: readConfig(configText.replace('"check":"daily"', '"check":"nevr"')) }));
  assert.equal(n.get('update/check')!.tone, 'warn');
  assert.match(n.get('update/check')!.description!, /nevr.*會連網/);
});

test('tune 的建議：只算跟現值不一樣的', () => {
  const n = nodes(input({ proposal: [
    { agent: 'reviewer', effort: 'high', reason: '判斷密度高' },
    { agent: 'implementer', effort: 'inherit', reason: '一樣' },
    { agent: 'nobody', effort: 'low', reason: '專案沒有這個 agent' },
  ] }));
  const t = n.get('agents/tune')!;
  assert.equal(t.label, 'tune 有 1 項建議');
  assert.equal(t.description, 'reviewer → high');
  assert.equal(nodes(input()).get('agents/tune')!.label, '依 repo 現況給建議…');
});

test('規範：README 不算規範文件；機械層關著 → 警告並給「打開」', () => {
  const n = nodes(input({ guidelines: { dir: true, files: ['README.md', 'coding.md', 'rules.json'], rulesExists: true, ruleCount: 8, gateDisabled: true } }));
  assert.equal(n.get('guidelines/docs')!.description, 'coding');
  assert.equal(n.get('guidelines/gate')!.contextValue, 'gateOff');
  assert.equal(n.get('guidelines/gate')!.tone, 'warn');
  assert.match(n.get('guidelines/rules')!.description!, /8 條 · 驗證通過/);
  const invalid = nodes(input({ doctor: doctor((x) => { x.guidelines = [{ level: 'warn', code: 'rules-invalid', text: 'rules.json 有 1 條載入失敗' }]; }) }));
  assert.equal(invalid.get('guidelines/rules')!.tone, 'error');
});

test('沒有 guidelines/ → 一句話，不出現機械層開關', () => {
  const n = nodes(input({ guidelines: { dir: false, files: [], rulesExists: false, gateDisabled: false } }));
  assert.ok(n.has('guidelines/none'));
  assert.ok(!n.has('guidelines/gate'));
});

test('這台機器：找不到 pwsh → 紅，帶「選擇」', () => {
  const n = nodes(input({ machine: { pwsh: { ok: false, message: '找不到 pwsh' }, codex: { source: 'none' }, extensionVersion: '4.9.0' } }));
  assert.equal(n.get('machine/pwsh')!.tone, 'error');
  assert.equal(n.get('machine/pwsh')!.contextValue, 'machinePwsh');
  assert.match(n.get('machine/codex')!.description!, /找不到/);
});

test('設定檔壞了 → 一句話＋開檔，而不是一棵空樹', () => {
  const n = nodes(input({ config: undefined, configError: 'sdlc.config.json 解析不了' }));
  assert.equal(n.get('agents/error')!.command?.command, 'codexSdlc.openFile');
});

test('沒有 sdlc.config.json：照樣列出 agent 讓你改（第一次改就會建檔），並說這是合法狀態', () => {
  const n = nodes(input({ config: undefined, knownAgents: ['implementer', 'reviewer', 'sa-analyst', 'orchestrator'] }));
  assert.match(n.get('agents/none')!.description!, /全部 inherit/);
  assert.equal(n.get('agents/none')!.tone, 'muted', '合法狀態不該顯示成錯誤');
  assert.equal(n.get('agents/reviewer/effort')!.edit?.key, 'agents.reviewer.effort', '沒有設定檔就不給改 —— 使用者會被丟回去手動建檔');
  assert.match(n.get('agents/reviewer')!.description!, /effort inherit/);
  assert.equal(n.get('review/maxRounds')!.edit?.key, 'review.maxRounds');
});

test('沒有 hooks.json → 面板那一行是紅的，並說怎麼補', () => {
  const h = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'no-hooks', codex: null }; }) })).get('status/hooks')!;
  assert.equal(h.tone, 'error');
  assert.match(h.tooltip!, /update/);
});
