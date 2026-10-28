# lib/map-status.ps1
# project-map.md 的逐節失效判斷，加上「已經付過批准的東西」的清單。repo-index.ps1 -StatusOnly 用。
#
# 以前這是 sa-analyst 每次 ② 的固定步驟：每一節跑兩行 git（`git diff {sha}..HEAD -- 來源`、`git status --porcelain -- 來源`），
# 六節照字面就是 12 次工具呼叫 —— 每次一個模型回合加一次 hook 等待，而這件事完全是機械的。
# 第二行最容易漏（v4.5.1 修過的就是它：這套流程從不 commit，只跑第一行的話上一個需求的改動全部看不見），
# 現在不靠 prompt 守了。
#
# 判斷規則跟 sa-analyst 原本照做的一樣：
#   - 地圖檔頭沒有 `<!-- git-sha: … -->`、不是 git repo、或任何一行 git 失敗 → 整份地圖待驗證（只當線索、不當證據）
#   - 一節的兩行 git 任一行非空 → 那一節要重查；兩行都空 → 那一節直接採信
#   - 一節沒有「來源：」→ 判斷不了它過期了沒，當成要重查
#   - 一節有來源在 repo 裡找不到（拼錯、只寫檔名、大小寫不符、根本不是 path）→ 那一節要重查，列在 `missing`：
#     git 對不存在的 path 兩行都回空、exit 0，不擋的話那一節永遠是「沒變」—— 編出來的來源會讓它被當成證據一直採信。

function Get-MapSources([string]$body) {
    $sources = @()
    foreach ($m in [regex]::Matches($body, '(?m)^[ \t>*_-]*(?:\*\*)?來源(?:\*\*)?\s*[:：]\s*(.+)$')) {
        foreach ($tok in [regex]::Matches($m.Groups[1].Value, '[\w./\\*?\[\]{}@+~-]+')) {
            $t = ($tok.Value -replace ':\d+(-\d+)?$', '').Trim('.', '-')
            if ($t -match '[/\\.*]' -and $t -notmatch '^\.+$') { $sources += ($t -replace '\\', '/') }
        }
    }
    return @($sources | Sort-Object -Unique)
}

# 來源在 repo 裡有沒有 git 看得到的東西。大小寫要一字不差：git 的 pathspec 分大小寫，Windows／macOS 的檔案系統不分 ——
# `src/orders/` 開得到檔，`git status -- src/orders/` 卻永遠是空的。萬用字元交給 git 自己比。
function Test-MapSource([string]$root, [string]$src) {
    if ($src -match '[*?\[]') { return [bool](Invoke-GitLines $root @('ls-files', '--cached', '--others', '--exclude-standard', '--', $src)).lines.Count }
    $cur = $root
    try {
        foreach ($seg in ($src.Trim('/') -split '/')) {
            if ($seg -eq '..') { return $false }
            if (-not $seg -or $seg -eq '.') { continue }
            if (-not [IO.Directory]::Exists($cur)) { return $false }
            if (-not @([IO.Directory]::EnumerateFileSystemEntries($cur, $seg) | Where-Object { [IO.Path]::GetFileName($_) -ceq $seg }).Count) { return $false }
            $cur = Join-Path $cur $seg
        }
    } catch { return $false }
    return $true
}

function Invoke-GitLines([string]$root, [string[]]$gitArgs) {
    $out = & git -C $root @gitArgs 2>$null
    return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); lines = @($out | Where-Object { $_ }) }
}

function Get-MapStatus {
    param([string]$Root, [bool]$IsGit, [string]$MapRel = 'bdd-docs/project-map.md', [string]$DocsRel = 'bdd-docs')
    $map = [ordered]@{ exists = $false; path = $MapRel; git_sha = $null; whole_map_unverified = $true; reason = 'missing'; sections = @() }
    $mapFull = Join-Path $Root $MapRel
    if (Test-Path -LiteralPath $mapFull -PathType Leaf) {
        $text = [IO.File]::ReadAllText($mapFull)
        $map.exists = $true
        $m = [regex]::Match($text, '<!--\s*git-sha:\s*([0-9a-fA-F]{7,40})\s*-->')
        if ($m.Success) { $map.git_sha = $m.Groups[1].Value }
        $map.reason = if (-not $map.git_sha) { 'no-git-sha' } elseif (-not $IsGit) { 'not-a-git-repo' } else { $null }

        $parts = [regex]::Split(($text -replace "`r`n", "`n"), '(?m)^(?=## )')
        $failed = $false
        $sections = @()
        foreach ($p in $parts) {
            if ($p -notmatch '^## ') { continue }
            $title = ($p -split "`n", 2)[0].Substring(3).Trim()
            $src = @(Get-MapSources $p)
            $sec = [ordered]@{ title = $title; sources = $src; stale = $true; changed = @(); missing = @() }
            if (-not $src.Count) { $sec.note = 'no-sources' }
            elseif (-not $map.reason) {
                $committed = Invoke-GitLines $Root (@('diff', '--name-only', "$($map.git_sha)..HEAD", '--') + $src)
                $pending   = Invoke-GitLines $Root (@('status', '--porcelain', '--untracked-files=all', '--') + $src)
                if (-not $committed.ok -or -not $pending.ok) { $failed = $true }
                $changed = @($committed.lines) + @($pending.lines | ForEach-Object { $_.Substring([Math]::Min(3, $_.Length)) })
                $sec.missing = @($src | Where-Object { -not (Test-MapSource $Root $_) })
                $sec.stale = ($changed.Count -gt 0 -or $sec.missing.Count -gt 0)
                $sec.changed = @($changed | Sort-Object -Unique | Select-Object -First 5)
            }
            $sections += [pscustomobject]$sec
        }
        if ($failed) { $map.reason = 'git-error' }
        # 一節都解析不出來（沒有用 `## ` 分節）：不是「沒有東西過期」，是判斷不了 —— 整份待驗證。
        if (-not $sections.Count -and -not $map.reason) { $map.reason = 'no-sections' }
        $map.whole_map_unverified = [bool]$map.reason
        $map.sections = $sections
    }

    # 已經花掉一次使用者批准、一次 live 連線換來的東西 —— 跨 feature，不必等 handoff 帶。
    # 用 .NET 列檔、先判斷目錄在不在：`Get-ChildItem -Path <不存在> -Recurse` 會把最後一段當成名稱，從上一層整棵樹遞迴去找
    # （沒有 bdd-docs/ 的專案，這一行就白走一遍整個 repo）。
    $evidence = @()
    $docsFull = Join-Path $Root $DocsRel
    if ([IO.Directory]::Exists($docsFull)) {
        $evFiles = @([IO.Directory]::EnumerateFiles($docsFull, 'db-*.md', [IO.SearchOption]::AllDirectories) |
                     Where-Object { [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($_)) -eq 'evidence' } | Sort-Object | Select-Object -First 100)
        foreach ($f in $evFiles) {
            $titles = @([regex]::Matches([IO.File]::ReadAllText($f), '(?m)^##\s+(\d{4}-\d{2}-\d{2}\s*——.+?)\s*$') |
                        ForEach-Object { $_.Groups[1].Value } | Select-Object -First 30)
            $evidence += [pscustomobject]@{ path = ($f.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'); sections = $titles }
        }
    }
    $legacy = @()
    $legacyFull = Join-Path $Root "$DocsRel/artifacts/legacy-schema"
    if ([IO.Directory]::Exists($legacyFull)) {
        foreach ($f in @([IO.Directory]::EnumerateFiles($legacyFull, '*.sql') | Sort-Object | Select-Object -First 300)) {
            $first = ''
            try { $first = [IO.File]::ReadLines($f) | Select-Object -First 1 } catch { }
            $c = [regex]::Match([string]$first, '--\s*captured:\s*(\d{4}-\d{2}-\d{2})(?:\s*\|\s*object:\s*(\S+))?')
            $legacy += [pscustomobject]@{
                path     = ($f.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/')
                captured = if ($c.Success) { $c.Groups[1].Value } else { $null }
                object   = if ($c.Success -and $c.Groups[2].Success) { $c.Groups[2].Value } else { $null }
            }
        }
    }
    return [pscustomobject]@{ project_map = [pscustomobject]$map; evidence = $evidence; legacy_schema = $legacy }
}
