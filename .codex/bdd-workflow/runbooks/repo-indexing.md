# Runbook: Repo Indexing（確定性索引）

> 供 `project-scanner`、`domain-analyst`、`db-introspection-scanner` 於掃描既有／遺留專案時使用。
> 只在需要建立或刷新索引、或判定 staleness 時讀本檔。

## 核心原則

**LLM 讀索引，不讀原始碼樹。**

機械性探索 —— 定位檔案、列專案相依、比對 SQL 樣式、抓 public 簽章 —— 一律由腳本完成，零 token。
LLM 只做**判斷**：SQL 是 data-access 還是 business-rule、風險等級、可重用性。定位不是判斷。

在 300 檔的 solution 上，索引約 5-15KB（~2-5k tokens），取代讀 100+ 個檔案。

## 三支腳本

| 腳本 | 用途 | 輸出 |
|---|---|---|
| `.codex/scripts/repo-index.ps1` | 建立／刷新結構索引 | `bdd-docs/artifacts/repo-index/index.json` + `index-digest.json` |
| `.codex/scripts/sql-scan.ps1` | 遺留 SQL 訊號偵測 | `bdd-docs/artifacts/repo-index/sql-signals.json` |
| `.codex/scripts/impact-scope.ps1` | 需求 → 排序候選檔案集 | stdout JSON（不落檔） |

索引是**全域**產物（`bdd-docs/artifacts/`，非 run-scoped），跨 run 共用。同一碼庫的第二個 feature 幾乎不用付掃描成本。

## index.json 結構

```
meta          : generated-at, git-sha|null, invalidation-mode, file-count,
                project-count, refreshed-scopes[], changed-files[], symbol-truncated
solutions[]   : .sln 相對路徑
projects[]    : name, path, target-framework, project-refs[], package-refs[]
test-toolchain: { test, bdd, mock, assertion, bdd-fallback? }
entrypoints[] : Program.cs / Startup.cs / *Controller.cs / *Endpoints.cs
config-keys[] : "path#Section:Key"（**只有 key path，永不含 value**）
symbols[]     : { file, types[], methods[] } —— public 簽章，**無 body**
hashes        : structure-hash, config-hash, symbol-hash
```

`test-toolchain` 取代原本寫在 `project-scanner` 的偵測程序：掃 `.csproj` 的 `PackageReference` 辨識
xUnit/NUnit/MSTest、Reqnroll/SpecFlow、NSubstitute/Moq、AwesomeAssertions/FluentAssertions/Shouldly。
未偵測到 BDD 框架時填 `bdd-fallback: Reqnroll.xUnit`。

## 失效判定

- **git 專案**：`git diff --name-only <上次 SHA>..HEAD` 取得精確變更清單，寫入 `meta.changed-files`。
- **非 git**：檔案 hash 比對（路徑 + 大小 + mtime）。
- **分域失效**：`structure`／`config`／`symbols` 三個 scope 各自獨立。動一個 `.cs` 只讓 `symbols` stale，
  不會連帶重掃 `.sln`／`.csproj`。

```powershell
# 只問狀態、不寫檔
pwsh -NoProfile -File .codex/scripts/repo-index.ps1 -StatusOnly
# → { index_exists, stale_scopes[], invalidation_mode, git_sha, changed_files[], needs_refresh }

# 刷新（只重掃 stale scope）
pwsh -NoProfile -File .codex/scripts/repo-index.ps1

# 完整重建
pwsh -NoProfile -File .codex/scripts/repo-index.ps1 -Force
```

索引為最新時回 `status: current` 且不做任何工作。

## 使用程序

### inventory（取得專案輪廓）

1. `-StatusOnly` 判定；`needs_refresh` 為 true 才刷新。
2. **讀 `index.json`，不走訪 solution。**
3. 需要的欄位直接取用：`projects`、`test-toolchain`、`entrypoints`、`config-keys`。

### impact（決定 safe-change envelope）

1. 從需求抽關鍵字／符號名。
2. `impact-scope.ps1 -Keywords '<逗號分隔>' -TopN 12`。
3. **只讀回傳的候選清單**。清單外的檔案不得讀取，除非追蹤呼叫鏈確有必要，且必須在回傳中說明理由。

```powershell
pwsh -NoProfile -File .codex/scripts/impact-scope.ps1 -Keywords 'Order,Discount' -TopN 12
```

評分：symbol 命中（×3）> 檔名命中（×2）> 內容命中（×1，上限 5），
再加 ProjectReference 鄰近度（+1）。索引不存在時自動退化為直接搜尋並於 `index-note` 標明。

### 遺留 SQL 萃取

```powershell
pwsh -NoProfile -File .codex/scripts/sql-scan.ps1
```

stdout 只回摘要（`signal_count`、`by_construct`、`db-object-source`、`next_step`）；
訊號全文落在 `sql-signals.json`，供 `domain-analyst` 按需讀取。**不要把訊號清單貼進 handoff。**

樣式優先序為**最具體優先** —— `embedded-sp-call` → `orm-raw-query` → `dynamic-sql` → `dapper-ado` →
`string-concat-sql`。一行只記一個訊號；順序若被打亂，通用樣式會吃掉更有資訊量的型別。

### DB 來源三路徑

`db-object-source` 欄位決定後續：

| 值 | 意義 | 下一步 |
|---|---|---|
| `ddl-files-found` | repo 內有 `.sql`／DDL 檔 | 已直接掃完，零額外成本 |
| `none-found` | 找不到 DDL 檔 | orchestrator 走既有的「schema 來源策略確認」問使用者 |
| （使用者選 DB MCP） | 定義只在資料庫裡 | `db-introspection-scanner` 取回後**先落地**成 `bdd-docs/artifacts/legacy-schema/*.sql`（DLP 遮蔽），再跑 `sql-scan.ps1` |

落地再掃是關鍵：避免反覆連線，也避免把定義全文重複讀進 context。

## DLP

三支腳本的輸出都經過遮蔽，且必須維持：

- `sql-scan` 的 `context` 只留 1 行，字串常值 → `'***'`、3 位以上數字 → `N`，截斷至 120 字。
- **絕不輸出完整 SQL**、appsettings value、連線字串或任何 secret。
- `config-keys` 只有 key path。

索引與訊號檔寫入 `bdd-docs/` 時，既有的 PostToolUse `dlp-gate.ps1` 會再掃一次。

## 退化路徑（必要）

`policies/cli-execution-policy.md` 已載明 `shell` 可能完全不可用。

腳本無法執行時：**退回既有的 bounded LLM 掃描**（單次 ≤12 檔、≤8 次搜尋），
並在 evidence 標記 `environment: index-unavailable`。

**不得因為索引不可用就 hard-block 整個流程。**
