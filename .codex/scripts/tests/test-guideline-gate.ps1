# test-guideline-gate.ps1
# 團隊規範裡「有機械 oracle」的那一半。這支腳本是唯一擋得住禁用語法的東西 ——
# prompt 裡的同一條規則是榮譽制，所以它靜默失效的代價特別高：團隊以為有人在守，而沒有人在守。
#
# 因此下面每一條都對著一種**靜默**的失效，而不是對著功能：
#   排除清單漏掉 bdd-docs/ → 每次 SQL 逆推都無條件紅燈 → gate 被整個關掉
#   標記檔路徑漂移         → 關不掉，也沒有人發現關不掉
#   規則檔壞掉時安靜通過   → 規範沒生效，而畫面上一切正常
#   把命中的原始行印出來   → 掃描器自己變成外洩管道

$Gate = '.codex/scripts/guideline-gate.ps1'

# 標準測試規則：涵蓋 block、warn，以及「severity 省略 → 預設 warn」。
$StdRules = @'
{ "rules": [
  { "id": "no-nolock", "applies-to": ["**/*.sql"], "pattern": "(?i)NOLOCK",
    "severity": "block", "message": "禁止 NOLOCK", "fix": "改用快照隔離" },
  { "id": "no-star", "applies-to": ["**/*.sql"], "pattern": "(?i)SELECT\\s+\\*",
    "severity": "warn", "message": "不要 SELECT *", "fix": "列出欄位" },
  { "id": "sev-omitted", "applies-to": ["**/*.txt"], "pattern": "BADWORD",
    "message": "省略 severity 時必須預設為 warn" }
] }
'@

function New-GlFile([string]$relPath, [string]$content) {
    $dir = Split-Path $relPath -Parent
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content $relPath -Value $content -Encoding UTF8
}

function New-GlRules([string]$json) {
    $p = 'gl-rules-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json'
    Set-Content $p -Value $json -Encoding UTF8
    return $p
}

function New-GlDir { 'gl-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }

Describe-Suite 'guideline-gate / 掃描與阻斷' {

    It-Should '沒有 rules.json 時完全靜默通過（沒有規範的團隊零成本）' {
        $d = New-GlDir
        try {
            New-GlFile "$d/q.sql" 'SELECT * FROM T WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = 'gl-nonexistent-rules.json' }
            Assert-Equal 0 $r.exit
            Assert-Equal '' $r.stderr.Trim() '沒有規則檔時不該輸出任何東西'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'block 規則命中時阻斷，訊息帶 rule id 與修法' {
        $d = New-GlDir; $rules = New-GlRules $StdRules
        try {
            New-GlFile "$d/q.sql" 'SELECT Id FROM T WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 2 $r.exit
            Assert-Match 'no-nolock' $r.stderr
            Assert-Match "$d/q\.sql:1" $r.stderr 'agent 要靠檔:行才改得動'
            Assert-Match '改用快照隔離' $r.stderr '沒有修法的訊息只是在罵人'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'warn 規則單獨命中時不阻斷，但要講出來' {
        $d = New-GlDir; $rules = New-GlRules $StdRules
        try {
            New-GlFile "$d/q.sql" 'SELECT * FROM T'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 0 $r.exit
            Assert-Match 'no-star' $r.stderr
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'severity 省略時預設 warn（block 必須明確 opt-in）' {
        # 一條寫錯的 regex 若預設阻斷，會卡死整條流程，而使用者唯一的修法是去改工具本身。
        $d = New-GlDir; $rules = New-GlRules $StdRules
        try {
            New-GlFile "$d/note.txt" 'this line has BADWORD in it'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/note.txt"; RulesFile = $rules }
            Assert-Equal 0 $r.exit '省略 severity 卻阻斷了 —— 預設值錯邊'
            Assert-Match 'sev-omitted' $r.stderr
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'applies-to 不符的檔不掃' {
        $d = New-GlDir; $rules = New-GlRules $StdRules
        try {
            New-GlFile "$d/Repo.cs" 'var sql = "SELECT 1 WITH (NOLOCK)";'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/Repo.cs"; RulesFile = $rules }
            Assert-Equal 0 $r.exit 'glob 只寫了 **/*.sql，卻掃到了 .cs'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '**bdd-docs/ 一律不掃**（逆推回來的舊 SP 不是新違規）' {
        # 這條漏掉的症狀最惡劣：legacy-schema 底下的舊定義本來就滿是 NOLOCK 與 cursor，
        # 於是每次 SQL 逆推都無條件紅燈，而唯一「有效」的處置是把整個 gate 關掉。
        $d = 'bdd-docs/artifacts/legacy-schema'
        $rules = New-GlRules $StdRules
        try {
            New-GlFile "$d/sp_old.sql" 'SELECT * FROM Orders WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/sp_old.sql"; RulesFile = $rules }
            Assert-Equal 0 $r.exit "bdd-docs/ 被掃到了；stderr: $($r.stderr)"
        } finally {
            Remove-Item 'bdd-docs/artifacts' -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $rules -Force -ErrorAction SilentlyContinue
        }
    }

    It-Should 'stdin payload 的路徑掃得到，單引號也算（shell 寫入慣用單引號）' {
        $d = New-GlDir; $rules = New-GlRules $StdRules
        try {
            New-GlFile "$d/q.sql" 'SELECT Id FROM T WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Stdin "{""command"":""cat > '$d/q.sql'""}" -Params @{ RulesFile = $rules }
            Assert-Equal 2 $r.exit '單引號路徑漏掃，經 shell 寫入的檔就完全躲過本 gate'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '**絕不輸出命中的原始行**（安全契約）' {
        $d = New-GlDir; $rules = New-GlRules $StdRules
        try {
            New-GlFile "$d/q.sql" "SELECT Id FROM T WITH (NOLOCK) -- SEKRETVALUE9f"
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 2 $r.exit
            Assert-True ($r.stderr -notmatch 'SEKRETVALUE9f') 'gate 把命中的原始行印出來了 —— 它自己變成外洩管道'
            Assert-True ($r.stdout -notmatch 'SEKRETVALUE9f') '同上（stdout）'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'guideline-gate / 短路標記' {

    It-Should 'guidelines/.gate-disabled 讓整個專案短路' {
        # 用**預設**的標記路徑，不是自訂路徑 —— 這條守的正是路徑漂移：
        # 標記檔改了位置而腳本沒跟上時，症狀是「關不掉，也沒有人發現關不掉」。
        $d = New-GlDir; $rules = New-GlRules $StdRules
        $marker = 'guidelines/.gate-disabled'
        $markerPreexisting = Test-Path $marker
        try {
            New-GlFile "$d/q.sql" 'SELECT Id FROM T WITH (NOLOCK)'
            if (-not $markerPreexisting) {
                New-Item -ItemType Directory -Path 'guidelines' -Force | Out-Null
                Set-Content $marker -Value 'test opt-out'
            }
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 0 $r.exit "有 .gate-disabled 時不該阻斷；stderr: $($r.stderr)"
        } finally {
            Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $markerPreexisting) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should '沒有標記檔時同樣的內容會被阻斷（證明上一條真的是標記在起作用）' {
        $d = New-GlDir; $rules = New-GlRules $StdRules
        try {
            Assert-True (-not (Test-Path 'guidelines/.gate-disabled')) '前提：標記檔必須不存在'
            New-GlFile "$d/q.sql" 'SELECT Id FROM T WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 2 $r.exit
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'guideline-gate / 規則檔損壞' {

    It-Should '壞掉的 regex 不阻斷，但**每次都喊**（失效必須是可見的）' {
        $d = New-GlDir
        $rules = New-GlRules '{ "rules": [ { "id": "broken", "pattern": "(unclosed" } ] }'
        try {
            New-GlFile "$d/q.sql" 'SELECT Id FROM T WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 0 $r.exit '規則檔壞掉時阻斷，會讓使用者卡在一個他改不到的地方'
            Assert-Match '規則載入失敗' $r.stderr '安靜地略過等於「規範沒生效，而畫面上一切正常」'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '一條規則壞掉不影響其餘規則' {
        $d = New-GlDir
        $rules = New-GlRules @'
{ "rules": [
  { "id": "broken", "pattern": "(unclosed" },
  { "id": "no-nolock", "applies-to": ["**/*.sql"], "pattern": "(?i)NOLOCK", "severity": "block", "message": "m" }
] }
'@
        try {
            New-GlFile "$d/q.sql" 'SELECT Id FROM T WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 2 $r.exit '一條寫壞就讓另外 199 條跟著失效，等於整份規範靠最爛的一條決定'
            Assert-Match 'no-nolock' $r.stderr
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'JSON 整個壞掉時也不阻斷，但要喊' {
        $d = New-GlDir; $rules = New-GlRules '{ this is not json'
        try {
            New-GlFile "$d/q.sql" 'WITH (NOLOCK)'
            $r = Invoke-Script $Gate -Params @{ Path = "$d/q.sql"; RulesFile = $rules }
            Assert-Equal 0 $r.exit
            Assert-Match '規則載入失敗' $r.stderr
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'guideline-gate / -Validate' {

    It-Should '本 repo 附的範例規則必須通過' {
        $r = Invoke-Script $Gate -Params @{ Validate = $true; Json = $true }
        Assert-Equal 0 $r.exit "guidelines/rules.json 自己都驗不過；stderr: $($r.stderr)"
        $j = $r.stdout | ConvertFrom-Json
        Assert-True $j.passed
        Assert-True ($j.rule_count -gt 0)
    }

    It-Should '壞掉的 regex 在 -Validate 就要紅（不是等到半夜實作到一半才炸）' {
        $rules = New-GlRules '{ "rules": [ { "id": "broken", "pattern": "(unclosed" } ] }'
        try {
            $r = Invoke-Script $Gate -Params @{ Validate = $true; RulesFile = $rules }
            Assert-Equal 2 $r.exit
            Assert-Match 'broken' $r.stderr
        } finally { Remove-Item $rules -Force -ErrorAction SilentlyContinue }
    }

    It-Should '不合法的 severity 在 -Validate 就要紅' {
        $rules = New-GlRules '{ "rules": [ { "id": "oops", "pattern": "x", "severity": "error" } ] }'
        try {
            $r = Invoke-Script $Gate -Params @{ Validate = $true; RulesFile = $rules }
            Assert-Equal 2 $r.exit
            Assert-Match 'severity' $r.stderr
        } finally { Remove-Item $rules -Force -ErrorAction SilentlyContinue }
    }
}
