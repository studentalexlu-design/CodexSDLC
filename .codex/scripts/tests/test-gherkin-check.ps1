# test-gherkin-check.ps1
# gherkin-check 是 reviewer 的 oracle：它說綠，reviewer 就不再逐字人工比對。所以它最危險的失效是「該紅的時候綠」——
# 改了一個字、刪了一條既有 scenario、改了既有 step 的措辭，每一種都要有一條必紅的案例。

$GcScript = (Resolve-Path '.codex/scripts/gherkin-check.ps1').Path
$GcRoot   = Join-Path ([IO.Path]::GetTempPath()) 'codex-gherkin-check-tests'
$GcUtf8   = [Text.UTF8Encoding]::new($false)

$GcSpec = @'
# cancel-order —— 客戶可以取消還沒出貨的訂單

## 需求決議
- 已出貨的不能取消

## 驗收條件

```gherkin
# feature-id: cancel-order
Feature: 取消訂單
  Scenario: 未出貨的訂單可以取消
    Given 訂單 1001 的狀態是「已付款」
    When 客戶取消訂單 1001
    Then 訂單 1001 的狀態變成「已取消」

  Scenario: 已出貨的訂單不能取消
    Given 訂單 1002 的狀態是「已出貨」
    When 客戶取消訂單 1002
    Then 系統拒絕並顯示「已出貨的訂單不能取消」
```

驗收層：application service
'@

$GcFeature = @'
# feature-id: cancel-order
# language: en
@orders
Feature: 取消訂單
  Scenario: 未出貨的訂單可以取消
    Given 訂單 1001 的狀態是「已付款」
    When 客戶取消訂單 1001
    Then 訂單 1001 的狀態變成「已取消」

  @regression
  Scenario: 已出貨的訂單不能取消
    Given 訂單 1002 的狀態是「已出貨」
    When 客戶取消訂單 1002
    Then 系統拒絕並顯示「已出貨的訂單不能取消」
'@

function New-GcProject([string]$feature = $GcFeature, [string]$spec = $GcSpec, [switch]$Git) {
    Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path (Join-Path $GcRoot 'bdd-docs/cancel-order') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $GcRoot 'tests/Features') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $GcRoot 'bdd-docs/cancel-order/spec.md'), $spec, $GcUtf8)
    [IO.File]::WriteAllText((Join-Path $GcRoot 'tests/Features/CancelOrder.feature'), $feature, $GcUtf8)
    if ($Git) {
        Push-Location $GcRoot
        try {
            git init -q 2>$null; git add -A 2>$null
            git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base 2>$null
        } finally { Pop-Location }
    }
}

# {test 名稱 = outcome} → 最小的 TRX（有 Results 與 TestDefinitions，跟 dotnet test --logger trx 同構）
function New-GcTrx([hashtable]$tests, [hashtable]$descriptions = @{}) {
    $res = ''; $defs = ''; $i = 0
    $total = $tests.Count; $ne = @($tests.Values | Where-Object { $_ -eq 'NotExecuted' }).Count
    foreach ($k in $tests.Keys) {
        $i++; $id = "00000000-0000-0000-0000-{0:D12}" -f $i
        $e = [Security.SecurityElement]::Escape($k)   # Outline 的名稱帶雙引號
        $res  += "<UnitTestResult testId=""$id"" testName=""$e"" outcome=""$($tests[$k])"" />"
        $desc = if ($descriptions[$k]) { "<Description>$($descriptions[$k])</Description>" } else { '' }
        $defs += "<UnitTest name=""$e"" id=""$id"">$desc<TestMethod className=""Tests.CancelOrderFeature"" name=""$e"" /></UnitTest>"
    }
    return "<TestRun xmlns=""http://microsoft.com/schemas/VisualStudio/TeamTest/2010""><Results>$res</Results><TestDefinitions>$defs</TestDefinitions><ResultSummary outcome=""Completed""><Counters total=""$total"" executed=""$($total - $ne)"" passed=""$($total - $ne)"" failed=""0"" notExecuted=""$ne"" inconclusive=""0"" /></ResultSummary></TestRun>"
}

function Set-GcFeature([string]$text) { [IO.File]::WriteAllText((Join-Path $GcRoot 'tests/Features/CancelOrder.feature'), $text, $GcUtf8) }

function Invoke-Gc([hashtable]$extra = @{}) {
    Push-Location $GcRoot
    try {
        $p = @{ Feature = 'tests/Features/CancelOrder.feature'; Json = $true }
        foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
        $r = Invoke-Script $GcScript -Params $p
        $r | Add-Member -NotePropertyName json -NotePropertyValue $(try { $r.stdout | ConvertFrom-Json } catch { $null })
        return $r
    } finally { Pop-Location }
}

Describe-Suite 'gherkin-check / 逐字照抄 spec.md' {

    It-Should '逐字一致（加了 tag、註解、# language）→ 綠' {
        New-GcProject
        try {
            $r = Invoke-Gc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
            Assert-Equal 'bdd-docs/cancel-order/spec.md' $r.json.results[0].spec '沒有從 # feature-id: 找回 spec.md'
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '步驟改了一個字 → 紅（使用者批准的是那些字）' {
        New-GcProject ($GcFeature -replace '狀態變成「已取消」', '狀態改成「已取消」')
        try {
            $r = Invoke-Gc
            Assert-Equal 2 $r.exit
            Assert-Match '狀態變成「已取消」' (@($r.json.results[0].missing_steps | ForEach-Object { $_.step }) -join '|')
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'spec 的 scenario 標題被改了 → 紅' {
        New-GcProject ($GcFeature -replace 'Scenario: 已出貨的訂單不能取消', 'Scenario: 出貨後不能取消')
        try {
            $r = Invoke-Gc
            Assert-Equal 2 $r.exit
            Assert-Equal '已出貨的訂單不能取消' @($r.json.results[0].missing_scenarios)[0]
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '共用的 Given 搬進 Background 也算照抄' {
        $f = @'
# feature-id: cancel-order
Feature: 取消訂單
  Background:
    Given 訂單 1001 的狀態是「已付款」
  Scenario: 未出貨的訂單可以取消
    When 客戶取消訂單 1001
    Then 訂單 1001 的狀態變成「已取消」
  Scenario: 已出貨的訂單不能取消
    Given 訂單 1002 的狀態是「已出貨」
    When 客戶取消訂單 1002
    Then 系統拒絕並顯示「已出貨的訂單不能取消」
'@
        New-GcProject $f
        try {
            $r = Invoke-Gc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '有 ## 迭代 2 時預設只比最後一次的區塊' {
        $spec = $GcSpec + @'


## 迭代 2 —— 已出貨可以退貨

```gherkin
# feature-id: cancel-order
Feature: 取消訂單
  Scenario: 已出貨的訂單改走退貨
    Given 訂單 1003 的狀態是「已出貨」
    When 客戶申請退貨 1003
    Then 系統建立退貨單
```
'@
        New-GcProject -spec $spec
        try {
            $r = Invoke-Gc
            Assert-Equal 2 $r.exit '迭代 2 的 scenario 還沒落地卻通過了'
            Assert-Equal 2 $r.json.results[0].iteration
            Assert-Equal '已出貨的訂單改走退貨' @($r.json.results[0].missing_scenarios)[0]
            $r = Invoke-Gc @{ Iteration = 1 }
            Assert-Equal 0 $r.exit "指定迭代 1 時應該只比第 1 次；stdout: $($r.stdout)"
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'gherkin-check / 既有的 scenario 與 step 不動（跟 git HEAD 比）' {

    It-Should '刪掉一條既有 scenario → 紅（QA 的工作區，刪了不會有測試變紅）' {
        # HEAD 裡多一條 QA 自己加的 scenario；這次的 .feature 把它弄丟了。
        $withQa = $GcFeature + @'

  Scenario: QA 加的：取消後庫存回補
    Given 訂單 1001 的狀態是「已付款」
    When 客戶取消訂單 1001
    Then 商品 A 的庫存加回 1
'@
        New-GcProject $withQa -Git
        Set-GcFeature $GcFeature
        try {
            $r = Invoke-Gc
            Assert-Equal 2 $r.exit '既有 scenario 被刪卻通過了'
            Assert-Equal 'QA 加的：取消後庫存回補' @($r.json.results[0].removed_scenarios)[0]
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '改了既有 step 的措辭 → 紅；這次迭代明講要改的同名 scenario 不算' {
        $withQa = $GcFeature + @'

  Scenario: QA 加的：取消後庫存回補
    Given 訂單 1001 的狀態是「已付款」
    When 客戶取消訂單 1001
    Then 商品 A 的庫存加回 1
'@
        New-GcProject $withQa -Git
        Set-GcFeature ($withQa -replace '商品 A 的庫存加回 1', '商品 A 的庫存回補 1')
        try {
            $r = Invoke-Gc
            Assert-Equal 2 $r.exit '既有 step 被改了措辭卻通過了'
            Assert-Match '庫存加回 1' (@($r.json.results[0].removed_steps | ForEach-Object { $_.step }) -join '|')
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }

        # 同一個改法，但 spec 的這次迭代明講要改那一條 → 不是違規
        $spec = $GcSpec + @'


## 迭代 2 —— 庫存回補的措辭

```gherkin
Feature: 取消訂單
  Scenario: QA 加的：取消後庫存回補
    Given 訂單 1001 的狀態是「已付款」
    When 客戶取消訂單 1001
    Then 商品 A 的庫存回補 1
```
'@
        New-GcProject $withQa -spec $spec -Git
        Set-GcFeature ($withQa -replace '商品 A 的庫存加回 1', '商品 A 的庫存回補 1')
        try {
            $r = Invoke-Gc
            Assert-Equal 0 $r.exit "spec 明講要改的那一條被當成違規；stdout: $($r.stdout)"
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'gherkin-check / 不略過' {

    It-Should 'scenario 標了 @ignore → 紅（skipped 不是綠燈）' {
        New-GcProject ($GcFeature -replace '@regression', '@ignore')
        try {
            $r = Invoke-Gc
            Assert-Equal 2 $r.exit
            Assert-Equal '已出貨的訂單不能取消' @($r.json.results[0].skipped_scenarios)[0]
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '測試結果（TRX）裡有沒跑的 → 紅；全部跑了 → 綠' {
        New-GcProject
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed'; '已出貨的訂單不能取消' = 'Passed'; 'Other' = 'NotExecuted' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit
            Assert-Equal 1 $r.json.results[0].skipped_tests
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed'; '已出貨的訂單不能取消' = 'Passed'; 'Other' = 'Passed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'JUnit XML（surefire）的 skipped 也算' {
        New-GcProject
        $xml = Join-Path $GcRoot 'TEST-x.xml'
        try {
            [IO.File]::WriteAllText($xml, '<testsuite name="x" tests="2" failures="0" errors="0" skipped="1"><testcase name="未出貨的訂單可以取消"/><testcase name="已出貨的訂單不能取消"><skipped/></testcase></testsuite>', $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $xml }
            Assert-Equal 2 $r.exit
            Assert-Equal '已出貨的訂單不能取消' @($r.json.results[0].scenarios_not_passed)[0].scenario
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'scenario 在結果檔裡沒有測試 → 紅（skipped 是 0 也一樣）' {
        New-GcProject
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit '有 scenario 沒產生測試卻通過了'
            Assert-Equal 0 $r.json.results[0].skipped_tests
            Assert-Equal '已出貨的訂單不能取消' @($r.json.results[0].scenarios_without_test)[0]
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'scenario 的測試 Failed → 紅' {
        New-GcProject
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed'; '已出貨的訂單不能取消' = 'Failed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit
            Assert-Equal 'failed' @(@($r.json.results[0].scenarios_not_passed)[0].outcomes)[0]
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '對得上 Reqnroll 的方法名、xUnit 的全名、Outline 的每一列、MSTest 的 Description' {
        $spec = $GcSpec -replace '未出貨的訂單可以取消', 'Unshipped order can be cancelled'
        New-GcProject ($GcFeature -replace '未出貨的訂單可以取消', 'Unshipped order can be cancelled') -spec $spec
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ 'Tests.CancelOrderFeature.UnshippedOrderCanBeCancelled' = 'Passed'; '已出貨的訂單不能取消_Variant0' = 'Passed'; '已出貨的訂單不能取消_Variant1' = 'Passed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ 'UnshippedOrderCanBeCancelled' = 'Passed'; 'ShippedOrderRejected' = 'Passed' } @{ 'ShippedOrderRejected' = '已出貨的訂單不能取消' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 0 $r.exit "Description 沒對上；stderr: $($r.stderr)"
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '對得上 Reqnroll 2.2.1 實際寫進 TRX 的名稱（MSTest／xUnit／NUnit，全形標點、Outline 參數）' {
        # 2026-10-26 在 dotnet 10 上實跑三種 runner 抄下來的 testName
        $spec = $GcSpec -replace '已出貨的訂單不能取消', '已出貨的訂單不能取消（退款另計）'
        $feat = $GcFeature -replace '已出貨的訂單不能取消', '已出貨的訂單不能取消（退款另計）'
        $feat = $feat -replace '系統拒絕並顯示「已出貨的訂單不能取消（退款另計）」', '系統拒絕並顯示「已出貨的訂單不能取消」'
        $spec = $spec -replace '系統拒絕並顯示「已出貨的訂單不能取消（退款另計）」', '系統拒絕並顯示「已出貨的訂單不能取消」'
        New-GcProject $feat -spec $spec
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            foreach ($names in @(
                    @('未出貨的訂單可以取消 ("金卡","100",null)', '已出貨的訂單不能取消退款另計'),                                  # MSTest
                    @('未出貨的訂單可以取消(level: "金卡", points: "100", exampleTags: [])', '已出貨的訂單不能取消（退款另計）'),       # xUnit
                    @('未出貨的訂單可以取消("金卡","100",null)', '已出貨的訂單不能取消退款另計'))) {                              # NUnit
                $t = @{}; foreach ($n in $names) { $t[$n] = 'Passed' }
                [IO.File]::WriteAllText($trx, (New-GcTrx $t), $GcUtf8)
                $r = Invoke-Gc @{ TestResults = $trx }
                Assert-Equal 0 $r.exit "對不上 $($names -join ' ／ ')；stderr: $($r.stderr)"
            }
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '標題是另一條的開頭時，不拿較長那條的測試充數' {
        # spec 有「取消訂單」與「取消訂單並退款」；結果檔只有後者 → 前者沒有測試
        $spec = $GcSpec -replace '未出貨的訂單可以取消', '取消訂單' -replace '已出貨的訂單不能取消', '取消訂單並退款'
        New-GcProject ($GcFeature -replace '未出貨的訂單可以取消', '取消訂單' -replace '已出貨的訂單不能取消', '取消訂單並退款') -spec $spec
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '取消訂單並退款' = 'Passed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit '較短的標題被較長那條的測試充數了'
            Assert-Equal '取消訂單' @($r.json.results[0].scenarios_without_test)[0]
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '前幾次迭代的 scenario 沒產生測試或沒通過 → 紅；標 @manual 的不要求測試' {
        # 這次只有一條；.feature 裡還有前一次交付的「已出貨的訂單不能取消」—— 改了共用的 step 讓它失去繫結時，全套照樣綠。
        $spec = $GcSpec -replace '(?s)\n  Scenario: 已出貨的訂單不能取消.*?不能取消」\n', "`n"
        New-GcProject -spec $spec
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit '前幾次迭代的 scenario 沒有測試卻通過了'
            Assert-Equal '已出貨的訂單不能取消' @($r.json.results[0].prior_scenarios_without_test)[0]
            Assert-Equal 0 @($r.json.results[0].scenarios_without_test).Count '前幾次的算進這次的了'

            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed'; '已出貨的訂單不能取消' = 'Failed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit '前幾次迭代的 scenario 測試失敗卻通過了'
            Assert-Equal '已出貨的訂單不能取消' @($r.json.results[0].prior_scenarios_not_passed)[0].scenario

            Set-GcFeature ($GcFeature -replace '@regression', '@manual')
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 0 $r.exit "@manual 的 scenario 不該要求測試；stderr: $($r.stderr)"
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '這次的短標題不拿前幾次迭代較長標題的測試充數' {
        $spec = $GcSpec -replace '未出貨的訂單可以取消', '取消訂單' -replace '(?s)\n  Scenario: 已出貨的訂單不能取消.*?不能取消」\n', "`n"
        New-GcProject ($GcFeature -replace '未出貨的訂單可以取消', '取消訂單' -replace '已出貨的訂單不能取消', '取消訂單並退款') -spec $spec
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '取消訂單並退款' = 'Passed' }), $GcUtf8)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit
            Assert-Equal '取消訂單' @($r.json.results[0].scenarios_without_test)[0]
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '結果檔比改過的檔舊 → 紅（先跑測試、後改程式）' {
        New-GcProject -Git
        $trx = Join-Path $GcRoot 'r.trx'
        try {
            [IO.File]::WriteAllText($trx, (New-GcTrx @{ '未出貨的訂單可以取消' = 'Passed'; '已出貨的訂單不能取消' = 'Passed' }), $GcUtf8)
            $src = Join-Path $GcRoot 'src/OrderService.cs'
            New-Item -ItemType Directory -Path (Split-Path $src) -Force | Out-Null
            [IO.File]::WriteAllText($src, 'class OrderService {}', $GcUtf8)
            (Get-Item $src).LastWriteTimeUtc = (Get-Item $trx).LastWriteTimeUtc.AddMinutes(1)
            # bdd-docs/ 與建置輸出比結果檔新不算
            foreach ($p in 'bdd-docs/cancel-order/review.md', 'src/bin/Debug/x.dll') {
                $full = Join-Path $GcRoot $p
                New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
                [IO.File]::WriteAllText($full, 'x', $GcUtf8)
                (Get-Item $full).LastWriteTimeUtc = (Get-Item $trx).LastWriteTimeUtc.AddMinutes(1)
            }
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 2 $r.exit '舊的結果檔通過了'
            Assert-Equal 'src/OrderService.cs' (@($r.json.results[0].stale_results_newer) -join '|')
            (Get-Item $trx).LastWriteTimeUtc = (Get-Item $src).LastWriteTimeUtc.AddMinutes(1)
            $r = Invoke-Gc @{ TestResults = $trx }
            Assert-Equal 0 $r.exit "重跑之後應該綠；stderr: $($r.stderr)"
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '.feature 沒有 # feature-id: 也沒給 -Spec → 錯誤（exit 1），不是綠' {
        New-GcProject ($GcFeature -replace '# feature-id: cancel-order', '')
        try {
            $r = Invoke-Gc
            Assert-Equal 1 $r.exit
            Assert-Match 'feature-id' $r.json.results[0].error
        } finally { Remove-Item $GcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
