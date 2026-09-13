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
