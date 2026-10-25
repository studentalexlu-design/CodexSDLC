# CodexSDLC

供 **Codex CLI** 使用的 SDLC 工作流：釐清需求 → 分析專案並提出做法 → 使用者定案 → test-first 實作 → 獨立審核 → 交付。缺陷修正則先建立可重現的失敗測試，再行修正。

本 repo 僅含工作流的設定與腳本，不含產品程式碼。

## 需求

| 項目 | 說明 |
| --- | --- |
| Codex（CLI 或 VS Code 擴充） | 載入 `.codex/hooks.json` 與 agent 定義；已於 0.154 驗證 |
| PowerShell 7（`pwsh`） | 強制層腳本必需；缺少時 hook 不會執行，且無任何提示 |
| git（位於 Codex 的 PATH） | 審核檢查既有 scenario、分析判斷系統地圖是否過期 |
| 唯讀 DB MCP server | 僅於查詢 live DB 時需要 |

## 安裝

1. 將 `codex-sdlc-{版本}.zip` 解壓至專案以外的目錄，執行：

   ```powershell
   pwsh <解壓目錄>/.codex/scripts/sdlc.ps1 install -Target <專案路徑>
   ```

   - 既有的 `AGENTS.md` 不會被覆蓋，新版另存為 `AGENTS.md.new` 供合併。合併後請維持在 28 KiB 以內（Codex 僅讀取前 32 KiB）。
   - 曾以手動複製安裝者，請執行 `install -Adopt` 建立升級基準線。
2. **信任 hooks（必要）**：於專案目錄啟動 `codex`，在「Hooks need review」選擇 **Trust all and continue**。未信任時強制層全數失效，且無提示。更換機器、移動目錄或 `hooks.json` 變更後須重新信任。
3. **檢查**：

   ```powershell
   pwsh .codex/scripts/sdlc.ps1 doctor                   # 設定、工具檔、本機工具
   pwsh .codex/scripts/sdlc.ps1 doctor -CheckHookTrust   # 另行確認 hooks 信任狀態
   ```

   `doctor` 預設不向 Codex 查詢信任狀態，而是比對 hook 心跳與 agent 產出的時間，於產出後無任何 hook 執行時回報問題。尚未於 Codex 中執行過需求的專案無從判斷，故全綠不代表已信任。
4. **使用**：於專案中啟動 Codex，直接描述需求（例：「我要讓客戶可以取消訂單」）。

安裝後的結構：

```
<專案>/
├── .codex/ .agents/ AGENTS.md   工具檔，升級時覆蓋
├── guidelines/                  團隊規範（使用者維護，選用）
├── sdlc.config.json             agent 設定（使用者維護）
└── bdd-docs/                    流程產出
```

僅 `guidelines/` 與 `sdlc.config.json` 屬於使用者；其餘路徑於升級時覆蓋。

## 流程

| 步驟 | 內容 | 執行者 | 產出 |
| --- | --- | --- | --- |
| ① 需求 | 找出必須由使用者決定的缺口；需求很空時，先盤點現況並起草主流程供使用者修改；需要其他系統的資料而未說明來源時，先比對 repo 中的來源，比對不到者才詢問 | orchestrator（現況由 `sa-analyst` 盤點） | `spec.md`、`current-state.md` |
| ② 分析 | 查閱規格、repo、schema，提出 2–4 個做法 | `sa-analyst` | `project-map.md` |
| ③ 定案 | 選定做法、確認 Gherkin 驗收條件 | 使用者 | `spec.md` |
| ④ 實作 | test-first 實作至測試通過 | `implementer` | `.feature`、程式碼、測試 |
| ⑤ 審核 | 於獨立 context 審核，未通過則返回 ④ | `reviewer` | PASS／FAIL |
| ⑥ 交付 | 回報變更、驗證方式與剩餘風險（含僅以替身驗證的外部來源） | orchestrator | — |

- 使用者僅於三處被詢問：① 有缺口時（每輪至多 5 題，均附建議；答完若出現新的前置缺口會再問一輪，至多三輪）、③ 定案（必問）、⑥ 涉及既有資料、線上流量或既有 step 措辭時。執行 smoke test、啟動服務或連線外部 DB 前亦會先行確認。
- 需求只有一句話、連主流程都還沒講時，① 會先請 `sa-analyst` 盤點這塊系統的現況，再起草一份主流程供使用者修改；草稿每一行標明出處（使用者所述、系統現況或假設），只詢問假設與不一致之處，至多三輪。
- 需求要用到其他系統的資料、但未說明來源時，① 會先請 `sa-analyst` 將每一項資料比對到 repo 中的來源（資料表、欄位、既有的 client、設定 key）；比對不到者一次列出，詢問來源系統、負責人與取得方式。建議將 API 文件或樣本放入 repo，後續的分析、測試替身與審核均以其為準。
- ② 僅以會編譯、會執行的程式碼為現況；註解掉的程式碼與 TODO 不視為需求。
- 純技術變更可省略 ①；可由單一 commit 還原且無驗收行為的小改動將直接完成。
- **缺陷無法重現時**：略過 ①，先建立重現該症狀的失敗測試，並回查原始需求；若行為與原需求一致，改以需求變更處理。
- 每個需求請開新對話；中斷時可由既有的 `spec.md` 接續。

## 產出

| 位置 | 內容 |
| --- | --- |
| `bdd-docs/{feature-id}/spec.md` | 需求決議、選定做法、驗收條件 |
| `bdd-docs/{feature-id}/current-state.md` | 需求很空或資料來源不明時盤點的系統現況（流程、狀態、規則、角色、資料來源） |
| `bdd-docs/{feature-id}/review.md` | 審核結論與發現 |
| `bdd-docs/{feature-id}/reviews/` | 各輪審核的快照（由 hook 自動留存），供 `sdlc.ps1 learn` 讀取 |
| `bdd-docs/{feature-id}/evidence/` | 經核准的 DB 盤點結果（已遮蔽），請勿刪除 |
| `bdd-docs/{feature-id}/contract/` | 對外 API、事件或 schema 契約 |
| `bdd-docs/project-map.md` | 系統地圖與領域詞彙 |
| `bdd-docs/.sdlc/` | 升級基準線與備份，請勿刪除 |
| `bdd-docs/.cache/` | 索引快取與 hook 心跳，可隨時刪除；刪除後至 hook 再次執行前，`doctor` 可能誤報 hooks 未執行 |

- `.feature` 置於單元測試旁（C#：Reqnroll；Java：Cucumber；或沿用既有框架）。首行 `# feature-id:` 請保留。
- 修改既有 step 措辭屬破壞性變更，交付前會列出新舊對照。
- 每完成一個功能請 commit；`project-map.md` 依 commit 判斷變動範圍。
- DB 請使用唯讀帳號。

## 設定

專案根目錄的 `sdlc.config.json`：

| 鍵 | 預設 | 說明 |
| --- | --- | --- |
| `agents.<名稱>.model` | `inherit` | 可用值見 `sdlc.ps1 models` |
| `agents.<名稱>.effort` | `inherit` | `low`～`ultra`，依模型支援範圍而定 |
| `review.maxRounds` | `3` | 審核修正輪上限（1–5） |
| `update.check` | `daily` | `never` 停用更新檢查 |
| `update.source` | 安裝時帶入 | 更新來源（見〈升級〉） |

```powershell
pwsh .codex/scripts/sdlc.ps1 set agents.reviewer.effort=high -Apply
pwsh .codex/scripts/sdlc.ps1 set -Preset balanced   # fast／balanced／deep
pwsh .codex/scripts/sdlc.ps1 tune                   # 依 repo 規模提出建議，不自動套用
```

- `set` 先驗證全部值再寫入；值不合法時整批不寫，並提示最接近的合法值。
- `agents.*` 須經 `apply`（或 `-Apply`）方生效；`review.*`、`update.*` 即時生效。
- 檔案不支援註解，說明請寫於 `_note`。檔案不存在等同全部採用預設值。
- model／effort 依本機 Codex 實際支援的清單（`codex debug models`）驗證；委派前 `handoff-lint` 會再依當下模型檢查一次。
- `orchestrator` 欄位僅供記錄，主對話的模型須於啟動 Codex 時指定。

## 團隊規範

`guidelines/` 為選用目錄，可用 git submodule 跨 repo 共用。

- `*.md`：需判斷的規範，分列於 `## MUST`／`## SHOULD`。違反 MUST 於審核判為必修。
- `rules.json`：可機械判定的規則，寫檔後由 `guideline-gate` 掃描；`severity: block` 將阻擋寫入。
- 驗證規則：`pwsh -NoProfile -File .codex/scripts/guideline-gate.ps1 -Validate`。
- 暫停檢查：建立 `guidelines/.gate-disabled`（規範）或 `bdd-docs/.dlp-disabled`（DLP）。
- 由審核歸納規範：`pwsh .codex/scripts/sdlc.ps1 learn` 列出各需求、各輪的審核發現（唯讀）。於 Codex 中要求「把審核一再抓到的問題整理成規範」，會將兩個以上需求共有的問題起草為 `rules.json` 規則或 `*.md` 條文，經使用者確認後寫入。

## VS Code extension（選用）

提供設定面板、狀態列、Problems 標示與常用指令；所有功能皆可改以 `sdlc.ps1` 完成。詳見 [vscode-extension/README.md](vscode-extension/README.md)。

```powershell
code --install-extension codex-sdlc-{版本}.vsix
```

狀態列的綠勾不代表 hooks 已信任；偵測到 hooks 未執行時，狀態列顯示「hooks 沒在跑」。

## 升級

- **使用 extension**：點選狀態卡片下方的「升級」。下載後驗證 sha256，列出變更檔案，經確認後執行；不會降級。
- **不使用 extension**：解壓新版後執行 `pwsh <新版目錄>/.codex/scripts/sdlc.ps1 update -Target <專案路徑>`；加 `-Preview` 僅列出計畫。

說明：

- 使用者改過的檔案會先備份至 `bdd-docs/.sdlc/backup-{舊版}/`。`guidelines/` 不變動；`sdlc.config.json` 僅補足新欄位與空白的 `update.source`。
- `hooks.json` 變更後須重新信任。`update` 不會重新安裝 extension。
- 檢查新版：`sdlc.ps1 check-update`；變更內容：`sdlc.ps1 whatsnew` 或 [CHANGELOG.md](CHANGELOG.md)。
- `update.source` 格式：
  - 公開主機直接寫：`https://github.com/<owner>/<repo>`、`https://gitlab.com/<group>/<project>`。
  - 自架主機須標明類型：`gitea:<url>`（含 Forgejo）、`gitlab:<url>`、`github:<url>`。
  - 發佈頁須有正式版，tag 為 `v<版本>`，附件為 `codex-sdlc-<版本>.zip`。
- 私有 repo 的 token 放在環境變數 `CODEX_SDLC_TOKEN_<主機>`（主機名轉大寫，非英數字元改為 `_`）。token 僅送往該主機，不寫入任何設定檔。

## 疑難排解

| 現象 | 處理 |
| --- | --- |
| 違規內容未被阻擋、亦無訊息 | hooks 未信任；執行 `doctor -CheckHookTrust` 並依提示處理 |
| `doctor` 回報「hooks 好像沒在跑」，或狀態列顯示「hooks 沒在跑」 | 於專案中啟動 `codex` 並信任 hooks；已信任者，確認 Codex 可執行 `pwsh`。若所列產出檔為手動修改，可忽略 |
| `doctor` 回報 `.codex/hooks.json` 不存在 | 執行 `update -Target <專案>` 或於面板補回工具檔，再重新信任 |
| `doctor` 回報缺少 git、JDK、.NET SDK 等 | 依提示安裝；勿為遷就本機修改 `global.json` |
| 委派被擋：`missing-spec-ref` | 先完成 ③ |
| 委派被擋：`review-loop-exceeded` | 達修正輪上限，由使用者決定後續 |
| 委派被擋：`handoff-too-long` | 改傳檔案路徑，勿貼全文 |
| 委派被擋：`connection-string`／`secret-literal` | 自來源移除敏感值 |
| 委派被擋：`effort-unsupported` | 以 `set … -Apply` 修正後重新委派 |
| 寫檔被擋：`[Hook][Guideline]` | 依規則修正，或將規則降為 `warn` |
| `set` 拒絕寫入 | 依提示修正值；含註解時改寫於 `_note`，或加 `-Yes`（先備份） |
| 逾時 | 縮小範圍後重試 |
| ② 將已註解的舊程式視為現況 | 刪除 `project-map.md` 首行 `<!-- git-sha: … -->` 以觸發完整重查 |
| VS Code 未顯示 Codex SDLC | 確認 extension 已安裝、工作區已信任，再執行 `Developer: Reload Window` |
