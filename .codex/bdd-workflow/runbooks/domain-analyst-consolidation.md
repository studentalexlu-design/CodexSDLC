# Domain Analyst — Consolidation（多舊系統合併）

供 `analyst` 在合併多個舊系統的情境下讀取；單一系統/greenfield 情境不需要讀此檔。

## Schema 分析與合併（Consolidation 專用）

當合併多個舊系統時，在資料建模之前：

1. 讀取各舊系統的 `legacy-system-profiles/{system}.md` 的 DB Schema 摘要。
2. 使用 `data-modeling` 技能的 Phase 0，產出 `schema-comparison.md`。
3. 將 schema 級衝突登錄到 active run 的 `source-conflicts.md`（`schema-mismatch` 類型）。
4. 輸出確認選項到終端，請使用者確認合併策略（adopt-a / adopt-b / redesign / union / ✏️ 自行輸入…）。
5. 初步填寫 `data-migration-plan.md` 的表格映射與欄位轉換規則。

## Context Mapping（多系統合併時）

合併多個舊系統時，需重新劃定 bounded context：

1. 從各舊系統的程式碼結構與 DB 邊界識別原始 context。
2. 定義合併後的目標 context，記錄整合策略（Shared Kernel / Anti-Corruption Layer / Open Host Service）。
3. context 決策記錄到 active run 的 `decision-log.md`，必要時摘要回寫全域 `bdd-docs/decision-log.md`。
