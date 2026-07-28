# ATDD Runbook: skeleton / resume / fix

Use only after `atdd-automator.agent.md` selected a mode.

## Read Order

Read only the minimum files needed for the current slice:

1. active run `workflow-state.json` artifact refs
2. project profile digest / coding standards
3. impact report or safe-change envelope digest
4. reviewed `.feature` file
5. existing step definitions / driver/helper only when resuming or fixing

Do not read full logs, full source register, unrelated features, or full test output.

## mode: skeleton

Goal: create executable ATDD outer loop, not full business implementation.

Steps:

1. Verify `.feature` exists and is reviewed.
2. Verify or create test project and BDD package references.
3. Create thin step definitions for current scope.
4. Create scenario context, hooks, driver/helper, and test host.
5. Build binding coverage baseline:

   * total steps
   * bound steps
   * pending bindings
   * step definition method count
   * orphan step definitions
6. Select one walking skeleton candidate.
7. Run focused acceptance test for the candidate.
8. Mark unsupported business behavior as `deferred-to-tdd`.

## Walking Skeleton Candidate

Prefer a scenario that:

* is happy path
* crosses the main system boundary
* avoids real external services
* avoids real DB mutation
* avoids migration or public contract change
* can run locally, in CI, or in sandbox
* proves `.feature` → step definition → driver/helper → system boundary

If every candidate requires risky external dependencies, return `blocked` with approval questions for orchestrator.

## Thin Step Definition Rules

Allowed:

* bind Gherkin text to code
* manage scenario context
* call driver/helper
* transform test input into request / command / DTO
* assert observable outputs

Forbidden:

* business logic
* domain decisions
* repository queries
* production behavior implementation
* hidden mocks that bypass the main behavior
* real DB or external environment access without approval

## Smoke Test Boundary

ATDD should create smoke-test-ready entry points.

Execute external smoke tests only after orchestrator approval for:

* target environment
* base URL
* credentials handling
* test data setup
* data cleanup
* allowed impact

Without approval, return `partial-completed` or `blocked`.

## mode: resume

1. Inspect existing `.feature`, step definitions, driver/helper, context, hooks.
2. Skip valid existing bindings.
3. Fill only missing bindings or missing driver/helper pieces.
4. If walking skeleton was not verified, focus on the smallest candidate.
5. If walking skeleton was already verified, rerun minimal verification and return TDD baseline.
6. Do not start TDD implementation.

## mode: fix

1. Read reviewer defects.
2. Fix only ATDD defects.
3. Prioritize:

   * missing bindings
   * orphan bindings
   * thick step definitions
   * invalid context injection
   * weak boundary assertions
   * walking skeleton failure
4. If a defect requires production business behavior, do not implement it here; mark `deferred-to-tdd` or return `blocked`.

## Return

Always return:

* artifact paths and versions
* scenario counts
* binding coverage counts
* walking skeleton status
* command summary
* completed-items
* pending-items
* evidence refs

Never paste full test output, full feature file, full logs, or unrelated source files.

