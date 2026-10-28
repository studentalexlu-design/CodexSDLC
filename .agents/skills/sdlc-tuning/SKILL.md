---
name: sdlc-tuning
version: 1.0.0
description: "Use when: 使用者嫌這套工作流太慢、太貴，或要調子代理的 model／effort。跑 tune → 講提議與理由 → 他決定才套用。"
---

# 調校

**套用那一下是他按的。** 你跑、講、等他決定。

1. 跑 `pwsh .codex/scripts/sdlc.ps1 tune`。
2. 把提議連同**每一條的理由與訊號**講給他聽 —— 只講結論，他沒有東西可以判斷要不要照做。
3. 他決定之後才 `tune -ApplyProposal`；或請他直接改 `sdlc.config.json` 再跑 `sdlc.ps1 apply`。

## 能調到什麼

- 子代理的 model／effort 由專案根的 `sdlc.config.json` 決定（`inherit` = 不釘，交給 CLI）。
- **你自己（orchestrator）那一組強制不了** —— 要生效得由使用者在啟動時自己下。他嫌的是你慢，就照實講這一點，不要假裝 `tune` 管得到。
