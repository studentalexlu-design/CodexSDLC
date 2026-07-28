# TDD Implementer — Data Layer / FK / Legacy SQL Guardrail

供 `tdd-implementer` 在切片涉及 data layer、FK/關聯、或 legacy SQL 重構時讀取。純邏輯切片（不碰 persistence、不涉及 legacy SQL 重構）不需要讀此檔。

## Data Layer 實作指引

當 backlog 中包含 data layer 切片時：

1. 先確認資料設計來源：
   - **full**：`bdd-docs/runs/{run-id}/artifacts/design/er-model.mmd` + `design/data-dictionary.md`（`design-modeler` 是**唯一**的資料模型 owner）。
   - **standard／lite**：不產出資料模型（該 profile 定義為不動 schema）。以 `repo-index` 的既有 entity／repository 符號與現有慣例為準；**若確實需要新增或變更 schema，停止並回報 orchestrator 升級 `full`**。
2. 實作順序：
   - Entity / Value Object（domain layer）
   - Repository 介面（domain layer）
   - Repository 實作（infrastructure layer）
   - DI registration
   - Migration（若適用）
3. Entity 的 business invariant 必須有對應的 unit test。
4. Repository 介面符合上述資料設計來源。
5. Migration 必須符合 `project-profile` 中的 migration policy。
6. 若 migration 涉及 breaking change，暫停並回報 orchestrator 走批准流程。

## FK 與關聯實作（強制）

當 data-model 包含「Entity 關聯」與「外鍵設計」表格時，必須依以下順序實作：

1. **Entity FK 屬性**：在 Entity 中定義 FK 屬性與導航屬性（依 data-model 的關聯表「導航方向」欄）。
2. **EF Core 關係設定**：在 DbContext 的 `OnModelCreating` 中設定 FK 約束、On Delete 政策與索引（依 data-model 的「外鍵設計」表）。
3. **跨 Entity 查詢方法**：實作 data-model 「查詢模型 / Read Model」表格中定義的投影查詢：
   - 使用 `.Include()` / `.ThenInclude()` 載入關聯資料，或使用 `.Select()` 投影為 DTO
   - 在 repository 內完成 JOIN，不對外暴露 `IQueryable`
4. **N+1 查詢防禦**：每個帶關聯資料的查詢方法，必須有對應的 unit test 驗證：
   - 查詢結果包含關聯資料（不是 null / 空集合）
   - 若使用 integration test，驗證 SQL 查詢次數不超過預期（避免 N+1）
5. **畫面欄位追溯驗證**：實作前檢查 data-model 的「畫面欄位 → 資料來源映射」表格，確認每個「需要 JOIN」的欄位都有對應的 repository 方法。若發現 gap，停止並回報 orchestrator。

## Legacy SQL 重構守門

當 active run 存在 `legacy-sql-analysis/{feature-id}.md`（舊系統重構）時：

- **不得把 `business-rule` 型別的 legacy SQL（含舊 app code 的 inline SQL 字串）整段複製到新 repository/DAL。**
- 每條 `move-to-domain` / `move-to-application` 規則必須實作於對應分層，並有 domain/application 層單元測試驅動（先 Red 再 Green）。
- `keep-in-sql` 規則的 repository 只能做 thin data-access（取值/塑形），且需留整合層對等驗證證據。
- `redesign` 規則依 Gate-B 裁定後的新行為實作，不沿用舊行為。
- 實作後回填 `legacy-sql-analysis` 「行為對等驗證」表的驗證狀態，供 Gate-E 對等比對。
