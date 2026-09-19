# Codex SDLC —— VS Code 駕駛艙

這套工作流（`.codex/`、`.agents/`、`AGENTS.md`）在 VS Code 裡的**設定面板＋狀態列＋Problems＋幾個一鍵指令**。

**它只是殼。** 所有真相仍在專案根的 `sdlc.config.json` 與 `.codex/scripts/sdlc.ps1`、各個 gate 裡 —— 這個 extension 做的每一件事，你在終端機跑那些腳本都做得到。拿掉它，工作流照常運作。

## 從哪裡開始

- **活動列的 Codex SDLC 圖示 → 設定面板。** 一眼看到全部設定的現值（Agent 調校、審核、更新、規範、這台機器）；點一下就改；需要套用的標 ●，改完按一次「套用」。
- **狀態列左下角的 `SDLC`。** 版本與需要處理的事；點它是選單。
- **命令面板**打 `Codex SDLC`，全部指令都在。
- 第一次啟動會打開 **Get Started 的四步引導**（之後可以從選單的「開始使用」再打開）。

## 它給你看什麼

| | 資料從哪來 |
|---|---|
| 設定面板上每一個值 | 專案裡的 `sdlc.config.json`；選項與說明來自專案裡的 `.codex/bdd-workflow/sdlc.config.schema.json` |
| 「未套用」● | `doctor` 的調校區塊比對（剛寫完、doctor 還沒回來時先標上） |
| **Codex 有沒有信任這個專案的 hooks** | `doctor` 問 `codex app-server`（沒信任的 hook 一條都不跑，而且 Codex 不會提示）。沒信任時面板上有按鈕在終端機開 Codex |
| 審核修正輪上限（寫壞時亮警示） | `doctor` 的 `review` |
| 有新版 | 更新快取；背景每小時問一次 `sdlc.ps1 check-update -IfDue`（`update.check = never` 時一條連線都沒有） |
| tune 的建議（面板與 `sdlc.config.json` 上方的「採用」） | `sdlc.ps1 tune` 存下來的那份提議 |
| Problems：團隊規範違規 | 存檔時跑 `guideline-gate.ps1 -Json` |
| Problems：`guidelines/rules.json` 自己寫壞的那一條 | 存檔時跑 `guideline-gate.ps1 -Validate -Json`（對錯由 gate 判，extension 只把問題放到那一行） |
| Problems：`bdd-docs/` 裡的敏感資料殘留 | 存檔時跑 `dlp-gate.ps1 -Json`（只有類別與行號，沒有原始值） |

**每一次修改都經過 `sdlc.ps1 set`**：它先依 schema 驗完全部的值才寫，有一組不對就一個字都不動，並提示最接近的合法值。extension 自己不寫設定檔。

專案還沒有 `sdlc.config.json` 也沒關係（那是合法狀態＝全部 inherit）：面板照樣把 agent 列出來讓你改，改第一個值的時候 `set` 會替你建一份預設的。`.codex/hooks.json` 不在就不一樣了 —— 那是機械強制層整層不存在，面板與狀態列都會亮紅，並告訴你補回工具檔的指令。

`sdlc.config.json` 與 `rules.json` 第一行的 `$schema` 讓 VS Code 在你手改時就有補全、錯字波浪線與說明 —— 那是 VS Code 本身的 JSON 支援，不靠這個 extension。

## 刻意不做的三件事

1. **不推測「現在在流程的第幾步」。** 流程狀態活在對話裡，磁碟上只有 `bdd-docs/{feature-id}/spec.md`。靠檔案反推會猜錯，而猜錯的成本由你付 —— 一個顯示錯階段的狀態列比沒有狀態列更糟。
2. **不自己實作任何 lint／gate 邏輯。** 狀態一律來自 `sdlc.ps1 -Json` 的結構化欄位，違規一律來自 gate 的 `-Json`，合法值一律來自專案裡的 schema。它自己算 sha、自己判規則或自己抄一份合法值的那一天，兩份實作就開始分岔，而分岔的那一天沒有人會知道。它也從不讀腳本輸出裡給人看的句子。
3. **不把工作流設定存進 VS Code settings。** user settings 每機器一份、不進版控、團隊看不到。設定面板只改 `sdlc.config.json`（經過 `set`）。這裡的設定只有這台機器的事：`pwsh` 在哪、`codex` 在哪、要不要顯示狀態列、要不要在存檔時掃 —— 前兩個可以在面板的「這台機器」直接選檔。

## 需要

- **PowerShell 7（`pwsh`）。** 找不到時它會說，並讓你選檔（寫進 `codexSdlc.pwshPath`）。Windows PowerShell 5.1 不行。
- 工作流 **4.8.0 以上**才有狀態列與 Problems；**4.9.0 以上**才能在面板裡改設定（`set` 與 schema 從那一版開始）。版本太舊時會直接講。
- **`codex` 執行檔**，查 hooks 信任用（沒有也能跑，只是查不到那一項）。依序找設定 `codexSdlc.codexPath` → PATH → OpenAI VS Code 擴充內附的那一支（位置未實測）。都找不到時**狀態列不亮警示**，面板上那一行是黃的「無法確認」—— 狀態列的綠勾不等於 hooks 已信任。

受限模式（不信任的工作區）下它不啟動 —— 它會執行工作區裡的 `.ps1`。這跟 Codex 的 hooks 信任是兩回事：VS Code 信任了工作區，Codex 那邊仍要在專案裡開一次 `codex` 信任。

## 安裝與移除

它跟著工作流的發佈物走（`editor/codex-sdlc-{版本}.vsix`）：

```powershell
pwsh <發佈物>/.codex/scripts/sdlc.ps1 install -Target <專案> -WithEditor
# 或自己裝
code --install-extension <發佈物>/editor/codex-sdlc-4.9.0.vsix
```

Cursor／Windsurf／VSCodium 吃同一個 `.vsix`，換成各自的指令即可。

**它是每台機器一份、所有專案共用。刪掉專案不會移除它**，它下次在別的專案裡還會啟動。要移除：

```powershell
code --uninstall-extension codex-sdlc.codex-sdlc
```

升級工作流（`sdlc.ps1 update`）**不會替你重裝**它 —— 一個專案的升級不該動到另一個專案也在用的編輯器。版本對不上時 `update` 與 `doctor` 會各說一行。

## 已知限制

- 只在 Windows ＋ VS Code 上實測過；macOS／Linux、Cursor／Windsurf／VSCodium 沒有實際跑過。
- 「在終端機開 Codex 信任 hooks」沒有在真的（登入的）Codex 上試過。畫面不對的話，在專案目錄的終端機自己跑一次 `codex`。
- 設定面板裡要人點的那一段（選值的彈出框、確認框、選檔對話框）沒有自動測試；它們後面的寫入與套用有。
- 「有新版」要專案 `sdlc.config.json` 的 `update.source` 指向一個 GitHub repo。4.9.0 的發佈物還沒帶這個網址，所以背景檢查目前查不到東西 —— 在面板的「更新 → 來源」填上就會開始查。
