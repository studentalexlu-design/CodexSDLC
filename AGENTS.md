# Codex Instructions — SDLC Workflow (v4.0.0)

This repo is configuration only. Every file here is a prompt, policy, or script that configures the Codex CLI. There is no product code.

**What this workflow is for:** help the user make correct decisions faster at each SDLC stage, then produce the code correctly. Everything below is an instrument kept only while it buys correctness or speed.

## First move

If the user asks for feature work, bug work, or anything that ends in code: **spawn `bdd-orchestrator` as a top-level agent right away, passing the user's sentence verbatim.**

Do not survey the repo first. Do not read agent definitions or skills — the orchestrator loads its own. Do not run `git status` to orient yourself. Every read done here is a read the orchestrator will do again, and its context is the one that matters.

**The user does not supply `mode`, `feature-id`, or a path.** The orchestrator derives all three. Never bounce a request back asking for them.

Handle yourself, no spawn: answering a question about the code, a one-line edit, a typo, a rename.

## The flow

```
① BA  requirement analysis   orchestrator, in-conversation — find gaps the user did not state
② SA  system analysis        sa-analyst — read specs/repo/schema, return 2–4 approaches
③ settle                     confirm approach + acceptance criteria → write spec.md
④ build                      implementer — test-first, run to green
⑤ review                     reviewer — independent context
⑥ deliver                    report what changed, how it was verified, residual risk
```

**Two mandatory user confirmations only**: ① gaps (skipped when there are none) and ③ settle. A third appears at ⑥ only when the change is irreversible.

**BA before SA, never merged.** The BA answer determines what the SA has to look for. Asking "can a shipped order be cancelled?" and hearing "yes, via returns" is what makes the system search for a returns flow; hearing "no" means never searching. Merging the two forces exploring both branches.

**BA is not delegated.** It reads almost nothing — its input is the user's request and its reference is general domain knowledge. Delegation buys the reads that would not fit in the orchestrator's context; BA has none, so a spawn would pay a 4–8k cold start for reasoning the orchestrator can already do, and lose the ability to converse about it.

## Agents

Five, all under `.codex/agents/`. `bdd-orchestrator` must run as a **top-level** agent — as a child it cannot spawn, and the hooks that enforce everything below never fire.

| Agent | Why it gets its own context |
|---|---|
| `bdd-orchestrator` | Holds the conversation. Does BA itself, delegates the rest. |
| `sa-analyst` | Reads specs, repo, and schema files — high read volume, small return. |
| `implementer` | Test-first implementation, many read/write iterations. |
| `reviewer` | **Independence is the point.** A reviewer sharing the implementer's context re-confirms the same assumptions. |
| `db-introspection-scanner` | Sole exit for live DB. A **security** boundary, not a context one. |

Delegation buys exactly one thing: reads that never enter the orchestrator's context. That is the only test for whether a step deserves a spawn.

## Artifacts

| Path | Written by | When |
|---|---|---|
| `bdd-docs/{feature-id}/spec.md` | orchestrator | after ③, always |
| `.feature` + step definitions (**in the project's test tree**) | `implementer` | ④, landed verbatim from ③'s Gherkin block |
| `bdd-docs/{feature-id}/evidence/db-*.md` | `db-introspection-scanner` | after every live DB query, always |
| `bdd-docs/{feature-id}/analysis.md` | `sa-analyst` | only when ② did **not** finish (`blocked`/`partial`) |
| `bdd-docs/{feature-id}/contract/*` | `sa-analyst` | only with real external consumers or a real schema change |
| `bdd-docs/artifacts/legacy-schema/*.sql` | `db-introspection-scanner` | only when reverse-engineering legacy SQL |
| code and tests | `implementer` | ④ |

Nothing else is produced — no state files, no progress records, no stage handoff documents.

**The test is what it costs to get again, not whether it counts as state.**

- Re-thinkable inside a context that already exists (① 's reasoning, how far along we are, who handed off to whom) → **off disk**. Re-running is nearly free; maintaining it is not.
- Costs **another spawn** to recover (`sa-analyst`'s unfinished analysis) → **on disk, but only when it did not finish.** A completed analysis goes straight into `spec.md`; the happy path gains no file.
- Obtained through **user approval or a live-system round trip** (DB introspection, legacy SQL definitions) → **always on disk.** Losing it means paying for the approval and the wait a second time, and nothing anywhere accounts for that.

It also resolves a hard conflict: handoffs are capped at 1200 chars, so DB metadata cannot travel inline — but `sa-analyst` needs it. A file is the only form that satisfies both.

So a lost conversation is not a restart: `spec.md` and `evidence/` survive, ① is pure reasoning (nearly free), and only ②'s static analysis costs another spawn. Cheaper than maintaining a state machine.

## Gherkin is a QA deliverable, not documentation

Acceptance criteria are written as Gherkin inside `spec.md` at ③, then landed **verbatim** as `.feature` by `implementer` at ④ — alongside that project's unit tests, never under `bdd-docs/`. QA builds automation on those files.

Everything follows from that: C# uses Reqnroll, Java uses Cucumber (an existing framework in the project always wins); step definitions are written for reuse because QA adds scenarios; and **changing an existing step's wording is a breaking change** — it silently breaks QA's automation in *their* repo, so it triggers the same confirmation as changing a public API. Adding steps or scenarios does not.

The one exception: a change with no acceptance-testable behaviour (pure refactor, dependency bump, config) gets a one-line DoD instead. Don't apply the format for its own sake.

## Always-on principles

1. **Irreversibility is confirmed, not inferred.** Two questions, asked at ⑥ and required in every `sa-analyst` option: does it touch **existing data or live traffic**? do **consumers I don't control** see a difference? Either yes → stop and get the user's answer. Providing a contract counts; consuming someone else's does not. QA's automation is such a consumer — see the Gherkin section.
2. **Safe change.** Migrations, DB access, smoke tests, and starting a web/API surface require explicit user approval. This never relaxes with change size.
3. **Secret safety.** Never write credentials, connection strings, API keys, or DLP mapping tables to `bdd-docs/`, artifacts, logs, or prompts.
4. **Green means green.** `failed == 0` and `skipped == 0`. A skip is not a pass — it is reported as a risk.
5. **Minimal implementation.** Build what the acceptance criteria ask for. Input validation, error handling, security, and necessary tests are not "extra" and are never cut in the name of minimalism.
6. **Bounded vs unbounded unknowns.** Bounded (single verifiable answer, ≤3 read-only operations) → the agent resolves it itself. Unbounded (needs logic reconstruction, cross-system comparison, live DB, binary files, or no unique answer) → return `blocked` with what to look for and what was already checked. An unbounded unknown is never absorbed by scanning wider.
7. **Rough beats timed-out.** An agent running out of room returns `partial` with what it has; a timeout returns nothing and voids every approval and wait that preceded it. When a subagent times out after a long run, the recovery is **cutting scope**, never compressing the prompt — a shorter prompt does not shrink the work.

## Enforcement

Rules in prompts are honour-system; these are not.

- **`.codex/scripts/handoff-lint.ps1`** (`PreToolUse`, before every spawn) blocks on: handoff > 1200 chars, multiple `mode:` declarations, missing `mode` or `feature-id`, `mode: build|fix|code` without a `spec.md` **path**, `mode: fix` without `round` or past round 3, and forbidden payloads (connection strings, secret literals, DLP mapping tables, long test output).
- **`.codex/scripts/dlp-gate.ps1`** + **`dlp-residual-scan.ps1`** (`PostToolUse`) scan written artifacts. The residual scanner never emits matched values — only category, count, and line refs.
- **`.codex/scripts/build-check.ps1`** (`PostToolUse`, debounced) catches broken production-code edits early.
- **`.codex/scripts/agent-lint.ps1`** checks the config itself: AGENT-CORE identical across all agents, TOML structure, roster ↔ delegation table both directions, dangling policy/runbook/script/skill refs, and residue of v4-removed concepts.
- **`.codex/scripts/tests/run-tests.ps1`** — fixture tests for all of the above. Every check has a "deliberately broken input must go red" case, because a check that catches nothing is worse than no check.

## Paths

- Agents: `.codex/agents/`
- Scripts and hooks: `.codex/scripts/`, `.codex/hooks.json`
- Version: `.codex/bdd-workflow/bdd-workflow-version.json`
- DB policy: `.codex/bdd-workflow/policies/db-mcp-introspection-policy.md`
- Skills: `.agents/skills/`
- Runtime output (in the consuming project): `bdd-docs/`

## Tool mapping

- `agent` delegation → Codex custom subagent spawning
- `edit` / `editFiles` → `apply_patch`
- `execute` / `runInTerminal` → Codex shell under the current sandbox and approval policy
- `vscode_askQuestions` → explicit user confirmation in the parent Codex conversation

Source tool lists are behaviour guidance, not a permission boundary. Codex sandbox, approval, hooks, and MCP settings are the actual enforcement layer.

## Skills (load on hit, never preload)

- `requirement-gap-analysis` — BA gap checklist, read once when entering ①
- `gherkin-authoring` — writing acceptance criteria and step definitions QA can build on
- `safe-change` — change boundaries, migrations, public contracts, DB risk
- `test-reliability` — flaky tests, suspected false green
- `impact-analysis` — unknown blast radius
- `interruption-recovery` — timeouts, cancellations, partial returns

## Upgrading from v3.x

v4.0.0 is a clean break with no resume path. It removed the entire tier layer (`discover`/`t0`–`t3`), five gates, the run skeleton, and every run state file; it merged 12 agents into 5. A `bdd-docs/runs/` directory written by v3 is not readable by v4 — finish or abandon those runs before upgrading. Design reasoning lives in `docs/design-rationale.md` (for maintainers; never read at runtime).
