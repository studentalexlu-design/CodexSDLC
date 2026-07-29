---
name: contract-testing
version: 1.0.0
description: 以 OpenAPI draft 為契約來源，設計 API 契約測試與整合/smoke 測試證據（P0-3 交付 Gate）
---

# Contract Testing Skill

> 用途：整合驗證階段（integration）以 `design/api-contract.yaml`（P0-1 產出）為**唯一契約來源**，
> 驗證實作回應符合契約，並產出契約/整合/smoke 測試證據供交付 Gate 確認（`t2` → `gate-close`；`t3` → `gate-release`）。
> 契約測試本身應在 `gate-contract`（**實作前**）就已寫好且為紅燈 —— 紅燈是契約可測的證據。本 skill 處理的是實作後的轉綠與證據產出。
> 維持 lean：產出為測試證據，不是正式整合測試報告或 E2E 報告治理產物。

## 使用時機

- TDD 完成（tdd-done），功能有對外 API / 跨模組整合 / 可 smoke 的端到端路徑。
- 無對外 API → 契約測試 `not-applicable`；無整合面 → integration `not-applicable`；
  純函式庫無法 smoke → smoke `not-applicable`（皆需 reason）。

## 契約來源

- 唯一契約來源：`bdd-docs/runs/{run-id}/artifacts/design/api-contract.yaml`。
- 契約與實作漂移時，契約測試失敗即為訊號；不得為通過而修改契約遷就實作，
  契約變更須回設計橋接（design）更新並重新審核。

## 契約測試最小要求

1. 每個 endpoint 至少驗證：
   - 一個成功回應：狀態碼 + response schema（必填欄位、型別）。
   - 一個錯誤回應：狀態碼 + error schema 結構。
2. 驗證 `operationId` / path / method 與契約一致。
3. 以既有測試框架撰寫（C#: Reqnroll / xUnit；Java: Cucumber-JVM / JUnit 5，皆加 schema 驗證）；框架依 `index.json` 的 `test-toolchain`，不新增重量框架，除非批准（minimal-implementation-policy）。

## 違反分級

- response/error schema 不符契約 = **BLOCKER**。
- 缺 example 覆蓋（契約有 example 但無對應測試）= **MAJOR**。
- 狀態碼不符 = **BLOCKER**。

## 整合與 smoke

- 整合測試：跨模組/元件流程；外部介接以 test double 或受控環境；不連 production。
- smoke test：端到端最小可用路徑；**Web/API 啟動、外部呼叫須先取得使用者批准**（safe-change）。
- 環境須可重建；flaky 依 `test-reliability` 處理，最多 1 次自動重試。

## Output Contract

````markdown
STATUS: needs-input | evidence

## Contract Test Summary
| Endpoint | Method | Success Case | Error Case | Result | Violation |
| --- | --- | --- | --- | --- | --- |

CONTRACT_RESULT: {total} endpoints, {passed} passed, {failed} failed

## Integration / Smoke Summary
- command / exit code
- total / passed / failed / skipped
- 前 3 筆失敗或契約違反
- trx / log path

## Assumptions / Open Questions
- ...

## Next Step
交付 Gate 使用者確認 → 收尾（`t3` 經 living-doc）
````

## Secret Safety

契約/整合/smoke 測試不得硬編 credentials、連線字串；使用 test config / 受控 secret；
證據不得貼長 log 或原始敏感值。

## Quality Gate

- `STATUS: needs-input`：契約來源缺失或 endpoint 行為不明。
- `STATUS: evidence`：契約測試 0 違反、整合/ smoke（若適用）通過且證據可追溯。
