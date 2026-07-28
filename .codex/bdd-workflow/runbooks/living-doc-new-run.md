# Living Doc Runbook: new-run

Use only when `mode: new-run`.

## Read Order

1. `.codex/bdd-workflow/workflow-contract.json` context-budget only, plus `.codex/bdd-workflow/agent-skill-matrix.json` for skill versions.
2. `bdd-docs/workflow-state.json`.
3. `bdd-docs/runs/template/` files needed for the requested skeleton.
4. `.codex/bdd-workflow/templates/lean-sdlc-checklist.md`.
5. Source material paths named by orchestrator; summarize, do not paste full text.

## Required Writes

Create shallow files before deep files:

1. `bdd-docs/runs/{run-id}/workflow-state.json`
2. `decision-log.md`, `PROGRESS.md`, `index.md`, `log.md`
3. `artifacts/source-materials-register.md`, `source-conflicts.md`, `implementation-backlog.md`, `flow-description.md`
4. `artifacts/db-select-authorization.md` with status `not-requested`
5. `artifacts/lean-sdlc-checklist.md` from `.codex/bdd-workflow/templates/lean-sdlc-checklist.md`
6. `.gitkeep` files for child artifact/checkpoint directories when needed
7. Root `bdd-docs/workflow-state.json` last, only after core run files exist

## Lean SDLC Checklist Initialization

- Initialize only these stages: 需求收集, 需求分析, 系統分析, 程式開發.
- Do not create architecture design, program design review, formal integration/E2E test, release readiness, deployment, rollback, or release-note checklists.
- Replace `{run-id}`, `{feature-id}`, `{stage}`, and `{timestamp}` placeholders.
- Set known paths for artifacts that already have a stable run or global path.
- Leave unknown paths as `TBD` with status `pending`.
- If an artifact is truly not relevant for this run, set status to `not-applicable` and fill `not-applicable reason`.

## Source Register Rules

- Register every user-provided source, workspace path, DB clue, and code clue.
- DB clues stay `pending-approval` until DB introspection produces evidence. If run-scoped bounded SELECT is approved, record only `db-select-authorization.md` path/version/digest/evidence refs.
- Never store credentials, connection strings, API keys, or raw secrets.

## Initial Runtime Metadata

Set:

- `current-gate`: `intake`
- `last-agent`: `living-doc`
- `lean-sdlc-checklist`: `bdd-docs/runs/{run-id}/artifacts/lean-sdlc-checklist.md`
- `needs-lint`: `false` only if index/log/state/source register were all updated consistently
- `handoff-budget`: summary limits from workflow contract
- `log-read`: latest offset/hash for resume

Return `partial-completed` if any required file cannot be created.
