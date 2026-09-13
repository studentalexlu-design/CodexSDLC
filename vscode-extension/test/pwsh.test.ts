import assert from 'node:assert/strict';
import { test } from 'node:test';
import { encodedCommandArgs, gateInvocation, psQuote, resolvePwsh, runPwsh } from '../src/pwsh';

const has = (...paths: string[]) => (p: string) => paths.includes(p);

test('設定了 pwshPath 而且檔在 → 用它', () => {
  const r = resolvePwsh({ setting: 'D:\\tools\\pwsh.exe', env: {}, platform: 'win32', exists: has('D:\\tools\\pwsh.exe') });
  assert.deepEqual(r, { ok: true, path: 'D:\\tools\\pwsh.exe', source: 'setting' });
});

test('設定指向不存在的檔 → 明講是設定錯，不去別處亂找', () => {
  const r = resolvePwsh({ setting: 'D:\\nope\\pwsh.exe', env: { PATH: 'C:\\pw' }, platform: 'win32', exists: has('C:\\pw\\pwsh.exe') });
  assert.equal(r.ok, false);
  assert.equal(!r.ok && r.reason, 'setting-invalid');
});

test('Windows 的 PATH 變數名大小寫不同也找得到（extension host 拿到的常是 Path）', () => {
  const r = resolvePwsh({ env: { Path: 'C:\\Windows;"C:\\Program Files\\PowerShell\\7"' }, platform: 'win32', exists: has('C:\\Program Files\\PowerShell\\7\\pwsh.exe') });
  assert.equal(r.ok && r.source, 'path');
});

test('PATH 裡沒有，退回常見安裝位置（VS Code 從開始選單啟動時 PATH 跟終端機不一樣）', () => {
  const r = resolvePwsh({ env: { PATH: 'C:\\Windows', ProgramFiles: 'C:\\Program Files' }, platform: 'win32', exists: has('C:\\Program Files\\PowerShell\\7\\pwsh.exe') });
  assert.equal(r.ok && r.source, 'known-location');
});

test('找不到 → 人看得懂的一句話 ＋ 安裝連結；有 5.1 時點明那不是 pwsh 7', () => {
  const r = resolvePwsh({ env: { PATH: 'C:\\Windows', SystemRoot: 'C:\\Windows' }, platform: 'win32', exists: has('C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe') });
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.match(r.message, /aka\.ms\/powershell/);
    assert.match(r.message, /5\.1/);
    assert.match(r.message, /codexSdlc\.pwshPath/);
  }
});

test('macOS／Linux 的常見位置', () => {
  const r = resolvePwsh({ env: { PATH: '/usr/bin' }, platform: 'darwin', exists: has('/opt/homebrew/bin/pwsh') });
  assert.equal(r.ok && r.path, '/opt/homebrew/bin/pwsh');
});

test('psQuote 只需要跳脫單引號', () => {
  assert.equal(psQuote("C:\\Users\\o'brien\\a b.sql"), "'C:\\Users\\o''brien\\a b.sql'");
});

test('gate 的呼叫：陣列參數、傳遞 exit code', () => {
  const s = gateInvocation('C:\\p\\.codex\\scripts\\guideline-gate.ps1', ['src/a.sql', "src/o'b.cs"], ['-MaxReport', '500']);
  assert.equal(s, "& 'C:\\p\\.codex\\scripts\\guideline-gate.ps1' -Path @('src/a.sql','src/o''b.cs') -MaxReport 500 -Json; exit $LASTEXITCODE");
});

test('-EncodedCommand 是 UTF-16LE 的 base64（中文路徑不會被命令列轉壞）', () => {
  const args = encodedCommandArgs("& 'x.ps1' -Path @('規格/訂單.sql')");
  const decoded = Buffer.from(args[args.length - 1], 'base64').toString('utf16le');
  assert.equal(decoded, "& 'x.ps1' -Path @('規格/訂單.sql')");
});

test('執行檔不存在時回報 spawnError，不丟例外', async () => {
  const r = await runPwsh('Z:\\definitely\\not\\pwsh.exe', ['-Command', 'exit 0'], { cwd: process.cwd(), timeoutMs: 5000 });
  assert.equal(r.exit, null);
  assert.ok(r.spawnError);
});
