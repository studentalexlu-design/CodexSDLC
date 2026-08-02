# run-tests.ps1
# `.codex/scripts/` 的 fixture 測試執行器。
#
# 為什麼不是 Pester：本機只有 Windows 內建的 Pester 3.4（語法與 5.x 不相容，
# 且不保證目標專案有裝）。強制層的測試不該因為測試框架沒裝就跑不起來，
# 所以這裡是零依賴的 assert runner。
#
# 用法：
#   pwsh -NoProfile -File .codex\scripts\tests\run-tests.ps1
#   pwsh -NoProfile -File .codex\scripts\tests\run-tests.ps1 -Filter handoff
#
# Exit: 0 = 全數通過；1 = 有失敗。

[CmdletBinding()]
param(
    [string]$Filter,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# 一律以 repo root 為工作目錄執行（腳本內含相對路徑預設值）。
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $RepoRoot

$script:Results = @()
$script:CurrentSuite = ''

function Describe-Suite {
    param([string]$Name, [scriptblock]$Body)
    if ($Filter -and $Name -notmatch $Filter) { return }
    $script:CurrentSuite = $Name
    & $Body
}

function It-Should {
    param([string]$Name, [scriptblock]$Body)
    $rec = [pscustomobject]@{
        suite = $script:CurrentSuite; name = $Name; passed = $true; message = ''
    }
    try {
        & $Body
    } catch {
        $rec.passed = $false
        $rec.message = $_.Exception.Message
    }
    $script:Results += $rec
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) {
        throw "expected <$Expected> but got <$Actual>$(if ($Because) { " — $Because" })"
    }
}

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Because = '')
    if ($Actual -notmatch $Pattern) {
        throw "expected to match /$Pattern/ but got <$Actual>$(if ($Because) { " — $Because" })"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because = '')
    if (-not $Condition) { throw "expected true$(if ($Because) { " — $Because" })" }
}

# 以 stdin 餵 payload 呼叫受測腳本，回傳 { exit, stdout, stderr }。
#
# 一定要走 stdin，不能走 -Payload 參數：hook 實際就是 stdin，而 handoff／DLP payload
# 是多行文字 —— 經由 ArgumentList 傳遞會被空白與換行拆成多個引數，後續引數還會被
# 誤繫結到 -MaxChars 之類的參數上。那是測試自己的假象，不是受測腳本的行為。
function Invoke-Script {
    # 參數名不可用 $Args —— 那是 PowerShell 的自動變數（未繫結引數陣列），
    # 宣告成 [hashtable] 會在繫結期就轉型失敗。
    param([string]$Script, [string]$Stdin = '', [hashtable]$Params = @{})

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'pwsh'
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script)) { $psi.ArgumentList.Add($a) }
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($v -is [switch] -or $v -is [bool]) { if ($v) { $psi.ArgumentList.Add("-$k") } }
        else { $psi.ArgumentList.Add("-$k"); $psi.ArgumentList.Add([string]$v) }
    }

    $proc = [Diagnostics.Process]::Start($psi)
    # stdout/stderr 非同步讀取，避免任一管線填滿時死結。
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($Stdin) { $proc.StandardInput.Write($Stdin) }
    $proc.StandardInput.Close()
    $proc.WaitForExit()

    [pscustomobject]@{
        exit   = $proc.ExitCode
        stdout = $outTask.GetAwaiter().GetResult()
        stderr = $errTask.GetAwaiter().GetResult()
    }
}

# --- 載入所有測試檔 ---
# 部分測試要在 bdd-docs/ 底下建暫存檔才驗得到 hook 的路徑判定。
# bdd-docs/ 是目標專案的執行期產物，在本 repo 必須不存在 —— 測試建了就要收乾淨，
# 連空目錄都不留（git 不追蹤空目錄，所以這種殘留不會出現在 git status 裡）。
$bddDocsPreexisting = Test-Path 'bdd-docs'

$testFiles = Get-ChildItem $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name
foreach ($f in $testFiles) { . $f.FullName }

if (-not $bddDocsPreexisting -and (Test-Path 'bdd-docs')) {
    Remove-Item 'bdd-docs' -Recurse -Force -ErrorAction SilentlyContinue
}

Pop-Location

# --- 輸出 ---
$failed = @($script:Results | Where-Object { -not $_.passed })
$passed = @($script:Results | Where-Object { $_.passed })

if ($Json) {
    [pscustomobject]@{
        passed = ($failed.Count -eq 0)
        total  = $script:Results.Count
        failed = $failed.Count
        failures = $failed
    } | ConvertTo-Json -Depth 4 -Compress
} else {
    $bySuite = $script:Results | Group-Object suite
    foreach ($s in $bySuite) {
        $sf = @($s.Group | Where-Object { -not $_.passed })
        $mark = if ($sf.Count -eq 0) { 'PASS' } else { 'FAIL' }
        "[$mark] $($s.Name) — $($s.Group.Count - $sf.Count)/$($s.Group.Count)"
        foreach ($t in $sf) {
            "       x $($t.name)"
            "         $($t.message)"
        }
    }
    ''
    "$($passed.Count)/$($script:Results.Count) passed"
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
