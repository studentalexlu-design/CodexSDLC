# Runbook: DLP 主動脫敏

> 從 `bdd-orchestrator` 指令檔搬出（contract 1.11.0）。只在**觸發脫敏情境**時讀取。
> 殘留掃描、阻斷與稽核規則見 `policies/dlp-verification-policy.md`，此處不重複。

## 層級適用

| tier | 是否執行 |
|---|---|
| lite | 不執行，除非 intake 明確標記來源含敏感資料 |
| standard | 不執行，除非 intake 明確標記來源含敏感資料 |
| full | **必須執行** |

任何層級只要 intake 標記來源敏感，就套用完整流程 —— 分流不覆蓋 secret safety。

## Intake 脫敏 Scope 確認

source materials 登錄完成後、首次委派子代理前，以 `Codex user confirmation` 讓使用者標記範圍：

- 全部來源都需脫敏（預設）
- 僅標記的來源需脫敏（使用者列出來源 ID）
- 不需要脫敏（使用者確認無敏感資料風險）
- ✏️ 自行輸入…

選「不需要脫敏」→ 跳過本 runbook 其餘段落，並委派 `living-doc`（`mode: checkpoint`）執行**兩件事**：

1. 於 `mask-audit.md` 記錄該決策（不含敏感值）。
2. 建立標記檔 `bdd-docs/runs/{run-id}/.dlp-disabled`，內容為一行決策摘要（時間 + 使用者決策，**不得含敏感值**）。

標記檔存在時，`.codex/scripts/dlp-gate.ps1`（PostToolUse hook）會對該 run 底下的所有 artifact 短路整條殘留掃描 —— 這是讓「不需要脫敏」真正省下成本的環節。沒有這個檔，hook 仍會逐檔掃描。

選部分脫敏 → 只對被標記來源執行；**不得**建立 `.dlp-disabled`（該標記是全 run 短路，會連帶跳過需脫敏來源的掃描）。

撤銷：run 中途發現敏感資料時，先刪除 `.dlp-disabled`，再依「脫敏流程」重跑全量掃描。

## 脫敏觸發模式

來源含下列任一類別即須脫敏：

- 個人識別資料：姓名、身份證、電話、Email
- 業務識別符：訂單號、客戶 ID、系統代碼、內部專案代號
- 機密字串：帳號、密碼、API key、連線字串

## 脫敏流程

1. **掃描識別**：讀取 source materials，識別上述模式。
2. **建立 Mapping Table**：以 `{{ENTITY_TYPE_N}}` 格式替換（如 `{{CUSTOMER_ID_1}}`、`{{ORDER_NO_1}}`）。
   > ⚠️ mapping table 含原始敏感資料。**僅保存於 session memory**；禁止寫入 `bdd-docs/`、artifact、log、decision-log 或任何 handoff prompt。
3. **以脫敏版本委派**：所有 handoff 使用脫敏後內容，不得夾帶原始值。
   委派前的殘留掃描依 `policies/dlp-verification-policy.md` 第 2–4 節執行。
4. **還原 Mapping**：子代理回傳後、委派 `living-doc` 寫入 artifact 前，以 mapping table 還原識別符。mapping 指示以 session context 傳遞，不貼入 prompt 全文。
5. **還原後語法驗證**：若產出為程式碼（`.cs`、`.feature`、`.json` 等），委派對應 doer 或 `living-doc` 執行基本語法檢查（如 `dotnet build` 或格式 lint）。若語法因替換而破壞，標記問題行並以**最小修正**修復，不重跑整個子代理切片。
6. **例外處理**：若脫敏後語意嚴重喪失（無法進行 domain 分析），以 `Codex user confirmation` 詢問後續策略（見下方「DLP 攔截確認」）。

## Handoff 佔位符保留

handoff 內容含 `{{...}}` 佔位符時，prompt 必須加入：

> 內容中包含 `{{PLACEHOLDER}}` 格式的佔位符，請在生成產出時完整保留這些佔位符，不要更改、移除或展開它們。

四個 handoff 模板的 `constraints` 段落已內建此規則（「若內容含 `{{...}}` 佔位符，請完整保留」），
套版產生的 handoff 自動涵蓋；只有在**不使用模板**的特殊委派時才需另外加入。

> 注意區分兩種佔位符：模板自身的 `{{RUN_ID}}` 等欄位是**待替換**的，
> DLP 脫敏產生的 `{{CUSTOMER_ID_1}}` 等是**必須原樣保留**的。子代理收到的 handoff 中，
> 前者應已被替換為實際值，殘留未替換的模板欄位視為 handoff 產生錯誤。

## Mapping Table 生命週期

- **建立**：首次脫敏掃描完成時，存入 session memory。
- **更新**：同一 run 內發現新敏感值時追加 entry。
- **跨對話 Resume**：session memory 不跨對話保存。resume 新對話時必須以 `Codex user confirmation` 請使用者重新提供或確認 mapping table（選項：貼上先前 mapping、重新掃描來源、宣告不再需要脫敏）。重建後、繼續委派前，先跑一次全量殘留掃描。
- **銷毀**：run 結束（archive）後自動失效，不得保留至下一個 run。

## DLP 攔截確認

子代理或工具回傳含 `DLP`、`blocked`、`policy violation`、`sensitive data`、`content filtered` 關鍵字時，視為攔截事件：

1. **立即停止委派**。
2. 以 `Codex user confirmation` 告知攔截發生的 stage 與來源類型 —— **不顯示被攔截的原始內容**。選項固定為：
   - 提供已脫敏版本後繼續（使用者自行替換敏感內容後重新提供）
   - 改以摘要或截圖描述替代原始來源，由 orchestrator 更新 mapping 後繼續
   - 暫停 run，等待 DLP 政策解除後 resume
   - ✏️ 自行輸入…
3. 未取得使用者明確選擇前，**不得繼續委派任何子代理**。
4. 委派 `living-doc` 在 `decision-log.md` 與 `source-materials-register.md` 標記 `dlp-blocked`（不記錄被攔截的原始內容）。
5. 使用者選擇脫敏後繼續 → 更新 session memory mapping，從最近 checkpoint 重新委派。
   選擇暫停 → 寫入 checkpoint 並回傳 resume 指引。
