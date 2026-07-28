# Artifact Versioning Policy

目標：避免重複讀取完整 artifact，並提供可驗證的快取鍵。

## Digest 與版本

- digest 演算法：SHA-256。
- 短 digest：可使用前 16 個十六進位字元作為顯示用途；驗證仍以完整 SHA-256 為準。
- artifact version 建議格式：`{stage}.{artifact-id}.{short-digest}`。

## 生成時機

- 建立新 artifact 時必須生成 digest。
- artifact 內容變更後必須重新生成 digest 與 version。
- checkpoint 寫入時必須同步最新 `last-artifact-digest`。

## Handoff 規則

- handoff 必帶：artifact path + version + digest。
- 若 digest 未變，子代理不得要求重讀完整 artifact。
- 僅在以下情況允許 full read：Gate、review 修復、hash/version 不一致。

## 回傳驗證

- 子代理回傳包含新版本或新內容時，必須附更新後 digest。
- orchestrator 在下一輪委派前先做 digest 一致性檢查。
- digest 缺失視為 metadata incomplete，先要求補齊，再進下一步。

