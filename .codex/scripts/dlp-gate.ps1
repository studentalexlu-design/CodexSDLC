# dlp-gate.ps1
# PostToolUse 縱深防禦：對寫入 bdd-docs/** 的 artifact 執行殘留掃描。
#
# 短路條件：存在 `bdd-docs/.dlp-disabled` 時整條掃描鏈路跳過。
# 這是**專案層級**的宣告（v4.0.0 起；v3 是 run 層級，而 v4 沒有 run）。
# 中途發現敏感資料 → 刪掉該檔並重跑全量掃描，見 runbooks/dlp-masking.md。
#
# Exit: 0 = 通過或已短路；2 = 偵測到殘留（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string]$ScanScript = '.codex/scripts/dlp-residual-scan.ps1',
    [string]$DisableMarker = 'bdd-docs/.dlp-disabled'
)

if (-not $Payload) { $Payload = [Console]::In.ReadToEnd() }
if (-not $Payload) { exit 0 }
if (-not (Test-Path $ScanScript)) { exit 0 }

# 標記檔關掉時**每次都喊**（不阻斷，exit 仍是 0）。標記檔通常是某一次為了解卡建的，
# 建完就留在那裡 —— 之後每一個需求都在沒有殘留掃描的情況下寫檔，而畫面上一切正常。
# 靜默地「防護其實沒在生效」比擋錯更糟，這一行是唯一會提醒的東西。
if (Test-Path $DisableMarker) {
    [Console]::Error.WriteLine("[Hook][DLP] 已被 $DisableMarker 關閉 —— 這次沒有掃任何檔。要恢復就刪掉那個標記檔。")
    exit 0
}

# 引號類別含單引號：PowerShell heredoc／shell 寫入路徑慣用單引號，
# 只認雙引號會讓經 shell 寫入的 artifact 完全躲過本 gate。
$targets = [regex]::Matches($Payload, '["''](bdd-docs[^"''\r\n]*)["'']') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique

foreach ($p in $targets) {
    if (-not (Test-Path $p)) { continue }
    if ((Get-Item $p).PSIsContainer) { continue }

    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScanScript -Path $p
    if ($LASTEXITCODE -eq 2) {
        [Console]::Error.WriteLine("[Hook][DLP] Residual sensitive pattern in ${p}: $out")
        exit 2
    }
}
exit 0
