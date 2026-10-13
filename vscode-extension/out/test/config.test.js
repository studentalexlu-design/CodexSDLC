"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const strict_1 = __importDefault(require("node:assert/strict"));
const node_test_1 = require("node:test");
const config_1 = require("../src/config");
const cfg = [
    '{',
    '  "$schema": "./.codex/bdd-workflow/sdlc.config.schema.json",',
    '  "update": { "source": "", "check": "nevr" },',
    '  "review": { "maxRounds": "3" },',
    '  "agents": {',
    '    "orchestrator": { "model": "inherit", "effort": "high" },',
    '    "sa-analyst": { "effort": "low" },',
    '    "reviewer": {',
    '      "model": "gpt-5.5",',
    '      "effort": "high"',
    '    }',
    '  }',
    '}',
].join('\n');
(0, node_test_1.test)('讀出面板要顯示的值；寫壞的值原樣給（對錯由 doctor 判）', () => {
    const c = (0, config_1.readConfig)(cfg);
    strict_1.default.equal(c.hasSchemaRef, true);
    strict_1.default.equal(c.updateCheck, 'nevr');
    strict_1.default.equal(c.reviewMaxRounds, '3', '字串 "3" 要原樣給，面板才說得出它寫壞了');
    strict_1.default.deepEqual(c.agents.map((a) => [a.name, a.effort, a.model]), [
        ['sa-analyst', 'low', 'inherit'],
        ['reviewer', 'high', 'gpt-5.5'],
        ['orchestrator', 'high', 'inherit'],
    ], 'orchestrator 排最後（只是記錄）；沒寫的 model 讀成 inherit');
});
(0, node_test_1.test)('JSON 壞了 → ConfigReadError（面板顯示這一句，不顯示一棵空樹）', () => {
    strict_1.default.throws(() => (0, config_1.readConfig)('{ "agents": '), config_1.ConfigReadError);
});
(0, node_test_1.test)('CodeLens 的位置：agent 那個 key 所在的行', () => {
    strict_1.default.equal((0, config_1.agentLine)(cfg, 'reviewer'), 7);
    strict_1.default.equal((0, config_1.agentLine)(cfg, 'sa-analyst'), 6);
    strict_1.default.equal((0, config_1.agentLine)(cfg, 'nobody'), undefined);
});
const rules = [
    '{',
    '  "rules": [',
    '    { "id": "a", "pattern": "x" },',
    '    {',
    '      "id": "b",',
    '      "pattern": "y",',
    '      "severity": "blok"',
    '    }',
    '  ]',
    '}',
].join('\n');
(0, node_test_1.test)('rules.json 的問題定位到那一條、那個欄位；欄位不存在就停在規則開頭', () => {
    strict_1.default.equal((0, config_1.ruleLine)(rules, 2, 'severity'), 6);
    strict_1.default.equal((0, config_1.ruleLine)(rules, 2, 'fix'), 3);
    strict_1.default.equal((0, config_1.ruleLine)(rules, 1), 2);
    strict_1.default.equal((0, config_1.ruleLine)(rules, 9), undefined);
    strict_1.default.equal((0, config_1.countRules)(rules), 2);
    strict_1.default.equal((0, config_1.countRules)('{}'), undefined);
});
