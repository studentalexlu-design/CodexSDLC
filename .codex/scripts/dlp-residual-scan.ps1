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
    JSON: { residual_count, passed, categories:[{type,count,lines:[int]}], line_refs:[int], scanned_chars }
    每個類別的 `lines` 是給編輯器的 Problems 面板用的（哪一行是哪一類）—— 仍然只有行號，沒有值。

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
    return Read-StdinUtf8
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
        $typeLines = New-Object System.Collections.Generic.SortedSet[int]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $matches = $regex.Matches($lines[$i])
            foreach ($m in $matches) {
                if ($AllowList -contains $m.Value) { continue }
                $count++
                [void]$lineRefSet.Add($i + 1)
                [void]$typeLines.Add($i + 1)
            }
        }
        if ($count -gt 0) {
            $categoryResults += [ordered]@{ type = $type; count = $count; lines = @($typeLines) }
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
