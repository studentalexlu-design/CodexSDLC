---
name: impact-analysis
version: 1.0.0
description: 評估變更影響面與風險
---

# Impact Analysis Skill

## 分析流程

1. 定位變更起點（entry point）
2. 追蹤呼叫鏈與依賴圖
3. 識別 public surface 與 API 契約
4. 評估風險等級與回歸範圍
5. 輸出影響報告

## 必查清單

| 面向 | 檢查項目 |
|------|---------|
| 呼叫鏈 | 呼叫點 / 被呼叫點、跨層 / 跨模組依賴 |
| Public Surface | API 端點、public method 簽章、共用介面 |
| DI / IoC | 註冊、生命週期、替換影響 |
| 資料契約 | DTO / event schema / serialization 格式 |
| 組態 | config、feature flag、environment variable |
| 資料庫 | schema、migration、stored procedure |
| 測試覆蓋 | 既有測試數量與品質、回歸風險區域 |
| 跨系統 | 外部 API、message queue、shared cache |

## 風險等級判定

| 等級 | 條件 |
|------|------|
| 🟢 Low | additive-only、無 public contract 變更、測試覆蓋充足 |
| 🟡 Medium | 既有 API 修改、跨層變更、部分測試覆蓋 |
| 🔴 High | public contract 破壞、DB migration、跨系統 / 跨 bounded context |

## 輸出格式

| 產出項目 | 說明 |
|---------|------|
| Impact Summary | 變更範圍摘要與受影響元件清單 |
| Editable Paths | 允許修改的檔案 / 模組 |
| Forbidden Paths | 禁止修改的檔案 / 模組（含理由） |
| Risk Level | 🟢 / 🟡 / 🔴 與判定依據 |
| Rollback Hints | 回滾策略與注意事項 |

## 升級條件

以下情況需輸出選項到終端請求人工裁定：

- 涉及 public API contract 破壞性變更
- 跨 bounded context 或跨系統影響
- 風險等級為 🔴 High
- 影響範圍無法確定

---

## API 設計規則（UI 操作 → API 映射）

> **核心原則**：API 命名必須反映實際行為語意，不可從 UI 按鈕名稱直接映射。

### 語意判定表

| UI 描述 | 實際行為 | 正確命名 | ❌ 錯誤命名 |
|---------|---------|---------|-----------|
| 「新增」+ 預帶/複製/範本 | 取得既有資料作為範本 | `GetTemplateForCreate` | `Create` |
| 「新增」+ 空白表單 | 導頁至空白表單 | `GetEmptyForm` 或純前端 | `Create` |
| 「儲存」（含新增/修改） | 依 PK 決定 Insert 或 Update | `Save` / `Upsert` | `Create` + `Update` 分開 |
| 刪除/提交/退回/審核 | 狀態變更或刪除 | 直接映射語意 | — |

### 判定要點

1. **導頁 → 讀取**：UI 含「導頁」描述 → API 返回資料，非寫入 DB
2. **儲存 → 寫入**：DB 寫入在「儲存」API，非「新增」按鈕
3. **預帶 → 範本**：「新增」含「預帶」「複製」「最近一筆」→ `GetTemplate` 類

### 查詢頁 + 明細頁參考模式

| UI 操作 | 頁面 | API |
|---------|------|-----|
| 查詢 | 查詢頁 | `Query` |
| 檢視/編輯 | 查詢頁 | `GetDetail` |
| 新增（預帶） | 查詢頁 | `GetTemplateForCreate` |
| 儲存 | 明細頁 | `Save` (Upsert) |
| 刪除/提交/退回/審核 | 查詢頁 | `Delete` / `Submit` / `Reject` / `Approve` |

### 優缺點

**優點**
- API 語意精確，降低前後端溝通誤解
- 明確區分「取資料」與「寫入 DB」，職責清晰
- 與常見列表 + 明細頁 UI 模式對齊，設計可預測

**缺點**
- 需深入理解 UI 流程與導頁行為，分析成本較高
- 團隊若未事先對齊規則，過渡期可能命名風格不一致
- 對純 CRUD 場景可能過度分析

### 反模式

- ❌ UI 按鈕名稱 1:1 映射為 API 名稱
- ❌ 忽略「導頁後預帶資料」的讀取行為

 


