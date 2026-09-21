# CodexSDLC — 使用說明

一套給 **Codex CLI** 的 agent 設定。你只要說「我要做什麼」，它會：

**幫你把需求的漏洞問出來 → 查你的專案給你幾個做法 → 你選 → 寫測試寫程式 → 獨立審一遍 → 交付。**

（**bug 走另一條**：症狀清楚但講不出重現步驟時，它會先做出一個會紅的測試，再往下走。）

本 repo 只有設定，沒有產品程式碼。

---

## 安裝

拿到 `codex-sdlc-{版本}.zip`（維護者給你，或從 Release 頁下載），**解壓到別的地方**（不要直接蓋在專案上），然後跑一行：

```powershell
pwsh <解壓目錄>/.codex/scripts/sdlc.ps1 install -Target C:\你的專案
```

zip 裡是工具那半的全部（`.codex/`、`.agents/`、`AGENTS.md`）、一份 `manifest.json`（升級時用來分辨哪些檔是你改過的）、一份 `guidelines/` 骨架，以及選用的 VS Code extension（`editor/codex-sdlc-{版本}.vsix`；要順便裝就加 `-WithEditor`，見下面「在 VS Code 裡」）。

**裝過 extension 之後，下一個專案不必再走這一段**：在那個資料夾開 VS Code，點活動列的 Codex SDLC 圖示 →「安裝到這個工作區」。vsix 內附了一份同版的發佈物，離線也裝得起來。

裝完長這樣：

```
你的專案/
├── .codex/            ← 工具的，升級會覆蓋
├── .agents/           ← 工具的，升級會覆蓋
├── AGENTS.md          ← 工具的（少了它整套流程不會啟動）
├── guidelines/        ← 你的，升級永遠不動（選用）
├── sdlc.config.json   ← 你的，每個 agent 的 model／effort
├── src/
└── tests/
```

**為什麼要解壓到別處**：`install` 得先看過你原本有什麼才能決定怎麼寫。直接把 zip 蓋上去，它就沒有機會了 —— 最要緊的是 `AGENTS.md`。

`AGENTS.md` **就是 orchestrator 本身** —— Codex 最上層對話讀的那份指令。它不是說明文件，漏掉會安靜地什麼都不發生。**你的專案已經有一份的話，`install` 不會覆蓋它**，只會在旁邊放 `AGENTS.md.new` 並要你把流程那幾節合進去（專案自己的規範放進 `guidelines/`，見下面「你們團隊的規範」）。

`guidelines/` 與 `sdlc.config.json` 是**你的**，其餘是工具的。**升級只覆蓋工具那半** —— 所以團隊規範跟調校設定只能放那兩處。不需要 `guidelines/` 就整個刪掉，流程照常跑。

需要：

- Codex —— CLI 或 VS Code 裡的 Codex 擴充都可以。兩條路都會載入 `.codex/hooks.json` 與 `.codex/agents/*.toml`（Codex 0.154 實測：CLI，以及 VS Code 擴充底下跑的 `codex app-server`）；`.codex/config.toml` 裡的 hooks 已經開好
- **PowerShell 7+（`pwsh`）** —— 強制層的腳本靠它，沒有的話 hook 會全部靜默失效
- 只有要查 live DB 才需要：設定好的唯讀 DB MCP server

隨時可以問它自己裝得對不對：

```powershell
pwsh .codex/scripts/sdlc.ps1 doctor
```

### 裝好之後一定要做的一件事：讓 Codex 信任它

**Codex 不會跑它沒信任過的 hooks，而且不會告訴你。** 在專案裡開一次 `codex`：

1. 問你要不要信任這個資料夾 → 信任
2. 出現「Hooks need review」→ 選 **Trust all and continue**

沒做這一步，`handoff-lint`、`dlp-gate`、`guideline-gate`、`build-check` 一條都不會跑 —— 流程照常進行、畫面上一切正常，只是沒有任何東西在擋。信任記在**你的** `~/.codex/config.toml`，所以換一台機器、專案搬了目錄、或升級改到 `hooks.json`，都要再信任一次。

確認：

```powershell
pwsh .codex/scripts/sdlc.ps1 doctor -CheckHookTrust
```

它會問 Codex 本人，回報「N 條都已信任」或哪幾條還沒。找不到 `codex` 執行檔時它會說查不到，不會假裝沒問題。（問的時候 Codex 連不到網路，這是刻意的。）

**`-CheckHookTrust` 要自己加** —— 4.10.0 起 `doctor` 預設不問這一項：問它要另外叫起一個 `codex app-server`（最久 15 秒），而它回答的問題 `doctor` 修不了，修法永遠是上面那兩步。沒加的那一次 `doctor` 會說一句「信任狀態這次沒查」，所以 **`doctor` 全綠不等於強制層在跑**。VS Code 的狀態列同理。

**只在 VS Code 裡用 Codex 擴充的話**：信任一樣記在 `~/.codex/config.toml`，跟 CLI 共用。我們沒驗過擴充會不會跳出同一個審核畫面，所以最保險的做法是在專案目錄的終端機裡開一次 `codex` 把這一步做完，再用上面那行確認。只裝了擴充、PATH 上沒有 `codex` 時它會說「無法確認」—— 再加 `-CodexPath <codex 的完整路徑>` 指給它。

### 已經用手動複製裝過了

先接管一次，讓它把**現況**記成基準線 —— 之後升級才分得出哪些檔是你改過的：

```powershell
pwsh .codex/scripts/sdlc.ps1 install -Adopt
```

這一步只做一次，不會覆蓋任何東西。

---

## 升級

**它會自己提醒你，但不會自己升。** 有新版時，委派子代理前的 hook 會多帶一行通知（Codex 把它記在那次 hook 的輸出裡，orchestrator 也看得到）：

```
[sdlc] 有新版 4.9.0（你在 4.8.0）。看變更：pwsh .codex/scripts/sdlc.ps1 whatsnew
```

那是通知，不是待辦 —— **它不會擋你、不會問你、也不會自己動手**。看過一次就不再提醒，直到下一版；剛升級完、快取還是舊的時候也不會亂喊。（不想被提醒：把 `sdlc.config.json` 的 `update.check` 改成 `"never"`。）

「有新版」要先有人查過才知道。`check-update` 是你手動跑的；裝了 VS Code extension 的話它每天在背景替你查一次（`never` 時一次都不查）。

檢查更新讀的是 `sdlc.config.json` 的 `update.source`。它由發佈物帶進來，指向這套工作流自己的 repo；**連不到（離線、私有 repo、網址還沒設）時整件事完全靜默** —— 不影響任何流程，只是不會有人告訴你有新版。手動查一次：`pwsh .codex/scripts/sdlc.ps1 check-update`。它說「不是可辨識的 GitHub repo」，就是這個值空著或不是 GitHub 網址：自己填上發佈這套工作流的 GitHub repo 網址 —— `update` 不會替你補：

```powershell
pwsh .codex/scripts/sdlc.ps1 set update.source=https://github.com/<owner>/<repo>
pwsh .codex/scripts/sdlc.ps1 set update.check=never    # 不想被提醒（只接受 daily／never，打錯字會被擋）
```

要升級：下載新版、解壓到別處，然後

```powershell
pwsh <新版解壓目錄>/.codex/scripts/sdlc.ps1 update -Target C:\你的專案
```

動任何一個檔之前，它會先讓你看三件事：

| 它會告訴你 | 為什麼你需要知道 |
|---|---|
| 哪些檔會被覆蓋 | 那些是你沒動過的，直接蓋沒有損失 |
| **哪些檔你改過** | 這幾個先備份到 `bdd-docs/.sdlc/backup-{舊版}/` 再覆蓋 |
| 哪些檔這一版刪掉了 | 留著舊檔的症狀通常是靜默的，所以它會備份後刪掉 |
| 是不是破壞性升級 | 你的版本低於新版的最低相容版本時會標出來 |

確認之後才動手。**`guidelines/` 一個字都不會被碰** —— 但它會順便告訴你三件事：新版的 agent 會讀哪些規範檔名而你缺了哪個、`rules.json` 在新版還驗不驗得過、`.gate-disabled` 是不是還躺在那裡（那個檔會活過每一次升級）。

升級之後它會自動重跑一次 `apply` —— 新版的 agent 檔是原廠狀態，不重套的話你的 effort 設定就沒有生效，而那件事看不出來。

**升級動到 `hooks.json` 時，Codex 會把改過的那幾條 hook 標成「待重新審核」，審核前不跑。** `update` 會提醒你；升級完開一次 codex，在「Hooks need review」選 Trust all，再用 `doctor` 確認。

VS Code extension 不會被 `update` 重裝（它是整台機器共用的）；版本對不上時會多說一行怎麼換。

---

## 在 VS Code 裡（選用）

發佈物附了一個 VS Code extension。**它只是殼** —— 它做的每一件事你在終端機跑 `sdlc.ps1` 都做得到，不裝它流程照常。

它買到兩件事：「現在靜默的幾件事變成看得見」，以及「改設定不必記 key、不必記得 apply」。

| 在哪裡 | 看得到／做得到什麼 | 沒有它的話 |
|---|---|---|
| **還沒裝工作流的資料夾 → 活動列的 Codex SDLC 圖示** | 「安裝到這個工作區」：先看發佈物來源有沒有新版，沒有就用 vsix 內附的那一份（離線可用，一律驗 sha）。已經有的 `AGENTS.md`／`guidelines/` 不覆蓋 | 找 zip、解壓、記得 `-Target` |
| **活動列的 Codex SDLC 圖示 → 設定面板** | 一眼看到全部設定的現值；點一下就改（選項與說明來自 schema）；需要套用的標 ●，改完按一次「套用」；工具檔缺了就點一下補回來；`AGENTS.md.new` 還沒合併會常駐提醒（點一下開左右對照）；預設組合、tune 建議、規範機械層開關 | `sdlc.ps1 set` 或手改 JSON，再記得 apply |
| 狀態列左下角的 **SDLC** | 版本、改了沒套用、工具檔缺不缺、有新版（背景每天刷新一次；`update.check = never` 就一條連線都沒有）。點它是選單 | 只有主動跑 `doctor`／`check-update` 才知道 |
| `sdlc.config.json` 上方 | 「套用（N 個 agent 未套用）」、tune 建議「採用」（只套那一個） | 切去終端機 |
| Problems 面板（存檔時） | `guidelines/rules.json` 的違規、`bdd-docs/` 裡的敏感資料殘留、**`rules.json` 自己寫壞的那一條** | 只在 hook 的訊息裡捲過去 |
| Get Started（第一次啟動自動打開） | 四步：裝進這個資料夾 → 選預設組合 → 跑 doctor → 設定在哪裡改 | 讀這份 README |

面板裡的每一次修改都經過 `sdlc.ps1 set` —— 先驗完才寫，寫錯一個字都不動（見下面「每個 agent 用哪個模型」）。工作流還是 4.8 的專案，面板只顯示、不給改。

裝：`install` 時加 `-WithEditor`，或自己 `code --install-extension <解壓目錄>/editor/codex-sdlc-{版本}.vsix`（Cursor／Windsurf／VSCodium 吃同一個檔）。需要 PowerShell 7；VS Code 找不到 `pwsh` 時它會說，並讓你直接選檔。**裝過一次之後，下一個專案不必再找 zip** —— 在那個資料夾按「安裝到這個工作區」就好。

**它不查 Codex 有沒有信任這個專案的 hooks**（4.10.0 起 `doctor` 本身就預設不查）：那要另外叫起一個 `codex` 子行程，而答案是在面板裡按不動的東西。所以**狀態列的綠勾不等於強制層在跑** —— 裝完照樣要做「裝好之後一定要做的一件事」，要確認就跑 `sdlc.ps1 doctor -CheckHookTrust`。

**有兩種信任，別搞混。** VS Code 的「工作區信任」決定這個 extension 會不會啟動 —— 它會執行 `.ps1`，所以受限模式下不啟動。Codex 的 hooks 信任決定強制層會不會跑（見「裝好之後一定要做的一件事」），那一項在 VS Code 裡看不到。

**它是每台機器一份、所有專案共用 —— 刪掉專案不會移除它**，下次在別的專案裡它還會啟動。移除：

```powershell
code --uninstall-extension codex-sdlc.codex-sdlc
```

它刻意不做三件事：不猜你流程走到第幾步（那活在對話裡）、不自己判任何規則（一律跑腳本、讀腳本的結構化輸出）、不把工作流設定放進 VS Code settings（唯一真相是 `sdlc.config.json`）。安裝那條路也一樣：找發佈物是 `sdlc.ps1 fetch`、裝是發佈物自己的 `install`、補工具檔是它的 `update`，**連網只發生在腳本那一側**。vsix 內附的那份 payload 是打包時同一次建置複製進去的（不進版控），所以它跟發佈物不會分岔。

已知限制：

- **只在 Windows ＋ VS Code 上實測過。** macOS／Linux、Cursor／Windsurf／VSCodium 照理吃同一個 `.vsix`，但沒有實際跑過。
- **「先看發佈物來源有沒有新版」目前是空轉的**：`bdd-workflow-version.json` 的 `source` 還是空的（見下面「已知的洞」），所以安裝一律用內附的那一份。要開通：填那個網址，或在 VS Code 設 `codexSdlc.releaseSource`。
- 遠端有比 extension 新的版本時，裝出來的工作流可能吐出這一版讀不懂的 `-Json`；面板會說「版本不相容」，換一版 extension 就好。
- 「有新版」要 `sdlc.config.json` 的 `update.source` 指向一個 GitHub repo 才查得到（見「升級」）。

---

## 每個 agent 用哪個模型、想多深

寫在專案根的 `sdlc.config.json`：

```json
"agents": {
  "orchestrator": { "model": "inherit", "effort": "inherit" },
  "sa-analyst":   { "model": "inherit", "effort": "inherit" },
  "implementer":  { "model": "inherit", "effort": "inherit" },
  "reviewer":     { "model": "inherit", "effort": "high"    }
}
```

**改值最省事的方法**（VS Code 裡就用設定面板，走的是同一條路）：

```powershell
pwsh .codex/scripts/sdlc.ps1 set agents.reviewer.effort=high agents.sa-analyst.effort=low -Apply
```

- **先驗完才寫。** 任何一組不合法 —— 值不在清單裡、key 打錯、agent 名稱打錯 —— 一個字都不動，並告訴你最接近的那個（`agents.reviewer.effort=hgih` → 「是不是要 …=high？」）。
- **`-Apply` 讓寫與套用是同一個動作**，改幾個值都只套用一次。不加的話它會提醒你還沒套用。
- `-Preview` 只列出會改什麼；`-Preset fast|balanced|deep` 換一整組（先列差異，確認才寫；裝完之後也能換）。

手改也可以：檔案第一行的 `$schema` 讓編輯器有補全、錯字波浪線與說明（VS Code 不裝 extension 也有）。手改之後要跑 `pwsh .codex/scripts/sdlc.ps1 apply` —— **忘記跑會被 `agent-lint` 擋下來**，不擋的話症狀是零：檔案看起來改好了，跑起來是舊值。

**這個檔不支援註解。** `set`、`update`、`tune` 都會整份改寫它；有註解時 `set` 會先停下來問（加 `-Yes` 才寫，原檔先備份到 `bdd-docs/.sdlc/`），`update` 會先備份再告訴你。要寫說明就寫在 `_note`。

**沒有這個檔也是合法狀態**：全部 `inherit`、修正輪照預設 3 輪，`doctor` 會說明而不是報錯。你第一次用 `set`（或在設定面板改任何一個值）時，它會替你建一份預設的 —— 內容跟 `install` 建的一樣，所以「建檔」本身不改變任何行為，只是讓你有地方放那個值。

**`"inherit"` 是預設，意思是「不釘」** —— 那個 agent 的設定裡連這一行都不會寫出去，交給 Codex CLI 決定。這不是偷懶，是這套工作流付過學費的地方：曾經把四個 agent 全部釘成 `high`，結果大型舊專案的分析**逾時**。所以除非你有理由，就讓它 `inherit`。

effort 能填的值：`inherit`、`low`、`medium`、`high`、`xhigh`、`max`、`ultra`。這份清單取自 Codex 0.154 內建的模型清單 —— **能不能用由模型決定，Codex 本身不檢查**：`xhigh` 每個內建模型都有，`max`／`ultra` 只有較新的模型才有，寫了模型不支援的值要到呼叫 API 時才出事。舊版清單裡的 `minimal` 已經不在任何一個模型的清單裡，`apply` 會警告。

一開始就想設好：`install -Preset fast|balanced|deep`。

### 讓它自己看一遍再給建議

```powershell
pwsh .codex/scripts/sdlc.ps1 tune
```

它會看你的 repo 有多大、是什麼語言、有沒有在逆推舊系統，然後**提議**一組值，每一條都附理由跟訊號來源。**它不會自己套。** 你看過覺得可以再套用：

```powershell
pwsh .codex/scripts/sdlc.ps1 tune -ApplyProposal                 # 全部
pwsh .codex/scripts/sdlc.ps1 tune -ApplyProposal -Only reviewer  # 只套這幾個（逗號分隔）
```

套用的是**剛才存下來的那一份**提議，不會重算 —— 你看到什麼就套什麼。VS Code 裡：設定面板的「tune」讓你勾選要套用哪幾個，`sdlc.config.json` 上方也會在那個 agent 旁邊掛一個「採用」。

跟直覺相反、但這是它會建議的方向：

| agent | 方向 | 為什麼 |
|---|---|---|
| `sa-analyst` | repo 越大**越往下調** | 它的失敗模式是逾時，不是想得不夠深 |
| `implementer` | 通常不動 | 成本在測試來回的次數，不在單次想多深 |
| `reviewer` | **唯一值得調高的** | 輸入小、判斷密度高，而審核的修正輪有上限，審得淺就是白付 |

**orchestrator 那一格設了也沒用** —— 它沒有自己的設定檔（它就是 `AGENTS.md`，最上層那個對話本身）。那一格只是記錄，`install` 跟 `doctor` 會把它印成一行你可以自己下的啟動指令。

### 審核最多修幾輪

同一個檔：

```jsonc
"review": { "maxRounds": 3 }
```

⑤ 審核 FAIL 會回 ④ 修，這個數字是修正輪的上限，**只接受 1–5，預設 3**。到了上限還 FAIL，它會停下來交回你（接受現版本／指定重點再跑一輪／暫停）。改法：`pwsh .codex/scripts/sdlc.ps1 set review.maxRounds=4`，或設定面板的「審核」。

- **改完不必 apply** —— 每次委派修正輪時 `handoff-lint` 都現讀，orchestrator 也會從它那裡拿到「第幾輪／上限幾輪」。
- **偶爾想多跑一輪不用改這裡**：到上限交回你時選「指定重點跑最後一輪」就好。這個值是給「團隊一貫想要不同上限」用的。
- 寫壞了（`0`、`6`、`"3"`）不會卡住流程 —— 照預設 3 輪算，但 `doctor` 與 `agent-lint` 會紅，免得你以為設了 5 其實還是 3。
- 為什麼有上限、而且最多 5：實作↔審核的來回沒有自然終點，輪次又是 orchestrator 自己報的。上限太高等於沒有上限。
- **已知缺口**：上限是在「開一個新的子代理」時檢查的。orchestrator 如果把修正交給一個已經存在的子代理（Codex 的 `send_input`，或先 `resume_agent` 再 `send_input`），那一次不會經過 `handoff-lint`，上限擋不到。流程規定子代理一律冷啟動、每一輪修正都帶著 `round` 重新委派，但這一點目前只靠 prompt。

---

## 啟動

在專案裡開 Codex，直接說你要什麼：

> 我要讓客戶可以取消訂單

**一句話就夠。** 把需求想清楚再來，正是它要幫你省掉的事。

**不用挑 agent、不用打指令。** 最上層那個對話讀了 `AGENTS.md` 就是 orchestrator 本人，`sa-analyst` 那些是它自己去叫的。

---

## 流程六步

| | 做什麼 | 誰做 | 產出 |
|---|---|---|---|
| **① BA** | 找出你沒說的需求缺口 | orchestrator 自己（不查你的專案） | `spec.md`（有缺口才開） |
| **② SA** | 查規格／repo／schema，回 2–4 個做法 | `sa-analyst` | `project-map.md`；沒做完才有 `analysis.md` |
| **③ 定案** | 選做法＋確認驗收條件（Gherkin） | 你 ＋ orchestrator | `spec.md` 補齊 |
| **④ 實作** | test-first 寫到綠 | `implementer` | `.feature`、step definitions、程式碼與測試 |
| **⑤ 審核** | 換一個乾淨的 context 獨立審 | `reviewer` | 無（PASS／FAIL，修正輪上限預設 3，可調） |
| **⑥ 交付** | 回報改了什麼、怎麼驗的、殘留風險 | orchestrator | 無 |

**能跳的就跳。** 純技術改動（重構、升套件、重現步驟明確的 bug）① 通常沒缺口，直接進 ②；改動小到「單一 commit 可 revert 且沒有要驗收的行為變更」，② 也跳過，它自己改完。

### bug 走另一條

**症狀清楚、但重現步驟講不出來**（偶發、只在某台機器、只有某筆資料會壞）→ 它會換一條路：

| | 換成什麼 |
|---|---|
| **①** | 跳過 —— 你要的行為已經很清楚（不要壞） |
| **②′** | 不查做法，改成**先做出一個會紅的測試**，紅在你報的那個症狀上 |
| **②″** | 測試紅了之後，它**自己**去查這塊行為當初是哪份需求做的（從紅測試 grep `.feature` 裡的 `# feature-id:`）。**不會問你** —— 報 bug 的人常常不是當初提需求的那個人，查不到就直接往下走 |
| **③** | 那個紅測試就是驗收條件（**轉綠 ＝ 完成**）。問你的是「**它紅的，是不是你講的那件事**」；查到當初那份需求的話，同一次還會問你「**原本就是這樣定的嗎**」 |
| **④⑤⑥** | 不變 |

看起來像這樣：

```
你 ▸ 對帳報表偶爾會少一筆，客服說大概一週遇到一兩次

▸ 這種我先不猜原因，先做一個穩定重現它的測試。
  （幾分鐘後）

▸ 做出來了：ReconciliationTests.MissingEntry_WhenSettledAtMidnight
  跑 dotnet test --filter MissingEntry_WhenSettledAtMidnight → 紅
  它紅在：結算時間剛好落在 00:00:00 的那筆不會進報表。

  這就是你講的那件事嗎？
  1. 是，照這個修   2. 不是，我遇到的不是跨日那種   3. ✏️ 自行輸入…
```

**答對這一題比什麼都值錢** —— 選 1 之後，那個測試就是驗收條件，轉綠就是修好；選 2 的話它回去重做迴路，而你只花了一次作答。**答錯的代價是 ④⑤ 整段白做**，所以這一問不會省。

**有時候答案是「這根本不是 bug」。** ②″ 查到當初那份 `spec.md` 之後，它會拿原本談定的 scenario 跟你報的症狀比對 —— **一模一樣就代表當初就是這樣決定的**，那是需求變更，不是壞掉。這時它會轉去走迭代（在原 `spec.md` 新增一節，重新談你要的行為），而不是去修一個沒有壞的東西。**這一刀砍在動手之前**，省掉的是整個 ④⑤。

查到原需求還有第二個好處你不會直接看到：當初那份 `spec.md` 寫著「驗收層」（這塊功能的測試該繫結在哪個介面），修 bug 時的回歸測試就寫在同一層。**這一行 bug 這條路本來生不出來**（它沒跑過 ②，沒有人決定過），而繫結錯層的後果是「回歸測試綠了，但 bug 還在」。

原因是 bug 跟新功能的未知不一樣：新功能不知道「你要什麼」，bug 不知道「哪裡壞了」，而後者**靜態讀程式碼讀不出來**。先做出可靠地紅／綠的一行指令，原因才找得到 —— 沒有它，每一步都是猜，而猜錯會吃掉 ⑤ 有限的修正輪。

**做不出重現的時候它會回來問你**（缺哪一天的資料、要哪個環境、症狀本身就不穩）—— 那些是你答得出來、它答不出來的事。

一個例外：**「正確行為應該是什麼」本身還沒定**（四捨五入怎麼算、跨時區算哪一天、重試幾次）→ 那是需求缺口不是 bug，它會照 ① 問你。

---

## 一次完整的例子

### ① 它先問你需求的漏洞

```
你 ▸ 我要讓客戶可以取消訂單

▸ 我看了一下，有 3 個地方你還沒說（下面的日期和金額是我假設的，只是用來把話講清楚）：

  1. 訂單 8/10 出貨，客戶 8/12 按「取消」—— 會發生什麼？
     a) 擋下來顯示「已出貨，請改走退貨」，訂單維持已出貨
        ★ 建議 —— 最簡單，而且不需要系統裡先有退貨流程
     b) 自動開一張退貨單，收到退貨後才退款 —— 前提是系統已經有退貨流程
     c) 進客服待審清單，客服核准後才退款 —— 需要一個審核介面

  2. 一張已付款 1,200 元的訂單被取消 —— 那 1,200 元怎麼走？
     a) 立刻原路退回，客戶 3–5 個工作天收到
     b) 開一張待退款單，財務每天結批處理
        ★ 建議 —— 不必接金流的退款 API，這一版就能上
     c) 這一版先不動錢，只把訂單關掉

  3. 那張訂單裡有 2 件商品，取消之後庫存怎麼算？
     a) 立刻 +2 回架上
        ★ 建議 —— 跟「訂單已取消」同一筆交易，不會有中間狀態
     b) 這版先不管，人工調整

你 ▸ 1a 2b 3a
```

**這一步不查你的專案**，用的是一般業務流程的常識。所以它問的是「你沒說、而它不能替你決定」的事 —— 猜得到的（取消後狀態要變成已取消）不會拿來問你。

問題和選項都寫成**具體實例**，不是抽象標籤（「自動開一張退貨單，收到退貨後才退款」，不是「能，但轉成退貨流程」）。為什麼是這樣、日期和金額哪裡來的、怎麼回最有效 —— 見下面「① 的問法：實例，不是問題」。

**每題都會標一個建議並附一行理由**，所以你要做的是「否決或放行」，不是從零挑一個。回「1a 2b 3a」可以，回「都照建議」也可以 —— 覺得哪一題的理由不成立，只回那一題就好。

最多問 5 個。**而且它會先排依賴，只問前置那一層** —— 上面第 1 題答「擋下來」的話，「退貨要不要收運費」「退貨單誰審」整串就不存在了，不會浪費你一次作答。所以你看到 3 題，不代表它只想到 3 個缺口；真的多到排完還超過 5 個，它會把全部標題列給你，讓你先切範圍。

沒發現漏洞會直接說一句「沒發現需求缺口」跳過。

### ② 它去查你的專案，給你幾個做法

```
▸ （查了 OrderService、Order.cs、退款相關的 12 個檔）

  現況
  訂單狀態在 Order.Status，狀態轉換集中在 OrderService.ChangeStatus()，
  已經有 IOrderStateRule 介面可以掛新規則。庫存在 InventoryService.Restock()。
  沒有現成的退款單 entity。

  做法
  A) 在 IOrderStateRule 加一條取消規則 ＋ 新增 RefundRequest
     動到：OrderService.cs、CancelOrderRule.cs(新)、RefundRequest.cs(新)、一支 migration
     風險：RefundRequest 是新表，要 migration
     工　：約 5 個檔 + 1 migration
     影響：資料=動既有資料（Order 多一個狀態值）　消費者=無

  B) 直接在 OrderService.ChangeStatus() 裡加判斷，不做退款單
     ...

  我建議 A —— IOrderStateRule 已經在那裡，不用動 ChangeStatus 的核心。
```

**每個做法的「影響」兩欄一定會填**，那是它判斷「要不要在交付前停下來問你」的唯一依據。查不出來它會停下來問，不會猜。

### ③ 你選做法，同時確認驗收條件

```
▸ 選 A 的話，驗收條件長這樣（★ 這幾條會原封不動變成 QA 的自動化測試）：

  Feature: 取消訂單
    Scenario: 已出貨的訂單不可取消
      Given 訂單 #1001 已於 8/10 出貨
      When 客戶於 8/12 送出取消要求
      Then 系統拒絕並回覆「已出貨，請改走退貨」
      And 訂單狀態維持「已出貨」

    Scenario: 未出貨的訂單取消後產生待退款單
      Given 訂單 #1002 已付款 1,200 元且尚未出貨，內含 2 件商品
      When 客戶送出取消要求
      Then 訂單狀態變為「已取消」
      And 產生一張 1,200 元的待退款單
      And 商品庫存回補 2 件

  驗收層：OrderService.Cancel（application service）

  ⚠️ 這個做法會動到既有資料（Order 多一個狀態值）

  1. 確認，開始實作   2. 我要改驗收條件   3. 換做法 B   4. ✏️ 自行輸入…
```

**這是唯一不能省的確認點。** 你在這裡批准的 Given/When/Then，就是 QA 之後拿到的字 —— 所以措辭值得多看一眼。

裡面的日期和金額就是你在 ① 答過的那些（8/10 出貨、1,200 元、2 件）。**這一步是謄寫，不是重編一組** —— 重編的話，③ 給你看的東西會跟你在 ① 答的不一樣，而沒有任何地方會標出那個差異。

**「驗收層」那一行是寫給實作者看的**，指定這幾條 scenario 要繫結在哪個介面上。它不是要你決定的東西（② 選做法時就決定了），但值得掃一眼：實作者是全新的 context，看不到你跟它談過什麼，**自己挑一層而挑錯正是「測試全綠但功能是壞的」最常見的原因** —— 繫結在把被測邏輯整段 mock 掉的那一層，測試永遠會綠。

### ④⑤⑥ 實作、審核、交付

之後它自己跑：寫 `.feature` → 寫 step definitions → 看紅 → 寫程式 → 綠 → 換一個乾淨的 context 獨立審一遍 → 沒過就回去修（預設最多 3 輪，見「審核最多修幾輪」）。

交付時回報**改了什麼、怎麼驗的、殘留風險**。

---

## 你只會被問三個地方

| | 什麼時候出現 | 你要做什麼 |
|---|---|---|
| **① 需求漏洞** | 有找到漏洞才出現 | 每題都有建議，否決你不同意的那幾題就好，或直接說「都照建議」 |
| **③ 定案** | **一定出現** | 選做法＋看一眼驗收條件。走 bug 那條時問的是「重現出來的是不是你講的那件事」，以及查得到當初需求時的「原本就是這樣定的嗎」 |
| **⑥ 交付前** | **只有**動到既有資料／正在跑的流量，或改到 QA 綁住的 step 措辭 | 決定要不要放行 |

跑 smoke test、啟動 Web／API、碰外部 DB 之前也會另外問你 —— 那不因改動大小放寬。

**它不會為了「讓你有參與感」多問一輪。** 覺得問太多，直接說「後面不用問我了，照建議做」。

### ① 什麼時候該不信它

需求漏洞是靠**一般業務常識**推的。**保險、醫療、法規、特定產業慣例這類，它可能講得很有把握但是錯的。**

所以它的措辭一律是「我認為這裡可能還沒定」，碰到專門領域也會主動說自己不準。看到不對的直接打斷。

**實例裡的日期和金額是它假設的，不是查來的** —— 這一步不碰你的專案。具體的數字讓話講得更清楚，但也會讓錯的猜測看起來更可信，所以它只能用你自己講過的值、或明講「假設」。需要一個只有你知道的事實（法規期限、你們的業界慣例）才編得出實例時，它會**直接問你那個事實**，不會編一個看起來很像的數字混過去。

---

## ① 的問法：實例，不是問題

### 為什麼

因為**標籤會藏東西**。

「已出貨的能不能取消？b) 能，但轉成退貨流程」—— 這句聽起來很清楚，但錢什麼時候退、運費誰付、部分出貨怎麼算，全都藏在「退貨流程」四個字裡。你點頭了，它也點頭了，兩個人想的可以是不同的事。

換成實例，那些維度就跑到選項上：

```
b) 自動開一張退貨單，收到退貨後才退款
```

多十幾個字，而「收到退貨後才退款」你一眼就能否決。

**這不是多花你的時間。** ③ 的驗收條件是 Gherkin，而 **Gherkin 一定要填具體的值** —— 「錢什麼時候退」到 ③ 一定得有答案。你不在 ① 講，它就在 ③ 替你填，然後包進一個標題叫「選哪個做法」的確認裡，沒有人會單獨去看它一眼。實例只是把同一筆帳挪到最便宜的地方付。

**題數沒有變多**：一樣最多 5 題、一樣一次問完。

### 門檻題會用邊界問

```
17:00 下單，隔天 16:59 按取消 —— 可以嗎？17:01 呢？
   a) 以「下單時間 +24 小時」算：16:59 可以、17:01 不行
      ★ 建議 —— 唯一不依賴其他流程狀態的算法
   b) 從「付款完成」起算 —— 貨到付款的訂單就等於沒有時限
   c) 不看時間看狀態：只要還沒出貨都可以
```

比起「多久內可以取消？a) 24 小時內」，這個問法會逼出「從什麼時候起算」，而且常常會冒出 (c) 這種**你原本沒想到、抽象問法也產不出來**的選項。

### 你答的數字會一路走到 QA

談定的實例會連同你的答案寫進 `spec.md`，③ 的 Gherkin 直接拿那些值寫 Given 和 `Examples:`，`.feature` 再原封不動交給 QA。

所以 **① 你確認的數字，就是 QA 手上測試裡的數字**。③ 那一步是謄寫，不是重編一組。

### 想改的時候，直接改實例最快

不用只回 `1a 2b`。**把實例改成對的那句話**是最有效的回法：

> 「1 選 b，但退款是開退貨單當下就退，不是收到貨才退」

它會照你的措辭更新決議，而那句話會一路走到驗收條件。

### 什麼時候它不會用實例

沒有東西可攤的時候：真正的二選一（「要不要寄通知信？」）、你自己已經把話講成實例了（它會照抄你的措辭）、以及純技術改動（重構、升套件、有重現步驟的 bug —— 那類本來就常常沒有缺口）。

---

## 常見情境

| 你想做的事 | 怎麼說 | 它會怎麼跑 |
|---|---|---|
| **改個字、改設定、修 typo** | 直接說 | 自己改完，不跑流程 |
| **加一個新功能** | 一句話說目的 | ①→⑥ 全跑 |
| **需求我已經想清楚了** | 「需求已定，直接看怎麼做」 | 跳過 ①，從 ② 開始 |
| **我只想知道有哪些做法** | 「先不要做，只給我選項」 | 跑到 ② 停 |
| **改到資料庫 schema** | 直接說 | ⑥ 一定會停下來問你 |
| **舊系統，邏輯藏在 SP／View 裡** | 「這塊邏輯在 DB 裡，要逆推」 | 先問你 schema 從哪來（你給／從程式推／連 DB），連 DB 要你批准 |
| **一次要做 5 個行為** | 直接說 | ④ 會拆成一次一個可獨立驗收的行為 |
| **有個 bug，但我講不出怎麼重現** | 說症狀就好（「偶爾會少算一筆」「只有小美的帳號會壞」） | 走 bug 那條：先做出一個會紅的測試，再問你「它紅的是不是這件事」 |
| **有個 bug，重現步驟很明確** | 直接說 | ① 通常沒缺口，直接進 ② 當一般改動做 |
| **剛做完的那塊功能要再改一次** | 「剛剛那個取消訂單，再加上部分退款」 | 會先問你這算同一塊功能的下一次迭代還是新需求 —— 迭代接在原本的 `spec.md` 上新增一節，既有的 scenario 不會被覆蓋掉 |
| **一個功能做完了，要做下一個** | 開一個新對話再說 | 見下 |

**一個需求跑完就換一個新對話。** 它會在交付時提醒你。理由是整輪的問答、選項與審核往返都堆在同一份對話裡，第二個需求在同一個對話裡跑到交付很可能撐不住，而**最先被擠掉的是你在 ① 談定的那些實例**。換對話不會弄丟東西：`spec.md`、DB 證據、系統地圖都在檔案裡，新對話接得上。

---

## 你會拿到什麼檔

產出物分三層。**分層方式決定了你做第二個需求時會不會撞到第一個**，所以值得看一眼。

### 這個需求專屬 —— `bdd-docs/{feature-id}/`

| 檔 | 誰寫 | 什麼時候 |
|---|---|---|
| `spec.md` | orchestrator | 你答完 ① 的問題就先有（那時只有需求決議），③ 之後補上選定做法＋驗收條件。行為多到要分次做時，多一節「切片與沿用」 |
| `evidence/db-*.md` | orchestrator | 每次查過 live DB 之後。**你批准換來的東西，一定會留檔** |
| `analysis.md` | `sa-analyst` | 只在 ② 中途停下來時。做完了就直接進 `spec.md`，不會多一個檔 |
| `contract/` | `sa-analyst` | 只在真的有外部消費者或真的動 schema |

`{feature-id}` 是它從你的需求取的英文短名（`cancel-order`），第一次回覆會說用了什麼、你可以改。**換一個需求就換一個目錄，這一層不會互相覆蓋。**

**每次你開一個新需求，它會先把 `bdd-docs/` 底下已經有的 feature 列一次**（目錄名 ＋ 每份 `spec.md` 的第一行標題，**只讀那一行**）。看到像的就問你一句：**這是同一塊功能的下一次迭代，還是新需求？** 兩者處理方式相反 —— 新需求換一個 id，迭代則接在原本的 `spec.md` 上**新增一節**（前幾次一個字不動）。這一問會併進本來就要問你的那次確認，不會多問一輪；**一個都沒有就不問你**，直接當新需求開始。

它不是拿新取的 id 去撞目錄名 —— 同一塊功能第二次來，你的講法幾乎一定不一樣（「讓客戶可以取消訂單」→ `cancel-order`，三個月後「取消訂單後運費要退」→ 會取成別的名字），**撞不到不代表沒有**，而撞不到的後果是同一塊功能多出第二份 `spec.md`，之後每次迭代都改在錯的檔上。所以 `spec.md` 的第一行固定是一句**用你自己的話**寫的標題 —— 列出來給你認的就是那一行。

### 跨需求共用 —— 固定路徑，不分 feature

| 檔 | 誰寫 | 作用 |
|---|---|---|
| `bdd-docs/project-map.md` | `sa-analyst`，每次分析結束 | 這個 repo 的系統地圖：模組邊界、分層與擴充點、資料存取、重點資料表、**已經建立的 step 詞彙**、**領域詞彙**。上限 200 行，每節掛「來源」。有它，第二個需求就不必把同一份現況再查一遍 |
| `bdd-docs/artifacts/legacy-schema/*.sql` | orchestrator | 只在舊系統逆推 SQL 時，見下 |

`evidence/db-*.md` 雖然放在各自的 feature 目錄底下，但**讀的時候是跨需求的**：第二個需求碰到同一張表時，② 會先去看前幾個需求盤點過的檔，**不會再叫你批准一次、也不會再連一次 DB**。所以那些目錄不要刪 —— 它們是你已經付過的批准。懷疑某份太舊了，直接說一聲，它會連同「那份是哪天查的」一起重新問你。

**「領域詞彙」那一節值得你偶爾看一眼。** 它記的是**業務詞 → 程式裡的名字**，同義詞標「避用」：

```
已出貨 → Shipped（Order.Status、orders.status）；避用 Dispatched、Delivered
```

你在 ① 講的是業務詞，實作者是全新的 context，得自己把它翻成程式命名 —— 沒有這張表，第二個需求換一個實作者就會生出第二個名字。**這種漂移測試看不見**（兩個名字的系統照樣全綠），只是半年後沒有人分得出那是一個概念還是兩個。看到裡面的用詞跟你們團隊講法不一樣，直接說一聲改掉，它下次就照新的走。

**這一層要靠 commit 才準。** `project-map.md` 判斷「上次查過的還算不算數」是拿它自己記的 commit 跟現在比，另外也會看工作區有沒有還沒 commit 的改動。功能做完就 commit 一次，第二個需求會跑得比較快、也比較準。

### 落進你的專案樹

`.feature` ＋ step definitions ＋ 程式碼與測試，都由 `implementer` 在 ④ 寫。**跟你的單元測試放在一起，不在 `bdd-docs/` 底下** —— `bdd-docs/` 是流程草稿區，QA 不會去那裡找測試。

---

**其餘一律不產出** —— 沒有狀態檔、沒有進度紀錄、沒有階段交接文件。判準是**「重新拿一次要花多少」**：想一想就有的不留檔；要重跑一次分析的，只在沒做完時留；**要你批准、要連 live 系統才拿得到的一定留檔**；而**每個需求都要重付一次的**（這個 repo 長什麼樣）留成 `project-map.md`。（`bdd-docs/.cache/` 是唯讀腳本的索引快取，隨時可刪。）

### `legacy-schema/*.sql` 是做什麼的

舊系統常把業務規則寫在 View／Stored Procedure／Function 裡，不在程式碼裡。要動那塊時：

1. `sa-analyst` 發現邏輯在 DB 物件裡 —— 但它連不到 DB，會停下來
2. **你批准** → orchestrator 讀出 definition，遮蔽後**一物件一檔**落成 `legacy-schema/{object-name}.sql`
3. 跑 `sql-scan.ps1` 掃出 cursor／case-when／dynamic-sql 這類邏輯訊號（純腳本，零 token）
4. `sa-analyst` 讀檔判定：哪些是**業務規則**（要搬進程式、要寫成驗收條件）、哪些只是資料存取（join／分頁／排序不算規則）

它存在的理由是 `sa-analyst` 沒有 DB 權限、而 orchestrator 不該替它做「哪些算業務規則」的判斷 —— 這個檔就是那道落差的橋，順帶讓幾百行的 definition 不必擠進 1200 字元的委派、也不必進對話。

**它是唯讀的分析素材，不是拿來執行的**（整套流程禁止任何 DDL／DML）。放在 `artifacts/` 而不是 `{feature-id}/` 底下，因為它描述的是你的資料庫、不是這次的需求。

### `.feature` 是交付給 QA 的，不是文件

C# 用 **Reqnroll**，Java 用 **Cucumber**；你的專案已經在用別的就沿用。

**每份 `.feature` 開頭會多一行 `# feature-id: {feature-id}` 註解。** 它是這份測試跟 `bdd-docs/{feature-id}/spec.md` 之間唯一的連結 —— 以後有人報這塊功能的 bug，它就是靠這一行從壞掉的測試回查到當初的驗收條件（見上面的 ②″）。**不要刪掉它**；那是 Gherkin 註解，對 QA 的自動化沒有任何影響。

由此推出一條你會遇到的規則：**改掉既有 step 的措辭是破壞性變更。** QA 的自動化綁在那些文字上，改了會靜默斷掉、而且斷在他們的 repo。所以它跟「改對外 API」走同一條確認 —— 交付前會停下來，把「哪些 step、舊措辭、新措辭」列給你，你拿去轉達 QA。**加新 step、加 scenario、改實作都不算。**

沒有可驗收行為變更的改動（純重構、升套件、改設定）不套這個格式，寫一行 DoD 就好。

### 中斷了怎麼辦

狀態活在對話裡，所以**對話沒了就重跑** —— 但不是從零：`spec.md`、DB 證據、以及 ② 沒做完時留下的 `analysis.md` 都還在。① 是純推理幾乎免費，② 從上次停的地方接。**已經批准過的 DB 查詢不會叫你再批准一次。**

`spec.md` 不在就從 ① 重來。不要叫它猜你上次決定了什麼。

---

## 你們團隊的規範

「API 要怎麼設計」「SQL 不能用哪些語法」這種東西放 `guidelines/`。**不需要就不用建**，沒有那個目錄整套流程照跑。

不同團隊的規範不同，而工作流是複製到**每個專案根目錄**的 —— 所以 **repo 本身就是團隊選擇器**。不用設 team-id、不用切設定檔。同一團隊跨多個 repo 想共用，把 `guidelines/` 掛成 git submodule 就好。

### 分兩半，判準是「機器判不判得出對錯」

```
guidelines/
├── api.md        ← sa-analyst 讀（排做法時、產契約時）
├── sql.md        ← sa-analyst + implementer 讀
├── coding.md     ← implementer 讀
├── testing.md    ← implementer 讀
└── rules.json    ← 腳本讀，agent 從不讀
```

**散文（`*.md`）** 放判斷題：資源怎麼命名、錯誤格式長什麼樣、邏輯該放哪一層。子代理自己讀，是榮譽制。

**`rules.json`** 放判得出對錯的：禁用的關鍵字、禁用的 API。`.codex/scripts/guideline-gate.ps1` 在**每次寫檔之後**掃一遍，`severity: block` 的規則會直接把那次寫檔擋下來，訊息帶 rule id、檔:行與修法，實作當場就改。

**這半是零成本的。** 散文每次委派都要讓 agent 讀一遍（所以每檔上限 150 行），`rules.json` 一個 token 都不用，而且擋得住。**能搬過去的就搬過去** —— 這是你唯一的施力點。

### 每一條都要標 MUST 或 SHOULD

```markdown
## MUST
- 對外 endpoint 一律 `/api/v{n}/{resource}`，動詞不進 path

## SHOULD
- 列表預設每頁 20 筆
```

違反 MUST 審核會判 **[必修]**，違反 SHOULD 只給 [建議] 且**不會**因此打回。沒標的一律當 SHOULD。不標的話，每一條都變成打回候選，而修正輪有上限（預設 3）—— 全被命名意見吃掉，真正的問題就沒人看了。

### 規範會刪掉做法，而它不會替你刪

② 排做法之前就會讀 `api.md` 與 `sql.md`，每個做法帶一行「規範：符合 / 違反 X，需要豁免」，③ 原樣呈給你。

**違反規範的做法不會被默默丟掉。** 有時候正確答案就是去要一次豁免 —— 那是你的決定。被悄悄刪掉的選項，你不會知道它存在過。

### 改完規則驗一次

```powershell
pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate
```

寫壞的 regex 要在這裡就紅。規則檔壞掉時 gate **不會擋你**，但每次寫檔都會在訊息裡喊 —— 安靜地失效（規範沒生效，畫面上一切正常）比擋錯更糟。

暫時全關：建一個空的 `guidelines/.gate-disabled`。

---

## 卡住的時候

每次委派前會擋下這些，訊息裡附了怎麼修：

| 訊息 | 意思 | 通常怎麼辦 |
|---|---|---|
| `missing-spec-ref` | 要實作或審核，但沒帶 `spec.md` 的**路徑** | 還沒走完 ③，先定案 |
| `review-loop-exceeded` | 修正輪超過上限（預設 3，`sdlc.config.json` 的 `review.maxRounds`） | 它會交回你裁定：接受現版本／指定重點跑最後一輪／暫停 |
| `handoff-too-long` | 委派超過 1200 字元 | 通常是它想貼全文；讓它改傳路徑 |
| `connection-string`／`secret-literal` | prompt 裡有連線字串或密鑰 | **不要繞過**，把敏感值從來源拿掉 |
| （沒有任何訊息）寫了違規的檔、沒帶 meta 的委派都照樣過 | Codex 沒信任這個專案的 hooks，強制層整層沒在跑 | 跑 `sdlc.ps1 doctor -CheckHookTrust`，照它說的去 codex 裡信任 |
| `doctor -CheckHookTrust` 說「無法確認 Codex 是否信任了這個專案的 hooks」 | 括號裡寫原因：找不到 `codex` 執行檔，或問了 15 秒沒回應。不代表沒信任，也不代表有 | 找不到：裝 Codex CLI，或再加 `-CodexPath <完整路徑>`。沒回應：再跑一次 |
| `doctor` 全綠，寫檔卻沒有人擋 | **綠燈不包含 Codex 的 hooks 信任** —— 4.10.0 起預設不查那一項（`doctor` 會說一句「這次沒查」） | 跑 `sdlc.ps1 doctor -CheckHookTrust`，照它說的去 codex 裡信任 |
| `doctor` 說 `.codex/hooks.json` 不在 | 工具檔缺了（被刪掉，或當初只複製了一部分）—— 四支 hook 一支都不會跑，寫檔與委派完全沒有人擋 | VS Code 面板那一行點下去（「補回工具檔」）；終端機的話把發佈物解壓到別處跑 `update -Target <這個專案>`。之後在 codex 裡重新信任 |
| `apply` 說「沒有 sdlc.config.json —— 沒有東西要套用」 | 沒有設定檔是合法狀態（全部 inherit），所以沒有東西要套 | 要開始調校就用 `set …`（它會替你建設定檔）；不想調校就不必理它 |
| `set` 說「設定檔裡有註解」，一個字都沒寫 | `sdlc.config.json` 不支援註解，整份改寫會把它們吃掉 | 把說明搬進 `_note` 再跑；或加 `-Yes` 照寫（原檔先備份到 `bdd-docs/.sdlc/sdlc.config.with-comments.json`）。VS Code 面板會跳出同一個選擇 |
| `set` 說某個值「不是合法值」或「不認得的設定」 | 值不在 schema 的清單裡，或 key 打錯了 —— 整批都沒寫 | 照它給的「是不是要 …」改；合法值與說明也可以在設定面板或編輯器的補全裡看到 |
| 裝了工作流，VS Code 裡卻沒有任何介面（左下角沒有 `SDLC`、活動列沒有 Codex SDLC、命令面板找不到 `Codex SDLC`） | 最常見：extension 根本沒裝 —— `install` 沒加 `-WithEditor` 時只會提示、不會裝。其次：打開的資料夾不是裝了工作流的那個，或工作區沒被信任 | `doctor` 會說這台機器有沒有裝；沒裝就 `code --install-extension <發佈物>/editor/codex-sdlc-{版本}.vsix`，然後 `Developer: Reload Window`。打開有 `.codex/bdd-workflow/` 的那個資料夾，信任它 |
| 活動列有 Codex SDLC 圖示，點進去卻說「這個資料夾還沒有 Codex SDLC 工作流」 | 正常 —— 面板現在在每個工作區都在，那就是安裝入口 | 按「安裝到這個工作區」。說找不到發佈物的話（開發模式裝的 extension 沒有內附），改按「選擇發佈物…」或設 `codexSdlc.releaseSource` |

寫入 `bdd-docs/**` 之後還會掃一次敏感資料殘留。確定整個專案沒有敏感資料的話，建一個 `bdd-docs/.dlp-disabled` 可以整個關掉。

寫檔之後另外會擋一種：**違反 `guidelines/rules.json` 裡 `severity: block` 的規則**（訊息開頭是 `[Hook][Guideline]`，帶 rule id、檔:行與修法）。這是你們自己設的規則，所以要嘛照著改、要嘛去改規則 —— 把 severity 降成 `warn`，或建 `guidelines/.gate-disabled` 整個關掉。

**這兩個關掉的開關不會自己回來。** 它們通常是某一次為了解卡建的，建完就留在那裡，之後每一個需求都在沒有防護的情況下跑。所以只要標記檔還在，每次寫檔都會在 stderr 喊一行「已被 … 關閉」—— 它不擋你，只是不讓「其實沒有人在守」這件事變成安靜的。看膩了就刪掉標記檔。

**子代理回 `blocked` 的時候不會硬重試** —— 它會帶著修正過的委派重開一次，或直接交回你。

### 跑很久然後逾時

這跟「斷線」不一樣：不是話沒傳到，是**那次的活太多**。所以正確的做法是**砍範圍**，不是重試 —— 同樣的範圍再跑一次，結果一樣。

它會給你「縮小範圍再跑一次」的選項（例如「這次只看這兩個目錄，只要 2 個做法」）。**選它，不要選單純重試。** 分析類的工作切小之後仍然有用，切完的那一半不會白做。

---

## 想插手的時候

- **「不要問了，照建議做」** —— 後面的選擇它自己決定
- **「用做法 B」** —— 直接指定，不用等它建議
- **「1 選 b，但退款是開退貨單當下就退」** —— 在 ① 直接改實例，比只回 `1a 2b` 準
- **「這條驗收條件改成…」** —— 在 ③ 直接改，改完再確認
- **「停」** —— 隨時停，`spec.md` 已經寫的會留著
- **「這塊我的專案不是這樣，是…」** —— 它的現況判斷來自靜態分析，你比它清楚

---

## 給維護者

改完設定跑這兩個，都要綠：

```powershell
pwsh -NoProfile -File .codex/scripts/agent-lint.ps1              # 設定一致性
pwsh -NoProfile -File .codex/scripts/tests/run-tests.ps1         # 強制層的 fixture 測試
pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate # 規則檔（有 guidelines/ 才需要）
```

發佈一版：

```powershell
pwsh -NoProfile -File .codex/scripts/pack.ps1     # → dist/codex-sdlc-{version}.zip
```

發佈前把 `bdd-workflow-version.json` 的 **`source`** 填成這個 repo 的網址 —— `install` 會把它寫進每個消費端的 `sdlc.config.json`，那是他們唯一的更新來源，**也是 VS Code 的「安裝到這個工作區」去哪裡找新版發佈物的依據**（`sdlc.ps1 fetch`）。沒填不會擋你出貨（第一版還沒推上去很正常），但 `pack` 每次都會喊：**沒有它，那些專案永遠不會有人告訴他們有新版，而症狀是零。**

`pack` 自己會先跑 `agent-lint` 與 fixture 測試，**紅燈就不出貨** —— 一份設定不一致的發佈物，症狀會落在別人的專案裡，而且通常是靜默的。它同時產生 `manifest.json`（每個工具檔一個 sha256），那是升級能分辨「使用者改過」的唯一依據，也會清掉 agent 檔裡的 `SDLC-TUNING` 區塊（發佈物一律原廠狀態，別把自己的調校偷渡出去）。版本號改 `bdd-workflow-version.json` 的 `contract-version`，`AGENTS.md`、`config.toml` 的標題與 `vscode-extension/package.json` 由檢查 10／11 盯著（extension 那一處用 `npm version <版本> --no-git-tag-version` 改）。

repo 裡有 `vscode-extension/` 時，`pack` 還會 `npm ci` ＋ 編譯 ＋ 跑 extension 的測試（需要 Node.js；這一版不帶編輯器那一層就加 `-SkipExtension`），產出的 `.vsix` 放進發佈物的 `editor/` —— **不進 manifest**，它不是工具那半也不是使用者那半。extension 的測試包含一支拿真的 `sdlc.ps1` 輸出來驗的合約測試，所以改了 `-Json` 的欄位卻沒同步 extension，這裡會紅。

建 vsix 之前，`pack` 會把**這一次 staging 算出來的發佈物**複製進 `vscode-extension/payload/`，讓 vsix 內附一份（使用者才能在還沒裝工作流的資料夾裡直接安裝）。內附的就是同一次打包的那一份、同一份 manifest，所以不會跟發佈物分岔；複製完還會從產出的 vsix 裡讀回版本再驗一次，對不上就不出貨。`payload/` 只在打包期間存在於工作區（`finally` 一定刪掉），而且 **gitignore —— repo 裡長期躺著第二份 `.codex/` 才是真正會分岔的那個形狀**。

改了 extension 之後，另外在真的 VS Code 裡驗一次打包出來的 vsix（會開一個獨立的視窗，不碰你平常那一份）：

```powershell
cd vscode-extension
npm ci; npm run build; npm test     # 不必等 pack 就能跑的那一套
npm run test:host                   # 打包的是 out/ 現有的東西，所以先 build
```

`test:host` 在 Windows 上預設用 PATH 上 `code` 所在的那份 VS Code；那份正在背景更新時會拒絕再開一個實例，這時設 `$env:VSCODE_TEST_DOWNLOAD='1'` 改用下載的 stable（其他平台一律下載）。下載的放在 `vscode-extension/.vscode-test/`，約 1 GB，已 gitignore，不要了直接刪。

發佈前的清單：

1. 版本號：`contract-version` 與另外三處（見上；漏了會被檢查 10／11 擋下，先改省一輪）。
2. `bdd-workflow-version.json` 加一個 `v{主次}-…` 說明，`source` 填好。
3. README 補一節「從 v… 升上來」。
4. 上一版之後 Codex 升過版 → 重跑一次 hook 實測，並重查 effort 的合法值（見下面第 7、8 條）。
5. `pack`。

八條容易踩的規則：

1. **`AGENT-CORE` 區塊必須在 4 個檔之間逐字相同**（`.codex/agents/` 的 3 個 toml ＋ `AGENTS.md`）。重複是刻意的 —— prompt cache 只認逐字相同的前綴，跨 agent 不共用。改一個要改全部，`agent-lint` 檢查 1 會擋。
2. **不要幫 orchestrator 補一個 `.codex/agents/bdd-orchestrator.toml`。** 它的指令屬於 `AGENTS.md`。有了 toml 它就會被當子代理 spawn 起來，而被 spawn 出來的 agent 拿不到 `agent` 工具 —— ② 到 ⑤ 全部委派不出去，症狀只是一句「工具不存在」。檢查 3 會擋。
3. **加了 agent 就要加進 orchestrator 的「## 委派」表**，反之亦然。檢查 3 雙向比對。
4. **每個檢查都要有一個「刻意弄壞後必須紅燈」的測試。** 抓不到東西的檢查比沒有檢查更糟。
5. **`guidelines/` 底下加了新的 `*.md`，就要有 agent 提到那個檔名。** 規範走「檔名即路由鍵」，沒有映射表（映射表是第二份會走鐘的名冊）。代價是沒有讀者的規範檔**完全靜默** —— 沒有錯誤、沒有警告，只是它不生效，而團隊以為有人在守。檢查 8 會擋。
6. **不要把任何使用者會想改的東西放進 `.codex/`、`.agents/` 或 `AGENTS.md`。** 那三處升級時會被覆蓋，放進去的設定會**靜默消失**。使用者的東西只有兩個落點：`guidelines/`（團隊規範）與 `sdlc.config.json`（每個 agent 的 model／effort）。這條沒有機械強制 —— 唯一的護欄是記得它。
7. **hook 腳本的測試一律餵 Codex 真的送出來的 payload**（`run-tests.ps1` 的 `New-CodexHookPayload`）。舊測試自己捏了一個 Codex 從來不送的形狀，三支 gate 對真的 `apply_patch` 完全失明，而測試一路全綠。工具名稱（`apply_patch`／`Bash`／`spawn_agent`）與 payload 形狀是**觀測值，不是合約** —— Codex 升版時照 `docs/vscode-extension-plan.md` 記的方法重跑一次實測（假模型驅動 `exec` 與 `app-server`），不要只讀文件。
8. **設定的合法值只改 schema 一處，再讓檢查 14 告訴你還有哪裡要跟。** `.codex/bdd-workflow/sdlc.config.schema.json`／`rules.schema.json` 是 `set`、VS Code 設定面板與編輯器補全讀的那一份；hook 與 lint 必須在 schema 不在時照跑，所以各留了一份常數（`sdlc.ps1` 的 `$KnownEfforts`／`$UpdateChecks`／`$GitHubSourcePattern`、`handoff-lint` 的修正輪範圍、`guideline-gate` 的 `$Severities`、`agent-lint` 自己的兩個），由檢查 14 綁在一起。effort 清單是**觀測值**（Codex 0.154 內建模型清單的 reasoning effort；Codex 本身不檢查這個值）—— Codex 升版時用 `strings` 查一次它的模型清單（`docs/settings-ux-plan.md` 的執行結果有方法）。

**為什麼是這樣設計**（哪些事該有自己的 context、為什麼無狀態、v4 砍掉了什麼、砍掉的代價）見 `docs/design-rationale.md`。那份只給人看，執行期不讀。

### 還沒做完的事

截至 v4.10.0。細節與證據在 `docs/vscode-extension-plan.md` 與 `docs/settings-ux-plan.md` 的「執行結果」。

**要先做決定的**

- **`send_input`／`resume_agent` 要不要也經過 `handoff-lint`。** 現在 matcher 只攔 `spawn_agent`；把修正交給已經存在的子代理不會被檢查，修正輪上限因此擋不到（見「審核最多修幾輪」）。要攔，就得先定義一次 `send_input` 什麼時候算一輪修正 —— 它也拿來追問、補資料，不能每一次都要求帶 `round`。
- **extension 的 publisher ID。** 現在的 `codex-sdlc` 是佔位。上 Marketplace 之前要定案 —— 改 publisher 等於改 extension ID，已經裝過的人要重裝；repo 裡寫著這個 ID 的地方要一起改（`sdlc.ps1` 的 `$ExtensionId`、兩份 README 的移除指令、`test-host/suite.ts`、`test-sdlc.ps1` 的假 extensions.json）。
- **VS Code 裡要不要（用別的方式）把「Codex 還沒信任 hooks」講出來。** 4.10.0 把那一項整條從 extension 拿掉了：查它要另外叫起一個 `codex` 子行程（最久 15 秒），而答案在面板裡按不動。代價是最靜默的那個失效在 VS Code 裡完全看不到 —— 只有在終端機跑 `doctor -CheckHookTrust` 才知道（CLI 的預設也一起關了）。要補的話，成本最低的形狀是「裝完之後提醒一次」，而不是每次健檢都去問。
- **網頁式設定頁（`docs/settings-ux-plan.md` 的 S5）。** 照計畫的判準：側邊欄上線之後回饋仍然是「不好設定」，或要設定的人不是開發者，才做。

**計畫裡延後的**

- **M2**：Marketplace ＋ OpenVSX 雙通道、`.vscode/extensions.json` 推薦（已經有這個檔的專案，`install` 後位元組不變）、CI 發佈的版號與 `contract-version` 一致。照計畫的判準，等有一批「你不知道他們裝了哪一版」的外部使用者再做。
- **只用終端機的人的更新刷新**：沒裝 extension 就要自己跑 `check-update`，那行「有新版」才會出現。計畫裡的便宜替代只做了一半：`check-update -IfDue`（快取未滿一天不連網）有了，「由 `doctor`／`whatsnew` 順手觸發一次背景刷新」沒做。

**做了、但沒在真實環境驗過的**

- VS Code 工作區信任 → extension 啟動這條路（host 測試用了 `--disable-workspace-trust`）；「工作流太舊」的提示。
- 設定面板裡要人點的那一段：選值的彈出框、換預設組合與關閉機械層的確認框、選檔對話框、tune 的勾選清單。host 測試驗的是它們後面那一條路（`set` 寫入 → 標未套用 → 一次套用 → CodeLens 採用），畫面本身沒有自動測試。
- 設定面板在「沒有工作流的資料夾」與受限模式下不出現：靠 `when: codexSdlc.active`，只驗了「有工作流時會出現」。
- 「在終端機開 Codex 信任 hooks」：沒有在真的（登入的）Codex 上試過。
- macOS／Linux、Cursor／Windsurf／VSCodium、沒有 pwsh 或只有 Windows PowerShell 5.1 的機器、非繁中語系的 Windows（hook 的編碼問題是在 cp950 上查到並驗證修正的）。
- OpenAI VS Code 擴充：內附 `codex` 的位置、它有沒有「Hooks need review」審核畫面。
- `doctor -CheckHookTrust` 問 Codex 信任狀態只在未登入的 Codex home 驗過；登入後 app-server 的啟動行為沒驗（15 秒沒回應就只說「無法確認」）。

**已知、還沒修的**

- 兩支會阻斷的 hook 同時命中時，Codex 合併後的回饋偶爾有一兩個字亂碼（約十二次一次，隔離環境重現不出來）。
- **更新檢查目前在每個專案上都查不到東西。** `bdd-workflow-version.json` 的 `source` 還是空的，`install` 寫進每個專案的 `update.source` 也就是空的（extension 的背景檢查一樣）。而且 `update` 不會替已經裝好的專案補這個值 —— 填好之後只有新裝的專案拿得到，舊的要自己改 `sdlc.config.json`，或讓 `update` 補空值（還沒做）。**同一個洞也讓 VS Code 的「安裝到這個工作區」的「先看遠端有沒有新版」永遠空轉** —— 它一律退回 vsix 內附的那一份（功能是好的，只是現在沒有遠端可問）。

### 從 v4.9 升上來

**非破壞性** —— 流程六步、產物路徑、handoff 合約、hooks 都沒動（不必重新信任）。升級動作：跑 `update`，並換上這一版附的 vsix。這一版改的是「怎麼把它裝進下一個專案」：

- **VS Code 裡多了安裝入口。** 活動列的 Codex SDLC 圖示現在**每個工作區都在**；還沒裝工作流的資料夾點進去是「安裝到這個工作區」。它先問發佈物來源有沒有新版，拿不到就用 vsix 內附的那一份（離線可用），拿回來的東西一律逐檔比對 `manifest.json` 的 sha256 才用。已經有的 `AGENTS.md`／`guidelines/` 不覆蓋。
- **工具檔缺了、`AGENTS.md.new` 沒合併，現在都有按得下去的按鈕**（「補回工具檔」＝跑發佈物的 `update`；「比對並合併」＝開左右對照）。以前這些狀態只有一句「請去終端機跑 …」。
- **新的子命令 `sdlc.ps1 fetch`**：找一份可用的發佈物（遠端優先、本機墊底、一律驗 sha、依版本快取）。終端機也能用：`pwsh .codex/scripts/sdlc.ps1 fetch -Json`。
- **`doctor` 不再問 Codex 的信任狀態**（終端機也一樣）。問它要另外叫起一個 `codex app-server` 子行程（最久 15 秒），而修法永遠是同一句「去 codex 裡信任」—— `doctor` 幫不上忙。**要查就明講 `doctor -CheckHookTrust`**，行為跟以前一模一樣。沒查的那一次 `doctor` 會說一句「這次沒查」並告訴你這個參數 —— 因為「doctor 全綠」被讀成「強制層在跑」是這裡最貴的誤會。extension 因此拿掉了 `codexSdlc.codexPath` 與兩個信任相關的指令，多了 `codexSdlc.releaseSource`。
- `install`／`update` 提早失敗時 `-Json` 多了結構化的 `error`（`not-a-release`／`same-path`／`not-managed`／`nothing-to-adopt`）。讀 `-Json` 的人不必再解析句子。

### 從 v4.8 升上來

**非破壞性** —— 流程六步、產物路徑、handoff 合約、hooks 都沒動（不必重新信任）。升級動作：跑 `update`。這一版改的是「改設定」這件事：

- **新的入口 `sdlc.ps1 set`**（見「每個 agent 用哪個模型」）：先依 schema 驗完才寫，`-Apply` 一次套用，`-Preset` 裝完也能換組合。`tune -ApplyProposal` 改成套用**存下來的那份**提議（不重算），可以 `-Only` 只套幾個。
- **設定檔有了 `$schema`**：`update` 會替你的 `sdlc.config.json` 補上第一行，編輯器從此有補全與錯字波浪線（VS Code 不裝 extension 也有）。`guidelines/rules.json` 在你那半，升級不碰 —— 想要同樣的提示，自己在第一個 key 前加一行 `"$schema": "../.codex/bdd-workflow/rules.schema.json",`。
- **effort 的合法值換成 Codex 0.154 模型清單裡的值**：多了 `xhigh`、`max`、`ultra`，拿掉 `minimal`（沒有任何一個模型支援它）。設定檔裡還有 `minimal` 的話，`apply` 會警告 —— 用 `set` 改成別的值。
- **`sdlc.config.json` 不支援註解**（以前就會被 `update` 靜默吃掉，現在講明）。有註解時 `update` 先把原檔備份到 `bdd-docs/.sdlc/backup-4.8.0/` 再警告；把說明搬進 `_note`。
- 新裝的設定檔不再寫 `update.channel`（從來沒有人讀它；舊檔留著不影響）。`update.check` 打錯字（例如 `nevr`）現在 `doctor` 會紅、`check-update` 會講 —— 以前是靜默地照 `daily` 算。
- VS Code extension 換成這一版附的 vsix：活動列多了設定面板、`sdlc.config.json` 上方有「套用」與 tune 建議、`rules.json` 存檔即驗、第一次啟動會打開四步引導。它**需要專案的工作流也是 4.9.0** 才能改設定；還在 4.8 的專案照樣有狀態列，面板只顯示。
- `guideline-gate -Validate -Json` 多了 `rule_problems`（第幾條、哪個欄位）；`problems` 還在。

### 從 v4.7 升上來

**先講最重要的：v4.7 以前的機械強制層，在現行的 Codex（0.154 實測）上沒有在擋。** 不是規則寫錯，是 hook 跟 Codex 之間的四個接縫都鬆了，而且每一個的症狀都是零 —— hook 每次都跑、每次都「完成」。這一版修好它，**升級動作**：跑 `update`（或複製 `.codex/` 與 `AGENTS.md`），然後**在專案裡開一次 codex，信任資料夾、在「Hooks need review」選 Trust all**，再跑 `doctor` 確認 hooks 已信任。流程六步、產物路徑、handoff 合約都不變。

修掉的東西（全部用本機的假模型驅動 Codex 實測過，CLI 與 IDE 的路徑一樣）：

1. **Windows 上四支 hook 沒有一支擋得下來。** Codex 把 hook 包成 `pwsh -Command`，腳本的 `exit 2` 被回報成 1，Codex 當成「hook 失敗」—— 不阻斷，訊息也不交給模型。`hooks.json` 每一條加了 `commandWindows` 把 exit code 傳出去。
2. **agent 寫的檔，三支寫檔後的 gate 幾乎全漏。** `apply_patch` 的路徑在 patch 標頭、沒有引號，gate 只認引號路徑；shell 工具在 Codex 裡叫 `Bash`，matcher 只有 `shell`。實測寫進 `bdd-docs/` 的 email、含 `NOLOCK` 的 `.sql`、改過的 `.cs`，DLP／規範／build 三支全部放行。
3. **「不擋但要喊」的訊息全部被丟掉。** Codex 會丟掉成功結束的 hook 寫的 stderr —— kill switch 還關著、`rules.json` 寫壞、warn 級的規範命中、有新版，這些一句都沒到過任何人眼前。現在改走 Codex 會送進模型的那條管道。
4. **中文 handoff 在 hook 裡被解錯編碼。** 一份 743 字的合法中文 handoff 會被算成 1772 字、而且抓不到 `mode:` —— 前三條修好之後如果不修這條，**每一次委派都會被擋**。所有會被程式呼叫的腳本現在一律用 UTF-8 讀寫。
5. **hooks 要被信任才會跑**（見上面「裝好之後一定要做的一件事」）。`doctor` 現在會問 Codex 信任了沒。

順帶：

- **`doctor` 不再誤報「你缺 guidelines/spec.md」。** v4.7 起它每次都這樣報，而且因此永遠是紅的 —— 那不是你的問題，是章節切錯了，不要去建那個檔。
- 剛升級完、更新快取還沒刷新時，不會再跟你說「有新版（你在舊版）」。
- **審核最多修幾輪可以設了**：`sdlc.config.json` 的 `review.maxRounds`（1–5，預設 3，見「審核最多修幾輪」）。`update` 會替舊的設定檔補上這一節、值填 3，行為跟以前一模一樣。
- 新增選用的 VS Code extension（見「在 VS Code 裡」），以及它需要的：`sdlc.ps1 -Json` 改成結構化輸出（有程式在讀它的人注意：外殼多了 `schema`、`data`、`warnings`，`output` 還在）；`check-update -IfDue`；`dlp-gate -Json`。

殘留一件已知的事：兩支會阻斷的 hook **同時**命中時，Codex 合併後交給模型的訊息偶爾會有一兩個字變成亂碼（約十二次一次）。擋還是有擋，理由也還看得懂；我們這一側送出去的位元組是正確的。

### 從 v4.6 升上來

**非破壞性** —— 流程六步、產物路徑、handoff 合約全部沒動。升級動作：複製 `.codex/`、`.agents/` 與 `AGENTS.md`。

五件事：

1. **bug 有自己的路了。** 症狀清楚但重現步驟講不出來（偶發、只在某環境、只有某筆資料會壞）→ ① 跳過、② 換成「先建一個會紅的測試」，那個測試接著就是驗收條件（轉綠 ＝ 完成），③ 的確認問的是「它紅的是不是你講的那件事」。以前這類需求會走完整流程然後空轉：① 找不到缺口、② 讓 SA 盲讀二十幾個檔、③ 要寫 Gherkin 但還不知道 bug 在哪。新 skill 是 `bug-diagnosis`。**沒有新 mode、沒有新產物路徑** —— 路由鍵是 `spec.md` 驗收條件的形狀（一行「回歸測試：…」）。
2. **① 會給你建議答案了。** 每個缺口的選項會標出一個建議並附一行理由，而且問之前先排依賴、只問前置那一層 —— 後面那串常常會因為前面的答案直接消失（12 個縮到 4 個是常態，而且一個都沒丟）。題數上限仍是 5，仍是一次確認。
3. **③ 多一行「驗收層」。** Gherkin 區塊底下會指定 scenario 繫結在哪個介面。這是寫給 `implementer` 看的：它是冷啟動，看不到你跟 SA 談過什麼，自己挑一層而挑錯正是假綠燈最常見的來源。
4. **修 bug 時會回查當初那份需求。** 迴路紅了之後、動手修之前（②″），它從紅測試 grep `.feature` 裡的 `# feature-id:` 找到當初的 `spec.md`，拿原本談定的 scenario 跟你報的症狀比對：**一樣就代表這不是 bug 是需求變更**，轉去走迭代，省掉整個 ④⑤；不一樣才是真 bug，而原 spec 的「驗收層」直接告訴實作者回歸測試該繫結在哪一層。查不到就往下走，**不會為了找出處多問你一輪**。同時，開新需求時不再是拿 id 去撞目錄名，改成把既有 feature 連同標題列出來讓你認。配套是兩行新格式：`spec.md` 第一行是一句**用你的話**寫的標題，`.feature` 開頭多一行 `# feature-id:` 註解。**舊檔不用手動補** —— 沒有那兩行只是回查不到，流程照跑。
5. **`project-map.md` 多一節「領域詞彙」。** 業務詞對到程式裡的名字，同義詞標「避用」。地圖裡本來只有 step 詞彙有這個待遇，而一般術語漂移的症狀一樣、只是**沒有任何測試看得見**。舊地圖不用手動改，下一次 ② 會自己補上。

**還有一件你會看到、但不用做的事**：`AGENTS.md` 與三個 agent 定義裡的「不要 X」大多改寫成「做 Y」了（四個檔加起來 95 → 13，剩下的是機械層擋得住的硬 guardrail 加幾個「要不要」的誤判）。行為沒變 —— 改的理由是禁令會把被禁的行為拉進 context，反而更容易發生。你自己那份合併過的 `AGENTS.md` 不改也照樣跑。

### 從 v4.5.1 升上來

**非破壞性** —— 流程六步、產物路徑、handoff 合約全部沒動。新增的是包版、升級與 per-agent 調校，**不用它也能照舊跑**。

升級動作：複製 `.codex/` 與 `AGENTS.md`，然後跑一次

```powershell
pwsh .codex/scripts/sdlc.ps1 install -Adopt
```

那一步不覆蓋任何東西，只是把現況記成基準線 —— **之後的升級才分得出哪些檔是你改過的**。以前的做法是「複製新目錄過去」，而它分不出來，所以每次升級都在賭你沒改過 `AGENTS.md`（但 README 從第一天就叫你去改它）。

四件事：

1. **裝跟升有指令了。** `install`／`update` 會先給你一份報告（哪些檔會變、你改過哪幾個、這一版做了什麼、是不是破壞性），確認之後才動手，改過的檔一律先備份。**`guidelines/` 一個字都不會被碰。**
2. **會提醒有新版，但不會自己升。** 一行 stderr，看過就安靜，永遠不會多問你一輪 —— 必經的確認仍然只有兩個。
3. **每個 agent 的 model 與 effort 可以分開設**，寫在 `sdlc.config.json`（**你的**，升級不覆蓋）。預設全部 `inherit` = 不釘，跟現在的行為完全一樣。想讓它幫你看一遍：`sdlc.ps1 tune`。
4. **修掉版本號分岔。** `AGENTS.md` 與 `.codex/config.toml` 的標題停在 v4.3.0，而版本檔已經是 4.5.1 —— 一個會謊報自己版本的東西，讓相容性判斷跟你的升級決定同時建立在錯的數字上。現在由 `agent-lint` 檢查 10 盯著。

### 從 v4.5 升上來

**非破壞性，只改行為不改介面** —— 流程六步、產物路徑、handoff 合約都沒動。升級動作：複製 `.codex/` 與 `.agents/`。

修的是三個**只在第二個需求才發作、而且症狀全部是靜默的**缺陷：

1. **`project-map.md` 的新鮮度以前只看 commit。** 但這套流程沒有任何一步會 commit，所以上一個需求的程式還在工作區時，`HEAD` 沒動過 → 地圖每一節都「看起來沒變」→ 整份被採信，而它是上一次 ② 結束時寫的，那時連上一個需求的實作都還沒發生。現在每節多驗一次工作區（`git status --porcelain`）。最痛的是「已建立的 step 詞彙」那一節：`implementer` 靠它跨需求沿用措辭，拿到舊的就會另造一套 —— 撞名會被測試炸出來，**措辭分岔則完全沒有人會發現**。
2. **同一張表的 DB 盤點，第二個需求會再叫你批准一次。** `evidence/db-*.md` 放在各自的 feature 目錄，而以前沒有任何一方被告知要去看**別的** feature 的。現在 ② 會自己掃 `bdd-docs/*/evidence/db-*.md`，有就直接用。這跟 v4.4 為 `legacy-schema` 修的是同一個病。
3. **兩個 kill switch 以前關掉是完全安靜的。** `bdd-docs/.dlp-disabled` 與 `guidelines/.gate-disabled` 只要還在，現在每次寫檔都會在 stderr 喊一行（不擋你）。
4. **同一塊功能再改一次，以前沒有任何規則。** 兩個訂單相關的需求很容易撞到同一個 `feature-id`，而撞上時 `spec.md` 會被沿用成上一個需求的決議，`.feature` 是覆蓋還是合併也沒人規定。現在：目錄已存在會問你一句（併進本來就要問的那次確認），迭代在 `spec.md` **新增一節** `## 迭代 N`，`.feature` **只增修這次要求的那幾條**，而「既有 scenario 被刪掉或整檔被重寫」成了 ⑤ 的**必修**項 —— 那件事刪了測試照樣全綠，沒有任何自動檢查看得見。
5. **交付時會提醒你下一個需求開新對話。** 只是一句提醒，不擋流程。

### 從 v4.4 升上來

**非破壞性，不做也能跑。** 兩件事：

**1. 團隊規範層** —— `guidelines/`（你的，升級不覆蓋）＋ `.codex/scripts/guideline-gate.ps1`。升級動作：複製 `.codex/`、`.agents/` 與 `AGENTS.md`，然後**選擇性**複製 `guidelines/` 當骨架再換成你們自己的。

沒有 `guidelines/` 就完全沒有差別 —— gate 靜默通過，agent 也不會去找。建了之後，② 排做法時會標出「這個做法違反你們的 MUST」，而寫檔後會擋下 `rules.json` 裡設成 `block` 的語法。

**2. ① 改用具體實例問缺口** —— 題數、輪數、上限 5 個都不變，只是每個選項從標籤（「能，但轉成退貨流程」）換成實例（「自動開一張退貨單，收到退貨後才退款」），門檻題改用邊界問。談定的實例會落進 `spec.md`，③ 的 Gherkin 直接拿那些值來寫。

改的是 `AGENTS.md`、`.agents/skills/requirement-gap-analysis/` 與 `.agents/skills/gherkin-authoring/`。**進行中的需求可以直接續跑** —— 舊的 `spec.md` 只是「需求決議」裡沒有實例，③ 照舊會自己補值。

順帶修掉一個潛在缺陷：`sql-scan.ps1` 對**單行檔**掃不出任何訊號（PowerShell 的 `Get-Content` 在單行檔回的是字串不是陣列，逐行迴圈於是逐**字元**在比對），症狀是安靜地少報 —— 壓成一行的 View／SP 定義正好最常見。

### 從 v4.1 升上來

`db-introspection-scanner` 這個 agent 沒了 —— 改由 orchestrator 自己查 live DB，規則搬進 skill `.agents/skills/db-introspection/`。升級動作：刪掉 `.codex/agents/db-introspection-scanner.toml`、複製新的 skill 目錄，`AGENTS.md` 一併更新。

**對你的差別**：查 DB 之前一樣要你批准，落檔位置一樣是 `bdd-docs/{feature-id}/evidence/db-*.md`，寫檔後的 DLP 掃描一樣會跑。少掉的是**工具層的隔離** —— 以前 orchestrator 根本呼叫不到 DB 工具，現在它可以，只是被規則綁著。所以 **DB 連線請務必用唯讀帳號**：這一版之後，「不能寫」要靠帳號權限保證，而不是靠流程結構。

### 從 v4.0 升上來

只有一件事要做：**把 `AGENTS.md` 複製到你的專案根目錄，並刪掉 `.codex/agents/bdd-orchestrator.toml`。** 產物格式、流程、handoff 合約都沒變，手上跑到一半的需求可以直接接著跑。

改的是 orchestrator 的**啟動方式**：v4.0 要你去 spawn `bdd-orchestrator`，但被 spawn 出來的 agent 拿不到 `agent` 工具，於是它自己委派不出去 —— ② 到 ⑤ 全部卡住，而症狀只是一句「工具不存在」。v4.1 讓最上層對話直接就是 orchestrator，沒有那個 agent 了。

### 從 v3.x 升上來

v4.0.0 是乾淨斷代，**沒有 resume 相容路徑**。移除了整層 tier（`discover`／`t0`–`t3`）、5 道 gate、run 骨架與所有 run 狀態檔，agent 由 12 併為 5。v3 寫出來的 `bdd-docs/runs/` 目錄 v4 讀不懂 —— 升級前先把手上的 run 跑完或放掉。
