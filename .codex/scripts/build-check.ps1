# build-check.ps1
# 只在 production 程式碼變更時執行 dotnet build。
# 讀 hook payload（stdin），抽出檔案路徑；僅 .cs / .csproj / .sln 觸發，
# 且排除 bdd-docs/** 與 *.md。無命中即靜默 exit 0。
#
# Exit: 0 = 無需 build 或 build 成功；2 = build 失敗（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [switch]$WhatIfPaths   # 只印出判定結果，不實際 build（測試用）
)

if (-not $Payload) { $Payload = [Console]::In.ReadToEnd() }
if (-not $Payload) { exit 0 }

# 抽出所有看起來像檔案路徑的字串
$paths = [regex]::Matches($Payload, '[""]([^""\r\n]*?\.[A-Za-z0-9]{1,10})[""]') |
    ForEach-Object { $_.Groups[1].Value }

$triggering = $paths | Where-Object {
    $p = $_ -replace '\\', '/'
    ($p -match '\.(cs|csproj|sln)$') -and ($p -notmatch '(^|/)bdd-docs/')
}

if ($WhatIfPaths) {
    "detected=$($paths.Count) triggering=$($triggering.Count)"
    $triggering | ForEach-Object { "  TRIGGER $_" }
    exit 0
}

if (-not $triggering) { exit 0 }

$sln = Get-ChildItem -Recurse -Depth 3 -Filter *.sln -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sln) { exit 0 }

$result = dotnet build --nologo --verbosity quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('[Hook] Build FAILED after production code change. Fix before proceeding.')
    $result | Select-Object -Last 10 | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 2
}
exit 0
