# active-code.ps1
# 由 repo-index／impact-scope／sql-scan dot-source：把原始碼裡「不會被編譯、不會被執行」的部分拿掉 ——
# 註解，以及 C# 的 `#if false` 區塊。三支腳本都是 regex 比對，不先剝掉的話，舊專案裡被註解掉的東西會被當成現役：
#
#   //services.AddScoped<IFoo, OldFoo>();     → 索引說 OldFoo 被註冊了（DI 那條樣式沒有錨在行首）
#   /* public class OldFoo : IFoo { … } */   → 索引說 OldFoo 實作了 IFoo
#   #if false … #endif                        → 索引說那幾個方法存在
#   SP 裡 /* IF EXISTS (…) */ 的舊規則       → sql-scan 把它報成邏輯訊號，單行 context 看不出它在註解裡
#
# 而 sa-analyst 被要求「索引查得到就直接採用、不必開檔」—— 唯一看得到那個 // 的動作被省掉了。
#
# 為什麼不是一行 regex：字串裡的 "*/*"、"image/*"、"http://…"、SQL 的 '--' 會被當成註解的開頭，把後面真的
# 程式碼一起吃掉。所以這裡是一個認得字串的掃描器：同一條樣式裡先認字串、再認註解，字串原樣跳過。
#
# **行數不變**：行註解刪掉（它不含換行），區塊註解換成等長的空白、換行原樣保留。sql-scan 靠行號把剝過的那一行
# 跟原文對齊，`^\s*public` 這類錨在行首的樣式也照舊成立；`public/**/class` 不會黏成一個字。
#
# 只認字面上的 `#if false`／`#if true`：`#if 某符號` 有沒有編進去要看專案檔的 DefineConstants，這裡不猜。
# SQL 的區塊註解照 T-SQL 可以巢狀（`/* … /* … */ … */` 整段都是註解）—— 註解掉一段本身就含 `/* */` 的 SP，
# 在 SQL Server 上是常態。MySQL／Oracle 不巢狀，但在那兩邊這種寫法本來就是語法錯誤。
# 已知的不精確：C# 內插字串的 `{…}` 裡又有含 `//` 的字串時，那一行後面的部分會被當成註解（只影響那一行）。
#
# 為什麼是共用檔（其餘腳本的小段重複都是各留一份）：三支腳本對「什麼是註解」必須是同一個答案。
# 分岔的症狀是靜默的 —— 索引說那個類別不存在，impact-scope 卻還因為註解裡的關鍵字把它排進前幾名。

# 每條樣式都是：\G（緊接上一個命中）＋ 一段不含註解的程式碼（atomic，字串在裡面整段吃掉、不回頭）＋ 一個註解。
# 沒有下一個註解時比對失敗、Replace 就停 —— 所以每個命中都是一個註解，字串不會各自成為一次命中。
$script:ActiveCodeLexers = @{
    # C#／Java／Gradle：verbatim（@"…"、$@"…"、@$"…"）、raw／text block（"""…"""）、一般字串、字元常值
    c = [regex]::new(@'
\G(?<code>(?>(?:
    [^/"'@]+
  | /(?![/*])
  | @\$?"(?:[^"]|"")*"
  | (?<q>"{3,})[\s\S]*?\k<q>
  | "(?:\\.|[^"\\\r\n])*"
  | '(?:\\.|[^'\\\r\n])*'
  | ["'@]
)*))(?<comment>(?<line>//[^\r\n]*)|(?<block>/\*[\s\S]*?(?:\*/|\z)))
'@, 'IgnorePatternWhitespace')

    # JS／TS（含 .vue／.svelte 整檔）：一般字串、樣板字串（`…` 整段吃掉，不追進 ${} 裡）。
    # 已知的不精確：regex 常值裡的 `//`、`/*`（如 /\/\//）會被當成註解開頭；SFC 的 HTML 註解 `<!-- -->` 不剝。
    js = [regex]::new(@'
\G(?<code>(?>(?:
    [^/"'`]+
  | /(?![/*])
  | `(?:\\.|[^`\\])*`
  | "(?:\\.|[^"\\\r\n])*"
  | '(?:\\.|[^'\\\r\n])*'
  | ["'`]
)*))(?<comment>(?<line>//[^\r\n]*)|(?<block>/\*[\s\S]*?(?:\*/|\z)))
'@, 'IgnorePatternWhitespace')

    # SQL：'…'（'' 跳脫）、"識別字"、[識別字]；區塊註解可巢狀（平衡群組）
    sql = [regex]::new(@'
\G(?<code>(?>(?:
    [^-/'"\[]+
  | -(?!-)
  | /(?!\*)
  | '(?:[^']|'')*'
  | "(?:[^"]|"")*"
  | \[(?:[^\]]|\]\])*\]
  | ['"\[]
)*))(?<comment>(?<line>--[^\r\n]*)|(?<block>/\*(?>(?:(?!/\*|\*/)[\s\S])+|/\*(?<d>)|\*/(?<-d>))*(?:(?(d)(?!))\*/|\z)))
'@, 'IgnorePatternWhitespace')

    # XML（MyBatis mapper、csproj、pom.xml）：CDATA 是內容不是註解
    xml = [regex]::new(@'
\G(?<code>(?>(?:
    [^<]+
  | <!\[CDATA\[[\s\S]*?(?:\]\]>|\z)
  | <(?!!--)
)*))(?<comment>(?<block><!--[\s\S]*?(?:-->|\z)))
'@, 'IgnorePatternWhitespace')
}

$script:ActiveCodeLexerByExt = @{
    '.cs' = 'c'; '.java' = 'c'; '.gradle' = 'c'; '.kts' = 'c'
    '.ts' = 'js'; '.tsx' = 'js'; '.mts' = 'js'; '.cts' = 'js'; '.js' = 'js'; '.jsx' = 'js'; '.mjs' = 'js'; '.cjs' = 'js'
    '.vue' = 'js'; '.svelte' = 'js'
    '.sql' = 'sql'
    '.xml' = 'xml'; '.csproj' = 'xml'
}

$script:ActiveCodeBlank = [regex]::new('[^\r\n]')
$script:ActiveCodeBlankComment = [Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $m.Groups['code'].Value + $script:ActiveCodeBlank.Replace($m.Groups['comment'].Value, ' ')
}

# 回傳「會被編譯、會被執行」的那一份：註解（與 C# 的 #if false 區塊）拿掉，其餘逐字不變、行數不變。
# 不認得的副檔名原樣回傳。
#
# 分兩趟是為了速度：第一趟用替換字串把行註解刪掉、區塊註解原樣放回 —— 整趟在 .NET 裡跑完，不叫 PowerShell；
# 第二趟只剩區塊註解，evaluator 一個一個換成空白。實測 800 個每個方法都帶 `///` 的 C# 檔：一個註解叫一次
# evaluator 讓 repo-index 多花三成時間，分兩趟之後約兩成 —— 行註解正是佔多數的那一種。
function Get-ActiveCode([string]$Text, [string]$Extension) {
    if (-not $Text) { return $Text }
    $kind = $script:ActiveCodeLexerByExt[$Extension]
    if (-not $kind) { return $Text }
    $re = $script:ActiveCodeLexers[$kind]
    $out = $re.Replace($re.Replace($Text, '${code}${block}'), $script:ActiveCodeBlankComment)
    if ($Extension -eq '.cs') { $out = Remove-InactiveCSharp $out }
    return $out
}

# C# 的 #if／#elif／#else／#endif。編譯器根本不看 `#if false` 裡的東西，那跟註解掉是同一件事。
# 只有「確定不會編進去」的分支才換成空白：字面上的 false，或前面已經有字面上的 true 的那些分支。
# 呼叫前註解已經剝掉了，所以 `#if false // 舊版` 的條件就是 false。指示詞那一行本身原樣留著。
# 一律分大小寫：C# 的指示詞與 true／false 都是小寫，`#if TRUE` 的 TRUE 是一個（多半沒定義的）符號。
function Remove-InactiveCSharp([string]$text) {
    if ($text -cnotmatch '(?m)^[ \t]*#[ \t]*(?:if|elif)\b[ \t(]*(?:true|false)\b') { return $text }
    $lines = $text -split '(?<=\n)'
    $frames = [Collections.Generic.Stack[hashtable]]::new()
    $dead = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -cmatch '^[ \t]*#[ \t]*(if|elif|else|endif)\b(.*)') {
            $kw = $Matches[1]
            $lit = if ($Matches[2].Trim() -cmatch '^\(?\s*(true|false)\s*\)?$') { $Matches[1] } else { $null }
            switch ($kw) {
                'if'    { $frames.Push(@{ outer = $dead; taken = ($lit -eq 'true'); dead = ($lit -eq 'false') }) }
                'elif'  { if ($frames.Count) { $f = $frames.Peek(); $f.dead = $f.taken -or ($lit -eq 'false'); $f.taken = $f.taken -or ($lit -eq 'true') } }
                'else'  { if ($frames.Count) { $f = $frames.Peek(); $f.dead = $f.taken } }
                'endif' { if ($frames.Count) { [void]$frames.Pop() } }
            }
            $dead = $frames.Count -gt 0 -and ($frames.Peek().outer -or $frames.Peek().dead)
            continue
        }
        if ($dead) { $lines[$i] = $script:ActiveCodeBlank.Replace($lines[$i], ' ') }
    }
    return -join $lines
}
