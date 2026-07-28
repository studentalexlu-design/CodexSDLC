# DLP Verification Policy（P0-2）

> Scope: `bdd-orchestrator` 及其委派前的 DLP 驗證流程。
> Engine: pwsh regex（`.codex/scripts/dlp-residual-scan.ps1`），零外部依賴。
> Contract: `workflow-contract.json` `1.9.0+`。

## 1. 目的

在維持 LLM 主動脫敏的前提下，加入**確定性殘留掃描**與**稽核**，解決三個風險：
非確定性漏遮、mapping 生命週期不穩、缺遮蔽前稽核。

## 2. 強制前置：委派前殘留掃描

- 每次委派子代理**之前**，若該來源需脫敏（使用者未於 intake 宣告免脫敏），
  必須先對「脫敏後、即將送出的 handoff 內容」執行殘留掃描。
- 掃描透過 `.codex/scripts/dlp-residual-scan.ps1` 執行（stdin 或 `-Path`）。
- orchestrator 本身不執行命令：掃描由委派 `living-doc`（checkpoint mode）或
  指定的驗證步驟執行，orchestrator 只讀回傳的 JSON 摘要判斷放行。

## 3. 掃描腳本輸出契約

- 只輸出：`residual_count`、`passed`、`categories:[{type,count}]`、`line_refs`、`scanned_chars`。
- **絕不輸出**：命中的原始值、mapping table、連線字串、任何 secret。
- 退出碼：`0`=無殘留、`2`=有殘留、`1`=錯誤。

## 4. 阻斷與重掃規則

1. `residual_count > 0` → **不得委派**。
2. orchestrator 依 `categories` 補遮蔽對應類別（更新 session-memory mapping）→ 重掃。
3. 重掃上限 **3 次**。
4. 3 次仍殘留 → 以 Codex user confirmation 升級，選項：
   手動指定遮蔽、縮小委派範圍、暫停 workflow、✏️ 自行輸入。

## 5. 稽核 artifact：`mask-audit.md`

- 路徑：`bdd-docs/runs/{run-id}/artifacts/mask-audit.md`，owner：`living-doc`。
- 每次委派前掃描後追加一列，記錄：
  - 時間、handoff 目標 stage/agent
  - 殘留類別與計數、coverage%（遮蔽 entity 數 / 偵測敏感 token 數）
  - 放行決策、重掃次數
- **禁列**：原始敏感值、mapping table、命中字串全文、連線字串、任何 secret。
- Gate（尤其 intake「DLP scope 是否正確」）可引用此稽核摘要作為證據。

## 6. 誤報處理

- 以腳本頂端 `$AllowList` 或 `-Categories` 過濾降低雜訊。
- allowlist 只記類別/樣式，不記業務原始值。
- LLM 脫敏仍為主要遮蔽手段；殘留掃描為交叉驗證，非取代。

## 7. 生命週期整合

- mapping table 儲存位置不變（session memory only），本政策不改變其生命週期。
- **跨對話 resume**：重建 mapping 後，繼續委派前必須先跑一次全量殘留掃描。
- **免脫敏來源**：使用者於 intake 選「不需要脫敏」時略過掃描，並於 `mask-audit.md`
  記錄該決策（不含敏感值）。

## 8. 縱深防禦（寫入後）

- `.codex/hooks.json` 於 `PostToolUse`（Edit/Write/apply_patch）對寫入 `bdd-docs/**`
  的 artifact 執行殘留掃描；偵測到殘留即 `exit 2` 警示，補足「委派前」掃描。

## 9. 不可覆蓋

本政策不得覆蓋 secret-safety、safe-change approval、Gate 規則與 lean SDLC checklist 證據要求。
