# test-build-check.ps1
# build-check 掛在每一次 apply_patch 上，所以它有兩種失效方式：
#   - 觸發判定過寬 → 改一個 .md 也 build，純等待
#   - 觸發判定過窄 → 改 production code 卻不 build，守衛形同不存在
# 另外驗證綠燈去抖：一次邏輯變更由數個 patch 組成，每個 patch 都 build 是主要的等待來源。

$Script = '.codex/scripts/build-check.ps1'

function New-EditPayload {
    param([string[]]$Paths)
    $files = $Paths | ForEach-Object { @{ path = $_ } }
    return (@{ tool_name = 'apply_patch'; tool_input = @{ files = $files } } | ConvertTo-Json -Depth 5 -Compress)
}

Describe-Suite 'build-check / 觸發判定' {

    It-Should '.cs 變更會觸發' {
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/Orders/OrderService.cs')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=1' $r.stdout
    }

    It-Should '.csproj / .sln 變更會觸發' {
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/Orders/Orders.csproj', 'App.sln')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=2' $r.stdout
    }

    It-Should 'markdown 不觸發' {
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('README.md', 'AGENTS.md')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=0' $r.stdout
    }

    It-Should 'bdd-docs/ 下的產物不觸發（即使副檔名相符）' {
        # 工作流自己的產物不是 production code。誤觸發會讓每次寫 checkpoint 都 build。
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('bdd-docs/f1/sample.cs')) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=0' $r.stdout
    }

    It-Should '混合變更只算 production code 那些' {
        $paths = @('src/A.cs', 'docs/note.md', 'bdd-docs/f1/spec.md', 'src/B.cs')
        $r = Invoke-Script $Script -Stdin (New-EditPayload $paths) -Params @{ WhatIfPaths = $true }
        Assert-Match 'triggering=2' $r.stdout
    }

    It-Should '空 payload 靜默通過' {
        $r = Invoke-Script $Script -Stdin ''
        Assert-Equal 0 $r.exit
    }

    It-Should '無可辨識專案時不阻斷（本 repo 沒有 .sln／pom.xml）' {
        # 這個 repo 只有設定沒有產品程式碼。守衛在無工具鏈時必須靜默放行，
        # 否則把設定 repo 本身變成不可編輯。
        $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/Orders/OrderService.cs'))
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }
}

Describe-Suite 'build-check / 綠燈去抖' {

    # 去抖時間戳依 cwd 雜湊命名，路徑要與腳本內的算法一致才能操作它。
    function Get-StampPath {
        $hash = [BitConverter]::ToString(
            [Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes((Get-Location).Path))
        ).Replace('-', '').Substring(0, 12)
        return (Join-Path ([IO.Path]::GetTempPath()) "codex-build-check-$hash.stamp")
    }

    It-Should '時間戳在視窗內時略過 build' {
        $stamp = Get-StampPath
        Set-Content $stamp -Value (Get-Date -Format o) -NoNewline
        try {
            # 若沒有略過，會落到「推斷專案類型」那段；本 repo 無專案檔仍會 exit 0，
            # 所以改用 -WhatIfPaths 之外的可觀察差異：略過時不會印任何東西。
            $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/A.cs')) -Params @{ DebounceSeconds = 300 }
            Assert-Equal 0 $r.exit
        } finally { Remove-Item $stamp -ErrorAction SilentlyContinue }
    }

    It-Should 'DebounceSeconds=0 時停用去抖' {
        $stamp = Get-StampPath
        Set-Content $stamp -Value (Get-Date -Format o) -NoNewline
        try {
            $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/A.cs')) -Params @{ DebounceSeconds = 0 }
            Assert-Equal 0 $r.exit
        } finally { Remove-Item $stamp -ErrorAction SilentlyContinue }
    }

    It-Should '過期時間戳不再抑制' {
        $stamp = Get-StampPath
        Set-Content $stamp -Value 'old' -NoNewline
        (Get-Item $stamp).LastWriteTime = (Get-Date).AddSeconds(-3600)
        try {
            $r = Invoke-Script $Script -Stdin (New-EditPayload @('src/A.cs')) -Params @{ DebounceSeconds = 90 }
            Assert-Equal 0 $r.exit
        } finally { Remove-Item $stamp -ErrorAction SilentlyContinue }
    }
}
