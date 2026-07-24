-- Justitia's playground v3.1.0 verification

select
  count(*) filter (where column_name = 'exam_date') as exam_date_column,
  count(*) filter (where column_name = 'selected_paper_kinds') as paper_kinds_column,
  count(*) filter (where column_name = 'source_attempt_ids') as source_attempts_column,
  count(*) filter (where column_name = 'selection_strategy') as strategy_column
from information_schema.columns
where table_schema = 'public'
  and table_name = 'exam_attempts';

select
  to_regclass('public.attempt_question_annotations') is not null as exam_annotations_table,
  to_regclass('public.question_review_annotations') is not null as review_annotations_table;

select
  to_regprocedure('public.save_exam_annotation(uuid,text,boolean,text)') is not null as save_exam_annotation_rpc,
  to_regprocedure('public.save_review_annotation(text,boolean,text)') is not null as save_review_annotation_rpc,
  to_regprocedure('public.start_custom_subject_attempt(smallint[],text[],text[],integer,text,date)') is not null as custom_subject_rpc,
  to_regprocedure('public.start_review_attempt(uuid[],boolean,boolean,boolean,text)') is not null as review_builder_rpc;

select
  position('recent_scope_attempts' in pg_get_functiondef('public.start_custom_subject_attempt(smallint[],text[],text[],integer,text,date)'::regprocedure)) > 0 as recent_scope_attempts_present,
  position('limit 10' in lower(pg_get_functiondef('public.start_custom_subject_attempt(smallint[],text[],text[],integer,text,date)'::regprocedure))) > 0 as recent_attempt_limit_is_10,
  position('recent_wrong_pool' in pg_get_functiondef('public.start_custom_subject_attempt(smallint[],text[],text[],integer,text,date)'::regprocedure)) > 0 as recent_wrong_pool_present;

select selection_strategy, count(*)
from public.exam_attempts
group by selection_strategy
order by selection_strategy;

select
  count(*) as attempts,
  count(*) filter (where exam_date is null) as missing_exam_date,
  count(*) filter (where default_question_count is null) as missing_default_count,
  count(*) filter (where requested_question_count is null) as missing_requested_count
from public.exam_attempts;
