# Handoff Template: feature

> 段落順序：靜態在前、易變在後。`constraints` 與 `output-contract` 同 mode 完全固定，
> 排在最前面才可能進入共用前綴；`meta` 每次都變，排最後。**不得調換。**

## constraints
- 單一切片處理，不跨 stage。
- 只讀必要來源，不貼完整 artifact。
- 若內容含 `{{...}}` 佔位符，請完整保留。

## output-contract
- status: completed | partial-completed | blocked | error
- feature-path: {{FEATURE_PATH}}
- updated-digest: {{UPDATED_DIGEST_OR_SAME}}
- next-step: {{NEXT_STEP_IF_PARTIAL}}

## meta
- mode: feature
- tier: {{TIER}}
- run-id: {{RUN_ID}}
- feature-id: {{FEATURE_ID}}
- stage: formulate

## target
- source-example-map-path: {{EXAMPLE_MAP_PATH}}
- source-example-map-version: {{EXAMPLE_MAP_VERSION}}
- source-example-map-digest: {{EXAMPLE_MAP_DIGEST}}
- target-feature-path: {{FEATURE_PATH}}

## gate
- gate-conditions: {{GATE_CONDITIONS}}

## summary
{{SUMMARY_MAX_500_CHARS}}
