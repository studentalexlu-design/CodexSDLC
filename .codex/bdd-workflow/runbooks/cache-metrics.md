# Cache Metrics Runbook

目標：量測成本優化是否有效，避免只靠體感判斷。

> **先量對的東西。** 舊版本量的是代理指標（handoff 字數、模板採用率），
> 那些不是成本主因。主因是**每次 spawn 的固定成本 × spawn 次數**。

## 指標定義

### 主要成本驅動因子（優先量這三個）

- **`spawns-per-run`** —— 該 run 的子代理呼叫總次數。
  每次 spawn 約 4,000–8,000 tokens 的固定成本（系統提示 + policy + runbook + handoff），
  在做任何實際工作之前就已支出。**這是最大的單一成本來源。**
- **`fixed-cost-per-spawn`** —— 系統提示 tokens + 必讀 policy／runbook tokens。
  可用 `.codex/scripts/agent-lint.ps1` 搭配檔案大小估算，不需實際執行流程。
- **`total-tokens-per-run`（依 profile）** —— 對照 `route-profiles` 的 5／12／20 上限是否成立。

### Cache 相關

- **`same-agent-repeat-count`** —— 同一 agent 在單一 run 內被呼叫幾次。
  **這是唯一的 cache 機會窗口**（跨 agent 永遠不共用 cache，見 `policies/cache-stability-policy.md`）。
  數值越高，系統提示的快取效益越大。
- **`agent-toml-modified-during-run`** —— run 進行中是否修改過 agent 檔（應為 0）。
  非 0 代表該 agent 的 cache 被作廢。

### Effort 相關

- **`reasoning-tokens-by-effort`** —— 依 `high`／`medium`／`low` 分組的 reasoning token 量。
  effort 影響成本的管道是 output/reasoning tokens，不是 cache。

### 既有指標（保留）

- `handoff-length-chars`、`handoff-template-adoption-rate`
- `artifact-full-read-count`、`checkpoint-resume-steps`
- `partial-same-slice-repeat-count`

## 目標值（建議）

| 指標 | 目標 |
|---|---|
| `spawns-per-run` | ≤ profile 的 `max-subagent-calls`（lite 5／standard 12／full 20）|
| `fixed-cost-per-spawn` | ≤ 6,000 tokens |
| `agent-toml-modified-during-run` | 0 |
| `handoff-template-adoption-rate` | ≥ 90% |
| `artifact-full-read-count` | 較基準下降 ≥ 40% |
| `checkpoint-resume-steps` | ≤ 3 |
| `partial-same-slice-repeat-count` | 0 |

## 量測方法

1. 選 2 到 3 條代表性流程（lite 全程、standard 全程、full 的 analyst+tdd 段）。
2. 在優化前後各跑一次，記錄上述指標。
3. 只記錄摘要數字與證據 path，不貼完整 log。
4. `fixed-cost-per-spawn` 可離線估算：

```powershell
# 各 agent 系統提示的 token 估算
Get-ChildItem .codex\agents\*.toml | ForEach-Object {
  $t = Get-Content $_.FullName -Raw
  $cjk = ([regex]::Matches($t,'[\p{IsCJKUnifiedIdeographs}]')).Count
  [pscustomobject]@{ Agent=$_.BaseName; EstTokens=[int]($cjk + ($t.Length-$cjk)/3.5) }
} | Sort-Object EstTokens -Descending
```

## 偵錯優先序

1. **`spawns-per-run` 超標** —— 檢查是否該升／降 profile、是否有純狀態更新被誤委派給 `living-doc`
   （那些應由 orchestrator 直寫）、合併模式（`mode: all`）是否被正確使用。
2. **`fixed-cost-per-spawn` 超標** —— 檢查 agent 是否讀了非 active mode 的 runbook、
   是否內嵌了應該只傳路徑的 policy 全文。
3. `handoff` 是否使用 `templates/` 模板且段落順序為靜態在前。
4. 是否攜帶 artifact path/version/digest（而非全文）。
5. `partial-completed` 是否附 `next-step` 與 `checkpoint-recommended`。
6. 同 turn 是否重複委派同一切片。

## 回報格式

```yaml
cache-metrics:
  flow: {flow-name}
  profile: lite | standard | full
  before:
    spawns-per-run: {N}
    fixed-cost-per-spawn: {N}
    total-tokens-per-run: {N}
    same-agent-repeat-count: {agent: N, ...}
    reasoning-tokens-by-effort: {high: N, medium: N, low: N}
    agent-toml-modified-during-run: {N}
    handoff-template-adoption-rate: {N%}
    artifact-full-read-count: {N}
  after:
    # 同上欄位
  verdict: improved | unchanged | regressed
```
