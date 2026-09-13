# pack.ps1
# 維護者用：把工具那半打成一份可發佈的 zip，附 manifest.json（每個檔一個 sha256）。
#
# manifest 是整條升級路徑的地基：沒有它，update 分不出「這個檔跟上一版一樣」與
# 「使用者改過」—— 而 README 本來就叫使用者去改 AGENTS.md，所以「改過」是常態不是例外。
#
# 打包前一定跑 agent-lint 與 fixture 測試，紅燈就不出貨：一份設定不一致的發佈物，
# 症狀會落在**別人的**專案裡，而且通常是靜默的。
#
# 打包時會把 agent toml 的 SDLC-TUNING 區塊清掉 —— 發佈物一律是原廠狀態。
# 維護者在自己 repo 跑過 apply 之後那些區塊會留在工作區，跟著出貨就等於把
# 維護者的調校偷渡進所有人的專案。
#
# repo 裡有 vscode-extension/ 時，出貨前也會 npm ci ＋ build ＋ 跑它自己的測試，產出 .vsix 放進發佈物的 editor/。
# 紅燈一樣不出貨。vsix **不進 manifest**：它不是工具那半、也不是使用者那半，是每台機器一份的編輯器外掛，
# 升級邏輯管不到、也不該管（理由見 docs/vscode-extension-plan.md 事實 1）。
#
# Exit: 0 = 打包完成；2 = 驗證未過或參數錯誤。

[CmdletBinding()]
param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$OutDir = 'dist',
    [switch]$SkipTests,
    [switch]$SkipExtension,              # 不打包 VS Code extension（沒有 Node.js 的機器、或這一版不帶編輯器那一層）
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$ToolRoots  = @('.codex', '.agents')
$ToolFiles  = @('AGENTS.md')
$VersionRel = '.codex/bdd-workflow/bdd-workflow-version.json'
$ManifestRel = '.codex/bdd-workflow/manifest.json'
$ExtensionDir = 'vscode-extension'
$TuneBegin  = '# SDLC-TUNING:BEGIN'
$TuneEnd    = '# SDLC-TUNING:END'
$Utf8NoBom  = [Text.UTF8Encoding]::new($false)

function Fail([string]$m) { [Console]::Error.WriteLine("[pack] $m"); exit 2 }
function Say([string]$m)  { if (-not $Json) { Write-Output $m } }

# 子行程（agent-lint、fixture 測試、npm、node）被重導向時寫的是 UTF-8，PowerShell 卻拿 console 的 code page 解碼
# —— 在 cp950 的終端機上，中文的測試名稱與錯誤訊息全是亂碼，紅燈了也看不懂紅在哪。所以解碼期間暫時換成 UTF-8。
function Invoke-Utf8([scriptblock]$block) {
    $prev = $null
    try { $prev = [Console]::OutputEncoding; [Console]::OutputEncoding = $Utf8NoBom } catch { }
    try { & $block } finally { if ($prev) { try { [Console]::OutputEncoding = $prev } catch { } } }
}

$Root = (Resolve-Path $Root).Path
$verFile = Join-Path $Root $VersionRel
if (-not (Test-Path $verFile)) { Fail "找不到 $VersionRel" }
$ver = Get-Content $verFile -Raw -Encoding UTF8 | ConvertFrom-Json
$version = [string]$ver.'contract-version'
if ($version -notmatch '^\d+\.\d+\.\d+$') { Fail "contract-version 不是 semver：$version" }

# 來源網址跟著發佈物走 —— install 會把它寫進每個消費端的 sdlc.config.json。
# 沒設不阻斷（第一版還沒推上去很正常），但一定要喊：沒有它，那些專案永遠不會
# 有人告訴他們有新版，而症狀是零 —— 畫面上一切正常。
$srcUrl = [string]$ver.source
if (-not $srcUrl) {
    [Console]::Error.WriteLine("[pack] 版本檔沒有設 `source` —— 這一版裝出去的專案不會收到更新通知（check-update 會直接說查不到）。推上 repo 之後把網址填進 $VersionRel 的 `source`。")
} elseif ($srcUrl -match '(?i)OWNER|EXAMPLE|<') {
    [Console]::Error.WriteLine("[pack] 版本檔的 `source` 看起來還是預留位置（$srcUrl）—— 換成真的網址，否則裝出去的專案會拿到一個指不到任何地方的來源。")
}

# ---- 出貨前驗證 ----
Push-Location $Root
try {
    Invoke-Utf8 { & pwsh -NoProfile -ExecutionPolicy Bypass -File '.codex/scripts/agent-lint.ps1' | ForEach-Object { Say "  $_" } }
    if ($LASTEXITCODE -ne 0) { Fail 'agent-lint 紅燈 —— 不出貨。設定不一致的症狀會落在別人的專案裡。' }
    if (-not $SkipTests) {
        Invoke-Utf8 { & pwsh -NoProfile -ExecutionPolicy Bypass -File '.codex/scripts/tests/run-tests.ps1' | ForEach-Object { Say "  $_" } }
        if ($LASTEXITCODE -ne 0) { Fail 'fixture 測試紅燈 —— 不出貨。' }
    }
} finally { Pop-Location }

# ---- VS Code extension ----
# 放在收集檔案之前：extension 紅燈就不該留下半套 staging。
# 版本號由 agent-lint 檢查 11 擋（package.json 必須等於 contract-version，上面已經跑過）；
# 這裡再從**產出的 vsix 本身**讀一次 —— 建置腳本若改寫了版本號，出貨的是 vsix，不是 package.json。
$vsix = $null
$extRoot = Join-Path $Root $ExtensionDir
if ((Test-Path (Join-Path $extRoot 'package.json')) -and -not $SkipExtension) {
    foreach ($tool in @('node', 'npm')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Fail "要打包 VS Code extension 需要 $tool（Node.js）。這一版不帶編輯器那一層的話，加 -SkipExtension。"
        }
    }
    $extBuild = Join-Path ([IO.Path]::GetTempPath()) ("sdlc-vsix-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $extBuild -Force | Out-Null
    Push-Location $extRoot
    try {
        Say 'VS Code extension：npm ci'
        Invoke-Utf8 { & npm ci --no-audit --no-fund 2>&1 | ForEach-Object { Say "  $_" } }
        if ($LASTEXITCODE -ne 0) { Fail 'extension 的 npm ci 失敗 —— 不出貨。' }
        Invoke-Utf8 { & npm run build 2>&1 | ForEach-Object { Say "  $_" } }
        if ($LASTEXITCODE -ne 0) { Fail 'extension 編譯失敗 —— 不出貨。' }
        if (-not $SkipTests) {
            Invoke-Utf8 { & npm test 2>&1 | Where-Object { $_ -match '^(not ok|# (tests|pass|fail))' } | ForEach-Object { Say "  $_" } }
            if ($LASTEXITCODE -ne 0) { Fail 'extension 測試紅燈 —— 不出貨。它讀的是 sdlc.ps1 的 -Json，紅在這裡通常代表兩邊的合約分岔了。' }
        }
        $vsix = Join-Path $extBuild "codex-sdlc-$version.vsix"
        Invoke-Utf8 { & npx --no-install vsce package --skip-license --allow-missing-repository --out $vsix 2>&1 | ForEach-Object { Say "  $_" } }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $vsix)) { Fail 'vsce package 失敗 —— 不出貨。' }
    } finally { Pop-Location }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipRead = [IO.Compression.ZipFile]::OpenRead($vsix)
    try {
        $entry = $zipRead.Entries | Where-Object { $_.FullName -eq 'extension/package.json' } | Select-Object -First 1
        if (-not $entry) { Fail 'vsix 裡沒有 extension/package.json —— 產物是壞的，不出貨。' }
        $reader = [IO.StreamReader]::new($entry.Open(), $Utf8NoBom)
        try { $vpkg = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $zipRead.Dispose() }
    if ([string]$vpkg.version -ne $version) {
        Fail "vsix 的版本是 $($vpkg.version)，contract-version 是 $version —— 對不上就不出貨（doctor 的相容性判斷會建立在錯的數字上）。"
    }
    if ($null -eq $vpkg.codexSdlc -or $null -eq $vpkg.codexSdlc.jsonSchema) {
        Fail 'vsix 的 package.json 沒有宣告 codexSdlc.jsonSchema —— doctor 判斷不了它讀不讀得懂這一版的 -Json，不出貨。'
    }
    Say "VS Code extension：codex-sdlc-$version.vsix（-Json schema $($vpkg.codexSdlc.jsonSchema)）"
} elseif ($SkipExtension) {
    Say 'VS Code extension：-SkipExtension，這一版的發佈物不帶 editor/。'
}

# ---- 收集檔案 ----
$files = @()
foreach ($d in $ToolRoots) {
    $p = Join-Path $Root $d
    if (Test-Path $p) {
        $files += @(Get-ChildItem $p -Recurse -File | ForEach-Object {
            ($_.FullName.Substring($Root.Length) -replace '\\', '/').TrimStart('/')
        })
    }
}
foreach ($f in $ToolFiles) { if (Test-Path (Join-Path $Root $f)) { $files += $f } }
$files = @($files | Where-Object { $_ -ne $ManifestRel } | Sort-Object -Unique)
if (-not $files) { Fail '沒有收集到任何檔案。' }

# ---- staging（絕不動工作區）----
$stage = Join-Path ([IO.Path]::GetTempPath()) ("sdlc-pack-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    foreach ($rel in $files) {
        $dst = Join-Path $stage $rel
        $dir = Split-Path $dst -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item (Join-Path $Root $rel) $dst -Force
    }

    # guidelines/ 骨架跟著出貨，但**不進 manifest**。
    # manifest 是「這些檔是工具的、升級時我負責」的清單，而 guidelines/ 是使用者的 ——
    # 列進去就等於宣稱工具擁有它，下一次升級會開始比對、報告、甚至覆蓋團隊自己的規範。
    # install 只在目標沒有 guidelines/ 時才放這份骨架。
    $skelCount = 0
    $gsrc = Join-Path $Root 'guidelines'
    if (Test-Path $gsrc) {
        Copy-Item $gsrc (Join-Path $stage 'guidelines') -Recurse -Force
        $skelCount = @(Get-ChildItem (Join-Path $stage 'guidelines') -Recurse -File).Count
    }

    # vsix 同理：跟著出貨，但**不進 manifest**（$files 在上面就算完了，這裡放進 stage 的檔不會被列進去）。
    # install 的複製迴圈只走工具那半，看不到 editor/；只有 -WithEditor 才會拿它去裝。
    if ($vsix) {
        New-Item -ItemType Directory -Path (Join-Path $stage 'editor') -Force | Out-Null
        Copy-Item $vsix (Join-Path $stage "editor/codex-sdlc-$version.vsix") -Force
    }

    # 發佈物一律原廠狀態：清掉 SDLC-TUNING 區塊。
    $stripped = @()
    foreach ($t in @(Get-ChildItem (Join-Path $stage '.codex/agents') -Filter *.toml -File -ErrorAction SilentlyContinue)) {
        $text = [IO.File]::ReadAllText($t.FullName)
        $pattern = "(?s)" + [regex]::Escape($TuneBegin) + ".*?" + [regex]::Escape($TuneEnd) + "\r?\n?"
        if ($text -match $pattern) {
            [IO.File]::WriteAllText($t.FullName, ([regex]::Replace($text, $pattern, '')), $Utf8NoBom)
            $stripped += $t.Name
        }
    }
    if ($stripped.Count -gt 0) { Say "清掉 SDLC-TUNING 區塊：$($stripped -join '、')（發佈物一律原廠狀態）" }

    # ---- manifest ----
    $sha = [Security.Cryptography.SHA256]::Create()
    $manifest = [ordered]@{}
    try {
        foreach ($rel in $files) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $stage $rel))
            $manifest[$rel] = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
        }
    } finally { $sha.Dispose() }

    $mPath = Join-Path $stage $ManifestRel
    $mDir = Split-Path $mPath -Parent
    if (-not (Test-Path $mDir)) { New-Item -ItemType Directory -Path $mDir -Force | Out-Null }
    [IO.File]::WriteAllText($mPath, ((([ordered]@{
        'contract-version'      = $version
        'min-compatible-version' = [string]$ver.'min-compatible-version'
        'packed-at'             = (Get-Date).ToString('o')
        'file_count'            = $files.Count
        'files'                 = $manifest
    }) | ConvertTo-Json -Depth 6) + "`n"), $Utf8NoBom)

    # ---- zip ----
    $outAbs = if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $Root $OutDir }
    if (-not (Test-Path $outAbs)) { New-Item -ItemType Directory -Path $outAbs -Force | Out-Null }
    $zip = Join-Path $outAbs "codex-sdlc-$version.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

    if ($Json) {
        [pscustomobject]@{ version = $version; zip = $zip; file_count = $files.Count; vsix = $(if ($vsix) { "editor/codex-sdlc-$version.vsix" } else { $null }) } | ConvertTo-Json -Compress
    } else {
        Say ''
        Say "打包完成：$zip"
        Say "版本 $version，$($files.Count) 個工具檔（manifest 已寫入 $ManifestRel）$(if ($skelCount) { "，另附 $skelCount 個 guidelines/ 骨架檔（不在 manifest 內 —— 那是使用者的）" })$(if ($vsix) { "，以及 editor/codex-sdlc-$version.vsix（不在 manifest 內 —— 那是每台機器一份的編輯器外掛）" })"
        Say ''
        Say '使用者的安裝方式（解壓到別處，不要直接蓋在專案上）：'
        Say '  pwsh <解壓目錄>/.codex/scripts/sdlc.ps1 install -Target <他的專案>'
        if ($vsix) { Say '  （要順便裝 VS Code extension 就加 -WithEditor）' }
    }
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    if ($vsix) { Remove-Item (Split-Path $vsix -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
