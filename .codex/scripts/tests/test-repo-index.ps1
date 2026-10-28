# test-repo-index.ps1
# repo-index 的 `commands` 與 `test-toolchain` 是 ④ 唯一的 build／test 指令來源（implementer.toml「一律從那裡取」），
# 所以這裡錯一個字，下游就整段照錯的跑，而且沒有任何地方會標出來：
#
#   寫死 mvn／gradle            → 只有 wrapper 的機器上，④ 的測試指令跑不起來
#   加了 wrapper，索引卻不失效   → 專案檔沒動的 repo 永遠沿用舊指令
#   bdd-fallback 寫死一個        → NUnit／MSTest／JUnit 4／TestNG 的專案被建議加第二套測試框架
#   schema 沒 +1                → 上面幾條修好了，舊索引照樣被沿用
#
# 索引同時是 sa-analyst「不開檔就採信」的答案（擴充點、實作有沒有掛上去），所以註解掉的東西不能進來：
#
#   //services.AddScoped<IFoo, OldFoo>()   → 停用的舊實作被當成已註冊的擴充點
#   /* 整個舊類別 */、#if false 裡的方法  → 現況裡多出不存在的類別與方法
#   註解掉的 <PackageReference Reqnroll>  → 說專案已經有 BDD 框架，④ 就不會去加
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

    It-Should 'dotnet 的測試指令不帶 --no-build（會測到改之前的 DLL）' {
        # build-check 綠燈後 90 秒內不 build；帶 --no-build 的 dotnet test 在那段時間裡測的是舊的 DLL —
        # 紅綠判斷錯，implementer 在已經修好的地方繼續修，或帶著假綠燈交出去。
        $root = New-RiProject 'dotnet-nobuild' dotnet -Packages @('NUnit')
        try {
            $c = (Invoke-RepoIndex $root).commands
            foreach ($k in @('test', 'test-filter', 'acceptance')) {
                Assert-Match '^dotnet test\b' $c.$k
                Assert-True ($c.$k -notmatch '--no-build') "commands.$k 是 $($c.$k)"
            }
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '上一版（schema 4）留下的索引不得沿用 —— 它的 dotnet 測試指令帶 --no-build' {
        $root = New-RiProject 'dotnet-schema4' dotnet -Packages @('NUnit')
        try {
            $null = Invoke-RepoIndex $root
            $path = "$root.out/index.json"
            $old = Get-Content $path -Raw | ConvertFrom-Json
            $old.meta.'index-schema' = 4
            $old.commands.test = 'dotnet test --no-build'
            $old | ConvertTo-Json -Depth 8 | Set-Content $path -Encoding UTF8
            Assert-Equal 'dotnet test' (Invoke-RepoIndex $root).commands.test '舊索引被沿用了'
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

Describe-Suite 'repo-index / 註解掉的東西不進索引' {

    It-Should 'C#：註解掉的 DI 註冊不算 —— 行首的、行尾的、區塊裡的都一樣' {
        # DI 那條樣式沒有錨在行首，以前 // 開頭的舊註冊會被記成「這個實作有掛上去」。
        $root = New-RiProject 'cmt-di' dotnet
        New-RiFile (Join-Path $root 'App.Tests/Startup.cs') @'
public class Startup
{
    public void ConfigureServices(IServiceCollection services)
    {
        //services.AddScoped<IOrderService, LegacyOrderService>();
        services.AddScoped<IOrderService, OrderServiceV2>();
        services.AddSingleton<IClock, SystemClock>(); // services.AddSingleton<IClock, FakeClock>();
        /* services.AddTransient<IMailer, OldMailer>(); */
    }
}
'@
        try {
            $di = @((Invoke-RepoIndex $root).'di-registrations' | ForEach-Object { "$($_.service)=$($_.impl)" })
            foreach ($live in 'IOrderService=OrderServiceV2', 'IClock=SystemClock') {
                Assert-True ($live -in $di) "現役的註冊 $live 不見了：$($di -join '、')"
            }
            foreach ($dead in 'IOrderService=LegacyOrderService', 'IClock=FakeClock', 'IMailer=OldMailer') {
                Assert-True ($dead -notin $di) "註解掉的 $dead 被當成已註冊"
            }
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'C#：/* */ 包起來的類別、#if false 裡的方法、基底清單後面的行尾註解都不進索引' {
        $root = New-RiProject 'cmt-symbols' dotnet
        New-RiFile (Join-Path $root 'App.Tests/Orders.cs') @'
namespace Legacy.Orders
{
/*
    public class LegacyOrderService : IOrderService
    {
        public bool CancelShipped(int id) { return true; }
    }
*/
    public class OrderServiceV2 : IOrderService // , IOldOrderService
    {
        public bool Cancel(int id) { return false; }
#if false
        public decimal RefundShipping(int id) { return 0m; }
#endif
    }
}
'@
        try {
            $s = (Invoke-RepoIndex $root).symbols | Where-Object { $_.file -eq 'App.Tests/Orders.cs' }
            Assert-Equal 'class OrderServiceV2' (@($s.types) -join ';') '註解掉的類別進了 types'
            Assert-Equal 'OrderServiceV2 : IOrderService' (@($s.bases) -join ';') 'bases 收了註解掉的類別，或行尾註解裡的基底'
            Assert-Equal 'Cancel' (@($s.methods) -join ',') 'methods 收了註解或 #if false 裡的方法'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Java：同檔前面被註解掉的舊 @Service 類別，不會搶走現役類別的 DI 註冊' {
        # DI 的歸屬取檔內第一個 public 型別。舊類別沒剝掉時排第一 —— 註冊記到死碼名下，現役的反而像沒註冊。
        $root = New-RiProject 'cmt-java' maven
        New-RiFile (Join-Path $root 'src/main/java/OrderService.java') @'
/*
@Service
public class OldOrderService implements OrderPort {
    public boolean cancelShipped(long id) { return true; }
}
*/
//@Component
@Service
public class OrderService implements OrderPort {
    public boolean cancel(long id) { return false; }
}
'@
        try {
            $i = Invoke-RepoIndex $root
            $di = @($i.'di-registrations' | Where-Object { $_.file -eq 'src/main/java/OrderService.java' })
            Assert-Equal '@Service OrderService' (@($di | ForEach-Object { "$($_.kind) $($_.service)" }) -join '、') 'DI 記錯了對象，或收了註解掉的註解'
            Assert-Equal 'class OrderService' (@(($i.symbols | Where-Object { $_.file -eq 'src/main/java/OrderService.java' }).types) -join ';')
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'csproj 裡註解掉的 PackageReference 不算 —— 不然會說專案已經有 BDD 框架' {
        # test-toolchain.bdd 有值，④ 就不會去加 Reqnroll；而那個套件其實沒被引用，要到第一次跑 .feature 才發現。
        $root = New-RiProject 'cmt-csproj' dotnet
        New-RiFile (Join-Path $root 'App.Tests/App.Tests.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="NUnit" Version="4.0.0" />
    <!-- 升 .NET 8 時先拿掉
    <PackageReference Include="Reqnroll.NUnit" Version="2.0.0" />
    -->
  </ItemGroup>
</Project>
'@
        try {
            $tt = (Invoke-RepoIndex $root).'test-toolchain'
            Assert-True (-not $tt.bdd) "註解掉的 Reqnroll 被當成已引用：bdd=$($tt.bdd)"
            Assert-Equal 'Reqnroll.NUnit' $tt.'bdd-fallback'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '字串裡長得像註解的東西，不會吃掉後面的宣告' {
        # 剝註解若不認字串，"image/*" 會被當成 /* 的開頭，後面整段真的程式碼跟著消失 —— 而少掉的東西不會出現在任何輸出裡。
        $root = New-RiProject 'cmt-strings' dotnet
        New-RiFile (Join-Path $root 'App.Tests/Media.cs') @'
public class Media
{
    public const string Images = "image/*";
    public string Url = "http://example.com"; public string Dir = @"C:\temp\";
    public void AfterStrings() { }
}
public class Registration
{
    public void Register(IServiceCollection services) { services.AddScoped<IMedia, MediaV2>(); }
}
'@
        try {
            $i = Invoke-RepoIndex $root
            $s = $i.symbols | Where-Object { $_.file -eq 'App.Tests/Media.cs' }
            Assert-True ('AfterStrings' -in @($s.methods)) "字串之後的方法不見了：$(@($s.methods) -join ',')"
            Assert-True ('class Registration' -in @($s.types)) "字串之後的類別不見了：$(@($s.types) -join ';')"
            Assert-Equal 1 @($i.'di-registrations' | Where-Object { $_.impl -eq 'MediaV2' }).Count '字串之後的 DI 註冊不見了'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '上一版（schema 3）留下的索引不得沿用 —— 那一版把註解掉的 DI 當成現役' {
        # 原始碼沒動、hash 全中的舊索引：只有 schema 不同能讓它重建。schema 沒 +1，註解掉的註冊會一直留在索引裡。
        $root = New-RiProject 'cmt-schema' dotnet
        New-RiFile (Join-Path $root 'App.Tests/Startup.cs') @'
public class Startup
{
    public void ConfigureServices(IServiceCollection services)
    {
        //services.AddScoped<IOrderService, LegacyOrderService>();
        services.AddScoped<IOrderService, OrderServiceV2>();
    }
}
'@
        try {
            $null = Invoke-RepoIndex $root
            $path = "$root.out/index.json"
            $old = Get-Content $path -Raw | ConvertFrom-Json
            $old.meta.'index-schema' = 3
            $old.'di-registrations' = @($old.'di-registrations') +
                [pscustomobject]@{ file = 'App.Tests/Startup.cs'; kind = 'AddScoped'; service = 'IOrderService'; impl = 'LegacyOrderService' }
            $old | ConvertTo-Json -Depth 8 | Set-Content $path -Encoding UTF8
            $impls = @((Invoke-RepoIndex $root).'di-registrations' | ForEach-Object { $_.impl })
            Assert-True ('LegacyOrderService' -notin $impls) '舊索引被沿用了'
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

# ---- v4.13.0：目錄樹只走一次、symbols 逐檔增量、digest 帶指令、-StatusOnly 帶地圖驗證 ----

function Invoke-RiStatus([string]$root) {
    $r = Invoke-Script $RiScript -Params @{ Root = $root; OutDir = "$root.out"; StatusOnly = $true }
    if ($r.exit -ne 0) { throw "repo-index -StatusOnly exit $($r.exit)：$($r.stderr)" }
    return ($r.stdout | ConvertFrom-Json)
}

function Invoke-RiGit([string]$root, [string[]]$gitArgs) {
    $null = & git -C $root -c user.email=t@t -c user.name=t -c commit.gpgsign=false @gitArgs 2>&1
}

Describe-Suite 'repo-index / 目錄樹只走一次（跟以前的 Get-ChildItem -Recurse 同一個集合）' {

    It-Should '排除的目錄不分大小寫、只看目錄名；名叫 build 的檔、buildtools/ 照樣算；隱藏目錄不算' {
        $root = New-RiProject 'walk' dotnet
        New-RiFile (Join-Path $root 'App/Bin/Debug/Gen.cs') 'public class FromBin { }'
        New-RiFile (Join-Path $root 'App/OBJ/x/Gen2.cs') 'public class FromObj { }'
        New-RiFile (Join-Path $root 'App/buildtools/Tool.cs') 'public class BuildTool { }'
        New-RiFile (Join-Path $root 'App/build') 'not a directory'
        New-RiFile (Join-Path $root 'hidden/Secret.cs') 'public class HiddenOne { }'
        $h = Get-Item (Join-Path $root 'hidden'); $h.Attributes = $h.Attributes -bor [IO.FileAttributes]::Hidden
        try {
            $types = @((Invoke-RepoIndex $root).symbols | ForEach-Object { $_.types } | ForEach-Object { $_ })
            Assert-True ('class BuildTool' -in $types) "buildtools/ 被當成 build/ 排除了：$($types -join '、')"
            foreach ($gone in 'class FromBin', 'class FromObj', 'class HiddenOne') { Assert-True ($gone -notin $types) "$gone 不該進索引" }
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '.slnx（.NET 9 起 dotnet new sln 的預設）也算 solution' {
        $root = New-RiProject 'slnx' dotnet
        New-RiFile (Join-Path $root 'App.slnx') '<Solution />'
        try {
            Assert-True ('App.slnx' -in @((Invoke-RepoIndex $root).solutions)) '.slnx 沒被認成 solution'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'repo-index / symbols 只重掃變動的檔' {

    It-Should '改一個檔後刷新：只重讀那一個，symbols 與 DI 跟全量重建逐位元相同' {
        # 以前任何一個原始碼檔改了就整包重掃 —— 上一個需求一定改過程式，所以第二個需求以後每次都是全量重建。
        $root = New-RiProject 'inc' dotnet
        foreach ($i in 1..6) { New-RiFile (Join-Path $root "App.Tests/S$i.cs") "public interface IS$i { }`npublic class S$i : IS$i`n{`n    public void M$i() { }`n}" }
        New-RiFile (Join-Path $root 'App.Tests/Startup.cs') 'public class Startup { public void C(IServiceCollection s) { s.AddScoped<IS1, S1>(); s.AddScoped<IS2, S2>(); } }'
        try {
            $null = Invoke-RepoIndex $root
            New-RiFile (Join-Path $root 'App.Tests/S3.cs') "public interface IS3 { }`npublic class S3 : IS3`n{`n    public void M3() { }`n    public void Extra() { }`n}"
            Remove-Item (Join-Path $root 'App.Tests/S5.cs')
            $r = Invoke-Script $RiScript -Params @{ Root = $root; OutDir = "$root.out" }
            $sum = $r.stdout | ConvertFrom-Json
            Assert-Equal 1 $sum.symbols_rescanned "沒變的檔也被重讀了：$($r.stdout)"
            $inc = Get-Content "$root.out/index.json" -Raw | ConvertFrom-Json
            $r = Invoke-Script $RiScript -Params @{ Root = $root; OutDir = "$root.out"; Force = $true }
            Assert-True (($r.stdout | ConvertFrom-Json).symbols_rescanned -ge 7) '-Force 應該全部重掃'
            $full = Get-Content "$root.out/index.json" -Raw | ConvertFrom-Json
            Assert-Equal (ConvertTo-Json $full.symbols -Depth 6 -Compress) (ConvertTo-Json $inc.symbols -Depth 6 -Compress) '增量的 symbols 跟全量重建不一樣'
            Assert-Equal (ConvertTo-Json $full.'di-registrations' -Depth 6 -Compress) (ConvertTo-Json $inc.'di-registrations' -Depth 6 -Compress) '增量的 DI 跟全量重建不一樣'
            Assert-True ('Extra' -in @(($inc.symbols | Where-Object { $_.file -eq 'App.Tests/S3.cs' }).methods)) '改過的檔沒被重讀'
            Assert-True (-not @($inc.symbols | Where-Object { $_.file -eq 'App.Tests/S5.cs' }).Count) '刪掉的檔還留在索引裡'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'repo-index / digest 帶 build／test 指令（implementer、reviewer 讀這一份，不讀近 1 MB 的 index.json）' {

    It-Should 'index-digest.json 有 commands 與 test-toolchain' {
        $root = New-RiProject 'digest' dotnet -Packages @('NUnit')
        try {
            $null = Invoke-RepoIndex $root
            $d = Get-Content "$root.out/index-digest.json" -Raw | ConvertFrom-Json
            Assert-Equal 'dotnet test' $d.commands.test
            Assert-Equal '**/*Steps.cs' $d.commands.'step-def-glob'
            Assert-Equal 'NUnit' $d.'test-toolchain'.test
            Assert-Equal 'Reqnroll.NUnit' $d.'test-toolchain'.'bdd-fallback'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'repo-index -StatusOnly / project-map 逐節失效（以前是 sa-analyst 自己跑十幾次 git）' {

    # 一個 git repo、兩節地圖：「訂單」看 src/Orders/，「報表」看 src/Reports/。
    function New-MapRepo {
        $root = New-RiProject 'map' dotnet
        New-RiFile (Join-Path $root 'src/Orders/OrderService.cs') 'public class OrderService { }'
        New-RiFile (Join-Path $root 'src/Reports/ReportService.cs') 'public class ReportService { }'
        Invoke-RiGit $root @('init', '-q'); Invoke-RiGit $root @('add', '-A'); Invoke-RiGit $root @('commit', '-q', '-m', 'base')
        $sha = (& git -C $root rev-parse HEAD).Trim()
        New-RiFile (Join-Path $root 'bdd-docs/project-map.md') "<!-- git-sha: $sha -->`n# Project map`n`n## 訂單`n訂單由 OrderService 處理。`n來源：``src/Orders/```n`n## 報表`n報表在 ReportService。`n來源：``src/Reports/ReportService.cs```n"
        return $root
    }

    It-Should '兩節都沒動 → 都採信；地圖本身沒有被判待驗證' {
        $root = New-MapRepo
        try {
            $m = (Invoke-RiStatus $root).project_map
            Assert-True $m.exists
            Assert-True (-not $m.whole_map_unverified) "reason: $($m.reason)"
            Assert-Equal 2 @($m.sections).Count
            Assert-True (-not @($m.sections | Where-Object stale).Count) "沒動的節被判過期：$(ConvertTo-Json $m.sections -Compress)"
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '來源檔改了但還沒 commit → 那一節過期（這套流程不 commit，這才是常態）' {
        $root = New-MapRepo
        New-RiFile (Join-Path $root 'src/Orders/OrderService.cs') 'public class OrderService { public void Cancel() { } }'
        try {
            $s = @((Invoke-RiStatus $root).project_map.sections)
            Assert-True ($s | Where-Object title -eq '訂單').stale '沒 commit 的改動沒被看見 —— 只跑了 git diff {sha}..HEAD'
            Assert-True (-not ($s | Where-Object title -eq '報表').stale) '沒動的那一節也被判過期'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '來源目錄多了一個沒追蹤的新檔 → 那一節過期' {
        $root = New-MapRepo
        New-RiFile (Join-Path $root 'src/Orders/Refund.cs') 'public class Refund { }'
        try {
            Assert-True (@((Invoke-RiStatus $root).project_map.sections) | Where-Object title -eq '訂單').stale '未追蹤的新檔沒被看見'
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '來源檔改了而且 commit 了 → 那一節過期' {
        $root = New-MapRepo
        New-RiFile (Join-Path $root 'src/Reports/ReportService.cs') 'public class ReportService { public void Daily() { } }'
        Invoke-RiGit $root @('commit', '-q', '-am', 'change report')
        try {
            $s = @((Invoke-RiStatus $root).project_map.sections)
            Assert-True ($s | Where-Object title -eq '報表').stale '已 commit 的改動沒被看見'
            Assert-True (-not ($s | Where-Object title -eq '訂單').stale)
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '地圖沒有 git-sha → 整份待驗證（只當線索）' {
        $root = New-MapRepo
        $p = Join-Path $root 'bdd-docs/project-map.md'
        [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '<!-- git-sha: [0-9a-f]+ -->', ''), $RiUtf8)
        try {
            $m = (Invoke-RiStatus $root).project_map
            Assert-True $m.whole_map_unverified
            Assert-Equal 'no-git-sha' $m.reason
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '來源在 repo 裡找不到（只寫檔名、大小寫不符、對不到檔的萬用字元）→ 那一節過期，missing 列出它' {
        # git 對不存在的 path 兩行都回空、exit 0 —— 以前這種節永遠是「沒變」，編出來的來源讓它一直被當成證據採信。
        $root = New-MapRepo
        $sha = (& git -C $root rev-parse HEAD).Trim()
        New-RiFile (Join-Path $root 'bdd-docs/project-map.md') ("<!-- git-sha: $sha -->`n# Project map`n`n" +
            "## 訂單`n來源：``OrderService.cs``、``src/Orders/```n`n" +
            "## 報表`n來源：``src/reports/ReportService.cs```n`n" +
            "## 測試骨架`n來源：``src/Nope/*.cs```n`n" +
            "## 分層`n來源：``src/*/*Service.cs``、``src/Reports/```n")
        try {
            $s = @((Invoke-RiStatus $root).project_map.sections)
            $o = $s | Where-Object title -eq '訂單'
            Assert-True $o.stale '只寫檔名的來源沒被判過期'
            Assert-Equal 'OrderService.cs' (@($o.missing) -join '|')
            $r = $s | Where-Object title -eq '報表'
            Assert-True $r.stale '大小寫不符沒被判過期（git 的 pathspec 分大小寫，status 永遠是空的）'
            Assert-Equal 'src/reports/ReportService.cs' (@($r.missing) -join '|')
            Assert-True ($s | Where-Object title -eq '測試骨架').stale '對不到任何檔的萬用字元沒被判過期'
            $l = $s | Where-Object title -eq '分層'
            Assert-True (-not $l.stale) "對得到的萬用字元與目錄被判過期：$(ConvertTo-Json $l -Compress)"
            Assert-Equal 0 @($l.missing).Count
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '跨 feature 的 DB 證據與 legacy-schema 一起列出（含節標題與 captured 日期）' {
        $root = New-MapRepo
        New-RiFile (Join-Path $root 'bdd-docs/old-feature/evidence/db-orders.md') "# DB`n`n## 2026-09-01 —— dbo.Orders`n欄位…`n`n## 2026-09-03 —— dbo.OrderItems`n"
        New-RiFile (Join-Path $root 'bdd-docs/artifacts/legacy-schema/usp_Cancel.sql') "-- captured: 2026-08-20 | object: dbo.usp_Cancel`nCREATE PROCEDURE …"
        try {
            $s = Invoke-RiStatus $root
            $ev = @($s.evidence)[0]
            Assert-Equal 'bdd-docs/old-feature/evidence/db-orders.md' $ev.path
            Assert-Equal '2026-09-01 —— dbo.Orders|2026-09-03 —— dbo.OrderItems' (@($ev.sections) -join '|')
            $ls = @($s.legacy_schema)[0]
            Assert-Equal '2026-08-20' $ls.captured
            Assert-Equal 'dbo.usp_Cancel' $ls.object
        } finally { Remove-Item $RiRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
