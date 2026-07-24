# Supabase v3.12.0 升級

既有 v3.1.0 資料庫只需執行：

1. `sql_editor_v3/26_v3_12_pacing_learning.sql`
2. `sql_editor_v3/27_verify_v3_12.sql`

第一份 migration 會新增：

- `attempt_answer_revisions`
- `attempt_error_annotations`
- `user_question_review_state`
- 信心、錯因、今日複習、學習洞察與 attempt 刪除 RPC
- 現有完成紀錄的間隔複習 backfill

執行後驗證頁應顯示三張表與四個 RPC 都是 `true`。
