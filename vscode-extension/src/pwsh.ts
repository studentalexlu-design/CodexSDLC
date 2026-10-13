// 找 PowerShell 7、執行工作流的腳本。**不 import vscode** —— 這一層要能在純 Node 底下測。
//
// 兩個前提決定了這支檔的形狀：
//   1. extension host 的 PATH 不等於終端機的 PATH。VS Code 從開始選單或 Dock 啟動時，
//      使用者在 shell profile 裡加的路徑都不在，所以 PATH 找不到時要再看常見的安裝位置。
//   2. 這套腳本要的是 pwsh 7，不是 Windows PowerShell 5.1（兩支執行檔、名字不同）。
//      找不到時給一句人看得懂的話 ＋ 安裝連結，不是一個 spawn 失敗的堆疊 ——
//      「擋下的理由跟使用者要做的事無關，而且他修不了」是這套流程踩過兩次的失敗形狀。

import { spawn } from 'node:child_process';
import * as path from 'node:path';

export const INSTALL_URL = 'https://aka.ms/powershell';

export interface PwshLookup {
  setting?: string;
  env: Record<string, string | undefined>;
  platform: NodeJS.Platform;
  exists: (p: string) => boolean;
}

export type PwshResolution =
  | { ok: true; path: string; source: 'setting' | 'path' | 'known-location' }
  | { ok: false; reason: 'setting-invalid' | 'not-found'; message: string; installUrl: string };

function pathApi(platform: NodeJS.Platform): path.PlatformPath {
  return platform === 'win32' ? path.win32 : path.posix;
}

// Windows 的環境變數名稱不分大小寫，但複製出來的物件分。
export function envValue(env: Record<string, string | undefined>, name: string): string | undefined {
  const key = Object.keys(env).find((k) => k.toLowerCase() === name.toLowerCase());
  return key === undefined ? undefined : env[key];
}

export function knownPwshLocations(platform: NodeJS.Platform, env: Record<string, string | undefined>): string[] {
  const p = pathApi(platform);
  if (platform === 'win32') {
    const out: string[] = [];
    for (const root of [envValue(env, 'ProgramFiles'), envValue(env, 'ProgramW6432'), 'C:\\Program Files']) {
      if (!root) continue;
      out.push(p.join(root, 'PowerShell', '7', 'pwsh.exe'), p.join(root, 'PowerShell', '7-preview', 'pwsh.exe'));
    }
    const local = envValue(env, 'LOCALAPPDATA');
    if (local) out.push(p.join(local, 'Microsoft', 'WindowsApps', 'pwsh.exe'));
    const home = envValue(env, 'USERPROFILE');
    if (home) out.push(p.join(home, '.dotnet', 'tools', 'pwsh.exe'));
    return [...new Set(out)];
  }
  const home = envValue(env, 'HOME');
  return [
    '/usr/local/bin/pwsh',
    '/opt/homebrew/bin/pwsh',
    '/usr/local/microsoft/powershell/7/pwsh',
    '/usr/bin/pwsh',
    '/opt/microsoft/powershell/7/pwsh',
    '/snap/bin/pwsh',
    ...(home ? [p.join(home, '.dotnet', 'tools', 'pwsh')] : []),
  ];
}

export function resolvePwsh(l: PwshLookup): PwshResolution {
  const p = pathApi(l.platform);
  if (l.setting && l.setting.trim()) {
    const s = l.setting.trim();
    if (l.exists(s)) return { ok: true, path: s, source: 'setting' };
    return {
      ok: false,
      reason: 'setting-invalid',
      message: `設定 codexSdlc.pwshPath 指向的檔不存在：${s}。改成 pwsh 的完整路徑，或清空讓它自己找。`,
      installUrl: INSTALL_URL,
    };
  }

  const exe = l.platform === 'win32' ? 'pwsh.exe' : 'pwsh';
  const sep = l.platform === 'win32' ? ';' : ':';
  for (const raw of (envValue(l.env, 'PATH') ?? '').split(sep)) {
    const dir = raw.trim().replace(/^"(.*)"$/, '$1');
    if (!dir) continue;
    const candidate = p.join(dir, exe);
    if (l.exists(candidate)) return { ok: true, path: candidate, source: 'path' };
  }
  for (const candidate of knownPwshLocations(l.platform, l.env)) {
    if (l.exists(candidate)) return { ok: true, path: candidate, source: 'known-location' };
  }

  let message =
    '找不到 PowerShell 7（pwsh）。這套工作流的腳本需要它 —— 沒有它，Codex 的 hooks 也會全部靜默失效。' +
    `安裝：${INSTALL_URL}。已經裝了但 VS Code 找不到的話，在設定 codexSdlc.pwshPath 填 pwsh 的完整路徑。`;
  if (l.platform === 'win32') {
    const winPs = p.join(envValue(l.env, 'SystemRoot') ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    if (l.exists(winPs)) {
      message += '（這台機器有 Windows PowerShell 5.1，但它不是 pwsh 7 —— 這套腳本在 5.1 上跑不起來。）';
    }
  }
  return { ok: false, reason: 'not-found', message, installUrl: INSTALL_URL };
}

export interface RunResult {
  exit: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  spawnError?: string;
}

export interface RunOptions {
  cwd: string;
  timeoutMs: number;
  env?: Record<string, string | undefined>;
}

// 腳本被重導向時一律寫 UTF-8（見各腳本的「標準 I/O」段），所以這裡也一律用 UTF-8 解碼。
export function runPwsh(pwsh: string, args: string[], opts: RunOptions): Promise<RunResult> {
  return new Promise((resolve) => {
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    let timedOut = false;
    let settled = false;
    const finish = (r: RunResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(r);
    };

    let child;
    try {
      child = spawn(pwsh, ['-NoProfile', '-NonInteractive', ...args], {
        cwd: opts.cwd,
        env: opts.env ?? process.env,
        windowsHide: true,
      });
    } catch (e) {
      resolve({ exit: null, stdout: '', stderr: '', timedOut: false, spawnError: (e as Error).message });
      return;
    }
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill(); } catch { /* 已經結束 */ }
    }, opts.timeoutMs);

    child.stdout.on('data', (d: Buffer) => out.push(d));
    child.stderr.on('data', (d: Buffer) => err.push(d));
    child.on('error', (e: Error) =>
      finish({ exit: null, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8'), timedOut, spawnError: e.message }));
    child.on('close', (code: number | null) =>
      finish({ exit: code, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8'), timedOut }));
    child.stdin.end();
  });
}

export function fileArgs(scriptPath: string, params: string[]): string[] {
  return ['-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...params];
}

// 單引號字串：PowerShell 裡唯一需要跳脫的是單引號本身。
export function psQuote(s: string): string {
  return `'${s.replace(/'/g, "''")}'`;
}

// 要傳陣列參數（gate 的 -Path）時用 -EncodedCommand：-File 模式下 `-Path a,b` 只是一個字串，
// 而把路徑拼進命令列又得處理 Windows 的引號規則。base64(UTF-16LE) 兩個問題都沒有。
export function encodedCommandArgs(psCode: string): string[] {
  return ['-ExecutionPolicy', 'Bypass', '-EncodedCommand', Buffer.from(psCode, 'utf16le').toString('base64')];
}

export function gateInvocation(scriptPath: string, relPaths: string[], extra: string[] = []): string {
  const list = relPaths.map(psQuote).join(',');
  return `& ${psQuote(scriptPath)} -Path @(${list}) ${extra.join(' ')} -Json; exit $LASTEXITCODE`;
}
