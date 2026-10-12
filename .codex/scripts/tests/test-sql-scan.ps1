# test-sql-scan.ps1
# sql-scan 的訊號清單是 sa-analyst 判斷「這是不是要保留的業務規則」的輸入（它只讀訊號與行號，不貼 SQL 全文）。
# 這裡錯的症狀都是靜默的：
#
#   註解裡的命中沒標出來   → 一條早就被拿掉的舊規則被當成要保留的現況，寫進 ③ 的 Gherkin，測試照樣全綠
#   字串裡的 -- 被當成註解 → 現役的規則被標成舊碼
#   單行檔掃不出東西       → 壓成一行的 View／SP 定義整個漏掉（舊版踩過）

$SsScript = (Resolve-Path '.codex/scripts/sql-scan.ps1').Path
$SsRoot   = Join-Path ([IO.Path]::GetTempPath()) 'codex-sql-scan-tests'
$SsUtf8   = [Text.UTF8Encoding]::new($false)

# 在乾淨的資料夾裡放好檔案、跑一次 sql-scan。回傳 stdout 的摘要與輸出檔的全文。
# 輸出檔寫在掃描根目錄旁邊（不寫進去），免得它自己變成下一次掃描的輸入。
function Invoke-SqlScanFixture([hashtable]$Files, [int]$MaxSignals = 300) {
    Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($k in $Files.Keys) {
        $p = Join-Path $SsRoot $k
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, $Files[$k], $SsUtf8)
    }
    $out = "$SsRoot.out/sql-signals.json"
    $r = Invoke-Script $SsScript -Params @{ Root = $SsRoot; OutFile = $out; MaxSignals = $MaxSignals }
    if ($r.exit -ne 0) { throw "sql-scan exit $($r.exit)：$($r.stderr)" }
    [pscustomobject]@{ summary = ($r.stdout | ConvertFrom-Json); result = (Get-Content $out -Raw | ConvertFrom-Json) }
}

function Get-SsSignal($result, [string]$file, [int]$line) {
    @($result.signals | Where-Object { $_.file -eq $file -and $_.line -eq $line })[0]
}

function Test-SsCommented($signal) { [bool]($signal -and $signal.PSObject.Properties['commented'] -and $signal.commented) }

Describe-Suite 'sql-scan / 註解裡的命中照樣報，但標出來、不算進現況' {

    It-Should 'SP 裡被 /* */ 與 -- 拿掉的舊規則：標 commented，不算進 signal-count 與 by-construct' {
        $sp = @'
CREATE PROCEDURE dbo.usp_CancelOrder @OrderId INT AS
BEGIN
    /* 舊規則：已出貨也能取消，會連帶退運費
    IF EXISTS (SELECT 1 FROM Orders WHERE Id = @OrderId AND Status = 3)
    BEGIN
        UPDATE Payments SET Refund = Amount + ShippingFee WHERE OrderId = @OrderId
    END
    */
    -- DECLARE c CURSOR FOR SELECT Id FROM OrderItems WHERE OrderId = @OrderId
    UPDATE Orders SET Status = 9 WHERE Id = @OrderId AND Status < 3
END
'@
        try {
            $r = Invoke-SqlScanFixture @{ 'db/usp_CancelOrder.sql' = $sp }
            $old = Get-SsSignal $r.result 'db/usp_CancelOrder.sql' 4
            Assert-True ($null -ne $old) '註解裡的舊規則整個沒報 —— 那是重構時該問的線索（是刻意拿掉的嗎？）'
            Assert-True (Test-SsCommented $old) '/* */ 裡的舊規則沒標 commented：單行 context 看不出它在註解裡，讀的人會當成現況'
            Assert-True (Test-SsCommented (Get-SsSignal $r.result 'db/usp_CancelOrder.sql' 9)) '-- 拿掉的 cursor 沒標 commented'
            $live = Get-SsSignal $r.result 'db/usp_CancelOrder.sql' 10
            Assert-True ($null -ne $live -and -not (Test-SsCommented $live)) '現役的那一行沒報，或被標成 commented'
            Assert-Equal 1 $r.result.'signal-count' 'signal-count 算進了註解裡的'
            Assert-Equal 2 $r.result.'commented-signal-count'
            $types = @($r.result.'by-construct' | ForEach-Object { $_.type })
            Assert-True ('cursor' -notin $types -and 'control-flow' -notin $types) "by-construct 算進了註解裡的：$($types -join '、')"
            Assert-Equal 2 $r.summary.commented_count 'stdout 摘要沒有 commented_count —— 對話裡只留摘要'
            Assert-Match '註解裡' $r.summary.next_step 'next_step 沒說有訊號在註解裡'
        } finally { Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'T-SQL 的區塊註解可以巢狀：內層的 */ 之後仍是舊碼' {
        # 註解掉一段本身就含 /* */ 的 SP，在 SQL Server 上是常態；不認巢狀，內層 */ 之後的舊碼就變回現役。
        $sql = @'
/*
IF @Mode = 1
BEGIN
    /* 舊的說明 */
    WHILE @i < 10 BEGIN SET @i = @i + 1 END
END
*/
SELECT a FROM t WHERE b = 1 AND c = 2
'@
        try {
            $r = Invoke-SqlScanFixture @{ 'v.sql' = $sql }
            Assert-True (Test-SsCommented (Get-SsSignal $r.result 'v.sql' 5)) '內層 */ 之後的 WHILE 被當成現役'
            $after = Get-SsSignal $r.result 'v.sql' 8
            Assert-True ($null -ne $after -and -not (Test-SsCommented $after)) '註解結束之後的那一行沒報，或被標成 commented'
        } finally { Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should "字串與 [識別字] 裡的 -- 不是註解 —— 那一行是現役的" {
        try {
            $r = Invoke-SqlScanFixture @{ 'q.sql' = "SELECT [a--b] FROM t WHERE sep = '--' AND x = 1 -- 尾巴 OR 說明" }
            $s = Get-SsSignal $r.result 'q.sql' 1
            Assert-True ($null -ne $s) '那一行沒報'
            Assert-True (-not (Test-SsCommented $s)) '把字串或識別字裡的 -- 當成註解開頭，現役的規則被標成舊碼'
        } finally { Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'C#：// 註解掉的 SQL 標 commented，現役的不標' {
        $cs = @'
public class Repo
{
    public Order Get(int id)
    {
        // var sql = "SELECT * FROM Orders WHERE Status <> 3 AND IsDeleted = 0";
        var sql = "SELECT Id, Status FROM Orders WHERE Id = @id";
        return _db.QueryFirst<Order>(sql, new { id });
    }
}
'@
        try {
            $r = Invoke-SqlScanFixture @{ 'Repo.cs' = $cs }
            Assert-True (Test-SsCommented (Get-SsSignal $r.result 'Repo.cs' 5)) '// 註解掉的 SQL 沒標 commented'
            foreach ($n in 6, 7) {
                $s = Get-SsSignal $r.result 'Repo.cs' $n
                Assert-True ($null -ne $s -and -not (Test-SsCommented $s)) "第 $n 行（現役）沒報，或被標成 commented"
            }
        } finally { Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'MyBatis mapper：<!-- --> 裡的 <select> 標 commented' {
        $xml = @'
<mapper namespace="OrderMapper">
  <!--
  <select id="findShippedOld">SELECT * FROM orders WHERE status = 3</select>
  -->
  <select id="findOpen">SELECT * FROM orders WHERE status = 1</select>
</mapper>
'@
        try {
            $r = Invoke-SqlScanFixture @{ 'OrderMapper.xml' = $xml }
            Assert-True (Test-SsCommented (Get-SsSignal $r.result 'OrderMapper.xml' 3)) 'XML 註解裡的 <select> 沒標 commented'
            $live = Get-SsSignal $r.result 'OrderMapper.xml' 5
            Assert-True ($null -ne $live -and -not (Test-SsCommented $live)) '現役的 <select> 沒報，或被標成 commented'
        } finally { Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '上限先給現役的訊號 —— 註解裡的舊碼只拿剩下的名額' {
        $sql = @'
-- SELECT a FROM t WHERE b = 1 AND c = 2
-- SELECT a FROM t WHERE b = 1 AND c = 3
SELECT a FROM t WHERE b = 1 AND c = 4
'@
        try {
            $r = Invoke-SqlScanFixture @{ 'cap.sql' = $sql } -MaxSignals 1
            Assert-Equal 1 @($r.result.signals).Count
            Assert-Equal 3 @($r.result.signals)[0].line '名額被註解裡的舊碼佔掉了'
            Assert-True $r.result.truncated
        } finally { Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '單行檔照樣掃得到（壓成一行的 View／SP 定義）' {
        try {
            $r = Invoke-SqlScanFixture @{ 'one.sql' = 'CREATE VIEW v AS SELECT a FROM t INNER JOIN u ON t.id = u.id' }
            Assert-Equal 1 $r.result.'signal-count' '單行檔掃不出訊號 —— 逐字元比對的舊 bug 回來了'
        } finally { Remove-Item $SsRoot, "$SsRoot.out" -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
