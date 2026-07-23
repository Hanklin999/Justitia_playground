# Recovery from ERROR 42710

The first SQL run already created `public.attempt_status` and then stopped. Do not delete the enum or reset the project.

1. Open Supabase → SQL Editor.
2. Run `setup_all_v2_idempotent.sql` in full.
3. Verify:

```sql
select count(*) from public.exam_papers;                -- 8
select count(*) from public.questions;                  -- 600
select count(*) from private.question_answer_keys;      -- 600
```

The v2 setup is repeat-safe for enums, tables, indexes, trigger, policies, seeds, functions, grants, and the cron job. Existing attempts and answers are preserved.
