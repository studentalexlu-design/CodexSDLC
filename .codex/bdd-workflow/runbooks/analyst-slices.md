# analyst Runbook: bounded analyst slices

Read only after `analyst` has been given a `mode`. Sections map 1:1 to the modes
declared in `.codex/agents/analyst.toml`; read only the section for the active mode.

## mode: flow

> `t3` only. `t0` / `t1` / `t2` do not run this mode.

Goal: complete one flow-alignment round only.

Read/search:

- active run `artifacts/source-materials-register.md`
- shared `bdd-docs/artifacts/domain-glossary.md`
- the single most relevant requirements source first
- `artifacts/context-packs/domain.md` when it exists
- DB/schema/code sources only when the current round needs them

Execution limits:

- perform exactly one flow-alignment round per invocation
- read source materials in bounded chunks; prefer notes over repeated rereads
- write or update only `artifacts/flow-description.md`
- after emitting the alignment summary/questions, stop and return `completed`, or
  `phase0-iteration-completed` (the contract's status value for a finished flow round —
  see `workflow-contract.json` `return-contract.doer-status-enum`)
- new or conflicting terms are resolved **in the same invocation** by updating
  `domain-glossary.md` and reporting `glossary-delta` — there is no domain round-trip to pause for
- if source coverage is still incomplete within budget, return `phase0-iteration-completed`
  with `source-coverage: partial`

## mode: example-map

Goal depends on `tier` — this is the one place the two profiles genuinely differ:

| tier | scope per invocation |
|---|---|
| `t2` | the **whole** example map (all stories); no story-level slicing |
| `t3` | exactly **one** story |

Read/search:

- approved `artifacts/flow-description.md` (`t3` only — `t2` has none)
- `artifacts/context-packs/domain.md` when it exists
- existing example map if present
- only the specific source slices needed for the stories in scope

Execution limits:

- update only `artifacts/example-maps/{feature-id}.md`
- when `artifacts/example-maps/{feature-id}.md` already contains multiple stories, preserve every
  untouched story section and top-level metadata; merge or append the targeted story instead of
  replacing the whole artifact
- `t3`: process at most 1 story, and do not continue to the next story in the same invocation
- `t2`: complete every story before returning; if the wall-clock budget runs out first,
  return `partial-completed` listing the remaining stories
- if more stories remain, return `partial-completed` with the newly completed items and the
  remaining pending items
- if work cannot be completed safely within the time/token budget, return `partial-completed`
  or `blocked` instead of continuing

## mode: resume

Goal: continue the smallest pending slice.

Read/search:

- only the current stage artifact plus the pending items supplied by orchestrator
- prefer `flow-description.md`, existing example map, and the minimal relevant source slices

Execution limits:

- do not reopen completed stories or completed flow rounds
- resume one pending slice only
- preserve existing statuses and mark only the touched story/round
- if the example map is a merged multi-story artifact, update only the targeted story section and
  its local metadata; never drop previously completed story sections during resume

## Time / token guardrails

- target wall-clock: <= 6 minutes per invocation
- if approaching the budget, stop and return `partial-completed`
- do not expand from `flow` into `example-map` in the same invocation
- `t3`: do not combine story exploration, NFR exploration, and stale-story revalidation across
  multiple stories in one invocation

## Return

Always return paths, versions, status, completed-items, pending-items, and open questions only.
Do not paste full flow descriptions, full example maps, or full source excerpts.
