---
applyTo: "**/*Tests.cs, **/*Test.java, **/*Tests.java"
description: "C# 單元測試與微型迭代規範"
---

# Unit Tests 規範

- 採 AAA；一個測試只驗證一個行為。
- 先寫失敗測試，再寫最少量實作；命名沿用既有專案慣例。
- 測試工具鏈以 `coding-standards.md` 或既有 `.csproj` 為準；無既有慣例時才使用 repo 預設。
- 詳細 mock/斷言/微型迭代規則按需讀 `.agents/skills/unit-test-gen/SKILL.md` 與 `.agents/skills/outside-in-tdd/SKILL.md`。
