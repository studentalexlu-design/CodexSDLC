## 為什麼一定要做這一步

Codex **不會跑它沒信任過的 hooks，而且不會告訴你**。沒信任的話，`handoff-lint`、`dlp-gate`、`guideline-gate`、`build-check` 一條都不跑 —— 流程照常進行、畫面一切正常，只是沒有任何東西在擋。

按左邊的按鈕，會在專案目錄開一個終端機跑 `codex`：

1. 問你要不要信任這個資料夾 → **信任**
2. 出現「Hooks need review」→ 選 **Trust all and continue**

做完關掉終端機，設定面板的「狀態」會自動重新檢查，應該顯示「Codex hooks：N 條都已信任」。

信任記在你的 `~/.codex/config.toml`：換一台機器、專案搬了目錄、或升級改到 `hooks.json`，都要再做一次。

找不到 `codex` 的話，設定面板的「這台機器 → codex」可以指定它的位置。
