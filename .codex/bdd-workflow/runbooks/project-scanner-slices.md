# Project Scanner Runbook: bounded scan slices

Use only after `project-scanner.toml` selected a mode.

> **索引優先**：正常路徑是讀 `.codex/scripts/repo-index.ps1` 產生的 `index.json`，
> 不走訪原始碼樹。程序見 `runbooks/repo-indexing.md`。
> 本檔的「Read/search」清單只在**腳本不可用**時作為退化路徑使用
> （evidence 需標 `environment: index-unavailable`）。

## mode: index

Goal: build or refresh the deterministic index.

1. `repo-index.ps1 -StatusOnly` → check `needs_refresh` and `stale_scopes`.
2. Refresh only when stale; the script rescans just the stale scopes.
3. Return the script summary. Do not read the source tree.

## mode: inventory

Goal: identify the project boundary.

**Normal path**: read `index.json` only — `projects`, `test-toolchain`, `entrypoints`, `config-keys`.
Test-toolchain detection is the script's job; write it into `coding-standards.md` without overwriting manual content.

Fallback path (index unavailable):

- `.sln` and relevant `.csproj`
- top-level README/Jenkinsfile only if needed
- `Program.cs`, DI registration files, controller folders by names first
- appsettings key paths only, not values

Output/update:

- `bdd-docs/artifacts/project-profile.md` project structure, build/test command candidates, runtime type, known config categories
- completed-items and pending-items

Stop after inventory. Do not proceed to impact in the same invocation.

## mode: impact

Goal: determine safe-change envelope for the feature.

**Normal path**: run `impact-scope.ps1 -Keywords '<comma-separated>' -TopN <profile impact-top-n>`,
then read **only** the returned candidates. Files outside the list require a stated reason in the return.

Fallback path (index unavailable):

- active run source register and intake context pack
- files named by source clues
- controllers/services/models/repositories directly related to the feature

Output/update:

- active run impact report under `artifacts/impact-reports/`
- editable paths, forbidden paths, risky areas
- public surface / DI / DTO / config / DB risk summary

Return `db-introspection-needed` if DB metadata is required.

## mode: runtime-and-db-policy

Goal: prepare later approvals.

Do not run DB or long commands. Summarize:

- likely build/test/run commands from project files and docs
- smoke test entry candidates
- DB introspection scope needed: metadata, definition, approved-select
- candidate run-scoped bounded SELECT envelope when row-level evidence may be needed: database/schema, table/view, explicit columns, purpose, default row limit 50, sensitive-field warning, and manual alternative
- questions orchestrator should ask the user

## mode: resume

Use completed-items to skip done work. Read only the files needed for pending-items.

## Partial Completion

Return partial when:

- more than one scan mode remains
- more than 12 files would need to be read
- a long command would be required without approval
- DB details or user choices are needed

Partial response must include completed-items, pending-items, completion-percentage, blocking-reason, and evidence refs.
