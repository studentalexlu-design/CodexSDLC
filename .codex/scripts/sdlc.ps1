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
# 更新通知刻意**不在這裡**：它折進 handoff-lint.ps1 的尾端，只讀快取、不碰網路、只喊一行。
# 流程裡不得冒出更新確認 —— AGENTS.md 的「必經的確認只有兩個」是硬不變量。
#
# **-Json 是給程式讀的合約**（VS Code extension 讀它）：`{ schema, command, exit, data, warnings, output }`。
# `data` 是結構化欄位，`output`／`warnings` 是給人看的句子。**呼叫端只准讀 data** —— 從中文句子裡撈狀態，
# 改一句措辭就會讓讀的人靜默地顯示錯的東西。欄位改名或改義就要把 $JsonSchema 加一。
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
    [switch]$WithEditor,                   # install 用：順便把發佈物附的 VS Code extension 裝進這台機器的編輯器
    [switch]$ApplyProposal,                # tune 用：把提議寫回設定檔
    [switch]$IfDue,                        # check-update 用：照 update.check 的頻率決定要不要真的連網
    [string]$CodexPath,                    # doctor 用：codex 執行檔（預設找 PATH）；查 hooks 信任狀態要問它
    [string]$EditorHome,                   # 找已安裝 extension 的家目錄（預設 = 使用者家目錄；測試用）
    [switch]$Yes,                          # 非互動確認
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# Codex 送進來的 payload 是 UTF-8、也用 UTF-8 解讀 hook 的輸出；Windows 上 [Console] 的編碼卻跟著 console 的
# code page 走（zh-TW 是 cp950；並行的 hook 共用同一個 console，偶爾連輸出端也是）。Codex 0.154.0 實測的後果：
# 一份 743 字、meta 完整的中文 handoff 被解成 1772 字、JSON 解析失敗、抓不到 mode —— **每一次 spawn 都被擋**；
# 阻斷理由的中文到模型手上是亂碼。只在被重導向時才換：人在終端機跑的時候照 console 的 code page 顯示。
# 同一段在 handoff-lint／dlp-gate／guideline-gate／build-check／agent-lint／sdlc.ps1 各有一份。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
}

# ---- 常數 ----
# 工具那半。guidelines/ 與 bdd-docs/ 刻意不在裡面 —— 它們是使用者的。
$ToolRoots   = @('.codex', '.agents')
$ToolFiles   = @('AGENTS.md')
$VersionRel  = '.codex/bdd-workflow/bdd-workflow-version.json'
$ProfilesRel = '.codex/bdd-workflow/tuning-profiles.json'
$ManifestRel = '.codex/bdd-workflow/manifest.json'          # 發佈物自帶，不列入自己
$HooksRel    = '.codex/hooks.json'
$StateDir    = 'bdd-docs/.sdlc'
$BaselineRel = "$StateDir/installed-manifest.json"
$CacheRel    = "$StateDir/update-cache.json"
$ProposalRel = "$StateDir/tuning-proposal.json"

$TuneBegin   = '# SDLC-TUNING:BEGIN'
$TuneEnd     = '# SDLC-TUNING:END'
$KnownEfforts = @('minimal', 'low', 'medium', 'high')
# 修正輪上限的預設值。範圍（1–5）不在這裡驗 —— 那是 handoff-lint 與 agent-lint 檢查 13 的事，doctor 讀 lint 的結論。
$DefaultReviewRounds = 3

$JsonSchema  = 1
$ExtensionId = 'codex-sdlc.codex-sdlc'
# 編輯器的 CLI 名稱與各自的 extension 目錄。VS Code／Insiders／Cursor／Windsurf／VSCodium 都吃同一個 .vsix，
# 但執行檔名與目錄各一個 —— 只找 `code` 的話，另外四種的使用者會收到一句「找不到」而他們明明裝了編輯器。
$Editors = @(
    [pscustomobject]@{ product = 'VS Code';          cli = 'code';          dir = '.vscode' }
    [pscustomobject]@{ product = 'VS Code Insiders'; cli = 'code-insiders'; dir = '.vscode-insiders' }
    [pscustomobject]@{ product = 'Cursor';           cli = 'cursor';        dir = '.cursor' }
    [pscustomobject]@{ product = 'Windsurf';         cli = 'windsurf';      dir = '.windsurf' }
    [pscustomobject]@{ product = 'VSCodium';         cli = 'codium';        dir = '.vscode-oss' }
)

if (-not $Source) { $Source = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
if (-not $EditorHome) { $EditorHome = [Environment]::GetFolderPath('UserProfile') }

# 路徑不存在時給一句人看得懂的話，而不是讓 Resolve-Path 丟出堆疊 ——
# 「擋下的理由跟使用者要做的事無關，而且他也修不了」是這套流程踩過兩次的失敗形狀。
foreach ($pair in @(@{ n = '-Source'; v = $Source }, @{ n = '-Target'; v = $Target })) {
    if (-not (Test-Path $pair.v)) {
        [Console]::Error.WriteLine("[sdlc] $($pair.n) 指向的路徑不存在：$($pair.v)")
        if ($Json) {
            [Console]::Out.WriteLine(([ordered]@{ schema = $JsonSchema; command = $Command; exit = 2; data = [ordered]@{ error = 'path-not-found'; param = $pair.n }; warnings = @("$($pair.n) 指向的路徑不存在：$($pair.v)"); output = @() } | ConvertTo-Json -Depth 4 -Compress))
        }
        exit 2
    }
}

$script:Notes = @()
$script:Warnings = @()
$script:Data = [ordered]@{}
# 直接寫 stdout，**不能用 Write-Output**：這些訊息是從有回傳值的函式裡發出的，
# 走輸出串流會跟 return 的 exit code 混在同一個陣列裡 —— 症狀是整支腳本一個字都不印，
# 而且 exit code 變成一個字串陣列。
function Say([string]$m)  { $script:Notes += $m; if (-not $Json) { [Console]::Out.WriteLine($m) } }
function Warn([string]$m) { $script:Warnings += $m; [Console]::Error.WriteLine("[sdlc] $m") }

# ---- 共用工具 ----
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

# ConvertFrom-Json 會把 ISO 時間字串變成 [DateTime]，而 [string]$dt 是**依文化**的格式（「2026/9/13 上午 06:56」）。
# -Json 的讀者要的是 ISO。
function ConvertTo-IsoText($v) {
    if ($null -eq $v -or $v -eq '') { return $null }
    if ($v -is [DateTime]) { return $v.ToString('o') }
    return [string]$v
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

# 跑另一支 pwsh 腳本並收回輸出，一律 UTF-8。
# 不用 `& pwsh ... 2>&1`：PowerShell 會拿 console 的 code page 解碼子行程的輸出，
# 而子行程被重導向時寫的是 UTF-8（見「標準 I/O」段）—— 兩邊對不上，中文就是亂碼，JSON 就解析失敗。
# 用執行中的這一支 pwsh，不去 PATH 找：從 VS Code 叫起來的時候 PATH 裡不一定有它。
function Invoke-PwshScript([string]$file, [string[]]$arguments = @(), [string]$cwd = (Get-Location).Path) {
    $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file) + $arguments) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory       = $cwd
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $Utf8NoBom
    $psi.StandardErrorEncoding  = $Utf8NoBom
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    return [pscustomobject]@{ exit = $p.ExitCode; stdout = $o.GetAwaiter().GetResult(); stderr = $e.GetAwaiter().GetResult() }
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
        '_note'            = 'sdlc.config.json 是你的，升級永遠不覆蓋。effort/model 的 "inherit" = 產生出來的 toml 裡不寫那一行，交由 Codex CLI 決定（改完要跑 apply）。orchestrator 沒有 agent 定義檔，這裡只是記錄建議值，強制不了。review.maxRounds = ⑤ 審核的修正輪上限（1–5，預設 3），handoff-lint 每次現讀，不必 apply。'
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
        # ⑤ 的修正輪上限。由 handoff-lint 每次現讀（不寫進 hooks.json：hook 指令一改，Codex 就要你重新信任它）。
        'review'           = [ordered]@{ maxRounds = $DefaultReviewRounds }
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
#
# 每一條 finding 帶一個 code（absent／missing／orphan／gate-disabled／rules-invalid）給 -Json 的讀者用。
function Test-Guidelines([string]$target, [string]$source) {
    $findings = @()
    $gdir = Join-Path $target 'guidelines'
    if (-not (Test-Path $gdir)) {
        return @([pscustomobject]@{ level = 'info'; code = 'absent'; text = 'guidelines/ 不存在 —— gate 靜默通過，agent 也不會去找。需要團隊規範時再建。' })
    }

    # 新版讀哪些檔名：只取每個 agent 的「專案規範」那一節裡的 `X.md`。不掃全文 —— 全文裡的 spec.md／SKILL.md 會混進來。
    #
    # 那一節在哪裡結束，看的是**標題層級**：碰到同級或更高的下一個標題就停。
    # 舊版寫死「停在下一個 `## `」—— sa-analyst 的那一節是 `###`，於是一路讀進下一節
    # 「精度是事實」，把那裡的 `spec.md` 當成規範檔名，每一次 install／update／doctor 都報「你缺 spec.md」，
    # 而 doctor 因此永遠是紅的。一個永遠紅的健檢，就是一個沒有人會再看的健檢。
    $wanted = @()
    $adir = Join-Path $source '.codex/agents'
    $docs = @()
    if (Test-Path $adir) { $docs += @(Get-ChildItem $adir -Filter *.toml -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) }
    foreach ($d in $docs) {
        foreach ($h in [regex]::Matches($d, '(?m)^(#{2,6})[ \t]*專案規範.*$')) {
            $level = $h.Groups[1].Value.Length
            $rest  = $d.Substring($h.Index + $h.Length)
            $next  = [regex]::Match($rest, "(?m)^#{1,$level}[ \t]")
            $sec   = if ($next.Success) { $rest.Substring(0, $next.Index) } else { $rest }
            $wanted += @([regex]::Matches($sec, '`([a-z0-9\-]+\.md)`') | ForEach-Object { $_.Groups[1].Value })
        }
    }
    $wanted = @($wanted | Sort-Object -Unique)

    if ($wanted.Count -gt 0) {
        $have = @(Get-ChildItem $gdir -Filter *.md -File | ForEach-Object { $_.Name })
        $missing = @($wanted | Where-Object { $_ -notin $have })
        if ($missing.Count -gt 0) {
            $findings += [pscustomobject]@{
                level = 'warn'; code = 'missing'
                text  = "新版的 agent 會讀 guidelines/ 底下這幾個檔名：$($wanted -join '、')；你缺 $($missing -join '、')。缺的那幾節規範不會生效，而且完全靜默。**不要建空檔** —— 空檔會讓 agent-lint 檢查 8 過關而內容是空的。"
            }
        }
        $orphan = @($have | Where-Object { $_ -ne 'README.md' -and $_ -notin $wanted })
        if ($orphan.Count -gt 0) {
            $findings += [pscustomobject]@{
                level = 'warn'; code = 'orphan'
                text  = "這幾個規範檔新版沒有任何 agent 會讀到：$($orphan -join '、')。內容併進有讀者的檔，否則團隊以為有人在守而沒有人在守。"
            }
        }
    }

    if (Test-Path (Join-Path $gdir '.gate-disabled')) {
        $findings += [pscustomobject]@{
            level = 'warn'; code = 'gate-disabled'
            text  = 'guidelines/.gate-disabled 還在 —— 規範的機械層是關的，而且它會活過每一次升級（guidelines/ 永遠不覆蓋）。不需要就刪掉它。'
        }
    }

    $rules = Join-Path $gdir 'rules.json'
    $gate  = Join-Path $source '.codex/scripts/guideline-gate.ps1'
    if ((Test-Path $rules) -and (Test-Path $gate)) {
        $r = Invoke-PwshScript $gate @('-Validate', '-RulesFile', (Resolve-Path $rules).Path)
        if ($r.exit -ne 0) {
            $findings += [pscustomobject]@{ level = 'warn'; code = 'rules-invalid'; text = "guidelines/rules.json 在新版的 guideline-gate 下驗不過：$(($r.stderr + $r.stdout).Trim() -replace '\s*\r?\n\s*', ' ')" }
        }
    }
    return $findings
}

function Get-FindingData($findings) {
    return @($findings | ForEach-Object { [ordered]@{ level = $_.level; code = $_.code; text = $_.text } })
}

# ---- agent-lint：一律用 -Json 收回來，人看的句子由這裡排 ----
function Invoke-Lint([string]$root) {
    $lint = Join-Path $root '.codex/scripts/agent-lint.ps1'
    if (-not (Test-Path $lint)) { return [ordered]@{ ran = $false; passed = $true; violations = @() } }
    $r = Invoke-PwshScript $lint @('-Json') $root
    $j = $null
    try { $j = $r.stdout.Trim() | ConvertFrom-Json } catch { }
    if (-not $j) {
        # lint 自己炸了（例如沒有任何 agent toml）：不是「通過」，把它說的話原樣交出去。
        $msg = ($r.stderr + $r.stdout).Trim()
        Say "  [agent-lint] 沒有跑完：$msg"
        return [ordered]@{ ran = $true; passed = $false; error = $msg; violations = @() }
    }
    $violations = @($j.violations | ForEach-Object { [ordered]@{ rule = [string]$_.rule; detail = [string]$_.detail; fix = [string]$_.fix } })
    if ($j.passed) {
        Say "  [agent-lint] OK —— $($j.subagent_count) 個子代理 ＋ orchestrator，共用核心一致、路由對得上、沒有斷掉或過期的引用。"
    } else {
        Say "  [agent-lint] $($violations.Count) 項違規："
        foreach ($v in $violations) { Say "  - $($v.rule): $($v.detail)"; Say "    fix: $($v.fix)" }
    }
    return [ordered]@{ ran = $true; passed = [bool]$j.passed; violations = $violations }
}

# ---- Codex 的 hook 信任狀態 ----
#
# Codex（0.154.0 實測）要**兩層信任**才會跑 `.codex/hooks.json`：專案本身被信任，而且每一條 hook 被信任。
# 信任記在**使用者的** `~/.codex/config.toml`（以 hooks.json 的絕對路徑為 key、hook 定義的雜湊為值），
# 所以：新裝的專案一定還沒信任；hooks.json 的某一條被改過（例如升級）那一條就變成「待重審」；專案搬了目錄就全部重來。
# 沒信任的 hook **一條都不會跑，而且沒有任何提示** —— 機械強制層整層不在，畫面上一切正常。
#
# 信任狀態只有 Codex 自己知道（雜湊怎麼算是它的實作），所以這裡**問它**（`codex app-server` 的 `hooks/list`），不自己算。
# 啟動 app-server 時它會去連 chatgpt.com 與 github.com（實測），所以子行程的 proxy 一律指向一個一定連不上的位址 ——
# doctor 從構造上就碰不到網路，不靠 Codex 哪一版剛好沒有連。
function Resolve-Codex {
    if ($CodexPath) { return $(if (Test-Path $CodexPath) { (Resolve-Path $CodexPath).Path } else { $null }) }
    $c = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    return $(if ($c) { $c.Source } else { $null })
}

function Invoke-CodexHooksList([string]$codex, [string]$cwd, [int]$timeoutMs = 15000) {
    $psi = [Diagnostics.ProcessStartInfo]::new($codex)
    $psi.ArgumentList.Add('app-server')
    $psi.WorkingDirectory       = $cwd
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardInputEncoding  = $Utf8NoBom
    $psi.StandardOutputEncoding = $Utf8NoBom
    $psi.StandardErrorEncoding  = $Utf8NoBom
    foreach ($k in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) { $psi.Environment[$k] = 'http://127.0.0.1:9' }
    foreach ($k in @('NO_PROXY', 'no_proxy')) { [void]$psi.Environment.Remove($k) }
    $p = $null
    try {
        $p = [Diagnostics.Process]::Start($psi)
        $null = $p.StandardError.ReadToEndAsync()          # 不讀的話它的 log 寫滿管線就卡住
        $init = [ordered]@{ id = 1; method = 'initialize'; params = [ordered]@{ clientInfo = [ordered]@{ name = 'codex-sdlc-doctor'; title = $null; version = '1' }; capabilities = $null } }
        $p.StandardInput.WriteLine(($init | ConvertTo-Json -Depth 5 -Compress))
        $p.StandardInput.WriteLine('{"method":"initialized","params":{}}')
        $p.StandardInput.WriteLine(([ordered]@{ id = 2; method = 'hooks/list'; params = [ordered]@{ cwds = @($cwd) } } | ConvertTo-Json -Depth 5 -Compress))
        $p.StandardInput.Flush()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
        while ($true) {
            $left = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0) { return $null }
            $t = $p.StandardOutput.ReadLineAsync()
            if (-not $t.Wait([int][Math]::Ceiling($left))) { return $null }
            $line = $t.Result
            if ($null -eq $line) { return $null }
            $msg = $null
            try { $msg = $line | ConvertFrom-Json } catch { continue }
            if ($msg -and $msg.PSObject.Properties['id'] -and $msg.id -eq 2) { return $msg }
        }
    } catch {
        return $null
    } finally {
        if ($p) { try { if (-not $p.HasExited) { $p.Kill($true) } } catch { }; $p.Dispose() }
    }
}

function Get-HookTrust([string]$target) {
    $hooksFile = Join-Path $target $HooksRel
    if (-not (Test-Path $hooksFile)) { return [ordered]@{ status = 'no-hooks'; codex = $null } }
    $codex = Resolve-Codex
    if (-not $codex) { return [ordered]@{ status = 'unknown'; reason = 'codex-not-found'; codex = $null } }

    $root = (Resolve-Path $target).Path
    $msg = Invoke-CodexHooksList $codex $root
    if (-not $msg -or -not $msg.result) {
        return [ordered]@{ status = 'unknown'; reason = $(if ($msg -and $msg.error) { 'query-failed' } else { 'no-response' }); codex = $codex }
    }

    $want = ((Resolve-Path $hooksFile).Path -replace '\\', '/').ToLowerInvariant()
    $mine = @($msg.result.data | ForEach-Object { @($_.hooks) } |
              Where-Object { $_ -and ([string]$_.sourcePath -replace '\\', '/').ToLowerInvariant() -eq $want })
    $counts = [ordered]@{
        total     = $mine.Count
        trusted   = @($mine | Where-Object { $_.trustStatus -in @('trusted', 'managed') -and $_.enabled -ne $false }).Count
        untrusted = @($mine | Where-Object trustStatus -eq 'untrusted').Count
        modified  = @($mine | Where-Object trustStatus -eq 'modified').Count
        disabled  = @($mine | Where-Object { $_.enabled -eq $false }).Count
    }
    # hooks.json 在、Codex 卻一條都沒列出來 = 專案本身沒被信任（專案層的 config 與 hooks 整個停用）。
    $status = if ($mine.Count -eq 0) { 'project-untrusted' }
              elseif ($counts.trusted -eq $counts.total) { 'trusted' }
              else { 'untrusted' }
    return [ordered]@{ status = $status; codex = $codex; counts = $counts }
}

function Show-HookTrust($trust) {
    switch ($trust.status) {
        'trusted' {
            Say "Codex hooks：$($trust.counts.total) 條都已信任 —— 機械強制層會跑。"
            return 0
        }
        'untrusted' {
            $c = $trust.counts
            $parts = @()
            if ($c.untrusted) { $parts += "$($c.untrusted) 條未信任" }
            if ($c.modified)  { $parts += "$($c.modified) 條改過、待重新審核" }
            if ($c.disabled)  { $parts += "$($c.disabled) 條被停用" }
            Warn "Codex 還沒信任這個專案的 hooks（$($parts -join '、')）—— 沒信任的那幾條（handoff-lint／dlp-gate／guideline-gate／build-check）一次都不會跑，而且不會有任何提示。在專案裡開 codex，出現「Hooks need review」時選 Trust all and continue。"
            return 1
        }
        'project-untrusted' {
            Warn 'Codex 還沒信任這個專案 —— 專案層的 .codex/config.toml 與 hooks 整個停用，機械強制層一條都不會跑。在專案裡開 codex，信任這個資料夾，接著在「Hooks need review」選 Trust all and continue。'
            return 1
        }
        'unknown' {
            $why = if ($trust.reason -eq 'codex-not-found') { '找不到 codex 執行檔' } else { '問 codex 沒有得到回應' }
            Say "無法確認 Codex 是否信任了這個專案的 hooks（$why）。信任狀態只有 Codex 自己知道：開 codex 時若出現「Hooks need review」，要選 Trust all and continue，否則強制層不會跑。"
            return 0
        }
        default { return 0 }
    }
}

# ---- VS Code extension（每台機器一份，不屬於任何一個專案）----
#
# 它不在工具那半、也不在使用者那半：裝在編輯器自己的目錄，所有專案共用。所以——
#   不進 manifest、不進基準線（update 分不出、也不該分使用者有沒有「改過」一個 vsix）；
#   update **不替你重裝**（一個專案的升級不該動到另一個專案也在用的編輯器），版本對不上只說一行；
#   只有 install 帶了 -WithEditor 才裝，而且沒有「以後都自動裝」這個選項。
function Find-ReleaseVsix([string]$root, [string]$version) {
    $dir = Join-Path $root 'editor'
    if (-not (Test-Path $dir)) { return $null }
    $exact = Join-Path $dir "codex-sdlc-$version.vsix"
    if (Test-Path $exact) { return (Resolve-Path $exact).Path }
    $any = Get-ChildItem $dir -Filter 'codex-sdlc-*.vsix' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return $(if ($any) { $any.FullName } else { $null })
}

function Find-EditorClis {
    return @($Editors | ForEach-Object {
        $c = Get-Command $_.cli -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { [pscustomobject]@{ product = $_.product; cli = $_.cli; path = $c.Source } }
    })
}

# 讀編輯器自己的 extensions.json（沒有才退回掃目錄）—— 不需要 `code` 在 PATH 上，macOS 沒裝 shell 指令的人也查得到。
function Get-InstalledExtensions {
    $found = @()
    foreach ($e in $Editors) {
        $extDir = Join-Path (Join-Path $EditorHome $e.dir) 'extensions'
        if (-not (Test-Path $extDir)) { continue }
        $hit = $null
        $registry = Join-Path $extDir 'extensions.json'
        if (Test-Path $registry) {
            try {
                $entries = @(Get-Content $registry -Raw -Encoding UTF8 | ConvertFrom-Json)
                $entry = $entries | Where-Object { $_.identifier -and [string]$_.identifier.id -ieq $ExtensionId } | Select-Object -Last 1
                if ($entry) {
                    $loc = if ($entry.relativeLocation) { Join-Path $extDir $entry.relativeLocation } else { $null }
                    $hit = [pscustomobject]@{ version = [string]$entry.version; location = $loc }
                }
            } catch { }
        }
        if (-not $hit) {
            $obsolete = @()
            $obsFile = Join-Path $extDir '.obsolete'
            if (Test-Path $obsFile) { try { $obsolete = @((Get-Content $obsFile -Raw | ConvertFrom-Json).PSObject.Properties.Name) } catch { } }
            $dir = Get-ChildItem $extDir -Directory -Filter "$ExtensionId-*" -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notin $obsolete } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($dir) { $hit = [pscustomobject]@{ version = ($dir.Name.Substring($ExtensionId.Length + 1) -replace '-.*$', ''); location = $dir.FullName } }
        }
        if (-not $hit) { continue }

        # 相容與否看它讀得懂的 -Json 形狀（package.json 的 codexSdlc.jsonSchema），不是看版本號像不像。
        $schema = $null
        if ($hit.location) {
            $pkg = Read-JsonFile (Join-Path $hit.location 'package.json')
            if ($pkg -and $pkg.codexSdlc -and $null -ne $pkg.codexSdlc.jsonSchema) { $schema = [int]$pkg.codexSdlc.jsonSchema }
        }
        $found += [pscustomobject]@{ product = $e.product; version = $hit.version; jsonSchema = $schema; compatible = ($schema -eq $JsonSchema) }
    }
    return $found
}

function Install-Editor([string]$vsix) {
    $result = [ordered]@{ vsix = $vsix; requested = [bool]$WithEditor; installed = $false; product = $null; cli = $null; error = $null }
    if (-not $vsix) {
        if ($WithEditor) {
            Warn '這份發佈物沒有附 VS Code extension（editor/ 底下沒有 .vsix）—— 工作流照常裝好了，只是沒有編輯器那一層。'
            $result.error = 'no-vsix'
        }
        return $result
    }
    if (-not $WithEditor) {
        Say "發佈物附了 VS Code extension（狀態列、Problems、一鍵 doctor／apply）。要裝：code --install-extension `"$vsix`"（Cursor／Windsurf／VSCodium 換成各自的指令）。它是每台機器一份、所有專案共用。"
        return $result
    }

    $clis = @(Find-EditorClis)
    if ($clis.Count -eq 0) {
        # 查不到就說怎麼手動裝 —— 不丟例外：擋下的理由跟他要做的事無關，而且他修不了。
        Warn "找不到編輯器的指令（code／code-insiders／cursor／windsurf／codium 都不在 PATH）—— 工作流照常裝好了。手動裝 extension：編輯器的 Extensions 面板 → … → Install from VSIX，選 $vsix"
        $result.error = 'cli-not-found'
        return $result
    }
    $pick = $clis[0]
    $result.cli = $pick.cli; $result.product = $pick.product
    $out = & $pick.path --install-extension $vsix --force 2>&1
    if ($LASTEXITCODE -ne 0) {
        Warn "extension 沒裝成（$($pick.cli) --install-extension 回 $LASTEXITCODE）：$((@($out) -join ' ').Trim()) —— 工作流照常裝好了。可以手動再試：$($pick.cli) --install-extension `"$vsix`" --force"
        $result.error = 'install-failed'
        return $result
    }
    $result.installed = $true
    Say "VS Code extension 裝進了 $($pick.product)。**它是每台機器一份、所有專案共用** —— 刪掉這個專案不會移除它，要移除：$($pick.cli) --uninstall-extension $ExtensionId"
    if ($clis.Count -gt 1) {
        Say "  另外找到 $(@($clis | Select-Object -Skip 1 | ForEach-Object { $_.product }) -join '、')；要裝進去就各自跑 <指令> --install-extension `"$vsix`""
    }
    return $result
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
    $script:Data.mode    = if ($Adopt) { 'adopt' } else { 'install' }
    $script:Data.target  = (Resolve-Path $Target).Path
    $script:Data.version = $srcVer.contract
    $script:Data.guidelinesSkeleton = $false

    if ($Adopt) {
        if (-not (Test-Path (Join-Path $Target '.codex'))) { Warn "-Adopt 需要目標已經有 .codex/。"; return 2 }
        $tgtVer = Get-ContractVersion $Target
        $script:Data.version = if ($tgtVer) { $tgtVer.contract } else { $null }
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
            $script:Data.guidelinesSkeleton = $true
            Say 'guidelines/ 放了一份骨架 —— 這份是**你的**，換成你們自己的規範；不需要就整個刪掉，流程照常跑。升級永遠不會覆蓋它。'
        }
    }
    $script:Data.written    = $writes.Count
    $script:Data.needsMerge = @($needsMerge)

    # 設定檔
    if (Test-Path $cfgPath) {
        $script:Data.config = [ordered]@{ created = $false; preset = $null }
        Say "$ConfigFile 已存在，保留不動。"
    } else {
        Write-JsonFile $cfgPath (Get-DefaultConfig $Source $srcVer.contract $Preset)
        $script:Data.config = [ordered]@{ created = $true; preset = $(if ($Preset) { $Preset } else { $null }) }
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

    $code = Complete-Install $needsMerge ($HooksRel -in $writes)
    # extension 放在最後、而且在基準線寫完之後 —— 它從頭到尾都不是這個專案的檔。
    $script:Data.editor = Install-Editor $(if ($Adopt) { $null } else { Find-ReleaseVsix $Source $srcVer.contract })
    return $code
}

function Complete-Install([string[]]$needsMerge, [bool]$hooksWritten) {
    $cfg = Read-JsonFile (Join-Path $Target $ConfigFile)
    $res = Invoke-TuningApply $Target $cfg
    if ($res.changed.Count -gt 0) { Say "apply：更新了 $($res.changed -join '、') 的 SDLC-TUNING 區塊" }
    foreach ($w in $res.warnings) { Warn $w }
    $script:Data.tuning = [ordered]@{ changed = @($res.changed); warnings = @($res.warnings) }

    foreach ($m in $needsMerge) {
        Warn "$m 你已經有一份，沒有覆蓋 —— 新版寫成 $m.new，請把流程那幾節合進你自己那份，然後刪掉 .new。少了它整套流程不會啟動。"
    }

    $findings = @(Test-Guidelines $Target $Source)
    foreach ($f in $findings) { if ($f.level -eq 'warn') { Warn $f.text } else { Say $f.text } }
    $script:Data.guidelines = @(Get-FindingData $findings)

    $lint = Invoke-Lint $Target
    $script:Data.lint = $lint

    # hooks.json 寫出去了 = Codex 那邊一定要（重新）信任。沒信任之前強制層一條都不會跑，而 Codex 不會主動說。
    $script:Data.hooksWritten = $hooksWritten
    if ($hooksWritten) {
        Say "hooks 寫好了，但 **Codex 要你信任之後才會跑**：在專案裡開 codex，信任這個資料夾，出現「Hooks need review」時選 Trust all and continue。沒信任之前 handoff-lint／dlp-gate／guideline-gate／build-check 一條都不會跑，而且沒有任何提示。之後隨時可以用 sdlc.ps1 doctor 確認。"
    }

    $cfg = Read-JsonFile (Join-Path $Target $ConfigFile)
    $orch = Get-AgentConfig $cfg 'orchestrator'
    $script:Data.orchestratorHint = $null
    if ($orch -and (($orch.model -and $orch.model -ne 'inherit') -or ($orch.effort -and $orch.effort -ne 'inherit'))) {
        # orchestrator 沒有 agent 定義檔（它就是 AGENTS.md），設定檔強制不了它。
        $hint = 'codex'
        if ($orch.model  -and $orch.model  -ne 'inherit') { $hint += " --model $($orch.model)" }
        if ($orch.effort -and $orch.effort -ne 'inherit') { $hint += " -c model_reasoning_effort=$($orch.effort)" }
        $script:Data.orchestratorHint = $hint
        Say "orchestrator 的設定強制不了（它沒有 agent 定義檔，就是 AGENTS.md 本身）。要用你記的那組值，啟動時自己下：$hint"
    }

    Say ''
    Say '裝好了。在專案裡開 Codex，直接說你要什麼即可。'
    return $(if ($lint.passed) { 0 } else { 2 })
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

    $breaking = [bool]($tgtVer -and $srcVer.minCompat -and ((Compare-Semver $tgtVer.contract $srcVer.minCompat) -lt 0))
    $script:Data.from      = if ($tgtVer) { $tgtVer.contract } else { $null }
    $script:Data.to        = $srcVer.contract
    $script:Data.breaking  = $breaking
    $script:Data.degraded  = [bool]$degraded
    $script:Data.unchanged = @($unchanged)
    $script:Data.modified  = @($modified)
    $script:Data.added     = @($added)
    $script:Data.removed   = @($removed)

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
    $script:Data.notes = @()
    if ($srcVer.raw) {
        $tag = 'v' + (($srcVer.contract -split '\.')[0..1] -join '')
        $notes = @($srcVer.raw.PSObject.Properties | Where-Object { $_.Name -like "$tag*" })
        if (-not $notes) { $notes = @($srcVer.raw.PSObject.Properties | Where-Object { $_.Name -match '^v\d' } | Select-Object -First 1) }
        foreach ($n in $notes) {
            $txt = [string]$n.Value
            $script:Data.notes += [ordered]@{ key = $n.Name; text = $txt }
            Say ''
            Say "這一版[$($n.Name)]：$($txt.Substring(0, [Math]::Min(500, $txt.Length)))$(if ($txt.Length -gt 500) { '…（全文：sdlc.ps1 whatsnew）' })"
        }
    }
    Say ''

    if ($unchanged.Count -eq 0 -and $modified.Count -eq 0 -and $added.Count -eq 0 -and $removed.Count -eq 0) {
        $script:Data.result = 'up-to-date'
        Say '已經是最新，沒有檔要動。'
        return 0
    }
    if (-not (Confirm-Step '要升級嗎？')) { $script:Data.result = 'cancelled'; Say '已取消，一個檔都沒動。'; return 2 }

    $backupDir = Join-Path $Target "$StateDir/backup-$(if ($tgtVer) { $tgtVer.contract } else { 'unknown' })"
    foreach ($rel in @($modified + $removed)) {
        $src = Join-Path $Target $rel
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $backupDir $rel
        $d = Split-Path $dst -Parent
        if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Copy-Item $src $dst -Force
    }
    $script:Data.backup = $null
    if ($modified.Count + $removed.Count -gt 0) {
        $script:Data.backup = ConvertTo-Rel $Target (Resolve-Path $backupDir).Path
        Say "備份：$($script:Data.backup)"
    }

    foreach ($rel in @($unchanged + $modified + $added)) {
        $t = Join-Path $Target $rel
        $d = Split-Path $t -Parent
        if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Copy-Item (Join-Path $Source $rel) $t -Force
    }
    foreach ($rel in $removed) { Remove-Item (Join-Path $Target $rel) -Force -ErrorAction SilentlyContinue }

    $cfg = Read-JsonFile $cfgPath
    $newAgents = Merge-Config $cfg $Source $srcVer.contract
    # 舊版的設定檔沒有 review 這一節。補上預設值 = 跟以前寫死的 3 輪一模一樣，只是從此看得到、改得到。
    $script:Data.reviewAdded = $false
    if (-not $cfg.PSObject.Properties['review']) {
        $cfg | Add-Member -NotePropertyName 'review' -NotePropertyValue ([pscustomobject]@{ maxRounds = $DefaultReviewRounds })
        $script:Data.reviewAdded = $true
    }
    Write-JsonFile $cfgPath $cfg
    $script:Data.newAgents = @($newAgents)
    if ($newAgents.Count -gt 0) { Say "$ConfigFile：新增 agent $($newAgents -join '、')（值填 inherit），既有設定一個字沒動。" }
    if ($script:Data.reviewAdded) { Say "$ConfigFile：新增 review.maxRounds = $DefaultReviewRounds（⑤ 的修正輪上限，跟以前寫死的一樣；可改成 1–5）。" }

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
    $script:Data.result = 'applied'

    # 新版的 toml 是原廠檔，裡面沒有 TUNING 區塊 —— 不重跑 apply，使用者的 effort 設定就沒生效。
    # hooks.json 只要內容換了（不管你有沒有改過它），Codex 那邊的信任就要重來。
    $code = Complete-Install @() ($HooksRel -in @($unchanged + $modified + $added))

    # extension 不替你重裝（它是整台機器共用的），只在版本對不上時說一行。
    $installedExt = @(Get-InstalledExtensions)
    $vsix = Find-ReleaseVsix $Source $srcVer.contract
    $script:Data.editor = [ordered]@{ installed = @($installedExt | ForEach-Object { [ordered]@{ product = $_.product; version = $_.version; compatible = $_.compatible } }); vsix = $vsix; mismatch = $false }
    foreach ($x in $installedExt) {
        if ($x.version -ne $srcVer.contract) {
            $script:Data.editor.mismatch = $true
            $how = if ($vsix) { "要換：code --install-extension `"$vsix`" --force" } else { '要換就裝這一版發佈物附的 vsix' }
            Say "$($x.product) 裡的 VS Code extension 還是 $($x.version)（這個專案現在是 $($srcVer.contract)）—— 沒有替你重裝，因為它是整台機器共用的。$how"
        }
    }
    return $code
}

function Invoke-Apply {
    $cfgPath = Join-Path $Target $ConfigFile
    $cfg = Read-JsonFile $cfgPath
    if (-not $cfg) { Warn "找不到或解析不了 $ConfigFile。"; $script:Data.error = 'config-unreadable'; return 2 }
    $res = Invoke-TuningApply $Target $cfg
    foreach ($w in $res.warnings) { Warn $w }
    $script:Data.changed  = @($res.changed)
    $script:Data.warnings = @($res.warnings)
    if ($res.changed.Count -gt 0) { Say "更新了：$($res.changed -join '、')" } else { Say '沒有變更 —— toml 的 SDLC-TUNING 區塊已經跟設定檔一致。' }
    return 0
}

# update.check 的頻率。daily = 距上次查過滿 24 小時才再查；查失敗（離線）的話一小時內不重試 ——
# extension 的背景刷新每開一次視窗就叫一次，離線的人不該每次都等一個 8 秒的逾時。
# 快取記的 installed 跟現在的版本對不上（剛升級完）一律視為到期：那份快取說的是升級前的世界。
function Test-UpdateDue($cache, [string]$installed) {
    if (-not $cache) { return $true }
    if ([string]$cache.installed -ne $installed) { return $true }
    $now = [DateTime]::UtcNow
    $checked = $null; $attempted = $null
    try { if ($cache.'checked-at') { $checked = ([DateTime]$cache.'checked-at').ToUniversalTime() } } catch { }
    try { if ($cache.'attempted-at') { $attempted = ([DateTime]$cache.'attempted-at').ToUniversalTime() } } catch { }
    if ($checked -and ($now - $checked).TotalHours -lt 24) { return $false }
    if ($attempted -and ($now - $attempted).TotalHours -lt 1) { return $false }
    return $true
}

function Invoke-CheckUpdate {
    $cfg = Read-JsonFile (Join-Path $Target $ConfigFile)
    $tgtVer = Get-ContractVersion $Target
    if (-not $cfg -or -not $tgtVer) { Warn '這個專案還沒安裝這套工作流。'; $script:Data.status = 'not-installed'; return 2 }
    $script:Data.installed = $tgtVer.contract
    if ($cfg.update -and $cfg.update.check -eq 'never') {
        $script:Data.status = 'disabled'
        Say '設定為不檢查更新（update.check = never）。'
        return 0
    }

    $cachePath = Join-Path $Target $CacheRel
    $cache = Read-JsonFile $cachePath
    if ($IfDue -and -not (Test-UpdateDue $cache $tgtVer.contract)) {
        $script:Data.status = 'not-due'
        $script:Data.latest = if ($cache.latest) { [string]$cache.latest } else { $null }
        $script:Data.newer  = [bool]$cache.newer
        Say "上次檢查還沒滿一天（update.check = daily），這次不連網。"
        return 0
    }

    $src = if ($cfg.update) { [string]$cfg.update.source } else { '' }
    if ($src -notmatch 'github\.com/([^/]+)/([^/\s]+?)(\.git)?/?$') {
        $script:Data.status = 'unsupported-source'
        Warn "update.source 不是可辨識的 GitHub repo（$src）—— 無法自動檢查，請手動看發佈頁。"
        return 0
    }
    $api = "https://api.github.com/repos/$($Matches[1])/$($Matches[2])/releases/latest"

    try {
        $rel = Invoke-RestMethod -Uri $api -TimeoutSec 8 -Headers @{ 'User-Agent' = 'codex-sdlc' } -ErrorAction Stop
    } catch {
        # 離線、逾時、私有 repo 一律靜默 —— 檢查更新失敗不是使用者要處理的事。
        # 只記下「試過了」，好讓 -IfDue 一小時內不重試；其餘欄位原樣保留（newer 沒有就是 false，通知不會亂喊）。
        $keep = [ordered]@{}
        if ($cache) { foreach ($p in $cache.PSObject.Properties) { $keep[$p.Name] = $(if ($p.Value -is [DateTime]) { $p.Value.ToString('o') } else { $p.Value }) } }
        if (-not $keep.Contains('installed')) { $keep['installed'] = $tgtVer.contract; $keep['newer'] = $false; $keep['latest'] = ''; $keep['seen'] = '' }
        $keep['attempted-at'] = (Get-Date).ToString('o')
        Write-JsonFile $cachePath $keep
        $script:Data.status = 'unreachable'
        Say '檢查不到更新（離線或來源不可達）。不影響任何流程。'
        return 0
    }

    $latest = ([string]$rel.tag_name) -replace '^v', ''
    $newer  = [bool]($latest -and ((Compare-Semver $latest $tgtVer.contract) -gt 0))
    $checkedAt = (Get-Date).ToString('o')
    Write-JsonFile $cachePath ([ordered]@{
        'checked-at' = $checkedAt
        'installed'  = $tgtVer.contract
        'latest'     = $latest
        'newer'      = $newer
        'notes'      = if ($rel.body) { [string]$rel.body } else { '' }
        'url'        = [string]$rel.html_url
        'seen'       = ''
    })
    $script:Data.status    = if ($newer) { 'newer' } else { 'up-to-date' }
    $script:Data.latest    = $latest
    $script:Data.newer     = $newer
    $script:Data.url       = [string]$rel.html_url
    $script:Data.checkedAt = $checkedAt
    if ($newer) { Say "有新版 $latest（你在 $($tgtVer.contract)）。看變更：pwsh .codex/scripts/sdlc.ps1 whatsnew" }
    else        { Say "已是最新（$($tgtVer.contract)）。" }
    return 0
}

function Invoke-WhatsNew {
    $cachePath = Join-Path $Target $CacheRel
    $cache = Read-JsonFile $cachePath
    $v = Get-ContractVersion $Target
    # 快取說的 installed 跟現在的版本對不上 = 升級前留下來的，不拿它唸「有新版」。
    if ($cache -and $cache.newer -and (-not $v -or [string]$cache.installed -eq $v.contract)) {
        $script:Data.source    = 'cache'
        $script:Data.latest    = [string]$cache.latest
        $script:Data.installed = [string]$cache.installed
        $script:Data.url       = [string]$cache.url
        $script:Data.notes     = [string]$cache.notes
        Say "新版 $($cache.latest)（你在 $($cache.installed)）"
        if ($cache.url) { Say $cache.url }
        Say ''
        if ($cache.notes) { Say $cache.notes }
        # 看過就安靜下來，直到下一個版本 —— 通知的目的是讓你看一次，不是每次 spawn 都提醒。
        $cache.seen = $cache.latest
        Write-JsonFile $cachePath $cache
        $script:Data.markedSeen = $true
        Say ''
        Say '要升級：把新版發佈物解壓到別處，然後 pwsh <發佈物>/.codex/scripts/sdlc.ps1 update -Target .'
        return 0
    }
    if (-not $v) { Warn '這個專案還沒安裝這套工作流。'; $script:Data.source = 'not-installed'; return 2 }
    $script:Data.source    = 'installed'
    $script:Data.installed = $v.contract
    $script:Data.minCompatible = $v.minCompat
    $script:Data.entries   = @()
    Say "目前版本 $($v.contract)（最低相容 $($v.minCompat)）。這一版的變更說明："
    foreach ($p in @($v.raw.PSObject.Properties | Where-Object { $_.Name -match '^v\d' })) {
        $script:Data.entries += [ordered]@{ key = $p.Name; text = [string]$p.Value }
        Say ''
        Say "[$($p.Name)] $($p.Value)"
    }
    return 0
}

function Invoke-Tune {
    $cfgPath = Join-Path $Target $ConfigFile
    $cfg = Read-JsonFile $cfgPath
    if (-not $cfg) { Warn "找不到 $ConfigFile。先跑 install。"; $script:Data.error = 'config-unreadable'; return 2 }

    # 訊號：只用便宜的。repo-index -StatusOnly 不讀任何檔內容。
    $signals = [ordered]@{ file_count = $null; language = ''; build_tool = ''; legacy_schema = 0 }
    $idx = Join-Path $Target '.codex/scripts/repo-index.ps1'
    if (Test-Path $idx) {
        try {
            $r = Invoke-PwshScript $idx @('-StatusOnly') (Resolve-Path $Target).Path
            $st = $r.stdout | ConvertFrom-Json
            $signals.file_count = $st.file_count
            $signals.language   = [string]$st.language
            $signals.build_tool = [string]$st.build_tool
        } catch {
            # 索引拿不到就用不到訊號，但 tune 仍然要能跑完 —— 它是使用者主動叫的，不該卡住。
            Warn "repo-index 取不到訊號（$($_.Exception.Message)），改用可得的部分。"
        }
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

    $items += @{ agent='reviewer'; effort='high'; reason='輸入小、判斷密度高，而且 ⑤ 的修正輪有上限（預設 3）—— 審得淺就是白付'; signal='一律' }
    $items += @{ agent='orchestrator'; effort='inherit'; reason='它沒有 agent 定義檔，這裡只是記錄；要生效得在 CLI 啟動時自己下'; signal='—' }

    Write-JsonFile (Join-Path $Target $ProposalRel) ([ordered]@{
        'generated-at' = (Get-Date).ToString('o')
        'signals'      = $signals
        'proposal'     = $items
    })

    $script:Data.signals  = $signals
    $script:Data.proposal = @()
    Say "訊號：file_count=$fc、language=$($signals.language)、build_tool=$($signals.build_tool)、legacy-schema=$($signals.legacy_schema)"
    Say ''
    foreach ($i in $items) {
        $cur = Get-AgentConfig $cfg $i.agent
        $now = if ($cur -and $cur.effort) { [string]$cur.effort } else { 'inherit' }
        $script:Data.proposal += [ordered]@{ agent = $i.agent; current = $now; proposed = $i.effort; reason = $i.reason; signal = $i.signal }
        $mark = if ($now -eq $i.effort) { ' ' } else { '*' }
        Say "$mark $($i.agent)：$now → $($i.effort)"
        Say "    理由：$($i.reason)"
        Say "    訊號：$($i.signal)"
    }
    Say ''
    Say "提議寫在 $ProposalRel。這是提議不是動作 —— 要套用：sdlc.ps1 tune -ApplyProposal"

    $script:Data.applied = $false
    if ($ApplyProposal) {
        foreach ($i in $items) {
            $cur = Get-AgentConfig $cfg $i.agent
            if ($cur) { $cur.effort = $i.effort }
        }
        Write-JsonFile $cfgPath $cfg
        $script:Data.applied = $true
        Say ''
        Say '已寫回設定檔，接著跑 apply。'
        $proposal = $script:Data.proposal; $signalsKeep = $script:Data.signals
        $code = Invoke-Apply
        $script:Data.proposal = $proposal; $script:Data.signals = $signalsKeep
        return $code
    }
    return 0
}

function Invoke-Doctor {
    $problems = 0
    $v = Get-ContractVersion $Target
    if (-not $v) { Warn "$VersionRel 不存在或解析不了。"; $script:Data.error = 'not-installed'; return 2 }
    $script:Data.version = [ordered]@{ contract = [string]$v.contract; minCompatible = [string]$v.minCompat }
    Say "版本 $($v.contract)（最低相容 $($v.minCompat)）"

    $cfgPath = Join-Path $Target $ConfigFile
    $cfg = Read-JsonFile $cfgPath
    $script:Data.unverifiedModel = @()
    if (-not $cfg) {
        $exists = Test-Path $cfgPath
        $script:Data.config = [ordered]@{ exists = $exists; parsable = $false }
        $script:Data.tuning = [ordered]@{ status = $(if ($exists) { 'unparsable' } else { 'no-config' }); stale = @() }
        if ($exists) { Warn "$ConfigFile 解析不了 —— apply 與 doctor 都讀不到你的設定。"; $problems++ }
        else { Say "$ConfigFile 不存在 —— per-agent 調校未啟用，全部交由 Codex CLI 決定（這是合法狀態）。" }
    } else {
        $script:Data.config = [ordered]@{ exists = $true; parsable = $true }
        $stale = @()
        foreach ($f in @(Get-ChildItem (Join-Path $Target '.codex/agents') -Filter *.toml -File -ErrorAction SilentlyContinue)) {
            $text = [IO.File]::ReadAllText($f.FullName)
            $want = Get-TuningSha (Get-AgentConfig $cfg $f.BaseName)
            $m = [regex]::Match($text, [regex]::Escape($TuneBegin) + '\s+sha=([0-9a-f]{8})')
            if (-not $m.Success -or $m.Groups[1].Value -ne $want) { $stale += $f.Name }
        }
        $script:Data.tuning = [ordered]@{ status = $(if ($stale.Count -gt 0) { 'stale' } else { 'in-sync' }); stale = @($stale) }
        if ($stale.Count -gt 0) {
            Warn "SDLC-TUNING 區塊跟設定檔對不上：$($stale -join '、') —— 跑 pwsh .codex/scripts/sdlc.ps1 apply"
            $problems++
        } else {
            Say '調校區塊與設定檔一致。'
        }
        foreach ($p in @($cfg.agents.PSObject.Properties)) {
            if ($p.Value.model -and $p.Value.model -ne 'inherit') {
                $script:Data.unverifiedModel += $p.Name
                Warn "$($p.Name)：設了 model=`"$($p.Value.model)`" —— 這個 key 尚未在本工作流驗證過，Codex 若忽略它會靜默地用預設模型跑。"
            }
        }
    }

    $baseline = Read-JsonFile (Join-Path $Target $BaselineRel)
    if (-not $baseline) {
        $script:Data.baseline = [ordered]@{ exists = $false; version = $null; fileCount = 0 }
        Say '沒有基準線 —— update 將無法分辨你改過哪些工具檔。跑 install -Adopt 建立一次。'
    } else {
        $n = @($baseline.files.PSObject.Properties).Count
        $script:Data.baseline = [ordered]@{ exists = $true; version = [string]$baseline.'workflow-version'; fileCount = $n }
        Say "基準線：$($baseline.'workflow-version')（$n 個檔）"
    }

    $findings = @(Test-Guidelines $Target $Target)
    foreach ($f in $findings) { if ($f.level -eq 'warn') { Warn $f.text; $problems++ } else { Say $f.text } }
    $script:Data.guidelines = @(Get-FindingData $findings)

    $lint = Invoke-Lint $Target
    $script:Data.lint = $lint
    if (-not $lint.passed) { $problems++ }

    # 修正輪上限。值合不合法由 agent-lint 檢查 13 判（上面已經算進問題數），這裡只算出「實際生效的是幾輪」給人與 extension 看。
    $rawRounds = $null
    if ($cfg -and $cfg.PSObject.Properties['review'] -and $cfg.review -is [pscustomobject] -and $cfg.review.PSObject.Properties['maxRounds']) { $rawRounds = $cfg.review.maxRounds }
    $roundsInvalid = @($lint.violations | Where-Object { $_.rule -in @('review-max-rounds-invalid', 'review-config-invalid') }).Count -gt 0
    $roundsFromConfig = (-not $roundsInvalid) -and ($rawRounds -is [int] -or $rawRounds -is [long])
    $script:Data.review = [ordered]@{
        maxRounds  = $(if ($roundsFromConfig) { [int]$rawRounds } else { $DefaultReviewRounds })
        source     = $(if ($roundsFromConfig) { 'config' } else { 'default' })
        valid      = -not $roundsInvalid
    }
    if ($roundsInvalid) { Say "修正輪上限：$DefaultReviewRounds 輪（review.maxRounds 寫壞了，handoff-lint 照預設算 —— 見上面的 agent-lint）" }
    else { Say "修正輪上限：$($script:Data.review.maxRounds) 輪（$(if ($roundsFromConfig) { "$ConfigFile 的 review.maxRounds" } else { '預設' })）" }

    $trust = Get-HookTrust $Target
    $script:Data.hooks = $trust
    $problems += (Show-HookTrust $trust)

    # 更新快取：installed 跟現在的版本對不上 = 升級前留下來的，不當真（見 handoff-lint 尾端同一條）。
    $cache = Read-JsonFile (Join-Path $Target $CacheRel)
    $cacheStale = [bool]($cache -and [string]$cache.installed -ne [string]$v.contract)
    $newer = [bool]($cache -and $cache.newer -and -not $cacheStale)
    $script:Data.update = [ordered]@{
        cached    = [bool]$cache
        stale     = $cacheStale
        newer     = $newer
        latest    = $(if ($cache -and $cache.latest) { [string]$cache.latest } else { $null })
        seen      = [bool]($cache -and $cache.latest -and $cache.seen -eq $cache.latest)
        checkedAt = $(if ($cache) { ConvertTo-IsoText $cache.'checked-at' } else { $null })
        check     = $(if ($cfg -and $cfg.update -and $cfg.update.check) { [string]$cfg.update.check } else { 'daily' })
    }
    if ($newer -and $cache.seen -ne $cache.latest) { Say "有新版 $($cache.latest) —— pwsh .codex/scripts/sdlc.ps1 whatsnew" }

    # 編輯器那一層：只報、不擋（它是整台機器共用的，不是這個專案的健康狀態）。
    $ext = @(Get-InstalledExtensions)
    $script:Data.editor = [ordered]@{ installed = @($ext | ForEach-Object { [ordered]@{ product = $_.product; version = $_.version; jsonSchema = $_.jsonSchema; compatible = $_.compatible } }) }
    foreach ($x in $ext) {
        if ($x.compatible) { Say "VS Code extension：$($x.product) 裝的是 $($x.version)，跟這個專案相容。" }
        else { Say "VS Code extension：$($x.product) 裝的是 $($x.version)，跟這個專案（$($v.contract)）的 -Json 形狀對不上 —— 狀態列會顯示不了；換成這一版發佈物附的 vsix。" }
    }

    $script:Data.problems = $problems
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
    [Console]::Out.WriteLine(([ordered]@{
        schema   = $JsonSchema
        command  = $Command
        exit     = $code
        data     = $script:Data
        warnings = @($script:Warnings)
        output   = @($script:Notes)
    } | ConvertTo-Json -Depth 10 -Compress))
}
exit $code
