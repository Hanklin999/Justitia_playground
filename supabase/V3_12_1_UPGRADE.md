# v3.12.1 Supabase 升級

1. 在 Supabase SQL Editor 執行 `supabase/sql_editor_v3/28_v3_12_1_external_explanations.sql`。
2. 執行 `supabase/sql_editor_v3/29_verify_v3_12_1.sql`。
3. 第一個 count 應為 `43`，Bitly 與無效網址 count 應為 `0`，重疊區段 count 應為 `0`。
4. 部署前執行：

```powershell
npm.cmd install
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
```

## URL 維護

前端每次載入檢討頁時，會透過 RPC 讀取 Supabase 的最新版網址，因此更新網址不需要重新部署。

```sql
update public.external_explanation_links
set external_url = 'https://www.facebook.com/...',
    last_verified_at = now(),
    link_status = 'login_required',
    updated_at = now()
where coverage_year = 113
  and paper_type = 'civil'
  and question_start = 1
  and question_end = 25;
```

狀態建議：

- `active`：內容可直接開啟。
- `login_required`：連結可導向 Facebook，但可能要求登入。
- `unverified`、`broken`、`retired`：前端不顯示。

目前 seed 全部標為 `login_required`，因為自動化驗證只能確認短網址導向 Facebook，無法可靠確認每位使用者的 Facebook 登入與內容可見權限。

## 第三方內容邊界

本版本只保存來源名稱、網址、年份、卷別、題號範圍與驗證狀態；不抓取、不嵌入、不截圖、不 OCR、不摘要、不改寫第三方詳解，也不暗示合作或授權。
