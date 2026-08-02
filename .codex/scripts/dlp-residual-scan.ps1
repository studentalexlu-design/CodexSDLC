<#
.SYNOPSIS
    DLP 殘留掃描（deterministic residual scan）— P0-2。

.DESCRIPTION
    在 orchestrator 委派子代理前，以確定性 regex 掃描「脫敏後即將送出的內容」，
    偵測已知敏感模式殘留。作為 LLM 脫敏之上的確定性防護層。

    安全契約：
    - 絕不輸出命中的原始值；只回類別、計數、行號參照。
    - 不寫入任何檔案；結果由呼叫端決定怎麼處置。
    - mapping table 永不經過此腳本。

.PARAMETER Path
    要掃描的檔案路徑。與 -InputText 擇一。

.PARAMETER InputText
    要掃描的文字（字串）。與 -Path 擇一；未提供時從 stdin 讀取。

.PARAMETER Categories
    可選：只掃描指定類別（逗號分隔），例如 "ipv4,email,connstring"。
    未指定時掃描全部。

.OUTPUTS
    JSON: { residual_count, passed, categories:[{type,count}], line_refs:[int], scanned_chars }

.NOTES
    PowerShell 5.1 相容，零外部依賴。退出碼：殘留=0 -> 0；殘留>0 -> 2；錯誤 -> 1。
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$InputText,
    [string]$Categories
)

$ErrorActionPreference = 'Stop'

# --- 偵測模式（集中管理，可依專案調整）---------------------------------------
# 每個模式只用於「偵測是否殘留」，不擷取或輸出原始命中值。
$Patterns = [ordered]@{
    'ipv4'       = '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b'
    'email'      = '\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b'
    'tw_id'      = '\b[A-Z][12]\d{8}\b'
    'connstring' = '(?i)(server|data source|initial catalog|user id|uid|password|pwd)\s*='
    'secret'     = '(?i)(api[_-]?key|bearer\s+[A-Za-z0-9._\-]+|secret|access[_-]?token|token)\s*[:=]\s*\S+'
    'internal_host' = '(?i)\b(srv|db|prod|stg|uat|internal)[-_]?\w*\.(local|corp|internal|lan)\b'
}

# 誤報 allowlist（僅用於降低雜訊，仍不記錄原始值）。
$AllowList = @(
    '0.0.0.0',
    '127.0.0.1',
    '255.255.255.255'
)

function Get-InputContent {
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Path not found: $Path"
        }
        return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path))
    }
    # 不可用 $PSBoundParameters 判斷 —— 在函式內它指的是**該函式自己**的繫結參數
    # （Get-InputContent 沒有參數，所以永遠是空的），於是 -InputText 這條路徑
    # 從來不會成立，一律落到 stdin。呼叫端以 -InputText 傳入時 stdin 是空的，
    # 掃描結果會是 scanned_chars=0 / passed=true —— 一次**假的全綠 DLP 放行**。
    if (-not [string]::IsNullOrEmpty($InputText)) {
        return $InputText
    }
    return [Console]::In.ReadToEnd()
}

try {
    $content = Get-InputContent
    if ($null -eq $content) { $content = '' }

    $activeTypes = $Patterns.Keys
    if ($Categories) {
        $requested = $Categories.Split(',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
        $activeTypes = $Patterns.Keys | Where-Object { $requested -contains $_ }
    }

    $lines = $content -split "`n"
    $categoryResults = @()
    $lineRefSet = New-Object System.Collections.Generic.HashSet[int]
    $totalResidual = 0

    foreach ($type in $activeTypes) {
        $regex = [regex]$Patterns[$type]
        $count = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $matches = $regex.Matches($lines[$i])
            foreach ($m in $matches) {
                if ($AllowList -contains $m.Value) { continue }
                $count++
                [void]$lineRefSet.Add($i + 1)
            }
        }
        if ($count -gt 0) {
            $categoryResults += [ordered]@{ type = $type; count = $count }
            $totalResidual += $count
        }
    }

    $lineRefs = @($lineRefSet) | Sort-Object
    $result = [ordered]@{
        residual_count = $totalResidual
        passed         = ($totalResidual -eq 0)
        categories     = $categoryResults
        line_refs      = $lineRefs
        scanned_chars  = $content.Length
    }

    # 只輸出結構化摘要，絕不含原始命中值。
    $result | ConvertTo-Json -Depth 4 -Compress

    if ($totalResidual -gt 0) { exit 2 } else { exit 0 }
}
catch {
    ([ordered]@{ error = $_.Exception.Message; passed = $false } | ConvertTo-Json -Compress)
    exit 1
}
