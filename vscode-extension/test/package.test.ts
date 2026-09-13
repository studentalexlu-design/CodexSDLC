// extension 本身的形狀：這幾條每一條都守一個「靜默」的失效，而不是守功能。
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';
import { SUPPORTED_SCHEMA } from '../src/contract';

const ext = path.resolve(__dirname, '..', '..');
const repo = path.resolve(ext, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(ext, 'package.json'), 'utf8'));

test('只在裝了工作流的工作區啟動（在每個專案都亮著的外掛，使用者的第一個動作是停用它）', () => {
  assert.deepEqual(pkg.activationEvents, ['workspaceContains:.codex/bdd-workflow/bdd-workflow-version.json']);
});

test('受限模式（不信任的工作區）不啟動 —— 它會執行工作區裡的 .ps1', () => {
  assert.equal(pkg.capabilities?.untrustedWorkspaces?.supported, false);
});

test('extension 讀的 -Json 形狀 = package.json 宣告的 = sdlc.ps1 產生的', () => {
  // 三處各寫一次，任一處改了另外兩處沒跟上，doctor 的相容性判斷與 extension 的解析就會各說各話。
  const sdlc = fs.readFileSync(path.join(repo, '.codex/scripts/sdlc.ps1'), 'utf8');
  const m = /^\$JsonSchema\s*=\s*(\d+)/m.exec(sdlc);
  assert.ok(m, 'sdlc.ps1 裡找不到 $JsonSchema');
  assert.equal(Number(m![1]), SUPPORTED_SCHEMA);
  assert.equal(pkg.codexSdlc?.jsonSchema, SUPPORTED_SCHEMA);
});

test('版本號 = 工作流的 contract-version（第四處版本號，agent-lint 檢查 11 也在守）', () => {
  const ver = JSON.parse(fs.readFileSync(path.join(repo, '.codex/bdd-workflow/bdd-workflow-version.json'), 'utf8'));
  assert.equal(pkg.version, ver['contract-version']);
});

test('extension ID 跟 sdlc.ps1 找已安裝版本用的一致', () => {
  const sdlc = fs.readFileSync(path.join(repo, '.codex/scripts/sdlc.ps1'), 'utf8');
  const m = /^\$ExtensionId\s*=\s*'([^']+)'/m.exec(sdlc);
  assert.equal(m?.[1], `${pkg.publisher}.${pkg.name}`);
});

test('宣告的指令與註冊的指令雙向一致', () => {
  const src = fs.readFileSync(path.join(ext, 'src/extension.ts'), 'utf8');
  const registered = [...src.matchAll(/reg\('([^']+)'/g)].map((x) => x[1]).sort();
  const declared = pkg.contributes.commands.map((c: { command: string }) => c.command).sort();
  assert.deepEqual(registered, declared);
});

test('VS Code settings 裡沒有工作流設定（唯一真相是 sdlc.config.json）', () => {
  // user settings 每機器一份、不進版控、團隊看不到 —— 設定放錯地方會靜默消失的同一個坑。
  const keys = Object.keys(pkg.contributes.configuration.properties);
  const leaked = keys.filter((k) => /(model|effort|tuning|preset|update|check|agent)/i.test(k));
  assert.deepEqual(leaked, []);
});

test('extension 自己不碰網路（check = never 的保證不能被它繞過）', () => {
  // 更新檢查一律交給 sdlc.ps1 check-update（它看 update.check）。extension 只會啟動行程。
  const outDir = path.join(ext, 'out', 'src');
  const offenders: string[] = [];
  for (const f of fs.readdirSync(outDir).filter((x) => x.endsWith('.js'))) {
    const js = fs.readFileSync(path.join(outDir, f), 'utf8');
    for (const re of [/require\("(node:)?(http|https|http2|net|tls|dgram)"\)/, /\bfetch\(/, /\bWebSocket\b/, /\bXMLHttpRequest\b/]) {
      if (re.test(js)) offenders.push(`${f}: ${re}`);
    }
  }
  assert.deepEqual(offenders, []);
});

test('README 講清楚三件刻意不做的事與「移除專案不等於移除 extension」', () => {
  const readme = fs.readFileSync(path.join(ext, 'README.md'), 'utf8');
  assert.match(readme, /不推測/);
  assert.match(readme, /不自己實作/);
  assert.match(readme, /不把工作流設定存進 VS Code settings/);
  assert.match(readme, /--uninstall-extension codex-sdlc\.codex-sdlc/);
});
