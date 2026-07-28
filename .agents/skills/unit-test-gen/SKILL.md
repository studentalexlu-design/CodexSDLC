---
name: unit-test-gen
version: 1.0.0
description: 產生符合 AAA 與 test-first 的 C# 單元測試
---

# Unit Test Generation Skill

- 採 AAA 結構。
- 測試命名：`Method_Condition_ExpectedResult`
- 一個測試一個意圖
- 先寫失敗測試，再寫最少量實作
- 優先測主要邊界條件
- 使用結構化錯誤工具讀取失敗資訊
- 必要時用 mock / stub，但避免過度 mock

## 工具鏈

產生測試程式碼前，必須依以下順序確認使用的工具：

1. `bdd-docs/artifacts/coding-standards.md`「測試慣例」→ 已填寫則遵循。
2. 專案 `.csproj` 已安裝的 NuGet → 沿用既有框架。
3. 預設：**xUnit** + **AwesomeAssertions** + **NSubstitute**。

產生的程式碼必須**只使用已確認的工具鏈**，禁止混用（例如同時出現 `Assert.Equal` 與 `Should().Be()`）。

## 邊界

- 此 skill 只處理單元測試設計與寫法，不負責 commit、evidence、gate 或 smoke test 流程。
