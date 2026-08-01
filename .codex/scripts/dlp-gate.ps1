# dlp-gate.ps1
# PostToolUse 縱深防禦：對寫入 bdd-docs/** 的 artifact 執行殘留掃描。
#
# 短路條件（Phase 0.4）：若該 artifact 所屬 run 目錄下存在 `.dlp-disabled` 標記
# （使用者於 intake 選「不需要脫敏」時由 living-doc 建立），整條掃描鏈路跳過。
#
# Exit: 0 = 通過或已短路；2 = 偵測到殘留（阻斷）。

[CmdletBinding()]
param(
    [string]$Payload,
    [string]$ScanScript = '.codex/scripts/dlp-residual-scan.ps1'
)

if (-not $Payload) { $Payload = [Console]::In.ReadToEnd() }
if (-not $Payload) { exit 0 }
if (-not (Test-Path $ScanScript)) { exit 0 }

# 引號類別含單引號：PowerShell heredoc／shell 寫入路徑慣用單引號，
# 只認雙引號會讓經 shell 寫入的 artifact 完全躲過本 gate。
$targets = [regex]::Matches($Payload, '["''](bdd-docs[^"''\r\n]*)["'']') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique

foreach ($p in $targets) {
    if (-not (Test-Path $p)) { continue }
    if ((Get-Item $p).PSIsContainer) { continue }

    # --- 短路：該 run 已宣告免脫敏 ---
    $norm = ($p -replace '\\', '/')
    if ($norm -match '^(bdd-docs/runs/[^/]+)/') {
        if (Test-Path (Join-Path $Matches[1] '.dlp-disabled')) { continue }
    }

    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScanScript -Path $p
    if ($LASTEXITCODE -eq 2) {
        [Console]::Error.WriteLine("[Hook][DLP] Residual sensitive pattern in ${p}: $out")
        exit 2
    }
}
exit 0
