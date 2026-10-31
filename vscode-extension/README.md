# Codex SDLC — VS Code extension

Codex SDLC 工作流的操作介面：設定面板、狀態列、Problems 標示與常用指令。狀態與設定以 `sdlc.config.json` 與 `sdlc.ps1` 為準；移除 extension 不影響工作流。

## 介面

| 位置 | 功能 |
| --- | --- |
| 活動列 › **狀態** | 待處理事項與處理按鈕；有新版時顯示「升級」 |
| 活動列 › **調校** | 各 agent 的 model 與 effort |
| 活動列 › **進階** | 更新、規範、本機環境 |
| 未安裝的資料夾 | 「安裝到這個工作區」（逐檔驗證 sha256） |
| 狀態列 `SDLC` | 版本與待處理事項 |
| Problems | `guidelines/rules.json` 違規、`bdd-docs/` 敏感資料殘留 |
| 命令面板 | `Codex SDLC` |

設定一律經由 `sdlc.ps1 set` 寫入，依 schema 驗證後才寫。

## 設計原則

1. **不推測流程進度**：流程狀態存在於對話中。
2. **不自行實作 lint／gate**：一律取自腳本的 `-Json` 與 schema。
3. **不將工作流設定存入 VS Code settings**：settings 僅存本機事項。

extension 不查詢 Codex 的 hooks 信任狀態，**綠勾不代表已信任**；請以 `sdlc.ps1 doctor -CheckHookTrust` 確認。

## 需求

- PowerShell 7（`pwsh`），可於 `codexSdlc.pwshPath` 指定路徑。
- 工作流 4.19.0 以上。
- 受限模式下不啟動。

## 安裝與移除

```powershell
code --install-extension codex-sdlc-{版本}.vsix
code --uninstall-extension codex-sdlc.codex-sdlc
```

vsix 內附同版工作流，可直接安裝至其他工作區；Cursor、Windsurf、VSCodium 通用。extension 為整台機器共用，`sdlc.ps1 update` 不會重新安裝它。

## 已知限制

- 僅於 Windows ＋ VS Code 實測。
- hooks 未執行須待 agent 寫入產出後方能判斷；手動修改產出檔或切換分支可能誤報。
- 發佈來源尚未設定，檢查新版目前不會取得結果。
