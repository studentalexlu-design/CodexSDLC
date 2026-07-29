# Contract Test Policy（P0-3）

> Scope: `integration-tester` 及交付 Gate（`t2` → `gate-close`；`t3` → `gate-release`）的契約/整合/smoke 測試證據要求。
> Skill: `.agents/skills/contract-testing/SKILL.md`
> Contract: `workflow-contract.json` `2.0.0+`（stage `integration`/`integration-done`, gate `gate-close`/`gate-release`）。

## 1. 契約來源唯一性

- 唯一契約來源：`bdd-docs/runs/{run-id}/artifacts/design/api-contract.yaml`（P0-1 design-modeler 產出）。
- 契約與實作漂移時，契約測試失敗即為訊號。
- **不得為通過而修改契約遷就實作**；契約變更須回設計橋接（`design`）更新並經 `spec-reviewer`（`mode: design`） 重新審核。

## 2. 契約測試最小要求

每個 endpoint 至少驗證：

1. 一個成功回應：狀態碼 + response schema（必填欄位、型別）。
2. 一個錯誤回應：狀態碼 + error schema 結構。
3. `operationId` / path / method 與契約一致。

以既有測試框架撰寫（Reqnroll / xUnit + schema 驗證）；不新增重量框架，除非經 orchestrator 批准（minimal-implementation-policy）。

## 3. 違反分級

| 情況 | 分級 |
| --- | --- |
| response/error schema 不符契約 | BLOCKER |
| 狀態碼不符契約 | BLOCKER |
| 缺 example 覆蓋（契約有 example 但無對應測試） | MAJOR |
| 契約有 endpoint 但無任何測試 | MAJOR |

## 4. 整合與 smoke

- 整合測試：跨模組/元件流程；外部介接以 test double 或受控環境；**不連 production**。
- smoke test：端到端最小可用路徑。
- **Web/API 啟動、外部呼叫、smoke 執行須先取得使用者批准**（safe-change envelope）。
- 環境須可重建；flaky 依 `test-reliability` 處理，最多 1 次自動重試。

## 5. 證據要求

- 證據路徑：`bdd-docs/runs/{run-id}/artifacts/integration/{contract|integration|smoke}-test-evidence.md`。
- 只記：command、exit code、total/passed/failed/skipped、契約違反前 3 筆、trx/log path。
- **禁止**：長 log 全文、硬編 credentials、連線字串、原始敏感值。

## 6. 適用性（N/A）

- 無對外 API → 契約測試 `not-applicable`。
- 無整合面 → integration `not-applicable`。
- 純函式庫無法 smoke → smoke `not-applicable`。
- 皆需 reason，由 `living-doc` 記入 lean-sdlc-checklist「整合驗證（evidence）」區段。

## 7. 交付 Gate 通過條件

```text
contract-tests.passed OR contract.not-applicable
integration-tests.passed OR integration.not-applicable
smoke-test.user-approved-and-passed OR smoke.not-applicable
lean-sdlc.stage.integration-verification.required-artifacts satisfied-or-not-applicable
```

## 8. 不可覆蓋

本政策不得覆蓋 secret-safety、safe-change approval、DLP、Gate 規則與 lean SDLC checklist 證據要求；亦不等同正式整合測試報告或 E2E 測試報告治理（仍屬 excluded）。
