# Runbook: Design Bridge（P0-1）

> 供 `design-modeler` 與 `spec-reviewer`（`mode: design`） 於設計橋接階段（`design` / `design-done`）使用。
> Agent mode 檔只留摘要，操作細節放此。
> Skills：`api-contract-design`、`er-modeling`（或 `data-modeling`）、`code-review`。

## 階段定位

FSM：`formulate-done → design → design-done → data-model-p2-5 → atdd`。
在 Gherkin 定稿後、ATDD 外殼前，產出 draft 設計契約。不設獨立 user-confirmation Gate；
以 `spec-reviewer`（`mode: design`） 品質迴圈把關，並將 design draft 併入 **`gate-contract`** 一次確認（**位於任何 production 實作之前**）。

## Mode 執行順序（建議）

1. `api`（若有對外 API）→ 2. `data`（若有持久化）→ 3. `sequence`（關鍵流程）→ 4. `module` → 5. `traceability`。
每個 mode 單獨一輪委派；不適用者標 `not-applicable` + reason。

## 產出與路徑

| Mode | 產出 | 路徑 |
| --- | --- | --- |
| api | OpenAPI 3.1 draft | `design/api-contract.yaml` |
| data | ER 圖 + 資料字典 | `design/er-model.mmd`, `design/data-dictionary.md` |
| sequence | 關鍵 scenario 時序圖 | `design/sequence/{scenario}.md` |
| module | 模組/交易邊界/錯誤碼草案 | `design/module-design.md` |
| traceability | 追溯表 | `design/design-traceability.md` |

## 追溯表格式（design-traceability.md）

| Scenario/Rule | Endpoint (operationId) | Entity | Module | Notes |
| --- | --- | --- | --- | --- |

- 每個 endpoint 至少對映 1 rule + 1 example。
- traceability-coverage = 已追溯項 / 應追溯項。

## 目錄前置

若 `bdd-docs/runs/{run-id}/artifacts/design/` 不存在，先由 orchestrator 委派 `living-doc` 建立目錄或 checkpoint，再委派 design-modeler 產出內容（不在同一輪混合目錄修復與內容探索）。

## 切片與 partial-completed

- endpoint > 15 或 entity > 12：回 `partial-completed`，附 `completed-items`/`pending-items`/`next-step`。
- orchestrator 收到 partial 後先委派 `living-doc` checkpoint，再依 next-step 續跑下一最小切片。

## DLP 交叉檢查

- 命名不得洩漏 DB 實體/欄位（除官方業務術語）。
- spec-reviewer (mode: design) 發現疑似洩漏時，回報 orchestrator 觸發 `dlp-residual-scan.ps1`（見 `runbooks/dlp-verification.md`）。

## 品質迴圈與 `gate-contract`

- spec-reviewer (mode: design) `VERDICT: PASS|FAIL`，最多 3 輪，超過升級 user arbitration。
- PASS 後 orchestrator 將 design draft 併入 `gate-contract` `documents-to-review`，
  `gate-contract` `requires` 檢查 `spec-reviewer.verdict == PASS (mode: design)`。
- living-doc 於 checklist「設計橋接（draft）」區段更新 path/status/evidence refs。

## 適用性（N/A 準則）

- 純 UI/無 API → `api` = N/A。
- 無資料持久化 → `data` = N/A。
- 無跨元件互動 → `sequence` 可精簡。
- 皆 N/A 時 design 階段快速通過，`gate-contract` 以 `design.not-applicable` 放行（`t2` 仍須有 data/API contract）。
