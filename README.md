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
2. **信任 hooks（必要）**：於專案目錄啟動 `codex`，在「Hooks need review」選擇 **Trust all and continue**。未信任時強制層全數失效且無提示；移動目錄或 `hooks.json` 變更後須重新信任。
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
| ② 分析 | 盤點現況，提出 2–4 個做法 | `sa-analyst` |
| ③ 定案 | 確認 `spec.md`、Gherkin 驗收條件與交付範圍 | 使用者 |
| ④ 實作 | test-first 實作至測試通過 | `implementer` |
| ⑤ 審核 | 獨立審核；未通過返回 ④ | `reviewer` |
| ⑥ 交付 | 回報變更、驗證方式與剩餘風險；先通過 `delivery-check` | orchestrator |

- 驗收條件須於全套測試結果中逐條通過，且結果晚於最後一次修改（`gherkin-check`）。QA 手動測試者標 `@manual`。
- 缺陷先建立重現症狀的失敗測試；純技術變更可省略 ①。
- 審核修正輪有上限；同一檔的必修修過兩輪仍在，交回使用者決定。

## 產出

| 位置 | 內容 |
| --- | --- |
| `bdd-docs/{feature-id}/spec.md` | 需求決議、做法、驗收條件、交付紀錄 |
| `bdd-docs/{feature-id}/review.md`、`reviews/` | 審核結論與各輪紀錄 |
| `bdd-docs/{feature-id}/evidence/`、`contract/` | 經核准的 DB 盤點、對外契約 |
| `bdd-docs/project-map.md` | 系統地圖與領域詞彙 |
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

## VS Code extension（選用）

設定面板、狀態列與 Problems 標示；詳見 [vscode-extension/README.md](vscode-extension/README.md)。

## 升級

```powershell
pwsh <新版目錄>/.codex/scripts/sdlc.ps1 update -Target <專案路徑>   # -Preview 僅列出計畫
```

- 使用者改過的工具檔先備份至 `bdd-docs/.sdlc/backup-{舊版}/`；`guidelines/` 不變動。
- `hooks.json` 變更後須重新信任。變更內容見 `sdlc.ps1 whatsnew` 或 [CHANGELOG.md](CHANGELOG.md)。
- `update.source` 格式：`https://github.com/<owner>/<repo>`、`https://gitlab.com/<group>/<project>`，或 `gitea:<url>`／`gitlab:<url>`／`github:<url>`。私有 repo 的 token 置於 `CODEX_SDLC_TOKEN_<主機>`。

## 疑難排解

| 現象 | 處理 |
| --- | --- |
| 違規內容未被阻擋，或顯示「hooks 沒在跑」 | 信任 hooks；執行 `doctor -CheckHookTrust` |
| `gherkin-check`：找不到 scenario 的測試 | 確認 step 已繫結、結果檔為全套測試；手動測試者標 `@manual` |
| `gherkin-check`：結果檔比改過的檔舊 | 重跑測試 |
| 委派被擋：`review-loop-exceeded`／`review-item-stuck` | 由使用者決定後續 |
| `delivery-check` 未通過 | 依列出的項目補齊「交付」一節或重跑測試 |
| 寫檔被擋：`[Hook][Guideline]` | 依規則修正，或將規則降為 `warn` |
