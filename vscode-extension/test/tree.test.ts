// 設定面板的樹。每一條守的是「畫面跟真相對不上」的一種：看到的值不是檔裡的、該標未套用沒標、不該改的給改。
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';
import { readConfig } from '../src/config';
import { parseDoctor, parseEnvelope, SUPPORTED_SCHEMA, type DoctorData } from '../src/contract';
import { parseSettingsSchema } from '../src/schema';
import { attentionCount, buildPanel, buildSettingsTree, flatten, pendingAgentsOf, statusCard, upgradeOffer, type SettingNode, type TreeInput } from '../src/tree';
import { doctorFixture, modelsFixture } from './fixtures';

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

const statusRows = (i: TreeInput) => buildSettingsTree(i)[0].children!;

test('調校 view 不包標題：agent 直接列，審核接在後面；其他收進進階', () => {
  const p = buildPanel(input());
  const ids = p.views.settings.map((n) => n.id);
  assert.deepEqual(ids.filter((id) => /^agents\/[^/]+$/.test(id) && id !== 'agents/tune').sort(), ['agents/implementer', 'agents/orchestrator', 'agents/reviewer', 'agents/sa-analyst']);
  assert.equal(ids[ids.length - 1], 'review/maxRounds');
  assert.ok(!ids.includes('agents') && !ids.includes('review'), '又多包了一層區段標題');
  assert.deepEqual(p.views.advanced.map((n) => n.id), ['update', 'guidelines', 'machine']);
});

test('有未套用 → 調校最上面一行就是「套用 N 項」；剛套用完換成「已套用」', () => {
  const pending = buildPanel(input({ pendingAgents: ['reviewer', 'implementer'] })).views.settings[0];
  assert.equal(pending.label, '套用 2 項');
  assert.equal(pending.command?.command, 'codexSdlc.apply');
  assert.equal(pending.tone, 'accent', '待套用是你自己的改動，不該用警告色');
  const applied = buildPanel(input({ pendingAgents: ['reviewer'], justApplied: ['reviewer'] })).views.settings[0];
  assert.equal(applied.label, '已套用 reviewer');
  assert.ok(!buildPanel(input({ pendingAgents: ['reviewer'], justApplied: ['reviewer'] })).views.settings.some((n) => n.id === 'settings/apply'));
  assert.notEqual(buildPanel(input()).views.settings[0].id, 'settings/apply');
});

test('全部正常 → 狀態只剩「一切正常」一行，其他收在它底下', () => {
  const top = statusRows(input());
  assert.deepEqual(top.map((n) => n.label), ['一切正常']);
  assert.ok(top[0].children!.some((n) => n.id === 'status/hooks'));
  assert.ok(!top[0].expanded);
});

test('有事 → 要處理的排最上面，沒事的收成「其他 N 項正常」', () => {
  const top = statusRows(input({ agentsNewExists: true, doctor: doctor((x) => { x.hooks = { status: 'no-hooks', codex: null }; }) }));
  assert.deepEqual(top.slice(0, 2).map((n) => n.id), ['status/hooks', 'status/merge']);
  assert.match(top[top.length - 1].label, /^其他 \d+ 項正常$/);
});

test('狀態卡片：全部正常 → ok，帶專案、版本、幾點檢查過', () => {
  const c = statusCard(input({ checkedAt: new Date(2026, 9, 18, 9, 5).getTime() }));
  assert.equal(c.state, 'ok');
  assert.deepEqual(c.items, []);
  assert.equal(c.project, 'shop');
  assert.equal(c.version, '4.9.0');
  assert.equal(c.checkedAt, '09:05');
  assert.ok(c.quiet > 0);
});

test('狀態卡片：要處理的事各帶一顆短按鈕；hooks 不在 → 補回、.new 沒合併 → 合併', () => {
  const c = statusCard(input({ agentsNewExists: true, doctor: doctor((x) => { x.hooks = { status: 'no-hooks', codex: null }; }) }));
  assert.equal(c.state, 'attention');
  assert.deepEqual(c.items.map((x) => [x.level, x.action?.label, x.action?.command]), [
    ['error', '補回', 'codexSdlc.repair'],
    ['error', '合併', 'codexSdlc.mergeAgents'],
  ]);
  assert.deepEqual(c.items[1].action?.arguments, ['C:/work/shop'], '合併要帶著是哪個專案');
});

test('狀態卡片：新版與調校未套用都不算要處理的事', () => {
  const c = statusCard(input({ doctor: doctor((x) => {
    x.update = { ...x.update, cached: true, newer: true, latest: '4.16.0' };
    x.tuning = { status: 'stale', stale: ['reviewer.toml'] };
  }) }));
  assert.equal(c.state, 'ok', '待套用或新版把卡片變成「有事」');
  assert.equal(c.upgrade?.version, '4.16.0');
  assert.equal(c.upgrade?.action.command, 'codexSdlc.upgrade');
  assert.equal(attentionCount(input({ pendingAgents: ['reviewer'] })), 0);
});

test('狀態卡片：活動列的數字＝卡片上列的件數', () => {
  const i = input({ agentsNewExists: true, doctor: doctor((x) => { x.config.comments = true; }) });
  assert.equal(attentionCount(i), statusCard(i).items.length);
  assert.equal(attentionCount(i), 2);
});

test('狀態卡片：doctor 還沒回來 → 檢查中；沒跑起來 → 說原因，不說一切正常', () => {
  assert.equal(statusCard(input({ doctor: undefined, checking: true })).state, 'checking');
  const f = statusCard(input({ doctor: undefined, failure: '找不到 PowerShell 7' }));
  assert.equal(f.state, 'failed');
  assert.equal(f.failure, '找不到 PowerShell 7');
});

test('ID 不重複（VS Code 的樹靠它記住展開狀態，重複會直接丟錯）', () => {
  const all = flatten(buildSettingsTree(input({ pendingAgents: ['reviewer'], proposal: [{ agent: 'reviewer', effort: 'high', reason: 'r' }] })));
  assert.equal(new Set(all.map((n) => n.id)).size, all.length);
});

test('看到的值就是設定檔裡的值', () => {
  const n = nodes(input());
  // 側邊欄很窄：那一行只放兩個值，完整的說法在 tooltip。
  assert.equal(n.get('agents/reviewer')!.description, 'medium · gpt-5.5');
  assert.match(n.get('agents/reviewer')!.tooltip!, /effort medium · model gpt-5\.5/);
  assert.equal(n.get('agents/reviewer/model')!.description, 'gpt-5.5');
  const unverified = nodes(input({ doctor: doctor((x) => { x.unverifiedModel = ['reviewer']; }) }));
  assert.equal(unverified.get('agents/reviewer/model')!.description, 'gpt-5.5 · 沒對 Codex 驗證');
  assert.equal(n.get('review/maxRounds')!.description, '4 輪');
  assert.match(n.get('review/maxRounds')!.tooltip!, /下一次委派就生效/);
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

test('更新來源：認得的照實顯示；認不得的寫法標警告（check-update 只會靜默地查不到）', () => {
  const withSource = (src: string) => nodes(input({ config: readConfig(configText.replace('"source":""', `"source":${JSON.stringify(src)}`)) })).get('update/source')!;
  for (const ok of ['gitea:https://git.acme.local/team/flow', 'https://gitlab.com/g/sub/p']) {
    assert.equal(withSource(ok).description, ok);
    assert.equal(withSource(ok).tone, undefined);
  }
  const bad = withSource('https://git.acme.local/team/flow');
  assert.equal(bad.tone, 'warn');
  assert.match(bad.description!, /認不得/);
});

test('問得到這台 Codex 的模型清單：effort 只列 agent 實際用的模型支援的，model 的建議就是這台有的', () => {
  const n = nodes(input({ doctor: doctor((x) => { x.models = modelsFixture(); }) }));
  const values = (id: string) => { const e = n.get(id)!.edit; return e?.kind === 'choice' ? e.choices.map((c) => c.value) : []; };
  // reviewer 釘了 gpt-5.5（只到 xhigh）：選了 max 子代理就會被 Codex 拒絕，所以不給選
  assert.deepEqual(values('agents/reviewer/effort'), ['inherit', 'low', 'medium', 'high', 'xhigh']);
  // implementer 是 inherit → 跟主對話的 gpt-big，它支援到 ultra；Codex 新增、schema 還不認得的 hyper 也要能選
  assert.ok(values('agents/implementer/effort').includes('ultra'));
  assert.ok(values('agents/implementer/effort').includes('hyper'), 'Codex 新增的 effort 選不到 —— 要等下一版工作流才能用');
  assert.equal(n.get('agents/implementer/model')!.description, 'inherit（gpt-big）');
  const model = n.get('agents/reviewer/model')!.edit;
  assert.ok(model?.kind === 'text');
  if (model?.kind === 'text') {
    assert.deepEqual(model.suggestions.map((x) => x.value), ['inherit', 'gpt-big', 'gpt-5.5'], '隱藏的模型被列成可以選的，或沒用這台的清單');
    assert.match(model.suggestions[1].description, /ultra/);
  }
});

test('doctor 說這台跑不起來 → 那個 agent 標紅、說會起不來；值已經改了（doctor 還沒回來）就不拿舊結論標', () => {
  const problem = { agent: 'sa-analyst', model: 'inherit', effort: 'high', effectiveModel: 'gpt-x', status: 'effort-unsupported', level: 'problem', message: 'gpt-x 只支援 low —— sa-analyst 會起不來（Codex 拒絕這次 spawn）', suggestion: 'agents.sa-analyst.effort=low', allowed: ['low'] };
  const n = nodes(input({ doctor: doctor((x) => { x.models = modelsFixture([problem]); }) }));
  assert.equal(n.get('agents/sa-analyst')!.tone, 'error');
  assert.equal(n.get('agents/sa-analyst')!.description, 'high · 跑不起來');
  assert.equal(n.get('agents/sa-analyst')!.iconFile, 'effort-high-error', '跑不起來時訊號格要換成異常色');
  assert.equal(n.get('agents/sa-analyst/effort')!.tone, 'error');
  assert.match(n.get('agents/sa-analyst/effort')!.description!, /sa-analyst 會起不來/);
  const stale = nodes(input({ doctor: doctor((x) => { x.models = modelsFixture([{ ...problem, effort: 'xhigh' }]); }) }));
  assert.notEqual(stale.get('agents/sa-analyst')!.tone, 'error', '拿別組值的結論標在現在這組值上');
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
  assert.equal(n.get('agents/implementer')!.tone, 'pending');
  assert.match(n.get('agents/implementer')!.tooltip!, /未套用/);
  assert.notEqual(n.get('agents/sa-analyst')!.tone, 'pending');
});

test('都套用了 → 沒有「套用」按鈕，寫明已套用', () => {
  const agents = nodes(input()).get('agents')!;
  assert.equal(agents.contextValue, undefined);
  assert.equal(agents.description, '已套用');
});

test('orchestrator 說清楚「只是記錄，強制不了」', () => {
  const o = nodes(input()).get('agents/orchestrator')!;
  assert.match(o.description!, /只是記錄/);
  assert.match(o.tooltip!, /只是記錄，強制不了/);
});

test('工作流太舊（沒有 set／schema）→ 只顯示、不給改，並說要升到哪一版', () => {
  const n = nodes(input({ canEdit: false, schema: undefined, workflowVersion: '4.8.0', editBlockedReason: '升到 4.9.0 以上才能在這裡改' }));
  assert.ok([...n.values()].every((x) => !x.edit && x.contextValue !== 'editable'), '不能改的專案出現了修改按鈕');
  assert.match(n.get('agents/blocked')!.label, /4\.9\.0/);
  assert.match(n.get('agents/reviewer')!.description!, /^medium · gpt-5\.5/, '不能改也要看得到值');
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

test('有新版 → 那一行點下去是升級（不是只看說明）；沒有新版就沒有升級按鈕', () => {
  const n = nodes(input({ doctor: doctor((x) => { x.update = { ...x.update, cached: true, newer: true, latest: '4.16.0' }; }) }));
  const u = n.get('status/update')!;
  assert.match(u.label, /4\.16\.0/);
  assert.equal(u.command?.command, 'codexSdlc.upgrade');
  const none = nodes(input({ doctor: doctor((x) => { x.update = { ...x.update, cached: true, newer: false, latest: '4.9.0' }; }) }));
  assert.notEqual(none.get('status/update')!.command?.command, 'codexSdlc.upgrade');
});

test('連不到發佈頁，但 extension 內附的比專案新 → 一樣提示可以升，點下去是升級', () => {
  const offline = doctor((x) => { x.update = { ...x.update, cached: false, newer: false, latest: null }; });
  const m = (payloadVersion?: string) => ({ pwsh: { ok: true, path: 'C:/pwsh/pwsh.exe' }, extensionVersion: payloadVersion ?? '4.16.0', payloadVersion });
  const u = nodes(input({ workflowVersion: '4.16.0', doctor: offline, machine: m('4.16.1') })).get('status/update')!;
  assert.match(u.label, /4\.16\.1/);
  assert.equal(u.command?.command, 'codexSdlc.upgrade');
  assert.match(u.description ?? '', /內附/);
  // 內附的跟專案一樣或更舊 → 不提示（升級會被當成沒東西可升或降級擋下）
  for (const same of ['4.16.0', '4.15.1', undefined]) {
    const n = nodes(input({ workflowVersion: '4.16.0', doctor: offline, machine: m(same) })).get('status/update')!;
    assert.notEqual(n.command?.command, 'codexSdlc.upgrade', `內附 ${same} 卻提示升級`);
  }
});

test('upgradeOffer：發佈頁與內附都比專案新 → 講較新的那一個', () => {
  const remote = (latest: string) => doctor((x) => { x.update = { ...x.update, cached: true, newer: true, latest }; });
  assert.deepEqual(upgradeOffer({ doctor: remote('4.17.0'), workflowVersion: '4.16.0', payloadVersion: '4.16.1' }), { version: '4.17.0', from: 'remote' });
  assert.deepEqual(upgradeOffer({ doctor: remote('4.16.1'), workflowVersion: '4.16.0', payloadVersion: '4.16.2' }), { version: '4.16.2', from: 'bundled' });
  assert.deepEqual(upgradeOffer({ doctor: remote('4.16.1'), workflowVersion: '4.16.0', payloadVersion: '4.16.1' }), { version: '4.16.1', from: 'remote' });
  assert.equal(upgradeOffer({ doctor: undefined, workflowVersion: undefined, payloadVersion: '4.16.1' }), undefined);
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
  assert.equal(t.label, '1 項建議：reviewer → high');
  assert.equal(t.contextValue, 'tuneProposal', '沒有行內「採用」');
  assert.deepEqual(t.data, ['C:/work/shop', ['reviewer']], '採用的範圍不是只有跟現值不同的那幾個');
  assert.equal(nodes(input()).get('agents/tune')!.label, '依 repo 現況給建議');
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
  assert.match(n.get('agents/reviewer')!.description!, /^跟隨 · 跟隨主對話/);
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
