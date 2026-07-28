# repo-index.ps1
# 建立／刷新目標專案的確定性索引，讓 agent 讀索引而不是讀原始碼樹。
# 支援 .NET（C#）與 Java（Maven／Gradle）；語言與建置工具自動偵測。
#
# 核心原則：機械性探索（定位檔案、列相依、抓簽章）由腳本做，零 token。
# LLM 只讀本腳本輸出的 index.json —— 包含 `meta.language`、`test-toolchain`
# 與 `commands`，下游 agent 一律讀 `commands`，**不得自行硬編 dotnet／mvn／gradle**。
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

# Java
$poms       = @(Get-SourceFiles 'pom.xml')
$gradles    = @(Get-SourceFiles 'build.gradle') + @(Get-SourceFiles 'build.gradle.kts')
$javaFiles  = @(Get-SourceFiles '*.java')
$appYaml    = @(Get-SourceFiles 'application*.yml') + @(Get-SourceFiles 'application*.yaml') +
              @(Get-SourceFiles 'application*.properties')

# ---------- 語言判定 ----------
# 依原始碼檔數決定主語言；兩者都有且比例接近時標 mixed，由 agent 依 handoff 目標路徑決定。
$language =
    if ($csFiles.Count -gt 0 -and $javaFiles.Count -eq 0) { 'csharp' }
    elseif ($javaFiles.Count -gt 0 -and $csFiles.Count -eq 0) { 'java' }
    elseif ($csFiles.Count -eq 0 -and $javaFiles.Count -eq 0) { 'unknown' }
    elseif ($csFiles.Count -ge $javaFiles.Count * 4) { 'csharp' }
    elseif ($javaFiles.Count -ge $csFiles.Count * 4) { 'java' }
    else { 'mixed' }

$buildTool =
    if ($poms.Count -gt 0) { 'maven' }
    elseif ($gradles.Count -gt 0) { 'gradle' }
    elseif ($slnFiles.Count -gt 0 -or $csprojs.Count -gt 0) { 'dotnet' }
    else { $null }

$srcFiles = switch ($language) {
    'java'  { $javaFiles }
    'mixed' { @($csFiles) + @($javaFiles) }
    default { $csFiles }
}

# ---------- 分域 hash ----------
$structureInput = (@($slnFiles) + @($csprojs) + @($poms) + @($gradles) | Sort-Object FullName | ForEach-Object {
    "$(ConvertTo-RelPath $_.FullName):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
$structureHash = Get-Sha256 $structureInput

$configInput = (@($appsettings) + @($appYaml) | Sort-Object FullName | ForEach-Object {
    "$(ConvertTo-RelPath $_.FullName):$($_.Length)" }) -join "`n"
$configHash = Get-Sha256 $configInput

$symbolInput = ($srcFiles | Sort-Object FullName | ForEach-Object {
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

# ---------- Java 專案（Maven / Gradle） ----------
foreach ($p in (@($poms) + @($gradles))) {
    $x = Get-Content $p.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $x) { continue }
    $deps = if ($p.Name -eq 'pom.xml') {
        @([regex]::Matches($x, '<artifactId>\s*([^<\s]+)\s*</artifactId>') | ForEach-Object { $_.Groups[1].Value })
    } else {
        @([regex]::Matches($x, '(?m)^\s*(?:test|api|implementation|testImplementation)\s*[\(\s]["'']([^"'']+)["'']') |
            ForEach-Object { ($_.Groups[1].Value -split ':')[1] } | Where-Object { $_ })
    }
    $projects += [pscustomobject]@{
        name              = Split-Path (Split-Path $p.FullName -Parent) -Leaf
        path              = ConvertTo-RelPath $p.FullName
        'target-framework'= ([regex]::Match($x, '<(?:maven\.compiler\.release|java\.version)>([^<]+)<')).Groups[1].Value
        'project-refs'    = @([regex]::Matches($x, '<module>\s*([^<\s]+)\s*</module>') | ForEach-Object { $_.Groups[1].Value })
        'package-refs'    = @($deps | Sort-Object -Unique)
    }
}

# ---------- test toolchain（依語言偵測；原本寫在 project-scanner.toml） ----------
$allPkgs = @($projects.'package-refs' | Where-Object { $_ })
function Find-Pkg([string[]]$names) {
    foreach ($n in $names) { if ($allPkgs -match "^$n") { return $n } }
    return $null
}

if ($language -eq 'java') {
    $testToolchain = [pscustomobject]@{
        language  = 'java'
        test      = Find-Pkg @('junit-jupiter', 'junit', 'testng')
        bdd       = Find-Pkg @('cucumber-java', 'cucumber-junit', 'cucumber-spring', 'jbehave')
        mock      = Find-Pkg @('mockito', 'easymock')
        assertion = Find-Pkg @('assertj', 'hamcrest', 'truth')
    }
    if (-not $testToolchain.bdd) {
        $testToolchain | Add-Member -NotePropertyName 'bdd-fallback' -NotePropertyValue 'cucumber-java + cucumber-junit-platform-engine' -Force
    }
} else {
    $testToolchain = [pscustomobject]@{
        language  = if ($language -eq 'mixed') { 'mixed' } else { 'csharp' }
        test      = Find-Pkg @('xunit', 'NUnit', 'MSTest')
        bdd       = Find-Pkg @('Reqnroll', 'SpecFlow')
        mock      = Find-Pkg @('NSubstitute', 'Moq', 'FakeItEasy')
        assertion = Find-Pkg @('AwesomeAssertions', 'FluentAssertions', 'Shouldly')
    }
    if (-not $testToolchain.bdd) {
        $testToolchain | Add-Member -NotePropertyName 'bdd-fallback' -NotePropertyValue 'Reqnroll.xUnit' -Force
    }
    if ($language -eq 'mixed') {
        $testToolchain | Add-Member -NotePropertyName 'java-bdd' -NotePropertyValue (
            Find-Pkg @('cucumber-java', 'cucumber-junit') ?? 'cucumber-java + cucumber-junit-platform-engine') -Force
    }
}

# ---------- build / test 命令（下游一律讀這裡，不得自行硬編） ----------
$commands = switch ($buildTool) {
    'maven'  { [pscustomobject]@{
                 'build-tool'='maven';  build='mvn -q -B compile'; test='mvn -q -B test'
                 'test-filter'='mvn -q -B test -Dtest={pattern}'
                 acceptance='mvn -q -B test -Dtest=*CucumberTest'
                 'source-globs'=@('**/*.java'); 'project-globs'=@('pom.xml')
                 'step-def-glob'='**/*Steps.java'; 'feature-glob'='**/*.feature' } }
    'gradle' { [pscustomobject]@{
                 'build-tool'='gradle'; build='gradle -q compileJava'; test='gradle -q test'
                 'test-filter'='gradle -q test --tests {pattern}'
                 acceptance='gradle -q test --tests *Cucumber*'
                 'source-globs'=@('**/*.java'); 'project-globs'=@('build.gradle','build.gradle.kts')
                 'step-def-glob'='**/*Steps.java'; 'feature-glob'='**/*.feature' } }
    'dotnet' { [pscustomobject]@{
                 'build-tool'='dotnet';  build='dotnet build --nologo'; test='dotnet test --no-build'
                 'test-filter'='dotnet test --no-build --filter {pattern}'
                 acceptance='dotnet test --no-build --filter Category=Acceptance'
                 'source-globs'=@('**/*.cs'); 'project-globs'=@('*.sln','*.csproj')
                 'step-def-glob'='**/*Steps.cs'; 'feature-glob'='**/*.feature' } }
    default  { $null }
}

# ---------- entrypoints ----------
$entrypoints = if ($language -eq 'java') {
    @($javaFiles | Where-Object {
        $_.Name -match 'Application\.java$' -or $_.Name -match 'Controller\.java$' -or
        $_.Name -match 'Resource\.java$'    -or $_.Name -eq 'Main.java'
    } | ForEach-Object { ConvertTo-RelPath $_.FullName })
} else {
    @($srcFiles | Where-Object {
        $_.Name -eq 'Program.cs' -or $_.Name -eq 'Startup.cs' -or
        $_.Name -match 'Controller\.(cs|java)$' -or $_.Name -match 'Endpoints?\.cs$' -or
        $_.Name -match 'Application\.java$'
    } | ForEach-Object { ConvertTo-RelPath $_.FullName })
}

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
# Java：properties / yml 只抓 key path，不抓值
foreach ($a in $appYaml) {
    $rel = ConvertTo-RelPath $a.FullName
    Get-Content $a.FullName -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_ -match '^\s*([A-Za-z0-9_.\-]+)\s*[:=]') { $configKeys += "${rel}#$($Matches[1])" } }
}

# ---------- symbols（只抓 public 簽章，不含 body） ----------
$symbols = @()
$symFiles = $srcFiles | Select-Object -First $MaxSymbolFiles
foreach ($f in $symFiles) {
    $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $txt) { continue }
    $isJava = $f.Extension -eq '.java'
    $types = if ($isJava) {
        @([regex]::Matches($txt,
            '(?m)^\s*public\s+(?:final\s+|abstract\s+|static\s+)*(class|interface|record|enum)\s+(\w+)') |
            ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
    } else {
        @([regex]::Matches($txt,
            '(?m)^\s*public\s+(?:sealed\s+|abstract\s+|static\s+|partial\s+)*(class|interface|record|struct|enum)\s+(\w+)') |
            ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
    }
    $methods = if ($isJava) {
        # interface 方法隱含 public、無修飾詞，因此 public 為選用；
        # 以負向前瞻排除控制流關鍵字，避免把 `else if (` 之類誤判為方法。
        @([regex]::Matches($txt,
            '(?m)^\s*(?:public\s+|protected\s+)?(?:static\s+|final\s+|synchronized\s+|abstract\s+|default\s+)*(?!(?:if|for|while|switch|catch|return|else|new|throw|class|interface|record|enum)\b)[\w<>,\[\]\.\?]+\s+(\w+)\s*\(') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notin @('if','for','while','switch','catch','return') } |
            Sort-Object -Unique)
    } else {
        @([regex]::Matches($txt,
            '(?m)^\s*public\s+(?:static\s+|async\s+|virtual\s+|override\s+|sealed\s+)*[\w<>,\[\]\?\.]+\s+(\w+)\s*\(') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
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
        'language'          = $language
        'build-tool'        = $buildTool
        'file-count'        = $srcFiles.Count
        'cs-file-count'     = $csFiles.Count
        'java-file-count'   = $javaFiles.Count
        'project-count'     = $projects.Count
        'refreshed-scopes'  = $stale
        'changed-files'     = @($changedFiles | Select-Object -First 200)
        'symbol-truncated'  = ($srcFiles.Count -gt $MaxSymbolFiles)
    }
    solutions       = @(@($slnFiles) + @($poms) + @($gradles) | ForEach-Object { ConvertTo-RelPath $_.FullName })
    projects        = $projects
    'test-toolchain'= $testToolchain
    commands        = $commands
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
    summary  = "$language/$buildTool, $($projects.Count) projects, $($srcFiles.Count) source files, $($symbols.Count) symbol entries"
    counts   = [pscustomobject]@{ projects=$projects.Count; files=$srcFiles.Count; entrypoints=$entrypoints.Count }
    open_questions = 0
} | ConvertTo-Json -Depth 5 | Set-Content $digestPath -Encoding UTF8

[pscustomobject]@{
    status = 'refreshed'; index_path = $indexPath; digest_path = $digestPath
    stale_scopes = $stale; invalidation_mode = $invalidationMode
    index_bytes = $json.Length
    file_count = $srcFiles.Count; project_count = $projects.Count; language = $language; build_tool = $buildTool
} | ConvertTo-Json -Depth 4 -Compress
exit 0
