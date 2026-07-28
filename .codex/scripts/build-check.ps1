# build-check.ps1
# 只在 production 程式碼變更時執行 build。
# 讀 hook payload（stdin），抽出檔案路徑；僅原始碼／專案檔觸發，
# 且排除 bdd-docs/** 與 *.md。無命中即靜默 exit 0。
#
# 語言與 build 命令取自 repo-index 的 `commands`；索引不存在時退化為副檔名偵測。
# 支援 .NET（dotnet）與 Java（maven／gradle）。
#
# Exit: 0 = 無需 build 或 build 成功；2 = build 失敗（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string]$IndexPath = 'bdd-docs/artifacts/repo-index/index.json',
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
    [Console]::Error.WriteLine("[Hook] Build FAILED after production code change ($buildCmd). Fix before proceeding.")
    $result | Select-Object -Last 10 | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 2
}
exit 0
