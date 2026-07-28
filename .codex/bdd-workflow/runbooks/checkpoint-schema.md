# Checkpoint Schema Runbook

目標：讓 resume 僅需讀最小必要資訊，避免重讀大型檔案。

## Required Fields

- `checkpoint-id`: 唯一識別。
- `run-id`: 目前 run。
- `timestamp`: ISO-8601。
- `stage`: 當前 stage。
- `next-step`: 下一個最小可執行切片。
- `resume-hint`: 不超過 200 字。
- `pending-items`: 尚未完成項目 ID 陣列。
- `open-questions`: 待使用者裁定數量。
- `blocker`: blocker 描述，無則 null。
- `last-artifact-digest`: `{ path, version, digest }`。
- `context-pack-versions`: 例如 `{ domain, stage }`。
- `quality-loop`: 例如 `{ iteration, last-verdict }`。

## Resume 最小讀取順序

1. `workflow-state.json` runtime metadata
2. 最新 checkpoint
3. `pending-items` 對應 artifact path
4. 必要 context pack path + 摘要

## 寫入時機

- doer 回傳 `partial-completed`。
- 網路/連線錯誤後完成恢復判讀。
- stage boundary 切換。
- reviewer FAIL 後更新 quality-loop iteration。

## 驗證規則

- `pending-items` 不可為 null，空陣列代表無待辦。
- `last-artifact-digest` 缺一視為 checkpoint 不完整。
- `next-step` 必須是單一切片，不得為多階段工作。

