# repo-index.ps1
# 建立／刷新目標專案的確定性索引，讓 agent 讀索引而不是讀原始碼樹。
# 支援 .NET（C#）與 Java（Maven／Gradle）；語言與建置工具自動偵測。
#
# 核心原則：機械性探索（定位檔案、列相依、抓簽章）由腳本做，零 token。
# LLM 只讀本腳本輸出的 index.json —— 包含 `meta.language`、`test-toolchain`
# 與 `commands`，下游 agent 一律讀 `commands`，**不得自行硬編 dotnet／mvn／gradle**。
#
# 符號、DI 註冊與專案檔只看「會被編譯的那一份」：註解與 C# 的 `#if false` 先換成空白（lib/active-code.ps1）。
# 索引是 sa-analyst 不開檔就採信的答案，註解掉的舊類別或舊註冊一旦進來，它就被當成現役的擴充點。
#
# 失效判定：偵測到 git → git diff；非 git → 檔案 hash 比對。分域失效，只重掃有變的 scope
# —— `symbols` 是唯一要讀進每個檔內容的 scope，也是唯一值得沿用的；它沒失效就直接搬上一份，
# 失效了也只重掃變動的檔（每個檔的大小＋修改時間記在 symbol-cache.json）。上一個需求一定改過程式，
# 所以以前第二個需求以後的每次 ② 都是全量重建 —— 正好是 repo 最大、最需要索引的時候。
#
# 目錄樹只走一次（lib/source-files.ps1），排除的目錄不進去。
#
# `-StatusOnly` 不讀原始碼內容，是下游 agent 的固定第一動作：一次呼叫就回規模、語言、建置工具、
# 「上次索引之後變了哪些檔」，以及 project-map.md 每一節過期了沒、跨 feature 的 DB 證據與 legacy-schema 清單
# （lib/map-status.ps1）—— 以前 sa-analyst 為了這些要自己跑十幾次 git 與搜檔。
#
# Exit: 0 = 索引為最新或已成功刷新；1 = 錯誤。

[CmdletBinding()]
param(
    [string]$Root = '.',
    [string]$OutDir = 'bdd-docs/.cache',
    [switch]$Force,          # 忽略快取，完整重建
    [switch]$StatusOnly,     # 只回報 staleness，不寫檔
    [int]$MaxSymbolFiles = 1500
)

$ErrorActionPreference = 'Stop'

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# Codex 送進來的 payload 是 UTF-8、也用 UTF-8 解讀 hook 的輸出；Windows 上 [Console] 的編碼卻跟著 console 的
# code page 走（zh-TW 是 cp950；並行的 hook 共用同一個 console，偶爾連輸出端也是）。Codex 0.154.0 實測的後果：
# 一份 743 字、meta 完整的中文 handoff 被解成 1772 字、JSON 解析失敗、抓不到 mode —— **每一次 spawn 都被擋**；
# 阻斷理由的中文到模型手上是亂碼。只在被重導向時才換：人在終端機跑的時候照 console 的 code page 顯示。
# 同一段在每一支會被程式呼叫的腳本裡各有一份（清單由 test-hook-payload.ps1 守住）。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
}

. (Join-Path $PSScriptRoot 'lib/source-files.ps1')
. (Join-Path $PSScriptRoot 'lib/map-status.ps1')
# lib/active-code.ps1（剝註解）只有真的要讀原始碼時才載入 —— -StatusOnly 用不到，而光是載入它就要兩三百毫秒。
$Root = (Resolve-Path $Root).Path
$indexPath  = Join-Path $OutDir 'index.json'
$digestPath = Join-Path $OutDir 'index-digest.json'
$symCachePath = Join-Path $OutDir 'symbol-cache.json'

# 索引結構版本。改欄位就要 +1 —— 舊索引缺新欄位（ns／bases／di-registrations），
# 沿用它會讓下游把「這一版沒掃」讀成「掃過但沒有」，而那是靜默的錯。
# **欄位的產生規則改了也要 +1**：3 = `commands` 改用專案自帶的 wrapper、`bdd-fallback` 跟著測試框架走。
# 沒有 +1 的話，專案檔沒動的 repo 會一直沿用舊索引 —— ④ 照舊跑 `mvn`、照舊被建議加 `Reqnroll.xUnit`。
# 4 = 掃描前先剝掉註解與 `#if false`。原始碼沒動的 repo 若沿用 3，註解掉的類別與 DI 註冊會一直留在索引裡。
# 5 = dotnet 的 test／test-filter／acceptance 拿掉 `--no-build`（沿用 4 的 repo 會一直測到舊的 DLL）；
#     `.slnx`（.NET 9 起 `dotnet new sln` 的預設）也算 solution；symbols 改成逐檔增量（symbol-cache.json 記同一個 schema）。
$IndexSchema = 5

function Get-Sha256([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

$excludeDirs = @('bin', 'obj', 'node_modules', 'packages', '.git', '.vs', 'TestResults', 'dist', 'build')
$excludeRe = '[\\/](bin|obj|node_modules|packages|\.git|\.vs|TestResults|dist|build)[\\/]'   # git diff 的輸出用

# 整棵樹只走一次；底下每一種檔都從這一份挑（順序跟走訪順序一樣，等同以前的 Get-ChildItem -Recurse -Filter）。
$workspace = Get-WorkspaceFiles -Root $Root -ExcludeDirs $excludeDirs
function Get-SourceFiles([string[]]$patterns) { Select-WorkspaceFiles -Files $workspace -Patterns $patterns }

function ConvertTo-RelPath([string]$full) {
    # 走訪出來的檔一定以 $Root 開頭，直接切掉前綴（逐檔跑 regex 在幾千個檔上看得出來；
    # 而且 -replace 會把路徑中段再出現一次的 $Root 也刪掉 —— Linux 上 /src/app/src/x.cs 會變成 app/x.cs）。
    if ($full.StartsWith($Root, [StringComparison]::Ordinal)) { return $full.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
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
# schema 不符的舊索引一律當成沒有索引 —— 重建一次，好過讓下游拿缺欄位的索引下結論。
if ($prev -and $prev.meta.'index-schema' -ne $IndexSchema) { $prev = $null }

# ---------- 掃描輸入 ----------
$slnFiles   = @(Get-SourceFiles '*.sln') + @(Get-SourceFiles '*.slnx')
$csprojs    = @(Get-SourceFiles '*.csproj')
$csFiles    = @(Get-SourceFiles '*.cs')
$appsettings= @(Get-SourceFiles 'appsettings*.json')

# Java
$poms       = @(Get-SourceFiles 'pom.xml')
$gradles    = @(Get-SourceFiles 'build.gradle') + @(Get-SourceFiles 'build.gradle.kts')
$javaFiles  = @(Get-SourceFiles '*.java')
$appYaml    = @(Get-SourceFiles 'application*.yml') + @(Get-SourceFiles 'application*.yaml') +
              @(Get-SourceFiles 'application*.properties')

# ---------- wrapper ----------
# 專案自帶的 mvnw／gradlew 釘了它要的 Maven／Gradle 版本，有就一定用它：只有 wrapper、沒裝全域 mvn 的機器上，
# 寫死 `mvn` 的指令 ④ 根本跑不起來；裝了全域的另一版，也可能 build 不過（Gradle 尤其明顯）。
# 要「腳本＋設定檔」都在才算 —— 只有一支腳本的 wrapper 跑不起來。
# 指令一律寫 `./mvnw`：pwsh 7 與 Windows PowerShell 5.1 都會解析到 mvnw.cmd（實測），其他平台就是那支 sh 腳本。
# build-check.ps1 的退化偵測有同一套判定，兩邊由 test-repo-index.ps1 用同一組 fixture 釘住。
function Test-Wrapper([string[]]$scripts, [string]$props) {
    (@($scripts | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf }).Count -gt 0) -and
        (Test-Path -LiteralPath (Join-Path $Root $props) -PathType Leaf)
}
$mvn    = if (Test-Wrapper @('mvnw', 'mvnw.cmd') '.mvn/wrapper/maven-wrapper.properties') { './mvnw' } else { 'mvn' }
$gradle = if (Test-Wrapper @('gradlew', 'gradlew.bat') 'gradle/wrapper/gradle-wrapper.properties') { './gradlew' } else { 'gradle' }
# 進 structure hash：加上或拿掉 wrapper 時 commands 要跟著變，而那幾個檔不是專案檔。
$wrapperFiles = @(@('mvnw', 'mvnw.cmd', '.mvn/wrapper/maven-wrapper.properties',
                    'gradlew', 'gradlew.bat', 'gradle/wrapper/gradle-wrapper.properties') |
                  ForEach-Object { Join-Path $Root $_ } |
                  Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                  ForEach-Object { Get-Item -LiteralPath $_ })

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

$srcFiles = @(switch ($language) {
    'java'  { $javaFiles }
    'mixed' { @($csFiles) + @($javaFiles) }
    default { $csFiles }
})

# ---------- 分域 hash ----------
# 「相對路徑:大小[:修改時間]」一行一個、照完整路徑排序 —— 跟以前的 ForEach-Object 逐位元相同，只是 foreach 快得多。
function Get-FileListInput($files, [bool]$withTicks) {
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($f in @($files | Sort-Object FullName)) {
        $lines.Add($(if ($withTicks) { "$(ConvertTo-RelPath $f.FullName):$($f.Length):$($f.LastWriteTimeUtc.Ticks)" } else { "$(ConvertTo-RelPath $f.FullName):$($f.Length)" }))
    }
    return ($lines -join "`n")
}
$structureHash = Get-Sha256 (Get-FileListInput (@($slnFiles) + @($csprojs) + @($poms) + @($gradles) + $wrapperFiles) $true)
$configHash    = Get-Sha256 (Get-FileListInput (@($appsettings) + @($appYaml)) $false)
$symbolHash    = Get-Sha256 (Get-FileListInput $srcFiles $true)

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
    # 這份輸出要讓 agent 一次呼叫就決定得了下一步，所以規模與工具鏈也一起回 ——
    # 沒有它們，agent 為了知道「這個 repo 多大」還是得自己掃一遍，門檻等於自我否定。
    # 地圖的新鮮度只能用地圖自己的 git-sha 算（不是 changed_files：那是相對 index.json 的基準線，索引一刷新就清空）。
    $mapStatus = Get-MapStatus -Root $Root -IsGit ([bool]$gitSha)
    [pscustomobject]@{
        index_exists       = [bool]$prev
        index_path         = ($indexPath -replace '\\', '/')
        index_schema       = $IndexSchema
        stale_scopes       = $stale
        invalidation_mode  = $invalidationMode
        git_sha            = $gitSha
        language           = $language
        build_tool         = $buildTool
        file_count         = $srcFiles.Count
        project_count      = (@($csprojs).Count + @($poms).Count + @($gradles).Count)
        changed_file_count = $changedFiles.Count
        changed_files      = @($changedFiles | Select-Object -First 200)
        needs_refresh      = ($stale.Count -gt 0)
        project_map        = $mapStatus.project_map
        evidence           = @($mapStatus.evidence)
        legacy_schema      = @($mapStatus.legacy_schema)
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}

if ($stale.Count -eq 0 -and $prev) {
    [pscustomobject]@{
        status = 'current'; index_path = $indexPath
        file_count = $prev.meta.'file-count'; stale_scopes = @()
    } | ConvertTo-Json -Compress
    exit 0
}

. (Join-Path $PSScriptRoot 'lib/active-code.ps1')

# ---------- projects ----------
$projects = @()
foreach ($p in $csprojs) {
    # 註解掉的 <PackageReference> 不算：否則 test-toolchain 會說專案已經有 Reqnroll，④ 就不會去加它。
    $x = Get-ActiveCode (Get-Content $p.FullName -Raw) $p.Extension
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
    $x = Get-ActiveCode (Get-Content $p.FullName -Raw -ErrorAction SilentlyContinue) $p.Extension
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

# ---------- test toolchain（依語言偵測） ----------
$allPkgs = @($projects.'package-refs' | Where-Object { $_ })
function Find-Pkg([string[]]$names) {
    foreach ($n in $names) { if ($allPkgs -match "^$n") { return $n } }
    return $null
}

# 專案還沒有 BDD 框架時，④ 要加哪個套件。**跟著專案現有的測試框架走** —— 舊版寫死 Reqnroll.xUnit／JUnit 5，
# NUnit、MSTest、JUnit 4、TestNG 的專案會被建議加錯套件，等於引入第二套測試框架。
# 套件 ID 是 2026-10 在 nuget.org／Maven Central 查過的正式名稱（Reqnroll.MSTest 的大小寫照官方）。
function Get-BddFallback([string]$lang) {
    if ($lang -eq 'java') {
        switch (Find-Pkg @('junit-jupiter', 'junit', 'testng')) {
            'junit'  { return 'cucumber-java + cucumber-junit' }
            'testng' { return 'cucumber-java + cucumber-testng' }
            default  { return 'cucumber-java + cucumber-junit-platform-engine + junit-platform-suite' }
        }
    }
    if ($allPkgs -match '^xunit\.v3') { return 'Reqnroll.xunit.v3' }
    switch (Find-Pkg @('xunit', 'NUnit', 'MSTest')) {
        'NUnit'  { return 'Reqnroll.NUnit' }
        'MSTest' { return 'Reqnroll.MSTest' }
        default  { return 'Reqnroll.xUnit' }
    }
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
        $testToolchain | Add-Member -NotePropertyName 'bdd-fallback' -NotePropertyValue (Get-BddFallback 'java') -Force
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
        $testToolchain | Add-Member -NotePropertyName 'bdd-fallback' -NotePropertyValue (Get-BddFallback 'csharp') -Force
    }
    if ($language -eq 'mixed') {
        $testToolchain | Add-Member -NotePropertyName 'java-bdd' -NotePropertyValue (
            Find-Pkg @('cucumber-java', 'cucumber-junit') ?? (Get-BddFallback 'java')) -Force
    }
}

# ---------- build / test 命令（下游一律讀這裡，不得自行硬編） ----------
$commands = switch ($buildTool) {
    'maven'  { [pscustomobject]@{
                 'build-tool'='maven';  build="$mvn -q -B compile"; test="$mvn -q -B test"
                 'test-filter'="$mvn -q -B test -Dtest={pattern}"
                 acceptance="$mvn -q -B test -Dtest=*CucumberTest"
                 'source-globs'=@('**/*.java'); 'project-globs'=@('pom.xml')
                 'step-def-glob'='**/*Steps.java'; 'feature-glob'='**/*.feature' } }
    'gradle' { [pscustomobject]@{
                 'build-tool'='gradle'; build="$gradle -q compileJava"; test="$gradle -q test"
                 'test-filter'="$gradle -q test --tests {pattern}"
                 acceptance="$gradle -q test --tests *Cucumber*"
                 'source-globs'=@('**/*.java'); 'project-globs'=@('build.gradle','build.gradle.kts')
                 'step-def-glob'='**/*Steps.java'; 'feature-glob'='**/*.feature' } }
    # dotnet test 自己會增量 build —— 不能帶 --no-build：build-check 綠燈後 90 秒內不 build，
    # 帶著它跑的測試就是改之前那一份 DLL，紅綠判斷錯（在已經修好的地方繼續修，或帶著假綠燈交出去）。
    'dotnet' { [pscustomobject]@{
                 'build-tool'='dotnet';  build='dotnet build --nologo'; test='dotnet test'
                 'test-filter'='dotnet test --filter {pattern}'
                 acceptance='dotnet test --filter Category=Acceptance'
                 'source-globs'=@('**/*.cs'); 'project-globs'=@('*.sln','*.csproj')
                 'step-def-glob'='**/*Steps.cs'; 'feature-glob'='**/*.feature' } }
    default  { $null }
}

# ---------- entrypoints ----------
$entrypoints = @(if ($language -eq 'java') {
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
})

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

# ---------- symbols ＋ DI 註冊（只抓 public 簽章與註冊點，不含 body） ----------
# 這是整份索引唯一要讀進每個檔內容的一段，也是唯一貴到值得沿用的。
# `symbols` 沒失效就直接搬上一份 —— 只有 config 或專案檔變動時不必重讀幾千個原始碼檔。
$symbols = @()
$diRegistrations = @()

# 名稱正規化：去掉泛型引數與 namespace 前綴，只留可比對的短名。
function Get-ShortName([string]$raw) {
    $n = ($raw -replace '<[^>]*>', '').Trim()
    if ($n -match '([\w]+)$') { return $Matches[1] }
    return $n
}

$symbolsRescanned = 0
if ($prev -and ('symbols' -notin $stale)) {
    $symbols         = @($prev.symbols)
    $diRegistrations = @($prev.'di-registrations')
} else {

# 一個檔的 symbols 與 DI 註冊。結果放進 $sym（[ref]）與 $di，不碰全域陣列 —— 快取存的就是這兩樣。
function Get-FileSymbols([IO.FileInfo]$f, [string]$rel, [ref]$sym, $di) {
    # 註解掉的類別、DI 註冊與 #if false 裡的方法都不是現況 —— 下面每一條樣式都只看剝過的這一份。
    $txt = Get-ActiveCode (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue) $f.Extension
    if (-not $txt) { return }
    $isJava = $f.Extension -eq '.java'

    # namespace / package：讓「這個型別住在哪一層」不必開檔就看得出來
    $ns = if ($isJava) {
        ([regex]::Match($txt, '(?m)^\s*package\s+([\w.]+)\s*;')).Groups[1].Value
    } else {
        ([regex]::Match($txt, '(?m)^\s*namespace\s+([\w.]+)')).Groups[1].Value
    }

    # 外層的 @() 不可省：PowerShell 會把 if/switch 回傳的單元素集合展開成純量，
    # 只有一個 public 型別的檔會因此在 JSON 裡變成字串而不是陣列，讀的人得處理兩種形狀。
    $types = @(if ($isJava) {
        @([regex]::Matches($txt,
            '(?m)^\s*public\s+(?:final\s+|abstract\s+|static\s+)*(class|interface|record|enum)\s+(\w+)') |
            ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
    } else {
        @([regex]::Matches($txt,
            '(?m)^\s*public\s+(?:sealed\s+|abstract\s+|static\s+|partial\s+)*(class|interface|record|struct|enum)\s+(\w+)') |
            ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" })
    })
    $methods = @(if ($isJava) {
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
    })
    # 繼承／實作關係。「有沒有現成的擴充點」是每次分析都要問的問題，而它完全是機械可掃的：
    # 知道誰實作了 IFoo，就不必為了找掛載點把整層服務讀過一遍。
    $bases = @()
    if ($isJava) {
        foreach ($m in [regex]::Matches($txt,
            '(?m)^\s*public\s+(?:final\s+|abstract\s+|static\s+)*(?:class|interface|record|enum)\s+(\w+)\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*((?:extends|implements)\b[^{\r\n]+)')) {
            $list = @(($m.Groups[2].Value -replace '\b(extends|implements)\b', ',') -split ',' |
                      ForEach-Object { Get-ShortName $_ } | Where-Object { $_ })
            if ($list.Count) { $bases += "$($m.Groups[1].Value) : $($list -join ', ')" }
        }
    } else {
        foreach ($m in [regex]::Matches($txt,
            '(?m)^\s*public\s+(?:sealed\s+|abstract\s+|static\s+|partial\s+)*(?:class|interface|record|struct)\s+(\w+)\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*:\s*([^{\r\n]+)')) {
            $list = @((($m.Groups[2].Value -split '\bwhere\b')[0]) -split ',' |
                      ForEach-Object { Get-ShortName $_ } | Where-Object { $_ })
            if ($list.Count) { $bases += "$($m.Groups[1].Value) : $($list -join ', ')" }
        }
    }

    # DI 註冊：C# 是泛型註冊呼叫，Java 是類別層註解。兩者都是「這個實作真的被掛上去了」的訊號 ——
    # 光看有沒有實作某介面不夠，沒註冊的實作是死碼，掛上去的那個才是擴充點。
    if ($isJava) {
        $primary = if ($types.Count) { ($types[0] -split '\s+')[-1] } else { $f.BaseName }
        foreach ($a in @([regex]::Matches($txt, '(?m)^\s*@(Service|Component|Repository|Configuration|RestController)\b') |
                         ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
            $di.Add([ordered]@{ file = $rel; kind = "@$a"; service = $primary; impl = $null })
        }
    } else {
        foreach ($m in [regex]::Matches($txt,
            '\.(?:Try)?Add(Scoped|Singleton|Transient|HostedService)\s*<\s*([\w.]+(?:<[^>]*>)?)\s*(?:,\s*([\w.]+(?:<[^>]*>)?)\s*)?>')) {
            $di.Add([ordered]@{
                file    = $rel
                kind    = "Add$($m.Groups[1].Value)"
                service = (Get-ShortName $m.Groups[2].Value)
                impl    = if ($m.Groups[3].Success) { Get-ShortName $m.Groups[3].Value } else { $null }
            })
        }
    }

    if ($types.Count -or $methods.Count) {
        $entry = [ordered]@{ file = $rel }
        if ($ns)           { $entry.ns    = $ns }
        $entry.types = $types
        if ($bases.Count)  { $entry.bases = $bases }
        $entry.methods = @($methods | Select-Object -First 40)
        $sym.Value = $entry
    }
}

# 逐檔沿用：大小＋修改時間沒變的檔，沿用上一次掃出來的 symbols 與 DI 註冊；只重讀新增與變動的檔，刪掉的自然不在。
# 快取存的是**每個檔各自**的結果（DI 不截斷），所以組出來的 symbols／di-registrations 跟全量重建逐位元相同：
# 順序照走訪順序，DI 一樣在最後才截到 300。上一份索引不能用（第一次、schema 換了）或 -Force 時不沿用。
$symCache = @{}
if ($prev -and -not $Force -and (Test-Path $symCachePath)) {
    try {
        $c = Get-Content $symCachePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ($c -and $c['index-schema'] -eq $IndexSchema -and $c['files']) { $symCache = $c['files'] }
    } catch { $symCache = @{} }
}
$newCache = [ordered]@{}

$symFiles = $srcFiles | Select-Object -First $MaxSymbolFiles
foreach ($f in $symFiles) {
    $rel = ConvertTo-RelPath $f.FullName
    $fp  = "$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
    $hit = $symCache[$rel]
    if ($hit -and $hit['fp'] -eq $fp) {
        $fileSym = $hit['sym']
        $fileDi  = @($hit['di'] | Where-Object { $_ })
    } else {
        $symbolsRescanned++
        $ref = [ref]$null
        $list = [Collections.Generic.List[object]]::new()
        Get-FileSymbols $f $rel $ref $list
        $fileSym = $ref.Value
        $fileDi  = @($list)
    }
    $newCache[$rel] = [ordered]@{ fp = $fp; sym = $fileSym; di = @($fileDi) }
    if ($fileSym) { $symbols += [pscustomobject]$fileSym }
    foreach ($d in $fileDi) { $diRegistrations += [pscustomobject]$d }
}

$diRegistrations = @($diRegistrations | Select-Object -First 300)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
[ordered]@{ 'index-schema' = $IndexSchema; files = $newCache } | ConvertTo-Json -Depth 10 -Compress | Set-Content $symCachePath -Encoding UTF8

}   # end: symbols 重掃

# ---------- 組裝 ----------
$index = [pscustomobject]@{
    meta = [pscustomobject]@{
        'generated-at'      = (Get-Date).ToUniversalTime().ToString('o')
        'index-schema'      = $IndexSchema
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
        'symbols-reused'    = [bool]($prev -and ('symbols' -notin $stale))
    }
    solutions       = @(@($slnFiles) + @($poms) + @($gradles) | ForEach-Object { ConvertTo-RelPath $_.FullName })
    projects        = $projects
    'test-toolchain'= $testToolchain
    commands        = $commands
    entrypoints     = $entrypoints
    'config-keys'   = @($configKeys | Select-Object -First 400)
    'di-registrations' = $diRegistrations
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
    summary  = "$language/$buildTool, $($projects.Count) projects, $($srcFiles.Count) source files, $($symbols.Count) symbol entries, $($diRegistrations.Count) DI registrations"
    counts   = [pscustomobject]@{ projects=$projects.Count; files=$srcFiles.Count; entrypoints=$entrypoints.Count; di=$diRegistrations.Count }
    open_questions = 0
    # 下面這幾欄是 implementer／reviewer 要的：build／test 指令、測試框架、step definition 與 .feature 的落點。
    # index.json 一個 2,000 檔的專案就近 1 MB，模型讀不下 —— 拿到的是截斷的輸出，或花好幾個回合 grep 它。
    meta     = [pscustomobject]@{
        'index-schema' = $IndexSchema; 'git-sha' = $gitSha; 'language' = $language; 'build-tool' = $buildTool
        'file-count' = $srcFiles.Count; 'project-count' = $projects.Count; 'symbol-truncated' = ($srcFiles.Count -gt $MaxSymbolFiles)
    }
    commands         = $commands
    'test-toolchain' = $testToolchain
    solutions        = @(@($slnFiles) + @($poms) + @($gradles) | ForEach-Object { ConvertTo-RelPath $_.FullName })
} | ConvertTo-Json -Depth 5 | Set-Content $digestPath -Encoding UTF8

[pscustomobject]@{
    status = 'refreshed'; index_path = $indexPath; digest_path = $digestPath
    stale_scopes = $stale; invalidation_mode = $invalidationMode
    index_bytes = $json.Length; index_schema = $IndexSchema
    symbols_reused = [bool]($prev -and ('symbols' -notin $stale)); symbols_rescanned = $symbolsRescanned
    file_count = $srcFiles.Count; project_count = $projects.Count; language = $language; build_tool = $buildTool
    di_count = $diRegistrations.Count
} | ConvertTo-Json -Depth 4 -Compress
exit 0
