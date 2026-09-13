// 調校 UI 的文字層：讀／改 sdlc.config.json 裡某個 agent 的 model／effort。**不 import vscode。**
//
// 唯一真相仍是 sdlc.config.json —— extension 只改那個檔，然後叫 sdlc.ps1 apply 產生 toml 區塊。
// 它不自己寫 toml、不自己算 SDLC-TUNING 的 sha（那是 sdlc.ps1 與 agent-lint 之間的合約）。
//
// 改檔用**文字層的插入**（jsonc-parser 的 modify），不是 parse → 改 → stringify：
// 使用者的檔可能有註解、有自己的縮排，整份重新序列化會把它們吃掉，而且不會有人立刻發現。

import { applyEdits, modify, parse, type ParseError } from 'jsonc-parser';

// inherit = 產生出來的 toml 裡不寫那一行，交給 Codex CLI 決定。它是每個 agent 的預設 ——
// 1d8e411 把四個 agent 全釘 high，大型 legacy repo 的分析就逾時了。
export const EFFORTS = ['inherit', 'minimal', 'low', 'medium', 'high'] as const;

export interface AgentTuning { name: string; model: string; effort: string }

export function readAgents(text: string): AgentTuning[] {
  const errors: ParseError[] = [];
  const root = parse(text, errors, { allowTrailingComma: true, disallowComments: false });
  if (errors.length > 0 || typeof root !== 'object' || root === null) {
    throw new Error('sdlc.config.json 解析不了 —— 先把 JSON 修好（apply 與 doctor 也讀不到它）');
  }
  const agents = (root as Record<string, unknown>).agents;
  if (typeof agents !== 'object' || agents === null) return [];
  return Object.entries(agents as Record<string, Record<string, unknown>>).map(([name, v]) => ({
    name,
    model: typeof v?.model === 'string' ? v.model : 'inherit',
    effort: typeof v?.effort === 'string' ? v.effort : 'inherit',
  }));
}

function detectFormatting(text: string): { insertSpaces: boolean; tabSize: number; eol: string } {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const m = /\n([ \t]+)"/.exec(text);
  if (m && m[1].startsWith('\t')) return { insertSpaces: false, tabSize: 1, eol };
  return { insertSpaces: true, tabSize: m ? Math.min(m[1].length, 8) : 2, eol };
}

export function setAgentValue(text: string, agent: string, key: 'model' | 'effort', value: string): string {
  readAgents(text); // 壞掉的檔不動它 —— 在壞掉的 JSON 上做文字插入，只會把它弄得更壞
  const edits = modify(text, ['agents', agent, key], value, { formattingOptions: detectFormatting(text) });
  return applyEdits(text, edits);
}

// ⑤ 的修正輪上限（review.maxRounds）。合法範圍由 handoff-lint 與 agent-lint 判；這裡只提供那個範圍的選項，
// 寫進去的一定是整數 —— 寫成字串 "3" 的話 hook 不採用，而那正是最容易手寫錯的形狀。
export const REVIEW_ROUNDS = [1, 2, 3, 4, 5] as const;

export function readReviewMaxRounds(text: string): unknown {
  readAgents(text);
  const root = parse(text, [], { allowTrailingComma: true, disallowComments: false }) as Record<string, unknown>;
  const review = root.review;
  return typeof review === 'object' && review !== null ? (review as Record<string, unknown>).maxRounds : undefined;
}

export function setReviewMaxRounds(text: string, rounds: number): string {
  readAgents(text);
  if (!Number.isInteger(rounds)) throw new Error(`修正輪上限要是整數，收到 ${rounds}`);
  const edits = modify(text, ['review', 'maxRounds'], rounds, { formattingOptions: detectFormatting(text) });
  return applyEdits(text, edits);
}
