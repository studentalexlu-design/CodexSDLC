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
          [string]$SourceUrl = '', [string]$AgentBody = '', [switch]$WithVsix, [switch]$WithHooks, [switch]$WithSchema)
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
$AgentBody
'''
"@
    }
    foreach ($e in $Extra) { New-SdlcFile (Join-Path $root $e) "# $e`n" }
    if ($WithVsix)  { New-SdlcFile (Join-Path $root "editor/codex-sdlc-$Version.vsix") 'not really a vsix' }
    if ($WithHooks) { New-SdlcFile (Join-Path $root '.codex/hooks.json') '{ "hooks": {} }' }
    # set 靠 schema 驗值、靠 tuning-profiles 換預設組合 —— 用真的那兩份，測的才是會出貨的合法值。
    if ($WithSchema) {
        foreach ($f in @('sdlc.config.schema.json', 'rules.schema.json', 'tuning-profiles.json')) {
            Copy-Item ".codex/bdd-workflow/$f" (Join-Path $root ".codex/bdd-workflow/$f")
        }
    }
    return $root
}

# 形狀斷言：只看欄位名與型別，**不看任何句子**。改一句中文措辭不會紅；改欄位名一定紅。
# 這就是 -Json 合約的全部意義 —— 讀的人只准讀 data，所以測試也只准斷言 data。
function Assert-Shape {
    param($Obj, [hashtable]$Shape, [string]$At = '$')
    foreach ($k in $Shape.Keys) {
        $prop = if ($null -ne $Obj) { $Obj.PSObject.Properties[$k] } else { $null }
        if (-not $prop) { throw "缺欄位 $At.$k —— -Json 合約被改了（欄位改名要把 sdlc.ps1 的 `$JsonSchema 加一，並同步 extension）" }
        $v = $prop.Value; $want = $Shape[$k]
        if ($want -is [hashtable]) {
            if ($null -eq $v) { throw "$At.$k 是 null，應為物件" }
            Assert-Shape $v $want "$At.$k"; continue
        }
        $ok = switch ($want) {
            'string'  { $v -is [string] }
            'string?' { $null -eq $v -or $v -is [string] }
            'bool'    { $v -is [bool] }
            'int'     { $v -is [int] -or $v -is [long] }
            'array'   { $v -is [array] }
            'any'     { $true }
        }
        if (-not $ok) { throw "$At.$k 應為 $want，實際是 $(if ($null -eq $v) { 'null' } else { $v.GetType().Name })" }
    }
}

$EnvelopeShape = @{ schema = 'int'; command = 'string'; exit = 'int'; data = 'any'; warnings = 'array'; output = 'array' }

function Invoke-SdlcJson {
    param([string]$Cmd, [hashtable]$Params = @{}, [hashtable]$Env = @{}, [string[]]$Rest = @())
    $p = @{ Command = $Cmd; Json = $true }
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    $r = Invoke-Script $Sdlc -Params $p -Env $Env -Positional $Rest
    $j = $null
    try { $j = $r.stdout.Trim() | ConvertFrom-Json } catch { throw "-Json 輸出不是 JSON：$($r.stdout) / stderr: $($r.stderr)" }
    Assert-Shape $j $EnvelopeShape
    Assert-Equal 1 $j.schema '-Json 的 schema 版本變了 —— extension 會拒絕讀它'
    Assert-Equal $r.exit $j.exit 'JSON 裡的 exit 跟行程的 exit code 不一致'
    return $j
}

function New-SdlcTarget([string]$Name) {
    $p = Join-Path $SdlcRoot $Name
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Invoke-Sdlc {
    param([string]$Cmd, [hashtable]$Params = @{}, [string[]]$Rest = @())
    $p = @{ Command = $Cmd }
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    return Invoke-Script $Sdlc -Params $p -Positional $Rest
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

    It-Should '未知的 effort 值照寫但要喊（手改的人不擋在門口；擋的是 set）' {
        $rel = New-SdlcRelease 'r-unknown'; $t = New-SdlcTarget 't-unknown'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            # minimal：4.8 以前的清單裡有，Codex 0.154 的模型清單裡沒有 —— 舊設定檔裡留著的人要聽到這一句。
            Set-SdlcEffort $t 'sa-analyst' 'minimal'
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
    # 快取的 installed 必須是**現在**的版本 —— 對不上的快取是升級前留下來的，handoff-lint 刻意不喊。
    $CurVer = [string](Get-Content '.codex/bdd-workflow/bdd-workflow-version.json' -Raw -Encoding UTF8 | ConvertFrom-Json).'contract-version'

    function Set-UpdateCache([string]$json) {
        New-Item -ItemType Directory -Path 'bdd-docs/.sdlc' -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Get-Location) 'bdd-docs/.sdlc/update-cache.json'), $json, [Text.UTF8Encoding]::new($false))
    }

    It-Should '有新版時印一行，但**不阻斷** spawn' {
        Set-UpdateCache "{ `"newer`": true, `"latest`": `"99.0.0`", `"installed`": `"$CurVer`", `"seen`": `"`" }"
        try {
            $r = Invoke-Script $Hl -Stdin $Ok
            Assert-Equal 0 $r.exit '更新通知擋住了 spawn'
            Assert-Match '有新版 99\.0\.0' $r.stderr
        } finally { Remove-Item 'bdd-docs/.sdlc' -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '看過（seen == latest）就不再提醒' {
        Set-UpdateCache "{ `"newer`": true, `"latest`": `"99.0.0`", `"installed`": `"$CurVer`", `"seen`": `"99.0.0`" }"
        try {
            $r = Invoke-Script $Hl -Stdin $Ok
            Assert-Equal 0 $r.exit
            Assert-True ($r.stderr -notmatch '有新版') '看過之後還在每次 spawn 提醒'
        } finally { Remove-Item 'bdd-docs/.sdlc' -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '升級完、快取還沒刷新時不喊（它會說你還在舊版）' {
        # 快取記的是升級**前**查的：installed=舊版、latest=你剛升上去的那一版。
        # 照唸就是「有新版 X（你在 舊版）」—— 而你已經在 X 上。一個會說謊的通知比沒有更糟。
        Set-UpdateCache "{ `"newer`": true, `"latest`": `"$CurVer`", `"installed`": `"0.0.1`", `"seen`": `"`" }"
        try {
            $r = Invoke-Script $Hl -Stdin $Ok
            Assert-Equal 0 $r.exit
            Assert-True ($r.stderr -notmatch '有新版') '拿升級前的快取對已經升級完的專案喊有新版'
        } finally { Remove-Item 'bdd-docs/.sdlc' -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Codex 的 hook payload 下，通知走 additionalContext（exit 0 的 stderr 會被丟掉）' {
        Set-UpdateCache "{ `"newer`": true, `"latest`": `"99.0.0`", `"installed`": `"$CurVer`", `"seen`": `"`" }"
        try {
            $handoff = "## meta`n- feature-id: cancel-order`n- mode: analyze`n"
            $r = Invoke-Script $Hl -Stdin (New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ message = $handoff })
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-True ([bool]$r.stdout.Trim()) '只寫了 stderr —— Codex 0.154 會整段丟掉，orchestrator 永遠看不到'
            $ctx = ($r.stdout.Trim() | ConvertFrom-Json).hookSpecificOutput
            Assert-Equal 'PreToolUse' $ctx.hookEventName
            Assert-Match '有新版 99\.0\.0' $ctx.additionalContext
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

# 不碰這台機器上真正的東西：沒有 codex、編輯器家目錄指向 scratch。
function Get-IsolatedDoctorParams([string]$t) {
    return @{ Target = $t; CodexPath = (Join-Path $t 'no-such-codex.exe'); EditorHome = (Join-Path $SdlcRoot 'editor-home') }
}

Describe-Suite 'sdlc / -Json 是結構化合約（改措辭不紅、改欄位名必紅）' {

    # VS Code extension 只讀 data。它要是從 output 的中文句子裡撈狀態，改一句話就會讓它靜默地顯示錯的東西 ——
    # 所以下面每一條只斷言欄位名與型別，一個句子都不看。

    It-Should 'doctor 的 data 形狀' {
        $rel = New-SdlcRelease 'r-jd'; $t = New-SdlcTarget 't-jd'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Shape $j.data @{
                version    = @{ contract = 'string'; minCompatible = 'string' }
                config     = @{ exists = 'bool'; parsable = 'bool' }
                tuning     = @{ status = 'string'; stale = 'array' }
                unverifiedModel = 'array'
                baseline   = @{ exists = 'bool'; version = 'string?'; fileCount = 'int' }
                guidelines = 'array'
                lint       = @{ ran = 'bool'; passed = 'bool'; violations = 'array' }
                review     = @{ maxRounds = 'int'; source = 'string'; valid = 'bool' }
                hooks      = @{ status = 'string' }
                update     = @{ cached = 'bool'; stale = 'bool'; newer = 'bool'; latest = 'string?'; seen = 'bool'; checkedAt = 'any'; check = 'string' }
                editor     = @{ installed = 'array' }
                problems   = 'int'
            }
            Assert-Equal 'in-sync' $j.data.tuning.status
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '改了設定沒 apply → doctor 的 data.tuning 說 stale 並列出檔名（extension 的漂移顯示靠這個）' {
        $rel = New-SdlcRelease 'r-jst'; $t = New-SdlcTarget 't-jst'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            Set-SdlcEffort $t 'sa-analyst' 'high'
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 2 $j.exit
            Assert-Equal 'stale' $j.data.tuning.status
            Assert-Equal 'sa-analyst.toml' @($j.data.tuning.stale)[0]
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'install 的 data 形狀' {
        $rel = New-SdlcRelease 'r-ji'; $t = New-SdlcTarget 't-ji'
        try {
            $j = Invoke-SdlcJson install @{ Source = $rel; Target = $t }
            Assert-Shape $j.data @{
                mode = 'string'; target = 'string'; version = 'string'; written = 'int'; needsMerge = 'array'
                guidelinesSkeleton = 'bool'; config = @{ created = 'bool' }; tuning = @{ changed = 'array'; warnings = 'array' }
                guidelines = 'array'; lint = @{ passed = 'bool' }; hooksWritten = 'bool'; orchestratorHint = 'string?'
                editor = @{ requested = 'bool'; installed = 'bool' }
            }
            Assert-Equal 'install' $j.data.mode
            Assert-True $j.data.config.created
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'update 的 data 形狀' {
        $r1 = New-SdlcRelease 'r1-ju' -Extra @('.codex/scripts/a.ps1'); $t = New-SdlcTarget 't-ju'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $r2 = New-SdlcRelease 'r2-ju' -Version '4.7.0' -Extra @('.codex/scripts/a.ps1', '.codex/scripts/b.ps1')
            $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true; EditorHome = (Join-Path $SdlcRoot 'editor-home') }
            Assert-Shape $j.data @{
                from = 'string?'; to = 'string'; breaking = 'bool'; degraded = 'bool'
                unchanged = 'array'; modified = 'array'; added = 'array'; removed = 'array'; notes = 'array'; result = 'string'
                editor = @{ installed = 'array'; mismatch = 'bool' }
            }
            Assert-Equal 'applied' $j.data.result
            Assert-True ('.codex/scripts/b.ps1' -in @($j.data.added)) '新增的檔沒有出現在 data.added'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'apply／tune／whatsnew／check-update 的 data 形狀' {
        $rel = New-SdlcRelease 'r-jx'; $t = New-SdlcTarget 't-jx'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $a = Invoke-SdlcJson apply @{ Target = $t }
            Assert-Shape $a.data @{ changed = 'array'; warnings = 'array' }

            $tu = Invoke-SdlcJson tune @{ Target = $t }
            Assert-Shape $tu.data @{ signals = 'any'; proposal = 'array'; applied = 'bool' }
            Assert-Shape @($tu.data.proposal)[0] @{ agent = 'string'; current = 'string'; proposed = 'string'; reason = 'string'; signal = 'string' }

            $w = Invoke-SdlcJson whatsnew @{ Target = $t }
            Assert-Shape $w.data @{ source = 'string'; installed = 'string'; entries = 'array' }

            $c = Invoke-SdlcJson check-update @{ Target = $t }
            Assert-Shape $c.data @{ status = 'string'; installed = 'string' }
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / doctor 問 Codex：hooks 到底有沒有被信任' {

    # Codex（0.154.0 實測）要專案與每一條 hook 都被信任才會跑 hooks.json，沒信任時**一條都不跑、也不提示**。
    # 信任狀態只有 Codex 自己知道，所以 doctor 問它（app-server 的 hooks/list）。這裡用一支假的 codex 回答，
    # 順便記下它收到的 proxy 設定 —— doctor 啟動 app-server 時必須從構造上碰不到網路。

    $FakeCodexBody = @'
$log = $env:FAKE_CODEX_LOG
if ($log) { Add-Content $log "args=$($args -join ' ') HTTPS_PROXY=$env:HTTPS_PROXY" }
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $msg = $line | ConvertFrom-Json
    if (-not $msg.PSObject.Properties['id']) { continue }
    if ($msg.id -eq 1) { [Console]::Out.WriteLine('{"id":1,"result":{"userAgent":"fake"}}'); continue }
    if ($msg.id -ne 2) { continue }
    $cwd = @($msg.params.cwds)[0]
    $src = Join-Path $cwd '.codex\hooks.json'
    $trust = @($env:FAKE_TRUST -split ',' | Where-Object { $_ -and $_ -ne 'none' })
    $hooks = @(for ($i = 0; $i -lt $trust.Count; $i++) {
        [ordered]@{ key = "${src}:post_tool_use:${i}:0"; eventName = 'postToolUse'; sourcePath = $src; source = 'project'; enabled = $true; trustStatus = $trust[$i] }
    })
    [Console]::Out.WriteLine(([ordered]@{ id = 2; result = [ordered]@{ data = @([ordered]@{ cwd = $cwd; hooks = $hooks; warnings = @(); errors = @() }) } } | ConvertTo-Json -Depth 8 -Compress))
}
'@

    function New-FakeCodex([string]$dir) {
        New-SdlcFile (Join-Path $dir 'fake-codex.ps1') $FakeCodexBody
        $cmd = Join-Path $dir 'codex.cmd'
        [IO.File]::WriteAllText($cmd, "@pwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-codex.ps1`" %*`r`n", [Text.Encoding]::ASCII)
        return $cmd
    }

    function Invoke-TrustDoctor([string]$trust) {
        $rel = New-SdlcRelease 'r-ht' -WithHooks; $t = New-SdlcTarget 't-ht'
        Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
        $codex = New-FakeCodex (Join-Path $SdlcRoot 'fake')
        $log = Join-Path $SdlcRoot 'fake/calls.log'
        $p = Get-IsolatedDoctorParams $t
        $p.CodexPath = $codex
        $p.CheckHookTrust = $true            # 預設不查 —— 這一組測的就是「明講要查」的那條路
        $j = Invoke-SdlcJson doctor $p -Env @{ FAKE_TRUST = $trust; FAKE_CODEX_LOG = $log }
        return [pscustomobject]@{ json = $j; log = $(if (Test-Path $log) { Get-Content $log -Raw } else { '' }) }
    }

    It-Should '全部信任 → trusted，不算問題' {
        try {
            $r = Invoke-TrustDoctor 'trusted,trusted,trusted,trusted'
            Assert-Equal 'trusted' $r.json.data.hooks.status
            Assert-Equal 4 $r.json.data.hooks.counts.trusted
            Assert-Equal 0 $r.json.exit "warnings: $($r.json.warnings -join ' | ')"
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '有沒信任或改過待重審的 → untrusted，doctor 紅燈並說去哪裡按' {
        try {
            $r = Invoke-TrustDoctor 'trusted,untrusted,modified,trusted'
            Assert-Equal 'untrusted' $r.json.data.hooks.status
            Assert-Equal 1 $r.json.data.hooks.counts.untrusted
            Assert-Equal 1 $r.json.data.hooks.counts.modified
            Assert-Equal 2 $r.json.exit '強制層有一半沒在跑，doctor 卻是綠的'
            Assert-True ((@($r.json.warnings) -match 'Hooks need review').Count -gt 0) '沒有告訴使用者要去哪裡按信任'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'hooks.json 在、Codex 一條都沒列 → 專案本身沒被信任' {
        try {
            $r = Invoke-TrustDoctor 'none'
            Assert-Equal 'project-untrusted' $r.json.data.hooks.status
            Assert-Equal 2 $r.json.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '問 Codex 的時候 proxy 指向一個連不上的位址（doctor 從構造上碰不到網路）' {
        # 實測 app-server 一啟動就會去連 chatgpt.com 與 github.com。拿掉這個保護，
        # 「update.check = never」的使用者跑一次 doctor 就連網了，而且沒有人會知道。
        try {
            $r = Invoke-TrustDoctor 'trusted'
            Assert-Match 'args=app-server' $r.log '沒有用 app-server 問'
            Assert-Match 'HTTPS_PROXY=http://127\.0\.0\.1:9' $r.log '啟動 Codex 時沒有把網路擋掉'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-CheckHookTrust 但找不到 codex → unknown，不算問題（查不到不等於有問題，但要講出來）' {
        $rel = New-SdlcRelease 'r-hn' -WithHooks; $t = New-SdlcTarget 't-hn'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $p = Get-IsolatedDoctorParams $t
            $p.CheckHookTrust = $true
            $j = Invoke-SdlcJson doctor $p
            Assert-Equal 'unknown' $j.data.hooks.status
            Assert-Equal 'codex-not-found' $j.data.hooks.reason
            Assert-Equal 0 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'install 寫出 hooks.json 時記下來並提醒要去 Codex 信任' {
        $rel = New-SdlcRelease 'r-hw' -WithHooks; $t = New-SdlcTarget 't-hw'
        try {
            $j = Invoke-SdlcJson install @{ Source = $rel; Target = $t }
            Assert-True $j.data.hooksWritten 'hooks.json 寫出去了卻沒有記下來 —— 使用者不會知道要去信任'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 4.10.0 起**預設不查**：問它要另外叫起一個 codex（最久 15 秒），而修法永遠是同一句
    # 「去 codex 裡信任」—— doctor 幫不上忙。這三條守的是「預設真的沒查」與「沒查一定要講」，
    # 後者才是關鍵：不講的話「doctor 全綠」會被讀成「強制層在跑」，而那是這裡最貴的誤會。
    It-Should '預設不查：一次都不叫 codex，狀態是 skipped，不算問題' {
        $rel = New-SdlcRelease 'r-hs' -WithHooks; $t = New-SdlcTarget 't-hs'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $codex = New-FakeCodex (Join-Path $SdlcRoot 'fake')
            $log = Join-Path $SdlcRoot 'fake/calls.log'
            $p = Get-IsolatedDoctorParams $t
            $p.CodexPath = $codex
            $j = Invoke-SdlcJson doctor $p -Env @{ FAKE_TRUST = 'trusted'; FAKE_CODEX_LOG = $log }
            Assert-Equal 'skipped' $j.data.hooks.status
            Assert-Equal 0 $j.exit
            Assert-True (-not (Test-Path $log)) 'codex 被叫起來了 —— 預設應該連碰都不碰它'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒查的時候一定要說一句，而且說得出怎麼查' {
        $rel = New-SdlcRelease 'r-hs3' -WithHooks; $t = New-SdlcTarget 't-hs3'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            $said = @($j.output) -join "`n"
            Assert-Match '沒查' $said 'doctor 全綠卻沒說「信任狀態這次沒查」—— 使用者會以為強制層在跑'
            Assert-Match 'CheckHookTrust' $said '沒告訴他要怎麼查'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '預設不查也不會把「hooks.json 不見了」蓋掉（那是工具檔缺了，補得回來）' {
        $rel = New-SdlcRelease 'r-hs2'; $t = New-SdlcTarget 't-hs2'    # 這份發佈物沒有 hooks.json
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'no-hooks' $j.data.hooks.status
            Assert-Equal 2 $j.exit '強制層整層不存在，doctor 卻是綠的'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / fetch：在一個還沒裝工作流的資料夾裡也要找得到發佈物' {

    # extension 自己不碰網路（那條界線由它的測試守著），所以「去哪裡拿一份發佈物」只有這一份實作。
    # 這一組守的是三件會靜默出事的事：
    #   拿不到遠端就整個失敗   → 離線的人裝不起來，而這套 zip 從第一天就是離線可用的
    #   下載回來的東西不驗     → 壞掉的 payload 裝進專案，症狀落在使用者的流程裡
    #   同一版每次重新下載     → 第二個專案、第二台機器都要再等一次（而且離線就沒了）

    function New-PayloadZip([string]$release, [string]$zip) {
        $dir = Split-Path $zip -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $release '*') -DestinationPath $zip
    }

    It-Should '沒有設來源 → 用本機那一份，而且形狀是結構化合約' {
        $rel = New-SdlcRelease 'r-f1'; $t = New-SdlcTarget 't-f1'
        try {
            $j = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; CacheDir = (Join-Path $SdlcRoot 'cache') }
            Assert-Shape $j.data @{
                chosen = 'string'; version = 'string?'; path = 'string?'; cacheDir = 'string'
                remote = @{ checked = 'bool'; reachable = 'bool'; latest = 'string?'; url = 'string?'; reason = 'string?' }
                bundled = @{ version = 'string?'; path = 'string?' }
            }
            Assert-Equal 'bundled' $j.data.chosen
            Assert-Equal 'no-source' $j.data.remote.reason
            Assert-Equal $false $j.data.remote.checked '沒有來源卻連了網'
            Assert-Equal 0 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '來源連不上 → 靜默退回本機那一份，不擋安裝' {
        # 離線是常態，不是錯誤。遠端拿不到就讓他用手上這一份裝起來。
        $rel = New-SdlcRelease 'r-f2' -SourceUrl 'https://github.com/codex-sdlc-no-such-owner/no-such-repo'
        $t = New-SdlcTarget 't-f2'
        try {
            $j = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; CacheDir = (Join-Path $SdlcRoot 'cache') }
            Assert-Equal 'bundled' $j.data.chosen
            Assert-True ($j.data.remote.checked) '有設來源卻沒去查'
            Assert-Equal $false $j.data.remote.reachable
            Assert-Equal 0 $j.exit '拿不到遠端不該擋住安裝'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-NoRemote → 一條連線都不開' {
        $rel = New-SdlcRelease 'r-f3' -SourceUrl 'https://github.com/codex-sdlc-no-such-owner/no-such-repo'
        $t = New-SdlcTarget 't-f3'
        try {
            $j = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; NoRemote = $true; CacheDir = (Join-Path $SdlcRoot 'cache') }
            Assert-Equal 'skipped' $j.data.remote.reason
            Assert-Equal $false $j.data.remote.checked
            Assert-Equal 'bundled' $j.data.chosen
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '指一個 .zip → 解壓進快取、驗過才交出去（使用者自己從發佈頁抓的那一份）' {
        $rel = New-SdlcRelease 'r-f4' -Version '4.6.0'; $t = New-SdlcTarget 't-f4'
        $cache = Join-Path $SdlcRoot 'cache'
        $zip = Join-Path $SdlcRoot 'dl/codex-sdlc-4.6.0.zip'
        try {
            New-PayloadZip $rel $zip
            $j = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; NoRemote = $true; Bundled = $zip; CacheDir = $cache }
            Assert-Equal 'bundled' $j.data.chosen
            Assert-Equal '4.6.0' $j.data.version
            Assert-Match '4\.6\.0$' $j.data.path '解出來的東西沒有照版本放進快取'
            Assert-True (Test-Path (Join-Path $cache '4.6.0/.codex/agents')) '解出來的不是一份能用的發佈物'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'manifest 對不上的發佈物 → 不採用（壞掉的 payload 裝進去，症狀是靜默的）' {
        $rel = New-SdlcRelease 'r-f5'; $t = New-SdlcTarget 't-f5'
        try {
            # 發佈物自己的 manifest：列一個檔的 sha，然後把那個檔改掉。
            $agent = Join-Path $rel '.codex/agents/sa-analyst.toml'
            $sha = (Get-FileHash $agent -Algorithm SHA256).Hash.ToLowerInvariant()
            New-SdlcFile (Join-Path $rel '.codex/bdd-workflow/manifest.json') `
                "{ `"contract-version`": `"4.6.0`", `"files`": { `".codex/agents/sa-analyst.toml`": `"$sha`" } }"
            $ok = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; NoRemote = $true; CacheDir = (Join-Path $SdlcRoot 'cache') }
            Assert-Equal 'bundled' $ok.data.chosen '原樣的發佈物應該驗得過'

            [IO.File]::AppendAllText($agent, "`n# 被動過了`n")
            $bad = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; NoRemote = $true; CacheDir = (Join-Path $SdlcRoot 'cache') }
            Assert-Equal 'none' $bad.data.chosen 'manifest 對不上還是拿去裝了'
            Assert-Equal 2 $bad.exit
            Assert-True ((@($bad.warnings) -match 'manifest').Count -gt 0) '沒說是哪裡不對'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '一份都找不到 → 明講（exit 2），不給一個空路徑讓呼叫端拿去裝' {
        $rel = New-SdlcRelease 'r-f6'; $t = New-SdlcTarget 't-f6'
        try {
            $j = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; NoRemote = $true; Bundled = ''; CacheDir = (Join-Path $SdlcRoot 'cache') }
            Assert-Equal 'none' $j.data.chosen
            Assert-Equal $null $j.data.path
            Assert-Equal 2 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / guidelines 檢查只讀「專案規範」那一節' {

    It-Should '### 層級的專案規範一節，不會一路讀進下一節' {
        # 回歸：sa-analyst 的「專案規範」是 ###，舊版只停在下一個 ##，於是讀進「精度是事實」那一節的 spec.md，
        # 每一次 install／update／doctor 都報「你缺 spec.md」，doctor 永遠是紅的。
        $body = "## 分析`n`n### 專案規範會刪掉做法`n`n讀 ``api.md``。`n`n### 精度是事實`n`n``spec.md`` 已經談定。`n"
        $rel = New-SdlcRelease 'r-gs' -AgentBody $body; $t = New-SdlcTarget 't-gs'
        New-SdlcFile (Join-Path $t 'guidelines/api.md') "## MUST`n- x`n"
        try {
            $j = Invoke-SdlcJson install @{ Source = $rel; Target = $t }
            $missing = @($j.data.guidelines | Where-Object code -eq 'missing')
            Assert-Equal 0 $missing.Count "把別的章節的檔名當成規範了：$(@($missing | ForEach-Object text) -join ' ')"
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '真的缺規範檔時照樣報（證明上一條不是把檢查整個關掉）' {
        $body = "### 專案規範`n`n讀 ``api.md`` 與 ``sql.md``。`n"
        $rel = New-SdlcRelease 'r-gm' -AgentBody $body; $t = New-SdlcTarget 't-gm'
        New-SdlcFile (Join-Path $t 'guidelines/api.md') "## MUST`n- x`n"
        try {
            $j = Invoke-SdlcJson install @{ Source = $rel; Target = $t }
            $missing = @($j.data.guidelines | Where-Object code -eq 'missing')
            Assert-Equal 1 $missing.Count
            Assert-Match 'sql\.md' $missing[0].text
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / check-update 的頻率與網路' {

    # 一個一定回 403 的假 proxy。子行程的 HTTPS_PROXY 指向它，連線企圖就一條不漏地記下來 ——
    # 「update.check = never 完全不碰網路」只有這樣驗得出來（計畫裡寫的是「用防火牆驗」）。
    function Start-ProxyTrap {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $log = Join-Path ([IO.Path]::GetTempPath()) "codex-sdlc-proxytrap-$port.log"
        Remove-Item $log -ErrorAction SilentlyContinue
        $job = Start-ThreadJob -ArgumentList $listener, $log -ScriptBlock {
            param($listener, $log)
            while ($true) {
                try { $c = $listener.AcceptTcpClient() } catch { break }
                try {
                    $s = $c.GetStream(); $buf = [byte[]]::new(2048); $n = $s.Read($buf, 0, $buf.Length)
                    [IO.File]::AppendAllText($log, (([Text.Encoding]::ASCII.GetString($buf, 0, $n)) -split "`r`n")[0] + "`n")
                    $resp = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 403 Forbidden`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $s.Write($resp, 0, $resp.Length)
                } catch { } finally { $c.Close() }
            }
        }
        $url = "http://127.0.0.1:$port"
        return [pscustomobject]@{ listener = $listener; job = $job; log = $log; env = @{ HTTPS_PROXY = $url; HTTP_PROXY = $url; ALL_PROXY = $url } }
    }
    function Stop-ProxyTrap($trap) {
        $trap.listener.Stop()
        $null = Wait-Job $trap.job -Timeout 5
        Remove-Job $trap.job -Force -ErrorAction SilentlyContinue
        $lines = @(if (Test-Path $trap.log) { Get-Content $trap.log })
        Remove-Item $trap.log -ErrorAction SilentlyContinue
        return $lines
    }
    function New-CheckTarget([string]$check) {
        $rel = New-SdlcRelease 'r-cu' -SourceUrl 'https://github.com/acme/flow'; $t = New-SdlcTarget 't-cu'
        Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
        $p = Join-Path $t 'sdlc.config.json'
        $c = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $c.update.check = $check
        [IO.File]::WriteAllText($p, ($c | ConvertTo-Json -Depth 8), $Utf8)
        return $t
    }

    It-Should '對照組：daily 而且沒有快取 → 真的去連（證明陷阱抓得到連線）' {
        $t = New-CheckTarget 'daily'; $trap = Start-ProxyTrap
        try {
            $j = Invoke-SdlcJson check-update @{ Target = $t; IfDue = $true } -Env $trap.env
            $seen = Stop-ProxyTrap $trap; $trap = $null
            Assert-Equal 'unreachable' $j.data.status
            Assert-Match 'CONNECT api\.github\.com' ($seen -join "`n") '對照組沒有連線 —— 下面「never 不連網」那條就證明不了任何事'
        } finally { if ($trap) { Stop-ProxyTrap $trap | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'update.check = never → 一條連線都沒有' {
        $t = New-CheckTarget 'never'; $trap = Start-ProxyTrap
        try {
            $j = Invoke-SdlcJson check-update @{ Target = $t; IfDue = $true } -Env $trap.env
            $seen = Stop-ProxyTrap $trap; $trap = $null
            Assert-Equal 'disabled' $j.data.status
            Assert-Equal 0 $seen.Count "設定 never 卻連網了：$($seen -join ' | ')"
        } finally { if ($trap) { Stop-ProxyTrap $trap | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-IfDue：一天內查過就不連網' {
        $t = New-CheckTarget 'daily'; $trap = Start-ProxyTrap
        try {
            $cur = (Get-Content (Join-Path $t '.codex/bdd-workflow/bdd-workflow-version.json') -Raw | ConvertFrom-Json).'contract-version'
            New-SdlcFile (Join-Path $t 'bdd-docs/.sdlc/update-cache.json') "{ `"checked-at`": `"$((Get-Date).ToString('o'))`", `"installed`": `"$cur`", `"latest`": `"$cur`", `"newer`": false, `"seen`": `"`" }"
            $j = Invoke-SdlcJson check-update @{ Target = $t; IfDue = $true } -Env $trap.env
            $seen = Stop-ProxyTrap $trap; $trap = $null
            Assert-Equal 'not-due' $j.data.status
            Assert-Equal 0 $seen.Count 'daily 的快取還新鮮卻又連網了 —— 每開一次視窗就打一次 API'
        } finally { if ($trap) { Stop-ProxyTrap $trap | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-IfDue：快取是升級前留下的（installed 對不上）→ 視為到期' {
        $t = New-CheckTarget 'daily'; $trap = Start-ProxyTrap
        try {
            New-SdlcFile (Join-Path $t 'bdd-docs/.sdlc/update-cache.json') "{ `"checked-at`": `"$((Get-Date).ToString('o'))`", `"installed`": `"0.0.1`", `"latest`": `"4.6.0`", `"newer`": true, `"seen`": `"`" }"
            Invoke-SdlcJson check-update @{ Target = $t; IfDue = $true } -Env $trap.env | Out-Null
            $seen = Stop-ProxyTrap $trap; $trap = $null
            Assert-True ($seen.Count -gt 0) '拿升級前的快取當作「今天查過了」'
        } finally { if ($trap) { Stop-ProxyTrap $trap | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-IfDue：離線查失敗後一小時內不重試' {
        $t = New-CheckTarget 'daily'; $trap = Start-ProxyTrap
        try {
            Invoke-SdlcJson check-update @{ Target = $t; IfDue = $true } -Env $trap.env | Out-Null
            $j2 = Invoke-SdlcJson check-update @{ Target = $t; IfDue = $true } -Env $trap.env
            $seen = Stop-ProxyTrap $trap; $trap = $null
            Assert-Equal 'not-due' $j2.data.status '離線的人每開一次視窗就等一次逾時'
            Assert-Equal 1 @($seen | Where-Object { $_ -match 'CONNECT' }).Count
        } finally { if ($trap) { Stop-ProxyTrap $trap | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / VS Code extension（每台機器一份，不屬於任何專案）' {

    # 測試絕不碰這台機器上真正的編輯器：PATH 只放一支假的 code.cmd，編輯器家目錄指向 scratch。
    function New-FakeEditorCli([string]$dir) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'code.cmd'), "@echo %* >> `"%~dp0code.calls`"`r`n@exit /b 0`r`n", [Text.Encoding]::ASCII)
        return (Join-Path $dir 'code.calls')
    }
    function Get-IsolatedPath([string]$extra) {
        return (@($extra, (Split-Path ([Environment]::ProcessPath) -Parent), [Environment]::SystemDirectory) | Where-Object { $_ }) -join ';'
    }
    function New-InstalledExtension([string]$editorHome, [string]$version, [int]$schema = 1) {
        $dirName = "codex-sdlc.codex-sdlc-$version"
        New-SdlcFile (Join-Path $editorHome ".vscode/extensions/$dirName/package.json") "{ `"name`": `"codex-sdlc`", `"version`": `"$version`", `"codexSdlc`": { `"jsonSchema`": $schema } }"
        New-SdlcFile (Join-Path $editorHome '.vscode/extensions/extensions.json') "[ { `"identifier`": { `"id`": `"codex-sdlc.codex-sdlc`" }, `"version`": `"$version`", `"relativeLocation`": `"$dirName`" } ]"
    }

    It-Should '沒給 -WithEditor：一行提示，不動編輯器' {
        $rel = New-SdlcRelease 'r-e1' -WithVsix; $t = New-SdlcTarget 't-e1'
        $calls = New-FakeEditorCli (Join-Path $SdlcRoot 'bin')
        try {
            $j = Invoke-SdlcJson install @{ Source = $rel; Target = $t; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env @{ PATH = (Get-IsolatedPath (Join-Path $SdlcRoot 'bin')) }
            Assert-True (-not $j.data.editor.requested)
            Assert-True (-not (Test-Path $calls)) '沒有明確同意就動了使用者的編輯器'
            Assert-Match 'codex-sdlc-4\.6\.0\.vsix' ([string]$j.data.editor.vsix)
            # 那一行排在「裝好了」後面；不明講沒裝，使用者會以為 extension 也裝好了。
            Assert-Match '沒有裝' (@($j.output) -join "`n") '沒加 -WithEditor 卻沒說 extension 沒裝'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-WithEditor：用找得到的編輯器指令裝，而且 vsix 不進基準線、不進專案' {
        $rel = New-SdlcRelease 'r-e2' -WithVsix; $t = New-SdlcTarget 't-e2'
        $calls = New-FakeEditorCli (Join-Path $SdlcRoot 'bin')
        try {
            $j = Invoke-SdlcJson install @{ Source = $rel; Target = $t; WithEditor = $true; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env @{ PATH = (Get-IsolatedPath (Join-Path $SdlcRoot 'bin')) }
            Assert-Equal 0 $j.exit "warnings: $($j.warnings -join ' | ')"
            Assert-True $j.data.editor.installed
            Assert-Match '--install-extension .*codex-sdlc-4\.6\.0\.vsix --force' (Get-Content $calls -Raw)
            $bl = Get-Content (Join-Path $t 'bdd-docs/.sdlc/installed-manifest.json') -Raw | ConvertFrom-Json
            Assert-Equal 0 @($bl.files.PSObject.Properties.Name | Where-Object { $_ -match 'vsix|^editor/' }).Count 'vsix 進了基準線 —— 它不是這個專案的檔'
            Assert-True (-not (Test-Path (Join-Path $t 'editor'))) 'vsix 被複製進專案了'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-WithEditor 但找不到任何編輯器指令：說怎麼手動裝，工作流照常裝好（不丟例外）' {
        $rel = New-SdlcRelease 'r-e3' -WithVsix; $t = New-SdlcTarget 't-e3'
        try {
            $r = Invoke-Script $Sdlc -Params @{ Command = 'install'; Source = $rel; Target = $t; WithEditor = $true; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env @{ PATH = (Get-IsolatedPath '') }
            Assert-Equal 0 $r.exit "擋下的理由跟他要做的事無關，而且他修不了；stderr: $($r.stderr)"
            Assert-Match 'Install from VSIX' $r.stderr
            Assert-True (Test-Path (Join-Path $t 'AGENTS.md')) '工作流本身沒裝好'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'update 不替你重裝 extension，版本對不上只說一行' {
        $r1 = New-SdlcRelease 'r1-e4'; $t = New-SdlcTarget 't-e4'
        $eh = Join-Path $SdlcRoot 'editor-home'
        $calls = New-FakeEditorCli (Join-Path $SdlcRoot 'bin')
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            New-InstalledExtension $eh '4.6.0'
            $r2 = New-SdlcRelease 'r2-e4' -Version '4.7.0' -WithVsix
            $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true; EditorHome = $eh } -Env @{ PATH = (Get-IsolatedPath (Join-Path $SdlcRoot 'bin')) }
            Assert-True $j.data.editor.mismatch '裝的是舊版 extension 卻沒有說'
            Assert-True (-not (Test-Path $calls)) '一個專案的升級動到了整台機器共用的編輯器'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'doctor 用 extension 宣告的 -Json 形狀判斷相容，而且不算專案的問題' {
        # 帶 hooks.json：這兩條量的是「編輯器那一層不該讓 doctor 紅」，缺工具檔是另一回事（它現在會紅，見「檔不在的時候」）。
        $rel = New-SdlcRelease 'r-e5' -WithHooks; $t = New-SdlcTarget 't-e5'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $p = Get-IsolatedDoctorParams $t
            New-InstalledExtension $p.EditorHome '9.9.9' -schema 99
            $j = Invoke-SdlcJson doctor $p
            $x = @($j.data.editor.installed)[0]
            Assert-Equal '9.9.9' $x.version
            Assert-True (-not $x.compatible) '形狀對不上卻說相容'
            Assert-Equal 0 $j.exit '編輯器那一層不是這個專案的健康狀態，不該讓 doctor 紅'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'doctor：這台機器沒裝 extension 也說一行，但不算問題' {
        $rel = New-SdlcRelease 'r-e6' -WithHooks; $t = New-SdlcTarget 't-e6'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 0 @($j.data.editor.installed).Count
            Assert-Match 'VS Code extension：這台機器沒裝' (@($j.output) -join "`n") '在 VS Code 裡找不到介面的人跑 doctor，卻沒人告訴他 extension 沒裝'
            Assert-Equal 0 $j.exit '選用的東西沒裝，不該讓 doctor 紅'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / 修正輪上限（review.maxRounds）' {

    function Get-Cfg([string]$t) { return Get-Content (Join-Path $t 'sdlc.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
    function Set-Cfg([string]$t, $cfg) { [IO.File]::WriteAllText((Join-Path $t 'sdlc.config.json'), ($cfg | ConvertTo-Json -Depth 8), $Utf8) }

    It-Should 'install 寫入的預設值，就是 handoff-lint 在沒有設定時用的值' {
        # 兩處各寫一次「3」。設定檔寫 3、hook 預設卻是別的數字的話，刪掉那一行就會悄悄改變行為。
        $rel = New-SdlcRelease 'r-rv1'; $t = New-SdlcTarget 't-rv1'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $written = (Get-Cfg $t).review.maxRounds
            Assert-Equal 3 $written 'install 沒有寫出 review.maxRounds = 3'
            $hook = (Invoke-Script '.codex/scripts/handoff-lint.ps1' -Stdin "## meta`n- feature-id: f`n- mode: analyze`n" -Params @{ ConfigFile = 'no-such-config.json'; Json = $true }).stdout | ConvertFrom-Json
            Assert-Equal $written $hook.max_review_rounds 'install 的預設值跟 handoff-lint 的預設值分岔了'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'update 替沒有 review 的舊設定檔補上 3，其他值一個字不動' {
        $r1 = New-SdlcRelease 'r1-rv2'; $t = New-SdlcTarget 't-rv2'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $cfg = Get-Cfg $t
            $cfg.PSObject.Properties.Remove('review')
            $cfg.agents.'sa-analyst'.effort = 'medium'
            Set-Cfg $t $cfg
            $r2 = New-SdlcRelease 'r2-rv2' -Version '4.7.0' -Extra @('.codex/scripts/new.ps1')
            $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true; EditorHome = (Join-Path $SdlcRoot 'editor-home') }
            Assert-True $j.data.reviewAdded 'data 沒記下補了 review'
            $after = Get-Cfg $t
            Assert-Equal 3 $after.review.maxRounds
            Assert-Equal 'medium' $after.agents.'sa-analyst'.effort '補 review 的時候動到了使用者的其他設定'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '已經有 review 的設定檔，update 不碰它' {
        $r1 = New-SdlcRelease 'r1-rv3'; $t = New-SdlcTarget 't-rv3'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $cfg = Get-Cfg $t; $cfg.review.maxRounds = 5; Set-Cfg $t $cfg
            $r2 = New-SdlcRelease 'r2-rv3' -Version '4.7.0' -Extra @('.codex/scripts/new.ps1')
            $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true; EditorHome = (Join-Path $SdlcRoot 'editor-home') }
            Assert-True (-not $j.data.reviewAdded)
            Assert-Equal 5 (Get-Cfg $t).review.maxRounds '升級把使用者設的上限蓋回預設了'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'doctor 顯示實際生效的上限；寫壞時照 agent-lint 的結論退回 3' {
        $rel = New-SdlcRelease 'r-rv4'; $t = New-SdlcTarget 't-rv4'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            # 範圍由 agent-lint 檢查 13 判（doctor 不寫第三份規則），所以這裡要有真的 agent-lint。
            New-Item -ItemType Directory -Path (Join-Path $t '.codex/scripts') -Force | Out-Null
            Copy-Item '.codex/scripts/agent-lint.ps1' (Join-Path $t '.codex/scripts/agent-lint.ps1') -Force

            $cfg = Get-Cfg $t; $cfg.review.maxRounds = 5; Set-Cfg $t $cfg
            $ok = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 5 $ok.data.review.maxRounds
            Assert-Equal 'config' $ok.data.review.source
            Assert-True $ok.data.review.valid

            $cfg.review.maxRounds = 7; Set-Cfg $t $cfg
            $bad = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-True (-not $bad.data.review.valid) '寫壞的上限被當成合法'
            Assert-Equal 3 $bad.data.review.maxRounds 'doctor 顯示的上限跟 hook 實際用的不一樣'
            Assert-Equal 'default' $bad.data.review.source
            Assert-Equal 2 $bad.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / schema：編輯器與 set 的單一來源' {

    It-Should 'install 寫出 $schema（放第一個），不再寫沒人讀的 update.channel' {
        $rel = New-SdlcRelease 'r-sc1' -WithSchema; $t = New-SdlcTarget 't-sc1'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $cfg = Get-Content (Join-Path $t 'sdlc.config.json') -Raw | ConvertFrom-Json
            Assert-Equal '$schema' @($cfg.PSObject.Properties.Name)[0] '編輯器只看 $schema；放第一個是給人看的'
            Assert-Equal './.codex/bdd-workflow/sdlc.config.schema.json' $cfg.'$schema'
            Assert-True (Test-Path (Join-Path $t '.codex/bdd-workflow/sdlc.config.schema.json')) '$schema 指向的檔沒有被裝進去 —— 編輯器找不到它，也不會說'
            Assert-True (-not $cfg.update.PSObject.Properties['channel']) 'update.channel 沒有任何一方讀，新裝的不該再寫'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'update 替舊設定檔補上 $schema，其餘值一個字不動' {
        $r1 = New-SdlcRelease 'r1-sc2' -Version '4.8.0'; $t = New-SdlcTarget 't-sc2'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            # 4.8 的設定檔長這樣：沒有 $schema，有 channel。
            $p = Join-Path $t 'sdlc.config.json'
            $old = Get-Content $p -Raw | ConvertFrom-Json
            $old.PSObject.Properties.Remove('$schema')
            $old.update | Add-Member -NotePropertyName channel -NotePropertyValue 'stable' -Force
            $old.agents.'sa-analyst'.effort = 'low'
            [IO.File]::WriteAllText($p, ($old | ConvertTo-Json -Depth 8), $Utf8)

            $r2 = New-SdlcRelease 'r2-sc2' -Version '4.9.0' -WithSchema
            $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-True $j.data.schemaAdded
            $cfg = Get-Content $p -Raw | ConvertFrom-Json
            Assert-Equal '$schema' @($cfg.PSObject.Properties.Name)[0]
            Assert-Equal 'low' $cfg.agents.'sa-analyst'.effort '升級動到了使用者的值'
            Assert-Equal 'stable' $cfg.update.channel '升級不刪使用者檔裡的 key（棄用的也一樣）'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'update 遇到有註解的設定檔：先備份原檔、再說一聲' {
        $r1 = New-SdlcRelease 'r1-sc3' -Version '4.8.0'; $t = New-SdlcTarget 't-sc3'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $p = Join-Path $t 'sdlc.config.json'
            $text = [IO.File]::ReadAllText($p) -replace '^\{', "{`n  // 團隊約定：reviewer 固定 high"
            [IO.File]::WriteAllText($p, $text, $Utf8)
            $r2 = New-SdlcRelease 'r2-sc3' -Version '4.9.0' -WithSchema
            $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true }
            Assert-True ($null -ne $j.data.configCommentsBackup) '註解被吃掉卻沒有備份'
            Assert-Match '團隊約定' ([IO.File]::ReadAllText((Join-Path $t $j.data.configCommentsBackup))) '備份的不是原檔'
            Assert-Match '註解' ($j.warnings -join "`n") '註解被吃掉卻沒說'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'check-update：update.check 打錯字要講（照 daily 算，會連網）' {
        $rel = New-SdlcRelease 'r-sc4'; $t = New-SdlcTarget 't-sc4'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $p = Join-Path $t 'sdlc.config.json'
            $cfg = Get-Content $p -Raw | ConvertFrom-Json
            $cfg.update.check = 'nevr'
            [IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 8), $Utf8)
            $j = Invoke-SdlcJson check-update @{ Target = $t }
            Assert-Match 'nevr' ($j.warnings -join "`n") '以為關掉了其實照樣連網，卻沒有人說'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'doctor 回報設定檔裡有沒有註解（不算問題）' {
        $rel = New-SdlcRelease 'r-sc5' -WithSchema; $t = New-SdlcTarget 't-sc5'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $p = Join-Path $t 'sdlc.config.json'
            $j0 = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-True (-not $j0.data.config.comments)
            Assert-True $j0.data.config.schemaRef
            [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '^\{', '{ /* note */'), $Utf8)
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-True $j.data.config.comments
            Assert-Equal $j0.data.problems $j.data.problems '註解本身不是問題，不該讓 doctor 多紅一項'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / set：改設定的單一入口（先驗完才寫）' {

    function New-SetTarget([string]$name) {
        $rel = New-SdlcRelease "r-$name" -Agents @('sa-analyst', 'implementer', 'reviewer') -WithSchema
        $t = New-SdlcTarget "t-$name"
        Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
        return $t
    }
    function Get-ConfigText([string]$t) { [IO.File]::ReadAllText((Join-Path $t 'sdlc.config.json')) }
    function Get-Config([string]$t) { Get-ConfigText $t | ConvertFrom-Json }

    It-Should '一組錯、一組對 → 檔案位元組不變，錯的那組附上建議' {
        $t = New-SetTarget 's1'
        try {
            $before = Get-ConfigText $t
            $j = Invoke-SdlcJson set @{ Target = $t } -Rest @('review.maxRounds=4', 'agents.reviewer.effort=hgih')
            Assert-Equal 2 $j.exit
            Assert-Equal 'invalid' $j.data.error
            Assert-Equal $before (Get-ConfigText $t) '有一組不合法卻寫了另一組 —— 使用者會以為兩個都沒生效，其實一半生效了'
            $e = @($j.data.errors)[0]
            Assert-Equal 'agents.reviewer.effort' $e.key
            Assert-Equal 'agents.reviewer.effort=high' $e.suggestion
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '打錯 key、打錯 agent 名、大小寫不對 → 不寫，提示最接近的那個' {
        $t = New-SetTarget 's2'
        try {
            $j = Invoke-SdlcJson set @{ Target = $t } -Rest @('review.maxRound=4', 'agents.reveiwer.effort=high', 'Review.maxRounds=2')
            Assert-Equal 2 $j.exit
            $byKey = @{}; foreach ($e in @($j.data.errors)) { $byKey[$e.key] = $e }
            Assert-Equal 'review.maxRounds' $byKey['review.maxRound'].suggestion '打錯的 key 會被寫成一個沒有人讀的設定'
            Assert-Equal 'agents.reviewer.effort' $byKey['agents.reveiwer.effort'].suggestion
            Assert-True ($byKey.ContainsKey('Review.maxRounds')) '大小寫不同的 key 在 JSON 裡是另一個 key，不能照收'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '範圍外、型別錯、格式錯、已棄用、由工具維護的 key → 一律擋' {
        $t = New-SetTarget 's3'
        try {
            foreach ($bad in @('review.maxRounds=6', 'review.maxRounds=three', 'update.source=https://gitlab.com/o/r',
                               'update.check=weekly', 'update.channel=beta', 'workflow-version=9.9.9', 'agents.reviewer.model=gpt 5',
                               'agents.reviewer.effort=minimal')) {
                $j = Invoke-SdlcJson set @{ Target = $t } -Rest @($bad)
                Assert-Equal 2 $j.exit "$bad 竟然被收了"
            }
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '合法的值：寫進去、整數存成整數、-Apply 只套用一次，每一項說清楚要不要 apply' {
        $t = New-SetTarget 's4'
        try {
            $j = Invoke-SdlcJson set @{ Target = $t; Apply = $true } -Rest @('agents.reviewer.effort=high', 'agents.sa-analyst.effort=low', 'review.maxRounds=4', 'update.source=https://github.com/o/r')
            Assert-Equal 0 $j.exit "warnings: $($j.warnings -join ' | ')"
            Assert-Shape $j.data @{ changes = 'array'; errors = 'array'; written = 'bool'; applied = 'bool'; preview = 'bool'; backup = 'string?' }
            Assert-True $j.data.written
            Assert-True $j.data.applied
            Assert-Equal 2 @($j.data.changed).Count 'apply 應該在同一次呼叫裡把兩個 agent 一起套掉'
            $cfg = Get-Config $t
            Assert-True ($cfg.review.maxRounds -is [long] -or $cfg.review.maxRounds -is [int]) 'review.maxRounds 被寫成字串 —— handoff-lint 不採用，設定等於沒生效'
            Assert-Equal 4 $cfg.review.maxRounds
            Assert-Match 'model_reasoning_effort = "high"' (Get-Toml $t 'reviewer')
            $c = @($j.data.changes | Where-Object key -eq 'review.maxRounds')[0]
            Assert-True (-not $c.needsApply) '修正輪是 hook 現讀的，不該叫人 apply'
            $a = @($j.data.changes | Where-Object key -eq 'agents.reviewer.effort')[0]
            Assert-True $a.needsApply
            $dj = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'in-sync' $dj.data.tuning.status 'set -Apply 之後調校區塊應該跟設定檔一致'
            # 網址裡的 // 不是註解：來源設好之後，下一次 set 不該被當成「有註解」擋下來。
            Assert-True (-not $dj.data.config.comments) '把 update.source 網址裡的 // 當成註解了'
            Assert-Equal 0 (Invoke-SdlcJson set @{ Target = $t } -Rest @('update.check=never')).exit '來源設成網址之後，set 就再也寫不進去了'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '值跟現在一樣 → 不寫檔；沒加 -Apply → 留在未套用狀態' {
        $t = New-SetTarget 's5'
        try {
            $before = Get-ConfigText $t
            $j = Invoke-SdlcJson set @{ Target = $t } -Rest @('review.maxRounds=3')
            Assert-Equal 0 $j.exit
            Assert-True (-not $j.data.written)
            Assert-Equal $before (Get-ConfigText $t)
            $j2 = Invoke-SdlcJson set @{ Target = $t } -Rest @('agents.implementer.effort=medium')
            Assert-True $j2.data.written
            Assert-True (-not $j2.data.applied)
            Assert-Equal 'stale' (Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)).data.tuning.status '沒 apply 就該是漂移狀態 —— 設定面板靠這個標「未套用」'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '設定檔有註解：沒同意就不寫；-Yes 先備份再寫' {
        $t = New-SetTarget 's6'
        try {
            $p = Join-Path $t 'sdlc.config.json'
            [IO.File]::WriteAllText($p, ((Get-ConfigText $t) -replace '^\{', "{`n  // 我們的約定"), $Utf8)
            $before = Get-ConfigText $t
            $j = Invoke-SdlcJson set @{ Target = $t } -Rest @('update.check=never')
            Assert-Equal 2 $j.exit
            Assert-Equal 'has-comments' $j.data.error
            Assert-Equal $before (Get-ConfigText $t) '沒同意就把註解吃掉了'
            $j2 = Invoke-SdlcJson set @{ Target = $t; Yes = $true } -Rest @('update.check=never')
            Assert-Equal 0 $j2.exit
            Assert-Match '我們的約定' ([IO.File]::ReadAllText((Join-Path $t $j2.data.backup)))
            Assert-Equal 'never' (Get-Config $t).update.check
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-Preset -Preview 只列差異不寫；-Preset -Yes 才寫；後面指定的值蓋過預設組合' {
        $t = New-SetTarget 's7'
        try {
            $before = Get-ConfigText $t
            $pv = Invoke-SdlcJson set @{ Target = $t; Preset = 'deep'; Preview = $true }
            Assert-Equal 0 $pv.exit
            Assert-True $pv.data.preview
            Assert-Equal $before (Get-ConfigText $t) '預覽寫了檔'
            Assert-True (@($pv.data.changes | Where-Object { $_.changed }).Count -gt 0)
            $no = Invoke-SdlcJson set @{ Target = $t; Preset = 'deep' }
            Assert-Equal 2 $no.exit '非互動又沒有 -Yes，一次換掉一整組不該默默發生'
            Assert-Equal $before (Get-ConfigText $t)
            $ok = Invoke-SdlcJson set @{ Target = $t; Preset = 'deep'; Yes = $true; Apply = $true } -Rest @('agents.reviewer.effort=xhigh')
            Assert-Equal 0 $ok.exit
            $cfg = Get-Config $t
            Assert-Equal 'medium' $cfg.agents.'sa-analyst'.effort
            Assert-Equal 'xhigh' $cfg.agents.reviewer.effort '個別指定的值應該蓋過預設組合'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'schema 不在 → 一個字都不寫（驗不了就不寫）' {
        $t = New-SetTarget 's8'
        try {
            Remove-Item (Join-Path $t '.codex/bdd-workflow/sdlc.config.schema.json')
            $before = Get-ConfigText $t
            $j = Invoke-SdlcJson set @{ Target = $t } -Rest @('review.maxRounds=4')
            Assert-Equal 2 $j.exit
            Assert-Equal 'schema-unreadable' $j.data.error
            Assert-Equal $before (Get-ConfigText $t)
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'tune -ApplyProposal 套的是存下來的那一份，不重算；-Only 只套指定的 agent' {
        $t = New-SetTarget 's9'
        try {
            Assert-Equal 'no-proposal' (Invoke-SdlcJson tune @{ Target = $t; ApplyProposal = $true }).data.error '沒看過提議就套用，不該默默重算一份'
            Invoke-SdlcJson tune @{ Target = $t } | Out-Null
            # 模擬「看提議與按套用之間 repo 變了」：重算會得到別的值，存下來的那份才是使用者看到的。
            $pp = Join-Path $t 'bdd-docs/.sdlc/tuning-proposal.json'
            $stored = Get-Content $pp -Raw | ConvertFrom-Json
            foreach ($i in $stored.proposal) { if ($i.agent -eq 'implementer') { $i.effort = 'max' } }
            [IO.File]::WriteAllText($pp, ($stored | ConvertTo-Json -Depth 8), $Utf8)

            $only = Invoke-SdlcJson tune @{ Target = $t; ApplyProposal = $true; Only = 'reviewer' }
            Assert-Equal 0 $only.exit "warnings: $($only.warnings -join ' | ')"
            $cfg = Get-Config $t
            Assert-Equal 'high' $cfg.agents.reviewer.effort
            Assert-Equal 'inherit' $cfg.agents.implementer.effort '-Only reviewer 卻動到了 implementer'
            Assert-Equal 1 @($only.data.proposal).Count

            $all = Invoke-SdlcJson tune @{ Target = $t; ApplyProposal = $true }
            Assert-Equal 0 $all.exit
            Assert-True $all.data.applied
            Assert-Equal 'max' (Get-Config $t).agents.implementer.effort '套的不是存下來的那份 —— 畫面上看到的跟寫進去的不一樣'

            Assert-Equal 'unknown-agent' (Invoke-SdlcJson tune @{ Target = $t; ApplyProposal = $true; Only = 'reveiwer' }).data.error
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / 檔不在的時候：哪一個該吵、哪一個給預設' {

    function New-DefaultsTarget([string]$name) {
        $rel = New-SdlcRelease "r-$name" -Agents @('sa-analyst', 'implementer', 'reviewer') -WithSchema -WithHooks
        $t = New-SdlcTarget "t-$name"
        Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
        return $t
    }

    It-Should 'hooks.json 不在 → doctor 算問題並說怎麼補（整層強制沒了，症狀是零）' {
        $t = New-DefaultsTarget 'd1'
        try {
            Assert-True (Test-Path (Join-Path $t '.codex/hooks.json')) '這份發佈物沒有 hooks.json，這個案例就沒在驗它'
            $before = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 0 $before.data.problems "刪之前就已經有問題了，這個案例量不到 hooks.json 的那一項：$($before.warnings -join ' | ')"
            Remove-Item (Join-Path $t '.codex/hooks.json')
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'no-hooks' $j.data.hooks.status
            Assert-Equal 2 $j.exit 'hooks.json 不在卻說這個專案是健康的 —— 四支 hook 一支都不會跑'
            Assert-True ($j.data.problems -ge 1)
            Assert-Match 'hooks.json' ($j.warnings -join "`n")
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有 sdlc.config.json：doctor 說這是合法狀態，不算問題（＝全部 inherit）' {
        $t = New-DefaultsTarget 'd2'
        try {
            Remove-Item (Join-Path $t 'sdlc.config.json')
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'no-config' $j.data.tuning.status
            Assert-True (-not $j.data.config.exists)
            Assert-Equal 0 $j.data.problems '沒有設定檔是合法狀態，不該紅'
            Assert-Equal 3 $j.data.review.maxRounds
            Assert-Equal 'default' $j.data.review.source
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有設定檔時 set 替你建一份預設的，再寫你要的值（不叫你去跑 install）' {
        $t = New-DefaultsTarget 'd3'
        try {
            Remove-Item (Join-Path $t 'sdlc.config.json')
            $j = Invoke-SdlcJson set @{ Target = $t; Apply = $true } -Rest @('agents.reviewer.effort=high')
            Assert-Equal 0 $j.exit "warnings: $($j.warnings -join ' | ')"
            Assert-True $j.data.configCreated
            Assert-True $j.data.written
            $cfg = Get-Content (Join-Path $t 'sdlc.config.json') -Raw | ConvertFrom-Json
            Assert-Equal '$schema' @($cfg.PSObject.Properties.Name)[0] '建出來的檔要跟 install 建的一樣'
            Assert-Equal 3 $cfg.review.maxRounds '建檔本身不該改變任何行為 —— 修正輪還是預設 3'
            Assert-Equal 'high' $cfg.agents.reviewer.effort
            Assert-Equal 'inherit' $cfg.agents.'sa-analyst'.effort '其他 agent 要留在 inherit'
            Assert-Match 'model_reasoning_effort = "high"' (Get-Toml $t 'reviewer')
            Assert-Equal 'in-sync' (Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)).data.tuning.status
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有設定檔時 -Preview 不建檔（預覽不留痕跡）' {
        $t = New-DefaultsTarget 'd4'
        try {
            Remove-Item (Join-Path $t 'sdlc.config.json')
            $j = Invoke-SdlcJson set @{ Target = $t; Preset = 'deep'; Preview = $true }
            Assert-Equal 0 $j.exit
            Assert-True (-not $j.data.configCreated)
            Assert-True (-not (Test-Path (Join-Path $t 'sdlc.config.json'))) '預覽建了檔'
            Assert-True (@($j.data.changes | Where-Object { $_.changed }).Count -gt 0)
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒裝工作流的資料夾 → set 不建檔，說「先跑 install」' {
        $t = New-SdlcTarget 't-d5'
        try {
            $j = Invoke-SdlcJson set @{ Target = $t } -Rest @('review.maxRounds=4')
            Assert-Equal 2 $j.exit
            Assert-Equal 'not-installed' $j.data.error
            Assert-True (-not (Test-Path (Join-Path $t 'sdlc.config.json'))) '在一個沒裝工作流的資料夾裡建了設定檔'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有設定檔時 apply 與 tune 指向 set，不指向 install（專案已經裝好了）' {
        $t = New-DefaultsTarget 'd6'
        try {
            Remove-Item (Join-Path $t 'sdlc.config.json')
            $a = Invoke-SdlcJson apply @{ Target = $t }
            Assert-Equal 'no-config' $a.data.error
            Assert-Match 'set ' ($a.warnings -join "`n") 'apply 沒告訴他下一步該用什麼'
            $tu = Invoke-SdlcJson tune @{ Target = $t }
            Assert-Equal 0 $tu.exit "沒有設定檔照樣要能給建議；warnings: $($tu.warnings -join ' | ')"
            Assert-True (@($tu.data.proposal).Count -gt 0)
            Assert-Equal 'inherit' @($tu.data.proposal)[0].current '沒有設定檔時現值一律是 inherit'
            # 套用建議時才建檔
            $ap = Invoke-SdlcJson tune @{ Target = $t; ApplyProposal = $true; Only = 'reviewer' }
            Assert-Equal 0 $ap.exit "warnings: $($ap.warnings -join ' | ')"
            Assert-True $ap.data.configCreated
            Assert-Equal 'high' (Get-Content (Join-Path $t 'sdlc.config.json') -Raw | ConvertFrom-Json).agents.reviewer.effort
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
