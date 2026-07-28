---
name: example-mapping
version: 1.0.0
description: 以 story、rules、examples、questions 進行需求探索
---

# Example Mapping Skill

## 使用時機

- 需求仍模糊，需要在撰寫 Gherkin 前釐清業務規則
- 已有核准的 `flow-description`，需要將其拆解為可驗收的 rules 與 examples
- 需要切分規則與範例，辨識 happy path 與 edge case
- 需要釐清 out-of-scope，避免 scope creep
- 多個來源之間有規則差異需要比較
- 需要與使用者協作確認業務行為

## 核心概念：四色卡片

| 顏色 | 代表 | 說明 |
|------|------|------|
| 🟡 黃卡 | **Story** | 要探索的使用者需求或功能 |
| 🔵 藍卡 | **Rule** | 約束行為的業務規則（一個 story 通常有 2–7 條 rules） |
| 🟢 綠卡 | **Example** | 具體的驗收範例，用來證明 rule 的行為（每條 rule 至少 1 個 happy + 1 個 edge） |
| 🔴 紅卡 | **Question** | 無法當場決定的問題，標記後追蹤 |

## 操作步驟

### Step 1：定義 Story

1. 若已有核准的 `flow-description`，以其業務流程步驟分群作為 story 拆分依據：每個主要步驟或步驟群組對應一個 story 候選。
2. 用一句話描述要探索的功能或需求。
3. **標註追溯欄位**：每個 story 須標註「對應業務步驟#」與「對應操作流程#」（若 `flow-description` 包含操作流程區段）。此追溯是後續跨層驗證的基礎。
4. 確認 story 的粒度：若一次探索超過 25 分鐘或 rules 超過 7 條，應拆分為多個 story。
5. 確認 story 與 `domain-glossary` 中的術語一致。

### Step 2：提取 Rules

1. 從來源素材（需求文件、既有程式碼、DB schema、使用者描述）中提取約束行為的規則。
2. 每條 rule 用一句業務語言描述（不含技術實作細節）。
3. 依重要性排序：核心 happy-path rules 在前，edge case rules 在後。
4. 交叉比對多個來源：若同一行為在不同來源中有不同規則，記錄到 Questions 並標記來源衝突。

### Step 3：為每條 Rule 補充 Examples

1. 每條 rule 至少一個 **happy path** example（規則正常運作）。
2. 每條 rule 至少一個 **boundary / edge case** example（規則邊界行為）。
3. 若規則涉及錯誤處理，補充 **sad path** example。
4. Example 必須具體：使用真實但虛構的數據，不用「某個值」之類的抽象描述。
5. Example 格式建議：`Given [前置條件] When [操作] Then [預期結果]`（非正式 Gherkin，僅作為探索草稿）。

### Step 4：記錄 Questions

1. 規則不明確或來源矛盾 → 紅卡。
2. 標記 question 的影響等級：
   - **blocking**：不解決就無法寫出驗收條件，阻擋進入 Formulate
   - **clarifying**：可先用假設前進，但需要後續確認
3. 對每個 question，標記預期由誰回答（使用者 / 領域專家 / 技術負責人）。

### Step 5：標記 Out-of-Scope

1. 探索過程中浮現但不屬於本次需求的功能或規則 → 明確標記 out-of-scope。
2. 記錄原因：「超出本次交付範圍」/「候選未來需求」/「需要獨立評估」。

### Step 6：NFR 探索

1. 檢查是否有非功能需求隱含在 story 中（效能、安全性、可用性、資料一致性）。
2. 若有，轉換為可驗證的 rule + example（例如：「回應時間不超過 200ms」→ Rule + Example）。
3. 無法量化的 NFR 記錄為 Question。

### Step 7：追溯驗證

1. 確認所有 story 都已標註「對應業務步驟#」與「對應操作流程#」。
2. 確認 `flow-description` 中所有業務步驟都被至少一個 story 涵蓋。
3. 若 `flow-description` 包含操作流程區段，確認所有操作步驟都被至少一個 story 涵蓋。
4. 確認 example-map metadata 中的 `flow-description-version` 與當前 `flow-description` 的 `version` 一致。
5. 若版本不一致（上游已更新），將 example-map 標記為 `stale` 並通報 orchestrator。

## 時間盒控制

- 單一 story 的 Example Mapping 不超過 **25 分鐘**。
- 若 rules 超過 7 條 → 拆分 story。
- 若 examples 超過 3 個/rule → 可能規則定義過寬，考慮拆分 rule。
- 若 questions 超過 5 個 → 停止探索，優先解決 blocking questions。

## 常見反模式

| 反模式 | 症狀 | 修正方式 |
|--------|------|----------|
| **抽象 Example** | Example 用「某個值」「有效的輸入」等模糊描述 | 使用具體數據：金額、日期、名稱 |
| **Rule-Example 混淆** | Rule 寫得像 Example（包含具體數據），或 Example 寫得像 Rule（過於抽象） | Rule 是規則，Example 是該規則的具體實例 |
| **Question 堆積不處理** | Questions 持續新增但不解決 | 每輪結束前輸出 blocking questions 到終端請使用者確認 |
| **一次做太多** | 單次 mapping 超過 30 分鐘 | 拆分 story，每次聚焦一個子需求 |
| **跳過 sad path** | 只有 happy path examples | 每條 rule 強制補至少一個 edge/sad case |
| **技術語言滲入** | Rule 用 SQL 欄位名或 API 參數名描述 | 使用業務語言，技術對映留到 step definitions |
| **遺漏來源** | 只看需求文件，忽略既有程式碼或 DB schema 中的隱含規則 | 交叉比對 `source-materials-register` 中所有來源 |

## 與使用者協作的對話模板

### 開始探索
> 我們要探索「{story}」這個需求。我先從已有的來源中提取了以下 rules 和 examples，請幫我確認：
> 1. 這些 rules 是否正確？有沒有遺漏？
> 2. 每個 example 的預期行為是否符合你的期望？
> 3. 有沒有額外的 edge case 或例外情況？

### 發現矛盾
> 我在分析來源時發現一個矛盾：
> - 來源 A（{來源名}）說：{規則 A}
> - 來源 B（{來源名}）說：{規則 B}
> 請問應該以哪個為準？還是合併後的行為應該是其他方式？

### 確認邊界
> 針對規則「{rule}」，我想確認以下邊界情況：
> - 當 {邊界條件 1} 時，預期行為是？
> - 當 {邊界條件 2} 時，預期行為是？

## 輸出格式

使用 `bdd-docs/artifacts/example-maps/template.md` 或 `bdd-docs/runs/{run-id}/artifacts/example-maps/` 的模板，包含：

- **Story**：一句話描述
- **Rules**：編號列表，每條 rule 下方接對應的 examples
- **Examples**：具體的 Given-When-Then 草稿
- **Questions**：標記 blocking / clarifying 與指派對象
- **Out-of-Scope**：明確排除項目
- **NFR**：可驗證的非功能需求（若有）

## 守則

- 不直接跳到技術實作。
- 若 blocking questions 影響驗收，不得進入 Formulate 階段。
- 必須涵蓋 `source-materials-register` 中所有相關來源的 scenario，不得遺漏。
- 每個 rule / example 須可追溯到來源（source-material ID）。
- 若 analyst 過程中發現術語不在 `domain-glossary` 中，通報 orchestrator 考慮升級流程複雜度。

## 邊界

- 此 skill 只處理需求探索的方法論與產出格式。
- 流程 gate、批准、階段切換由 orchestrator 控制。
- Gherkin 撰寫由 `gherkin-authoring` skill 負責。
