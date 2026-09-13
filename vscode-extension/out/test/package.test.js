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
// extension 本身的形狀：這幾條每一條都守一個「靜默」的失效，而不是守功能。
const strict_1 = __importDefault(require("node:assert/strict"));
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const node_test_1 = require("node:test");
const contract_1 = require("../src/contract");
const ext = path.resolve(__dirname, '..', '..');
const repo = path.resolve(ext, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(ext, 'package.json'), 'utf8'));
(0, node_test_1.test)('只在裝了工作流的工作區啟動（在每個專案都亮著的外掛，使用者的第一個動作是停用它）', () => {
    strict_1.default.deepEqual(pkg.activationEvents, ['workspaceContains:.codex/bdd-workflow/bdd-workflow-version.json']);
});
(0, node_test_1.test)('受限模式（不信任的工作區）不啟動 —— 它會執行工作區裡的 .ps1', () => {
    strict_1.default.equal(pkg.capabilities?.untrustedWorkspaces?.supported, false);
});
(0, node_test_1.test)('extension 讀的 -Json 形狀 = package.json 宣告的 = sdlc.ps1 產生的', () => {
    // 三處各寫一次，任一處改了另外兩處沒跟上，doctor 的相容性判斷與 extension 的解析就會各說各話。
    const sdlc = fs.readFileSync(path.join(repo, '.codex/scripts/sdlc.ps1'), 'utf8');
    const m = /^\$JsonSchema\s*=\s*(\d+)/m.exec(sdlc);
    strict_1.default.ok(m, 'sdlc.ps1 裡找不到 $JsonSchema');
    strict_1.default.equal(Number(m[1]), contract_1.SUPPORTED_SCHEMA);
    strict_1.default.equal(pkg.codexSdlc?.jsonSchema, contract_1.SUPPORTED_SCHEMA);
});
(0, node_test_1.test)('版本號 = 工作流的 contract-version（第四處版本號，agent-lint 檢查 11 也在守）', () => {
    const ver = JSON.parse(fs.readFileSync(path.join(repo, '.codex/bdd-workflow/bdd-workflow-version.json'), 'utf8'));
    strict_1.default.equal(pkg.version, ver['contract-version']);
});
(0, node_test_1.test)('extension ID 跟 sdlc.ps1 找已安裝版本用的一致', () => {
    const sdlc = fs.readFileSync(path.join(repo, '.codex/scripts/sdlc.ps1'), 'utf8');
    const m = /^\$ExtensionId\s*=\s*'([^']+)'/m.exec(sdlc);
    strict_1.default.equal(m?.[1], `${pkg.publisher}.${pkg.name}`);
});
(0, node_test_1.test)('宣告的指令與註冊的指令雙向一致', () => {
    const src = fs.readFileSync(path.join(ext, 'src/extension.ts'), 'utf8');
    const registered = [...src.matchAll(/reg\('([^']+)'/g)].map((x) => x[1]).sort();
    const declared = pkg.contributes.commands.map((c) => c.command).sort();
    strict_1.default.deepEqual(registered, declared);
});
(0, node_test_1.test)('VS Code settings 裡沒有工作流設定（唯一真相是 sdlc.config.json）', () => {
    // user settings 每機器一份、不進版控、團隊看不到 —— 設定放錯地方會靜默消失的同一個坑。
    const keys = Object.keys(pkg.contributes.configuration.properties);
    const leaked = keys.filter((k) => /(model|effort|tuning|preset|update|check|agent)/i.test(k));
    strict_1.default.deepEqual(leaked, []);
});
(0, node_test_1.test)('extension 自己不碰網路（check = never 的保證不能被它繞過）', () => {
    // 更新檢查一律交給 sdlc.ps1 check-update（它看 update.check）。extension 只會啟動行程。
    const outDir = path.join(ext, 'out', 'src');
    const offenders = [];
    for (const f of fs.readdirSync(outDir).filter((x) => x.endsWith('.js'))) {
        const js = fs.readFileSync(path.join(outDir, f), 'utf8');
        for (const re of [/require\("(node:)?(http|https|http2|net|tls|dgram)"\)/, /\bfetch\(/, /\bWebSocket\b/, /\bXMLHttpRequest\b/]) {
            if (re.test(js))
                offenders.push(`${f}: ${re}`);
        }
    }
    strict_1.default.deepEqual(offenders, []);
});
(0, node_test_1.test)('README 講清楚三件刻意不做的事與「移除專案不等於移除 extension」', () => {
    const readme = fs.readFileSync(path.join(ext, 'README.md'), 'utf8');
    strict_1.default.match(readme, /不推測/);
    strict_1.default.match(readme, /不自己實作/);
    strict_1.default.match(readme, /不把工作流設定存進 VS Code settings/);
    strict_1.default.match(readme, /--uninstall-extension codex-sdlc\.codex-sdlc/);
});
