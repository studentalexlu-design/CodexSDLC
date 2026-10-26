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
#   給了 -TestResults 時另外兩項（一條驗收條件要「有測試、測試通過、而且是現在這份程式碼跑出來的」才算完成）：
#   4. 逐條通過：這次迭代的每一條 scenario，在結果檔裡都找得到對應的 test case，而且全部 passed。只看 skipped 總數的話，
#      某條 scenario 根本沒產生測試（step 沒繫結、檔案沒被編進測試專案）時結果檔照樣乾淨。
#      對應方式：標題與 test 名稱都只留字母和數字、不分大小寫後，相等或以標題開頭（Outline 的每一列）。Reqnroll 的方法名
#      （PascalCase）、xUnit 的 DisplayName、MSTest 的 Description、Cucumber JUnit 的 testcase name 都對得上。
#      **前幾次迭代**的 scenario（.feature 裡有、這次的區塊沒有的）也一樣驗：這次改了共用的 step 或繫結，它們不再產生測試時，
#      全套照樣是綠的。所以結果檔要是全套測試的，不是只跑這次那幾條的。標了 @manual 的（QA 手動測）不要求有測試，有就要通過。
#   5. 不過期：結果檔要比這次改過的檔（.feature、git 工作區裡改過或新增的檔；bdd-docs/ 與建置輸出除外）新。
#      先跑測試、後改程式的舊結果檔，數字再好看也不是現在這份程式碼的結果。
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
$ManualTagRe = '(?i)(^|\s)@manual\b'   # QA 手動測的 scenario：本來就沒有自動化測試，前幾次迭代的那幾條不要求結果檔裡有

function Norm([string]$s) { return ($s -replace '\s+', ' ').Trim() }

# Gherkin 文字 → { background = @(步驟); scenarios = ordered{ 標題 = @(步驟) }; tags = @(標題 → 標籤行) }
function Read-Gherkin([string]$text) {
    $bg = [Collections.Generic.List[string]]::new()
    $sc = [ordered]@{}
    $skipped = @(); $manual = @()
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
            if ($pendingTags -match $ManualTagRe) { $manual += $title }
            $pendingTags = ''
            continue
        }
        if ($line -match '^\s*(Feature|功能)\s*:' -and $pendingTags -match $SkipTagRe) { $skipAll = $true }
        if ($line -match '^\s*(Feature|功能|Rule|規則|Examples|Scenarios|例子)\s*:') { $pendingTags = ''; if ($line -notmatch '^\s*(Examples|Scenarios|例子)') { $cur = $null; $inBg = $false }; continue }
        if ($line -match $StepRe) {
            if ($inBg) { $bg.Add((Norm $line)) } elseif ($null -ne $cur) { $cur.Add((Norm $line)) }
        }
    }
    return [pscustomobject]@{ background = @($bg); scenarios = $sc; skipped = $skipped; manual = $manual }
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

# 結果檔 → 每個 test case 的 { names = @(可拿來對應標題的名字); outcome = passed／failed／skipped }
function Get-TestRecords([string]$path) {
    [xml]$x = [IO.File]::ReadAllText($path)
    $recs = @()
    if ($x.TestRun) {   # TRX
        $defs = @{}
        foreach ($d in @($x.TestRun.TestDefinitions.UnitTest)) { if ($d) { $defs[[string]$d.id] = $d } }
        foreach ($u in @($x.TestRun.Results.UnitTestResult)) {
            if (-not $u) { continue }
            $names = @([string]$u.testName)
            $d = $defs[[string]$u.testId]
            if ($d) { $names += [string]$d.name; if ($d.TestMethod) { $names += [string]$d.TestMethod.name }; if ($d.Description) { $names += [string]$d.Description } }
            $o = switch -Regex ([string]$u.outcome) { '^Passed$' { 'passed' } '^(Failed|Error|Timeout|Aborted)$' { 'failed' } default { 'skipped' } }
            $recs += [pscustomobject]@{ names = @($names | Where-Object { $_ }); outcome = $o }
        }
        return $recs
    }
    foreach ($t in @($x.SelectNodes('//testcase'))) {
        $o = if ($t.SelectSingleNode('failure|error')) { 'failed' } elseif ($t.SelectSingleNode('skipped')) { 'skipped' } else { 'passed' }
        $recs += [pscustomobject]@{ names = @([string]$t.GetAttribute('name')); outcome = $o }
    }
    return $recs
}

function NormId([string]$s) { return ($s -replace '[^\p{L}\p{N}]', '').ToLowerInvariant() }

# test 名稱的各種寫法 → 正規化後的候選：全名、去掉參數、去掉 namespace／class（xUnit 的 Namespace.Class.Method）
function Get-NameKeys($rec) {
    $keys = @()
    foreach ($n in $rec.names) {
        $bare = ($n -replace '\(.*$', '').Trim()
        $keys += (NormId $n), (NormId $bare), (NormId ($bare -replace '^.*\.', ''))
    }
    return @($keys | Where-Object { $_ } | Select-Object -Unique)
}

# 在 git 工作區裡、比結果檔新的檔。這套流程不 commit，這次的改動全部在工作區裡。
function Get-NewerSources([string]$repoTop, [string]$featureFull, [string[]]$resultFulls, [string]$docsRoot) {
    $oldest = ($resultFulls | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } | Measure-Object -Minimum).Minimum
    $limit = $oldest.AddSeconds(2)
    $cands = @($featureFull)
    if ($repoTop) {
        $prevEnc = $null
        try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = $Utf8NoBom } catch { }
        try {
            $cands += @(& git -C $repoTop -c core.quotepath=false diff --name-only HEAD 2>$null) + @(& git -C $repoTop -c core.quotepath=false ls-files --others --exclude-standard 2>$null) |
                Where-Object { $_ } | ForEach-Object { Join-Path $repoTop $_ }
        } finally { if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } } }
    }
    $skip = @($resultFulls | ForEach-Object { $_ -replace '\\', '/' })
    $docs = ($docsRoot -replace '\\', '/').Trim('/')
    $top = if ($repoTop) { ($repoTop -replace '\\', '/').TrimEnd('/') } else { '' }
    $newer = @()
    foreach ($c in ($cands | Select-Object -Unique)) {
        $p = $c -replace '\\', '/'
        if ($p -in $skip -or -not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        $rel = if ($top -and $p.StartsWith("$top/", [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($top.Length + 1) } else { [IO.Path]::GetRelativePath((Get-Location).Path, $c) -replace '\\', '/' }
        if ($rel -like "$docs/*" -or $rel -match '(^|/)(bin|obj|target|build|out|TestResults|coverage|node_modules)/' -or $rel -match '\.(trx|log)$') { continue }
        if ((Get-Item -LiteralPath $c).LastWriteTimeUtc -gt $limit) { $newer += $rel }
    }
    return $newer
}

$results = @()
$exitCode = 0
foreach ($f in $Feature) {
    $r = [ordered]@{ feature = ($f -replace '\\', '/'); spec = $null; feature_id = $null; iteration = $null; passed = $true; missing_steps = @(); missing_scenarios = @(); removed_scenarios = @(); removed_steps = @(); skipped_scenarios = @(); skipped_tests = $null; scenarios_without_test = $null; scenarios_not_passed = $null; prior_scenarios_without_test = $null; prior_scenarios_not_passed = $null; stale_results_newer = $null; error = $null }
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

            # 4. 逐條通過。以標題開頭的對應會讓「取消訂單」也吃到「取消訂單失敗」的測試 —— 也對得上更長標題的那個 test 不算。
            $recs = @($TestResults | ForEach-Object { Get-TestRecords $_ } | ForEach-Object { [pscustomobject]@{ keys = (Get-NameKeys $_); outcome = $_.outcome } })
            # 「較長的標題」要看整份 .feature：這次的「取消訂單」不能吃前幾次「取消訂單並退款」的測試。
            $titles = @(@($want.scenarios.Keys) + @($have.scenarios.Keys) | Select-Object -Unique |
                        ForEach-Object { [pscustomobject]@{ title = $_; key = (NormId $_); prior = (-not $want.scenarios.Contains($_)) } })
            $r.scenarios_without_test = @(); $r.scenarios_not_passed = @()
            $r.prior_scenarios_without_test = @(); $r.prior_scenarios_not_passed = @()
            foreach ($t in $titles) {
                $longer = @($titles | Where-Object { $_.key.Length -gt $t.key.Length -and $_.key.StartsWith($t.key) } | ForEach-Object { $_.key })
                $hit = @($recs | Where-Object {
                    $ks = $_.keys
                    @($ks | Where-Object { $_.StartsWith($t.key) }).Count -and -not @($ks | Where-Object { $k = $_; @($longer | Where-Object { $k.StartsWith($_) }).Count }).Count
                })
                if (-not $hit.Count) {
                    if (-not $t.prior) { $r.scenarios_without_test += $t.title }
                    elseif ($t.title -notin $have.manual -and $t.title -notin $have.skipped) { $r.prior_scenarios_without_test += $t.title }
                    continue
                }
                $bad = @($hit | Where-Object { $_.outcome -ne 'passed' } | ForEach-Object { $_.outcome })
                if ($bad.Count) {
                    $entry = [pscustomobject]@{ scenario = $t.title; outcomes = $bad }
                    if ($t.prior) { $r.prior_scenarios_not_passed += $entry } else { $r.scenarios_not_passed += $entry }
                }
            }

            # 5. 不過期
            $r.stale_results_newer = @(Get-NewerSources $repoTop (Resolve-Path -LiteralPath $f).Path @($TestResults | ForEach-Object { (Resolve-Path -LiteralPath $_).Path }) $DocsRoot)
        }

        $r.passed = -not ($r.missing_steps.Count -or $r.missing_scenarios.Count -or $r.removed_scenarios.Count -or $r.removed_steps.Count -or
                          $r.skipped_scenarios.Count -or ($r.skipped_tests -gt 0) -or
                          @($r.scenarios_without_test | Where-Object { $_ }).Count -or @($r.scenarios_not_passed | Where-Object { $_ }).Count -or
                          @($r.prior_scenarios_without_test | Where-Object { $_ }).Count -or @($r.prior_scenarios_not_passed | Where-Object { $_ }).Count -or
                          @($r.stale_results_newer | Where-Object { $_ }).Count)   # 沒給 -TestResults 時是 $null，而 @($null).Count 是 1
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
        if ($r.passed) {
            $extra = if ($null -ne $r.scenarios_without_test) { '、每條 scenario（含前幾次迭代的）都有通過的測試、結果檔不過期' } else { '' }
            "[gherkin-check] OK — $($r.feature) 對 $($r.spec)（迭代 $($r.iteration)）逐字一致、既有的沒動、沒有略過$extra。"; continue
        }
        [Console]::Error.WriteLine("[gherkin-check] $($r.feature) 對 $($r.spec)（迭代 $($r.iteration)）：")
        foreach ($s in $r.missing_scenarios) { [Console]::Error.WriteLine("  - spec 的 scenario 不在 .feature 裡（或標題被改了）：$s") }
        foreach ($s in $r.missing_steps)     { [Console]::Error.WriteLine("  - 步驟沒有逐字照抄（$($s.scenario)）：$($s.step)") }
        foreach ($s in $r.removed_scenarios) { [Console]::Error.WriteLine("  - 既有的 scenario 被刪了：$s —— QA 的工作區，刪掉不會有任何測試變紅") }
        foreach ($s in $r.removed_steps)     { [Console]::Error.WriteLine("  - 既有 step 的措辭被改了（$($s.scenario)）：$($s.step) —— 會讓 QA 的自動化靜默斷掉；真要改，寫進「風險與待確認」交給 orchestrator 問使用者") }
        foreach ($s in $r.skipped_scenarios) { [Console]::Error.WriteLine("  - scenario 被標成略過：$s —— skipped 不是綠燈") }
        if ($r.skipped_tests -gt 0)          { [Console]::Error.WriteLine("  - 測試結果裡有 $($r.skipped_tests) 個 skipped —— skipped 不是綠燈") }
        foreach ($s in @($r.scenarios_without_test)) { if ($s) { [Console]::Error.WriteLine("  - 結果檔裡找不到這條 scenario 的測試：$s —— step 沒繫結、.feature 沒編進測試專案，或給錯了結果檔（標題與 test 名稱只比字母和數字）") } }
        foreach ($s in @($r.scenarios_not_passed))   { if ($s) { [Console]::Error.WriteLine("  - 這條 scenario 的測試沒有全部通過（$($s.outcomes -join '、')）：$($s.scenario)") } }
        foreach ($s in @($r.prior_scenarios_without_test)) { if ($s) { [Console]::Error.WriteLine("  - 前幾次迭代的 scenario 在結果檔裡找不到測試：$s —— 這次的改動讓它的 step 失去繫結，或給的結果檔只跑了部分測試（要給全套的）；QA 手動測的請標 @manual") } }
        foreach ($s in @($r.prior_scenarios_not_passed))   { if ($s) { [Console]::Error.WriteLine("  - 前幾次迭代的 scenario 測試沒有全部通過（$($s.outcomes -join '、')）：$($s.scenario) —— 這次的改動弄壞了已經交付的行為") } }
        if (@($r.stale_results_newer | Where-Object { $_ }).Count) { [Console]::Error.WriteLine("  - 結果檔比這些改過的檔舊，不是現在這份程式碼的結果，重跑測試再檢查：$((@($r.stale_results_newer) | Select-Object -First 5) -join '、')") }
    }
}
exit $exitCode
