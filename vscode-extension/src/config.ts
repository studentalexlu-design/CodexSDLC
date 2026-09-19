// 讀 sdlc.config.json／guidelines/rules.json 來「顯示」與「定位」。**不 import vscode，也不寫檔。**
//
// 寫檔一律交給 `sdlc.ps1 set`：它先依 schema 驗完全部的值才寫。extension 以前自己做文字層的修改，
// 結果是兩條寫檔路徑、兩套驗證 —— 而其中一條（update／tune）會吃掉註解，另一條不會。
// 現在設定檔宣告不支援註解，寫的人只有一個。
//
// 這裡讀到的值只拿來畫面板；對錯（合不合法、有沒有套用）一律看 doctor 與 schema。

import { findNodeAtLocation, parse, parseTree, type Node, type ParseError } from 'jsonc-parser';

export interface AgentValues { name: string; model: string; effort: string }

export interface ConfigSnapshot {
  agents: AgentValues[];
  reviewMaxRounds: unknown;     // 沒設 = undefined；型別不對就原樣給（面板會說它寫壞了）
  updateCheck: unknown;
  updateSource: unknown;
  hasSchemaRef: boolean;
}

type Json = Record<string, unknown>;
const isObj = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);

export class ConfigReadError extends Error {}

export function readConfig(text: string): ConfigSnapshot {
  const errors: ParseError[] = [];
  const root = parse(text, errors, { allowTrailingComma: true, disallowComments: false });
  if (errors.length > 0 || !isObj(root)) {
    throw new ConfigReadError('sdlc.config.json 解析不了 —— 先把 JSON 修好（apply、doctor 與 set 也讀不到它）');
  }
  const agents = isObj(root.agents) ? root.agents : {};
  const order = (n: string) => (n === 'orchestrator' ? 1 : 0);   // orchestrator 只是記錄，排最後
  return {
    agents: Object.entries(agents)
      .map(([name, v]) => ({
        name,
        model: isObj(v) && typeof v.model === 'string' ? v.model : 'inherit',
        effort: isObj(v) && typeof v.effort === 'string' ? v.effort : 'inherit',
      }))
      .sort((a, b) => order(a.name) - order(b.name)),
    reviewMaxRounds: isObj(root.review) ? root.review.maxRounds : undefined,
    updateCheck: isObj(root.update) ? root.update.check : undefined,
    updateSource: isObj(root.update) ? root.update.source : undefined,
    hasSchemaRef: typeof root.$schema === 'string',
  };
}

// 0 起算的行號。
function lineOf(text: string, offset: number): number {
  let n = 0;
  for (let i = 0; i < offset && i < text.length; i++) if (text.charCodeAt(i) === 10) n++;
  return n;
}
function propertyLine(text: string, node: Node | undefined): number | undefined {
  // findNodeAtLocation 回的是值；它的 parent 是 property（key 所在的那一行才是人眼找的位置）
  if (!node) return undefined;
  return lineOf(text, node.parent?.type === 'property' ? node.parent.offset : node.offset);
}

export function agentLine(text: string, agent: string): number | undefined {
  const tree = parseTree(text, [], { allowTrailingComma: true, disallowComments: false });
  return tree ? propertyLine(text, findNodeAtLocation(tree, ['agents', agent])) : undefined;
}

// rules.json 的第 index 條（1 起算）規則；給了欄位就定位到那個欄位，那條規則沒有那個欄位就停在規則的開頭。
export function ruleLine(text: string, index: number, field?: string | null): number | undefined {
  const tree = parseTree(text, [], { allowTrailingComma: true, disallowComments: false });
  if (!tree) return undefined;
  const rule = findNodeAtLocation(tree, ['rules', index - 1]);
  if (!rule) return undefined;
  if (field) {
    const f = findNodeAtLocation(rule, [field]);
    if (f) return propertyLine(text, f);
  }
  return lineOf(text, rule.offset);
}

export function countRules(text: string): number | undefined {
  const root = parse(text, [], { allowTrailingComma: true, disallowComments: false });
  return isObj(root) && Array.isArray(root.rules) ? root.rules.length : undefined;
}
