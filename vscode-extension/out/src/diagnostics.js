"use strict";
// gate 的 -Json → Problems 面板的紀錄。**不 import vscode。**
//
// 這一層不判斷任何規則：哪些檔要掃、哪一行算違規，全部是 guideline-gate／dlp-gate 說了算。
// extension 自己判規則的那一天，就是兩份實作開始分岔、而沒有人知道的那一天。
Object.defineProperty(exports, "__esModule", { value: true });
exports.guidelineOutcome = guidelineOutcome;
exports.dlpOutcome = dlpOutcome;
exports.groupByFile = groupByFile;
const norm = (p) => p.replace(/\\/g, '/').replace(/^\.\//, '');
function guidelineOutcome(r) {
    const records = r.hits.map((h) => ({
        file: norm(h.file),
        line: h.line,
        severity: h.severity === 'block' ? 'error' : 'warning',
        message: h.fix ? `${h.message}（修法：${h.fix}）` : h.message,
        code: h.rule,
        source: 'SDLC 規範',
    }));
    let note;
    if (r.status === 'disabled')
        note = 'guidelines/.gate-disabled 還在 —— 規範的機械層是關的。';
    else if (r.problems.length > 0)
        note = `guidelines/rules.json 有 ${r.problems.length} 條載入失敗（該條沒有生效）：${r.problems[0]}`;
    return { scanned: r.files.map(norm), records, note };
}
function dlpOutcome(r) {
    const records = [];
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
function groupByFile(outcome, requested) {
    const map = new Map();
    for (const f of [...requested.map(norm), ...outcome.scanned])
        map.set(f, []);
    for (const r of outcome.records) {
        const list = map.get(r.file) ?? [];
        list.push(r);
        map.set(r.file, list);
    }
    return map;
}
