# API 設計規範

> **範例檔。** 整份請換成你們團隊自己的。留著不改，agent 會照著這裡的字做事。
>
> 讀這份的是 `sa-analyst`（排做法、產契約）與 `reviewer`。上限 150 行 —— 每次委派都要付一次。

## MUST

- **路徑用資源名詞，動詞不進 path。** `POST /orders/{id}/cancellations`，不是 `POST /cancelOrder`。
  動作真的不是資源時（`/orders/{id}:reopen`）在契約裡註明理由。
- **對外路徑一律帶版本**：`/api/v{n}/...`。版本只在破壞性變更時進位。
- **不暴露資料表名或欄位名**，除非它本來就是業務術語。`customerId` 可以，`CUST_MST_NO` 不行。
- **所有錯誤走同一個 error schema**，不得每個 endpoint 自己定一種：
  ```json
  { "code": "order_already_shipped", "message": "…", "details": [] }
  ```
  `code` 是穩定的機器可讀字串，**它是契約的一部分** —— 改了等同破壞性變更。
- **破壞性變更必須單獨列一節**：刪欄位、改型別、改語意、收緊驗證、把選填改必填。
  寫清楚**誰**會壞、**怎麼**壞。查不出有沒有消費者 → 列進「未確認的消費者」，不得假設不存在。
- **分頁、排序、篩選的參數名跨 endpoint 一致**（本專案：`page`、`size`、`sort`、`filter[x]`）。
- **時間一律 ISO 8601 UTC 帶時區**（`2026-08-14T09:00:00Z`）。不得回當地時間、不得回 epoch 秒數。

## SHOULD

- 狀態碼：`200` 有 body 的成功／`201` 建立／`204` 無 body 的成功／`400` 格式或驗證／`401` 未認證／
  `403` 未授權／`404` 不存在／`409` 狀態衝突／`422` 語意驗證／`500` 只留給非預期錯誤。
- 列表預設每頁 20 筆，上限 100。
- 建立類 endpoint 接受 `Idempotency-Key`，重送回同一筆結果而不是建第二筆。
- 欄位命名用 `camelCase`；布林欄位用 `is`／`has` 開頭。
- 每個 endpoint 至少對映到一條驗收條件（`spec.md` 的 Gherkin 區塊）。

## 這裡不管的事

- **實作怎麼寫**（哪一層、哪個 class）—— 那是 `implementer` 的事，寫進來只會過期。
- **現在有哪些 endpoint** —— 那是現況，`sa-analyst` 自己查，寫進 `bdd-docs/project-map.md`。
  現況寫進規範，不合規的舊 endpoint 就變成標準。
