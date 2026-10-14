# test-pack.ps1
# pack 是出貨前最後一道閘。這裡只驗「出貨前就該擋、而且是靜默的」那幾件；整條打包流程（lint、測試、vsix）
# 由維護者每次發版實際跑過。
#
#   版本檔的 source 寫法認不得 → install 把它寫進每個消費端的 update.source，check-update 永遠查不到 ——
#                                 畫面上一切正常，只是再也沒有人告訴他們有新版

$PackRoot = Join-Path ([IO.Path]::GetTempPath()) 'codex-sdlc-pack-tests'

# 一份只夠走到 source 檢查的 repo：版本檔＋真的 schema（pack 拿 schema 的 pattern 驗，跟 set 同一條）。
# 後面的 agent-lint 一定紅（什麼都沒有）—— 這裡只看 source 那一句有沒有出現。
function Invoke-PackWithSource([string]$source, [hashtable]$Extra = @{ SkipExtension = $true }) {
    Remove-Item $PackRoot -Recurse -Force -ErrorAction SilentlyContinue
    $bdd = Join-Path $PackRoot '.codex/bdd-workflow'
    New-Item -ItemType Directory -Path $bdd -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $bdd 'bdd-workflow-version.json'),
        "{ `"contract-version`": `"9.9.0`", `"source`": `"$source`" }", [Text.UTF8Encoding]::new($false))
    Copy-Item '.codex/bdd-workflow/sdlc.config.schema.json' (Join-Path $bdd 'sdlc.config.schema.json')
    $params = @{ Root = $PackRoot; OutDir = (Join-Path $PackRoot 'dist'); SkipTests = $true }
    foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
    return Invoke-Script '.codex/scripts/pack.ps1' -Params $params
}

Describe-Suite 'pack / 出貨前擋下靜默的失效' {

    It-Should '版本檔的 source 是沒標明哪一家的自架網址 → 不出貨，並說要怎麼寫' {
        try {
            $r = Invoke-PackWithSource 'https://git.acme.local/team/codex-sdlc'
            Assert-Equal 2 $r.exit
            Assert-Match '寫法認不得' $r.stderr
            Assert-Match 'gitea:https://' $r.stderr '只說認不得，沒說要怎麼寫'
        } finally { Remove-Item $PackRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '認得的寫法（gitea:、gitlab.com、github.com）→ 這一關放行（對照組）' {
        try {
            foreach ($ok in @('gitea:https://git.acme.local/team/codex-sdlc', 'https://gitlab.com/acme/tools/codex-sdlc', 'https://github.com/acme/codex-sdlc')) {
                $r = Invoke-PackWithSource $ok
                Assert-True ($r.stderr -notmatch '寫法認不得') "$ok 被當成認不得：$($r.stderr)"
            }
        } finally { Remove-Item $PackRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# -NpmRegistry 的參數錯誤要在 lint、測試、vsix 之前就擋 —— 等完整套建置才說「網址打錯」是白等。
# 這份 repo 的 agent-lint 一定紅，所以只要看到的是 -NpmRegistry 那一句、而不是 agent-lint，就代表擋在前面了。
Describe-Suite 'pack / -NpmRegistry 參數先驗' {

    It-Should '跟 -SkipExtension 一起給 → 先擋（沒有 vsix 可包）' {
        try {
            $r = Invoke-PackWithSource 'https://github.com/acme/codex-sdlc' @{ SkipExtension = $true; NpmRegistry = 'https://nexus.acme.local/repository/npm-hosted/' }
            Assert-Equal 2 $r.exit
            Assert-Match 'SkipExtension 不能一起用' $r.stderr
            Assert-True ($r.stderr -notmatch 'agent-lint') '應該在 agent-lint 之前就擋下'
        } finally { Remove-Item $PackRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'repo 沒有 vscode-extension/ → 先擋' {
        try {
            $r = Invoke-PackWithSource 'https://github.com/acme/codex-sdlc' @{ NpmRegistry = 'https://nexus.acme.local/repository/npm-hosted/' }
            Assert-Equal 2 $r.exit
            Assert-Match '沒有 vscode-extension/' $r.stderr
        } finally { Remove-Item $PackRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '不是 http(s) 網址 → 先擋，並舉例要怎麼寫' {
        try {
            # 先讓 helper 建好 repo（它會清掉 PackRoot），再補一個 vscode-extension/ 讓前一關放行
            Invoke-PackWithSource 'https://github.com/acme/codex-sdlc' | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $PackRoot 'vscode-extension') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $PackRoot 'vscode-extension/package.json'), '{}')
            $r = Invoke-Script '.codex/scripts/pack.ps1' -Params @{ Root = $PackRoot; OutDir = (Join-Path $PackRoot 'dist'); SkipTests = $true; NpmRegistry = 'nexus.acme.local/npm-hosted' }
            Assert-Equal 2 $r.exit
            Assert-Match '要是 registry 的網址' $r.stderr
            Assert-Match 'https://' $r.stderr '只說不對，沒舉例'
        } finally { Remove-Item $PackRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
