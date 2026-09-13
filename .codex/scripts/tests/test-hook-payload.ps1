# test-hook-payload.ps1
# 三支 PostToolUse gate 在**真正的 Codex payload** 上擋不擋得住。
#
# 這一組存在的理由是一次實測（Codex 0.154.0，版本檔 v48-enforcement）：舊的 gate 測試全綠，
# 但它們餵的是測試自己捏的形狀。換成 Codex 真的送出來的 payload 之後——
#   apply_patch 寫進 bdd-docs/ 的 email       → dlp-gate exit 0
#   apply_patch 寫出含 NOLOCK 的 .sql          → guideline-gate exit 0
#   apply_patch 改了 .cs                       → build-check 沒觸發
# 三支全漏，而且每一次都「成功完成」。所以下面每一條都用 New-CodexHookPayload（run-tests.ps1），
# 不准再手捏形狀。

$DlpGate = '.codex/scripts/dlp-gate.ps1'
$GlGate  = '.codex/scripts/guideline-gate.ps1'
$Build   = '.codex/scripts/build-check.ps1'

$HpRules = @'
{ "rules": [
  { "id": "no-nolock", "applies-to": ["**/*.sql"], "pattern": "(?i)NOLOCK", "severity": "block", "message": "禁止 NOLOCK", "fix": "改用快照隔離" },
  { "id": "no-star", "applies-to": ["**/*.sql"], "pattern": "(?i)SELECT\\s+\\*", "severity": "warn", "message": "不要 SELECT *", "fix": "列出欄位" }
] }
'@

function New-HpId { [guid]::NewGuid().ToString('N').Substring(0, 8) }

function New-HpFile([string]$rel, [string]$content) {
    $dir = Split-Path $rel -Parent
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path (Get-Location) $rel), $content, [Text.UTF8Encoding]::new($false))
}

function New-HpRules([string]$json = $HpRules) {
    $p = "hp-rules-$(New-HpId).json"
    [IO.File]::WriteAllText((Join-Path (Get-Location) $p), $json, [Text.UTF8Encoding]::new($false))
    return $p
}

function Get-HookContext([string]$stdout) {
    # hook 模式下 stdout 只能是一個 JSON 物件（或什麼都沒有）—— 其他東西會讓 Codex 判成 invalid output。
    if (-not $stdout.Trim()) { return $null }
    return ($stdout.Trim() | ConvertFrom-Json).hookSpecificOutput
}

Describe-Suite 'hook payload / apply_patch 寫的檔要掃得到（路徑在 patch 標頭、沒有引號）' {

    It-Should 'dlp-gate：Add File 進 bdd-docs/ 的敏感資料被阻斷' {
        $d = "bdd-docs/hp-$(New-HpId)"
        New-HpFile "$d/notes.md" "客戶 carol@contoso.com 反映結帳失敗`n"
        try {
            $r = Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/notes.md"))
            Assert-Equal 2 $r.exit 'apply_patch 寫進 bdd-docs/ 的 email 沒被擋 —— 這正是實測漏掉的那一條'
            Assert-Match 'Residual sensitive pattern' $r.stderr
            Assert-True ($r.stderr -notmatch 'carol') '阻斷訊息洩漏了命中的原始值'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'dlp-gate：Update File 同樣被阻斷' {
        $d = "bdd-docs/hp-$(New-HpId)"
        New-HpFile "$d/spec.md" "Server=db01;Initial Catalog=Orders;`n"
        try {
            $r = Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$d/spec.md"))
            Assert-Equal 2 $r.exit
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate：Add File 寫出 block 規則命中的 .sql 被阻斷，訊息帶檔:行' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        try {
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/q.sql")) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit 'apply_patch 寫出的 NOLOCK 沒被擋 —— 實測漏掉的第二條'
            Assert-Match 'no-nolock' $r.stderr
            Assert-Match "$d/q\.sql:1" $r.stderr
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate：Move to 掃的是搬過去的那個檔' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/new.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        try {
            $patch = New-CodexPatch -Move @("$d/old.sql", "$d/new.sql")
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command $patch) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit '搬移後的目的檔沒被掃'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate：patch 標頭寫絕對路徑也掃得到' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        try {
            $abs = Join-Path (Get-Location).Path "$d\q.sql"
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update $abs)) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit "絕對路徑沒被正規化成相對路徑；stderr: $($r.stderr)"
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'build-check：apply_patch 改 .cs 會觸發 build' {
        $r = Invoke-Script $Build -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update 'src/Orders/OrderService.cs')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=1' $r.stdout 'apply_patch 改了 production code 卻不 build —— 實測漏掉的第三條'
        Assert-Match 'TRIGGER src/Orders/OrderService\.cs' $r.stdout
    }

    It-Should 'build-check：bdd-docs/ 底下的產物照舊不觸發' {
        $r = Invoke-Script $Build -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add 'bdd-docs/f1/sample.cs')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=0' $r.stdout
    }
}

Describe-Suite 'hook payload / Bash（shell）寫的檔要掃得到' {

    It-Should 'dlp-gate：單引號路徑' {
        $d = "bdd-docs/hp-$(New-HpId)"
        New-HpFile "$d/notes.md" "聯絡人 dave@contoso.com`n"
        try {
            $cmd = "Set-Content -Path '$d/notes.md' -Value 'x'"
            $r = Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Tool 'Bash' -Command $cmd)
            Assert-Equal 2 $r.exit
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'dlp-gate：沒有引號的 bdd-docs/ 路徑' {
        # 敏感資料寫出去就收不回來，所以 DLP 這一支多認一種寫法：shell 指令裡裸寫的 bdd-docs/ 路徑。
        $d = "bdd-docs/hp-$(New-HpId)"
        New-HpFile "$d/notes.md" "聯絡人 erin@contoso.com`n"
        try {
            $cmd = "echo x > $d/notes.md"
            $r = Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Tool 'Bash' -Command $cmd)
            Assert-Equal 2 $r.exit '裸寫的 bdd-docs/ 路徑躲過了 DLP'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate：雙引號路徑' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        try {
            $cmd = "Set-Content -Path `"$d/q.sql`" -Value `$sql"
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Tool 'Bash' -Command $cmd) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'hook payload / 不是這次寫的檔就不要掃' {

    It-Should 'patch 內文裡的引號字串是檔案內容，不是路徑' {
        # 解碼之後 C# 的 "legacy.sql" 看起來就是一個乾淨的引號路徑。把它當成這次寫的檔，
        # 等於拿團隊規範去擋一個 agent 根本沒碰過的舊檔 —— 假阻斷，而且修不掉。
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/legacy.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        New-HpFile "$d/Repo.cs" "class Repo {}`n"
        try {
            $patch = "*** Begin Patch`n*** Update File: $d/Repo.cs`n@@`n-class Repo {}`n+class Repo { const string F = `"$d/legacy.sql`"; }`n*** End Patch`n"
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command $patch) -Params @{ RulesFile = $rules }
            Assert-Equal 0 $r.exit "patch 內文的字串被當成路徑掃了；stderr: $($r.stderr)"
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'transcript_path（對話紀錄）不掃' {
        $d = "hp-src-$(New-HpId)"
        $rules = New-HpRules '{ "rules": [ { "id": "no-nolock-anywhere", "pattern": "(?i)NOLOCK", "severity": "block", "message": "m" } ] }'
        New-HpFile "$d/rollout.jsonl" "{`"text`":`"WITH (NOLOCK)`"}`n"
        New-HpFile "$d/ok.txt" "clean`n"
        try {
            $payload = (New-CodexHookPayload -Command (New-CodexPatch -Update "$d/ok.txt")) |
                       ConvertFrom-Json
            $payload.transcript_path = (Join-Path (Get-Location).Path "$d/rollout.jsonl")
            $r = Invoke-Script $GlGate -Stdin ($payload | ConvertTo-Json -Depth 6 -Compress) -Params @{ RulesFile = $rules }
            Assert-Equal 0 $r.exit "掃到了對話紀錄；stderr: $($r.stderr)"
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'hook payload / 三支 gate 的抽取邏輯逐字相同' {

    It-Should 'Read-HookPayload 在三支腳本裡逐字相同' {
        # 重複是刻意的（gate 要能獨立跑），代價就是漂移。改一支忘了另外兩支的症狀，
        # 就是這一組測試當初要抓的東西：某一種寫法只有一支 gate 看得到。
        $bodies = @{}
        foreach ($s in @($DlpGate, $GlGate, $Build)) {
            $m = [regex]::Match([IO.File]::ReadAllText((Join-Path (Get-Location) $s)), '(?ms)^function Read-HookPayload.*?^\}')
            Assert-True $m.Success "$s 找不到 Read-HookPayload"
            $bodies[$s] = $m.Value -replace "`r`n", "`n"
        }
        Assert-True ($bodies[$DlpGate] -eq $bodies[$GlGate]) 'dlp-gate 與 guideline-gate 的抽取邏輯已漂移'
        Assert-True ($bodies[$DlpGate] -eq $bodies[$Build])  'dlp-gate 與 build-check 的抽取邏輯已漂移'
    }
}

Describe-Suite 'hook 通知 / 不阻斷的訊息要到得了 agent（Codex 會丟掉 exit 0 的 stderr）' {

    It-Should 'guideline-gate 被 .gate-disabled 關掉時，additionalContext 要喊' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        $marker = 'guidelines/.gate-disabled'
        $pre = Test-Path $marker
        New-HpFile "$d/q.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        if (-not $pre) { New-Item -ItemType Directory 'guidelines' -Force | Out-Null; Set-Content $marker 'test' }
        try {
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/q.sql")) -Params @{ RulesFile = $rules }
            Assert-Equal 0 $r.exit
            $ctx = Get-HookContext $r.stdout
            Assert-True ($null -ne $ctx) '只寫了 stderr —— Codex 會把它整段丟掉，關掉這件事又變回靜默的'
            Assert-Equal 'PostToolUse' $ctx.hookEventName
            Assert-Match '\.gate-disabled' $ctx.additionalContext
        } finally {
            Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $pre) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should 'guideline-gate 的 warn 命中要以 additionalContext 回到 agent 手上' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT * FROM T`n"
        try {
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/q.sql")) -Params @{ RulesFile = $rules }
            Assert-Equal 0 $r.exit 'warn 不該阻斷'
            $ctx = Get-HookContext $r.stdout
            Assert-True ($null -ne $ctx) 'warn 命中只寫了 stderr，agent 永遠看不到'
            Assert-Match 'no-star' $ctx.additionalContext
            Assert-Match "$d/q\.sql:1" $ctx.additionalContext
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate 的規則檔壞掉時，additionalContext 要喊' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules '{ "rules": [ { "id": "broken", "pattern": "(unclosed" } ] }'
        New-HpFile "$d/q.sql" "SELECT 1`n"
        try {
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/q.sql")) -Params @{ RulesFile = $rules }
            Assert-Equal 0 $r.exit
            $ctx = Get-HookContext $r.stdout
            Assert-True ($null -ne $ctx) '規則檔壞掉只寫了 stderr —— 規範沒生效，而沒有任何人看得到'
            Assert-Match '規則載入失敗' $ctx.additionalContext
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'dlp-gate 被 .dlp-disabled 關掉時，additionalContext 要喊' {
        $d = "bdd-docs/hp-$(New-HpId)"
        $marker = 'bdd-docs/.dlp-disabled'
        $pre = Test-Path $marker
        New-HpFile "$d/notes.md" "clean`n"
        if (-not $pre) { Set-Content $marker 'test' }
        try {
            $r = Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/notes.md"))
            Assert-Equal 0 $r.exit
            $ctx = Get-HookContext $r.stdout
            Assert-True ($null -ne $ctx) '只寫了 stderr —— Codex 會把它整段丟掉'
            Assert-Match '\.dlp-disabled' $ctx.additionalContext
        } finally {
            Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $pre) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should '沒有話要說時 stdout 保持空白' {
        # 空的 additionalContext 也會被塞進模型的 context —— 每次寫檔一條，純噪音。
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT Id FROM T`n"
        try {
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/q.sql")) -Params @{ RulesFile = $rules }
            Assert-Equal 0 $r.exit
            Assert-Equal '' $r.stdout.Trim() '乾淨的寫入卻輸出了東西'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '手動執行（不是 hook）時不輸出 hook JSON' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT * FROM T`n"
        try {
            $r = Invoke-Script $GlGate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 0 $r.exit
            Assert-Equal '' $r.stdout.Trim() '人在終端機跑的時候看到的應該是訊息，不是給 Codex 的 JSON'
            Assert-Match 'no-star' $r.stderr
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'dlp-gate / -Path 與 -Json（給 Problems 面板）' {

    It-Should '回報檔、類別與每一類的行號，而且不含原始值' {
        $d = "bdd-docs/hp-$(New-HpId)"
        New-HpFile "$d/notes.md" "第一行`n客戶 frank@contoso.com`n"
        try {
            $r = Invoke-Script $DlpGate -Params @{ Path = "$d/notes.md"; Json = $true }
            Assert-Equal 2 $r.exit
            $j = $r.stdout | ConvertFrom-Json
            Assert-True (-not $j.passed)
            Assert-True ($j.findings -is [array]) 'findings 被攤平成物件了 —— extension 讀的是陣列'
            Assert-Equal "$d/notes.md" $j.findings[0].file
            Assert-True ($j.findings[0].categories -is [array]) '只有一個類別時 categories 被攤平成物件了 —— extension 讀的是陣列'
            Assert-True ($j.findings[0].categories[0].lines -is [array]) 'lines 被攤平了'
            $cat = $j.findings[0].categories[0]
            Assert-Equal 'email' $cat.type
            Assert-Equal 2 @($cat.lines)[0] '行號是 Problems 面板定位的唯一依據'
            Assert-True ($r.stdout -notmatch 'frank') '-Json 洩漏了命中的原始值'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '乾淨的檔回 passed，而且列出掃過哪些檔' {
        $d = "bdd-docs/hp-$(New-HpId)"
        New-HpFile "$d/notes.md" "沒有敏感資料`n"
        try {
            $r = Invoke-Script $DlpGate -Params @{ Path = "$d/notes.md"; Json = $true }
            Assert-Equal 0 $r.exit
            $j = $r.stdout | ConvertFrom-Json
            Assert-True $j.passed
            Assert-Equal "$d/notes.md" @($j.scanned)[0] '沒列出掃過的檔，呼叫端分不出「乾淨」與「沒掃」'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'guideline-gate / -Json 每一種結局都回同一個形狀' {

    It-Should '沒有規則檔 → status=no-rules' {
        $d = "hp-src-$(New-HpId)"
        New-HpFile "$d/q.sql" "SELECT 1`n"
        try {
            $r = Invoke-Script $GlGate -Params @{ Path = "$d/q.sql"; RulesFile = 'hp-no-such-rules.json'; Json = $true }
            Assert-Equal 0 $r.exit
            $j = $r.stdout | ConvertFrom-Json
            Assert-Equal 'no-rules' $j.status '沒有輸出狀態，呼叫端會把「沒有在守」顯示成「乾淨」'
            Assert-True $j.passed
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '掃過 → status=scanned，hits 帶檔與行，files 列出掃過的檔' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT 1`nSELECT Id FROM T WITH (NOLOCK)`n"
        try {
            $r = Invoke-Script $GlGate -Params @{ Path = "$d/q.sql"; RulesFile = $rules; Json = $true }
            Assert-Equal 2 $r.exit
            $j = $r.stdout | ConvertFrom-Json
            Assert-Equal 'scanned' $j.status
            Assert-Equal "$d/q.sql" @($j.files)[0]
            $h = @($j.hits)[0]
            Assert-Equal 'no-nolock' $h.rule
            Assert-Equal 2 $h.line
            Assert-Equal 'block' $h.severity
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'hook 編碼 / payload 與訊息一律 UTF-8' {

    It-Should '743 字、meta 完整的中文 handoff 在 Codex 形狀下通過，而且字數算對' {
        # 實測：stdin 被當成 cp950 解碼時，這一份被算成 1772 字、JSON 解析失敗、抓不到 mode／feature-id，
        # 於是 orchestrator **再也 spawn 不出任何子代理**。在 console 已經是 UTF-8 的機器上這條測試本來就會綠，
        # 所以下面另有一條靜態的守衛。
        $body = ('需求已定案：已出貨的訂單不可取消。' * 50).Substring(0, 700)
        $handoff = "## meta`n- feature-id: cancel-order`n- mode: analyze`n`n## summary`n$body"
        $r = Invoke-Script '.codex/scripts/handoff-lint.ps1' -Stdin (New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ message = $handoff }) -Params @{ Json = $true }
        Assert-Equal 0 $r.exit "合法的中文 handoff 被擋了；stdout: $($r.stdout)"
        $j = $r.stdout | ConvertFrom-Json
        Assert-Equal $handoff.Length $j.prompt_chars 'stdin 沒有照 UTF-8 解碼 —— 字數被算錯'
    }

    It-Should '阻斷理由裡的中文原樣到達（stderr 是 UTF-8）' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        try {
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/q.sql")) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit
            Assert-Match '禁止 NOLOCK' $r.stderr '模型拿到的阻斷理由是亂碼'
            Assert-True ($r.stderr -notmatch [char]0xFFFD) 'stderr 裡有 U+FFFD —— 不是 UTF-8'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '被程式呼叫的腳本都有同一段「標準 I/O」' {
        # 行為測試在 console 已是 UTF-8 的機器上抓不到回歸（舊寫法在那裡也會綠），所以這裡直接守段落本身：
        # 少了它，在 zh-TW 的 Windows 上每一次 spawn 都被擋、每一則中文訊息都是亂碼，而維護者的機器上一切正常。
        $want = $null
        foreach ($s in @('.codex/scripts/handoff-lint.ps1', $DlpGate, $GlGate, $Build, '.codex/scripts/agent-lint.ps1', '.codex/scripts/sdlc.ps1')) {
            $t = [IO.File]::ReadAllText((Join-Path (Get-Location) $s)) -replace "`r`n", "`n"
            $m = [regex]::Match($t, '(?s)\$Utf8NoBom = \[Text\.UTF8Encoding\]::new\(\$false\)\nif \(\[Console\]::IsOutputRedirected\).*?\n\}\n')
            Assert-True $m.Success "$s 沒有「標準 I/O」段落"
            if ($null -eq $want) { $want = $m.Value } else { Assert-Equal $want $m.Value "$s 的「標準 I/O」段落跟其他腳本不一樣" }
        }
    }
}
