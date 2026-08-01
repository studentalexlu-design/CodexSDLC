# handoff-lint.ps1
# 在 subagent spawn 前機械強制 handoff contract。把 prompt 裡的「規則」
# 變成「保證」—— 這是 token 預算唯一不依賴模型自律的環節。
#
# 檢查項：
#   1. handoff 長度 <= MaxChars（預設 1200）
#   2. 單一 operation mode（不得同時出現多個 mode 宣告）
#   3. 必填 meta 欄位：mode、tier（tier ∈ probe|spike|t0|t1|t2|t3）
#   3a. t0 不得 spawn（上限 0）—— 需要 spawn 即代表判定過低，應升 t1
#   3b. 探索 tier（probe/spike）不得掛交付型 mode —— 探索只產事實，不碰 production code
#   3c. 單點紀錄型 mode 不得委派（checkpoint 等）—— 事實已在 orchestrator 手上，
#       委派省不到讀取只多付一次 spawn
#   4. 禁用 payload：完整 log、完整 source register、長測試輸出、secrets
#   5. quality-loop 迭代上限（讀 workflow-state.json，超限即阻斷）
#   6. tier 的 max-subagent-calls 上限（spawn 次數是成本主導變數，
#      上限值一律從 route-profiles.json 讀取，不在本檔重複宣告）
#   7. successor／linked run 必須繼承 parent 的 subagent-calls.count
#      （額度用滿就開下一個 run 是繞過上限最省力的路徑）
#
# Exit: 0 = 通過；2 = 違規（阻斷 spawn）。

[CmdletBinding()]
param(
    [string]$Payload,
    [int]$MaxChars = 1200,
    [int]$MaxQualityLoopIterations = 3,
    [string]$RouteProfilesPath = '.codex/bdd-workflow/route-profiles.json',
    [switch]$Json
)

if (-not $Payload) { $Payload = [Console]::In.ReadToEnd() }
if (-not $Payload) { exit 0 }

$violations = @()

# --- 抽出 handoff prompt 本體 ---
# hook payload 是 JSON；prompt 通常在 "prompt" 欄位。抓不到就退回整包長度。
$prompt = $Payload
$m = [regex]::Match($Payload, '"prompt"\s*:\s*"((?:[^"\\]|\\.)*)"')
if ($m.Success) { $prompt = $m.Groups[1].Value -replace '\\n', "`n" -replace '\\"', '"' }

# --- 1. 長度 ---
if ($prompt.Length -gt $MaxChars) {
    $violations += [pscustomobject]@{
        rule = 'handoff-too-long'
        detail = "$($prompt.Length) chars > $MaxChars"
        fix = '先委派 living-doc 編譯 context pack，或改以更小切片委派'
    }
}

# --- 2. 單一 mode ---
$modes = [regex]::Matches($prompt, '(?im)^\s*[-*]?\s*mode\s*:\s*([a-z0-9-]+)') |
    ForEach-Object { $_.Groups[1].Value.ToLower() } |
    Sort-Object -Unique
if ($modes.Count -gt 1) {
    $violations += [pscustomobject]@{
        rule = 'multiple-modes'
        detail = ($modes -join ', ')
        fix = '一次 handoff 只描述一個 operation mode'
    }
}

# --- 3. 必填 meta ---
if ($modes.Count -eq 0) {
    $violations += [pscustomobject]@{ rule='missing-mode'; detail='no mode: field'; fix='meta 區塊補 mode' }
}
$tier = if ($prompt -match '(?im)^\s*[-*]?\s*tier\s*:\s*(probe|spike|t0|t1|t2|t3)\b') { $Matches[1].ToLower() } else { $null }
if (-not $tier) {
    $violations += [pscustomobject]@{
        rule = 'missing-tier'
        detail = 'no tier: probe|spike|t0|t1|t2|t3'
        fix = 'meta 區塊補 tier；缺 tier 時子代理會退回 t3（最嚴格），成本最高'
    }
}

# t0 的 max-subagent-calls 是 0 —— 任何 spawn 都是判定過低的證據。
# 這裡明確擋下並給出正確處置，而不是讓它落到下方的通用預算檢查（那時 run 狀態檔可能還不存在）。
if ($tier -eq 't0') {
    $violations += [pscustomobject]@{
        rule = 't0-must-not-spawn'
        detail = 'tier: t0 的委派上限為 0'
        fix = 't0 由 orchestrator 自行實作。需要 spawn 代表判定過低 —— 升 t1，不要加 spawn'
    }
}

# 單點紀錄不得委派：checkpoint／Gate confirmation／decision-log／DLP 標記／DB 授權紀錄
# 的事實在使用者確認或 doer 回傳時已在 orchestrator 手上，委派買不到任何讀取節省。
# 這些 mode 自 contract v2.1.0 起不存在於任何子代理。
$stateOnlyModes = @('checkpoint', 'decision-log', 'gate-record', 'runtime-metadata')
$stateHit = @($modes | Where-Object { $_ -in $stateOnlyModes })
if ($stateHit.Count -gt 0) {
    $violations += [pscustomobject]@{
        rule = 'state-only-mode-delegated'
        detail = "mode=$($stateHit -join ',')"
        fix = 'orchestrator 自行寫入（所有 tier），欄位見 runbooks/checkpoint-schema.md。需要跨階段彙整才委派 living-doc mode: context-pack'
    }
}

# 探索 run 不得碰 production code：交付型 mode 不得掛在探索 tier 下。
if ($tier -in @('probe', 'spike')) {
    $deliveryModes = @('slice', 'skeleton', 'feature', 'contract', 'foundation', 'elaboration', 'migration', 'all', 'review')
    $hit = @($modes | Where-Object { $_ -in $deliveryModes })
    if ($hit.Count -gt 0) {
        $violations += [pscustomobject]@{
            rule = 'discovery-tier-delivery-mode'
            detail = "tier=$tier mode=$($hit -join ',')"
            fix = '探索 run 只產事實，不產 production code。改用 probe/metadata/definition/glossary/sql-logic-extraction/spike，或先結束探索 run 再開交付 run'
        }
    }
}

# --- 4. 禁用 payload ---
$forbidden = @(
    @{ rule='full-operation-log';      pattern='(?s)##\s*log\.md.{2000,}' }
    @{ rule='long-test-output';        pattern='(?m)^\s*(Passed|Failed|Skipped)!?\s+-\s+Failed:.*(\r?\n.*){40,}' }
    @{ rule='connection-string';       pattern='(?i)(Server|Data Source)\s*=[^;]+;\s*(Initial Catalog|Database)\s*=' }
    @{ rule='secret-literal';          pattern='(?i)\b(api[_-]?key|password|pwd|secret|bearer)\s*[:=]\s*["'']?[A-Za-z0-9_\-\.]{12,}' }
    @{ rule='dlp-mapping-table';       pattern='(?s)\{\{[A-Z_]+_\d+\}\}\s*(=>|->|:)\s*\S+' }
)
foreach ($f in $forbidden) {
    if ($prompt -match $f.pattern) {
        $violations += [pscustomobject]@{ rule=$f.rule; detail='禁用 payload 命中'; fix='只傳 path/version/digest 與 <=500 字摘要' }
    }
}

# --- 5 & 6. run 狀態相關檢查（一次讀取，兩項檢查）---
$runId = if ($prompt -match '(?im)^\s*[-*]?\s*run-id\s*:\s*(\S+)') { $Matches[1] } else { $null }
if ($runId) {
    $statePath = "bdd-docs/runs/$runId/workflow-state.json"
    if (Test-Path $statePath) {
        try {
            $state = Get-Content $statePath -Raw | ConvertFrom-Json

            # --- 5. quality-loop 上限 ---
            $iter = $state.'quality-loop'.iteration
            $last = $state.'quality-loop'.'last-verdict'
            if ($null -ne $iter -and $iter -ge $MaxQualityLoopIterations -and $last -eq 'FAIL') {
                $violations += [pscustomobject]@{
                    rule = 'quality-loop-exceeded'
                    detail = "iteration=$iter last-verdict=FAIL"
                    fix = '禁止再呼叫 doer+reviewer；必須以 Codex user confirmation 升級使用者裁定'
                }
            }

            # --- 6. max-subagent-calls 上限 ---
            # 已用次數由 orchestrator 於每次 spawn 後遞增（比照 quality-loop）。
            # 上限值從 contract 讀取，避免本檔成為第二份會走鐘的預算宣告。
            $used = $state.'subagent-calls'.count
            if ($null -ne $used) {
                # tier 以 handoff 宣告優先，退回 run 狀態檔（resume 時 handoff 仍應帶 tier）。
                $stateTier = $state.'runtime-metadata'.tier
                $effTier = if ($tier) { $tier } else { $stateTier }
                $cap = $null
                try {
                    $rp = (Get-Content $RouteProfilesPath -Raw | ConvertFrom-Json).profiles
                    $rawCap = $null
                    if ($effTier) { $rawCap = $rp.$effTier.'max-subagent-calls' }
                    # tier 不明時退回 t3 的上限當天花板，不 hard-block 合法流程。
                    if ($null -eq $rawCap) { $rawCap = $rp.t3.'max-subagent-calls' }

                    # 上限可為數字，或 {base, per-behaviour}（只有按行為切片的 tier 用後者）。
                    # 物件形式：base + per-behaviour × min(N, 10)。N > 10 一律拆 run，故以 10 封頂。
                    # N 缺漏時以 10 計 —— 寬鬆側，寧可不擋也不要擋下合法流程。
                    if ($rawCap -is [System.Management.Automation.PSCustomObject]) {
                        $n = $state.'runtime-metadata'.'behaviour-count'
                        if ($null -eq $n -or $n -lt 1) { $n = 10 }
                        if ($n -gt 10) { $n = 10 }
                        $cap = [int]$rawCap.base + ([int]$rawCap.'per-behaviour' * [int]$n)
                    } else {
                        $cap = $rawCap
                    }
                } catch { }
                if ($null -ne $cap -and $used -ge $cap) {
                    $violations += [pscustomobject]@{
                        rule = 'subagent-budget-exceeded'
                        detail = "used=$used cap=$cap tier=$(if ($effTier) { $effTier } else { 'unknown(套用 t3 上限)' })"
                        fix = '停止委派；以 Codex user confirmation 讓使用者選擇升級 tier、拆成多個 run 或放寬切片。若原因是現況不明 → 開 probe run，不要升 tier'
                    }
                }
            }

            # --- 7. successor／linked run 的額度繼承 ---
            # 用滿額度就開下一個 run，是繞過上限最省力也最不留痕跡的路徑：
            # 新 run 的 count 從 0 起算，檢查 6 便永遠不會命中。唯一機械可查的
            # 錨點是 runtime-metadata.linked-from —— 宣告了 parent，就必須把
            # parent 的累計值帶過來（bdd-orchestrator 不變原則 5）。
            $linkedFrom = $state.'runtime-metadata'.'linked-from'
            if ($linkedFrom -and $null -ne $used) {
                $parentStatePath = "bdd-docs/runs/$linkedFrom/workflow-state.json"
                if (Test-Path $parentStatePath) {
                    try {
                        $parentUsed = (Get-Content $parentStatePath -Raw | ConvertFrom-Json).'subagent-calls'.count
                        if ($null -ne $parentUsed -and $used -lt $parentUsed) {
                            $violations += [pscustomobject]@{
                                rule = 'successor-budget-not-inherited'
                                detail = "count=$used parent($linkedFrom)=$parentUsed"
                                fix = '把 parent 的累計值寫入本 run 的 subagent-calls.count。額度上限的用意是逼你停下來重新界定範圍，不是逼你換一個 run 繼續'
                            }
                        }
                    } catch { }
                }
            }
        } catch { }
    }
}

# --- 輸出 ---
if ($Json) {
    [pscustomobject]@{
        passed = ($violations.Count -eq 0)
        violation_count = $violations.Count
        prompt_chars = $prompt.Length
        modes = $modes
        violations = $violations
    } | ConvertTo-Json -Depth 4 -Compress
}

if ($violations.Count -gt 0) {
    if (-not $Json) {
        [Console]::Error.WriteLine("[Hook][handoff-lint] $($violations.Count) violation(s), spawn blocked:")
        foreach ($v in $violations) {
            [Console]::Error.WriteLine("  - $($v.rule): $($v.detail)")
            [Console]::Error.WriteLine("    fix: $($v.fix)")
        }
    }
    exit 2
}
exit 0
