---
name: data-modeling
version: 1.0.0
description: 資料流、實體與儲存設計方法論
---

# Data Modeling Skill

## 使用時機

- domain glossary 已建立，需要設計 entity / aggregate / value object
- 需要規劃資料在系統中的流動路徑
- 需要決定儲存技術與 schema 設計
- 需要定義 repository / data access 介面

## 方法論

### Phase 0：既有 Schema 分析（Consolidation 專用）

當合併多個舊系統時，先執行此階段：

1. 從每個舊系統的 DDL / migration / ER diagram 中，提取 table / column / constraint 清冊。
2. 填寫 [bdd-docs/artifacts/schema-comparison.md](../../../bdd-docs/artifacts/schema-comparison.md)：
   - 表格對照（identical / similar / a-only / b-only）
   - 欄位級差異（型別、nullable、constraint）
   - 主鍵策略比對
   - 資料衝突風險
3. 將 schema 衝突登錄到 active run 的 `source-conflicts.md`（`schema-mismatch` 類型）。
4. 產出合併後新 Schema 草案，作為 Phase 3 的輸入。
5. 識別需要資料遷移的表格，初步填寫 `data-migration-plan.md` 的表格映射。

### Phase 1：從 Domain 到 Entity

1. 從 `domain-glossary` 中識別 noun → 候選 entity。
2. 從 `example-map` 的 rules 識別 business invariant → aggregate boundary。
3. 辨識哪些概念是 value object（無獨立 identity、以值相等）。
4. 確認 aggregate root 與 consistency boundary。5. **識別 Entity 間關聯**：從 glossary 的 verb / preposition（例如「屬於」「包含」「擁有」）識別 entity 間的關聯，確認：
   - **關聯類型**：association / composition / aggregation
   - **基數**：1:1 / 1:N / N:M
   - **導航方向**：單向→ / 雙向↔（優先單向，需要時才雙向）
   - **生命週期綁定**：composition 的 child 是否隨 parent 刪除
6. 將關聯記錄到 data-model 範本的「Entity 關聯」表格。
### Phase 2：資料流設計

1. **先讀取 `flow-description` 的「使用者操作流程」區段**（若存在），以操作步驟為基礎規劃資料流。每個操作步驟的資料輸入/輸出是資料流設計的主要依據。
2. 列出每個 use case 的資料進入點（API endpoint / message / event / UI）。
3. 追蹤每筆資料的轉換鏈：input → validation → mapping → domain logic → persistence → output。
4. 識別跨 bounded context 的資料流，確認傳輸方式（同步 API / 非同步 event / shared kernel）。
5. 辨識 read model 與 write model 是否需要分離（CQRS 候選）。
6. **識別跨 Entity JOIN 需求**：檢查每個資料流的「輸出」欄位，若畫面 / API 回應需要來自多個 Entity 的欄位，必須：
   - 在資料流表格的「輸出」欄明確標註來源 Entity（例：`Order.OrderDate + Customer.Name`）
   - 在 data-model 範本的「查詢模型 / Read Model」表格中登錄對應的 DTO 與 JOIN 路徑
   - 在「畫面欄位 → 資料來源映射」表格中填寫每個欄位的來源
7. **跨層驗證**：檢查所有操作流程步驟是否都有對應的資料流設計。遺漏的操作步驟標記為 gap，需補齊。
8. 在資料流表格中填寫「對應操作流程#」與「對應業務步驟#」欄位。

### Phase 3：儲存設計

#### Step 0：判斷 Table 設計起點

在開始儲存設計前，先確認資料庫狀態：

1. **檢查來源**：讀取 `source-materials-register.md` 和 `db-introspection-report`（若存在）。
2. **判斷路徑**：

| 情境 | 路徑 |
|------|------|
| 來源無資料庫（greenfield / 純文件需求） | → **Greenfield Table Design**（Step 1-G 起） |
| 資料庫存在但缺少本次需求的 table | → **Greenfield Table Design**（Step 1-G 起，但參考既有 DB 慣例） |
| 資料庫存在且 table 已存在 | → **Existing Schema Evolution**（Step 1-E 起） |

#### Greenfield Table Design（Step 1-G ~ 5-G）

適用於「無資料庫」或「資料庫中尚無對應 table」的場景。

##### Step 1-G：需求分析與資料特性評估

在做任何設計決策前，先分析需求的資料特性：

1. 從 Phase 1 的 Entity / Aggregate 設計與 Phase 2 的資料流設計中，彙整以下特性：
   - **資料結構穩定性**：schema 是否固定、是否會頻繁變動
   - **關聯複雜度**：entity 間的關聯數量與深度（JOIN 需求）
   - **查詢模式**：以交易型（OLTP）為主還是分析型（OLAP）為主
   - **一致性需求**：是否需要跨表交易一致性（ACID）
   - **資料量預估**：預期資料筆數與成長趨勢
   - **擴展需求**：是否需要水平擴展
2. 將分析結果填入 data-model 範本的「Greenfield 設計決策」區段。

##### Step 2-G：資料庫類型選擇（關聯 vs 非關聯）

輸出分析結果與建議到終端，請使用者確認資料庫類型：

**關聯式資料庫（Relational / SQL）**
- ✅ 優點：強一致性（ACID）、成熟的 JOIN 能力、標準化 SQL 語法、豐富的約束機制（FK / CHECK / UNIQUE）、適合複雜查詢與報表
- ❌ 缺點：水平擴展較困難、schema 變更需要 migration、對非結構化資料支援較弱

**非關聯式資料庫（Non-Relational / NoSQL）**
- ✅ 優點：水平擴展容易、schema 彈性高、對非結構化/半結構化資料友好、高吞吐寫入
- ❌ 缺點：缺少跨文件交易支援（部分支援）、JOIN 能力弱或不存在、資料一致性通常為最終一致、重複資料管理成本

**選擇建議**：
- entity 間有 3+ 個關聯且需要 JOIN 查詢 → 傾向關聯式
- 單一 aggregate 且少跨表查詢 → 可考慮非關聯式
- 既有 DB 是 SQL Server / PostgreSQL 且團隊熟悉 → 傾向關聯式

使用者確認後，將選擇記錄到 data-model 範本。

##### Step 3-G：正規化層級選擇

僅適用於關聯式資料庫。輸出正規化層級建議到終端：

**第一正規化（1NF）**
- 消除重複群組，每欄位為原子值
- 最低基準，所有設計至少須達到 1NF

**第二正規化（2NF）** ← 一般預設目標
- 在 1NF 基礎上，消除部分依賴（非主鍵欄位完全依賴於主鍵）
- ✅ 優點：減少資料冗餘、更新異常風險低、儲存效率合理
- ❌ 缺點：部分查詢需要 JOIN，但數量可控
- **適用**：大多數 OLTP 業務系統

**第三正規化（3NF）** ← 僅在需要時使用
- 在 2NF 基礎上，消除遞移依賴（非主鍵欄位不依賴於其他非主鍵欄位）
- ✅ 優點：最小化資料冗餘、最大化更新一致性、資料完整性最佳
- ❌ 缺點：JOIN 數量增多、查詢效能可能下降、設計複雜度增加
- **適用**：資料完整性要求極高、頻繁更新的系統（如財務、庫存）

**反正規化（Denormalization）**
- 刻意保留冗餘以提升查詢效能
- ✅ 優點：減少 JOIN、查詢速度快、讀取密集場景表現佳
- ❌ 缺點：資料冗餘增加儲存成本、更新時需同步多處（一致性風險）、維護複雜度高
- **適用**：讀取密集且更新頻率低的報表/檢視場景

**預設規則**：
- 一般業務系統 → **2NF**（平衡冗餘與效能）
- 資料一致性需求高 → **3NF**（可在 orchestrator 呼叫時指定）
- 不得超過 **3NF**

使用者確認後，將選擇記錄到 data-model 範本。

##### Step 4-G：Table Schema 設計

依 Phase 1 的 Entity / Aggregate 與選定的正規化層級，設計 table：

1. 每個 Entity → 一張 table（或依正規化拆分）。
2. 設計 primary key（偏好 surrogate key，除非有明確業務理由使用 natural key）。
3. 依正規化層級拆分欄位：
   - **2NF**：確保非主鍵欄位完全依賴於整個主鍵。若有複合主鍵，檢查部分依賴並拆出獨立表。
   - **3NF**：額外檢查遞移依賴，將間接依賴欄位拆出獨立表。
4. 設計 FK 約束（依 Phase 1 Entity 關聯）。
5. 設計 index（依 Phase 2 的查詢模式）。
6. 設計 constraint（NOT NULL / CHECK / UNIQUE / DEFAULT）。
7. N:M 關聯設計 junction table。
8. 將設計填入 data-model 範本的「表格 / Collection 設計」和「外鍵設計」表格。

##### Step 5-G：設計驗證

1. 檢查每個 Phase 2 資料流的存取需求是否都有對應 table 與欄位。
2. 檢查每個查詢模型的 JOIN 路徑是否可行。
3. 遺漏的欄位或 table 標記為 **gap**。
4. 填入「畫面欄位 → 資料來源映射」追溯表。

#### Existing Schema Evolution（Step 1-E）

適用於「資料庫已有對應 table」的場景，沿用既有邏輯：

1. 依 aggregate 決定儲存邊界（一個 aggregate = 一個 transaction boundary）。
2. 選擇儲存技術，考量：查詢模式、consistency 需求、scale 需求。
3. 設計 table / collection schema，包含 primary key、index、constraint。
4. 規劃 migration 策略：是否為 additive-only、是否需要 data migration。
5. 若有 breaking schema change，標記需要 safe-change envelope。
6. **外鍵與關係設計**：依 Phase 1 識別的 Entity 關聯，設計對應的 FK 約束：
   - 為每個 1:N 關聯定義 FK 欄位與約束（On Delete / On Update 政策）
   - 為每個 N:M 關聯設計中間表（junction table），定義其複合主鍵與兩個 FK
   - 決定導航屬性載入策略：
     - `eager`：畫面必定需要關聯資料時（使用 `.Include()`）
     - `explicit`：只在特定查詢載入（使用 `.Entry().Collection().LoadAsync()`）
     - `lazy`：避免使用（N+1 查詢風險），若必須使用需標記風險
   - **Aggregate 內部**（composition）：通常 `Cascade` 刪除
   - **跨 Aggregate**（association）：通常 `Restrict` 或 `SetNull`
   - 將 FK 設計記錄到 data-model 範本的「外鍵設計」表格
7. **查詢模型設計**：對於 Phase 2 識別的跨 Entity JOIN 需求，設計對應的查詢模型（DTO / Projection）：
   - 明確列出查詢模型的欄位來源（哪個 Table.Column）
   - 明確 JOIN 路徑（A JOIN B ON A.FK = B.PK）
   - 記錄到 data-model 範本的「查詢模型 / Read Model」表格

### Phase 4：Data Access 介面

1. 為每個 aggregate root 定義 repository 介面。
2. 遵循 interface segregation：只暴露本 use case 需要的操作。
3. 使用 `CancellationToken` 作為非同步方法的最後一個參數。
4. 不在 repository 中混入 domain logic。
5. **跨 Entity 查詢方法**：對於 Phase 3 設計的查詢模型，定義對應的 repository / query service 方法：
   - 帶 Include 的查詢（載入導航屬性）：`GetByIdWithDetailsAsync(id, ct)`
   - 投影查詢（回傳 DTO，避免載入整個 Entity 圖）：`QueryForListViewAsync(filter, ct)`
   - JOIN 過濾查詢（依關聯 Entity 欄位過濾）：`QueryByRelatedEntityAsync(relatedId, ct)`
   - 優先使用投影查詢，在 repository 內完成 JOIN，不對外暴露 `IQueryable`
6. **操作→Repository 驗證**：檢查所有操作流程步驟的資料需求是否都有對應的 Repository 方法。遺漏的操作標記為 gap。
7. 填寫追溯矩陣的「操作流程 → Repository 方法」表格。

### Phase 5：追溯驗證與版本確認

1. **反向檢查 Entity 引用**：每個 Entity 是否被至少一個 story / rule 引用。未被引用的 Entity 為孤立 Entity，標記為 warning。
2. **反向檢查 Repository 方法**：每個 Repository 方法是否有對應的操作流程步驟。無對應操作的方法為冗餘方法，標記為 warning。
3. **填寫追溯矩陣**：確認「Business Rules → 實現方式」與「操作流程 → Repository 方法」兩個表格已完整填寫。
4. **記錄版本依賴**：在 data-model 的概要中填寫 `flow-description-version` 和 `example-map-version`，記錄本次設計所依據的上游產物版本。
5. **版本一致性檢查**：若 `flow-description` 或 `example-map` 的當前版本與 data-model 記錄的版本不一致（上游已更新），標記整個 data-model 為 `stale` 並通報 orchestrator。

## 輸出產物

- `bdd-docs/artifacts/data-models/{feature-name}.md`（使用 [template](../../../bdd-docs/artifacts/data-models/template.md)）
- 更新 `domain-glossary`（補充 entity / value object 定義）
- 更新 active run 的 `implementation-backlog`（加入 data layer slice）

## 注意事項

- 不得跳過 Phase 1 直接設計 schema。
- entity 命名必須與 `domain-glossary` 一致。
- 若來源之間有 schema 衝突，必須記錄到 active run 的 `source-conflicts.md`。
- 資料流設計必須涵蓋所有 `example-map` 中的 scenario。
- migration 若涉及 breaking change，必須標記 risk 並通知 orchestrator。

## 與其他技能的關係

- 依賴 `impact-analysis`：了解變更影響面。
- 依賴 `safe-change`：處理 schema breaking change。
- 供應 `outside-in-tdd`：提供 repository 介面作為 TDD 外層。
- 供應 `unit-test-gen`：提供 entity invariant 作為測試目標。

