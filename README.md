# CodexSDLC

供 **Codex CLI** 使用的 SDLC 工作流：需求 → 分析 → 定案 → test-first 實作 → 獨立審核 → 交付。本 repo 僅含工作流的設定與腳本。

## 需求

| 項目 | 用途 |
| --- | --- |
| Codex（CLI 或 VS Code 擴充，已驗證 0.154） | 載入 hooks 與 agent 定義 |
| PowerShell 7（`pwsh`） | 強制層腳本；缺少時 hook 不執行且無提示 |
| git（位於 Codex 的 PATH） | 比對既有 scenario、判斷系統地圖是否過期 |
| 唯讀 DB MCP server | 僅查詢 live DB 時 |

## 安裝

1. 將 `codex-sdlc-{版本}.zip` 解壓至專案以外的目錄，執行：

   ```powershell
   pwsh <解壓目錄>/.codex/scripts/sdlc.ps1 install -Target <專案路徑>
   ```

   - 既有 `AGENTS.md` 不覆蓋，新版另存為 `AGENTS.md.new`；合併後須在 28 KiB 以內。
   - 手動複製安裝者，改用 `install -Adopt`。
   - 前後端為兩個 repo 時，可裝於共同上層目錄（`workspace/backend`、`workspace/frontend`），**`codex` 須於該層啟動**。
2. **信任 hooks（必要）**：執行 `pwsh .codex/scripts/sdlc.ps1 trust-hooks`（或安裝時加 `-TrustHooks`；VS Code extension 安裝與升級時會一併處理）。未信任時強制層全數失效且無提示；移動目錄或 `hooks.json` 變更後須重新信任。
   - 由 Codex 自己把信任寫入 `~/.codex/config.toml`，與在終端機的 `codex` 選 **Trust all and continue** 相同。只信任本工作流的 hooks，其他 hook 不處理。
   - VS Code 的 Codex chat 不會顯示「Hooks need review」，只用 chat 時須以此方式信任。
   - `PATH` 上沒有 `codex` 時，改用 OpenAI VS Code 擴充內附的 `codex`；仍找不到時加 `-CodexPath <codex 完整路徑>`。
   - 組織政策僅允許管理員部署的 hooks（`allow_managed_hooks_only`）時不會出現此畫面：請管理員部署 `sdlc.ps1 managed-hooks -OutDir <資料夾>` 產生的腳本與 `requirements.toml` 片段。管理員不部署時，見「[組織政策不允許專案 hooks](#組織政策不允許專案-hooks)」。
3. **檢查**：`pwsh .codex/scripts/sdlc.ps1 doctor`；確認 hooks 信任狀態加 `-CheckHookTrust`。
4. **使用**：於專案中啟動 Codex，直接描述需求。每個需求請開新對話。

```
<專案>/
├── .codex/ .agents/ AGENTS.md   工具檔，升級時覆蓋
├── guidelines/                  團隊規範（選用，升級不覆蓋）
├── sdlc.config.json             agent 設定
└── bdd-docs/                    流程產出
```

## 流程

| 步驟 | 內容 | 執行者 |
| --- | --- | --- |
| ① 需求 | 找出須由使用者決定的缺口 | orchestrator |
| ② 分析 | 盤點現況，提出 2–4 個做法；會動資料表的做法附資料表設計（`data-model.md`） | `sa-analyst` |
| ③ 定案 | 確認 `spec.md`：做法、Gherkin 驗收條件、改動範圍、資料表設計與交付範圍 | 使用者 |
| ④ 實作 | test-first 實作至測試通過 | `implementer` |
| ⑤ 審核 | 獨立審核；未通過返回 ④ | `reviewer` |
| ⑥ 交付 | 回報變更、驗證方式與剩餘風險；先通過 `delivery-check` | orchestrator |

- 驗收條件須於全套測試結果中逐條通過，且結果晚於最後一次修改（`gherkin-check`）。QA 手動測試者標 `@manual`。
- 修改既有功能時，③ 列出改動範圍（既有行為改前→改後、會改的既有檔與表、連帶影響、要改的既有測試）供確認；實作超出範圍須先回報取得同意。
- 缺陷先建立重現症狀的失敗測試並找出原因，修法與改動範圍經確認後才修改程式；純技術變更可省略 ①。
- 審核修正輪有上限；同一檔的必修修過兩輪仍在，交回使用者決定。
- 修法有幾種、使用者看到的結果不同時，審核標成 `[需決定]`，由使用者選定修法才進修正輪。
- 改動之前就有的問題不算這次的發現，記進 `bdd-docs/known-issues.md`，之後的需求分析時會看到。

## 前後端分離

工作流不規定前後端的先後順序。請於需求開頭指明：同一行為先完成後端 API，再實作畫面；前端替身依已完成的後端 DTO 或 API 文件。

> 後端在 `backend/`、前端在 `frontend/`。分片時同一個行為先做後端 API、再做畫面；前端替身照後端已完成的 DTO（或 OpenAPI）。交付範圍含整合驗證：在本機起後端跑瀏覽器測試。

- 未指明時，前端可能先行，替身僅能依 `spec.md` 的文字描述，接上後端時才發現不符。
- API 另有外部消費者（行動 App、第三方），或前後端由不同人員分頭開發時，才先以 `sa-analyst` 的 `contract` 模式產出 API 規格。
- 僅以替身驗證不代表前後端可正確串接；③ 選擇交付範圍時應包含整合驗證。

### UI 驗收方式

驗收層是 UI 時，`spec.md` 在驗收層底下多寫一行「驗收方式」，③ 一起確認：

```
驗收層：UI（瀏覽器）
驗收方式：playwright｜chromium, mobile-safari｜1280x800、iPhone 13｜後端：替身（依 openapi.yaml）
```

- 四欄依序是工具、瀏覽器／project、尺寸或輸入方式、後端（真實或替身）。不適用寫 `—`。
- `gherkin-check`／`delivery-check` 核對：沒寫或少欄不放行；瀏覽器層不能寫元件測試工具；Playwright 的每條 scenario 要在宣告的每個 project 通過（看 JUnit 的 testsuite hostname）；Vitest 的結果要出自 Vitest 的 JUnit。
- 尺寸、後端兩欄與其他工具結果檔看不出來，由 reviewer 對測試碼。

## 產出

| 位置 | 內容 |
| --- | --- |
| `bdd-docs/{feature-id}/spec.md` | 需求決議、做法、改動範圍、驗收條件、交付紀錄 |
| `bdd-docs/{feature-id}/data-model.md` | 資料表設計（新增與修改的表、欄位、型別、鍵、索引、既有資料處理）；③ 確認、④ 依此建立 |
| `bdd-docs/{feature-id}/review.md`、`reviews/` | 審核結論與各輪紀錄 |
| `bdd-docs/{feature-id}/evidence/`、`contract/` | 經核准的 DB 盤點、對外契約 |
| `bdd-docs/project-map.md` | 系統地圖與領域詞彙 |
| `bdd-docs/known-issues.md` | 審核與實作時發現、不在當時範圍的既有問題 |
| `bdd-docs/.sdlc/` | 升級基準線與備份（勿刪） |
| `bdd-docs/.cache/` | 索引快取（可刪） |

`.feature` 置於既有測試旁（C#：Reqnroll；Java：Cucumber；Node：沿用既有 runner），首行 `# feature-id:` 須保留。修改既有 step 措辭屬破壞性變更。

## 設定

`sdlc.config.json`：

| 鍵 | 預設 | 說明 |
| --- | --- | --- |
| `agents.<名稱>.model`／`.effort` | `inherit` | 可用值見 `sdlc.ps1 models` |
| `review.maxRounds` | `3` | 審核修正輪上限（1–5） |
| `update.check`／`update.source` | `daily`／安裝時帶入 | 更新檢查與來源 |

```powershell
pwsh .codex/scripts/sdlc.ps1 set agents.reviewer.effort=high -Apply
pwsh .codex/scripts/sdlc.ps1 set -Preset balanced   # fast／balanced／deep
```

`agents.*` 須經 `-Apply` 生效。

## 團隊規範

`guidelines/` 的 `*.md` 為需判斷的規範（違反 MUST 判為必修），`rules.json` 為寫檔時機械檢查的規則。寫法見 `.codex/bdd-workflow/guidelines-guide.md`。

## 組織政策不允許專案 hooks

`allow_managed_hooks_only = true` 且管理員不部署 `managed-hooks` 時，Codex 不會執行任何一條 hook。此政策只約束 Codex，不約束 git：

```powershell
pwsh .codex/scripts/sdlc.ps1 git-hooks
```

- **commit 前檢查**：工作區每個 repo 安裝 `pre-commit`（位於 `.git/hooks`，每份 clone 各自一份、不進版控），執行 `.codex/scripts/commit-check.ps1`：staged 的 `bdd-docs/` 檔做殘留掃描，其餘檔套用 `rules.json` 的 block 規則，含 production 程式碼時 build。
- **委派前檢查**：寫入 `bdd-docs/.cache/no-codex-hooks`；orchestrator 見到此檔即於每次委派前自行執行 `handoff-lint -SelfCheck`。此項依賴模型遵守，不是機械強制。
- **CI**：`git commit --no-verify` 可略過本機檢查。需強制時於 pipeline 執行（clone 須含完整歷史）：

  ```powershell
  pwsh -NoProfile -File .codex/scripts/commit-check.ps1 -Base origin/main
  ```

  工作流裝於上層、前後端各一個 repo 時，單一 repo 的 pipeline 內沒有 `.codex/`，無法以此方式執行。

限制：
- 問題在 commit 前才被發現，不是寫檔當下，修正成本較高。
- 檢查的是工作區內容；stage 後又修改的檔會列出提醒。
- 審核紀錄的「上一輪必修交代」檢查與審核快照仍需 Codex hooks。
- repo 已有自己的 `pre-commit` 或設定了 `core.hooksPath` 時不覆蓋，改為列出需自行加入的一行。
- 移除：`git-hooks -Remove`。管理員日後部署 managed hooks 時應移除，否則委派前會重複檢查。

## 驗證 hooks（lab）

測試只驗得到腳本的邏輯。Codex 有沒有叫 hook、這一版送來的 payload 長怎樣、擋下的理由有沒有交到模型手上，要在真的 Codex 上看：

```powershell
pwsh .codex/scripts/sdlc.ps1 lab -Target <新資料夾>          # 建沙盒，印出要貼給 Codex 的 prompt
pwsh .codex/scripts/sdlc.ps1 lab -Report -Target <該資料夾>  # 做完之後對帳
```

- 沙盒只放假資料。依指示信任 hooks（或照管理員的做法部署 `managed-hooks`），在沙盒開 Codex 新對話，貼上 `lab-prompt.md`。
- `-Report` 逐步列出通過、未通過、待確認（看不出理由有沒有送到，到 Codex 畫面確認）、沒跑到。原始紀錄在 `bdd-docs/.cache/lab/calls/`，可用來更新測試的 fixture。
- 組織政策只允許管理員部署的 hooks 時，lab 不能在受管理的電腦上另開環境來跑：請使用不受公司管理的 lab 機（自行設定 `allow_managed_hooks_only` 並部署 `managed-hooks`，即可重現公司設定），或請管理員只在 lab 機部署。
- 驗完：`lab -Remove` 停止記錄，沙盒可整個刪除。

## VS Code extension（選用）

設定面板、狀態列與 Problems 標示；詳見 [vscode-extension/README.md](vscode-extension/README.md)。

## 升級

```powershell
pwsh <新版目錄>/.codex/scripts/sdlc.ps1 update -Target <專案路徑>   # -Preview 僅列出計畫
```

- 使用者改過的工具檔先備份至 `bdd-docs/.sdlc/backup-{舊版}/`；`guidelines/` 不變動。
- `hooks.json` 變更後須重新信任：`update` 加 `-TrustHooks`，或事後執行 `trust-hooks`。變更內容見 `sdlc.ps1 whatsnew` 或 [CHANGELOG.md](CHANGELOG.md)。
- `update.source` 格式：`https://github.com/<owner>/<repo>`、`https://gitlab.com/<group>/<project>`，或 `gitea:<url>`／`gitlab:<url>`／`github:<url>`。私有 repo 的 token 置於 `CODEX_SDLC_TOKEN_<主機>`。

## 疑難排解

| 現象 | 處理 |
| --- | --- |
| 違規內容未被阻擋，或顯示「hooks 沒在跑」 | 執行 `trust-hooks`（extension：「在 Codex 信任 hooks」）；以 `doctor -CheckHookTrust` 確認。已開啟的 Codex 對話須開新對話 |
| `trust-hooks` 回報 `project-untrusted` | Codex 認定的專案根不是此目錄（例如位於另一個 git repo 內）；於該目錄以終端機啟動 `codex` 依提示信任 |
| 未出現「Hooks need review」、`doctor` 回報 `allow_managed_hooks_only` | 組織政策所致；由管理員部署 `managed-hooks` 的產出，或執行 `git-hooks`（見「組織政策不允許專案 hooks」） |
| commit 被擋：`[commit-check]` | 依列出的項目修正後重新 `git add` |
| `gherkin-check`：找不到 scenario 的測試 | 確認 step 已繫結、結果檔為全套測試；手動測試者標 `@manual` |
| `gherkin-check`：結果檔比改過的檔舊 | 重跑測試 |
| 委派被擋：`review-loop-exceeded`／`review-item-stuck` | 由使用者決定後續 |
| 委派被擋：`review-decision-pending` | 審核有 `[需決定]`：選定修法後，handoff 每項加 `decision: {檔} —— {選擇}` |
| `delivery-check`：`known-issue-missing` | 把列出的既有問題追加進 `bdd-docs/known-issues.md` |
| `delivery-check` 未通過 | 依列出的項目補齊「交付」一節或重跑測試 |
| 寫檔被擋：`[Hook][Guideline]` | 依規則修正，或將規則降為 `warn` |
