# Checkpoint Schema Runbook

目標：讓 resume 僅需讀最小必要資訊，避免重讀大型檔案。

**owner 是 orchestrator，所有 tier 皆然。** checkpoint、Gate confirmation 紀錄、decision-log entry、DLP 標記與 DB SELECT 授權紀錄都是 orchestrator 手上已有的單點事實，委派 `living-doc` 只多付一次 spawn，不省任何讀取。

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

## 同輪決策的 checkpoint 是暫時性 resume 點，不是停止點

當 checkpoint 記錄的是 `decision-recorded`、`pending-artifact-sync` 或等價的 metadata-only 狀態時：

- `next-step` 必須點名具體待同步目標或下一個最小切片。
- `resume-hint` 必須指出繼續當前 stage，除非仍需新的使用者批准或 transport recovery 選擇。
- **不得**在只剩同 stage artifact 同步、reviewer 重跑或下一個最小切片時，寫出等同「等待下一次指令」的措辭。

## Gate Confirmation 紀錄

Gate 核准後，同時寫入 `decision-log.md` 與該 stage 的 checkpoint。只記錄：

- gate id 與 display name
- reviewed document refs（只含 path/version/digest/evidence refs）
- verification checklist 項目標籤或短摘要
- user decision（`approve-gate`、`return-for-fix`、`pause-workflow`，或自由輸入的摘要）
- 核准後的下一個 stage
- timestamp 與 actor/source（`bdd-orchestrator` + user confirmation）

不得將完整 artifact、secret、DLP mapping table、長 log 或原始敏感來源寫入 decision-log 或 checkpoint。

## DB SELECT 授權紀錄

使用者核准 run-scoped bounded SELECT 後，建立或更新 `bdd-docs/runs/{run-id}/artifacts/db-select-authorization.md`，並補一筆短 decision-log entry。只記錄：

- run id、feature id
- status：`active`／`revoked`／`expired`
- decision-log ref、actor/source、timestamp
- MCP server/profile alias、database/schema、approved table/view、approved columns、approved purpose
- default row limit `50`
- evidence refs 與 digest refs

不得記錄 credentials、connection strings、MCP secrets、raw rows、DLP mapping table 或大型 query output。scope 擴大不得覆蓋原授權，必須保留原決策可追溯並要求新的核准 entry。

## DLP 短路標記

intake 判定「全部來源都不需要脫敏」時，除了在 `mask-audit.md` 記錄，另建立 `bdd-docs/runs/{run-id}/.dlp-disabled`，內容只有一行：決策時間 + 使用者決策摘要。**不得寫入任何敏感值或來源內容。**

- 部分脫敏**不得**建立（該標記會全 run 短路掃描）。
- 撤銷時直接刪除該檔。
- 此標記由 `.codex/scripts/dlp-gate.ps1` 讀取，決定是否跳過 PostToolUse 殘留掃描。

