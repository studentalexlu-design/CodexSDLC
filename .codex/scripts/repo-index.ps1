# repo-index.ps1
# 建立／刷新目標 .NET 專案的確定性索引，讓 agent 讀索引而不是讀原始碼樹。
#
# 核心原則：機械性探索（定位檔案、列相依、抓簽章）由腳本做，零 token。
# LLM 只讀本腳本輸出的 index.json。
#
# 失效判定：偵測到 git → git diff；非 git → 檔案 hash 比對。分域失效，只重掃有變的 scope。
#
# Exit: 0 = 索引為最新或已成功刷新；1 = 錯誤。

[CmdletBinding()]
param(
    [string]$Root = '.',
    [string]$OutDir = 'bdd-docs/artifacts/repo-index',
    [switch]$Force,          # 忽略快取，完整重建
    [switch]$StatusOnly,     # 只回報 staleness，不寫檔
    [int]$MaxSymbolFiles = 1500
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path
$indexPath  = Join-Path $OutDir 'index.json'
$digestPath = Join-Path $OutDir 'index-digest.json'

function Get-Sha256([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

$excludeRe = '[\\/](bin|obj|node_modules|packages|\.git|\.vs|TestResults|dist|build)[\\/]'

function Get-SourceFiles([string]$pattern) {
    Get-ChildItem -Path $Root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludeRe }
}

function ConvertTo-RelPath([string]$full) {
    ($full -replace [regex]::Escape($Root), '').TrimStart('\', '/') -replace '\\', '/'
}

# ---------- git 偵測 ----------
$gitSha = $null
Push-Location $Root
try {
    $null = git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) { $gitSha = (git rev-parse HEAD 2>$null) }
} catch { }
finally { Pop-Location }
$invalidationMode = if ($gitSha) { 'git' } else { 'hash' }

# ---------- 讀既有索引 ----------
$prev = $null
if ((Test-Path $indexPath) -and -not $Force) {
    try { $prev = Get-Content $indexPath -Raw | ConvertFrom-Json } catch { $prev = $null }
}

# ---------- 掃描輸入 ----------
$slnFiles   = @(Get-SourceFiles '*.sln')
$csprojs    = @(Get-SourceFiles '*.csproj')
$csFiles    = @(Get-SourceFiles '*.cs')
$appsettings= @(Get-SourceFiles 'appsettings*.json')

# ---------- 分域 hash ----------
$structureInput = ($slnFiles + $csprojs | Sort-Object FullName | ForEach-Object {
    "$(ConvertTo-RelPath $_.FullName):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
$structureHash = Get-Sha256 $structureInput

$configInput = ($appsettings | Sort-Object FullName | ForEach-Object {
    "$(ConvertTo-RelPath $_.FullName):$($_.Length)" }) -join "`n"
$configHash = Get-Sha256 $configInput

$symbolInput = ($csFiles | Sort-Object FullName | ForEach-Object {
    "$(ConvertTo-RelPath $_.FullName):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
$symbolHash = Get-Sha256 $symbolInput

# ---------- staleness ----------
$stale = @()
if (-not $prev) {
    $stale = @('structure', 'config', 'symbols')
} else {
    if ($prev.hashes.'structure-hash' -ne $structureHash) { $stale += 'structure' }
    if ($prev.hashes.'config-hash'    -ne $configHash)    { $stale += 'config' }
    if ($prev.hashes.'symbol-hash'    -ne $symbolHash)    { $stale += 'symbols' }
}
if ($Force) { $stale = @('structure', 'config', 'symbols') }

# git 模式下補充精確變更清單（供 agent 判斷影響面）
$changedFiles = @()
if ($gitSha -and $prev -and $prev.meta.'git-sha' -and $prev.meta.'git-sha' -ne $gitSha) {
    Push-Location $Root
    try {
        $changedFiles = @(git diff --name-only "$($prev.meta.'git-sha')..HEAD" 2>$null |
            Where-Object { $_ -and $_ -notmatch $excludeRe })
    } catch { } finally { Pop-Location }
}

if ($StatusOnly) {
    [pscustomobject]@{
        index_exists      = [bool]$prev
        stale_scopes      = $stale
        invalidation_mode = $invalidationMode
        git_sha           = $gitSha
        changed_files     = $changedFiles
        needs_refresh     = ($stale.Count -gt 0)
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}

if ($stale.Count -eq 0 -and $prev) {
    [pscustomobject]@{
        status = 'current'; index_path = $indexPath
        file_count = $prev.meta.'file-count'; stale_scopes = @()
    } | ConvertTo-Json -Compress
    exit 0
}

# ---------- projects ----------
$projects = @()
foreach ($p in $csprojs) {
    $x = Get-Content $p.FullName -Raw
    $projects += [pscustomobject]@{
        name              = $p.BaseName
        path              = ConvertTo-RelPath $p.FullName
        'target-framework'= ([regex]::Match($x, '<TargetFrameworks?>([^<]+)<')).Groups[1].Value
        'project-refs'    = @([regex]::Matches($x, '<ProjectReference\s+Include="([^"]+)"') |
                              ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Groups[1].Value) })
        'package-refs'    = @([regex]::Matches($x, '<PackageReference\s+Include="([^"]+)"') |
                              ForEach-Object { $_.Groups[1].Value })
    }
}

# ---------- test toolchain（原本寫在 project-scanner.toml 的偵測邏輯） ----------
$allPkgs = $projects.'package-refs' | Where-Object { $_ }
function Find-Pkg([string[]]$names) {
    foreach ($n in $names) { if ($allPkgs -match "^$n") { return $n } }
    return $null
}
$testToolchain = [pscustomobject]@{
    test      = Find-Pkg @('xunit', 'NUnit', 'MSTest')
    bdd       = Find-Pkg @('Reqnroll', 'SpecFlow')
    mock      = Find-Pkg @('NSubstitute', 'Moq', 'FakeItEasy')
    assertion = Find-Pkg @('AwesomeAssertions', 'FluentAssertions', 'Shouldly')
}
if (-not $testToolchain.bdd) {
    $testToolchain | Add-Member -NotePropertyName 'bdd-fallback' -NotePropertyValue 'Reqnroll.xUnit' -Force
}

# ---------- entrypoints ----------
$entrypoints = @($csFiles | Where-Object {
    $_.Name -eq 'Program.cs' -or $_.Name -eq 'Startup.cs' -or
    $_.Name -match 'Controller\.cs$' -or $_.Name -match 'Endpoints?\.cs$'
} | ForEach-Object { ConvertTo-RelPath $_.FullName })

# ---------- config keys（只記 key path，不記 value） ----------
$configKeys = @()
foreach ($a in $appsettings) {
    try {
        $obj = Get-Content $a.FullName -Raw | ConvertFrom-Json
        $rel = ConvertTo-RelPath $a.FullName
        function Walk($node, $prefix) {
            foreach ($prop in $node.PSObject.Properties) {
                $key = if ($prefix) { "$prefix`:$($prop.Name)" } else { $prop.Name }
                if ($prop.Value -is [pscustomobject]) { Walk $prop.Value $key }
                else { $script:configKeys += "${rel}#${key}" }
            }
        }
        Walk $obj ''
    } catch { }
}

# ---------- symbols（只抓 public 簽章，不含 body） ----------
$symbols = @()
$symFiles = $csFiles | Select-Object -First $MaxSymbolFiles
foreach ($f in $symFiles) {
    $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $txt) { continue }
    $types = @([regex]::Matches($txt,
        '(?m)^\s*public\s+(?:sealed\s+|abstract\s+|static\s+|partial\s+)*(class|interface|record|struct|enum)\s+(\w+)') |
        ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
    $methods = @([regex]::Matches($txt,
        '(?m)^\s*public\s+(?:static\s+|async\s+|virtual\s+|override\s+|sealed\s+)*[\w<>,\[\]\?\.]+\s+(\w+)\s*\(') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($types.Count -or $methods.Count) {
        $symbols += [pscustomobject]@{
            file = ConvertTo-RelPath $f.FullName
            types = $types
            methods = @($methods | Select-Object -First 40)
        }
    }
}

# ---------- 組裝 ----------
$index = [pscustomobject]@{
    meta = [pscustomobject]@{
        'generated-at'      = (Get-Date).ToUniversalTime().ToString('o')
        'git-sha'           = $gitSha
        'invalidation-mode' = $invalidationMode
        'file-count'        = $csFiles.Count
        'project-count'     = $projects.Count
        'refreshed-scopes'  = $stale
        'changed-files'     = @($changedFiles | Select-Object -First 200)
        'symbol-truncated'  = ($csFiles.Count -gt $MaxSymbolFiles)
    }
    solutions       = @($slnFiles | ForEach-Object { ConvertTo-RelPath $_.FullName })
    projects        = $projects
    'test-toolchain'= $testToolchain
    entrypoints     = $entrypoints
    'config-keys'   = @($configKeys | Select-Object -First 400)
    symbols         = $symbols
    hashes = [pscustomobject]@{
        'structure-hash' = $structureHash
        'config-hash'    = $configHash
        'symbol-hash'    = $symbolHash
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$json = $index | ConvertTo-Json -Depth 8
$json | Set-Content $indexPath -Encoding UTF8

[pscustomobject]@{
    artifact = ($indexPath -replace '\\', '/')
    version  = "scan.repo-index.$((Get-Sha256 $json).Substring(0,16))"
    hash     = (Get-Sha256 $json)
    summary  = "$($projects.Count) projects, $($csFiles.Count) cs files, $($symbols.Count) symbol entries"
    counts   = [pscustomobject]@{ projects=$projects.Count; files=$csFiles.Count; entrypoints=$entrypoints.Count }
    open_questions = 0
} | ConvertTo-Json -Depth 5 | Set-Content $digestPath -Encoding UTF8

[pscustomobject]@{
    status = 'refreshed'; index_path = $indexPath; digest_path = $digestPath
    stale_scopes = $stale; invalidation_mode = $invalidationMode
    index_bytes = $json.Length
    file_count = $csFiles.Count; project_count = $projects.Count
} | ConvertTo-Json -Depth 4 -Compress
exit 0
