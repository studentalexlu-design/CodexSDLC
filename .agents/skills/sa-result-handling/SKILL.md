---
name: sa-result-handling
version: 1.0.0
description: ② orchestrator 收到 sa-analyst 回傳後怎麼接。用於：sa-analyst 回 blocked（要 live DB、需求還很空、來源待確認）或 partial 時的重新委派
---

# sa-analyst 回來之後

**這裡每一條都是「下一次委派要帶什麼」。** 帶漏了不會報錯，只會讓下一個 `sa-analyst` 從頭重讀整個 repo，或讓你在沒有批准的情況下往前走。

## 回 `blocked`

- **說需要 live DB** → **你先取得使用者批准，然後自己查** —— 載入 skill `db-introspection`，照它的規則做唯讀盤點，結果落成 `bdd-docs/{feature-id}/evidence/db-*.md`，再把那個 path 補進 handoff 重新委派。**沒有使用者的明確批准，一次查詢都不能發**；skill 那三條「立刻落檔、一次一物件、寫入前先遮蔽」不是建議。
- **說需求還很空** → 回 ① 起草。
- **說有「來源待確認」** → 回 ① 問來源。
- 後兩種的現況它都已經寫進 `current-state.md`，回 ① 時直接用，**不要再委派一次 `survey`**。

## 中途停下（`blocked`／`partial`）

- 分析會落在 `bdd-docs/{feature-id}/analysis.md`。**重新委派時把那個 path 一起帶上**，否則下一個 `sa-analyst` 會從頭重讀整個 repo。
- 回 `partial` 而「風險與待確認」沒有要問人的問題 → 不問，直接再委派一次；**第二次 `partial` 才問**（skill `interruption-recovery`）。
