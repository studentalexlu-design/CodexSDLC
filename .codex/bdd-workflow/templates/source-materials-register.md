# Template: source-materials-register.md

Source-First 的落地檔。**每個 run 都有一份**，不論由 `living-doc`（`t3`）或 orchestrator 自行（其餘所有 tier）建立。

> **登錄 ≠ 已讀。** 這份表最容易出的錯，是把「使用者列了這個檔名」寫成 `completed`，讓下游把未讀的來源當成已消化。
> 因此狀態拆成兩欄：`registered` 是「這個來源存在且路徑已確認」，`analysis` 才是「內容已被消化成事實」。
> **Gate 檢查的是 `analysis` 欄，不是 `registered` 欄。**

---

## 段落順序固定（不得改寫）

```markdown
# Source Materials Register — {run-id}

## 來源

| id | 來源 | 類型 | readability | registered | analysis | 消化者 | 產物／證據 ref |
|---|---|---|---|---|---|---|---|
| SRC-001 | {path 或 DB 物件名} | spec｜legacy-code｜db｜doc｜verbal | text｜binary-needs-transcription｜not-in-workspace｜db-clue | yes｜missing | pending｜analyzed｜conflict｜blocked｜not-applicable | {agent} | {path#Lx-Ly 或 artifact ref} |

## 未消化來源（`analysis` 非 `analyzed` 者全列於此）

- {id}｜{為何未消化}｜{阻塞交付｜不阻塞}

## 衝突

- {id-a} vs {id-b}｜{衝突點}｜{權威來源或「未裁定」}
```

---

## 欄位規則

| 欄 | 規則 |
|---|---|
| `readability` | 建立時就要判定，**不能留空**。判定方式見下節 |
| `registered` | `yes` 只在**路徑實際存在且可定位**時給。使用者口述的檔名在確認存在前是 `missing` |
| `analysis` | 只有在「已有 agent 讀過內容並產出附 ref 的事實」時才可寫 `analyzed`。由消化它的 doer 更新，不由 orchestrator 代填 |
| `產物／證據 ref` | `analyzed` 必附。沒有 ref 的 `analyzed` 視同 `pending` |

## readability 判定

| 值 | 條件 | 後續 |
|---|---|---|
| `text` | 純文字、可直接被 agent 讀取（`.cs`／`.aspx`／`.sql`／`.md`／`.json`…） | 正常委派消化 |
| `binary-needs-transcription` | `.xlsx`／`.xls`／`.docx`／`.pdf`／圖片等 —— **roster 中沒有任何 agent 能直接讀** | 必須先依 `runbooks/binary-source-transcription.md` 產生轉錄產物，並把轉錄檔登錄為衍生來源（`derived-from: {原 id}`）。原始來源在轉錄完成前不得標 `analyzed` |
| `not-in-workspace` | 路徑不在目前 workspace 下 | `registered: missing`。**不得以推測補足內容** |
| `db-clue` | DB 物件線索 | 維持 `pending-approval`，經 `db-introspection-scanner` 取得證據後才更新 |

## 硬規則

1. **不得從未 `analyzed` 的來源推導事實。** 任何 artifact 中的資料表名、欄位名、商業規則，都必須可回溯到某個 `analyzed` 列的證據 ref。無法回溯的內容是推測，必須刪除或改列為 open question。
2. **不得為了讓流程前進而把 `analysis` 標成 `analyzed`。** 讀不到就是 `blocked`，並在「未消化來源」段標明是否阻塞交付。
3. 不得存放 credentials、connection string、API key、原始敏感資料列。
4. `completed` **不是合法值** —— 它同時可讀成「登錄完成」與「消化完成」，正是本表要消除的歧義。
