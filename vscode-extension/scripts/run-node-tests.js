// 跑 out/test/*.test.js。Node 20 的 `node --test <dir>` 行為跟 22 不一樣，所以明確列出檔案。
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const dir = path.join(__dirname, '..', 'out', 'test');
if (!fs.existsSync(dir)) {
  console.error('找不到 out/test —— 先跑 npm run build');
  process.exit(1);
}
const only = process.argv.slice(2);
const files = fs.readdirSync(dir)
  .filter((f) => f.endsWith('.test.js'))
  .filter((f) => only.length === 0 || only.some((o) => f.includes(o)))
  .sort()
  .map((f) => path.join(dir, f));
if (files.length === 0) {
  console.error('沒有任何測試檔');
  process.exit(1);
}
const r = spawnSync(process.execPath, ['--test', ...files], { stdio: 'inherit' });
process.exit(r.status === null ? 1 : r.status);
