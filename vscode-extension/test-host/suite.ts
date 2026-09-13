// 在**真的** VS Code extension host 裡驗打包出來的 vsix（計畫 M1／M1.5 的驗收）。
// 由 scripts/run-host-test.js 啟動：vsix 裝進一個隔離的 extensions 目錄，工作區是一個剛 install 好的暫存專案。

import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';
import type { CockpitApi } from '../src/extension';

async function waitFor(what: string, cond: () => boolean, timeoutMs = 90_000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error(`等不到：${what}`);
    await new Promise((r) => setTimeout(r, 250));
  }
}

export async function run(): Promise<void> {
  const log = (m: string) => console.log(`[host-test] ${m}`);
  const workspace = process.env.CODEX_SDLC_HOST_WORKSPACE!;
  const version = process.env.CODEX_SDLC_HOST_VERSION!;
  assert.ok(workspace && version, '缺 CODEX_SDLC_HOST_WORKSPACE／CODEX_SDLC_HOST_VERSION');

  const ext = vscode.extensions.getExtension<CockpitApi>('codex-sdlc.codex-sdlc');
  assert.ok(ext, 'vsix 沒有裝進 extension host');
  assert.equal(ext.packageJSON.version, version, '裝進去的不是這一版的 vsix');
  const api = await ext.activate();
  log(`activated ${ext.packageJSON.version}; roots=${JSON.stringify(api.roots())}`);

  // 1. 狀態列出現版本
  await api.refresh();
  const first = api.status();
  log(`status: ${first?.text}`);
  assert.ok(first, '沒有狀態');
  assert.match(first.text, new RegExp(`SDLC ${version.replace(/\./g, '\\.')}`), `狀態列沒有版本：${first.text} / ${first.tooltip.join(' | ')}`);

  // 2. 改 sdlc.config.json 不 apply → 立刻看到漂移（靠 file watcher，不是我們手動 refresh）
  const cfg = path.join(workspace, 'sdlc.config.json');
  const json = JSON.parse(fs.readFileSync(cfg, 'utf8'));
  json.agents.reviewer.effort = 'high';
  fs.writeFileSync(cfg, JSON.stringify(json, null, 2));
  await waitFor('改了設定之後狀態列顯示漂移', () => /調校未套用/.test(api.status()?.text ?? ''));
  log(`status after edit: ${api.status()?.text}`);

  // 3. 按 apply（真的指令）→ doctor 綠（SDLC-TUNING sha 對得上）
  await vscode.commands.executeCommand('codexSdlc.apply');
  await waitFor('apply 之後調校一致', () => api.doctor()?.tuning.status === 'in-sync');
  log(`status after apply: ${api.status()?.text}`);
  assert.doesNotMatch(api.status()!.text, /調校未套用/);

  // 4. 存檔 → Problems 出現規範違規
  const sql = path.join(workspace, 'src', 'q.sql');
  fs.mkdirSync(path.dirname(sql), { recursive: true });
  fs.writeFileSync(sql, 'SELECT 1\nSELECT Id FROM Orders WITH (NOLOCK)\n');
  const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(sql));
  await vscode.window.showTextDocument(doc);
  await api.scan(doc.uri);
  await waitFor('Problems 出現 sql-no-nolock', () => api.diagnostics(doc.uri).some((d) => d.code === 'sql-no-nolock'), 60_000);
  const hit = api.diagnostics(doc.uri).find((d) => d.code === 'sql-no-nolock')!;
  log(`diagnostic: line ${hit.range.start.line + 1} ${vscode.DiagnosticSeverity[hit.severity]} ${hit.message}`);
  assert.equal(hit.range.start.line, 1);
  assert.equal(hit.severity, vscode.DiagnosticSeverity.Error);
  assert.match(hit.message, /禁止 NOLOCK/);

  log('all host checks passed');
}
