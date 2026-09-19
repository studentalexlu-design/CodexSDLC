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
// 面板的選項從專案裡的 schema 來。這一組守兩件事：讀得懂**真的那一份** schema、形狀不對時明講而不是猜。
const strict_1 = __importDefault(require("node:assert/strict"));
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const node_test_1 = require("node:test");
const contract_1 = require("../src/contract");
const schema_1 = require("../src/schema");
const repo = path.resolve(__dirname, '..', '..', '..');
const real = fs.readFileSync(path.join(repo, '.codex/bdd-workflow/sdlc.config.schema.json'), 'utf8');
(0, node_test_1.test)('真的 schema：effort、修正輪、更新檢查的選項都讀得出來', () => {
    const s = (0, schema_1.parseSettingsSchema)(real);
    strict_1.default.equal(s.effort.choices[0].value, 'inherit', 'inherit 要排第一個 —— 它是每個 agent 的預設');
    strict_1.default.ok(s.effort.choices.every((c) => c.description.length > 0), '每個 effort 選項都要有說明');
    strict_1.default.deepEqual([s.reviewRounds.min, s.reviewRounds.max, s.reviewRounds.default], [1, 5, 3]);
    strict_1.default.deepEqual(s.updateCheck.choices.map((c) => [c.value, c.label]), [['daily', '每天'], ['never', '不檢查']]);
    strict_1.default.ok(s.model.examples.includes('inherit'));
});
(0, node_test_1.test)('某個 agent 的 effort 選項會疊上 schema 給它的提醒（sa-analyst 不要 high）', () => {
    const s = (0, schema_1.parseSettingsSchema)(real);
    const sa = (0, schema_1.effortChoicesFor)(s, 'sa-analyst').find((c) => c.value === 'high');
    strict_1.default.match(sa.description, /^⚠.*逾時/);
    const other = (0, schema_1.effortChoicesFor)(s, 'implementer').find((c) => c.value === 'high');
    strict_1.default.doesNotMatch(other.description, /逾時/, '提醒不該漏到別的 agent 身上');
});
(0, node_test_1.test)('schema 缺了面板要的值 → ContractError，說得出缺哪一個', () => {
    const broken = JSON.parse(real);
    delete broken.properties.review.properties.maxRounds.maximum;
    strict_1.default.throws(() => (0, schema_1.parseSettingsSchema)(JSON.stringify(broken)), (e) => e instanceof contract_1.ContractError && /maxRounds\.maximum/.test(e.message));
    const noEnum = JSON.parse(real);
    noEnum.definitions.effort.enum = 'inherit';
    strict_1.default.throws(() => (0, schema_1.parseSettingsSchema)(JSON.stringify(noEnum)), /effort\.enum/);
    strict_1.default.throws(() => (0, schema_1.parseSettingsSchema)('{ not json'), contract_1.ContractError);
});
(0, node_test_1.test)('只是說明文字缺了 → 照樣能用（不因為少一句話就讓整個面板不能改）', () => {
    const lean = JSON.parse(real);
    delete lean.definitions.effort.enumDescriptions;
    delete lean.properties.update.properties.check['x-labels'];
    const s = (0, schema_1.parseSettingsSchema)(JSON.stringify(lean));
    strict_1.default.equal(s.effort.choices[0].description, '');
    strict_1.default.equal(s.updateCheck.choices[0].label, 'daily');
});
(0, node_test_1.test)('輸入框的即時提示用 schema 的 pattern（寫不寫得進去仍由 set 判）', () => {
    const s = (0, schema_1.parseSettingsSchema)(real);
    strict_1.default.ok((0, schema_1.matchesPattern)(s.updateSource.pattern, 'https://github.com/owner/repo.git'));
    strict_1.default.ok(!(0, schema_1.matchesPattern)(s.updateSource.pattern, 'https://example.com/x'));
    strict_1.default.ok(!(0, schema_1.matchesPattern)(s.model.pattern, 'gpt 5'));
    strict_1.default.ok((0, schema_1.matchesPattern)(undefined, 'anything'));
    strict_1.default.ok((0, schema_1.matchesPattern)('([', 'x'), 'pattern 本身壞掉時不擋人，交給 set 判');
});
