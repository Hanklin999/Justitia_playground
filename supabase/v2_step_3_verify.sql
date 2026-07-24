-- Run after V2 step 1 and step 2.
select count(*) as papers from public.exam_papers;
select count(*) as questions from public.questions;
select count(*) as answer_keys from private.question_answer_keys;
select count(*) as subject_configs from public.subject_exam_config where is_active;
select count(*) as cutoffs from public.exam_cutoffs;

select
  question_id,
  original_answer,
  final_answer,
  accepted_answers,
  official_answer_status,
  official_notice_url
from private.question_answer_keys
where question_id = '111-2301-050';

select
  p.exam_year_roc,
  p.paper_code,
  q.subject_primary,
  q.subsubject_primary,
  count(*) as question_count
from public.questions q
join public.exam_papers p on p.paper_id = q.paper_id
where q.is_published
  and p.exam_year_roc between 110 and 114
group by p.exam_year_roc, p.paper_code, q.subject_primary, q.subsubject_primary
order by p.exam_year_roc, p.paper_code, q.subject_primary, q.subsubject_primary;
