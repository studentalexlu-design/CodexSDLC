# Runbook: Complexity Routing（難度分流）

對應 `workflow-contract.json` 的 `complexity-assessment` stage 與 `route-profiles` 區塊。

> 目的：讓需求難度決定流程深度。低難度需求不應付出遺留系統重構的代價。
> **本檔不在 `complexity-assessment` 讀取。** 判定訊號與升級規則已內建於 `bdd-orchestrator` 指令檔 ——
> 那是每個 run 都要做的無條件判斷，放在有 cache 的系統提示裡，比每個 run 付一次 ~2.6k tokens 的執行期讀取便宜。
> 本檔只在**條件成立時**讀：profile 升降級程序、某個 profile 的細部流程、掃描成本細節。
> **三個 profile 都保留 Gherkin 與 Outside-In TDD 骨幹** —— 分流砍的是流程稅，不是 BDD 本身。

## 執行時機

`intake-done` 之後、`scan` 之前，**必須**執行且**只執行一次**。判定結果決定本 run 啟用哪些 stage、gate 與 agent。

resume 時直接沿用 `runtime-metadata.profile`，不重新判定；只有使用者明確要求變更時才重跑（並記錄到 decision-log）。

handoff 以 `tier:` 欄位傳遞 profile 名稱（`lite` / `standard` / `full`）。`handoff-lint` hook 會強制此欄位存在。

## 判定訊號與使用者確認

**唯一定義在 `bdd-orchestrator` 指令檔的「難度分流」段。** 此處刻意不複製一份 ——
未被機械強制的重複正是本 repo 反覆出過的漏洞（見同目錄 `cache-metrics.md` 曾把 lite 上限寫成 5）。

摘要：8 個訊號中 6 個是純 full 觸發（DB schema／introspection／破壞性契約／legacy 重構／敏感資料／設計 draft），
真正區分 lite 與 standard 的只有改動檔案數與 domain 術語增量。不確定時往上升一級。
確認後 orchestrator 寫入 `runtime-metadata.profile`；`full` 委派 `living-doc` 記 decision-log，
`lite`／`standard` 由 orchestrator 自行寫入（此二 profile 不啟用 `living-doc`）。

---

## lite：低難度快速路徑（**≤2 次委派**）

**適用**：單檔改動、新增欄位、文案調整、修 bug、複製既有 pattern。

**stage**：`intake` → `complexity-assessment` → `scan` → `formulate` → `tdd` → `tdd-done` → `completed`

**gate**：`gate-lite` 一個（合併 intake + Gate-A + Gate-D）。

**agent**：只有 `formulator` 與 `tdd-implementer`。

> **為什麼 lite 不用多代理**：多代理與單一代理的成本交叉點約在 10 次操作 —— 低於此，spawn 的固定成本（每次 4-8k tokens）超過單一長對話的累積成本。lite 只有幾步，因此**能不 spawn 就不 spawn**。
> 原本的 5 次委派中，`living-doc` 與 `project-scanner` 各佔一次，但它們在 lite 做的事 orchestrator 本來就能做。

**流程**（2 次委派）：

1. **orchestrator 自行**建立 run 最小骨架：run 目錄 + `lean-sdlc-checklist.md` + `workflow-state.json`。（已有狀態檔寫入權，不委派 `living-doc`。）
2. **orchestrator 自行**取得專案輪廓：直讀 `bdd-docs/artifacts/repo-index/index.json`，需要時執行 `impact-scope.ps1 -TopN 5`。（唯讀操作，不委派 `project-scanner`。）
3. **spawn 1** —— `formulator`（`feature`）產出 Gherkin。**保留驗收語言，這是 lite 仍算 BDD 的原因**。
4. **spawn 2** —— `tdd-implementer`（`slice`）依 Gherkin 走 Red → Green → Refactor，不設檔案數上限。
5. `gate-lite` 使用者確認 → orchestrator 自行寫 checklist 與 log 收尾。

**safe-change envelope**：`gate-lite` 要求 `safe-change-envelope.confirmed`，但 lite 不跑 `project-scanner`。
改由 orchestrator 以 `impact-scope.ps1` 的候選清單當 `editable-paths`、其餘為 `forbidden`，
連同風險評估納入 `gate-lite` 確認 —— **使用者核准 Gate 即等於核准 envelope**。

若過程中發現需要 `project-scanner` 的 `impact` 判斷、domain 分析、任何 reviewer，
或候選清單涉及 public contract／migration／DB —— 那代表**判定過低，應升級為 `standard`**，
而不是在 lite 內多加 spawn。

**不執行**：Example Mapping、domain glossary、ATDD walking skeleton、design draft、context-pack、reviewer、integration evidence、DLP 掃描（除非 intake 標記來源敏感）。

**產物**：Gherkin + production code + 測試 + checklist（minimal 欄位）。其餘標 `not-applicable`，reason `profile-lite: 低難度快速路徑不產出此項`。

---

## standard：中難度標準路徑（≤10 次委派）

**適用**：單一 feature、新增 API endpoint、不動 schema、不碰遺留 SQL。

**stage**：`intake` → `complexity-assessment` → `scan` → `domain` → `discovery-phase0` → `discovery-phase1` → `formulate` → `atdd` → `tdd` → `integration` → `living-doc` → `completed`

**gate**（6 → 2）：
- `gate-std-1`（需求與領域就緒）= intake + Gate-A + Gate-B + Gate-C 合併。
- `gate-std-2`（實作就緒與交付）= Gate-D + Gate-E 合併。

**agent**：`project-scanner`、`analyst`、`formulator`、`atdd-automator`、`tdd-implementer`、`integration-tester`。（**不含 `living-doc`** —— 見下方「跳過」。）

**reviewer**：**只有 1 次** —— `spec-reviewer`（`mode: gherkin`）於 Gherkin 定稿後。TDD 完成後不另跑 reviewer，改由 `gate-std-2` 的使用者確認把關。

**合併呼叫**：
- `analyst`：`glossary` 1 次 + `example-map` 一次處理整張 map（不切 story）。`flow` 不執行（僅 full）。
- `integration-tester`：`contract` / `integration` / `smoke` 合併為單次 `mode: all`。
- `tdd-implementer`：一次處理同一 backlog group（8 production + 8 test 檔上限）。

**跳過**：design bridge（`design-modeler` 與 `spec-reviewer`（`mode: design`）不啟用）、`living-doc`（checkpoint／decision-log／checklist 由 orchestrator 自理）、`db-introspection`、資料建模、legacy SQL 萃取、context-pack。

---

## full：高難度完整路徑（≤20 次委派）

**適用**：遺留系統重構、DB schema 變更、破壞性公開契約變更、需要 DB introspection、含敏感來源、safe-change envelope 為 high risk。

**維持完整流程**：28 stages、6 個 gate（intake + A~E）、全部 agent、全部 reviewer、完整 DLP 脫敏與殘留掃描、safe-change approval、legacy SQL 邏輯萃取、design bridge。

切片預算維持嚴格 —— 但**只在切片對應真實失敗復原邊界的地方**：

- `tdd-implementer` 3 production + 2 test、`analyst` 1 story：**維持分開**。這兩者的切片邊界就是 Red-Green-Refactor 與單一 story 的復原點，合併會讓失敗時要重做的範圍變大。
- `design-modeler`：**合併為 2 次**（`foundation` = api + data → `elaboration` = sequence + module + traceability）。分組依產物依賴，`traceability` 必須最後。中間保留分界供 `spec-reviewer`（`mode: design`）在 foundation 錯誤污染下游前介入。
- `integration-tester`：**合併為 1 次**（`mode: all`）。contract／integration／smoke 共用同一次 build，分開呼叫會 build 3 次。

> 原本「full 一律逐一 mode 分開呼叫」的規則已於 v1.13.0 解除。理由見 `policies/token-budget-policy.md` 的 Slice Rules：切片是**穩定性**手段，不是省 token 手段；分開呼叫買到的是穩定性，不是任何正確性保證 —— 設計與整合的正確性保證來自獨立審核與綠燈門檻，與呼叫次數無關。smoke 的使用者批准、DLP、safe-change 等強制項不因合併放寬。

**但 full 仍有上限：≤20 次委派。** 超過代表切片過細或範圍過大 —— 先 checkpoint，以 `Codex user confirmation` 讓使用者選擇拆成多個 run 或放寬切片，**不得無限展開**。這是與改造前最大的差別：full 不再是無底洞。

`context-pack` 僅在 full 且**跨階段**時編譯（同階段內不編）。

---

## Profile 升降

- **向上升級**（lite→standard→full）：任何時候發現原判定過低（實際改動遠超預估、發現需要碰 DB、發現敏感資料、委派次數逼近上限），**立即停止當前委派**，以 `Codex user confirmation` 告知並升級。已產出的產物保留，補做新 profile required 的前置產物。
- **向下降級**：不允許自動降級。使用者明確要求時才可降，並記錄到 decision-log。
- 升降級後 orchestrator 直接更新 `runtime-metadata.profile`，並委派 `living-doc` 寫 `decision-log.md`。

## 掃描成本（各 profile）

掃描成本必須與**專案大小脫鉤**。三個 profile 都先讀確定性索引，不走訪原始碼樹。

| profile | `scan-policy` | 行為 | `impact-top-n` | `sql-scan` |
|---|---|---|---|---|
| lite | `index-only` | 只讀 `index.json` + top-5 候選 | 5 | 停用 |
| standard | `index-plus-scoped` | 讀索引、只刷新 stale scope、top-12 | 12 | 停用 |
| full | `full-index-plus-sql` | 完整索引 + `sql-scan` + DB 定義落地 | 12 | 啟用 |

程序見 `runbooks/repo-indexing.md`；原則見 `policies/token-budget-policy.md` 的 Discovery Rules。

## 與其他規則的關係

- 分流**不覆蓋** DLP/secret safety、safe-change approval、smoke test 使用者批准。這些規則在任何 profile 只要觸發條件成立就必須執行。
- 分流**不覆蓋** `token-budget-policy.md` 的 `Never Remove For Token Saving` —— 但該段落只約束**已啟用**的階段。
- **綠燈門檻不因 profile 降低**：lite 沒有 acceptance suite，等效要求是相關單元／focused 測試全綠。
- `minimal-implementation-policy` 在所有 profile 皆適用。
