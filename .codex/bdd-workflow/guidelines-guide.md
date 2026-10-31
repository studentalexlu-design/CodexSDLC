# guidelines/ 使用說明

本說明屬於工作流，隨 `update` 更新。團隊規範寫於專案根的 `guidelines/`，該目錄屬於專案。

規範不放在 `AGENTS.md`、`.codex/` 或 `.agents/`：這三處於升級時覆蓋，寫入其中的規範會無聲消失。`guidelines/` 不覆蓋，唯未修改過的原廠 `README.md` 會換成新版。

- 首次 `install` 且專案沒有 `guidelines/` 時，放入範例骨架（`api.md`、`sql.md`、`coding.md`、`testing.md`、`frontend.md`、`rules.json`），請改寫為團隊規範。
- 每個專案各有一份；跨 repo 共用時，將 `guidelines/` 掛為 git submodule。

## 兩種規範

| | 條文（`*.md`） | 規則（`rules.json`） |
| --- | --- | --- |
| 內容 | 需判斷者：API 設計、分層 | 可機械判定者：禁用的語法或 API |
| 執行 | agent 讀入後遵守 | `guideline-gate` 於每次寫檔後掃描 |
| 強制力 | 依賴 agent 遵守 | `block` 直接使該次寫檔失敗 |
| 成本 | 每次委派消耗 token | 無 |

可寫成規則者，優先寫成規則。

## 條文：檔名即讀取對象

| 檔 | 讀取者 | 時機 |
| --- | --- | --- |
| `api.md` | `sa-analyst` | 提出涉及對外 API 的做法、產生契約時 |
| `sql.md` | `sa-analyst`、`implementer` | 涉及查詢或 schema 時 |
| `coding.md` | `implementer` | 每次 `mode: build` |
| `testing.md` | `implementer` | 撰寫測試前 |
| `frontend.md` | `sa-analyst`、`implementer` | 涉及前端時（選用：沒有這個檔就照專案慣例） |
| 以上相關者 | `reviewer` | `mode: code` |

- 不在此表的檔名無人讀取（`agent-lint` 檢查 8 會提出）；`orchestrator` 不讀任何規範。
- `frontend.md` 是選用檔：沒有前端的專案可以刪掉，`doctor` 不會因為缺它而報錯；其餘檔名缺了會提醒。
- 每條須列於 `## MUST` 或 `## SHOULD`；未標者視為 SHOULD。違反 MUST 判為必修（`implementer` 無法遵守時回報 `blocked`）；違反 SHOULD 僅為建議，不構成 FAIL。
- 每檔不超過 150 行；冗長的公司標準僅摘錄 MUST，其餘以連結引用。
- 寫「不得如何」，不寫現況。現況由 `sa-analyst` 記錄於 `bdd-docs/project-map.md`；兩者混寫會使不合規的既有寫法成為標準。

```markdown
## MUST
- 對外 endpoint 一律 `/api/v{n}/{resource}`，動詞不進 path

## SHOULD
- 列表預設每頁 20 筆
```

## 規則：`rules.json`

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

- 預設 `warn`；`block` 須明確指定。
- 不掃描 `bdd-docs/`、`guidelines/`、`.codex/`、`.agents/` 與建置產物。
- 結果僅含 rule id、檔:行、message、fix，不輸出命中的原始內容。
- 規則檔有誤時不阻擋，但每次寫檔均提出警告。
- 修改後驗證：`pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate`。
- 暫停全部規則：建立空檔 `guidelines/.gate-disabled`。

## 由審核歸納規範

同一類問題於**兩個以上需求**的審核（⑤）中被提出時，宜改寫為規範；僅於單一需求中反覆出現者不在此列。

於 Codex 中要求「把審核一再抓到的問題整理成規範」，skill `review-learning` 將：

1. 讀取 `sdlc.ps1 learn -Json`，依問題性質歸類，保留兩個以上需求共有的類別；已有規範涵蓋者，改為提議修改該條。
2. 起草：可由 regex 判定者寫成 `rules.json` 規則（`warn`），其餘寫成對應 `.md` 的條文（`## SHOULD`）。
3. 驗證：以暫存規則檔執行 `-Validate`，並掃描現有程式碼確認無誤判；既有違規僅列出，不修改。
4. 逐類詢問，經同意者方寫入。

- 僅檢視清單：`pwsh .codex/scripts/sdlc.ps1 learn`（唯讀）。
- 清單取自 `bdd-docs/{feature-id}/reviews/` 的各輪快照（4.19.0 起由 `dlp-gate` 留存）；hooks 未信任或 `bdd-docs/.dlp-disabled` 存在時不留存。
- 規範僅對之後的寫檔與委派生效。

## 規範對做法的影響

`sa-analyst` 提出做法前會讀取 `api.md` 與 `sql.md`，並於每個做法標示「規範：符合／違反 X，需要豁免」。違規的做法僅標示、不刪除，由使用者於 ③ 決定是否豁免。
