# Living Doc Runbook: maintenance

Use for `mode: lint`, `archive`, or `migration`.

## Lint

Check only BDD documents:

- metadata fields: id, version, status, run-id, artifact-scope
- link integrity for index/workflow-state/artifact refs
- version consistency between upstream and downstream artifacts
- gate consistency
- lean SDLC checklist row completeness
- `not-applicable` rows include a reason
- excluded governance artifacts are not created by this workflow
- stale checkpoints
- secret safety under `bdd-docs/`

Auto-fix only index/log/context-pack status and stale display paths. Return user-decision items for source conflicts, version rollbacks, missing approval, DB, or production-code impact.

For lean SDLC lint, return `blocked` or `partial-completed` when:

- `lean-sdlc-checklist.md` is missing for an active run.
- An enabled-stage artifact row lacks path, status, owner agent, last updated, or evidence refs after the stage should have produced evidence.
- A `not-applicable` row has an empty reason.
- The run created architecture design, program design review, formal integration/E2E governance, release readiness, deployment, rollback, or release-note checklist artifacts through this workflow.

## Archive

- Set run `workflow-state.json.status` to `archived` and `archived-at`.
- Clear or move root `bdd-docs/workflow-state.json.active-run-id` only when orchestrator explicitly requested archive.
- Update workflow metrics with a compact summary.

## Migration

- Patch version: no run rewrite required unless fields are missing.
- Minor version: compare workflow contract to run state, add optional fields with defaults.
- Major version: block and return required transform plan for orchestrator/user approval.

## Return

Always return paths and status summaries only. Do not paste full diff or full files.
