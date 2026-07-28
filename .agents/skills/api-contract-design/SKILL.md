---
name: api-contract-design
version: 1.0.0
description: 從 domain rules、examples、candidate models 產出 OpenAPI 3.1 draft 契約（P0-1 設計橋接）
---

# API Contract Design Skill

> 用途：設計橋接階段（design）產出 **draft API 契約**，供 ATDD/TDD 對齊與 P0-3 契約測試消費。
> 產出為 draft contract，不是實作程式碼，也不是正式 API 規格審查治理產物。

## 使用時機

- Gherkin 定稿、domain glossary、example map 已就緒，功能有對外 API 介面。
- 無對外 API（純 UI / 純函式庫 / 純批次）時，於 lean-sdlc-checklist 標記 `not-applicable` + reason。

## 輸入

- Gherkin final、domain summary、glossary、business rules、examples、candidate model。
- API style / auth 假設、既有 API 慣例或 coding-standards。
- （若有）DB introspection 報告、既有 endpoint 慣例。

## 指引

1. 預設 REST JSON over HTTPS，除非使用者指定其他風格。
2. 以業務資源與命令設計 path；命名對齊 domain language。
3. **不暴露** DB 資料表/欄位名稱，除非是官方業務術語（並與 DLP 交叉檢查）。
4. 每個 operation 定義 `operationId`、summary、description、parameters、request body、responses、examples。
5. 所有 request/response/DTO/error body 定義於 `components.schemas`。
6. 已知驗證時定義 `components.securitySchemes` 與 operation/root `security`。
7. 使用一致的 error schema。
8. 每個 endpoint 至少對映 1 條 business rule 與 1 個 example（追溯）。
9. 當 API style / auth / pagination / sorting / filtering / id 格式未指定時記錄 assumption。

## 狀態碼預設

- `200` 讀取/更新/動作成功且有回應 body；`201` 建立成功；`204` 動作成功無 body。
- `400` 語法/驗證錯誤；`401` 未認證；`403` 未授權；`404` 不存在。
- `409` 業務/狀態衝突；`422` 語意業務驗證錯誤（若 API style 偏好）；`500` 僅限非預期伺服器錯誤。

## Output Contract

````markdown
STATUS: needs-input | draft

## design/api-contract.yaml
```yaml
openapi: 3.1.0
info:
  title: ...
  version: 0.1.0
servers:
  - url: https://api.example.com
paths: {}
components:
  schemas: {}
```

## API Design Notes
| Operation ID | Method | Path | Rule IDs | Example IDs | Notes |
| --- | --- | --- | --- | --- | --- |

## Assumptions
- ...

## Open Questions
- ...

## Next Skill
建議下一步：spec-reviewer (mode: design) 審核 → contract-testing（P0-3）
````

## Quality Gate

- `STATUS: needs-input`：endpoint 行為、actor 權限、核心 request 資料或主要成功/失敗結果缺失。
- `STATUS: draft`：API 可在明確 assumptions 下被審核，且每個 endpoint 可追溯至 rule + example。
