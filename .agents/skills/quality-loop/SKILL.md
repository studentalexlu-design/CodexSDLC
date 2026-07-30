---
name: quality-loop
version: 1.1.0
description: "Use when: orchestrating doer-reviewer loops, reviewer prompt budgeting, PASS/FAIL verdict parsing, defect-driven revision, quality loop checkpoints, or gate-ready review decisions."
user-invocable: false
---

# Quality Loop Skill

## 使用時機

- Domain Analysis、analyst、Formulate、ATDD、TDD 需要「做事 → 審核 → 修正」。
- reviewer 回傳 `VERDICT: FAIL`，需要將缺陷摘要交回 doer。
- reviewer prompt 需要縮短，避免 token 預算耗盡。
- Gate 通過前需要判定產物是否達到可交付狀態。

## 標準流程

```text
1. orchestrator -> doer: 產出 v1
2. orchestrator -> reviewer: 審核 v1
3. PASS -> 下一階段
4. FAIL -> doer 修正 v2 -> reviewer 再審
5. 最多 3 輪；仍 FAIL 則交由使用者裁定
```

Doer 與 reviewer 永遠分開呼叫。Doer 不得自行宣告審核通過；PASS/FAIL 只由 reviewer 或降級審核結果決定。

## Doer / Reviewer 對照

| 階段 | Doer | Reviewer |
|---|---|---|
| Domain Analysis | `analyst` | `spec-reviewer`（`mode: domain`） |
| analyst | `analyst` | `spec-reviewer`（`mode: example-map`） |
| Formulate | `formulator` | `spec-reviewer`（`mode: gherkin`） |
| ATDD | `atdd-automator` | `code-reviewer`（`mode: atdd`） |
| TDD | `tdd-implementer` | `code-reviewer`（`mode: tdd`） |

## Reviewer 回傳契約

Reviewer 第一行必須輸出：

```text
VERDICT: PASS | FAIL
BLOCKER_COUNT: {n}
MAJOR_COUNT: {n}
MINOR_COUNT: {n}
```

- 存在 BLOCKER 或 MAJOR：`FAIL`。
- 僅 MINOR：`PASS`，但附建議。
- 若需要使用者裁定，缺陷列需標記 `Approval_Required: yes`。

## Doer 回傳契約

Doer 必須回傳：

- 狀態：`completed`、`partial-completed`、`blocked`、`error`，或 analyst 專屬 pause 狀態。
- 產出摘要：≤ 500 字。
- 產物路徑與版本。
- `partial-completed` 時附 `completion-summary`。

analyst 額外附：`glossary_delta` 與 `domain-check-completed`。

## Reviewer Prompt 預算規範

呼叫 reviewer 時，prompt 必須只傳：

- 產物檔案路徑，不嵌入全文。
- 版本號。
- doer 變更摘要，≤ 500 字。
- 審核焦點，最多 5 項；重試時最多 3 項。
- 修正輪只傳「未修正缺陷摘要」，不得貼完整歷史缺陷清單。

禁止在 reviewer prompt 中嵌入：完整 glossary、完整 example-map、來源素材全文、超過 3 個產物全文或大量測試輸出。

## Prompt 模板

```text
請審核以下產物：
- 路徑：{artifact-path}
- 版本：v{N}
- 變更摘要：{summary}
- 審核焦點：{focus-items}
{若為修正輪} 上輪未修正缺陷：{pending-defects-summary}

請自行讀取檔案內容後回傳 VERDICT。
```

## 缺陷驅動修正

當 reviewer 回傳 FAIL：

1. 萃取 BLOCKER 與 MAJOR 缺陷，保留缺陷 ID、位置、原因、建議修正。
2. **遞增** `working-state.quality-loop.iteration`（由 orchestrator 自行維護；`handoff-lint` 讀此欄位強制上限）。
3. orchestrator 自行寫入品質迴圈 checkpoint。
4. **Preflight 檢查**：若 `iteration >= 3`，禁止再呼叫 doer + reviewer，以 `Codex user confirmation` 升級使用者裁定。
5. 若 `iteration < 3`，呼叫 doer 修正，只傳必要缺陷摘要與目標產物。
6. 修正完成後重新呼叫同一 reviewer。
7. 第 4 輪為絕對上限（僅在使用者裁定指定重點後允許）；仍 FAIL 則強制停止。

## Gate 前最小驗證

品質迴圈 PASS 之後，進入 Gate 前仍需確認：

- 產物檔案存在且可讀。
- metadata 包含 `id`、`version`、`status`。
- `status` 不得為 `draft`，除非該 Gate 明確允許。
- 下游產物記錄的 upstream version 一致。
- `index.md` 與 `workflow-state.json` 對同一產物狀態一致。

不一致時先修復狀態再重新評估 Gate；索引層級的不一致在 `t3` 可委派 `living-doc`（`mode: lint`）。
