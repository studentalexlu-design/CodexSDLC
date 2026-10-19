# Codex SDLC — VS Code extension

Codex SDLC 工作流（`.codex/`、`.agents/`、`AGENTS.md`）的 VS Code 介面：設定面板、狀態列、Problems 標示與常用指令。

本 extension 僅為操作介面。所有狀態與設定以 `sdlc.config.json`、`.codex/scripts/sdlc.ps1` 及各 gate 為準；移除 extension 不影響工作流運作。

## 介面

| 位置 | 功能 |
| --- | --- |
| 活動列 › **狀態** | 狀態卡片。正常時顯示「一切正常」；有待處理事項時逐項列出並附處理按鈕，件數同步顯示於活動列圖示。有新版時於卡片下方顯示「升級」。 |
| 活動列 › **調校** | 每個 agent 一列，左側訊號格表示 effort。點選該列修改 effort，展開修改 model。未套用的變更以 ● 標示，最上方列為「套用 N 項」。tune 有建議時提供「採用」；預設組合位於標題列「…」。 |
| 活動列 › **進階** | 更新、規範、本機環境（預設收合）。 |
| 未安裝工作流的資料夾 | 「安裝到這個工作區」：優先取用發佈來源的新版，無法取得時使用內附版本；逐檔驗證 sha256。既有 `AGENTS.md` 不覆蓋（另存 `.new` 並開啟對照），既有 `guidelines/` 不變動。 |
| 狀態列 `SDLC` | 版本與待處理事項；點選開啟選單。 |
| Problems | 違反 `guidelines/rules.json` 的位置、`rules.json` 本身的錯誤、`bdd-docs/` 的敏感資料殘留（僅類別與行號）。 |
| `sdlc.config.json` 上方 | 「套用」與 tune 建議的「採用」。 |
| 命令面板 | 輸入 `Codex SDLC` 列出全部指令。 |

## 資料來源

| 顯示內容 | 來源 |
| --- | --- |
| 設定值、選項與說明 | `sdlc.config.json`、`.codex/bdd-workflow/sdlc.config.schema.json` |
| 未套用、工具檔缺漏、修正輪上限 | `sdlc.ps1 doctor` |
| 可用的 model／effort | `doctor` 的 `models`（取自本機 `codex debug models`；找不到 codex 時退回 schema） |
| 新版 | `sdlc.ps1 check-update -IfDue`（`update.check = never` 時不連線） |
| tune 建議 | `sdlc.ps1 tune` 儲存的提議 |
| Problems | `guideline-gate.ps1 -Json`、`guideline-gate.ps1 -Validate -Json`、`dlp-gate.ps1 -Json`（存檔時執行） |

所有修改皆經由 `sdlc.ps1 set` 寫入：先依 schema 驗證全部值，任一不合法即不寫入。extension 本身不寫設定檔。

## 設計原則

1. **不推測流程進度。** 流程狀態存在於對話中，無法由檔案可靠推得。
2. **不自己實作 lint／gate 邏輯。** 狀態、違規與合法值一律取自腳本的 `-Json` 與 schema，以避免兩份實作分岔。
3. **不把工作流設定存進 VS Code settings。** VS Code settings 僅存放本機事項：`pwsh` 路徑、發佈來源、狀態列顯示與存檔掃描。

網路存取僅發生於腳本端，extension 不開啟任何連線。extension 不檢查 Codex 是否信任 hooks，**狀態列的綠勾不包含此項**；請以 `sdlc.ps1 doctor -CheckHookTrust` 確認。

## 需求

- PowerShell 7（`pwsh`）。找不到時可選取路徑（寫入 `codexSdlc.pwshPath`）；不支援 Windows PowerShell 5.1。
- 工作流 4.8.0 以上（狀態列與 Problems）；4.9.0 以上（於面板修改設定）。
- 不在受限模式（未信任的工作區）下啟動。VS Code 工作區信任與 Codex hooks 信任彼此獨立。

## 安裝與移除

```powershell
code --install-extension codex-sdlc-{版本}.vsix
code --uninstall-extension codex-sdlc.codex-sdlc
```

- vsix 為發佈頁上與 zip 並列的附件，內附同版發佈物，可直接安裝至其他工作區。
- Cursor、Windsurf、VSCodium 使用同一個 vsix。
- extension 為整台機器共用，刪除專案不會移除它。`sdlc.ps1 update` 不會重新安裝 extension；於面板升級後若版本不同，會提供安裝新版 extension 的選項。

## 已知限制

- 僅於 Windows ＋ VS Code 實測。
- 對話框等互動流程無自動化測試；其後端的 `fetch`、`install`、`update`、`set` 已以實際腳本測試。
- `bdd-workflow-version.json` 的 `source` 尚未設定，發佈來源檢查目前不會取得結果。
- 發佈來源的版本較 extension 新時，可能出現「版本不相容」，更新 extension 即可。
