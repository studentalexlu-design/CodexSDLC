# Token Budget Policy

適用於 orchestrator handoff、doer、reviewer 與 living-doc 維護。

## Never Remove For Token Saving

以下規則**只約束該 tier 已啟用的階段**（tier 定義見 `workflow-contract.json` `route-profiles`）。未啟用的階段不受約束 —— 例如 lite 不產出 Gherkin，就沒有 ATDD acceptance path 可走。

- Outside-In：Example Mapping / Gherkin → ATDD walking skeleton → TDD 內圈。（standard / full）
- ATDD 必須走 `.feature` → step definition → driver/helper 的真 BDD acceptance path。（standard / full）
- TDD `completed` 前 full acceptance 必須 `failed == 0` 且 `pending == 0`。（M / H；lite 等效要求為相關單元／focused 測試 `failed == 0` 且 `skipped == 0`）
- reviewer FAIL 上限、Gate 升級不可跳過。（該 tier 有啟用 reviewer / Gate 時）

以下規則**不分 tier，一律適用**：

- safe-change envelope、DB approval、smoke test approval 不可跳過。
- secret safety 與 DLP（來源被標記敏感時）不可跳過。
- 綠燈門檻不可降低 —— 分流只改變衡量對象，不改變「必須全綠才算完成」。

## Discovery Rules（探索既有程式碼）

**LLM 讀索引，不讀原始碼樹。**

機械性探索 —— 定位檔案、列專案相依、比對 SQL 樣式、抓 public 簽章 —— 一律走 `.codex/scripts/`：

| 需求 | 腳本 | 不得改用 |
|---|---|---|
| 專案輪廓、相依、測試工具鏈、entry points | `repo-index.ps1` → `index.json` | 逐檔走訪 solution／`.csproj` |
| 遺留 SQL 訊號 | `sql-scan.ps1` → `sql-signals.json` | LLM 跨碼庫比對樣式 |
| 需求 → 相關檔案 | `impact-scope.ps1` → 排序候選集 | LLM 猜測「相關」檔案 |

LLM 只做**判斷**：SQL 是 data-access 還是 business-rule、風險等級、可重用性。**定位不是判斷。**

- 讀原始碼只在需要判斷時，且只讀候選清單中排名最前的檔案（上限見各 profile 的 `impact-top-n`）。
- 索引是全域產物，跨 run 共用；同一碼庫的第二個 feature 幾乎不付掃描成本。
- 掃描成本必須與**專案大小脫鉤** —— 300 檔和 3000 檔的 `inventory` 都應該只讀 1 個 `index.json`。
- 腳本不可用時退回 bounded LLM 掃描並標 `environment: index-unavailable`，**不得 hard-block**。

程序見 `runbooks/repo-indexing.md`。

## Context Rules

- Handoff 優先傳 run-id、feature-id、stage、mode、artifact path/version/digest、1 個 context pack path、Gate 條件與不超過 500 字摘要。
- 禁止貼完整 `log.md`、完整 `source-materials-register.md`、完整 context pack 集合、長測試輸出或大型 source artifact。
- 先讀 digest / project-profile cache；hash 或 version 不符時才讀完整 artifact。

## Digest Contract

主要 artifact 旁可維護 `{artifact}.digest.json`：

```json
{
  "artifact": "path/to/artifact",
  "version": "vX.Y",
  "hash": "...",
  "summary": "short facts",
  "counts": {},
  "open_questions": 0,
  "upstream_versions": {}
}
```

## Test Output Contract

- 不貼完整 `dotnet test` output。
- 只允許：command、exit code、total/passed/failed/skipped、前 3 個錯誤、trx/log artifact path。

## Slice Rules（依 tier）

- **H**：每次 invocation 只處理一個 mode 與最小 behavior slice。
- **M**：允許合併呼叫 —— `design-modeler` 與 `integration-tester` 使用 `mode: all`，`discovery` 一次處理整張 example map，`tdd-implementer` 一次處理同一 backlog group。
- **L**：單次 invocation 完成整個需求。
- 任何 tier：若該 tier 定義的範圍仍有剩餘，先回 `partial-completed`，由 orchestrator 決定是否續跑。

切得越細 = 冷啟動次數越多 = 總 token 越高。切片是**穩定性**手段，不是省 token 手段；只在 full 的高風險情境才值得付這個代價。

