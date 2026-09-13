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
const strict_1 = __importDefault(require("node:assert/strict"));
const node_test_1 = require("node:test");
const tuning_1 = require("../src/tuning");
const withComments = [
    '{',
    '    // 團隊約定：reviewer 一律 high',
    '    "workflow-version": "4.8.0",',
    '    "agents": {',
    '        "sa-analyst": { "model": "inherit", "effort": "inherit" }, /* 大 repo 別動 */',
    '        "reviewer":   { "model": "inherit", "effort": "medium" }',
    '    }',
    '}',
    '',
].join('\n');
(0, node_test_1.test)('只改那一個值：註解、縮排、其他欄位一個字不動', () => {
    const after = (0, tuning_1.setAgentValue)(withComments, 'reviewer', 'effort', 'high');
    strict_1.default.equal(after, withComments.replace('"effort": "medium"', '"effort": "high"'));
});
(0, node_test_1.test)('設定檔裡還沒有那個 agent（升級新增的）→ 補上，其餘不動', () => {
    const after = (0, tuning_1.setAgentValue)(withComments, 'implementer', 'effort', 'low');
    strict_1.default.ok(after.includes('// 團隊約定：reviewer 一律 high'), '註解被吃掉了');
    strict_1.default.deepEqual((0, tuning_1.readAgents)(after).find((a) => a.name === 'implementer'), { name: 'implementer', model: 'inherit', effort: 'low' });
});
(0, node_test_1.test)('沒寫的值讀成 inherit', () => {
    strict_1.default.deepEqual((0, tuning_1.readAgents)('{ "agents": { "reviewer": {} } }'), [{ name: 'reviewer', model: 'inherit', effort: 'inherit' }]);
});
(0, node_test_1.test)('壞掉的 JSON 不動它', () => {
    strict_1.default.throws(() => (0, tuning_1.setAgentValue)('{ "agents": ', 'reviewer', 'effort', 'high'), /解析不了/);
});
(0, node_test_1.test)('保留 CRLF', () => {
    const crlf = '{\r\n  "agents": {\r\n    "reviewer": { "effort": "medium" }\r\n  }\r\n}\r\n';
    const after = (0, tuning_1.setAgentValue)(crlf, 'reviewer', 'effort', 'high');
    strict_1.default.equal(after, crlf.replace('medium', 'high'));
});
(0, node_test_1.test)('修正輪上限：只改 review.maxRounds，註解與其他值不動；沒有這一節就補上', async () => {
    const { readReviewMaxRounds, setReviewMaxRounds } = await Promise.resolve().then(() => __importStar(require('../src/tuning')));
    const withReview = withComments.replace('"workflow-version": "4.8.0",', '"workflow-version": "4.8.0",\n    "review": { "maxRounds": 3 },');
    const after = setReviewMaxRounds(withReview, 5);
    strict_1.default.equal(after, withReview.replace('"maxRounds": 3', '"maxRounds": 5'));
    strict_1.default.equal(readReviewMaxRounds(after), 5);
    const added = setReviewMaxRounds(withComments, 2);
    strict_1.default.ok(added.includes('// 團隊約定：reviewer 一律 high'), '補 review 時註解被吃掉了');
    strict_1.default.equal(readReviewMaxRounds(added), 2);
    strict_1.default.equal(readReviewMaxRounds(withComments), undefined);
});
(0, node_test_1.test)('修正輪上限一定寫成整數（字串 "3" hook 不採用）', async () => {
    const { setReviewMaxRounds } = await Promise.resolve().then(() => __importStar(require('../src/tuning')));
    strict_1.default.throws(() => setReviewMaxRounds('{ "agents": {} }', 2.5), /整數/);
    strict_1.default.match(setReviewMaxRounds('{ "agents": {} }', 4), /"maxRounds": 4\b/);
});
