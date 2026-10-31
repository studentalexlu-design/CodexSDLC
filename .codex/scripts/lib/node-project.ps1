# lib/node-project.ps1
# Node／TypeScript 專案（package.json）：套件管理器、型別檢查與測試指令、測試框架。repo-index.ps1 與 build-check.ps1 共用。
#
# 為什麼是共用檔（wrapper 判定是兩邊各留一份）：這裡的判定長得多，兩份副本一旦分岔，索引寫給 agent 的指令
# 跟 hook 真的跑的就不是同一個 —— 而兩邊各自都是綠的。
#
# **只認 package.json，不數 .js 檔。** ASP.NET 的 wwwroot/lib 底下就是一堆 jquery.js；數檔數會把 .NET 專案判成前端，
# 而它的後端語言、指令全都跟著變。package.json 之於 Node，就是 .csproj／pom.xml 之於 .NET／Java。
#
# 指令一律先用專案自己的 script，沒有才推導 —— 同 wrapper 那條：專案寫好的就是它要的版本與參數。
# 套件名稱 2026-10 在 npm registry 查過；JUnit 的參數與各家 testcase name 實跑過（gherkin-check 的 Get-NameKeys 記了形狀）。

# 建置與工具的輸出目錄：不走進去（index 的 excludeDirs、impact-scope 都加這幾個）
$script:NodeGeneratedDirs = @('.next', '.nuxt', '.svelte-kit', '.angular', '.output', '.turbo', '.vite', '.yarn', '.pnpm-store',
                              '.features-gen', 'coverage', 'storybook-static', 'playwright-report', 'test-results')
$script:NodeSourceRe  = '(?i)\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|vue|svelte)$'
$script:NodeTypedRe   = '(?i)\.(ts|tsx|mts|cts|vue|svelte)$'   # 型別檢查看得到的；.js 沒有「編譯」這一步，改它不觸發
$script:NodeIgnoredRe = '(?i)(\.min\.js|\.d\.ts)$'              # 壓縮過的第三方檔、型別宣告（多半是產生的）

# 測試檔：test-first 期間 production code 還沒寫，型別檢查本來就過不了 —— 同 build-check 對 .cs 測試專案的理由。
# 不含 `features/`：feature-sliced 的前端把 production code 放在 src/features/ 底下。
function Test-NodeTestPath([string]$rel) {
    $p = $rel -replace '\\', '/'
    return ($p -match '(?i)(^|/)(__tests__|__mocks__|tests?|e2e|cypress|playwright|step_definitions|steps)/' -or
            $p -match '(?i)\.(test|spec|steps|stories|e2e|cy)\.[cm]?[jt]sx?$')
}

function Read-NodePackageJson([string]$dir) {
    $p = Join-Path $dir 'package.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop) } catch { return $null }
}

function Get-NodeDepNames($pkg) {
    $names = @()
    foreach ($k in 'dependencies', 'devDependencies') {
        if ($pkg -and $pkg[$k] -is [Collections.IDictionary]) { $names += @($pkg[$k].Keys) }
    }
    return @($names | Sort-Object -Unique)
}

# $dir 到 $root 之間（不含 $dir）每一層的 package.json —— workspace 的根常常才是裝 vitest／typescript 的那一份。
function Get-NodeAncestorPackages([string]$dir, [string]$root) {
    $out = @()
    $rootN = if ($root) { $root.TrimEnd('\', '/') } else { $null }
    $d = $dir.TrimEnd('\', '/')
    while ($rootN -and $d -ne $rootN) {
        $parent = Split-Path $d -Parent
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent.TrimEnd('\', '/')
        if (Test-Path -LiteralPath (Join-Path $d 'package.json') -PathType Leaf) { $out += , @{ dir = $d; pkg = (Read-NodePackageJson $d) } }
    }
    return $out
}

# 檔案所屬的套件目錄：往上找到的第一個 package.json（不出 $root、不在 node_modules 裡）
function Find-NodePackageDir([string]$full, [string]$root) {
    $rootN = $root.TrimEnd('\', '/')
    $d = Split-Path $full -Parent
    while ($d -and $d.StartsWith($rootN, [StringComparison]::OrdinalIgnoreCase)) {
        if ($d -match '[\\/]node_modules([\\/]|$)') { return $null }
        if (Test-Path -LiteralPath (Join-Path $d 'package.json') -PathType Leaf) { return $d }
        if ($d.TrimEnd('\', '/') -eq $rootN) { break }
        $parent = Split-Path $d -Parent
        if ($parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

# 依賴裝了沒（node_modules 或 Yarn PnP）。沒裝時 tsc 根本叫不起來 —— 那是「工具鏈不可用」，不是 build 失敗。
function Test-NodeInstalled([string]$dir, [string]$root) {
    $dirs = @($dir) + @(Get-NodeAncestorPackages $dir $root | ForEach-Object { $_.dir })
    if ($root) { $dirs += $root }
    foreach ($d in $dirs) {
        if ((Test-Path -LiteralPath (Join-Path $d 'node_modules') -PathType Container) -or
            (Test-Path -LiteralPath (Join-Path $d '.pnp.cjs') -PathType Leaf)) { return $true }
    }
    return $false
}

function Get-NodePackageManager([string]$dir, [string]$root, $pkg) {
    if ($pkg -and [string]$pkg['packageManager'] -match '^(npm|pnpm|yarn|bun)@') { return $Matches[1] }
    $locks = [ordered]@{ 'pnpm-lock.yaml' = 'pnpm'; 'yarn.lock' = 'yarn'; 'bun.lock' = 'bun'; 'bun.lockb' = 'bun'; 'package-lock.json' = 'npm' }
    foreach ($d in @($dir) + @(Get-NodeAncestorPackages $dir $root | ForEach-Object { $_.dir }) + @($root | Where-Object { $_ })) {
        foreach ($k in $locks.Keys) { if (Test-Path -LiteralPath (Join-Path $d $k) -PathType Leaf) { return $locks[$k] } }
        $p = Read-NodePackageJson $d
        if ($p -and [string]$p['packageManager'] -match '^(npm|pnpm|yarn|bun)@') { return $Matches[1] }
    }
    return 'npm'
}

function Get-NodeRun([string]$pm, [string]$script) {
    if ($script -eq 'test' -and $pm -ne 'bun') { return "$pm test" }   # `bun test` 是 bun 自己的 runner，不是 script
    return "$pm run $script"
}

# 跑套件自帶的執行檔。npx 一定帶 `--no`：沒裝 typescript 時 `npx tsc` 會去下載一個**同名的無關套件**；
# 帶了就只是失敗（實測：`npx canceled due to missing packages`）。
function Get-NodeExec([string]$pm, [string]$bin) {
    switch ($pm) {
        'pnpm' { return "pnpm exec $bin" }
        'yarn' { return "yarn run $bin" }
        'bun'  { return "bun run $bin" }
        default { return "npx --no -- $bin" }
    }
}

function Find-NodeDep([string[]]$deps, [string[]]$names) {
    foreach ($n in $names) { if ($deps -contains $n) { return $n } }
    return $null
}

# 型別檢查指令（build-check 存檔後跑的那一個）。順序：
#   1. 專案的型別檢查 script
#   2. build script 開頭的那段型別檢查（Vite 範本：`tsc -b && vite build`、`vue-tsc -b && vite build`）—— 不跑後面的打包
#   3. tsconfig.json → `tsc --noEmit`；solution-style（`"files": []` ＋ references）的 tsconfig 在 tsc --noEmit 下**什麼都不查**、
#      永遠是綠的，那時改查 tsconfig.app.json，沒有就不給（沒有檢查好過一個永遠綠的檢查）
# tsc 一律要 typescript 在依賴裡：沒有的話這個指令只會失敗，hook 會把它當成 build 紅燈擋下每一次寫檔。
function Get-NodeTypeCheck([string]$dir, $pkg, [string]$pm, [string[]]$deps) {
    $scripts = if ($pkg -and $pkg['scripts'] -is [Collections.IDictionary]) { $pkg['scripts'] } else { @{} }
    foreach ($n in 'typecheck', 'type-check', 'check-types', 'types:check', 'tsc') {
        if ($scripts.Contains($n)) { return (Get-NodeRun $pm $n) }
    }
    if ($scripts.Contains('check') -and [string]$scripts['check'] -match '\b(svelte-check|vue-tsc|tsc)\b') { return (Get-NodeRun $pm 'check') }
    if ($scripts['build']) {
        $first = (([string]$scripts['build'] -split '&&')[0]).Trim()
        if ($first -match '^(tsc|vue-tsc|svelte-check)(\s|$)') { return (Get-NodeExec $pm $first) }
    }
    if ($deps -notcontains 'typescript') { return $null }
    $ts = Join-Path $dir 'tsconfig.json'
    if (-not (Test-Path -LiteralPath $ts -PathType Leaf)) { return $null }
    $t = Get-Content -LiteralPath $ts -Raw -ErrorAction SilentlyContinue
    if ($t -match '"references"\s*:' -and $t -match '"files"\s*:\s*\[\s*\]') {
        if (Test-Path -LiteralPath (Join-Path $dir 'tsconfig.app.json') -PathType Leaf) { return (Get-NodeExec $pm 'tsc -p tsconfig.app.json --noEmit') }
        return $null
    }
    return (Get-NodeExec $pm 'tsc --noEmit')
}

# 一個套件目錄的完整資訊：commands 與 test-toolchain 的欄位名跟 .NET／Java 那份一致，下游照同一套讀。
function Get-NodeProjectInfo([string]$dir, [string]$root) {
    $pkg = Read-NodePackageJson $dir
    $own = @(Get-NodeDepNames $pkg)
    $deps = @($own + @(Get-NodeAncestorPackages $dir $root | ForEach-Object { Get-NodeDepNames $_.pkg }) | Sort-Object -Unique)
    $pm = Get-NodePackageManager $dir $root $pkg
    $scripts = if ($pkg -and $pkg['scripts'] -is [Collections.IDictionary]) { $pkg['scripts'] } else { @{} }
    $isTs = (Test-Path -LiteralPath (Join-Path $dir 'tsconfig.json') -PathType Leaf) -or $deps -contains 'typescript' -or $deps -contains 'vue-tsc'
    $ext = if ($isTs) { 'ts' } else { 'js' }

    $test      = Find-NodeDep $deps @('vitest', 'jest', 'mocha', 'jasmine', 'karma', 'ava')
    $component = Find-NodeDep $deps @('@testing-library/react', '@testing-library/vue', '@testing-library/svelte', '@testing-library/angular',
                                      '@testing-library/preact', '@vue/test-utils', '@testing-library/dom')
    $browser   = Find-NodeDep $deps @('@playwright/test', 'cypress', '@wdio/cli', 'webdriverio', 'puppeteer')
    $bdd       = Find-NodeDep $deps @('playwright-bdd', '@cucumber/cucumber', 'quickpickle', '@amiceli/vitest-cucumber', 'jest-cucumber',
                                      '@badeball/cypress-cucumber-preprocessor')

    # 還沒有 BDD 套件時 ④ 要加哪個：**跟著已經在用的 runner 走**，不另裝一套（同 .NET 的 Reqnroll.NUnit／MSTest）。
    # 驗收層由 spec.md 指定，所以瀏覽器層與元件層各給一個。元件層選 quickpickle 而不是下載量較大的 vitest-cucumber：
    # 前者直接跑 .feature、step 定義可重用 —— QA 在 .feature 裡加一條沿用既有 step 的 scenario 就會跑；
    # 後者每條 scenario 要在 spec 檔裡再寫一次，QA 加的 scenario 沒有對應的程式就不會跑。
    $fallback = @()
    if (-not $bdd) {
        switch ($browser) {
            '@playwright/test' { $fallback += 'playwright-bdd（瀏覽器層）' }
            'cypress'          { $fallback += '@badeball/cypress-cucumber-preprocessor（瀏覽器層）' }
        }
        switch ($test) {
            'vitest' { $fallback += 'quickpickle（元件層）' }
            'jest'   { $fallback += 'jest-cucumber（元件層）' }
        }
        if (-not $fallback.Count) { $fallback += '@cucumber/cucumber' }
    }
    $acceptBdd = if ($bdd) { $bdd } else { ($fallback[0] -split '（')[0] }

    $testCmd = $null
    if ($scripts['test'] -and [string]$scripts['test'] -notmatch 'no test specified') { $testCmd = Get-NodeRun $pm 'test' }
    elseif ($test -eq 'vitest') { $testCmd = Get-NodeExec $pm 'vitest run' }
    elseif ($test -in 'jest', 'mocha') { $testCmd = Get-NodeExec $pm $test }

    $filter = switch ($test) {
        'vitest' { Get-NodeExec $pm 'vitest run -t {pattern}' }
        'jest'   { Get-NodeExec $pm 'jest -t {pattern}' }
        'mocha'  { Get-NodeExec $pm 'mocha -g {pattern}' }
        default  { if ($browser -eq '@playwright/test') { Get-NodeExec $pm 'playwright test -g {pattern}' } else { $null } }
    }

    # 驗收與 JUnit 結果檔（gherkin-check／delivery-check 要它）。$acceptBdd 是已經在用的，或 fallback 的第一個。
    $acceptance = $null; $results = $null
    switch ($acceptBdd) {
        'playwright-bdd' {
            if ($bdd) { $acceptance = "$(Get-NodeExec $pm 'bddgen') && $(Get-NodeExec $pm 'playwright test')" }
            # junit 不放 test-results/：Playwright 每次跑之前會清空它
            $results = [ordered]@{ command = "$(Get-NodeExec $pm 'bddgen') && $(Get-NodeExec $pm 'playwright test --reporter=line,junit')"
                                   env = [ordered]@{ PLAYWRIGHT_JUNIT_OUTPUT_FILE = 'playwright-report/junit.xml' }; file = 'playwright-report/junit.xml' }
        }
        '@cucumber/cucumber' {
            if ($bdd) { $acceptance = Get-NodeExec $pm 'cucumber-js' }
            $results = [ordered]@{ command = (Get-NodeExec $pm 'cucumber-js --format progress --format junit:test-results/cucumber.xml'); env = $null; file = 'test-results/cucumber.xml' }
        }
        { $_ -in 'quickpickle', '@amiceli/vitest-cucumber' } {
            if ($bdd) { $acceptance = Get-NodeExec $pm 'vitest run' }
            $results = [ordered]@{ command = (Get-NodeExec $pm 'vitest run --reporter=default --reporter=junit --outputFile.junit=test-results/junit.xml'); env = $null; file = 'test-results/junit.xml' }
        }
        'jest-cucumber' {
            if ($bdd) { $acceptance = Get-NodeExec $pm 'jest' }
            $results = [ordered]@{ command = (Get-NodeExec $pm 'jest --reporters=default --reporters=jest-junit')
                                   env = [ordered]@{ JEST_JUNIT_OUTPUT_DIR = 'test-results'; JEST_JUNIT_OUTPUT_NAME = 'junit.xml' }; file = 'test-results/junit.xml' }
            if ($deps -notcontains 'jest-junit') { $results.needs = 'jest-junit' }
        }
        '@badeball/cypress-cucumber-preprocessor' {
            if ($bdd) { $acceptance = Get-NodeExec $pm 'cypress run' }
            $results = [ordered]@{ command = (Get-NodeExec $pm 'cypress run --reporter junit --reporter-options mochaFile=test-results/cypress-[hash].xml'); env = $null; file = 'test-results/cypress-*.xml' }
        }
    }

    $stepGlob = switch ($acceptBdd) {
        'playwright-bdd'     { "**/steps/**/*.$ext" }
        '@cucumber/cucumber' { "**/step_definitions/**/*.$ext" }
        '@amiceli/vitest-cucumber' { "**/*.spec.$ext" }
        '@badeball/cypress-cucumber-preprocessor' { "**/step_definitions/**/*.$ext" }
        default              { "**/*.steps.$ext" }   # quickpickle、jest-cucumber
    }

    $toolchain = [ordered]@{ language = $(if ($isTs) { 'typescript' } else { 'javascript' }); test = $test; component = $component; browser = $browser; bdd = $bdd }
    if ($fallback.Count) { $toolchain.'bdd-fallback' = ($fallback -join '；') }

    $name = if ($pkg -and $pkg['name']) { [string]$pkg['name'] } else { Split-Path $dir -Leaf }
    return [pscustomobject]@{
        dir       = $dir
        name      = $name
        pm        = $pm
        language  = $toolchain.language
        deps      = $own
        engines   = $(if ($pkg -and $pkg['engines'] -is [Collections.IDictionary]) { [string]$pkg['engines']['node'] } else { '' })
        commands  = [ordered]@{
            'build-tool' = $pm; build = (Get-NodeTypeCheck $dir $pkg $pm $deps); test = $testCmd; 'test-filter' = $filter
            acceptance = $acceptance; 'test-results' = $results
            'source-globs' = @('**/*.ts', '**/*.tsx', '**/*.js', '**/*.jsx', '**/*.vue', '**/*.svelte'); 'project-globs' = @('package.json')
            'step-def-glob' = $stepGlob; 'feature-glob' = '**/*.feature'
        }
        'test-toolchain' = $toolchain
    }
}
