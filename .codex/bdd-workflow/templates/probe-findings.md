# Template: probe-findings.md

探索 run（`tier: probe` / `tier: spike`）的**唯一交接產物**。

> **硬上限 2000 字元。** 這不是格式偏好，是成本結構：交付 run 會全文讀入本檔，因此本檔的每個字元都會在交付 run 的**每一輪重送**。
> **只列結論，不列探索過程。** 過程敘述在探索 run 結束時已無殘餘價值；把它寫進來等於讓一段死掉的對話在整個交付 run 收租。
> 探索 run 的 transcript 隨 run 結束一起丟棄 —— 本檔是它唯一的遺產。

---

## 段落順序固定（不得改寫）

```markdown
# Probe Findings — {run-id}

## 探索問題
{開工前不知道的是什麼。1-2 行。}

## 事實
{只寫查證後的結論，每條附 evidence ref（path / 物件名 / 行範圍）。}
- {fact}｜ref: {path or object}
- {fact}｜ref: {path or object}

## Tier 判定
tier: {t0|t1|t2|t3}
理由: {命中哪一個不可逆性問題。1-2 行。}

## 行為數（N）
N: {整數}
{>10 時註明建議的拆 run 切法。}

## 修正因子
V: {auto|manual|prod-only}
P: {none|pii|payment|credential}

## 未解決風險
- {risk}｜{是否阻塞交付 run 起跑}

## 交付 run 起跑指令
{一段可直接貼給新對話的最小指令：目標、tier、N、本檔路徑。}
```

---

## 撰寫規則

| 規則 | 理由 |
|---|---|
| 每條事實必須附 evidence ref | 交付 run 不會重跑探索。沒有 ref 的事實在交付 run 裡無法查證，等於沒查過 |
| 不貼 schema 全文、不貼程式碼片段 | 貼 path 與物件名。全文會撐爆 2000 字元上限，且交付 run 需要時可自行讀 |
| 不寫「我檢查了 X，發現…」 | 只寫「X 是…」。過程主詞是純成本 |
| `tier` 必須是六個 enum 值之一 | `handoff-lint` 會驗證交付 run 的 `tier:` 欄位 |
| 不含 credentials、連線字串、DLP mapping table | secret safety 不因 tier 放寬 |
| 未解決風險必須標明是否阻塞 | 阻塞項未清空前不得開交付 run |

## 超出 2000 字元時

**不要壓縮字句 —— 那代表探索範圍過寬。** 正確處理是二選一：

1. 事實太多 → 探索問了不只一件事。拆成多個 probe run，各自帶自己的 findings。
2. 事實太細 → 交付 run 不需要這個粒度。只留「足以判定 tier 與 N」的層級，其餘留在原始 artifact 由交付 run 按需讀。
