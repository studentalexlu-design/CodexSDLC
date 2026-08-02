# test-dlp.ps1
# DLP 是「不可逆錯誤」那一類：敏感資料一旦寫進 artifact 或送進子代理 prompt 就收不回來。
# 兩支腳本分工：dlp-residual-scan 做確定性偵測，dlp-gate 是 PostToolUse 的縱深防禦。
#
# 安全契約的關鍵一條：**絕不輸出命中的原始值**。這條若破了，掃描器自己就變成外洩管道。

$Scan = '.codex/scripts/dlp-residual-scan.ps1'
$Gate = '.codex/scripts/dlp-gate.ps1'

Describe-Suite 'dlp-residual-scan / 偵測' {

    It-Should '乾淨文字通過（exit 0）' {
        $r = Invoke-Script $Scan -Params @{ InputText = '訂單狀態由 pending 轉為 confirmed。' }
        Assert-Equal 0 $r.exit
        $j = $r.stdout | ConvertFrom-Json
        Assert-True $j.passed
        Assert-Equal 0 $j.residual_count
    }

    It-Should 'email 被偵測' {
        $r = Invoke-Script $Scan -Params @{ InputText = '聯絡人 alice@contoso.com 已確認' }
        Assert-Equal 2 $r.exit
        Assert-Match 'email' $r.stdout
    }

    It-Should '連線字串被偵測' {
        $r = Invoke-Script $Scan -Params @{ InputText = 'Server=db01;Initial Catalog=Orders;User Id=sa;' }
        Assert-Equal 2 $r.exit
        Assert-Match 'connstring' $r.stdout
    }

    It-Should '台灣身分證字號被偵測' {
        $r = Invoke-Script $Scan -Params @{ InputText = '申請人 A123456789 已建檔' }
        Assert-Equal 2 $r.exit
        Assert-Match 'tw_id' $r.stdout
    }

    It-Should 'allowlist 內的位址不算殘留' {
        $r = Invoke-Script $Scan -Params @{ InputText = 'bind 127.0.0.1 與 0.0.0.0' }
        Assert-Equal 0 $r.exit
    }

    It-Should '**絕不輸出命中的原始值**（安全契約）' {
        $secret = 'alice.wang@contoso.com'
        $r = Invoke-Script $Scan -Params @{ InputText = "負責人 $secret 已核准" }
        Assert-Equal 2 $r.exit
        Assert-True ($r.stdout -notmatch [regex]::Escape($secret)) '掃描結果洩漏了原始命中值'
        Assert-True ($r.stdout -notmatch 'alice') '掃描結果洩漏了原始命中值片段'
    }

    It-Should '只輸出類別、計數與行號' {
        $r = Invoke-Script $Scan -Params @{ InputText = "第一行`n第二行 bob@x.com" }
        $j = $r.stdout | ConvertFrom-Json
        # ConvertTo-Json 會把單元素陣列攤平成純量，統一用 @() 包起來再取。
        Assert-Equal 2 @($j.line_refs)[0]
        Assert-Equal 'email' @($j.categories)[0].type
    }

    It-Should '-InputText 真的有被讀進來（scanned_chars 不得為 0）' {
        # 迴歸鎖定：Get-InputContent 曾用 $PSBoundParameters 判斷 -InputText，
        # 但那在函式內指的是函式自己的參數 —— 永遠為空，於是一律落到 stdin。
        # hook 之外的呼叫端（orchestrator 的委派前掃描）以 -InputText 傳入時，
        # 會拿到 scanned_chars=0 + passed=true 的假全綠。
        $text = '客戶 erin@contoso.com 已建檔'
        $r = Invoke-Script $Scan -Params @{ InputText = $text }
        $j = $r.stdout | ConvertFrom-Json
        Assert-True ($j.scanned_chars -gt 0) '-InputText 沒有被讀進來，掃描的是空字串'
        Assert-Equal $text.Length $j.scanned_chars
    }

    It-Should '-Categories 可縮小掃描範圍' {
        $r = Invoke-Script $Scan -Params @{ InputText = 'a@b.com'; Categories = 'ipv4' }
        Assert-Equal 0 $r.exit '只掃 ipv4 時不該命中 email'
    }
}

Describe-Suite 'dlp-gate / PostToolUse 短路' {

    It-Should 'payload 未提及 bdd-docs 路徑時靜默通過' {
        $r = Invoke-Script $Gate -Stdin '{"tool_input":{"path":"src/A.cs"}}'
        Assert-Equal 0 $r.exit
    }

    It-Should '偵測到殘留時阻斷' {
        $dir = 'bdd-docs/test-dlp-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-Item -ItemType Directory -Path "$dir/artifacts" -Force | Out-Null
        $f = "$dir/artifacts/notes.md"
        Set-Content $f -Value '客戶 carol@contoso.com 反映結帳失敗'
        try {
            $r = Invoke-Script $Gate -Stdin "{`"tool_input`":{`"path`":`"$f`"}}"
            Assert-Equal 2 $r.exit
            Assert-Match 'Residual sensitive pattern' $r.stderr
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '.dlp-disabled 標記讓整個專案短路' {
        # v4.0.0 起是**專案層級**的宣告（bdd-docs/.dlp-disabled）。
        # v3 是 run 層級，而 v4 沒有 run —— 若這裡沒跟著改，標記檔會永遠命中不了，
        # 症狀是「掃描一直跑但沒人發現關不掉」，屬於靜默的浪費而非錯誤。
        $dir = 'bdd-docs/test-dlp-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $f = "$dir/notes.md"
        Set-Content $f -Value '客戶 dave@contoso.com 反映結帳失敗'
        $marker = 'bdd-docs/.dlp-disabled'
        $markerPreexisting = Test-Path $marker
        if (-not $markerPreexisting) { Set-Content $marker -Value 'test opt-out' }
        try {
            $r = Invoke-Script $Gate -Stdin "{`"tool_input`":{`"path`":`"$f`"}}"
            Assert-Equal 0 $r.exit "有 .dlp-disabled 時不該阻斷；stderr: $($r.stderr)"
        } finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $markerPreexisting) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should '沒有標記檔時同樣的內容會被阻斷（證明上一條真的是標記在起作用）' {
        $dir = 'bdd-docs/test-dlp-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $f = "$dir/notes.md"
        Set-Content $f -Value '客戶 dave@contoso.com 反映結帳失敗'
        try {
            Assert-True (-not (Test-Path 'bdd-docs/.dlp-disabled')) '前提：標記檔必須不存在'
            $r = Invoke-Script $Gate -Stdin "{`"tool_input`":{`"path`":`"$f`"}}"
            Assert-Equal 2 $r.exit
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '單引號路徑也會被掃到（shell 寫入慣用單引號）' {
        $dir = 'bdd-docs/test-dlp-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        New-Item -ItemType Directory -Path "$dir/artifacts" -Force | Out-Null
        $f = "$dir/artifacts/notes.md"
        Set-Content $f -Value 'Server=db01;Initial Catalog=X;'
        try {
            $r = Invoke-Script $Gate -Stdin "{""command"":""echo x > '$f'""}"
            Assert-Equal 2 $r.exit '單引號路徑漏掃會讓經 shell 寫入的 artifact 完全躲過本 gate'
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
