---
name: db-introspection
version: 1.0.0
description: 已取得使用者批准後，親自透過 DB MCP 做唯讀盤點（metadata／definition／受控 SELECT），並把結果落檔
---

# Live DB 盤點

**進這個 skill 之前，使用者必須已經明確批准這次查詢。** 沒批准就不要載入這份規則來說服自己可以查 —— 批准是先決條件，不是這裡面的一個步驟。

這份 skill 由 orchestrator 自己執行。**沒有子代理隔在中間，所以下面每一條都得你自己守。**

## 你是拿著 production 憑證的那個 context

從前這件事由獨立的 agent 做，它爆掉、被污染、塞滿資料都只影響它自己。現在不是了 —— 你手上同時有：使用者的完整對話、① 的需求決議、以及 live DB 的讀取權。

由此推出三條**不能省**的紀律，它們取代的是原本由 spawn 邊界免費提供的保護：

1. **查完立刻落檔，不要讓 result set 留在對話裡。** 每次查詢的完整結果直接寫進 `bdd-docs/{feature-id}/evidence/db-{scope}.md`，回到對話只留 path ＋ 三五行摘要。原本 1200 字元的 handoff 上限會強迫你這樣做，現在沒有東西強迫你了。
2. **一次只查一個物件、一句一送。** 不要「先全撈下來再看」—— 那正是把整個 schema 倒進你 context 的作法，而你的 context 是唯一必須活到 ⑥ 的。
3. **落檔前先遮蔽**（規則見 `runbooks/dlp-masking.md`）。`dlp-gate.ps1` 在 `PostToolUse` 還會掃一次寫出去的檔 —— **那道 hook 仍然有效，是這條路徑上唯一沒有變成榮譽制的檢查。** 但它只看檔案，看不到你貼在對話裡的東西。

另遵循 `policies/db-mcp-introspection-policy.md`。

## 只能用 DB MCP

只能用目前 session 中已核准的 DB MCP tool。**不得**透過 shell、`sqlcmd`、臨時 driver script、應用程式的 connection string 或 IDE extension 連 DB。

目前沒有可用的 DB MCP tool → 停下來告訴使用者，並建議改走：他提供 schema／DDL／截圖，或由程式碼與文件推斷。

- 優先用 MCP 的 structured metadata／list／describe tool；只有 metadata 查詢或已批准的受控 SELECT 才可用 raw query tool。
- **一次只送一句。** 不要把多個 `SELECT`／metadata 查詢併成多語句 batch —— 多數 MCP adapter 只回最後一句的 result set，或整批不回，症狀跟「查無資料」一模一樣。要查 5 個物件就呼叫 5 次。
- 允許：list databases／schemas／tables／views／functions／procedures、describe columns、讀 FK／index／dependency metadata、讀已批准的 definition、執行已批准的唯讀 SELECT。
- 無法證明某個工具是唯讀 → 不要用它。
- **不得擴大** database／schema／table／column／scope。需要更多 → **停下來重新取得使用者批准**，不要因為「反正已經連上了」就多查兩個物件。這條在沒有子代理邊界之後特別容易鬆掉，因為擴大範圍不再需要重新委派、不再有任何摩擦。
- **adapter 沒回 result set ≠ 零筆。** 只拿到 `Rows affected: -1`／空回應／無欄位標頭時，如實記錄「result set 不可用」，**不得**解讀成查無資料，也**不得**據此推論這個工具不支援回傳 rows。單次失敗不構成能力性結論 —— 同一工具稍早成功回過 rows 就已推翻它。要區分的事實是：這次與上次的參數差異、是否可能真的無資料、錯誤是否被 adapter 吞掉。

## 三種 scope

每次查詢前先確定自己在哪一種，**批准也是按 scope 給的**：

| scope | 要先確定的事 |
|---|---|
| `metadata` | 批准摘要 ＋ connection profile alias（**不得含 secret**）＋ 明確的目標物件。**不需要**欄位清單或 row limit |
| `definition` | 同上；只讀 View／SP／Function 的 definition |
| `approved-select` | 另需 table／view、**明確的欄位清單**、目的、row limit（未給則套 `50`） |

`approved-select` 缺任一項就不要查 —— 回頭把缺的那項問清楚。

## 掃描要求

- 列出 schemas、tables、views、functions、procedures 與必要 columns。
- 記錄 Foreign Key：本表、本欄、參考表、參考欄、On Delete／On Update。
- 建立表格依賴順序，標記 circular reference。
- 需要 definition 時，只讀 View／SP／Function 的 definition。
- 受控 `SELECT` 必須限定物件、明確欄位、筆數與目的。**禁止 `SELECT *`**、禁止未列欄位、禁止超過 row limit、禁止未授權的 join。

## 產出：查到的東西一律落地

**判準是「重新取得要花多少」，不是「這算不算狀態」。** 你手上每一樣東西都經過使用者批准、都跟 live 系統往返過 —— 沒落地就等於每次中斷都要再買一次批准、一次連線、一次等待。**那是整條流程裡最貴的東西。**

所以：**盤點結果一律寫進 `bdd-docs/{feature-id}/evidence/db-{scope}.md`**（`scope` 就是這次的 `metadata`／`definition`／`approved-select`）。

- 檔案裡放**完整的**（已遮蔽的）盤點：物件清單、欄位、FK 清冊、依賴順序、筆數。
- 同一個 scope 再次查詢 → **附加**一節（標題寫這次查了哪些物件），**不要覆蓋**既有內容。
- **寫入前先做 DLP 遮蔽。** 不得含 credentials、連線字串或未遮蔽的 row-level 資料。
- `approved-select` 只寫**已遮蔽的**欄位值樣本與筆數，不寫完整 result set。

落檔之後，把 **path** 補進給 `sa-analyst` 的 handoff 重新委派 —— metadata 塞不進 1200 字元的 handoff，也不需要塞，它自己會讀。落檔之後任何重跑都不必再連 DB。

### 舊系統 SQL 逆推：另外多一步

需要從 View／SP／Function 逆推舊系統邏輯時：

1. 定義**一物件一檔**落成 `bdd-docs/artifacts/legacy-schema/{object-name}.sql`（同樣先遮蔽）。
2. 落地後跑 `pwsh -NoProfile -File .codex/scripts/sql-scan.ps1 -Root bdd-docs/artifacts/legacy-schema`。
3. 對話裡只留腳本摘要（`signal_count`、`by_construct`、輸出檔 path）。

- **不要把完整 definition 或原始 SQL 貼進對話。** 也不要自己判定哪些是資料存取、哪些是業務規則 —— 那是 `sa-analyst` 的事，它讀檔就好。
- `sql-scan.ps1` 不可用時，退回：列出構件型別 ＋ 物件名／行號 ref（已遮蔽），並標記 `environment: index-unavailable`。

## 逾時與中斷

連線失敗、逾時、或做到一半被打斷 → **先把已經拿到的部分落檔**，再決定下一個最小的查詢。

**已落檔的東西不算沒做完。** 落了檔，下一次就從檔案接續，不必重談批准。

## 禁止事項

- 不得執行 DDL、DML、schema sync、資料編修或任何未批准的查詢。
- 不得執行缺少明確批准的 `approved-select`。
- 不得把 secrets 寫進 `bdd-docs/`、對話或 prompt。
- 不得把完整 row-level result set、raw DLP mapping table 或大型 query output 留在對話裡。
- **不得因為成本或急迫理由放寬上面任何一條。** 這些原本是工具層的邊界，現在只剩這份文字 —— 少一次自律就少一層。
