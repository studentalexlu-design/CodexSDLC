# test-impact-scope.ps1
# impact-scope 排出來的前 N 名是讀者唯一會讀的檔（read-budget 寫明「不得讀清單外檔案」）。
# 只在註解、TODO 或註解掉的舊碼裡提到關鍵字的檔若照樣加分，就會佔掉真的實作的名額 ——
# 而讀者不會知道還有別的檔沒讀到。

$IsScript = (Resolve-Path '.codex/scripts/impact-scope.ps1').Path
$IsRoot   = Join-Path ([IO.Path]::GetTempPath()) 'codex-impact-scope-tests'
$IsUtf8   = [Text.UTF8Encoding]::new($false)

Describe-Suite 'impact-scope / 內容命中只算會被編譯的程式碼' {

    It-Should '只在註解、TODO 裡提到關鍵字的檔不加分；程式碼與字串裡提到的照樣加分' {
        Remove-Item $IsRoot -Recurse -Force -ErrorAction SilentlyContinue
        $files = @{
            'Legacy/Dead.cs' = "// TODO: 取消訂單要退運費`n/* 取消訂單 的舊做法`n   CancelOld(); */`npublic class A { }"
            'Live/Real.cs'   = "public class B { void M() { Log(`"取消訂單`"); } }"
        }
        foreach ($k in $files.Keys) {
            $p = Join-Path $IsRoot $k
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($p, $files[$k], $IsUtf8)
        }
        try {
            # 刻意指向不存在的索引：只驗內容命中（index-used = false 時只剩檔名與內容兩項）
            $r = Invoke-Script $IsScript -Params @{ Root = $IsRoot; Keywords = '取消訂單'; IndexPath = (Join-Path $IsRoot 'no-index.json') }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            $c = @(($r.stdout | ConvertFrom-Json).candidates)
            Assert-True (@($c | Where-Object { $_.file -eq 'Live/Real.cs' }).Count -eq 1) '程式碼（字串）裡的關鍵字沒有加分 —— 字串被當成註解剝掉了'
            Assert-True (@($c | Where-Object { $_.file -eq 'Legacy/Dead.cs' }).Count -eq 0) '只在註解裡提到關鍵字的檔被排進候選'
        } finally { Remove-Item $IsRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function New-IsFiles([hashtable]$files) {
    foreach ($k in $files.Keys) {
        $p = Join-Path $IsRoot $k
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, $files[$k], $IsUtf8)
    }
}

Describe-Suite 'impact-scope / git repo 先用 git grep 篩（只讀有關鍵字的檔）' {

    It-Should '這套流程不 commit：未追蹤的新檔照樣找得到；git grep 讀不到的 UTF-16 .sql 也照樣找得到' {
        Remove-Item $IsRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-IsFiles @{ 'src/Old.cs' = 'public class Old { void M() { Log("CancelOrder"); } }'; 'src/Other.cs' = 'public class Other { }' }
        Push-Location $IsRoot
        try { git init -q 2>$null; git add -A 2>$null; git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m base 2>$null } finally { Pop-Location }
        New-IsFiles @{ 'src/NewOne.cs' = 'public class NewOne { void M() { Run("CancelOrder"); } }' }   # 上一個需求新增、還沒 commit
        # SSMS 舊版存 .sql 的預設是 UTF-16 LE（帶 BOM）—— git grep 當它是二進位檔，比對不到。
        New-Item -ItemType Directory -Path (Join-Path $IsRoot 'db') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $IsRoot 'db/usp_Refund.sql'), "EXEC dbo.CancelOrder @id`r`n", [Text.UnicodeEncoding]::new($false, $true))
        try {
            $r = Invoke-Script $IsScript -Params @{ Root = $IsRoot; Keywords = 'cancelorder'; IndexPath = (Join-Path $IsRoot 'no-index.json'); TopN = 20 }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            $j = $r.stdout | ConvertFrom-Json
            Assert-Equal 'git-grep' $j.'content-scan' 'git repo 裡沒有走 git grep'
            $files = @($j.candidates | ForEach-Object { $_.file })
            foreach ($want in 'src/Old.cs', 'src/NewOne.cs', 'db/usp_Refund.sql') { Assert-True ($want -in $files) "$want 沒被找到：$($files -join '、')" }
            Assert-True ('src/Other.cs' -notin $files) '沒有關鍵字的檔被排進來了'
        } finally { Remove-Item $IsRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe-Suite 'impact-scope / 候選檔帶著索引裡它的 types、bases、DI（sa-analyst 不必讀 index.json）' {

    It-Should '實作介面的候選帶 bases 與「誰把它掛上去」；組合根帶「它掛了什麼」' {
        Remove-Item $IsRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-IsFiles @{
            'App/App.csproj' = '<Project Sdk="Microsoft.NET.Sdk"></Project>'
            'App/Orders/OrderService.cs' = "namespace App.Orders;`npublic interface IOrderService { }`npublic class OrderService : IOrderService`n{`n    public void Cancel(int id) { }`n}"
            'App/Startup.cs' = "public class Startup`n{`n    public void Configure(IServiceCollection services) { services.AddScoped<IOrderService, OrderService>(); }`n}"
        }
        $out = Join-Path $IsRoot '.out'
        try {
            $r = Invoke-Script (Resolve-Path '.codex/scripts/repo-index.ps1').Path -Params @{ Root = $IsRoot; OutDir = $out }
            Assert-Equal 0 $r.exit "repo-index：$($r.stderr)"
            $r = Invoke-Script $IsScript -Params @{ Root = $IsRoot; Keywords = 'OrderService'; IndexPath = (Join-Path $out 'index.json') }
            Assert-Equal 0 $r.exit "stderr: $($r.stderr)"
            $c = @(($r.stdout | ConvertFrom-Json).candidates)
            $svc = $c | Where-Object { $_.file -eq 'App/Orders/OrderService.cs' }
            Assert-True ($null -ne $svc) 'OrderService.cs 不在候選裡'
            Assert-True ('OrderService : IOrderService' -in @($svc.bases)) "沒帶 bases：$(ConvertTo-Json $svc -Compress)"
            Assert-Match 'AddScoped<IOrderService, OrderService> @ App/Startup\.cs' (@($svc.registered) -join '|')
            $root = $c | Where-Object { $_.file -eq 'App/Startup.cs' }
            Assert-Match 'AddScoped<IOrderService, OrderService>' (@($root.registers) -join '|')
        } finally { Remove-Item $IsRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
