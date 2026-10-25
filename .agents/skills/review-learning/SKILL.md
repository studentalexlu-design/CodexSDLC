---
name: review-learning
version: 1.0.0
description: "Use when: 使用者要把審核（⑤）一再抓到的問題變成團隊規範（「把審核常抓到的問題整理成規範」「reviewer 一直抓同一種錯」「從 review 學規則」）。讀 sdlc.ps1 learn → 歸類 → 起草 rules.json／guidelines/*.md → 使用者確認 → 才寫。"
---

# 把一再被抓的錯，往前移成規範

⑤ 抓到一個錯，只讓**這個**需求多跑一輪修正；下一個需求還是可能犯同一個。同一類錯在**不同需求**裡被抓第二次，就往前移：

- **判得出對錯的**（不准出現的語法、API、寫法）→ `guidelines/rules.json`。寫檔當下 `guideline-gate` 就擋，不必等到 ⑤，也不用付 token。
- **要判斷的**（設計、分層、測試怎麼寫才算有測到）→ `guidelines/*.md` 的 `## MUST` 或 `## SHOULD`。`implementer` 動手前讀到，`reviewer` 拿同一批審。

這不是 ①～⑥ 流程的一部分，是使用者叫你做才做。**規範是團隊的：起草可以，寫進去要他點頭。**

## 1. 拿清單

```
pwsh .codex/scripts/sdlc.ps1 learn -Json
```

讀 `data.learn`：

- `findings[]`：`feature`、`severity`（必修｜建議）、`location`、`file`、`problem`、`failure`（會怎麼壞）、`rounds`（同一需求裡出現在幾輪）。同一需求內已去重。
- `features[]`：`snapshots` 是 0 的需求只剩最後一輪 —— 已經修掉的 [必修] 看不到，那幾個需求的「沒出現」不代表沒犯過。
- `guidelines.files`、`guidelines.ruleIds`：已經有的規範檔與規則 id。

`counts.features` 小於 2 → 跟使用者說「需求還太少，看不出哪些是一再出現的」，列出現有的 [必修] 就停。

## 2. 歸類

把 `findings` 依**問題的本質**分組，不是依措辭或檔名：「斷言只檢查不丟例外」與「測試沒有 assert」是同一類；「同一個檔被抓兩次」不一定是同一類。

只留**出現在 2 個以上需求**的類別。只在一個需求裡、多輪都被抓的，是那次實作的問題，不是規範缺了 —— 不提。

每一類先查兩件事，有一件成立就**不提新規範**，改成跟使用者說明：

- **已經有規範了**（`guidelines/*.md` 裡寫了、或 `ruleIds` 有一條在管）→ 規範在，但沒擋住。是規則的 pattern 漏了寫法，還是那條是 SHOULD 該升成 MUST？提的是**修改那一條**。
- **是這套工作流本身的檢查**（step 措辭被改、`.feature` 沒逐字照抄、`spec.md` 範圍外的改動）→ 那些已經有 `gherkin-check`、`handoff-lint` 與 reviewer 的固定檢查在管，不是團隊規範的事。

## 3. 起草

**能寫成 `rules.json` 就寫成 `rules.json`** —— 判準：一個 regex 判得出「出現就一定錯」。判不出來（要看上下文、要讀懂語意）就寫成 `.md` 的一條。

`rules.json` 的一條（欄位見 `.codex/bdd-workflow/rules.schema.json`）：

- `id`：kebab-case，不跟 `ruleIds` 撞名。
- `applies-to`：只列這類錯會出現的副檔名。
- `severity`：先給 `warn`。`block` 會讓那次寫檔直接失敗 —— 只有使用者明講要擋才用。
- `message` 寫「為什麼錯」，`fix` 寫「改成什麼」。

**驗兩次，都要做：**

1. 規則檔本身：把草稿寫進一個暫存檔（不是 `guidelines/rules.json`），跑
   `pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate -RulesFile <暫存檔>`，要 exit 0。
2. 誤判：拿暫存檔掃一次這類錯會出現的現有程式碼，
   `pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -RulesFile <暫存檔> -Path <檔...> -Json`。
   當初被抓的那幾處多半已經修掉，所以**命中的每一處不是既有的違規就是誤判** —— 逐一看，誤判就改 pattern 重驗。既有的違規照實列給使用者，不要順手改。

驗完刪掉暫存檔。

`.md` 的一條：

- 放進讀者對得上的檔 —— `coding.md`（實作）、`testing.md`（測試）、`sql.md`（查詢或 schema）、`api.md`（對外 API）。**不要新開檔名**：沒有 agent 讀的檔不會生效，而且完全靜默。檔不存在就提議建那個檔名。
- 一行，祈使句，寫得出「違反了會怎麼壞」。預設放 `## SHOULD`；放 `## MUST` 等於讓 reviewer 把它判成必修、佔掉修正輪，要使用者選。
- 每份 `.md` 有 150 行上限（檔頭寫的），加之前先數。

## 4. 問使用者

用 `Codex user confirmation`，一類一題，**每題帶題號，每個選項帶編號**。題目寫清楚：

- 這一類是什麼、在哪幾個需求出現過（`feature` ＋ `location`，各一行，最多 3 個例子）、`failure` 那一句
- 你的草稿（`rules.json` 的那一條，或 `.md` 的那一行與要放的檔、MUST 或 SHOULD）
- 誤判掃描的結果（命中幾處、是什麼）

選項：

1. 照草稿寫進去
2. 寫進去，但改成 {另一個 severity，或 MUST↔SHOULD}
3. 不要，這不是規範的事
4. ✏️ 自行輸入…

一輪最多 5 題，超過的先列標題，問他要不要下一輪。

## 5. 寫

只寫他選了 1 或 2 的。寫進 `guidelines/rules.json`（沒有就新建，帶 `"$schema": "../.codex/bdd-workflow/rules.schema.json"`）或那份 `.md`。寫完：

```
pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate
pwsh -NoProfile -File .codex/scripts/agent-lint.ps1
```

都要 exit 0。最後跟他說哪幾條進了哪個檔，以及：規範只對**之後**的寫檔與委派生效；`guidelines/` 升級時不會被覆蓋，用 submodule 共用的話要另外 commit 到那個 repo。

## 不要

- **不要寫進 `.codex/`、`.agents/` 或 `AGENTS.md`** —— 那三處升級時被覆蓋，規範會靜默消失。
- 不要沒經他確認就寫，也不要把「既有的違規」順手修掉。
- 不要從單一需求、單一發現推出規範。
- 不要編例子：題目裡的每個例子都要是 `findings` 裡真的有的那一項。
