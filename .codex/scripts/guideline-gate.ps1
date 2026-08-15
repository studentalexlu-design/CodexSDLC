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
# 但每次都往 stderr 喊。靜默地「規範沒有在生效」比擋錯更糟。
#
# Exit: 0 = 無命中／只有 warn／已短路／規則檔缺失或損壞；2 = 命中 block 規則（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string[]]$Path,                                    # 直接指定檔案（測試／手動用），跳過 payload 解析
    [string]$RulesFile     = 'guidelines/rules.json',
    [string]$DisableMarker = 'guidelines/.gate-disabled',
    [int]$MaxReport        = 10,
    [switch]$Validate,                                  # 只驗規則檔本身，不掃任何檔案
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# 工作流自己的目錄與建置產物一律不掃。
#
# `bdd-docs/` 排除得最要緊：`bdd-docs/artifacts/legacy-schema/` 放的是從舊系統抓回來的
# View／SP 定義 —— 那些本來就滿是 NOLOCK 與 cursor。拿團隊的新規範去擋一份唯讀的歷史證據，
# 只會讓 gate 在每次 SQL 逆推時無條件紅燈，然後被整個關掉。
$excludeRe = '^(bdd-docs|guidelines|\.codex|\.agents|\.git)/|/(bin|obj|node_modules|packages|\.git|\.vs|TestResults)/'

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

# 一律正規化成「相對 cwd、正斜線」的形式 —— applies-to 的 glob 是照這個寫的。
function ConvertTo-RelPath([string]$p) {
    $n = $p -replace '\\', '/'
    $root = ((Get-Location).Path -replace '\\', '/').TrimEnd('/')
    if ($n -like "$root/*") { $n = $n.Substring($root.Length + 1) }
    return $n.TrimStart('./')
}

# ---- 載入並驗證規則 ----
# 回傳 @{ rules = @(...); problems = @(...) }。壞掉的規則被丟掉，其餘照常生效 ——
# 一條規則寫壞不該讓另外 199 條跟著失效。
function Get-Rules([string]$file) {
    $problems = @()
    if (-not (Test-Path $file)) { return @{ rules = @(); problems = $problems; exists = $false } }

    try { $doc = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        $problems += "$file 不是合法的 JSON：$($_.Exception.Message)"
        return @{ rules = @(); problems = $problems; exists = $true }
    }

    $good = @()
    $i = 0
    foreach ($r in @($doc.rules)) {
        $i++
        $id = if ($r.id) { $r.id } else { "rule#$i" }
        if (-not $r.id)      { $problems += "第 $i 條缺 id"; continue }
        if (-not $r.pattern) { $problems += "${id}: 缺 pattern"; continue }

        $sev = if ($r.severity) { [string]$r.severity } else { 'warn' }   # 預設 warn，block 要明確 opt-in
        if ($sev -notin @('block', 'warn')) { $problems += "${id}: severity 必須是 block 或 warn，收到 '$sev'"; continue }

        try { $re = [regex]::new([string]$r.pattern) }
        catch { $problems += "${id}: pattern 不是合法的 regex —— $($_.Exception.Message)"; continue }

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
    return @{ rules = $good; problems = $problems; exists = $true }
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
    }
    if ($Json) { $out | ConvertTo-Json -Depth 4 -Compress }
    elseif ($ok) { "[guideline-gate] OK — $($loaded.rules.Count) rule(s) in $RulesFile ($($out.block_count) blocking)." }
    else {
        [Console]::Error.WriteLine("[guideline-gate] $($loaded.problems.Count) problem(s) in ${RulesFile}:")
        foreach ($p in $loaded.problems) { [Console]::Error.WriteLine("  - $p") }
    }
    exit $(if ($ok) { 0 } else { 2 })
}

# ---- 短路 ----
if (Test-Path $DisableMarker) { exit 0 }
if (-not $loaded.exists) { exit 0 }        # 沒有規範的團隊零成本，且完全安靜

# 規則檔壞掉：不阻斷，但每次都喊。
# 靜默地「規範其實沒在生效」比擋錯更糟 —— 團隊會以為有人在守，而沒有人在守。
foreach ($p in $loaded.problems) { Write-Warn "規則載入失敗（該條已略過）—— $p" }
if ($loaded.rules.Count -eq 0) { exit 0 }

# ---- 決定要掃哪些檔 ----
if (-not $Path) {
    if (-not $Payload) { $Payload = [Console]::In.ReadToEnd() }
    if (-not $Payload) { exit 0 }
    # 單引號也要認：shell／heredoc 寫入慣用單引號，只認雙引號會讓那條路徑完全躲過本 gate。
    $Path = [regex]::Matches($Payload, '["'']([^"''\r\n]*?\.[A-Za-z0-9]{1,10})["'']') |
            ForEach-Object { $_.Groups[1].Value }
}

$targets = @($Path | ForEach-Object { ConvertTo-RelPath $_ } |
             Sort-Object -Unique |
             Where-Object { $_ -notmatch $excludeRe -and (Test-Path $_) -and -not (Get-Item $_).PSIsContainer })

if (-not $targets) { exit 0 }

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
    $lines = @(Get-Content $t -ErrorAction SilentlyContinue)
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

if (-not $hits) { exit 0 }

$blocking = @($hits | Where-Object severity -eq 'block')
$warning  = @($hits | Where-Object severity -eq 'warn')

if ($Json) {
    [pscustomobject]@{
        passed = ($blocking.Count -eq 0)
        scanned_files = $targets.Count
        block_count = $blocking.Count
        warn_count  = $warning.Count
        hits = @($hits | Select-Object -First $MaxReport)
    } | ConvertTo-Json -Depth 4 -Compress
    exit $(if ($blocking.Count -gt 0) { 2 } else { 0 })
}

# stderr 是回饋管道：訊息會回到剛剛寫檔的那個 agent 手上，所以每一行都要能直接動手修。
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

Write-Warn "規範建議 $($warning.Count) 處（不阻斷）："
foreach ($h in ($warning | Select-Object -First $MaxReport)) { [Console]::Error.WriteLine((Format-Hit $h)) }
if ($warning.Count -gt $MaxReport) { [Console]::Error.WriteLine("  …另有 $($warning.Count - $MaxReport) 處") }
exit 0
