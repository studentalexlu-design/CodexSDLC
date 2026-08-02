# DB MCP Introspection Policy

Controls live database introspection through MCP tools. MCP is a tool transport and an evidence source; it does not replace user approval, safe-change boundaries, DLP rules, or artifact evidence.

## Schema source strategy

Before any introspection, `bdd-orchestrator` confirms which of these four the work will use. **Only the third continues into this policy**; the others skip live DB entirely and are usually cheaper.

1. `user-provided-schema-ddl-or-screenshot`
2. `code-doc-inference` — migration files, ORM models, `*.sql` in the repo
3. `approved-read-only-db-mcp`
4. `no-db-introspection`

Never request or persist credentials while confirming this.

## Scope

Live DB access is allowed only through currently available, explicitly configured DB MCP tools, and only after the user has approved.

| Scope | What it covers |
|---|---|
| `metadata` | schemas, tables, columns, views, functions, procedures, indexes, foreign keys |
| `definition` | view / function / stored-procedure definitions for approved objects |
| `approved-select` | narrow read-only SELECT with an explicit approval summary in the handoff |

**Approval travels in the handoff, not in the conversation.** `db-introspection-scanner` is cold-started and cannot see the approving exchange. "The approval isn't in my transcript" is never a valid reason to return `blocked`; if an external mechanism blocks anyway, return `blocked` marked `harness-approval-gate` so the orchestrator knows the scope needs no renegotiation.

`metadata` and `definition` are satisfied by the approval summary plus a named target object. **Do not demand a column list or row limit for them** — that is over-blocking, and it pushes work onto the far more expensive manual path.

`approved-select` additionally requires: table or view, **exact column list**, purpose, and a row limit (default `50`). `SELECT *` is forbidden. Every call carries its own approval summary — there is no standing authorization that outlives it, because a standing grant drifts out of scope without anyone noticing.

If no DB MCP tool is callable in the current session, return `blocked` and suggest strategy 1 or 2.

## Tool use rules

- Prefer structured MCP metadata / describe / list tools over raw SQL.
- Use raw query tools only for metadata queries or an approved controlled SELECT.
- **Never** use shell, `sqlcmd`, ad hoc scripts, application connection strings, or direct driver code for live DB access.
- Never request, receive, print, or persist credentials, connection strings, API keys, or secrets.
- Do not broaden scope after connecting. Needing more objects or data means returning `blocked` for a fresh approval.
- **An adapter returning no result set is not evidence of zero rows, and one failed call is not evidence of a missing capability.** `Rows affected: -1`, an empty response, or a response with no column headers means the result set is unavailable — report that literally. Never read it as "no matching rows", and never generalize it into "this tool cannot return rows": a call that returned rows earlier already refutes that. Report the distinguishing facts (parameter differences from the last successful call, whether the data could genuinely be empty, whether an error was swallowed) and let the orchestrator decide. Closing off the whole DB path on a single failure costs every fact still unreached on it.

## Query safety

**Forbidden:** DDL, DML, schema sync, migrations, side-effecting procedure execution, unrestricted `SELECT *`, missing column list, unapproved joins or filters, exports or sampling beyond the approved row limit, and writing raw sensitive result sets into prompts, logs, or artifacts.

**Allowed:** read-only metadata inspection, definition reads for approved objects, and controlled SELECT within the approved envelope.

## Output

Return summaries and refs only: metadata summary, FK list and dependency order, definition summary or landed path, controlled-SELECT summary with row count and redaction notes, MCP tool/server alias used, and anything left incomplete.

Landed files and returns must never contain secrets, credentials, DLP mapping tables, large result sets, or unnecessary row-level data. Masking rules: `runbooks/dlp-masking.md`.
