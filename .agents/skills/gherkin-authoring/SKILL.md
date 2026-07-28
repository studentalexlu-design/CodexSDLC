---
name: gherkin-authoring
version: 1.0.0
description: 撰寫高可讀性的 Gherkin 規格
---

# Gherkin Authoring Skill

## 核心原則

- 使用宣告式語言。
- Feature 對應業務能力。
- Rule 對應業務規則。
- Scenario 對應具體驗收範例。
- 避免 UI 操作細節。
- 用語與 domain glossary 對齊。

## 撰寫要求

- Gherkin 必須先於 step definitions 與內圈 unit tests 定案；它是外層可執行規格。
- 第一批 scenario 應優先涵蓋 walking skeleton 所需的最小 happy path。
- 若存在必要的非功能需求，應轉成可驗證的驗收條件。
- 新增 scenario 前，先檢查是否與現有 feature 的語意重疊。

## 邊界

- 此 skill 負責規格寫法與可讀性，不負責 gate、批准或流程切換。
