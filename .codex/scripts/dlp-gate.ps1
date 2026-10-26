# dlp-gate.ps1
# PostToolUse 縱深防禦：對寫入 bdd-docs/** 的 artifact 執行殘留掃描。
# 另外順手兩件不阻斷的事：寫心跳（Write-HookHeartbeat），以及替掃過、乾淨的 review.md 留一份快照（檔尾）。
# 留快照之前還驗一件會阻斷的事：上一份 review.md 的每一項 [必修]，新的這份都要有交代（Get-UnaccountedMust）。
#
# 短路條件：存在 `bdd-docs/.dlp-disabled` 時整條掃描鏈路跳過。
# 這是**專案層級**的宣告（v4.0.0 起；v3 是 run 層級，而 v4 沒有 run）。
# 中途發現敏感資料 → 刪掉該檔並重跑全量掃描，見 runbooks/dlp-masking.md。
#
# 兩條 Codex 行為決定了這支腳本的輸出形狀（0.154.0 實測，見版本檔 v48-enforcement）：
#   - **阻斷**：exit 2 ＋ stderr。Codex 把 stderr 當成回饋交給模型。
#   - **不阻斷但要喊**：exit 0 的 stderr 會被**整段丟掉**（不進模型、不進 UI）。所以 hook 在叫
#     （payload 帶 hook_event_name）時，同一句話另外寫成 stdout 上的 additionalContext JSON。
#
# 另有 -Path／-Json 給手動執行與 VS Code extension 用（Problems 面板）。-Json 的 stdout 就是結果本身。
#
# Exit: 0 = 通過或已短路；2 = 偵測到殘留，或 review.md 有上一份的 [必修] 沒交代（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string[]]$Path,                                    # 直接指定檔案，跳過 payload 解析
    [string]$ScanScript = '.codex/scripts/dlp-residual-scan.ps1',
    [string]$DisableMarker = 'bdd-docs/.dlp-disabled',
    [switch]$Json
)

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# Codex 送進來的 payload 是 UTF-8、也用 UTF-8 解讀 hook 的輸出；Windows 上 [Console] 的編碼卻跟著 console 的
# code page 走（zh-TW 是 cp950；並行的 hook 共用同一個 console，偶爾連輸出端也是）。Codex 0.154.0 實測的後果：
# 一份 743 字、meta 完整的中文 handoff 被解成 1772 字、JSON 解析失敗、抓不到 mode —— **每一次 spawn 都被擋**；
# 阻斷理由的中文到模型手上是亂碼。只在被重導向時才換：人在終端機跑的時候照 console 的 code page 顯示。
# 同一段在每一支會被程式呼叫的腳本裡各有一份（清單由 test-hook-payload.ps1 守住）。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
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
    $texts = @(); $tool = ''
    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['hook_event_name']) { $result.event = [string]$doc.hook_event_name }
        if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['tool_name']) { $tool = [string]$doc.tool_name }
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

    $paths = @(); $mentioned = @()
    foreach ($t in $texts) {
        if ($t -match '(?m)^\*\*\* Begin Patch') {
            foreach ($m in [regex]::Matches($t, '(?m)^\*\*\* (?:Add File|Update File|Move to):[ \t]*(.+?)[ \t]*\r?$')) { $paths += $m.Groups[1].Value }
            continue
        }
        foreach ($m in [regex]::Matches($t, '["'']([^"''\r\n]*?\.[A-Za-z0-9]{1,10})["'']')) { $mentioned += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '["''](bdd-docs[\\/][^"''\r\n]*)["'']')) { $mentioned += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($t, '(?<![\w.\\/-])(bdd-docs[\\/][^\s"''`;|&<>(){}]+)')) { $mentioned += $m.Groups[1].Value }
        if ($t -match '^[^"''\r\n*]+\.[A-Za-z0-9]{1,10}$') { $mentioned += $t }
    }
    # shell 指令裡的路徑只是「被提到」：`Get-Content -Path 'legacy/report.sql'`、`rg -n "Status" "x.sql"` 都抽得到，
    # 而那些檔這次沒被寫。不篩的話，讀一個不合新規範的舊檔就收到一句「現在就改掉」—— 唯讀的 agent 被叫去改舊檔。
    # 所以只留這次真的被寫到的：修改或建立時間在 120 秒內（建立時間接得住保留修改時間的 Copy-Item）。
    # 不用 git status：這套流程從不 commit，bdd-docs/ 與上一個需求改過的檔永遠是「已修改／未追蹤」，等於沒篩。
    # patch 標頭本來就是寫的檔，不篩；其他工具（Edit／Write 的 file_path）也是寫，不篩。
    if ($tool -match '^(Bash|shell)$') {
        $now = [DateTime]::UtcNow
        $mentioned = @($mentioned | Where-Object {
            $f = $_.Trim()
            try {
                if (-not [IO.Path]::IsPathRooted($f)) { $f = Join-Path (Get-Location).Path $f }
                if (-not [IO.File]::Exists($f)) { return $false }
                $touched = [IO.File]::GetLastWriteTimeUtc($f)
                $created = [IO.File]::GetCreationTimeUtc($f)
                if ($created -gt $touched) { $touched = $created }
                return (($now - $touched).TotalSeconds -le 120)
            } catch { return $false }
        })
    }
    $result.paths = @(($paths + $mentioned) | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    return $result
}

# ---- 心跳：證明 hook 真的有在跑 ----
# 四支 hook（handoff-lint／dlp-gate／guideline-gate／build-check）各有一份**逐字相同**的副本（test-hook-payload.ps1 守住）。
# Codex 沒信任 hooks、hooks.json 改過待重審、或叫不起 pwsh 時，這四支一次都不會跑，而且沒有任何提示 ——
# 看得見那件事的唯一線索是「agent 寫了產出，這裡的檔卻沒跟著變新」。doctor 拿它跟 bdd-docs/ 的產出比（Get-HookHeartbeat）。
# 只在 hook 在叫（payload 帶 hook_event_name）時寫：手動跑、-Path、-Json 都不算數。
# 寫不進去就算了 —— 心跳是證據，不是 gate；為了它讓一次寫檔或委派失敗是本末倒置。
function Write-HookHeartbeat([string]$eventName, [string]$name) {
    if (-not $eventName) { return }
    try {
        $dir = Join-Path (Get-Location).Path 'bdd-docs/.cache/hooks'
        [void][IO.Directory]::CreateDirectory($dir)
        [IO.File]::WriteAllText((Join-Path $dir "$name.last"), "$([DateTime]::UtcNow.ToString('o')) $eventName`n", [Text.UTF8Encoding]::new($false))
    } catch { }
}

# 一律正規化成「相對 cwd、正斜線」—— hook 的 cwd 就是專案根。
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

function Write-Result([bool]$passed, [bool]$disabled, [string[]]$scanned, $findings) {
    if (-not $Json) { return }
    [pscustomobject]@{
        passed   = $passed
        disabled = $disabled
        scanned  = @($scanned)
        findings = @($findings)
    } | ConvertTo-Json -Depth 6 -Compress
}

$hook = [pscustomobject]@{ event = ''; paths = @() }
if (-not $Path) {
    if (-not $Payload) { $Payload = Read-StdinUtf8 }
    if (-not $Payload) { Write-Result $true $false @() @(); exit 0 }
    $hook = Read-HookPayload $Payload
    Write-HookHeartbeat $hook.event 'dlp-gate'
    $Path = $hook.paths
}
if (-not (Test-Path $ScanScript)) { Write-Result $true $false @() @(); exit 0 }

# 標記檔關掉時**每次都喊**（不阻斷，exit 仍是 0）。標記檔通常是某一次為了解卡建的，
# 建完就留在那裡 —— 之後每一個需求都在沒有殘留掃描的情況下寫檔，而畫面上一切正常。
# 靜默地「防護其實沒在生效」比擋錯更糟，這一行是唯一會提醒的東西。
if (Test-Path $DisableMarker) {
    $msg = "[Hook][DLP] 已被 $DisableMarker 關閉 —— 這次沒有掃任何檔。要恢復就刪掉那個標記檔。"
    [Console]::Error.WriteLine($msg)
    Write-HookContext $hook.event @($msg)
    Write-Result $true $true @() @()
    exit 0
}

$targets = @($Path | ForEach-Object { ConvertTo-RelPath $_ } |
             Where-Object { $_ -match '^bdd-docs/' } |
             Sort-Object -Unique |
             Where-Object { (Test-Path -LiteralPath $_) -and -not (Get-Item -LiteralPath $_).PSIsContainer })

# 全部掃完才決定 exit —— 報第一個就停，同一次寫入的第二個檔要等下一輪才看得到。
# 殘留掃描在同一個行程裡跑：它把 JSON 寫到管線、用 exit code 回報，接得起來。以前每個檔另起一個 pwsh，
# 寫一次 spec.md 這支 gate 就要 3 秒多（一般 1.6 秒）—— 而 bdd-docs/ 是這支 gate 唯一會掃的地方。
$scanFull = (Resolve-Path -LiteralPath $ScanScript).Path
$findings = @()
foreach ($p in $targets) {
    $global:LASTEXITCODE = 0
    $out = & $scanFull -Path $p
    if ($LASTEXITCODE -eq 2) {
        [Console]::Error.WriteLine("[Hook][DLP] Residual sensitive pattern in ${p}: $out")
        $scan = $null
        try { $scan = ($out | Out-String) | ConvertFrom-Json } catch { }
        # 陣列一定要先放進變數：寫成 `categories = if (...) { @(...) }` 的話，if 敘述的輸出會把
        # 單元素陣列攤平成一個物件，-Json 的讀者（extension）就收到 object 而不是 array。
        $cats = @(); $refs = @()
        if ($scan) { $cats = @($scan.categories); $refs = @($scan.line_refs) }
        $findings += [pscustomobject]@{ file = $p; categories = $cats; lines = $refs }
    }
}

# ---- 上一份的 [必修] 不能無聲消失 ----
# reviewer 每一輪整份覆寫 review.md。上一輪的某項 [必修] 這一輪沒再出現，分不出是修好了、被接受了，還是忘了看 ——
# 而 PASS 就是從那裡漏出去的。借 REA 的 closure history：未完成的數量每少一項，都要指名是哪一項、憑什麼。
# 所以上一份（最新的快照）的每一項 [必修]，新的這份要嘛照樣列成 [必修]（同一個檔），要嘛寫進「## 上一輪必修的交代」：
#   - {檔:行} —— {問題}：已修 —— {證據}       或       ：接受不修 —— {理由}
# 對應只看檔（行號與措辭每輪都會變）：同一個檔，上一份有幾項，新的這份「仍是必修」加「有交代」就要有幾項。
# 解析格式跟 sdlc.ps1 learn 的 Read-ReviewFindings 同一條（reviewer.toml 規定的那一行）。
function Get-MustItems([string]$text) {
    $out = @()
    foreach ($line in ($text -replace "`r`n", "`n") -split "`n") {
        $m = [regex]::Match($line, '^\s*\d+\.\s*\[必修\]\s*(.+?)\s+——\s+(.+?)\s*$')
        if (-not $m.Success) { continue }
        $loc = $m.Groups[1].Value.Trim().Trim('`', '{', '}')
        $out += [pscustomobject]@{ location = $loc; file = ($loc -replace '(:\d+(-\d+)?)+$', ''); problem = $m.Groups[2].Value }
    }
    return $out
}

function Get-AccountedFiles([string]$text) {
    $out = @(); $in = $false
    foreach ($line in ($text -replace "`r`n", "`n") -split "`n") {
        if ($line -match '^##\s') { $in = $line -match '^##\s*上一輪必修的交代'; continue }
        if (-not $in) { continue }
        $m = [regex]::Match($line, '^\s*[-*]\s*(.+?)\s+——\s+.+?[:：]\s*(已修|接受不修)\s*——\s*\S')
        if ($m.Success) { $out += ($m.Groups[1].Value.Trim().Trim('`', '{', '}') -replace '(:\d+(-\d+)?)+$', '') }
    }
    return $out
}

function Get-UnaccountedMust([string]$prevText, [string]$newText) {
    $prev = @(Get-MustItems $prevText)
    if (-not $prev.Count) { return @() }
    $open = @(Get-MustItems $newText | ForEach-Object { $_.file })
    $done = @(Get-AccountedFiles $newText)
    $missing = @()
    foreach ($g in ($prev | Group-Object file)) {
        $have = @($open | Where-Object { $_ -eq $g.Name }).Count + @($done | Where-Object { $_ -eq $g.Name }).Count
        if ($have -lt $g.Count) { $missing += $g.Group }
    }
    return $missing
}

# ---- 每一輪審核留一份快照 ----
# reviewer 每一輪都整份覆寫 review.md（修正輪的 implementer 只該看最新那份）。代價是 PASS 之後，前幾輪抓到、
# 已經修掉的 [必修] 在磁碟上一項都不剩 —— 而「同一類錯一再被抓」只看得到那些（sdlc.ps1 learn 讀這些快照）。
# 放在這支，是因為它是唯一只看 bdd-docs/ 寫入的 hook；另開一條 hook 每個 patch 多付一次 pwsh 啟動，還要重新信任。
# 掃出殘留的不留：那一份照 runbook 要刪掉，快照會把它保存下來（DLP 被關掉時上面就 exit 了，理由相同）。
# 跟最新一份快照逐字相同就不留 —— 一輪審核常是好幾個 patch。只在 hook 在叫時做：手動 -Path 掃不算一輪。
# 上一份的 [必修] 沒交代的也不留：留了，下一次寫入就拿它當「上一份」，沒交代的那幾項從此脫鉤。
$unaccounted = @()
if ($hook.event) {
    foreach ($p in $targets) {
        $m = [regex]::Match($p, '^bdd-docs/([^/.][^/]*)/review\.md$')
        if (-not $m.Success -or @($findings | Where-Object file -eq $p).Count) { continue }
        try {
            $text = [IO.File]::ReadAllText((Join-Path (Get-Location).Path $p))
            $dir = Join-Path (Get-Location).Path "bdd-docs/$($m.Groups[1].Value)/reviews"
            $last = @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc, Name | Select-Object -Last 1)
            if ($last.Count -and [IO.File]::ReadAllText($last[0].FullName) -eq $text) { continue }
            if ($last.Count) {
                $miss = @(Get-UnaccountedMust ([IO.File]::ReadAllText($last[0].FullName)) $text)
                if ($miss.Count) {
                    $unaccounted += $miss
                    [Console]::Error.WriteLine("[Hook][review] $p：上一份 review.md 的這幾項 [必修] 在新的這份裡沒有交代 —— 沒修好就照樣列成 [必修]；修好了或接受不修，寫進「## 上一輪必修的交代」，一項一行：- {檔:行} —— {問題}：已修 —— {證據：測試名稱或 檔:行}（或：接受不修 —— {理由}）")
                    foreach ($x in $miss) { [Console]::Error.WriteLine("  - $($x.location) —— $($x.problem)") }
                    continue
                }
            }
            [void][IO.Directory]::CreateDirectory($dir)
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
            $dest = Join-Path $dir "$stamp.md"; $n = 1
            while (Test-Path -LiteralPath $dest) { $n++; $dest = Join-Path $dir "$stamp-$n.md" }
            [IO.File]::WriteAllText($dest, $text, [Text.UTF8Encoding]::new($false))
        } catch { }
    }
}

Write-Result ($findings.Count -eq 0) $false $targets $findings
if ($findings.Count -gt 0 -or $unaccounted.Count -gt 0) { exit 2 }
exit 0
