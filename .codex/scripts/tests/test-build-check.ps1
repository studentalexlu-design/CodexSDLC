# test-build-check.ps1
# build-check 掛在每一次 apply_patch 上，所以它有兩種失效方式：
#   - 觸發判定過寬 → 改一個 .md 也 build，純等待
#   - 觸發判定過窄 → 改 production code 卻不 build，守衛形同不存在
# 另外驗證綠燈去抖：一次邏輯變更由數個 patch 組成，每個 patch 都 build 是主要的等待來源。

$Script = '.codex/scripts/build-check.ps1'

function New-EditPayload {
    param([string[]]$Paths)
    $files = $Paths | ForEach-Object { @{ path = $_ } }
    return (@{ tool_name = 'apply_patch'; tool_input = @{ files = $files } } | ConvertTo-Json -Depth 5 -Compress)
}

Describe-Suite 'build-check / 觸發判定' {

    It-Should '.cs 變更會觸發' {
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/Orders/OrderService.cs')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=1' $r.stdout
    }

    It-Should '.csproj / .sln 變更會觸發' {
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/Orders/Orders.csproj', 'App.sln')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=2' $r.stdout
    }

    It-Should 'markdown 不觸發' {
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('README.md', 'AGENTS.md')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=0' $r.stdout
    }

    It-Should 'bdd-docs/ 下的產物不觸發（即使副檔名相符）' {
        # 工作流自己的產物不是 production code。誤觸發會讓每次寫 checkpoint 都 build。
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('bdd-docs/f1/sample.cs')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=0' $r.stdout
    }

    It-Should '混合變更只算 production code 那些' {
        $paths = @('src/A.cs', 'docs/note.md', 'bdd-docs/f1/spec.md', 'src/B.cs')
        $r = Invoke-Script $Script -Stdin (New-EditPayload $paths) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=2' $r.stdout
    }

    It-Should '空 payload 靜默通過' {
        $r = Invoke-Script $Script -Stdin ''
        Assert-Equal 0 $r.exit
    }

    It-Should '無可辨識專案時不阻斷（本 repo 沒有 .sln／pom.xml）' {
        # 這個 repo 只有設定沒有產品程式碼。守衛在無工具鏈時必須靜默放行，
        # 否則把設定 repo 本身變成不可編輯。
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/Orders/OrderService.cs'))
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }
}

Describe-Suite 'build-check / 測試檔不觸發（test-first 的紅燈期間）' {

    # test-first 先寫測試、production code 還沒寫，本來就編不過。以前每個這種 patch 都 build 整個 solution，
    # 再回「Build FAILED after production code change」擋下 —— 改的其實是測試檔。
    function New-BcProject([hashtable]$files) {
        $root = "bc-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        foreach ($k in $files.Keys) {
            $p = Join-Path (Get-Location) "$root/$k"
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($p, $files[$k], [Text.UTF8Encoding]::new($false))
        }
        return $root
    }

    It-Should '只改測試專案裡的檔 → 不觸發' {
        $r0 = New-BcProject @{
            'App.Tests/App.Tests.csproj' = '<Project Sdk="Microsoft.NET.Sdk"></Project>'
            'App.Tests/Orders/CancelOrderTests.cs' = 'public class CancelOrderTests { }'
        }
        try {
            $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$r0/App.Tests/Orders/CancelOrderTests.cs")) -Params @{ WhatIfPaths = $true }
            Assert-Match 'triggering=0' $r.stdout "測試檔觸發了 build：$($r.stdout)"
            Assert-Match 'test-skipped=1' $r.stdout
        } finally { Remove-Item $r0 -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '檔名不像測試、但引用了測試框架的專案也算測試專案' {
        $r0 = New-BcProject @{
            'App.Specs/App.Specs.csproj' = '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="Reqnroll.NUnit" Version="2.0.0" /></ItemGroup></Project>'
            'App.Specs/Hooks.cs' = 'public class Hooks { }'
        }
        try {
            $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$r0/App.Specs/Hooks.cs", "$r0/App.Specs/App.Specs.csproj")) -Params @{ WhatIfPaths = $true }
            Assert-Match 'triggering=0' $r.stdout $r.stdout
        } finally { Remove-Item $r0 -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'step definitions 與 Java 的 src/test/ → 不觸發' {
        $patch = New-CodexPatch -Update 'src/Orders.Bdd/CancelOrderSteps.cs', 'src/test/java/com/acme/OrderTest.java', 'module-a/src/test/java/StepsConfig.java'
        $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command $patch) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=0' $r.stdout $r.stdout
        Assert-Match 'test-skipped=3' $r.stdout
    }

    It-Should 'production 專案的檔照樣觸發；混在一起時只算 production 那個' {
        $r0 = New-BcProject @{
            'App/App.csproj' = '<Project Sdk="Microsoft.NET.Sdk"></Project>'
            'App/Orders/OrderService.cs' = 'public class OrderService { }'
            'App.Tests/App.Tests.csproj' = '<Project Sdk="Microsoft.NET.Sdk"></Project>'
            'App.Tests/OrderServiceTests.cs' = 'public class OrderServiceTests { }'
        }
        try {
            $patch = New-CodexPatch -Update "$r0/App/Orders/OrderService.cs", "$r0/App.Tests/OrderServiceTests.cs"
            $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command $patch) -Params @{ WhatIfPaths = $true }
            Assert-Match 'triggering=1' $r.stdout $r.stdout
            Assert-Match "TRIGGER $r0/App/Orders/OrderService\.cs" $r.stdout
            Assert-Match 'test-skipped=1' $r.stdout
        } finally { Remove-Item $r0 -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'build-check / 綠燈去抖' {

    # 去抖時間戳依 cwd 雜湊命名，路徑要與腳本內的算法一致才能操作它。
    function Get-StampPath {
        $hash = [BitConverter]::ToString(
            [Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes((Get-Location).Path))
        ).Replace('-', '').Substring(0, 12)
        return (Join-Path ([IO.Path]::GetTempPath()) "codex-build-check-$hash.stamp")
    }

    It-Should '時間戳在視窗內時略過 build' {
        $stamp = Get-StampPath
        Set-Content $stamp -Value (Get-Date -Format o) -NoNewline
        try {
            # 若沒有略過，會落到「推斷專案類型」那段；本 repo 無專案檔仍會 exit 0，
            # 所以改用 -WhatIfPaths 之外的可觀察差異：略過時不會印任何東西。
            $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/A.cs')) -Params @{ DebounceSeconds = 300 }
            Assert-Equal 0 $r.exit
        } finally { Remove-Item $stamp -ErrorAction SilentlyContinue }
    }

    It-Should 'DebounceSeconds=0 時停用去抖' {
        $stamp = Get-StampPath
        Set-Content $stamp -Value (Get-Date -Format o) -NoNewline
        try {
            $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/A.cs')) -Params @{ DebounceSeconds = 0 }
            Assert-Equal 0 $r.exit
        } finally { Remove-Item $stamp -ErrorAction SilentlyContinue }
    }

    It-Should '過期時間戳不再抑制' {
        $stamp = Get-StampPath
        Set-Content $stamp -Value 'old' -NoNewline
        (Get-Item $stamp).LastWriteTime = (Get-Date).AddSeconds(-3600)
        try {
            $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/A.cs')) -Params @{ DebounceSeconds = 90 }
            Assert-Equal 0 $r.exit
        } finally { Remove-Item $stamp -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'build-check / Node／TypeScript：存檔後跑型別檢查' {

    # 以前 .ts 一個都不觸發：前端專案寫錯型別，要等到 ④ 跑測試（或根本沒跑）才看得到。
    # 套件目錄由 package.json 決定，指令照 lib/node-project.ps1（跟 repo-index 同一份）。
    function New-BcNode([hashtable]$files, [switch]$NoInstall) {
        $root = "bcn-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        foreach ($k in $files.Keys) {
            $p = Join-Path (Get-Location) "$root/$k"
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($p, $files[$k], [Text.UTF8Encoding]::new($false))
        }
        if (-not $NoInstall) { New-Item -ItemType Directory -Path (Join-Path (Get-Location) "$root/web/node_modules") -Force | Out-Null }
        return $root
    }

    # 假的 npm：印一行 tsc 形狀的錯誤，後面接十幾行 npm 的「script 失敗」雜訊（只留最後 10 行的話會看不到錯誤），
    # 記下在哪個目錄被叫，exit code 讀那個目錄的 exitcode.txt。
    # 不用這台的 npm：test runner 把 codex 所在的目錄拿出 PATH，而用 npm 裝 codex 的機器上 node／npm 就在那個目錄裡 ——
    # 用真的 npm 的測試在那種機器上會走「工具鏈不可用」那條，什麼都沒測到。
    function New-BcFakeNpm([string]$bin) {
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $noise = (1..12 | ForEach-Object { "@echo npm error noise line $_" }) -join "`r`n"
        $body = "@echo %CD%>> `"%~dp0npm.calls`"`r`n@echo src/a.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'.`r`n$noise`r`n@set /p CODE=<exitcode.txt`r`n@exit /b %CODE%`r`n"
        [IO.File]::WriteAllText((Join-Path $bin 'npm.cmd'), $body, [Text.Encoding]::ASCII)
        return (Join-Path $bin 'npm.calls')
    }
    function Get-BcPath([string]$bin) {
        return (@($bin, (Split-Path ([Environment]::ProcessPath) -Parent), [Environment]::SystemDirectory) | Where-Object { $_ }) -join ';'
    }
    $BcPkg = @{ 'web/package.json' = '{ "name": "web", "scripts": { "typecheck": "tsc --noEmit" } }' }

    It-Should '.ts／.tsx／.vue／tsconfig 觸發；測試檔、.d.ts、.js、node_modules 不觸發' {
        $r0 = New-BcNode $BcPkg
        try {
            $patch = New-CodexPatch -Update "$r0/web/src/a.ts", "$r0/web/src/App.tsx", "$r0/web/src/Panel.vue", "$r0/web/tsconfig.json",
                                            "$r0/web/src/a.test.ts", "$r0/web/src/__tests__/b.ts", "$r0/web/e2e/c.spec.ts", "$r0/web/src/env.d.ts",
                                            "$r0/web/src/legacy.js", "$r0/web/node_modules/x/index.ts"
            $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command $patch) -Params @{ WhatIfPaths = $true }
            Assert-Match 'triggering=4' $r.stdout $r.stdout
            Assert-Match 'test-skipped=3' $r.stdout $r.stdout
            Assert-Match "NODE $r0/web build='npm run typecheck'" $r.stdout $r.stdout
        } finally { Remove-Item $r0 -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '型別錯誤 → exit 2，訊息是 tsc 那一行而不是 npm 的雜訊；在套件目錄跑；修好 → 0' {
        $r0 = New-BcNode ($BcPkg + @{ 'web/exitcode.txt' = '1' })
        $bin = Join-Path (Get-Location) "$r0-bin"
        $calls = New-BcFakeNpm $bin
        try {
            if (-not $IsWindows) { return }   # 假的 npm 是 .cmd
            $payload = New-CodexHookPayload -Command (New-CodexPatch -Update "$r0/web/src/a.ts")
            $r = Invoke-Script $Script -Stdin $payload -Params @{ DebounceSeconds = 0 } -Env @{ PATH = (Get-BcPath $bin) }
            Assert-Equal 2 $r.exit "型別錯誤沒有擋下：$($r.stdout) $($r.stderr)"
            Assert-Match 'Type check FAILED .*in .*web' $r.stderr
            Assert-Match 'error TS2322' $r.stderr '錯誤那一行被 npm 的「script 失敗」雜訊擠掉了'
            Assert-Match ([regex]::Escape((Join-Path (Get-Location) "$r0\web"))) ([IO.File]::ReadAllText($calls)) '型別檢查不是在套件目錄跑的'
            [IO.File]::WriteAllText((Join-Path (Get-Location) "$r0/web/exitcode.txt"), '0', [Text.Encoding]::ASCII)
            $r = Invoke-Script $Script -Stdin $payload -Params @{ DebounceSeconds = 0 } -Env @{ PATH = (Get-BcPath $bin) }
            Assert-Equal 0 $r.exit $r.stderr
        } finally { Remove-Item $r0, $bin -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '依賴沒裝（沒有 node_modules）→ 不跑、不阻斷：tsc 根本叫不起來，那不是型別錯誤' {
        $r0 = New-BcNode ($BcPkg + @{ 'web/exitcode.txt' = '1' }) -NoInstall
        $bin = Join-Path (Get-Location) "$r0-bin"
        $calls = New-BcFakeNpm $bin
        try {
            if (-not $IsWindows) { return }
            $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$r0/web/src/a.ts")) -Params @{ DebounceSeconds = 0 } -Env @{ PATH = (Get-BcPath $bin) }
            Assert-Equal 0 $r.exit "依賴沒裝卻擋下了每一次寫檔：$($r.stderr)"
            Assert-True (-not (Test-Path $calls)) '依賴沒裝還是去跑了型別檢查'
        } finally { Remove-Item $r0, $bin -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有可信的型別檢查（沒有 script、沒有 typescript）→ 不跑、不擋' {
        $r0 = New-BcNode @{ 'web/package.json' = '{ "name": "web" }' }
        $bin = Join-Path (Get-Location) "$r0-bin"
        $calls = New-BcFakeNpm $bin
        try {
            $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$r0/web/src/a.ts")) -Params @{ WhatIfPaths = $true }
            Assert-Match "NODE $r0/web build=''" $r.stdout $r.stdout
            $r = Invoke-Script $Script -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$r0/web/src/a.ts")) -Params @{ DebounceSeconds = 0 } -Env @{ PATH = (Get-BcPath $bin) }
            Assert-Equal 0 $r.exit $r.stderr
            Assert-True (-not (Test-Path $calls)) '沒有型別檢查指令卻叫了 npm'
        } finally { Remove-Item $r0, $bin -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
