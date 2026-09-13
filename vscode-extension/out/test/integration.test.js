"use strict";
// 拿**真的** sdlc.ps1 與 gate（這個 repo 工作區裡的那一份）裝進一個暫存專案，再用 extension 的解析去讀。
// 這是兩個語言之間的合約測試：PowerShell 那邊改了欄位名，這裡紅；extension 這邊讀錯欄位，這裡也紅。
// 也是計畫 M1／M1.5 的驗收：狀態列出現版本、改設定不 apply 立刻看到漂移、apply 之後 doctor 是綠的。
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
const fs = __importStar(require("node:fs"));
const os = __importStar(require("node:os"));
const path = __importStar(require("node:path"));
const node_test_1 = require("node:test");
const contract_1 = require("../src/contract");
const diagnostics_1 = require("../src/diagnostics");
const pwsh_1 = require("../src/pwsh");
const status_1 = require("../src/status");
const tuning_1 = require("../src/tuning");
const repo = path.resolve(__dirname, '..', '..', '..');
const pw = (0, pwsh_1.resolvePwsh)({ env: process.env, platform: process.platform, exists: (p) => { try {
        return fs.statSync(p).isFile();
    }
    catch {
        return false;
    } } });
let project = '';
let editorHome = '';
async function sdlc(command, params = []) {
    strict_1.default.ok(pw.ok, 'integration test 需要 pwsh 7');
    const script = path.join(project, '.codex/scripts/sdlc.ps1');
    // doctor 一律隔離：不問這台機器上的 codex、不看這台機器上真正裝的 extension。
    const isolate = command === 'doctor' ? ['-CodexPath', path.join(project, 'no-such-codex.exe'), '-EditorHome', editorHome] : [];
    const r = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.fileArgs)(script, [command, '-Target', project, '-Json', ...isolate, ...params]), { cwd: project, timeoutMs: 120_000 });
    strict_1.default.equal(r.spawnError, undefined);
    return (0, contract_1.parseEnvelope)(r.stdout, command);
}
async function gate(rel, files, extra = []) {
    strict_1.default.ok(pw.ok);
    const r = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.encodedCommandArgs)((0, pwsh_1.gateInvocation)(path.join(project, rel), files, extra)), { cwd: project, timeoutMs: 60_000 });
    return r.stdout;
}
(0, node_test_1.before)(async () => {
    strict_1.default.ok(pw.ok, `integration test 需要 pwsh 7：${pw.ok ? '' : pw.message}`);
    project = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-sdlc-ext-'));
    editorHome = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-sdlc-ext-home-'));
    const r = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.fileArgs)(path.join(repo, '.codex/scripts/sdlc.ps1'), ['install', '-Source', repo, '-Target', project, '-Json']), { cwd: repo, timeoutMs: 180_000 });
    const env = (0, contract_1.parseEnvelope)(r.stdout, 'install');
    strict_1.default.equal(env.exit, 0, `install 失敗：${env.warnings.join(' | ')}`);
});
(0, node_test_1.after)(() => {
    for (const d of [project, editorHome])
        if (d)
            fs.rmSync(d, { recursive: true, force: true });
});
(0, node_test_1.test)('doctor 的真實輸出讀得懂，狀態列出現版本', async () => {
    const d = (0, contract_1.parseDoctor)(await sdlc('doctor'));
    const ver = JSON.parse(fs.readFileSync(path.join(repo, '.codex/bdd-workflow/bdd-workflow-version.json'), 'utf8'))['contract-version'];
    strict_1.default.equal(d.version.contract, ver);
    const view = (0, status_1.statusFromDoctor)(d, new Date());
    strict_1.default.match(view.text, new RegExp(`SDLC ${ver.replace(/\./g, '\\.')}`));
    strict_1.default.equal(d.tuning.status, 'in-sync');
    strict_1.default.equal(d.problems, 0, `全新安裝的專案 doctor 應該是綠的：${JSON.stringify(d.guidelines)}`);
});
(0, node_test_1.test)('改 sdlc.config.json 不 apply → 立刻看到漂移；apply 之後 doctor 是綠的（M1.5 驗收）', async () => {
    const cfg = path.join(project, 'sdlc.config.json');
    fs.writeFileSync(cfg, (0, tuning_1.setAgentValue)(fs.readFileSync(cfg, 'utf8'), 'reviewer', 'effort', 'high'));
    const stale = (0, contract_1.parseDoctor)(await sdlc('doctor'));
    strict_1.default.equal(stale.tuning.status, 'stale');
    strict_1.default.deepEqual(stale.tuning.stale, ['reviewer.toml']);
    strict_1.default.match((0, status_1.statusFromDoctor)(stale, new Date()).text, /調校未套用/);
    const applied = (0, contract_1.parseApply)(await sdlc('apply'));
    strict_1.default.deepEqual(applied.changed, ['reviewer.toml']);
    const fresh = (0, contract_1.parseDoctor)(await sdlc('doctor'));
    strict_1.default.equal(fresh.tuning.status, 'in-sync');
    strict_1.default.match(fs.readFileSync(path.join(project, '.codex/agents/reviewer.toml'), 'utf8'), /model_reasoning_effort = "high"/);
});
(0, node_test_1.test)('guideline-gate 的違規進得了 Problems：行號、規則、中文訊息原樣', async () => {
    fs.mkdirSync(path.join(project, 'src'), { recursive: true });
    fs.writeFileSync(path.join(project, 'src/q.sql'), 'SELECT 1\nSELECT Id FROM Orders WITH (NOLOCK)\n');
    const o = (0, diagnostics_1.guidelineOutcome)((0, contract_1.parseGuidelineGate)(await gate('.codex/scripts/guideline-gate.ps1', ['src/q.sql'], ['-MaxReport', '500'])));
    const hit = o.records.find((r) => r.code === 'sql-no-nolock');
    strict_1.default.ok(hit, JSON.stringify(o));
    strict_1.default.equal(hit.line, 2);
    strict_1.default.equal(hit.severity, 'error');
    strict_1.default.match(hit.message, /禁止 NOLOCK/, 'gate 的 UTF-8 輸出在 Node 這一側被解碼壞了');
});
(0, node_test_1.test)('dlp-gate 的殘留進得了 Problems，而且沒有原始值', async () => {
    fs.mkdirSync(path.join(project, 'bdd-docs/f1'), { recursive: true });
    fs.writeFileSync(path.join(project, 'bdd-docs/f1/notes.md'), '第一行\n客戶 carol@contoso.com 反映結帳失敗\n');
    const out = await gate('.codex/scripts/dlp-gate.ps1', ['bdd-docs/f1/notes.md', 'src/q.sql']);
    strict_1.default.doesNotMatch(out, /carol/);
    const o = (0, diagnostics_1.dlpOutcome)((0, contract_1.parseDlpGate)(out));
    strict_1.default.deepEqual(o.records.map((r) => [r.file, r.line, r.code]), [['bdd-docs/f1/notes.md', 2, 'dlp-email']]);
});
(0, node_test_1.test)('tune／whatsnew／check-update 的真實輸出讀得懂；update.check = never 不連網', async () => {
    const t = (0, contract_1.parseTune)(await sdlc('tune'));
    strict_1.default.ok(t.proposal.some((p) => p.agent === 'reviewer'));
    const w = (0, contract_1.parseWhatsNew)(await sdlc('whatsnew'));
    strict_1.default.equal(w.source, 'installed');
    strict_1.default.ok(w.text.length > 0);
    const cfg = path.join(project, 'sdlc.config.json');
    const json = JSON.parse(fs.readFileSync(cfg, 'utf8'));
    json.update.check = 'never';
    fs.writeFileSync(cfg, JSON.stringify(json, null, 2));
    const c = (0, contract_1.parseCheckUpdate)(await sdlc('check-update', ['-IfDue']));
    strict_1.default.equal(c.status, 'disabled');
});
(0, node_test_1.test)('修正輪上限：extension 寫進去的值，doctor 與 handoff-lint 都照它算', async () => {
    const { setReviewMaxRounds } = await Promise.resolve().then(() => __importStar(require('../src/tuning')));
    const cfg = path.join(project, 'sdlc.config.json');
    fs.writeFileSync(cfg, setReviewMaxRounds(fs.readFileSync(cfg, 'utf8'), 5));
    const d = (0, contract_1.parseDoctor)(await sdlc('doctor'));
    strict_1.default.deepEqual(d.review, { maxRounds: 5, source: 'config', valid: true });
    strict_1.default.ok(pw.ok);
    const handoff = '## meta\n- feature-id: f1\n- mode: fix\n- round: 5\n\n## target\n- spec: bdd-docs/f1/spec.md\n';
    // hook 讀的是行程的 stdin（Codex 就是這樣餵的），不是 PowerShell 管線 —— 這裡直接用 -Payload。
    const r = await (0, pwsh_1.runPwsh)(pw.path, (0, pwsh_1.encodedCommandArgs)(`& '${path.join(project, '.codex/scripts/handoff-lint.ps1')}' -Payload '${handoff.replace(/'/g, "''")}' -Json; exit $LASTEXITCODE`), { cwd: project, timeoutMs: 60_000 });
    const j = JSON.parse(r.stdout.trim());
    strict_1.default.equal(r.exit, 0, `設了 5 卻擋下第 5 輪：${r.stdout}`);
    strict_1.default.equal(j.max_review_rounds, 5);
});
