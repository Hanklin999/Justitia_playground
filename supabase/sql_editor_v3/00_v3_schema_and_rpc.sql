-- Justitia's playground v3.0.0 schema and RPC upgrade
-- Ten-year question model, five-option multiple choice, partial scoring,
-- complete historical option review, and variable per-question points.
-- Repeat-safe and preserves existing attempts.

create schema if not exists private;

alter table public.questions add column if not exists option_e text;
alter table public.questions add column if not exists question_points numeric(6,2) not null default 2;

alter table public.questions drop constraint if exists questions_question_type_check;
alter table public.questions add constraint questions_question_type_check
  check (question_type in ('single_choice','multiple_choice'));

alter table private.question_answer_keys drop constraint if exists question_answer_keys_original_answer_check;
alter table private.question_answer_keys drop constraint if exists question_answer_keys_final_answer_check;
alter table private.question_answer_keys drop constraint if exists question_answer_keys_accepted_answers_check;
alter table private.question_answer_keys alter column original_answer type text using original_answer::text;
alter table private.question_answer_keys alter column final_answer type text using final_answer::text;
alter table private.question_answer_keys add column if not exists is_bonus boolean not null default false;

alter table public.attempt_answers drop constraint if exists attempt_answers_selected_answer_check;
alter table public.attempt_answers alter column selected_answer type text using selected_answer::text;

create or replace function private.normalize_answer(p_answer text)
returns text
language sql
immutable
as $$
  select coalesce(string_agg(letter, '' order by letter), '')
  from (
    select distinct upper(ch) as letter
    from regexp_split_to_table(coalesce(p_answer,''), '') as ch
    where upper(ch) ~ '^[A-E]$'
  ) s;
$$;

create or replace function private.score_question_answer(p_question_id text, p_selected_answer text)
returns numeric
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_type text;
  v_points numeric;
  v_bonus boolean;
  v_accepted text[];
  v_selected text;
  v_answer text;
  v_mismatch integer;
  v_score numeric := 0;
begin
  select q.question_type, q.question_points, k.is_bonus,
         case when cardinality(k.accepted_answers)>0 then k.accepted_answers else array[k.final_answer] end
  into v_type, v_points, v_bonus, v_accepted
  from public.questions q
  join private.question_answer_keys k on k.question_id=q.question_id
  where q.question_id=p_question_id;

  if not found then return 0; end if;
  if v_bonus then return v_points; end if;

  v_selected := private.normalize_answer(p_selected_answer);
  if v_selected='' then return 0; end if;

  foreach v_answer in array v_accepted loop
    v_answer := private.normalize_answer(v_answer);
    if v_type='single_choice' then
      if v_selected=v_answer then v_score:=greatest(v_score,v_points); end if;
    else
      select count(*) into v_mismatch
      from unnest(array['A','B','C','D','E']) letter
      where (position(letter in v_selected)>0) is distinct from (position(letter in v_answer)>0);
      v_score := greatest(v_score,
        case v_mismatch when 0 then v_points when 1 then v_points*0.6 when 2 then v_points*0.2 else 0 end
      );
    end if;
  end loop;
  return round(v_score,2);
end;
$$;

create or replace function private.finalize_exam_attempt(
  p_attempt_id uuid,
  p_requested_reason public.submit_reason default null
)
returns public.exam_attempts
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_attempt public.exam_attempts%rowtype;
  v_reason public.submit_reason;
  v_correct integer;
  v_unanswered integer;
  v_score numeric;
begin
  select ea.* into v_attempt from public.exam_attempts ea where ea.id=p_attempt_id for update;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status<>'in_progress' then return v_attempt; end if;

  v_reason := case
    when v_attempt.is_timed and now()>=v_attempt.expires_at then 'timeout'::public.submit_reason
    else coalesce(p_requested_reason,'manual'::public.submit_reason)
  end;

  select
    count(*) filter (where scored.earned_points>=q.question_points),
    count(*) filter (where ans.selected_answer is null and not key.is_bonus),
    coalesce(sum(scored.earned_points),0)
  into v_correct,v_unanswered,v_score
  from public.attempt_questions aq
  join public.questions q on q.question_id=aq.question_id
  join private.question_answer_keys key on key.question_id=q.question_id
  left join public.attempt_answers ans on ans.attempt_id=aq.attempt_id and ans.question_id=aq.question_id
  cross join lateral (select private.score_question_answer(q.question_id,ans.selected_answer) earned_points) scored
  where aq.attempt_id=p_attempt_id;

  update public.exam_attempts set
    status=case when v_reason='timeout' then 'timed_out'::public.attempt_status else 'submitted'::public.attempt_status end,
    submit_reason=v_reason,
    submitted_at=case when v_reason='timeout' then expires_at else now() end,
    correct_count=v_correct,
    unanswered_count=v_unanswered,
    score=v_score,
    elapsed_seconds=greatest(0,extract(epoch from ((case when v_reason='timeout' then expires_at else now() end)-started_at))::integer)
  where id=p_attempt_id returning * into v_attempt;
  return v_attempt;
end;
$$;

create or replace function public.start_subject_attempt(
  p_years smallint[], p_subjects text[], p_subsubjects text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid:=auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_started timestamptz:=clock_timestamp();
  v_count integer;
  v_total_seconds integer;
  v_max_score numeric;
  v_title text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if coalesce(cardinality(p_years),0)=0 then raise exception 'Select at least one year'; end if;
  if coalesce(cardinality(p_subjects),0)=0 and coalesce(cardinality(p_subsubjects),0)=0 then raise exception 'Select at least one subject'; end if;

  select string_agg(label,'＋' order by display_order) into v_title
  from (
    select distinct c.display_order,coalesce(c.subsubject_name,c.subject_name) label
    from public.subject_exam_config c
    where c.is_active and (
      (c.subsubject_name is not null and c.subsubject_name=any(coalesce(p_subsubjects,'{}'::text[])))
      or (c.subsubject_name is null and c.subject_name=any(coalesce(p_subjects,'{}'::text[]))
          and not (c.subject_name='民法' and coalesce(cardinality(p_subsubjects),0)>0))
    )
  ) labels;
  if v_title is null then raise exception 'No matching subject configuration'; end if;

  insert into public.exam_attempts(user_id,paper_id,attempt_mode,title,is_timed,selected_years,selected_subjects,selected_subsubjects,duration_minutes,question_count,points_per_question,max_score,started_at,expires_at)
  values(v_user,null,'subject_pool',v_title||'｜自組測驗',true,p_years,p_subjects,coalesce(p_subsubjects,'{}'),1,1,2,2,v_started,v_started+interval '1 minute')
  returning * into v_attempt;

  with configs as (
    select c.*,
      case when cardinality(p_years)=1 then (
        select count(*)::smallint
        from public.questions q2 join public.exam_papers p2 on p2.paper_id=q2.paper_id
        where q2.is_published and p2.exam_year_roc=p_years[1]
          and q2.subject_primary=c.subject_name
          and (c.subsubject_name is null or q2.subsubject_primary=c.subsubject_name)
      ) else c.target_question_count end effective_target_count
    from public.subject_exam_config c
    where c.is_active and (
      (c.subsubject_name is not null and c.subsubject_name=any(coalesce(p_subsubjects,'{}'::text[])))
      or (c.subsubject_name is null and c.subject_name=any(coalesce(p_subjects,'{}'::text[]))
          and not (c.subject_name='民法' and coalesce(cardinality(p_subsubjects),0)>0))
    )
  ), candidates as (
    select q.question_id,c.config_key,c.display_order,c.effective_target_count,
           row_number() over(partition by c.config_key order by random()) rn
    from configs c
    join public.questions q on q.subject_primary=c.subject_name
      and (c.subsubject_name is null or q.subsubject_primary=c.subsubject_name)
    join public.exam_papers p on p.paper_id=q.paper_id
    where q.is_published and p.exam_year_roc=any(p_years)
  ), chosen as (
    select * from candidates where rn<=effective_target_count
  )
  insert into public.attempt_questions(attempt_id,question_id,display_order)
  select v_attempt.id,question_id,row_number() over(order by display_order,random())::smallint from chosen;

  select count(*),
         ceil(sum(p.duration_minutes*60.0/p.question_count))::integer,
         sum(q.question_points)
  into v_count,v_total_seconds,v_max_score
  from public.attempt_questions aq
  join public.questions q on q.question_id=aq.question_id
  join public.exam_papers p on p.paper_id=q.paper_id
  where aq.attempt_id=v_attempt.id;

  if coalesce(v_count,0)=0 then
    delete from public.exam_attempts where id=v_attempt.id;
    raise exception 'No published questions match the selection';
  end if;
  v_total_seconds:=greatest(v_total_seconds,60);
  update public.exam_attempts set
    duration_minutes=ceil(v_total_seconds/60.0)::smallint,
    question_count=v_count,
    max_score=v_max_score,
    expires_at=v_started+make_interval(secs=>v_total_seconds)
  where id=v_attempt.id returning * into v_attempt;
  return jsonb_build_object('attempt_id',v_attempt.id,'resumed',false,'started_at',v_attempt.started_at,'expires_at',v_attempt.expires_at,'duration_minutes',v_attempt.duration_minutes,'question_count',v_attempt.question_count);
end;
$$;

create or replace function public.start_wrong_review_attempt(
  p_years smallint[] default null, p_subjects text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid:=auth.uid(); v_attempt public.exam_attempts%rowtype; v_count integer; v_max numeric; v_started timestamptz:=clock_timestamp();
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  insert into public.exam_attempts(user_id,paper_id,attempt_mode,title,is_timed,selected_years,selected_subjects,duration_minutes,question_count,points_per_question,max_score,started_at,expires_at)
  values(v_user,null,'wrong_review','錯題重刷｜不計時',false,coalesce(p_years,'{}'),coalesce(p_subjects,'{}'),0,1,2,2,v_started,null) returning * into v_attempt;

  with wrong as (
    select distinct aq.question_id
    from public.exam_attempts old_attempt
    join public.attempt_questions aq on aq.attempt_id=old_attempt.id
    join public.questions q on q.question_id=aq.question_id
    join private.question_answer_keys key on key.question_id=q.question_id
    left join public.attempt_answers ans on ans.attempt_id=aq.attempt_id and ans.question_id=aq.question_id
    join public.exam_papers p on p.paper_id=q.paper_id
    where old_attempt.user_id=v_user and old_attempt.status<>'in_progress'
      and not key.is_bonus
      and private.score_question_answer(q.question_id,ans.selected_answer)<q.question_points
      and (p_years is null or cardinality(p_years)=0 or p.exam_year_roc=any(p_years))
      and (p_subjects is null or cardinality(p_subjects)=0 or q.subject_primary=any(p_subjects))
  )
  insert into public.attempt_questions(attempt_id,question_id,display_order)
  select v_attempt.id,question_id,row_number() over(order by random())::smallint from wrong;

  select count(*),sum(q.question_points) into v_count,v_max
  from public.attempt_questions aq join public.questions q on q.question_id=aq.question_id
  where aq.attempt_id=v_attempt.id;
  if v_count=0 then delete from public.exam_attempts where id=v_attempt.id;raise exception 'No wrong questions match the filters';end if;
  update public.exam_attempts set question_count=v_count,max_score=v_max where id=v_attempt.id returning * into v_attempt;
  return jsonb_build_object('attempt_id',v_attempt.id,'resumed',false,'started_at',v_attempt.started_at,'expires_at',null,'duration_minutes',0,'question_count',v_count);
end;
$$;

create or replace function public.save_attempt_answer(p_attempt_id uuid,p_question_id text,p_selected_answer text)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  v_user uuid:=auth.uid(); v_attempt public.exam_attempts%rowtype; v_saved timestamptz:=clock_timestamp();
  v_type text; v_option_e text; v_answer text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select ea.* into v_attempt from public.exam_attempts ea where ea.id=p_attempt_id and ea.user_id=v_user for update;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status<>'in_progress' then return jsonb_build_object('ok',false,'status',v_attempt.status);end if;
  if v_attempt.is_timed and now()>=v_attempt.expires_at then v_attempt:=private.finalize_exam_attempt(p_attempt_id,'timeout');return jsonb_build_object('ok',false,'status',v_attempt.status);end if;
  select q.question_type,q.option_e into v_type,v_option_e from public.questions q
  join public.attempt_questions aq on aq.question_id=q.question_id
  where aq.attempt_id=p_attempt_id and q.question_id=p_question_id;
  if not found then raise exception 'Question is not part of this attempt'; end if;

  v_answer:=private.normalize_answer(p_selected_answer);
  if v_answer='' then
    delete from public.attempt_answers where attempt_id=p_attempt_id and question_id=p_question_id;
    return jsonb_build_object('ok',true,'status','in_progress','saved_at',v_saved);
  end if;
  if v_type='single_choice' and length(v_answer)<>1 then raise exception 'Single-choice question accepts one option';end if;
  if v_type='multiple_choice' and (length(v_answer)<1 or length(v_answer)>5) then raise exception 'Invalid multiple-choice answer';end if;
  if position('E' in v_answer)>0 and v_option_e is null then raise exception 'Option E is unavailable';end if;

  insert into public.attempt_answers(attempt_id,question_id,selected_answer,saved_at)
  values(p_attempt_id,p_question_id,v_answer,v_saved)
  on conflict(attempt_id,question_id) do update set selected_answer=excluded.selected_answer,saved_at=excluded.saved_at;
  return jsonb_build_object('ok',true,'status','in_progress','saved_at',v_saved);
end;
$$;

create or replace function public.get_attempt_payload(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  v_user uuid:=auth.uid(); v_attempt public.exam_attempts%rowtype; v_output jsonb;
begin
  if v_user is null then raise exception 'Authentication required';end if;
  select ea.* into v_attempt from public.exam_attempts ea where ea.id=p_attempt_id and ea.user_id=v_user;
  if not found then raise exception 'Attempt not found';end if;
  if v_attempt.status='in_progress' and v_attempt.is_timed and now()>=v_attempt.expires_at then v_attempt:=private.finalize_exam_attempt(p_attempt_id,'timeout');end if;
  select jsonb_build_object(
    'attempt',jsonb_build_object('id',v_attempt.id,'paper_id',v_attempt.paper_id,'attempt_mode',v_attempt.attempt_mode,'title',v_attempt.title,'is_timed',v_attempt.is_timed,'status',v_attempt.status,'duration_minutes',v_attempt.duration_minutes,'question_count',v_attempt.question_count,'points_per_question',v_attempt.points_per_question,'max_score',v_attempt.max_score,'started_at',v_attempt.started_at,'expires_at',v_attempt.expires_at,'submitted_at',v_attempt.submitted_at,'submit_reason',v_attempt.submit_reason,'selected_years',v_attempt.selected_years,'selected_subjects',v_attempt.selected_subjects,'selected_subsubjects',v_attempt.selected_subsubjects),
    'paper',case when ep.paper_id is null then null else jsonb_build_object('exam_year_roc',ep.exam_year_roc,'paper_order',ep.paper_order,'paper_code',ep.paper_code,'paper_title',ep.paper_title,'included_subjects',ep.included_subjects,'source_question_url',ep.source_question_url) end,
    'questions',coalesce(jsonb_agg(jsonb_build_object(
      'question_id',q.question_id,'display_order',aq.display_order,'question_number',q.question_number,'question_type',q.question_type,'question_points',q.question_points,
      'question_text',q.question_text,'option_a',q.option_a,'option_b',q.option_b,'option_c',q.option_c,'option_d',q.option_d,'option_e',q.option_e,
      'selected_answer',ans.selected_answer,'review_status',q.review_status,'subject_primary',q.subject_primary,'subsubject_primary',q.subsubject_primary,
      'is_starred',coalesce(ann.is_starred,false),'note_text',coalesce(ann.note_text,''),'active_seconds',coalesce(act.active_seconds,0)
    ) order by aq.display_order),'[]'::jsonb)
  ) into v_output
  from public.attempt_questions aq
  join public.questions q on q.question_id=aq.question_id
  left join public.exam_papers ep on ep.paper_id=v_attempt.paper_id
  left join public.attempt_answers ans on ans.attempt_id=aq.attempt_id and ans.question_id=aq.question_id
  left join public.question_annotations ann on ann.user_id=v_user and ann.question_id=q.question_id
  left join public.attempt_question_activity act on act.attempt_id=aq.attempt_id and act.question_id=q.question_id
  where aq.attempt_id=p_attempt_id group by ep.paper_id;
  return v_output;
end;
$$;

create or replace function public.get_attempt_result(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  v_user uuid:=auth.uid(); v_attempt public.exam_attempts%rowtype; v_output jsonb;
begin
  if v_user is null then raise exception 'Authentication required';end if;
  select ea.* into v_attempt from public.exam_attempts ea where ea.id=p_attempt_id and ea.user_id=v_user;
  if not found then raise exception 'Attempt not found';end if;
  if v_attempt.status='in_progress' and v_attempt.is_timed and now()>=v_attempt.expires_at then v_attempt:=private.finalize_exam_attempt(p_attempt_id,'timeout');
  elsif v_attempt.status='in_progress' then raise exception 'Attempt is still in progress';end if;
  select jsonb_build_object(
    'attempt',jsonb_build_object('id',v_attempt.id,'attempt_mode',v_attempt.attempt_mode,'title',v_attempt.title,'is_timed',v_attempt.is_timed,'status',v_attempt.status,'duration_minutes',v_attempt.duration_minutes,'question_count',v_attempt.question_count,'started_at',v_attempt.started_at,'expires_at',v_attempt.expires_at,'submitted_at',v_attempt.submitted_at,'submit_reason',v_attempt.submit_reason,'correct_count',v_attempt.correct_count,'unanswered_count',v_attempt.unanswered_count,'score',v_attempt.score,'max_score',v_attempt.max_score,'elapsed_seconds',v_attempt.elapsed_seconds,'selected_years',v_attempt.selected_years,'selected_subjects',v_attempt.selected_subjects,'selected_subsubjects',v_attempt.selected_subsubjects),
    'paper',case when ep.paper_id is null then null else jsonb_build_object('exam_year_roc',ep.exam_year_roc,'paper_order',ep.paper_order,'paper_code',ep.paper_code,'paper_title',ep.paper_title,'source_question_url',ep.source_question_url,'source_answer_url',ep.source_answer_url) end,
    'questions',coalesce(jsonb_agg(jsonb_build_object(
      'question_id',q.question_id,'display_order',aq.display_order,'question_number',q.question_number,'question_type',q.question_type,'question_points',q.question_points,
      'question_text',q.question_text,'option_a',q.option_a,'option_b',q.option_b,'option_c',q.option_c,'option_d',q.option_d,'option_e',q.option_e,
      'selected_answer',ans.selected_answer,'correct_answer',key.final_answer,'correct_answers',key.accepted_answers,'is_bonus',key.is_bonus,
      'earned_points',scored.earned_points,'is_correct',scored.earned_points>=q.question_points,'is_unanswered',ans.selected_answer is null and not key.is_bonus,
      'subject_primary',q.subject_primary,'subsubject_primary',q.subsubject_primary,'is_starred',coalesce(ann.is_starred,false),'note_text',coalesce(ann.note_text,''),'active_seconds',coalesce(act.active_seconds,0)
    ) order by aq.display_order),'[]'::jsonb)
  ) into v_output
  from public.attempt_questions aq
  join public.questions q on q.question_id=aq.question_id
  join private.question_answer_keys key on key.question_id=q.question_id
  left join public.exam_papers ep on ep.paper_id=v_attempt.paper_id
  left join public.attempt_answers ans on ans.attempt_id=aq.attempt_id and ans.question_id=aq.question_id
  left join public.question_annotations ann on ann.user_id=v_user and ann.question_id=q.question_id
  left join public.attempt_question_activity act on act.attempt_id=aq.attempt_id and act.question_id=q.question_id
  cross join lateral (select private.score_question_answer(q.question_id,ans.selected_answer) earned_points) scored
  where aq.attempt_id=p_attempt_id group by ep.paper_id;
  return v_output;
end;
$$;

revoke all on function private.normalize_answer(text) from public,anon,authenticated;
revoke all on function private.score_question_answer(text,text) from public,anon,authenticated;
revoke all on function private.finalize_exam_attempt(uuid,public.submit_reason) from public,anon,authenticated;
revoke all on function public.start_subject_attempt(smallint[],text[],text[]) from public,anon;
revoke all on function public.start_wrong_review_attempt(smallint[],text[]) from public,anon;
revoke all on function public.save_attempt_answer(uuid,text,text) from public,anon;
revoke all on function public.get_attempt_payload(uuid) from public,anon;
revoke all on function public.get_attempt_result(uuid) from public,anon;
grant execute on function public.start_subject_attempt(smallint[],text[],text[]) to authenticated;
grant execute on function public.start_wrong_review_attempt(smallint[],text[]) to authenticated;
grant execute on function public.save_attempt_answer(uuid,text,text) to authenticated;
grant execute on function public.get_attempt_payload(uuid) to authenticated;
grant execute on function public.get_attempt_result(uuid) to authenticated;
