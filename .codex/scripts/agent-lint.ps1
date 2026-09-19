# agent-lint.ps1
# 驗證 agent 定義的結構完整性與共用核心一致性。
#
# **orchestrator 沒有 toml —— 它就是 AGENTS.md（最上層對話本身）。** 被 spawn 出來的
# agent 不能再 spawn，所以 orchestrator 一旦有了 agent 定義檔就會被當成子代理叫起來，
# 然後委派不出去。檢查 3 因此多守一條：`bdd-orchestrator.toml` 不得出現在 $AgentDir。
#
# 共用核心刻意內嵌在每個檔（系統提示內，可跨同 agent 重複呼叫命中 cache），
# 而不是執行期讀共用檔。內嵌會帶來漂移風險 —— 本腳本把「重複」變成「被強制一致的重複」。
#
# 檢查項：
#   1. AGENT-CORE 區塊在所有 agent（含 AGENTS.md）中逐字相同
#   2. TOML 結構：''' 配對、必要 key 齊全、name 與檔名一致
#   3. agent 名冊與 orchestrator 委派表雙向一致，且 orchestrator 不得是可被 spawn 的 agent
#      （沒被路由到的 agent 永遠不會被叫起來；路由到不存在的 agent 會在執行期才炸）
#   4. 引用的 policy / runbook / script / skill 路徑真實存在
#   5. 無 v4.0.0 已移除的概念殘留
#      （這是本次重構最高價值的檢查：tier／gate／run 狀態／已刪除的 agent 名稱
#        散落在十幾個檔裡，漏一處的症狀通常是「執行期被擋下，而訊息指向錯的原因」）
#   6. 產物路徑合約：生產者／路由者／消費者三方都提到同一個路徑
#   7. bdd-workflow-version.json 可解析且帶版本號
#   8. guidelines/ 底下每個規範檔都有 agent 讀（檔名即路由鍵，沒有讀者就是靜默失效）
#   9. SDLC-TUNING 區塊與 sdlc.config.json 一致（改了設定卻沒 apply，症狀是零）
#  10. 版本號單一真相：AGENTS.md 與 config.toml 的標題要對得上版本檔
#  11. VS Code extension 的 package.json 版本 = 版本檔（repo 裡有 extension 原始碼時才檢查）
#  12. hooks.json 的形狀在 Codex 上真的擋得住：exit code 傳得出來、matcher 對得上真正的工具名稱
#  13. sdlc.config.json 的 review.maxRounds 是 1–5 的整數、update.check 是認得的值（寫壞時照預設算，症狀是「設定沒生效」）
#  14. 合法值的單一來源：sdlc.config.schema.json／rules.schema.json 跟各腳本留的常數一致
#
# v4.0.0 移除的檢查：skill matrix 覆蓋、gate 定義完整性、回傳 shape 對 policy 檔、
# tier 表對 route-profiles、findings 段落對 template、合併 mode 矛盾、文件 tier 預算。
# 它們守的東西（gate 檔、tier 表、route-profiles、living-doc、design-modeler）都已不存在。
#
# Exit: 0 = 全部通過；2 = 有違規。

[CmdletBinding()]
param(
    [string]$AgentDir          = '.codex/agents',
    [string]$Orchestrator      = 'bdd-orchestrator',
    [string]$OrchestratorFile  = 'AGENTS.md',
    [string]$VersionFile       = '.codex/bdd-workflow/bdd-workflow-version.json',
    [string]$GuidelineDir      = 'guidelines',
    [string]$ConfigFile        = 'sdlc.config.json',
    [string]$WorkflowConfig    = '.codex/config.toml',
    [string]$ExtensionManifest = 'vscode-extension/package.json',
    [string]$HooksFile         = '.codex/hooks.json',
    [string]$ConfigSchema      = '.codex/bdd-workflow/sdlc.config.schema.json',
    [string]$RulesSchema       = '.codex/bdd-workflow/rules.schema.json',
    [string]$ScriptDir         = '.codex/scripts',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---- 標準 I/O：被程式呼叫時一律 UTF-8 ----
# Codex 送進來的 payload 是 UTF-8、也用 UTF-8 解讀 hook 的輸出；Windows 上 [Console] 的編碼卻跟著 console 的
# code page 走（zh-TW 是 cp950；並行的 hook 共用同一個 console，偶爾連輸出端也是）。Codex 0.154.0 實測的後果：
# 一份 743 字、meta 完整的中文 handoff 被解成 1772 字、JSON 解析失敗、抓不到 mode —— **每一次 spawn 都被擋**；
# 阻斷理由的中文到模型手上是亂碼。只在被重導向時才換：人在終端機跑的時候照 console 的 code page 顯示。
# 同一段在 handoff-lint／dlp-gate／guideline-gate／build-check／agent-lint／sdlc.ps1 各有一份。
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
if ([Console]::IsOutputRedirected) { $w = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetOut($w) }
if ([Console]::IsErrorRedirected)  { $w = [IO.StreamWriter]::new([Console]::OpenStandardError(),  $Utf8NoBom); $w.AutoFlush = $true; [Console]::SetError($w) }
function Read-StdinUtf8 {
    if ([Console]::IsInputRedirected) { return [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8NoBom).ReadToEnd() }
    return [Console]::In.ReadToEnd()
}

$violations = @()
function Add-V([string]$rule, [string]$detail, [string]$fix) {
    $script:violations += [pscustomobject]@{ rule = $rule; detail = $detail; fix = $fix }
}

$agents = @(Get-ChildItem $AgentDir -Filter *.toml -ErrorAction SilentlyContinue)
if (-not $agents) { Write-Error "no agent toml under $AgentDir"; exit 2 }

# 受檢文件 = 子代理 toml ＋ orchestrator（AGENTS.md）。
# 檢查 1／4／5／6 對兩者一視同仁；只有檢查 2（TOML 結構）僅適用於 toml。
$docs = [ordered]@{}
foreach ($a in $agents) {
    $docs[$a.BaseName] = [pscustomobject]@{ Label = $a.Name; Text = (Get-Content $a.FullName -Raw) }
}
if (Test-Path $OrchestratorFile) {
    $docs[$Orchestrator] = [pscustomobject]@{
        Label = (Split-Path $OrchestratorFile -Leaf)
        Text  = (Get-Content $OrchestratorFile -Raw)
    }
} else {
    Add-V 'orchestrator-missing' $OrchestratorFile `
          'orchestrator 的指令就是這個檔（最上層對話讀的那份）—— 缺檔則整套流程沒有入口'
}

# ---- 1. AGENT-CORE 區塊逐字一致 ----
$coreRe = '(?s)<!-- AGENT-CORE:BEGIN.*?<!-- AGENT-CORE:END -->'
$cores = @{}
foreach ($k in $docs.Keys) {
    $m = [regex]::Match($docs[$k].Text, $coreRe)
    if (-not $m.Success) {
        Add-V 'missing-agent-core' $docs[$k].Label '內嵌 AGENT-CORE 區塊（從任一現有 agent 複製）'
        continue
    }
    $cores[$k] = ($m.Value -replace "`r`n", "`n")
}
if ($cores.Count -gt 1) {
    $ref = $cores[($cores.Keys | Sort-Object)[0]]
    foreach ($k in ($cores.Keys | Sort-Object)) {
        if ($cores[$k] -ne $ref) {
            Add-V 'agent-core-drift' $k '共用核心已漂移；與其他 agent 的區塊同步（必須逐字相同）'
        }
    }
}

# ---- 2. TOML 結構 ----
# `model_reasoning_effort` 不在必填之列：釘死在 agent 定義裡會蓋掉 CLI 的設定，
# 而把 `sa-analyst` 釘在 high 正是大型 legacy repo 分析逾時的成因之一。
# 要設仍然可以設（這裡不禁止），但它是**呼叫端的選擇**，不是 agent 定義的義務。
$requiredKeys = @('name', 'description', 'sandbox_mode', 'developer_instructions')
foreach ($a in $agents) {
    $t = Get-Content $a.FullName -Raw
    $q = ([regex]::Matches($t, "'''")).Count
    if ($q -ne 2) { Add-V 'toml-delimiter' "$($a.Name): ''' x$q" "developer_instructions 須恰好一組 ''' 界定" }
    foreach ($k in $requiredKeys) {
        if ($t -notmatch "(?m)^$k\s*=") { Add-V 'toml-missing-key' "$($a.Name): $k" "補上 $k" }
    }
    $declared = [regex]::Match($t, '(?m)^name\s*=\s*"([^"]+)"').Groups[1].Value
    if ($declared -and $declared -ne $a.BaseName) {
        Add-V 'name-mismatch' "$($a.Name): name=$declared" 'name 必須與檔名一致'
    }
}

# ---- 3. agent 名冊 ↔ orchestrator 委派表 雙向一致 ----
# 取代了舊的 agent-skill-matrix.json 覆蓋檢查。矩陣是第二份會走鐘的名冊；
# orchestrator 的委派表本來就是唯一真正決定「誰會被叫起來」的地方，直接綁它。

# orchestrator 一旦有了 agent 定義檔，就會被當成子代理 spawn 起來，而被 spawn 出來的
# agent 拿不到 `agent` 工具 —— ② 到 ⑤ 全部委派不出去，症狀卻只是一句「工具不存在」。
# 這道檢查是唯一在守它的東西：踩過一次，兩次冷啟動零產出收場。
$orchToml = Join-Path $AgentDir "$Orchestrator.toml"
if (Test-Path $orchToml) {
    Add-V 'orchestrator-must-not-be-spawnable' $orchToml `
          "刪掉這個檔 —— orchestrator 的指令屬於 $OrchestratorFile。被 spawn 出來的 orchestrator 無法再委派"
}

if ($docs.Contains($Orchestrator)) {
    $orchText = $docs[$Orchestrator].Text
    $onDisk = @($agents.BaseName | Where-Object { $_ -ne $Orchestrator })

    foreach ($d in $onDisk) {
        if ($orchText -notmatch [regex]::Escape("``$d``")) {
            Add-V 'agent-not-routed' $d `
                  "bdd-orchestrator 的委派表沒有提到它 —— 沒有路由的 agent 永遠不會被叫起來"
        }
    }

    # 委派表列： | 要什麼 | `agent-name` | mode |
    $routeSection = [regex]::Match($orchText, '(?s)##\s*委派.*?(?=\r?\n##\s|\Z)')
    if ($routeSection.Success) {
        foreach ($row in [regex]::Matches($routeSection.Value, '(?m)^\|[^|]*\|\s*`([a-z][a-z0-9-]*)`\s*\|')) {
            $target = $row.Groups[1].Value
            if ($target -notin $onDisk) {
                Add-V 'route-to-unknown-agent' "委派表指向 ``$target``，但 $AgentDir 沒有這個 agent" `
                      '修正 agent 名稱或建立該 agent —— 這個錯誤要到執行期 spawn 失敗才會出現'
            }
        }
    } else {
        Add-V 'route-table-missing' $OrchestratorFile '「## 委派」段落遺失；沒有它就沒有任何機械可查的路由來源'
    }
}

# ---- 4. 引用路徑存在性 ----
$refPatterns = @(
    @{ re = '`?(policies/[a-z0-9-]+\.md)`?';  base = '.codex/bdd-workflow/' }
    @{ re = '`?(runbooks/[a-z0-9-]+\.md)`?';  base = '.codex/bdd-workflow/' }
    @{ re = '(\.codex/scripts/[a-z0-9-]+\.ps1)'; base = '' }
    @{ re = '(\.codex/bdd-workflow/(?:policies|runbooks|templates)/[a-z0-9-]+\.md)'; base = '' }
)
foreach ($k in $docs.Keys) {
    $t = $docs[$k].Text
    foreach ($p in $refPatterns) {
        foreach ($mm in [regex]::Matches($t, $p.re)) {
            $rel = $mm.Groups[1].Value
            if ($rel -match '\{') { continue }   # 樣板路徑
            $full = if ($p.base) { Join-Path $p.base $rel } else { $rel }
            if (-not (Test-Path $full)) {
                Add-V 'dangling-ref' "$($docs[$k].Label) -> $rel" '修正路徑或建立該檔'
            }
        }
    }
}
# skill 引用：skill `name` → .agents/skills/{name}/SKILL.md
foreach ($k in $docs.Keys) {
    foreach ($mm in [regex]::Matches($docs[$k].Text, 'skill\s+`([a-z0-9-]+)`')) {
        $skill = $mm.Groups[1].Value
        if (-not (Test-Path ".agents/skills/$skill/SKILL.md")) {
            Add-V 'dangling-skill-ref' "$($docs[$k].Label) -> skill ``$skill``" '修正 skill 名稱或建立 .agents/skills/{name}/SKILL.md'
        }
    }
}

# ---- 5. v4.0.0 已移除的概念殘留 ----
# 這一類缺陷的症狀特別惡劣：殘留的舊詞彙會讓 agent 在執行期發出已不合法的欄位，
# 而 hook 的錯誤訊息通常指向「缺少 X」而不是「X 的值已過期」—— 最難診斷的那種。
# 因此模式寫得寧可嚴一點，誤報成本遠低於漏報。
$stale = @(
    # tier 系統（v4.0.0 整層移除，改為「這件事可不可逆」單一提問）
    '(?i)\btier\b',
    '`t[0-3]`',
    '`discover`',
    # gate 系統（改為對話式確認點）
    'gate-(probe|close|contract|migration|release)\b',
    'gate-confirmations?/',
    # run 狀態機（改為無狀態，狀態活在對話裡）
    'run-id',
    'workflow-state',
    'checkpoints?/',
    'probe-findings',
    'context-pack',
    'decision-log',
    'lean-sdlc',
    'source-materials-register',
    'subagent-calls',
    'quality-loop',
    'route-profiles',
    'workflow-contract',
    'agent-skill-matrix',
    # 已刪除的 agent。用反引號形式比對 —— agent 引用一律帶反引號，
    # 而裸字比對會誤傷（`-match` 在 PowerShell 大小寫不敏感，`analyst` 會命中標題 "SA Analyst"）。
    '`analyst`',
    '`formulator`',
    '`project-scanner`',
    '`atdd-automator`',
    '`tdd-implementer`',
    '`spec-reviewer`',
    '`code-reviewer`',
    '`design-modeler`',
    '`integration-tester`',
    '`living-doc`',
    # v4.2.0 移除：live DB 改由 orchestrator 自己查（skill `db-introspection`）。
    # 殘留的委派指示會讓它去 spawn 一個不存在的 agent，而錯誤要到執行期才出現。
    '`db-introspection-scanner`',
    # 已改名的回傳狀態
    'partial-completed',
    'needs-probe',
    # 更早期已移除的詞彙
    'agent-common\.md',
    'bdd-orchestrator\.agent\.md',
    'complexity-(assessment|routing)'
)
foreach ($k in $docs.Keys) {
    $t = $docs[$k].Text
    foreach ($s in $stale) {
        if ($t -match $s) { Add-V 'stale-ref' "$($docs[$k].Label): /$s/" 'v4.0.0 已移除該概念，更新或刪除該處' }
    }
}

# ---- 6. 產物路徑合約：生產者／路由者／消費者三方一致 ----
# 這類漂移是**靜默**的。scanner 改了落地路徑而 sa-analyst 沒跟上，症狀不是報錯 ——
# 是 SA 找不到證據於是回 `blocked` 要求查 DB，使用者被要求批准一件已經批准過的事，
# 而整條流程看起來一切正常。付出的代價（一次批准 ＋ 一次連線 ＋ 一次等待）沒有任何地方會記帳。
#
# 所以規則是「有人提到就三方都要提到」：沒有人用的產物不強制（這一版可能就是沒有），
# 但只要有人開始寫它，讀它的那一方就不能缺席。
$artifactContracts = @(
    # DB 證據自 v4.2.0 起由 orchestrator 自己查、自己落地（skill `db-introspection`），
    # 生產者與路由者是同一方；消費者仍是 sa-analyst，它靠 handoff 帶的 path 讀檔。
    @{ path = 'bdd-docs/{feature-id}/evidence/';   roles = @('bdd-orchestrator', 'sa-analyst') }
    @{ path = 'bdd-docs/{feature-id}/analysis.md'; roles = @('sa-analyst', 'bdd-orchestrator') }
    # v4.3.0：spec.md 多了一個消費者 —— sa-analyst 在 ② 讀 ① 的需求決議。
    # implementer／reviewer 有 handoff-lint 檢查 3a 保底（build／fix／code 必須帶 spec.md
    # 路徑），但 `analyze` **不在**那份清單裡，所以沒有任何機械層在守 SA 讀不讀得到決議。
    # 漏掉的症狀不是報錯：SA 拿著被壓進 300 字的決議去分析，回一份看起來很合理、
    # 但方向錯的做法清單，然後使用者在 ③ 照著它做不可逆的決定。
    @{ path = 'bdd-docs/{feature-id}/spec.md';     roles = @('bdd-orchestrator', 'sa-analyst') }
    @{ path = 'bdd-docs/artifacts/legacy-schema/'; roles = @('bdd-orchestrator', 'sa-analyst') }
    # v4.4.0：唯一跨需求的產物。生產者是 sa-analyst，orchestrator 只是路由者 ——
    # 它刻意**不讀**這個檔（那會把 repo 現況灌進唯一必須活到 ⑥ 的 context），但產出物表
    # 必須列它：漏了，「其餘一律不產出」就把它變成一個沒有人授權、卻每次分析都被寫出來的檔，
    # 而下一個維護者看不出那是設計還是失控。
    #
    # implementer 與 reviewer 是「測試骨架」那一節的消費者，兩者都只讀那一節。它們缺席的
    # 症狀比別的產物嚴重：step definition 在測試專案裡全域繫結，第 N 個需求看不到前 N-1 個
    # 建立的 step 詞彙就會另造一套，撞名時 Reqnroll／Cucumber 整包炸掉 —— 連已經綠的
    # 測試一起帶走。而那是 build 期的失敗，不是這條 lint 抓得到的東西，所以指標本身不能掉。
    @{ path = 'bdd-docs/project-map.md';           roles = @('sa-analyst', 'bdd-orchestrator', 'implementer', 'reviewer') }
    # v4.4.0：團隊規範。生產者是**人**（不是任何 agent），所以這裡只驗消費端。
    # orchestrator 刻意不讀它，但必須列 —— 它是 ③ 唯一會把「這個做法需要規範豁免」
    # 呈到使用者眼前的地方。漏掉的症狀是靜默的：sa-analyst 照樣標出違反 MUST 的做法，
    # 而 orchestrator 因為沒有被告知那一行的意義，把它當雜訊濾掉，使用者永遠不知道
    # 自己在 ③ 批准的是一個違反團隊規範的做法 —— 然後 ⑤ 才炸，而 ③ 已經回不去了。
    @{ path = 'guidelines/';                       roles = @('bdd-orchestrator', 'sa-analyst', 'implementer', 'reviewer') }
)
foreach ($c in $artifactContracts) {
    $lit = [regex]::Escape($c.path)
    $mentions = @($docs.Keys | Where-Object { $docs[$_].Text -match $lit })
    if ($mentions.Count -eq 0) { continue }
    foreach ($role in $c.roles) {
        if ($role -notin $docs.Keys) { continue }
        if ($role -notin $mentions) {
            Add-V 'artifact-path-orphan' "$($c.path) 未出現在 $role" `
                  '產物路徑須生產者／路由者／消費者三方一致 —— 漏掉消費者的症狀是它退回去重新要求查 DB，不是報錯'
        }
    }
}

# ---- 7. 版本檔 ----
if (Test-Path $VersionFile) {
    try {
        $ver = Get-Content $VersionFile -Raw | ConvertFrom-Json
        foreach ($k in @('contract-version', 'min-compatible-version')) {
            if ($ver.$k -notmatch '^\d+\.\d+\.\d+$') {
                Add-V 'version-invalid' "${k}=$($ver.$k)" '須為 semver（例如 4.0.0）'
            }
        }
    } catch { Add-V 'version-file-unparsable' $VersionFile '修正 JSON 格式' }
} else {
    Add-V 'version-file-missing' $VersionFile '建立版本檔 —— 消費端專案靠它判斷相容性'
}

# ---- 8. guidelines/ 的每個檔都要有讀者 ----
# 規範走「檔名即路由鍵」，沒有映射表（映射表是第二份會走鐘的名冊）。代價是：
# 團隊新增 guidelines/security.md 而沒有任何 agent 提到那個檔名時，**沒有人會讀它**，
# 而症狀是零 —— 沒有錯誤、沒有警告，只是規範不生效，團隊卻以為有人在守。
# 這道檢查是唯一在守它的東西。README.md 是寫給人看的說明，不算規範。
if (Test-Path $GuidelineDir) {
    $allAgentText = ($docs.Keys | ForEach-Object { $docs[$_].Text }) -join "`n"
    foreach ($g in @(Get-ChildItem $GuidelineDir -Filter *.md -File -ErrorAction SilentlyContinue)) {
        if ($g.Name -eq 'README.md') { continue }
        if ($allAgentText -notmatch [regex]::Escape($g.Name)) {
            Add-V 'guideline-has-no-reader' "$GuidelineDir/$($g.Name)" `
                  '沒有任何 agent 提到這個檔名 —— 規範不會被讀到，而且完全靜默。把檔名寫進讀它的 agent 的「專案規範」一節，或把內容併進已經有讀者的檔'
        }
    }
}

# ---- 9. SDLC-TUNING 區塊 ↔ sdlc.config.json ----
# 使用者的 model／effort 真相是專案根的 sdlc.config.json（放在工具那半會在升級時靜默消失）。
# toml 裡的區塊只是它的產物，由 `sdlc.ps1 apply` 產生。
#
# 這道檢查守的是「改了設定但沒 apply」：檔案看起來改好了，跑起來是舊值 —— **症狀是零**。
# 同 guideline-gate 檔頭那句：靜默地「設定沒在生效」比擋錯更糟。
#
# 正規化字串是這裡與 sdlc.ps1 之間的合約，兩邊各有一份逐字相同的副本 ——
# lint 必須能獨立驗，不能為了算一個雜湊去 spawn 那支腳本。重複由 test-sdlc.ps1 的
# 「設定改了但沒 apply → 必須紅燈」那一條守住。
if (Test-Path $ConfigFile) {
    $cfg = $null
    try { $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $cfg) {
        Add-V 'sdlc-config-unparsable' $ConfigFile '修正 JSON 格式 —— 解析不了時 apply 與 doctor 都會停擺'
    } else {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            foreach ($a in $agents) {
                $acfg = $null
                if ($cfg.agents) {
                    $acfg = $cfg.agents.PSObject.Properties |
                            Where-Object { $_.Name -eq $a.BaseName } |
                            ForEach-Object { $_.Value } | Select-Object -First 1
                }
                $model  = if ($acfg -and $acfg.model)  { [string]$acfg.model }  else { 'inherit' }
                $effort = if ($acfg -and $acfg.effort) { [string]$acfg.effort } else { 'inherit' }
                $stanza = "model=$model;effort=$effort"
                $want = (-join ($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($stanza)) |
                                ForEach-Object { $_.ToString('x2') })).Substring(0, 8)

                $text = Get-Content $a.FullName -Raw
                $m = [regex]::Match($text, '#\s*SDLC-TUNING:BEGIN\s+sha=([0-9a-f]{8})')
                if (-not $m.Success) {
                    Add-V 'tuning-block-missing' $a.Name `
                          "有 $ConfigFile 就要有產生區塊 —— 跑 pwsh .codex/scripts/sdlc.ps1 apply"
                } elseif ($m.Groups[1].Value -ne $want) {
                    Add-V 'tuning-block-stale' "$($a.Name): sha=$($m.Groups[1].Value)，設定檔是 $want" `
                          "設定改過但沒有套用 —— 跑 pwsh .codex/scripts/sdlc.ps1 apply（不跑的話流程用的是舊值，而畫面上看不出來）"
                }
            }
        } finally { $sha256.Dispose() }
    }
}

# ---- 10. 版本號單一真相 ----
# 版本檔的 contract-version 是唯一真相。AGENTS.md 與 config.toml 的標題各自寫過一次版本號，
# 而它們曾經停在 v4.3.0 而版本檔已經是 4.5.1 —— 一個會謊報自己版本的發佈物，
# 讓 update 的相容性判斷與使用者的升級決定同時建立在錯的數字上。
if ($ver -and $ver.'contract-version') {
    $truth = [string]$ver.'contract-version'
    foreach ($f in @($OrchestratorFile, $WorkflowConfig)) {
        if (-not (Test-Path $f)) { continue }
        $head = (Get-Content $f -TotalCount 3) -join "`n"
        $m = [regex]::Match($head, 'v(\d+\.\d+\.\d+)')
        if ($m.Success -and $m.Groups[1].Value -ne $truth) {
            Add-V 'version-drift' "$f 標題寫 v$($m.Groups[1].Value)，版本檔是 $truth" `
                  "改成 v$truth —— 版本檔是唯一真相"
        }
    }
}

# ---- 11. VS Code extension 的版本 = 版本檔 ----
# extension 的 package.json.version 是版本號的第四處。它跟前三處（版本檔、AGENTS.md、config.toml）
# 分岔的症狀跟檢查 10 一樣：`doctor` 的相容性判斷與使用者要不要重裝 extension 的決定，
# 同時建立在一個錯的數字上。pack.ps1 出貨前跑本腳本，所以這裡紅 = 不出貨。
# 只在 repo 裡真的有 extension 原始碼時檢查 —— 消費端專案不會有這個目錄。
if ($ver -and $ver.'contract-version' -and (Test-Path $ExtensionManifest)) {
    $truth = [string]$ver.'contract-version'
    $pkg = $null
    try { $pkg = Get-Content $ExtensionManifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $pkg) {
        Add-V 'extension-manifest-unparsable' $ExtensionManifest '修正 JSON 格式 —— 解析不了時 pack 產不出 vsix'
    } elseif ([string]$pkg.version -ne $truth) {
        Add-V 'extension-version-drift' "$ExtensionManifest 是 $($pkg.version)，版本檔是 $truth" `
              "把 $ExtensionManifest 的 version 改成 $truth —— 版本檔是唯一真相"
    }
}

# ---- 12. hooks.json 在 Codex 上真的擋得住 ----
# 這道檢查守的三件事，全部是 Codex 0.154.0 用假模型實測出來的（版本檔 v48-enforcement），
# 而且三件的症狀都是零 —— hook 每次都跑、每次都「完成」，只是什麼都沒擋：
#
#   (a) Windows 上 Codex 把 hook 指令包成 `pwsh -NoProfile -Command "<command>"`。內層腳本 `exit 2`，
#       外層 `-Command` 回報的是 **1**，Codex 把 1 當成「hook 失敗」—— 不阻斷、stderr 也不交給模型。
#       所以每一個 command hook 都要有 `commandWindows`，而且結尾要把 exit code 傳出去。
#   (b) shell 工具在 hook payload 裡叫 **`Bash`**，不是 `shell`。matcher 沒有它，經 shell 寫的檔就不掃。
#   (c) 引用的腳本要存在 —— 不存在時 hook 以 exit 1 收場，同樣是靜默的「失敗」。
#
# (b) 的工具名稱表是觀測值，不是 Codex 的合約。Codex 改名時這張表要跟著改，
# 而那一天唯一會發現的方法是重跑一次實測（不是讀文件）。
if (Test-Path $HooksFile) {
    $hooksDoc = $null
    try { $hooksDoc = Get-Content $HooksFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $hooksDoc -or -not $hooksDoc.hooks) {
        Add-V 'hooks-unparsable' $HooksFile '修正 JSON 格式 —— Codex 讀不到它時整個機械強制層都不存在，而且不會有任何提示'
    } else {
        # 腳本 → 它必須攔得到的工具名稱（實測的 hook payload tool_name）
        $mustMatch = @{
            'handoff-lint.ps1'   = @('spawn_agent')
            'dlp-gate.ps1'       = @('apply_patch', 'Bash')
            'guideline-gate.ps1' = @('apply_patch', 'Bash')
            'build-check.ps1'    = @('apply_patch')
        }
        foreach ($ev in $hooksDoc.hooks.PSObject.Properties) {
            foreach ($group in @($ev.Value)) {
                foreach ($h in @($group.hooks)) {
                    if ($h.type -ne 'command' -or -not $h.command) { continue }
                    $sm = [regex]::Match([string]$h.command, '-File\s+(\S+\.ps1)')
                    if (-not $sm.Success) { continue }
                    $script = $sm.Groups[1].Value
                    $label  = "$($ev.Name) → $(Split-Path $script -Leaf)"

                    if (-not (Test-Path $script)) {
                        Add-V 'hook-script-missing' "$label：$script" '修正路徑 —— 腳本不存在時 hook 以 exit 1 收場，Codex 當成失敗略過，什麼都不會擋'
                    }
                    $win = [string]$h.commandWindows
                    if (-not $win) {
                        Add-V 'hook-exit-code-swallowed' "$label 沒有 commandWindows" `
                              "補上 `"commandWindows`": `"$($h.command); exit `$LASTEXITCODE`" —— Windows 上 Codex 用 pwsh -Command 包一層，沒有這句 exit 2 會變成 1，阻斷與回饋全部失效"
                    } elseif ($win -notmatch ';\s*exit\s+\$LASTEXITCODE\s*$') {
                        Add-V 'hook-exit-code-swallowed' "$label 的 commandWindows 沒有以 exit `$LASTEXITCODE 結尾" `
                              "結尾加上 ; exit `$LASTEXITCODE —— 否則外層 pwsh -Command 把 exit 2 回報成 1"
                    } elseif ($win -notmatch [regex]::Escape($script)) {
                        Add-V 'hook-command-drift' "$label：commandWindows 跑的不是 $script" 'command 與 commandWindows 必須跑同一支腳本，只差結尾的 exit code 傳遞'
                    }

                    $leaf = Split-Path $script -Leaf
                    if ($mustMatch.ContainsKey($leaf)) {
                        $matcher = [string]$group.matcher
                        foreach ($tool in $mustMatch[$leaf]) {
                            $hit = $false
                            if ($matcher) { try { $hit = [regex]::IsMatch($tool, $matcher) } catch { } }
                            if (-not $hit) {
                                Add-V 'hook-matcher-misses-tool' "$label：matcher /$matcher/ 攔不到 $tool" `
                                      "matcher 加上 ^$tool$ —— Codex 回報的工具名稱是 $tool，攔不到就代表經它寫的檔完全不掃"
                            }
                        }
                    }
                }
            }
        }
    }
}

# ---- 13. 設定值的型別與範圍 ----
# 修正輪上限由 handoff-lint 每次現讀 sdlc.config.json。值寫壞時 hook 照預設 3 輪算、不擋 spawn ——
# 所以寫壞的症狀是「設了 5，還是第 3 輪就停」，而且要等到真的跑到那一輪才看得出來。這道檢查讓它在 doctor 就紅。
# update.check 同理：不認得的值照 daily 算 —— 打成 "nevr" 的人以為關掉了，其實每天連網。
# 範圍規則跟 handoff-lint 的一份相同（lint 要能獨立驗），兩邊由 test-handoff-lint.ps1 的交叉測試綁在一起；
# 這兩個常數跟 schema 由檢查 14 綁在一起。設定檔整份解析不了的情況由檢查 9 報，這裡不重複。
$ReviewRoundsRange = @(1, 5)
$UpdateCheckValues = @('daily', 'never')
if (Test-Path $ConfigFile) {
    $cfg13 = $null
    try { $cfg13 = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if ($cfg13 -is [pscustomobject] -and $cfg13.PSObject.Properties['review']) {
        $review13 = $cfg13.review
        if ($review13 -isnot [pscustomobject]) {
            Add-V 'review-config-invalid' "$ConfigFile 的 review 不是物件" '寫成 "review": { "maxRounds": 3 } —— 寫壞時 handoff-lint 照預設 3 輪算，設定等於沒生效'
        } elseif ($review13.PSObject.Properties['maxRounds']) {
            $v13 = $review13.maxRounds
            if (-not (($v13 -is [int] -or $v13 -is [long]) -and $v13 -ge $ReviewRoundsRange[0] -and $v13 -le $ReviewRoundsRange[1])) {
                Add-V 'review-max-rounds-invalid' "$ConfigFile 的 review.maxRounds 是 $(ConvertTo-Json -InputObject $v13 -Compress)" `
                      "改成 $($ReviewRoundsRange[0])–$($ReviewRoundsRange[1]) 的整數 —— 值不合法時 handoff-lint 照預設 3 輪算，設定等於沒生效"
            }
        }
    }
    if ($cfg13 -is [pscustomobject] -and $cfg13.PSObject.Properties['update'] -and $cfg13.update -is [pscustomobject] -and
        $cfg13.update.PSObject.Properties['check']) {
        $c13 = $cfg13.update.check
        if (-not ($c13 -is [string] -and $c13 -in $UpdateCheckValues)) {
            Add-V 'update-check-invalid' "$ConfigFile 的 update.check 是 $(ConvertTo-Json -InputObject $c13 -Compress)" `
                  "改成 $($UpdateCheckValues -join ' 或 ') —— 不認得的值照 daily 算，會連網檢查（pwsh .codex/scripts/sdlc.ps1 set update.check=never）"
        }
    }
}

# ---- 14. 合法值的單一來源：schema ↔ 各腳本的常數 ----
# sdlc.config.schema.json／rules.schema.json 是合法值的唯一真相：VS Code 的補全與波浪線、`sdlc.ps1 set` 的檢查、
# extension 的設定面板都讀它。但 hook（handoff-lint、guideline-gate）與這支 lint 必須在 schema 不在時照跑，
# 所以各自留了一份常數 —— 這道檢查讓每一份都跟 schema 綁在一起：只改一邊，這裡紅。
# 沒有這道檢查，下一次 Codex 多一個 effort 值，UI 會讓人選、hook 會照舊值判，而兩邊看起來都對。
# 常數用 PowerShell 的語法樹讀（不執行那幾支腳本）。
function Get-ScriptConstant([string]$file, [string]$name) {
    if (-not (Test-Path $file)) { return $null }
    $tree = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$null, [ref]$null)
    $hit = $tree.Find({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $name
    }, $true)
    if (-not $hit -or $hit.Right -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
    try { return , $hit.Right.Expression.SafeGetValue() } catch { return $null }
}
function Test-SameSet($a, $b) {
    $x = @($a | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $y = @($b | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if ($x.Count -ne $y.Count) { return $false }
    if ($x.Count -eq 0) { return $true }
    return (@(Compare-Object $x $y -CaseSensitive).Count -eq 0)
}
function Get-JsonDoc([string]$file) {
    try { return (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

$sdlcScript  = Join-Path $ScriptDir 'sdlc.ps1'
$hookScript  = Join-Path $ScriptDir 'handoff-lint.ps1'
$gateScript  = Join-Path $ScriptDir 'guideline-gate.ps1'
$schemaFix   = '兩邊改成一樣 —— schema 是 UI、sdlc.ps1 set 與編輯器讀的那一份，常數是 hook／lint 實際照著判的那一份'

$cs = $null
if (Test-Path $ConfigSchema) {
    $cs = Get-JsonDoc $ConfigSchema
    if (-not $cs) { Add-V 'schema-unparsable' $ConfigSchema '修正 JSON 格式 —— 解析不了時編輯器沒有補全、sdlc.ps1 set 無法檢查任何值' }
} elseif (Test-Path $sdlcScript) {
    Add-V 'schema-missing' $ConfigSchema '這是工具那半的檔，缺了它 sdlc.ps1 set 與 VS Code 的設定面板都無法運作 —— 重跑 update 或從發佈物補回來'
}
if ($cs) {
    $effortEnum = @($cs.definitions.effort.enum)
    $known = Get-ScriptConstant $sdlcScript 'KnownEfforts'
    if ($null -ne $known -and -not (Test-SameSet $effortEnum (@('inherit') + @($known)))) {
        Add-V 'schema-drift' "effort：schema 是 $($effortEnum -join '／')，sdlc.ps1 的 `$KnownEfforts ＋ inherit 是 $((@('inherit') + @($known)) -join '／')" $schemaFix
    }

    $mr = $cs.properties.review.properties.maxRounds
    $pairs = @(
        @{ label = 'handoff-lint.ps1 的 $MinReviewRounds';        want = $mr.minimum; got = (Get-ScriptConstant $hookScript 'MinReviewRounds') }
        @{ label = 'handoff-lint.ps1 的 $MaxAllowedReviewRounds'; want = $mr.maximum; got = (Get-ScriptConstant $hookScript 'MaxAllowedReviewRounds') }
        @{ label = 'handoff-lint.ps1 的 $DefaultReviewRounds';    want = $mr.default; got = (Get-ScriptConstant $hookScript 'DefaultReviewRounds') }
        @{ label = 'sdlc.ps1 的 $DefaultReviewRounds';            want = $mr.default; got = (Get-ScriptConstant $sdlcScript 'DefaultReviewRounds') }
        @{ label = 'agent-lint.ps1 的 $ReviewRoundsRange 下限';    want = $mr.minimum; got = $ReviewRoundsRange[0] }
        @{ label = 'agent-lint.ps1 的 $ReviewRoundsRange 上限';    want = $mr.maximum; got = $ReviewRoundsRange[1] }
    )
    foreach ($p in $pairs) {
        if ($null -ne $p.got -and [string]$p.got -ne [string]$p.want) {
            Add-V 'schema-drift' "review.maxRounds：schema 是 $($p.want)，$($p.label) 是 $($p.got)" $schemaFix
        }
    }

    $checkEnum = @($cs.properties.update.properties.check.enum)
    foreach ($p in @(
        @{ label = 'sdlc.ps1 的 $UpdateChecks'; got = (Get-ScriptConstant $sdlcScript 'UpdateChecks') }
        @{ label = 'agent-lint.ps1 的 $UpdateCheckValues'; got = $UpdateCheckValues }
    )) {
        if ($null -ne $p.got -and -not (Test-SameSet $checkEnum $p.got)) {
            Add-V 'schema-drift' "update.check：schema 是 $($checkEnum -join '／')，$($p.label) 是 $(@($p.got) -join '／')" $schemaFix
        }
    }

    $srcPattern = [string]$cs.properties.update.properties.source.pattern
    $ghPattern = Get-ScriptConstant $sdlcScript 'GitHubSourcePattern'
    if ($null -ne $ghPattern -and $srcPattern -cne ('^$|' + $ghPattern)) {
        Add-V 'schema-drift' "update.source：schema 的 pattern 是 $srcPattern，應該是 ^`$| 加上 sdlc.ps1 的 `$GitHubSourcePattern（$ghPattern）" $schemaFix
    }
}

if (Test-Path $RulesSchema) {
    $rs = Get-JsonDoc $RulesSchema
    if (-not $rs) {
        Add-V 'schema-unparsable' $RulesSchema '修正 JSON 格式 —— 解析不了時編輯器對 guidelines/rules.json 沒有任何提示'
    } else {
        $sevEnum = @($rs.definitions.rule.properties.severity.enum)
        $sev = Get-ScriptConstant $gateScript 'Severities'
        if ($null -ne $sev -and -not (Test-SameSet $sevEnum $sev)) {
            Add-V 'schema-drift' "severity：schema 是 $($sevEnum -join '／')，guideline-gate.ps1 的 `$Severities 是 $(@($sev) -join '／')" $schemaFix
        }
    }
} elseif (Test-Path $gateScript) {
    Add-V 'schema-missing' $RulesSchema '這是工具那半的檔 —— 重跑 update 或從發佈物補回來'
}

# ---- 輸出 ----
$summary = [pscustomobject]@{
    passed           = ($violations.Count -eq 0)
    subagent_count   = $agents.Count
    # 子代理 toml ＋ orchestrator（AGENTS.md）—— 這些檔的 AGENT-CORE 必須逐字相同。
    core_block_files = $docs.Count
    core_block_sync  = ($cores.Count -eq $docs.Count -and
                        ($violations | Where-Object rule -eq 'agent-core-drift').Count -eq 0)
    violation_count  = $violations.Count
    violations       = $violations
}

if ($Json) { $summary | ConvertTo-Json -Depth 4 -Compress }
else {
    if ($violations.Count -eq 0) {
        "[agent-lint] OK — $($agents.Count) subagents + orchestrator($OrchestratorFile), core block in sync, routes resolved, no dangling or stale refs."
    } else {
        [Console]::Error.WriteLine("[agent-lint] $($violations.Count) violation(s):")
        foreach ($v in $violations) {
            [Console]::Error.WriteLine("  - $($v.rule): $($v.detail)")
            [Console]::Error.WriteLine("    fix: $($v.fix)")
        }
    }
}
if ($violations.Count -gt 0) { exit 2 }
exit 0
