# agent-lint.ps1
# 驗證 agent 定義的結構完整性與共用核心一致性。
#
# **orchestrator 沒有 toml —— 它就是 AGENTS.md（最上層對話本身）。** 被 spawn 出來的
# agent 不能再 spawn，所以 orchestrator 一旦有了 agent 定義檔就會被當成子代理叫起來，
# 然後委派不出去。檢查 3 因此多守一條：`bdd-orchestrator.toml` 不得出現在 $AgentDir。
#
# 共用核心刻意內嵌在每個檔（系統提示內，可跨同 agent 重複呼叫命中 cache），
# 而不是執行期讀共用檔。內嵌會帶來漂移風險 —— 本腳本把「重複」變成「被強制一致的重複」。
#
# 檢查項：
#   1. AGENT-CORE 區塊在所有 agent（含 AGENTS.md）中逐字相同
#   2. TOML 結構：''' 配對、必要 key 齊全、name 與檔名一致
#   3. agent 名冊與 orchestrator 委派表雙向一致，且 orchestrator 不得是可被 spawn 的 agent
#      （沒被路由到的 agent 永遠不會被叫起來；路由到不存在的 agent 會在執行期才炸）
#   4. 引用的 policy / runbook / script / skill 路徑真實存在
#   5. 無 v4.0.0 已移除的概念殘留
#      （這是本次重構最高價值的檢查：tier／gate／run 狀態／已刪除的 agent 名稱
#        散落在十幾個檔裡，漏一處的症狀通常是「執行期被擋下，而訊息指向錯的原因」）
#   6. 產物路徑合約：生產者／路由者／消費者三方都提到同一個路徑
#   7. bdd-workflow-version.json 可解析且帶版本號
#
# v4.0.0 移除的檢查：skill matrix 覆蓋、gate 定義完整性、回傳 shape 對 policy 檔、
# tier 表對 route-profiles、findings 段落對 template、合併 mode 矛盾、文件 tier 預算。
# 它們守的東西（gate 檔、tier 表、route-profiles、living-doc、design-modeler）都已不存在。
#
# Exit: 0 = 全部通過；2 = 有違規。

[CmdletBinding()]
param(
    [string]$AgentDir          = '.codex/agents',
    [string]$Orchestrator      = 'bdd-orchestrator',
    [string]$OrchestratorFile  = 'AGENTS.md',
    [string]$VersionFile       = '.codex/bdd-workflow/bdd-workflow-version.json',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$violations = @()
function Add-V([string]$rule, [string]$detail, [string]$fix) {
    $script:violations += [pscustomobject]@{ rule = $rule; detail = $detail; fix = $fix }
}

$agents = @(Get-ChildItem $AgentDir -Filter *.toml -ErrorAction SilentlyContinue)
if (-not $agents) { Write-Error "no agent toml under $AgentDir"; exit 2 }

# 受檢文件 = 子代理 toml ＋ orchestrator（AGENTS.md）。
# 檢查 1／4／5／6 對兩者一視同仁；只有檢查 2（TOML 結構）僅適用於 toml。
$docs = [ordered]@{}
foreach ($a in $agents) {
    $docs[$a.BaseName] = [pscustomobject]@{ Label = $a.Name; Text = (Get-Content $a.FullName -Raw) }
}
if (Test-Path $OrchestratorFile) {
    $docs[$Orchestrator] = [pscustomobject]@{
        Label = (Split-Path $OrchestratorFile -Leaf)
        Text  = (Get-Content $OrchestratorFile -Raw)
    }
} else {
    Add-V 'orchestrator-missing' $OrchestratorFile `
          'orchestrator 的指令就是這個檔（最上層對話讀的那份）—— 缺檔則整套流程沒有入口'
}

# ---- 1. AGENT-CORE 區塊逐字一致 ----
$coreRe = '(?s)<!-- AGENT-CORE:BEGIN.*?<!-- AGENT-CORE:END -->'
$cores = @{}
foreach ($k in $docs.Keys) {
    $m = [regex]::Match($docs[$k].Text, $coreRe)
    if (-not $m.Success) {
        Add-V 'missing-agent-core' $docs[$k].Label '內嵌 AGENT-CORE 區塊（從任一現有 agent 複製）'
        continue
    }
    $cores[$k] = ($m.Value -replace "`r`n", "`n")
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
# `model_reasoning_effort` 不在必填之列：釘死在 agent 定義裡會蓋掉 CLI 的設定，
# 而把 `sa-analyst` 釘在 high 正是大型 legacy repo 分析逾時的成因之一。
# 要設仍然可以設（這裡不禁止），但它是**呼叫端的選擇**，不是 agent 定義的義務。
$requiredKeys = @('name', 'description', 'sandbox_mode', 'developer_instructions')
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

# ---- 3. agent 名冊 ↔ orchestrator 委派表 雙向一致 ----
# 取代了舊的 agent-skill-matrix.json 覆蓋檢查。矩陣是第二份會走鐘的名冊；
# orchestrator 的委派表本來就是唯一真正決定「誰會被叫起來」的地方，直接綁它。

# orchestrator 一旦有了 agent 定義檔，就會被當成子代理 spawn 起來，而被 spawn 出來的
# agent 拿不到 `agent` 工具 —— ② 到 ⑤ 全部委派不出去，症狀卻只是一句「工具不存在」。
# 這道檢查是唯一在守它的東西：踩過一次，兩次冷啟動零產出收場。
$orchToml = Join-Path $AgentDir "$Orchestrator.toml"
if (Test-Path $orchToml) {
    Add-V 'orchestrator-must-not-be-spawnable' $orchToml `
          "刪掉這個檔 —— orchestrator 的指令屬於 $OrchestratorFile。被 spawn 出來的 orchestrator 無法再委派"
}

if ($docs.Contains($Orchestrator)) {
    $orchText = $docs[$Orchestrator].Text
    $onDisk = @($agents.BaseName | Where-Object { $_ -ne $Orchestrator })

    foreach ($d in $onDisk) {
        if ($orchText -notmatch [regex]::Escape("``$d``")) {
            Add-V 'agent-not-routed' $d `
                  "bdd-orchestrator 的委派表沒有提到它 —— 沒有路由的 agent 永遠不會被叫起來"
        }
    }

    # 委派表列： | 要什麼 | `agent-name` | mode |
    $routeSection = [regex]::Match($orchText, '(?s)##\s*委派.*?(?=\r?\n##\s|\Z)')
    if ($routeSection.Success) {
        foreach ($row in [regex]::Matches($routeSection.Value, '(?m)^\|[^|]*\|\s*`([a-z][a-z0-9-]*)`\s*\|')) {
            $target = $row.Groups[1].Value
            if ($target -notin $onDisk) {
                Add-V 'route-to-unknown-agent' "委派表指向 ``$target``，但 $AgentDir 沒有這個 agent" `
                      '修正 agent 名稱或建立該 agent —— 這個錯誤要到執行期 spawn 失敗才會出現'
            }
        }
    } else {
        Add-V 'route-table-missing' $OrchestratorFile '「## 委派」段落遺失；沒有它就沒有任何機械可查的路由來源'
    }
}

# ---- 4. 引用路徑存在性 ----
$refPatterns = @(
    @{ re = '`?(policies/[a-z0-9-]+\.md)`?';  base = '.codex/bdd-workflow/' }
    @{ re = '`?(runbooks/[a-z0-9-]+\.md)`?';  base = '.codex/bdd-workflow/' }
    @{ re = '(\.codex/scripts/[a-z0-9-]+\.ps1)'; base = '' }
    @{ re = '(\.codex/bdd-workflow/(?:policies|runbooks|templates)/[a-z0-9-]+\.md)'; base = '' }
)
foreach ($k in $docs.Keys) {
    $t = $docs[$k].Text
    foreach ($p in $refPatterns) {
        foreach ($mm in [regex]::Matches($t, $p.re)) {
            $rel = $mm.Groups[1].Value
            if ($rel -match '\{') { continue }   # 樣板路徑
            $full = if ($p.base) { Join-Path $p.base $rel } else { $rel }
            if (-not (Test-Path $full)) {
                Add-V 'dangling-ref' "$($docs[$k].Label) -> $rel" '修正路徑或建立該檔'
            }
        }
    }
}
# skill 引用：skill `name` → .agents/skills/{name}/SKILL.md
foreach ($k in $docs.Keys) {
    foreach ($mm in [regex]::Matches($docs[$k].Text, 'skill\s+`([a-z0-9-]+)`')) {
        $skill = $mm.Groups[1].Value
        if (-not (Test-Path ".agents/skills/$skill/SKILL.md")) {
            Add-V 'dangling-skill-ref' "$($docs[$k].Label) -> skill ``$skill``" '修正 skill 名稱或建立 .agents/skills/{name}/SKILL.md'
        }
    }
}

# ---- 5. v4.0.0 已移除的概念殘留 ----
# 這一類缺陷的症狀特別惡劣：殘留的舊詞彙會讓 agent 在執行期發出已不合法的欄位，
# 而 hook 的錯誤訊息通常指向「缺少 X」而不是「X 的值已過期」—— 最難診斷的那種。
# 因此模式寫得寧可嚴一點，誤報成本遠低於漏報。
$stale = @(
    # tier 系統（v4.0.0 整層移除，改為「這件事可不可逆」單一提問）
    '(?i)\btier\b',
    '`t[0-3]`',
    '`discover`',
    # gate 系統（改為對話式確認點）
    'gate-(probe|close|contract|migration|release)\b',
    'gate-confirmations?/',
    # run 狀態機（改為無狀態，狀態活在對話裡）
    'run-id',
    'workflow-state',
    'checkpoints?/',
    'probe-findings',
    'context-pack',
    'decision-log',
    'lean-sdlc',
    'source-materials-register',
    'subagent-calls',
    'quality-loop',
    'route-profiles',
    'workflow-contract',
    'agent-skill-matrix',
    # 已刪除的 agent。用反引號形式比對 —— agent 引用一律帶反引號，
    # 而裸字比對會誤傷（`-match` 在 PowerShell 大小寫不敏感，`analyst` 會命中標題 "SA Analyst"）。
    '`analyst`',
    '`formulator`',
    '`project-scanner`',
    '`atdd-automator`',
    '`tdd-implementer`',
    '`spec-reviewer`',
    '`code-reviewer`',
    '`design-modeler`',
    '`integration-tester`',
    '`living-doc`',
    # 已改名的回傳狀態
    'partial-completed',
    'needs-probe',
    # 更早期已移除的詞彙
    'agent-common\.md',
    'bdd-orchestrator\.agent\.md',
    'complexity-(assessment|routing)'
)
foreach ($k in $docs.Keys) {
    $t = $docs[$k].Text
    foreach ($s in $stale) {
        if ($t -match $s) { Add-V 'stale-ref' "$($docs[$k].Label): /$s/" 'v4.0.0 已移除該概念，更新或刪除該處' }
    }
}

# ---- 6. 產物路徑合約：生產者／路由者／消費者三方一致 ----
# 這類漂移是**靜默**的。scanner 改了落地路徑而 sa-analyst 沒跟上，症狀不是報錯 ——
# 是 SA 找不到證據於是回 `blocked` 要求查 DB，使用者被要求批准一件已經批准過的事，
# 而整條流程看起來一切正常。付出的代價（一次批准 ＋ 一次連線 ＋ 一次等待）沒有任何地方會記帳。
#
# 所以規則是「有人提到就三方都要提到」：沒有人用的產物不強制（這一版可能就是沒有），
# 但只要有人開始寫它，讀它的那一方就不能缺席。
$artifactContracts = @(
    @{ path = 'bdd-docs/{feature-id}/evidence/';   roles = @('db-introspection-scanner', 'bdd-orchestrator', 'sa-analyst') }
    @{ path = 'bdd-docs/{feature-id}/analysis.md'; roles = @('sa-analyst', 'bdd-orchestrator') }
    @{ path = 'bdd-docs/artifacts/legacy-schema/'; roles = @('db-introspection-scanner', 'bdd-orchestrator', 'sa-analyst') }
)
foreach ($c in $artifactContracts) {
    $lit = [regex]::Escape($c.path)
    $mentions = @($docs.Keys | Where-Object { $docs[$_].Text -match $lit })
    if ($mentions.Count -eq 0) { continue }
    foreach ($role in $c.roles) {
        if ($role -notin $docs.Keys) { continue }
        if ($role -notin $mentions) {
            Add-V 'artifact-path-orphan' "$($c.path) 未出現在 $role" `
                  '產物路徑須生產者／路由者／消費者三方一致 —— 漏掉消費者的症狀是它退回去重新要求查 DB，不是報錯'
        }
    }
}

# ---- 7. 版本檔 ----
if (Test-Path $VersionFile) {
    try {
        $ver = Get-Content $VersionFile -Raw | ConvertFrom-Json
        foreach ($k in @('contract-version', 'min-compatible-version')) {
            if ($ver.$k -notmatch '^\d+\.\d+\.\d+$') {
                Add-V 'version-invalid' "${k}=$($ver.$k)" '須為 semver（例如 4.0.0）'
            }
        }
    } catch { Add-V 'version-file-unparsable' $VersionFile '修正 JSON 格式' }
} else {
    Add-V 'version-file-missing' $VersionFile '建立版本檔 —— 消費端專案靠它判斷相容性'
}

# ---- 輸出 ----
$summary = [pscustomobject]@{
    passed           = ($violations.Count -eq 0)
    subagent_count   = $agents.Count
    # 子代理 toml ＋ orchestrator（AGENTS.md）—— 這些檔的 AGENT-CORE 必須逐字相同。
    core_block_files = $docs.Count
    core_block_sync  = ($cores.Count -eq $docs.Count -and
                        ($violations | Where-Object rule -eq 'agent-core-drift').Count -eq 0)
    violation_count  = $violations.Count
    violations       = $violations
}

if ($Json) { $summary | ConvertTo-Json -Depth 4 -Compress }
else {
    if ($violations.Count -eq 0) {
        "[agent-lint] OK — $($agents.Count) subagents + orchestrator($OrchestratorFile), core block in sync, routes resolved, no dangling or stale refs."
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
