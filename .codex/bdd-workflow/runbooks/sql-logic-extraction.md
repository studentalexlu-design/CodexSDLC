# Runbook: Legacy SQL Logic Extraction

> 供 `db-introspection-scanner`、`project-scanner`、`analyst` 於舊系統重構時萃取 SQL 內嵌業務邏輯使用。
> Agent mode 檔只留摘要，操作細節放此。
> Skills：`impact-analysis`、`data-modeling`、`safe-change`。

## 目的

舊專案的業務邏輯常寫死在 SQL（CASE WHEN / JOIN 篩選 / temp table / cursor / 動態 SQL），
重構時容易被整段複製到新專案。此 runbook 把 SQL 拆成「純資料存取」與「業務規則」，
讓業務規則走使用者處置決策，並在開發階段落實分層與行為對等驗證。

## 階段定位

- 萃取（識別）：`scan` 系統分析階段，併入 **Gate-A**。
- 處置決策（使用者規劃確認）：`domain` 需求分析階段，併入 **Gate-B**。
- 分層落實：`design`（Gate-D）+ `tdd`。
- 行為對等驗證：`integration`（Gate-E）。

不新增 FSM stage；掛在既有 `scan` 與 `domain`。

## 產物

- 模板：`bdd-docs/artifacts/legacy-sql-analysis/template.md`
- 實例：`bdd-docs/runs/{run-id}/artifacts/legacy-sql-analysis/{feature-id}.md`
- 目錄若不存在，由 orchestrator 委派 `living-doc` 先建立，再委派內容產出。

## 兩類來源偵測法

### db-object（`db-introspection-scanner`，`definition` mode）
讀 View / Stored Procedure / Function / Trigger 定義，標記含業務邏輯的構件位置：
- `CASE WHEN` 內含分類/計算
- JOIN / WHERE 表達的資格或篩選判定
- `#temp` / `@table` / CTE 承載中間業務計算
- `DECLARE CURSOR` 逐筆處理
- SP 內 `IF` / `WHILE` / 交易控制
- 動態拼接（`EXEC(@sql)` / `sp_executesql`）

輸出「邏輯訊號清單」：構件型別 + 物件名/行號 ref（DLP 遮蔽），**不回傳完整定義**。

### inline-code-sql（`project-scanner`，`inventory` / `impact` mode）
掃描舊應用程式碼內嵌 SQL（與 db-object **並列的一級來源**）：
- 字串拼接 SQL（字串常值 + `+` / 內插 + `SELECT`/`WHERE`/`CASE`）
- ORM raw query：`FromSqlRaw` / `FromSqlInterpolated` / `ExecuteSqlRaw` / `Database.SqlQuery`
- Dapper / ADO.NET：`Query<>` / `Execute` / `SqlCommand` / `DbCommand.CommandText`
- 程式碼動態組 SQL：`StringBuilder` 拼 SQL、條件式 append WHERE
- 內嵌 SP 呼叫：`CommandType.StoredProcedure`

輸出「inline-sql 邏輯訊號清單」：構件型別 + 檔案路徑/行號 ref（DLP 遮蔽），不貼完整 SQL。

## 萃取判定（`analyst`，`sql-logic-extraction` mode）

對每個邏輯訊號逐一判定：

1. **意圖分類**：`data-access`（取值/分頁/投影）vs `business-rule`（驗證/資格/計算/狀態/分類）。
2. **規則改寫**：`business-rule` 用 domain 語言改寫成白話規則敘述（遮蔽識別符）。
3. **矛盾登錄**：規則與其他來源矛盾時，寫入 `source-conflicts.md`（`rule-contradiction`）。
4. **回填 glossary**：規則涉及的術語補進 `domain-glossary.md`。
5. **提出處置建議**：對每條 business-rule 建議處置（見決策矩陣），狀態 `pending`，待 Gate-B 使用者裁定。

## 處置決策矩陣（建議值，最終由使用者於 Gate-B 裁定）

| 情境 | 建議處置 | 目標分層 |
| --- | --- | --- |
| 純取值/分頁/投影 | keep-in-sql | repository-thin-sql |
| 驗證/資格判定 | move-to-domain | domain |
| 跨實體計算公式 | move-to-domain | domain |
| use case 編排/流程控制 | move-to-application | application |
| 報表彙總指標且效能敏感 | keep-in-sql（附對等驗證）| repository-thin-sql |
| 規則已過時或需求已變 | redesign / drop | tbd / dropped |

## 切片與 partial-completed

- 邏輯訊號 > 20 條：`analyst` 回 `partial-completed`，附 `completed-items` / `pending-items` / `next-step`。
- `db-introspection-scanner` / `project-scanner` 依各自 scan budget 切片；超量回 `partial-completed`。
- orchestrator 收到 partial 後先委派 `living-doc` checkpoint，再依 next-step 續跑。

## Gate 對齊

- **Gate-A**：`sql-logic-extraction.status in [extracted, dispositions-resolved, not-applicable]`。
- **Gate-B**：`sql-logic-extraction.dispositions-resolved OR not-applicable`；使用者逐條確認處置（keep/move/redesign/drop/defer）。
- **Gate-D**：`design-traceability` 把每條 `move-to-*` 規則映到 module + endpoint；repository SQL 維持 thin。
- **Gate-E**：`move-to-*` / `redesign` 規則以行為對等 example 驗證新實作保留可觀察行為。

## 開發落實守門（`tdd-implementer` / `code-reviewer`（`mode: tdd`））

- 不得把 `business-rule` 型別的 legacy SQL（含 inline SQL 字串）整段複製到新 repository/DAL。
- 每條 `move-to-domain` / `move-to-application` 規則需有 domain/application 層單元測試。
- `keep-in-sql` 規則需有整合層對等驗證證據。
- reviewer 檢查非 `keep-in-sql` 規則不得殘留於 SQL；殘留標 `MAJOR`（`Defect_Type: sql-embedded-business-logic`），跨越 safe-change envelope 或破壞行為對等標 `BLOCKER`。

## 適用性（N/A 準則）

- 來源無資料庫、無 SP/View、且應用碼無 inline SQL → `sql-logic-extraction` 標 `not-applicable` + reason。
- 全部訊號皆判定為 `data-access` → 無 business-rule 需處置，狀態可標 `dispositions-resolved`（無待決項）。

## DLP 交叉檢查

- 邏輯訊號清單與萃取矩陣只存構件型別、行號 ref、遮蔽後規則敘述。
- 不得存原始 SQL 全文、資料表/欄位名稱（除官方業務術語）、機密值。
- 委派前套用 `runbooks/dlp-verification.md` 殘留掃描。
