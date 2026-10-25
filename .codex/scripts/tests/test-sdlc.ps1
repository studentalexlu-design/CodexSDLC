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

# doctor 的「環境」一段看的是這台機器上的工具 —— 測試不能跟著機器變（維護者的機器 PATH 上就沒有 git）。
# 所以 doctor 一律在 PATH 最前面放一支假的 git：環境檢查只看它在不在，不會執行它。
# 要測環境檢查本身的，用 Invoke-DoctorEnv（PATH 整個換掉）。
$DoctorBin = Join-Path ([IO.Path]::GetTempPath()) 'codex-sdlc-doctor-bin'
function Get-DoctorPath {
    if (-not (Test-Path (Join-Path $DoctorBin 'git.cmd'))) {
        New-Item -ItemType Directory -Path $DoctorBin -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $DoctorBin 'git.cmd'), "@exit /b 0`r`n", [Text.Encoding]::ASCII)
    }
    return "$DoctorBin$([IO.Path]::PathSeparator)$env:PATH"
}

function Invoke-SdlcJson {
    param([string]$Cmd, [hashtable]$Params = @{}, [hashtable]$Env = @{}, [string[]]$Rest = @())
    $p = @{ Command = $Cmd; Json = $true }
    foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] }
    if ($Cmd -eq 'doctor' -and -not $Env.ContainsKey('PATH')) { $Env = $Env.Clone(); $Env['PATH'] = Get-DoctorPath }
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

    It-Should '-Preview 只列計畫：改過的檔、新增、刪除、hooks 換不換都講，一個檔都不動' {
        # extension 的「升級」拿這份計畫填確認對話框。這裡寫了任何一個檔，「確認」就成了事後告知。
        $r1 = New-SdlcRelease 'r1-pv' -Extra @('.codex/scripts/a.ps1', '.codex/scripts/old.ps1'); $t = New-SdlcTarget 't-pv'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            New-SdlcFile (Join-Path $t '.codex/scripts/a.ps1') '# 使用者改過'
            $before = @{}
            Get-ChildItem $t -Recurse -File | ForEach-Object { $before[$_.FullName] = (Get-FileHash $_.FullName).Hash }
            $r2 = New-SdlcRelease 'r2-pv' -Version '4.7.0' -WithHooks -WithVsix -Extra @('.codex/scripts/a.ps1', '.codex/scripts/new.ps1')
            $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Preview = $true }
            Assert-Equal 0 $j.exit '-Preview 不該要求 -Yes'
            Assert-Equal 'preview' $j.data.result
            Assert-Shape $j.data @{
                from = 'string?'; to = 'string'; breaking = 'bool'; downgrade = 'bool'; degraded = 'bool'
                unchanged = 'array'; modified = 'array'; added = 'array'; removed = 'array'; notes = 'array'; result = 'string'
                vsix = 'string?'; hooksChanged = 'bool'
            }
            Assert-True ('.codex/scripts/a.ps1' -in @($j.data.modified)) '改過的檔沒有列在計畫裡'
            Assert-True ('.codex/scripts/new.ps1' -in @($j.data.added)) '新增的檔沒有列在計畫裡'
            Assert-True ('.codex/scripts/old.ps1' -in @($j.data.removed)) '要刪的檔沒有列在計畫裡'
            Assert-True $j.data.hooksChanged 'hooks.json 會換卻沒說 —— 換了就要重新信任'
            Assert-Match 'codex-sdlc-4\.7\.0\.vsix$' ([string]$j.data.vsix) '沒有指出這一版附的 extension'
            $after = @{}
            Get-ChildItem $t -Recurse -File | ForEach-Object { $after[$_.FullName] = (Get-FileHash $_.FullName).Hash }
            Assert-Equal ($before.Keys.Count) ($after.Keys.Count) '-Preview 新增或刪除了檔'
            foreach ($k in $before.Keys) { Assert-Equal $before[$k] $after[$k] "-Preview 改了 $k" }
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '拿比專案舊的發佈物 update → 標成降級並警告（照做，但要講）' {
        $r1 = New-SdlcRelease 'r1-dg' -Version '4.7.0' -Extra @('.codex/scripts/a.ps1'); $t = New-SdlcTarget 't-dg'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $r0 = New-SdlcRelease 'r0-dg' -Version '4.6.0'
            $j = Invoke-SdlcJson update @{ Source = $r0; Target = $t; Preview = $true }
            Assert-True $j.data.downgrade '舊的發佈物沒有被標成降級'
            Assert-True ((@($j.warnings) -match '降級').Count -gt 0) '降級沒有警告'
            $r2 = New-SdlcRelease 'r2-dg' -Version '4.8.0' -Extra @('.codex/scripts/a.ps1')
            $j2 = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Preview = $true }
            Assert-True (-not $j2.data.downgrade) '正常的升級被標成降級'
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
    It-Should '預設不查：不叫 codex app-server，狀態是 skipped，不算問題' {
        # doctor 預設會問一次 `codex --version`（環境檢查：毫秒級、不連網，答案「比實測版本舊」使用者修得了）。
        # 這一條守的是信任狀態那一支：app-server 最久 15 秒，而且它的答案 doctor 修不了 —— 預設不起來。
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
            $calls = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
            Assert-True ($calls -notmatch 'args=app-server') 'codex app-server 被叫起來了 —— 信任狀態預設不該去問'
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

Describe-Suite 'sdlc / 發佈來源不只 GitHub：Gitea、GitLab（含自架）' {

    # 公司內部多半是自架的 Gitea／GitLab，而且是私有的（要 token）。這一組守的全是靜默的失效：
    #   自架的來源認不得           → 更新通知從此沒有，沒有人會發現
    #   token 跟著轉址送到別台主機 → GitLab 的 PRIVATE-TOKEN 不會被自動轉址拿掉，附件又常轉到物件儲存；外流了也沒有症狀
    #   token 用通用的環境變數名   → 專案設定檔（進版控）裡的來源被改掉，token 就送到別人的主機
    #
    # 一台假的發佈站，兩個 port = 兩個站台：a 是發佈來源，b 是「別台主機」（物件儲存那類）。
    # 照路徑表（完整網址 → 回應）回；每個請求記一行「網址 | 收到的 token 標頭」—— token 有沒有外流就看這一份。
    function Start-StubForge {
        $forge = [pscustomobject]@{ a = $null; b = $null; listeners = @(); jobs = @(); log = $null; routes = [hashtable]::Synchronized(@{}) }
        foreach ($name in 'a', 'b') {
            $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start()
            $origin = "http://127.0.0.1:$(([Net.IPEndPoint]$l.LocalEndpoint).Port)"
            $forge.$name = $origin; $forge.listeners += $l
            if (-not $forge.log) {
                $forge.log = Join-Path ([IO.Path]::GetTempPath()) "codex-sdlc-forge-$(([Net.IPEndPoint]$l.LocalEndpoint).Port).log"
                Remove-Item $forge.log -ErrorAction SilentlyContinue
            }
            $forge.jobs += Start-ThreadJob -ArgumentList $l, $origin, $forge.routes, $forge.log -ScriptBlock {
                param($listener, $origin, $routes, $log)
                while ($true) {
                    try { $c = $listener.AcceptTcpClient() } catch { break }
                    try {
                        $s = $c.GetStream(); $rd = [IO.StreamReader]::new($s, [Text.Encoding]::ASCII)
                        $url = $origin + (($rd.ReadLine()) -split ' ')[1]
                        $hdr = @{}
                        while ($line = $rd.ReadLine()) { $i = $line.IndexOf(':'); if ($i -gt 0) { $hdr[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() } }
                        [IO.File]::AppendAllText($log, "$url | authorization=$($hdr['Authorization']) | private-token=$($hdr['PRIVATE-TOKEN'])`n")
                        $r = $routes[$url]
                        $status = if ($r) { [int]$r.status } else { 404 }
                        $body = if ($r -and $r.body -is [byte[]]) { $r.body } elseif ($r -and $r.body) { [Text.Encoding]::UTF8.GetBytes([string]$r.body) } else { [byte[]]::new(0) }
                        $head = "HTTP/1.1 $status X`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n"
                        if ($r -and $r.type) { $head += "Content-Type: $($r.type)`r`n" }
                        if ($r -and $r.location) { $head += "Location: $($r.location)`r`n" }
                        $hb = [Text.Encoding]::ASCII.GetBytes($head + "`r`n")
                        $s.Write($hb, 0, $hb.Length); $s.Write($body, 0, $body.Length); $s.Flush()
                    } catch { } finally { $c.Close() }
                }
            }
        }
        return $forge
    }
    function Stop-StubForge($forge) {
        foreach ($l in $forge.listeners) { $l.Stop() }
        foreach ($j in $forge.jobs) { $null = Wait-Job $j -Timeout 5; Remove-Job $j -Force -ErrorAction SilentlyContinue }
        $lines = @(if (Test-Path $forge.log) { Get-Content $forge.log -Encoding UTF8 })
        Remove-Item $forge.log -ErrorAction SilentlyContinue
        return $lines
    }
    # 子行程不准走 proxy（假站台在本機），而且 token 只有測試明講的那一個 —— 開發機上真的設了也不算數。
    function Get-ForgeEnv([hashtable]$extra = @{}) {
        $e = @{ HTTPS_PROXY = ''; HTTP_PROXY = ''; ALL_PROXY = ''; NO_PROXY = '127.0.0.1,localhost'; CODEX_SDLC_TOKEN_127_0_0_1 = '' }
        foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }
        return $e
    }
    function New-ForgeTarget([string]$name, [string]$source) {
        $rel = New-SdlcRelease "r-$name" -SourceUrl $source; $t = New-SdlcTarget "t-$name"
        Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
        return $t
    }
    # Gitea／GitHub 的 release 長一樣；Content-Type 不帶 charset（GitLab 就是這樣回），中文說明照樣要讀對。
    function Add-GiteaRelease($forge, [string]$api, [string]$web) {
        $forge.routes["$api/releases/latest"] = @{ status = 200; type = 'application/json'; body = (@{
            tag_name = 'v9.9.0'; body = '新增：自架的發佈來源'; html_url = "$web/releases/tag/v9.9.0"; draft = $false; prerelease = $false
            assets = @(@{ name = 'codex-sdlc-9.9.0.zip'; browser_download_url = "$web/releases/download/v9.9.0/codex-sdlc-9.9.0.zip" })
        } | ConvertTo-Json -Depth 5) }
    }
    function Get-PayloadBytes([string]$version) {
        $rel = New-SdlcRelease "r-payload-$version" -Version $version
        $zip = Join-Path $SdlcRoot "dl/codex-sdlc-$version.zip"
        New-Item -ItemType Directory -Path (Split-Path $zip -Parent) -Force | Out-Null
        Compress-Archive -Path (Join-Path $rel '*') -DestinationPath $zip -Force
        return , [IO.File]::ReadAllBytes($zip)
    }

    It-Should 'fetch：本機那一份比發佈頁的新 → 不下載、用本機的（新版 extension 先裝了、發佈頁還沒掛上去）' {
        $forge = Start-StubForge
        try {
            Add-GiteaRelease $forge "$($forge.a)/api/v1/repos/team/flow" "$($forge.a)/team/flow"
            $forge.routes["$($forge.a)/team/flow/releases/download/v9.9.0/codex-sdlc-9.9.0.zip"] = @{ status = 200; type = 'application/zip'; body = (Get-PayloadBytes '9.9.0') }
            $newer = New-SdlcRelease 'r-bn' -Version '10.0.0'; $t = New-SdlcTarget 't-bn'
            $j = Invoke-SdlcJson fetch @{ Source = $newer; Target = $t; SourceUrl = "gitea:$($forge.a)/team/flow"; CacheDir = (Join-Path $SdlcRoot 'cache') } -Env (Get-ForgeEnv)
            $seen = Stop-StubForge $forge; $forge = $null
            Assert-Equal 'bundled' $j.data.chosen "warnings: $($j.warnings -join ' | ')"
            Assert-Equal '10.0.0' $j.data.version '點「升級到 10.0.0」卻拿到發佈頁比較舊的那一版'
            Assert-Equal '9.9.0' $j.data.remote.latest '發佈頁查到的版本要照實回報'
            Assert-Equal 0 @($seen | Where-Object { $_ -match 'releases/download' }).Count "用不到的東西照樣下載了：$($seen -join ' ; ')"
        } finally { if ($forge) { Stop-StubForge $forge | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'fetch：vsix 是發佈頁上另一個附件 → 補進快取的 editor/，第二次走快取不再下載' {
        # zip 預設不帶 vsix。沒補的話 update -Preview 找不到它，extension 升級完就不會提示「安裝新版 extension」。
        $forge = Start-StubForge
        try {
            $api = "$($forge.a)/api/v1/repos/team/flow"; $web = "$($forge.a)/team/flow"
            $forge.routes["$api/releases/latest"] = @{ status = 200; type = 'application/json'; body = (@{
                tag_name = 'v9.9.0'; body = ''; html_url = "$web/releases/tag/v9.9.0"; draft = $false; prerelease = $false
                assets = @(
                    @{ name = 'codex-sdlc-9.9.0.zip'; browser_download_url = "$web/releases/download/v9.9.0/codex-sdlc-9.9.0.zip" }
                    @{ name = 'codex-sdlc-9.9.0.vsix'; browser_download_url = "$web/releases/download/v9.9.0/codex-sdlc-9.9.0.vsix" })
            } | ConvertTo-Json -Depth 5) }
            $forge.routes["$web/releases/download/v9.9.0/codex-sdlc-9.9.0.zip"] = @{ status = 200; type = 'application/zip'; body = (Get-PayloadBytes '9.9.0') }
            $forge.routes["$web/releases/download/v9.9.0/codex-sdlc-9.9.0.vsix"] = @{ status = 200; type = 'application/octet-stream'; body = 'not really a vsix' }
            $rel = New-SdlcRelease 'r-vx'; $t = New-SdlcTarget 't-vx'; $cache = Join-Path $SdlcRoot 'cache'
            $p = @{ Source = $rel; Target = $t; Bundled = ''; SourceUrl = "gitea:$($forge.a)/team/flow"; CacheDir = $cache }
            $j = Invoke-SdlcJson fetch $p -Env (Get-ForgeEnv)
            $j2 = Invoke-SdlcJson fetch $p -Env (Get-ForgeEnv)
            $seen = Stop-StubForge $forge; $forge = $null
            Assert-Equal 'remote' $j.data.chosen "warnings: $($j.warnings -join ' | ')"
            Assert-True (Test-Path (Join-Path $j.data.path 'editor/codex-sdlc-9.9.0.vsix')) "vsix 沒進快取的 editor/：$($seen -join ' ; ')"
            Assert-Equal 'cached' $j2.data.chosen
            Assert-Equal 1 @($seen | Where-Object { $_ -match '\.vsix' }).Count "快取裡已經有了還再下載一次：$($seen -join ' ; ')"
        } finally { if ($forge) { Stop-StubForge $forge | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '自架 Gitea（裝在子路徑底下）：check-update 查得到新版，中文說明與發佈頁網址都對' {
        $forge = Start-StubForge
        try {
            Add-GiteaRelease $forge "$($forge.a)/git/api/v1/repos/team/flow" "$($forge.a)/git/team/flow"
            $t = New-ForgeTarget 'gt1' "gitea:$($forge.a)/git/team/flow"
            $j = Invoke-SdlcJson check-update @{ Target = $t } -Env (Get-ForgeEnv)
            $seen = Stop-StubForge $forge; $forge = $null
            Assert-Equal 'newer' $j.data.status "warnings: $($j.warnings -join ' | ') / 站台收到：$($seen -join ' ; ')"
            Assert-Equal '9.9.0' $j.data.latest
            Assert-Equal 'gitea' $j.data.provider
            Assert-Match '/git/team/flow/releases/tag/v9\.9\.0$' $j.data.url
            $cache = Get-Content (Join-Path $t 'bdd-docs/.sdlc/update-cache.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-Equal '新增：自架的發佈來源' $cache.notes '沒帶 charset 的 JSON 被用錯的編碼解了 —— whatsnew 唸出來是亂碼'
        } finally { if ($forge) { Stop-StubForge $forge | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '自架 GitLab（巢狀群組）：跳過還沒到發佈日的；fetch 下載附件，token 不跟著轉址送到物件儲存' {
        $forge = Start-StubForge
        try {
            $api = "$($forge.a)/api/v4/projects/group%2Fsub%2Fflow"
            $pkg = "$($forge.a)/api/v4/projects/7/packages/generic/codex-sdlc/9.9.0/codex-sdlc-9.9.0.zip"
            $perma = "$($forge.a)/group/sub/flow/-/releases/v9.9.0/downloads/codex-sdlc-9.9.0.zip"
            $forge.routes["$api/releases?per_page=5"] = @{ status = 200; type = 'application/json'; body = (ConvertTo-Json -Depth 6 -InputObject @(
                @{ tag_name = 'v10.0.0'; upcoming_release = $true; description = '還沒到發佈日'; assets = @{ links = @() } }
                @{ tag_name = 'v9.9.0'; upcoming_release = $false; description = '正式版'; _links = @{ self = "$($forge.a)/group/sub/flow/-/releases/v9.9.0" }
                   assets = @{ links = @(@{ name = 'codex-sdlc-9.9.0.zip'; url = $pkg; direct_asset_url = $perma }) } }
            )) }
            # 套件庫轉到物件儲存（另一個站台、帶簽章的網址，不需要 token）。
            $forge.routes[$pkg] = @{ status = 302; location = "$($forge.b)/bucket/codex-sdlc-9.9.0.zip?X-Amz-Signature=abc" }
            $forge.routes["$($forge.b)/bucket/codex-sdlc-9.9.0.zip?X-Amz-Signature=abc"] = @{ status = 200; type = 'application/zip'; body = (Get-PayloadBytes '9.9.0') }
            # 網頁路由的永久連結：私有專案拿 token 打它只會被轉到登入頁 —— 用了它，下載回來的是一頁 HTML。
            $forge.routes[$perma] = @{ status = 302; location = "$($forge.a)/users/sign_in" }
            $forge.routes["$($forge.a)/users/sign_in"] = @{ status = 200; type = 'text/html'; body = '<html>sign in</html>' }

            # 本機那一份明講沒有（-Bundled ''）：拿得到的只可能是遠端那一份。
            $rel = New-SdlcRelease 'r-gl1'; $t = New-SdlcTarget 't-gl1'
            $j = Invoke-SdlcJson fetch @{ Source = $rel; Target = $t; Bundled = ''; SourceUrl = "gitlab:$($forge.a)/group/sub/flow"; CacheDir = (Join-Path $SdlcRoot 'cache') } `
                     -Env (Get-ForgeEnv @{ CODEX_SDLC_TOKEN_127_0_0_1 = 'glpat-test' })
            $siteB = $forge.b
            $seen = Stop-StubForge $forge; $forge = $null
            Assert-Equal 'remote' $j.data.chosen "warnings: $($j.warnings -join ' | ') / 站台收到：$($seen -join ' ; ')"
            Assert-Equal '9.9.0' $j.data.version '拿了還沒到發佈日的那一版，或拿錯附件'
            Assert-Equal 'gitlab' $j.data.remote.provider
            $toA = @($seen | Where-Object { $_.StartsWith($api) -or $_.StartsWith($pkg) })
            Assert-Equal 2 $toA.Count "來源站台該收到 API 與套件庫各一次：$($seen -join ' ; ')"
            foreach ($line in $toA) { Assert-Match 'private-token=glpat-test' $line '私有專案的 token 沒有送到來源站台 —— 查不到也下載不了' }
            $toB = @($seen | Where-Object { $_.StartsWith($siteB) })
            Assert-Equal 1 $toB.Count
            Assert-Match 'authorization= \| private-token=$' $toB[0] "token 跟著轉址送到別台主機了：$($toB[0])"
        } finally { if ($forge) { Stop-StubForge $forge | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '三家各用自己認得的 token 標頭（GitHub Enterprise Bearer、Gitea token、GitLab PRIVATE-TOKEN）' {
        $forge = Start-StubForge
        try {
            Add-GiteaRelease $forge "$($forge.a)/api/v1/repos/team/flow" "$($forge.a)/team/flow"
            Add-GiteaRelease $forge "$($forge.a)/api/v3/repos/team/flow" "$($forge.a)/team/flow"
            $forge.routes["$($forge.a)/api/v4/projects/team%2Fflow/releases?per_page=5"] = @{ status = 200; type = 'application/json'
                body = (ConvertTo-Json -Depth 6 -InputObject @(@{ tag_name = 'v9.9.0'; description = ''; assets = @{ links = @() } })) }
            $fenv = Get-ForgeEnv @{ CODEX_SDLC_TOKEN_127_0_0_1 = 'tkn' }
            $got = @{}
            foreach ($p in 'gitea', 'github', 'gitlab') {
                $t = New-ForgeTarget "hd-$p" "${p}:$($forge.a)/team/flow"
                $got[$p] = Invoke-SdlcJson check-update @{ Target = $t } -Env $fenv
            }
            $seen = Stop-StubForge $forge; $forge = $null
            foreach ($p in 'gitea', 'github', 'gitlab') { Assert-Equal 'newer' $got[$p].data.status "$p 查不到：$($seen -join ' ; ')" }
            Assert-Match 'authorization=token tkn \|' (@($seen | Where-Object { $_ -match '/api/v1/' })[0])
            Assert-Match 'authorization=Bearer tkn \|' (@($seen | Where-Object { $_ -match '/api/v3/' })[0])
            Assert-Match 'authorization= \| private-token=tkn$' (@($seen | Where-Object { $_ -match '/api/v4/' })[0])
        } finally { if ($forge) { Stop-StubForge $forge | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'token 綁主機：通用名字（GITEA_TOKEN 這類）與別台主機的 token 一個都不送' {
        $forge = Start-StubForge
        try {
            Add-GiteaRelease $forge "$($forge.a)/api/v1/repos/team/flow" "$($forge.a)/team/flow"
            $t = New-ForgeTarget 'bind' "gitea:$($forge.a)/team/flow"
            $fenv = Get-ForgeEnv @{ GITEA_TOKEN = 'leak1'; GITLAB_TOKEN = 'leak2'; GITHUB_TOKEN = 'leak3'; CODEX_SDLC_TOKEN_GIT_ACME_LOCAL = 'leak4' }
            $j = Invoke-SdlcJson check-update @{ Target = $t } -Env $fenv
            $seen = Stop-StubForge $forge; $forge = $null
            Assert-Equal 'newer' $j.data.status "對照組：沒有 token 的公開 repo 照樣要查得到 / 站台收到：$($seen -join ' ; ')"
            Assert-True ($seen.Count -gt 0) '站台一個請求都沒收到，下面那條斷言證明不了任何事'
            Assert-True (-not ($seen -match 'leak')) "送出了不屬於這台主機的 token：$($seen -join ' ; ')"
        } finally { if ($forge) { Stop-StubForge $forge | Out-Null }; Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 4.14 把認得的寫法收窄了（舊的 GitHub pattern 開頭沒錨定）。升級後還留著舊寫法 = 更新通知從此靜默消失。
    It-Should '升級：4.13 以前收過的 GitHub 寫法換成認得的；換不了的原樣留著，update 與 doctor 都要講' {
        foreach ($c in @(
            @{ old = 'github.com/acme/flow'; want = 'https://github.com/acme/flow'; migrated = $true }
            @{ old = 'ssh://git@github.com/acme/flow.git'; want = 'https://github.com/acme/flow'; migrated = $true }
            @{ old = 'https://git.acme.local/team/flow'; want = 'https://git.acme.local/team/flow'; migrated = $false }
            @{ old = 'gitea:https://git.acme.local/team/flow'; want = 'gitea:https://git.acme.local/team/flow'; migrated = $false }   # 對照組：本來就認得
        )) {
            $r1 = New-SdlcRelease 'r-mig1'; $t = New-SdlcTarget 't-mig'
            try {
                Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
                $p = Join-Path $t 'sdlc.config.json'
                $cfg = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
                $cfg.update.source = $c.old
                [IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 8), $Utf8)
                $r2 = New-SdlcRelease 'r-mig2' -Version '4.7.0'
                $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true }
                Assert-Equal $c.want (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).update.source "升級後的 update.source（原本 $($c.old)）"
                Assert-Equal $c.migrated ($null -ne $j.data.sourceMigrated) "$($c.old)：sourceMigrated 不對"
                $recognized = $c.migrated -or $c.old.StartsWith('gitea:')
                $warned = (@($j.warnings) -match 'update\.source 認不得').Count -gt 0
                Assert-Equal (-not $recognized) $warned "$($c.old)：update 該講的沒講，或不該講的講了"
                $dj = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
                Assert-Equal (-not $recognized) ((@($dj.warnings) -match 'update\.source 認不得').Count -gt 0) "$($c.old)：doctor 該講的沒講，或不該講的講了"
            } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # 發佈物第一次填 source 之前裝的專案，update.source 是空字串。不補 = 那些專案永遠查不到新版。
    It-Should '升級：空的 update.source 從新發佈物補上；使用者填過的（含認不得的）不動' {
        foreach ($c in @(
            @{ old = '';                                 want = 'https://github.com/acme/flow';     filled = $true }
            @{ old = $null;                              want = 'https://github.com/acme/flow';     filled = $true }    # 連 source 這個 key 都沒有
            @{ old = 'gitea:https://git.acme.local/a/b'; want = 'gitea:https://git.acme.local/a/b'; filled = $false }
            @{ old = 'https://git.acme.local/a/b';       want = 'https://git.acme.local/a/b';       filled = $false }   # 認不得的也是使用者的
        )) {
            $r1 = New-SdlcRelease 'r-fill1'; $t = New-SdlcTarget 't-fill'
            try {
                Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
                $p = Join-Path $t 'sdlc.config.json'
                $cfg = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -eq $c.old) { $cfg.update.PSObject.Properties.Remove('source') } else { $cfg.update.source = $c.old }
                [IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 8), $Utf8)
                $r2 = New-SdlcRelease 'r-fill2' -Version '4.7.0' -SourceUrl 'https://github.com/acme/flow'
                $j = Invoke-SdlcJson update @{ Source = $r2; Target = $t; Yes = $true }
                Assert-Equal $c.want (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).update.source "升級後的 update.source（原本 '$($c.old)'）"
                Assert-Equal $c.filled ($null -ne $j.data.sourceFilled) "'$($c.old)'：sourceFilled 不對"
            } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # 對照組：新發佈物也沒填 → 照舊是空的，不報補上
        $r1 = New-SdlcRelease 'r-fill1'; $t = New-SdlcTarget 't-fill'
        try {
            Invoke-Sdlc install @{ Source = $r1; Target = $t } | Out-Null
            $j = Invoke-SdlcJson update @{ Source = (New-SdlcRelease 'r-fill2' -Version '4.7.0'); Target = $t; Yes = $true }
            Assert-Equal '' (Get-Content (Join-Path $t 'sdlc.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).update.source
            Assert-True ($null -eq $j.data.sourceFilled) '新發佈物沒填，卻報了補上'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒標明是哪一家的自架網址 → 認不得，並且講清楚怎麼寫' {
        $t = New-ForgeTarget 'unk' 'https://git.acme.local/team/flow'
        try {
            $j = Invoke-SdlcJson check-update @{ Target = $t } -Env (Get-ForgeEnv)
            Assert-Equal 'unsupported-source' $j.data.status
            Assert-True ((@($j.warnings) -match 'gitea:').Count -gt 0) '只說認不得，沒說要怎麼寫'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / model／effort 對這台的 Codex（清單問 codex 本身）' {

    # sdlc.config.json 全隊共用，Codex 卻各台各裝，每一版的模型清單都不一樣。對不上時 Codex 的行為（版本檔 v415-models）：
    #   子代理的 effort 不在它的模型支援之列 → spawn 直接失敗
    #   這版 Codex 不認得的模型               → 照樣 spawn、用 fallback 的模型資料，沒有任何提示
    # 所以 set 擋前者與後者，doctor／apply 講，而且「能用哪些」只問 codex（這裡是一支回固定清單的假 codex）。

    # 假 codex 是批次檔、不是 pwsh 腳本：sdlc.ps1 每次 set／doctor 都會問它兩次（--version、debug models），
    # 一支 pwsh 起來要 1 秒多，這一組因此是整套最慢的；平行跑、CPU 吃滿時還會撞上 sdlc.ps1 問 codex 的 10 秒逾時，
    # 清單變成「問不到」—— 測試紅，而紅的原因是測試自己慢。要輸出的內容都在 New-ModelsCodex 先寫成檔，這裡只 type。
    $FakeModelsCodexCmd = @'
@echo off
if defined FAKE_CODEX_LOG (>>"%FAKE_CODEX_LOG%" echo args=%*)
if "%~1"=="--version" (
    if defined FAKE_CODEX_VERSION (echo codex-cli %FAKE_CODEX_VERSION%) else (echo codex-cli 0.162.1)
    exit /b 0
)
if not "%~1"=="debug" exit /b 0
if not "%~2"=="models" exit /b 0
if defined FAKE_CODEX_NO_MODELS (>&2 echo error: unrecognized subcommand 'models'& exit /b 2)
if "%FAKE_CODEX_MODELS_MODE%"=="exit" (>&2 echo error: failed to load config& exit /b 3)
if "%FAKE_CODEX_MODELS_MODE%"=="not-json" (echo Logged in using ChatGPT& exit /b 0)
if "%FAKE_CODEX_MODELS_MODE%"=="no-models" (type "%~dp0no-models.json"& exit /b 0)
if "%FAKE_CODEX_MODELS_MODE%"=="utf8-bytes" (type "%~dp0models-utf8.json"& exit /b 0)
type "%~dp0models.json"
exit /b 0
'@
    # 形狀照 codex 0.162.1 的 debug models（只留用得到的欄位）：大的支援到 ultra（再加一個 schema 還不認得的 hyper，
    # 代表 Codex 升版新增的值）、中的只到 xhigh、隱藏的不列。
    function New-ModelEntry([string]$slug, [string]$vis, [int]$prio, [string]$def, [string[]]$efforts) {
        return [ordered]@{ slug = $slug; display_name = $slug; visibility = $vis; priority = $prio; default_reasoning_level = $def
                           supported_reasoning_levels = @($efforts | ForEach-Object { [ordered]@{ effort = $_; description = "$_ reasoning" } }) }
    }
    function New-ModelsCodex {
        $dir = Join-Path $SdlcRoot 'fake-codex'
        $catalog = @(
            (New-ModelEntry 'gpt-big' 'list' 1 'low' @('low', 'medium', 'high', 'xhigh', 'max', 'ultra', 'hyper'))
            (New-ModelEntry 'gpt-mid' 'list' 2 'medium' @('low', 'medium', 'high', 'xhigh'))
            (New-ModelEntry 'gpt-secret' 'hide' 9 'medium' @('low', 'medium'))
        )
        $json = [ordered]@{ models = $catalog } | ConvertTo-Json -Depth 8
        $utf8 = [Text.UTF8Encoding]::new($false)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'models.json'), $json, $utf8)
        [IO.File]::WriteAllText((Join-Path $dir 'no-models.json'), '{"providers":[]}', $utf8)
        # 真的 codex 不管 console 的 code page，一律寫 UTF-8 位元組；說明文字裡有 — “ ” …（0.162.1 實測）。type 原樣吐位元組。
        $fancy = $json -replace '"(\w+) reasoning"', ('"$1 reasoning ' + [char]0x2014 + ' ' + [char]0x201C + 'deep' + [char]0x201D + ' ' + [char]0x2026 + '"')
        [IO.File]::WriteAllText((Join-Path $dir 'models-utf8.json'), $fancy, $utf8)
        $cmd = Join-Path $dir 'codex.cmd'
        [IO.File]::WriteAllText($cmd, ($FakeModelsCodexCmd -replace "`r?`n", "`r`n") + "`r`n", [Text.Encoding]::ASCII)
        return $cmd
    }
    # 這台機器：模型清單快取的位置、CODEX_HOME（給了 $sessionModel 就放一份 config.toml 指定主對話的模型）、假 codex 的版本與呼叫紀錄。
    function Get-MachineEnv([string]$sessionModel = '', [string]$version = '0.162.1', [hashtable]$extra = @{}) {
        $codexHome = Join-Path $SdlcRoot 'machine/codex-home'
        New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
        $toml = Join-Path $codexHome 'config.toml'
        if ($sessionModel) { New-SdlcFile $toml "model = `"$sessionModel`"`n" } else { Remove-Item $toml -ErrorAction SilentlyContinue }
        $e = @{ CODEX_HOME = $codexHome; CODEX_SDLC_STATE_DIR = (Join-Path $SdlcRoot 'machine/state'); FAKE_CODEX_LOG = (Join-Path $SdlcRoot 'machine/codex.log'); FAKE_CODEX_VERSION = $version }
        foreach ($k in $extra.Keys) { $e[$k] = $extra[$k] }
        return $e
    }
    function New-ModelsTarget([string]$name) {
        $rel = New-SdlcRelease "r-$name" -Agents @('sa-analyst', 'implementer', 'reviewer') -WithSchema -WithHooks
        $t = New-SdlcTarget "t-$name"
        Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
        return $t
    }
    # 跳過 set，直接把值寫進設定檔（手改的人、或在別台用 set 選的值）。
    function Set-AgentValues([string]$t, [string]$agent, [string]$model, [string]$effort, [string]$checkedWith = '') {
        $p = Join-Path $t 'sdlc.config.json'
        $c = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $c.agents.$agent.model = $model; $c.agents.$agent.effort = $effort
        if ($checkedWith) { $c | Add-Member -NotePropertyName 'models-checked-with' -NotePropertyValue $checkedWith -Force }
        [IO.File]::WriteAllText($p, ($c | ConvertTo-Json -Depth 8), $Utf8)
    }
    function Get-CodexCalls([string]$what) {
        $log = Join-Path $SdlcRoot 'machine/codex.log'
        return @(if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match $what } })
    }
    function Get-Finding($j, [string]$agent) { return @($j.data.models.agents | Where-Object agent -eq $agent)[0] }

    It-Should 'models：列出這台 Codex 的清單；沒設主對話模型時，inherit 用 priority 最小的那個；隱藏的不列' {
        $t = New-ModelsTarget 'm1'; $codex = New-ModelsCodex
        try {
            $j = Invoke-SdlcJson models @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv)
            Assert-Equal 0 $j.exit "warnings: $($j.warnings -join ' | ')"
            Assert-Shape $j.data.models @{
                catalog = @{ available = 'bool'; reason = 'string?'; codexVersion = 'string?'; default = 'string?'; models = 'array' }
                session = @{ model = 'string?'; source = 'string?' }; checkedWith = 'string?'; agents = 'array'
            }
            Assert-Equal '0.162.1' $j.data.models.catalog.codexVersion
            Assert-Equal 'gpt-big' $j.data.models.catalog.default
            Assert-Equal 'gpt-big' $j.data.models.session.model '沒設主對話模型時，inherit 的 agent 跟著 Codex 的預設'
            Assert-Equal 'low,medium,high,xhigh' (@(@($j.data.models.catalog.models | Where-Object slug -eq 'gpt-mid')[0].efforts) -join ',')
            Assert-True (-not (($j.output -join "`n") -match '(?m)^\s+gpt-secret\s')) '隱藏的模型被列成可以選的'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'set：effort 超出模型上限 → 擋（子代理會起不來）、建議那個模型的上限、一個字都沒寫；配上支援它的模型就收，並記下是哪一版 Codex' {
        $t = New-ModelsTarget 'm2'; $codex = New-ModelsCodex
        try {
            $cfgPath = Join-Path $t 'sdlc.config.json'
            $before = [IO.File]::ReadAllText($cfgPath)
            $j = Invoke-SdlcJson set @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv 'gpt-mid') -Rest @('agents.reviewer.effort=ultra')
            Assert-Equal 2 $j.exit
            $e = @($j.data.errors)[0]
            Assert-Equal 'agents.reviewer.effort' $e.key
            Assert-Equal 'agents.reviewer.effort=xhigh' $e.suggestion
            Assert-Equal $before ([IO.File]::ReadAllText($cfgPath)) '擋了還寫'
            $ok = Invoke-SdlcJson set @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv 'gpt-mid') -Rest @('agents.reviewer.model=gpt-big', 'agents.reviewer.effort=ultra')
            Assert-Equal 0 $ok.exit "model 與 effort 要一起看：$($ok.warnings -join ' | ')"
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-Equal 'ultra' $cfg.agents.reviewer.effort
            Assert-Equal '0.162.1' $cfg.'models-checked-with' '沒記下這組值是在哪一版 Codex 上選的 —— 別台分不出該升級還是該換'
            Assert-Equal 2 (Invoke-SdlcJson set @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv 'gpt-mid') -Rest @('models-checked-with=9.9.9')).exit '工具維護的欄位被手動改掉了'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'set：這版 Codex 不認得的模型 → 擋，給最接近的；只差大小寫也擋' {
        $t = New-ModelsTarget 'm3'; $codex = New-ModelsCodex
        try {
            foreach ($c in @(@{ raw = 'gpt-mdi'; want = 'gpt-mid' }, @{ raw = 'GPT-MID'; want = 'gpt-mid' })) {
                $j = Invoke-SdlcJson set @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv) -Rest @("agents.reviewer.model=$($c.raw)")
                Assert-Equal 2 $j.exit "$($c.raw) 被收了"
                Assert-Equal "agents.reviewer.model=$($c.want)" @($j.data.errors)[0].suggestion
            }
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'set：Codex 新增、schema 還沒列的 effort → 這台的 Codex 認得就收（面板列得出來，就要寫得進去）；問不到 Codex 時照 schema 擋' {
        $t = New-ModelsTarget 'm3b'; $codex = New-ModelsCodex
        try {
            $j = Invoke-SdlcJson set @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv) -Rest @('agents.reviewer.model=gpt-big', 'agents.reviewer.effort=hyper')
            Assert-Equal 0 $j.exit "等下一版工作流才能用 Codex 的新值：$(@($j.data.errors | ForEach-Object { $_.message }) -join ' | ')"
            $mid = Invoke-SdlcJson set @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv) -Rest @('agents.reviewer.model=gpt-mid')
            Assert-Equal 2 $mid.exit '換成不支援 hyper 的模型卻收了 —— 新值也要跟 model 一起驗'
            $none = Invoke-SdlcJson set @{ Target = $t; CodexPath = (Join-Path $SdlcRoot 'no-such-codex.exe') } -Env (Get-MachineEnv) -Rest @('agents.implementer.effort=hyper')
            Assert-Equal 2 $none.exit '問不到 Codex 時沒有根據收一個 schema 不認得的值'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'set：model 是 inherit、effort 只有部分模型支援 → 這台沒事就收，但要講換了主對話模型的人會起不來' {
        $t = New-ModelsTarget 'm4'; $codex = New-ModelsCodex
        try {
            $j = Invoke-SdlcJson set @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv 'gpt-big') -Rest @('agents.implementer.effort=max')
            Assert-Equal 0 $j.exit "warnings: $($j.warnings -join ' | ')"
            Assert-True ((@($j.warnings) -match 'gpt-mid.*implementer 會起不來').Count -gt 0) "沒講別台的風險：$($j.warnings -join ' | ')"
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'set：問不到 Codex（找不到、或太舊沒有 debug models）→ 退回 schema 驗、照寫，並明講沒驗' {
        $t = New-ModelsTarget 'm5'; $codex = New-ModelsCodex
        try {
            foreach ($case in @(
                @{ codex = (Join-Path $SdlcRoot 'no-such-codex.exe'); env = (Get-MachineEnv 'gpt-mid') }
                @{ codex = $codex; env = (Get-MachineEnv 'gpt-mid' '0.150.0' @{ FAKE_CODEX_NO_MODELS = '1' }) }
            )) {
                $j = Invoke-SdlcJson set @{ Target = $t; CodexPath = $case.codex } -Env $case.env -Rest @('agents.reviewer.effort=ultra')
                Assert-Equal 0 $j.exit "問不到清單就不該擋：$($j.warnings -join ' | ')"
                Assert-Match '只照 schema 驗' ($j.output -join "`n") '沒講這次沒有對 Codex 驗'
                Assert-True (-not (Get-Content (Join-Path $t 'sdlc.config.json') -Raw | ConvertFrom-Json).PSObject.Properties['models-checked-with']) '沒驗過卻記了版本'
                Set-AgentValues $t 'reviewer' 'inherit' 'inherit'
            }
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'models：問不到清單的原因分開講 —— 只有版本真的比 0.154.0 舊才提版本門檻' {
        $t = New-ModelsTarget 'm5b'; $codex = New-ModelsCodex
        try {
            foreach ($case in @(
                @{ want = 'too-old';      text = '0\.154\.0';          env = (Get-MachineEnv '' '0.150.0' @{ FAKE_CODEX_NO_MODELS = '1' }) }
                @{ want = 'exit-nonzero'; text = '結束碼 2';           env = (Get-MachineEnv '' '0.162.1' @{ FAKE_CODEX_NO_MODELS = '1' }) }
                @{ want = 'exit-nonzero'; text = '結束碼 3';           env = (Get-MachineEnv '' '0.162.1' @{ FAKE_CODEX_MODELS_MODE = 'exit' }) }
                @{ want = 'invalid-json'; text = '不是 JSON';          env = (Get-MachineEnv '' '0.162.1' @{ FAKE_CODEX_MODELS_MODE = 'not-json' }) }
                @{ want = 'no-models';    text = '沒有 models';        env = (Get-MachineEnv '' '0.162.1' @{ FAKE_CODEX_MODELS_MODE = 'no-models' }) }
            )) {
                $j = Invoke-SdlcJson models @{ Target = $t; CodexPath = $codex } -Env $case.env
                Assert-Equal 2 $j.exit "$($case.want)：問不到清單，models 該回 2"
                Assert-Equal $false $j.data.models.catalog.available
                Assert-Equal $case.want $j.data.models.catalog.reason
                $w = @($j.warnings) -join "`n"
                Assert-Match $case.text $w "$($case.want)：原因沒講清楚"
                if ($case.want -ne 'too-old') { Assert-True ($w -notmatch '0\.154\.0') "$($case.want)：版本夠新卻叫人升級：$w" }
            }
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有 console 視窗、code page 不是 UTF-8 時（VS Code 的背景 doctor）照樣讀得到 codex 的 UTF-8 清單' {
        # extension 用 windowsHide 叫 pwsh：沒有視窗的 console 用系統的 OEM code page（zh-TW 是 950），
        # 而 codex 輸出 UTF-8。用 950 去解，多位元組字元會吃掉後面的引號 —— JSON 壞掉、清單是空的（終端機裡卻正常）。
        # 這裡在自己的隱藏 console 裡把 code page 釘成 950，任何機器都重現得出來，也不動到跑測試的這個 console。
        $t = New-ModelsTarget 'm-cp'; $src = Split-Path (New-ModelsCodex)
        $dir = Join-Path $SdlcRoot 'Author Software\fake codex'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item (Join-Path $src '*') $dir
        $codex = Join-Path $dir 'codex.cmd'
        try {
            $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
            $code = "[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(950); & '$($Sdlc -replace "'", "''")' models -Target '$($t -replace "'", "''")' -CodexPath '$($codex -replace "'", "''")' -Json; exit `$LASTEXITCODE"
            foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $code)) { $psi.ArgumentList.Add($a) }
            $psi.WorkingDirectory = (Get-Location).Path; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
            foreach ($kv in (Get-MachineEnv '' '0.162.1' @{ FAKE_CODEX_MODELS_MODE = 'utf8-bytes' }).GetEnumerator()) { $psi.Environment[$kv.Key] = [string]$kv.Value }
            $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
            $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
            Assert-True ($p.WaitForExit(120000)) '逾時'
            $j = $o.GetAwaiter().GetResult() | ConvertFrom-Json
            Assert-Equal $null $j.data.models.catalog.reason "stderr: $($e.GetAwaiter().GetResult()) / warnings: $($j.warnings -join ' | ')"
            Assert-Equal $true $j.data.models.catalog.available
            Assert-Equal 'gpt-big,gpt-mid,gpt-secret' (@($j.data.models.catalog.models | ForEach-Object slug) -join ',')
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'doctor：會讓子代理起不來的算問題（多一個），只在別台才出事的只講' {
        $t = New-ModelsTarget 'm6'; $codex = New-ModelsCodex
        try {
            $base = Invoke-SdlcJson doctor @{ Target = $t; CodexPath = $codex; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env (Get-MachineEnv 'gpt-mid')
            Set-AgentValues $t 'reviewer' 'inherit' 'ultra'
            Invoke-Sdlc apply @{ Target = $t } | Out-Null      # 調校區塊同步，免得「沒 apply」也算進問題數
            $bad = Invoke-SdlcJson doctor @{ Target = $t; CodexPath = $codex; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env (Get-MachineEnv 'gpt-mid')
            $f = Get-Finding $bad 'reviewer'
            Assert-Equal 'effort-unsupported' $f.status
            Assert-Equal 'problem' $f.level
            Assert-Equal ($base.data.problems + 1) $bad.data.problems '子代理起不來，doctor 卻沒算成問題'
            Assert-True ((@($bad.warnings) -match 'reviewer.*set agents\.reviewer\.effort=xhigh -Apply').Count -gt 0) '沒給改法'

            Set-AgentValues $t 'reviewer' 'inherit' 'max'
            Invoke-Sdlc apply @{ Target = $t } | Out-Null
            $warn = Invoke-SdlcJson doctor @{ Target = $t; CodexPath = $codex; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env (Get-MachineEnv 'gpt-big')
            Assert-Equal 'depends-on-model' (Get-Finding $warn 'reviewer').status
            Assert-Equal $base.data.problems $warn.data.problems '這台跑得起來的值被算成問題'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'doctor：這台不認得的模型 —— 設定是在較新的 Codex 上選的就叫人升級，不是的話叫人換' {
        $t = New-ModelsTarget 'm7'; $codex = New-ModelsCodex
        try {
            Set-AgentValues $t 'reviewer' 'gpt-next' 'inherit' '0.170.0'
            $newer = Invoke-SdlcJson doctor @{ Target = $t; CodexPath = $codex; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env (Get-MachineEnv)
            Assert-Equal 'unknown-model' (Get-Finding $newer 'reviewer').status
            Assert-Match '升級這台的 Codex' (Get-Finding $newer 'reviewer').message
            Set-AgentValues $t 'reviewer' 'gpt-old' 'inherit' '0.150.0'
            $older = Invoke-SdlcJson doctor @{ Target = $t; CodexPath = $codex; EditorHome = (Join-Path $SdlcRoot 'editor-home') } -Env (Get-MachineEnv)
            Assert-Match '拿掉.*這台有：gpt-big、gpt-mid' (Get-Finding $older 'reviewer').message
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '清單快取：同一版 Codex 一天內只問一次 debug models；Codex 換版就重問' {
        $t = New-ModelsTarget 'm8'; $codex = New-ModelsCodex
        try {
            1..2 | ForEach-Object { Invoke-SdlcJson models @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv) | Out-Null }
            Assert-Equal 1 (Get-CodexCalls 'debug models').Count 'VS Code 的背景 doctor 每次都問一次 codex'
            Invoke-SdlcJson models @{ Target = $t; CodexPath = $codex } -Env (Get-MachineEnv '' '0.163.0') | Out-Null
            Assert-Equal 2 (Get-CodexCalls 'debug models').Count 'Codex 升版了還在用舊版的清單'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'apply：這台會出事的值照寫（擋在 set；apply 也跑在 update 裡），但每一個都講' {
        $t = New-ModelsTarget 'm9'; $codex = New-ModelsCodex
        try {
            Set-AgentValues $t 'reviewer' 'gpt-old' 'inherit'
            Set-AgentValues $t 'implementer' 'inherit' 'ultra'
            $r = Invoke-Script $Sdlc -Params @{ Command = 'apply'; Target = $t; CodexPath = $codex } -Env (Get-MachineEnv 'gpt-mid')
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Match 'model = "gpt-old"' (Get-Toml $t 'reviewer') '喊歸喊，還是要寫出去'
            Assert-Match '不認得 gpt-old' $r.stderr
            Assert-Match 'implementer 會起不來' $r.stderr
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
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

    It-Should 'whatsnew 的「怎麼升級」照裝的 extension 講：4.16.0 以前的先換 extension，之後的點「有新版」' {
        $rel = New-SdlcRelease 'r-e7'; $t = New-SdlcTarget 't-e7'
        $editorHome = Join-Path $SdlcRoot 'editor-home'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $cache = Join-Path $t 'bdd-docs/.sdlc/update-cache.json'
            $writeCache = { New-SdlcFile $cache "{ `"checked-at`": `"$((Get-Date).ToString('o'))`", `"installed`": `"4.6.0`", `"latest`": `"9.9.9`", `"newer`": true, `"notes`": `"x`", `"url`": `"`", `"seen`": `"`" }" }

            & $writeCache; New-InstalledExtension $editorHome '4.15.1'
            $old = (@((Invoke-SdlcJson whatsnew @{ Target = $t; EditorHome = $editorHome }).output) -join "`n")
            # 4.15 的 extension 點「有新版」只會跑 whatsnew：不在這裡叫他先換 extension，他就一直只看得到說明。
            Assert-Match 'extension 是 4\.15\.1，還沒有一鍵升級' $old
            Assert-Match 'install-extension .*codex-sdlc-9\.9\.9\.vsix' $old

            & $writeCache; New-InstalledExtension $editorHome '4.16.0'
            $new = (@((Invoke-SdlcJson whatsnew @{ Target = $t; EditorHome = $editorHome }).output) -join "`n")
            Assert-Match '升級到 9\.9\.9' $new
            Assert-True ($new -notmatch '還沒有一鍵升級') '新版的 extension 也被叫去換'
            Assert-Match 'update -Target' $new '終端機的做法不見了'
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

Describe-Suite 'sdlc / 叫起另一支 pwsh（doctor 的 agent-lint、tune 的 repo-index 都靠它）' {

    # pwsh 以 .NET global tool 安裝時，[Environment]::ProcessPath 是 dotnet.exe。拿它當 pwsh 叫，
    # doctor 的 agent-lint 一行都不會執行，只報「沒有跑完」—— 維護者的機器就是這種安裝。
    # 那個情境在一般安裝的機器上重現不出來，所以判斷本身從 sdlc.ps1 的語法樹拿出來、直接餵值驗；
    # 最後一條走真路徑（這台若是 global tool 安裝，走的就是 dotnet 那一支）。
    $sdlcAst = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Sdlc).Path, [ref]$null, [ref]$null)
    $launchFn = $sdlcAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PwshLaunch' }, $true)
    if ($launchFn) { Invoke-Expression $launchFn.Extent.Text }

    It-Should '一般安裝：ProcessPath 就是 pwsh，原樣叫' {
        Assert-True ($null -ne $launchFn) 'sdlc.ps1 裡找不到 Get-PwshLaunch'
        $fakeHome = Join-Path $SdlcRoot 'pshome-plain'
        New-SdlcFile (Join-Path $fakeHome 'pwsh.dll') 'x'
        try {
            $l = Get-PwshLaunch -processPath 'C:\Program Files\PowerShell\7\pwsh.exe' -pwshHome $fakeHome
            Assert-Equal 'C:\Program Files\PowerShell\7\pwsh.exe' $l.exe
            Assert-Equal 0 @($l.prefix).Count '一般安裝不該多帶 pwsh.dll'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '.NET global tool：ProcessPath 是 dotnet → 第一個參數要是 $PSHOME/pwsh.dll' {
        Assert-True ($null -ne $launchFn) 'sdlc.ps1 裡找不到 Get-PwshLaunch'
        $fakeHome = Join-Path $SdlcRoot 'pshome-tool'
        New-SdlcFile (Join-Path $fakeHome 'pwsh.dll') 'x'
        try {
            $l = Get-PwshLaunch -processPath 'C:\Program Files\dotnet\dotnet.exe' -pwshHome $fakeHome
            Assert-Equal 'C:\Program Files\dotnet\dotnet.exe' $l.exe
            Assert-Equal 1 @($l.prefix).Count '少了 pwsh.dll —— 跑的會是 `dotnet -NoProfile …`'
            Assert-Equal (Join-Path $fakeHome 'pwsh.dll') @($l.prefix)[0]
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'sdlc.ps1 裡只有 Get-PwshLaunch 碰 [Environment]::ProcessPath' {
        # 一般安裝的機器上，下面那條真路徑測不到 dotnet 的情況 —— 這一條守的是「有人又直接拿 ProcessPath 去叫 pwsh」。
        Assert-True ($null -ne $launchFn) 'sdlc.ps1 裡找不到 Get-PwshLaunch'
        $uses = @($sdlcAst.FindAll({ param($n)
            $n -is [Management.Automation.Language.MemberExpressionAst] -and
            $n.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
            $n.Expression.TypeName.Name -match '^(System\.)?Environment$' -and
            $n.Member.Extent.Text -eq 'ProcessPath' }, $true))
        $outside = @($uses | Where-Object { $_.Extent.StartOffset -lt $launchFn.Extent.StartOffset -or $_.Extent.EndOffset -gt $launchFn.Extent.EndOffset })
        Assert-Equal 0 $outside.Count "Get-PwshLaunch 以外直接用了 ProcessPath（第 $(@($outside | ForEach-Object { $_.Extent.StartLineNumber }) -join '、') 行）"
    }

    It-Should 'doctor 叫得起 agent-lint —— 不管 pwsh 是怎麼裝的' {
        $rel = New-SdlcRelease 'r-pw1'; $t = New-SdlcTarget 't-pw1'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $t '.codex/scripts') -Force | Out-Null
            Copy-Item '.codex/scripts/agent-lint.ps1' (Join-Path $t '.codex/scripts/agent-lint.ps1') -Force
            $lint = (Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)).data.lint
            Assert-True $lint.ran 'doctor 沒有叫 agent-lint'
            Assert-True (-not $lint.PSObject.Properties['error']) "doctor 叫不起 agent-lint：$($lint.error)"
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / doctor 的環境檢查（只偵測、不安裝）' {

    # 每一條都把 PATH 整個換掉，只放那一條要的假工具（環境檢查只看在不在、問版本，不會拿它們做事）。
    # pwsh 用絕對路徑叫（照 Get-PwshLaunch）：以 .NET global tool 安裝時，用名字叫 pwsh 會先叫起一個 shim，
    # 而 shim 要從 PATH 找 dotnet —— 那樣 PATH 就換不乾淨，「找不到 dotnet」也就測不到。
    function New-EnvTool([string]$bin, [string]$name, [string[]]$say = @(), [int]$exitCode = 0) {
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $body = @($say | ForEach-Object { "@echo $_" }) + "@exit /b $exitCode"
        [IO.File]::WriteAllText((Join-Path $bin "$name.cmd"), (($body -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    }

    # 裝好的最小專案：版本檔 ＋ hooks.json（不然 doctor 會因為 no-hooks 紅，量不到環境這一段）＋ 這一條要的檔。
    function New-EnvTarget([string]$Name, [hashtable]$Files = @{}) {
        $t = Join-Path $SdlcRoot $Name
        New-SdlcFile (Join-Path $t '.codex/bdd-workflow/bdd-workflow-version.json') '{ "contract-version": "4.10.0", "min-compatible-version": "4.2.0" }'
        New-SdlcFile (Join-Path $t '.codex/hooks.json') '{ "hooks": {} }'
        foreach ($f in $Files.Keys) { New-SdlcFile (Join-Path $t $f) $Files[$f] }
        return $t
    }

    function Invoke-DoctorEnv([string]$Target, [string]$Bin, [hashtable]$Env = @{}) {
        $exe = [Environment]::ProcessPath
        $pre = if ([IO.Path]::GetFileNameWithoutExtension($exe) -ieq 'dotnet') { @(Join-Path $PSHOME 'pwsh.dll') } else { @() }
        $psi = [Diagnostics.ProcessStartInfo]::new($exe)
        foreach ($a in @($pre) + @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Resolve-Path $Sdlc).Path,
                                    'doctor', '-Target', $Target, '-Json', '-EditorHome', (Join-Path $SdlcRoot 'editor-home'))) { $psi.ArgumentList.Add($a) }
        $psi.WorkingDirectory       = (Get-Location).Path
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = $Utf8
        $psi.StandardErrorEncoding  = $Utf8
        # 系統目錄要留：假工具是 .cmd，要 cmd.exe。這台機器的 JAVA_HOME 不能漏進來。
        $psi.Environment['PATH'] = (@($Bin, [Environment]::SystemDirectory) | Where-Object { $_ }) -join [IO.Path]::PathSeparator
        [void]$psi.Environment.Remove('JAVA_HOME')
        foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        $stdout = $o.GetAwaiter().GetResult()
        try { $j = $stdout.Trim() | ConvertFrom-Json } catch { throw "doctor -Json 的輸出不是 JSON：$stdout / stderr: $($e.GetAwaiter().GetResult())" }
        Assert-Equal $p.ExitCode $j.exit 'JSON 裡的 exit 跟行程的 exit code 不一致'
        return $j
    }

    function Get-EnvItem($j, [string]$id) {
        $i = @($j.data.environment | Where-Object { $_.id -eq $id })
        if ($i.Count -ne 1) { throw "data.environment 裡的 $id 應該剛好一項，實際 $($i.Count) 項" }
        return $i[0]
    }

    It-Should '工具都在、專案用不到 build 工具 → 都不算問題，但 build-check 空轉要講出來' {
        $bin = Join-Path $SdlcRoot 'bin-all'
        New-EnvTool $bin 'git'; New-EnvTool $bin 'codex' @('codex-cli 999.0.0')
        try {
            $j = Invoke-DoctorEnv (New-EnvTarget 't-env-ok') $bin
            foreach ($i in @($j.data.environment)) {
                Assert-Shape $i @{ id = 'string'; name = 'string'; status = 'string'; found = 'string?'; required = 'string?'; source = 'string?'; breaks = 'string'; hint = 'string?' } "環境的 $($i.id)"
            }
            # pwsh 7 啟動時會把自己的目錄放進 PATH —— 從 doctor 看出去它永遠在，這一項查了也抓不到東西。
            Assert-True (-not (@($j.data.environment) | Where-Object { $_.id -eq 'pwsh' })) 'doctor 又在查 pwsh 在不在 PATH —— 在 pwsh 7 裡那永遠是「在」'
            Assert-Equal 'ok' (Get-EnvItem $j 'git').status
            Assert-Equal 'ok' (Get-EnvItem $j 'codex').status
            Assert-Equal '999.0.0' (Get-EnvItem $j 'codex').found
            Assert-Equal 'not-applicable' (Get-EnvItem $j 'build-tool').status
            Assert-Match '空轉' (@($j.output) -join "`n") 'build-check 對這個專案是空轉，doctor 卻沒說'
            Assert-Equal 0 $j.exit "warnings: $($j.warnings -join ' | ')"
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'PATH 上沒有 git → missing，算問題' {
        $bin = Join-Path $SdlcRoot 'bin-nogit'
        New-EnvTool $bin 'codex' @('codex-cli 999.0.0')
        try {
            $j = Invoke-DoctorEnv (New-EnvTarget 't-env-git') $bin
            Assert-Equal 'missing' (Get-EnvItem $j 'git').status
            Assert-Equal 2 $j.exit '⑤ 的必修檢查做不了，doctor 卻是綠的'
            Assert-True ((@($j.warnings) -match 'git').Count -gt 0) '沒有說缺 git'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'git 裝了但不在 PATH → 說出要把哪個目錄加進 PATH（再裝一份是錯的修法）' {
        # 用 LOCALAPPDATA 那個位置：ProgramFiles 是 Windows 依行程位元數替每個行程設的，子行程蓋不掉。
        # 這台機器若真的在 Program Files 裝了 git（只是不在 PATH），找到的會是那一份 —— 所以只斷言「找到了、說了加哪裡」。
        $bin = Join-Path $SdlcRoot 'bin-offpath'
        New-EnvTool $bin 'codex' @('codex-cli 999.0.0')
        $lad = Join-Path $SdlcRoot 'localappdata'
        New-SdlcFile (Join-Path $lad 'Programs\Git\cmd\git.exe') 'x'
        try {
            $j = Invoke-DoctorEnv (New-EnvTarget 't-env-offpath') $bin @{ LOCALAPPDATA = $lad }
            $g = Get-EnvItem $j 'git'
            Assert-Equal 'missing' $g.status
            Assert-Match '這台有 .*Git\\cmd\\git\.exe —— 把 .*加進 PATH' $g.hint '找到了裝在別處的 git，卻沒說要把哪個目錄加進 PATH'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Codex 比實測版本舊 → below-verified，算問題；比較新 → ok，不提示' {
        $old = Join-Path $SdlcRoot 'bin-codex-old'; $new = Join-Path $SdlcRoot 'bin-codex-new'
        foreach ($b in @($old, $new)) { New-EnvTool $b 'git' }
        # 版本號刻意離實測版本很遠：改了 $VerifiedCodexVersion 不必回來改這裡。
        New-EnvTool $old 'codex' @('codex-cli 0.0.1')
        New-EnvTool $new 'codex' @('codex-cli 999.0.0')
        try {
            $t = New-EnvTarget 't-env-codex'
            $j = Invoke-DoctorEnv $t $old
            $c = Get-EnvItem $j 'codex'
            Assert-Equal 'below-verified' $c.status
            Assert-Equal '0.0.1' $c.found
            Assert-Equal 2 $j.exit '強制層沒在這一版 Codex 上驗過，doctor 卻是綠的'
            $j2 = Invoke-DoctorEnv $t $new
            Assert-Equal 'ok' (Get-EnvItem $j2 'codex').status
            Assert-Equal 0 $j2.exit '比實測版本新不該讓 doctor 紅 —— 使用者無從行動'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '找不到 codex → unknown，不算問題（只用 VS Code 的 Codex 擴充時是正常的）' {
        $bin = Join-Path $SdlcRoot 'bin-nocodex'
        New-EnvTool $bin 'git'
        try {
            $j = Invoke-DoctorEnv (New-EnvTarget 't-env-nocodex') $bin
            Assert-Equal 'unknown' (Get-EnvItem $j 'codex').status
            Assert-Equal 0 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '.NET：global.json 要的 SDK 不在 → mismatch，附上要的版本' {
        $bin = Join-Path $SdlcRoot 'bin-dn-bad'
        New-EnvTool $bin 'git'
        New-EnvTool $bin 'dotnet' @('A compatible .NET SDK was not found.', 'Requested SDK version: 8.0.999') 1
        try {
            $t = New-EnvTarget 't-env-dn-bad' @{ 'src/App/App.csproj' = '<Project Sdk="Microsoft.NET.Sdk" />'; 'global.json' = '{ "sdk": { "version": "8.0.999" } }' }
            $j = Invoke-DoctorEnv $t $bin
            $d = Get-EnvItem $j 'dotnet-sdk'
            Assert-Equal 'mismatch' $d.status
            Assert-Equal '8.0.999' $d.required
            Assert-Equal 'global.json' $d.source
            Assert-Equal 2 $j.exit '④ 的每一個 dotnet 指令都會失敗，doctor 卻是綠的'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '.NET：SDK 在 → ok，記下版本' {
        $bin = Join-Path $SdlcRoot 'bin-dn-ok'
        New-EnvTool $bin 'git'; New-EnvTool $bin 'dotnet' @('10.0.401')
        try {
            $j = Invoke-DoctorEnv (New-EnvTarget 't-env-dn-ok' @{ 'App.sln' = 'x' }) $bin
            $d = Get-EnvItem $j 'dotnet-sdk'
            Assert-Equal 'ok' $d.status
            Assert-Equal '10.0.401' $d.found
            Assert-Equal 0 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '.NET：PATH 上沒有 dotnet → missing' {
        $bin = Join-Path $SdlcRoot 'bin-dn-none'
        New-EnvTool $bin 'git'
        try {
            $j = Invoke-DoctorEnv (New-EnvTarget 't-env-dn-none' @{ 'App.sln' = 'x' }) $bin
            Assert-Equal 'missing' (Get-EnvItem $j 'dotnet-sdk').status
            Assert-Equal 2 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Java：只有 Maven wrapper、沒有全域 mvn → 算有' {
        $bin = Join-Path $SdlcRoot 'bin-mvnw'
        New-EnvTool $bin 'git'; New-EnvTool $bin 'java'
        try {
            $t = New-EnvTarget 't-env-mvnw' @{ 'pom.xml' = '<project />'; 'mvnw.cmd' = 'x'; '.mvn/wrapper/maven-wrapper.properties' = 'x' }
            $j = Invoke-DoctorEnv $t $bin
            $m = Get-EnvItem $j 'maven'
            Assert-Equal 'ok' $m.status '有 wrapper 卻被判成缺 Maven'
            Assert-Match '\./mvnw' $m.found
            Assert-Equal 'ok' (Get-EnvItem $j 'jdk').status
            Assert-Equal 0 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Java：只有 wrapper 腳本、沒有設定檔 → 不算 wrapper，缺 Maven（同 repo-index 的判定）' {
        $bin = Join-Path $SdlcRoot 'bin-mvnw-half'
        New-EnvTool $bin 'git'; New-EnvTool $bin 'java'
        try {
            $j = Invoke-DoctorEnv (New-EnvTarget 't-env-mvnw-half' @{ 'pom.xml' = '<project />'; 'mvnw.cmd' = 'x' }) $bin
            Assert-Equal 'missing' (Get-EnvItem $j 'maven').status
            Assert-Equal 2 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Java：沒有 JDK → missing（wrapper 也要它）；JAVA_HOME 設好就算有' {
        $bin = Join-Path $SdlcRoot 'bin-nojava'
        New-EnvTool $bin 'git'
        $jh = Join-Path $SdlcRoot 'jdk'
        New-SdlcFile (Join-Path $jh 'bin\java.exe') 'x'
        try {
            $t = New-EnvTarget 't-env-jdk' @{ 'build.gradle' = 'x'; 'gradlew.bat' = 'x'; 'gradle/wrapper/gradle-wrapper.properties' = 'x' }
            $j = Invoke-DoctorEnv $t $bin
            Assert-Equal 'missing' (Get-EnvItem $j 'jdk').status
            Assert-Equal 'ok' (Get-EnvItem $j 'gradle').status
            Assert-Equal 2 $j.exit
            $j2 = Invoke-DoctorEnv $t $bin @{ JAVA_HOME = $jh }
            Assert-Equal 'ok' (Get-EnvItem $j2 'jdk').status
            Assert-Equal 0 $j2.exit
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
            # 自架的網址沒標明是哪一家：網域看不出是 Gitea 還是 GitLab，收了就是一個永遠查不到的來源。
            foreach ($bad in @('review.maxRounds=6', 'review.maxRounds=three', 'update.source=https://git.acme.local/team/flow',
                               'update.check=weekly', 'update.channel=beta', 'workflow-version=9.9.9', 'agents.reviewer.model=gpt 5',
                               'agents.reviewer.effort=minimal')) {
                $j = Invoke-SdlcJson set @{ Target = $t } -Rest @($bad)
                Assert-Equal 2 $j.exit "$bad 竟然被收了"
            }
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '發佈來源：gitlab.com 直接寫、自架的標明 gitea:／gitlab:／github: → 收（公司內部多半是自架的）' {
        $t = New-SetTarget 's3b'
        try {
            foreach ($src in @('https://gitlab.com/acme/tools/flow', 'gitea:https://git.acme.local/team/flow',
                               'gitlab:https://gitlab.acme.local/group/sub/flow', 'github:https://ghe.acme.local/acme/flow')) {
                $j = Invoke-SdlcJson set @{ Target = $t } -Rest @("update.source=$src")
                Assert-Equal 0 $j.exit "$src 被擋了：$(@($j.data.errors | ForEach-Object { $_.message }) -join ' | ')"
                Assert-Equal $src (Get-Config $t).update.source
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

Describe-Suite 'sdlc / doctor 從心跳看出 hooks 沒在跑（不叫 codex）' {

    # 信任狀態預設不問（要另外叫起 codex），但「沒在跑」看得到：agent 寫了產出，心跳卻沒跟著變新。
    # 這一組守的是兩邊的誤判：真的沒在跑卻是綠的（最貴），以及人改了 spec.md、或升級前的舊產出就喊（喊多了沒人看）。

    function Set-Age([string]$file, [int]$minutes) {
        [IO.File]::SetLastWriteTimeUtc($file, [DateTime]::UtcNow.AddMinutes(-$minutes))
    }
    function New-HbTarget([string]$name) {
        $rel = New-SdlcRelease "r-$name" -WithHooks; $t = New-SdlcTarget "t-$name"
        Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
        Set-Age (Join-Path $t '.codex/hooks.json') 120
        Set-Age (Join-Path $t 'bdd-docs/.sdlc/installed-manifest.json') 60
        return $t
    }
    function New-HbFile([string]$t, [string]$rel, [int]$minutes) {
        $f = Join-Path $t $rel
        New-SdlcFile $f "# $rel`n"
        if ($minutes) { Set-Age $f $minutes }
    }

    It-Should 'agent 的產出比心跳新 → silent，doctor 紅並說去哪裡信任' {
        $t = New-HbTarget 'hb1'
        try {
            New-HbFile $t 'bdd-docs/f1/analysis.md' 10
            New-HbFile $t 'bdd-docs/.cache/hooks/dlp-gate.last' 30
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Shape $j.data @{ heartbeat = @{ status = 'string'; lastRun = 'any'; since = 'any' } }
            Assert-Equal 'silent' $j.data.heartbeat.status
            Assert-Equal 'bdd-docs/f1/analysis.md' $j.data.heartbeat.lastOutput.path
            Assert-Equal 2 $j.exit 'agent 寫了產出、hook 一次都沒跑，doctor 卻是綠的'
            Assert-Match 'Trust all' (@($j.warnings) -join "`n") '沒說去哪裡信任'
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '從來沒有心跳、但有產出 → 一樣是 silent' {
        $t = New-HbTarget 'hb2'
        try {
            New-HbFile $t 'bdd-docs/project-map.md' 10
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'silent' $j.data.heartbeat.status
            Assert-Equal $null $j.data.heartbeat.lastRun
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '心跳比產出新 → running，不算問題' {
        $t = New-HbTarget 'hb3'
        try {
            New-HbFile $t 'bdd-docs/f1/review.md' 10
            New-HbFile $t 'bdd-docs/.cache/hooks/guideline-gate.last' 9
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'running' $j.data.heartbeat.status
            Assert-Equal 0 $j.exit "hooks 有在跑，doctor 卻紅了：$(@($j.warnings) -join ' / ')"
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '產出剛寫（兩分鐘內）→ pending，不下結論（hook 是寫完才跑，背景健檢可能搶在前面）' {
        $t = New-HbTarget 'hb4'
        try {
            New-HbFile $t 'bdd-docs/f1/current-state.md' 0
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'pending' $j.data.heartbeat.status
            Assert-Equal 0 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '升級前的舊產出、人會改的 spec.md 都不算證據 → no-activity' {
        $t = New-HbTarget 'hb5'
        try {
            New-HbFile $t 'bdd-docs/old/analysis.md' 90
            New-HbFile $t 'bdd-docs/f1/spec.md' 10
            $j = Invoke-SdlcJson doctor (Get-IsolatedDoctorParams $t)
            Assert-Equal 'no-activity' $j.data.heartbeat.status '升級前（還沒有心跳的版本）寫的、或人在編輯器裡改的檔，被當成「hooks 沒在跑」的證據'
            Assert-Equal 0 $j.exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'sdlc / learn：把每個需求、每一輪的審核發現收成一份清單（一個字都不寫）' {

    It-Should '讀快照與最新的 review.md，同一需求內去重，數得出幾輪' {
        $rel = New-SdlcRelease 'r-ln1'; $t = New-SdlcTarget 't-ln1'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $r1 = "VERDICT: FAIL`n`n## 發現`n1. [必修] src/A.cs:10 —— 斷言只檢查沒有丟例外`n   會怎麼壞：刪掉實作測試照樣綠`n2. [必修] src/B.cs:3 —— 空的 catch`n"
            $r2 = "VERDICT: FAIL`n`n## 發現`n1. [必修] src/A.cs:12 —— 斷言只檢查沒有丟例外`n   會怎麼壞：刪掉實作測試照樣綠`n"
            New-SdlcFile (Join-Path $t 'bdd-docs/f1/reviews/20261001-010000.md') $r1
            [IO.File]::SetLastWriteTimeUtc((Join-Path $t 'bdd-docs/f1/reviews/20261001-010000.md'), [DateTime]::UtcNow.AddMinutes(-20))
            New-SdlcFile (Join-Path $t 'bdd-docs/f1/reviews/20261001-020000.md') $r2
            New-SdlcFile (Join-Path $t 'bdd-docs/f1/review.md') "VERDICT: PASS`n`n## 發現`n1. [建議] src/A.cs:20 —— 命名跟地圖分岔`n"
            New-SdlcFile (Join-Path $t 'bdd-docs/f2/review.md') "VERDICT: FAIL`n`n## 發現`n1. [必修] ``src/C.cs:7`` —— 斷言只檢查沒有丟例外`n"
            New-SdlcFile (Join-Path $t 'bdd-docs/.cache/review.md') "1. [必修] x —— 不該被讀`n"
            $j = Invoke-SdlcJson learn @{ Target = $t }
            Assert-Equal 0 $j.exit
            Assert-Shape $j.data.learn @{ features = 'array'; findings = 'array'; counts = @{ features = 'int'; snapshots = 'int'; findings = 'int'; must = 'int' }; guidelines = @{ files = 'array'; ruleIds = 'array' } }
            Assert-Equal 2 $j.data.learn.counts.features '. 開頭的目錄（.cache、.sdlc）被當成需求'
            Assert-Equal 2 $j.data.learn.counts.snapshots
            Assert-Equal 4 $j.data.learn.counts.findings '同一需求裡同檔同問題（行號不同）沒去重，或前幾輪的必修沒讀到'
            Assert-Equal 3 $j.data.learn.counts.must
            $a = @($j.data.learn.findings | Where-Object { $_.feature -eq 'f1' -and $_.file -eq 'src/A.cs' -and $_.severity -eq '必修' })
            Assert-Equal 1 $a.Count
            Assert-Equal 2 $a[0].rounds '兩輪都被抓的那一項沒數成 2 輪'
            Assert-Equal '刪掉實作測試照樣綠' $a[0].failure
            Assert-Equal 'src/C.cs' (@($j.data.learn.findings | Where-Object feature -eq 'f2'))[0].file '包在反引號裡的位置沒剝乾淨'
            Assert-Equal 0 (@($j.data.learn.features | Where-Object id -eq 'f2'))[0].snapshots
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有審核紀錄 → 說一句、exit 0，而且一個檔都不寫；沒裝工作流 → exit 2' {
        $rel = New-SdlcRelease 'r-ln2'; $t = New-SdlcTarget 't-ln2'; $empty = New-SdlcTarget 't-ln2-empty'
        try {
            Invoke-Sdlc install @{ Source = $rel; Target = $t } | Out-Null
            $before = @(Get-ChildItem $t -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
            $j = Invoke-SdlcJson learn @{ Target = $t }
            Assert-Equal 0 $j.exit
            Assert-Equal 0 $j.data.learn.counts.features
            $after = @(Get-ChildItem $t -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join "`n"
            Assert-Equal $before $after 'learn 寫了東西 —— 規範是團隊的，寫進去要他點頭'
            Assert-Equal 2 (Invoke-SdlcJson learn @{ Target = $empty }).exit
        } finally { Remove-Item $SdlcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
