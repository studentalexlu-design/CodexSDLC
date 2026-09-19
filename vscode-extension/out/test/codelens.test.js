"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const strict_1 = __importDefault(require("node:assert/strict"));
const node_test_1 = require("node:test");
const codelens_1 = require("../src/codelens");
const text = [
    '{',
    '  "agents": {',
    '    "sa-analyst": { "model": "inherit", "effort": "inherit" },',
    '    "reviewer": { "model": "inherit", "effort": "medium" }',
    '  }',
    '}',
].join('\n');
const proposal = [
    { agent: 'reviewer', effort: 'high', reason: '判斷密度高' },
    { agent: 'sa-analyst', effort: 'inherit', reason: '規模不大' },
    { agent: 'implementer', effort: 'medium', reason: '檔裡沒有這個 agent' },
];
(0, node_test_1.test)('有未套用 → 檔案最上面一個「套用」；一律有「在設定面板開啟」', () => {
    const l = (0, codelens_1.configLenses)(text, { rootPath: 'R', pendingAgents: ['reviewer'], canEdit: true });
    strict_1.default.deepEqual(l.map((x) => [x.line, x.command]), [[0, 'codexSdlc.apply'], [0, 'codexSdlc.openSettings']]);
    strict_1.default.match(l[0].title, /1 個 agent 未套用/);
    strict_1.default.deepEqual((0, codelens_1.configLenses)(text, { rootPath: 'R', pendingAgents: [], canEdit: true }).map((x) => x.command), ['codexSdlc.openSettings']);
});
(0, node_test_1.test)('tune 的建議掛在那個 agent 上，只給跟現值不一樣的；按下去只套那一個', () => {
    const l = (0, codelens_1.configLenses)(text, { rootPath: 'R', pendingAgents: [], proposal, canEdit: true }).filter((x) => x.command === 'codexSdlc.applyProposalFor');
    strict_1.default.equal(l.length, 1);
    strict_1.default.equal(l[0].line, 3);
    strict_1.default.deepEqual(l[0].arguments, ['R', 'reviewer']);
    strict_1.default.match(l[0].title, /high/);
});
(0, node_test_1.test)('不能改的專案（工作流太舊）→ 不給「採用」', () => {
    const l = (0, codelens_1.configLenses)(text, { rootPath: 'R', pendingAgents: [], proposal, canEdit: false });
    strict_1.default.ok(!l.some((x) => x.command === 'codexSdlc.applyProposalFor'));
});
(0, node_test_1.test)('檔案寫壞了 → 只剩「在設定面板開啟」，不丟例外', () => {
    const l = (0, codelens_1.configLenses)('{ "agents": ', { rootPath: 'R', pendingAgents: [], proposal, canEdit: true });
    strict_1.default.deepEqual(l.map((x) => x.command), ['codexSdlc.openSettings']);
});
