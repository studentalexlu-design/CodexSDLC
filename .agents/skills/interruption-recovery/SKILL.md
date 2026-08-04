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

## 先分清楚：工作量逾時 vs 傳輸失敗 vs `blocked`

**三者的處理方向不同，分錯會白花一次 spawn。**

| | 工作量逾時 | 傳輸失敗 | `blocked` |
|---|---|---|---|
| 長什麼樣 | 跑很久之後才 timeout —— 它一直在做事，只是沒做完 | `ERR_EMPTY_RESPONSE`、`ECONNRESET`、幾乎立刻斷、Canceled | 明確回 `blocked` 並給了理由 |
| 意義 | 任務**比它的時間大** | 子代理**沒有做出判定** | 子代理**做出了判定**：需要裁定、批准，或撞到無界未知 |
| 怎麼救 | **砍範圍** | 壓縮 prompt 後重試一次 | 修 handoff，或先解決外部原因 |

### 工作量逾時

**這是最容易救錯的一種。** 症狀跟傳輸失敗長得一樣（都是 timeout），原因卻相反：不是話沒傳到，是活太多。

**壓縮 prompt 對它完全沒有用** —— prompt 短了，要讀的檔還是那些。同一個範圍重試第二次，結果一樣 timeout，而你又燒掉一次 spawn。

正確的復原是**把任務切小**，而且要切在「切完仍然有用」的地方：

| 誰逾時 | 怎麼切 |
|---|---|
| `sa-analyst` | 限定這次只看哪幾個目錄／哪一份舊實作，明說「只要 2 個做法，工估得粗也可以」 |
| `implementer` | 一次一個可獨立驗收的行為 |
| `reviewer` | 焦點最多 3 項，只給檔案路徑，要求 `VERDICT` 第一行輸出 |

給使用者的選項**必須包含「縮小範圍再跑一次」**，不能只有「壓縮後重試／暫停」。**只給壓縮重試，等於把使用者推向放棄整套流程。**

### 傳輸失敗

1. **不得靜默停止**，也**不得**用同一個 prompt 立即重試。
2. 先看目標產物存不存在、寫到什麼程度 —— 判斷有沒有部分成果。
3. 以 `Codex user confirmation` 讓使用者選：壓縮後重試一次／縮小範圍再跑一次／暫停／✏️ 自行輸入。
4. 壓縮重試只要求**最小可恢復的那一片**，而且必須比原 prompt 短。**第二次仍失敗 → 改走「工作量逾時」的切法，不要再壓縮第三次。**

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
2. **`bdd-docs/{feature-id}/evidence/`** —— DB 盤點結果。**有這個就絕對不要重查 DB**：那要再花一次使用者批准、一次連線、一次等待，而答案已經在檔案裡了。
3. **`bdd-docs/{feature-id}/analysis.md`** —— `sa-analyst` 上次沒做完時留下的現況與做法。**有這個就從它接續，不要叫 SA 從頭重讀 repo** —— 那是逾時最常發生的地方。
4. **實際的程式碼與測試** —— 跑一次測試就知道做到哪了。
5. 使用者。

**`spec.md` 不在就從 ① 重跑。** BA 是純推理，幾乎免費；只有 SA 的靜態分析要重付一次 spawn（evidence 還在的話，DB 那段不用重付）。不要為了省那一次而猜使用者原本決定了什麼。
