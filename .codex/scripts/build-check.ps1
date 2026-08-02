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

if (-not $Payload) { $Payload = [Console]::In.ReadToEnd() }
if (-not $Payload) { exit 0 }

# 抽出所有看起來像檔案路徑的字串
$paths = [regex]::Matches($Payload, '[""]([^""\r\n]*?\.[A-Za-z0-9]{1,10})[""]') |
    ForEach-Object { $_.Groups[1].Value }

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
