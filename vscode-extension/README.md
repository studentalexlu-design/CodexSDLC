# Codex SDLC — VS Code extension

Codex SDLC 工作流的 VS Code 介面：設定面板、狀態列、Problems 標示與常用指令。

本 extension 僅為操作介面，狀態與設定以 `sdlc.config.json`、`.codex/scripts/sdlc.ps1` 及各 gate 為準；移除 extension 不影響工作流。

## 介面

| 位置 | 功能 |
| --- | --- |
| 活動列 › **狀態** | 正常時顯示「一切正常」；有待處理事項時逐項列出並附處理按鈕，件數顯示於活動列圖示。有新版時顯示「升級」。 |
| 活動列 › **調校** | 每個 agent 一列，訊號格表示 effort；點選修改 effort，展開修改 model。未套用者標 ●，最上方為「套用 N 項」。預設組合位於標題列「…」。 |
| 活動列 › **進階** | 更新、規範、本機環境（預設收合）。 |
| 未安裝工作流的資料夾 | 「安裝到這個工作區」：優先取用發佈來源的新版，否則使用內附版本；逐檔驗證 sha256。既有 `AGENTS.md` 另存 `.new` 供對照；既有 `guidelines/` 不變動（未修改過的原廠 `README.md` 除外）。 |
| 狀態列 `SDLC` | 版本與待處理事項；點選開啟選單。 |
| Problems | 違反 `guidelines/rules.json` 之處、`rules.json` 本身的錯誤、`bdd-docs/` 的敏感資料殘留（僅類別與行號）。 |
| `sdlc.config.json` 上方 | 「套用」與 tune 建議的「採用」。 |
| 命令面板 | 輸入 `Codex SDLC` 列出全部指令。 |

## 資料來源

| 顯示內容 | 來源 |
| --- | --- |
| 設定值、選項與說明 | `sdlc.config.json`、`.codex/bdd-workflow/sdlc.config.schema.json` |
| 未套用、工具檔缺漏、修正輪上限 | `sdlc.ps1 doctor` |
| hooks 未執行 | `doctor` 比對 hook 心跳與產出的修改時間（不呼叫 Codex）；agent 寫入產出約 150 秒後重新檢查 |
| 可用的 model／effort | 本機 `codex debug models`；找不到 codex 時退回 schema |
| 新版 | `sdlc.ps1 check-update -IfDue`（`update.check = never` 時不連線） |
| tune 建議 | `sdlc.ps1 tune` 儲存的提議 |
| Problems | `guideline-gate.ps1 -Json`、`-Validate -Json`、`dlp-gate.ps1 -Json`（存檔時執行） |

所有修改經由 `sdlc.ps1 set` 寫入：先依 schema 驗證，任一不合法即不寫入。

## 設計原則

1. **不推測流程進度**：流程狀態存在於對話中，無法由檔案可靠推得。
2. **不自行實作 lint／gate**：狀態、違規與合法值一律取自腳本的 `-Json` 與 schema。
3. **不將工作流設定存入 VS Code settings**：settings 僅存本機事項（`pwsh` 路徑、發佈來源、狀態列顯示、存檔掃描）。

網路存取僅發生於腳本端。extension 不向 Codex 查詢 hooks 信任狀態，**綠勾不代表已信任**，請以 `sdlc.ps1 doctor -CheckHookTrust` 確認。

## 需求

- PowerShell 7（`pwsh`）；找不到時可選取路徑（`codexSdlc.pwshPath`）。不支援 Windows PowerShell 5.1。
- 工作流 4.8.0 以上（狀態列與 Problems）、4.9.0 以上（面板修改設定）、4.19.0 以上（偵測 hooks 未執行）。
- 受限模式（未信任的工作區）下不啟動。VS Code 工作區信任與 Codex hooks 信任彼此獨立。

## 安裝與移除

```powershell
code --install-extension codex-sdlc-{版本}.vsix
code --uninstall-extension codex-sdlc.codex-sdlc
```

- vsix 為發佈頁上與 zip 並列的附件，內附同版發佈物，可直接安裝至其他工作區。Cursor、Windsurf、VSCodium 使用同一個 vsix。
- extension 為整台機器共用。`sdlc.ps1 update` 不重新安裝 extension；於面板升級後版本不同時，提供安裝新版的選項。

## 已知限制

- 僅於 Windows ＋ VS Code 實測。
- 對話框等互動流程無自動化測試；其後端的 `fetch`、`install`、`update`、`set` 已以實際腳本測試。
- hooks 未執行須待 agent 寫入產出後方能判斷；手動修改產出檔或切換 git 分支可能誤報。
- `bdd-workflow-version.json` 的 `source` 尚未設定，發佈來源檢查目前不會取得結果。
- 發佈來源的版本較 extension 新時可能顯示「版本不相容」，更新 extension 即可。
