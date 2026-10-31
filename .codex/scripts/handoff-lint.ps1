# handoff-lint.ps1
# 在 subagent spawn 前機械強制 handoff contract。把 prompt 裡的「規則」變成「保證」。
#
# v4.13.0 起也攔 send_input（Codex 0.162.1 的 tool_name 是 `multi_agent_v1send_input`）：修正輪改成把修正交回
# 原本那個 implementer，那則訊息不經過這裡的話，修正輪上限與禁用 payload 就擋不到。規則：
#   send_input 的訊息**帶了 `mode:`** → 就是一次 handoff，檢查跟 spawn 一模一樣（mode: fix 要 round、spec.md 路徑、受上限）；
#   **沒帶** → 那是追問或補資料，只查長度與禁用 payload，不要求 mode／feature-id（每一次追問都要帶 round 是擋錯人）。
#
# 檢查項：
#   1. handoff 長度 <= MaxChars（預設 1200）
#   2. 單一 operation mode（不得同時出現多個 mode 宣告）
#   3. 必填 meta：mode、feature-id
#   3a. 交付型 mode（build／fix／code）必須帶 spec.md 路徑 —— 沒有驗收條件就開工是最常見的返工來源
#   3b. 修正輪（mode: fix）必須帶 round；round 超過上限即阻斷
#       上限：-MaxReviewRounds ＞ sdlc.config.json 的 review.maxRounds（1–5）＞ 預設 3
#   3c. 同一個檔的 [必修] 修了兩輪還在 → 阻斷，交回使用者（v4.24.0；帳記在 bdd-docs/{id}/reviews/fix-rounds.json）
#   4. 禁用 payload：完整 log、長測試輸出、connection string、secret、DLP mapping table
#   5. 這次 spawn 會不會被 Codex 拒絕：effort 不在 agent 實際用的模型支援之列（v4.15.0；只判得準的才擋）
#
# 自 v4.0.0 起移除：tier 相關檢查、t0 零 spawn、discover 交付型 mode、
# 單點紀錄 mode、subagent 預算上限、successor 額度繼承。
# 那些檢查全部服務於 12-agent 的扇出控制；agent 收斂到 5 個、流程改為線性之後
# 它們沒有防守對象了。細節見 docs/design-rationale.md。
#
# Exit: 0 = 通過；2 = 違規（阻斷 spawn）。

[CmdletBinding()]
param(
    [string]$Payload,
    [int]$MaxChars = 1200,
    [int]$MaxReviewRounds = 3,                 # 明確給了就用它（測試用）；沒給就看設定檔
    [string]$ConfigFile = 'sdlc.config.json',
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

if (-not $Payload) { $Payload = Read-StdinUtf8 }
if (-not $Payload) { exit 0 }

$violations = @()

# hook 在叫的時候 payload 帶 hook_event_name —— 只有那時才寫給 Codex 的 additionalContext。
$hookEvent = ''
$toolName  = ''
try {
    $doc = $Payload | ConvertFrom-Json -ErrorAction Stop
    if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['hook_event_name']) { $hookEvent = [string]$doc.hook_event_name }
    if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['tool_name']) { $toolName = [string]$doc.tool_name }
} catch { }
Write-HookHeartbeat $hookEvent 'handoff-lint'
$isSendInput = $toolName -match 'send_input'
$verb = if ($isSendInput) { 'send_input' } else { 'spawn' }

# ---- 修正輪上限：使用者在 sdlc.config.json 的 review.maxRounds 決定 ----
# 由這支 hook **每次現讀**，不寫進 hooks.json：hook 指令一改，Codex 會把那條 hook 標成「改過、待重審」，
# 重新信任之前 handoff-lint 整支不跑（版本檔 v48-enforcement 實測）；hooks.json 升級時也會被覆蓋。
#
# 範圍 1–5：這個上限存在，是因為 doer↔reviewer 的來回沒有自然終點，而輪次是 orchestrator 自報的。
# 值不合法 → 照預設 3 算（保守的一側）並講出來；**不因為設定寫壞就擋 spawn** —— 擋下的理由跟他要做的事無關。
# agent-lint 檢查 13 有一份相同的範圍規則（lint 要能獨立驗），兩邊由 test-handoff-lint.ps1 的交叉測試綁在一起；
# 這三個常數跟 sdlc.config.schema.json 的 review.maxRounds 由 agent-lint 檢查 14 綁在一起（hook 不讀 schema：它要快，也要在 schema 不在時照跑）。
$DefaultReviewRounds    = 3
$MinReviewRounds        = 1
$MaxAllowedReviewRounds = 5
$roundsSource  = 'default'
$roundsProblem = $null
if ($PSBoundParameters.ContainsKey('MaxReviewRounds')) {
    $roundsSource = 'parameter'
} else {
    $MaxReviewRounds = $DefaultReviewRounds
    if (Test-Path $ConfigFile) {
        try {
            $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($cfg -is [pscustomobject] -and $cfg.PSObject.Properties['review']) {
                $review = $cfg.review
                if ($review -isnot [pscustomobject]) {
                    $roundsProblem = "sdlc.config.json 的 review 不是物件 —— 修正輪上限照預設 $DefaultReviewRounds 輪算。"
                } elseif ($review.PSObject.Properties['maxRounds']) {
                    $v = $review.maxRounds
                    if (($v -is [int] -or $v -is [long]) -and $v -ge $MinReviewRounds -and $v -le $MaxAllowedReviewRounds) {
                        $MaxReviewRounds = [int]$v
                        $roundsSource = 'config'
                    } else {
                        $roundsProblem = "sdlc.config.json 的 review.maxRounds 是 $(ConvertTo-Json -InputObject $v -Compress)，不是 $MinReviewRounds–$MaxAllowedReviewRounds 的整數 —— 修正輪上限照預設 $DefaultReviewRounds 輪算。"
                    }
                }
            }
        } catch {
            $roundsProblem = "sdlc.config.json 解析不了 —— 修正輪上限照預設 $DefaultReviewRounds 輪算。"
        }
    }
}
$roundsSourceText = switch ($roundsSource) {
    'config'    { 'sdlc.config.json 的 review.maxRounds' }
    'parameter' { '-MaxReviewRounds' }
    default     { '預設' }
}
$round = $null

# --- 抽出 handoff prompt 本體 ---
# hook payload 的形狀由 harness 決定，可能是 {"prompt":...}、{"tool_input":{"prompt":...}}
# 或更深的巢狀。抽錯的後果是雙向的且都很嚴重：抽到整包 JSON 會讓 `^mode:` 這類
# 行首正則全部落空 —— 每一次 spawn 都被 missing-mode 擋死；反之若完全抽不到，
# 長度檢查會量到錯的對象。因此改為「先解析 JSON、遞迴找已知欄位名、取最長者」，
# 解析失敗才退回舊的 regex，最後才退回整包。
function Get-HandoffPrompt {
    param([string]$Raw)

    $fieldNames = @('prompt', 'instructions', 'input', 'text', 'message', 'content', 'arguments', 'description')

    try {
        $root = $Raw | ConvertFrom-Json -ErrorAction Stop   # ConvertFrom-Json 會一併解掉 \n 與 \"
        $best = ''
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($root)
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if ($null -eq $cur -or $cur -is [string] -or $cur -is [ValueType]) { continue }
            if ($cur -is [System.Collections.IEnumerable]) {
                foreach ($item in $cur) { $queue.Enqueue($item) }
                continue
            }
            foreach ($p in $cur.PSObject.Properties) {
                if ($p.Value -is [string]) {
                    if ($p.Name -in $fieldNames -and $p.Value.Length -gt $best.Length) { $best = $p.Value }
                } else {
                    $queue.Enqueue($p.Value)
                }
            }
        }
        if ($best) { return $best }
    } catch { }

    $m = [regex]::Match($Raw, '"prompt"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { return ($m.Groups[1].Value -replace '\\n', "`n" -replace '\\"', '"') }

    return $Raw
}

$prompt = Get-HandoffPrompt -Raw $Payload

# --- 1. 長度 ---
if ($prompt.Length -gt $MaxChars) {
    $violations += [pscustomobject]@{
        rule = 'handoff-too-long'
        detail = "$($prompt.Length) chars > $MaxChars"
        fix = '只傳 feature-id、mode、spec.md path 與 <=300 字決策摘要。產物內容由子代理自己讀 path'
    }
}

# --- 2. 單一 mode ---
$modes = [regex]::Matches($prompt, '(?im)^\s*[-*]?\s*mode\s*:\s*([a-z0-9-]+)') |
    ForEach-Object { $_.Groups[1].Value.ToLower() } |
    Sort-Object -Unique
if ($modes.Count -gt 1) {
    $violations += [pscustomobject]@{
        rule = 'multiple-modes'
        detail = ($modes -join ', ')
        fix = '一次 handoff 只描述一個 operation mode'
    }
}

# --- 3. 必填 meta ---
# 沒帶 mode 的 send_input 是追問或補資料，不是 handoff —— 不要求 mode／feature-id（長度與禁用 payload 照查）。
$isFollowUp = $isSendInput -and $modes.Count -eq 0
if ($modes.Count -eq 0 -and -not $isFollowUp) {
    $violations += [pscustomobject]@{ rule='missing-mode'; detail='no mode: field'; fix='meta 區塊補 mode' }
}
if (-not $isFollowUp -and $prompt -notmatch '(?im)^\s*[-*]?\s*feature-id\s*:\s*\S') {
    $violations += [pscustomobject]@{
        rule = 'missing-feature-id'
        detail = 'no feature-id: field'
        fix = 'meta 區塊補 feature-id —— 子代理靠它定位 bdd-docs/{feature-id}/ 底下的產物'
    }
}

# --- 3a. 交付型 mode 必須有驗收依據 ---
# implementer 與 reviewer 的工作全部錨定在 spec.md 的驗收條件上。
# 沒帶就開工 = 靠子代理猜使用者要什麼，那是最貴的一種返工。
#
# 必須是**路徑**（含 `/`），不能只是散文裡提到「依 spec.md 的驗收條件」——
# 後者是子代理讀不到的東西，放行等於這個檢查形同虛設。
$specAnchoredModes = @('build', 'fix', 'code')
$anchorHit = @($modes | Where-Object { $_ -in $specAnchoredModes })
if ($anchorHit.Count -gt 0 -and $prompt -notmatch '(?i)[\w.-]+/spec\.md') {
    $violations += [pscustomobject]@{
        rule = 'missing-spec-ref'
        detail = "mode=$($anchorHit -join ',') 但 handoff 沒有 spec.md 路徑"
        fix = '先完成流程 ③ 定案並寫出 bdd-docs/{feature-id}/spec.md，再委派。不要讓子代理自己猜驗收條件'
    }
}

# --- 3b. 修正輪上限 ---
# doer↔reviewer 的 ping-pong 是沒有自然終點的迴圈。輪次由 orchestrator 自報，
# 但機械檢查讓「超過上限的那一輪」變成一個會被擋下的事件，而不是一個沒人注意到的數字。
# 訊息只講「停下來交回」，不講「去改設定」—— 上限歸使用者決定，要多跑一輪由他在交回時選。
if ($modes -contains 'fix') {
    $round = if ($prompt -match '(?im)^\s*[-*]?\s*round\s*:\s*(\d+)') { [int]$Matches[1] } else { $null }
    if ($null -eq $round) {
        $violations += [pscustomobject]@{
            rule = 'missing-round'
            detail = 'mode: fix 未帶 round'
            fix = 'meta 區塊補 round（第幾次修正輪，從 1 起算）'
        }
    } elseif ($round -gt $MaxReviewRounds) {
        $violations += [pscustomobject]@{
            rule = 'review-loop-exceeded'
            detail = "round=$round > 上限 $MaxReviewRounds（$roundsSourceText）"
            fix = '停止修正迴圈，以 Codex user confirmation 交回使用者裁定（接受現版本／指定重點跑最後一輪／暫停）'
        }
    }
}

# --- 3c. 同一個檔的 [必修] 修了兩輪還在 ---
# 輪數上限數的是整個迴圈；卡住的往往是其中一項：同一個方向修第三次，多半只是再付一輪 implementer ＋ reviewer。
# 借 archify 的修正上限（同一個問題經過兩次針對性修正還在 → 停下來回報缺口，不再盲修）：
#   修過一次還在 → reviewer 在那一項底下寫「上一輪也是必修：…」，implementer 換做法（prompt，見兩份 agent 定義）；
#   修過兩次還在 → 這裡擋下，交回使用者。他選「再修一輪」→ handoff 加 `stuck-approved: yes` 放行。
# 輪次的帳：每一次放行的 mode: fix 第 N 輪，記下當時 review.md（第 N 次審核）裡有 [必修] 的檔 → reviews/fix-rounds.json。
# round 1 重新起算（新的修正迴圈，可能是下一次迭代）。對應只看檔，跟 dlp-gate 的交代檢查同一個粒度 ——
# 同一個檔、不同的問題也算連續（寬的那一側是多問使用者一次，不會讓卡住的那一項繼續空轉）。
# 帳讀不到、寫不進去、或輪次跳號 → 連續就斷了，不擋（安全的一側：最多照舊跑到輪數上限）。
$ledgerPath = $null; $ledgerData = $null
if ($modes -contains 'fix' -and $null -ne $round -and $round -le $MaxReviewRounds) {
    try {
        $fid = if ($prompt -match '(?im)^\s*[-*]?\s*feature-id\s*:\s*([A-Za-z0-9][A-Za-z0-9._-]*)') { $Matches[1] } else { $null }
        $reviewPath = if ($fid) { "bdd-docs/$fid/review.md" } else { $null }
        if ($reviewPath -and (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
            $reviewText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $reviewPath).Path) -replace "`r`n", "`n"
            if ($reviewText -match '(?m)^\s*VERDICT\s*:\s*FAIL\b') {
                # 解析格式跟 dlp-gate 的 Get-MustItems 同一條（reviewer.toml 規定的那一行）
                $mustFiles = @([regex]::Matches($reviewText, '(?m)^\s*\d+\.\s*\[必修\]\s*(.+?)\s+——\s+') |
                    ForEach-Object { $_.Groups[1].Value.Trim().Trim('`', '{', '}') -replace '(:\d+(-\d+)?)+$', '' } | Select-Object -Unique)
                $ledgerPath = "bdd-docs/$fid/reviews/fix-rounds.json"
                $rounds = @{}
                if ($round -gt 1 -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
                    $old = Get-Content -LiteralPath $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($p in $old.rounds.PSObject.Properties) { if ([int]$p.Name -lt $round) { $rounds[[int]$p.Name] = @($p.Value | ForEach-Object { [string]$_ }) } }
                }
                $rounds[$round] = $mustFiles
                $stuck = @()
                foreach ($f in $mustFiles) {
                    $n = 0
                    for ($k = $round; $k -ge 1 -and $rounds.ContainsKey($k) -and ($f -cin $rounds[$k]); $k--) { $n++ }
                    if ($n -ge 3) { $stuck += "$f（第 $($round - $n + 1)–$round 次審核都有，修了 $($n - 1) 輪）" }
                }
                $approved = $prompt -match '(?im)^\s*[-*]?\s*stuck-approved\s*:\s*yes\b'
                if ($stuck.Count -and -not $approved) {
                    $violations += [pscustomobject]@{
                        rule = 'review-item-stuck'
                        detail = "同一個檔的 [必修] 修了兩輪還在：$($stuck -join '；')"
                        fix = '不要再原樣交回 implementer。以 Codex user confirmation 交回使用者裁定：換做法（回 ③ 改做法或驗收條件）／接受不修（寫進交付的殘留風險）／仍要再修一輪 → 他選了再修，handoff 的 meta 加一行 stuck-approved: yes 再送'
                    }
                }
                $ordered = [ordered]@{}
                foreach ($k in ($rounds.Keys | Sort-Object)) { $ordered["$k"] = @($rounds[$k]) }
                $ledgerData = [ordered]@{ 'feature-id' = $fid; note = 'handoff-lint 的修正輪帳：第 N 輪放行時 review.md 裡有 [必修] 的檔。可刪（刪了只是不再判「修了兩輪還在」）'; rounds = $ordered }
            }
        }
    } catch { $ledgerPath = $null; $ledgerData = $null }
}

# --- 4. 禁用 payload ---
$forbidden = @(
    @{ rule='full-operation-log';      pattern='(?s)##\s*log\.md.{2000,}' }
    @{ rule='long-test-output';        pattern='(?m)^\s*(Passed|Failed|Skipped)!?\s+-\s+Failed:.*(\r?\n.*){40,}' }
    @{ rule='connection-string';       pattern='(?i)(Server|Data Source)\s*=[^;]+;\s*(Initial Catalog|Database)\s*=' }
    @{ rule='secret-literal';          pattern='(?i)\b(api[_-]?key|password|pwd|secret|bearer)\s*[:=]\s*["'']?[A-Za-z0-9_\-\.]{12,}' }
    @{ rule='dlp-mapping-table';       pattern='(?s)\{\{[A-Z_]+_\d+\}\}\s*(=>|->|:)\s*\S+' }
)
foreach ($f in $forbidden) {
    if ($prompt -match $f.pattern) {
        $violations += [pscustomobject]@{ rule=$f.rule; detail='禁用 payload 命中'; fix='只傳 path 與 <=300 字摘要' }
    }
}

# --- 5. 這次 spawn 會不會被 Codex 拒絕：effort 不在模型支援之列 ---
# Codex（0.154.0／0.162.1 實測）對這種 spawn 直接回錯，子代理根本起不來 —— 擋下它沒有攔掉任何本來會成功的事，
# 只是把理由換成改得動的那一句（版本檔 v415-models）。判不準就不判：沒有模型清單的快取、清單裡沒有那個模型 → 放行。
#   模型：agent 定義釘的 ＞ spawn 參數 ＞ payload 的 model（主對話當下用的模型，不是從設定檔推出來的）
#   effort：agent 定義釘的 ＞ spawn 參數；兩邊都沒有 = 跟主對話一樣，不判
#   清單：sdlc.ps1 問過這台 Codex 之後留下的快取（doctor／set／apply／models 都會寫；位置同 sdlc.ps1 的 Get-SdlcStateDir）
$modelNote = $null
if (-not $isSendInput -and $doc -is [pscustomobject] -and $doc.PSObject.Properties['tool_input'] -and $doc.tool_input -is [pscustomobject]) {
    try {
        $ti = $doc.tool_input
        $agentType = if ($ti.PSObject.Properties['agent_type']) { [string]$ti.agent_type } else { '' }
        $pinModel = $null; $pinEffort = $null
        $toml = if ($agentType -match '^[\w.-]+$') { ".codex/agents/$agentType.toml" } else { $null }
        if ($toml -and (Test-Path -LiteralPath $toml -PathType Leaf)) {
            $head = ([IO.File]::ReadAllText($toml) -split '(?m)^developer_instructions\s*=')[0]
            $mm = [regex]::Match($head, '(?m)^\s*model\s*=\s*"([^"]+)"');                  if ($mm.Success) { $pinModel = $mm.Groups[1].Value }
            $me = [regex]::Match($head, '(?m)^\s*model_reasoning_effort\s*=\s*"([^"]+)"'); if ($me.Success) { $pinEffort = $me.Groups[1].Value }
        }
        $spawnModel  = if ($pinModel) { $pinModel } elseif ($ti.PSObject.Properties['model'] -and $ti.model) { [string]$ti.model } elseif ($doc.PSObject.Properties['model'] -and $doc.model) { [string]$doc.model } else { $null }
        $spawnEffort = if ($pinEffort) { $pinEffort } elseif ($ti.PSObject.Properties['reasoning_effort'] -and $ti.reasoning_effort) { [string]$ti.reasoning_effort } else { $null }
        $stateDir = if ($env:CODEX_SDLC_STATE_DIR) { $env:CODEX_SDLC_STATE_DIR } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'codex-sdlc' }
        $catalogPath = Join-Path $stateDir 'codex-models.json'
        if ($spawnModel -and (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
            $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry = @($catalog.models | Where-Object { $_ -and [string]$_.slug -ceq $spawnModel })[0]
            if ($entry -and $spawnEffort) {
                $levels = @($entry.efforts | ForEach-Object { [string]$_ })
                if ($levels.Count -gt 0 -and $spawnEffort -cnotin $levels) {
                    # 建議值：往下找最接近的（要的比上限高，就給上限）。順序 = 清單裡 effort 出現的順序（low → … → ultra）。
                    $order = [Collections.Generic.List[string]]::new()
                    foreach ($m in @($catalog.models)) { foreach ($e in @($m.efforts)) { if (-not $order.Contains([string]$e)) { $order.Add([string]$e) } } }
                    $down = @($levels | Where-Object { $order.IndexOf($_) -le $order.IndexOf($spawnEffort) } | Sort-Object { $order.IndexOf($_) })
                    $suggest = if ($down.Count) { $down[-1] } else { $levels[0] }
                    if ($pinEffort) {
                        $violations += [pscustomobject]@{
                            rule   = 'effort-unsupported'
                            detail = "$agentType 釘的 effort=$spawnEffort（sdlc.config.json），但 $spawnModel 只支援 $($levels -join '／') —— Codex 會拒絕這次 spawn"
                            fix    = "這不是 handoff 的問題，重送也一樣。停下來請使用者改設定，例如 pwsh .codex/scripts/sdlc.ps1 set agents.$agentType.effort=$suggest -Apply；改完直接重新委派，不必重開對話（Codex 每次 spawn 都重讀 agent 定義）"
                        }
                    } else {
                        $violations += [pscustomobject]@{
                            rule   = 'effort-unsupported'
                            detail = "spawn 參數 reasoning_effort=$spawnEffort，但 $spawnModel 只支援 $($levels -join '／') —— Codex 會拒絕這次 spawn"
                            fix    = "拿掉 reasoning_effort（跟主對話一樣），或改成 $suggest"
                        }
                    }
                }
            } elseif (-not $entry -and $pinModel) {
                $modelNote = "[sdlc] $agentType 釘的模型 $spawnModel 不在這台 Codex 的模型清單裡 —— 會用 fallback 的模型資料跑（表現變差，或被 API 拒絕）。可用的模型：pwsh .codex/scripts/sdlc.ps1 models"
            }
        }
    } catch { }
}

# --- 輸出 ---
if ($Json) {
    [pscustomobject]@{
        passed = ($violations.Count -eq 0)
        violation_count = $violations.Count
        prompt_chars = $prompt.Length
        tool = $verb
        follow_up = $isFollowUp
        modes = $modes
        round = $round
        max_review_rounds = $MaxReviewRounds
        max_review_rounds_source = $roundsSource
        max_review_rounds_problem = $roundsProblem
        violations = $violations
    } | ConvertTo-Json -Depth 4 -Compress
}

if ($violations.Count -gt 0) {
    if (-not $Json) {
        [Console]::Error.WriteLine("[Hook][handoff-lint] $($violations.Count) violation(s), $verb blocked:")
        foreach ($v in $violations) {
            [Console]::Error.WriteLine("  - $($v.rule): $($v.detail)")
            [Console]::Error.WriteLine("    fix: $($v.fix)")
        }
        if ($roundsProblem -and $modes -contains 'fix') { [Console]::Error.WriteLine("  ! $roundsProblem") }
    }
    exit 2
}

# 修正輪的帳只在放行、而且是 hook 在叫的時候記（手動跑、-Json 都不算一輪）。寫不進去就算了 —— 帳是線索，不是 gate。
if ($ledgerPath -and $ledgerData -and $hookEvent -and -not $Json) {
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path (Join-Path (Get-Location).Path $ledgerPath) -Parent))
        [IO.File]::WriteAllText((Join-Path (Get-Location).Path $ledgerPath), ($ledgerData | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    } catch { }
}

# --- 放行時要讓 orchestrator 知道的事（一個 additionalContext，不擋）---
# 同一次輸出只能有一個 JSON 物件，所以修正輪、模型提示與更新通知收在一起、最後一次寫出。
$contextLines = @()
if ($modelNote) {
    [Console]::Error.WriteLine($modelNote)
    $contextLines += $modelNote
}

# orchestrator 不讀 sdlc.config.json，它知道上限的唯一途徑就是這一行 —— 每一次 mode: fix 放行時說一次。
# 沒有這一行，設成 5 時它照 AGENTS.md 的預設在第 3 輪停下（設定靜默無效），設成 2 時它會去試第 3 輪才被擋。
if ($modes -contains 'fix' -and $null -ne $round) {
    $line = "[handoff-lint] 修正輪 $round／上限 $MaxReviewRounds（$roundsSourceText）"
    if ($round -ge $MaxReviewRounds) { $line += ' —— 這是最後一輪：還 FAIL 就停下，以 Codex user confirmation 交回使用者裁定。' }
    $contextLines += $line
    if ($roundsProblem) {
        [Console]::Error.WriteLine("[Hook][handoff-lint] $roundsProblem")
        $contextLines += "[handoff-lint] $roundsProblem"
    }
}

# --- 更新通知（不阻斷、不碰網路）---
# 這裡是唯一夠便宜的位置：PreToolUse 每個需求只觸發 4–5 次，不是每次寫檔。
#
# 四條紀律，每一條都有對應的失敗模式：
#   只讀本地 JSON —— 這支 hook 有 timeout，網路請求會擋在每一次 spawn 前面，
#   而「擋下的理由跟使用者要做的事無關、他也修不了」正是這套流程踩過兩次的失敗形狀。
#   整段包在 try/catch，任何例外都當作沒有更新 —— 通知壞掉不該讓流程停下來。
#   一行，不擋、不問、不自動升 —— 更新提示不得變成第三個必經確認
#   （AGENTS.md「必經的確認只有兩個」）。形狀比照 v4.5.1 的 kill switch 警告。
#   快取記的 installed 跟現在的版本檔對不上就不喊 —— 升級完、快取還沒刷新之前，
#   它會說「有新版 4.8.0（你在 4.7.0）」，而你已經在 4.8.0 上。一個會說謊的通知比沒有更糟。
#
# 那一行要到得了 orchestrator：Codex 0.154.0 會把 exit 0 的 stderr **整段丟掉**（見版本檔 v48-enforcement），
# 所以 hook 在叫（payload 帶 hook_event_name）時，同一句話另外寫成 stdout 上的 additionalContext。
# AGENTS.md 已經寫了看到 `[sdlc] 有新版…` 要怎麼處理（通知，不是待辦）。
#
# 快取由 `sdlc.ps1 check-update` 寫；`whatsnew` 會把 seen 設成該版本，於是看過就安靜下來。
try {
    $cachePath = 'bdd-docs/.sdlc/update-cache.json'
    if (Test-Path $cachePath) {
        $c = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $current = $null
        $verPath = '.codex/bdd-workflow/bdd-workflow-version.json'
        if (Test-Path $verPath) { $current = [string](Get-Content $verPath -Raw -Encoding UTF8 | ConvertFrom-Json).'contract-version' }
        $stale = $current -and $c.installed -and ([string]$c.installed -ne $current)
        if ($c.newer -and $c.latest -and $c.seen -ne $c.latest -and -not $stale) {
            $note = "[sdlc] 有新版 $($c.latest)（你在 $($c.installed)）。看變更：pwsh .codex/scripts/sdlc.ps1 whatsnew"
            [Console]::Error.WriteLine($note)
            $contextLines += $note
        }
    }
} catch { }

if ($contextLines.Count -gt 0 -and $hookEvent -and -not $Json) {
    [Console]::Out.WriteLine((@{ hookSpecificOutput = @{ hookEventName = $hookEvent; additionalContext = ($contextLines -join "`n") } } |
                              ConvertTo-Json -Compress -Depth 4))
}

exit 0
