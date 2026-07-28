---
name: test-reliability
version: 1.0.0
description: 管理 flaky tests、環境不穩與測試決定性
---

# Test Reliability Skill

## 常見風險

- 時間 / 時區
- 隨機值
- 平行測試競態
- 共享 DB / cache / file system
- 外部 API 不穩

## 原則

- 凍結時間
- 固定 seed
- 使用可重建 fixture
- 區分 flaky、environment、regression
- 不要為了通過不穩測試而亂改 production code

## Smoke Test Policy

- smoke test 前一律輸出確認選項到終端，請使用者確認目標環境、base URL、資料前提、憑證處理方式與允許影響。
- 明確標記 smoke test 是 local、shared、staging 或其他環境，避免把環境問題誤判為 regression。
- 若無法保證測試資料可復原或影響可接受，暫停 smoke test 並升級給 orchestrator。
