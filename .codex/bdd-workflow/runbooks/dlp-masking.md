# Runbook: DLP 脫敏

命中才讀：來源或即將落地的內容含敏感資料時。

## 什麼算敏感

- **個人識別**：姓名、身分證、電話、Email、地址
- **業務識別符**：訂單號、客戶 ID、內部代號 —— 只有在它們可回指到真人時才算
- **機密字串**：帳號、密碼、API key、連線字串 —— **這一類永遠不得寫入任何檔案，也不得脫敏後保留**

前兩類脫敏後可以留下；第三類沒有脫敏版本，只能刪掉。

## 流程

1. **識別** —— 讀來源，標出上述模式。
2. **建 mapping table** —— 以 `{{ENTITY_TYPE_N}}` 取代（`{{CUSTOMER_ID_1}}`、`{{ORDER_NO_1}}`）。
   > ⚠️ **mapping table 含原始敏感值。只留在本次對話的記憶裡** —— 禁止寫入 `bdd-docs/`、任何產物、log，或任何 handoff prompt。`handoff-lint` 會擋下形如 `{{X_1}} => 值` 的內容，但那是最後一道防線，不是設計。
3. **委派用脫敏版** —— handoff 一律帶脫敏後內容。若 handoff 含 `{{...}}` 佔位符，prompt 要加一句：**「內容中的 `{{PLACEHOLDER}}` 請完整保留，不要更改、移除或展開。」**
4. **還原** —— 子代理回傳後、內容落地前還原識別符。
5. **落地後檢查** —— 若還原後的產物是程式碼或結構化格式，跑一次語法檢查；替換破壞語法時做**最小修正**，不重跑整個子代理。

## 殘留掃描

`dlp-gate.ps1`（PostToolUse）會對寫入 `bdd-docs/**` 的檔自動跑 `dlp-residual-scan.ps1`，命中即阻斷。

也可以自己先掃（唯讀，不必委派）：

```powershell
pwsh -NoProfile -File .codex/scripts/dlp-residual-scan.ps1 -Path <file>
$handoff | pwsh -NoProfile -File .codex/scripts/dlp-residual-scan.ps1
```

掃描器**只回類別、次數與行號，永遠不回命中的原始值** —— 否則掃描報告本身就成了外洩管道。

## 免脫敏

確定整個專案沒有敏感資料時，建立 `bdd-docs/.dlp-disabled`（內容一行決策摘要，**不得含敏感值**），`dlp-gate.ps1` 會整個短路。

這是**專案層級**的宣告。中途發現敏感資料 → 先刪掉這個檔，再重跑一次全量掃描。

## 被 DLP 攔截時

子代理或工具回傳含 `DLP`、`policy violation`、`sensitive data`、`content filtered` 時：

1. **立即停止委派。**
2. 以 `Codex user confirmation` 告知在哪一步、什麼類型的來源被攔 —— **不顯示被攔截的原始內容**。選項：提供已脫敏版本後繼續／改以摘要或截圖替代／暫停／✏️ 自行輸入…
3. 未取得明確選擇前，不得繼續委派。
