# Runbook: DLP Verification（P0-2）

> 供 orchestrator 與 `living-doc` 於委派前 DLP 驗證使用。細節放此，agent mode 檔只留摘要。
> 政策：`.codex/bdd-workflow/policies/dlp-verification-policy.md`
> 腳本：`.codex/scripts/dlp-residual-scan.ps1`

## 何時觸發

- Source materials 登錄後、**首次委派任何子代理前**（需脫敏來源）。
- 每一次後續委派前（handoff 內容變動時）。
- 跨對話 resume 重建 mapping 後、繼續委派前（全量掃描一次）。

## 掃描呼叫方式

掃描屬只讀驗證操作，由 `living-doc`（checkpoint mode）或指定驗證步驟執行：

```powershell
# 掃描檔案
pwsh -NoProfile -File .codex/scripts/dlp-residual-scan.ps1 -Path <handoff-content-file>

# 或從 stdin
$handoff | pwsh -NoProfile -File .codex/scripts/dlp-residual-scan.ps1

# 只掃特定類別
pwsh -NoProfile -File .codex/scripts/dlp-residual-scan.ps1 -Path <file> -Categories "ipv4,connstring,secret"
```

## JSON 判讀

```jsonc
{ "residual_count": 0, "passed": true, "categories": [], "line_refs": [], "scanned_chars": 1234 }
```

- `passed=true`（`residual_count=0`）→ 放行委派。
- `passed=false` → 阻斷；讀 `categories` 決定補遮蔽哪些類別；`line_refs` 指出位置（不含原值）。

## 補遮蔽 → 重掃迴圈

1. 依 `categories[].type` 補遮蔽對應敏感類別（更新 session-memory mapping）。
2. 重跑掃描。
3. 最多 3 次。仍 `passed=false` → 升級 Codex user confirmation。

## 升級（3 次仍殘留）

以 Codex user confirmation 提供選項：
- 手動指定遮蔽（使用者標出殘留位置對應的實體類型）
- 縮小委派範圍（只送必要片段）
- 暫停 workflow
- ✏️ 自行輸入…

## mask-audit 更新（委派 living-doc）

每次掃描後於 `bdd-docs/runs/{run-id}/artifacts/mask-audit.md` 追加：

| 時間 | 目標 stage/agent | 殘留類別:計數 | coverage% | 重掃次數 | 放行決策 |
|---|---|---|---|---|---|

> 只記類別與計數，**不記原始值**。

## 跨對話 resume

1. 以 Codex user confirmation 確認 mapping 策略（貼上先前 mapping / 重新掃描 / 宣告免脫敏）。
2. 重建 mapping 後，先跑**全量**殘留掃描再繼續委派。

## 免脫敏來源

使用者於 intake 選「不需要脫敏」→ 略過掃描，於 mask-audit 記錄決策（不含敏感值）。
