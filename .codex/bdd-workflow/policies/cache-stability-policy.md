# Cache Stability Policy

目標：提高 input cache 命中率，降低同類委派的 prompt 漂移。

## Cache 實際如何運作（先理解這段，其餘規則才有意義）

Prompt cache 依**前綴精確匹配**運作。因此：

- **跨 agent 永遠不會共用 cache。** 每個 agent 有各自不同的系統提示，前綴在第 0 個 token 就分岔。
  `model_reasoning_effort` 不同與否**不影響這個結論** —— 系統提示本來就不同。
- **唯一的 cache 機會是同一個 agent 的重複呼叫**（例：`full` profile 下 `tdd-implementer` 每個 slice 一次）。
  該 agent 的系統提示每次相同，可被快取。
- 因此**共用核心必須內嵌在各 agent 的系統提示內**（`AGENT-CORE` 區塊），不可改成執行期讀共用檔 ——
  讀檔結果排在易變的 handoff 之後，永遠進不了共用前綴。內嵌的一致性由 `.codex/scripts/agent-lint.ps1` 強制。

### 分包守恆原則（決定要不要合併 agent 時看這條）

**指令總量不會因為重新分包而變少。** 把 N 個 agent 合併成 M 個胖 agent，冷啟動總成本大致守恆
（終究要載入全部指令內容一次），而快取重讀的成本反而隨提示變大而**上升**。

合併只在下列兩種情況才有效益：

1. **刪除確實重複的內容** —— 例：4 個 spec reviewer 共用約 80% 儀式，合併刪掉 3 份。
2. **把跨 agent 切換轉成同 agent 重複呼叫** —— 這是唯一存在的 cache 機會。
   例：`full` 下 4 次規格審核原本是 4 個不同 agent（零 cache），合併後是同一 agent 4 次（3 次命中）。

反例（**不要這樣做**）：把共用樣板抽到外部檔讓各 agent 執行期讀取。
那把內容從**可快取的系統提示**搬到**不可快取的執行期讀取**，總量沒減少反而增加。
共用核心因此刻意內嵌於各 agent（`AGENT-CORE` 區塊），一致性由 `agent-lint.ps1` 強制。

會破壞同 agent cache 的行為，依影響大小排序：

1. run 進行中修改 agent `.toml`（見「Agent 檔案變更控制」）。
2. handoff 段落順序不固定，或把易變欄位排在靜態欄位之前。
3. policy／runbook 讀取順序每次不同。

## 固定來源與路徑

- agent mode 主檔固定為 `.codex/agents/{agent-name}.toml`（orchestrator 為 `.codex/agents/bdd-orchestrator.toml`）。
- policy 固定掛載 `.codex/bdd-workflow/policies/`，不得在 handoff 內嵌 policy 全文。
- runbook 固定掛載 `.codex/bdd-workflow/runbooks/`，只讀 active mode 需要的最小檔案。
- handoff 模板固定掛載 `.codex/bdd-workflow/templates/`。

## Prompt 穩定化

- handoff 一律使用模板，避免每輪自由拼接文字。
- 模板段落順序必須固定，且**靜態在前、易變在後**：
  `constraints` → `output-contract` → `meta` → `target` → `{gate|review-focus|context}` → `summary`。
  > `constraints` 與 `output-contract` 同 mode 完全固定，排前面才可能進入共用前綴；
  > `meta`（run-id、feature-id、tier）每次都變，排最後。**順序顛倒會讓靜態內容永遠無法快取。**
- 動態欄位只允許替換 placeholder 值，不得改段落名稱與順序。
- 同 mode 的 handoff，固定句型與固定欄位名；不要每輪改寫敘述風格。

## Payload 限制

- handoff 只傳 path、version、digest、hash 與 <=500 字摘要。
- 禁止貼完整 operation log、完整 source materials、完整 context packs、長測試輸出。
- tool output 只保留：exit status、關鍵計數、前 3 筆缺陷、evidence refs。

## 同 turn 節流

- **full**：單一 turn 不連續呼叫超過 1 個 doer；同 stage 僅續跑最小切片。
- **standard**：允許同 turn 連續呼叫至 2 個 doer，且合併模式（`mode: all`）算 1 次呼叫。
- **lite**：不受此限（全程僅 1 個 doer）。
- 任何 tier：若超過該 tier 的切片上限，先 checkpoint 再回傳 partial-completed。
- atdd 發生 partial-completed 時，優先 checkpoint；同 turn 不重複要求同一子代理處理同一切片。

## Agent 檔案變更控制

- **run 進行中不得修改 agent `.toml`** —— 這會作廢該 agent 已累積的所有 cache，是最昂貴的失誤。
- 不得頻繁整份重寫 agent `.toml`；以增量 patch 為預設，每次僅調整必要段落。
- `AGENT-CORE` 共用核心刻意內嵌（理由見上方「Cache 實際如何運作」），
  修改時必須同步全部 12 份並跑 `agent-lint.ps1` 驗證逐字相同。

### 內嵌 vs 外掛：以「讀取頻率」決定，不是以「檔案精簡」決定

判準只有一條 —— **該 agent ≥80% 的 invocation 都會讀到 → 內嵌進系統提示；真正條件性 → 留在 policy／runbook／skill。**

理由直接來自上方的 cache 機制：系統提示可跨同 agent 的重複呼叫命中 cache（約 1/10 成本），執行期讀取排在易變的 handoff 之後，**每次 spawn 都付全額**。因此對會被重複 spawn 的 agent（`full` 下 `tdd-implementer` 每切片一次、`analyst` 每 story 一次、`living-doc` 每 stage boundary 一次），把必讀內容外掛是**淨損失**：

> N 次 spawn × 全額讀取　vs　1 次 cache write + (N−1) 次 cache read

「維持 agent 檔精簡」本身不是目標 —— 精簡若換來每次 spawn 重讀，就是把成本從看得見的地方搬到看不見的地方。

兩個配套要求：

1. **蒸餾，不是複製。** skill／runbook 是給人讀的教學文件，內嵌時只取**判斷規則**，捨棄說明、對話模板與範例鋪陳。整份貼進去會讓提示膨脹吃掉 cache 的好處。
2. **內嵌就有漂移風險，必須機械綁定。** 回傳合約的內嵌區塊與 `return-contract-policy.md` 由 `agent-lint.ps1` 檢查一致；新增其他內嵌時比照辦理，否則就會重演 DLP 兩份實作走鐘的老問題。

