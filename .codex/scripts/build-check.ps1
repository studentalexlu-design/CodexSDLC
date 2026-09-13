# build-check.ps1
# 只在 production 程式碼變更時執行 build。
# 讀 hook payload（stdin），抽出檔案路徑；僅原始碼／專案檔觸發，
# 且排除 bdd-docs/** 與 *.md。無命中即靜默 exit 0。
#
# 語言與 build 命令取自 repo-index 的 `commands`；索引不存在時退化為副檔名偵測。
# 支援 .NET（dotnet）與 Java（maven／gradle）。
#
# **綠燈時去抖（debounce）。** 本 hook 掛在每一次 apply_patch 上，而一次邏輯變更
# 通常由數個 patch 組成 —— 每個 patch 都 build 一次是純等待，且 implementer
# 本來就會在每個 micro-iteration 跑測試（也會 build）。因此：
#   build 成功 → 寫時間戳，之後 $DebounceSeconds 內的變更略過 build
#   build 失敗 → 刪除時間戳，之後每一次變更都重跑，直到恢復綠燈
# 去抖只作用在「已經綠燈」的情況，紅燈時的回饋速度完全不受影響。
#
# Exit: 0 = 無需 build 或 build 成功；2 = build 失敗（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string]$IndexPath = 'bdd-docs/.cache/index.json',
    [int]$DebounceSeconds = 90,   # 0 = 停用去抖（每次都 build）
    [switch]$WhatIfPaths   # 只印出判定結果，不實際 build（測試用）
)

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

if (-not $Payload) { $Payload = Read-StdinUtf8 }
if (-not $Payload) { exit 0 }

$paths = (Read-HookPayload $Payload).paths

# 語言／建置命令：優先取自索引，退化為副檔名偵測
$buildCmd = $null
$extRe    = '\.(cs|csproj|sln|java)$'
if (Test-Path $IndexPath) {
    try {
        $idx = Get-Content $IndexPath -Raw | ConvertFrom-Json
        if ($idx.commands.build) { $buildCmd = $idx.commands.build }
        switch ($idx.meta.language) {
            'java'   { $extRe = '\.(java|gradle|kts)$|(^|/)pom\.xml$' }
            'csharp' { $extRe = '\.(cs|csproj|sln)$' }
        }
    } catch { }
}

$triggering = $paths | Where-Object {
    $p = $_ -replace '\\', '/'
    ($p -match $extRe) -and ($p -notmatch '(^|/)bdd-docs/')
}

if ($WhatIfPaths) {
    "detected=$($paths.Count) triggering=$($triggering.Count) build='$buildCmd' extRe='$extRe'"
    $triggering | ForEach-Object { "  TRIGGER $_" }
    exit 0
}

if (-not $triggering) { exit 0 }

# --- 綠燈去抖 ---
# 時間戳依工作目錄雜湊命名，避免多個 repo 互相干擾。
$stampDir = [IO.Path]::GetTempPath()
$cwdHash  = [BitConverter]::ToString(
    [Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes((Get-Location).Path))
).Replace('-', '').Substring(0, 12)
$stamp = Join-Path $stampDir "codex-build-check-$cwdHash.stamp"

if ($DebounceSeconds -gt 0 -and (Test-Path $stamp)) {
    $age = ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds
    if ($age -lt $DebounceSeconds) { exit 0 }   # 上次 build 綠燈且仍在視窗內
}

# 索引沒給命令時，依專案檔存在性推斷
if (-not $buildCmd) {
    if (Get-ChildItem -Recurse -Depth 3 -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1) {
        $buildCmd = 'dotnet build --nologo --verbosity quiet'
    } elseif (Get-ChildItem -Recurse -Depth 3 -Filter pom.xml -ErrorAction SilentlyContinue | Select-Object -First 1) {
        $buildCmd = 'mvn -q -B compile'
    } elseif (Get-ChildItem -Recurse -Depth 3 -Filter build.gradle* -ErrorAction SilentlyContinue | Select-Object -First 1) {
        $buildCmd = 'gradle -q compileJava'
    } else {
        exit 0   # 無可辨識的專案，不阻斷
    }
}

$parts = $buildCmd -split '\s+'
$exe   = $parts[0]
if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { exit 0 }   # 工具鏈不可用時不阻斷

$result = & $exe @($parts[1..($parts.Count - 1)]) 2>&1
if ($LASTEXITCODE -ne 0) {
    # 紅燈：清掉時間戳，讓下一次變更立即重驗，不受去抖視窗影響。
    Remove-Item $stamp -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("[Hook] Build FAILED after production code change ($buildCmd). Fix before proceeding.")
    $result | Select-Object -Last 10 | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 2
}
# 綠燈：記錄時間戳，開啟去抖視窗。
if ($DebounceSeconds -gt 0) { Set-Content -Path $stamp -Value (Get-Date -Format o) -NoNewline }
exit 0
