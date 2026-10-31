# impact-scope.ps1
# 從需求關鍵字推導「排序後的候選檔案集」，讓 impact 分析從「LLM 猜哪些檔相關」
# 變成「讀分數最高的 N 個檔」。
#
# 評分：命中 symbol table (3) > 命中檔名 (2) > 命中內容 (1)，再加 ProjectReference 鄰近度。
# 關鍵字命中介面名時，實作它的檔與註冊它的檔也一起排進來 —— 那兩處正是擴充點所在，
# 而它們的檔名通常跟需求關鍵字完全不同，純靠檔名／內容比對排不出來。
# 優先使用 repo-index.ps1 產生的索引；索引不存在時退化為直接搜尋。
#
# 內容命中只算會被編譯的程式碼（lib/active-code.ps1）：只在註解、TODO 或註解掉的舊碼裡提到關鍵字的檔不加分。
# 讀者只讀前 N 名，一個整檔都是註解的舊實作排上去，就佔掉一個真的實作的位置。
#
# 每個候選檔帶著索引裡它的 `types`、`bases` 與 DI 註冊（`registered`：誰把它掛上去；`registers`：它掛了什麼）。
# 「有沒有現成的擴充點」「實作有沒有真的被掛上去」多半在這裡就答得出來 —— sa-analyst 不必去讀 index.json
# （2,000 檔的專案就近 1 MB，模型讀不下）。
#
# 內容比對在 git repo 裡先用 `git grep` 篩出有關鍵字的檔，只對那些檔讀全文、剝註解、計分；以前每次都把每個
# .cs／.java／.sql 讀一遍。非 git 照舊逐檔讀。工作區底下有好幾個 repo（前後端分開）時每個各 grep 一次。
#
# Exit: 0 = 完成；1 = 錯誤。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Keywords,
    [string]$Root = '.',
    [string]$IndexPath = 'bdd-docs/.cache/index.json',
    [int]$TopN = 12
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

. (Join-Path $PSScriptRoot 'lib/active-code.ps1')
. (Join-Path $PSScriptRoot 'lib/source-files.ps1')
. (Join-Path $PSScriptRoot 'lib/node-project.ps1')
. (Join-Path $PSScriptRoot 'lib/workspace-repos.ps1')
$Root = (Resolve-Path $Root).Path
$excludeDirs = @('bin', 'obj', 'node_modules', 'packages', '.git', '.vs', 'TestResults') + $script:NodeGeneratedDirs

function ConvertTo-RelPath([string]$full) {
    if ($full.StartsWith($Root, [StringComparison]::Ordinal)) { return $full.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
    ($full -replace [regex]::Escape($Root), '').TrimStart('\', '/') -replace '\\', '/'
}

# 正規化：透過 `pwsh -File` 呼叫時，陣列參數會被當成單一字串傳入
# （例：-Keywords 'A','B' → 一個元素 "'A','B'"）。統一拆逗號並去引號。
$terms = @(
    $Keywords |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim().Trim("'", '"').Trim() } |
        Where-Object { $_ } |
        Sort-Object -Unique
)
if (-not $terms) { Write-Error 'Keywords required'; exit 1 }
$termRe = ($terms | ForEach-Object { [regex]::Escape($_) }) -join '|'

$scores = @{}   # relPath -> [pscustomobject]@{ score; reasons }
function Add-Score([string]$path, [int]$pts, [string]$reason) {
    if (-not $path) { return }
    if (-not $scores.ContainsKey($path)) {
        $scores[$path] = [pscustomobject]@{ score = 0; reasons = New-Object System.Collections.ArrayList }
    }
    $scores[$path].score += $pts
    if ($scores[$path].reasons -notcontains $reason) { [void]$scores[$path].reasons.Add($reason) }
}

# ---------- 1. 索引：symbol 命中（權重 3） ----------
$index = $null
$indexUsed = $false
if (Test-Path $IndexPath) {
    try { $index = Get-Content $IndexPath -Raw | ConvertFrom-Json; $indexUsed = $true } catch { }
}

if ($indexUsed -and $index.symbols) {
    foreach ($s in $index.symbols) {
        $hits = @()
        foreach ($t in $s.types)   { if ($t   -match $termRe) { $hits += "type:$t" } }
        foreach ($m in $s.methods) { if ($m   -match $termRe) { $hits += "method:$m" } }
        # bases 的形狀是 "Impl : Base1, Base2" —— 只比對冒號右邊，左邊已由 types 計分過
        foreach ($b in $s.bases) {
            $rhs = ($b -split ' : ', 2)[-1]
            if ($rhs -match $termRe) { $hits += "implements:$rhs" }
        }
        if ($hits.Count) { Add-Score $s.file (3 * $hits.Count) ("symbol " + (($hits | Select-Object -First 3) -join ',')) }
    }
    # entrypoints 命中額外加權
    foreach ($e in $index.entrypoints) { if ($e -match $termRe) { Add-Score $e 2 'entrypoint-name' } }
    # DI 註冊命中：實作有沒有真的被掛上去，只有註冊處看得到
    foreach ($d in $index.'di-registrations') {
        if ("$($d.service) $($d.impl)" -match $termRe) { Add-Score $d.file 2 "di:$($d.kind)<$($d.service)>" }
    }
}

# ---------- 2. 檔名命中（權重 2） ----------
# 整棵樹只走一次，排除的目錄不進去（lib/source-files.ps1）。
$workspace = Get-WorkspaceFiles -Root $Root -ExcludeDirs $excludeDirs
$allFiles = @(Select-WorkspaceFiles -Files $workspace -Patterns '*.cs', '*.java', '*.csproj', '*.json', '*.sql', '*.xml')
# 前端的原始碼只算 package.json 底下的（同 repo-index）：wwwroot/lib 的 jquery.js 不是這個專案寫的，命中了只是佔掉前幾名。
$nodeDirs = @($workspace | Where-Object { $_.Name -eq 'package.json' } | ForEach-Object { $_.DirectoryName })
$jsFiles = @(if ($nodeDirs.Count) {
    $workspace | Where-Object {
        $full = $_.FullName
        $_.Name -match $script:NodeSourceRe -and $_.Name -notmatch $script:NodeIgnoredRe -and
            @($nodeDirs | Where-Object { $full.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count
    }
})
$allFiles += $jsFiles
foreach ($f in $allFiles) {
    if ($f.BaseName -match $termRe) { Add-Score (ConvertTo-RelPath $f.FullName) 2 "filename:$($f.BaseName)" }
}

# ---------- 3. 內容命中（權重 1） ----------
$contentFiles = @($allFiles | Where-Object { $_.Extension -in '.cs', '.java', '.sql' }) + $jsFiles

# git repo：先用 git grep 篩出「有任一個關鍵字」的檔，只讀那些。-F 逐詞（避開 PowerShell regex 與 git ERE 的語法差異）、
# -i 跟 -match 一樣不分大小寫；--untracked 一定要 —— 這套流程不 commit，上一個需求新增的檔全是未追蹤的；
# --no-exclude-standard 讓被 .gitignore 掉、但不在排除目錄裡的檔照樣算（跟逐檔讀的集合一樣），最後再跟走訪的結果取交集。
# git grep 讀不到 UTF-16（SSMS 舊版存 .sql 的預設），所以帶 UTF-16 BOM 的 .sql 另外補回來，照舊逐檔讀。
# 工作區底下每個 repo 各 grep 一次（lib/workspace-repos.ps1）：根目錄的 git grep 不會走進巢狀 repo，前後端分成兩個 repo 時
# 等於什麼都沒搜到 —— 而且不報錯。不在任何一個 grep 成功的 repo 裡的檔，照舊逐檔讀。
$grepHits = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$grepped = @()
$wsRepos = @(Get-WorkspaceRepos $Root)
foreach ($repo in $wsRepos) {
    $gitArgs = @('grep', '-l', '-i', '-F', '--untracked', '--no-exclude-standard')
    foreach ($term in $terms) { $gitArgs += @('-e', $term) }
    $gitArgs += @('--', '*.cs', '*.java', '*.sql')
    if ($jsFiles.Count) { $gitArgs += @('*.ts', '*.tsx', '*.mts', '*.cts', '*.js', '*.jsx', '*.mjs', '*.cjs', '*.vue', '*.svelte') }
    $out = Invoke-GitUtf8 $repo.dir $gitArgs
    if ($out.exit -ne 0 -and $out.exit -ne 1) { continue }   # 0 = 有命中、1 = 沒有命中；其他是錯誤 → 這個 repo 退回逐檔讀
    $grepped += $repo
    $prefix = if ($repo.rel) { "$($repo.rel)/" } else { '' }
    foreach ($l in $out.lines) { [void]$grepHits.Add($prefix + ($l -replace '\\', '/')) }
}
if ($grepped.Count) {
    $contentFiles = @($contentFiles | Where-Object {
        $rel = ConvertTo-RelPath $_.FullName
        if ($grepHits.Contains($rel)) { return $true }
        $owner = Get-RepoOf $wsRepos $rel
        if (-not $owner -or $owner.repo.dir -notin $grepped.dir) { return $true }   # 不在任何 repo 裡、或那個 repo 的 grep 失敗：逐檔讀
        if ($_.Extension -ne '.sql' -or $_.Length -lt 2) { return $false }
        $b = [byte[]]::new(2)
        try { $s = [IO.File]::OpenRead($_.FullName); try { [void]$s.Read($b, 0, 2) } finally { $s.Dispose() } } catch { return $false }
        return (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF))
    })
}

foreach ($f in $contentFiles) {
    $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    # 先用原文篩（便宜），命中了才剝註解再算 —— 多數檔一個關鍵字都沒有，不必替它們付剝註解的成本。
    if ($txt -and $txt -match $termRe) {
        $txt = Get-ActiveCode $txt $f.Extension
        if ($txt -match $termRe) {
            $n = ([regex]::Matches($txt, $termRe)).Count
            Add-Score (ConvertTo-RelPath $f.FullName) ([Math]::Min($n, 5)) "content x$n"
        }
    }
}

# ---------- 4. ProjectReference 鄰近度 ----------
if ($indexUsed -and $index.projects) {
    $hotProjects = @()
    foreach ($p in $index.projects) {
        $dir = Split-Path $p.path -Parent
        if ($scores.Keys | Where-Object { $_ -like "$dir/*" }) { $hotProjects += $p.name }
    }
    foreach ($p in $index.projects) {
        if ($p.name -in $hotProjects) { continue }
        $touches = @($p.'project-refs' | Where-Object { $_ -in $hotProjects })
        if ($touches.Count) {
            $dir = Split-Path $p.path -Parent
            foreach ($k in @($scores.Keys | Where-Object { $_ -like "$dir/*" })) {
                Add-Score $k 1 "depends-on:$($touches -join ',')"
            }
        }
    }
}

# ---------- 輸出 ----------
# 每個候選檔帶著索引裡它自己的那一份：types／bases，以及 DI —— registered = 誰把這個檔的型別掛上去（服務或實作是它），
# registers = 這個檔自己掛了什麼（組合根）。沒有索引就只有 file／score／reasons。
$symByFile = @{}
if ($indexUsed) { foreach ($s in @($index.symbols)) { $symByFile[$s.file] = $s } }
function Get-DiText($d) { if ($d.impl) { "$($d.kind)<$($d.service), $($d.impl)>" } else { "$($d.kind) $($d.service)" } }

$ranked = @($scores.GetEnumerator() |
    Sort-Object { $_.Value.score } -Descending |
    Select-Object -First $TopN |
    ForEach-Object {
        $c = [ordered]@{
            file    = $_.Key
            score   = $_.Value.score
            reasons = @($_.Value.reasons | Select-Object -First 4)
        }
        if ($indexUsed) {
            $s = $symByFile[$_.Key]
            if ($s) {
                $c.types = @($s.types | Select-Object -First 5)
                if ($s.bases) { $c.bases = @($s.bases | Select-Object -First 5) }
                $names = @($s.types | ForEach-Object { ($_ -split '\s+')[-1] })
                $reg = @($index.'di-registrations' | Where-Object { $_.file -ne $c.file -and ($_.service -in $names -or $_.impl -in $names) } |
                         Select-Object -First 3 | ForEach-Object { "$(Get-DiText $_) @ $($_.file)" })
                if ($reg.Count) { $c.registered = $reg }
            }
            $own = @($index.'di-registrations' | Where-Object { $_.file -eq $c.file } | Select-Object -First 5 | ForEach-Object { Get-DiText $_ })
            if ($own.Count) { $c.registers = $own }
        }
        [pscustomobject]$c
    })

[pscustomobject]@{
    status         = 'completed'
    keywords       = $terms
    'index-used'   = $indexUsed
    'index-note'   = if ($indexUsed) { $null } else { 'index 不存在，已退化為直接搜尋（候選檔不帶 types／bases／DI）；建議先跑 repo-index.ps1' }
    'content-scan' = if ($grepped.Count) { 'git-grep' } else { 'read-all' }
    'total-matched'= $scores.Count
    'returned'     = $ranked.Count
    'read-budget'  = "只讀下列 top-$TopN；不得讀清單外檔案，除非追蹤呼叫鏈必要並在回傳中說明"
    candidates     = $ranked
} | ConvertTo-Json -Depth 5
exit 0
