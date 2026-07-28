# Handoff Template: review

> 段落順序：靜態在前、易變在後。`constraints` 與 `output-contract` 同 mode 完全固定，
> 排在最前面才可能進入共用前綴；`meta` 每次都變，排最後。**不得調換。**

## constraints
- 僅回傳缺陷與證據，不重寫整份內容。
- 若內容含 `{{...}}` 佔位符，請完整保留。

## output-contract
- VERDICT: PASS | FAIL
- defect-counts: BLOCKER/MAJOR/MINOR
- evidence-refs: [path...]

## meta
- mode: review
- tier: {{TIER}}
- run-id: {{RUN_ID}}
- feature-id: {{FEATURE_ID}}
- stage: {{STAGE}}

## target
- artifact-path: {{ARTIFACT_PATH}}
- artifact-version: {{ARTIFACT_VERSION}}
- artifact-digest: {{ARTIFACT_DIGEST}}

## review-focus
- focus-1: {{FOCUS_1}}
- focus-2: {{FOCUS_2}}
- focus-3: {{FOCUS_3}}

## summary
{{SUMMARY_MAX_500_CHARS}}
