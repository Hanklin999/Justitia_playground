# Supabase V2 設定

Publishable Key 可放在瀏覽器；真正的資料安全依賴 RLS 與 Database Functions。不要把 Secret Key 或 `service_role` key 放進前端、GitHub 或聊天室。

## 1. V1 升級 V2

到 Supabase Dashboard → **SQL Editor**，建議分兩次執行：

1. `supabase/v2_step_1_schema.sql`：資料表、欄位、RLS、RPC、計時與歷史分析。
2. `supabase/v2_step_2_seed.sql`：110–114 年 20 卷、1,500 題與 private answer keys。

兩步完成後執行 `supabase/v2_step_3_verify.sql`。`supabase/setup_v2.sql` 是前兩步合併版，SQL Editor 能正常承受大型查詢時也可一次執行。

Migration 採 repeat-safe／upsert 寫法，可接在既有 V1 schema 後執行，並保留既有使用者與歷史紀錄。

完成後驗證：

```sql
select count(*) as papers from public.exam_papers;
select count(*) as questions from public.questions;
select count(*) as answer_keys from private.question_answer_keys;
select count(*) as subject_configs from public.subject_exam_config;
select exam_year_roc, judicial_cutoff, lawyer_cutoff
from public.exam_cutoffs
order by exam_year_roc;
```

預期：

- `papers = 20`
- `questions = 1500`
- `answer_keys = 1500`
- `subject_configs > 0`
- `exam_cutoffs = 5` 個年度
- `111-2301-050.accepted_answers = {A,B}`

## 2. Email Magic Link

Supabase Dashboard → **Authentication → URL Configuration**：

### 本機開發

- Site URL：`http://localhost:3000`
- Redirect URLs：`http://localhost:3000/**`

### Netlify

- Site URL：`https://exam-justitia-playground.netlify.app`
- Redirect URLs：
  - `https://exam-justitia-playground.netlify.app/**`
  - `https://**--exam-justitia-playground.netlify.app/**`

登入信會導回 `/auth/complete`，成功後前往 `/practice`。

## 3. 本機驗證

```powershell
npm.cmd install
npm.cmd run check:supabase
npm.cmd run build
npm.cmd run dev
```

## 4. V2 安全設計

- `public.questions` 不存官方答案。
- 官方答案存於 `private.question_answer_keys`，並以 `accepted_answers` 支援複數有效答案。
- 開始正式卷、自組卷、錯題重刷、保存答案、保存筆記、累積題目時間、交卷與計分全部透過 RPC。
- 使用者只能讀取自己的 attempt、作答、星號、筆記與題目活動。
- 正式計時使用 server-generated `expires_at`，不是依賴使用者電腦時間。
- 自組卷與錯題卷會把抽出的題目順序固定在 `attempt_questions`。
