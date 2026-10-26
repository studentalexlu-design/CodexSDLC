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

# 把一個檔變成「很久以前寫的」：修改與建立時間都退一小時。shell 指令裡被提到、但這次沒寫的舊檔就長這樣。
function Set-HpOld([string]$rel) {
    $f = Join-Path (Get-Location) $rel
    $old = [DateTime]::UtcNow.AddHours(-1)
    [IO.File]::SetLastWriteTimeUtc($f, $old)
    [IO.File]::SetCreationTimeUtc($f, $old)
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

    # 實測（speedup-plan 第 2 項）：專案放 repo 附的 guidelines/rules.json，舊檔含 WITH (NOLOCK)，
    # `Get-Content -Path 'legacy/report.sql'` 與 `rg -n "Status" "legacy/report.sql"` 都被 exit 2 擋下：
    # 「違反專案規範 —— 現在就改掉」。sa-analyst／reviewer 不該改程式，implementer 不該改 spec 範圍外的檔，
    # 而且 PostToolUse 的阻斷訊息會**取代**工具輸出 —— 它連那個檔的內容都看不到。
    foreach ($case in @(
        @{ label = 'Get-Content -Path ''…'''; cmd = { param($p) "Get-Content -Path '$p'" } }
        @{ label = 'rg -n "Status" "…"';     cmd = { param($p) "rg -n `"Status`" `"$p`"" } }
    )) {
        It-Should "guideline-gate：Bash 只是讀一個不合規範的舊檔（$($case.label)）→ 不擋" {
            $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
            New-HpFile "$d/report.sql" "SELECT o.Id FROM Orders o WITH (NOLOCK) WHERE o.Status = 2`n"
            Set-HpOld "$d/report.sql"
            try {
                $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Tool 'Bash' -Command (& $case.cmd "$d/report.sql")) -Params @{ RulesFile = $rules }
                Assert-Equal 0 $r.exit "讀舊檔被當成寫檔擋下了；stderr: $($r.stderr)"
            } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should 'guideline-gate：Bash 剛寫出同樣內容的檔 → 照樣擋（篩掉的只有舊檔）' {
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/report.sql" "SELECT o.Id FROM Orders o WITH (NOLOCK) WHERE o.Status = 2`n"
        try {
            $cmd = "Set-Content -Path '$d/report.sql' -Value `$sql"
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Tool 'Bash' -Command $cmd) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit '剛寫的檔沒被掃'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate：Copy-Item 保留了修改時間，但建立時間是新的 → 照樣擋' {
        # Windows 的 Copy-Item 會沿用來源檔的修改時間；只看修改時間的話，複製出來的新檔會被當成舊檔放過。
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/copy.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        [IO.File]::SetLastWriteTimeUtc((Join-Path (Get-Location) "$d/copy.sql"), [DateTime]::UtcNow.AddHours(-1))
        try {
            $cmd = "Copy-Item 'legacy/q.sql' '$d/copy.sql'"
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Tool 'Bash' -Command $cmd) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit '複製出來的新檔被當成舊檔放過了'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate：apply_patch 標頭的檔不篩（就算時間戳是舊的）' {
        # patch 標頭就是這次寫的檔。新鮮度只用來篩 shell 指令裡「被提到」的路徑。
        $d = "hp-src-$(New-HpId)"; $rules = New-HpRules
        New-HpFile "$d/q.sql" "SELECT Id FROM T WITH (NOLOCK)`n"
        Set-HpOld "$d/q.sql"
        try {
            $r = Invoke-Script $GlGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$d/q.sql")) -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit 'patch 寫的檔被時間戳篩掉了'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'dlp-gate：Bash 讀 bdd-docs/ 裡的舊檔（引號與裸路徑）→ 不掃' {
        # 每讀一次 spec.md 就掃一次（而且以前要再起一個 pwsh，約 3 秒）—— 它早在寫的那一刻就掃過了。
        $d = "bdd-docs/hp-$(New-HpId)"
        New-HpFile "$d/notes.md" "聯絡人 grace@contoso.com`n"
        Set-HpOld "$d/notes.md"
        try {
            foreach ($cmd in @("Get-Content -Path '$d/notes.md'", "cat $d/notes.md")) {
                $r = Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Tool 'Bash' -Command $cmd)
                Assert-Equal 0 $r.exit "「$cmd」把讀當成寫；stderr: $($r.stderr)"
            }
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
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
        foreach ($s in @('.codex/scripts/handoff-lint.ps1', $DlpGate, $GlGate, $Build, '.codex/scripts/agent-lint.ps1', '.codex/scripts/sdlc.ps1', '.codex/scripts/tests/run-tests.ps1',
                               '.codex/scripts/repo-index.ps1', '.codex/scripts/sql-scan.ps1', '.codex/scripts/impact-scope.ps1', '.codex/scripts/dlp-residual-scan.ps1', '.codex/scripts/pack.ps1')) {
            $t = [IO.File]::ReadAllText((Join-Path (Get-Location) $s)) -replace "`r`n", "`n"
            $m = [regex]::Match($t, '(?s)\$Utf8NoBom = \[Text\.UTF8Encoding\]::new\(\$false\)\nif \(\[Console\]::IsOutputRedirected\).*?\n\}\n')
            Assert-True $m.Success "$s 沒有「標準 I/O」段落"
            if ($null -eq $want) { $want = $m.Value } else { Assert-Equal $want $m.Value "$s 的「標準 I/O」段落跟其他腳本不一樣" }
        }
    }
}

Describe-Suite 'hook 心跳 / 每支 hook 被叫的時候都要留下痕跡（doctor 靠它看出 hooks 沒在跑）' {

    # Codex 沒信任 hooks、或叫不起 pwsh 時，這四支一次都不會跑，而且沒有提示。doctor 唯一看得到的線索是
    # 「agent 寫了產出，心跳卻沒跟著變新」—— 所以任何一支被叫的時候都要寫，手動跑的時候都不能寫（否則手動跑一次就把證據蓋掉）。
    $HbDir = 'bdd-docs/.cache/hooks'

    function Get-HbTime([string]$name) {
        $f = Join-Path (Get-Location) "$HbDir/$name.last"
        if (-not (Test-Path $f)) { return $null }
        return [IO.File]::GetLastWriteTimeUtc($f)
    }

    It-Should '四支 hook 被 Codex 叫的時候都寫心跳' {
        $d = "bdd-docs/hb-$(New-HpId)"
        New-HpFile "$d/notes.md" "沒有敏感資料`n"
        $start = [DateTime]::UtcNow.AddSeconds(-2)
        try {
            Remove-Item $HbDir -Recurse -Force -ErrorAction SilentlyContinue
            $post = New-CodexHookPayload -Command (New-CodexPatch -Add "$d/notes.md")
            foreach ($s in @($DlpGate, $GlGate, $Build)) { Invoke-Script $s -Stdin $post | Out-Null }
            Invoke-Script '.codex/scripts/handoff-lint.ps1' -Stdin (New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ message = 'x' }) | Out-Null
            foreach ($n in @('dlp-gate', 'guideline-gate', 'build-check', 'handoff-lint')) {
                $t = Get-HbTime $n
                Assert-True ($null -ne $t -and $t -ge $start) "$n 被叫了卻沒寫心跳 —— doctor 會把「有在跑」誤判成「沒在跑」"
            }
        } finally { Remove-Item $d, $HbDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '手動跑（-Path、沒有 hook_event_name）不寫心跳' {
        $d = "bdd-docs/hb-$(New-HpId)"
        New-HpFile "$d/notes.md" "沒有敏感資料`n"
        try {
            Remove-Item $HbDir -Recurse -Force -ErrorAction SilentlyContinue
            Invoke-Script $DlpGate -Params @{ Path = "$d/notes.md" } | Out-Null
            Invoke-Script $GlGate -Params @{ Path = "$d/notes.md"; Json = $true } | Out-Null
            Invoke-Script $DlpGate -Stdin (@{ tool_input = @{ command = (New-CodexPatch -Add "$d/notes.md") } } | ConvertTo-Json -Depth 4 -Compress) | Out-Null
            Assert-True (-not (Test-Path $HbDir) -or -not @(Get-ChildItem $HbDir -File).Count) '手動跑也寫了心跳 —— 維護者手動掃一次，就把「hooks 沒在跑」的證據蓋掉了'
        } finally { Remove-Item $d, $HbDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'Write-HookHeartbeat 在四支腳本裡逐字相同' {
        $bodies = @{}
        foreach ($s in @($DlpGate, $GlGate, $Build, '.codex/scripts/handoff-lint.ps1')) {
            $m = [regex]::Match([IO.File]::ReadAllText((Join-Path (Get-Location) $s)), '(?ms)^function Write-HookHeartbeat.*?^\}')
            Assert-True $m.Success "$s 找不到 Write-HookHeartbeat"
            $bodies[$s] = $m.Value -replace "`r`n", "`n"
        }
        $want = $bodies[$DlpGate]
        foreach ($s in @($bodies.Keys)) { Assert-True ($bodies[$s] -eq $want) "$s 的 Write-HookHeartbeat 跟 dlp-gate 的不一樣 —— 心跳寫的位置一分岔，doctor 就讀不到那一支" }
    }
}

Describe-Suite 'review 快照 / 每一輪審核都留一份（review.md 每輪整份覆寫，PASS 之後前幾輪的必修就不見了）' {

    function Get-Snaps([string]$d) { return @(Get-ChildItem (Join-Path (Get-Location) "$d/reviews") -Filter '*.md' -File -ErrorAction SilentlyContinue) }

    It-Should '寫了乾淨的 review.md → 留一份快照；內容沒變不重留；改了再留一份' {
        $d = "bdd-docs/rv-$(New-HpId)"
        New-HpFile "$d/review.md" "VERDICT: FAIL`n`n## 發現`n1. [必修] src/A.cs:10 —— 斷言是空的`n"
        try {
            $payload = New-CodexHookPayload -Command (New-CodexPatch -Add "$d/review.md")
            Assert-Equal 0 (Invoke-Script $DlpGate -Stdin $payload).exit
            $s = Get-Snaps $d
            Assert-Equal 1 $s.Count '第一輪的 review.md 沒有留快照 —— PASS 之後這一輪的必修就再也看不到'
            Assert-Equal ([IO.File]::ReadAllText((Join-Path (Get-Location) "$d/review.md"))) ([IO.File]::ReadAllText($s[0].FullName)) '快照的內容跟 review.md 不一樣'
            Invoke-Script $DlpGate -Stdin $payload | Out-Null
            Assert-Equal 1 (Get-Snaps $d).Count '同一份內容留了兩份 —— 一輪審核常是好幾個 patch，learn 會把同一輪算成好幾輪'
            New-HpFile "$d/review.md" "VERDICT: PASS`n`n## 發現`n1. [建議] src/A.cs:12 —— 命名`n`n## 上一輪必修的交代`n- src/A.cs:10 —— 斷言是空的：已修 —— CancelOrderTests.Rejects 斷言了狀態`n"
            Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Update "$d/review.md")) | Out-Null
            Assert-Equal 2 (Get-Snaps $d).Count '第二輪覆寫之後沒有再留一份'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '上一份的 [必修] 在新的 review.md 裡沒交代 → 阻斷、不留快照；交代了或照樣列成必修 → 通過' {
        # PASS 就是從這裡漏出去的：上一輪的必修這一輪沒再提，分不出是修好了還是忘了看。
        $d = "bdd-docs/rv-$(New-HpId)"
        $round1 = "VERDICT: FAIL`n`n## 發現`n1. [必修] src/A.cs:10 —— 斷言是空的`n   會怎麼壞：x`n2. [必修] src/B.cs:5 —— 沒擋已出貨`n"
        New-HpFile "$d/review.md" $round1
        try {
            Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/review.md")) | Out-Null
            $upd = New-CodexHookPayload -Command (New-CodexPatch -Update "$d/review.md")

            New-HpFile "$d/review.md" "VERDICT: PASS`n`n## 發現`n1. [建議] src/A.cs:12 —— 命名`n`n## 上一輪必修的交代`n- src/A.cs:10 —— 斷言是空的：已修 —— A 測試`n"
            $r = Invoke-Script $DlpGate -Stdin $upd
            Assert-Equal 2 $r.exit '上一輪的必修 src/B.cs 無聲消失，PASS 照樣過了'
            Assert-Match 'src/B\.cs:5' $r.stderr '沒說是哪一項沒交代'
            Assert-Equal 1 (Get-Snaps $d).Count '沒交代的那一份被留成快照 —— 下一次寫入就拿它當上一份，B 從此脫鉤'

            New-HpFile "$d/review.md" "VERDICT: PASS`n`n## 上一輪必修的交代`n- src/A.cs:10 —— 斷言是空的：已修 —— A 測試`n- src/B.cs:5 —— 沒擋已出貨：接受不修 ——`n"
            Assert-Equal 2 (Invoke-Script $DlpGate -Stdin $upd).exit '交代沒寫證據或理由也算數了'

            New-HpFile "$d/review.md" "VERDICT: FAIL`n`n## 發現`n1. [必修] src/B.cs:9 —— 還是沒擋已出貨`n`n## 上一輪必修的交代`n- src/A.cs:10 —— 斷言是空的：已修 —— A 測試`n"
            $r = Invoke-Script $DlpGate -Stdin $upd
            Assert-Equal 0 $r.exit "同一個檔照樣列成必修（行號變了）應該算有交代；stderr: $($r.stderr)"
            Assert-Equal 2 (Get-Snaps $d).Count
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '掃出殘留的 review.md 不留快照（那一份照 runbook 要刪掉）' {
        $d = "bdd-docs/rv-$(New-HpId)"
        New-HpFile "$d/review.md" "VERDICT: FAIL`n1. [必修] 客戶 carol@contoso.com 的資料 —— 外洩`n"
        try {
            Assert-Equal 2 (Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/review.md"))).exit
            Assert-Equal 0 (Get-Snaps $d).Count '敏感資料被快照保存下來了 —— 刪掉 review.md 也刪不掉它'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '別的檔、手動 -Path 掃都不留快照' {
        $d = "bdd-docs/rv-$(New-HpId)"
        New-HpFile "$d/review.md" "VERDICT: PASS`n"
        New-HpFile "$d/spec.md" "# spec`n"
        try {
            Invoke-Script $DlpGate -Params @{ Path = "$d/review.md" } | Out-Null
            Invoke-Script $DlpGate -Stdin (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/spec.md")) | Out-Null
            Assert-Equal 0 (Get-Snaps $d).Count '不是 hook 寫 review.md 的那一刻也留了快照'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
