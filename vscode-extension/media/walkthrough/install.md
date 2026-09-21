## 這一步在做什麼

把工作流那半 —— `.codex/`（腳本、agent 定義、hooks）、`.agents/`（skills）、`AGENTS.md`（orchestrator 本身）—— 寫進這個資料夾。沒有它們，這套流程一條都不會跑。

按左邊的按鈕：

1. **先問發佈物來源有沒有新版**（VS Code 設定 `codexSdlc.releaseSource`，或內附發佈物版本檔裡的 `source`）。拿不到就用這個 extension 內附的那一份 —— 離線照樣裝得起來。
2. 下載回來的東西會逐檔比對 `manifest.json` 的 sha256，**驗不過就不拿它安裝**。
3. 列出會寫什麼、讓你確認，才動手。

**不會覆蓋你的東西：**

- 已經有的 `AGENTS.md` 不動，新版寫成 `AGENTS.md.new`，裝完會開左右對照讓你合併。**合併之前整套流程不會照這一版跑**。
- 已經有的 `guidelines/` 完全不碰；沒有才放一份骨架，而那份是你的，升級永遠不會覆蓋。
- 不動 `.git`，不動你的程式碼。

已經有一份解壓好的發佈物（或 `.zip`）的話，改用命令面板的 **Codex SDLC：選擇發佈物安裝…**。

裝好之後，`.codex/hooks.json` 要 Codex 那邊信任過才會真的擋 —— 在專案裡開一次 `codex`，出現「Hooks need review」時選 Trust all and continue。**這個面板不會替你確認那一項**（要確認：`sdlc.ps1 doctor -CheckHookTrust`）。
