## 三組預設

| 組合 | 適合 | 重點 |
|---|---|---|
| **fast** | 小 repo、趕時間 | sa-analyst 淺、reviewer 中 |
| **balanced** | 大多數專案 | 只有 reviewer 釘 high |
| **deep** | 規則多、錯不起 | 各 agent 往上調，但 sa-analyst 不到 high |

sa-analyst 從來不會被推到 high：大型 legacy repo 的分析在 high 會逾時 —— 它的失敗模式是讀不完，不是想得不夠深。

按下去之後會先列出**會改哪些值**，確認了才寫進 `sdlc.config.json`，寫完自動套用到 agent 定義。

不確定選哪組？設定面板的「tune」會依 repo 規模給建議，你勾選要套用哪幾個。
