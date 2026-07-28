# Discovery Runbook: bounded discovery slices

Use only after `discovery.agent.md` selected a mode.

## mode: phase0

Goal: complete one flow-alignment round only.

Read/search:

- active run `artifacts/source-materials-register.md`
- shared `bdd-docs/artifacts/domain-glossary.md`
- the single most relevant requirements source first
- `artifacts/context-packs/domain.md` when it exists
- DB/schema/code sources only when the current round needs them

Execution limits:

- perform exactly one Phase 0 round per invocation
- read source materials in bounded chunks; prefer notes over repeated rereads
- write or update only `artifacts/flow-description.md`
- after emitting the alignment summary/questions, stop and return `phase0-iteration-completed`, `phase0-paused-for-domain-check`, or `completed`
- if source coverage is still incomplete within budget, return `phase0-iteration-completed` with `source-coverage: partial`

## mode: phase1

Goal: complete one story only.

Read/search:

- approved `artifacts/flow-description.md`
- `artifacts/context-packs/domain.md`
- existing example map if present
- only the specific source slices needed for the next unfinished story

Execution limits:

- process at most 1 story per invocation
- update only `artifacts/example-maps/{feature-id}.md`
- when `artifacts/example-maps/{feature-id}.md` already contains multiple stories, preserve every untouched story section and top-level metadata; merge or append the targeted story instead of replacing the whole artifact
- do not continue to the next story in the same invocation
- if more stories remain, return `partial-completed` with one new completed item and the remaining pending items
- if work cannot be completed safely within the time/token budget, return `partial-completed` or `blocked` instead of continuing

## mode: resume

Goal: continue the smallest pending slice.

Read/search:

- only the current stage artifact plus the pending items supplied by orchestrator
- prefer `flow-description.md`, existing example map, and the minimal relevant source slices

Execution limits:

- do not reopen completed stories or completed flow rounds
- resume one pending slice only
- preserve existing statuses and mark only the touched story/round
- if the example map is a merged multi-story artifact, update only the targeted story section and its local metadata; never drop previously completed story sections during resume

## Time / token guardrails

- target wall-clock: <= 6 minutes per invocation
- if approaching the budget, stop and return `partial-completed`
- do not expand from Phase 0 into Phase 1 in the same invocation
- do not combine story exploration, NFR exploration, and stale-story revalidation across multiple stories in one invocation

## Return

Always return paths, versions, status, completed-items, pending-items, and open questions only.
Do not paste full flow descriptions, full example maps, or full source excerpts.

