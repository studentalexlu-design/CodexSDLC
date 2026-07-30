# Runbook: Orchestrator Turn Rules

> 從 `bdd-orchestrator` 指令檔搬出（contract 1.11.0）。
> 只在遇到 `partial-completed`、`pending-items`、transport failure 或需判斷是否續跑時讀取。

## 子代理委派 Preflight

每次 `runSubagent` 前檢查：

- prompt 只描述**一個** operation mode、**一個**目標產物群、**一個**下一步；不得跨 Gate。
- prompt ≤ 1,200 字元。超過時改以更小切片委派；`t3` 且跨階段時可委派 `living-doc` 編譯 context pack。
- 必須傳入 `mode`（如 `new-run`、`checkpoint`、`inventory`、`impact`、`review`、`fix`）。
- 使用 `templates/handoff-{mode}.md` 固定模板；同 mode 不得改段落順序與欄位名稱。
- 有 artifact digest 或 project-profile cache 時，優先傳 digest/cache path 與 hash；不得要求子代理重掃 solution / test toolchain。
- 要求子代理在單一切片完成後回傳 `completed` 或 `partial-completed`，不得自行展開下一階段。
- 同一輪不連續呼叫超過 1 個 doer（**`t3` 限制**；`t1`／`t2` 見 `tier-routing.md` 的合併呼叫規則）。

## analyst 切片守門（full）

- `flow` 一次只允許 1 輪 flow alignment；不得在同一 handoff 要求 analyst 等待使用者回應或直接進入 `example-map`。
- `example-map` 一次只允許 1 個 story；handoff 不得出現「涵蓋所有 stories」「完成整份 example map」或等價要求。
- 同 turn 最多自動續跑 2 個 story；仍有 pending 時**自行**寫 checkpoint，回傳 `partial-completed` 與 resume 指引。
- handoff 優先傳 artifact path/version 與 pending-items，不貼 requirements / schema / context pack 全文。
- 若 analyst work 已跨越 6 分鐘，或前一輪曾發生 transport failure，下一次 handoff 必須縮到最小可恢復切片。
- 目標產物目錄不存在時由該 doer 於寫入時一併建立；**不得為了建目錄開一次 spawn**。

> standard：`analyst`（`mode: example-map`）一次處理整張 example map，不套用上述切片守門。lite 不委派 `analyst`。

## 同 turn 續跑規則

只要目前 user request 還在進行，且最後一個 approval/blocking question 已由使用者在本輪明確裁定，orchestrator **不得**因為剛寫完 checkpoint、decision-recorded 或 metadata-only sync 就結束回覆。

若 `workflow-state`、checkpoint 或 doer 回傳中存在 `pending-items`，且這些 pending 僅屬於內容同步、review 重跑、或同 stage 的下一個最小 resume 切片，**必須在同一個 user request 內繼續委派**，而不是要求「等待下一次指令」。

**只有**以下情況可在同一 user request 內停止：

1. 需要新的使用者裁定、批准或 Gate 通過決策。
2. 發生 transport failure，且已依 `interruption-recovery` 完成 checkpoint 檢查並交由使用者選擇後續處理。
3. 已抵達穩定的 stage boundary，且目前 stage 內沒有剩餘 pending-items 或 blocker。

### 非終止狀態

- `decision-recorded` + `pending-artifact-sync` 只代表「已取得裁定，待同步內容 artifact」。下一個動作必須是同步受影響 artifact，之後立即重跑受影響 reviewer 或繼續目前 stage 的最小切片。
- `partial-completed` 在 blocker 已清空後也不是終止狀態。若 reviewer PASS、blocking questions = 0，且同 stage 仍有未完成 stories 或未完成 artifact sync，必須自動續跑下一個最小切片。
- `atdd-skeleton` / `resume` 回傳 `partial-completed` 時，同 turn 不得重複委派同一切片；必須先**自行**寫 checkpoint，再依 `next-step` 續跑。

在任何 summary / final text 之前，先檢查 active run `resume-hint`、checkpoint `next-step`、`pending-items` 與 `quality-loop`。若顯示仍有本輪可繼續的最小切片 —— **先委派，後摘要**。

## 網路 / 連線錯誤

- 子代理回傳 `net::ERR_EMPTY_RESPONSE`、`network error`、`ECONNRESET`、`timeout`、`Canceled` 或長時間無結果 → 視為 **transport failure**，不視為業務失敗。
- transport failure 後**不得**自動用同一 handoff 重試。先讀 run runtime metadata / checkpoint / 實際產物存在性，再以 `Codex user confirmation` 讓使用者選擇：壓縮重試一次、開新對話 resume、暫停、或自行輸入。
- 選擇壓縮重試 → 重試 prompt 必須比原 prompt 短，且只要求最小可恢復切片。第二次仍失敗就停止委派，建議新對話 resume。
- 嚴格委派模式下，orchestrator 不得用自身工具寫入**產物**作為 fallback（狀態檔例外，見 orchestrator「工具邊界」）。

## Context 膨脹處理

**首選是預防，不是補救。** 常規手段是 Gate 邊界的 context reset（見 orchestrator 指令檔「Gate 邊界的 context reset」）—— Gate 核准時 checkpoint 已完整落地，換對話零資訊損失，且不額外增加一次提問。

本節只處理**兩個 Gate 之間**就已經膨脹的情況：

- 判斷訊號：同一 stage 內累積多輪大型 tool output、上次子代理輸入接近上限、或 `subagent-calls.count` − `count-at-last-reset` 已 ≥ 6 而下一個 Gate 還很遠。
- 處理：先**自行**寫 checkpoint（所有 tier），再以 `Codex user confirmation` 請使用者開新對話 resume。**不在膨脹的 context 中繼續大型委派。**
- resume 後更新 `count-at-last-reset = count`。

兩者的差別只在時機：Gate reset 是計畫內的、隨核准一起發生；本節是計畫外的、需要額外一次確認。能等到下一個 Gate 就等。
