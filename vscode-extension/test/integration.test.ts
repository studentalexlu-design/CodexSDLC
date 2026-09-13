// 拿**真的** sdlc.ps1 與 gate（這個 repo 工作區裡的那一份）裝進一個暫存專案，再用 extension 的解析去讀。
// 這是兩個語言之間的合約測試：PowerShell 那邊改了欄位名，這裡紅；extension 這邊讀錯欄位，這裡也紅。
// 也是計畫 M1／M1.5 的驗收：狀態列出現版本、改設定不 apply 立刻看到漂移、apply 之後 doctor 是綠的。

import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { after, before, test } from 'node:test';
import {
  parseApply, parseCheckUpdate, parseDlpGate, parseDoctor, parseEnvelope, parseGuidelineGate, parseTune, parseWhatsNew, type Envelope,
} from '../src/contract';
import { dlpOutcome, guidelineOutcome } from '../src/diagnostics';
import { encodedCommandArgs, fileArgs, gateInvocation, resolvePwsh, runPwsh } from '../src/pwsh';
import { statusFromDoctor } from '../src/status';
import { setAgentValue } from '../src/tuning';

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

test('改 sdlc.config.json 不 apply → 立刻看到漂移；apply 之後 doctor 是綠的（M1.5 驗收）', async () => {
  const cfg = path.join(project, 'sdlc.config.json');
  fs.writeFileSync(cfg, setAgentValue(fs.readFileSync(cfg, 'utf8'), 'reviewer', 'effort', 'high'));

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

test('修正輪上限：extension 寫進去的值，doctor 與 handoff-lint 都照它算', async () => {
  const { setReviewMaxRounds } = await import('../src/tuning');
  const cfg = path.join(project, 'sdlc.config.json');
  fs.writeFileSync(cfg, setReviewMaxRounds(fs.readFileSync(cfg, 'utf8'), 5));

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
