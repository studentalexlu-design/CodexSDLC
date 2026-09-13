"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const strict_1 = __importDefault(require("node:assert/strict"));
const node_test_1 = require("node:test");
const pwsh_1 = require("../src/pwsh");
const has = (...paths) => (p) => paths.includes(p);
(0, node_test_1.test)('設定了 pwshPath 而且檔在 → 用它', () => {
    const r = (0, pwsh_1.resolvePwsh)({ setting: 'D:\\tools\\pwsh.exe', env: {}, platform: 'win32', exists: has('D:\\tools\\pwsh.exe') });
    strict_1.default.deepEqual(r, { ok: true, path: 'D:\\tools\\pwsh.exe', source: 'setting' });
});
(0, node_test_1.test)('設定指向不存在的檔 → 明講是設定錯，不去別處亂找', () => {
    const r = (0, pwsh_1.resolvePwsh)({ setting: 'D:\\nope\\pwsh.exe', env: { PATH: 'C:\\pw' }, platform: 'win32', exists: has('C:\\pw\\pwsh.exe') });
    strict_1.default.equal(r.ok, false);
    strict_1.default.equal(!r.ok && r.reason, 'setting-invalid');
});
(0, node_test_1.test)('Windows 的 PATH 變數名大小寫不同也找得到（extension host 拿到的常是 Path）', () => {
    const r = (0, pwsh_1.resolvePwsh)({ env: { Path: 'C:\\Windows;"C:\\Program Files\\PowerShell\\7"' }, platform: 'win32', exists: has('C:\\Program Files\\PowerShell\\7\\pwsh.exe') });
    strict_1.default.equal(r.ok && r.source, 'path');
});
(0, node_test_1.test)('PATH 裡沒有，退回常見安裝位置（VS Code 從開始選單啟動時 PATH 跟終端機不一樣）', () => {
    const r = (0, pwsh_1.resolvePwsh)({ env: { PATH: 'C:\\Windows', ProgramFiles: 'C:\\Program Files' }, platform: 'win32', exists: has('C:\\Program Files\\PowerShell\\7\\pwsh.exe') });
    strict_1.default.equal(r.ok && r.source, 'known-location');
});
(0, node_test_1.test)('找不到 → 人看得懂的一句話 ＋ 安裝連結；有 5.1 時點明那不是 pwsh 7', () => {
    const r = (0, pwsh_1.resolvePwsh)({ env: { PATH: 'C:\\Windows', SystemRoot: 'C:\\Windows' }, platform: 'win32', exists: has('C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe') });
    strict_1.default.equal(r.ok, false);
    if (!r.ok) {
        strict_1.default.match(r.message, /aka\.ms\/powershell/);
        strict_1.default.match(r.message, /5\.1/);
        strict_1.default.match(r.message, /codexSdlc\.pwshPath/);
    }
});
(0, node_test_1.test)('macOS／Linux 的常見位置', () => {
    const r = (0, pwsh_1.resolvePwsh)({ env: { PATH: '/usr/bin' }, platform: 'darwin', exists: has('/opt/homebrew/bin/pwsh') });
    strict_1.default.equal(r.ok && r.path, '/opt/homebrew/bin/pwsh');
});
(0, node_test_1.test)('psQuote 只需要跳脫單引號', () => {
    strict_1.default.equal((0, pwsh_1.psQuote)("C:\\Users\\o'brien\\a b.sql"), "'C:\\Users\\o''brien\\a b.sql'");
});
(0, node_test_1.test)('gate 的呼叫：陣列參數、傳遞 exit code', () => {
    const s = (0, pwsh_1.gateInvocation)('C:\\p\\.codex\\scripts\\guideline-gate.ps1', ['src/a.sql', "src/o'b.cs"], ['-MaxReport', '500']);
    strict_1.default.equal(s, "& 'C:\\p\\.codex\\scripts\\guideline-gate.ps1' -Path @('src/a.sql','src/o''b.cs') -MaxReport 500 -Json; exit $LASTEXITCODE");
});
(0, node_test_1.test)('-EncodedCommand 是 UTF-16LE 的 base64（中文路徑不會被命令列轉壞）', () => {
    const args = (0, pwsh_1.encodedCommandArgs)("& 'x.ps1' -Path @('規格/訂單.sql')");
    const decoded = Buffer.from(args[args.length - 1], 'base64').toString('utf16le');
    strict_1.default.equal(decoded, "& 'x.ps1' -Path @('規格/訂單.sql')");
});
(0, node_test_1.test)('執行檔不存在時回報 spawnError，不丟例外', async () => {
    const r = await (0, pwsh_1.runPwsh)('Z:\\definitely\\not\\pwsh.exe', ['-Command', 'exit 0'], { cwd: process.cwd(), timeoutMs: 5000 });
    strict_1.default.equal(r.exit, null);
    strict_1.default.ok(r.spawnError);
});
