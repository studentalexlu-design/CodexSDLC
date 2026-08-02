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
if (Test-Path $DisableMarker) { exit 0 }

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
