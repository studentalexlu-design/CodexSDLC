---
name: outside-in-tdd
version: 1.0.0
description: 以 BDD/ATDD 外層驅動 TDD 內層的實作流程
---

# Outside-In TDD Skill

## 建議順序

1. Discovery / Example Mapping：先釐清 story、rules、examples、open questions。
2. BDD / Gherkin：先寫並審核可驗收的 `.feature` 規格，讓術語與行為先定案。
3. ATDD：依 Gherkin 建立 acceptance tests、薄型 step definitions 與測試基礎設施。
4. Walking Skeleton：先打通一條最小 happy-path 端到端流程，驗證系統接線、邊界與測試夾具。
5. TDD 內圈：在外層 failing scenario 驅動下，以 unit test 推進內部設計與行為切片。
6. Refactor：外層與內圈都維持綠燈後，再做結構整理。

## Step Definitions 原則

- step definitions 是語言對映層，不是業務邏輯層。
- step definitions 應委派給 driver / helper / application service。
- 先有 Gherkin，再實作 step definitions；不要反過來用 step definitions 發明需求。

## 工具鏈解析

進入 ATDD 或 TDD 階段前，必須確認工具鏈：

1. **優先讀取** `bdd-docs/artifacts/coding-standards.md`「測試慣例」區塊。
2. **次要偵測**現有專案 `.csproj` 的 NuGet 參考。
3. **fallback 預設**：xUnit + AwesomeAssertions + NSubstitute + Reqnroll.xUnit。

產生的程式碼必須使用確認後的工具鏈，不得混用其他框架。

## 微型迭代

- 一次只處理一個 behavior slice
- 每輪都必須有 Red、Green、Refactor 證據
- 綠燈後 commit

## Walking Skeleton 原則

- 第一條 scenario 以「薄但完整」為目標，而不是一次做完整商業規則。
- 先證明端到端路徑可執行，再往內層補單元測試與設計細化。
- 若 walking skeleton 尚未打通，不要直接跳進大量 unit tests。

## Smoke Test 原則

- 對 Web/API 驗證前，先輸出確認選項到終端，請使用者確認目標環境、base URL、資料前提與允許影響。
- smoke test 屬於最終驗證，不取代 ATDD 或 unit tests。

## 停止條件

- 需求未批准
- 超出 safe-change envelope
- flaky / environment issue 未釐清

## 邊界

- 此 skill 提供外層到內圈的實作順序與寫法原則，不負責 gate 判斷、批准紀錄或 backlog 管理。
