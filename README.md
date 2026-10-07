# CodexSDLC

給 **Codex CLI** 用的 SDLC 工作流。你說要做什麼，它會：

**問出需求漏洞 → 查你的專案、給幾個做法 → 你選 → test-first 實作 → 獨立審核 → 交付。**

bug 走另一條路：症狀清楚但重現不了時，先做出一個會紅的測試，再修。

本 repo 只有工作流的設定與腳本，沒有產品程式碼。

---

## 快速開始

### 需要

| 項目                                   | 用途                                                                                                       |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Codex                                  | CLI 或 VS Code 的 Codex 擴充都可以。兩者都會載入`.codex/hooks.json` 與 agent 定義（在 Codex 0.154 實測） |
| PowerShell 7（`pwsh`）               | 強制層的腳本靠它。沒有的話 hook 全部不會執行，而且沒有任何提示                                             |
| git，而且在啟動 Codex 的環境的 PATH 上 | ⑤ 用`git diff` 檢查既有 scenario 有沒有被刪；② 用它判斷系統地圖還準不準                                |
| 唯讀的 DB MCP server                   | 只有要查 live DB 時才需要                                                                                  |

### 1. 安裝

把 `codex-sdlc-{版本}.zip` **解壓到專案以外的地方**，再執行：

```powershell
pwsh <解壓目錄>/.codex/scripts/sdlc.ps1 install -Target C:\你的專案
```

- 加 `-WithEditor` 會順便安裝 VS Code extension。裝過一次之後，其他專案可以直接在 VS Code 的 Codex SDLC 面板按「安裝到這個工作區」。
- 不要把 zip 直接解壓到專案裡：`install` 要先看過現有的檔案才知道怎麼寫。專案已經有 `AGENTS.md` 的話，它不會覆蓋，而是放一份 `AGENTS.md.new` 讓你合併。
- 以前用手動複製裝過的，跑一次 `sdlc.ps1 install -Adopt` 把現況記成基準線（不會覆蓋任何檔），之後升級才分得出哪些檔是你改過的。

裝好後的結構：

```
你的專案/
├── .codex/ .agents/ AGENTS.md   ← 工具的，升級會覆蓋（AGENTS.md 就是 orchestrator 的指令）
├── guidelines/                  ← 你的：團隊規範（選用）
├── sdlc.config.json             ← 你的：各 agent 的 model／effort 等設定
└── bdd-docs/                    ← 流程產出的需求、分析與證據
```

你自己的東西只能放在 `guidelines/` 和 `sdlc.config.json`，其他地方升級時都會被覆蓋。

### 2. 讓 Codex 信任 hooks（必做）

Codex 不會執行沒被信任的 hooks，也不會提示你。在專案目錄開一次 `codex`：信任這個資料夾，出現「Hooks need review」時選 **Trust all and continue**。

- 沒做這一步，流程看起來照常，但強制層（`handoff-lint`、`dlp-gate`、`guideline-gate`、`build-check`）一條都不會擋。
- 信任記在你的 `~/.codex/config.toml`。換機器、搬專案目錄，或升級改到 `hooks.json` 之後，都要再信任一次。
- 只用 VS Code 的 Codex 擴充時，一樣在專案目錄的終端機開一次 `codex` 完成這一步（兩者共用同一份信任紀錄）。

### 3. 檢查

```powershell
pwsh .codex/scripts/sdlc.ps1 doctor                   # 設定、工具檔、這台機器上的工具
pwsh .codex/scripts/sdlc.ps1 doctor -CheckHookTrust   # 另外問 Codex hooks 信任了沒（最久 15 秒）
```

- doctor 會檢查這台機器上的 git、Codex 的版本，以及專案用得到的 .NET SDK（照 `global.json`）、JDK、Maven／Gradle（專案有 `mvnw`／`gradlew` 就算有）。它只告訴你缺什麼、去哪裡裝，不會替你裝。
- **doctor 全綠不代表 hooks 已被信任。** 那一項預設不查，要加 `-CheckHookTrust`。PATH 上沒有 `codex` 時，再加 `-CodexPath <codex 的完整路徑>`。

### 4. 開始用

在專案裡開 Codex，直接說要做什麼：

> 我要讓客戶可以取消訂單

一句話就夠，不用挑 agent，也不用打指令。

---

## 流程

| 步驟    | 做什麼                                  | 誰做                     | 產出                                         |
| ------- | --------------------------------------- | ------------------------ | -------------------------------------------- |
| ① 需求 | 找出你沒說、而它不能替你決定的缺口      | orchestrator（不查專案） | `spec.md`                                  |
| ② 分析 | 查規格、repo、schema，給 2–4 個做法    | `sa-analyst`           | 系統地圖`project-map.md`                   |
| ③ 定案 | 你選做法、確認驗收條件（Gherkin）       | 你 ＋ orchestrator       | `spec.md` 補齊                             |
| ④ 實作 | test-first 寫到綠                       | `implementer`          | `.feature`、step definitions、程式碼與測試 |
| ⑤ 審核 | 在獨立的 context 審一遍；沒過就回 ④ 修 | `reviewer`             | PASS／FAIL                                   |
| ⑥ 交付 | 回報改了什麼、怎麼驗的、還有什麼風險    | orchestrator             | —                                           |

- ② 的每個做法都會列出：動到哪些檔、風險、工作量，以及影響（會不會動到既有資料、有沒有外部消費者）。
- 能跳過的步驟會跳過：純技術改動（重構、升套件、重現步驟明確的 bug）通常沒有 ①；小到「一個 commit 就能還原、也沒有要驗收的行為」的改動，它會直接改完。

### 你只會在這三個地方被問

| 時機        | 什麼時候會問                                                 | 你要做的                                                                      |
| ----------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| ① 需求缺口 | 有缺口才問；最多 5 題，一次問完                              | 每題都附建議，只改你不同意的，或回「都照建議」                                |
| ③ 定案     | 一定會問                                                     | 選做法、看一眼驗收條件。這些 Given／When／Then 會原封不動變成 QA 的自動化測試 |
| ⑥ 交付前   | 只在動到既有資料或線上流量，或改到 QA 已經在用的 step 措辭時 | 決定要不要放行                                                                |

另外，跑 smoke test、啟動 Web／API、連外部 DB 之前一定會先問你。覺得問太多，就說「後面照建議做」。

### ① 怎麼問

- 缺口會寫成具體的例子，不用抽象的選項：「8/10 出貨、8/12 按取消 —— 會發生什麼？」。有門檻的題目用邊界問：「16:59 可以嗎？17:01 呢？」。
- 例子裡的日期和金額是假設的，只為了把話講清楚。需要只有你知道的事實時，它會直接問。
- 你確認過的數字會寫進 `spec.md`，③ 的 Gherkin 照抄這些值，最後就是 QA 測試裡的數字。
- 要改答案，直接改那個例子最準，例如「1 選 b，但退款是開退貨單當下就退」。
- 這些缺口是靠一般業務常識推出來的；保險、醫療、法規這類專門領域可能不準，看到不對就直接糾正。

### 例子

```
你 ▸ 我要讓客戶可以取消訂單

▸ 有 3 個地方你還沒說（日期與金額是我假設的）：
  1. 訂單 8/10 出貨，客戶 8/12 按「取消」—— 會發生什麼？
     a) 擋下，提示「已出貨，請改走退貨」   ★ 建議：最簡單，不需要現成的退貨流程
     b) 自動開退貨單，收到退貨後才退款
     c) 進客服待審清單，核准後才退款
  2. 已付款 1,200 元的訂單被取消 —— 這筆錢怎麼處理？ …
  3. 訂單裡的 2 件商品，取消後庫存怎麼算？ …

你 ▸ 都照建議
```

```
▸ 選 A 的話，驗收條件如下（會原封不動變成 QA 的自動化測試）：

  Feature: 取消訂單
    Scenario: 已出貨的訂單不可取消
      Given 訂單 #1001 已於 8/10 出貨
      When 客戶於 8/12 送出取消要求
      Then 系統拒絕並回覆「已出貨，請改走退貨」
      And 訂單狀態維持「已出貨」

  驗收層：OrderService.Cancel（application service）
  ⚠️ 這個做法會動到既有資料（Order 多一個狀態值）

  1. 確認，開始實作   2. 改驗收條件   3. 換做法 B   4. ✏️ 自行輸入…
```

「驗收層」指定測試要繫結在哪個介面上。這在 ② 選做法時就已經決定了，列出來是讓實作照著做 —— 測試繫結錯層，是「測試全綠、功能卻是壞的」最常見的原因。

### bug：症狀清楚，但重現不了

遇到偶發、只在某個環境、或只有某筆資料會壞的 bug，流程改成：

| 步驟   | 改成                                                                                                                                |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| ①     | 跳過                                                                                                                                |
| ②′   | 先做出一個會紅的測試，紅在你回報的症狀上                                                                                            |
| ②″   | 從那個紅測試回查，當初是哪份需求做的（不會問你；查不到就繼續）                                                                      |
| ③     | 問你「它紅的，是不是你講的那件事？」。查到原需求的話，也會比對「是不是原本就這樣定的」—— 是的話，這是需求變更而不是 bug，改走迭代 |
| ④⑤⑥ | 不變；那個測試轉綠就是修好了                                                                                                        |

做不出重現時，它會回來問你缺什麼（哪一天的資料、哪個環境）。如果是「正確行為還沒定」（四捨五入怎麼算、跨時區算哪一天），那不算 bug，會照 ① 問你。

### 常見情境

| 你想做的事                | 怎麼說                             | 它會怎麼做                                                                 |
| ------------------------- | ---------------------------------- | -------------------------------------------------------------------------- |
| 改字、改設定、修 typo     | 直接說                             | 直接改完，不跑流程                                                         |
| 新功能                    | 一句話說目的                       | ①→⑥ 全跑                                                                |
| 需求已經想清楚了          | 「需求已定，直接看怎麼做」         | 從 ② 開始                                                                 |
| 只想知道有哪些做法        | 「先不要做，只給選項」             | 跑到 ② 就停                                                               |
| 一次要做好幾個行為        | 直接說                             | ④ 會拆成一次做一個可以獨立驗收的行為                                      |
| 舊系統，邏輯藏在 SP／View | 「這塊邏輯在 DB 裡，要逆推」       | 先問你 schema 從哪裡來；連 DB 前要你批准                                   |
| 剛做完的功能要再改        | 「剛剛的取消訂單，再加上部分退款」 | 問你這是同一塊功能的迭代還是新需求；迭代會在原本的`spec.md` 新增一節     |
| 做下一個需求              | **開新對話**再說             | 需要的東西都在檔案裡，新對話接得上；同一個對話拉太長，會擠掉 ① 談定的內容 |

隨時可以插話：「用做法 B」、「這條驗收條件改成…」、「我們的專案這塊不是這樣」、「停」（已經寫好的 `spec.md` 會留著）。

---

## 產出的檔案

| 位置                                       | 內容                                                           | 什麼時候寫                                         |
| ------------------------------------------ | -------------------------------------------------------------- | -------------------------------------------------- |
| `bdd-docs/{feature-id}/spec.md`          | 需求決議、選定的做法、驗收條件（Gherkin）                      | ① 有缺口時先建立，③ 補齊（沒有缺口就在 ③ 建立） |
| `bdd-docs/{feature-id}/evidence/db-*.md` | live DB 的盤點結果（已遮蔽敏感資料）                           | 每次經你批准查 DB 之後                             |
| `bdd-docs/{feature-id}/analysis.md`      | ② 沒做完時的中間分析                                          | 只在 ② 中斷時                                     |
| `bdd-docs/{feature-id}/contract/`        | API、事件或 schema 的契約                                      | 只在有外部消費者或要改 schema 時                   |
| `bdd-docs/project-map.md`                | 系統地圖：模組、擴充點、資料存取、已建立的 step 詞彙、領域詞彙 | 每次 ② 結束                                       |
| `bdd-docs/artifacts/legacy-schema/*.sql` | 舊系統 View／SP 的 definition，用來逆推業務規則                | 只在需要逆推 DB 邏輯、而且經你批准後               |
| 專案的測試樹                               | `.feature`、step definitions、程式碼與測試                   | ④                                                 |

- `feature-id` 是它從需求取的英文短名（例如 `cancel-order`），你可以改。每次開新需求，它會先列出已有的 feature 讓你確認；同一塊功能再改一次時，會接在原本的 `spec.md` 新增一節，不會覆蓋。
- `.feature` 會跟你的單元測試放在一起。C# 用 Reqnroll、Java 用 Cucumber；專案已經在用別的框架就沿用。開頭那行 `# feature-id:` 註解是回查原需求的線索，不要刪。
- **修改既有 step 的措辭屬於破壞性變更**，因為 QA 的自動化綁在那些文字上。交付前它會列出新舊措辭，讓你轉達給 QA。
- `project-map.md` 的「領域詞彙」記錄業務用語對應到程式裡的名字。跟你們團隊的講法不一樣時，直接告訴它改。
- `evidence/` 之後的需求還會用到，不會再要你批准一次，所以不要刪。DB 連線請用唯讀帳號 —— 流程規定不執行 DDL／DML，但真正的保證來自帳號權限。
- **每做完一個功能就 commit 一次。** `project-map.md` 靠 commit 判斷哪些地方變過；不 commit 的話，下一個需求會比較慢，也比較不準。
- `bdd-docs/.cache/` 是腳本的索引快取，可以隨時刪除；`bdd-docs/.sdlc/` 存放升級用的基準線與備份，不要刪。
- 對話中斷了就開新對話。`spec.md`、`evidence/`、`analysis.md` 都還在，不必從頭來；只有沒有 `spec.md` 時才要從 ① 重來。

---

## 設定

設定寫在專案根目錄的 `sdlc.config.json`：

| 設定                     | 預設        | 說明                                                                                                                                                 |
| ------------------------ | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `agents.<名稱>.model`  | `inherit` | `inherit` 表示不指定，交給 Codex 決定                                                                                                              |
| `agents.<名稱>.effort` | `inherit` | 可填`low`、`medium`、`high`、`xhigh`、`max`、`ultra`。`max`、`ultra` 只有較新的模型支援；Codex 不會檢查，填錯要到呼叫 API 時才會出錯 |
| `review.maxRounds`     | `3`       | ⑤ 最多修幾輪（1–5）；到了上限，它會交回你決定                                                                                                      |
| `update.check`         | `daily`   | 改成`never` 就不檢查新版                                                                                                                           |
| `update.source`        | 安裝時帶入  | 檢查新版用的 GitHub repo 網址                                                                                                                        |

用 `set` 修改。它會先驗證所有的值才寫入，打錯時會提示最接近的值：

```powershell
pwsh .codex/scripts/sdlc.ps1 set agents.reviewer.effort=high review.maxRounds=4 -Apply
pwsh .codex/scripts/sdlc.ps1 set -Preset balanced            # 一次換成 fast／balanced／deep 其中一組
pwsh .codex/scripts/sdlc.ps1 tune                            # 依 repo 規模等訊號提議一組值，不會自動套用
pwsh .codex/scripts/sdlc.ps1 tune -ApplyProposal -Only reviewer
```

- 改了 `agents.*` 要套用才會生效（加 `-Apply`，或跑 `sdlc.ps1 apply`）；忘記套用的話，`agent-lint` 會擋下來。`review.*` 和 `update.*` 不必套用。
- 也可以直接編輯這個檔：第一行的 `$schema` 讓編輯器有自動完成和錯字提示，改完記得跑 `sdlc.ps1 apply`。
- 這個檔不支援註解（`set`、`update` 會整份重寫），說明請寫在 `_note`。沒有這個檔也沒關係，等於全部用預設值；第一次 `set` 會自動建立。
- effort 預設不指定是刻意的：曾經把全部 agent 釘成 `high`，結果大型舊專案的分析逾時。`tune` 通常只建議調高 `reviewer`，repo 越大，`sa-analyst` 反而越調低。
- `orchestrator` 那一格只是紀錄。orchestrator 就是最上層的對話，要在啟動 Codex 時自己指定（`install`、`doctor` 會印出對應的指令）。

---

## 團隊規範

團隊規範放在 `guidelines/`。這是選用的，沒有這個目錄流程照跑。它跟著專案走；同一個團隊要在多個 repo 共用，可以用 git submodule 掛進來。

```
guidelines/
├── api.md       ← sa-analyst 會讀
├── sql.md       ← sa-analyst、implementer 會讀
├── coding.md    ← implementer 會讀
├── testing.md   ← implementer 會讀
└── rules.json   ← 每次寫檔後由 guideline-gate 掃描；agent 不讀
```

- `*.md` 寫需要判斷的規範（命名、分層、錯誤格式），每條放在 `## MUST` 或 `## SHOULD` 底下。違反 MUST，審核會判為必修；SHOULD 只是建議；沒標的一律當 SHOULD。每個檔建議控制在 150 行以內。
- `rules.json` 寫機器判得出對錯的規則（禁用語法、禁用 API）。`severity: block` 的規則會直接擋下那次寫檔。能寫成規則的盡量寫進這裡：不花 token，而且擋得住。
- 違反 MUST 的做法不會被悄悄刪掉。② 會標註「需要豁免」，讓你決定。
- 改完規則先驗證：`pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate`。
- 要暫時關閉規則檢查，建立空檔 `guidelines/.gate-disabled`；DLP 掃描則是 `bdd-docs/.dlp-disabled`。關閉期間每次寫檔都會提醒一行，用完記得刪掉。

---

## VS Code extension（選用）

發佈包附了一個 VS Code extension。它能做的事，在終端機用 `sdlc.ps1` 都做得到；它的好處是讓狀態一眼看得到，改設定也不用記指令。

| 位置                      | 功能                                                                                                                                                            |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 活動列的 Codex SDLC 圖示  | 還沒安裝工作流的資料夾：「安裝到這個工作區」（離線也能裝）。已安裝的：設定面板，可以改值、套用、補回工具檔、合併`AGENTS.md.new`、換預設組合、採用 tune 的建議 |
| 狀態列左下角的 SDLC       | 版本、還沒套用的設定、缺少的工具檔與工具、有沒有新版                                                                                                            |
| Problems 面板             | 違反`rules.json` 的地方、`bdd-docs/` 裡殘留的敏感資料、`rules.json` 本身寫錯的地方                                                                        |
| `sdlc.config.json` 上方 | 「套用」，以及 tune 建議的「採用」                                                                                                                              |

- 安裝：`install` 時加 `-WithEditor`，或執行 `code --install-extension <解壓目錄>/editor/codex-sdlc-{版本}.vsix`（Cursor、Windsurf、VSCodium 也用同一個檔）。需要 PowerShell 7。
- 移除：`code --uninstall-extension codex-sdlc.codex-sdlc`。它裝在整台機器上、所有專案共用，刪掉專案不會一起移除。
- **狀態列的綠勾不代表 hooks 已被 Codex 信任。** 要確認，得在終端機跑 `doctor -CheckHookTrust`。VS Code 的「工作區信任」只決定 extension 會不會啟動，跟 Codex 的 hooks 信任是兩回事。

---

## 升級

有新版時，委派子代理前的 hook 會多帶一行通知（`[sdlc] 有新版 …`）。它不會擋你，也不會自動升級。要手動檢查用 `sdlc.ps1 check-update`，看變更內容用 `sdlc.ps1 whatsnew`；裝了 extension 的話，它每天會在背景檢查一次。

升級時，把新版 zip 解壓到別處，再執行：

```powershell
pwsh <新版解壓目錄>/.codex/scripts/sdlc.ps1 update -Target C:\你的專案
```

- 動手之前會先列出：哪些檔會被覆蓋、哪些是你改過的（會先備份到 `bdd-docs/.sdlc/backup-{舊版}/`）、哪些檔這一版刪掉了、是不是破壞性升級。你確認後才會寫入。
- `guidelines/` 完全不會動；`sdlc.config.json` 只會補上新版需要的欄位（有註解的話會先備份）。升級完會自動重跑一次 `apply`。
- 升級有改到 `hooks.json` 的話，要再到 Codex 裡信任一次。
- `update` 不會重裝 VS Code extension；版本對不上時會提示你。
- 各版的變更與升級注意事項見 [CHANGELOG.md](CHANGELOG.md)。
- 檢查新版需要 `update.source` 指向這套工作流的 GitHub repo（`sdlc.ps1 set update.source=https://github.com/<owner>/<repo>`）。查不到時一律不出聲，不影響流程。

---

## 疑難排解

| 現象                                                         | 原因                                                | 處理                                                                                                                                 |
| ------------------------------------------------------------ | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 寫了違規的檔、委派沒帶必要欄位，全都照樣通過，也沒有任何訊息 | Codex 沒信任這個專案的 hooks                        | 跑`doctor -CheckHookTrust`，照提示到 Codex 裡信任                                                                                  |
| doctor 全綠，卻沒有任何東西在擋                              | doctor 預設不檢查 hooks 信任                        | 同上                                                                                                                                 |
| `doctor -CheckHookTrust` 說「無法確認」                    | 找不到`codex`，或 15 秒內沒有回應；不代表沒有信任 | 加`-CodexPath <完整路徑>`，或再跑一次                                                                                              |
| doctor 說`.codex/hooks.json` 不在                          | 工具檔缺了，四支 hook 都不會執行                    | 在 VS Code 面板按「補回工具檔」，或用發佈包跑`update -Target <專案>`；之後重新信任                                                 |
| doctor 說找不到 git                                          | ⑤ 和 ② 各少一道檢查                               | 安裝 git。已經裝了但不在 PATH 上的（例如 GitHub Desktop 或 Visual Studio 內附的），把它的`cmd` 目錄加進 PATH，再重開終端機與 Codex |
| doctor 說 Codex 比實測版本舊                                 | 在舊版 Codex 上，hook 可能完全擋不住                | 升級 Codex（比實測版本新不會提示）                                                                                                   |
| doctor 說 .NET SDK 版本對不上                                | 專案`global.json` 指定的 SDK 不在這台機器上       | 安裝那一版 SDK；不要為了遷就這台機器去改`global.json`                                                                              |
| doctor 說找不到 Maven、Gradle 或 JDK                         | ④ 的 build／test 會跑不起來                        | 專案有`mvnw`／`gradlew` 就不必裝全域的版本；JDK 一定要裝，並設好 `JAVA_HOME`                                                   |
| 委派被擋：`missing-spec-ref`                               | 要實作或審核，但還沒有`spec.md`                   | 先完成 ③                                                                                                                            |
| 委派被擋：`review-loop-exceeded`                           | 修正輪數超過上限                                    | 它會交回你選：接受目前版本、指定重點再跑一輪，或暫停                                                                                 |
| 委派被擋：`handoff-too-long`                               | 委派內容超過 1200 字元                              | 讓它改傳檔案路徑，不要貼全文                                                                                                         |
| 委派被擋：`connection-string`／`secret-literal`          | prompt 裡有連線字串或密鑰                           | 不要繞過，把敏感值從來源移除                                                                                                         |
| 寫進`bdd-docs/` 被擋：殘留敏感資料                         | 寫出的內容含 email、連線字串之類的資料              | 遮蔽後再寫。確定整個專案都沒有敏感資料，才建`bdd-docs/.dlp-disabled`                                                               |
| 寫檔被擋：`[Hook][Guideline]`                              | 違反`rules.json` 裡 `block` 等級的規則          | 照著改；或把規則降成`warn`、建 `guidelines/.gate-disabled`                                                                       |
| 跑很久之後逾時                                               | 這次的範圍太大                                      | 選「縮小範圍再跑一次」，單純重試的結果會一樣                                                                                         |
| `set` 說設定檔裡有註解，沒有寫入                           | `sdlc.config.json` 不支援註解                     | 把說明移到`_note`；或加 `-Yes`（原檔會先備份）                                                                                   |
| `set` 說「不是合法值」或「不認得的設定」                   | 值或 key 打錯了，整批都沒有寫入                     | 照提示的建議值修正                                                                                                                   |
| VS Code 裡看不到任何 Codex SDLC 介面                         | extension 沒裝，或開的資料夾不對、工作區沒被信任    | doctor 會告訴你有沒有裝；裝好之後執行`Developer: Reload Window`                                                                    |
