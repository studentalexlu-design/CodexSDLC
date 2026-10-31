# delivery-check.ps1
# ⑥ 交付前的總檢查：一次跑完、只回一份精簡收據。orchestrator 寫完 spec.md 的「交付」一節之後跑一次，過了才回報交付。
#
# 為什麼要有它（借自 archify 的 finalize：一個指令串起所有關卡、回一份有界的收據，沒過的每一項附修法）：
# ⑥ 以前全是榮譽制 —— orchestrator 憑記憶把好幾輪子代理的回傳拼成殘留風險，沒有任何東西核對。
# 漏掉的那一項不會讓任何測試變紅，只會讓下一次迭代或修 bug 的人以為那裡驗過了。而它要的資料大多已經在磁碟上：
#   1. 審核：bdd-docs/{id}/review.md 存在，VERDICT 是 PASS；是 FAIL（使用者在修正輪上限接受了這一版）時，
#      每一項還開著的 [必修] 都要寫進交付。
#   2. 驗收條件：repo 裡首行 `# feature-id: {id}` 的 .feature 交給 gherkin-check 跑一次（帶 -TestResults）。
#      最後一輪修正之後沒重跑測試的話，結果檔會比改過的檔舊 —— 這裡擋得到，implementer 回報當時的綠燈擋不到。
#   3. 交付一節：spec.md 有 `## 交付 —— {日期}`、裡面有「殘留風險」那一行，而且提到下面每一項：
#        - .feature 裡標 @manual 的 scenario（待人工驗證）
#        - 審核快照（reviews/*.md）與 review.md 裡每一項「接受不修」
#        - review.md 是 FAIL 時還開著的每一項 [必修]
#      「提到」是寬鬆的：任何一節「交付」（含前幾次迭代的）提到那條 scenario 的標題（只比字母和數字），
#      或那個檔的路徑／檔名就算。寬的那一側：同一個檔另一個問題也算數，不會假紅。
# 「外部來源只用替身驗過」只在 implementer 的回傳裡、不在磁碟上 —— 這支看不到，通過時提醒一句。
#
# 唯讀：不寫任何檔。DLP：只回 scenario 標題、檔:行與審核的問題摘要（都已經在 bdd-docs/ 或 QA 的 .feature 裡）。
#
# Exit: 0 = 可以交付；2 = 有沒過的項目（訊息附修法）；1 = feature-id 不合法、找不到 spec.md 等錯誤。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FeatureId,
    [string[]]$TestResults = @(),        # implementer 最後一次回報的結果檔（全套測試的 TRX 或 JUnit XML）
    [string]$DocsRoot = 'bdd-docs',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# 同一段在每一支會被程式呼叫的腳本裡各有一份（清單由 test-hook-payload.ps1 守住）。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
}

. (Join-Path $PSScriptRoot 'lib/workspace-repos.ps1')
. (Join-Path $PSScriptRoot 'lib/source-files.ps1')

$MaxItems = 5   # 每一項問題最多列幾筆，其餘只給數量（收據要有界；全文在各自的檔或 gherkin-check 裡）

function Fail-Hard([string]$msg) {
    if ($Json) { [pscustomobject]@{ passed = $false; feature_id = $FeatureId; error = $msg } | ConvertTo-Json -Compress }
    else { [Console]::Error.WriteLine("[delivery-check] $msg") }
    exit 1
}

function NormId([string]$s) { return ($s -replace '[^\p{L}\p{N}]', '').ToLowerInvariant() }

# 解析格式跟 dlp-gate 的 Get-MustItems 同一條（reviewer.toml 規定的那一行）。
function Get-MustItems([string]$text) {
    $out = @()
    foreach ($line in ($text -replace "`r`n", "`n") -split "`n") {
        $m = [regex]::Match($line, '^\s*\d+\.\s*\[必修\]\s*(.+?)\s+——\s+(.+?)\s*$')
        if (-not $m.Success) { continue }
        $loc = $m.Groups[1].Value.Trim().Trim('`', '{', '}')
        $out += [pscustomobject]@{ location = $loc; file = ($loc -replace '(:\d+(-\d+)?)+$', ''); problem = $m.Groups[2].Value }
    }
    return $out
}

# 「## 上一輪必修的交代」裡的「接受不修」（格式同 dlp-gate 的 Get-AccountedFiles）。
function Get-AcceptedItems([string]$text) {
    $out = @(); $in = $false
    foreach ($line in ($text -replace "`r`n", "`n") -split "`n") {
        if ($line -match '^##\s') { $in = $line -match '^##\s*上一輪必修的交代'; continue }
        if (-not $in) { continue }
        $m = [regex]::Match($line, '^\s*[-*]\s*(.+?)\s+——\s+(.+?)[:：]\s*接受不修\s*——\s*\S')
        if (-not $m.Success) { continue }
        $loc = $m.Groups[1].Value.Trim().Trim('`', '{', '}')
        $out += [pscustomobject]@{ location = $loc; file = ($loc -replace '(:\d+(-\d+)?)+$', ''); problem = $m.Groups[2].Value.Trim() }
    }
    return $out
}

# 首行 `# feature-id: {id}` 的 .feature（判法跟 gherkin-check 找 spec 的那一條相同：第一個 feature-id 行）。
# 單一 repo 用 git（照 .gitignore 篩）；工作區底下有好幾個 repo、或根目錄不是 repo 時逐檔走 —— 根目錄的 git 看不進
# 巢狀 repo，前後端分成兩個 repo 時 .feature 全在裡面，會一個都找不到（lib/workspace-repos.ps1）。
function Get-FeatureFiles([string]$id) {
    $cands = @()
    $here = (Get-Location).Path
    $listed = if (Test-SingleRepo @(Get-WorkspaceRepos $here)) { Invoke-GitUtf8 $here @('ls-files', '--cached', '--others', '--exclude-standard', '--', '*.feature') } else { $null }
    if ($listed -and $listed.ok) {
        $cands = @($listed.lines)
    } else {
        $cands = @(Select-WorkspaceFiles -Files (Get-WorkspaceFiles -Root $here -ExcludeDirs @('.git', 'node_modules', 'bin', 'obj', 'target', 'build', 'out', 'dist', '.features-gen')) -Patterns '*.feature' |
            ForEach-Object { Get-WorkspaceRelPath $here $_.FullName })
    }
    $docs = ($DocsRoot -replace '\\', '/').Trim('/')
    $hit = @()
    foreach ($c in $cands) {
        $rel = $c -replace '\\', '/'
        if ($rel -like "$docs/*" -or -not (Test-Path -LiteralPath $rel -PathType Leaf)) { continue }
        $m = [regex]::Match([IO.File]::ReadAllText((Resolve-Path -LiteralPath $rel).Path), '(?m)^\s*#\s*feature-id:\s*([A-Za-z0-9._-]+)')
        if ($m.Success -and $m.Groups[1].Value -ceq $id) { $hit += $rel }
    }
    return $hit
}

$problems = [Collections.Generic.List[object]]::new()
function Add-Problem([string]$code, [string]$detail, [string]$fix, [string[]]$items = @()) {
    $items = @($items | Where-Object { $_ })
    $problems.Add([pscustomobject]@{
        code = $code; detail = $detail; fix = $fix
        items = @($items | Select-Object -First $MaxItems); omitted = [Math]::Max(0, $items.Count - $MaxItems)
    })
}

if ($FeatureId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Fail-Hard "feature-id「$FeatureId」不合法 —— 是 bdd-docs/ 底下那個目錄名" }
$specRel = "$(($DocsRoot -replace '\\', '/').TrimEnd('/'))/$FeatureId/spec.md"
if (-not (Test-Path -LiteralPath $specRel -PathType Leaf)) { Fail-Hard "找不到 $specRel" }
$specText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $specRel).Path) -replace "`r`n", "`n"
$featureDir = Split-Path $specRel -Parent

# ---- 1. 審核 ----
$verdict = $null
$openMust = @()
$reviewRel = "$featureDir/review.md" -replace '\\', '/'
if (-not (Test-Path -LiteralPath $reviewRel -PathType Leaf)) {
    Add-Problem 'no-review' "沒有 $reviewRel —— ⑤ 沒跑過" '委派 reviewer（mode: code）審過再交付'
} else {
    $reviewText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $reviewRel).Path)
    $vm = [regex]::Match($reviewText, '(?m)^\s*VERDICT\s*:\s*(PASS|FAIL)\b')
    if (-not $vm.Success) {
        Add-Problem 'review-no-verdict' "$reviewRel 沒有 VERDICT: PASS | FAIL 那一行" '請 reviewer 照它的格式重寫 review.md'
    } else {
        $verdict = $vm.Groups[1].Value
        if ($verdict -eq 'FAIL') { $openMust = @(Get-MustItems $reviewText) }
    }
}
# 接受不修：每一輪快照加上最新的 review.md（「上一輪必修的交代」只涵蓋上一輪，早幾輪接受的只留在快照裡）。
$accepted = @()
$reviewSources = @(Get-ChildItem -LiteralPath (Join-Path $featureDir 'reviews') -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name | ForEach-Object { $_.FullName })
if (Test-Path -LiteralPath $reviewRel -PathType Leaf) { $reviewSources += (Resolve-Path -LiteralPath $reviewRel).Path }
$seen = @{}
foreach ($src in $reviewSources) {
    foreach ($a in @(Get-AcceptedItems ([IO.File]::ReadAllText($src)))) {
        $k = "$($a.file)|$(NormId $a.problem)"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $accepted += $a }
    }
}

# ---- 2. 驗收條件（gherkin-check） ----
$features = @(Get-FeatureFiles $FeatureId)
$manual = @()
$gherkin = [ordered]@{ applicable = $false; features = $features; passed = $null }
$specHasGherkin = $specText -match '(?m)^```gherkin'
if (-not $features.Count) {
    if ($specHasGherkin) {
        Add-Problem 'feature-not-found' "spec.md 有 Gherkin 區塊，但 repo 裡找不到首行 # feature-id: $FeatureId 的 .feature" '請 implementer 把 Gherkin 區塊落成 .feature（放在測試樹、首行保留 # feature-id:），或確認它在 git 看得到的位置'
    }
} else {
    $gherkin.applicable = $true
    $missingResults = @($TestResults | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if (-not $TestResults.Count) {
        Add-Problem 'no-test-results' '.feature 存在，但沒有給結果檔 —— 判不出每條 scenario 有沒有通過、是不是現在這份程式碼跑的' '帶 implementer 最後一次回報的全套測試結果檔：-TestResults {TRX 或 JUnit XML 的 path}'
    } elseif ($missingResults.Count) {
        Add-Problem 'test-results-missing' '給的結果檔不存在' '確認 path；不在了就請 implementer 重跑全套測試' $missingResults
    }
    $useResults = if ($TestResults.Count -and -not $missingResults.Count) { $TestResults } else { @() }
    $gcOut = & (Join-Path $PSScriptRoot 'gherkin-check.ps1') -Feature $features -TestResults $useResults -DocsRoot $DocsRoot -Json
    $gc = $null
    try { $gc = ($gcOut | Out-String) | ConvertFrom-Json } catch { }
    if (-not $gc) {
        Add-Problem 'gherkin-check-error' 'gherkin-check 沒有回結果' "自己跑一次看訊息：pwsh -NoProfile -File .codex/scripts/gherkin-check.ps1 -Feature $($features -join ',')"
    } else {
        $labels = [ordered]@{
            error                        = '跑不起來'
            missing_scenarios            = 'spec 的 scenario 不在 .feature 裡'
            missing_steps                = '步驟沒有逐字照抄'
            removed_scenarios            = '既有的 scenario 被刪了'
            removed_steps                = '既有 step 的措辭被改了'
            skipped_scenarios            = 'scenario 被標成略過'
            scenarios_without_test       = '結果檔裡找不到這條 scenario 的測試'
            scenarios_not_passed         = '這條 scenario 的測試沒有全部通過'
            prior_scenarios_without_test = '前幾次迭代的 scenario 找不到測試'
            prior_scenarios_not_passed   = '前幾次迭代的 scenario 沒有全部通過'
            stale_results_newer          = '結果檔比這些改過的檔舊'
        }
        $items = @()
        foreach ($r in @($gc.results)) {
            $manual += @($r.manual_scenarios | Where-Object { $_ })
            foreach ($k in $labels.Keys) {
                foreach ($v in @($r.$k | Where-Object { $_ })) {
                    $txt = if ($v -is [string]) { $v } elseif ($v.scenario -and $v.step) { "$($v.scenario)：$($v.step)" } elseif ($v.scenario) { $v.scenario } else { [string]$v }
                    $items += "$($labels[$k])：$txt"
                }
            }
            if ($r.skipped_tests -gt 0) { $items += "測試結果裡有 $($r.skipped_tests) 個 skipped" }
        }
        $gherkin.passed = [bool]$gc.passed
        if (-not $gc.passed) {
            $cmd = "pwsh -NoProfile -File .codex/scripts/gherkin-check.ps1 -Feature $($features -join ',')$(if ($useResults.Count) { " -TestResults $($useResults -join ',')" })"
            Add-Problem 'gherkin' 'gherkin-check 沒過' "結果檔過期 → 請 implementer 重跑全套測試、給新的結果檔；其餘是實作的問題 → 交回 implementer（mode: fix）。全文：$cmd" $items
        }
    }
}
$manual = @($manual | Select-Object -Unique)
$gherkin.manual = $manual

# ---- 3. 交付一節 ----
$sections = @([regex]::Matches($specText, '(?ms)^##[ \t]*交付[^\n]*\n(.*?)(?=^##\s|\z)') | ForEach-Object { $_.Groups[1].Value })
$allDelivery = $sections -join "`n"
$deliveryNorm = NormId $allDelivery
$deliveryLower = $allDelivery.ToLowerInvariant()
function Test-Mentioned([string]$file) {
    if (-not $file) { return $false }
    $f = ($file -replace '\\', '/').ToLowerInvariant()
    $leaf = [IO.Path]::GetFileName($f)
    return $deliveryLower.Contains($f) -or ($leaf -and $deliveryLower.Contains($leaf))
}
$required = @()
foreach ($s in $manual)   { $required += [pscustomobject]@{ kind = 'manual';   text = "待人工驗證：$s"; ok = ([bool]$deliveryNorm -and $deliveryNorm.Contains((NormId $s))) } }
foreach ($a in $accepted) { $required += [pscustomobject]@{ kind = 'accepted'; text = "接受不修：$($a.location) —— $($a.problem)"; ok = (Test-Mentioned $a.file) } }
foreach ($o in $openMust) { $required += [pscustomobject]@{ kind = 'open-must'; text = "未修（審核 FAIL）：$($o.location) —— $($o.problem)"; ok = (Test-Mentioned $o.file) } }
$missing = @($required | Where-Object { -not $_.ok })

if (-not $sections.Count) {
    Add-Problem 'no-delivery-section' 'spec.md 沒有「## 交付 —— {日期}」一節' '在 spec.md 尾端寫「## 交付 —— {日期}」：怎麼驗的（指令、結果）與殘留風險（沒有寫「無」）'
} elseif ($sections[-1] -notmatch '殘留風險|剩餘風險') {
    Add-Problem 'delivery-no-risk-line' '最後那一節「交付」沒有寫殘留風險' '補一行「殘留風險：」，逐項列出；沒有就寫「殘留風險：無」'
}
if ($missing.Count) {
    Add-Problem 'delivery-missing-risk' '這幾項殘留風險沒有寫進「交付」' '一項一行寫進最後那一節「交付」的殘留風險（照下面的寫法；檔:行與 scenario 標題要寫出來，這支靠它們對）' @($missing | ForEach-Object { $_.text })
}
# FAIL 本身不擋：使用者在修正輪上限接受了這一版就能交付，代價是每一項必修都寫進殘留風險（上面已經核對）。
# 但 FAIL 卻一項必修都沒有 → reviewer 寫壞了，那不能當成「接受了」。
if ($verdict -eq 'FAIL' -and -not $openMust.Count) {
    Add-Problem 'review-fail-without-must' 'review.md 是 FAIL，卻解析不到任何 [必修]' '請 reviewer 照格式重寫（「N. [必修] 檔:行 —— 問題」），或確認這一版到底能不能交'
}

$passed = $problems.Count -eq 0
$reminder = '「外部來源只用替身驗過」只在 implementer 的回傳裡，這支看不到 —— 有的話確認已寫進交付。'

if ($Json) {
    [pscustomobject]@{
        passed     = $passed
        feature_id = $FeatureId
        spec       = $specRel
        review     = [pscustomobject]@{ path = $reviewRel; verdict = $verdict }
        gherkin    = [pscustomobject]$gherkin
        delivery   = [pscustomobject]@{ sections = $sections.Count; required = @($required | ForEach-Object { $_.text }); missing = @($missing | ForEach-Object { $_.text }) }
        problems   = @($problems)
        reminder   = $reminder
    } | ConvertTo-Json -Depth 6 -Compress
} elseif ($passed) {
    $g = if ($gherkin.applicable) { "gherkin-check 通過（$($features.Count) 個 .feature$(if ($manual.Count) { "，$($manual.Count) 條 @manual" })）" } else { '沒有 .feature（不適用）' }
    $v = if ($verdict -eq 'FAIL') { '審核 FAIL（每一項必修都已列進殘留風險）' } else { '審核 PASS' }
    "[delivery-check] OK — $FeatureId：$v、$g、交付一節列了 $($required.Count) 項要列的殘留風險。"
    "  ! $reminder"
} else {
    [Console]::Error.WriteLine("[delivery-check] $FeatureId：$($problems.Count) 項沒過，先處理再交付：")
    foreach ($p in $problems) {
        [Console]::Error.WriteLine("  - $($p.code)：$($p.detail)")
        foreach ($i in $p.items) { [Console]::Error.WriteLine("      $i") }
        if ($p.omitted) { [Console]::Error.WriteLine("      …還有 $($p.omitted) 項") }
        [Console]::Error.WriteLine("    fix: $($p.fix)")
    }
}
exit $(if ($passed) { 0 } else { 2 })
