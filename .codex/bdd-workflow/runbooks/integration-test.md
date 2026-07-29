# Runbook: Integration Test（P0-3）

> 供 `integration-tester` 於整合驗證階段（`integration` / `integration-done`）使用。
> 政策：`.codex/bdd-workflow/policies/contract-test-policy.md`
> Skills：`contract-testing`、`test-reliability`。

## 階段定位

FSM：`tdd-done → integration → integration-done → living-doc → verified`。
在 TDD 完成後、收尾前，產出契約/整合/smoke 測試證據，供交付 Gate 使用者確認（`t2` → `gate-close`；`t3` → `gate-release`）。

## Mode 執行順序（建議）

1. `contract`（若有對外 API）→ 2. `integration`（若有整合面）→ 3. `smoke`（須批准）。
不適用者標 `not-applicable` + reason。

## contract mode

1. 讀 `design/api-contract.yaml`（唯一契約來源）。
2. 對每個 endpoint 產/跑：成功回應 schema + 一個錯誤回應 schema + 狀態碼比對。
3. 以既有框架（Reqnroll/xUnit + schema 驗證）撰寫，不新增重量框架（除非批准）。
4. 輸出 `CONTRACT_RESULT: {total} endpoints, {passed} passed, {failed} failed` 與違反前 3 筆。
5. 契約與實作漂移 → 契約測試失敗，回報 orchestrator 回 `design` 更新契約，不遷就實作。

## integration mode

1. 跨模組/元件流程；外部介接用 test double 或受控環境；不連 production。
2. `dotnet build` + `dotnet test --filter Category=Integration`。
3. 環境須可重建；flaky 依 `test-reliability`，最多 1 次自動重試。

## smoke mode（須批准）

1. **前置**：orchestrator 必須已取得使用者對 Web/API 啟動與 smoke 執行的批准（safe-change）。未批准則回 `blocked`。
2. 執行端到端最小可用路徑。
3. 記錄 command、exit code、通過與否、log path。

## 證據輸出

| 檔案 | 內容 |
| --- | --- |
| `integration/contract-test-evidence.md` | 契約測試摘要表 + CONTRACT_RESULT |
| `integration/integration-test-evidence.md` | 整合測試 command/exit/計數/前 3 失敗 |
| `integration/smoke-test-evidence.md` | smoke 批准參照、command、結果 |

只記 command/exit/計數/前 3 筆與 log path；**不貼長 log、不含原始敏感值、不硬編 secret**。

## 目錄前置

若 `bdd-docs/runs/{run-id}/artifacts/integration/` 不存在，先由 orchestrator 委派 `living-doc` 建立，再委派 integration-tester 產出證據。

## 切片與 partial-completed

- 契約端點 > 15 或整合案例過多：回 `partial-completed`，附 `next-step`。
- orchestrator 先委派 `living-doc` checkpoint，再依 next-step 續跑。

## 交付 Gate 收斂

- 三項（contract/integration/smoke）通過或 N/A → 交付 Gate user confirmation。
- living-doc 於 checklist「整合驗證（evidence）」更新 path/status/evidence refs。
- 交付 Gate 通過後收尾（`t3` 經 living-doc；`t2` 由 orchestrator 自行寫入）。

## 適用性（N/A 準則）

- 無對外 API → contract N/A；無整合面 → integration N/A；純函式庫 → smoke N/A。
- 三者皆 N/A 時交付 Gate 退化為快速確認，避免過重。
