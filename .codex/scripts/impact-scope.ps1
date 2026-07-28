# impact-scope.ps1
# 從需求關鍵字推導「排序後的候選檔案集」，讓 impact 分析從「LLM 猜哪些檔相關」
# 變成「讀分數最高的 N 個檔」。
#
# 評分：命中 symbol table (3) > 命中檔名 (2) > 命中內容 (1)，再加 ProjectReference 鄰近度。
# 優先使用 repo-index.ps1 產生的索引；索引不存在時退化為直接搜尋。
#
# Exit: 0 = 完成；1 = 錯誤。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Keywords,
    [string]$Root = '.',
    [string]$IndexPath = 'bdd-docs/artifacts/repo-index/index.json',
    [int]$TopN = 12
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path
$excludeRe = '[\\/](bin|obj|node_modules|packages|\.git|\.vs|TestResults)[\\/]'

function ConvertTo-RelPath([string]$full) {
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
        if ($hits.Count) { Add-Score $s.file (3 * $hits.Count) ("symbol " + (($hits | Select-Object -First 3) -join ',')) }
    }
    # entrypoints 命中額外加權
    foreach ($e in $index.entrypoints) { if ($e -match $termRe) { Add-Score $e 2 'entrypoint-name' } }
}

# ---------- 2. 檔名命中（權重 2） ----------
$allFiles = @(Get-ChildItem -Path $Root -Recurse -File -Include '*.cs','*.java','*.csproj','*.json','*.sql','*.xml' -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch $excludeRe })
foreach ($f in $allFiles) {
    if ($f.BaseName -match $termRe) { Add-Score (ConvertTo-RelPath $f.FullName) 2 "filename:$($f.BaseName)" }
}

# ---------- 3. 內容命中（權重 1） ----------
foreach ($f in ($allFiles | Where-Object { $_.Extension -in '.cs', '.java', '.sql' })) {
    $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($txt -and $txt -match $termRe) {
        $n = ([regex]::Matches($txt, $termRe)).Count
        Add-Score (ConvertTo-RelPath $f.FullName) ([Math]::Min($n, 5)) "content x$n"
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
$ranked = @($scores.GetEnumerator() |
    Sort-Object { $_.Value.score } -Descending |
    Select-Object -First $TopN |
    ForEach-Object {
        [pscustomobject]@{
            file    = $_.Key
            score   = $_.Value.score
            reasons = @($_.Value.reasons | Select-Object -First 4)
        }
    })

[pscustomobject]@{
    status         = 'completed'
    keywords       = $terms
    'index-used'   = $indexUsed
    'index-note'   = if ($indexUsed) { $null } else { 'index 不存在，已退化為直接搜尋；建議先跑 repo-index.ps1' }
    'total-matched'= $scores.Count
    'returned'     = $ranked.Count
    'read-budget'  = "只讀下列 top-$TopN；不得讀清單外檔案，除非追蹤呼叫鏈必要並在回傳中說明"
    candidates     = $ranked
} | ConvertTo-Json -Depth 5
exit 0
