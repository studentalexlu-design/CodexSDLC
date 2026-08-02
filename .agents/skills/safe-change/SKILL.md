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

`sa-analyst` 在系統分析時就該把邊界講清楚，寫進 `spec.md` 的選定做法：

- **會動到的檔案與資料表** —— 具體列出，不寫「相關的服務層」
- **不該碰的** —— 這次明確排除的區域
- **需要額外審核的** —— 可以改，但 `reviewer` 要特別看的地方

`implementer` 發現要動的範圍比這個大很多 → **停下來回 `partial`**，不要一路改下去。

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

1. 把影響講清楚：動到什麼、誰會受影響、出事的話怎麼回去。
2. 以 `Codex user confirmation` 請使用者明確批准，選項要包含「不做這件事」的代價。
3. 批准的內容寫進 `bdd-docs/{feature-id}/spec.md`：批准範圍與附帶條件。**批准以 `spec.md` 傳遞，不以對話可見性傳遞** —— 子代理是冷啟動的，看不到你們的對話。
4. **未經批准不得委派實作。**

## 檢查清單

- [ ] 變更範圍不超出 `spec.md` 寫的
- [ ] 高風險區域的變更已有獨立審核
- [ ] 高風險變更已取得批准，且批准範圍寫在 `spec.md` 裡
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
