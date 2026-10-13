# test-pack.ps1
# pack 是出貨前最後一道閘。這裡只驗「出貨前就該擋、而且是靜默的」那幾件；整條打包流程（lint、測試、vsix）
# 由維護者每次發版實際跑過。
#
#   版本檔的 source 寫法認不得 → install 把它寫進每個消費端的 update.source，check-update 永遠查不到 ——
#                                 畫面上一切正常，只是再也沒有人告訴他們有新版

$PackRoot = Join-Path ([IO.Path]::GetTempPath()) 'codex-sdlc-pack-tests'

# 一份只夠走到 source 檢查的 repo：版本檔＋真的 schema（pack 拿 schema 的 pattern 驗，跟 set 同一條）。
# 後面的 agent-lint 一定紅（什麼都沒有）—— 這裡只看 source 那一句有沒有出現。
function Invoke-PackWithSource([string]$source) {
    Remove-Item $PackRoot -Recurse -Force -ErrorAction SilentlyContinue
    $bdd = Join-Path $PackRoot '.codex/bdd-workflow'
    New-Item -ItemType Directory -Path $bdd -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $bdd 'bdd-workflow-version.json'),
        "{ `"contract-version`": `"9.9.0`", `"source`": `"$source`" }", [Text.UTF8Encoding]::new($false))
    Copy-Item '.codex/bdd-workflow/sdlc.config.schema.json' (Join-Path $bdd 'sdlc.config.schema.json')
    return Invoke-Script '.codex/scripts/pack.ps1' -Params @{ Root = $PackRoot; OutDir = (Join-Path $PackRoot 'dist'); SkipTests = $true; SkipExtension = $true }
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
