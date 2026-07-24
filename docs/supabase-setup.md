# Supabase v3.0.0 設定

Publishable Key 可供瀏覽器使用；資料安全依賴 RLS 與 Database Functions。不要把 Secret Key 或 `service_role` key 放進前端、GitHub 或公開文件。

## V2／V2.1 升級到 v3.0.0

Supabase SQL Editor 有單次查詢大小限制，因此不要一次貼整個 2.4 MB seed。請依序執行 `supabase/sql_editor_v3/`：

1. `00_v3_schema_and_rpc.sql`
2. `01_exam_papers.sql`
3. `02_questions.sql` 至 `15_questions.sql`
4. `16_answers.sql` 至 `22_answers.sql`
5. `23_cutoffs_105_114.sql`
6. `99_verify_v3.sql`

每個檔案都可安全重跑。Migration 使用 `if not exists`、`create or replace`、policy 重建與 upsert，不會刪除既有使用者紀錄。

預期驗證：

```text
papers = 40
questions = 2968
answer_keys = 2968
multiple_choice = 64
bonus_questions = 3
cutoff_years = 10
```

完整操作：`supabase/V3_UPGRADE.md`

## Email Magic Link

Supabase Dashboard → Authentication → URL Configuration：

### 本機

- Site URL：`http://localhost:3000`
- Redirect URLs：`http://localhost:3000/**`

### Netlify

- Site URL：`https://exam-justitia-playground.netlify.app`
- Redirect URLs：
  - `https://exam-justitia-playground.netlify.app/**`
  - `https://**--exam-justitia-playground.netlify.app/**`

登入信會導回 `/auth/complete`，成功後前往 `/practice`。

## 安全設計

- `public.questions` 不含官方答案。
- 官方答案位於 `private.question_answer_keys`，支援複數有效答案與送分。
- 開始測驗、載入題目、保存答案／筆記、累積時間、交卷與計分均透過 RPC。
- 使用者只能讀寫自己的 attempt 與 activity。
- 正式計時使用 server-generated `expires_at`。
- 交卷後 `get_attempt_result` 才回傳答案與完整選項。
