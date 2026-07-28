# Minimal Implementation Policy

This policy is a local, Ponytail-inspired coding minimalism guardrail. It is not a replacement for the BDD orchestrator, lean SDLC artifact checklist, Gate rules, DLP, safe-change approvals, tests, or evidence requirements.

## Scope

Applies to:

- `tdd-implementer`
- `code-reviewer`（`mode: tdd`）
- `project-scanner` when scanning for reuse candidates or implementation impact

Does not apply to:

- `living-doc` checklist, context-pack, checkpoint, evidence, or lint maintenance
- required Gate evidence
- DLP, secret-safety, safe-change, accessibility, validation, error handling, or security controls

## External Plugin Position

The Ponytail marketplace plugin is optional. If installed, treat it as an auxiliary productivity layer only.

- Recommended initial mode: normal/full/default.
- Avoid starting a BDD workflow in ultra-minimal mode unless the team has reviewed and trusted the plugin hooks.
- Local Codex instructions remain sufficient when the plugin is not installed.

## Pre-Implementation Ladder

Before editing production code, check in this order:

1. Does the existing behavior already satisfy the acceptance criteria? If yes, return evidence and do not change code.
2. Is there an existing helper, service, endpoint, fixture, extension method, or local pattern that already solves this slice?
3. Can a standard-library or native framework feature solve it before adding a dependency?
4. Can an already-installed dependency solve it before adding a new dependency?
5. If code is required, make the smallest focused diff that satisfies the current failing test or behavior slice.

## Prohibited Without Orchestrator Approval

- New framework
- New dependency
- New abstraction layer or generic engine
- Broad refactor unrelated to the current slice
- Boilerplate generated for future scenarios
- Cross-layer rewrite
- Future-proofing not requested by the current story

## Required Preservation

Minimalism must preserve:

- validation
- error handling
- security and DLP protections
- accessibility where UI is touched
- existing observability conventions
- tests, build evidence, and focused verification
- lean SDLC checklist rows, artifact paths, statuses, owners, evidence refs, and not-applicable reasons

## Review Focus

Reviewers should flag unnecessary size or novelty as defects, especially:

- `over-engineering`
- `unapproved-dependency`
- `unnecessary-abstraction`
- `missed-existing-helper`
- `missed-stdlib-or-native-feature`

Do not ask to remove required workflow controls, tests, evidence, DLP/security handling, or lean SDLC artifacts in the name of minimalism.
