# Living Doc Runbook: checkpoint and context-pack

Use for `mode: checkpoint` or `mode: context-pack`.

## Checkpoint

Create or update `bdd-docs/runs/{run-id}/checkpoints/{stage}.json` with:

- stage
- timestamp
- run-id
- artifacts path/version
- next-step
- resumable flag
- notes or completion-summary

For partial work, include `partial: true`, completed-items, pending-items, completion-percentage, and resume-instructions.

If the checkpoint records a same-turn user decision that still requires content sync (`decision-recorded`, `pending-artifact-sync`, equivalent metadata-only states), treat it as a transient resume point rather than a stopping point:

- `next-step` must name the concrete pending sync targets or next minimal slice.
- `resume-instructions` must tell the orchestrator to continue the current stage by syncing those targets, unless a new human approval or transport-recovery choice is still required.
- Do not write wording equivalent to "await the next instruction" when the only remaining work is same-stage artifact sync, reviewer rerun, or the next minimal resume slice.

## Index / Progress / Log

- `index.md`: update Current Stage, Gates, Artifacts, Context Packs, Open Questions.
- `PROGRESS.md`: update stage table, next action, checkpoint list.
- `log.md`: append exactly one short parseable entry per operation.
- `decision-log.md`: only write real decisions, approvals, exceptions, or rollback notes.

## Gate Confirmation Decisions

When orchestrator supplies a Gate confirmation decision, write it to both `decision-log.md` and the stage checkpoint.

Record only:

- gate id and display name
- reviewed document refs as path/version/digest/evidence refs
- verification checklist item labels or short summaries
- user decision (`approve-gate`, `return-for-fix`, `pause-workflow`, or free-text summary)
- next stage if approved
- timestamp and actor/source (`bdd-orchestrator` + user confirmation)

Do not copy full artifacts, secrets, DLP mapping tables, long logs, or raw sensitive source material into the decision log or checkpoint.

## DB SELECT Authorization Decisions

When orchestrator supplies a run-scoped bounded SELECT authorization decision, create or update `bdd-docs/runs/{run-id}/artifacts/db-select-authorization.md` and write a short decision-log entry.

Record only:

- run id and feature id
- status: `active`, `revoked`, or `expired`
- decision-log ref, actor/source, timestamp
- MCP server/profile alias, database/schema, approved table/view, approved columns, approved purpose
- default row limit `50`
- evidence refs and digest refs

Do not copy credentials, connection strings, MCP secrets, raw rows, DLP mapping tables, or large query output. If scope is broadened, keep the prior decision traceable and require a new approval entry.

## Lean SDLC Checklist

On every stage boundary, update `bdd-docs/runs/{run-id}/artifacts/lean-sdlc-checklist.md`.

- Read `.codex/bdd-workflow/lean-sdlc-schema.json` `lean-sdlc` mapping for the active stage.
- Update only the matching lean SDLC stage rows for the current operation unless orchestrator explicitly supplied broader evidence.
- Each artifact row must keep: path, status, owner agent, last updated, evidence refs, and not-applicable reason.
- Valid status values are `pending`, `in-progress`, `completed`, `blocked`, and `not-applicable`.
- `not-applicable` requires a reason. Do not use `completed` for an artifact that is merely out of scope.
- If a requested artifact belongs to excluded governance scope, add it to `Out Of Scope Requests` and do not create release, architecture, formal integration/E2E, rollback, deployment, or release-note checklist artifacts.
- Include the checklist path and updated row count in the return summary.

## Context Pack

Write `artifacts/context-packs/{stage}.md` with only:

- Decision Summary
- Essential Handoff
- Artifact References
- Risks / Open Questions
- Next Agent Prompt Seeds

Never embed full upstream artifacts, full source register, full operation log, full test output, or all context packs.

## Runtime Metadata

After any checkpoint or context-pack update, update active run `workflow-state.json.runtime-metadata`:

- current-gate
- last-agent
- last-context-pack
- lean-sdlc-checklist
- needs-lint / lint-reason
- log-read offset/hash
- loaded-skills supplied by orchestrator

If state/index/log disagree and cannot be fixed within budget, set `needs-lint: true` and return `partial-completed`.

