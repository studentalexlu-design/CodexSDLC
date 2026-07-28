# Return Contract Policy

適用於 doer、scanner 與 living-doc 類 agent。reviewer 另遵循 `reviewer-policy.md`。

## Status

- `completed`：local DoD 已滿足，必要測試或 evidence 已完成，且沒有 pending blocker。
- `partial-completed`：已產出可保存成果，但仍有 pending items、預算不足、環境限制或下一切片。
- `blocked`：需要使用者裁定、Gate、批准、缺少來源或超出 safe-change envelope。
- `error`：工具或環境造成無法保存任何有效成果。

## Minimal Shape

```text
STATUS: completed | partial-completed | blocked | error
mode: {mode}
run-id: {run-id}
stage: {stage}
artifacts: {path + version/status only}
completed-items: [...]
pending-items: [...]
open-questions-or-risks: [...]
evidence-refs: {paths only}
```

## Evidence Rules

- 回傳 path、version、hash、digest path 與短摘要；不貼完整 artifact。
- build/test evidence 只包含 command、exit code、total/passed/failed/skipped、前 3 個錯誤與 trx/log path。
- `partial-completed` 必須列出 resume 可用的 `completed-items` 與下一個最小 `pending-items`。
- `blocked` 必須列出 orchestrator 可轉成使用者選項的明確問題；不得要求 reviewer 或 doer 直接保存 secrets。

