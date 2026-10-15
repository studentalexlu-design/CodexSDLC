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
#   pwsh -NoProfile -File .codex\scripts\tests\run-tests.ps1 -Jobs 1      # 單一行程依序跑
#
# **預設平行跑**。幾乎每一條測試都另外叫起一支 pwsh（一次 1 秒多），依序跑完整套要十幾分鐘，
# 而這台有 8 核只用 1 核。工作單位是 suite（Describe-Suite），交給 -Jobs 個 worker；每個 worker 是
# 這支腳本自己（-OnlyFile／-OnlySuite），跑在**自己的 repo 複本、自己的 TEMP** 底下 ——
# 測試會寫 repo 根的 bdd-docs/（dlp-gate 的殘留掃描會看整個 bdd-docs/）、會用固定名稱的暫存目錄
# （codex-sdlc-tests…）並在 finally 整個刪掉。共用的話，A 的 email 會讓 B 的「乾淨的回 0」紅，
# B 的清理會刪掉 A 正在用的目錄 —— 紅得隨機，比慢更糟。
#
# Exit: 0 = 全數通過；1 = 有失敗。

[CmdletBinding()]
param(
    [string]$Filter,
    [switch]$Json,
    # 預設 = 邏輯核數的一半、最多 4。這裡的工作幾乎全是「起一支 pwsh」，吃 CPU：8 核的機器上實測
    # 依序 1306 秒、4 個 worker 793 秒、8 個 885 秒 —— worker 多過頭只是讓每支 pwsh 互相搶，還更容易撞上逾時。
    [int]$Jobs = [Math]::Max(1, [Math]::Min([int][Math]::Floor([Environment]::ProcessorCount / 2), 4)),
    [string]$OnlyFile,                     # worker 用：只跑這個檔裡的
    [string]$OnlySuite                     # worker 用：這一個 suite（名稱完全相等）
)

$ErrorActionPreference = 'Stop'

# 一律以 repo root 為工作目錄執行（腳本內含相對路徑預設值）。
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

# ---- 平行：協調者 ----
# 只負責切工作、開 worker、收結果；自己不跑任何測試，也不碰這台機器的環境變數（worker 各自隔離）。
if ($Jobs -gt 1 -and -not $OnlySuite) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $Utf8 = [Text.UTF8Encoding]::new($false)

    # 靜態切出每個 suite。漏掉的 suite 不會靜默消失：下面拿 worker 實際看到的 suite 清單對帳。
    $units = [Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name)) {
        $cur = $null
        foreach ($line in [IO.File]::ReadAllLines($f.FullName, $Utf8)) {
            if ($line -match "^\s*Describe-Suite\s+'([^']*)'") {
                $cur = [pscustomobject]@{ order = $units.Count; file = $f.Name; suite = $Matches[1]; weight = 0; seconds = 0.0 }
                $units.Add($cur)
            } elseif ($cur -and $line -match '^\s*It-Should\s') { $cur.weight++ }
        }
    }
    $wanted = @($units | Where-Object { -not $Filter -or $_.suite -match $Filter })
    # 重的先發（最長處理時間優先）：最後才發 test-sdlc 那幾組大的，整體就會等它一個。
    $queue = [Collections.Generic.Queue[object]]::new([object[]]@($wanted | Sort-Object weight -Descending))
    $slotCount = [Math]::Max(1, [Math]::Min($Jobs, $wanted.Count))

    # 每個 worker 一份 repo 複本。只排除跟測試無關、又大的：版控、依賴、建置產物、執行期產物。
    $skip = @('.git', 'bdd-docs', 'dist', 'vscode-extension/node_modules', 'vscode-extension/out',
              'vscode-extension/.vscode-test', 'vscode-extension/payload')
    $base = Join-Path ([IO.Path]::GetTempPath()) ('codex-sdlc-test-par-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $srcFiles = @(Get-ChildItem $RepoRoot -Recurse -File -Force | ForEach-Object {
        $rel = [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) -replace '\\', '/'
        foreach ($s in $skip) { if ($rel -eq $s -or $rel.StartsWith("$s/")) { return } }
        $rel
    })
    $free = [Collections.Generic.Queue[object]]::new()
    for ($i = 0; $i -lt $slotCount; $i++) {
        $slot = [pscustomobject]@{ repo = Join-Path $base "w$i/repo"; temp = Join-Path $base "w$i/tmp" }
        foreach ($rel in $srcFiles) {
            $dst = Join-Path $slot.repo $rel
            [void][IO.Directory]::CreateDirectory((Split-Path $dst -Parent))
            [IO.File]::Copy((Join-Path $RepoRoot $rel), $dst, $true)
        }
        [void][IO.Directory]::CreateDirectory($slot.temp)
        $free.Enqueue($slot)
    }

    $results = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new()
    $running = [Collections.Generic.List[object]]::new()
    try {
        while ($queue.Count -gt 0 -or $running.Count -gt 0) {
            while ($running.Count -lt $slotCount -and $queue.Count -gt 0) {
                $u = $queue.Dequeue(); $slot = $free.Dequeue()
                $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
                $psi.WorkingDirectory = $slot.repo
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
                foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $slot.repo '.codex/scripts/tests/run-tests.ps1'),
                                 '-Jobs', '1', '-OnlyFile', $u.file, '-OnlySuite', $u.suite, '-Json')) { $psi.ArgumentList.Add($a) }
                $psi.Environment['TEMP'] = $slot.temp; $psi.Environment['TMP'] = $slot.temp
                $p = [Diagnostics.Process]::Start($psi)
                $running.Add([pscustomobject]@{
                    unit = $u; slot = $slot; proc = $p; clock = [Diagnostics.Stopwatch]::StartNew()
                    out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync()
                })
            }
            foreach ($r in @($running)) {
                if (-not $r.proc.HasExited) { continue }
                $r.proc.WaitForExit()
                $r.unit.seconds = $r.clock.Elapsed.TotalSeconds
                $stdout = $r.out.GetAwaiter().GetResult(); $stderr = $r.err.GetAwaiter().GetResult()
                $line = @($stdout -split "`r?`n" | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
                $j = $null
                if ($line) { try { $j = $line | ConvertFrom-Json } catch { } }
                $got = if ($j) { @($j.results | Where-Object { $_ }) } else { @() }
                if (-not $j -or ($got.Count -eq 0 -and $r.unit.weight -gt 0)) {
                    $why = if (-not $j) { "worker 沒有回報結果（exit $($r.proc.ExitCode)）" } else { '一條測試都沒跑到（-OnlySuite 對不上？）' }
                    $tail = (($stderr.Trim(), $stdout.Trim()) | Where-Object { $_ }) -join ' | '
                    $results.Add([pscustomobject]@{ order = $r.unit.order; suite = $r.unit.suite; name = '(worker)'; passed = $false
                                                   message = "$why$(if ($tail) { "：$($tail.Substring(0, [Math]::Min(800, $tail.Length)))" })" })
                }
                $k = 0
                foreach ($t in $got) {
                    $results.Add([pscustomobject]@{ order = $r.unit.order + ($k++ / 10000); suite = $t.suite; name = $t.name; passed = [bool]$t.passed; message = $t.message })
                }
                if ($j) { foreach ($s in @($j.seen)) { if ($s) { [void]$seen.Add("$($s.file)|$($s.suite)") } } }
                $r.proc.Dispose()
                [void]$running.Remove($r)
                $free.Enqueue($r.slot)
            }
            if ($running.Count -gt 0) { Start-Sleep -Milliseconds 50 }
        }
    } finally {
        foreach ($r in $running) { try { $r.proc.Kill($true) } catch { } }
        Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 對帳：worker 實際載入時看到的 suite，每一個都要在靜態清單裡。不在 = 上面的解析漏了它，它沒有被跑。
    $known = [Collections.Generic.HashSet[string]]::new([string[]]@($units | ForEach-Object { "$($_.file)|$($_.suite)" }))
    foreach ($s in $seen) {
        if ($known.Contains($s)) { continue }
        $file, $suite = $s -split '\|', 2
        if ($Filter -and $suite -notmatch $Filter) { continue }
        $results.Add([pscustomobject]@{ order = [double]::MaxValue; suite = $suite; name = '(runner)'; passed = $false
                                       message = "$file 的這個 suite 沒被平行 runner 切出來，所以沒有跑 —— Describe-Suite 要寫成一行開頭的 Describe-Suite '名稱'，或用 -Jobs 1" })
    }

    $all = @($results | Sort-Object order)
    $failedP = @($all | Where-Object { -not $_.passed })
    $secs = [Math]::Round($clock.Elapsed.TotalSeconds)
    if ($Json) {
        [pscustomobject]@{ passed = ($failedP.Count -eq 0); total = $all.Count; failed = $failedP.Count; failures = @($failedP | Select-Object suite, name, passed, message) } |
            ConvertTo-Json -Depth 4 -Compress
    } else {
        foreach ($g in ($all | Group-Object suite)) {
            $gf = @($g.Group | Where-Object { -not $_.passed })
            "[$(if ($gf.Count -eq 0) { 'PASS' } else { 'FAIL' })] $($g.Name) — $($g.Group.Count - $gf.Count)/$($g.Group.Count)"
            foreach ($t in $gf) { "       x $($t.name)"; "         $($t.message)" }
        }
        ''
        "最慢的 suite：$((@($wanted | Sort-Object seconds -Descending | Select-Object -First 3) | ForEach-Object { "$($_.suite)（$([Math]::Round($_.seconds))s）" }) -join '、')"
        "$($all.Count - $failedP.Count)/$($all.Count) passed（$slotCount 個 worker，$secs 秒）"
    }
    if ($failedP.Count -gt 0) { exit 1 }
    exit 0
}

Push-Location $RepoRoot

# --- 跟這台機器隔開 ---
# 受測腳本會去問 codex（版本、模型清單）、讀使用者的 ~/.codex/config.toml、在 LocalAppData 留快取 ——
# 結果不能跟著「這台有沒有裝 codex、裝哪一版、主對話設了什麼模型」變。整個 run 期間：
#   PATH 拿掉放著 codex 的目錄（要 codex 的測試自己給一支假的：-CodexPath，或自己的 PATH）
#   CODEX_HOME、CODEX_SDLC_STATE_DIR 指到這次 run 專用的暫存目錄，結束時還原、刪掉
$SavedMachineEnv = @{ PATH = $env:PATH; CODEX_HOME = $env:CODEX_HOME; CODEX_SDLC_STATE_DIR = $env:CODEX_SDLC_STATE_DIR }
$MachineIsolation = Join-Path ([IO.Path]::GetTempPath()) ('codex-sdlc-test-machine-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$env:CODEX_HOME = Join-Path $MachineIsolation 'codex-home'
$env:CODEX_SDLC_STATE_DIR = Join-Path $MachineIsolation 'sdlc-state'
$env:PATH = @(foreach ($d in ($env:PATH -split [IO.Path]::PathSeparator)) {
    if (-not $d) { continue }
    $hasCodex = $false
    foreach ($n in @('codex.exe', 'codex.cmd', 'codex.ps1', 'codex')) {
        try { if (Test-Path -LiteralPath (Join-Path $d $n) -PathType Leaf) { $hasCodex = $true; break } } catch { }
    }
    if (-not $hasCodex) { $d }
}) -join [IO.Path]::PathSeparator

$script:Results = @()
$script:CurrentSuite = ''
$script:CurrentFile = ''
$script:SeenSuites = @()

function Describe-Suite {
    param([string]$Name, [scriptblock]$Body)
    $script:SeenSuites += [pscustomobject]@{ file = $script:CurrentFile; suite = $Name }
    if ($OnlySuite) { if ($Name -ne $OnlySuite -or $script:CurrentFile -ne $OnlyFile) { return } }
    elseif ($Filter -and $Name -notmatch $Filter) { return }
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
    # $Positional：接在具名參數後面的位置引數（例如 sdlc.ps1 set 的 key=value）。
    param([string]$Script, [string]$Stdin = '', [hashtable]$Params = @{}, [hashtable]$Env = @{}, [string[]]$Positional = @())

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
    foreach ($a in $Positional) { $psi.ArgumentList.Add($a) }
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
foreach ($f in $testFiles) { $script:CurrentFile = $f.Name; . $f.FullName }

if (-not $bddDocsPreexisting -and (Test-Path 'bdd-docs')) {
    Remove-Item 'bdd-docs' -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($k in $SavedMachineEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $SavedMachineEnv[$k]) }
Remove-Item $MachineIsolation -Recurse -Force -ErrorAction SilentlyContinue

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
        # worker 模式：協調者要每一條的結果（印各 suite 的通過數）與載入時看到的 suite（對帳用）
        results  = $(if ($OnlySuite) { @($script:Results) } else { $null })
        seen     = $(if ($OnlySuite) { @($script:SeenSuites) } else { $null })
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
