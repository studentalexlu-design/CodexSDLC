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
#   8. AGENT-CORE 內嵌的回傳 shape 與 return-contract-policy.md 一致
#   9. bdd-orchestrator 內嵌的 tier 表與 route-profiles.json 的 tier／預算一致
#      （orchestrator 依內嵌表決策、handoff-lint 依 JSON 阻斷 —— 漂移會讓 hook
#       在模型認為合法時擋下 spawn，那是最難診斷的失敗模式）
#  10. gate 宣告的 findings-required-sections 在對應 template 中都存在
#      （gate 依段落驗證、template 是產出端規格 —— 漂移會讓 gate 通過卻什麼都沒驗到）
#  11. 定義了合併 mode 的代理不得保留「一次只處理一個 mode」的裸切片守門句
#      （合併前的殘留規則會讓代理挑保守讀法，把合併靜默作廢、退回逐一 mode 呼叫）
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
    [string]$ReturnPolicy  = '.codex/bdd-workflow/policies/return-contract-policy.md',
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
           '(?<![`a-z-])(domain|discovery|formulator|design)-reviewer(?![`a-z-])',
           # v2.0.0：tier 詞彙由 lite/standard/full 改為 probe/spike/t0..t3。
           # 只比對 tier 值位置與已移除的 gate id，避免誤傷 "full-index"、"標準" 等合法用字。
           'tier\s*[:：]\s*(lite|standard|full)\b',
           '`(lite|standard|full)`',
           'profile-(lite|standard|full)\b',
           'gate-(lite|std-1|std-2)\b',
           '(?<![a-z-])gate-[a-e](?![a-z0-9-])',
           'complexity-assessment', 'complexity-routing',
           'runtime-metadata\.profile')
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

# ---- 8. AGENT-CORE 內嵌的回傳 shape 與 policy 檔一致 ----
# 回傳合約已從「每次 spawn 讀 policy」改為「內嵌於 AGENT-CORE」（可跨同 agent 重複呼叫命中 cache）。
# 內嵌就有漂移風險 —— 這裡把 policy 檔與內嵌區塊綁在一起。
if ($cores.Count -gt 0 -and (Test-Path $ReturnPolicy)) {
    $fence = '(?s)```text\s*(.*?)```'
    $refCore = $cores[($cores.Keys | Sort-Object)[0]]
    $inCore = [regex]::Match($refCore, $fence)
    $inPol  = [regex]::Match(((Get-Content $ReturnPolicy -Raw) -replace "`r`n", "`n"), $fence)
    if (-not $inCore.Success) {
        Add-V 'core-return-shape-missing' 'AGENT-CORE' '內嵌回傳 shape 的 ```text 區塊遺失'
    } elseif (-not $inPol.Success) {
        Add-V 'return-policy-shape-missing' $ReturnPolicy '該檔的 ```text Minimal Shape 區塊遺失'
    } else {
        $a = ($inCore.Groups[1].Value -replace '\s+', ' ').Trim()
        $b = ($inPol.Groups[1].Value  -replace '\s+', ' ').Trim()
        if ($a -ne $b) {
            Add-V 'return-shape-drift' 'AGENT-CORE vs return-contract-policy.md' `
                  '兩處的回傳 shape 已不一致；以 policy 檔為準同步 AGENT-CORE 並重跑本腳本'
        }
    }
}

# ---- 9. bdd-orchestrator 內嵌的 tier 表與 route-profiles.json 一致 ----
# tier 表已從「執行期讀 route-profiles.json」改為「內嵌於 orchestrator 系統提示」。
# 理由：一次執行期讀取的真正成本是它多花的那一輪（在長對話裡等於重送整份歷史），
# 不是檔案大小。內嵌就有漂移風險 —— 這裡把 JSON 與內嵌表綁在一起。
# route-profiles.json 仍是 handoff-lint 的機械來源，兩者必須說同一件事。
$orch = Join-Path $AgentDir 'bdd-orchestrator.toml'
if ($profiles -and (Test-Path $orch)) {
    $ot = Get-Content $orch -Raw
    # 表列格式： | `tier` | ≤N 或 **N** 或 **≤ B + N** | `gate-x` | ... |
    # 第一段數字即該 tier 的上限（物件形式則為 base）；整格文字另存供 N 相關性檢查。
    $embedded = @{}
    $embeddedCell = @{}
    foreach ($row in [regex]::Matches($ot, '(?m)^\|\s*`([a-z][a-z0-9]*)`\s*\|([^|]*?(\d+)[^|]*)\|')) {
        $embedded[$row.Groups[1].Value] = [int]$row.Groups[3].Value
        $embeddedCell[$row.Groups[1].Value] = $row.Groups[2].Value
    }
    $declared = @($profiles.PSObject.Properties.Name)

    if ($embedded.Count -eq 0) {
        Add-V 'tier-table-missing' 'bdd-orchestrator.toml' `
              '內嵌 tier 表遺失；沒有它 orchestrator 會退回執行期讀 route-profiles.json（每 run 多付一輪）'
    } else {
        foreach ($t in $declared) {
            if (-not $embedded.ContainsKey($t)) {
                Add-V 'tier-table-missing-row' "$t（route-profiles 有，內嵌表沒有）" `
                      'bdd-orchestrator 的 tier 表補上該列 —— 缺列的 tier 在執行期無法路由'
            } else {
                # 上限可為數字，或 {base, per-behaviour}（按行為切片的 tier）。
                $rawCap = $profiles.$t.'max-subagent-calls'
                $isScaled = $rawCap -is [System.Management.Automation.PSCustomObject]
                $expected = if ($isScaled) { [int]$rawCap.base } else { [int]$rawCap }
                if ($embedded[$t] -ne $expected) {
                    Add-V 'tier-budget-drift' `
                          "${t}: 內嵌=$($embedded[$t]) route-profiles=$(if ($isScaled) { "base=$expected" } else { $expected })" `
                          'orchestrator 依內嵌表決策、handoff-lint 依 JSON 阻斷；不一致會讓 hook 在模型認為合法時擋下 spawn'
                }
                # 隨 N 變動的上限，內嵌表必須看得出來是變動的 —— 否則模型會以為是固定值而過早停手。
                if ($isScaled -and $embeddedCell[$t] -notmatch 'N') {
                    Add-V 'tier-budget-scaling-undeclared' `
                          "${t}: route-profiles 為 {base, per-behaviour}，內嵌表卻寫成固定值「$($embeddedCell[$t].Trim())」" `
                          '內嵌表該列須標明隨 N 變動（例如「≤ 20 + N」），否則 orchestrator 會照固定值決策'
                }
            }
        }
        foreach ($e in $embedded.Keys) {
            if ($e -notin $declared) {
                Add-V 'tier-table-orphan-row' "$e（內嵌表有，route-profiles 沒有）" `
                      '移除該列或在 route-profiles.json 補上定義'
            }
        }
    }
}

# ---- 10. gate 宣告的 findings 段落必須在對應 template 中存在 ----
# Gate 依 findings 的段落做驗證，template 是產出端的唯一規格。
# 兩者漂移的後果：gate 檢查一個沒有人會寫出來的段落，或 template 有段落而 gate 從不看 ——
# 兩種都是「通過了但什麼都沒驗到」，正是形式檢查最危險的失敗模式。
$sectionSources = @{
    'gate-probe' = '.codex/bdd-workflow/templates/probe-findings.md'
}
foreach ($gid in $sectionSources.Keys) {
    $gf = Join-Path $GateDir "$gid.json"
    $tpl = $sectionSources[$gid]
    if (-not (Test-Path $gf)) { continue }
    if (-not (Test-Path $tpl)) {
        Add-V 'findings-template-missing' "$gid -> $tpl" '建立該 template 或修正 gate 的段落來源對應'
        continue
    }
    try {
        $gj = Get-Content $gf -Raw | ConvertFrom-Json
        $need = @($gj.'findings-required-sections')
        if ($need.Count -eq 0) {
            Add-V 'findings-sections-undeclared' $gid `
                  "在 $gid.json 加入 findings-required-sections —— 沒有它，gate 與 template 之間沒有任何機械綁定"
        } else {
            $tplText = Get-Content $tpl -Raw
            foreach ($s in $need) {
                if ($tplText -notmatch [regex]::Escape("## $s")) {
                    Add-V 'findings-section-drift' "$gid 要求 '## $s'，$tpl 沒有" `
                          'template 補上該段落，或從 gate 的 findings-required-sections 移除'
                }
            }
        }
    } catch { Add-V 'gate-confirmation-unparsable' $gf '修正 JSON 格式' }
}

# ---- 11. 定義了合併 mode 的代理，不得同時保留「一次只處理一個 mode」的切片守門 ----
# 這是已經發生過兩次的缺陷類型：v2.0.0 的 consolidation 加了 foundation/elaboration
# 與 mode: all，卻沒刪掉合併前那句切片守門，於是同一份 prompt 裡隔數十行講反話。
# AGENT-CORE 的預設方向是往嚴格側倒（tier 缺漏套 t3），衝突時代理會挑保守讀法 ——
# 也就是把合併整個作廢，退回逐一 mode 呼叫。症狀是靜默的：流程照跑，只是每次多花幾次 spawn。
foreach ($a in $agents) {
    $txt = Get-Content $a.FullName -Raw
    # 合併 mode 的宣告特徵：mode 表中出現「同一 invocation」「一次完成」，或有「合併模式」段。
    $hasMerged = $txt -match '(?m)^###?\s*合併模式' -or
                 $txt -match '同一 invocation (內)?(依序)?完成' -or
                 $txt -match '一次完成 \w'
    if (-not $hasMerged) { continue }
    # 未加豁免說明的裸切片守門句。允許帶「但」的修訂版（明確排除合併 mode 本身）。
    foreach ($m in [regex]::Matches($txt, '(?m)^\s*[-*]\s*一次只處理一個 mode[^\r\n]*')) {
        if ($m.Value -notmatch '但') {
            Add-V 'merged-mode-contradiction' "$($a.Name): 「$($m.Value.Trim())」與同檔的合併模式宣告互相矛盾" `
                  '刪除該句，或改寫成明確排除合併 mode 本身（例如「但 `all` 本身就是 mode，其內含項須在同一 invocation 完成」）'
        }
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
