---
applyTo: "src/**/*.cs, src/main/java/**/*.java"
description: "Production Code 變更與安全邊界規範"
---

# Production Code 規範

- 只實作目前測試與驗收切片需要的最少程式碼。
- 優先遵循既有架構；若存在 `bdd-docs/artifacts/coding-standards.md`，先讀其相關章節。
- 變更 public surface、DI、serialization、migration、configuration 或 shared DTO 前，確認 safe-change envelope。
- Data layer / migration / rollback 細節按需讀 `.agents/skills/safe-change/SKILL.md` 與 `.agents/skills/impact-analysis/SKILL.md`。
