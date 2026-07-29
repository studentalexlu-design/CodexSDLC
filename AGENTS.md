# Codex Instructions - BDD + ATDD + TDD Workflow

This repository contains a Codex-native migration of the BDD workflow that was originally defined under `.github`.

## Always-On Principles

1. Source-First: do not advance a feature workflow until the active run has a completed `artifacts/source-materials-register.md`.
2. Outside-In: run Example Mapping and Gherkin before ATDD walking skeleton work, then use TDD for implementation.
3. Run Isolation: default to a new `bdd-docs/runs/{run-id}/` unless the user explicitly asks to resume an existing run.
4. Docs as Source of Truth: runtime state lives in `bdd-docs/`; agents and skills do not store dynamic workflow data.
5. Safe Change: public contracts, migrations, DB access, smoke tests, shared DTOs, and high-risk changes require explicit user approval.
6. Secret Safety: never write credentials, connection strings, API keys, or DLP mapping tables to `bdd-docs/`, artifacts, logs, or prompts.
7. Context Budget: prefer index, metadata, digests, and context-pack summaries over full artifacts or long logs.

## Codex Entry Points

- For full workflow coordination, explicitly use the `bdd-orchestrator` custom agent.
- The orchestrator delegates to 11 project-scoped custom agents:
  - **doers**: `project-scanner`, `db-introspection-scanner`, `analyst`, `formulator`, `design-modeler`, `atdd-automator`, `tdd-implementer`, `integration-tester`, `living-doc`
  - **reviewers**: `spec-reviewer` (modes: `domain` / `example-map` / `gherkin` / `design`), `code-reviewer` (modes: `atdd` / `tdd`)
- Three consolidations happened, each for a specific reason — **not** because "fewer agents is cheaper" (it isn't; see "Why multi-agent"):
  - `spec-reviewer` replaced four near-identical spec reviewers (~80% shared ceremony).
  - `code-reviewer` replaced `atdd-reviewer` + `tdd-reviewer` (~60% shared ceremony).
  - `analyst` replaced `domain-analyst` + `discovery`. These two read the same sources **and had a round-trip protocol between them** (`domain-backflow` stage, two `paused-for-domain-check` states, an incremental-validation runbook). Merging deleted that entire mechanism: glossary terms and behaviour examples now evolve in one context.
- Merging pays off only when it **deletes real duplication**, **removes a cross-agent coordination mechanism**, or **converts cross-agent switches into repeat invocations of one agent** (the only case where prompt cache can hit). Repackaging instructions without deleting anything makes things worse.
- Each delegation must cover one mode, one target artifact group, and one next step. Do not ask a subagent to cross multiple gates in one handoff.
- `bdd-router` was intentionally not migrated; its routing responsibility now lives in the `complexity-assessment` stage inside `bdd-orchestrator` (see Complexity Routing below).

## Complexity Routing

The workflow depth is chosen per run, not fixed. `bdd-orchestrator` runs `complexity-assessment` once, right after `intake-done` and before `scan`, then confirms the profile with the user in a single confirmation.

| Profile | Scope | Gates | Reviewers | Budget |
|---|---|---|---|---|
| **lite** | single-file change, add a field, copy an existing pattern | `gate-lite` | none | **≤ 2 subagent calls** |
| **standard** | one feature, new endpoint, no schema change, no legacy SQL | `gate-std-1` + `gate-std-2` | 1 (`spec-reviewer`) | ≤ 10 subagent calls |
| **full** | legacy rewrite, DB schema change, breaking public contract, sensitive sources | intake + Gate A–E | all | ≤ 20 subagent calls |

**All three profiles keep Gherkin and the Outside-In TDD spine.** Routing trims process tax, not BDD itself — even `lite` runs `formulator` before `tdd-implementer`. What `lite` drops is Example Mapping, domain glossary, ATDD skeleton, design bridge, reviewers, and context packs.

**`lite` spawns only `formulator` and `tdd-implementer`.** The orchestrator handles the run skeleton and the project overview itself (it already has run-state write access and can read `index.json` directly). If a `lite` run turns out to need `project-scanner`'s impact judgement, domain analysis, or any review, that means the profile was assessed too low — **escalate to `standard`**, don't add spawns to `lite`.

## Why multi-agent

Multi-agent costs *more* tokens per operation, not fewer: each spawn is a cold start paying 4–8k tokens of system prompt, policies, and runbook before doing any work. It is the right design anyway, for three reasons that have nothing to do with token count:

1. **Context window capacity** (decisive). A `full` run touches source materials, project scans, glossary, example maps, Gherkin, design drafts, production code, tests, and evidence. A single thread would exhaust the window and trigger compaction — losing information unpredictably at the worst moment. Multi-agent loses information *by contract* instead (handoffs carry path/version/digest only).
2. **Review independence.** A reviewer that never saw the doer's reasoning gives genuinely independent judgement.
3. **Least privilege.** `spec-reviewer` is read-only; the orchestrator cannot touch the DB; `db-introspection-scanner` is the only MCP exit.

The cost crossover against a single long thread sits near **10 operations** (spawn fixed cost vs. quadratic context accumulation). `standard` (10) and `full` (20) are at or above it. `lite` is well below it — which is why `lite` was cut to 2 spawns rather than kept structurally uniform with the others.

- Routing facts live in `workflow-contract.json` `route-profiles`; judgement criteria and per-profile procedure live in `.codex/bdd-workflow/runbooks/complexity-routing.md`.
- The chosen profile is stored in `bdd-docs/runs/{run-id}/workflow-state.json` `runtime-metadata.profile` and reused on resume — never re-assessed mid-run. Handoffs carry it in the `tier:` field.
- When signals are ambiguous, **round up**. If the profile is never confirmed, the default is **standard**, never lite.
- Escalation (lite→standard→full) is allowed at any time and stops the current delegation; downgrade requires an explicit user request.
- **`full` is capped at 20 delegations too.** Exceeding it means the slicing is too fine or the scope too large — checkpoint and ask the user to split into multiple runs. `full` is no longer unbounded.
- Profile selection never overrides secret safety, DLP masking when sources are flagged sensitive, safe-change approvals, or smoke-test/DB approvals. Those apply at every profile.

### Enforcement

Budgets and handoff rules are not honour-system. `.codex/scripts/handoff-lint.ps1` runs as a `PreToolUse` hook before every subagent spawn and blocks on: handoff > 1200 chars, multiple `mode:` declarations, missing `mode`/`tier`, forbidden payloads (connection strings, secret literals, DLP mapping tables, long test output), and `quality-loop.iteration >= 3` with `last-verdict: FAIL`.

## Codex Paths

- Workflow contract: `.codex/bdd-workflow/workflow-contract.json`
- Policies: `.codex/bdd-workflow/policies/`
- Runbooks: `.codex/bdd-workflow/runbooks/`
- Handoff templates: `.codex/bdd-workflow/templates/`
- Supporting instructions: `.codex/bdd-workflow/instructions/`
- Repo skills: `.agents/skills/`
- Runtime state and artifacts: `bdd-docs/`

## Lean SDLC Scope

The BDD orchestrator aligns only these SDLC stages with explicit artifacts and evidence:

- 需求收集: requirement list, source-materials register, background summary, pain points, business goals, open questions.
- 需求分析: requirement spec, user stories, acceptance criteria, example map, Gherkin draft, priority, domain glossary.
- 系統分析: flow-description, system boundary summary, integration list, data requirements analysis, project profile, impact report, source conflicts.
- 程式開發: Gherkin final, ATDD skeleton, step definitions, production code, unit tests, focused test evidence, build/test summary, code review findings.
- 設計橋接 (draft): API contract draft, ER model + data dictionary, sequence diagrams, module/transaction-boundary/error-code draft, design traceability, design review findings.
- 整合驗證 (evidence): contract test evidence, integration test evidence, smoke test evidence, gate-e review findings.

`living-doc` owns `bdd-docs/runs/{run-id}/artifacts/lean-sdlc-checklist.md`. Every stage boundary should update checklist rows with path, status, owner agent, last updated, evidence refs, and not-applicable reason when needed.

Design-bridge artifacts are drafts and integration-verification artifacts are evidence; both are lean-scoped and do NOT equal formal API/ER Model review or formal integration/E2E test reports.

Out of scope for this orchestrator: architecture design, program design review, formal functional/integration QA governance, release readiness, deployment guides, rollback plans, release notes, ADRs, formal E2E reports, and equivalent governance artifacts.

## Minimal Implementation Guardrail

Ponytail marketplace is optional. This repo uses local Codex instructions as the source of truth for coding minimalism, with `.codex/bdd-workflow/policies/minimal-implementation-policy.md` as the policy path.

- Apply the guardrail to `tdd-implementer`, `code-reviewer`（`mode: tdd`）, and `project-scanner` when scanning for reuse candidates.
- Before adding code, prefer existing behavior, existing helpers/patterns, standard-library/native features, then already-installed dependencies.
- Do not add frameworks, dependencies, abstractions, broad refactors, boilerplate, or future-proofing unless explicitly approved through the orchestrator.
- Minimalism never overrides Gate rules, lean SDLC checklist/evidence, DLP/secret safety, safe-change approvals, validation, error handling, security, accessibility, tests, or build evidence.
- If Ponytail plugin is installed later, treat it as an auxiliary productivity layer; review and trust its hooks before applying it broadly, and avoid starting BDD workflows in ultra mode.

## Loading Order

When starting or resuming a BDD workflow, read only the minimum context in this order:

1. `.codex/bdd-workflow/bdd-workflow-version.json` — version compatibility only.
2. `bdd-docs/workflow-state.json`.
3. Active run `workflow-state.json` runtime metadata (including `runtime-metadata.profile`, `quality-loop`, and `subagent-calls`), `index.md`, and recent or delta `log.md` entries.
4. The relevant context pack path and short summary.
5. Full artifacts only when needed for a gate, reviewer, repair, or digest mismatch.

**Do not read `workflow-contract.json` at startup.** It is a pointer file: the version lives in the version file, routing in `route-profiles.json`, gate conditions in each gate's own confirmation file. Reading it whole costs ~3k tokens that then stay resident for the entire run. Read it only on a version-check failure, or when `compiled-context` / `operations` / `repo-index` detail is actually needed.

`route-profiles.json` is read once per run, at `complexity-assessment`. On resume it is not read at all — `runtime-metadata.profile` already holds the answer.

Everything else is read on demand only: per-gate confirmation files, `lean-sdlc-schema.json`, `agent-skill-matrix.json`, policies, and runbooks are all pointer-loaded, never preloaded.

## User Confirmation

- Use explicit user confirmation for workflow start, resume, gate passage, phase switching, conflict decisions, smoke tests, DB introspection, and high-risk changes.
- Gate passage confirmation must name the Gate, the next stage, the document refs the user should review, and the concrete verification checklist. Read the single file `.codex/bdd-workflow/gate-confirmations/{gate-id}.json` — it carries that gate's `requires`, `merges`, documents, and checklist — plus `.codex/bdd-workflow/templates/gate-confirmation.md`; never ask only a generic "continue/pass Gate?" question. For a merged gate (`gate-lite`, `gate-std-1`, `gate-std-2`), do not fall back to reading the gates it merges.
- Before asking for Gate passage, repair missing/stale artifact refs or incomplete lean SDLC checklist rows through `living-doc`; Gate confirmations must reference path/version/digest/evidence refs, not full artifacts.
- Where the gate file offers `approve-and-resume-in-new-conversation`, present it alongside plain approval. Everything the orchestrator reads stays in the conversation and is re-sent every subsequent turn, so a long run pays for its own history; a Gate is the one point where the checkpoint is complete enough that starting a fresh conversation loses nothing. It is a variant of approval, not an extra question, and not a pause — the run is already approved into the next stage. Recommend it once `subagent-calls.count` − `count-at-last-reset` reaches 4.
- If confirmation is canceled, skipped, or incomplete, treat approval as not granted. Ask once more in a shorter form; if still unresolved, stop the high-risk step.
- DB introspection must first confirm the schema source strategy: user-provided schema/DDL/screenshot, code/doc inference, approved read-only DB MCP, or no DB introspection.
- Live DB access is MCP-only and must follow `.codex/bdd-workflow/policies/db-mcp-introspection-policy.md`. If no DB MCP tool is available in the current Codex session, `db-introspection-scanner` must return `blocked` and use manual schema/source alternatives.
- Never store DB credentials, connection strings, MCP secrets, or row-level sensitive data in repo files, prompts, logs, or artifacts.

## Tool Mapping

- Source `agent` delegation maps to Codex custom subagent spawning.
- Source `edit` / `editFiles` maps to `apply_patch`.
- `bdd-orchestrator` may write three run-state files directly — `log.md` (append only), `workflow-state.json` `runtime-metadata`, and existing rows in `lean-sdlc-checklist.md`. Everything else it produces still goes through `living-doc`. This scoped allowance replaced a round-trip-per-state-update pattern that dominated the token cost; it does not weaken auditability, because decision-log, checkpoints, and all artifacts remain `living-doc`-owned.
- Source `execute` / `runInTerminal` maps to Codex shell commands under the current sandbox and approval policy.
- Source `vscode_askQuestions` / `vscode/askQuestions` maps to explicit user confirmation in the parent Codex conversation.
- Source tool lists are behavior guidance, not a strict permission boundary. Use Codex sandbox, approval, hooks, and MCP settings as the actual enforcement layer.

## Lazy Skill Loading

Use `.agents/skills` only when the active task matches the skill trigger. Do not preload downstream skills just because the user expects a full BDD workflow.

- Quality loop and verdict parsing: `quality-loop`
- Interrupted runs, timeouts, partial completions, and transport failures: `interruption-recovery`
- Safe change boundaries, migrations, public contracts, DB risk: `safe-change`
- Flaky tests and environment instability: `test-reliability`
- Unknown blast radius or impact: `impact-analysis`

## Keep `.github` Stable

The `.github` agent, skill, hook, and instruction files remain as the GitHub Copilot source version. Do not edit them during Codex workflow runs unless the user explicitly asks to maintain the Copilot version.
