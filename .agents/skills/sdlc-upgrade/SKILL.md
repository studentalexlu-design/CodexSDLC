---
name: sdlc-upgrade
version: 1.0.0
description: "Use when: 使用者要升級這套 Codex SDLC 工作流（「升級」「更新到新版」「裝 4.x.y」）。下載 → 列計畫 → 使用者確認 → 套用 → 收尾。"
---

# 升級這套工作流

跟 VS Code extension 的「升級」是同一條路，同一支腳本做事，你只負責**跑、講、等他點頭**。
不要自己解壓、複製檔案、改 `.codex/` —— 哪些檔是使用者改過的、要先備份，只有 `sdlc.ps1 update` 分得出來。

## 權限

- 第 1 步要**連網**，第 4 步要寫 `.codex/` 與 `AGENTS.md` —— 沙箱多半會擋。被擋就以提升權限（escalated）重跑，理由寫「升級 Codex SDLC 工作流」。
- 不能提升（approval 設成 never 之類）→ 不要繞，把那一行指令給使用者，請他自己在終端機跑，貼回輸出。

## 步驟

**1. 拿一份發佈物**

```
pwsh .codex/scripts/sdlc.ps1 fetch -Target . -Json
```

讀 `data`：`version`、`path`、`chosen`（remote｜cached｜bundled｜none）、`remote.latest`、`remote.reason`，以及 `warnings`。

- `path` 是空的，或 `remote.latest` 比 `version` 新（遠端有新版卻沒拿到）→ **停**，照下表講原因與下一步，把 `warnings[0]` 原文一起給他：

| `remote.reason` | 跟使用者說 |
|---|---|
| `no-asset` | 發佈頁那一版沒有附 `codex-sdlc-<版本>.zip`（Gitea／GitHub 自動產生的 Source code 不算）。發佈的人要把 `pack.ps1` 產出的 zip 上傳成附件 |
| `unreachable`／`download-failed` | 離線、逾時，或私有 repo 沒有設 `CODEX_SDLC_TOKEN_<主機>`（主機名大寫、非英數換成 `_`）。設完要重開 Codex／VS Code |
| `expand-failed`／`no-version-file`／`sha-mismatch` | 下載回來的東西不是一份完整的發佈物（常見：私有 repo 拿到的是登入頁、zip 多包了一層資料夾、解開改過再壓回去） |
| `unsupported-source`／`no-source` | 更新來源沒設或寫法不對：`pwsh .codex/scripts/sdlc.ps1 set update.source=gitea:https://…` |

- 他手上有 zip 或解壓好的資料夾 → 改用那一份：`pwsh .codex/scripts/sdlc.ps1 fetch -Target . -Json -NoRemote -Bundled <zip 或資料夾>`。

**2. 列計畫 —— 一個檔都不動**

用**發佈物自己的** `sdlc.ps1`（新版的規則在新版的腳本裡，不是專案裡這一支）：

```
pwsh <path>/.codex/scripts/sdlc.ps1 update -Target . -Preview -Json
```

- `data.result = up-to-date` → 已是最新，結束。
- `data.downgrade = true` → 那一份比專案舊，**不升**，告訴他。
- 其他 → 照實講給他聽，不要省略：
  - 從 `data.from` 升到 `data.to`；`data.breaking` 為真就**先講**，建議先看 `pwsh .codex/scripts/sdlc.ps1 whatsnew`、手上跑到一半的需求先跑完
  - `data.modified`：他改過的檔 —— 會先備份再覆蓋
  - `data.removed`：新版刪掉的檔 —— 備份後刪除
  - `data.added` 幾個新檔；`data.hooksChanged` 為真 → 升級後要重新信任 hooks
  - `guidelines/`、`bdd-docs/`、`sdlc.config.json` 不會被動
- 舊版發佈物不認得 `-Preview`（`result` 是 `cancelled`）→ 說「列不出計畫，改過的檔一樣會先備份」，照樣問。

**3. 等他明確說要升。** 沒說就不做，「好像可以」不算。

**4. 套用**

```
pwsh <path>/.codex/scripts/sdlc.ps1 update -Target . -Yes -Json
```

`data.result` 不是 `applied` → 把 `warnings` 原文給他，停。

**5. 收尾 —— 一次講完**

- `data.from` → `data.to`；`data.backup` 有值就說備份在哪。
- **這個對話還在用舊的 AGENTS.md** —— 新規則從下一個 Codex 對話才生效，請他開新對話再繼續原本的工作。
- `data.hooksChanged` 為真 → 重開 codex，出現「Hooks need review」時選 Trust all，不然強制層一條都不跑。
- `data.editor.mismatch` 為真且 `data.editor.vsix` 有值 → VS Code extension 還是舊版；給他 `code --install-extension "<vsix>" --force`，**問過才跑**（它是整台機器共用的），裝完要重新載入視窗。
