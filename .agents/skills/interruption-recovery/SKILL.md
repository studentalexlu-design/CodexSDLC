---
name: interruption-recovery
version: 1.0.1
description: "Use when: recovering interrupted BDD workflow stages, subagent cancellations, reviewer timeouts, partial-completed doer results, resume checkpoints, stale workflow-state, or transport failures such as net::ERR_EMPTY_RESPONSE."
user-invocable: false
---

# Interruption Recovery Skill

## 使用時機

- 子代理回傳 `Canceled`、`Timeout`、`error`、`network error`、`net::ERR_EMPTY_RESPONSE` 或無回應。
- doer 回傳 `partial-completed`，或產物只有部分寫入。
- reviewer 連續中斷或 token 預算不足。
- resume 時發現 session memory、checkpoint、`workflow-state.json` 與實際產物狀態不一致。
- Gate 檢查前發現 stale checkpoint 或下游產物版本不一致。

## Resume 判斷優先序

1. `/memories/session/active-run.md`（若存在）。
2. `bdd-docs/runs/{run-id}/checkpoints/`。
3. `bdd-docs/runs/{run-id}/workflow-state.json.runtime-metadata`。
4. `bdd-docs/runs/{run-id}/index.md` 與 `log.md` 最近 entries 或 delta。
5. 實際產物存在性與 metadata。

若狀態矛盾，以實際產物存在性與最新 log entry 為準，並委派 `living-doc` 在 checkpoint mode 回寫索引。

## Transport Failure Circuit Breaker

`net::ERR_EMPTY_RESPONSE`、`network error`、`ECONNRESET`、timeout、Canceled 屬 transport failure，不代表子代理已完成或業務判定失敗。

處理規則：

1. 不得靜默停止。
2. 不得自動用同一 prompt 立即重試。
3. 先讀 runtime metadata、checkpoint 與目標產物存在性，判斷是否有部分成果。
4. 用 `Codex user confirmation` 讓使用者選擇：壓縮重試一次、開新對話 resume、暫停、或自行輸入。
5. 壓縮重試必須只要求最小可恢復切片，且比原 prompt 短；第二次仍 transport failure 則停止委派。

在嚴格委派模式下，orchestrator 不得以自身工具直接寫文件作為 fallback。

## Reviewer 中斷降級

第一次中斷後，重呼叫 reviewer 時必須縮小 prompt：

- 只傳產物路徑與版本號。
- 審核焦點最多 3 項。
- 指示 `VERDICT` 必須第一行輸出。
- 跳過 MINOR 級檢查。

第二次仍中斷時，orchestrator 執行 BLOCKER 級最小審核，降級 PASS 前必須以 `Codex user confirmation` 取得使用者同意，並委派 `living-doc` 記錄 decision。

## Doer 部分完成

當 doer 回傳 `partial-completed`：

1. 讀取 completion-summary。
2. 委派 `living-doc` checkpoint mode 寫入部分完成 checkpoint、更新 index/log。
3. 以 `Codex user confirmation` 提供：繼續、先審核已完成部分、暫停流程、或自行輸入。
4. 若繼續，以 resume mode 呼叫 doer，傳入 completed-items 與 pending-items。

## 交付要求

- 恢復後的下一個子代理只收到 stage、mode、產物路徑/版本、上一個 action、未完成項目摘要。
- 任何降級審核、暫停或重試決策都必須記錄到 run 文件。
- 產物狀態與 `workflow-state.json`、`index.md` 不一致時，不得通過 Gate。
