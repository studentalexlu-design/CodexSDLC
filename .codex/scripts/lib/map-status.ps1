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
#   - 工作區底下有好幾個 repo（lib/workspace-repos.ps1）：每個來源在它所屬的 repo 裡、用檔頭裡那個 repo 的 sha 算；
#     檔頭沒有那個 repo 的 sha → 那一節要重查，列在 `no_sha`。該寫的檔頭由 `head_header` 給。
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
# $own：Get-RepoOf 的結果（來源屬於哪個 repo、相對那個 repo 的 path）—— 萬用字元要在那個 repo 裡讓 git 比。
function Test-MapSource([string]$root, [string]$src, $own) {
    if ($src -match '[*?\[]') { return [bool]($own -and (Invoke-GitLines $own.repo.dir @('ls-files', '--cached', '--others', '--exclude-standard', '--', $own.path)).lines.Count) }
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

# 檔頭的 sha。單一 repo：`<!-- git-sha: {sha} -->`。工作區底下有好幾個 repo（前後端分開、工作流裝在外層）時每個 repo 各一個：
# `<!-- git-sha: .={sha} backend={sha} frontend={sha} -->`（`.` 是根目錄自己那個 repo）—— 各 repo 的 HEAD 互不相干，
# 一個 sha 只算得了其中一個的 diff。回傳 key（相對根目錄的 repo 目錄；單一 sha 是 '.'）→ sha。
function Read-MapShas([string]$text) {
    $shas = [ordered]@{}
    $m = [regex]::Match($text, '<!--\s*git-sha:\s*(.*?)\s*-->')
    if (-not $m.Success) { return $shas }
    $v = $m.Groups[1].Value
    if ($v -match '^[0-9a-fA-F]{7,40}$') { $shas['.'] = $v; return $shas }
    foreach ($p in [regex]::Matches($v, '([^\s=]+)=([0-9a-fA-F]{7,40})(?=\s|$)')) { $shas[$p.Groups[1].Value.Trim('/')] = $p.Groups[2].Value }
    return $shas
}

# 現在寫進檔頭的那一行（sa-analyst 六節全驗過時照抄，不必自己對每個 repo 跑 rev-parse）。
# 還沒有 commit 的 repo 不列 —— 它底下的節每次都判過期，方向是安全的。
function Get-MapHeadHeader($repos) {
    $pairs = @(foreach ($r in @($repos)) {
        $h = @((Invoke-GitLines $r.dir @('rev-parse', 'HEAD')).lines) | Select-Object -First 1
        if ($h) { [pscustomobject]@{ key = $(if ($r.rel) { $r.rel } else { '.' }); sha = $h } }
    })
    if (-not $pairs.Count) { return $null }
    if (Test-SingleRepo $repos) { return "<!-- git-sha: $($pairs[0].sha) -->" }
    return "<!-- git-sha: $(@($pairs | ForEach-Object { "$($_.key)=$($_.sha)" }) -join ' ') -->"
}

function Get-MapStatus {
    param([string]$Root, [string]$MapRel = 'bdd-docs/project-map.md', [string]$DocsRel = 'bdd-docs')
    $repos = @(Get-WorkspaceRepos $Root)
    $map = [ordered]@{ exists = $false; path = $MapRel; git_sha = $null; head_header = (Get-MapHeadHeader $repos); whole_map_unverified = $true; reason = 'missing'; sections = @() }
    $mapFull = Join-Path $Root $MapRel
    if (Test-Path -LiteralPath $mapFull -PathType Leaf) {
        $text = [IO.File]::ReadAllText($mapFull)
        $map.exists = $true
        $shas = Read-MapShas $text
        if ($shas.Count) { $map.git_sha = $(if ($shas.Contains('.') -and $shas.Count -eq 1) { $shas['.'] } else { @($shas.Keys | ForEach-Object { "$_=$($shas[$_])" }) -join ' ' }) }
        $map.reason = if (-not $shas.Count) { 'no-git-sha' } elseif (-not $repos.Count) { 'not-a-git-repo' } else { $null }

        $parts = [regex]::Split(($text -replace "`r`n", "`n"), '(?m)^(?=## )')
        $failed = $false
        $sections = @()
        foreach ($p in $parts) {
            if ($p -notmatch '^## ') { continue }
            $title = ($p -split "`n", 2)[0].Substring(3).Trim()
            $src = @(Get-MapSources $p)
            $sec = [ordered]@{ title = $title; sources = $src; stale = $true; changed = @(); missing = @(); no_sha = @() }
            if (-not $src.Count) { $sec.note = 'no-sources' }
            elseif (-not $map.reason) {
                # 來源照所屬的 repo 分組，每個 repo 跑一次 —— 在那個 repo 裡、用那個 repo 的 sha。
                # 檔頭沒有那個 repo 的 sha（或來源不在任何 repo 裡）→ 列在 no_sha，那一節判過期。
                $groups = [ordered]@{}
                $owners = @{}
                foreach ($s in $src) {
                    $own = Get-RepoOf $repos $s
                    $owners[$s] = $own
                    $key = if (-not $own) { $null } elseif ($own.repo.rel) { $own.repo.rel } else { '.' }
                    if (-not $key -or -not $shas.Contains($key)) { $sec.no_sha += $s; continue }
                    if (-not $groups.Contains($key)) { $groups[$key] = [pscustomobject]@{ repo = $own.repo; sha = $shas[$key]; paths = @() } }
                    $groups[$key].paths += $own.path
                }
                $changed = @()
                foreach ($g in $groups.Values) {
                    $committed = Invoke-GitLines $g.repo.dir (@('diff', '--name-only', "$($g.sha)..HEAD", '--') + $g.paths)
                    $pending   = Invoke-GitLines $g.repo.dir (@('status', '--porcelain', '--untracked-files=all', '--') + $g.paths)
                    if (-not $committed.ok -or -not $pending.ok) { $failed = $true }
                    $prefix = if ($g.repo.rel) { "$($g.repo.rel)/" } else { '' }
                    $changed += @(@($committed.lines) + @($pending.lines | ForEach-Object { $_.Substring([Math]::Min(3, $_.Length)) }) | ForEach-Object { "$prefix$_" })
                }
                $sec.missing = @($src | Where-Object { -not (Test-MapSource $Root $_ $owners[$_]) })
                $sec.stale = ($changed.Count -gt 0 -or $sec.missing.Count -gt 0 -or $sec.no_sha.Count -gt 0)
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
