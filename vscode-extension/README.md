# Codex SDLC —— VS Code 駕駛艙

這套工作流（`.codex/`、`.agents/`、`AGENTS.md`）在 VS Code 裡的**設定面板＋狀態列＋Problems＋幾個一鍵指令**。

**它只是殼。** 所有真相仍在專案根的 `sdlc.config.json` 與 `.codex/scripts/sdlc.ps1`、各個 gate 裡 —— 這個 extension 做的每一件事，你在終端機跑那些腳本都做得到。拿掉它，工作流照常運作。

## 從哪裡開始

- **這個資料夾還沒有工作流？** 活動列的 Codex SDLC 圖示 → **安裝到這個工作區**。它會先問發佈物來源有沒有新版（`codexSdlc.releaseSource`，或內附發佈物版本檔裡的 `source`），拿不到就用這個 extension 內附的那一份 —— 離線照樣裝得起來。拿回來的東西一律逐檔比對 `manifest.json` 的 sha256，驗不過就不裝。已經有的 `AGENTS.md` 不會被覆蓋（新版寫成 `.new`，裝完直接開左右對照讓你合併），已經有的 `guidelines/` 完全不碰。
- **活動列的 Codex SDLC 圖示 → 設定面板。** 一眼看到全部設定的現值（Agent 調校、審核、更新、規範、這台機器）；點一下就改；需要套用的標 ●，改完按一次「套用」。
- **狀態列左下角的 `SDLC`。** 版本與需要處理的事；點它是選單。
- **命令面板**打 `Codex SDLC`，全部指令都在。
- 第一次啟動會打開 **Get Started 的四步引導**（之後可以從選單的「開始使用」再打開）。

## 它給你看什麼

| | 資料從哪來 |
|---|---|
| 設定面板上每一個值 | 專案裡的 `sdlc.config.json`；選項與說明來自專案裡的 `.codex/bdd-workflow/sdlc.config.schema.json` |
| 「未套用」● | `doctor` 的調校區塊比對（剛寫完、doctor 還沒回來時先標上） |
| 機械強制層在不在（`.codex/hooks.json`） | `doctor`。**不在時面板那一行點下去就能補回工具檔**（跑發佈物的 `update`） |
| 「安裝到這個工作區」要用哪一份發佈物 | `sdlc.ps1 fetch`（遠端優先、內附墊底、一律驗 sha），`AGENTS.md.new` 還在時面板常駐一行提醒合併 |
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
3. **不把工作流設定存進 VS Code settings。** user settings 每機器一份、不進版控、團隊看不到。設定面板只改 `sdlc.config.json`（經過 `set`）。這裡的設定只有這台機器的事：`pwsh` 在哪、去哪裡拿發佈物、要不要顯示狀態列、要不要在存檔時掃。

安裝那條路（4.10.0 起）沒有違反第 2 條：找發佈物是 `sdlc.ps1 fetch`、裝是發佈物自己的 `install`、補工具檔是它的 `update`。**連網只發生在腳本那一側**，這個 extension 一個 socket 都不開。vsix 內附的那一份 payload 是打包時同一次建置複製進去的（不進版控），所以「兩份 payload 分岔」在構造上不會發生。

它也**不查 Codex 有沒有信任這個專案的 hooks**（4.10.0 起 `doctor` 本身就預設不查）。那要另外叫起一個 `codex` 子行程，而答案是在這個面板裡按不動的東西 —— 裝完之後在專案裡開一次 `codex`，出現「Hooks need review」時選 Trust all and continue。要確認的話跑 `sdlc.ps1 doctor -CheckHookTrust`。**狀態列的綠勾不包含這一項。**

## 需要

- **PowerShell 7（`pwsh`）。** 找不到時它會說，並讓你選檔（寫進 `codexSdlc.pwshPath`）。Windows PowerShell 5.1 不行。
- 工作流 **4.8.0 以上**才有狀態列與 Problems；**4.9.0 以上**才能在面板裡改設定（`set` 與 schema 從那一版開始）。版本太舊時會直接講。
- 安裝／補工具檔要有一份發佈物：**vsix 內附**（從發佈物裝的 extension 都有）、`codexSdlc.releaseSource` 指到的 GitHub repo，或你自己用「選擇發佈物安裝…」指一份資料夾／`.zip`。三種都沒有時它會直接講，不會裝到一半。

受限模式（不信任的工作區）下它不啟動 —— 它會執行 `.ps1`。這跟 Codex 的 hooks 信任是兩回事：VS Code 信任了工作區，Codex 那邊仍要在專案裡開一次 `codex` 信任，而**這個 extension 不會替你確認那一項**。

## 安裝與移除

它跟著工作流的發佈物走（`editor/codex-sdlc-{版本}.vsix`）：

```powershell
pwsh <發佈物>/.codex/scripts/sdlc.ps1 install -Target <專案> -WithEditor
# 或自己裝
code --install-extension <發佈物>/editor/codex-sdlc-4.10.0.vsix
```

**裝了 extension 之後，下一個專案不必再找 zip**：在那個資料夾按活動列的「安裝到這個工作區」就好 —— vsix 內附了一份同版的發佈物。

Cursor／Windsurf／VSCodium 吃同一個 `.vsix`，換成各自的指令即可。

**它是每台機器一份、所有專案共用。刪掉專案不會移除它**，它下次在別的專案裡還會啟動。要移除：

```powershell
code --uninstall-extension codex-sdlc.codex-sdlc
```

升級工作流（`sdlc.ps1 update`）**不會替你重裝**它 —— 一個專案的升級不該動到另一個專案也在用的編輯器。版本對不上時 `update` 與 `doctor` 會各說一行。

## 已知限制

- 只在 Windows ＋ VS Code 上實測過；macOS／Linux、Cursor／Windsurf／VSCodium 沒有實際跑過。
- 設定面板與安裝流程裡要人點的那一段（選值的彈出框、確認框、選檔對話框）沒有自動測試；它們後面的 `fetch`／`install`／`update`／`set` 有，而且是拿真的腳本跑的。
- **「先看發佈物來源有沒有新版」目前是空轉的**：`bdd-workflow-version.json` 的 `source` 還是空的，這個 repo 也沒有發佈到任何 GitHub repo。在那個網址填上（或設 `codexSdlc.releaseSource`）之前，安裝一律用內附的那一份，「有新版」的背景檢查也查不到東西。
- 遠端有比這個 extension 新的版本時，裝出來的工作流可能吐出這一版讀不懂的 `-Json` —— 面板會說「版本不相容」，換一版 extension 就好。
