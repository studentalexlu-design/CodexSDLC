# lib/workspace-repos.ps1
# 工作流裝在哪幾個 git repo 上：根目錄本身，加上底下兩層內各自的 repo。gherkin-check、delivery-check、impact-scope、
# map-status（repo-index -StatusOnly）共用。
#
# 為什麼要有：前後端分成兩個 repo、工作流裝在外面那一層（workspace/backend、workspace/frontend 各有自己的 .git）時，
# 在根目錄跑 git 不是失敗（根目錄不是 repo）就是看不到東西（根目錄是 repo 的話，巢狀 repo 對它只是一個未追蹤的目錄，
# diff／ls-files／grep 都不會走進去）。兩種都不報錯 —— 靠 git 的檢查就這樣靜默地什麼都沒查。
#
# 只往下找兩層、不進建置輸出與套件目錄：巢狀 repo 是「這幾個專案」，不是 node_modules 裡某個套件自帶的 .git。

$script:RepoScanSkip = @('node_modules', 'bin', 'obj', 'packages', '.git', '.vs', 'TestResults', 'dist', 'build', 'target', 'out',
                         'bdd-docs', '.next', '.nuxt', '.svelte-kit', '.angular', '.output', '.turbo', 'coverage')

# 每個 repo 一筆：dir（完整路徑，git -C 用）、rel（相對根目錄、正斜線；根目錄自己是 ''）。
# 根目錄在某個 repo 裡（不一定是那個 repo 的頂層）也算一筆 rel = '' —— git -C 根目錄時 pathspec 與輸出都相對根目錄。
# 順序：根目錄那筆在前，其他照路徑排；找檔案屬於哪個 repo 用 Get-RepoOf（最長前綴）。
function Get-WorkspaceRepos([string]$Root) {
    $Root = $Root.TrimEnd('\', '/')
    $repos = @()
    $null = & git -C $Root rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) { $repos += [pscustomobject]@{ dir = $Root; rel = '' } }
    $level = @([IO.DirectoryInfo]::new($Root))
    $nested = @()
    for ($depth = 1; $depth -le 2 -and $level.Count; $depth++) {
        $next = @()
        foreach ($d in $level) {
            try { $subs = @($d.EnumerateDirectories()) } catch { $subs = @() }
            foreach ($s in $subs) {
                if ($s.Name -in $script:RepoScanSkip -or ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                # .git 是目錄（一般 clone）或檔案（worktree、submodule）都算
                if (Test-Path -LiteralPath (Join-Path $s.FullName '.git')) {
                    $nested += [pscustomobject]@{ dir = $s.FullName; rel = $s.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
                    continue   # repo 裡面的 repo（submodule 底下再一層）不再往下找
                }
                $next += $s
            }
        }
        $level = $next
    }
    return @($repos + @($nested | Sort-Object rel))
}

# 根目錄自己是 repo、底下沒有別的 repo —— 一般的單一 repo，舊的「在根目錄跑 git」照舊成立。
function Test-SingleRepo($repos) {
    return (@($repos).Count -eq 1 -and $repos[0].rel -eq '')
}

# 檔案（相對根目錄、正斜線）屬於哪個 repo：最長的 rel 前綴。不在任何 repo 裡回 $null。
# 回傳的 path 是相對那個 repo（git -C 它的 dir 時用的 pathspec）。
function Get-RepoOf($repos, [string]$rel) {
    $rel = $rel.Replace('\', '/').TrimStart('/')
    $best = $null
    foreach ($r in @($repos)) {
        if ($r.rel -eq '') { if (-not $best) { $best = $r } ; continue }
        if ($rel -eq $r.rel -or $rel.StartsWith("$($r.rel)/", [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $best -or $r.rel.Length -gt $best.rel.Length) { $best = $r }
        }
    }
    if (-not $best) { return $null }
    $sub = if ($best.rel -eq '') { $rel } elseif ($rel.Length -le $best.rel.Length) { '.' } else { $rel.Substring($best.rel.Length + 1) }
    return [pscustomobject]@{ repo = $best; path = $sub }
}

# 跑 git、輸出照 UTF-8 解：git 寫出來的是 UTF-8，PowerShell 卻拿 console 的 code page 解碼（zh-TW 是 cp950），
# 中文檔名與內容會變亂碼。
function Invoke-GitUtf8([string]$dir, [string[]]$gitArgs) {
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
    try { $out = @(& git -C $dir -c core.quotepath=false @gitArgs 2>$null); $code = $LASTEXITCODE }
    catch { $out = @(); $code = -1 }
    finally { if ($prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } } }
    return [pscustomobject]@{ ok = ($code -eq 0); exit = $code; lines = @($out | Where-Object { $_ }) }
}
