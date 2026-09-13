# dlp-gate.ps1
# PostToolUse 縱深防禦：對寫入 bdd-docs/** 的 artifact 執行殘留掃描。
#
# 短路條件：存在 `bdd-docs/.dlp-disabled` 時整條掃描鏈路跳過。
# 這是**專案層級**的宣告（v4.0.0 起；v3 是 run 層級，而 v4 沒有 run）。
# 中途發現敏感資料 → 刪掉該檔並重跑全量掃描，見 runbooks/dlp-masking.md。
#
# 兩條 Codex 行為決定了這支腳本的輸出形狀（0.154.0 實測，見版本檔 v48-enforcement）：
#   - **阻斷**：exit 2 ＋ stderr。Codex 把 stderr 當成回饋交給模型。
#   - **不阻斷但要喊**：exit 0 的 stderr 會被**整段丟掉**（不進模型、不進 UI）。所以 hook 在叫
#     （payload 帶 hook_event_name）時，同一句話另外寫成 stdout 上的 additionalContext JSON。
#
# 另有 -Path／-Json 給手動執行與 VS Code extension 用（Problems 面板）。-Json 的 stdout 就是結果本身。
#
# Exit: 0 = 通過或已短路；2 = 偵測到殘留（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string[]]$Path,                                    # 直接指定檔案，跳過 payload 解析
    [string]$ScanScript = '.codex/scripts/dlp-residual-scan.ps1',
    [string]$DisableMarker = 'bdd-docs/.dlp-disabled',
    [switch]$Json
)

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# Codex 送進來的 payload 是 UTF-8、也用 UTF-8 解讀 hook 的輸出；Windows 上 [Console] 的編碼卻跟著 console 的
# code page 走（zh-TW 是 cp950；並行的 hook 共用同一個 console，偶爾連輸出端也是）。Codex 0.154.0 實測的後果：
# 一份 743 字、meta 完整的中文 handoff 被解成 1772 字、JSON 解析失敗、抓不到 mode —— **每一次 spawn 都被擋**；
# 阻斷理由的中文到模型手上是亂碼。只在被重導向時才換：人在終端機跑的時候照 console 的 code page 顯示。
# 同一段在 handoff-lint／dlp-gate／guideline-gate／build-check／agent-lint／sdlc.ps1 各有一份。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
}

# ---- hook payload → 這次寫出去的檔 ----
# 三支 PostToolUse gate（dlp-gate／guideline-gate／build-check）各有一份**逐字相同**的副本：
# gate 必須能獨立跑，少複製一支共用檔不該讓三支一起靜默失效。重複由 test-hook-payload.ps1 守住
# （三支的 Read-HookPayload 必須逐字相同）。
#
# 形狀以 Codex 0.154.0 實測為準：
#   apply_patch → tool_input.command 是整份 patch；路徑在 `*** Add File:`／`*** Update File:`／`*** Move to:`，**沒有引號**
#   Bash        → tool_input.command 是 shell 指令；路徑通常帶引號
# 舊版只認引號包住的路徑 —— apply_patch 寫的檔一個都抽不到，而那正是 agent 寫檔的主要途徑。症狀是零。
#
# 只看 tool_input（有的話）：其餘欄位裡的 transcript_path 是一個 .jsonl，那是對話紀錄，不是這次寫的檔。
# patch 內文裡的引號字串是**檔案內容**，不算路徑。
function Read-HookPayload([string]$raw) {
    $result = [pscustomobject]@{ event = ''; paths = @() }
    if (-not $raw) { return $result }
    $texts = @()
    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['hook_event_name']) { $result.event = [string]$doc.hook_event_name }
        $scope = if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['tool_input']) { $doc.tool_input } else { $doc }
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($scope)
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if ($null -eq $cur) { continue }
            if ($cur -is [string]) { $texts += $cur; continue }
            if ($cur -is [ValueType]) { continue }
            if ($cur -is [System.Collections.IEnumerable]) { foreach ($i in $cur) { $queue.Enqueue($i) }; continue }
            foreach ($p in $cur.PSObject.Properties) { $queue.Enqueue($p.Value) }
        }
    } catch { $texts = @($raw) }

    $paths = @()
    foreach ($t in $texts) {
        if ($t -match '(?m)^\*\*\* Begin Patch') {
            foreach ($m in [regex]::Matches($t, '(?m)^\*\*\* (?:Add File|Update File|Move to):[ \t]*(.+?)[ \t]*\r?$')) { $paths += $m.Groups[1].Value }
            continue
        }
        foreach ($m in [regex]::Matches($t, '["'']([^"''\r\n]*?\.[A-Za-z0-9]{1,10})["'']')) { $paths += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '["''](bdd-docs[\\/][^"''\r\n]*)["'']')) { $paths += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '(?<![\w.\\/-])(bdd-docs[\\/][^\s"''`;|&<>(){}]+)')) { $paths += $m.Groups[1].Value }
        if ($t -match '^[^"''\r\n*]+\.[A-Za-z0-9]{1,10}$') { $paths += $t }
    }
    $result.paths = @($paths | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    return $result
}

# 一律正規化成「相對 cwd、正斜線」—— hook 的 cwd 就是專案根。
function ConvertTo-RelPath([string]$p) {
    $n = $p.Trim() -replace '\\', '/'
    $root = ((Get-Location).Path -replace '\\', '/').TrimEnd('/')
    if ($n.StartsWith("$root/", [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring($root.Length + 1) }
    while ($n.StartsWith('./')) { $n = $n.Substring(2) }
    return $n
}

function Write-HookContext([string]$eventName, [string[]]$lines) {
    if ($Json -or -not $eventName -or -not $lines) { return }
    [Console]::Out.WriteLine((@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines -join "`n") } } |
                              ConvertTo-Json -Compress -Depth 4))
}

function Write-Result([bool]$passed, [bool]$disabled, [string[]]$scanned, $findings) {
    if (-not $Json) { return }
    [pscustomobject]@{
        passed   = $passed
        disabled = $disabled
        scanned  = @($scanned)
        findings = @($findings)
    } | ConvertTo-Json -Depth 6 -Compress
}

$hook = [pscustomobject]@{ event = ''; paths = @() }
if (-not $Path) {
    if (-not $Payload) { $Payload = Read-StdinUtf8 }
    if (-not $Payload) { Write-Result $true $false @() @(); exit 0 }
    $hook = Read-HookPayload $Payload
    $Path = $hook.paths
}
if (-not (Test-Path $ScanScript)) { Write-Result $true $false @() @(); exit 0 }

# 標記檔關掉時**每次都喊**（不阻斷，exit 仍是 0）。標記檔通常是某一次為了解卡建的，
# 建完就留在那裡 —— 之後每一個需求都在沒有殘留掃描的情況下寫檔，而畫面上一切正常。
# 靜默地「防護其實沒在生效」比擋錯更糟，這一行是唯一會提醒的東西。
if (Test-Path $DisableMarker) {
    $msg = "[Hook][DLP] 已被 $DisableMarker 關閉 —— 這次沒有掃任何檔。要恢復就刪掉那個標記檔。"
    [Console]::Error.WriteLine($msg)
    Write-HookContext $hook.event @($msg)
    Write-Result $true $true @() @()
    exit 0
}

$targets = @($Path | ForEach-Object { ConvertTo-RelPath $_ } |
             Where-Object { $_ -match '^bdd-docs/' } |
             Sort-Object -Unique |
             Where-Object { (Test-Path -LiteralPath $_) -and -not (Get-Item -LiteralPath $_).PSIsContainer })

# 全部掃完才決定 exit —— 報第一個就停，同一次寫入的第二個檔要等下一輪才看得到。
$findings = @()
foreach ($p in $targets) {
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScanScript -Path $p
    if ($LASTEXITCODE -eq 2) {
        [Console]::Error.WriteLine("[Hook][DLP] Residual sensitive pattern in ${p}: $out")
        $scan = $null
        try { $scan = ($out | Out-String) | ConvertFrom-Json } catch { }
        # 陣列一定要先放進變數：寫成 `categories = if (...) { @(...) }` 的話，if 敘述的輸出會把
        # 單元素陣列攤平成一個物件，-Json 的讀者（extension）就收到 object 而不是 array。
        $cats = @(); $refs = @()
        if ($scan) { $cats = @($scan.categories); $refs = @($scan.line_refs) }
        $findings += [pscustomobject]@{ file = $p; categories = $cats; lines = $refs }
    }
}

Write-Result ($findings.Count -eq 0) $false $targets $findings
if ($findings.Count -gt 0) { exit 2 }
exit 0
