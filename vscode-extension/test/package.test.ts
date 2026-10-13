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

test('面板永遠在；還沒裝工作流時它是安裝入口（以前這裡什麼都沒有，使用者無路可走）', () => {
  const views = pkg.contributes.views.codexSdlc;
  assert.equal(views.length, 1);
  assert.equal(views[0].id, 'codexSdlc.settings');
  assert.equal(views[0].when, undefined, '掛了 when 的話，沒裝工作流的工作區又會變成一片空白');
  const welcome = pkg.contributes.viewsWelcome.find((w: { view: string }) => w.view === 'codexSdlc.settings');
  assert.ok(welcome, '沒有 welcome view —— 面板會是空的，而使用者不知道要打哪個指令');
  assert.equal(welcome.when, '!codexSdlc.active');
  assert.match(welcome.contents, /command:codexSdlc\.install\)/);
  assert.match(welcome.contents, /command:codexSdlc\.installFrom\)/);
  const src = fs.readFileSync(path.join(ext, 'src/extension.ts'), 'utf8');
  assert.match(src, /setContext', 'codexSdlc\.active'/, 'extension 沒有設這個 context key —— welcome 與面板會同時出現');
  assert.ok(fs.existsSync(path.join(ext, pkg.contributes.viewsContainers.activitybar[0].icon)), '活動列圖示不存在');
});

test('不碰 Codex 的信任狀態，也不留 codex 的設定（整條拿掉了）', () => {
  // doctor 4.10.0 起預設就不問，所以這裡**一個相關的參數都不該出現** ——
  // 帶 -CheckHookTrust 等於把那個 15 秒的子行程請回來，而它回答的問題在這個介面裡按不動。
  // 註解先拿掉：說明為什麼不做那件事的句子本身會提到它，那不是在做那件事。
  const src = fs.readFileSync(path.join(ext, 'src/extension.ts'), 'utf8').replace(/^\s*\/\/.*$/gm, '');
  assert.doesNotMatch(src, /app-server|trustHooks|codexPath|CheckHookTrust/);
  assert.ok(!Object.keys(pkg.contributes.configuration.properties).includes('codexSdlc.codexPath'));
  const ids = pkg.contributes.commands.map((c: { command: string }) => c.command);
  for (const gone of ['codexSdlc.trustHooks', 'codexSdlc.pickCodex']) assert.ok(!ids.includes(gone), `${gone} 還在`);
});

test('內附的 payload 不進版控、但要進 vsix（repo 裡長期躺著第二份 .codex/ 就是分岔的形狀）', () => {
  assert.match(fs.readFileSync(path.join(repo, '.gitignore'), 'utf8'), /^vscode-extension\/payload\/$/m);
  assert.doesNotMatch(fs.readFileSync(path.join(ext, '.vscodeignore'), 'utf8'), /^payload/m);
});

test('選單引用的指令都有宣告；需要參數的指令不出現在命令面板', () => {
  const declared = new Set(pkg.contributes.commands.map((c: { command: string }) => c.command));
  const menus = pkg.contributes.menus as Record<string, { command: string; when?: string }[]>;
  for (const [where, items] of Object.entries(menus)) {
    for (const m of items) assert.ok(declared.has(m.command), `${where} 引用了沒宣告的 ${m.command}`);
  }
  const hidden = new Set(menus.commandPalette.filter((m) => m.when === 'false').map((m) => m.command));
  for (const c of ['codexSdlc.editSetting', 'codexSdlc.applyProposalFor', 'codexSdlc.openFile']) assert.ok(hidden.has(c), `${c} 從命令面板叫會沒有參數`);
});

test('面板的行內按鈕：tree.ts 產生的每一種標記都有對應的按鈕', () => {
  const tree = fs.readFileSync(path.join(ext, 'src/tree.ts'), 'utf8');
  const tags = new Set([...tree.matchAll(/contextValue: (?:[^,}]*\? )?'([A-Za-z]+)'(?: : '([A-Za-z]+)')?/g)].flatMap((m) => [m[1], m[2]]).filter(Boolean));
  const whens = (pkg.contributes.menus['view/item/context'] as { when: string }[]).map((m) => m.when).join(' ');
  for (const t of tags) {
    if (t === 'openable') continue;   // 點一下就開，不需要行內按鈕
    assert.ok(whens.includes(t) || new RegExp(t.replace(/(On|Off)$/, '')).test(whens), `contextValue ${t} 沒有任何行內按鈕`);
  }
  assert.ok(tags.size >= 6, `只抓到 ${[...tags].join(',')} —— 這條測試的 regex 跟 tree.ts 對不上了`);
});

test('四步引導的每一頁都在，而且會進 vsix（.vscodeignore 沒排除它們）', () => {
  const steps = pkg.contributes.walkthroughs[0].steps as { media: { markdown: string }; description: string }[];
  assert.equal(steps.length, 4);
  const ignore = fs.readFileSync(path.join(ext, '.vscodeignore'), 'utf8');
  for (const s of steps) {
    assert.ok(fs.existsSync(path.join(ext, s.media.markdown)), `${s.media.markdown} 不存在`);
    assert.match(s.description, /\]\(command:codexSdlc\.[A-Za-z]+\)/, '每一步都要有一個按鈕');
  }
  assert.doesNotMatch(ignore, /^media/m);
});

test('extension 自己不寫 sdlc.config.json（寫檔只經過 sdlc.ps1 set）', () => {
  // 以前 extension 自己做文字層修改；兩條寫檔路徑、兩套驗證，就是 set 要消掉的東西。
  for (const f of fs.readdirSync(path.join(ext, 'src'))) {
    const code = fs.readFileSync(path.join(ext, 'src', f), 'utf8');
    assert.doesNotMatch(code, /from 'jsonc-parser'[\s\S]*\b(modify|applyEdits)\b/, `${f} 又開始自己改設定檔了`);
    if (/writeFileSync/.test(code)) {
      assert.doesNotMatch(code, /writeFileSync\([^)]*CONFIG_REL/, `${f} 直接寫 sdlc.config.json`);
    }
  }
});
