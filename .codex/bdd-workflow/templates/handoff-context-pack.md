# Handoff Template: context-pack

> 段落順序：靜態在前、易變在後。`constraints` 與 `output-contract` 同 mode 完全固定，
> 排在最前面才可能進入共用前綴；`meta` 每次都變，排最後。**不得調換。**

## constraints
- 只讀取必要 path，不貼完整 artifact。
- 若內容含 `{{...}}` 佔位符，請完整保留。

## output-contract
- status: completed | partial-completed | blocked | error
- evidence-refs: [path...]
- updated-digest: {{UPDATED_DIGEST_OR_SAME}}

## meta
- mode: context-pack
- tier: {{TIER}}
- run-id: {{RUN_ID}}
- feature-id: {{FEATURE_ID}}
- stage: {{STAGE}}

## target
- artifact-path: {{ARTIFACT_PATH}}
- artifact-version: {{ARTIFACT_VERSION}}
- artifact-digest: {{ARTIFACT_DIGEST}}

## gate
- gate-conditions: {{GATE_CONDITIONS}}

## summary
{{SUMMARY_MAX_500_CHARS}}
