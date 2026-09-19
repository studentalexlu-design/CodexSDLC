// sdlc.config.json 上方的 CodeLens。**不 import vscode。**
//
// 給習慣直接改檔的人：改完不必切去面板或終端機，就在檔案上方按「套用」；tune 的建議就掛在那個 agent 上，按一下只套那一個。
// 跟面板一樣不判規則 —— 未套用看 doctor，建議看存下來的那份提議（tune -ApplyProposal -Only 套的也是那一份）。

import { agentLine, readConfig } from './config';
import type { StoredProposalItem } from './tree';

export interface LensSpec { line: number; title: string; command: string; arguments: unknown[]; tooltip?: string }

export interface LensInput {
  rootPath: string;
  pendingAgents: string[];
  proposal?: StoredProposalItem[];
  canEdit: boolean;
}

export function configLenses(text: string, i: LensInput): LensSpec[] {
  const lenses: LensSpec[] = [];
  if (i.pendingAgents.length > 0) {
    lenses.push({
      line: 0,
      title: `$(sync) 套用（${i.pendingAgents.length} 個 agent 未套用）`,
      command: 'codexSdlc.apply',
      arguments: [],
      tooltip: `${i.pendingAgents.join('、')} 改了還沒套用 —— 不套用的話流程用的是舊值`,
    });
  }
  lenses.push({ line: 0, title: '$(settings-gear) 在設定面板開啟', command: 'codexSdlc.openSettings', arguments: [] });

  if (!i.canEdit || !i.proposal) return lenses;
  let agents;
  try { agents = readConfig(text).agents; } catch { return lenses; }
  for (const p of i.proposal) {
    const a = agents.find((x) => x.name === p.agent);
    if (!a || a.effort === p.effort) continue;
    const line = agentLine(text, p.agent);
    if (line === undefined) continue;
    lenses.push({
      line,
      title: `$(lightbulb) tune 建議 effort：${p.effort} —— 採用`,
      command: 'codexSdlc.applyProposalFor',
      arguments: [i.rootPath, p.agent],
      tooltip: `${p.agent}：${a.effort} → ${p.effort}（${p.reason}）。只套這一個，套完自動 apply。`,
    });
  }
  return lenses;
}
