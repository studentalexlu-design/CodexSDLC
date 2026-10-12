# lib/source-files.ps1
# 一次走完工作區，排除的目錄不進去。repo-index 與 impact-scope 共用。
#
# 以前 repo-index 對每一種檔各跑一次 `Get-ChildItem -Recurse -Filter`（11 次），每次都走完整棵樹，
# **先走進 node_modules／bin／obj 才濾掉**：這個 repo（node_modules 1.3 萬個檔）`-StatusOnly` 要 6 秒，
# 走一次、排除的目錄不進去只要 0.2 秒；舊 .NET 專案每個專案都有大的 bin／obj，只會更慢。
#
# 不用 `git ls-files`：它照 .gitignore 篩，被忽略但不在排除清單裡的檔（例：被忽略的 appsettings.Development.json）
# 會從索引消失 —— 索引的內容就跟著變了。這裡跟舊的 `Get-ChildItem -Recurse -File`（不帶 -Force）是同一個集合、同一個順序：
# 跳過隱藏項目、不跟進目錄的符號連結；每個目錄先列它自己的檔、再依序走進子目錄。
# 排除只看「工作區底下」的目錄名 —— 舊寫法拿完整路徑比對，repo 放在 C:\build\ 底下時整個 repo 都被濾掉。

function Get-WorkspaceFiles {
    param([string]$Root, [string[]]$ExcludeDirs)
    $exclude = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $ExcludeDirs) { [void]$exclude.Add($d) }
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $stack.Push([IO.DirectoryInfo]::new($Root))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $subdirs = [Collections.Generic.List[IO.DirectoryInfo]]::new()
        try {
            foreach ($e in $dir.EnumerateFileSystemInfos()) {
                if ($e.Attributes -band [IO.FileAttributes]::Hidden) { continue }
                if ($e -is [IO.DirectoryInfo]) {
                    if ($exclude.Contains($e.Name)) { continue }
                    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $subdirs.Add($e)
                } else {
                    $files.Add([IO.FileInfo]$e)
                }
            }
        } catch { }   # 讀不到的目錄（權限）跳過，跟 Get-ChildItem -ErrorAction SilentlyContinue 一樣
        for ($i = $subdirs.Count - 1; $i -ge 0; $i--) { $stack.Push($subdirs[$i]) }
    }
    return , $files
}

# 依檔名樣式（跟 -Filter 一樣的萬用字元、不分大小寫）挑出來，保持走訪順序。
# foreach 迴圈，不用 Where-Object：一萬個檔 × 十幾種樣式時，腳本區塊的呼叫成本比走訪本身還大。
function Select-WorkspaceFiles {
    param($Files, [string[]]$Patterns)
    $wild = @($Patterns | ForEach-Object { [Management.Automation.WildcardPattern]::new($_, [Management.Automation.WildcardOptions]::IgnoreCase) })
    $out = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($f in $Files) { foreach ($w in $wild) { if ($w.IsMatch($f.Name)) { $out.Add($f); break } } }
    return $out.ToArray()
}

# 「相對 Root、正斜線」—— 走訪出來的檔一定在 Root 底下，直接切掉前綴（逐檔跑 -replace 在幾千個檔上看得出來）。
function Get-WorkspaceRelPath([string]$Root, [string]$Full) {
    return $Full.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
}
