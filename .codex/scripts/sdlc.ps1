# sdlc.ps1
# 這套工作流的安裝、升級與 per-agent 調校。
#
# 三個約束決定了整支腳本的形狀，每一個都來自這個 repo 已經付過的代價：
#
# 1. **使用者的設定不能放在工具那半。** 升級動作是「覆蓋 .codex/、.agents/、AGENTS.md」，
#    設定放那裡會在升級時靜默消失（同 guidelines/ 的理由）。所以 model／effort 的真相是
#    專案根的 sdlc.config.json，toml 裡的 SDLC-TUNING 區塊只是它的**產物**。
#
# 2. **effort 的預設必須是「不寫這個 key」。** 1d8e411 把四個 agent 全釘 high，
#    結果大型 legacy repo 的分析逾時（理由留在 agent-lint.ps1 檢查 2 的檔頭）。
#    所以設定值 `inherit` 代表產生出來的區塊裡**一行都沒有**，而它是每個 agent 的預設。
#
# 3. **「使用者改過 AGENTS.md」是預期狀態，不是例外**（README 就叫他把內容合進去）。
#    所以升級不能無條件覆蓋 —— 要靠 baseline manifest 分辨「沒動過／你改過／新增／這一版刪了」。
#    分不出來時**不得假設沒動過**：猜錯就是靜默蓋掉使用者的修改。
#
# 更新通知刻意**不在這裡**：它折進 handoff-lint.ps1 的尾端，只讀快取、不碰網路、只印一行 stderr。
# 流程裡不得冒出更新確認 —— AGENTS.md 的「必經的確認只有兩個」是硬不變量。
#
# Exit: 0 = 成功／無事可做；2 = 有問題（doctor／apply 檢出，或使用者取消）。

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'check-update', 'apply', 'tune', 'doctor', 'whatsnew')]
    [string]$Command = 'doctor',

    [string]$Source,                       # 發佈物根目錄；預設 = 本腳本所在的工作流根
    [string]$Target = '.',                 # 消費端專案根
    [string]$ConfigFile = 'sdlc.config.json',

    [ValidateSet('fast', 'balanced', 'deep')]
    [string]$Preset,                       # install 用；不給就全部 inherit
    [switch]$Adopt,                        # install 用：接管既有的手動安裝，把現況記成基準線
    [switch]$ApplyProposal,                # tune 用：把提議寫回設定檔
    [switch]$Yes,                          # 非互動確認
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---- 常數 ----
# 工具那半。guidelines/ 與 bdd-docs/ 刻意不在裡面 —— 它們是使用者的。
$ToolRoots   = @('.codex', '.agents')
$ToolFiles   = @('AGENTS.md')
$VersionRel  = '.codex/bdd-workflow/bdd-workflow-version.json'
$ProfilesRel = '.codex/bdd-workflow/tuning-profiles.json'
$ManifestRel = '.codex/bdd-workflow/manifest.json'          # 發佈物自帶，不列入自己
$StateDir    = 'bdd-docs/.sdlc'
$BaselineRel = "$StateDir/installed-manifest.json"
$CacheRel    = "$StateDir/update-cache.json"
$ProposalRel = "$StateDir/tuning-proposal.json"

$TuneBegin   = '# SDLC-TUNING:BEGIN'
$TuneEnd     = '# SDLC-TUNING:END'
$KnownEfforts = @('minimal', 'low', 'medium', 'high')

if (-not $Source) { $Source = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }

# 路徑不存在時給一句人看得懂的話，而不是讓 Resolve-Path 丟出堆疊 ——
# 「擋下的理由跟使用者要做的事無關，而且他也修不了」是這套流程踩過兩次的失敗形狀。
foreach ($pair in @(@{ n = '-Source'; v = $Source }, @{ n = '-Target'; v = $Target })) {
    if (-not (Test-Path $pair.v)) {
        [Console]::Error.WriteLine("[sdlc] $($pair.n) 指向的路徑不存在：$($pair.v)")
        exit 2
    }
}

$script:Notes = @()
# 直接寫 stdout，**不能用 Write-Output**：這些訊息是從有回傳值的函式裡發出的，
# 走輸出串流會跟 return 的 exit code 混在同一個陣列裡 —— 症狀是整支腳本一個字都不印，
# 而且 exit code 變成一個字串陣列。
function Say([string]$m)  { $script:Notes += $m; if (-not $Json) { [Console]::Out.WriteLine($m) } }
function Warn([string]$m) { [Console]::Error.WriteLine("[sdlc] $m") }

# ---- 共用工具 ----
$Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Get-Sha256Text([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Utf8NoBom.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

function Get-Sha256File([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([IO.File]::ReadAllBytes($path)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

# 比對用的雜湊：agent toml 一律**把 SDLC-TUNING 區塊拿掉之後**再算。
#
# 那個區塊是 `apply` 寫的，不是使用者寫的。拿原始位元組比對的話，install 之後跑一次 apply
# 就會讓每個 agent toml 在下一次 update 被判成「使用者改過」—— 三個檔、每次升級都報一次，
# 而那份報告的價值完全來自「列出來的都真的要看」。噪音會直接訓練使用者忽略它。
#
# 只正規化 .codex/agents/*.toml：其餘檔案照原樣算，不做任何文字解碼。
function Get-ComparableSha([string]$root, [string]$rel) {
    $full = Join-Path $root $rel
    if ($rel -notmatch '^\.codex/agents/.+\.toml$') { return Get-Sha256File $full }
    $text = [IO.File]::ReadAllText($full)
    $pattern = "(?s)" + [regex]::Escape($TuneBegin) + ".*?" + [regex]::Escape($TuneEnd) + "\r?\n?"
    return Get-Sha256Text ([regex]::Replace($text, $pattern, ''))
}

function ConvertTo-Rel([string]$root, [string]$full) {
    $r = (Resolve-Path $root).Path.TrimEnd('\', '/')
    $f = $full
    if ($f.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $f = $f.Substring($r.Length) }
    return ($f -replace '\\', '/').TrimStart('/')
}

# 工具那半的檔案清單（相對路徑，正斜線，排序）。manifest 自己不列入自己。
function Get-ToolFileList([string]$root) {
    $out = @()
    foreach ($d in $ToolRoots) {
        $p = Join-Path $root $d
        if (-not (Test-Path $p)) { continue }
        $out += @(Get-ChildItem $p -Recurse -File | ForEach-Object { ConvertTo-Rel $root $_.FullName })
    }
    foreach ($f in $ToolFiles) {
        if (Test-Path (Join-Path $root $f)) { $out += $f }
    }
    return @($out | Where-Object { $_ -ne $ManifestRel } | Sort-Object -Unique)
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile([string]$path, $obj) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, (($obj | ConvertTo-Json -Depth 8) + "`n"), $Utf8NoBom)
}

function Get-ContractVersion([string]$root) {
    $v = Read-JsonFile (Join-Path $root $VersionRel)
    if (-not $v) { return $null }
    return [pscustomobject]@{
        contract = $v.'contract-version'
        minCompat = $v.'min-compatible-version'
        raw = $v
    }
}

# semver 比較。回 -1／0／1。
function Compare-Semver([string]$a, [string]$b) {
    $pa = @(($a -split '\.') | ForEach-Object { [int]($_ -replace '\D', '') })
    $pb = @(($b -split '\.') | ForEach-Object { [int]($_ -replace '\D', '') })
    for ($i = 0; $i -lt 3; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -ne $y) { return $x.CompareTo($y) }
    }
    return 0
}

function Confirm-Step([string]$question) {
    if ($Yes) { return $true }
    if ($Json -or [Console]::IsInputRedirected) {
        Warn "$question —— 非互動環境，請加 -Yes 明確同意。已中止。"
        return $false
    }
    $a = Read-Host "$question [y/N]"
    return ($a -match '^(y|yes)$')
}

# ---- 調校：設定 → toml 區塊 ----
#
# 這個正規化字串是 sdlc.ps1 與 agent-lint.ps1 之間的合約。**agent-lint 有一份逐字相同的副本**
# （它必須能獨立驗，不能為了算一個雜湊去 spawn 這支腳本）。改這裡就要改那裡 ——
# test-sdlc.ps1 的「設定改了但沒 apply → agent-lint 必須紅燈」那一條就是在守這個重複。
function Get-TuningStanza($agentCfg) {
    $model  = if ($agentCfg -and $agentCfg.model)  { [string]$agentCfg.model }  else { 'inherit' }
    $effort = if ($agentCfg -and $agentCfg.effort) { [string]$agentCfg.effort } else { 'inherit' }
    return "model=$model;effort=$effort"
}

function Get-TuningSha($agentCfg) {
    return (Get-Sha256Text (Get-TuningStanza $agentCfg)).Substring(0, 8)
}

function Get-AgentConfig($cfg, [string]$name) {
    if (-not $cfg -or -not $cfg.agents) { return $null }
    return $cfg.agents.PSObject.Properties |
           Where-Object { $_.Name -eq $name } |
           ForEach-Object { $_.Value } |
           Select-Object -First 1
}

# 產生區塊本體。inherit → 一行都沒有（見檔頭約束 2）。
function New-TuningBlock($agentCfg, [string]$sha, [string]$nl) {
    $lines = @("$TuneBegin sha=$sha —— 由 sdlc.ps1 apply 產生，不要手改")
    $model  = if ($agentCfg -and $agentCfg.model)  { [string]$agentCfg.model }  else { 'inherit' }
    $effort = if ($agentCfg -and $agentCfg.effort) { [string]$agentCfg.effort } else { 'inherit' }
    if ($model  -ne 'inherit') { $lines += "model = `"$model`"" }
    if ($effort -ne 'inherit') { $lines += "model_reasoning_effort = `"$effort`"" }
    $lines += $TuneEnd
    return ($lines -join $nl)
}

function Invoke-TuningApply([string]$root, $cfg) {
    $changed = @(); $warnings = @()
    $agentDir = Join-Path $root '.codex/agents'
    if (-not (Test-Path $agentDir)) { return [pscustomobject]@{ changed = @(); warnings = @('.codex/agents 不存在') } }

    foreach ($f in @(Get-ChildItem $agentDir -Filter *.toml -File | Sort-Object Name)) {
        $name = $f.BaseName
        $acfg = Get-AgentConfig $cfg $name
        $text = [IO.File]::ReadAllText($f.FullName)
        $nl   = if ($text -match "`r`n") { "`r`n" } else { "`n" }
        $sha  = Get-TuningSha $acfg
        $block = New-TuningBlock $acfg $sha $nl

        $effort = if ($acfg -and $acfg.effort) { [string]$acfg.effort } else { 'inherit' }
        if ($effort -ne 'inherit' -and $effort -notin $KnownEfforts) {
            $warnings += "$name：effort=`"$effort`" 不在已知值（$($KnownEfforts -join '／')）之列，仍會寫出去"
        }
        # `model` 這個 key 本 repo 從來沒有驗證過。Codex 若忽略它，症狀是**靜默地用預設模型跑** ——
        # 所以寫得出去，但絕不安靜。
        if ($acfg -and $acfg.model -and [string]$acfg.model -ne 'inherit') {
            $warnings += "$name：model=`"$($acfg.model)`" —— 這個 key 尚未在本工作流驗證過。若 Codex 忽略它，症狀是靜默地用預設模型跑，畫面上不會有任何差別。"
        }

        $pattern = "(?s)" + [regex]::Escape($TuneBegin) + ".*?" + [regex]::Escape($TuneEnd) + "\r?\n?"
        if ($text -match $pattern) {
            $new = [regex]::Replace($text, $pattern, ($block + $nl), 1)
        } else {
            # 插在 developer_instructions 之前 —— 那是唯一確定存在（agent-lint 檢查 2 必填）
            # 且一定在所有純量 key 之後的錨點。
            $anchor = [regex]::Match($text, "(?m)^developer_instructions\s*=")
            if (-not $anchor.Success) {
                $warnings += "$($f.Name)：找不到 developer_instructions，跳過（agent-lint 檢查 2 會另外報這個檔）"
                continue
            }
            $new = $text.Insert($anchor.Index, $block + $nl)
        }
        if ($new -ne $text) {
            [IO.File]::WriteAllText($f.FullName, $new, $Utf8NoBom)
            $changed += $f.Name
        }
    }
    return [pscustomobject]@{ changed = $changed; warnings = $warnings }
}

# ---- 設定檔 ----
function Get-DefaultConfig([string]$root, [string]$version, [string]$preset) {
    $agentNames = @('orchestrator')
    $agentDir = Join-Path $root '.codex/agents'
    if (Test-Path $agentDir) {
        $agentNames += @(Get-ChildItem $agentDir -Filter *.toml -File | ForEach-Object { $_.BaseName } | Sort-Object)
    }

    $srcVersionRaw = Read-JsonFile (Join-Path $root $VersionRel)

    $presetMap = $null
    if ($preset) {
        $profiles = Read-JsonFile (Join-Path $root $ProfilesRel)
        if ($profiles -and $profiles.presets) {
            $presetMap = $profiles.presets.PSObject.Properties |
                         Where-Object { $_.Name -eq $preset } |
                         ForEach-Object { $_.Value } | Select-Object -First 1
        }
        if (-not $presetMap) { Warn "找不到 preset `"$preset`"，改用全部 inherit。" }
    }

    $agents = [ordered]@{}
    foreach ($n in ($agentNames | Sort-Object -Unique)) {
        $m = 'inherit'; $e = 'inherit'
        if ($presetMap) {
            $hit = $presetMap.PSObject.Properties | Where-Object { $_.Name -eq $n } | ForEach-Object { $_.Value } | Select-Object -First 1
            if ($hit) {
                if ($hit.model)  { $m = [string]$hit.model }
                if ($hit.effort) { $e = [string]$hit.effort }
            }
        }
        $agents[$n] = [ordered]@{ model = $m; effort = $e }
    }

    return [ordered]@{
        '_note'            = 'sdlc.config.json 是你的，升級永遠不覆蓋。effort/model 的 "inherit" = 產生出來的 toml 裡不寫那一行，交由 Codex CLI 決定。orchestrator 沒有 agent 定義檔，這裡只是記錄建議值，強制不了。'
        'workflow-version' = $version
        # 來源網址由**發佈物**帶進來（版本檔的 `source`），不是寫死在這支腳本裡。
        # 寫死的話，維護者換 repo 或第一次發佈時忘了改，每一個安裝出去的專案都會拿到
        # 一個指不到任何地方的網址 —— 而症狀是「沒有人告訴你有新版」，完全靜默。
        # 空字串是合法的：check-update 會直接說查不到，其餘一切照常。
        'update'           = [ordered]@{
            source  = $(if ($srcVersionRaw -and $srcVersionRaw.source) { [string]$srcVersionRaw.source } else { '' })
            channel = 'stable'
            check   = 'daily'
        }
        'agents'           = $agents
    }
}

# 升級時只補新 agent 的 key，既有的值一個字不動。
function Merge-Config($cfg, [string]$srcRoot, [string]$newVersion) {
    $added = @()
    $agentDir = Join-Path $srcRoot '.codex/agents'
    if (Test-Path $agentDir) {
        foreach ($n in @(Get-ChildItem $agentDir -Filter *.toml -File | ForEach-Object { $_.BaseName } | Sort-Object)) {
            if (-not (Get-AgentConfig $cfg $n)) {
                $cfg.agents | Add-Member -NotePropertyName $n -NotePropertyValue ([pscustomobject]@{ model = 'inherit'; effort = 'inherit' })
                $added += $n
            }
        }
    }
    $cfg.'workflow-version' = $newVersion
    return $added
}

# ---- guidelines/：唯讀檢查，一個字都不寫 ----
#
# 升級永遠不動 guidelines/，但工具那半會變，而它跟 guidelines/ 之間有一份沒寫下來的合約：
# 「檔名即路由鍵」。新版多讀一個檔名而使用者沒有那個檔 → 那一節規範完全不存在，且靜默。
function Test-Guidelines([string]$target, [string]$source) {
    $findings = @()
    $gdir = Join-Path $target 'guidelines'
    if (-not (Test-Path $gdir)) {
        return @([pscustomobject]@{ level = 'info'; text = 'guidelines/ 不存在 —— gate 靜默通過，agent 也不會去找。需要團隊規範時再建。' })
    }

    # 新版讀哪些檔名：只取每個 agent 的「## 專案規範」一節裡的 `X.md`。
    # 不掃全文 —— 全文裡的 spec.md／SKILL.md／policy 路徑會混進來。
    $wanted = @()
    $docs = @()
    $adir = Join-Path $source '.codex/agents'
    if (Test-Path $adir) { $docs += @(Get-ChildItem $adir -Filter *.toml -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) }
    foreach ($d in $docs) {
        $sec = [regex]::Match($d, '(?s)##\s*專案規範.*?(?=\r?\n##\s|\Z)')
        if (-not $sec.Success) { continue }
        $wanted += @([regex]::Matches($sec.Value, '`([a-z0-9\-]+\.md)`') | ForEach-Object { $_.Groups[1].Value })
    }
    $wanted = @($wanted | Sort-Object -Unique)

    if ($wanted.Count -gt 0) {
        $have = @(Get-ChildItem $gdir -Filter *.md -File | ForEach-Object { $_.Name })
        $missing = @($wanted | Where-Object { $_ -notin $have })
        if ($missing.Count -gt 0) {
            $findings += [pscustomobject]@{
                level = 'warn'
                text  = "新版的 agent 會讀 guidelines/ 底下這幾個檔名：$($wanted -join '、')；你缺 $($missing -join '、')。缺的那幾節規範不會生效，而且完全靜默。**不要建空檔** —— 空檔會讓 agent-lint 檢查 8 過關而內容是空的。"
            }
        }
        $orphan = @($have | Where-Object { $_ -ne 'README.md' -and $_ -notin $wanted })
        if ($orphan.Count -gt 0) {
            $findings += [pscustomobject]@{
                level = 'warn'
                text  = "這幾個規範檔新版沒有任何 agent 會讀到：$($orphan -join '、')。內容併進有讀者的檔，否則團隊以為有人在守而沒有人在守。"
            }
        }
    }

    if (Test-Path (Join-Path $gdir '.gate-disabled')) {
        $findings += [pscustomobject]@{
            level = 'warn'
            text  = 'guidelines/.gate-disabled 還在 —— 規範的機械層是關的，而且它會活過每一次升級（guidelines/ 永遠不覆蓋）。不需要就刪掉它。'
        }
    }

    $rules = Join-Path $gdir 'rules.json'
    $gate  = Join-Path $source '.codex/scripts/guideline-gate.ps1'
    if ((Test-Path $rules) -and (Test-Path $gate)) {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $gate -Validate -RulesFile $rules 2>&1
        if ($LASTEXITCODE -ne 0) {
            $findings += [pscustomobject]@{ level = 'warn'; text = "guidelines/rules.json 在新版的 guideline-gate 下驗不過：$($out -join ' ')" }
        }
    }
    return $findings
}

# ---- 子命令 ----

function Invoke-Install {
    $srcVer = Get-ContractVersion $Source
    if (-not $srcVer) { Warn "來源沒有 $VersionRel —— 這不是一份完整的發佈物。"; return 2 }

    $samePlace = (Resolve-Path $Source).Path -eq (Resolve-Path $Target).Path
    if ($samePlace -and -not $Adopt) {
        Warn "來源與目標是同一個目錄。把發佈物解壓到別處再指定 -Target，或用 -Adopt 接管這個既有安裝。"
        return 2
    }

    $cfgPath = Join-Path $Target $ConfigFile
    $writes = @(); $needsMerge = @()

    if ($Adopt) {
        if (-not (Test-Path (Join-Path $Target '.codex'))) { Warn "-Adopt 需要目標已經有 .codex/。"; return 2 }
        $tgtVer = Get-ContractVersion $Target
        Say "接管既有安裝：$((Resolve-Path $Target).Path)（版本 $($tgtVer.contract)）"
        Say '把**現況**記成基準線 —— 從現在起 update 才分得出哪些檔是你改過的。'
    } else {
        Say "安裝 $($srcVer.contract) → $((Resolve-Path $Target).Path)"
        foreach ($rel in (Get-ToolFileList $Source)) {
            $s = Join-Path $Source $rel
            $t = Join-Path $Target $rel
            # AGENTS.md 已存在是**預期狀態**（README 就叫使用者把內容合進去），不得覆蓋。
            if ($rel -eq 'AGENTS.md' -and (Test-Path $t) -and (Get-Sha256File $t) -ne (Get-Sha256File $s)) {
                Copy-Item $s "$t.new" -Force
                $needsMerge += $rel
                continue
            }
            $d = Split-Path $t -Parent
            if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            Copy-Item $s $t -Force
            $writes += $rel
        }

        # guidelines/ 是使用者的：不存在才放骨架，已存在就完全不碰（含 submodule 掛載點）。
        $gsrc = Join-Path $Source 'guidelines'
        $gdst = Join-Path $Target 'guidelines'
        if ((Test-Path $gsrc) -and -not (Test-Path $gdst)) {
            Copy-Item $gsrc $gdst -Recurse -Force
            Say 'guidelines/ 放了一份骨架 —— 這份是**你的**，換成你們自己的規範；不需要就整個刪掉，流程照常跑。升級永遠不會覆蓋它。'
        }
    }

    # 設定檔
    if (Test-Path $cfgPath) {
        Say "$ConfigFile 已存在，保留不動。"
    } else {
        Write-JsonFile $cfgPath (Get-DefaultConfig $Source $srcVer.contract $Preset)
        Say "建立 $ConfigFile$(if ($Preset) { "（preset: $Preset）" } else { '（全部 inherit）' })"
    }

    # 基準線：只記我們真的寫出去的檔。沒寫的（要合併的 AGENTS.md）不記 ——
    # 它沒有「原廠狀態」，記進去會讓下一次 update 把使用者的合併判成「改過」。
    $baseline = [ordered]@{}
    $recordSet = if ($Adopt) { Get-ToolFileList $Target } else { $writes }
    foreach ($rel in $recordSet) {
        $p = Join-Path $Target $rel
        if (Test-Path $p) { $baseline[$rel] = Get-ComparableSha $Target $rel }
    }
    Write-JsonFile (Join-Path $Target $BaselineRel) ([ordered]@{
        'workflow-version' = if ($Adopt) { (Get-ContractVersion $Target).contract } else { $srcVer.contract }
        'recorded-at'      = (Get-Date).ToString('o')
        'adopted'          = [bool]$Adopt
        'files'            = $baseline
    })

    return (Complete-Install $needsMerge)
}

function Complete-Install([string[]]$needsMerge) {
    $cfg = Read-JsonFile (Join-Path $Target $ConfigFile)
    $res = Invoke-TuningApply $Target $cfg
    if ($res.changed.Count -gt 0) { Say "apply：更新了 $($res.changed -join '、') 的 SDLC-TUNING 區塊" }
    foreach ($w in $res.warnings) { Warn $w }

    foreach ($m in $needsMerge) {
        Warn "$m 你已經有一份，沒有覆蓋 —— 新版寫成 $m.new，請把流程那幾節合進你自己那份，然後刪掉 .new。少了它整套流程不會啟動。"
    }

    foreach ($f in (Test-Guidelines $Target $Source)) {
        if ($f.level -eq 'warn') { Warn $f.text } else { Say $f.text }
    }

    $lint = Join-Path $Target '.codex/scripts/agent-lint.ps1'
    $lintOk = $true
    if (Test-Path $lint) {
        Push-Location $Target
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $lint 2>&1 | ForEach-Object { Say "  $_" }
            $lintOk = ($LASTEXITCODE -eq 0)
        } finally { Pop-Location }
    }

    $cfg = Read-JsonFile (Join-Path $Target $ConfigFile)
    $orch = Get-AgentConfig $cfg 'orchestrator'
    if ($orch -and (($orch.model -and $orch.model -ne 'inherit') -or ($orch.effort -and $orch.effort -ne 'inherit'))) {
        # orchestrator 沒有 agent 定義檔（它就是 AGENTS.md），設定檔強制不了它。
        $hint = 'codex'
        if ($orch.model  -and $orch.model  -ne 'inherit') { $hint += " --model $($orch.model)" }
        if ($orch.effort -and $orch.effort -ne 'inherit') { $hint += " -c model_reasoning_effort=$($orch.effort)" }
        Say "orchestrator 的設定強制不了（它沒有 agent 定義檔，就是 AGENTS.md 本身）。要用你記的那組值，啟動時自己下：$hint"
    }

    Say ''
    Say '裝好了。在專案裡開 Codex，直接說你要什麼即可。'
    return $(if ($lintOk) { 0 } else { 2 })
}

function Invoke-Update {
    $srcVer = Get-ContractVersion $Source
    $tgtVer = Get-ContractVersion $Target
    if (-not $srcVer) { Warn "來源沒有 $VersionRel —— 這不是一份完整的發佈物。"; return 2 }
    if ((Resolve-Path $Source).Path -eq (Resolve-Path $Target).Path) {
        Warn '來源與目標是同一個目錄。把新版發佈物解壓到別處，再從那裡跑 update -Target <你的專案>。'
        return 2
    }
    $cfgPath = Join-Path $Target $ConfigFile
    if (-not (Test-Path $cfgPath)) {
        Warn "$ConfigFile 不存在 —— 這個專案還沒被 sdlc.ps1 接管過。先跑：pwsh .codex/scripts/sdlc.ps1 install -Adopt"
        return 2
    }

    $baseline = Read-JsonFile (Join-Path $Target $BaselineRel)
    $degraded = -not ($baseline -and $baseline.files)
    if ($degraded) {
        Warn '找不到基準線（bdd-docs/.sdlc/installed-manifest.json）—— 我分不出哪些工具檔是你改過的。'
        Warn '所以下面每一個會被覆蓋的檔都會先備份，不會假設「沒動過」。'
    }

    $srcFiles = Get-ToolFileList $Source
    $unchanged = @(); $modified = @(); $added = @(); $removed = @()

    foreach ($rel in $srcFiles) {
        $t = Join-Path $Target $rel
        if (-not (Test-Path $t)) { $added += $rel; continue }
        $cur = Get-ComparableSha $Target $rel
        if ($cur -eq (Get-ComparableSha $Source $rel)) { continue }   # 內容已相同，無事可做
        $base = if (-not $degraded) { $baseline.files.PSObject.Properties | Where-Object Name -eq $rel | ForEach-Object { $_.Value } | Select-Object -First 1 } else { $null }
        if ((-not $degraded) -and $base -and $base -eq $cur) { $unchanged += $rel } else { $modified += $rel }
    }
    if (-not $degraded) {
        foreach ($p in $baseline.files.PSObject.Properties) {
            if ($p.Name -notin $srcFiles -and (Test-Path (Join-Path $Target $p.Name))) { $removed += $p.Name }
        }
    }

    $breaking = $tgtVer -and $srcVer.minCompat -and ((Compare-Semver $tgtVer.contract $srcVer.minCompat) -lt 0)

    Say "升級：$(if ($tgtVer) { $tgtVer.contract } else { '未知' }) → $($srcVer.contract)"
    Say ''
    if ($breaking) {
        Say "** 破壞性升級 ** 你的 $($tgtVer.contract) 低於新版要求的最低相容版本 $($srcVer.minCompat)。"
        Say '   升級前先看 README 的「從 v… 升上來」那幾節，手上跑到一半的需求先跑完。'
        Say ''
    }
    Say "會覆蓋（你沒動過）：$($unchanged.Count) 個"
    Say "新增：$($added.Count) 個"
    if ($modified.Count -gt 0) {
        Say ''
        Say "** 你改過的檔（$($modified.Count) 個）** —— 會先備份再覆蓋："
        foreach ($m in $modified) { Say "   $m" }
    }
    if ($removed.Count -gt 0) {
        Say ''
        Say "** 這一版刪掉的檔（$($removed.Count) 個）** —— 會備份後刪除（留著的症狀通常是靜默的）："
        foreach ($m in $removed) { Say "   $m" }
    }
    # 這一版的說明：先找檔名對得上新版號的那幾條（4.7.0 → v47*），沒有才退回第一條。
    # 拿錯條目的代價是使用者照著**別的版本**的說明做升級決定。
    if ($srcVer.raw) {
        $tag = 'v' + (($srcVer.contract -split '\.')[0..1] -join '')
        $notes = @($srcVer.raw.PSObject.Properties | Where-Object { $_.Name -like "$tag*" })
        if (-not $notes) { $notes = @($srcVer.raw.PSObject.Properties | Where-Object { $_.Name -match '^v\d' } | Select-Object -First 1) }
        foreach ($n in $notes) {
            $txt = [string]$n.Value
            Say ''
            Say "這一版[$($n.Name)]：$($txt.Substring(0, [Math]::Min(500, $txt.Length)))$(if ($txt.Length -gt 500) { '…（全文：sdlc.ps1 whatsnew）' })"
        }
    }
    Say ''

    if ($unchanged.Count -eq 0 -and $modified.Count -eq 0 -and $added.Count -eq 0 -and $removed.Count -eq 0) {
        Say '已經是最新，沒有檔要動。'
        return 0
    }
    if (-not (Confirm-Step '要升級嗎？')) { Say '已取消，一個檔都沒動。'; return 2 }

    $backupDir = Join-Path $Target "$StateDir/backup-$(if ($tgtVer) { $tgtVer.contract } else { 'unknown' })"
    foreach ($rel in @($modified + $removed)) {
        $src = Join-Path $Target $rel
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $backupDir $rel
        $d = Split-Path $dst -Parent
        if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Copy-Item $src $dst -Force
    }
    if ($modified.Count + $removed.Count -gt 0) { Say "備份：$((ConvertTo-Rel $Target (Resolve-Path $backupDir).Path))" }

    foreach ($rel in @($unchanged + $modified + $added)) {
        $t = Join-Path $Target $rel
        $d = Split-Path $t -Parent
        if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Copy-Item (Join-Path $Source $rel) $t -Force
    }
    foreach ($rel in $removed) { Remove-Item (Join-Path $Target $rel) -Force -ErrorAction SilentlyContinue }

    $cfg = Read-JsonFile $cfgPath
    $newAgents = Merge-Config $cfg $Source $srcVer.contract
    Write-JsonFile $cfgPath $cfg
    if ($newAgents.Count -gt 0) { Say "$ConfigFile：新增 agent $($newAgents -join '、')（值填 inherit），既有設定一個字沒動。" }

    $bl = [ordered]@{}
    foreach ($rel in (Get-ToolFileList $Target)) {
        $p = Join-Path $Target $rel
        if (Test-Path $p) { $bl[$rel] = Get-ComparableSha $Target $rel }
    }
    Write-JsonFile (Join-Path $Target $BaselineRel) ([ordered]@{
        'workflow-version' = $srcVer.contract
        'recorded-at'      = (Get-Date).ToString('o')
        'adopted'          = $false
        'files'            = $bl
    })

    # 新版的 toml 是原廠檔，裡面沒有 TUNING 區塊 —— 不重跑 apply，使用者的 effort 設定就沒生效。
    return (Complete-Install @())
}

function Invoke-Apply {
    $cfgPath = Join-Path $Target $ConfigFile
    $cfg = Read-JsonFile $cfgPath
    if (-not $cfg) { Warn "找不到或解析不了 $ConfigFile。"; return 2 }
    $res = Invoke-TuningApply $Target $cfg
    foreach ($w in $res.warnings) { Warn $w }
    if ($res.changed.Count -gt 0) { Say "更新了：$($res.changed -join '、')" } else { Say '沒有變更 —— toml 的 SDLC-TUNING 區塊已經跟設定檔一致。' }
    return 0
}

function Invoke-CheckUpdate {
    $cfg = Read-JsonFile (Join-Path $Target $ConfigFile)
    $tgtVer = Get-ContractVersion $Target
    if (-not $cfg -or -not $tgtVer) { Warn '這個專案還沒安裝這套工作流。'; return 2 }
    if ($cfg.update -and $cfg.update.check -eq 'never') { Say '設定為不檢查更新（update.check = never）。'; return 0 }

    $src = if ($cfg.update) { [string]$cfg.update.source } else { '' }
    if ($src -notmatch 'github\.com/([^/]+)/([^/\s]+?)(\.git)?/?$') {
        Warn "update.source 不是可辨識的 GitHub repo（$src）—— 無法自動檢查，請手動看發佈頁。"
        return 0
    }
    $api = "https://api.github.com/repos/$($Matches[1])/$($Matches[2])/releases/latest"

    try {
        $rel = Invoke-RestMethod -Uri $api -TimeoutSec 8 -Headers @{ 'User-Agent' = 'codex-sdlc' } -ErrorAction Stop
    } catch {
        # 離線、逾時、私有 repo 一律靜默 —— 檢查更新失敗不是使用者要處理的事。
        Say '檢查不到更新（離線或來源不可達）。不影響任何流程。'
        return 0
    }

    $latest = ([string]$rel.tag_name) -replace '^v', ''
    $newer  = $latest -and ((Compare-Semver $latest $tgtVer.contract) -gt 0)
    Write-JsonFile (Join-Path $Target $CacheRel) ([ordered]@{
        'checked-at' = (Get-Date).ToString('o')
        'installed'  = $tgtVer.contract
        'latest'     = $latest
        'newer'      = [bool]$newer
        'notes'      = if ($rel.body) { [string]$rel.body } else { '' }
        'url'        = [string]$rel.html_url
        'seen'       = ''
    })
    if ($newer) { Say "有新版 $latest（你在 $($tgtVer.contract)）。看變更：pwsh .codex/scripts/sdlc.ps1 whatsnew" }
    else        { Say "已是最新（$($tgtVer.contract)）。" }
    return 0
}

function Invoke-WhatsNew {
    $cache = Read-JsonFile (Join-Path $Target $CacheRel)
    if ($cache -and $cache.newer) {
        Say "新版 $($cache.latest)（你在 $($cache.installed)）"
        if ($cache.url) { Say $cache.url }
        Say ''
        if ($cache.notes) { Say $cache.notes }
        # 看過就安靜下來，直到下一個版本 —— 通知的目的是讓你看一次，不是每次 spawn 都提醒。
        $cache.seen = $cache.latest
        Write-JsonFile (Join-Path $Target $CacheRel) $cache
        Say ''
        Say '要升級：把新版發佈物解壓到別處，然後 pwsh <發佈物>/.codex/scripts/sdlc.ps1 update -Target .'
        return 0
    }
    $v = Get-ContractVersion $Target
    if (-not $v) { Warn '這個專案還沒安裝這套工作流。'; return 2 }
    Say "目前版本 $($v.contract)（最低相容 $($v.minCompat)）。這一版的變更說明："
    foreach ($p in @($v.raw.PSObject.Properties | Where-Object { $_.Name -match '^v\d' })) {
        Say ''
        Say "[$($p.Name)] $($p.Value)"
    }
    return 0
}

function Invoke-Tune {
    $cfgPath = Join-Path $Target $ConfigFile
    $cfg = Read-JsonFile $cfgPath
    if (-not $cfg) { Warn "找不到 $ConfigFile。先跑 install。"; return 2 }

    # 訊號：只用便宜的。repo-index -StatusOnly 不讀任何檔內容。
    $signals = [ordered]@{ file_count = $null; language = ''; build_tool = ''; legacy_schema = 0 }
    $idx = Join-Path $Target '.codex/scripts/repo-index.ps1'
    if (Test-Path $idx) {
        Push-Location $Target
        try {
            $raw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $idx -StatusOnly 2>$null
            $st = $raw | ConvertFrom-Json
            $signals.file_count = $st.file_count
            $signals.language   = [string]$st.language
            $signals.build_tool = [string]$st.build_tool
        } catch {
            # 索引拿不到就用不到訊號，但 tune 仍然要能跑完 —— 它是使用者主動叫的，不該卡住。
            Warn "repo-index 取不到訊號（$($_.Exception.Message)），改用可得的部分。"
        } finally { Pop-Location }
    }
    $legacy = Join-Path $Target 'bdd-docs/artifacts/legacy-schema'
    if (Test-Path $legacy) { $signals.legacy_schema = @(Get-ChildItem $legacy -Filter *.sql -File -ErrorAction SilentlyContinue).Count }

    $fc = if ($null -ne $signals.file_count) { [int]$signals.file_count } else { -1 }
    $items = @()

    # sa-analyst：成本驅動是**讀取量**，而讀取量大時的失敗模式是逾時，不是想得不夠深。
    # 所以大 repo 往下調 —— 釘 high 正是大型 legacy repo 分析逾時的成因（1d8e411 → 7159725）。
    if ($fc -ge 8000) {
        $items += @{ agent='sa-analyst'; effort='low'; reason='repo 很大，analyze 的失敗模式是逾時而不是想得不夠深'; signal="file_count=$fc" }
    } elseif ($fc -ge 3000 -or $signals.legacy_schema -gt 0) {
        $items += @{ agent='sa-analyst'; effort='medium'; reason='讀取量偏大或有舊系統逆推，往下調並把 analyze 的範圍切小'; signal="file_count=$fc, legacy-schema=$($signals.legacy_schema)" }
    } else {
        $items += @{ agent='sa-analyst'; effort='inherit'; reason='規模不大，沒有理由付'; signal="file_count=$fc" }
    }

    if ($signals.legacy_schema -gt 0) {
        $items += @{ agent='implementer'; effort='medium'; reason='要對著逆推回來的舊邏輯寫，測試回圈會變長'; signal="legacy-schema=$($signals.legacy_schema) 個 .sql" }
    } else {
        $items += @{ agent='implementer'; effort='inherit'; reason='成本在測試回圈的次數，不在單次推理深度；衝 high 買不到東西'; signal='—' }
    }

    $items += @{ agent='reviewer'; effort='high'; reason='輸入小、判斷密度高，而且 ⑤ 只有 3 輪修正額度 —— 審得淺就是白付'; signal='一律' }
    $items += @{ agent='orchestrator'; effort='inherit'; reason='它沒有 agent 定義檔，這裡只是記錄；要生效得在 CLI 啟動時自己下'; signal='—' }

    Write-JsonFile (Join-Path $Target $ProposalRel) ([ordered]@{
        'generated-at' = (Get-Date).ToString('o')
        'signals'      = $signals
        'proposal'     = $items
    })

    Say "訊號：file_count=$fc、language=$($signals.language)、build_tool=$($signals.build_tool)、legacy-schema=$($signals.legacy_schema)"
    Say ''
    foreach ($i in $items) {
        $cur = Get-AgentConfig $cfg $i.agent
        $now = if ($cur -and $cur.effort) { [string]$cur.effort } else { 'inherit' }
        $mark = if ($now -eq $i.effort) { ' ' } else { '*' }
        Say "$mark $($i.agent)：$now → $($i.effort)"
        Say "    理由：$($i.reason)"
        Say "    訊號：$($i.signal)"
    }
    Say ''
    Say "提議寫在 $ProposalRel。這是提議不是動作 —— 要套用：sdlc.ps1 tune -ApplyProposal"

    if ($ApplyProposal) {
        foreach ($i in $items) {
            $cur = Get-AgentConfig $cfg $i.agent
            if ($cur) { $cur.effort = $i.effort }
        }
        Write-JsonFile $cfgPath $cfg
        Say ''
        Say '已寫回設定檔，接著跑 apply。'
        return (Invoke-Apply)
    }
    return 0
}

function Invoke-Doctor {
    $problems = 0
    $v = Get-ContractVersion $Target
    if (-not $v) { Warn "$VersionRel 不存在或解析不了。"; return 2 }
    Say "版本 $($v.contract)（最低相容 $($v.minCompat)）"

    $cfgPath = Join-Path $Target $ConfigFile
    $cfg = Read-JsonFile $cfgPath
    if (-not $cfg) {
        Say "$ConfigFile 不存在 —— per-agent 調校未啟用，全部交由 Codex CLI 決定（這是合法狀態）。"
    } else {
        $stale = @()
        foreach ($f in @(Get-ChildItem (Join-Path $Target '.codex/agents') -Filter *.toml -File -ErrorAction SilentlyContinue)) {
            $text = [IO.File]::ReadAllText($f.FullName)
            $want = Get-TuningSha (Get-AgentConfig $cfg $f.BaseName)
            $m = [regex]::Match($text, [regex]::Escape($TuneBegin) + '\s+sha=([0-9a-f]{8})')
            if (-not $m.Success -or $m.Groups[1].Value -ne $want) { $stale += $f.Name }
        }
        if ($stale.Count -gt 0) {
            Warn "SDLC-TUNING 區塊跟設定檔對不上：$($stale -join '、') —— 跑 pwsh .codex/scripts/sdlc.ps1 apply"
            $problems++
        } else {
            Say '調校區塊與設定檔一致。'
        }
        foreach ($p in @($cfg.agents.PSObject.Properties)) {
            if ($p.Value.model -and $p.Value.model -ne 'inherit') {
                Warn "$($p.Name)：設了 model=`"$($p.Value.model)`" —— 這個 key 尚未在本工作流驗證過，Codex 若忽略它會靜默地用預設模型跑。"
            }
        }
    }

    $baseline = Read-JsonFile (Join-Path $Target $BaselineRel)
    if (-not $baseline) { Say '沒有基準線 —— update 將無法分辨你改過哪些工具檔。跑 install -Adopt 建立一次。' }
    else { Say "基準線：$($baseline.'workflow-version')（$(@($baseline.files.PSObject.Properties).Count) 個檔）" }

    foreach ($f in (Test-Guidelines $Target $Target)) {
        if ($f.level -eq 'warn') { Warn $f.text; $problems++ } else { Say $f.text }
    }

    $lint = Join-Path $Target '.codex/scripts/agent-lint.ps1'
    if (Test-Path $lint) {
        Push-Location $Target
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $lint 2>&1 | ForEach-Object { Say "  $_" }
            if ($LASTEXITCODE -ne 0) { $problems++ }
        } finally { Pop-Location }
    }

    $cache = Read-JsonFile (Join-Path $Target $CacheRel)
    if ($cache -and $cache.newer -and $cache.seen -ne $cache.latest) { Say "有新版 $($cache.latest) —— pwsh .codex/scripts/sdlc.ps1 whatsnew" }

    return $(if ($problems -gt 0) { 2 } else { 0 })
}

# ---- 派送 ----
$code = switch ($Command) {
    'install'      { Invoke-Install }
    'update'       { Invoke-Update }
    'apply'        { Invoke-Apply }
    'check-update' { Invoke-CheckUpdate }
    'whatsnew'     { Invoke-WhatsNew }
    'tune'         { Invoke-Tune }
    'doctor'       { Invoke-Doctor }
}

if ($Json) {
    [pscustomobject]@{ command = $Command; exit = $code; output = $script:Notes } | ConvertTo-Json -Depth 5 -Compress
}
exit $code
