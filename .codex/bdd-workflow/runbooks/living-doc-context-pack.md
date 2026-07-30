# Living Doc Runbook: context-pack

Use for `mode: context-pack`. Checkpoints, gate confirmation records, decision-log entries, DLP markers, and DB SELECT authorization records are **not** living-doc work — the orchestrator writes those itself (`runbooks/checkpoint-schema.md`).

## Context Pack

Write `artifacts/context-packs/{stage}.md` with only:

- Decision Summary
- Essential Handoff
- Artifact References
- Risks / Open Questions
- Next Agent Prompt Seeds

Compile **only at a stage boundary**. Compiling again inside the same stage buys nothing and costs one spawn.

Never embed full upstream artifacts, full source register, full operation log, full test output, or other context packs. Reference everything as path/version/digest. Upstream content you read is for distillation only — copying it into the pack hands the orchestrator back exactly the context this delegation was meant to keep out.

## Index / Progress

- `index.md`: update Current Stage, Gates, Artifacts, Context Packs, Open Questions.
- `PROGRESS.md`: update stage table, next action, checkpoint list — read the existing checkpoint files, do not create or modify them.

## Lean SDLC Checklist

Structural maintenance only. Day-to-day row status transitions belong to the orchestrator.

- Read `.codex/bdd-workflow/lean-sdlc-schema.json` `lean-sdlc` mapping for the active stage.
- Fill in missing structural fields (path, owner agent, evidence refs) for rows of the current stage. Do not rewrite status values the orchestrator already set.
- Each artifact row must keep: path, status, owner agent, last updated, evidence refs, and not-applicable reason.
- Valid status values are `pending`, `in-progress`, `completed`, `blocked`, and `not-applicable`.
- `not-applicable` requires a reason. Do not use `completed` for an artifact that is merely out of scope.
- If a requested artifact belongs to excluded governance scope, add it to `Out Of Scope Requests` and do not create release, architecture, formal integration/E2E, rollback, deployment, or release-note checklist artifacts.
- Include the checklist path and updated row count in the return summary.

## Runtime Metadata

You do not write `workflow-state.json`. Return suggested values and let the orchestrator apply them:

- `last-context-pack`
- `needs-lint` / `lint-reason`

If state and index disagree and cannot be reconciled within budget, return `partial-completed` with `needs-lint: true` as a suggestion.
