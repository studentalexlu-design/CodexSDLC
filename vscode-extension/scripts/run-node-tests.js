// 跑 out/test/*.test.js。Node 20 的 `node --test <dir>` 行為跟 22 不一樣，所以明確列出檔案。
//
// 單元測試與整合測試分開跑：整合測試真的叫起 pwsh 跑 sdlc.ps1（一次 1 秒多），一整套要兩分鐘；
// 單元測試加起來不到 5 秒。改 UI 邏輯時每次都等兩分鐘，就會有人乾脆不跑。
//   npm test                    單元測試（不含 integration）
//   npm run test:integration    只跑整合測試
//   npm run test:all            全部（pack.ps1 出貨前跑這個）
// 後面再接字串 = 只跑檔名含那個字串的（例如 npm test -- tree）。
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const INTEGRATION = 'integration.test.js';

const dir = path.join(__dirname, '..', 'out', 'test');
if (!fs.existsSync(dir)) {
  console.error('找不到 out/test —— 先跑 npm run build');
  process.exit(1);
}
const args = process.argv.slice(2);
const mode = args.includes('--all') ? 'all' : args.includes('--integration') ? 'integration' : 'unit';
const only = args.filter((a) => !a.startsWith('--'));
const files = fs.readdirSync(dir)
  .filter((f) => f.endsWith('.test.js'))
  .filter((f) => mode === 'all' || (mode === 'integration') === (f === INTEGRATION))
  .filter((f) => only.length === 0 || only.some((o) => f.includes(o)))
  .sort()
  .map((f) => path.join(dir, f));
if (files.length === 0) {
  console.error('沒有任何測試檔');
  process.exit(1);
}
const r = spawnSync(process.execPath, ['--test', ...files], { stdio: 'inherit' });
process.exit(r.status === null ? 1 : r.status);
