-- Justitia's playground v3.12.0 verification
select
  to_regclass('public.attempt_answer_revisions') is not null as answer_revisions_ready,
  to_regclass('public.attempt_error_annotations') is not null as error_annotations_ready,
  to_regclass('public.user_question_review_state') is not null as spaced_review_ready;

select
  exists(select 1 from pg_proc where proname = 'save_attempt_confidence') as confidence_rpc,
  exists(select 1 from pg_proc where proname = 'save_error_annotation') as error_reason_rpc,
  exists(select 1 from pg_proc where proname = 'start_due_review_attempt') as due_review_rpc,
  exists(select 1 from pg_proc where proname = 'delete_my_attempt') as delete_attempt_rpc;

select
  count(*) as review_state_rows,
  count(*) filter (where next_review_at <= now()) as due_now
from public.user_question_review_state;
