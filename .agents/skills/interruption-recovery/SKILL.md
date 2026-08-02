---
name: interruption-recovery
version: 2.0.0
description: "Use when: a subagent returns blocked, is cancelled, times out, returns partial, or the conversation resumes after an interruption."
user-invocable: false
---

# Interruption Recovery Skill

## 使用時機

- 子代理回傳 `Canceled`、`Timeout`、`error`、`network error`、`net::ERR_EMPTY_RESPONSE` 或無回應。
- 子代理回傳 `partial`，或產物只寫了一半。
- reviewer 連續中斷。
- 中斷後續跑，不確定做到哪裡。

## 先分清楚：傳輸失敗 vs `blocked`

**這兩者的處理方向相反，分錯會白花一次 spawn。**

| | 傳輸失敗 | `blocked` |
|---|---|---|
| 長什麼樣 | `net::ERR_EMPTY_RESPONSE`、`ECONNRESET`、timeout、Canceled | 子代理明確回 `blocked` 並給了理由 |
| 意義 | 子代理**沒有做出判定** | 子代理**做出了判定**：需要裁定、批准，或撞到無界未知 |
| 能不能用同一個 prompt 重試 | 可以（但要壓縮） | **不行** —— 它的 context 已含自己上一輪的拒絕結論，重試只會複誦同一句 |

### 傳輸失敗

1. **不得靜默停止**，也**不得**用同一個 prompt 立即重試。
2. 先看目標產物存不存在、寫到什麼程度 —— 判斷有沒有部分成果。
3. 以 `Codex user confirmation` 讓使用者選：壓縮後重試一次／暫停／✏️ 自行輸入。
4. 壓縮重試只要求**最小可恢復的那一片**，而且必須比原 prompt 短。第二次仍失敗則停止委派。

### `blocked`

1. 先判阻塞在哪一側：
   - **子代理側**（範圍不清、參數錯、缺 `spec.md` 路徑、handoff 漏欄位）→ 修正 handoff 就能解。
   - **外部側**（harness 閘門、工具不存在、來源是二進位、需要使用者批准）→ 再跑幾次結果都一樣，先解決外部原因。
2. **不得續跑同一個子代理實例。** 復原一律是**新 spawn ＋ 修正過的 handoff**。
3. 新 handoff 必須明列**「這次和上次差在哪」**：補上的批准、收斂後的範圍、更正的參數。**差異寫不出來就不要重試** —— 那是註定重複的一次消耗。
4. 同一個 `blocked` 理由連續兩次沒解決 → 停止委派，以 `Codex user confirmation` 交回使用者。

## Reviewer 中斷

第一次中斷後重呼叫時縮小 prompt：只給檔案路徑、審核焦點最多 3 項、要求 `VERDICT` 第一行輸出。

第二次仍中斷 → orchestrator 自己做一次最小審核（只看「測試有沒有真的測到東西」），降級 PASS 前必須以 `Codex user confirmation` 取得使用者同意。

## 子代理回 `partial`

1. 讀它寫的「做完了／沒做完」。
2. 以 `Codex user confirmation` 提供：繼續下一片／先審核已完成的部分／暫停／✏️ 自行輸入。
3. 若繼續，新 spawn 帶上「已完成的部分」與「下一件最小的事」。

## 中斷後續跑

這套流程是無狀態的，所以續跑不靠狀態檔，靠這三樣，依序：

1. **`bdd-docs/{feature-id}/spec.md`** —— 需求與驗收條件都在裡面，這是唯一必須存在的東西。
2. **實際的程式碼與測試** —— 跑一次測試就知道做到哪了。
3. 使用者。

**`spec.md` 不在就從 ① 重跑。** BA 是純推理，幾乎免費；只有 SA 要重付一次 spawn。不要為了省那一次而猜使用者原本決定了什麼。
