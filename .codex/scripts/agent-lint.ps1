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
#   6. bdd-workflow-version.json 與 contract 的版本號一致
#      （啟動只讀版本檔，兩者不一致等於啟動讀到錯的相容性資訊）
#   7. route-profiles 用到的每個 gate 都有對應的 gate-confirmations 檔且帶 requires
#      （缺檔會讓該 profile 的 Gate 變成即席拼裝 —— 使用者核准的驗證清單將不確定）
#
# Exit: 0 = 全部通過；2 = 有違規。

[CmdletBinding()]
param(
    [string]$AgentDir    = '.codex/agents',
    [string]$Matrix      = '.codex/bdd-workflow/agent-skill-matrix.json',
    [string]$Contract      = '.codex/bdd-workflow/workflow-contract.json',
    [string]$VersionFile   = '.codex/bdd-workflow/bdd-workflow-version.json',
    [string]$RouteProfiles = '.codex/bdd-workflow/route-profiles.json',
    [string]$GateDir       = '.codex/bdd-workflow/gate-confirmations',
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

# ---- 6. 版本檔與 contract 一致 ----
$contractJson = $null
if ((Test-Path $Contract) -and (Test-Path $VersionFile)) {
    try {
        $contractJson = Get-Content $Contract -Raw | ConvertFrom-Json
        $ver = Get-Content $VersionFile -Raw | ConvertFrom-Json
        foreach ($k in @('contract-version', 'min-compatible-version')) {
            if ($ver.$k -ne $contractJson.$k) {
                Add-V 'version-file-drift' "$k : version-file=$($ver.$k) contract=$($contractJson.$k)" `
                      "同步 $VersionFile —— 啟動只讀此檔，不一致會讀到錯的相容性資訊"
            }
        }
    } catch { Add-V 'version-file-unparsable' $VersionFile '修正 JSON 格式' }
} else {
    Add-V 'version-file-missing' $VersionFile '建立版本檔（啟動讀取來源）'
}

# ---- 7. gate 定義完整性 ----
$profiles = $null
if (Test-Path $RouteProfiles) {
    try { $profiles = (Get-Content $RouteProfiles -Raw | ConvertFrom-Json).profiles }
    catch { Add-V 'route-profiles-unparsable' $RouteProfiles '修正 JSON 格式' }
} else {
    Add-V 'route-profiles-missing' $RouteProfiles '建立 route-profiles.json（啟動路由讀取來源）'
}
if ($profiles) {
    $needed = @()
    foreach ($p in $profiles.PSObject.Properties) { $needed += @($p.Value.gates) }
    $needed = @($needed | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($g in $needed) {
        $gf = Join-Path $GateDir "$g.json"
        if (-not (Test-Path $gf)) {
            Add-V 'gate-confirmation-missing' "$g (由 route-profiles 啟用)" `
                  "建立 $gf —— 缺檔會讓該 Gate 每次即席拼裝，使用者核准的驗證清單將不確定"
            continue
        }
        try {
            $gj = Get-Content $gf -Raw | ConvertFrom-Json
            foreach ($k in @('gate-id', 'requires', 'documents-to-review', 'user-verification-checklist', 'next-stage-if-approved')) {
                if (-not $gj.$k) { Add-V 'gate-confirmation-incomplete' "${g}: 缺 $k" "補上 $k" }
            }
            if ($gj.'gate-id' -and $gj.'gate-id' -ne $g) {
                Add-V 'gate-id-mismatch' "${gf}: gate-id=$($gj.'gate-id')" 'gate-id 必須與檔名一致'
            }
            foreach ($src in @($gj.merges)) {
                if ($src -and -not (Test-Path (Join-Path $GateDir "$src.json"))) {
                    Add-V 'gate-merge-dangling' "$g merges $src（不存在）" '修正 merges 或建立來源 gate 檔'
                }
            }
        } catch { Add-V 'gate-confirmation-unparsable' $gf '修正 JSON 格式' }
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
