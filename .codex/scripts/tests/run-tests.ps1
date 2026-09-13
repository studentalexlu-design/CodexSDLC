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
    param([string]$Script, [string]$Stdin = '', [hashtable]$Params = @{}, [hashtable]$Env = @{})

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'pwsh'
    # 一定要明講：Process.Start 用的是**行程**的目前目錄，而上面的 Push-Location 只改 PowerShell 的 location。
    # 不設的話，從別的目錄啟動 runner 時，受測的會是那個目錄底下的腳本 —— 測試照樣全綠，測的卻是別的東西。
    $psi.WorkingDirectory       = (Get-Location).Path
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    # 跟 Codex 一樣用 UTF-8 讀寫。受測腳本被重導向時一律寫 UTF-8（見各腳本的「標準 I/O」段）；
    # 這裡不指定的話會用 console 的 code page 解碼 —— 在 cp950 的終端機上，所有中文斷言都會紅。
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding  = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding  = $utf8
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script)) { $psi.ArgumentList.Add($a) }
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($v -is [switch] -or $v -is [bool]) { if ($v) { $psi.ArgumentList.Add("-$k") } }
        else { $psi.ArgumentList.Add("-$k"); $psi.ArgumentList.Add([string]$v) }
    }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }

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

# Codex 0.154.0 實測的 hook payload 形狀（2026-09-13，用假模型驅動 `codex exec` 與 `codex app-server` 錄下來）。
# 只換掉會洩漏本機資訊的值（session id、transcript 路徑）；欄位名、順序與巢狀結構照錄。
#
# 這個 builder 存在的理由：舊測試自己捏了一個 Codex 從來不送的形狀（tool_input.files[].path，路徑帶引號），
# 於是三支 PostToolUse gate 對真正的 apply_patch（路徑在 patch 標頭、沒有引號）完全失明，而測試一路全綠。
# **gate 的測試一律用這個形狀**；要驗舊形狀的相容性時才另外手寫。
#
#   apply_patch → tool_input = { command = "*** Begin Patch\n*** Add File: x\n...*** End Patch\n" }
#   Bash        → tool_input = { command = "<shell 指令>" }
#   spawn_agent → tool_input = { message = "<handoff>" }
function New-CodexHookPayload {
    param([string]$Event = 'PostToolUse', [string]$Tool = 'apply_patch', [string]$Command, [hashtable]$ToolInput)
    $toolInput = if ($ToolInput) { $ToolInput } else { @{ command = $Command } }
    $p = [ordered]@{
        session_id      = '00000000-0000-7000-8000-000000000000'
        turn_id         = '00000000-0000-7000-8000-000000000001'
        transcript_path = 'C:\codex-home\sessions\2026\09\13\rollout-2026-09-13T07-01-12-00000000.jsonl'
        cwd             = (Get-Location).Path
        hook_event_name = $Event
        model           = 'gpt-5.5'
        permission_mode = 'bypassPermissions'
        tool_name       = $Tool
        tool_input      = $toolInput
    }
    if ($Event -eq 'PostToolUse') { $p['tool_response'] = '' }
    $p['tool_use_id'] = 'call_1'
    return ($p | ConvertTo-Json -Depth 6 -Compress)
}

# apply_patch 的 patch 本體。`-Add`／`-Update` 給路徑，`-Move` 給 @(from, to)。
function New-CodexPatch {
    param([string[]]$Add = @(), [string[]]$Update = @(), [string[]]$Move = @())
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("*** Begin Patch`n")
    foreach ($a in $Add)    { [void]$sb.Append("*** Add File: $a`n+x`n") }
    foreach ($u in $Update) { [void]$sb.Append("*** Update File: $u`n@@`n-old`n+new`n") }
    if ($Move.Count -eq 2)  { [void]$sb.Append("*** Update File: $($Move[0])`n*** Move to: $($Move[1])`n@@`n-old`n+new`n") }
    [void]$sb.Append("*** End Patch`n")
    return $sb.ToString()
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
