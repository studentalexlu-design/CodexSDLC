# Lean SDLC Artifact Checklist

> Scope: 需求收集、需求分析、系統分析、設計橋接（draft）、程式開發、整合驗證（evidence）.
> Excluded: 架構設計、程式設計審查、正式功能/整合驗測治理、上線檢核 and their formal governance artifacts.
> 設計橋接產物為 draft、整合驗證為 evidence，皆不等同正式 API/ER Model 審查或正式整合/E2E 測試報告。

## Metadata

- run-id: `{run-id}`
- feature-id: `{feature-id}`
- current-bdd-stage: `{stage}`
- last-updated: `{timestamp}`
- owner-agent: `living-doc`

## Status Values

Allowed status values: `pending`, `in-progress`, `completed`, `blocked`, `not-applicable`.

When status is `not-applicable`, `not-applicable reason` is required. Do not mark an artifact as complete only because it is out of scope.

## 需求收集

| Artifact | Path | Status | Owner Agent | Last Updated | Evidence Refs | Not-Applicable Reason |
| --- | --- | --- | --- | --- | --- | --- |
| 需求清單 | TBD | pending | living-doc | TBD | TBD |  |
| 來源素材登錄 | `bdd-docs/runs/{run-id}/artifacts/source-materials-register.md` | pending | living-doc | TBD | TBD |  |
| 訪談/背景摘要 | TBD | pending | living-doc | TBD | TBD |  |
| 痛點 | TBD | pending | living-doc | TBD | TBD |  |
| 業務目標 | TBD | pending | living-doc | TBD | TBD |  |
| open questions | TBD | pending | living-doc | TBD | TBD |  |

## 需求分析

| Artifact | Path | Status | Owner Agent | Last Updated | Evidence Refs | Not-Applicable Reason |
| --- | --- | --- | --- | --- | --- | --- |
| 需求規格 | TBD | pending | analyst | TBD | TBD |  |
| User Story | TBD | pending | analyst | TBD | TBD |  |
| Acceptance Criteria | TBD | pending | analyst | TBD | TBD |  |
| Example Map | TBD | pending | analyst | TBD | TBD |  |
| Gherkin 草稿 | TBD | pending | formulator | TBD | TBD |  |
| 需求優先級 | TBD | pending | analyst | TBD | TBD |  |
| domain glossary | TBD | pending | analyst | TBD | TBD |  |
| SQL 規則處置決策 | `bdd-docs/runs/{run-id}/artifacts/legacy-sql-analysis/{feature-id}.md` | pending | analyst | TBD | TBD | 非舊系統重構 / 無 business-rule 時標 not-applicable |

## 系統分析

| Artifact | Path | Status | Owner Agent | Last Updated | Evidence Refs | Not-Applicable Reason |
| --- | --- | --- | --- | --- | --- | --- |
| flow-description | `bdd-docs/runs/{run-id}/artifacts/flow-description.md` | pending | analyst | TBD | TBD |  |
| 系統邊界摘要 | TBD | pending | project-scanner | TBD | TBD |  |
| 介接清單 | TBD | pending | project-scanner | TBD | TBD |  |
| 資料需求分析 | TBD | pending | analyst | TBD | TBD |  |
| project profile | `bdd-docs/artifacts/project-profile.md` | pending | project-scanner | TBD | TBD |  |
| impact report | TBD | pending | project-scanner | TBD | TBD |  |
| legacy SQL 邏輯萃取 | `bdd-docs/runs/{run-id}/artifacts/legacy-sql-analysis/{feature-id}.md` | pending | analyst | TBD | TBD | 非舊系統重構 / 無 SQL 邏輯時標 not-applicable |
| source conflicts | `bdd-docs/runs/{run-id}/artifacts/source-conflicts.md` | pending | living-doc | TBD | TBD |  |

## 設計橋接（draft）

> P0-1：draft 設計契約，位於 formulate 後、atdd 前；並入 `gate-contract` 一次確認（**實作前**）。不適用項目標 `not-applicable` + reason。

| Artifact | Path | Status | Owner Agent | Last Updated | Evidence Refs | Not-Applicable Reason |
| --- | --- | --- | --- | --- | --- | --- |
| API contract draft | `bdd-docs/runs/{run-id}/artifacts/design/api-contract.yaml` | pending | design-modeler | TBD | TBD |  |
| ER model + data dictionary | `bdd-docs/runs/{run-id}/artifacts/design/` | pending | design-modeler | TBD | TBD |  |
| sequence diagrams | `bdd-docs/runs/{run-id}/artifacts/design/sequence/` | pending | design-modeler | TBD | TBD |  |
| 模組/交易邊界/錯誤碼草案 | `bdd-docs/runs/{run-id}/artifacts/design/module-design.md` | pending | design-modeler | TBD | TBD |  |
| design traceability | `bdd-docs/runs/{run-id}/artifacts/design/design-traceability.md` | pending | design-modeler | TBD | TBD |  |
| design review findings | TBD | pending | spec-reviewer (mode: design) | TBD | TBD |  |

## 程式開發

| Artifact | Path | Status | Owner Agent | Last Updated | Evidence Refs | Not-Applicable Reason |
| --- | --- | --- | --- | --- | --- | --- |
| Gherkin 定稿 | TBD | pending | formulator | TBD | TBD |  |
| ATDD skeleton | TBD | pending | atdd-automator | TBD | TBD |  |
| step definitions | TBD | pending | atdd-automator | TBD | TBD |  |
| production code | TBD | pending | tdd-implementer | TBD | TBD |  |
| unit tests | TBD | pending | tdd-implementer | TBD | TBD |  |
| focused test evidence | TBD | pending | tdd-implementer | TBD | TBD |  |
| build/test summary | TBD | pending | tdd-implementer | TBD | TBD |  |
| code review findings | TBD | pending | code-reviewer (mode: tdd) | TBD | TBD |  |

## 整合驗證（evidence）

> P0-3：契約/整合/smoke 測試證據，位於 tdd 後、收尾前；由交付 Gate 確認（`t2` → `gate-close`；`t3` → `gate-release`）。不適用項目標 `not-applicable` + reason。

| Artifact | Path | Status | Owner Agent | Last Updated | Evidence Refs | Not-Applicable Reason |
| --- | --- | --- | --- | --- | --- | --- |
| contract test evidence | `bdd-docs/runs/{run-id}/artifacts/integration/contract-test-evidence.md` | pending | integration-tester | TBD | TBD |  |
| integration test evidence | `bdd-docs/runs/{run-id}/artifacts/integration/integration-test-evidence.md` | pending | integration-tester | TBD | TBD |  |
| smoke test evidence | `bdd-docs/runs/{run-id}/artifacts/integration/smoke-test-evidence.md` | pending | integration-tester | TBD | TBD |  |
| delivery-gate review findings | TBD | pending | code-reviewer (mode: tdd) | TBD | TBD |  |

## Out Of Scope Requests

If a request asks for formal architecture review, program design review, formal integration/E2E test governance, or release readiness, record it here as out of scope instead of creating release or governance checklists.

| Request | Requested By | Decision | Evidence Refs |
| --- | --- | --- | --- |
