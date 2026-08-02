# handoff-lint.ps1
# 在 subagent spawn 前機械強制 handoff contract。把 prompt 裡的「規則」變成「保證」。
#
# 檢查項：
#   1. handoff 長度 <= MaxChars（預設 1200）
#   2. 單一 operation mode（不得同時出現多個 mode 宣告）
#   3. 必填 meta：mode、feature-id
#   3a. 交付型 mode（build／fix／code）必須帶 spec.md 路徑 —— 沒有驗收條件就開工是最常見的返工來源
#   3b. 修正輪（mode: fix）必須帶 round；round > MaxReviewRounds 即阻斷
#   4. 禁用 payload：完整 log、長測試輸出、connection string、secret、DLP mapping table
#
# 自 v4.0.0 起移除：tier 相關檢查、t0 零 spawn、discover 交付型 mode、
# 單點紀錄 mode、subagent 預算上限、successor 額度繼承。
# 那些檢查全部服務於 12-agent 的扇出控制；agent 收斂到 5 個、流程改為線性之後
# 它們沒有防守對象了。細節見 docs/design-rationale.md。
#
# Exit: 0 = 通過；2 = 違規（阻斷 spawn）。

[CmdletBinding()]
param(
    [string]$Payload,
    [int]$MaxChars = 1200,
    [int]$MaxReviewRounds = 3,
    [switch]$Json
)

if (-not $Payload) { $Payload = [Console]::In.ReadToEnd() }
if (-not $Payload) { exit 0 }

$violations = @()

# --- 抽出 handoff prompt 本體 ---
# hook payload 的形狀由 harness 決定，可能是 {"prompt":...}、{"tool_input":{"prompt":...}}
# 或更深的巢狀。抽錯的後果是雙向的且都很嚴重：抽到整包 JSON 會讓 `^mode:` 這類
# 行首正則全部落空 —— 每一次 spawn 都被 missing-mode 擋死；反之若完全抽不到，
# 長度檢查會量到錯的對象。因此改為「先解析 JSON、遞迴找已知欄位名、取最長者」，
# 解析失敗才退回舊的 regex，最後才退回整包。
function Get-HandoffPrompt {
    param([string]$Raw)

    $fieldNames = @('prompt', 'instructions', 'input', 'text', 'message', 'content', 'arguments', 'description')

    try {
        $root = $Raw | ConvertFrom-Json -ErrorAction Stop   # ConvertFrom-Json 會一併解掉 \n 與 \"
        $best = ''
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($root)
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if ($null -eq $cur -or $cur -is [string] -or $cur -is [ValueType]) { continue }
            if ($cur -is [System.Collections.IEnumerable]) {
                foreach ($item in $cur) { $queue.Enqueue($item) }
                continue
            }
            foreach ($p in $cur.PSObject.Properties) {
                if ($p.Value -is [string]) {
                    if ($p.Name -in $fieldNames -and $p.Value.Length -gt $best.Length) { $best = $p.Value }
                } else {
                    $queue.Enqueue($p.Value)
                }
            }
        }
        if ($best) { return $best }
    } catch { }

    $m = [regex]::Match($Raw, '"prompt"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { return ($m.Groups[1].Value -replace '\\n', "`n" -replace '\\"', '"') }

    return $Raw
}

$prompt = Get-HandoffPrompt -Raw $Payload

# --- 1. 長度 ---
if ($prompt.Length -gt $MaxChars) {
    $violations += [pscustomobject]@{
        rule = 'handoff-too-long'
        detail = "$($prompt.Length) chars > $MaxChars"
        fix = '只傳 feature-id、mode、spec.md path 與 <=300 字決策摘要。產物內容由子代理自己讀 path'
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
if ($prompt -notmatch '(?im)^\s*[-*]?\s*feature-id\s*:\s*\S') {
    $violations += [pscustomobject]@{
        rule = 'missing-feature-id'
        detail = 'no feature-id: field'
        fix = 'meta 區塊補 feature-id —— 子代理靠它定位 bdd-docs/{feature-id}/ 底下的產物'
    }
}

# --- 3a. 交付型 mode 必須有驗收依據 ---
# implementer 與 reviewer 的工作全部錨定在 spec.md 的驗收條件上。
# 沒帶就開工 = 靠子代理猜使用者要什麼，那是最貴的一種返工。
#
# 必須是**路徑**（含 `/`），不能只是散文裡提到「依 spec.md 的驗收條件」——
# 後者是子代理讀不到的東西，放行等於這個檢查形同虛設。
$specAnchoredModes = @('build', 'fix', 'code')
$anchorHit = @($modes | Where-Object { $_ -in $specAnchoredModes })
if ($anchorHit.Count -gt 0 -and $prompt -notmatch '(?i)[\w.-]+/spec\.md') {
    $violations += [pscustomobject]@{
        rule = 'missing-spec-ref'
        detail = "mode=$($anchorHit -join ',') 但 handoff 沒有 spec.md 路徑"
        fix = '先完成流程 ③ 定案並寫出 bdd-docs/{feature-id}/spec.md，再委派。不要讓子代理自己猜驗收條件'
    }
}

# --- 3b. 修正輪上限 ---
# doer↔reviewer 的 ping-pong 是沒有自然終點的迴圈。輪次由 orchestrator 自報，
# 但機械檢查讓「第 4 輪」變成一個會被擋下的事件，而不是一個沒人注意到的數字。
if ($modes -contains 'fix') {
    $round = if ($prompt -match '(?im)^\s*[-*]?\s*round\s*:\s*(\d+)') { [int]$Matches[1] } else { $null }
    if ($null -eq $round) {
        $violations += [pscustomobject]@{
            rule = 'missing-round'
            detail = 'mode: fix 未帶 round'
            fix = 'meta 區塊補 round（第幾次修正輪，從 1 起算）'
        }
    } elseif ($round -gt $MaxReviewRounds) {
        $violations += [pscustomobject]@{
            rule = 'review-loop-exceeded'
            detail = "round=$round > $MaxReviewRounds"
            fix = '停止修正迴圈，以 Codex user confirmation 交回使用者裁定（接受現版本／指定重點跑最後一輪／暫停）'
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
        $violations += [pscustomobject]@{ rule=$f.rule; detail='禁用 payload 命中'; fix='只傳 path 與 <=300 字摘要' }
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
