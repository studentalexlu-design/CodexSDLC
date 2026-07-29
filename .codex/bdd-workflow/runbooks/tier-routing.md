# Runbook: Tier Routing（兩軸分流）

對應 `workflow-contract.json` 的 `route-assessment` stage 與 `route-profiles.json`。

> **本檔不在 `route-assessment` 讀取。** 判定程序（Step 1 未知度 / Step 2 不可逆性 / Step 3 修正因子）
> 與 tier 表已內建於 `bdd-orchestrator` 指令檔 —— 那是每個 run 都要做的無條件判斷。
> **一次執行期讀取的真正成本是它多花的那一輪**：在長對話裡等於重送整份歷史，而非檔案大小。
> 內建在有 cache 的系統提示裡，比每個 run 付一次未快取讀取加一輪往返便宜得多。
>
> 本檔只在**條件成立時**讀：tier 升降程序、某個 tier 的細部流程、掃描成本細節、與舊 profile 的對照。

## 兩軸模型

分流砍的是流程稅，不是 BDD 本身。**所有交付 tier（`t1`–`t3`）都保留 Gherkin 與 Outside-In TDD 骨幹**；`t0` 以一行 DoD 取代 Gherkin，因為對行為等價的改動寫 Given-When-Then 是純儀式成本。

| 軸 | 問的是 | 高的時候要的是 | 由什麼吸收 |
|---|---|---|---|
| **不可逆性** | 錯了要付多少代價才能回頭 | 閘門與批准 | 交付 tier `t0`→`t3` |
| **未知度** | 開工前我不知道什麼 | 探索與澄清 | 獨立的 `probe`／`spike` run |

這兩件事**可以各自獨立出現**，藥方不同：

- 有完整 DDL 的 DB migration = 高不可逆 + **低未知** → 要一堆閘門，幾乎不需探索
- 在 sandbox 摸清黑箱套件怎麼用 = **低不可逆** + 高未知 → 要一堆探索，幾乎不需閘門

**單軸「複雜度」分流會強迫你兩種保險一起買。** 這是 v2.0.0 改掉的核心問題。

### 不進入 tier 判定的三件事

| 因子 | 為什麼不是 tier | 怎麼處理 |
|---|---|---|
| **規模** | 20 個一模一樣的 CRUD 是大工作量、低風險、低未知度；一個 500 檔的 rename 不需要設計審查 | 以**行為數 N**（不是檔案數）計；N > 10 → 拆多個 run，深度不變 |
| **敏感資料** | 「在 log 遮罩一個信用卡號」不該因為碰到個資就走完整重構流程 | 橫切約束 **P**：全程 DLP 脫敏 + 殘留掃描，不抬 tier |
| **驗證受限** | 驗證方式改變的是證據形式，不是回頭的代價 | 因子 **V**：`prod-only` 讓交付閘門必須分階段 |

> 檔案數是壞度量：一次 rename 改 50 檔、一次演算法改寫改 1 檔。**行為數**（可寫成獨立 Given-When-Then 的行為）才與風險相關。

---

## 探索 run：`probe` / `spike`

**唯一定義在 `bdd-orchestrator` 指令檔的「路由判定」段。** 此處不複製判定條件 ——
未被機械強制的重複正是本 repo 反覆出過的漏洞（同目錄 `cache-metrics.md` 曾把上限寫錯）。

### 為什麼探索要獨立成 run，而不是抬高交付 tier

舊模型「不確定 → 走最貴路徑」有兩層浪費：

1. **付錯的錢**：為了查清一件事，付出完整交付流程的 spawn 預算與 Gate 數。
2. **付重複的錢**（更貴）：探索過程留在交付 run 的 context 裡，在**之後每一輪重送**。一段 30k 的探索歷史在後續 30 輪裡就是 30k × 30 的 token-turn 租金。

探索 run 把這兩層都消掉：≤2–3 次委派、結束即**丟棄 transcript**，只留 ≤2000 字元的 `probe-findings.md`。交付 run 從乾淨 context 起跑。

### 交接規則

- 唯一交接產物：`bdd-docs/runs/{run-id}/artifacts/probe-findings.md`，套版 `templates/probe-findings.md`，**硬上限 2000 字元**。
- 超出上限**不得壓縮字句** —— 那代表探索範圍過寬。二選一：拆成多個 probe run；或只留「足以判定 tier 與 N」的粒度，細節留在原始 artifact 由交付 run 按需讀。
- `gate-probe` 核准後**必須結束該 run**，建議項固定為「結案並在新對話開交付 run」且排第一。
- 交付 run 起跑只讀 `probe-findings.md`，**不讀探索 run 的 `log.md` 或 checkpoint**。
- 探索 run **不得碰 production code**。`spike` 的程式寫在 `bdd-docs/runs/{run-id}/spike/`，Gate 核准時丟棄。
- `handoff-lint` 機械阻斷探索 tier 掛交付型 mode（`slice`／`skeleton`／`feature`／`contract`／`migration`／`all`／`review` 等）。

### probe vs spike

| | `probe`（讀） | `spike`（寫，丟棄） |
|---|---|---|
| 產出 | 事實：現況地圖、schema、相依、bug 重現步驟、legacy 邏輯 | 結論：可行性、效能量級、黑箱行為 |
| 委派上限 | 2 | 3（多 1 次給 build／run 循環） |
| 啟用 agent | `project-scanner`(`probe`)、`db-introspection-scanner`、`analyst`(`glossary`／`sql-logic-extraction`) | `tdd-implementer`(`spike`) |
| 程式碼 | 不寫 | 寫在 `spike/`，Gate 後丟棄 |

> 探測超過 2 次委派代表它不是探測、是交付。停下來改開交付 run。

---

## `t0`：直通（**0 次委派**）

**適用**：改動可單一 commit revert、無對外可見差異、無狀態變更。文案、log level、既有欄位補回既有 response、加測試。

**驗收語言**：一行 DoD，**不寫 Gherkin**。

**流程**：`intake` → `route-assessment` → `implement` → `close`（`gate-close`）

**0 次委派是刻意的。** spawn 的固定成本是 4–8k tokens；`t0` 的整個 diff 通常比一次 spawn 的框架開銷還小。orchestrator 自行：讀索引取專案輪廓 → `impact-scope.ps1` 產 safe-change envelope → 實作 → 跑相關測試 → 寫 checklist 與 log。

`route-profiles.json` 的 `t0.max-subagent-calls = 0`，因此 **`handoff-lint` 會擋下 `t0` 的任何 spawn** —— 這是機械保證，不是自律。

**升級條件（任一命中即停止自行實作）**：diff 超出單一 commit 可 revert 範圍｜出現需驗收的行為變更｜需要任何 spawn。

> `t0` 是唯一放寬 orchestrator 產物寫入邊界的地方。doer/orchestrator 分離買的是高風險改動的可稽核性，而 `t0` 的定義就是「這個保證不適用的那一類」。

---

## `t1`：內含（≤5 次委派）

**適用**：改動限於我控制的邊界內、不改對外契約、不動既有資料。內部 service method、只給自家前端的 endpoint、既有 flow 加業務分支。

**流程**：`intake` → `route-assessment` → `scan` → `formulate` → `atdd` → `tdd` → `verify` → `close`（`gate-close`）

**agent**：`formulator`、`atdd-automator`、`tdd-implementer`
**reviewer**：**只有 1 次** —— `spec-reviewer`(`mode: gherkin`) 於 Gherkin 定稿後。

**為什麼審 spec 不審 code**：code 品質由測試綠燈把關；**驗收條件錯了，測試會忠實地驗證錯的東西** —— 那是測試抓不到的缺陷類別。TDD 後不跑 `code-reviewer`，改由 `gate-close` 的使用者確認檢視 diff 範圍、測試覆蓋與 minimal-implementation。

**預算為何是 5**：`formulator` + `atdd-automator` + `tdd-implementer` + `spec-reviewer` = 4，**留 1 次給修正輪**。舊模型的 `standard` 給 10 次卻在零修正輪時就用滿 —— 預算必須留修正空間，否則 hook 會在最不該擋的時候擋下。

**envelope**：由 orchestrator 以 `impact-scope.ps1` 候選清單產生（候選 = `editable-paths`，其餘 `forbidden`），納入 `gate-close`；使用者核准 Gate 即等於核准 envelope。

**不執行**：`design-modeler`、`code-reviewer`、`integration-tester`、`living-doc`、context-pack、資料建模。

---

## `t2`：契約（≤9 次委派）

**適用**：對外 API、事件 schema、共用 library 介面、CLI 參數、給外部查的 view。新增尚無寫入者的 table、新增 nullable 欄位。

**方向性**：只約束「**我提供**契約給別人」。**消費別人的契約是 `t1`** —— 消費端改錯只有自己壞，提供端改錯是別人壞。

**流程**：`…formulate` → `contract` → `contract-review` → **`gate-contract`** → `atdd` → `tdd` → `integration` → `gate-close`

**Gate 順序是硬性不變條件**：`gate-contract` 必須在**任何 production 實作之前**。這是唯一能省下重工的位置 —— 契約定案後才寫的實作，錯了只要改實作；實作後才定案的契約，錯了要同時改實作、測試與已經看過它的下游。核准前 orchestrator 不得委派 `atdd-automator`／`tdd-implementer`。

**合併呼叫**：
- `design-modeler`：**只有 `mode: contract`**。`sequence`／`module`／`traceability` 在 `t2` 不產出 —— 它們是設計文件而非契約，換不到任何驗證價值。
- `integration-tester`：單次 `mode: all`（contract／integration／smoke 共用同一次 build，分開呼叫會 build 3 次）。
- `analyst`：`example-map` 一次處理整張 map（不切 story）。

**reviewer**：`spec-reviewer`(`design`) 於 `gate-contract` 前 + `code-reviewer`(`tdd`)。契約必須由人審 —— 「契約設計得不好」是測試抓不到的缺陷類別。

**升級條件**：相容性判定為 `breaking`（移除欄位／改型別／改簽章）｜會動到既有資料、在跑的流量或認證授權｜消費者無法協調同步升級 → 全部升 `t3`。

---

## `t3`：有狀態（≤14 次委派）

**適用**：schema migration、data backfill、線上大表加索引、破壞性契約變更、**認證授權變更**。

**定義以「碰到已存在的資料或已在跑的流量」為準，不以「改 schema」為準** —— backfill script 不改 schema 但完全不可逆；認證變更不碰 DB 但權限放寬出去收不回來。

**流程**：完整路徑 + `gate-contract` → `gate-migration` → `migration-execution` → `gate-release`

**必要產出**：`migration-plan`、**`rollback-plan`**、`staged-rollout-plan`。

**`gate-migration`／`gate-release` 不是品質閘門，是不可逆性閘門。** 使用者批准的是「我接受這件事可能回不去」，不是「我覺得程式寫得不錯」。因此：

- **`rollback-plan` 不得標 `not-applicable`。** 真的無法回復時，計畫必須明說「不可回復」並改為要求前置備份與還原演練 —— 「無法回復」是一個必須被使用者明確接受的結論，不是可以跳過的欄位。
- **未演練過的 rollback 計畫等於沒有計畫。** `gate-migration` 要求演練證據。
- **交付不得一次全量。** 分階段是不可逆變更唯一的實質保險：它把「發現錯了」提前到影響範圍還小的時候。`gate-release` 要求具體可觀測的**中止標準**。

**切片**：只保留在切片邊界等於失敗復原邊界之處 —— `tdd-implementer` 維持 1 個 behavior slice、`analyst` 維持 1 個 story。`design-modeler` 用 `foundation`(api+data) → `elaboration`(sequence+module+traceability)，中間保留分界供 `spec-reviewer`(`design`) 在 foundation 錯誤污染下游前介入。`integration-tester` 單次 `mode: all`。

**預算為何從 20 降到 14**：`t3` 通常前置一個 `probe` run，帶著事實起跑，修正輪大幅減少。逼近上限代表範圍過大 —— **拆多個 run，不放寬上限**。

`living-doc` **只在 `t3` 啟用**：委派寫檔的損益平衡是「產物大小 × 剩餘輪次 > spawn 成本」，只有 `t3` 的 run 夠長、產物夠大而值得。`context-pack` 僅在 `t3` 且跨階段時編譯。

---

## Tier 升降

- **向上升級**：任何時候發現原判定過低（實際不可逆性超出、消費者範圍超出、委派次數逼近上限），**立即停止當前委派**，以 `Codex user confirmation` 告知並升級。已產出的產物保留，補做新 tier required 的前置產物。
- **發現未知度問題時不要升級 —— 開探索 run。** 現況不明、可行性不明、需求無可驗證完成定義 → 停止交付、`checkpoint`、開 `probe`／`spike`。抬高交付 tier 不會讓你知道得更多，只會讓不知道變得更貴。
- **向下降級**：不允許自動降級。使用者明確要求時才可降，並記錄到 decision-log。
- 升降級後 orchestrator 更新 `runtime-metadata.tier`；`t3` 委派 `living-doc` 寫 `decision-log.md`，其餘自行寫入。

## 掃描成本（各 tier）

掃描成本必須與**專案大小脫鉤**。所有 tier 都先讀確定性索引，不走訪原始碼樹。

| tier | `scan-policy` | 行為 | `impact-top-n` | `sql-scan` |
|---|---|---|---|---|
| `t0` | `index-only` | 只讀 `index.json` + top-5 候選 | 5 | 停用 |
| `spike` | `index-only` | 同上 | 5 | 停用 |
| `t1` | `index-plus-scoped` | 讀索引、只刷新 stale scope | 12 | 停用 |
| `probe` | `index-plus-scoped` | 同上，`sql-scan` 依探索問題按需啟用 | 12 | 按需 |
| `t2` | `index-plus-scoped` | 同上 | 12 | 停用 |
| `t3` | `full-index-plus-sql` | 完整索引 + `sql-scan` + DB 定義落地 | 12 | 啟用 |

程序見 `runbooks/repo-indexing.md`；原則見 `policies/token-budget-policy.md` 的 Discovery Rules。

## 與其他規則的關係

- 分流**不覆蓋** DLP／secret safety、safe-change 批准、smoke test 使用者批准、DB introspection 批准。這些在任何 tier 只要觸發條件成立就必須執行。
- 分流**不覆蓋** `token-budget-policy.md` 的 `Never Remove For Token Saving` —— 但該段落只約束**已啟用**的階段。
- **綠燈門檻不因 tier 降低**：`t0` 沒有 acceptance suite，等效要求是相關既有測試全綠且 `skipped == 0`。
- `minimal-implementation-policy` 在所有 tier 皆適用。

## 舊 profile 對照（v1.x → v2.0.0）

僅供讀舊 run 紀錄時參考。**舊 run 無法自動遷移** —— `min-compatible-version` 已升至 2.0.0，舊 run 需重新判定 tier。

| 舊 profile | 大致對應 | 差異 |
|---|---|---|
| `lite` | `t0` 或 `t1` | 舊 `lite` 仍 spawn `formulator`+`tdd-implementer`（2 次）；新 `t0` 是 0 次，新 `t1` 有 reviewer |
| `standard` | `t1` 或 `t2` | 分界改為「有無不受控消費者」，不再是檔案數 4–15 |
| `full` | `t2`、`t3`，或 `probe` + 交付 tier | 舊 `full` 的 6 個純觸發中，「不確定」與「含敏感資料」不再進入 tier 判定 |
| （無對應） | `probe` / `spike` | 新增。舊模型用「升 `full`」吸收未知度 |
