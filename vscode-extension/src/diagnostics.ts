// gate 的 -Json → Problems 面板的紀錄。**不 import vscode。**
//
// 這一層不判斷任何規則：哪些檔要掃、哪一行算違規，全部是 guideline-gate／dlp-gate 說了算。
// extension 自己判規則的那一天，就是兩份實作開始分岔、而沒有人知道的那一天。

import { ruleLine } from './config';
import type { DlpGateResult, GuidelineGateResult, RulesValidation } from './contract';

export interface DiagnosticRecord {
  file: string;          // 相對專案根、正斜線 —— gate 回的就是這個形狀
  line: number;          // 1 起算
  severity: 'error' | 'warning';
  message: string;
  code: string;
  source: string;
}

export interface ScanOutcome {
  scanned: string[];     // 這次 gate 真的看過的檔（要清掉舊的診斷）
  records: DiagnosticRecord[];
  note?: string;         // 「被關掉了」這類要讓人知道、但不是某一行的事
}

const norm = (p: string) => p.replace(/\\/g, '/').replace(/^\.\//, '');

export function guidelineOutcome(r: GuidelineGateResult): ScanOutcome {
  const records = r.hits.map<DiagnosticRecord>((h) => ({
    file: norm(h.file),
    line: h.line,
    severity: h.severity === 'block' ? 'error' : 'warning',
    message: h.fix ? `${h.message}（修法：${h.fix}）` : h.message,
    code: h.rule,
    source: 'SDLC 規範',
  }));
  let note: string | undefined;
  if (r.status === 'disabled') note = 'guidelines/.gate-disabled 還在 —— 規範的機械層是關的。';
  else if (r.problems.length > 0) note = `guidelines/rules.json 有 ${r.problems.length} 條載入失敗（該條沒有生效）：${r.problems[0]}`;
  return { scanned: r.files.map(norm), records, note };
}

export function dlpOutcome(r: DlpGateResult): ScanOutcome {
  const records: DiagnosticRecord[] = [];
  for (const f of r.findings) {
    for (const c of f.categories) {
      for (const line of c.lines) {
        // 只有類別與行號 —— gate 從來不回命中的原始值，這裡也沒有東西可以洩漏。
        records.push({
          file: norm(f.file),
          line,
          severity: 'error',
          message: `敏感資料殘留：${c.type}（這個檔在 bdd-docs/ 底下，會跟著流程被讀進 agent 的 context）`,
          code: `dlp-${c.type}`,
          source: 'SDLC DLP',
        });
      }
    }
  }
  return {
    scanned: r.scanned.map(norm),
    records,
    note: r.disabled ? 'bdd-docs/.dlp-disabled 還在 —— 殘留掃描是關的。' : undefined,
  };
}

// 把紀錄依檔分組；沒有紀錄但被掃過的檔也要出現（值是空陣列），呼叫端才會清掉它上一次的診斷。
export function groupByFile(outcome: ScanOutcome, requested: string[]): Map<string, DiagnosticRecord[]> {
  const map = new Map<string, DiagnosticRecord[]>();
  for (const f of [...requested.map(norm), ...outcome.scanned]) map.set(f, []);
  for (const r of outcome.records) {
    const list = map.get(r.file) ?? [];
    list.push(r);
    map.set(r.file, list);
  }
  return map;
}

// rules.json 自己的問題（guideline-gate -Validate -Json）→ Problems。
// 對錯全由 gate 判；這裡只負責把「第幾條、哪個欄位」放到那一行。找不到位置就放第一行 —— 不丟掉。
export const RULES_REL = 'guidelines/rules.json';

export function rulesOutcome(v: RulesValidation, text: string): ScanOutcome {
  const records = v.ruleProblems.map<DiagnosticRecord>((p) => {
    const at = p.index !== null ? ruleLine(text, p.index, p.field) : undefined;
    return {
      file: RULES_REL,
      line: (at ?? 0) + 1,
      severity: 'error',
      message: p.index !== null ? `${p.message}（這一條規則沒有生效，其餘照常）` : `${p.message}（整份規則都沒有生效）`,
      code: p.field ? `rules-${p.field}` : 'rules-file',
      source: 'SDLC 規範',
    };
  });
  return { scanned: [RULES_REL], records };
}
