"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
// 設定面板的樹。每一條守的是「畫面跟真相對不上」的一種：看到的值不是檔裡的、該標未套用沒標、不該改的給改。
const strict_1 = __importDefault(require("node:assert/strict"));
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const node_test_1 = require("node:test");
const config_1 = require("../src/config");
const contract_1 = require("../src/contract");
const schema_1 = require("../src/schema");
const tree_1 = require("../src/tree");
const fixtures_1 = require("./fixtures");
const repo = path.resolve(__dirname, '..', '..', '..');
const schema = (0, schema_1.parseSettingsSchema)(fs.readFileSync(path.join(repo, '.codex/bdd-workflow/sdlc.config.schema.json'), 'utf8'));
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
function doctor(mutate = () => { }) {
    const data = (0, fixtures_1.doctorFixture)();
    data.version.contract = '4.9.0';
    data.review = { maxRounds: 4, source: 'config', valid: true };
    mutate(data);
    return (0, contract_1.parseDoctor)((0, contract_1.parseEnvelope)(JSON.stringify({ schema: contract_1.SUPPORTED_SCHEMA, command: 'doctor', exit: 0, data, warnings: [], output: [] }), 'doctor'));
}
function input(over = {}) {
    return {
        rootName: 'shop', rootPath: 'C:/work/shop', workflowVersion: '4.9.0', schema, canEdit: true,
        config: (0, config_1.readConfig)(configText), knownAgents: [], doctor: doctor(), checking: false, pendingAgents: [],
        guidelines: { dir: true, files: ['README.md', 'coding.md', 'rules.json', 'sql.md'], rulesExists: true, ruleCount: 8, gateDisabled: false },
        machine: { pwsh: { ok: true, path: 'C:/pwsh/pwsh.exe' }, codex: { source: 'path', path: 'C:/bin/codex.exe' }, extensionVersion: '4.9.0' },
        ...over,
    };
}
const nodes = (i) => new Map((0, tree_1.flatten)((0, tree_1.buildSettingsTree)(i)).map((n) => [n.id, n]));
(0, node_test_1.test)('六個區段，順序固定（人找東西靠位置）', () => {
    strict_1.default.deepEqual((0, tree_1.buildSettingsTree)(input()).map((n) => n.label), ['狀態', 'Agent 調校', '審核', '更新', '規範', '這台機器']);
});
(0, node_test_1.test)('ID 不重複（VS Code 的樹靠它記住展開狀態，重複會直接丟錯）', () => {
    const all = (0, tree_1.flatten)((0, tree_1.buildSettingsTree)(input({ pendingAgents: ['reviewer'], proposal: [{ agent: 'reviewer', effort: 'high', reason: 'r' }] })));
    strict_1.default.equal(new Set(all.map((n) => n.id)).size, all.length);
});
(0, node_test_1.test)('看到的值就是設定檔裡的值', () => {
    const n = nodes(input());
    strict_1.default.match(n.get('agents/reviewer').description, /effort medium · model gpt-5\.5/);
    strict_1.default.equal(n.get('agents/reviewer/model').description, 'gpt-5.5 · 未驗證');
    strict_1.default.match(n.get('review/maxRounds').description, /^4 輪 · 下一次委派就生效/);
    strict_1.default.equal(n.get('update/check').description, '每天');
    strict_1.default.match(n.get('update/source').description, /未設定/);
});
(0, node_test_1.test)('每個可改的值都帶著 set 用的 key 與 schema 的選項', () => {
    const n = nodes(input());
    const effort = n.get('agents/sa-analyst/effort');
    strict_1.default.equal(effort.contextValue, 'editable');
    strict_1.default.equal(effort.command?.command, 'codexSdlc.editSetting');
    strict_1.default.equal(effort.edit?.kind, 'choice');
    strict_1.default.equal(effort.edit?.key, 'agents.sa-analyst.effort');
    if (effort.edit?.kind === 'choice') {
        strict_1.default.deepEqual(effort.edit.choices.map((c) => c.value), schema.effort.choices.map((c) => c.value), '選項不是從 schema 來的');
    }
    const rounds = n.get('review/maxRounds').edit;
    strict_1.default.equal(rounds.key, 'review.maxRounds');
    if (rounds.kind === 'choice')
        strict_1.default.deepEqual(rounds.choices.map((c) => c.value), ['1', '2', '3', '4', '5']);
    strict_1.default.equal(n.get('update/source').edit?.kind, 'text');
});
(0, node_test_1.test)('sa-analyst 釘 high → 那一行直接標警告（逾時的成因）', () => {
    const n = nodes(input());
    strict_1.default.equal(n.get('agents/sa-analyst/effort').tone, 'warn');
    strict_1.default.match(n.get('agents/sa-analyst/effort').description, /逾時/);
});
(0, node_test_1.test)('未套用：doctor 說的 ∪ 剛寫、doctor 還沒回來的；orchestrator 永遠不算', () => {
    const d = doctor((x) => { x.tuning = { status: 'stale', stale: ['reviewer.toml'] }; });
    strict_1.default.deepEqual((0, tree_1.pendingAgentsOf)({ doctor: d, pendingAgents: ['implementer', 'orchestrator'] }), ['implementer', 'reviewer']);
    const n = nodes(input({ doctor: d, pendingAgents: ['implementer'] }));
    const agents = n.get('agents');
    strict_1.default.equal(agents.contextValue, 'tuningPending', '沒有「套用」按鈕');
    strict_1.default.equal(agents.description, '2 項未套用');
    strict_1.default.match(n.get('agents/implementer').description, /未套用/);
    strict_1.default.doesNotMatch(n.get('agents/sa-analyst').description, /未套用/);
});
(0, node_test_1.test)('都套用了 → 沒有「套用」按鈕，寫明已套用', () => {
    const agents = nodes(input()).get('agents');
    strict_1.default.equal(agents.contextValue, undefined);
    strict_1.default.equal(agents.description, '已套用');
});
(0, node_test_1.test)('orchestrator 說清楚「只是記錄，強制不了」', () => {
    strict_1.default.match(nodes(input()).get('agents/orchestrator').description, /只是記錄，強制不了/);
});
(0, node_test_1.test)('工作流太舊（沒有 set／schema）→ 只顯示、不給改，並說要升到哪一版', () => {
    const n = nodes(input({ canEdit: false, schema: undefined, workflowVersion: '4.8.0', editBlockedReason: '升到 4.9.0 以上才能在這裡改' }));
    strict_1.default.ok([...n.values()].every((x) => !x.edit && x.contextValue !== 'editable'), '不能改的專案出現了修改按鈕');
    strict_1.default.match(n.get('agents/blocked').label, /4\.9\.0/);
    strict_1.default.match(n.get('agents/reviewer').description, /effort medium/, '不能改也要看得到值');
});
(0, node_test_1.test)('hooks 沒信任 → 那一行紅、帶「在終端機信任」；找不到 codex → 帶「選擇 codex」', () => {
    const untrusted = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'untrusted', codex: 'c', counts: { total: 4, trusted: 2, untrusted: 1, modified: 1, disabled: 0 } }; }) }));
    const h = untrusted.get('status/hooks');
    strict_1.default.equal(h.tone, 'error');
    strict_1.default.equal(h.contextValue, 'hooksUntrusted');
    strict_1.default.equal(h.command?.command, 'codexSdlc.trustHooks');
    strict_1.default.match(h.label, /1 條未信任、1 條改過待重審/);
    strict_1.default.ok(![...untrusted.keys()].some((k) => k.startsWith('status/issues/') && /信任/.test(untrusted.get(k).label)), 'hooks 的問題重複列了兩次');
    const unknown = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'unknown', reason: 'codex-not-found', codex: null }; }) })).get('status/hooks');
    strict_1.default.equal(unknown.contextValue, 'hooksUnknown');
    strict_1.default.equal(unknown.command?.command, 'codexSdlc.pickCodex');
    strict_1.default.notEqual(unknown.tone, 'ok', '查不到不能顯示成綠的');
});
(0, node_test_1.test)('doctor 的其他問題列在「需要處理」底下', () => {
    const n = nodes(input({ doctor: doctor((x) => { x.config.comments = true; x.problems = 0; }) }));
    const issues = n.get('status/issues');
    strict_1.default.equal(issues.children.length, 1);
    strict_1.default.match(issues.children[0].label, /註解/);
});
(0, node_test_1.test)('修正輪寫壞 → 說照預設幾輪算', () => {
    const n = nodes(input({ doctor: doctor((x) => { x.review = { maxRounds: 3, source: 'default', valid: false }; }), config: (0, config_1.readConfig)(configText.replace('"maxRounds":4', '"maxRounds":"4"')) }));
    const r = n.get('review/maxRounds');
    strict_1.default.equal(r.tone, 'warn');
    strict_1.default.match(r.description, /寫壞了.*照預設 3 輪算/);
});
(0, node_test_1.test)('update.check 不認得的值 → 說會照每天算、會連網', () => {
    const n = nodes(input({ config: (0, config_1.readConfig)(configText.replace('"check":"daily"', '"check":"nevr"')) }));
    strict_1.default.equal(n.get('update/check').tone, 'warn');
    strict_1.default.match(n.get('update/check').description, /nevr.*會連網/);
});
(0, node_test_1.test)('tune 的建議：只算跟現值不一樣的', () => {
    const n = nodes(input({ proposal: [
            { agent: 'reviewer', effort: 'high', reason: '判斷密度高' },
            { agent: 'implementer', effort: 'inherit', reason: '一樣' },
            { agent: 'nobody', effort: 'low', reason: '專案沒有這個 agent' },
        ] }));
    const t = n.get('agents/tune');
    strict_1.default.equal(t.label, 'tune 有 1 項建議');
    strict_1.default.equal(t.description, 'reviewer → high');
    strict_1.default.equal(nodes(input()).get('agents/tune').label, '依 repo 現況給建議…');
});
(0, node_test_1.test)('規範：README 不算規範文件；機械層關著 → 警告並給「打開」', () => {
    const n = nodes(input({ guidelines: { dir: true, files: ['README.md', 'coding.md', 'rules.json'], rulesExists: true, ruleCount: 8, gateDisabled: true } }));
    strict_1.default.equal(n.get('guidelines/docs').description, 'coding');
    strict_1.default.equal(n.get('guidelines/gate').contextValue, 'gateOff');
    strict_1.default.equal(n.get('guidelines/gate').tone, 'warn');
    strict_1.default.match(n.get('guidelines/rules').description, /8 條 · 驗證通過/);
    const invalid = nodes(input({ doctor: doctor((x) => { x.guidelines = [{ level: 'warn', code: 'rules-invalid', text: 'rules.json 有 1 條載入失敗' }]; }) }));
    strict_1.default.equal(invalid.get('guidelines/rules').tone, 'error');
});
(0, node_test_1.test)('沒有 guidelines/ → 一句話，不出現機械層開關', () => {
    const n = nodes(input({ guidelines: { dir: false, files: [], rulesExists: false, gateDisabled: false } }));
    strict_1.default.ok(n.has('guidelines/none'));
    strict_1.default.ok(!n.has('guidelines/gate'));
});
(0, node_test_1.test)('這台機器：找不到 pwsh → 紅，帶「選擇」', () => {
    const n = nodes(input({ machine: { pwsh: { ok: false, message: '找不到 pwsh' }, codex: { source: 'none' }, extensionVersion: '4.9.0' } }));
    strict_1.default.equal(n.get('machine/pwsh').tone, 'error');
    strict_1.default.equal(n.get('machine/pwsh').contextValue, 'machinePwsh');
    strict_1.default.match(n.get('machine/codex').description, /找不到/);
});
(0, node_test_1.test)('設定檔壞了 → 一句話＋開檔，而不是一棵空樹', () => {
    const n = nodes(input({ config: undefined, configError: 'sdlc.config.json 解析不了' }));
    strict_1.default.equal(n.get('agents/error').command?.command, 'codexSdlc.openFile');
});
(0, node_test_1.test)('沒有 sdlc.config.json：照樣列出 agent 讓你改（第一次改就會建檔），並說這是合法狀態', () => {
    const n = nodes(input({ config: undefined, knownAgents: ['implementer', 'reviewer', 'sa-analyst', 'orchestrator'] }));
    strict_1.default.match(n.get('agents/none').description, /全部 inherit/);
    strict_1.default.equal(n.get('agents/none').tone, 'muted', '合法狀態不該顯示成錯誤');
    strict_1.default.equal(n.get('agents/reviewer/effort').edit?.key, 'agents.reviewer.effort', '沒有設定檔就不給改 —— 使用者會被丟回去手動建檔');
    strict_1.default.match(n.get('agents/reviewer').description, /effort inherit/);
    strict_1.default.equal(n.get('review/maxRounds').edit?.key, 'review.maxRounds');
});
(0, node_test_1.test)('沒有 hooks.json → 面板那一行是紅的，並說怎麼補', () => {
    const h = nodes(input({ doctor: doctor((x) => { x.hooks = { status: 'no-hooks', codex: null }; }) })).get('status/hooks');
    strict_1.default.equal(h.tone, 'error');
    strict_1.default.match(h.tooltip, /update/);
});
