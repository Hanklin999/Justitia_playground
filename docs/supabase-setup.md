# Supabase 設定

Project URL 與 Publishable Key 已寫入本機 `.env.local`。Publishable Key 可放在瀏覽器；真正的資料安全依賴 RLS 與 Database Functions。不要把 Secret Key 或 `service_role` key 放進前端、GitHub 或聊天室。

## 1. 建立資料庫

在 Supabase Dashboard → **SQL Editor**，最簡單是直接執行：

```text
supabase/setup_all.sql
```

它依序包含：

1. `supabase/migrations/0001_initial_schema.sql`
2. `supabase/migrations/0002_seed_113_114.sql`
3. `supabase/migrations/0003_timeout_cron.sql`

第三份 migration 會每分鐘完成已逾時的考試紀錄。即使使用者關掉瀏覽器，逾時紀錄仍會被標記為 `timed_out` 並完成計分。

執行完成後，可用以下 SQL 驗證：

```sql
select count(*) as papers from public.exam_papers;
select count(*) as questions from public.questions;
select count(*) as answer_keys from private.question_answer_keys;
select jobname, schedule, command from cron.job
where jobname = 'justitia-finalize-expired-attempts';
```

預期：

- `papers = 8`
- `questions = 600`
- `answer_keys = 600`
- Cron job 共 1 筆

## 2. Email Magic Link

Supabase Dashboard → **Authentication → URL Configuration**：

### 本機開發

- Site URL：`http://localhost:3000`
- Redirect URLs：`http://localhost:3000/**`

### Netlify 上線後

將 Site URL 改為正式 `https://<site-name>.netlify.app`，並加入：

- `https://<site-name>.netlify.app/**`
- `https://**--<site-name>.netlify.app/**`（Deploy Preview）

登入信會導回 `/auth/complete`，成功後前往 `/practice`。

## 3. 本機測試

```bash
npm install
npm run check:supabase
npm run dev
```

`check:supabase` 會嘗試讀取一筆 `exam_papers`。若 migration 尚未建立，會回傳 API 錯誤。

## 4. 安全設計

- `public.questions` 不存官方答案。
- 官方答案存於 `private.question_answer_keys`，前端不能直接讀取。
- 使用者不能直接新增或修改 `exam_attempts`、`attempt_answers`。
- 開始考試、保存答案、交卷與計分全部透過 Security Definer RPC。
- `duration_minutes`、題數、配分與滿分會在開始考試時寫入 Log 快照。
- 成績頁只在考試已交卷或逾時後回傳正確答案。
