# test-repo-index.ps1
# repo-index 的 `commands` 與 `test-toolchain` 是 ④ 唯一的 build／test 指令來源（implementer.toml「一律從那裡取」），
# 所以這裡錯一個字，下游就整段照錯的跑，而且沒有任何地方會標出來：
#
#   寫死 mvn／gradle            → 只有 wrapper 的機器上，④ 的測試指令跑不起來
#   加了 wrapper，索引卻不失效   → 專案檔沒動的 repo 永遠沿用舊指令
#   bdd-fallback 寫死一個        → NUnit／MSTest／JUnit 4／TestNG 的專案被建議加第二套測試框架
#   schema 沒 +1                → 上面幾條修好了，舊索引照樣被沿用
#
# build-check 的退化偵測（索引不在時）用同一套 wrapper 判定，所以也在這裡、用同一組 fixture 驗。

$RiScript = (Resolve-Path '.codex/scripts/repo-index.ps1').Path
$BcScript = (Resolve-Path '.codex/scripts/build-check.ps1').Path
$RiRoot   = Join-Path ([IO.Path]::GetTempPath()) 'codex-repo-index-tests'
$RiUtf8   = [Text.UTF8Encoding]::new($false)

$MvnWrapper    = @('mvnw', 'mvnw.cmd', '.mvn/wrapper/maven-wrapper.properties')
$GradleWrapper = @('gradlew', 'gradlew.bat', 'gradle/wrapper/gradle-wrapper.properties')

function New-RiFile([string]$path, [string]$content = '') {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $content, $RiUtf8)
}

# 最小的專案：建置檔 ＋ 一個原始碼檔（語言判定靠它）＋ 要放的 wrapper 檔（相對專案根）。
function New-RiProject {
    param([string]$Name, [ValidateSet('maven', 'gradle', 'dotnet')] [string]$Kind, [string[]]$Packages = @(), [string[]]$Wrapper = @())
    $root = Join-Path $RiRoot $Name
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    switch ($Kind) {
        'maven' {
            $deps = ($Packages | ForEach-Object { "<dependency><groupId>g</groupId><artifactId>$_</artifactId></dependency>" }) -join ''
            New-RiFile (Join-Path $root 'pom.xml') "<project><artifactId>app</artifactId><dependencies>$deps</dependencies></project>"
            New-RiFile (Join-Path $root 'src/main/java/App.java') 'public class App { }'
        }
        'gradle' {
            $deps = ($Packages | ForEach-Object { "    testImplementation 'g:$($_):1.0'" }) -join "`n"
            New-RiFile (Join-Path $root 'build.gradle') "dependencies {`n$deps`n}"
            New-RiFile (Join-Path $root 'src/main/java/App.java') 'public class App { }'
        }
        'dotnet' {
            $refs = ($Packages | ForEach-Object { "<PackageReference Include=`"$_`" Version=`"1.0.0`" />" }) -join ''
            New-RiFile (Join-Path $root 'App.Tests/App.Tests.csproj') "<Project Sdk=`"Microsoft.NET.Sdk`"><ItemGroup>$refs</ItemGroup></Project>"
            New-RiFile (Join-Path $root 'App.Tests/AppTests.cs') 'public class AppTests { }'
        }
    }
    foreach ($w in $Wrapper) { New-RiFile (Join-Path $root $w) 'wrapper' }
    return $root
}

# 索引寫在專案旁邊（不寫進專案裡），免得它自己變成下一次掃描的輸入。
function Invoke-RepoIndex([string]$root) {
    $r = Invoke-Script $RiScript -Params @{ Root = $root; OutDir = "$root.out" }
    if ($r.exit -ne 0) { throw "repo-index exit $($r.exit)：$($r.stderr)" }
    return (Get-Content "$root.out/index.json" -Raw | ConvertFrom-Json)
}

# Windows 上 `./mvnw` 解析到的是 mvnw.cmd（pwsh 7 與 5.1 實測）。假的那一支只記下被叫的參數，exit code 由測試決定。
function New-RiWrapperCmd([string]$root, [string]$name, [int]$exitCode = 0) {
    [IO.File]::WriteAllText((Join-Path $root $name), "@echo %* >> `"%~dp0$name.calls`"`r`n@exit /b $exitCode`r`n", [Text.Encoding]::ASCII)
    return (Join-Path $root "$name.calls")
}

# PATH 上只留執行中這一支的目錄與系統目錄（假 wrapper 是 .cmd，要 cmd.exe）—— 這台機器裝了 mvn／gradle 的話，
# 「沒有 wrapper 就放行」那條會測到真的 build。
# 執行中這一支的目錄一定要留：pwsh 以 .NET global tool 安裝時，PATH 上的 pwsh 是個 shim，
# 要從**子行程的** PATH 找 dotnet 才起得來，而那時 [Environment]::ProcessPath 正好是 dotnet.exe（一般安裝則是 pwsh.exe）。
function Get-RiIsolatedPath {
    return (@((Split-Path ([Environment]::ProcessPath) -Parent), [Environment]::SystemDirectory) | Where-Object { $_ }) -join ';'
}

function Invoke-BuildCheck([string]$root, [string]$javaFile = 'src/main/java/App.java') {
    $payload = New-CodexHookPayload -Command (New-CodexPatch -Update $javaFile)
    Push-Location $root
    try { return (Invoke-Script $BcScript -Stdin $payload -Params @{ DebounceSeconds = 0 } -Env @{ PATH = (Get-RiIsolatedPath) }) }
    finally { Pop-Location }
}

Describe-Suite 'repo-index / commands 用專案自帶的 wrapper' {

    It-Should 'Maven 有 wrapper → 四個指令都用 ./mvnw' {
        $root = New-RiProject 'mvn-wrapper' maven -Wrapper $MvnWrapper
        try {
            $c = (Invoke-RepoIndex $root).commands
            Assert-Equal './mvnw -q -B compile' $c.build
            Assert-Equal './mvnw -q -B test' $c.test
            Assert-Match '^\./mvnw ' $c.'test-filter'
            Assert-Match '^\./mvnw ' $c.acceptance
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Maven 沒有 wrapper → 照舊用全域 mvn' {
        $root = New-RiProject 'mvn-plain' maven
        try {
            Assert-Equal 'mvn -q -B compile' (Invoke-RepoIndex $root).commands.build
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '只有 wrapper 腳本、沒有設定檔 → 不算 wrapper（那支腳本跑不起來）' {
        $root = New-RiProject 'mvn-script-only' maven -Wrapper @('mvnw.cmd')
        try {
            Assert-Equal 'mvn -q -B compile' (Invoke-RepoIndex $root).commands.build
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Gradle 只有 Windows 那一支 gradlew.bat 也算' {
        $root = New-RiProject 'gradle-bat' gradle -Wrapper @('gradlew.bat', 'gradle/wrapper/gradle-wrapper.properties')
        try {
            $c = (Invoke-RepoIndex $root).commands
            Assert-Equal './gradlew -q compileJava' $c.build
            Assert-Equal './gradlew -q test' $c.test
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '加上 wrapper 之後索引要失效，commands 跟著換' {
        # wrapper 不是專案檔。沒有算進 structure hash 的話，第二次會回「current」，commands 永遠停在 mvn。
        $root = New-RiProject 'mvn-add-wrapper' maven
        try {
            Assert-Equal 'mvn -q -B compile' (Invoke-RepoIndex $root).commands.build
            foreach ($w in $MvnWrapper) { New-RiFile (Join-Path $root $w) 'wrapper' }
            Assert-Equal './mvnw -q -B compile' (Invoke-RepoIndex $root).commands.build '加了 wrapper，索引卻沒有失效'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'repo-index / bdd-fallback 跟著測試框架走' {

    $cases = @(
        @{ kind = 'dotnet'; pkgs = @('xunit', 'xunit.runner.visualstudio'); want = 'Reqnroll.xUnit' }
        @{ kind = 'dotnet'; pkgs = @('xunit.v3');                          want = 'Reqnroll.xunit.v3' }
        @{ kind = 'dotnet'; pkgs = @('NUnit', 'NUnit3TestAdapter');        want = 'Reqnroll.NUnit' }
        @{ kind = 'dotnet'; pkgs = @('MSTest.TestFramework');              want = 'Reqnroll.MSTest' }
        @{ kind = 'maven';  pkgs = @('junit-jupiter');                     want = 'cucumber-java + cucumber-junit-platform-engine + junit-platform-suite' }
        @{ kind = 'maven';  pkgs = @('junit');                             want = 'cucumber-java + cucumber-junit' }
        @{ kind = 'gradle'; pkgs = @('testng');                            want = 'cucumber-java + cucumber-testng' }
    )
    foreach ($case in $cases) {
        It-Should "$($case.kind) 用 $($case.pkgs[0]) → 建議 $($case.want)" {
            $root = New-RiProject "bdd-$($case.pkgs[0])" $case.kind -Packages $case.pkgs
            try {
                Assert-Equal $case.want (Invoke-RepoIndex $root).'test-toolchain'.'bdd-fallback'
            } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should '已經有 BDD 框架 → 不給 bdd-fallback（不引入第二套）' {
        $root = New-RiProject 'bdd-present' dotnet -Packages @('NUnit', 'Reqnroll.NUnit')
        try {
            $tt = (Invoke-RepoIndex $root).'test-toolchain'
            Assert-Equal 'Reqnroll' $tt.bdd
            Assert-True (-not $tt.PSObject.Properties['bdd-fallback']) "已有 Reqnroll 卻還建議 $($tt.'bdd-fallback')"
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '上一版（schema 2）留下的索引不得沿用' {
        # 專案檔沒動、hash 全中的舊索引：只有 schema 不同能讓它重建。schema 沒 +1，這裡會一直是舊的建議。
        $root = New-RiProject 'old-schema' dotnet -Packages @('NUnit')
        try {
            $null = Invoke-RepoIndex $root
            $path = "$root.out/index.json"
            $old = Get-Content $path -Raw | ConvertFrom-Json
            $old.meta.'index-schema' = 2
            $old.'test-toolchain'.'bdd-fallback' = 'Reqnroll.xUnit'
            $old | ConvertTo-Json -Depth 8 | Set-Content $path -Encoding UTF8
            Assert-Equal 'Reqnroll.NUnit' (Invoke-RepoIndex $root).'test-toolchain'.'bdd-fallback' '舊索引被沿用了'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'build-check / wrapper（索引不在時的退化偵測，與 repo-index 同一套判定）' {

    It-Should '只有 Maven wrapper、PATH 上沒有 mvn → 用 wrapper build' {
        $root = New-RiProject 'bc-mvn' maven -Wrapper @('mvnw', '.mvn/wrapper/maven-wrapper.properties')
        $calls = New-RiWrapperCmd $root 'mvnw.cmd'
        try {
            $r = Invoke-BuildCheck $root
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-True (Test-Path $calls) 'wrapper 沒被叫 —— build-check 又靜默放行了'
            Assert-Match '-q -B compile' (Get-Content $calls -Raw)
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Gradle wrapper 同理' {
        $root = New-RiProject 'bc-gradle' gradle -Wrapper @('gradlew', 'gradle/wrapper/gradle-wrapper.properties')
        $calls = New-RiWrapperCmd $root 'gradlew.bat'
        try {
            $r = Invoke-BuildCheck $root
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-True (Test-Path $calls) 'wrapper 沒被叫'
            Assert-Match '-q compileJava' (Get-Content $calls -Raw)
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'wrapper 的 build 失敗會擋下（不是靜默放行）' {
        $root = New-RiProject 'bc-mvn-red' maven -Wrapper @('.mvn/wrapper/maven-wrapper.properties')
        $null = New-RiWrapperCmd $root 'mvnw.cmd' 1
        try {
            $r = Invoke-BuildCheck $root
            Assert-Equal 2 $r.exit '改壞的 production code 沒被擋'
            Assert-Match '\./mvnw' $r.stderr
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '索引給的 ./mvnw 照樣跑得起來' {
        # 索引路徑先 Get-Command 再 `&` —— `./mvnw` 兩步都要解析到 mvnw.cmd。
        $root = New-RiProject 'bc-index' maven -Wrapper @('.mvn/wrapper/maven-wrapper.properties')
        $calls = New-RiWrapperCmd $root 'mvnw.cmd'
        New-RiFile (Join-Path $root 'bdd-docs/.cache/index.json') '{ "meta": { "language": "java" }, "commands": { "build": "./mvnw -q -B compile" } }'
        try {
            $r = Invoke-BuildCheck $root
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-True (Test-Path $calls) '索引的 ./mvnw 沒有被執行'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有 wrapper、PATH 上也沒有 mvn → 照舊放行（工具鏈不可用時不阻斷）' {
        $root = New-RiProject 'bc-none' maven
        try {
            $r = Invoke-BuildCheck $root
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
