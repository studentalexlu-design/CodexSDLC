# TDD Implementer — 全量 Acceptance 驗收與 Smoke Test

供 `tdd-implementer` 在完成所有 TDD 切片、回傳 `completed` 之前讀取。

## 全量 Acceptance 驗收（完成前強制）

**所有 TDD 切片完成後、回傳 `completed` 之前**，必須執行以下驗收步驟：

1. 執行完整 acceptance test suite（例如 `dotnet test` 指定 acceptance / specs test project，或使用 `--filter Category=Acceptance`）。
2. 分析測試結果，分類為以下三種：
   - **passed**：情景執行成功
   - **failed**：情景執行失敗（assertion 不通過或 runtime 錯誤）
   - **pending**：step definition 存在但標記為 pending / not implemented，或 step binding 找不到
3. 若有 **failed** 情景 → 將失敗的情景視為新的待修切片，繼續 Red-Green-Refactor 迴圈修正，直到全部通過。
4. 若有 **pending** 情景 → 表示 step definition 尚未實作完成，必須補齊實作後重新執行，不得以 pending 狀態回傳 `completed`。
5. 全部情景通過後，在回傳的 completion-summary 中附帶 `acceptance-scenarios` 統計：

```
acceptance-scenarios:
  total: {N}
  passed: {N}
  failed: 0
  pending: 0
  evidence: "{test summary or test result file path}"
```

6. **只有 `failed == 0` 且 `pending == 0` 時，才可回傳 `completed` 狀態。** 否則必須繼續修正或回傳 `partial-completed`（附帶 acceptance-scenarios 統計與 blocking-reason）。

## Smoke Test 規則

- 若交付包含 Web/API 服務，在最終完成前必須依 `project-profile` 啟動服務，並對每個新增或修改的對外 API 執行至少 1 個基本 smoke test；輸出確認選項到終端並等候使用者確認目標環境、base URL / 啟動方式、測試資料前置條件與允許影響後，**立即透過 `shell` 自動執行**；**不得僅產出腳本供使用者手動執行**。
- 當你是由 `bdd-orchestrator` 以子代理方式呼叫時，仍必須使用你自己的 `shell` 工具執行 smoke test。**不得**因 orchestrator 本身沒有 terminal tool，就回覆「需要使用者手動執行」。
