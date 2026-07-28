# Handoff Template: resume

> 段落順序：靜態在前、易變在後。`constraints` 與 `output-contract` 同 mode 完全固定，
> 排在最前面才可能進入共用前綴；`meta` 每次都變，排最後。**不得調換。**

## constraints
- 單一 operation mode、單一切片。
- 不得跨 Gate 展開下一階段。
- 若內容含 `{{...}}` 佔位符，請完整保留。

## output-contract
- status: completed | partial-completed | blocked | error
- next-step: {{NEXT_STEP_IF_PARTIAL}}
- evidence-refs: [path...]

## meta
- mode: resume
- tier: {{TIER}}
- run-id: {{RUN_ID}}
- feature-id: {{FEATURE_ID}}
- stage: {{STAGE}}

## target
- next-step: {{NEXT_STEP_SINGLE_SLICE}}
- pending-items: {{PENDING_ITEMS}}
- checkpoint-id: {{CHECKPOINT_ID}}

## context
- primary-context-pack-path: {{CONTEXT_PACK_PATH}}
- primary-context-pack-digest: {{CONTEXT_PACK_DIGEST}}
- artifact-path: {{ARTIFACT_PATH}}
- artifact-version: {{ARTIFACT_VERSION}}
- artifact-digest: {{ARTIFACT_DIGEST}}

## summary
{{SUMMARY_MAX_500_CHARS}}
