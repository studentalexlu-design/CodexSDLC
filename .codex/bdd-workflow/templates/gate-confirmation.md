# Gate Confirmation Template

Use this template whenever `bdd-orchestrator` asks the user to approve a Gate. Do not ask a generic "continue?" question.

## 現在確認的 Gate
- gate-id: {{GATE_ID}}
- display-name: {{GATE_DISPLAY_NAME}}
- current-boundary: {{CURRENT_BOUNDARY}}
- next-stage-if-approved: {{NEXT_STAGE_IF_APPROVED}}

## 請查看/確認的文件
{{DOCUMENTS_TO_REVIEW_WITH_PATH_VERSION_DIGEST_EVIDENCE_REFS}}

## 請驗證的重點
{{USER_VERIFICATION_CHECKLIST}}

## 目前缺口或 blocker
{{CURRENT_GAPS_OR_BLOCKERS}}

## 決策選項
- 核准通過 Gate，進入 {{NEXT_STAGE_IF_APPROVED}}
- 核准通過 Gate，並在**新對話**續跑 {{NEXT_STAGE_IF_APPROVED}}（保留全部進度，只歸零已累積的對話 context）{{RESET_RECOMMENDED_MARKER}}
- 退回修正，列出需修正的文件或驗證項目
- 暫停流程，保留目前 checkpoint
- 自行輸入其他決策

> 第二項僅在 `gate-contract`／`gate-migration`／`gate-release` 出現；`gate-probe` 與 `gate-close` 省略。
> `subagent-calls.count` − `count-at-last-reset` ≥ 4 時，將其排為第一項並標示「建議」。

## 記錄要求
- If approved, delegate `living-doc` to write gate id, reviewed document refs, verification checklist, user decision, and next stage to `decision-log.md` and the stage checkpoint.
- Keep only path/version/digest/evidence refs. Do not paste full artifacts, secrets, DLP mapping tables, or long logs.
