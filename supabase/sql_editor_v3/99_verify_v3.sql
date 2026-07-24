select count(*) as papers from public.exam_papers where exam_year_roc between 105 and 114;
select count(*) as questions from public.questions where split_part(question_id,'-',1)::int between 105 and 114;
select count(*) as answer_keys from private.question_answer_keys where split_part(question_id,'-',1)::int between 105 and 114;
select count(*) as multiple_choice_questions from public.questions where question_type='multiple_choice';
select count(*) as bonus_questions from private.question_answer_keys where is_bonus;
select count(*) as cutoffs from public.exam_cutoffs where exam_year_roc between 105 and 114;
select count(*) as unclassified from public.questions where subject_primary='未分類';
select question_id,question_type,question_points,option_e from public.questions where question_id in ('105-2301-061','106-3301-063') order by question_id;
select question_id,accepted_answers,is_bonus,official_answer_status from private.question_answer_keys where official_answer_status<>'official_standard' order by question_id;
