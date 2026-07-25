# 套用 v3.12.1

將此壓縮檔解壓縮後，把全部內容複製到 `Justitia_playground` 專案根目錄，再於 PowerShell 執行：

```powershell
python .\apply_v3_12_1.py
```

接著在 Supabase SQL Editor 依序執行：

1. `supabase/sql_editor_v3/28_v3_12_1_external_explanations.sql`
2. `supabase/sql_editor_v3/29_verify_v3_12_1.sql`

本機驗證：

```powershell
npm.cmd install
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
```

確認後提交：

```powershell
git add .
git commit -m "release: v3.12.1 external explanation links"
git push origin main
```

## 注意

- 腳本以目前 GitHub `main` 的 v3.12.0 結構為基準，遇到不一致的核心片段會停止，不會默默亂改。
- SQL 為 repeat-safe，可重跑。
- 111 年公法 1–20 題未在提供清單中，因此不建立未經確認的連結。
- 目前資料標記為 `login_required`，代表連結可導向 Facebook，但內容可見性可能取決於登入、貼文權限或 Facebook 狀態。
