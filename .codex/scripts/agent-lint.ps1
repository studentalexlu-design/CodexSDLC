# agent-lint.ps1
# 驗證 agent 定義的結構完整性與共用核心一致性。
#
# 共用核心刻意內嵌在每個 toml（系統提示內，可跨同 agent 重複呼叫命中 cache），
# 而不是執行期讀共用檔。內嵌會帶來漂移風險 —— 本腳本把「重複」變成「被強制一致的重複」。
#
# 檢查項：
#   1. AGENT-CORE 區塊在所有 agent 中逐字相同
#   2. TOML 結構：''' 配對、必要 key 齊全
#   3. 每個 agent 都登錄於 agent-skill-matrix.json（且無多餘項）
#   4. 引用的 policy / runbook / script 路徑真實存在
#   5. 無已知的過時引用
#
# Exit: 0 = 全部通過；2 = 有違規。

[CmdletBinding()]
param(
    [string]$AgentDir = '.codex/agents',
    [string]$Matrix   = '.codex/bdd-workflow/agent-skill-matrix.json',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$violations = @()
function Add-V([string]$rule, [string]$detail, [string]$fix) {
    $script:violations += [pscustomobject]@{ rule = $rule; detail = $detail; fix = $fix }
}

$agents = @(Get-ChildItem $AgentDir -Filter *.toml -ErrorAction SilentlyContinue)
if (-not $agents) { Write-Error "no agent toml under $AgentDir"; exit 2 }

# ---- 1. AGENT-CORE 區塊逐字一致 ----
$coreRe = '(?s)<!-- AGENT-CORE:BEGIN.*?<!-- AGENT-CORE:END -->'
$cores = @{}
foreach ($a in $agents) {
    $t = Get-Content $a.FullName -Raw
    $m = [regex]::Match($t, $coreRe)
    if (-not $m.Success) {
        Add-V 'missing-agent-core' $a.Name '內嵌 AGENT-CORE 區塊（從任一現有 agent 複製）'
        continue
    }
    $cores[$a.BaseName] = ($m.Value -replace "`r`n", "`n")
}
if ($cores.Count -gt 1) {
    $ref = $cores[($cores.Keys | Sort-Object)[0]]
    foreach ($k in ($cores.Keys | Sort-Object)) {
        if ($cores[$k] -ne $ref) {
            Add-V 'agent-core-drift' $k '共用核心已漂移；與其他 agent 的區塊同步（必須逐字相同）'
        }
    }
}

# ---- 2. TOML 結構 ----
$requiredKeys = @('name', 'description', 'sandbox_mode', 'model_reasoning_effort', 'developer_instructions')
foreach ($a in $agents) {
    $t = Get-Content $a.FullName -Raw
    $q = ([regex]::Matches($t, "'''")).Count
    if ($q -ne 2) { Add-V 'toml-delimiter' "$($a.Name): ''' x$q" "developer_instructions 須恰好一組 ''' 界定" }
    foreach ($k in $requiredKeys) {
        if ($t -notmatch "(?m)^$k\s*=") { Add-V 'toml-missing-key' "$($a.Name): $k" "補上 $k" }
    }
    $declared = [regex]::Match($t, '(?m)^name\s*=\s*"([^"]+)"').Groups[1].Value
    if ($declared -and $declared -ne $a.BaseName) {
        Add-V 'name-mismatch' "$($a.Name): name=$declared" 'name 必須與檔名一致'
    }
}

# ---- 3. skill matrix 覆蓋 ----
if (Test-Path $Matrix) {
    try {
        $m = (Get-Content $Matrix -Raw | ConvertFrom-Json).'agent-skill-matrix'
        $inMatrix = @($m.PSObject.Properties.Name)
        $onDisk   = @($agents.BaseName)
        foreach ($d in $onDisk)   { if ($d -notin $inMatrix) { Add-V 'matrix-missing' $d '加入 agent-skill-matrix.json' } }
        foreach ($i in $inMatrix) { if ($i -notin $onDisk)   { Add-V 'matrix-orphan'  $i '該 agent 已不存在，從矩陣移除' } }
    } catch { Add-V 'matrix-unparsable' $Matrix '修正 agent-skill-matrix.json 的 JSON 格式' }
} else {
    Add-V 'matrix-missing-file' $Matrix '建立 agent-skill-matrix.json'
}

# ---- 4. 引用路徑存在性 ----
$refPatterns = @(
    @{ re = '`?(policies/[a-z0-9-]+\.md)`?';  base = '.codex/bdd-workflow/' }
    @{ re = '`?(runbooks/[a-z0-9-]+\.md)`?';  base = '.codex/bdd-workflow/' }
    @{ re = '(\.codex/scripts/[a-z0-9-]+\.ps1)'; base = '' }
    @{ re = '(\.codex/bdd-workflow/(?:policies|runbooks|templates)/[a-z0-9-]+\.md)'; base = '' }
)
foreach ($a in $agents) {
    $t = Get-Content $a.FullName -Raw
    foreach ($p in $refPatterns) {
        foreach ($mm in [regex]::Matches($t, $p.re)) {
            $rel = $mm.Groups[1].Value
            if ($rel -match '\{') { continue }   # 樣板路徑
            $full = if ($p.base) { Join-Path $p.base $rel } else { $rel }
            if (-not (Test-Path $full)) {
                Add-V 'dangling-ref' "$($a.Name) -> $rel" '修正路徑或建立該檔'
            }
        }
    }
}

# ---- 5. 已知過時引用 ----
$stale = @('agent-common\.md', 'bdd-orchestrator\.agent\.md', 'route-hints', 'gate-m1', 'gate-m2',
           '(?<![`a-z-])(domain|discovery|formulator|design)-reviewer(?![`a-z-])')
foreach ($a in $agents) {
    $t = Get-Content $a.FullName -Raw
    foreach ($s in $stale) {
        if ($t -match $s) { Add-V 'stale-ref' "$($a.Name): $s" '該檔／概念已移除，更新引用' }
    }
}

# ---- 輸出 ----
$summary = [pscustomobject]@{
    passed          = ($violations.Count -eq 0)
    agent_count     = $agents.Count
    core_block_sync = ($cores.Count -eq $agents.Count -and
                       ($violations | Where-Object rule -eq 'agent-core-drift').Count -eq 0)
    violation_count = $violations.Count
    violations      = $violations
}

if ($Json) { $summary | ConvertTo-Json -Depth 4 -Compress }
else {
    if ($violations.Count -eq 0) {
        "[agent-lint] OK — $($agents.Count) agents, core block in sync, no dangling or stale refs."
    } else {
        [Console]::Error.WriteLine("[agent-lint] $($violations.Count) violation(s):")
        foreach ($v in $violations) {
            [Console]::Error.WriteLine("  - $($v.rule): $($v.detail)")
            [Console]::Error.WriteLine("    fix: $($v.fix)")
        }
    }
}
if ($violations.Count -gt 0) { exit 2 }
exit 0
