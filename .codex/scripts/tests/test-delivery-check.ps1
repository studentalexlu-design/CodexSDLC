# test-delivery-check.ps1
# delivery-check 是 ⑥ 唯一的機械檢查：它說 OK，orchestrator 就回報交付。最危險的失效是「該紅的時候綠」——
# 漏寫一項殘留風險、最後一輪修正之後沒重跑測試、審核 FAIL 卻當成可以交付，每一種都要有一條必紅的案例。

$DcScript = (Resolve-Path '.codex/scripts/delivery-check.ps1').Path
$DcRoot   = Join-Path ([IO.Path]::GetTempPath()) 'codex-delivery-check-tests'
$DcUtf8   = [Text.UTF8Encoding]::new($false)

$DcSpecBody = @'
# cancel-order —— 客戶可以取消還沒出貨的訂單

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

$DcDelivery = @'

## 交付 —— 2026-10-29

- 怎麼驗的：dotnet test（2 passed）＋ gherkin-check
- 殘留風險：無
'@

$DcFeature = @'
# feature-id: cancel-order
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

$DcReviewPass = @'
VERDICT: PASS

## 發現
1. [建議] src/Orders/CancelService.cs:12 —— 方法太長
   會怎麼壞：不會壞，只是難讀

## 沒問題的部分
測試斷言都來自驗收條件的值。
'@

$DcReviewFail = @'
VERDICT: FAIL

## 發現
1. [必修] src/Orders/CancelService.cs:40 —— 已出貨的訂單沒有被擋下
   會怎麼壞：訂單 1002（已出貨）取消後狀態變成「已取消」
'@

function New-DcTrx([string[]]$passed) {
    $res = ''; $defs = ''; $i = 0
    foreach ($k in $passed) {
        $i++; $id = "00000000-0000-0000-0000-{0:D12}" -f $i
        $res  += "<UnitTestResult testId=""$id"" testName=""$k"" outcome=""Passed"" />"
        $defs += "<UnitTest name=""$k"" id=""$id""><TestMethod className=""Tests.CancelOrderFeature"" name=""$k"" /></UnitTest>"
    }
    return "<TestRun xmlns=""http://microsoft.com/schemas/VisualStudio/TeamTest/2010""><Results>$res</Results><TestDefinitions>$defs</TestDefinitions><ResultSummary outcome=""Completed""><Counters total=""$i"" executed=""$i"" passed=""$i"" failed=""0"" notExecuted=""0"" inconclusive=""0"" /></ResultSummary></TestRun>"
}

function Write-DcFile([string]$rel, [string]$text) {
    $p = Join-Path $DcRoot $rel
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($p, $text, $DcUtf8)
}

# 一個交付得出去的專案：spec（含交付一節）、PASS 的審核、.feature、src、已 commit，結果檔比所有改過的檔新。
function New-DcProject([string]$spec = ($DcSpecBody + $DcDelivery), [string]$feature = $DcFeature, [string]$review = $DcReviewPass,
                       [string[]]$tests = @('未出貨的訂單可以取消', '已出貨的訂單不能取消'), [switch]$NoGit) {
    Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-DcFile 'bdd-docs/cancel-order/spec.md' $spec
    if ($feature) { Write-DcFile 'tests/Features/CancelOrder.feature' $feature }
    if ($review)  { Write-DcFile 'bdd-docs/cancel-order/review.md' $review }
    Write-DcFile 'src/Orders/CancelService.cs' 'class CancelService {}'
    if (-not $NoGit) {
        Push-Location $DcRoot
        try {
            git init -q 2>$null; git add -A 2>$null
            git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base 2>$null
        } finally { Pop-Location }
    }
    Write-DcFile 'TestResults/run.trx' (New-DcTrx $tests)
}

function Invoke-Dc([hashtable]$extra = @{}, [switch]$NoResults) {
    Push-Location $DcRoot
    try {
        $p = @{ FeatureId = 'cancel-order'; Json = $true }
        if (-not $NoResults) { $p['TestResults'] = 'TestResults/run.trx' }
        foreach ($k in $extra.Keys) { $p[$k] = $extra[$k] }
        $r = Invoke-Script $DcScript -Params $p
        $r | Add-Member -NotePropertyName json -NotePropertyValue $(try { $r.stdout | ConvertFrom-Json } catch { $null })
        $r | Add-Member -NotePropertyName codes -NotePropertyValue @($r.json.problems | ForEach-Object { $_.code })
        return $r
    } finally { Pop-Location }
}

Describe-Suite 'delivery-check / 交付得出去的那一份要綠' {

    It-Should '審核 PASS、gherkin-check 通過、交付一節寫了殘留風險 → exit 0' {
        New-DcProject
        try {
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout) stderr: $($r.stderr)"
            Assert-Equal 'PASS' $r.json.review.verdict
            Assert-True $r.json.gherkin.passed
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '不帶 -Json：一行 OK，附「外部來源只用替身驗過」的提醒（那一項這支看不到）' {
        New-DcProject
        try {
            Push-Location $DcRoot
            try { $r = Invoke-Script $DcScript -Params @{ FeatureId = 'cancel-order'; TestResults = 'TestResults/run.trx' } } finally { Pop-Location }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            Assert-Match '\[delivery-check\] OK' $r.stdout
            Assert-Match '替身' $r.stdout
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '沒有 .feature 的需求（bug 修復、沒有行為變更）不要求結果檔' {
        New-DcProject -spec "# cancel-order —— 修好取消按鈕`n`n回歸測試：tests/CancelTests.cs::已出貨不能取消`n$DcDelivery" -feature ''
        try {
            $r = Invoke-Dc -NoResults
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-True (-not $r.json.gherkin.applicable)
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '不是 git repo 也找得到 .feature' {
        New-DcProject -NoGit
        try {
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-Equal 1 @($r.json.gherkin.features).Count
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'delivery-check / 交付一節' {

    It-Should '沒有「## 交付」一節 → 紅' {
        New-DcProject -spec $DcSpecBody
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('no-delivery-section' -in $r.codes) "codes: $($r.codes -join ',')"
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '最後那一節沒寫殘留風險 → 紅（「無」也要寫出來）' {
        New-DcProject -spec ($DcSpecBody + "`n## 交付 —— 2026-10-29`n`n- 怎麼驗的：dotnet test`n")
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('delivery-no-risk-line' -in $r.codes) "codes: $($r.codes -join ',')"
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '@manual 的 scenario 沒寫進交付 → 紅；寫了「待人工驗證」→ 綠' {
        New-DcProject -feature ($DcFeature -replace '@regression', '@manual') -tests @('未出貨的訂單可以取消')
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit "stdout: $($r.stdout)"
            Assert-True ('delivery-missing-risk' -in $r.codes)
            Assert-Match '已出貨的訂單不能取消' (@($r.json.delivery.missing) -join ' ')

            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($DcSpecBody + ($DcDelivery -replace '殘留風險：無', "殘留風險：`n  - 待人工驗證：已出貨的訂單不能取消"))
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "寫了還是紅；stdout: $($r.stdout)"
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '早幾輪「接受不修」的必修只留在快照裡，也要寫進交付' {
        # 「上一輪必修的交代」只涵蓋上一輪：第 1 輪接受不修的，到第 3 輪的 review.md 已經看不到了
        New-DcProject
        try {
            Write-DcFile 'bdd-docs/cancel-order/reviews/20261029-010000.md' ($DcReviewFail + "`n## 上一輪必修的交代`n- src/Orders/Refund.cs:8 —— 退款金額四捨五入：接受不修 —— 使用者說月底統一調帳`n")
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit "快照裡接受不修的沒列也過了；stdout: $($r.stdout)"
            Assert-Match 'Refund\.cs' (@($r.json.delivery.missing) -join ' ')

            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($DcSpecBody + ($DcDelivery -replace '殘留風險：無', '殘留風險：Refund.cs:8 退款四捨五入接受不修（月底調帳）'))
            Assert-Equal 0 (Invoke-Dc).exit '寫了檔名還是紅'
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '前幾次迭代的交付已經列過的，不必再列一次' {
        $spec = $DcSpecBody + "`n## 交付 —— 2026-10-01`n`n- 殘留風險：待人工驗證：已出貨的訂單不能取消`n`n## 迭代 2 —— 加退款`n" + $DcDelivery
        New-DcProject -spec $spec -feature ($DcFeature -replace '@regression', '@manual') -tests @('未出貨的訂單可以取消')
        try {
            $r = Invoke-Dc @{ Json = $true }
            Assert-True ('delivery-missing-risk' -notin $r.codes) "前一次交付列過的又被要求一次；codes: $($r.codes -join ',')"
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '要列的項目很多時，收據有界：只列前 5 項，其餘給數量' {
        New-DcProject
        try {
            $lines = (1..8 | ForEach-Object { "- src/M$_.cs:1 —— 問題 $_：接受不修 —— 理由 $_" }) -join "`n"
            Write-DcFile 'bdd-docs/cancel-order/review.md' ($DcReviewPass + "`n## 上一輪必修的交代`n$lines`n")
            $r = Invoke-Dc
            $p = @($r.json.problems | Where-Object code -eq 'delivery-missing-risk')[0]
            Assert-Equal 5 @($p.items).Count
            Assert-Equal 3 $p.omitted
            Assert-Equal 8 @($r.json.delivery.missing).Count 'JSON 的 missing 是完整清單'
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'delivery-check / 審核' {

    It-Should '沒有 review.md → 紅（⑤ 沒跑過）' {
        New-DcProject -review ''
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('no-review' -in $r.codes)
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '審核 FAIL（使用者接受了這一版）：每一項必修沒寫進交付 → 紅；寫了 → 綠' {
        New-DcProject -review $DcReviewFail
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit 'FAIL 的必修沒列進殘留風險就放行了'
            Assert-Match 'CancelService\.cs:40' (@($r.json.delivery.missing) -join ' ')

            Write-DcFile 'bdd-docs/cancel-order/spec.md' ($DcSpecBody + ($DcDelivery -replace '殘留風險：無', '殘留風險：未修 src/Orders/CancelService.cs:40 已出貨的沒被擋下（使用者接受這一版）'))
            $r = Invoke-Dc
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
            Assert-Equal 'FAIL' $r.json.review.verdict
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'FAIL 卻解析不到任何 [必修] → 紅（不能當成「接受了」）' {
        New-DcProject -review "VERDICT: FAIL`n`n## 發現`n- 必修：CancelService 有問題`n"
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('review-fail-without-must' -in $r.codes)
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'delivery-check / 驗收條件' {

    It-Should '有 .feature 卻沒給結果檔 → 紅' {
        New-DcProject
        try {
            $r = Invoke-Dc -NoResults
            Assert-Equal 2 $r.exit
            Assert-True ('no-test-results' -in $r.codes)
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '最後一輪修正之後沒重跑測試（結果檔比改過的檔舊）→ 紅' {
        New-DcProject
        try {
            (Get-Item (Join-Path $DcRoot 'TestResults/run.trx')).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
            Write-DcFile 'src/Orders/CancelService.cs' 'class CancelService { /* 修正輪改過 */ }'
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit 'implementer 當時的綠燈被當成現在的'
            Assert-True ('gherkin' -in $r.codes)
            Assert-Match '結果檔比這些改過的檔舊' (@(@($r.json.problems | Where-Object code -eq 'gherkin')[0].items) -join ' ')
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '有一條 scenario 沒有測試 → 紅' {
        New-DcProject -tests @('未出貨的訂單可以取消')
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-Match '找不到這條 scenario 的測試：已出貨的訂單不能取消' (@(@($r.json.problems | Where-Object code -eq 'gherkin')[0].items) -join ' ')
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should 'spec 有 Gherkin、repo 裡卻找不到那個 feature-id 的 .feature → 紅' {
        New-DcProject -feature ($DcFeature -replace 'feature-id: cancel-order', 'feature-id: cancel-order-v2')
        try {
            $r = Invoke-Dc
            Assert-Equal 2 $r.exit
            Assert-True ('feature-not-found' -in $r.codes) "codes: $($r.codes -join ',')"
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It-Should '給的結果檔不存在 → 紅，不是當成沒給' {
        New-DcProject
        try {
            $r = Invoke-Dc @{ TestResults = 'TestResults/nope.trx' }
            Assert-Equal 2 $r.exit
            Assert-True ('test-results-missing' -in $r.codes)
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'delivery-check / 輸入錯誤' {

    It-Should 'feature-id 不合法（../）或找不到 spec.md → exit 1' {
        New-DcProject
        try {
            Assert-Equal 1 (Invoke-Dc @{ FeatureId = '../cancel-order' }).exit
            Assert-Equal 1 (Invoke-Dc @{ FeatureId = 'no-such-feature' }).exit
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'delivery-check / 前後端分成兩個 repo、工作流裝在外層' {

    It-Should '.feature 在巢狀 repo（workspace/frontend）裡 → 找得到，照樣綠' {
        # 根目錄的 git ls-files 不會走進巢狀 repo：以前這裡永遠是 feature-not-found，⑥ 交不出去。
        New-DcProject -NoGit
        Remove-Item (Join-Path $DcRoot 'tests') -Recurse -Force
        Write-DcFile 'frontend/tests/Features/CancelOrder.feature' $DcFeature
        # 巢狀的先建：反過來的話，根目錄的 repo 會把 frontend/ 的檔當成自己的追蹤進去。
        foreach ($d in @((Join-Path $DcRoot 'frontend'), $DcRoot)) {
            git -C $d init -q 2>$null; git -C $d add -A 2>$null
            git -C $d -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base 2>$null
        }
        Write-DcFile 'TestResults/run.trx' (New-DcTrx @('未出貨的訂單可以取消', '已出貨的訂單不能取消'))
        try {
            $r = Invoke-Dc
            Assert-True ('feature-not-found' -notin $r.codes) "巢狀 repo 裡的 .feature 沒找到：$($r.stdout)"
            Assert-Equal 0 $r.exit "stdout: $($r.stdout)"
        } finally { Remove-Item $DcRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
