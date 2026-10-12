# test-hooks-json.ps1
# hooks.json 的每一條，照 Codex 在 Windows 上的包法真的跑一次：`pwsh -NoProfile -Command "<commandWindows>"`，payload 走 stdin。
#
# 別的測試驗的是腳本（pwsh -File），這一組驗的是 hooks.json 裡那一行字串本身 —— v4.13.0 起 commandWindows 直接在 Codex
# 起的那個 pwsh 裡跑腳本（`& ./腳本`），exit code、stdin、stderr 都要穿得過那一層才算數：
#   exit 2 被吃成 1（或 0）→ Codex 當成 hook 失敗／通過，不阻斷，理由也不交給模型 —— 強制層靜默消失。
# 包法是 Codex 0.162.1 實測的（版本檔 v413-speedup）；Codex 改了包法，這裡要跟著重量。

$HooksFile = '.codex/hooks.json'

function Invoke-HookCommand([string]$Command, [string]$Stdin) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8; $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    foreach ($a in @('-NoProfile', '-Command', $Command)) { $psi.ArgumentList.Add($a) }
    $proc = [Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
    if ($Stdin) { $proc.StandardInput.Write($Stdin) }
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    [pscustomobject]@{ exit = $proc.ExitCode; stdout = $outTask.GetAwaiter().GetResult(); stderr = $errTask.GetAwaiter().GetResult() }
}

function Get-HookCommand([string]$scriptLeaf) {
    $doc = Get-Content $HooksFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($ev in $doc.hooks.PSObject.Properties) {
        foreach ($g in @($ev.Value)) { foreach ($h in @($g.hooks)) { if ([string]$h.commandWindows -match [regex]::Escape($scriptLeaf)) { return [string]$h.commandWindows } } }
    }
    throw "hooks.json 裡找不到跑 $scriptLeaf 的 commandWindows"
}

Describe-Suite 'hooks.json / 照 Codex 的包法跑（pwsh -NoProfile -Command "<commandWindows>"）' {

    It-Should 'handoff-lint：缺 mode 的 handoff 回 2，理由在 stderr；合法的回 0' {
        $cmd = Get-HookCommand 'handoff-lint.ps1'
        $bad = "## meta`n- feature-id: cancel-order`n`n## summary`n取消訂單。"
        $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ message = $bad })
        Assert-Equal 2 $r.exit "stderr: $($r.stderr)"
        Assert-Match 'mode' $r.stderr '阻斷理由沒有穿過外層'
        $good = "## meta`n- feature-id: cancel-order`n- mode: analyze`n`n## summary`n取消訂單。"
        $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ message = $good })
        Assert-Equal 0 $r.exit "合法的 handoff 被擋；stderr: $($r.stderr)"
    }

    It-Should 'handoff-lint：send_input 交回的修正輪超過上限回 2；沒帶 mode 的追問回 0' {
        # matcher 攔得到 send_input 還不夠，那一行在 Codex 的包法下也要真的把 exit 2 傳出去。
        $cmd = Get-HookCommand 'handoff-lint.ps1'
        $doc = Get-Content $HooksFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ([regex]::IsMatch('multi_agent_v1send_input', $doc.hooks.PreToolUse[0].matcher)) 'matcher 攔不到 multi_agent_v1send_input'
        $fix = "## meta`n- feature-id: cancel-order`n- mode: fix`n- round: 99`n- spec: bdd-docs/cancel-order/spec.md`n`n## summary`n照 review.md 修。"
        $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Event 'PreToolUse' -Tool 'multi_agent_v1send_input' -ToolInput @{ target = 'x'; message = $fix })
        Assert-Equal 2 $r.exit "stderr: $($r.stderr)"
        Assert-Match 'review-loop-exceeded' $r.stderr
        $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Event 'PreToolUse' -Tool 'multi_agent_v1send_input' -ToolInput @{ target = 'x'; message = '測試失敗的前 3 行貼一下。' })
        Assert-Equal 0 $r.exit "追問被擋了；stderr: $($r.stderr)"
    }

    It-Should 'dlp-gate：apply_patch 寫進 bdd-docs/ 的 email 回 2（殘留掃描在同一個行程裡跑）；乾淨的回 0' {
        $cmd = Get-HookCommand 'dlp-gate.ps1'
        $d = "bdd-docs/hj-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Get-Location) "$d/notes.md"), "客戶 heidi@contoso.com`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path (Get-Location) "$d/clean.md"), "沒有敏感資料`n", [Text.UTF8Encoding]::new($false))
        try {
            $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/notes.md"))
            Assert-Equal 2 $r.exit "stderr: $($r.stderr)"
            Assert-Match 'Residual sensitive pattern' $r.stderr
            Assert-True ($r.stderr -notmatch 'heidi') '阻斷訊息洩漏了命中的原始值'
            $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Command (New-CodexPatch -Add "$d/clean.md"))
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'guideline-gate：Bash 剛寫出含 NOLOCK 的 .sql 回 2，中文理由原樣到達' {
        $cmd = Get-HookCommand 'guideline-gate.ps1'
        $d = "hj-src-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $rules = "hj-rules-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Get-Location) "$d/q.sql"), "SELECT Id FROM T WITH (NOLOCK)`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path (Get-Location) $rules), '{ "rules": [ { "id": "no-nolock", "applies-to": ["**/*.sql"], "pattern": "(?i)NOLOCK", "severity": "block", "message": "禁止 NOLOCK", "fix": "改用快照隔離" } ] }', [Text.UTF8Encoding]::new($false))
        try {
            # 規則檔用參數指給它：在 hook 的那一行後面接參數，跟 Codex 跑的是同一個 pwsh 與同一條 exit code 路徑。
            $withRules = $cmd -replace '(guideline-gate\.ps1)', "`$1 -RulesFile '$rules'"
            $r = Invoke-HookCommand $withRules (New-CodexHookPayload -Tool 'Bash' -Command "Set-Content -Path '$d/q.sql' -Value `$sql")
            Assert-Equal 2 $r.exit "stderr: $($r.stderr)"
            Assert-Match '禁止 NOLOCK' $r.stderr '中文理由沒有原樣穿過外層'
        } finally { Remove-Item $d, $rules -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'build-check：沒有可 build 的專案時回 0（不阻斷）' {
        $cmd = Get-HookCommand 'build-check.ps1'
        $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Command (New-CodexPatch -Update 'src/Orders/OrderService.cs'))
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }

    It-Should '拿掉結尾的 exit $LASTEXITCODE → 阻斷變成 1（證明上面那幾條量得到外層）' {
        # Codex 0.154／0.162 實測：-Command 把內層的 exit 2 回報成 1，Codex 當成「hook 失敗」—— 不阻斷。
        $cmd = (Get-HookCommand 'handoff-lint.ps1') -replace ';\s*exit\s+\$LASTEXITCODE\s*$', ''
        $bad = "## meta`n- feature-id: cancel-order`n`n## summary`n取消訂單。"
        $r = Invoke-HookCommand $cmd (New-CodexHookPayload -Event 'PreToolUse' -Tool 'spawn_agent' -ToolInput @{ message = $bad })
        Assert-True ($r.exit -ne 2) "沒有 exit `$LASTEXITCODE 也回 2 —— 這組測試量不到外層"
    }
}
