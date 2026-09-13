# Codex SDLC —— VS Code 駕駛艙

這套工作流（`.codex/`、`.agents/`、`AGENTS.md`）在 VS Code 裡的**狀態列＋Problems＋幾個一鍵指令**。

**它只是殼。** 所有真相仍在專案根的 `sdlc.config.json` 與 `.codex/scripts/sdlc.ps1`、各個 gate 裡 —— 這個 extension 做的每一件事，你在終端機跑那些腳本都做得到。拿掉它，工作流照常運作。

## 它給你看什麼

| | 資料從哪來 |
|---|---|
| 狀態列：工作流版本 | `sdlc.ps1 doctor -Json` |
| **Codex 有沒有信任這個專案的 hooks** | `doctor` 問 `codex app-server`（沒信任的 hook 一條都不跑，而且 Codex 不會提示） |
| 改了 `sdlc.config.json` 卻沒 apply | `doctor` 的調校區塊比對 |
| 審核修正輪上限（`review.maxRounds` 寫壞時亮警示） | `doctor` 的 `review` |
| 有新版 | 更新快取；背景每小時問一次 `sdlc.ps1 check-update -IfDue`（`update.check = never` 時一條連線都沒有） |
| Problems：團隊規範違規 | 存檔時跑 `guideline-gate.ps1 -Json` |
| Problems：`bdd-docs/` 裡的敏感資料殘留 | 存檔時跑 `dlp-gate.ps1 -Json`（只有類別與行號，沒有原始值） |

點狀態列打開選單：doctor、apply、調整某個 agent 的 effort／model、調整審核修正輪上限（只改 `review.maxRounds`，不必 apply —— `handoff-lint` 每次現讀）、tune、whatsnew、立即檢查更新。

## 刻意不做的三件事

1. **不推測「現在在流程的第幾步」。** 流程狀態活在對話裡，磁碟上只有 `bdd-docs/{feature-id}/spec.md`。靠檔案反推會猜錯，而猜錯的成本由你付 —— 一個顯示錯階段的狀態列比沒有狀態列更糟。
2. **不自己實作任何 lint／gate 邏輯。** 狀態一律來自 `sdlc.ps1 -Json` 的結構化欄位，違規一律來自 gate 的 `-Json`。它自己算 sha 或自己判規則的那一天，兩份實作就開始分岔，而分岔的那一天沒有人會知道。它也從不讀腳本輸出裡給人看的句子。
3. **不把工作流設定存進 VS Code settings。** user settings 每機器一份、不進版控、團隊看不到。調校 UI 只改 `sdlc.config.json`，然後跑 `apply`。這裡的設定只有這台機器的事：`pwsh` 在哪、`codex` 在哪、要不要顯示狀態列、要不要在存檔時掃。

## 需要

- **PowerShell 7（`pwsh`）。** 找不到時它會說，並給安裝連結；VS Code 找不到但你確定裝了，就在設定 `codexSdlc.pwshPath` 填完整路徑。Windows PowerShell 5.1 不行。
- 工作流 **4.8.0 以上**（結構化的 `-Json` 從那一版開始）。版本太舊時狀態列會直接講。
- **`codex` 執行檔**，查 hooks 信任用（沒有也能跑，只是查不到那一項）。依序找設定 `codexSdlc.codexPath` → PATH → OpenAI VS Code 擴充內附的那一支（位置未實測）。都找不到時**狀態列不亮警示**，說明裡寫「Codex hooks：無法確認」—— 綠勾不等於 hooks 已信任。

受限模式（不信任的工作區）下它不啟動 —— 它會執行工作區裡的 `.ps1`。這跟 Codex 的 hooks 信任是兩回事：VS Code 信任了工作區，Codex 那邊仍要在專案裡開一次 `codex` 信任（沒做時狀態列顯示「專案未信任」或「hooks 未信任」）。

## 安裝與移除

它跟著工作流的發佈物走（`editor/codex-sdlc-{版本}.vsix`）：

```powershell
pwsh <發佈物>/.codex/scripts/sdlc.ps1 install -Target <專案> -WithEditor
# 或自己裝
code --install-extension <發佈物>/editor/codex-sdlc-4.8.0.vsix
```

Cursor／Windsurf／VSCodium 吃同一個 `.vsix`，換成各自的指令即可。

**它是每台機器一份、所有專案共用。刪掉專案不會移除它**，它下次在別的專案裡還會啟動。要移除：

```powershell
code --uninstall-extension codex-sdlc.codex-sdlc
```

升級工作流（`sdlc.ps1 update`）**不會替你重裝**它 —— 一個專案的升級不該動到另一個專案也在用的編輯器。版本對不上時 `update` 與 `doctor` 會各說一行。

## 已知限制

- 只在 Windows ＋ VS Code 上實測過；macOS／Linux、Cursor／Windsurf／VSCodium 沒有實際跑過。
- 「有新版」要專案 `sdlc.config.json` 的 `update.source` 指向一個 GitHub repo。4.8.0 的發佈物還沒帶這個網址，所以背景檢查目前查不到東西 —— 自己填上就會開始查。
