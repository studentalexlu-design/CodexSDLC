# test-sdlc.ps1
# 安裝、升級與 per-agent 調校。這一組守的全部是**靜默**的失效：
#
#   inherit 沒有真的留白       → effort 被釘死，大型 repo 的分析逾時（1d8e411 踩過一次）
#   升級無條件覆蓋 AGENTS.md   → 使用者照 README 做的合併被蓋掉，而且沒有備份
#   apply 寫的區塊被當成使用者改的 → 每次升級都誤報三個檔，報告從此沒有人看
#   沒有基準線時假設「沒動過」 → 猜錯就是安靜地蓋掉使用者的修改
#   更新通知擋住 spawn         → 擋下的理由跟他要做的事無關，而且他修不了
#
# 每一條都對著上面某一種，而不是對著功能。

$Sdlc = '.codex/scripts/sdlc.ps1'
$SdlcRoot = Join-Path ([IO.Path]::GetTempPath()) 'codex-sdlc-tests'
$Utf8 = [Text.UTF8Encoding]::new($false)

function New-SdlcFile([string]$path, [string]$content) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $content, $Utf8)
}

# 最小的「發佈物」：install／update 只需要版本檔、agent toml 與 AGENTS.md。
# 刻意不放 agent-lint 與 guideline-gate —— 那兩支在 sdlc.ps1 裡都有 Test-Path 保護，
# 缺席時要能安靜跳過（消費端若只複製了部分目錄，不該整支腳本炸掉）。
function New-SdlcRelease {
    param([string]$Name, [string]$Version = '4.6.0', [string[]]$Agents = @('sa-analyst'), [string[]]$Extra = @(),
          [string]$SourceUrl = '')
    $root = Join-Path $SdlcRoot $Name
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    New-SdlcFile (Join-Path $root '.codex/bdd-workflow/bdd-workflow-version.json') `
        "{ `"contract-version`": `"$Version`", `"min-compatible-version`": `"4.2.0`", `"source`": `"$SourceUrl`", `"v46-note`": `"測試用說明`" }"
    New-SdlcFile (Join-Path $root '.codex/config.toml') "# workflow (v$Version).`npersonality = `"friendly`"`n"
    New-SdlcFile (Join-Path $root 'AGENTS.md') "# Codex Instructions (v$Version)`n`n## 委派`n"
    foreach ($a in $Agents) {
        New-SdlcFile (Join-Path $root ".codex/agents/$a.toml") @"
name = "$a"
description = "scratch"
sandbox_mode = "danger-full-access"
developer_instructions = '''
# $a
'''
"@
    }
    foreach ($e in $Extra) { New-SdlcFile (Join-Path $root $e) "# $e`n" }
    return $root
}

function New-SdlcTarget([string]$Name) {
    $p = Join-Path $SdlcRoot $Name
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Invoke-Sdlc {
    param([string]$Cmd, [hashtable]$Params = @{})
    $p = @{ Command = $Cmd }
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    return Invoke-Script $Sdlc -Params $p
}

function Get-Toml([string]$target, [string]$agent) {
    return [IO.File]::ReadAllText((Join-Path $target ".codex/agents/$agent.toml"))
}

function Set-SdlcEffort([string]$target, [string]$agent, [string]$effort) {
    $p = Join-Path $target 'sdlc.config.json'
    $c = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.agents.$agent.effort = $effort
    [IO.File]::WriteAllText($p, ($c | ConvertTo-Json -Depth 8), $Utf8)
}

Describe-Suite 'sdlc / 調校：inherit 必須真的留白' {

    It-Should 'inherit 不寫出 model_reasoning_effort（整個功能的安全帶）' {
        # 1d8e411 把四個 agent 全釘 high → 大型 legacy repo 的分析逾時 → 7159725 拿掉必填。
        # 如果 inherit 渲染出一個預設值，這個功能就是把那個 bug 裝回去，只是這次有 UI。
        $rel = New-SdlcRelease 'r-inherit'; $t = New-SdlcTarget 't-inherit'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $toml = Get-Toml $t 'sa-analyst'
            Assert-Match 'SDLC-TUNING:BEGIN' $toml '區塊本身要在（下次 apply 才找得到它）'
            Assert-True ($toml -notmatch 'model_reasoning_effort') 'inherit 卻寫出了 effort —— 逾時 bug 被裝回去了'
            Assert-True ($toml -notmatch '(?m)^model\s*=') 'inherit 卻寫出了 model'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '設了值才寫出來，而且 apply 是冪等的' {
        $rel = New-SdlcRelease 'r-set'; $t = New-SdlcTarget 't-set'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            Set-SdlcEffort $t 'sa-analyst' 'high'
            $r1 = Invoke-Sdlc apply @{ Target = $t }
            Assert-Match 'model_reasoning_effort = "high"' (Get-Toml $t 'sa-analyst')
            $r2 = Invoke-Sdlc apply @{ Target = $t }
            Assert-Equal 0 $r2.exit
            Assert-Match '沒有變更' $r2.stdout 'apply 不冪等 —— 每次跑都改檔會讓升級誤判成使用者改過'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '設了 model 一定要喊 —— 這個 key 沒有驗證過，被忽略時症狀是靜默的' {
        $rel = New-SdlcRelease 'r-model'; $t = New-SdlcTarget 't-model'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $p = Join-Path $t 'sdlc.config.json'
            $c = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
            $c.agents.'sa-analyst'.model = 'some-model'
            [IO.File]::WriteAllText($p, ($c | ConvertTo-Json -Depth 8), $Utf8)
            $r = Invoke-Sdlc apply @{ Target = $t }
            Assert-Match '尚未在本工作流驗證過' $r.stderr '未驗證的 key 被安靜地渲染出去了'
            Assert-Match 'model = "some-model"' (Get-Toml $t 'sa-analyst') '喊歸喊，還是要寫出去'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '未知的 effort 值照寫但要喊（不擋在門口）' {
        $rel = New-SdlcRelease 'r-unknown'; $t = New-SdlcTarget 't-unknown'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            Set-SdlcEffort $t 'sa-analyst' 'ultra'
            $r = Invoke-Sdlc apply @{ Target = $t }
            Assert-Equal 0 $r.exit '未知值不該讓 apply 失敗 —— 值域是 Codex 的，不是這支腳本的'
            Assert-Match '不在已知值' $r.stderr
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / 安裝' {

    It-Should '既有的 AGENTS.md 不被覆蓋，改寫成 .new' {
        # README 本來就叫使用者把流程那幾節合進他自己那份 —— 所以「已存在」是常態不是例外。
        $rel = New-SdlcRelease 'r-agents'; $t = New-SdlcTarget 't-agents'
        New-SdlcFile (Join-Path $t 'AGENTS.md') '# 我自己的 AGENTS.md'
        try {
            $r = Invoke-Sdlc install @{ Source = $rel; Target = $t }
            Assert-Equal '# 我自己的 AGENTS.md' ([IO.File]::ReadAllText((Join-Path $t 'AGENTS.md'))) '使用者的 AGENTS.md 被蓋掉了'
            Assert-True (Test-Path (Join-Path $t 'AGENTS.md.new')) '新版沒有留下來給他合併'
            Assert-Match '合進' $r.stderr '沒有告訴他要去合併'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒被覆蓋的 AGENTS.md 不進基準線' {
        # 記進去的話，下一次 update 會把使用者的合併判成「你改過這個檔」——
        # 它從來沒有過原廠狀態，那個判斷沒有意義。
        $rel = New-SdlcRelease 'r-base'; $t = New-SdlcTarget 't-base'
        New-SdlcFile (Join-Path $t 'AGENTS.md') '# 我自己的'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $bl = Get-Content (Join-Path $t 'bdd-docs/.sdlc/installed-manifest.json') -Raw | ConvertFrom-Json
            Assert-True ($null -eq ($bl.files.PSObject.Properties | Where-Object Name -eq 'AGENTS.md')) `
                        'AGENTS.md 進了基準線 —— 下次升級會誤報使用者改過'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '已存在的 guidelines/ 完全不碰' {
        $rel = New-SdlcRelease 'r-gl'; $t = New-SdlcTarget 't-gl'
        New-SdlcFile (Join-Path $rel 'guidelines/coding.md') '# 骨架'
        New-SdlcFile (Join-Path $t 'guidelines/coding.md') '# 我們團隊自己的'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            Assert-Equal '# 我們團隊自己的' ([IO.File]::ReadAllText((Join-Path $t 'guidelines/coding.md'))) `
                         '團隊規範被工具的骨架蓋掉了 —— guidelines/ 永遠不覆蓋'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / 升級' {

    It-Should '使用者改過的工具檔會被備份，不是靜默覆蓋' {
        $r1 = New-SdlcRelease 'r1-mod' -Extra @('.codex/scripts/impact-scope.ps1')
        $t = New-SdlcTarget 't-mod'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            New-SdlcFile (Join-Path $t '.codex/scripts/impact-scope.ps1') '# 使用者改過'
            $r2 = New-SdlcRelease 'r2-mod' -Version '4.7.0' -Extra @('.codex/scripts/impact-scope.ps1')
            $res = Invoke-Sdlc update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-Match 'impact-scope\.ps1' $res.stdout '改過的檔沒有列進報告'
            Assert-True (Test-Path (Join-Path $t 'bdd-docs/.sdlc/backup-4.6.0/.codex/scripts/impact-scope.ps1')) `
                        '沒有備份就覆蓋了'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'apply 寫的 TUNING 區塊不會被誤判成「使用者改過」' {
        # 這是回歸測試：基準線在 apply **之前**記錄的話，每個 agent toml 都會在下一次
        # 升級被列成「你改過」。三個檔、每次都報 —— 那份報告的價值來自「列出來的都真的要看」。
        $r1 = New-SdlcRelease 'r1-tune'; $t = New-SdlcTarget 't-tune'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            Set-SdlcEffort $t 'sa-analyst' 'high'
            Invoke-Sdlc apply @{ Target = $t } | Out-Null
            $r2 = New-SdlcRelease 'r2-tune' -Version '4.7.0'
            $res = Invoke-Sdlc update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-True ($res.stdout -notmatch '(?s)你改過的檔.*sa-analyst\.toml') `
                        'apply 自己寫的區塊被當成使用者的修改了'
            Assert-Match 'model_reasoning_effort = "high"' (Get-Toml $t 'sa-analyst') `
                         '升級後調校沒有重新套用 —— 新版 toml 是原廠檔，不 apply 就等於設定沒生效'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '這一版刪掉的檔要真的刪掉（留著的症狀通常是靜默的）' {
        # v4.1 漏刪 bdd-orchestrator.toml 的人，看到的只有一句「工具不存在」。
        $r1 = New-SdlcRelease 'r1-del' -Extra @('.codex/scripts/legacy.ps1')
        $t = New-SdlcTarget 't-del'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $r2 = New-SdlcRelease 'r2-del' -Version '4.7.0'
            $res = Invoke-Sdlc update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-True (-not (Test-Path (Join-Path $t '.codex/scripts/legacy.ps1'))) '舊版的檔沒有被刪掉'
            Assert-True (Test-Path (Join-Path $t 'bdd-docs/.sdlc/backup-4.6.0/.codex/scripts/legacy.ps1')) '刪之前沒有備份'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有基準線時明講分不出來，而且不假設「沒動過」' {
        $r1 = New-SdlcRelease 'r1-nb' -Extra @('.codex/scripts/x.ps1'); $t = New-SdlcTarget 't-nb'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            Remove-Item (Join-Path $t 'bdd-docs/.sdlc/installed-manifest.json') -Force
            New-SdlcFile (Join-Path $t '.codex/scripts/x.ps1') '# 動過但沒人知道'
            $r2 = New-SdlcRelease 'r2-nb' -Version '4.7.0' -Extra @('.codex/scripts/x.ps1')
            $res = Invoke-Sdlc update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-Match '分不出' $res.stderr '沒有告訴使用者判斷失去依據'
            Assert-True (Test-Path (Join-Path $t 'bdd-docs/.sdlc/backup-4.6.0/.codex/scripts/x.ps1')) `
                        '沒有基準線卻直接覆蓋了 —— 猜錯就是安靜地蓋掉使用者的修改'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有設定檔時叫他去 install -Adopt，不是硬幹' {
        $r1 = New-SdlcRelease 'r1-ad'; $t = New-SdlcTarget 't-ad'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            Remove-Item (Join-Path $t 'sdlc.config.json') -Force
            $r2 = New-SdlcRelease 'r2-ad' -Version '4.7.0'
            $res = Invoke-Sdlc update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-Equal 2 $res.exit
            Assert-Match 'install -Adopt' $res.stderr '沒有給出使用者做得到的下一步'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '破壞性升級要標出來' {
        $r1 = New-SdlcRelease 'r1-bk' -Version '4.2.0'; $t = New-SdlcTarget 't-bk'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $r2 = New-SdlcRelease 'r2-bk' -Version '5.0.0'
            New-SdlcFile (Join-Path $r2 '.codex/bdd-workflow/bdd-workflow-version.json') `
                '{ "contract-version": "5.0.0", "min-compatible-version": "4.9.0" }'
            $res = Invoke-Sdlc update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-Match '破壞性升級' $res.stdout '低於最低相容版本卻沒有標示'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / 更新通知（折進 handoff-lint）' {

    # 通知的紀律：一行 stderr、不擋、不問。它掛在 PreToolUse 上，擋住就是擋住每一次 spawn，
    # 而「擋下的理由跟使用者要做的事無關」正是這套流程踩過兩次的失敗形狀。
    $Hl = '.codex/scripts/handoff-lint.ps1'
    $Ok = "mode: analyze`nfeature-id: cancel-order`n"

    function Set-UpdateCache([string]$json) {
        New-Item -ItemType Directory -Path 'bdd-docs/.sdlc' -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Get-Location) 'bdd-docs/.sdlc/update-cache.json'), $json, [Text.UTF8Encoding]::new($false))
    }

    It-Should '有新版時印一行，但**不阻斷** spawn' {
        Set-UpdateCache '{ "newer": true, "latest": "4.7.0", "installed": "4.6.0", "seen": "" }'
        try {
            $r = Invoke-Script $Hl -Stdin $Ok
            Assert-Equal 0 $r.exit '更新通知擋住了 spawn'
            Assert-Match '有新版 4\.7\.0' $r.stderr
        } finally { Remove-Item 'bdd-docs/.sdlc' -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '看過（seen == latest）就不再提醒' {
        Set-UpdateCache '{ "newer": true, "latest": "4.7.0", "installed": "4.6.0", "seen": "4.7.0" }'
        try {
            $r = Invoke-Script $Hl -Stdin $Ok
            Assert-Equal 0 $r.exit
            Assert-True ($r.stderr -notmatch '有新版') '看過之後還在每次 spawn 提醒'
        } finally { Remove-Item 'bdd-docs/.sdlc' -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '快取壞掉時完全不影響 spawn' {
        Set-UpdateCache '{ 這不是 JSON'
        try {
            $r = Invoke-Script $Hl -Stdin $Ok
            Assert-Equal 0 $r.exit '一個壞掉的通知快取擋住了整條流程'
        } finally { Remove-Item 'bdd-docs/.sdlc' -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有快取時完全靜默' {
        $r = Invoke-Script $Hl -Stdin $Ok
        Assert-Equal 0 $r.exit
        Assert-True ($r.stderr -notmatch 'sdlc') '沒有快取卻輸出了東西'
    }
}

Describe-Suite 'sdlc / 接管既有的手動安裝（-Adopt）' {

    # 所有現有使用者都走這條路：他們是用「複製目錄」裝的，硬碟上沒有基準線。
    # 沒有這一步，他們的第一次 update 只能在「分不出誰改過」的降級模式下跑。
    It-Should '把現況記成基準線，而且不覆蓋任何東西' {
        $rel = New-SdlcRelease 'r-adopt'; $t = New-SdlcTarget 't-adopt'
        try {
            # 模擬手動安裝：直接複製，沒有經過 install
            Copy-Item (Join-Path $rel '.codex') $t -Recurse -Force
            Copy-Item (Join-Path $rel 'AGENTS.md') $t -Force
            New-SdlcFile (Join-Path $t '.codex/agents/sa-analyst.toml') @'
name = "sa-analyst"
description = "scratch"
sandbox_mode = "danger-full-access"
developer_instructions = '''
# 我自己改過這個檔
'''
'@
            $r = Invoke-Sdlc install @{ Target = $t; Adopt = $true }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Match '我自己改過這個檔' (Get-Toml $t 'sa-analyst') '-Adopt 覆蓋了使用者的檔'
            Assert-True (Test-Path (Join-Path $t 'bdd-docs/.sdlc/installed-manifest.json')) '沒有建立基準線'
            $bl = Get-Content (Join-Path $t 'bdd-docs/.sdlc/installed-manifest.json') -Raw | ConvertFrom-Json
            Assert-True ([bool]$bl.adopted) '沒有記下這是接管來的'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '接管之後，使用者原本改過的檔在下一次升級才會被認出來' {
        # 接管把「現況」當原廠 —— 所以接管當下的修改不算「改過」（無從得知），
        # 但接管**之後**的修改就分得出來了。這正是這一步唯一買到的東西。
        $r1 = New-SdlcRelease 'r1-ad2' -Extra @('.codex/scripts/y.ps1'); $t = New-SdlcTarget 't-ad2'
        try {
            Copy-Item (Join-Path $r1 '.codex') $t -Recurse -Force
            Copy-Item (Join-Path $r1 'AGENTS.md') $t -Force
            Invoke-Sdlc install @{ Target = $t; Adopt = $true } | Out-Null
            New-SdlcFile (Join-Path $t '.codex/scripts/y.ps1') '# 接管之後改的'
            $r2 = New-SdlcRelease 'r2-ad2' -Version '4.7.0' -Extra @('.codex/scripts/y.ps1')
            $res = Invoke-Sdlc update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-Match 'y\.ps1' $res.stdout '接管之後的修改沒有被認出來'
            Assert-True (Test-Path (Join-Path $t 'bdd-docs/.sdlc/backup-4.6.0/.codex/scripts/y.ps1')) '沒有備份'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '目標沒有 .codex/ 時 -Adopt 要說清楚，不是安靜建一份空基準線' {
        $t = New-SdlcTarget 't-ad3'
        try {
            $r = Invoke-Sdlc install @{ Target = $t; Adopt = $true }
            Assert-Equal 2 $r.exit
            Assert-Match '需要目標已經有' $r.stderr
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / 更新來源跟著發佈物走' {

    # 寫死在腳本裡的話，換 repo 或第一次發佈忘了改，每個安裝出去的專案都會拿到一個
    # 指不到任何地方的網址 —— 而症狀是「沒有人告訴你有新版」，完全靜默。
    It-Should 'install 把發佈物版本檔的 source 寫進使用者的設定' {
        $rel = New-SdlcRelease 'r-src' -SourceUrl 'https://github.com/acme/flow'
        $t = New-SdlcTarget 't-src'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $c = Get-Content (Join-Path $t 'sdlc.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-Equal 'https://github.com/acme/flow' $c.update.source '來源沒有跟著發佈物走'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '發佈物沒設 source 時留空，而不是塞一個假網址' {
        $rel = New-SdlcRelease 'r-nosrc'; $t = New-SdlcTarget 't-nosrc'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $c = Get-Content (Join-Path $t 'sdlc.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-Equal '' $c.update.source '塞了一個指不到地方的預留位置'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'source 查不到時 check-update 靜默通過，不影響流程' {
        $rel = New-SdlcRelease 'r-chk'; $t = New-SdlcTarget 't-chk'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $r = Invoke-Sdlc check-update @{ Target = $t }
            Assert-Equal 0 $r.exit '查不到更新竟然變成錯誤 —— 那不是使用者要處理的事'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
