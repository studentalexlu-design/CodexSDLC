# DB MCP Introspection Policy

This policy controls live database introspection through MCP tools. MCP is a tool transport and evidence source; it does not replace `bdd-orchestrator` approval, safe-change boundaries, DLP rules, or artifact evidence.

## Scope

Live DB access is allowed only through currently available, explicitly configured DB MCP tools and only after `bdd-orchestrator` records user approval.

Allowed scopes:

- `metadata`: schemas, tables, columns, views, functions, procedures, indexes, and foreign keys.
- `definition`: view, function, and stored procedure definitions for approved objects.
- `approved-select`: narrow read-only SELECT queries approved either by an explicit per-query approval or by a valid run-scoped bounded SELECT authorization.

`run-scoped-default-select` authorization lets a run approve a bounded SELECT envelope once, then reuse it inside that same run without asking the user again for every matching query.

Default bounds:

- valid only for the approved `run-id`;
- default row limit is `50` when a lower per-query limit is not supplied;
- every query must name a table or view, exact columns, and purpose;
- `SELECT *` is forbidden;
- raw row-level result sets must not be written to prompts, logs, or artifacts.

The authorization expires when the run is completed/archived, when the authorization is revoked, or when a query would broaden scope. Scope broadening includes a new database/schema/object, additional columns, joins, sensitive fields, a new purpose, or a row limit above the approved cap.

If no DB MCP tools are callable in the current Codex session, `db-introspection-scanner` must return `blocked` and suggest manual alternatives: user-provided schema/DDL/screenshot or code/doc inference.

## Approval Envelope

The orchestrator handoff to `db-introspection-scanner` must include:

- run id and feature id
- approval summary and decision-log reference
- MCP server or connection profile alias, never credentials
- target database or schema, when known
- allowed scope: `metadata`, `definition`, or `approved-select`
- approved object list or bounded discovery target
- target report path under `bdd-docs/`

For `approved-select`, the handoff must include either an explicit per-query approval or a run-scoped authorization reference at `bdd-docs/runs/{run-id}/artifacts/db-select-authorization.md`.

With a valid run-scoped authorization, the handoff must include:

- table or view name
- exact columns
- purpose
- authorization ref and evidence ref
- row limit, when different from the default `50`

Without a valid run-scoped authorization, the handoff must also include row limit and why row data is required instead of metadata/definition.

## MCP Tool Use Rules

- Prefer structured MCP metadata/describe/list tools over raw SQL.
- Use raw query MCP tools only for metadata queries or approved controlled SELECT.
- Do not use shell, `sqlcmd`, ad hoc scripts, app connection strings, or direct driver code for live DB access.
- Do not request, receive, print, or persist credentials, connection strings, API keys, or secrets.
- Do not broaden scope after connecting. If more objects or data are needed, return `blocked` for orchestrator approval.

## Query Safety

Forbidden:

- DDL, DML, schema sync, migrations, stored procedure execution with side effects
- unrestricted `SELECT *`
- missing explicit column list
- joins or filters not approved by orchestrator for `approved-select`
- large exports, dumps, or sampling beyond the approved row limit
- writing raw result sets containing sensitive data into prompts, logs, or artifacts

Allowed:

- read-only metadata inspection
- definition reads for approved views/functions/procedures
- controlled SELECT with approved table/view, columns, row limit, purpose, and authorization ref when run-scoped default authorization is used

## Evidence Output

Write only summaries and evidence refs:

- metadata summary
- FK list and dependency order
- approved object definitions summary or path
- controlled SELECT summary with row count and redaction notes
- default SELECT authorization ref, when used
- MCP tool name/server alias used
- incomplete items and blockers

Artifacts must not contain secrets, raw credentials, DLP mapping tables, large result sets, or unnecessary row-level data.
