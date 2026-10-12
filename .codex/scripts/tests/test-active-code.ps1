# test-active-code.ps1
# lib/active-code.ps1 是 repo-index、impact-scope、sql-scan 共用的「什麼是註解」。錯在這裡三支一起錯，方向有兩個：
#
#   沒認出註解          → 註解掉的舊碼被當成現役（索引、排名、SQL 訊號全部）
#   把字串當成註解的開頭 → "image/*"、"http://…"、'--' 後面真的程式碼被吃掉
#
# 第二種更難發現：被吃掉的東西不會出現在任何輸出裡，索引只是少了幾個類別。

. (Resolve-Path '.codex/scripts/lib/active-code.ps1')

# 剝過的那一份，逐行 Trim 之後用 | 接起來 —— 斷言失敗時一眼看得出是哪一行多了或少了。
function Get-AcView([string]$text, [string]$ext) {
    ((Get-ActiveCode $text $ext) -split '\r?\n' | ForEach-Object { $_.Trim() }) -join '|'
}

Describe-Suite 'active-code / C#、Java：註解拿掉，字串不動' {

    It-Should '行註解與區塊註解都拿掉，行數不變（sql-scan 靠行號對回原文）' {
        Assert-Equal 'a();||d();|e();' (Get-AcView "a(); // x`n/* b`n c */ d();`ne();" '.cs')
        $t = "x();`r`n/* a`r`n b`r`n*/`r`ny(); // z`r`n"
        Assert-Equal ($t -split "`n").Count ((Get-ActiveCode $t '.cs') -split "`n").Count '行數變了'
    }

    It-Should '字串裡的 */*、image/*、http:// 不是註解的開頭' {
        Assert-Equal 'var a = "*/*"; var b = "image/*";|keep();' (Get-AcView "var a = `"*/*`"; var b = `"image/*`";`nkeep();" '.cs')
        Assert-Equal 'x("http://a"); y();' (Get-AcView "x(`"http://a`"); y(); // z" '.cs')
    }

    It-Should "字元常值 '`"' 不會開出一個字串（不然後面的 // 認不出來）" {
        # 註解後面要再有一個 " —— 沒有的話，被誤開的字串在行尾找不到收尾，掃描器退回逐字元，碰巧又對了。
        Assert-Equal "var q = '`"';|live();" (Get-AcView "var q = '`"'; // 舊寫法 `"x`"`nlive();" '.cs')
    }

    It-Should 'verbatim 字串：反斜線不是跳脫、"" 才是' {
        # 同一行後面要再有字串：把 \" 當成跳脫的話，字串會一路吃到下一個 "，把 http:// 的 // 留在字串外面當成註解。
        Assert-Equal 'var p = @"C:\temp\"; var u = "http://x";' (Get-AcView 'var p = @"C:\temp\"; var u = "http://x";' '.cs')
        Assert-Equal 'var s = @"say ""hi"" // no";' (Get-AcView 'var s = @"say ""hi"" // no"; // yes' '.cs')
        Assert-Equal 'var t = $@"{a}\";' (Get-AcView 'var t = $@"{a}\"; // c' '.cs')
    }

    It-Should 'raw 字串與 Java text block（"""）裡的 /* 不是註解' {
        Assert-Equal 'var r = """|a /* b|""";|after();' (Get-AcView "var r = `"`"`"`n  a /* b`n  `"`"`";`nafter();" '.cs')
        Assert-Equal 'String s = """|-- /* x|""";|after();' (Get-AcView "String s = `"`"`"`n  -- /* x`n  `"`"`";`nafter(); // c" '.java')
    }

    It-Should '沒收尾的 /* 一路算到檔尾' {
        Assert-Equal 'x();|' (Get-AcView "x(); /* open`npublic class Gone {}" '.cs')
    }

    It-Should 'public/**/class 不會黏成一個字' {
        Assert-Match 'public\s+class Foo' (Get-ActiveCode 'public/**/class Foo' '.cs')
    }
}

Describe-Suite 'active-code / C# 的 #if：只拿掉確定不會編進去的' {

    It-Should '#if false 的分支拿掉，#else 留著，#endif 之後恢復' {
        Assert-Equal '#if false||#else|Alive();|#endif|After();' (Get-AcView "#if false`n  Dead();`n#else`n  Alive();`n#endif`nAfter();" '.cs')
    }

    It-Should '#if false 裡的巢狀 #if 一起拿掉' {
        Assert-Equal '#if false|#if DEBUG||#endif||#endif|Live();' (Get-AcView "#if false`n#if DEBUG`n  D1();`n#endif`n  D2();`n#endif`nLive();" '.cs')
    }

    It-Should '#if 某符號 不猜 —— 原樣留著' {
        Assert-Equal '#if LEGACY|Kept();|#endif' (Get-AcView "#if LEGACY`n  Kept();`n#endif" '.cs')
    }

    It-Should '#if true 之後的 #elif、#else 拿掉' {
        Assert-Equal '#if true|Live();|#elif X||#else||#endif' (Get-AcView "#if true`n  Live();`n#elif X`n  D1();`n#else`n  D2();`n#endif" '.cs')
    }

    It-Should '#if TRUE 是一個符號、不是字面值 —— 兩邊都留著' {
        # 前面放一段字面上的 #if false：讓檔案通過「有沒有字面值」的初篩，真的走到逐行判斷那一段。
        Assert-Equal '#if false|#endif|#if TRUE|A();|#else|B();|#endif' (Get-AcView "#if false`n#endif`n#if TRUE`n  A();`n#else`n  B();`n#endif" '.cs')
    }

    It-Should '#if false 後面的行尾註解不影響判斷' {
        Assert-Equal '#if false||#endif' (Get-AcView "#if false // 舊版`n  D();`n#endif" '.cs')
    }
}

Describe-Suite 'active-code / SQL 與 XML' {

    It-Should 'T-SQL 的區塊註解可以巢狀：內層的 */ 之後仍在註解裡' {
        Assert-Equal '|SELECT 1' (Get-AcView "/* a /* b */ IF 1=1 */`nSELECT 1" '.sql')
    }

    It-Should "字串、[識別字]、`"識別字`" 裡的 -- 不是註解" {
        Assert-Equal "SELECT [a--b], 'x--y', `"c--d`" FROM t" (Get-AcView "SELECT [a--b], 'x--y', `"c--d`" FROM t -- tail" '.sql')
        Assert-Equal "SELECT 'O''Brien -- not'" (Get-AcView "SELECT 'O''Brien -- not' -- yes" '.sql')
    }

    It-Should '跨行的字串整段是字串' {
        Assert-Equal "SELECT 'line1|-- still string' FROM t" (Get-AcView "SELECT 'line1`n-- still string' FROM t" '.sql')
    }

    It-Should 'XML 的 <!-- --> 拿掉，CDATA 不動' {
        Assert-Equal '<a>||<![CDATA[ <!-- keep --> ]]>|</a>' (Get-AcView "<a>`n<!-- <select id=`"x`"> -->`n<![CDATA[ <!-- keep --> ]]>`n</a>" '.xml')
    }

    It-Should '不認得的副檔名原樣回傳' {
        Assert-Equal '// keep' (Get-ActiveCode '// keep' '.txt')
    }
}
