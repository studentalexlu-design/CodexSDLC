---
applyTo: "**/*Steps.cs, **/*Steps.java"
description: "Reqnroll Step Definitions 撰寫規範"
---

# Step Definitions 規範

- 預設使用 Reqnroll；若 `coding-standards.md` 指定其他框架，以該檔案為準。
- `Given` 設定前置、`When` 執行操作、`Then` 斷言結果；不要把業務邏輯堆在 steps。
- 共享狀態使用 constructor injection、scenario context 或專用 context 物件。
- 測試穩定性與 BDD walking skeleton 細節按需讀 `.agents/skills/outside-in-tdd/SKILL.md` 與 `.agents/skills/test-reliability/SKILL.md`。
