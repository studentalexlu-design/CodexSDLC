# test-handoff-lint.ps1
# handoff-lint 是整套流程唯一不依賴模型自律的強制層。它的失效是雙向的：
#   - 假阻斷：payload 抽取錯誤 → 每次 spawn 都被 missing-mode 擋死 → 流程完全跑不動
#   - 假放行：規則沒命中 → 上限與禁用 payload 靜默失效
# 這兩種都不會有人回報，所以必須有測試。

$Script = '.codex/scripts/handoff-lint.ps1'

# 一份合法的最小 handoff（分析階段，不需要 spec.md）。
$ValidAnalyze = @'
## constraints
- 只傳 path 與 <=300 字摘要，不貼全文

## meta
- feature-id: order-cancel
- mode: analyze

## summary
需求已定案：已出貨的訂單不可取消。請查現況並給 2-4 個技術做法。
'@

# 交付階段的 handoff —— 必須錨定 spec.md。
$ValidBuild = @'
## meta
- feature-id: order-cancel
- mode: build

## target
- spec: bdd-docs/order-cancel/spec.md

## summary
依 spec.md 的驗收條件實作。
'@

function New-Payload {
    param([string]$Prompt, [string]$Shape = 'nested')
    switch ($Shape) {
        'flat'     { return (@{ prompt = $Prompt } | ConvertTo-Json -Depth 4 -Compress) }
        'nested'   { return (@{ tool_name = 'agent'; tool_input = @{ prompt = $Prompt } } | ConvertTo-Json -Depth 4 -Compress) }
        'deep'     { return (@{ hook = @{ event = 'PreToolUse'; call = @{ tool_input = @{ subagent_type = 'implementer'; prompt = $Prompt } } } } | ConvertTo-Json -Depth 6 -Compress) }
        'withdesc' { return (@{ tool_input = @{ description = 'spawn implementer'; prompt = $Prompt } } | ConvertTo-Json -Depth 4 -Compress) }
        'raw'      { return $Prompt }
    }
}

Describe-Suite 'handoff-lint / payload 形狀' {

    # 這是本檔存在的首要理由。舊版用 regex 撈 "prompt" 欄位、撈不到就把整包 JSON
    # 當 prompt —— 那時所有 `(?m)^\s*mode:` 行首正則都落空，於是「完全合法的 handoff」
    # 會被判成缺欄位，spawn 被永久擋死。
    foreach ($shape in @('flat', 'nested', 'deep', 'withdesc', 'raw')) {
        It-Should "合法 handoff 在 $shape 形狀下通過" {
            $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $ValidAnalyze -Shape $shape)
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        }
    }

    It-Should '巢狀 payload 量到的是 prompt 長度，不是整包 JSON 長度' {
        # 整包 JSON 比 prompt 長；若抽取錯誤，長度檢查會量到整包。
        # 這裡用一個「prompt 剛好合法、但整包超過 1200」的 payload 來分辨兩者。
        $filler = 'x' * 1200
        $payload = @{
            tool_name = 'agent'
            tool_input = @{ prompt = $ValidAnalyze }
            unrelated_metadata = $filler
        } | ConvertTo-Json -Depth 4 -Compress
        Assert-True ($payload.Length -gt 1200) '前提：整包 payload 必須超過上限才驗得出差異'
        $r = Invoke-Script $Script -Stdin $payload
        Assert-Equal 0 $r.exit "抽到整包 JSON 才會失敗；stderr: $($r.stderr)"
    }

    It-Should 'JSON 轉義的換行被還原（否則行首正則全部落空）' {
        $payload = '{"tool_input":{"prompt":"## meta\n- feature-id: f1\n- mode: analyze\n"}}'
        $r = Invoke-Script $Script -Stdin $payload
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }

    It-Should '空 payload 靜默通過（非 spawn 的工具呼叫不該被擋）' {
        $r = Invoke-Script $Script -Stdin ''
        Assert-Equal 0 $r.exit
    }

    # 欄位名不叫 "prompt" 時 —— 這是唯一能分辨新舊抽取邏輯的案例。
    # 注意本案例的性質：Codex 實際 payload 用哪個欄位名**尚未證實**。
    # 這裡涵蓋的是「萬一不是 prompt」的情形，不是已觀測到的缺陷。
    foreach ($field in @('instructions', 'input', 'arguments')) {
        It-Should "欄位名為 $field 時仍能正確抽取" {
            $payload = @{ tool_input = @{ $field = $ValidAnalyze } } | ConvertTo-Json -Depth 4 -Compress
            $r = Invoke-Script $Script -Stdin $payload
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        }
    }
}

Describe-Suite 'handoff-lint / 必填欄位' {

    It-Should '缺 mode 被阻斷' {
        $p = $ValidAnalyze -replace '(?m)^- mode: analyze\r?\n', ''
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'missing-mode' $r.stderr
    }

    It-Should '缺 feature-id 被阻斷' {
        # 子代理靠 feature-id 定位 bdd-docs/{feature-id}/ 底下的產物。
        # 缺了它，子代理只能猜路徑 —— 猜錯的症狀是「寫到別的 feature 目錄下」，
        # 而那不會有任何機制發現。
        $p = $ValidAnalyze -replace '(?m)^- feature-id: order-cancel\r?\n', ''
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'missing-feature-id' $r.stderr
    }

    It-Should '多個 mode 宣告被阻斷' {
        $p = $ValidAnalyze -replace '(?m)^- mode: analyze', "- mode: analyze`n- mode: build"
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'multiple-modes' $r.stderr
    }

    It-Should 'v4 已移除 tier —— 帶著舊的 tier 欄位仍應通過（不是錯誤，只是多餘）' {
        # 這條的用意是防止「移除檢查」變成「新增反向檢查」。
        # 舊 handoff 混進來時該做的是忽略多餘欄位，不是製造新的阻斷點。
        $p = $ValidAnalyze -replace '(?m)^- mode: analyze', "- mode: analyze`n- tier: t2"
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }
}

Describe-Suite 'handoff-lint / 驗收依據與修正輪' {

    It-Should '交付型 mode 通過（有 spec.md）' {
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $ValidBuild)
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }

    It-Should 'mode: survey 不需要 spec.md（需求還很空，還沒有 spec 可帶）' {
        # survey 跑在 ① 起草之前，那時 spec.md 根本還不存在。把它加進交付型 mode 的清單，
        # 需求很空的那條路就在第一次 spawn 被擋死。
        $p = $ValidAnalyze -replace 'mode: analyze', 'mode: survey'
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }

    foreach ($m in @('build', 'code')) {
        It-Should "mode: $m 缺 spec.md 被阻斷" {
            # 沒有驗收條件就開工 = 讓子代理猜使用者要什麼。那是最貴的一種返工，
            # 而且症狀出現在最後（reviewer 或使用者才發現做錯方向）。
            $p = ($ValidBuild -replace 'mode: build', "mode: $m") -replace '(?m)^- spec:.*\r?\n', ''
            $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
            Assert-Equal 2 $r.exit
            Assert-Match 'missing-spec-ref' $r.stderr
        }
    }

    # 修正輪的三條都指向一個不存在的設定檔：上限會讀 sdlc.config.json，而維護者本機的 repo 根可能真的有一份。
    $NoConfig = 'hl-no-such-sdlc.config.json'

    It-Should 'mode: fix 缺 round 被阻斷' {
        $p = ($ValidBuild -replace 'mode: build', 'mode: fix')
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p) -Params @{ ConfigFile = $NoConfig }
        Assert-Equal 2 $r.exit
        Assert-Match 'missing-round' $r.stderr
    }

    It-Should 'mode: fix 第 3 輪通過（沒有設定時上限是 3）' {
        $p = ($ValidBuild -replace 'mode: build', "mode: fix`n- round: 3")
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p) -Params @{ ConfigFile = $NoConfig }
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }

    It-Should 'mode: fix 第 4 輪被阻斷（沒有設定時上限是 3）' {
        # doer↔reviewer 的 ping-pong 沒有自然終點。輪次由 orchestrator 自報，
        # 但機械檢查讓「超過上限的那一輪」變成一個會被擋下的事件，而不是沒人注意到的數字。
        $p = ($ValidBuild -replace 'mode: build', "mode: fix`n- round: 4")
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p) -Params @{ ConfigFile = $NoConfig }
        Assert-Equal 2 $r.exit
        Assert-Match 'review-loop-exceeded' $r.stderr
    }
}

# ---- 修正輪上限可設定（sdlc.config.json 的 review.maxRounds）----
$HlScratch = Join-Path ([IO.Path]::GetTempPath()) 'codex-handoff-lint-rounds'

function New-HlConfig([string]$json) {
    New-Item -ItemType Directory -Path $HlScratch -Force | Out-Null
    $p = Join-Path $HlScratch ("sdlc.config.{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($p, $json, [Text.UTF8Encoding]::new($false))
    return $p
}
function New-HlRoundsConfig([string]$maxRoundsLiteral) {
    return New-HlConfig "{ `"agents`": {}, `"review`": { `"maxRounds`": $maxRoundsLiteral } }"
}
function Get-FixHandoff([int]$round) { return ($ValidBuild -replace 'mode: build', "mode: fix`n- round: $round") }
function Invoke-Fix([int]$round, [string]$config, [switch]$Codex, [hashtable]$Extra = @{}) {
    $stdin = if ($Codex) { New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ message = (Get-FixHandoff $round) } }
             else { New-Payload -Prompt (Get-FixHandoff $round) }
    $p = @{ ConfigFile = $config }
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    return Invoke-Script $Script -Stdin $stdin -Params $p
}

Describe-Suite 'handoff-lint / 修正輪上限（sdlc.config.json 的 review.maxRounds）' {

    It-Should 'maxRounds = 5 → 第 5 輪放行、第 6 輪擋，而且訊息帶實際上限' {
        $cfg = New-HlRoundsConfig '5'
        try {
            Assert-Equal 0 (Invoke-Fix 5 $cfg).exit '設了 5 卻擋下第 5 輪 —— 設定沒生效'
            $r = Invoke-Fix 6 $cfg
            Assert-Equal 2 $r.exit
            Assert-Match 'review-loop-exceeded' $r.stderr
            Assert-Match '上限 5' $r.stderr '擋下時沒講實際上限，orchestrator 不知道自己被擋在哪一輪'
        } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'maxRounds = 2 → 第 3 輪就擋' {
        $cfg = New-HlRoundsConfig '2'
        try {
            Assert-Equal 0 (Invoke-Fix 2 $cfg).exit
            Assert-Equal 2 (Invoke-Fix 3 $cfg).exit '設了 2 卻放行第 3 輪'
        } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    foreach ($bad in @('0', '6', '"3"', '2.5', 'true', 'null')) {
        It-Should "寫壞的值（$bad）→ 照預設 3 算、講出來，但不因此擋下合法的修正輪" {
            $cfg = New-HlRoundsConfig $bad
            try {
                $ok = Invoke-Fix 3 $cfg
                Assert-Equal 0 $ok.exit "設定寫壞就擋 spawn —— 擋下的理由跟他要做的事無關；stderr: $($ok.stderr)"
                Assert-Match 'review\.maxRounds' $ok.stderr '值寫壞了卻安靜地退回預設 —— 使用者會以為設定有效'
                Assert-Equal 2 (Invoke-Fix 4 $cfg).exit '值寫壞時沒有退回預設 3（保守的一側）'
            } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should 'review 不是物件、或設定檔整份壞掉 → 照預設 3 算，而且講出來' {
        foreach ($json in @('{ "review": 5 }', '{ "review": ')) {
            $cfg = New-HlConfig $json
            try {
                $r = Invoke-Fix 3 $cfg
                Assert-Equal 0 $r.exit "json=$json；stderr: $($r.stderr)"
                Assert-Match 'sdlc\.config\.json' $r.stderr "json=$json 壞掉卻沒講"
                Assert-Equal 2 (Invoke-Fix 4 $cfg).exit
            } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should '沒有 review 這一節 → 預設 3，而且完全安靜（舊的設定檔是合法狀態）' {
        $cfg = New-HlConfig '{ "agents": {} }'
        try {
            $r = Invoke-Fix 3 $cfg
            Assert-Equal 0 $r.exit
            Assert-True ($r.stderr -notmatch 'maxRounds') '沒設的值被當成寫壞'
            Assert-Equal 2 (Invoke-Fix 4 $cfg).exit
        } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-MaxReviewRounds 明確給了就蓋過設定檔' {
        $cfg = New-HlRoundsConfig '5'
        try {
            Assert-Equal 2 (Invoke-Fix 3 $cfg -Extra @{ MaxReviewRounds = 2 }).exit
        } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '-Json 回報實際上限與它從哪來' {
        $cfg = New-HlRoundsConfig '4'
        try {
            $j = (Invoke-Fix 2 $cfg -Extra @{ Json = $true }).stdout | ConvertFrom-Json
            Assert-Equal 4 $j.max_review_rounds
            Assert-Equal 'config' $j.max_review_rounds_source
            Assert-Equal 2 $j.round
        } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Codex 形狀：放行時用 additionalContext 告訴 orchestrator 第幾輪、上限幾輪' {
        # orchestrator 不讀設定檔。沒有這一行，設成 5 時它照 AGENTS.md 的預設在第 3 輪停下 —— 設定靜默無效。
        $cfg = New-HlRoundsConfig '5'
        try {
            $r = Invoke-Fix 2 $cfg -Codex
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-True ([bool]$r.stdout.Trim()) '沒有輸出任何 additionalContext —— orchestrator 不會知道上限是 5'
            $ctx = ($r.stdout.Trim() | ConvertFrom-Json).hookSpecificOutput
            Assert-Equal 'PreToolUse' $ctx.hookEventName
            Assert-Match '修正輪 2／上限 5' $ctx.additionalContext
            Assert-True ($ctx.additionalContext -notmatch '最後一輪') '還沒到上限卻說是最後一輪'

            $last = (Invoke-Fix 5 $cfg -Codex).stdout.Trim() | ConvertFrom-Json
            Assert-Match '最後一輪' $last.hookSpecificOutput.additionalContext '到了上限沒有講明還 FAIL 就要停下交回'
        } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '修正輪與更新通知同時要說 → 只輸出一個 JSON 物件，兩件事都在' {
        # 同一次 hook 輸出兩個 JSON 物件，Codex 會把整段判成 invalid output —— 兩句話一起不見。
        $cfg = New-HlRoundsConfig '3'
        $cur = [string](Get-Content '.codex/bdd-workflow/bdd-workflow-version.json' -Raw -Encoding UTF8 | ConvertFrom-Json).'contract-version'
        New-Item -ItemType Directory -Path 'bdd-docs/.sdlc' -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Get-Location) 'bdd-docs/.sdlc/update-cache.json'),
            "{ `"newer`": true, `"latest`": `"99.0.0`", `"installed`": `"$cur`", `"seen`": `"`" }", [Text.UTF8Encoding]::new($false))
        try {
            $r = Invoke-Fix 1 $cfg -Codex
            Assert-Equal 0 $r.exit
            $lines = @($r.stdout -split "`r?`n" | Where-Object { $_.Trim() })
            Assert-Equal 1 $lines.Count "stdout 有 $($lines.Count) 行 —— 必須是恰好一個 JSON 物件"
            $ctx = ($lines[0] | ConvertFrom-Json).hookSpecificOutput.additionalContext
            Assert-Match '修正輪 1／上限 3' $ctx
            Assert-Match '有新版 99\.0\.0' $ctx
        } finally {
            Remove-Item 'bdd-docs/.sdlc' -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It-Should '擋下時只叫它停下交回，不叫它去改設定（上限歸使用者決定）' {
        $cfg = New-HlRoundsConfig '2'
        try {
            $r = Invoke-Fix 3 $cfg
            $fix = @($r.stderr -split "`r?`n" | Where-Object { $_ -match '^\s+fix:' })
            Assert-True ($fix.Count -gt 0)
            Assert-True (($fix -join ' ') -notmatch 'sdlc\.config|maxRounds') '擋下的修法在教 orchestrator 去改上限'
            Assert-Match '交回使用者' ($fix -join ' ')
        } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'handoff-lint ↔ agent-lint：修正輪上限的範圍規則一致' {

    # 範圍規則在兩支腳本各一份（hook 與 lint 都要能獨立跑）。一邊改了另一邊沒跟上的症狀：
    # agent-lint 說合法、hook 卻照預設 3 算 —— doctor 綠燈，設定照樣沒生效。
    foreach ($literal in @('1', '3', '5', '0', '6', '-1', '"3"', '2.5', 'true', 'null')) {
        It-Should "review.maxRounds = $literal：hook 有沒有採用它，跟 lint 說它合不合法，必須一致" {
            $cfg = New-HlRoundsConfig $literal
            try {
                $hook = (Invoke-Fix 1 $cfg -Extra @{ Json = $true }).stdout | ConvertFrom-Json
                $lint = (Invoke-Script '.codex/scripts/agent-lint.ps1' -Params @{ ConfigFile = $cfg; Json = $true }).stdout | ConvertFrom-Json
                $lintSaysInvalid = @($lint.violations | Where-Object { $_.rule -like 'review-*' }).Count -gt 0
                $hookUsedIt = $hook.max_review_rounds_source -eq 'config'
                Assert-True ($hookUsedIt -ne $lintSaysInvalid) "hook 採用=$hookUsedIt，lint 判不合法=$lintSaysInvalid —— 兩份範圍規則已分岔"
            } finally { Remove-Item $HlScratch -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe-Suite 'handoff-lint / 長度與禁用 payload' {

    It-Should '超過 1200 字元被阻斷' {
        $p = $ValidAnalyze + "`n" + ('說明文字' * 400)
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'handoff-too-long' $r.stderr
    }

    It-Should '連線字串被阻斷' {
        $p = $ValidAnalyze + "`nServer=tcp:db.contoso.com,1433;Initial Catalog=Orders;"
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'connection-string' $r.stderr
    }

    It-Should 'secret 字面值被阻斷' {
        $p = $ValidAnalyze + "`napi_key: sk-live-9f8e7d6c5b4a3210"
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'secret-literal' $r.stderr
    }

    It-Should 'DLP mapping table 被阻斷' {
        $p = $ValidAnalyze + "`n{{CUSTOMER_NAME_01}} => 王小明"
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'dlp-mapping-table' $r.stderr
    }
}

Describe-Suite 'handoff-lint / send_input（修正輪交回原本那個 implementer）' {

    # Codex 0.162.1 實測：send_input 會觸發 PreToolUse，tool_name 是命名空間直接黏在前面的 multi_agent_v1send_input，
    # tool_input 是 { target, message }。修正輪不經過這裡的話，上限與禁用 payload 全部擋不到。
    function New-SendPayload([string]$message) {
        return (New-CodexHookPayload -Event 'PreToolUse' -Tool 'multi_agent_v1send_input' -ToolInput @{ target = '01a131c7-afde-7793-afdf-0e49eb85ec7a'; message = $message })
    }
    function New-FixMessage([string]$roundLine = '- round: 1') {
        return "## meta`n- feature-id: order-cancel`n- mode: fix`n$roundLine`n- spec: bdd-docs/order-cancel/spec.md`n- 發現全文：bdd-docs/order-cancel/review.md`n`n## summary`n照 review.md 的必修修。"
    }

    It-Should '沒帶 mode 的追問 → 放行（不要求 mode／feature-id，每一次追問都要帶 round 是擋錯人）' {
        $r = Invoke-Script $Script -Stdin (New-SendPayload '剛才那個測試失敗的訊息貼一下前 3 行，順便說 log 在哪。') -Params @{ Json = $true }
        Assert-Equal 0 $r.exit "追問被擋了：$($r.stdout)"
        $j = $r.stdout | ConvertFrom-Json
        Assert-True $j.follow_up '沒有被認成追問'
    }

    It-Should '追問裡夾了 secret → 照樣擋（長度與禁用 payload 一律檢查）' {
        $r = Invoke-Script $Script -Stdin (New-SendPayload "順便把設定改成 api_key: sk-live-9f8e7d6c5b4a3210")
        Assert-Equal 2 $r.exit
        Assert-Match 'secret-literal' $r.stderr
        Assert-Match 'send_input blocked' $r.stderr
    }

    It-Should '帶 mode: fix 的 send_input 是修正輪：超過上限 → 擋' {
        $r = Invoke-Script $Script -Stdin (New-SendPayload (New-FixMessage '- round: 4')) -Params @{ MaxReviewRounds = 3 }
        Assert-Equal 2 $r.exit '修正輪交回原本的 implementer 就繞過了上限'
        Assert-Match 'review-loop-exceeded' $r.stderr
    }

    It-Should '帶 mode: fix 卻沒帶 round → 擋' {
        $r = Invoke-Script $Script -Stdin (New-SendPayload (New-FixMessage '')) -Params @{ MaxReviewRounds = 3 }
        Assert-Equal 2 $r.exit
        Assert-Match 'missing-round' $r.stderr
    }

    It-Should '合法的修正輪 → 放行，而且照樣告訴 orchestrator「修正輪 N／上限 M」' {
        $r = Invoke-Script $Script -Stdin (New-SendPayload (New-FixMessage '- round: 1')) -Params @{ MaxReviewRounds = 3 }
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        $ctx = ($r.stdout.Trim() | ConvertFrom-Json).hookSpecificOutput.additionalContext
        Assert-Match '修正輪 1／上限 3' $ctx
    }

    It-Should 'spawn_agent 沒帶 mode → 照舊擋（追問的豁免只給 send_input）' {
        $p = New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ agent_type = 'implementer'; message = '剛才那個測試失敗的訊息貼一下。' }
        $r = Invoke-Script $Script -Stdin $p
        Assert-Equal 2 $r.exit '豁免漏到 spawn 了'
        Assert-Match 'missing-mode' $r.stderr
        Assert-Match 'spawn blocked' $r.stderr
    }
}

Describe-Suite 'handoff-lint / spawn 前先看 effort 跟模型對不對得上（這次 spawn 會不會被 Codex 拒絕）' {

    # Codex（0.154.0／0.162.1 實測）對「effort 不在模型支援之列」的 spawn 直接回錯，子代理根本起不來。
    # 這裡擋下來只是把理由換成改得動的那一句 —— 所以判不準的一律放行（沒有清單快取、清單裡沒有那個模型）。
    # agent 定義從 cwd 的 .codex/agents 讀，所以在暫存專案裡跑（腳本用絕對路徑）。
    $HandoffAbs = (Resolve-Path $Script).Path
    $SpawnRoot = Join-Path ([IO.Path]::GetTempPath()) 'codex-sdlc-spawn-tests'

    function New-SpawnProject([string[]]$tuning) {
        Remove-Item $SpawnRoot -Recurse -Force -ErrorAction SilentlyContinue
        $agents = Join-Path $SpawnRoot 'proj/.codex/agents'
        New-Item -ItemType Directory -Path $agents -Force | Out-Null
        $lines = @('name = "reviewer"', 'description = "x"') + $tuning + @("developer_instructions = '''", '# Reviewer', "'''")
        [IO.File]::WriteAllText((Join-Path $agents 'reviewer.toml'), (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
        return (Join-Path $SpawnRoot 'proj')
    }
    # sdlc.ps1 問過 codex 之後留下的那份快取（形狀同 Get-ModelCatalog 寫的）。
    function New-CatalogCache {
        $state = Join-Path $SpawnRoot 'state'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $doc = [ordered]@{
            codex = [ordered]@{ path = 'C:\fake\codex.exe'; version = '0.162.1' }; 'read-at' = (Get-Date).ToUniversalTime().ToString('o'); default = 'gpt-big'
            models = @(
                [ordered]@{ slug = 'gpt-big'; visible = $true; priority = 1; defaultEffort = 'low'; efforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra') }
                [ordered]@{ slug = 'gpt-mid'; visible = $true; priority = 2; defaultEffort = 'medium'; efforts = @('low', 'medium', 'high', 'xhigh') }
            )
        }
        [IO.File]::WriteAllText((Join-Path $state 'codex-models.json'), ($doc | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        return $state
    }
    function Invoke-Spawn([string]$proj, [string]$sessionModel, [string]$state, [hashtable]$extraInput = @{}) {
        $ti = @{ agent_type = 'reviewer'; message = $ValidAnalyze }
        foreach ($k in $extraInput.Keys) { $ti[$k] = $extraInput[$k] }
        Push-Location $proj
        try {
            # payload 的 model = 主對話當下用的模型（New-CodexHookPayload 寫死 gpt-5.5，換掉）
            $payload = (New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput $ti).Replace('"model":"gpt-5.5"', "`"model`":`"$sessionModel`"")
            return Invoke-Script $HandoffAbs -Stdin $payload -Env @{ CODEX_SDLC_STATE_DIR = $state }
        } finally { Pop-Location }
    }

    It-Should 'agent 釘的 effort 主對話的模型不支援 → 擋，理由附改法、並說不必重開對話；換成支援的模型就放行' {
        $proj = New-SpawnProject @('model_reasoning_effort = "ultra"')
        $state = New-CatalogCache
        try {
            $r = Invoke-Spawn $proj 'gpt-mid' $state
            Assert-Equal 2 $r.exit "stderr: $($r.stderr)"
            Assert-Match 'effort-unsupported' $r.stderr
            Assert-Match 'set agents\.reviewer\.effort=xhigh -Apply' $r.stderr '沒給改法 —— orchestrator 只能把 Codex 的錯原樣丟給使用者'
            Assert-Match '不必重開對話' $r.stderr
            $ok = Invoke-Spawn $proj 'gpt-big' $state
            Assert-Equal 0 $ok.exit "主對話用支援 ultra 的模型，卻被擋了：$($ok.stderr)"
        } finally { Remove-Item $SpawnRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'agent 自己釘了模型 → 看那個模型，不看主對話的' {
        $proj = New-SpawnProject @('model = "gpt-big"', 'model_reasoning_effort = "ultra"')
        $state = New-CatalogCache
        try {
            $r = Invoke-Spawn $proj 'gpt-mid' $state
            Assert-Equal 0 $r.exit "agent 用的是 gpt-big（支援 ultra），卻拿主對話的 gpt-mid 判：$($r.stderr)"
        } finally { Remove-Item $SpawnRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '判不準就不判：這台還沒有模型清單的快取 → 放行' {
        $proj = New-SpawnProject @('model_reasoning_effort = "ultra"')
        try {
            $r = Invoke-Spawn $proj 'gpt-mid' (Join-Path $SpawnRoot 'no-state')
            Assert-Equal 0 $r.exit "沒有清單也擋 —— 擋下的理由沒有根據：$($r.stderr)"
        } finally { Remove-Item $SpawnRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'spawn 參數帶了模型不支援的 reasoning_effort → 擋，叫它拿掉' {
        $proj = New-SpawnProject @()
        $state = New-CatalogCache
        try {
            $r = Invoke-Spawn $proj 'gpt-mid' $state @{ reasoning_effort = 'ultra' }
            Assert-Equal 2 $r.exit "stderr: $($r.stderr)"
            Assert-Match '拿掉 reasoning_effort' $r.stderr
        } finally { Remove-Item $SpawnRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'agent 釘了這台清單裡沒有的模型 → 不擋（Codex 會用 fallback 照跑），但要提醒一行' {
        $proj = New-SpawnProject @('model = "gpt-new"', 'model_reasoning_effort = "high"')
        $state = New-CatalogCache
        try {
            $r = Invoke-Spawn $proj 'gpt-mid' $state
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Match '不在這台 Codex 的模型清單裡' $r.stderr
            Assert-Match 'additionalContext' $r.stdout '提醒沒有送到 orchestrator（exit 0 的 stderr 會被 Codex 丟掉）'
        } finally { Remove-Item $SpawnRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
