# guideline-gate.ps1
# 專案規範裡**機械可查**的那一半：語法禁令、命名硬規則、不准出現的 API。
#
# 為什麼這些不寫進 prompt：prompt 裡的規則是榮譽制，而且每個 spawn 都要付一次 token。
# 一份 200 條的 SQL 規範寫進 implementer 的系統提示，成本是每次委派都付，效果是照樣被違反。
# 掃描器的成本是零 token，而且擋得住。
#
# 分工（這條線就是 reviewer 那句「有機械 oracle 的不審」的同一條線）：
#   有 oracle（regex 判得出來）→ 這裡。零 token、強制、回饋落在寫檔的那一刻。
#   沒 oracle（「API 該怎麼設計」）→ guidelines/*.md，由子代理自己讀。
#
# 規則來自**使用者專案**的 `guidelines/rules.json`，不是本 repo。升級只覆蓋 .codex/、
# .agents/ 與 AGENTS.md —— 規範放在 guidelines/ 才不會在升級時靜默消失。
#
# DLP：**絕不輸出命中的原始行**（跟 dlp-residual-scan 同一條安全契約）。
# 只回 rule id、檔:行、message 與 fix —— 那已經足夠讓 agent 當場改掉。
#
# 失效必須是可見的：rules.json 壞掉時**不阻斷**（不能讓一條寫壞的 regex 卡死整條流程），
# 但每次都喊。靜默地「規範沒有在生效」比擋錯更糟。
#
# 「喊」要喊到得了人。Codex 0.154.0 實測（見版本檔 v48-enforcement）：
#   - exit 2 的 stderr 會當成回饋交給模型 → 阻斷訊息照舊走 stderr。
#   - exit 0 的 stderr 會被**整段丟掉** → 不阻斷的訊息（warn 命中、規則檔壞掉、標記檔關閉）
#     在 hook 模式下另外寫成 stdout 上的 additionalContext JSON，stderr 照印給手動執行的人看。
#
# -Json 的 stdout 就是結果本身（VS Code extension 的 Problems 面板讀這個），**每一種情況都會輸出一個物件**，
# 包含「沒有規則」「被關閉」這些狀態 —— 呼叫端才分得出「乾淨」與「沒有在守」。
#
# Exit: 0 = 無命中／只有 warn／已短路／規則檔缺失或損壞；2 = 命中 block 規則（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string[]]$Path,                                    # 直接指定檔案（測試／手動／extension 用），跳過 payload 解析
    [string]$RulesFile     = 'guidelines/rules.json',
    [string]$DisableMarker = 'guidelines/.gate-disabled',
    [int]$MaxReport        = 10,
    [switch]$Validate,                                  # 只驗規則檔本身，不掃任何檔案
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

# 工作流自己的目錄與建置產物一律不掃。
#
# `bdd-docs/` 排除得最要緊：`bdd-docs/artifacts/legacy-schema/` 放的是從舊系統抓回來的
# View／SP 定義 —— 那些本來就滿是 NOLOCK 與 cursor。拿團隊的新規範去擋一份唯讀的歷史證據，
# 只會讓 gate 在每次 SQL 逆推時無條件紅燈，然後被整個關掉。
$excludeRe = '^(bdd-docs|guidelines|\.codex|\.agents|\.git)/|/(bin|obj|node_modules|packages|\.git|\.vs|TestResults)/'

# severity 的合法值。跟 .codex/bdd-workflow/rules.schema.json 一致，由 agent-lint 檢查 14 守（gate 不讀 schema：它要在 schema 不在時照跑）。
$Severities = @('block', 'warn')

function Write-Warn([string]$msg) { [Console]::Error.WriteLine("[Hook][Guideline] $msg") }

# glob → regex。支援 `**/`（跨層）、`*`（單層內）、`?`。
function ConvertTo-GlobRegex([string]$glob) {
    $s = [regex]::Escape(($glob -replace '\\', '/'))
    # 順序不可調換：`**/` 必須先於 `**`，`**` 必須先於 `*`。
    $s = $s -replace '\\\*\\\*/', '(?:.*/)?'
    $s = $s -replace '\\\*\\\*',  '.*'
    $s = $s -replace '\\\*',      '[^/]*'
    $s = $s -replace '\\\?',      '[^/]'
    return "^$s$"
}

# ---- hook payload → 這次寫出去的檔 ----
# 三支 PostToolUse gate（dlp-gate／guideline-gate／build-check）各有一份**逐字相同**的副本：
# gate 必須能獨立跑，少複製一支共用檔不該讓三支一起靜默失效。重複由 test-hook-payload.ps1 守住
# （三支的 Read-HookPayload 必須逐字相同）。
#
# 形狀以 Codex 0.154.0 實測為準：
#   apply_patch → tool_input.command 是整份 patch；路徑在 `*** Add File:`／`*** Update File:`／`*** Move to:`，**沒有引號**
#   Bash        → tool_input.command 是 shell 指令；路徑通常帶引號
# 舊版只認引號包住的路徑 —— apply_patch 寫的檔一個都抽不到，而那正是 agent 寫檔的主要途徑。症狀是零。
#
# 只看 tool_input（有的話）：其餘欄位裡的 transcript_path 是一個 .jsonl，那是對話紀錄，不是這次寫的檔。
# patch 內文裡的引號字串是**檔案內容**，不算路徑。
function Read-HookPayload([string]$raw) {
    $result = [pscustomobject]@{ event = ''; paths = @() }
    if (-not $raw) { return $result }
    $texts = @()
    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['hook_event_name']) { $result.event = [string]$doc.hook_event_name }
        $scope = if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['tool_input']) { $doc.tool_input } else { $doc }
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($scope)
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if ($null -eq $cur) { continue }
            if ($cur -is [string]) { $texts += $cur; continue }
            if ($cur -is [ValueType]) { continue }
            if ($cur -is [System.Collections.IEnumerable]) { foreach ($i in $cur) { $queue.Enqueue($i) }; continue }
            foreach ($p in $cur.PSObject.Properties) { $queue.Enqueue($p.Value) }
        }
    } catch { $texts = @($raw) }

    $paths = @()
    foreach ($t in $texts) {
        if ($t -match '(?m)^\*\*\* Begin Patch') {
            foreach ($m in [regex]::Matches($t, '(?m)^\*\*\* (?:Add File|Update File|Move to):[ \t]*(.+?)[ \t]*\r?$')) { $paths += $m.Groups[1].Value }
            continue
        }
        foreach ($m in [regex]::Matches($t, '["'']([^"''\r\n]*?\.[A-Za-z0-9]{1,10})["'']')) { $paths += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '["''](bdd-docs[\\/][^"''\r\n]*)["'']')) { $paths += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '(?<![\w.\\/-])(bdd-docs[\\/][^\s"''`;|&<>(){}]+)')) { $paths += $m.Groups[1].Value }
        if ($t -match '^[^"''\r\n*]+\.[A-Za-z0-9]{1,10}$') { $paths += $t }
    }
    $result.paths = @($paths | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    return $result
}

# 一律正規化成「相對 cwd、正斜線」—— applies-to 的 glob 是照這個寫的，hook 的 cwd 就是專案根。
function ConvertTo-RelPath([string]$p) {
    $n = $p.Trim() -replace '\\', '/'
    $root = ((Get-Location).Path -replace '\\', '/').TrimEnd('/')
    if ($n.StartsWith("$root/", [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring($root.Length + 1) }
    while ($n.StartsWith('./')) { $n = $n.Substring(2) }
    return $n
}

function Write-HookContext([string]$eventName, [string[]]$lines) {
    if ($Json -or -not $eventName -or -not $lines) { return }
    [Console]::Out.WriteLine((@{ hookSpecificOutput = @{ hookEventName = $eventName; additionalContext = ($lines -join "`n") } } |
                              ConvertTo-Json -Compress -Depth 4))
}

# ---- 載入並驗證規則 ----
# 回傳 @{ rules = @(...); problems = @(...) }。壞掉的規則被丟掉，其餘照常生效 ——
# 一條規則寫壞不該讓另外 199 條跟著失效。
# `details` 是同一批問題的結構化版本（第幾條、哪個 id、哪個欄位），給 -Validate -Json 的讀者把問題放到對的那一行 ——
# 讀者只負責「放在哪」，對錯一律在這裡判。
function Get-Rules([string]$file) {
    $problems = @(); $details = @()
    function Add-Problem([string]$text, $index, [string]$id, [string]$field) {
        $script:rulesProblems += $text
        $script:rulesDetails  += [pscustomobject]@{ index = $index; id = $(if ($id) { $id } else { $null }); field = $(if ($field) { $field } else { $null }); message = $text }
    }
    $script:rulesProblems = @(); $script:rulesDetails = @()
    if (-not (Test-Path $file)) { return @{ rules = @(); problems = $problems; details = $details; exists = $false } }

    try { $doc = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Add-Problem "$file 不是合法的 JSON：$($_.Exception.Message)" $null $null $null
        return @{ rules = @(); problems = @($script:rulesProblems); details = @($script:rulesDetails); exists = $true }
    }

    $good = @()
    $i = 0
    foreach ($r in @($doc.rules)) {
        $i++
        $id = if ($r.id) { $r.id } else { "rule#$i" }
        if (-not $r.id)      { Add-Problem "第 $i 條缺 id" $i $null 'id'; continue }
        if (-not $r.pattern) { Add-Problem "${id}: 缺 pattern" $i $id 'pattern'; continue }

        $sev = if ($r.severity) { [string]$r.severity } else { 'warn' }   # 預設 warn，block 要明確 opt-in
        if ($sev -notin $Severities) { Add-Problem "${id}: severity 必須是 $($Severities -join ' 或 ')，收到 '$sev'" $i $id 'severity'; continue }

        try { $re = [regex]::new([string]$r.pattern) }
        catch { Add-Problem "${id}: pattern 不是合法的 regex —— $($_.Exception.Message)" $i $id 'pattern'; continue }

        $globs = @()
        foreach ($g in @($r.'applies-to')) { if ($g) { $globs += (ConvertTo-GlobRegex ([string]$g)) } }

        $good += [pscustomobject]@{
            id       = [string]$id
            regex    = $re
            globs    = $globs          # 空 = 套用到所有未被排除的檔
            severity = $sev
            message  = [string]$r.message
            fix      = [string]$r.fix
        }
    }
    return @{ rules = $good; problems = @($script:rulesProblems); details = @($script:rulesDetails); exists = $true }
}

$loaded = Get-Rules $RulesFile

# ---- -Validate：只驗規則檔 ----
if ($Validate) {
    $ok = ($loaded.problems.Count -eq 0)
    $out = [pscustomobject]@{
        passed      = $ok
        rules_file  = $RulesFile
        exists      = $loaded.exists
        rule_count  = $loaded.rules.Count
        block_count = @($loaded.rules | Where-Object severity -eq 'block').Count
        problems    = $loaded.problems
        # 同一批問題，帶「第幾條規則（1 起算）／id／欄位」—— 檔案層級的問題 index 是 null。
        rule_problems = @($loaded.details)
    }
    if ($Json) { $out | ConvertTo-Json -Depth 4 -Compress }
    elseif ($ok) { "[guideline-gate] OK — $($loaded.rules.Count) rule(s) in $RulesFile ($($out.block_count) blocking)." }
    else {
        [Console]::Error.WriteLine("[guideline-gate] $($loaded.problems.Count) problem(s) in ${RulesFile}:")
        foreach ($p in $loaded.problems) { [Console]::Error.WriteLine("  - $p") }
    }
    exit $(if ($ok) { 0 } else { 2 })
}

# -Json：每一種結局都輸出同一個形狀。status 讓呼叫端分得出「乾淨」與「沒有在守」。
function Write-Result([string]$status, [string[]]$files = @(), $hits = @()) {
    if (-not $Json) { return }
    $block = @($hits | Where-Object severity -eq 'block')
    [pscustomobject]@{
        passed        = ($block.Count -eq 0)
        status        = $status          # disabled | no-rules | no-targets | scanned
        rules_file    = $RulesFile
        problems      = @($loaded.problems)
        files         = @($files)
        scanned_files = @($files).Count
        block_count   = $block.Count
        warn_count    = @($hits | Where-Object severity -eq 'warn').Count
        hits          = @($hits | Select-Object -First $MaxReport)
    } | ConvertTo-Json -Depth 4 -Compress
}

# ---- 決定要掃哪些檔 ----
$hook = [pscustomobject]@{ event = ''; paths = @() }
if (-not $Path) {
    if (-not $Payload) { $Payload = Read-StdinUtf8 }
    if ($Payload) {
        $hook = Read-HookPayload $Payload
        $Path = $hook.paths
    }
}

# ---- 短路 ----
# 標記檔關掉時**每次都喊**，理由跟底下「規則檔壞掉」完全相同：靜默地「規範其實沒在生效」
# 比擋錯更糟。而標記檔比壞掉的規則檔更容易變成永久的 —— 它通常是某一次為了解卡建的，
# 建完就留在那裡，接下來每一個需求都在沒有規範的情況下跑，而畫面上一切正常。
# 這一行是唯一會提醒的東西（它不阻斷，exit 仍是 0）。
if (Test-Path $DisableMarker) {
    $msg = "已被 $DisableMarker 關閉 —— 這次沒有掃任何檔。要恢復就刪掉那個標記檔。"
    Write-Warn $msg
    Write-HookContext $hook.event @("[Hook][Guideline] $msg")
    Write-Result 'disabled'
    exit 0
}
if (-not $loaded.exists) { Write-Result 'no-rules'; exit 0 }        # 沒有規範的團隊零成本，且完全安靜

# 規則檔壞掉：不阻斷，但每次都喊。
# 靜默地「規範其實沒在生效」比擋錯更糟 —— 團隊會以為有人在守，而沒有人在守。
$notices = @()
foreach ($p in $loaded.problems) {
    Write-Warn "規則載入失敗（該條已略過）—— $p"
    $notices += "[Hook][Guideline] 規則載入失敗（該條已略過）—— $p"
}
if ($loaded.rules.Count -eq 0) { Write-HookContext $hook.event $notices; Write-Result 'no-rules'; exit 0 }

$targets = @($Path | ForEach-Object { ConvertTo-RelPath $_ } |
             Sort-Object -Unique |
             Where-Object { $_ -notmatch $excludeRe -and (Test-Path -LiteralPath $_) -and -not (Get-Item -LiteralPath $_).PSIsContainer })

if (-not $targets) { Write-HookContext $hook.event $notices; Write-Result 'no-targets'; exit 0 }

# ---- 掃描 ----
$hits = @()
foreach ($t in $targets) {
    $applicable = @($loaded.rules | Where-Object {
        $_.globs.Count -eq 0 -or (@($_.globs | Where-Object { $t -match $_ }).Count -gt 0)
    })
    if (-not $applicable) { continue }

    # `@()` 不可省：單行檔的 Get-Content 回的是**字串**而不是陣列，
    # 此時 `.Count` 仍是 1，但 `$lines[0]` 取到的是第一個**字元** —— 於是單行檔永遠掃不到東西，
    # 而且完全安靜。禁用語法寫在單行檔裡正是最常見的情況（一句 SQL、一個 config）。
    $lines = @(Get-Content -LiteralPath $t -ErrorAction SilentlyContinue)
    if (-not $lines) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($r in $applicable) {
            if ($r.regex.IsMatch($lines[$i])) {
                # 只記位置與規則，**不記命中的原始行**（安全契約，見檔頭）。
                $hits += [pscustomobject]@{
                    rule = $r.id; severity = $r.severity; file = $t; line = $i + 1
                    message = $r.message; fix = $r.fix
                }
            }
        }
    }
}

$blocking = @($hits | Where-Object severity -eq 'block')
$warning  = @($hits | Where-Object severity -eq 'warn')

if ($Json) {
    Write-Result 'scanned' $targets $hits
    exit $(if ($blocking.Count -gt 0) { 2 } else { 0 })
}

if (-not $hits) { Write-HookContext $hook.event $notices; exit 0 }

# 回饋管道：阻斷走 stderr（Codex 把它交給模型），不阻斷走 additionalContext。
# 兩者訊息會回到剛剛寫檔的那個 agent 手上，所以每一行都要能直接動手修。
function Format-Hit($h) {
    $line = "  [$($h.severity)] $($h.rule)  $($h.file):$($h.line)"
    if ($h.message) { $line += "`n         $($h.message)" }
    if ($h.fix)     { $line += "`n         修法：$($h.fix)" }
    return $line
}

if ($blocking.Count -gt 0) {
    Write-Warn "違反專案規範（$RulesFile）$($blocking.Count) 處 —— 現在就改掉，不要留到審核。"
    foreach ($h in ($blocking | Select-Object -First $MaxReport)) { [Console]::Error.WriteLine((Format-Hit $h)) }
    if ($blocking.Count -gt $MaxReport) { [Console]::Error.WriteLine("  …另有 $($blocking.Count - $MaxReport) 處") }
    exit 2
}

$head = "規範建議 $($warning.Count) 處（不阻斷）："
Write-Warn $head
$notices += "[Hook][Guideline] $head"
foreach ($h in ($warning | Select-Object -First $MaxReport)) {
    $f = Format-Hit $h
    [Console]::Error.WriteLine($f)
    $notices += $f
}
if ($warning.Count -gt $MaxReport) {
    $more = "  …另有 $($warning.Count - $MaxReport) 處"
    [Console]::Error.WriteLine($more)
    $notices += $more
}
Write-HookContext $hook.event $notices
exit 0
