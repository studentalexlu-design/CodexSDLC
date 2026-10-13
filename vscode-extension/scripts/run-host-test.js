// 在真的 VS Code 裡驗打包出來的 vsix。會開一個 VS Code 視窗（獨立的 user-data-dir 與 extensions 目錄，
// 不碰你平常用的那一份），跑完自己關掉。
//
//   npm run build && npm run test:host
//
// VS Code 執行檔：環境變數 VSCODE_EXECUTABLE ＞ PATH 上的 `code` 所在的安裝目錄 ＞ 下載 stable 到 .vscode-test/。
// VSCODE_TEST_DOWNLOAD=1 強制用下載的那一份（本機的 VS Code 正在更新時會拒絕再開一個實例；下載的也比較接近乾淨環境）。
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { runTests, downloadAndUnzipVSCode, resolveCliArgsFromVSCodeExecutablePath } = require('@vscode/test-electron');

const ext = path.resolve(__dirname, '..');
const repo = path.resolve(ext, '..');
const version = JSON.parse(fs.readFileSync(path.join(repo, '.codex/bdd-workflow/bdd-workflow-version.json'), 'utf8'))['contract-version'];

function findOnPath(names) {
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    for (const n of names) {
      const p = path.join(dir, n);
      if (dir && fs.existsSync(p)) return p;
    }
  }
  return undefined;
}

function localVsCode() {
  if (process.env.VSCODE_EXECUTABLE) return process.env.VSCODE_EXECUTABLE;
  if (process.env.VSCODE_TEST_DOWNLOAD === '1' || process.platform !== 'win32') return undefined;
  const cli = findOnPath(['code.cmd']);
  if (!cli) return undefined;
  const exe = path.resolve(path.dirname(cli), '..', 'Code.exe');
  return fs.existsSync(exe) ? exe : undefined;
}

function run(cmd, args, opts = {}) {
  // Node 不准不經 shell 直接跑 .cmd；經 shell 時要自己加引號（VS Code 預設裝在「Microsoft VS Code」底下）。
  const viaShell = process.platform === 'win32' && /\.cmd$/i.test(cmd);
  const q = (s) => (viaShell && /[\s&()^]/.test(s) ? `"${s}"` : s);
  const r = spawnSync(q(cmd), args.map(q), { encoding: 'utf8', shell: viaShell, ...opts });
  if (r.status !== 0) {
    console.error(r.stdout, r.stderr);
    throw new Error(`${path.basename(cmd)} ${args[0]} 失敗（exit ${r.status}）`);
  }
  return r.stdout;
}

(async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-sdlc-host-'));
  const workspace = path.join(tmp, 'project');
  const userData = path.join(tmp, 'user-data');
  const extDir = path.join(tmp, 'extensions');
  fs.mkdirSync(workspace, { recursive: true });
  try {
    const vsix = path.join(tmp, `codex-sdlc-${version}.vsix`);
    run(process.platform === 'win32' ? 'npx.cmd' : 'npx', ['--no-install', 'vsce', 'package', '--skip-license', '--allow-missing-repository', '--out', vsix], { cwd: ext });

    const pwsh = findOnPath(process.platform === 'win32' ? ['pwsh.exe'] : ['pwsh']);
    if (!pwsh) throw new Error('需要 pwsh 7 在 PATH 上');
    const install = JSON.parse(run(pwsh, ['-NoProfile', '-File', path.join(repo, '.codex/scripts/sdlc.ps1'), 'install', '-Source', repo, '-Target', workspace, '-Json']));
    if (install.exit !== 0) throw new Error(`sdlc.ps1 install 失敗：${install.warnings.join(' | ')}`);

    const vscodeExecutablePath = localVsCode() || (await downloadAndUnzipVSCode('stable'));
    console.log(`[host-test] VS Code: ${vscodeExecutablePath}`);
    const [cli, ...defaultArgs] = resolveCliArgsFromVSCodeExecutablePath(vscodeExecutablePath);
    const cliArgs = defaultArgs.filter((a) => !/^--(extensions-dir|user-data-dir)/.test(a));
    run(cli, [...cliArgs, '--extensions-dir', extDir, '--user-data-dir', userData, '--install-extension', vsix, '--force']);

    await runTests({
      vscodeExecutablePath,
      extensionDevelopmentPath: path.join(ext, 'test-host', 'runner-extension'),
      extensionTestsPath: path.join(ext, 'out', 'test-host', 'suite.js'),
      extensionTestsEnv: { CODEX_SDLC_HOST_WORKSPACE: workspace, CODEX_SDLC_HOST_VERSION: version },
      launchArgs: [workspace, '--extensions-dir', extDir, '--user-data-dir', userData, '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes', '--disable-telemetry'],
    });
    console.log('[host-test] PASS');
  } catch (e) {
    console.error(`[host-test] FAIL: ${e && e.message ? e.message : e}`);
    process.exitCode = 1;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
  }
})();
