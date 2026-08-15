# guidelines/ — 你們團隊的開發規範

> **這整個目錄是範例。** 裡面的每一條都請換成你們自己的 —— 它是骨架，不是建議。

不同團隊的規範不同，所以規範屬於**你的專案**，不屬於這套工作流。這也是它放在這裡、而不是放進 `AGENTS.md` 或 `.codex/agents/*.toml` 的唯一理由：

**升級只覆蓋 `.codex/`、`.agents/` 與 `AGENTS.md`。`guidelines/` 永遠不覆蓋。** 規範寫進那三個地方，下次升級會**靜默消失** —— 沒有任何錯誤訊息，只是 agent 突然不再遵守，而沒有人會發現。

「不同的開發團隊」不需要任何機制：工作流是複製到每個專案根目錄的，所以 **repo 本身就是團隊選擇器**。不用 team-id、不用切設定檔。同一團隊跨多個 repo 想共用 → 把 `guidelines/` 掛成 git submodule，零程式碼。

---

## 兩半，分法是「有沒有機械 oracle」

| | 散文（`*.md`） | 機械禁令（`rules.json`） |
|---|---|---|
| 放什麼 | 判斷題：API 該怎麼設計、分層怎麼切 | 判得出對錯的：不准用的語法、不准出現的 API |
| 誰執行 | 子代理讀進 context 後自己遵守 | `.codex/scripts/guideline-gate.ps1` 每次寫檔後自動掃 |
| 強制力 | 榮譽制 | **擋得住**（`block` 直接讓那次寫檔失敗） |
| 成本 | 每次 spawn 付一次 token | **零** |

**能搬去 `rules.json` 的就搬。** 這是你唯一的施力點：規範越機械化，每次委派越便宜，而且越擋得住。

---

## 散文那半：檔名就是路由鍵

| 檔 | 誰讀 | 什麼時候 |
|---|---|---|
| `api.md` | `sa-analyst` | 排做法時（會動到對外 API）、產契約時一律 |
| `sql.md` | `sa-analyst`、`implementer` | 動到查詢或 schema 時 |
| `coding.md` | `implementer` | 每次 `mode: build` |
| `testing.md` | `implementer` | 寫測試前 |
| 以上相關的 | `reviewer` | `mode: code`，跟 `implementer` 讀同一批 |

**沒有映射表。** 檔名直接對應，多的檔沒有人讀，少的檔就是沒有規範。這個 repo 已經因為同樣的理由砍掉過一份索引檔 —— 第二份名冊一定會跟真相走鐘。

**`orchestrator` 一個字都不讀。** 它的 context 是唯一必須活到交付的，規範進去就是在燒那份預算。

---

## 三條硬規則

### 1. 每條都要標 `## MUST` 或 `## SHOULD`

```markdown
## MUST
- 對外 endpoint 一律 `/api/v{n}/{resource}`，動詞不進 path

## SHOULD
- 列表預設每頁 20 筆
```

- **MUST** → `reviewer` 給 **[必修]**，`implementer` 做不到要回 `blocked`
- **SHOULD** → 只給 [建議]，**不得因此 FAIL**
- **沒標的一律當 SHOULD**

不標會怎樣：每一條都變成 FAIL 候選，而審核只有 3 輪 —— 3 輪全被命名意見吃掉，真正的問題沒人看。

### 2. 每檔 ≤150 行

這是**每一次** `implementer` 與 `reviewer` 委派都要付的。公司標準真的有 3000 行 → 抽出 MUST 進檔案，其餘留連結。一份要整個讀完才用得起來的規範，只是把「重讀 repo」換成「重讀規範」。

### 3. 寫「不准做什麼」，不要寫「我們的技術棧是什麼」

現況（用什麼框架、目錄怎麼擺、擴充點在哪）由 `sa-analyst` 自己查，寫進 `bdd-docs/project-map.md`。

**兩者不可混寫**：map 是**描述**（現在怎麼做），guidelines 是**規範**（規定怎麼做）。混在一起，不合規的 legacy 現況會變成標準。

---

## 機械那半：`rules.json`

```jsonc
{ "rules": [
  { "id": "sql-no-nolock",
    "applies-to": ["**/*.sql", "**/*.cs"],   // 省略 = 所有檔
    "pattern": "(?i)\\bWITH\\s*\\(\\s*NOLOCK\\s*\\)",
    "severity": "block",                      // 省略 = warn
    "message": "禁止 NOLOCK —— 會讀到未提交的資料",
    "fix": "改用 READ COMMITTED SNAPSHOT，或明確接受髒讀並寫進 spec.md" }
]}
```

- **預設 `warn`，`block` 要明確寫。** 一條寫錯的 regex 若預設阻斷，會卡死整條流程，而使用者唯一的修法是去改工具本身。
- `bdd-docs/`、`guidelines/`、`.codex/`、`.agents/`、建置產物**一律不掃**。特別是 `bdd-docs/artifacts/legacy-schema/` —— 那是從舊系統抓回來的唯讀證據，本來就滿是 NOLOCK 和 cursor，掃它只會讓 gate 每次都紅燈然後被整個關掉。
- 掃描結果**只回 rule id、檔:行、message、fix，絕不回命中的原始行**（跟 DLP 同一條安全契約）。
- 規則檔壞掉 → **不阻斷，但每次寫檔都往 stderr 喊**。靜默地「規範其實沒在生效」比擋錯更糟。

改完規則跑一次：

```powershell
pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate
```

壞掉的 regex 要在這裡就紅，不是在半夜實作到一半時才炸。

暫時全關：建一個空的 `guidelines/.gate-disabled`。

---

## 規範會刪掉做法 —— 這是它最大的作用，也最容易被忽略

`sa-analyst` 在排做法之前就會讀 `api.md` 與 `sql.md`，每個做法帶一行「規範：符合 / 違反 X，需要豁免」。

它**不會替你刪掉**違規的做法，只會標出來。因為有時候正確答案就是去要一次豁免 —— 而被默默刪掉的選項，你不會知道它存在過。

規範沒讀到的代價落在最貴的地方：做法在②被提出、你在③照著它下了不可逆的決定、④做完、⑤才發現違規 —— 而那時③回不去了。
