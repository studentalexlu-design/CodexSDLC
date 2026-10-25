# gherkin-check.ps1
# `.feature` 對 spec.md 的機械檢查 —— reviewer 的必修項裡不需要判斷的那幾項，改由這支腳本當 oracle。
#
# 為什麼要機械化：這幾項以前由 reviewer 逐字人工比對，比錯或漏比要花掉一輪修正（implementer ＋ reviewer 各一次冷啟動），
# 而它們全部判得出對錯：
#   1. 逐字：spec.md 的 Gherkin 區塊（有 `## 迭代 N` 時只比那一次）裡每一個步驟，都原字出現在 .feature 對應的 scenario
#      （或 Background）裡。使用者批准的是那些字，QA 拿到的也該是那些字。
#   2. 既有的不動：跟 git HEAD 的版本比，既有 scenario 沒被刪、既有 step 的措辭沒被改 —— 除非這次迭代的區塊明講要改那一條
#      （同名 scenario）。那個檔是 QA 的工作區，刪掉的 scenario 不會有任何測試變紅。
#      限制：這套流程不 commit，所以只比得到 HEAD 那一份；HEAD 之後、還沒 commit 的舊改動不在比對範圍內。
#   3. 不略過：.feature 裡沒有 @ignore／@skip／@wip；給了 -TestResults（TRX 或 JUnit XML）時，skipped 也必須是 0。
#
# spec.md 從 .feature 第一個 `# feature-id: {id}` 找回 bdd-docs/{id}/spec.md（③ 規定 Gherkin 區塊第一行就是它）。
# 唯讀：不寫任何檔。DLP：只回步驟文字與行號（步驟文字本來就是使用者確認過、要交給 QA 的東西）。
#
# Exit: 0 = 通過；2 = 有違規；1 = 找不到 spec、讀不到檔等錯誤。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Feature,
    [string]$Spec,                       # 不給就從 .feature 的 # feature-id: 推
    [int]$Iteration = 0,                 # 0 = spec.md 最後一次迭代
    [string[]]$TestResults = @(),        # 選用：TRX（dotnet test --logger trx）或 JUnit XML（surefire／gradle）
    [string]$DocsRoot = 'bdd-docs',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }

# 關鍵字：英文 ＋ zh-TW（Gherkin i18n）。* 也是步驟。
$StepRe     = '^\s*(Given|When|Then|And|But|\*|假如|假設|假定|當|那麼|而且|並且|同時|但是)\s+\S'
$ScenarioRe = '^\s*(Scenario Outline|Scenario Template|Scenario|Example|場景大綱|劇本大綱|場景|劇本)\s*:\s*(.*)$'
$BackRe     = '^\s*(Background|背景)\s*:'
$SkipTagRe  = '(?i)(^|\s)@(ignore|ignored|skip|skipped|wip|pending)\b'

function Norm([string]$s) { return ($s -replace '\s+', ' ').Trim() }

# Gherkin 文字 → { background = @(步驟); scenarios = ordered{ 標題 = @(步驟) }; tags = @(標題 → 標籤行) }
function Read-Gherkin([string]$text) {
    $bg = [Collections.Generic.List[string]]::new()
    $sc = [ordered]@{}
    $skipped = @()
    $cur = $null; $inBg = $false; $pendingTags = ''
    $inDoc = $false; $skipAll = $false
    foreach ($raw in ($text -replace "`r`n", "`n") -split "`n") {
        $line = $raw.Trim()
        if ($line -match '^("""|```)') { $inDoc = -not $inDoc; continue }
        if ($inDoc -or -not $line -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('@')) { $pendingTags += " $line"; continue }
        if ($line -match $BackRe) { $inBg = $true; $cur = $null; $pendingTags = ''; continue }
        $m = [regex]::Match($line, $ScenarioRe)
        if ($m.Success) {
            $title = Norm $m.Groups[2].Value
            $inBg = $false
            $cur = [Collections.Generic.List[string]]::new()
            $sc[$title] = $cur
            if ($skipAll -or $pendingTags -match $SkipTagRe) { $skipped += $title }
            $pendingTags = ''
            continue
        }
        if ($line -match '^\s*(Feature|功能)\s*:' -and $pendingTags -match $SkipTagRe) { $skipAll = $true }
        if ($line -match '^\s*(Feature|功能|Rule|規則|Examples|Scenarios|例子)\s*:') { $pendingTags = ''; if ($line -notmatch '^\s*(Examples|Scenarios|例子)') { $cur = $null; $inBg = $false }; continue }
        if ($line -match $StepRe) {
            if ($inBg) { $bg.Add((Norm $line)) } elseif ($null -ne $cur) { $cur.Add((Norm $line)) }
        }
    }
    return [pscustomobject]@{ background = @($bg); scenarios = $sc; skipped = $skipped }
}

# spec.md → 每一次迭代的 Gherkin 區塊（沒有 `## 迭代` 的部分算第 1 次）
function Get-SpecBlocks([string]$text) {
    $text = $text -replace "`r`n", "`n"
    $iters = @([regex]::Matches($text, '(?m)^##\s*迭代\s*(\d+)') | ForEach-Object { [pscustomobject]@{ pos = $_.Index; n = [int]$_.Groups[1].Value } })
    $blocks = @{}
    foreach ($b in [regex]::Matches($text, '(?ms)^```gherkin[^\n]*\n(.*?)^```')) {
        $n = 1
        foreach ($it in $iters) { if ($it.pos -lt $b.Index) { $n = $it.n } }
        $blocks[$n] = ([string]$blocks[$n]) + "`n" + $b.Groups[1].Value
    }
    return $blocks
}

function Get-SkippedFromResults([string]$path) {
    [xml]$x = [IO.File]::ReadAllText($path)
    if ($x.TestRun) {   # TRX
        $c = $x.TestRun.ResultSummary.Counters
        $n = 0; foreach ($a in 'notExecuted', 'inconclusive') { if ($c.$a) { $n += [int]$c.$a } }
        return $n
    }
    $n = 0
    foreach ($s in @($x.SelectNodes('//testsuite'))) { if ($s.skipped) { $n += [int]$s.skipped } elseif ($s.disabled) { $n += [int]$s.disabled } }
    if (-not @($x.SelectNodes('//testsuite')).Count) { $n = @($x.SelectNodes('//skipped')).Count }
    return $n
}

$results = @()
$exitCode = 0
foreach ($f in $Feature) {
    $r = [ordered]@{ feature = ($f -replace '\\', '/'); spec = $null; feature_id = $null; iteration = $null; passed = $true; missing_steps = @(); missing_scenarios = @(); removed_scenarios = @(); removed_steps = @(); skipped_scenarios = @(); skipped_tests = $null; error = $null }
    try {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "找不到 $f" }
        $featText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $f).Path)
        $id = [regex]::Match($featText, '(?m)^\s*#\s*feature-id:\s*([A-Za-z0-9._-]+)')
        if ($id.Success) { $r.feature_id = $id.Groups[1].Value }
        $specPath = if ($Spec) { $Spec } elseif ($r.feature_id) { Join-Path $DocsRoot "$($r.feature_id)/spec.md" } else { $null }
        if (-not $specPath) { throw '.feature 沒有 `# feature-id:` 那一行，也沒有給 -Spec —— ③ 規定 Gherkin 區塊第一行固定寫它' }
        if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) { throw "找不到 $specPath" }
        $r.spec = ($specPath -replace '\\', '/')
        $blocks = Get-SpecBlocks ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $specPath).Path))
        if (-not $blocks.Count) { throw "$specPath 裡沒有 ``````gherkin 區塊" }
        $iter = if ($Iteration -gt 0) { $Iteration } else { [int](($blocks.Keys | Measure-Object -Maximum).Maximum) }
        if (-not $blocks.ContainsKey($iter)) { throw "$specPath 沒有第 $iter 次迭代的 Gherkin 區塊" }
        $r.iteration = $iter

        $want = Read-Gherkin $blocks[$iter]
        $have = Read-Gherkin $featText

        # 1. 逐字
        foreach ($title in $want.scenarios.Keys) {
            if (-not $have.scenarios.Contains($title)) { $r.missing_scenarios += $title; continue }
            $pool = @($have.scenarios[$title]) + @($have.background)
            foreach ($step in $want.scenarios[$title]) {
                if ($step -notin $pool) { $r.missing_steps += [pscustomobject]@{ scenario = $title; step = $step } }
            }
        }
        foreach ($step in $want.background) {
            if ($step -notin $have.background -and -not @($have.scenarios.Values | Where-Object { $step -in $_ }).Count) {
                $r.missing_steps += [pscustomobject]@{ scenario = '(Background)'; step = $step }
            }
        }

        # 2. 既有的不動（跟 git HEAD 比；這次迭代明講要改的同名 scenario 除外）
        $rel = $null
        $repoTop = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $repoTop) {
            $full = (Resolve-Path -LiteralPath $f).Path -replace '\\', '/'
            $top = ($repoTop -replace '\\', '/').TrimEnd('/')
            if ($full.StartsWith("$top/", [StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($top.Length + 1) }
        }
        if ($rel) {
            # git 寫出來的是 UTF-8，PowerShell 卻拿 console 的 code page 解碼（zh-TW 是 cp950）—— 中文的 scenario 標題
            # 與 step 解出來是亂碼，跟現在的檔永遠對不上：每一條既有 scenario 都像被刪掉了。解碼期間換成 UTF-8。
            $prevEnc = $null
            try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = $Utf8NoBom } catch { }
            try { $old = & git -C $repoTop show "HEAD:$rel" 2>$null }
            finally { if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } } }
            if ($LASTEXITCODE -eq 0 -and $old) {
                $before = Read-Gherkin (($old -join "`n"))
                foreach ($title in $before.scenarios.Keys) {
                    if ($want.scenarios.Contains($title)) { continue }      # 這次迭代明講要改的那一條
                    if (-not $have.scenarios.Contains($title)) { $r.removed_scenarios += $title; continue }
                    foreach ($step in $before.scenarios[$title]) {
                        if ($step -notin @($have.scenarios[$title]) -and $step -notin $have.background) {
                            $r.removed_steps += [pscustomobject]@{ scenario = $title; step = $step }
                        }
                    }
                }
            }
        }

        # 3. 不略過
        $r.skipped_scenarios = @($have.skipped)
        if ($TestResults.Count) {
            $n = 0; foreach ($t in $TestResults) { $n += (Get-SkippedFromResults $t) }
            $r.skipped_tests = $n
        }

        $r.passed = -not ($r.missing_steps.Count -or $r.missing_scenarios.Count -or $r.removed_scenarios.Count -or $r.removed_steps.Count -or
                          $r.skipped_scenarios.Count -or ($r.skipped_tests -gt 0))
        if (-not $r.passed -and $exitCode -eq 0) { $exitCode = 2 }
    } catch {
        $r.passed = $false; $r.error = $_.Exception.Message; $exitCode = 1
    }
    $results += [pscustomobject]$r
}

if ($Json) {
    [pscustomobject]@{ passed = ($exitCode -eq 0); results = $results } | ConvertTo-Json -Depth 6 -Compress
} else {
    foreach ($r in $results) {
        if ($r.error) { [Console]::Error.WriteLine("[gherkin-check] $($r.feature)：$($r.error)"); continue }
        if ($r.passed) { "[gherkin-check] OK — $($r.feature) 對 $($r.spec)（迭代 $($r.iteration)）逐字一致、既有的沒動、沒有略過。"; continue }
        [Console]::Error.WriteLine("[gherkin-check] $($r.feature) 對 $($r.spec)（迭代 $($r.iteration)）：")
        foreach ($s in $r.missing_scenarios) { [Console]::Error.WriteLine("  - spec 的 scenario 不在 .feature 裡（或標題被改了）：$s") }
        foreach ($s in $r.missing_steps)     { [Console]::Error.WriteLine("  - 步驟沒有逐字照抄（$($s.scenario)）：$($s.step)") }
        foreach ($s in $r.removed_scenarios) { [Console]::Error.WriteLine("  - 既有的 scenario 被刪了：$s —— QA 的工作區，刪掉不會有任何測試變紅") }
        foreach ($s in $r.removed_steps)     { [Console]::Error.WriteLine("  - 既有 step 的措辭被改了（$($s.scenario)）：$($s.step) —— 會讓 QA 的自動化靜默斷掉；真要改，寫進「風險與待確認」交給 orchestrator 問使用者") }
        foreach ($s in $r.skipped_scenarios) { [Console]::Error.WriteLine("  - scenario 被標成略過：$s —— skipped 不是綠燈") }
        if ($r.skipped_tests -gt 0)          { [Console]::Error.WriteLine("  - 測試結果裡有 $($r.skipped_tests) 個 skipped —— skipped 不是綠燈") }
    }
}
exit $exitCode
