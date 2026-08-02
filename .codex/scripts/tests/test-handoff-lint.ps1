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

    It-Should 'mode: fix 缺 round 被阻斷' {
        $p = ($ValidBuild -replace 'mode: build', 'mode: fix')
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'missing-round' $r.stderr
    }

    It-Should 'mode: fix 第 3 輪通過' {
        $p = ($ValidBuild -replace 'mode: build', "mode: fix`n- round: 3")
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }

    It-Should 'mode: fix 第 4 輪被阻斷' {
        # doer↔reviewer 的 ping-pong 沒有自然終點。輪次由 orchestrator 自報，
        # 但機械檢查讓「第 4 輪」變成一個會被擋下的事件，而不是沒人注意到的數字。
        $p = ($ValidBuild -replace 'mode: build', "mode: fix`n- round: 4")
        $r = Invoke-Script $Script -Stdin (New-Payload -Prompt $p)
        Assert-Equal 2 $r.exit
        Assert-Match 'review-loop-exceeded' $r.stderr
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
