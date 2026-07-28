# CLI Execution Policy

適用於具備 `shell` / terminal 工具的 doer 與 reviewer。

## Environment Rules

- `shell` 可能完全不可用；`dotnet build` / `dotnet test` 可能可用，也可能受 sandbox 限制。
- 不得使用 PowerShell cmdlets 或 shell built-in 探路，例如 `Get-ChildItem`、`New-Item`、`Write-Host`、`mkdir`、`echo`、`cd`、`dir`。
- 若 `dotnet` 命令失敗，改用 `read` + `search` 做靜態驗證，並在 evidence 中標明 `environment` 或 `review-incomplete`。

## File Creation Strategy

1. 直接用 `edit` 建立或更新檔案，不做前置 shell 探測。
2. 只有在 `edit` 因目錄不存在失敗時，才可嘗試 `shell` 建立目錄後重試。
3. 若 `shell` 也失敗，記錄失敗路徑、已完成項與 pending 項，回傳 `partial-completed` 或 `blocked`。

## Execution Recovery

- 執行失敗時先取得結構化摘要：command、exit code、total/passed/failed/skipped、前 3 個錯誤、log/trx path。
- 錯誤分類：package / build / test-framework / test-failure / runtime / environment-flaky / permission-path。
- 同一類可自動修正錯誤最多重試 3 次；environment / flaky 最多重試 1 次。
- 超過上限或需超出 safe-change envelope 時停止，回傳分類、已嘗試修正與 pending decision。

## Output Limits

- 不貼完整 build/test output、完整 log、secrets、connection strings 或大型 source artifact。
- 測試 evidence 只回傳摘要與 artifact path；必要錯誤最多列前 3 筆。

