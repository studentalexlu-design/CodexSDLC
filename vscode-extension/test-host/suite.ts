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

  // ---- 設定體驗（docs/settings-ux-plan.md 的 S0–S4）----
  const cfgUri = vscode.Uri.file(cfg);
  const rulesPath = path.join(workspace, 'guidelines', 'rules.json');
  const rulesUri = vscode.Uri.file(rulesPath);
  const lineOf = (file: string, needle: string) => fs.readFileSync(file, 'utf8').split(/\r?\n/).findIndex((l) => l.includes(needle));
  const schemaDiag = (uri: vscode.Uri, line: number) =>
    vscode.languages.getDiagnostics(uri).find((d) => d.range.start.line === line && !String(d.source ?? '').startsWith('SDLC'));

  // 5. 動手前要先驗證的第 1 件：VS Code 認不認 $schema 的相對路徑 —— 沒有任何 extension 幫忙（我們沒有註冊 jsonValidation）。
  const goodCfg = fs.readFileSync(cfg, 'utf8');
  assert.match(goodCfg, /"\$schema": "\.\/\.codex\/bdd-workflow\/sdlc\.config\.schema\.json"/, 'install 沒寫 $schema');
  fs.writeFileSync(cfg, goodCfg.replace(/("sa-analyst":\s*\{[^}]*"effort":\s*)"[a-z]+"/, '$1"hgih"'));
  const cfgDoc = await vscode.workspace.openTextDocument(cfgUri);
  await vscode.window.showTextDocument(cfgDoc);
  const badLine = lineOf(cfg, '"hgih"');
  assert.ok(badLine >= 0, '測試自己沒把 hgih 寫進去');
  await waitFor('sdlc.config.json 的 hgih 出現 schema 的波浪線', () => !!schemaDiag(cfgUri, badLine), 60_000);
  log(`schema diagnostic (config): line ${badLine + 1} ${schemaDiag(cfgUri, badLine)!.message}`);

  const goodRules = fs.readFileSync(rulesPath, 'utf8');
  assert.match(goodRules, /"\$schema": "\.\.\/\.codex\/bdd-workflow\/rules\.schema\.json"/, 'rules.json 骨架沒有 $schema');
  fs.writeFileSync(rulesPath, goodRules.replace('"severity": "block"', '"severity": "blok"'));
  const rulesDoc = await vscode.workspace.openTextDocument(rulesUri);
  await vscode.window.showTextDocument(rulesDoc);
  const blokLine = lineOf(rulesPath, '"blok"');
  await waitFor('rules.json 的 blok 出現 schema 的波浪線（../ 的相對路徑）', () => !!schemaDiag(rulesUri, blokLine), 60_000);
  log(`schema diagnostic (rules): line ${blokLine + 1} ${schemaDiag(rulesUri, blokLine)!.message}`);

  // 6. rules.json 存檔 → 我們自己的 Problems（guideline-gate -Validate 判、extension 只定位）落在同一行
  await api.scan(rulesUri);
  await waitFor('rules.json 的問題進了 Problems', () => api.diagnostics(rulesUri).some((d) => d.source === 'SDLC 規範'), 60_000);
  const ruleHit = api.diagnostics(rulesUri).find((d) => d.source === 'SDLC 規範')!;
  assert.equal(ruleHit.range.start.line, blokLine, `問題沒有落在寫壞的那一行：${ruleHit.message}`);
  fs.writeFileSync(rulesPath, goodRules);
  fs.writeFileSync(cfg, goodCfg);
  await waitFor('設定檔改回來之後波浪線消失', () => !schemaDiag(cfgUri, badLine), 60_000);

  // 7. 設定面板：在裝了工作流的工作區出現（context key ＋ when ＋ 面板註冊，三者一起驗）
  await vscode.commands.executeCommand('codexSdlc.openSettings');
  await waitFor('設定面板打開', () => api.settingsViewVisible(), 30_000);
  await api.refresh();
  const tree = api.settingsTree();
  assert.deepEqual(tree.map((n) => n.label), ['狀態', 'Agent 調校', '審核', '更新', '規範', '這台機器']);
  log(`settings tree: ${tree.map((n) => `${n.label}${n.description ? `(${n.description})` : ''}`).join(' / ')}`);

  // 8. 改三個值 → apply 只跑一次（計畫 S2 的驗收）；順便量「現況」與「S2」各等多久（動手前要先驗證的第 3 件）
  const flat = (nodes: typeof tree): typeof tree => nodes.flatMap((n) => [n, ...flat(n.children ?? [])]);
  const values = ['agents.reviewer.effort', 'agents.sa-analyst.effort', 'agents.implementer.effort'];
  let t0 = Date.now();
  for (const [i, key] of values.entries()) {
    await api.writeSettings([`${key}=${['low', 'medium', 'high'][i]}`], { apply: true, quiet: true });
    await api.refresh();
  }
  const oldFlowMs = Date.now() - t0;

  const before = api.calls();
  t0 = Date.now();
  for (const [i, key] of values.entries()) {
    const d = await api.writeSettings([`${key}=${['medium', 'low', 'inherit'][i]}`], { quiet: true });
    assert.equal(d?.error, null, `set 失敗：${JSON.stringify(d)}`);
  }
  const writesMs = Date.now() - t0;
  const pendingNode = flat(api.settingsTree()).find((n) => n.id === 'agents')!;
  assert.equal(pendingNode.contextValue, 'tuningPending', '寫完沒標未套用 —— 面板上看不出要按套用');
  assert.match(pendingNode.description ?? '', /3 項未套用/);
  await vscode.commands.executeCommand('codexSdlc.apply');
  await waitFor('套用之後調校一致', () => api.doctor()?.tuning.status === 'in-sync');
  const newFlowMs = Date.now() - t0;
  const after = api.calls();
  assert.equal((after.apply ?? 0) - (before.apply ?? 0), 1, '改三個值卻 apply 了不只一次');
  assert.equal((after.set ?? 0) - (before.set ?? 0), 3);
  assert.equal(flat(api.settingsTree()).find((n) => n.id === 'agents')!.contextValue, undefined, '套用完還掛著「套用」按鈕');
  log(`timing: 現況（每個值 set+apply+doctor）${oldFlowMs} ms；S2（三次 set 共 ${writesMs} ms，之後一次 apply+doctor）${newFlowMs} ms`);
  const reviewerToml = fs.readFileSync(path.join(workspace, '.codex/agents/reviewer.toml'), 'utf8');
  assert.match(reviewerToml, /model_reasoning_effort = "medium"/);

  // 9. set 擋下不合法的值：檔案不動
  const cfgBefore = fs.readFileSync(cfg, 'utf8');
  const bad = await api.writeSettings(['review.maxRounds=9'], { quiet: true });
  assert.equal(bad?.error, 'invalid');
  assert.equal(fs.readFileSync(cfg, 'utf8'), cfgBefore);

  // 10. CodeLens：tune 的建議掛在那個 agent 上，按下去只套那一個
  const proposalPath = path.join(workspace, 'bdd-docs/.sdlc/tuning-proposal.json');
  fs.mkdirSync(path.dirname(proposalPath), { recursive: true });
  fs.writeFileSync(proposalPath, JSON.stringify({
    'generated-at': new Date().toISOString(),
    signals: {},
    proposal: [
      { agent: 'reviewer', effort: 'high', reason: '判斷密度高', signal: '一律' },
      { agent: 'implementer', effort: 'max', reason: '測試用', signal: '—' },
    ],
  }));
  let lenses: vscode.CodeLens[] = [];
  await waitFor('tune 的建議出現在 CodeLens', () => {
    void vscode.commands.executeCommand<vscode.CodeLens[]>('vscode.executeCodeLensProvider', cfgUri).then((l) => { lenses = l ?? []; });
    return lenses.some((l) => l.command?.command === 'codexSdlc.applyProposalFor' && (l.command.arguments ?? [])[1] === 'reviewer');
  }, 30_000);
  const lens = lenses.find((l) => l.command?.command === 'codexSdlc.applyProposalFor' && (l.command.arguments ?? [])[1] === 'reviewer')!;
  log(`codelens: line ${lens.range.start.line + 1} ${lens.command!.title}`);
  await vscode.commands.executeCommand(lens.command!.command, ...(lens.command!.arguments ?? []));
  const cfgAfter = JSON.parse(fs.readFileSync(cfg, 'utf8'));
  assert.equal(cfgAfter.agents.reviewer.effort, 'high');
  assert.equal(cfgAfter.agents.implementer.effort, 'inherit', 'CodeLens 只該套那一個 agent');

  // 11. 引導、合併對照、補工具檔叫得起來（沒有 .new 時只會說「沒有要合併的東西」，不會卡住）
  await vscode.commands.executeCommand('codexSdlc.openWalkthrough');
  await vscode.commands.executeCommand('codexSdlc.mergeAgents');

  log('all host checks passed');
}
