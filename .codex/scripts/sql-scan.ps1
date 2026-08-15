# sql-scan.ps1
# 遺留 SQL 邏輯訊號偵測。用腳本掃完整個舊碼庫 —— 零 token。
#
# 下面兩份樣式清單**就是**這件事的規格，沒有第二份文件。原本它們寫在
# runbooks/sql-logic-extraction.md，那份 runbook 連同它引用的 db-introspection-scanner、
# project-scanner 與 bdd-docs/runs/ 在 v4.0.0 一起被移除 —— 樣式本身完整搬到這裡了。
# 要增修樣式改這裡，不要為此把那份 runbook 復活（它會把 v3 概念一起帶回來）。
#
# LLM 只讀本腳本輸出的訊號清單，判定 data-access vs business-rule（那才是 LLM 的工作）。
#
# DLP：絕不輸出完整 SQL。context 只留 1 行且遮蔽字串常值與數字。
#
# Exit: 0 = 完成（含無訊號）；1 = 錯誤。

[CmdletBinding()]
param(
    [string]$Root = '.',
    [string]$OutFile = 'bdd-docs/.cache/sql-signals.json',
    [int]$MaxSignals = 300,
    [switch]$NoWrite      # 只輸出到 stdout，不落檔（測試用）
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path
$excludeRe = '[\\/](bin|obj|node_modules|packages|\.git|\.vs|TestResults)[\\/]'

function ConvertTo-RelPath([string]$full) {
    ($full -replace [regex]::Escape($Root), '').TrimStart('\', '/') -replace '\\', '/'
}

# DLP 遮蔽：字串常值 → '***'，數字 → N，壓成單行且截斷
function Protect-Context([string]$line) {
    $s = $line -replace "'[^']*'", "'***'" -replace '"[^"]*"', '"***"' -replace '\b\d{3,}\b', 'N'
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120) + '…' }
    return $s
}

# ---- inline-code-sql 樣式：舊應用程式碼內嵌的 SQL ----
# 順序即優先序：一行只記一個訊號，**最具體的樣式必須排在最前面**，
# 否則通用的 string-concat-sql 會把 FromSqlRaw / StringBuilder 等更有資訊量的型別吃掉。
$inlinePatterns = @(
    @{ type='embedded-sp-call';  re='(?i)CommandType\s*\.\s*StoredProcedure' }
    @{ type='orm-raw-query';     re='(?i)\b(FromSqlRaw|FromSqlInterpolated|ExecuteSqlRaw|ExecuteSqlInterpolated|Database\.SqlQuery)\b' }
    @{ type='dynamic-sql';       re='(?i)\b(StringBuilder)\b[^\r\n]*\b(SELECT|WHERE|FROM)\b|\.Append(?:Line)?\s*\(\s*"[^"]*\b(WHERE|AND|OR|JOIN)\b' }
    @{ type='dapper-ado';        re='(?i)\b(Query<|QueryAsync<|QueryFirst|QuerySingle|ExecuteScalar|new\s+SqlCommand|\.CommandText\s*=)' }
    @{ type='string-concat-sql'; re='(?i)(?:"|\$")[^"]*\b(SELECT|INSERT|UPDATE|DELETE|WHERE|CASE\s+WHEN)\b' }
)

# ---- db-object 樣式：View／SP／Function／Trigger 定義裡的邏輯構件 ----
# 同樣最具體優先：dynamic-sql 與 cursor 是重構風險最高的訊號，
# 不可被通用的 join-filter（WHERE ... AND/OR）吃掉。
$dbObjectPatterns = @(
    @{ type='dynamic-sql';    re='(?i)\b(EXEC\s*\(|sp_executesql)\b' }
    @{ type='cursor';         re='(?i)\bDECLARE\s+\w+\s+CURSOR\b' }
    @{ type='case-when';      re='(?i)\bCASE\s+WHEN\b' }
    @{ type='temp-table-cte'; re='(?i)(#\w+|\@\w+\s+TABLE\b|\bWITH\s+\w+\s+AS\s*\()' }
    @{ type='control-flow';   re='(?i)^\s*(IF|WHILE)\b|\bBEGIN\s+TRAN' }
    @{ type='join-filter';    re='(?i)\b(INNER|LEFT|RIGHT|FULL)\s+JOIN\b|\bWHERE\b[^\r\n]*\b(AND|OR)\b' }
)

function Get-Signals($files, $patterns, [string]$sourceType) {
    $out = @()
    foreach ($f in $files) {
        # `@()` 不可省：單行檔的 Get-Content 回字串而非陣列，`$lines[$i]` 會取到單一**字元**，
        # 於是整個檔靜默地掃不出任何訊號。壓成一行的 View／SP 定義正好是最常見的那種。
        $lines = @(Get-Content $f.FullName -ErrorAction SilentlyContinue)
        if (-not $lines) { continue }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            foreach ($p in $patterns) {
                if ($lines[$i] -match $p.re) {
                    $out += [pscustomobject]@{
                        'source-type'   = $sourceType
                        file            = ConvertTo-RelPath $f.FullName
                        line            = $i + 1
                        'construct-type'= $p.type
                        context         = Protect-Context $lines[$i]
                    }
                    break   # 一行只記一個訊號，避免重複膨脹
                }
            }
        }
    }
    return $out
}

# ---- Java inline SQL 樣式（最具體優先，同上）----
$javaPatterns = @(
    @{ type='stored-proc-call'; re='(?i)\b(CallableStatement|prepareCall)\b' }
    @{ type='orm-raw-query';    re='(?i)@(Query|NamedQuery|NativeQuery)\b|\b(createNativeQuery|createQuery)\s*\(' }
    @{ type='mybatis-mapper';   re='(?i)@(Select|Insert|Update|Delete)\s*\(|<(select|insert|update|delete)\s+id=' }
    @{ type='jdbc-template';    re='(?i)\b(jdbcTemplate|namedParameterJdbcTemplate)\s*\.\s*(query|update|execute|batchUpdate)' }
    @{ type='prepared-stmt';    re='(?i)\b(prepareStatement|createStatement|executeQuery|executeUpdate)\s*\(' }
    @{ type='dynamic-sql';      re='(?i)\b(StringBuilder|StringBuffer)\b[^\r\n]*\b(SELECT|WHERE|FROM)\b|\.append\s*\(\s*"[^"]*\b(WHERE|AND|OR|JOIN)\b' }
    @{ type='string-concat-sql';re='(?i)"[^"]*\b(SELECT|INSERT|UPDATE|DELETE|WHERE|CASE\s+WHEN)\b' }
)

$csFiles = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.cs' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch $excludeRe })
$javaSrc = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.java' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch $excludeRe })
$xmlMappers = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.xml' -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch $excludeRe -and $_.Name -ne 'pom.xml' })
$sqlFiles = @(Get-ChildItem -Path $Root -Recurse -File -Filter '*.sql' -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch $excludeRe })

$inlineSignals   = @(Get-Signals $csFiles    $inlinePatterns   'inline-code-sql') +
                   @(Get-Signals $javaSrc    $javaPatterns     'inline-code-sql') +
                   @(Get-Signals $xmlMappers $javaPatterns     'inline-code-sql')
$dbObjectSignals = Get-Signals $sqlFiles $dbObjectPatterns 'db-object'

# DB 來源判定（使用者尚未確定來源，執行時偵測）
$dbObjectSource = if ($sqlFiles.Count -gt 0) { 'ddl-files-found' } else { 'none-found' }

$all = @($inlineSignals) + @($dbObjectSignals)
$truncated = $all.Count -gt $MaxSignals
$emit = @($all | Select-Object -First $MaxSignals)

$result = [pscustomobject]@{
    'scanned-at'        = (Get-Date).ToUniversalTime().ToString('o')
    'db-object-source'  = $dbObjectSource
    'ddl-file-count'    = $sqlFiles.Count
    'cs-file-count'     = $csFiles.Count
    'signal-count'      = $all.Count
    truncated           = $truncated
    # 這個欄位會直接進讀者的 context，所以它必須指向現在真的存在的 agent 與 mode。
    # v4.0.0 之前寫的是「analyst 以 sql-logic-extraction mode」—— 那個 agent 和那個 mode
    # 都已經不存在，照著做的人會去找一個叫不出來的東西。
    'next-step'         = if ($truncated) { "訊號超過 $MaxSignals；以 -MaxSignals 提高上限或分批處置" }
                          elseif ($dbObjectSource -eq 'none-found' -and $inlineSignals.Count -eq 0) { '沒有邏輯訊號，這次不需要 SQL 逆推' }
                          else { 'sa-analyst（mode: analyze）逐一判定 data-access vs business-rule' }
    'by-construct'      = ($emit | Group-Object 'construct-type' |
                            ForEach-Object { [pscustomobject]@{ type=$_.Name; count=$_.Count } })
    signals             = $emit
}

if (-not $NoWrite) {
    $dir = Split-Path $OutFile -Parent
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $result | ConvertTo-Json -Depth 6 | Set-Content $OutFile -Encoding UTF8
}

# stdout 只給摘要，訊號全文在檔案裡（避免灌爆 context）
[pscustomobject]@{
    status = 'completed'
    out_file = if ($NoWrite) { $null } else { $OutFile }
    'db-object-source' = $dbObjectSource
    signal_count = $all.Count
    truncated = $truncated
    by_construct = $result.'by-construct'
    next_step = $result.'next-step'
} | ConvertTo-Json -Depth 5 -Compress
exit 0
