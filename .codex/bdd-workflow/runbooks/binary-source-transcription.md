# Runbook: 二進位來源轉錄

適用於 `source-materials-register.md` 中 `readability: binary-needs-transcription` 的列 —— `.xlsx`／`.xls`／`.docx`／`.pdf`／截圖等。

## 為什麼需要這份 runbook

roster 裡**沒有任何 agent 能直接讀取二進位來源**。過去的失敗模式是：規格書被登錄進 register、狀態標成完成、然後從頭到尾沒有人打開過它，而下游把「規格已消化」當成前提繼續跑。**規格是報表類需求的唯一權威來源，它未被讀取時，整個 run 沒有可驗證的完成定義。**

因此規則是二選一，沒有第三條路：**要嘛產出轉錄產物，要嘛回 `blocked`。** 不得跳過、不得以 legacy 程式碼反推規格、不得以模型既有知識補足欄位名。

## Owner

`project-scanner`。它是 Source-First 的 inventory owner，在 `probe` tier 可用，且轉錄是機械抽取而非詮釋 —— 交給 `analyst` 會讓「抽取」和「解讀」混在同一步，那正是需要分開的兩件事。

## 產物

`bdd-docs/runs/{run-id}/artifacts/source-transcripts/{slug}.md`

轉錄檔登錄為衍生來源，`derived-from` 指向原始來源 id，並記錄原始檔的 SHA-256（原始檔換版時轉錄即失效）。**原始來源列在轉錄完成前不得標 `analyzed`。**

## 方法（依序嘗試，命中即停）

1. **使用者已提供文字版** —— CSV／貼上的表格／既有轉錄檔。最可靠，優先使用。
2. **Python + 對應套件** —— `openpyxl`（xlsx）、`python-docx`、`pdfplumber`。先確認套件可用再跑，不得為此安裝套件。
3. **PowerShell 模組** —— `ImportExcel` 的 `Import-Excel`。同樣先確認已安裝。
4. **.NET + 專案既有套件** —— 若目標方案已依賴 ClosedXML／EPPlus，可在 run 的 artifacts 目錄下寫一支**拋棄式**轉錄程式。它等同 spike code：不得放進 production 專案、不得進 commit，`gate-probe` 前必須刪除。
5. **以上皆不可用 → 回 `blocked` + `needs-transcription`**，明確列出：來源 id、檔案路徑、缺少的工具、以及請使用者做的最小動作（例如「請將該 sheet 另存為 CSV 放在同目錄」或「請貼上欄位清單」）。

## 轉錄內容要求

- **保留結構**：sheet 名、表頭列、欄位順序、合併儲存格的實際涵蓋範圍、公式原文（不是計算結果）。
- **不搬運資料列**：規格書的範例資料常含真實客戶資料。只轉錄**結構與規則**；需要示意時以遮罩後的樣本表示，並在 register 標記 `P` 因子。
- **標註不確定處**：無法從檔案本身判定的（欄位語意、來源對應、計算規則），列成 open questions，不填入猜測。
- 轉錄檔本身也受 DLP 殘留掃描與 sidecar digest 規範。

## 完成判定

轉錄完成 = 下游能單憑轉錄檔回答「這份報表要產出哪些欄位、每欄的定義是什麼」。若轉錄後仍答不出來，那是**規格本身不足**，應列為 open question 交回使用者，而不是轉去 legacy 程式碼或 DB 推測補齊 —— 那是把「規格不明」偷換成「實作已存在」。
