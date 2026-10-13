// 專案裡的 sdlc.config.schema.json → 設定面板要的選項與說明。**不 import vscode。**
//
// 合法值只有一份，在工作流那邊（.codex/bdd-workflow/sdlc.config.schema.json）：`sdlc.ps1 set` 用它驗、
// VS Code 的 JSON 支援用它畫波浪線、這裡用它列選項。extension 自己不寫任何一份清單 ——
// 寫了，下一次 Codex 多一個 effort 值，面板會是最晚被發現沒跟上的那一個。
// schema 的形狀跟這裡對不上時明講（丟 ContractError），不猜。

import * as fs from 'node:fs';
import * as path from 'node:path';
import { ContractError } from './contract';

export const CONFIG_SCHEMA_REL = '.codex/bdd-workflow/sdlc.config.schema.json';

export interface Choice { value: string; label: string; description: string }

export interface SettingsSchema {
  effort: { choices: Choice[]; description: string; agentHints: Record<string, Record<string, string>> };
  model: { description: string; examples: string[]; pattern?: string; patternError: string };
  reviewRounds: { min: number; max: number; default: number; title: string; description: string };
  updateCheck: { choices: Choice[]; default: string; title: string; description: string };
  updateSource: { pattern: string; patternError: string; title: string; description: string };
}

type Json = Record<string, unknown>;
const isObj = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);

function at(root: unknown, pathSegments: string[]): unknown {
  let node = root;
  for (const s of pathSegments) {
    if (!isObj(node) || !(s in node)) throw new ContractError(`sdlc.config.schema.json 缺 ${pathSegments.join('.')}`);
    node = node[s];
  }
  return node;
}
// 給了 fallback 的是「有會比較好」的說明文字；沒給的是面板少了它就不能運作的值。
function text(root: unknown, p: string[], fallback?: string): string {
  let v: unknown;
  try { v = at(root, p); } catch (e) { if (fallback !== undefined) return fallback; throw e; }
  if (typeof v === 'string') return v;
  if (fallback !== undefined) return fallback;
  throw new ContractError(`sdlc.config.schema.json 的 ${p.join('.')} 應為字串`);
}
const integer = (root: unknown, p: string[]): number => {
  const v = at(root, p);
  if (typeof v !== 'number' || !Number.isInteger(v)) throw new ContractError(`sdlc.config.schema.json 的 ${p.join('.')} 應為整數`);
  return v;
};
function choices(node: unknown, where: string): Choice[] {
  const values = isObj(node) ? node.enum : undefined;
  if (!Array.isArray(values) || values.length === 0 || !values.every((x) => typeof x === 'string')) {
    throw new ContractError(`sdlc.config.schema.json 的 ${where}.enum 應為字串陣列`);
  }
  const descs = isObj(node) && Array.isArray(node.enumDescriptions) ? node.enumDescriptions : [];
  const labels = isObj(node) && Array.isArray(node['x-labels']) ? node['x-labels'] : [];
  return (values as string[]).map((value, i) => ({
    value,
    label: typeof labels[i] === 'string' ? (labels[i] as string) : value,
    description: typeof descs[i] === 'string' ? (descs[i] as string) : '',
  }));
}

export function parseSettingsSchema(raw: string): SettingsSchema {
  let root: unknown;
  try { root = JSON.parse(raw); } catch { throw new ContractError('sdlc.config.schema.json 不是合法的 JSON'); }

  const effortNode = at(root, ['definitions', 'effort']);
  const hintsRaw = isObj(effortNode) && isObj(effortNode['x-agent-hints']) ? effortNode['x-agent-hints'] : {};
  const agentHints: Record<string, Record<string, string>> = {};
  for (const [agent, hints] of Object.entries(hintsRaw)) {
    if (!isObj(hints)) continue;
    agentHints[agent] = Object.fromEntries(Object.entries(hints).filter(([, v]) => typeof v === 'string')) as Record<string, string>;
  }

  const modelNode = at(root, ['definitions', 'model']);
  const examples = isObj(modelNode) && Array.isArray(modelNode.examples) ? modelNode.examples.filter((x): x is string => typeof x === 'string') : [];

  const rounds = ['properties', 'review', 'properties', 'maxRounds'];
  const check = ['properties', 'update', 'properties', 'check'];
  const source = ['properties', 'update', 'properties', 'source'];
  return {
    effort: { choices: choices(effortNode, 'definitions.effort'), description: text(root, ['definitions', 'effort', 'description'], ''), agentHints },
    model: {
      description: text(root, ['definitions', 'model', 'description'], ''),
      examples,
      pattern: text(root, ['definitions', 'model', 'pattern'], '') || undefined,
      patternError: text(root, ['definitions', 'model', 'patternErrorMessage'], '格式不對'),
    },
    reviewRounds: {
      min: integer(root, [...rounds, 'minimum']),
      max: integer(root, [...rounds, 'maximum']),
      default: integer(root, [...rounds, 'default']),
      title: text(root, [...rounds, 'title'], '修正輪上限'),
      description: text(root, [...rounds, 'description'], ''),
    },
    updateCheck: {
      choices: choices(at(root, check), 'update.check'),
      default: text(root, [...check, 'default']),
      title: text(root, [...check, 'title'], '檢查頻率'),
      description: text(root, [...check, 'description'], ''),
    },
    updateSource: {
      pattern: text(root, [...source, 'pattern']),
      patternError: text(root, [...source, 'patternErrorMessage'], '格式不對'),
      title: text(root, [...source, 'title'], '來源'),
      description: text(root, [...source, 'description'], ''),
    },
  };
}

// 專案裡沒有 schema（4.9.0 以前的工作流）→ undefined：面板只顯示、不給改。
export function readSettingsSchema(root: string): SettingsSchema | undefined {
  let raw: string;
  try { raw = fs.readFileSync(path.join(root, CONFIG_SCHEMA_REL), 'utf8'); } catch { return undefined; }
  return parseSettingsSchema(raw);
}

// 某個 agent 的 effort 選項：通用說明之外，疊上 schema 給那個 agent 的提醒（例如 sa-analyst 不要 high）。
export function effortChoicesFor(schema: SettingsSchema, agent: string): Choice[] {
  const hints = schema.effort.agentHints[agent] ?? {};
  return schema.effort.choices.map((c) => ({ ...c, description: hints[c.value] ? `${hints[c.value]}${c.description ? `（${c.description}）` : ''}` : c.description }));
}

// JSON schema 的 pattern 是 ECMAScript regex，跟這裡同一種 —— 只拿來給輸入框即時提示，寫不寫得進去仍由 sdlc.ps1 set 判。
export function matchesPattern(pattern: string | undefined, value: string): boolean {
  if (!pattern) return true;
  try { return new RegExp(pattern).test(value); } catch { return true; }
}
