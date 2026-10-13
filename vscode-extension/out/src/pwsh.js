"use strict";
// 找 PowerShell 7、執行工作流的腳本。**不 import vscode** —— 這一層要能在純 Node 底下測。
//
// 兩個前提決定了這支檔的形狀：
//   1. extension host 的 PATH 不等於終端機的 PATH。VS Code 從開始選單或 Dock 啟動時，
//      使用者在 shell profile 裡加的路徑都不在，所以 PATH 找不到時要再看常見的安裝位置。
//   2. 這套腳本要的是 pwsh 7，不是 Windows PowerShell 5.1（兩支執行檔、名字不同）。
//      找不到時給一句人看得懂的話 ＋ 安裝連結，不是一個 spawn 失敗的堆疊 ——
//      「擋下的理由跟使用者要做的事無關，而且他修不了」是這套流程踩過兩次的失敗形狀。
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
Object.defineProperty(exports, "__esModule", { value: true });
exports.INSTALL_URL = void 0;
exports.envValue = envValue;
exports.knownPwshLocations = knownPwshLocations;
exports.resolvePwsh = resolvePwsh;
exports.runPwsh = runPwsh;
exports.fileArgs = fileArgs;
exports.psQuote = psQuote;
exports.encodedCommandArgs = encodedCommandArgs;
exports.gateInvocation = gateInvocation;
const node_child_process_1 = require("node:child_process");
const path = __importStar(require("node:path"));
exports.INSTALL_URL = 'https://aka.ms/powershell';
function pathApi(platform) {
    return platform === 'win32' ? path.win32 : path.posix;
}
// Windows 的環境變數名稱不分大小寫，但複製出來的物件分。
function envValue(env, name) {
    const key = Object.keys(env).find((k) => k.toLowerCase() === name.toLowerCase());
    return key === undefined ? undefined : env[key];
}
function knownPwshLocations(platform, env) {
    const p = pathApi(platform);
    if (platform === 'win32') {
        const out = [];
        for (const root of [envValue(env, 'ProgramFiles'), envValue(env, 'ProgramW6432'), 'C:\\Program Files']) {
            if (!root)
                continue;
            out.push(p.join(root, 'PowerShell', '7', 'pwsh.exe'), p.join(root, 'PowerShell', '7-preview', 'pwsh.exe'));
        }
        const local = envValue(env, 'LOCALAPPDATA');
        if (local)
            out.push(p.join(local, 'Microsoft', 'WindowsApps', 'pwsh.exe'));
        const home = envValue(env, 'USERPROFILE');
        if (home)
            out.push(p.join(home, '.dotnet', 'tools', 'pwsh.exe'));
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
function resolvePwsh(l) {
    const p = pathApi(l.platform);
    if (l.setting && l.setting.trim()) {
        const s = l.setting.trim();
        if (l.exists(s))
            return { ok: true, path: s, source: 'setting' };
        return {
            ok: false,
            reason: 'setting-invalid',
            message: `設定 codexSdlc.pwshPath 指向的檔不存在：${s}。改成 pwsh 的完整路徑，或清空讓它自己找。`,
            installUrl: exports.INSTALL_URL,
        };
    }
    const exe = l.platform === 'win32' ? 'pwsh.exe' : 'pwsh';
    const sep = l.platform === 'win32' ? ';' : ':';
    for (const raw of (envValue(l.env, 'PATH') ?? '').split(sep)) {
        const dir = raw.trim().replace(/^"(.*)"$/, '$1');
        if (!dir)
            continue;
        const candidate = p.join(dir, exe);
        if (l.exists(candidate))
            return { ok: true, path: candidate, source: 'path' };
    }
    for (const candidate of knownPwshLocations(l.platform, l.env)) {
        if (l.exists(candidate))
            return { ok: true, path: candidate, source: 'known-location' };
    }
    let message = '找不到 PowerShell 7（pwsh）。這套工作流的腳本需要它 —— 沒有它，Codex 的 hooks 也會全部靜默失效。' +
        `安裝：${exports.INSTALL_URL}。已經裝了但 VS Code 找不到的話，在設定 codexSdlc.pwshPath 填 pwsh 的完整路徑。`;
    if (l.platform === 'win32') {
        const winPs = p.join(envValue(l.env, 'SystemRoot') ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
        if (l.exists(winPs)) {
            message += '（這台機器有 Windows PowerShell 5.1，但它不是 pwsh 7 —— 這套腳本在 5.1 上跑不起來。）';
        }
    }
    return { ok: false, reason: 'not-found', message, installUrl: exports.INSTALL_URL };
}
// 腳本被重導向時一律寫 UTF-8（見各腳本的「標準 I/O」段），所以這裡也一律用 UTF-8 解碼。
function runPwsh(pwsh, args, opts) {
    return new Promise((resolve) => {
        const out = [];
        const err = [];
        let timedOut = false;
        let settled = false;
        const finish = (r) => {
            if (settled)
                return;
            settled = true;
            clearTimeout(timer);
            resolve(r);
        };
        let child;
        try {
            child = (0, node_child_process_1.spawn)(pwsh, ['-NoProfile', '-NonInteractive', ...args], {
                cwd: opts.cwd,
                env: opts.env ?? process.env,
                windowsHide: true,
            });
        }
        catch (e) {
            resolve({ exit: null, stdout: '', stderr: '', timedOut: false, spawnError: e.message });
            return;
        }
        const timer = setTimeout(() => {
            timedOut = true;
            try {
                child.kill();
            }
            catch { /* 已經結束 */ }
        }, opts.timeoutMs);
        child.stdout.on('data', (d) => out.push(d));
        child.stderr.on('data', (d) => err.push(d));
        child.on('error', (e) => finish({ exit: null, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8'), timedOut, spawnError: e.message }));
        child.on('close', (code) => finish({ exit: code, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8'), timedOut }));
        child.stdin.end();
    });
}
function fileArgs(scriptPath, params) {
    return ['-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...params];
}
// 單引號字串：PowerShell 裡唯一需要跳脫的是單引號本身。
function psQuote(s) {
    return `'${s.replace(/'/g, "''")}'`;
}
// 要傳陣列參數（gate 的 -Path）時用 -EncodedCommand：-File 模式下 `-Path a,b` 只是一個字串，
// 而把路徑拼進命令列又得處理 Windows 的引號規則。base64(UTF-16LE) 兩個問題都沒有。
function encodedCommandArgs(psCode) {
    return ['-ExecutionPolicy', 'Bypass', '-EncodedCommand', Buffer.from(psCode, 'utf16le').toString('base64')];
}
function gateInvocation(scriptPath, relPaths, extra = []) {
    const list = relPaths.map(psQuote).join(',');
    return `& ${psQuote(scriptPath)} -Path @(${list}) ${extra.join(' ')} -Json; exit $LASTEXITCODE`;
}
