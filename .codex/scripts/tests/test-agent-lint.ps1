# test-agent-lint.ps1
# agent-lint 是設定本身的一致性檢查。它最危險的失效方式不是誤報，是**永遠不報** ——
# 一個抓不到任何東西的檢查，會讓人以為那個不變量有人在守。
# 所以每個檢查都要有一個「刻意破壞後必須紅燈」的案例。

$Script = '.codex/scripts/agent-lint.ps1'
$Scratch = Join-Path ([IO.Path]::GetTempPath()) 'codex-agent-lint-tests'

# 與正式 agent 同形的最小 AGENT-CORE 區塊。內容不必與正式版相同 ——
# 檢查 1 驗的是「所有 agent 之間逐字相同」，不是「與某個基準相同」。
$Core = @'
<!-- AGENT-CORE:BEGIN v8 — 測試用 -->
## 共用核心
- 測試用最小核心。
<!-- AGENT-CORE:END -->
'@

function New-ScratchAgent {
    param([string]$Name, [string]$Body, [string]$CoreBlock = $Core)
    New-Item -ItemType Directory -Path $Scratch -Force | Out-Null
    $p = Join-Path $Scratch "$Name.toml"
    $content = @"
name = "$Name"
description = "scratch"
sandbox_mode = "danger-full-access"
developer_instructions = '''
# $Name

$CoreBlock

$Body
'''
"@
    Set-Content $p -Value $content -NoNewline
    return $p
}

# orchestrator 沒有 toml —— 它的指令就是 AGENTS.md（最上層對話讀的那份）。
# 被 spawn 出來的 agent 拿不到 `agent` 工具，所以 orchestrator 一旦變成可被 spawn 的
# agent，② 到 ⑤ 全部委派不出去。scratch 這裡照同樣的形狀擺。
$ScratchOrchFile = Join-Path $Scratch 'AGENTS.md'

function New-ScratchOrchestrator {
    param([string]$Body, [string]$CoreBlock = $Core)
    New-Item -ItemType Directory -Path $Scratch -Force | Out-Null
    Set-Content $ScratchOrchFile -Value "# bdd-orchestrator`n`n$CoreBlock`n`n$Body" -NoNewline
    return $ScratchOrchFile
}

# 一組乾淨的 scratch 設定：orchestrator + 一個被正確路由到的子代理。
function New-CleanScratch {
    Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue
    New-ScratchOrchestrator @'
## 委派

| 要什麼 | 給誰 | mode |
|---|---|---|
| 查現況 | `sa-analyst` | `analyze` |
'@ | Out-Null
    New-ScratchAgent 'sa-analyst' '查現況並回選項。' | Out-Null
    return $Scratch
}

function Invoke-Lint {
    param([hashtable]$Extra = @{})
    $p = @{ AgentDir = $Scratch; OrchestratorFile = $ScratchOrchFile }
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    return Invoke-Script $Script -Params $p
}

Describe-Suite 'agent-lint / 基準' {

    It-Should '目前的正式設定是乾淨的' {
        $r = Invoke-Script $Script
        Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
    }

    It-Should '-Json 輸出可解析且回報 4 個子代理 ＋ 5 個核心檔' {
        # 4 個子代理 toml，加上 orchestrator（AGENTS.md）＝ 5 個檔要維持核心逐字一致。
        $r = Invoke-Script $Script -Params @{ Json = $true }
        $j = $r.stdout | ConvertFrom-Json
        Assert-True $j.passed
        Assert-Equal 4 $j.subagent_count
        Assert-Equal 5 $j.core_block_files
        Assert-True $j.core_block_sync
    }

    It-Should 'scratch 乾淨設定通過（前提：後面每個紅燈案例都只差一處）' {
        New-CleanScratch | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'agent-lint / 檢查 1：共用核心一致性' {

    It-Should '核心區塊漂移必須紅燈' {
        # 內嵌重複是刻意的（prompt cache 只認逐字相同的前綴），
        # 代價就是漂移風險。這個檢查是唯一在守它的東西。
        New-CleanScratch | Out-Null
        New-ScratchAgent 'sa-analyst' '查現況並回選項。' -CoreBlock @'
<!-- AGENT-CORE:BEGIN v8 — 測試用 -->
## 共用核心
- 測試用最小核心（被改過的版本）。
<!-- AGENT-CORE:END -->
'@ | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit '檢查 1 沒有觸發'
            Assert-Match 'agent-core-drift' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '完全缺少核心區塊必須紅燈' {
        New-CleanScratch | Out-Null
        New-ScratchAgent 'sa-analyst' '查現況並回選項。' -CoreBlock '' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit
            Assert-Match 'missing-agent-core' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'agent-lint / 檢查 3：名冊與委派表雙向一致' {

    # 取代了 v3 的 agent-skill-matrix 覆蓋檢查。矩陣是第二份會走鐘的名冊；
    # orchestrator 的委派表本來就是唯一真正決定「誰會被叫起來」的地方。
    It-Should '存在但沒被路由到的 agent 必須紅燈' {
        New-CleanScratch | Out-Null
        New-ScratchAgent 'implementer' '寫程式。' | Out-Null   # 委派表沒提到它
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit '檢查 3 沒有觸發 —— 孤兒 agent 會永遠不被叫起來且無人察覺'
            Assert-Match 'agent-not-routed' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '委派表指向不存在的 agent 必須紅燈' {
        # 這個錯誤原本要到執行期 spawn 失敗才會出現，而當下的訊息通常
        # 只說「找不到 agent」，不會說「是委派表寫錯」。
        New-CleanScratch | Out-Null
        New-ScratchOrchestrator @'
## 委派

| 要什麼 | 給誰 | mode |
|---|---|---|
| 查現況 | `sa-analyst` | `analyze` |
| 寫程式 | `implementer` | `build` |
'@ | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit
            Assert-Match 'route-to-unknown-agent' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '委派表整段消失必須紅燈' {
        New-CleanScratch | Out-Null
        New-ScratchOrchestrator '沒有委派表，只有 `sa-analyst` 這個提及。' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit
            Assert-Match 'route-table-missing' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'orchestrator 被做成可 spawn 的 agent 必須紅燈' {
        # 這是踩過的那一次：orchestrator 有了 toml → 被當子代理 spawn 起來 →
        # 拿不到 `agent` 工具 → ② 到 ⑤ 全部委派不出去。而症狀只是一句「工具不存在」，
        # 看起來像環境壞掉，沒有人會回頭懷疑是設定的形狀不對。
        New-CleanScratch | Out-Null
        New-ScratchAgent 'bdd-orchestrator' '## 委派' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit '檢查 3 的可 spawn 分支沒有觸發'
            Assert-Match 'orchestrator-must-not-be-spawnable' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'orchestrator 檔缺漏必須紅燈' {
        New-CleanScratch | Out-Null
        Remove-Item $ScratchOrchFile -Force
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit
            Assert-Match 'orchestrator-missing' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'agent-lint / 檢查 5：v4.0.0 已移除的概念殘留' {

    # 這是本次重構最高價值的檢查。殘留舊詞彙的症狀特別惡劣：
    # agent 會在執行期發出已不合法的欄位，而 hook 的錯誤訊息通常指向
    # 「缺少 X」而不是「X 的值已過期」—— 最難診斷的那一種。
    foreach ($case in @(
        @{ label = 'tier 欄位';        text = '- tier: t2' }
        @{ label = 'tier 值';          text = '交付走 `t3`。' }
        @{ label = 'gate';             text = '核准後進 gate-close。' }
        @{ label = 'run 狀態檔';       text = '更新 workflow-state 的欄位。' }
        @{ label = '已刪除的 agent';   text = '需要時委派 `living-doc`。' }
        @{ label = '舊回傳狀態';       text = '回 partial-completed。' }
    )) {
        It-Should "殘留「$($case.label)」必須紅燈" {
            New-CleanScratch | Out-Null
            New-ScratchAgent 'sa-analyst' $case.text | Out-Null
            try {
                $r = Invoke-Lint
                Assert-Equal 2 $r.exit "「$($case.text)」沒有被抓到"
                Assert-Match 'stale-ref' $r.stderr
            } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It-Should '`sa-analyst` 不得被「已刪除的 analyst」誤傷' {
        # `-match` 在 PowerShell 大小寫不敏感，裸字 `analyst` 會命中標題 "SA Analyst"。
        # 這條測試鎖住「用反引號形式比對」的修法 —— 一旦有人改回裸字比對就會紅。
        New-CleanScratch | Out-Null
        New-ScratchAgent 'sa-analyst' '# SA Analyst 的工作是系統分析，由 `sa-analyst` 執行。' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 0 $r.exit "誤報：stderr: $($r.stderr)"
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'agent-lint / 檢查 4：引用路徑存在性' {

    It-Should '引用不存在的 policy 必須紅燈' {
        New-CleanScratch | Out-Null
        New-ScratchAgent 'sa-analyst' '另遵循 `policies/no-such-policy.md`。' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit
            Assert-Match 'dangling-ref' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '引用不存在的 skill 必須紅燈' {
        # skill 是延伸規則的載入點。指向不存在的 skill 不會有任何執行期錯誤 ——
        # agent 只會讀不到東西然後照自己的判斷做，靜默降級。
        New-CleanScratch | Out-Null
        New-ScratchAgent 'sa-analyst' '影響不明 → skill `no-such-skill`。' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit '檢查 4 的 skill 分支沒有觸發'
            Assert-Match 'dangling-skill-ref' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '引用存在的 skill 通過' {
        New-CleanScratch | Out-Null
        New-ScratchAgent 'sa-analyst' '需求缺口 → skill `requirement-gap-analysis`。' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# orchestrator 提到 evidence 路徑，但委派表仍然完整 —— 只差消費者那一側。
$OrchWithEvidence = @'
## 委派

| 要什麼 | 給誰 | mode |
|---|---|---|
| 查現況 | `sa-analyst` | `analyze` |

DB 盤點落在 `bdd-docs/{feature-id}/evidence/db-*.md`，把 path 補進 handoff。
'@

Describe-Suite 'agent-lint / 檢查 6：產物路徑合約' {

    It-Should '消費者沒提到產物路徑必須紅燈' {
        # 這是**靜默**失效：生產者改了落地路徑而消費者沒跟上，症狀不是報錯，
        # 是 SA 找不到證據於是回頭要求查 DB —— 使用者被要求批准一件已經批准過的事。
        New-CleanScratch | Out-Null
        New-ScratchOrchestrator $OrchWithEvidence | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit 'sa-analyst 沒提到 evidence 路徑卻通過了'
            Assert-Match 'artifact-path-orphan' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '三方都提到就通過' {
        New-CleanScratch | Out-Null
        New-ScratchOrchestrator $OrchWithEvidence | Out-Null
        New-ScratchAgent 'sa-analyst' 'handoff 帶了 `bdd-docs/{feature-id}/evidence/db-*.md` 就先讀它。' | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 0 $r.exit "誤報：stderr: $($r.stderr)"
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有人用到的產物不強制' {
        # 這一版可能就是沒有 legacy-schema 的需求，不該因此紅燈。
        New-CleanScratch | Out-Null
        try {
            $r = Invoke-Lint
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'agent-lint / 檢查 2 與 7：結構與版本' {

    It-Should 'name 與檔名不一致必須紅燈' {
        New-CleanScratch | Out-Null
        $p = Join-Path $Scratch 'sa-analyst.toml'
        (Get-Content $p -Raw) -replace 'name = "sa-analyst"', 'name = "analyst-sa"' | Set-Content $p -NoNewline
        try {
            $r = Invoke-Lint
            Assert-Equal 2 $r.exit
            Assert-Match 'name-mismatch' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '版本檔缺漏必須紅燈' {
        New-CleanScratch | Out-Null
        try {
            $r = Invoke-Lint -Extra @{ VersionFile = '.codex/bdd-workflow/no-such-version.json' }
            Assert-Equal 2 $r.exit
            Assert-Match 'version-file-missing' $r.stderr
        } finally { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
