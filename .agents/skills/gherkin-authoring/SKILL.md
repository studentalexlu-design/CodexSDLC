---
name: gherkin-authoring
version: 2.0.0
description: 撰寫 Gherkin 驗收條件與 step definitions；.feature 是交付給 QA 做自動化的產物
---

# Gherkin Authoring Skill

**`.feature` 不是文件，是交付給 QA 的產物。** QA 會在上面建自動化、加新的 scenario、沿用你寫的 step。所有取捨都從這一點推導。

## Scenario 怎麼寫

- **宣告式，不是操作手冊。** `When 客戶送出取消要求`，不是 `When 使用者點擊「取消」按鈕然後在對話框按確定`。UI 會改，業務規則不會。
- Feature 對業務能力；Rule 對業務規則；Scenario 對具體範例。
- **一個 Scenario 一條規則。** 塞兩條的那個，之後壞掉時你不知道是哪一條壞了。
- 同型資料多筆 → `Scenario Outline` + `Examples`，不要複製貼上。
- **例外路徑要有自己的 Scenario。** 只寫 happy path 的驗收條件等於沒寫 —— 出事的都在例外路徑。
- 非功能需求能轉成可驗證條件就轉（「3 秒內回應」可以驗，「效能要好」不行）。

## Step definitions 怎麼寫

這裡是 QA 真正會碰的地方，也是最容易長成維護坑的地方。

1. **為重用而寫。** QA 會加新 scenario 沿用你的 step。一次性的 step（只被一個 scenario 用、措辭綁死該情境）會逼他們自己再造一套詞彙，最後系統裡有兩套講法。
2. **step 措辭是介面。** 想好再定，因為改它就是破壞性變更（見下）。
3. **業務邏輯不要堆在 step 裡。** `Given`／`When`／`Then` 只負責前置、動作、斷言；邏輯在被測系統裡。
4. **共用狀態用 constructor injection 或 scenario context**，不要用 static。平行執行會炸。
5. 加新 step 前**先看既有的能不能用**。詞彙分岔是漸進發生的，一次一個看不出來。

## 改既有 step 的措辭是破壞性變更

QA 的自動化綁在 step 的文字上。改掉 `When 客戶送出取消要求` 的措辭，他們的測試會**靜默斷掉，而且斷在他們的 repo**。

這命中主流程的不可逆性判斷：**有你控制不了的消費者會看到差異嗎？** 是。所以：

- 改既有 step 的措辭 → 交付前**必須**停下來讓使用者決定
- 加新 step、加 scenario、改實作 → 不是破壞性變更，照常走
- 真的要改 → 在回傳裡列出「哪些 step、舊措辭、新措辭」，讓使用者能轉達給 QA

## 框架與落點

- **C#** → Reqnroll｜**Java** → Cucumber。專案已經在用別的就沿用既有的，不要引入第二套。
- `.feature` 跟**該專案的單元測試放在一起**。先找測試在哪（`*Tests.csproj`、`src/test/java/…`），再放進去。
- 已經有 `.feature` 檔的話，**沿用既有的目錄結構與命名慣例** —— 不要在旁邊另開一套。

## 逐字落地

`spec.md` 裡經使用者確認的 Gherkin 區塊，**Given／When／Then 的步驟文字必須逐字落成 `.feature`**。

可以加：tag、`Background`、`Examples` 表、註解。
不可以：改寫已確認的步驟措辭。使用者批准的是那些字，QA 拿到的也該是那些字。

真的需要改（例如措辭在技術上無法繫結）→ 回報並說明，由使用者重新確認，**不要自己改完就當沒事**。
