// 拿**真的** sdlc.ps1 與 gate（這個 repo 工作區裡的那一份）裝進一個暫存專案，再用 extension 的解析去讀。
// 這是兩個語言之間的合約測試：PowerShell 那邊改了欄位名，這裡紅；extension 這邊讀錯欄位，這裡也紅。
// 也是計畫 M1／M1.5 的驗收：狀態列出現版本、改設定不 apply 立刻看到漂移、apply 之後 doctor 是綠的。

import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { after, before, test } from 'node:test';
import { configLenses } from '../src/codelens';
import { readConfig } from '../src/config';
import {
  parseApply, parseCheckUpdate, parseDlpGate, parseDoctor, parseEnvelope, parseGuidelineGate, parseRulesValidation, parseSet, parseTune, parseWhatsNew,
  type Envelope,
} from '../src/contract';
import { dlpOutcome, guidelineOutcome, rulesOutcome } from '../src/diagnostics';
import { encodedCommandArgs, fileArgs, gateInvocation, resolvePwsh, runPwsh } from '../src/pwsh';
import { readSettingsSchema } from '../src/schema';
import { statusFromDoctor } from '../src/status';
import { buildSettingsTree, flatten, type TreeInput } from '../src/tree';

const repo = path.resolve(__dirname, '..', '..', '..');
const pw = resolvePwsh({ env: process.env, platform: process.platform, exists: (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } } });
let project = '';
let editorHome = '';

async function sdlc(command: string, params: string[] = []): Promise<Envelope> {
  assert.ok(pw.ok, 'integration test 需要 pwsh 7');
  const script = path.join(project, '.codex/scripts/sdlc.ps1');
  // doctor 一律隔離：不問這台機器上的 codex、不看這台機器上真正裝的 extension。
  const isolate = command === 'doctor' ? ['-CodexPath', path.join(project, 'no-such-codex.exe'), '-EditorHome', editorHome] : [];
  const r = await runPwsh(pw.path, fileArgs(script, [command, '-Target', project, '-Json', ...isolate, ...params]), { cwd: project, timeoutMs: 120_000 });
  assert.equal(r.spawnError, undefined);
  return parseEnvelope(r.stdout, command);
}

async function gate(rel: string, files: string[], extra: string[] = []): Promise<string> {
  assert.ok(pw.ok);
  const r = await runPwsh(pw.path, encodedCommandArgs(gateInvocation(path.join(project, rel), files, extra)), { cwd: project, timeoutMs: 60_000 });
  return r.stdout;
}

before(async () => {
  assert.ok(pw.ok, `integration test 需要 pwsh 7：${pw.ok ? '' : pw.message}`);
  project = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-sdlc-ext-'));
  editorHome = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-sdlc-ext-home-'));
  const r = await runPwsh(pw.path, fileArgs(path.join(repo, '.codex/scripts/sdlc.ps1'), ['install', '-Source', repo, '-Target', project, '-Json']), { cwd: repo, timeoutMs: 180_000 });
  const env = parseEnvelope(r.stdout, 'install');
  assert.equal(env.exit, 0, `install 失敗：${env.warnings.join(' | ')}`);
});

after(() => {
  for (const d of [project, editorHome]) if (d) fs.rmSync(d, { recursive: true, force: true });
});

test('doctor 的真實輸出讀得懂，狀態列出現版本', async () => {
  const d = parseDoctor(await sdlc('doctor'));
  const ver = JSON.parse(fs.readFileSync(path.join(repo, '.codex/bdd-workflow/bdd-workflow-version.json'), 'utf8'))['contract-version'];
  assert.equal(d.version.contract, ver);
  const view = statusFromDoctor(d, new Date());
  assert.match(view.text, new RegExp(`SDLC ${ver.replace(/\./g, '\\.')}`));
  assert.equal(d.tuning.status, 'in-sync');
  assert.equal(d.problems, 0, `全新安裝的專案 doctor 應該是綠的：${JSON.stringify(d.guidelines)}`);
});

test('set 不 apply → 立刻看到漂移；apply 之後 doctor 是綠的（M1.5 驗收，寫檔改走 set）', async () => {
  const w = parseSet(await sdlc('set', ['agents.reviewer.effort=high']));
  assert.equal(w.error, null);
  assert.equal(w.written, true);
  assert.equal(w.applied, false);
  assert.deepEqual(w.changes.map((c) => [c.key, c.to, c.changed, c.needsApply]), [['agents.reviewer.effort', 'high', true, true]]);

  const stale = parseDoctor(await sdlc('doctor'));
  assert.equal(stale.tuning.status, 'stale');
  assert.deepEqual(stale.tuning.stale, ['reviewer.toml']);
  assert.match(statusFromDoctor(stale, new Date()).text, /調校未套用/);

  const applied = parseApply(await sdlc('apply'));
  assert.deepEqual(applied.changed, ['reviewer.toml']);

  const fresh = parseDoctor(await sdlc('doctor'));
  assert.equal(fresh.tuning.status, 'in-sync');
  assert.match(fs.readFileSync(path.join(project, '.codex/agents/reviewer.toml'), 'utf8'), /model_reasoning_effort = "high"/);
});

test('guideline-gate 的違規進得了 Problems：行號、規則、中文訊息原樣', async () => {
  fs.mkdirSync(path.join(project, 'src'), { recursive: true });
  fs.writeFileSync(path.join(project, 'src/q.sql'), 'SELECT 1\nSELECT Id FROM Orders WITH (NOLOCK)\n');
  const o = guidelineOutcome(parseGuidelineGate(await gate('.codex/scripts/guideline-gate.ps1', ['src/q.sql'], ['-MaxReport', '500'])));
  const hit = o.records.find((r) => r.code === 'sql-no-nolock');
  assert.ok(hit, JSON.stringify(o));
  assert.equal(hit.line, 2);
  assert.equal(hit.severity, 'error');
  assert.match(hit.message, /禁止 NOLOCK/, 'gate 的 UTF-8 輸出在 Node 這一側被解碼壞了');
});

test('dlp-gate 的殘留進得了 Problems，而且沒有原始值', async () => {
  fs.mkdirSync(path.join(project, 'bdd-docs/f1'), { recursive: true });
  fs.writeFileSync(path.join(project, 'bdd-docs/f1/notes.md'), '第一行\n客戶 carol@contoso.com 反映結帳失敗\n');
  const out = await gate('.codex/scripts/dlp-gate.ps1', ['bdd-docs/f1/notes.md', 'src/q.sql']);
  assert.doesNotMatch(out, /carol/);
  const o = dlpOutcome(parseDlpGate(out));
  assert.deepEqual(o.records.map((r) => [r.file, r.line, r.code]), [['bdd-docs/f1/notes.md', 2, 'dlp-email']]);
});

test('tune／whatsnew／check-update 的真實輸出讀得懂；update.check = never 不連網', async () => {
  const t = parseTune(await sdlc('tune'));
  assert.ok(t.proposal.some((p) => p.agent === 'reviewer'));

  const w = parseWhatsNew(await sdlc('whatsnew'));
  assert.equal(w.source, 'installed');
  assert.ok(w.text.length > 0);

  const cfg = path.join(project, 'sdlc.config.json');
  const json = JSON.parse(fs.readFileSync(cfg, 'utf8'));
  json.update.check = 'never';
  fs.writeFileSync(cfg, JSON.stringify(json, null, 2));
  const c = parseCheckUpdate(await sdlc('check-update', ['-IfDue']));
  assert.equal(c.status, 'disabled');
});

test('修正輪上限：面板寫進去的值（經 set），doctor 與 handoff-lint 都照它算', async () => {
  const w = parseSet(await sdlc('set', ['review.maxRounds=5']));
  assert.equal(w.error, null);
  assert.equal(w.changes[0].needsApply, false, '修正輪是 hook 現讀的，面板不該標成未套用');

  const d = parseDoctor(await sdlc('doctor'));
  assert.deepEqual(d.review, { maxRounds: 5, source: 'config', valid: true });

  assert.ok(pw.ok);
  const handoff = '## meta\n- feature-id: f1\n- mode: fix\n- round: 5\n\n## target\n- spec: bdd-docs/f1/spec.md\n';
  // hook 讀的是行程的 stdin（Codex 就是這樣餵的），不是 PowerShell 管線 —— 這裡直接用 -Payload。
  const r = await runPwsh(pw.path, encodedCommandArgs(`& '${path.join(project, '.codex/scripts/handoff-lint.ps1')}' -Payload '${handoff.replace(/'/g, "''")}' -Json; exit $LASTEXITCODE`), { cwd: project, timeoutMs: 60_000 });
  const j = JSON.parse(r.stdout.trim());
  assert.equal(r.exit, 0, `設了 5 卻擋下第 5 輪：${r.stdout}`);
  assert.equal(j.max_review_rounds, 5);
});

test('set 擋下的值：錯誤的形狀讀得懂，而且附上建議（面板的「改用 X」按鈕靠它）', async () => {
  const before = fs.readFileSync(path.join(project, 'sdlc.config.json'), 'utf8');
  const env = await sdlc('set', ['agents.reviewer.effort=hgih', 'review.maxRounds=2']);
  const d = parseSet(env);
  assert.equal(env.exit, 2);
  assert.equal(d.error, 'invalid');
  assert.equal(d.errors[0].key, 'agents.reviewer.effort');
  assert.equal(d.errors[0].suggestion, 'agents.reviewer.effort=high');
  assert.equal(fs.readFileSync(path.join(project, 'sdlc.config.json'), 'utf8'), before, '有一組不合法卻寫了檔');
});

test('set -Preset -Preview：只列差異，面板拿它給人確認', async () => {
  const d = parseSet(await sdlc('set', ['-Preset', 'deep', '-Preview']));
  assert.equal(d.preview, true);
  assert.equal(d.written, false);
  assert.ok(d.changes.some((c) => c.key === 'agents.sa-analyst.effort' && c.to === 'medium'));
});

test('專案裡的 schema 讀得懂：面板的選項與說明從這裡來，不是 extension 自己寫的', () => {
  const s = readSettingsSchema(project);
  assert.ok(s, '裝好的專案裡沒有 schema');
  assert.ok(s.effort.choices.some((c) => c.value === 'inherit'));
  assert.ok(s.effort.choices.some((c) => c.value === 'xhigh'));
  assert.ok(!s.effort.choices.some((c) => c.value === 'minimal'), 'minimal 不在 Codex 0.154 的任何模型清單裡');
  assert.match(s.effort.agentHints['sa-analyst']?.high ?? '', /逾時/);
  assert.deepEqual([s.reviewRounds.min, s.reviewRounds.max, s.reviewRounds.default], [1, 5, 3]);
  assert.deepEqual(s.updateCheck.choices.map((c) => c.value), ['daily', 'never']);
  assert.ok(new RegExp(s.updateSource.pattern).test('https://github.com/o/r'));
  assert.ok(new RegExp(s.updateSource.pattern).test(''));
  assert.ok(!new RegExp(s.updateSource.pattern).test('https://gitlab.com/o/r'));
});

test('設定面板：拿真的 doctor 與 schema 建出來的樹，值跟設定檔一致、未套用標得出來', async () => {
  parseSet(await sdlc('set', ['agents.implementer.effort=medium']));
  const d = parseDoctor(await sdlc('doctor'));
  const cfg = readConfig(fs.readFileSync(path.join(project, 'sdlc.config.json'), 'utf8'));
  const input: TreeInput = {
    rootName: 'p', rootPath: project, workflowVersion: d.version.contract, schema: readSettingsSchema(project), canEdit: true,
    config: cfg, knownAgents: [], doctor: d, checking: false, pendingAgents: [],
    guidelines: { dir: true, files: [], rulesExists: true, ruleCount: 1, gateDisabled: false },
    machine: { pwsh: { ok: true, path: 'pwsh' }, codex: { source: 'none' }, extensionVersion: 'test' },
  };
  const nodes = flatten(buildSettingsTree(input));
  const byId = new Map(nodes.map((n) => [n.id, n]));
  assert.equal(byId.get('agents')?.contextValue, 'tuningPending', 'set 之後沒 apply，面板卻沒標未套用');
  assert.match(byId.get('agents/implementer')?.description ?? '', /effort medium.*未套用/);
  assert.equal(byId.get('agents/implementer/effort')?.edit?.key, 'agents.implementer.effort');
  assert.equal(byId.get('status/hooks')?.contextValue, 'hooksUnknown', '找不到 codex 時要給「選擇 codex」而不是假裝信任了');

  const lenses = configLenses(fs.readFileSync(path.join(project, 'sdlc.config.json'), 'utf8'), { rootPath: project, pendingAgents: ['implementer'], canEdit: true });
  assert.match(lenses[0].title, /套用（1 個 agent 未套用）/);

  assert.equal(parseApply(await sdlc('apply')).changed.length, 1);
});

test('rules.json 自己的問題：落在寫壞的那一條規則上（S3 驗收）', async () => {
  const rules = path.join(project, 'guidelines/rules.json');
  const good = fs.readFileSync(rules, 'utf8');
  try {
    const text = good.replace('"severity": "block"', '"severity": "blok"');
    fs.writeFileSync(rules, text);
    assert.ok(pw.ok);
    const r = await runPwsh(pw.path, fileArgs(path.join(project, '.codex/scripts/guideline-gate.ps1'), ['-Validate', '-Json', '-RulesFile', rules]), { cwd: project, timeoutMs: 60_000 });
    const v = parseRulesValidation(r.stdout);
    assert.equal(v.passed, false);
    const o = rulesOutcome(v, text);
    assert.equal(o.records.length, 1);
    const expectLine = text.split('\n').findIndex((l) => l.includes('"blok"')) + 1;
    assert.equal(o.records[0].line, expectLine, `問題沒有落在寫壞的那一行：${JSON.stringify(o.records[0])}`);
    assert.match(o.records[0].message, /severity/);
  } finally {
    fs.writeFileSync(rules, good);
  }
});
