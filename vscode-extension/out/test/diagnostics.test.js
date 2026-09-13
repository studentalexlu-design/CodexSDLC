"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const strict_1 = __importDefault(require("node:assert/strict"));
const node_test_1 = require("node:test");
const diagnostics_1 = require("../src/diagnostics");
(0, node_test_1.test)('guideline：block → error、warn → warning，帶規則 id 與修法', () => {
    const o = (0, diagnostics_1.guidelineOutcome)({
        status: 'scanned', files: ['src/q.sql'], problems: [],
        hits: [
            { rule: 'sql-no-nolock', severity: 'block', file: 'src/q.sql', line: 2, message: '禁止 NOLOCK', fix: '改用快照隔離' },
            { rule: 'sql-no-select-star', severity: 'warn', file: 'src/q.sql', line: 5, message: '不要 SELECT *', fix: '' },
        ],
    });
    strict_1.default.equal(o.records[0].severity, 'error');
    strict_1.default.equal(o.records[0].code, 'sql-no-nolock');
    strict_1.default.match(o.records[0].message, /修法：改用快照隔離/);
    strict_1.default.equal(o.records[1].severity, 'warning');
    strict_1.default.equal(o.records[1].message, '不要 SELECT *');
});
(0, node_test_1.test)('guideline：被關掉時留一句話（不是某一行的事，但不能安靜）', () => {
    const o = (0, diagnostics_1.guidelineOutcome)({ status: 'disabled', files: [], problems: [], hits: [] });
    strict_1.default.match(o.note ?? '', /\.gate-disabled/);
});
(0, node_test_1.test)('DLP：每個類別的每一行一筆，訊息只有類別', () => {
    const o = (0, diagnostics_1.dlpOutcome)({ disabled: false, scanned: ['bdd-docs/f/notes.md'], findings: [{ file: 'bdd-docs/f/notes.md', categories: [{ type: 'email', count: 2, lines: [2, 7] }, { type: 'connstring', count: 1, lines: [9] }] }] });
    strict_1.default.deepEqual(o.records.map((r) => [r.line, r.code]), [[2, 'dlp-email'], [7, 'dlp-email'], [9, 'dlp-connstring']]);
});
(0, node_test_1.test)('掃過但乾淨的檔也要出現在分組裡（才清得掉上一次的診斷）', () => {
    const o = (0, diagnostics_1.guidelineOutcome)({ status: 'scanned', files: ['src/a.sql', 'src/b.sql'], problems: [], hits: [{ rule: 'r', severity: 'warn', file: 'src/b.sql', line: 1, message: 'm', fix: '' }] });
    const g = (0, diagnostics_1.groupByFile)(o, ['src/a.sql', 'src/b.sql', 'docs/readme.md']);
    strict_1.default.deepEqual(g.get('src/a.sql'), []);
    strict_1.default.equal(g.get('src/b.sql')?.length, 1);
    strict_1.default.deepEqual(g.get('docs/readme.md'), [], 'gate 沒掃（被排除）的檔也要清掉舊的診斷');
});
