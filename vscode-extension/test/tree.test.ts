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
    agentsNewExists: false,
    machine: { pwsh: { ok: true, path: 'C:/pwsh/pwsh.exe' }, extensionVersion: '4.9.0', payloadVersion: '4.9.0' },
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

test('hooks.json 在 → 那一行綠，而且不提信任（要問 codex 的事一律不做）', () => {
  const n = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'skipped', codex: null }; }) }));
  const h = n.get('status/hooks')!;
  assert.equal(h.tone, 'ok');
  assert.equal(h.contextValue, undefined);
  assert.doesNotMatch(h.label, /信任/);
});

test('AGENTS.md.new 還在 → 常駐一行，點一下開對照', () => {
  const n = nodes(input({ agentsNewExists: true }));
  const m = n.get('status/merge')!;
  assert.equal(m.tone, 'error');
  assert.equal(m.contextValue, 'needsMerge');
  assert.equal(m.command?.command, 'codexSdlc.mergeAgents');
  assert.deepEqual(m.command?.arguments, ['C:/work/shop']);
  assert.ok(!nodes(input()).has('status/merge'), '沒有 .new 時不該有這一行');
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
  const n = nodes(input({ machine: { pwsh: { ok: false, message: '找不到 pwsh' }, extensionVersion: '4.9.0' } }));
  assert.equal(n.get('machine/pwsh')!.tone, 'error');
  assert.equal(n.get('machine/pwsh')!.contextValue, 'machinePwsh');
  // 沒有內附發佈物（開發模式）要講出來 —— 不然「安裝到這個工作區」會在按下去之後才說沒東西可裝。
  assert.match(n.get('machine/payload')!.description!, /沒有/);
});

test('這台機器：沒有 codex 那一行了（信任檢查整條拿掉）', () => {
  assert.ok(!nodes(input()).has('machine/codex'));
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

test('沒有 hooks.json → 面板那一行是紅的，而且點下去就能補（不是叫人去終端機）', () => {
  const n = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'no-hooks', codex: null }; }) }));
  const h = n.get('status/hooks')!;
  assert.equal(h.tone, 'error');
  assert.equal(h.contextValue, 'toolFilesMissing');
  assert.equal(h.command?.command, 'codexSdlc.repair');
  assert.ok(![...n.keys()].some((k) => k.startsWith('status/issues/') && /hooks/.test(n.get(k)!.label)), 'hooks 的問題重複列了兩次');
});
