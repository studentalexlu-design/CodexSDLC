---
name: code-review
version: 1.0.0
description: 以結構化格式回報審核結果與修正建議
---

# Code Review Skill

所有 reviewer 都必須使用以下結構化格式回應，供 orchestrator 解析並驅動品質迴圈。

## 回傳結構（強制）

每次審核回傳必須包含以下兩個區塊，缺一不可：

### 區塊 1：VERDICT 摘要

```
VERDICT: PASS | FAIL
BLOCKER_COUNT: {n}
MAJOR_COUNT: {n}
MINOR_COUNT: {n}
ITERATION: {當前迭代輪次，由 orchestrator 傳入}
```

**判定規則：**
- 存在任何 BLOCKER 或 MAJOR → 必須判 `FAIL`
- 僅有 MINOR → 可判 `PASS`（附建議）
- 無缺陷 → 判 `PASS`

### 區塊 2：結構化缺陷清單

| Severity | File_Path | Line_Range | Defect_Type | Suggested_Code_Change | Approval_Required | Linked_Test | Rollback_Note |
| --- | --- | --- | --- | --- | --- | --- | --- |

## 欄位說明

- `Severity`: BLOCKER / MAJOR / MINOR
- `File_Path`: 檔案路徑
- `Line_Range`: 行號範圍；不明時填 `n/a`
- `Defect_Type`: 例如 Architecture / Reliability / Naming / Scope / Contract / Completeness / Readability
- `Suggested_Code_Change`: 具體修正建議，不接受只有抽象評論
- `Approval_Required`: yes / no — 標記是否需要使用者裁定
- `Linked_Test`: 對應測試名稱或情境
- `Rollback_Note`: 若要回退應注意的事項

## 原則

- 不接受只有抽象評論、沒有落點的回饋。
- 每個 BLOCKER / MAJOR 必須有具體的 `Suggested_Code_Change`。
- 若問題屬於需求不明，應標為 `Approval_Required: yes`，orchestrator 會輸出選項到終端處理。
- 審核者必須獨立判斷，不受 doer 的自我評估影響。
- 迭代修正時，reviewer 需確認先前指出的缺陷是否已修正，並在缺陷清單中標記 `[FIXED]` 或 `[REMAINING]`。
