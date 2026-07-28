---
name: safe-change
version: 1.0.0
description: 控制既有系統的安全修改邊界與遷移模式
---

# Safe Change Skill

## 使用時機

- 修改影響 public surface、shared DTO、DI registration
- 涉及 DB migration 或 schema breaking change
- 跨 bounded context 改名或移動
- 影響範圍可能超出 safe-change envelope

## Safe-Change Envelope

每次 feature 開始前，`project-scanner` 會建立 envelope：

- `editable-paths`：允許修改的檔案與目錄
- `forbidden-paths`：禁止修改的檔案與目錄
- `risky-areas`：可修改但需額外審核的區域
- `max-impact-radius`：預期影響的最大範圍

## 安全遷移模式

依風險程度選擇適當遷移策略：

### 低風險

- Additive-only change（只新增、不修改既有 API）
- New class / method / endpoint

### 中風險

- Feature flag（新行為隱藏在 flag 後面）
- Adapter pattern（新介面包裝舊實作）
- Strangler fig（逐步取代舊路徑）

### 高風險

- Branch by abstraction（抽象層分岔）
- Parallel run（新舊並行比對結果）
- Blue-green / canary deployment

## 批准解鎖流程（Approval Unlock）

高風險變更需經過以下流程才能進入實作：

1. `impact-analysis` 產出 impact report，標注 risk-level = high。
2. orchestrator 在 `approval-matrix.md` 中記錄待批准項目。
3. 輸出影響摘要到終端，請求使用者明確批准。
4. 使用者批准後，更新 `approval-matrix.md` 與 `workflow-state.json`。
5. 批准記錄必須包含：批准者、時間、批准範圍、附帶條件。
6. 未經批准不得進入 `tdd-implementer` 實作高風險切片。

## 檢查清單

- [ ] 變更不超出 editable-paths
- [ ] 未觸及 forbidden-paths
- [ ] risky-areas 的變更已有額外審核
- [ ] 高風險變更已取得批准
- [ ] migration 策略已確認（additive-only / data migration / breaking）
- [ ] rollback plan 已記錄

## Consolidation Playbook（系統整併專用）

當場景為「多個舊系統合併為一個新系統」時（例如台幣 + 外幣系統整合），使用以下策略：

### 整併模式選擇

#### Greenfield Rewrite（建議）

適用場景：舊系統技術債高、新團隊有不同的 coding standard。

1. 新建全新專案，不修改舊系統程式碼。
2. 以 BDD 流程逐功能重實作（Outside-In TDD）。
3. 舊系統程式碼僅作為參考來源（read-only）。
4. Safe-change envelope 僅管控新專案。

#### Strangler Fig（漸進式）

適用場景：需要漸進切換、不能一次全部替換。

1. 新 API 逐步上線，透過 routing/proxy 將流量導向新系統。
2. 每個 feature 實作完且驗收通過後，切換該 feature 的流量。
3. 舊系統保持運作直到所有 feature 遷移完成。

### 分階段 Rollout 建議

```
Phase 1：共用基礎功能（認證、授權、共用 domain model）
Phase 2：核心業務功能（依 feature-inventory 優先序）
Phase 3：查詢/報表功能
Phase 4：管理/設定功能
Phase 5：資料遷移與切換
```

### Parallel Run 驗證

整併期間，若新舊並行：

1. 同一業務操作同時送到新舊系統。
2. 比對回應是否一致（結構化 diff）。
3. 不一致時記錄到 `behavior-comparison.md`。
4. 驗證通過後才能 cutover。

### Cutover 條件

- [ ] `feature-inventory` 所有必要 feature 狀態為 `verified`
- [ ] `endpoint-mapping` 覆蓋率達到目標
- [ ] `data-migration-plan` 已執行且驗證通過
- [ ] Parallel run 比對無重大差異
- [ ] 使用者已明確批准切換

## 與其他技能的關係

- `impact-analysis`：提供影響面評估作為 envelope 依據
- `data-modeling`：schema change 需要 safe-change 評估
- `test-reliability`：確保遷移過程中測試穩定性
