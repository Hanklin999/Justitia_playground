-- Justitia's playground V2 hotfix
-- Fixes: column reference "a.paper_id" is ambiguous
-- Safe to run repeatedly. No data is deleted.

create or replace function public.get_attempt_payload(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_output jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select ea.*
  into v_attempt
  from public.exam_attempts as ea
  where ea.id = p_attempt_id
    and ea.user_id = v_user_id;

  if not found then
    raise exception 'Attempt not found';
  end if;

  if v_attempt.status = 'in_progress'
     and v_attempt.is_timed
     and now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
  end if;

  select jsonb_build_object(
    'attempt', jsonb_build_object(
      'id', v_attempt.id,
      'paper_id', v_attempt.paper_id,
      'attempt_mode', v_attempt.attempt_mode,
      'title', v_attempt.title,
      'is_timed', v_attempt.is_timed,
      'status', v_attempt.status,
      'duration_minutes', v_attempt.duration_minutes,
      'question_count', v_attempt.question_count,
      'points_per_question', v_attempt.points_per_question,
      'max_score', v_attempt.max_score,
      'started_at', v_attempt.started_at,
      'expires_at', v_attempt.expires_at,
      'submitted_at', v_attempt.submitted_at,
      'submit_reason', v_attempt.submit_reason,
      'selected_years', v_attempt.selected_years,
      'selected_subjects', v_attempt.selected_subjects,
      'selected_subsubjects', v_attempt.selected_subsubjects
    ),
    'paper', case
      when ep.paper_id is null then null
      else jsonb_build_object(
        'exam_year_roc', ep.exam_year_roc,
        'paper_order', ep.paper_order,
        'paper_code', ep.paper_code,
        'paper_title', ep.paper_title,
        'included_subjects', ep.included_subjects,
        'source_question_url', ep.source_question_url
      )
    end,
    'questions', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'question_id', q.question_id,
          'display_order', aq.display_order,
          'question_number', q.question_number,
          'question_text', q.question_text,
          'option_a', q.option_a,
          'option_b', q.option_b,
          'option_c', q.option_c,
          'option_d', q.option_d,
          'selected_answer', ans.selected_answer,
          'review_status', q.review_status,
          'subject_primary', q.subject_primary,
          'subsubject_primary', q.subsubject_primary,
          'is_starred', coalesce(ann.is_starred, false),
          'note_text', coalesce(ann.note_text, ''),
          'active_seconds', coalesce(act.active_seconds, 0)
        ) order by aq.display_order
      ),
      '[]'::jsonb
    )
  )
  into v_output
  from public.attempt_questions as aq
  join public.questions as q
    on q.question_id = aq.question_id
  left join public.exam_papers as ep
    on ep.paper_id = v_attempt.paper_id
  left join public.attempt_answers as ans
    on ans.attempt_id = aq.attempt_id
   and ans.question_id = aq.question_id
  left join public.question_annotations as ann
    on ann.user_id = v_user_id
   and ann.question_id = q.question_id
  left join public.attempt_question_activity as act
    on act.attempt_id = aq.attempt_id
   and act.question_id = q.question_id
  where aq.attempt_id = p_attempt_id
  group by ep.paper_id;

  return v_output;
end;
$$;

create or replace function public.get_attempt_result(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_output jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select ea.*
  into v_attempt
  from public.exam_attempts as ea
  where ea.id = p_attempt_id
    and ea.user_id = v_user_id;

  if not found then
    raise exception 'Attempt not found';
  end if;

  if v_attempt.status = 'in_progress'
     and v_attempt.is_timed
     and now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
  elsif v_attempt.status = 'in_progress' then
    raise exception 'Attempt is still in progress';
  end if;

  select jsonb_build_object(
    'attempt', jsonb_build_object(
      'id', v_attempt.id,
      'attempt_mode', v_attempt.attempt_mode,
      'title', v_attempt.title,
      'is_timed', v_attempt.is_timed,
      'status', v_attempt.status,
      'duration_minutes', v_attempt.duration_minutes,
      'question_count', v_attempt.question_count,
      'started_at', v_attempt.started_at,
      'expires_at', v_attempt.expires_at,
      'submitted_at', v_attempt.submitted_at,
      'submit_reason', v_attempt.submit_reason,
      'correct_count', v_attempt.correct_count,
      'unanswered_count', v_attempt.unanswered_count,
      'score', v_attempt.score,
      'max_score', v_attempt.max_score,
      'elapsed_seconds', v_attempt.elapsed_seconds,
      'selected_years', v_attempt.selected_years,
      'selected_subjects', v_attempt.selected_subjects,
      'selected_subsubjects', v_attempt.selected_subsubjects
    ),
    'paper', case
      when ep.paper_id is null then null
      else jsonb_build_object(
        'exam_year_roc', ep.exam_year_roc,
        'paper_order', ep.paper_order,
        'paper_code', ep.paper_code,
        'paper_title', ep.paper_title,
        'source_question_url', ep.source_question_url,
        'source_answer_url', ep.source_answer_url
      )
    end,
    'questions', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'question_id', q.question_id,
          'display_order', aq.display_order,
          'question_number', q.question_number,
          'question_text', q.question_text,
          'option_a', q.option_a,
          'option_b', q.option_b,
          'option_c', q.option_c,
          'option_d', q.option_d,
          'selected_answer', ans.selected_answer,
          'correct_answer', key.final_answer,
          'correct_answers', key.accepted_answers,
          'is_correct', coalesce(ans.selected_answer::text = any(key.accepted_answers), false),
          'is_unanswered', ans.selected_answer is null,
          'subject_primary', q.subject_primary,
          'subsubject_primary', q.subsubject_primary,
          'is_starred', coalesce(ann.is_starred, false),
          'note_text', coalesce(ann.note_text, ''),
          'active_seconds', coalesce(act.active_seconds, 0)
        ) order by aq.display_order
      ),
      '[]'::jsonb
    )
  )
  into v_output
  from public.attempt_questions as aq
  join public.questions as q
    on q.question_id = aq.question_id
  join private.question_answer_keys as key
    on key.question_id = q.question_id
  left join public.exam_papers as ep
    on ep.paper_id = v_attempt.paper_id
  left join public.attempt_answers as ans
    on ans.attempt_id = aq.attempt_id
   and ans.question_id = aq.question_id
  left join public.question_annotations as ann
    on ann.user_id = v_user_id
   and ann.question_id = q.question_id
  left join public.attempt_question_activity as act
    on act.attempt_id = aq.attempt_id
   and act.question_id = q.question_id
  where aq.attempt_id = p_attempt_id
  group by ep.paper_id;

  return v_output;
end;
$$;

revoke all on function public.get_attempt_payload(uuid) from public, anon;
revoke all on function public.get_attempt_result(uuid) from public, anon;
grant execute on function public.get_attempt_payload(uuid) to authenticated;
grant execute on function public.get_attempt_result(uuid) to authenticated;
