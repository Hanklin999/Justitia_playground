-- Justitia's playground v3.12.0
-- P0 pacing coach + P1 confidence, error diagnosis, spaced review,
-- answer revision history, and attempt-level deletion.
-- Repeat-safe and preserves existing attempts.

create schema if not exists private;

alter table public.attempt_answers
  add column if not exists confidence_level text;
alter table public.attempt_answers
  add column if not exists answered_at timestamptz;
alter table public.attempt_answers
  add column if not exists seconds_remaining_at_answer integer;

update public.attempt_answers
set answered_at = coalesce(answered_at, saved_at)
where answered_at is null;

alter table public.attempt_answers drop constraint if exists attempt_answers_confidence_level_check;
alter table public.attempt_answers add constraint attempt_answers_confidence_level_check
  check (confidence_level is null or confidence_level in ('confident','unsure','guess'));

create table if not exists public.attempt_answer_revisions (
  revision_id bigint generated always as identity primary key,
  attempt_id uuid not null,
  question_id text not null,
  from_answer text,
  to_answer text,
  changed_at timestamptz not null default now(),
  seconds_remaining integer,
  foreign key (attempt_id, question_id)
    references public.attempt_questions(attempt_id, question_id)
    on delete cascade
);

create table if not exists public.attempt_error_annotations (
  attempt_id uuid not null,
  question_id text not null,
  primary_error_reason text,
  secondary_error_reasons text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  foreign key (attempt_id, question_id)
    references public.attempt_questions(attempt_id, question_id)
    on delete cascade,
  check (
    primary_error_reason is null or primary_error_reason in (
      'unfamiliar_rule','forgot_exception','misread_stem','option_confusion',
      'time_pressure','careless','guessed'
    )
  )
);

create table if not exists public.user_question_review_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references public.questions(question_id) on delete cascade,
  review_count integer not null default 0 check (review_count >= 0),
  last_reviewed_at timestamptz,
  last_outcome text,
  next_review_at timestamptz,
  interval_days smallint not null default 1 check (interval_days >= 1),
  mastery_level smallint not null default 0 check (mastery_level between 0 and 5),
  updated_at timestamptz not null default now(),
  primary key (user_id, question_id)
);

create index if not exists answer_revisions_attempt_question_idx
  on public.attempt_answer_revisions (attempt_id, question_id, changed_at);
create index if not exists error_annotations_attempt_idx
  on public.attempt_error_annotations (attempt_id, primary_error_reason);
create index if not exists review_state_due_idx
  on public.user_question_review_state (user_id, next_review_at)
  where next_review_at is not null;

alter table public.attempt_answer_revisions enable row level security;
alter table public.attempt_error_annotations enable row level security;
alter table public.user_question_review_state enable row level security;

drop policy if exists "users read own answer revisions" on public.attempt_answer_revisions;
create policy "users read own answer revisions"
on public.attempt_answer_revisions for select to authenticated
using (
  exists (
    select 1 from public.exam_attempts ea
    where ea.id = attempt_id and ea.user_id = auth.uid()
  )
);

drop policy if exists "users read own error annotations" on public.attempt_error_annotations;
create policy "users read own error annotations"
on public.attempt_error_annotations for select to authenticated
using (
  exists (
    select 1 from public.exam_attempts ea
    where ea.id = attempt_id and ea.user_id = auth.uid()
  )
);

drop policy if exists "users read own review state" on public.user_question_review_state;
create policy "users read own review state"
on public.user_question_review_state for select to authenticated
using (user_id = auth.uid());

revoke all on public.attempt_answer_revisions, public.attempt_error_annotations, public.user_question_review_state
  from anon, authenticated;
grant select on public.attempt_answer_revisions, public.attempt_error_annotations, public.user_question_review_state
  to authenticated;

create or replace function private.learning_outcome(
  p_earned_points numeric,
  p_question_points numeric,
  p_confidence text
)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_earned_points, 0) < coalesce(p_question_points, 0) then 'incorrect'
    when p_confidence = 'guess' then 'correct_guess'
    when p_confidence = 'confident' then 'correct_confident'
    when p_confidence = 'unsure' then 'correct_unsure'
    else 'correct_unspecified'
  end;
$$;

create or replace function private.learning_interval_days(
  p_outcome text,
  p_previous_outcome text
)
returns integer
language sql
immutable
as $$
  select case
    when p_outcome = 'incorrect' then 1
    when p_outcome = 'correct_guess' then 3
    when p_outcome in ('correct_unsure','correct_unspecified') then 7
    when p_outcome = 'correct_confident' and p_previous_outcome = 'correct_confident' then 30
    when p_outcome = 'correct_confident' then 14
    else 1
  end;
$$;

create or replace function private.refresh_review_state_for_attempt(p_attempt_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_attempt public.exam_attempts%rowtype;
  v_row record;
  v_previous public.user_question_review_state%rowtype;
  v_outcome text;
  v_interval integer;
  v_mastery integer;
begin
  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id;

  if not found or v_attempt.status = 'in_progress' or v_attempt.submitted_at is null then
    return;
  end if;

  for v_row in
    select aq.question_id, q.question_points,
           private.score_question_answer(q.question_id, ans.selected_answer) as earned_points,
           ans.confidence_level
    from public.attempt_questions aq
    join public.questions q on q.question_id = aq.question_id
    left join public.attempt_answers ans
      on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
    where aq.attempt_id = p_attempt_id
  loop
    select s.* into v_previous
    from public.user_question_review_state s
    where s.user_id = v_attempt.user_id and s.question_id = v_row.question_id;

    v_outcome := private.learning_outcome(v_row.earned_points, v_row.question_points, v_row.confidence_level);
    v_interval := private.learning_interval_days(v_outcome, v_previous.last_outcome);
    v_mastery := case
      when v_outcome = 'incorrect' then 0
      when v_outcome = 'correct_guess' then greatest(coalesce(v_previous.mastery_level, 0), 1)
      when v_outcome in ('correct_unsure','correct_unspecified') then least(3, greatest(coalesce(v_previous.mastery_level, 0), 1) + 1)
      else least(5, greatest(coalesce(v_previous.mastery_level, 0), 1) + 1)
    end;

    insert into public.user_question_review_state(
      user_id, question_id, review_count, last_reviewed_at, last_outcome,
      next_review_at, interval_days, mastery_level, updated_at
    ) values (
      v_attempt.user_id, v_row.question_id, coalesce(v_previous.review_count, 0) + 1,
      v_attempt.submitted_at, v_outcome,
      v_attempt.submitted_at + make_interval(days => v_interval),
      v_interval, v_mastery, now()
    )
    on conflict (user_id, question_id) do update set
      review_count = excluded.review_count,
      last_reviewed_at = excluded.last_reviewed_at,
      last_outcome = excluded.last_outcome,
      next_review_at = excluded.next_review_at,
      interval_days = excluded.interval_days,
      mastery_level = excluded.mastery_level,
      updated_at = now();
  end loop;
end;
$$;

create or replace function private.rebuild_review_state_for_questions(
  p_user_id uuid,
  p_question_ids text[]
)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_question_id text;
  v_row record;
  v_previous_outcome text;
  v_review_count integer;
  v_mastery integer;
  v_outcome text;
  v_interval integer;
begin
  if coalesce(cardinality(p_question_ids), 0) = 0 then return; end if;

  foreach v_question_id in array p_question_ids loop
    delete from public.user_question_review_state s
    where s.user_id = p_user_id and s.question_id = v_question_id;

    v_previous_outcome := null;
    v_review_count := 0;
    v_mastery := 0;

    for v_row in
      select ea.submitted_at, q.question_points,
             private.score_question_answer(q.question_id, ans.selected_answer) as earned_points,
             ans.confidence_level
      from public.exam_attempts ea
      join public.attempt_questions aq on aq.attempt_id = ea.id
      join public.questions q on q.question_id = aq.question_id
      left join public.attempt_answers ans
        on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
      where ea.user_id = p_user_id
        and ea.status <> 'in_progress'
        and ea.submitted_at is not null
        and q.question_id = v_question_id
      order by ea.submitted_at, ea.started_at
    loop
      v_outcome := private.learning_outcome(v_row.earned_points, v_row.question_points, v_row.confidence_level);
      v_interval := private.learning_interval_days(v_outcome, v_previous_outcome);
      v_review_count := v_review_count + 1;
      v_mastery := case
        when v_outcome = 'incorrect' then 0
        when v_outcome = 'correct_guess' then greatest(v_mastery, 1)
        when v_outcome in ('correct_unsure','correct_unspecified') then least(3, greatest(v_mastery, 1) + 1)
        else least(5, greatest(v_mastery, 1) + 1)
      end;

      insert into public.user_question_review_state(
        user_id, question_id, review_count, last_reviewed_at, last_outcome,
        next_review_at, interval_days, mastery_level, updated_at
      ) values (
        p_user_id, v_question_id, v_review_count, v_row.submitted_at, v_outcome,
        v_row.submitted_at + make_interval(days => v_interval),
        v_interval, v_mastery, now()
      )
      on conflict (user_id, question_id) do update set
        review_count = excluded.review_count,
        last_reviewed_at = excluded.last_reviewed_at,
        last_outcome = excluded.last_outcome,
        next_review_at = excluded.next_review_at,
        interval_days = excluded.interval_days,
        mastery_level = excluded.mastery_level,
        updated_at = now();

      v_previous_outcome := v_outcome;
    end loop;
  end loop;
end;
$$;

-- Score and close an attempt, then update its spaced-review state.
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
  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id
  for update;

  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status <> 'in_progress' then return v_attempt; end if;

  v_reason := case
    when v_attempt.is_timed and now() >= v_attempt.expires_at then 'timeout'::public.submit_reason
    else coalesce(p_requested_reason, 'manual'::public.submit_reason)
  end;

  select
    count(*) filter (where scored.earned_points >= q.question_points),
    count(*) filter (where ans.selected_answer is null and not answer_key.is_bonus),
    coalesce(sum(scored.earned_points), 0)
  into v_correct, v_unanswered, v_score
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  join private.question_answer_keys answer_key on answer_key.question_id = q.question_id
  left join public.attempt_answers ans
    on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
  cross join lateral (
    select private.score_question_answer(q.question_id, ans.selected_answer) as earned_points
  ) scored
  where aq.attempt_id = p_attempt_id;

  update public.exam_attempts set
    status = case when v_reason = 'timeout' then 'timed_out'::public.attempt_status else 'submitted'::public.attempt_status end,
    submit_reason = v_reason,
    submitted_at = case when v_reason = 'timeout' then expires_at else now() end,
    correct_count = v_correct,
    unanswered_count = v_unanswered,
    score = v_score,
    elapsed_seconds = greatest(0, extract(epoch from ((case when v_reason = 'timeout' then expires_at else now() end) - started_at))::integer)
  where id = p_attempt_id
  returning * into v_attempt;

  perform private.refresh_review_state_for_attempt(p_attempt_id);
  return v_attempt;
end;
$$;

create or replace function public.save_attempt_answer(
  p_attempt_id uuid,
  p_question_id text,
  p_selected_answer text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_saved timestamptz := clock_timestamp();
  v_type text;
  v_option_e text;
  v_answer text;
  v_previous_answer text;
  v_seconds_remaining integer;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id and ea.user_id = v_user
  for update;

  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status <> 'in_progress' then
    return jsonb_build_object('ok', false, 'status', v_attempt.status);
  end if;
  if v_attempt.is_timed and now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
    return jsonb_build_object('ok', false, 'status', v_attempt.status);
  end if;

  select q.question_type, q.option_e into v_type, v_option_e
  from public.questions q
  join public.attempt_questions aq on aq.question_id = q.question_id
  where aq.attempt_id = p_attempt_id and q.question_id = p_question_id;
  if not found then raise exception 'Question is not part of this attempt'; end if;

  select ans.selected_answer into v_previous_answer
  from public.attempt_answers ans
  where ans.attempt_id = p_attempt_id and ans.question_id = p_question_id;

  v_answer := private.normalize_answer(p_selected_answer);
  v_seconds_remaining := case
    when v_attempt.is_timed and v_attempt.expires_at is not null
      then greatest(0, floor(extract(epoch from (v_attempt.expires_at - v_saved)))::integer)
    else null
  end;

  if v_answer = '' then
    if v_previous_answer is not null then
      insert into public.attempt_answer_revisions(
        attempt_id, question_id, from_answer, to_answer, changed_at, seconds_remaining
      ) values (p_attempt_id, p_question_id, v_previous_answer, null, v_saved, v_seconds_remaining);
    end if;
    delete from public.attempt_answers
    where attempt_id = p_attempt_id and question_id = p_question_id;
    return jsonb_build_object('ok', true, 'status', 'in_progress', 'saved_at', v_saved);
  end if;

  if v_type = 'single_choice' and length(v_answer) <> 1 then
    raise exception 'Single-choice question accepts one option';
  end if;
  if v_type = 'multiple_choice' and (length(v_answer) < 1 or length(v_answer) > 5) then
    raise exception 'Invalid multiple-choice answer';
  end if;
  if position('E' in v_answer) > 0 and v_option_e is null then
    raise exception 'Option E is unavailable';
  end if;

  if v_previous_answer is distinct from v_answer then
    insert into public.attempt_answer_revisions(
      attempt_id, question_id, from_answer, to_answer, changed_at, seconds_remaining
    ) values (p_attempt_id, p_question_id, v_previous_answer, v_answer, v_saved, v_seconds_remaining);
  end if;

  insert into public.attempt_answers(
    attempt_id, question_id, selected_answer, saved_at, answered_at, seconds_remaining_at_answer
  ) values (
    p_attempt_id, p_question_id, v_answer, v_saved, v_saved, v_seconds_remaining
  )
  on conflict (attempt_id, question_id) do update set
    confidence_level = case
      when public.attempt_answers.selected_answer is distinct from excluded.selected_answer then null
      else public.attempt_answers.confidence_level
    end,
    selected_answer = excluded.selected_answer,
    saved_at = excluded.saved_at,
    answered_at = excluded.answered_at,
    seconds_remaining_at_answer = excluded.seconds_remaining_at_answer;

  return jsonb_build_object('ok', true, 'status', 'in_progress', 'saved_at', v_saved);
end;
$$;

create or replace function public.save_attempt_confidence(
  p_attempt_id uuid,
  p_question_id text,
  p_confidence_level text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_confidence_level is not null and p_confidence_level not in ('confident','unsure','guess') then
    raise exception 'Invalid confidence level';
  end if;

  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id and ea.user_id = v_user
  for update;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status <> 'in_progress' then raise exception 'Confidence is locked after submission'; end if;

  update public.attempt_answers ans
  set confidence_level = p_confidence_level, saved_at = now()
  where ans.attempt_id = p_attempt_id and ans.question_id = p_question_id;
  if not found then raise exception 'Answer the question before setting confidence'; end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.save_error_annotation(
  p_attempt_id uuid,
  p_question_id text,
  p_primary_error_reason text,
  p_secondary_error_reasons text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_points numeric;
  v_earned numeric;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_primary_error_reason is not null and p_primary_error_reason not in (
    'unfamiliar_rule','forgot_exception','misread_stem','option_confusion',
    'time_pressure','careless','guessed'
  ) then raise exception 'Invalid error reason'; end if;

  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id and ea.user_id = v_user;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status = 'in_progress' then raise exception 'Error reasons are available after submission'; end if;

  select q.question_points,
         private.score_question_answer(q.question_id, ans.selected_answer)
  into v_points, v_earned
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  left join public.attempt_answers ans
    on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
  where aq.attempt_id = p_attempt_id and aq.question_id = p_question_id;
  if not found then raise exception 'Question is not part of this attempt'; end if;
  if v_earned >= v_points then raise exception 'Error reasons are only available for non-full-score questions'; end if;

  insert into public.attempt_error_annotations(
    attempt_id, question_id, primary_error_reason, secondary_error_reasons, updated_at
  ) values (
    p_attempt_id, p_question_id, p_primary_error_reason,
    coalesce(p_secondary_error_reasons, '{}'::text[]), now()
  )
  on conflict (attempt_id, question_id) do update set
    primary_error_reason = excluded.primary_error_reason,
    secondary_error_reasons = excluded.secondary_error_reasons,
    updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.get_due_review_summary()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select jsonb_build_object(
    'due_count', count(*) filter (where s.next_review_at <= now()),
    'upcoming_count', count(*) filter (where s.next_review_at > now()),
    'next_due_at', min(s.next_review_at) filter (where s.next_review_at > now()),
    'due_by_subject', coalesce((
      select jsonb_agg(jsonb_build_object('subject', grouped.subject_primary, 'count', grouped.item_count)
                       order by grouped.item_count desc, grouped.subject_primary)
      from (
        select q.subject_primary, count(*) as item_count
        from public.user_question_review_state s2
        join public.questions q on q.question_id = s2.question_id
        where s2.user_id = auth.uid() and s2.next_review_at <= now()
        group by q.subject_primary
      ) grouped
    ), '[]'::jsonb)
  )
  from public.user_question_review_state s
  where s.user_id = auth.uid();
$$;


create or replace function public.get_learning_insights()
returns jsonb
language sql
security definer
set search_path = public, private, pg_temp
stable
as $$
  with recent_attempts as (
    select ea.id
    from public.exam_attempts ea
    where ea.user_id = auth.uid()
      and ea.status <> 'in_progress'
      and ea.submitted_at is not null
    order by ea.submitted_at desc
    limit 5
  ), error_counts as (
    select ann.primary_error_reason as reason, count(*)::integer as item_count
    from public.attempt_error_annotations ann
    join recent_attempts ra on ra.id = ann.attempt_id
    where ann.primary_error_reason is not null
    group by ann.primary_error_reason
    order by item_count desc, reason
  ), confidence_rows as (
    select ans.confidence_level,
           private.score_question_answer(q.question_id, ans.selected_answer) >= q.question_points as is_full_score
    from recent_attempts ra
    join public.attempt_questions aq on aq.attempt_id = ra.id
    join public.questions q on q.question_id = aq.question_id
    left join public.attempt_answers ans
      on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
  )
  select jsonb_build_object(
    'recent_attempt_count', (select count(*) from recent_attempts),
    'top_error_reasons', coalesce((
      select jsonb_agg(jsonb_build_object('reason', reason, 'count', item_count)
                       order by item_count desc, reason)
      from error_counts
    ), '[]'::jsonb),
    'confidence', jsonb_build_object(
      'confident_wrong', count(*) filter (where confidence_level = 'confident' and not is_full_score),
      'unsure_correct', count(*) filter (where confidence_level = 'unsure' and is_full_score),
      'guess_wrong', count(*) filter (where confidence_level = 'guess' and not is_full_score),
      'recorded', count(*) filter (where confidence_level is not null)
    )
  )
  from confidence_rows;
$$;

alter table public.exam_attempts drop constraint if exists exam_attempts_selection_strategy_check;
alter table public.exam_attempts add constraint exam_attempts_selection_strategy_check
  check (selection_strategy in ('default_scope','recent_10_wrong_priority','review_union','official_order','spaced_review'));

create or replace function public.start_due_review_attempt(
  p_limit integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_started timestamptz := clock_timestamp();
  v_count integer;
  v_max_score numeric;
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 200);
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.user_id = v_user
    and ea.status = 'in_progress'
    and ea.selection_strategy = 'spaced_review'
  order by ea.started_at desc
  limit 1;
  if found then
    return jsonb_build_object(
      'attempt_id', v_attempt.id, 'resumed', true,
      'started_at', v_attempt.started_at, 'expires_at', null,
      'duration_minutes', 0, 'question_count', v_attempt.question_count
    );
  end if;

  insert into public.exam_attempts(
    user_id, paper_id, attempt_mode, title, is_timed,
    selected_years, selected_subjects, selected_subsubjects,
    duration_minutes, question_count, points_per_question, max_score,
    started_at, expires_at, exam_date,
    default_question_count, requested_question_count, selection_strategy
  ) values (
    v_user, null, 'wrong_review', '今日間隔複習', false,
    '{}', '{}', '{}', 0, 1, 2, 2,
    v_started, null, (v_started at time zone 'Asia/Taipei')::date,
    v_limit, v_limit, 'spaced_review'
  ) returning * into v_attempt;

  insert into public.attempt_questions(attempt_id, question_id, display_order)
  select v_attempt.id, due.question_id,
         row_number() over(order by due.priority_order, due.next_review_at, random())::smallint
  from (
    select s.question_id, s.next_review_at,
           case s.last_outcome
             when 'incorrect' then 1
             when 'correct_guess' then 2
             when 'correct_unsure' then 3
             when 'correct_unspecified' then 4
             else 5
           end as priority_order
    from public.user_question_review_state s
    where s.user_id = v_user and s.next_review_at <= now()
    order by priority_order, s.next_review_at, random()
    limit v_limit
  ) due;

  select count(*), coalesce(sum(q.question_points), 0)
  into v_count, v_max_score
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  where aq.attempt_id = v_attempt.id;

  if v_count = 0 then
    delete from public.exam_attempts ea where ea.id = v_attempt.id;
    raise exception 'No review questions are due today';
  end if;

  update public.exam_attempts ea set
    title = '今日間隔複習｜' || v_count || ' 題',
    question_count = v_count,
    default_question_count = v_count,
    requested_question_count = v_count,
    max_score = v_max_score,
    selected_years = (
      select array_agg(distinct ep.exam_year_roc order by ep.exam_year_roc desc)
      from public.attempt_questions aq
      join public.questions q on q.question_id = aq.question_id
      join public.exam_papers ep on ep.paper_id = q.paper_id
      where aq.attempt_id = v_attempt.id
    ),
    selected_subjects = (
      select array_agg(distinct q.subject_primary order by q.subject_primary)
      from public.attempt_questions aq
      join public.questions q on q.question_id = aq.question_id
      where aq.attempt_id = v_attempt.id
    )
  where ea.id = v_attempt.id
  returning * into v_attempt;

  return jsonb_build_object(
    'attempt_id', v_attempt.id,
    'resumed', false,
    'started_at', v_attempt.started_at,
    'expires_at', null,
    'duration_minutes', 0,
    'question_count', v_attempt.question_count
  );
end;
$$;

create or replace function public.delete_my_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_question_ids text[];
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.exam_attempts ea
    where ea.id = p_attempt_id and ea.user_id = v_user
  ) then raise exception 'Attempt not found'; end if;

  select coalesce(array_agg(aq.question_id), '{}') into v_question_ids
  from public.attempt_questions aq
  where aq.attempt_id = p_attempt_id;

  delete from public.exam_attempts ea
  where ea.id = p_attempt_id and ea.user_id = v_user;

  update public.exam_attempts ea
  set source_attempt_ids = array_remove(ea.source_attempt_ids, p_attempt_id)
  where ea.user_id = v_user and p_attempt_id = any(ea.source_attempt_ids);

  perform private.rebuild_review_state_for_questions(v_user, v_question_ids);
  return jsonb_build_object('ok', true, 'deleted_attempt_id', p_attempt_id);
end;
$$;

-- Return richer exam payload including confidence.
create or replace function public.get_attempt_payload(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_output jsonb;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id and ea.user_id = v_user;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status = 'in_progress' and v_attempt.is_timed and now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
  end if;

  select jsonb_build_object(
    'attempt', jsonb_build_object(
      'id', v_attempt.id, 'paper_id', v_attempt.paper_id,
      'attempt_mode', v_attempt.attempt_mode, 'title', v_attempt.title,
      'is_timed', v_attempt.is_timed, 'status', v_attempt.status,
      'duration_minutes', v_attempt.duration_minutes, 'question_count', v_attempt.question_count,
      'points_per_question', v_attempt.points_per_question, 'max_score', v_attempt.max_score,
      'started_at', v_attempt.started_at, 'expires_at', v_attempt.expires_at,
      'submitted_at', v_attempt.submitted_at, 'submit_reason', v_attempt.submit_reason,
      'selected_years', v_attempt.selected_years, 'selected_subjects', v_attempt.selected_subjects,
      'selected_subsubjects', v_attempt.selected_subsubjects,
      'exam_date', v_attempt.exam_date,
      'default_question_count', v_attempt.default_question_count,
      'requested_question_count', v_attempt.requested_question_count,
      'selection_strategy', v_attempt.selection_strategy,
      'selected_paper_kinds', v_attempt.selected_paper_kinds
    ),
    'paper', case when ep.paper_id is null then null else jsonb_build_object(
      'exam_year_roc', ep.exam_year_roc, 'paper_order', ep.paper_order,
      'paper_code', ep.paper_code, 'paper_title', ep.paper_title,
      'included_subjects', ep.included_subjects, 'source_question_url', ep.source_question_url
    ) end,
    'questions', coalesce(jsonb_agg(jsonb_build_object(
      'question_id', q.question_id, 'display_order', aq.display_order,
      'question_number', q.question_number, 'question_type', q.question_type,
      'question_points', q.question_points, 'question_text', q.question_text,
      'option_a', q.option_a, 'option_b', q.option_b, 'option_c', q.option_c,
      'option_d', q.option_d, 'option_e', q.option_e,
      'selected_answer', ans.selected_answer,
      'confidence_level', ans.confidence_level,
      'answered_at', ans.answered_at,
      'seconds_remaining_at_answer', ans.seconds_remaining_at_answer,
      'review_status', q.review_status,
      'subject_primary', q.subject_primary, 'subsubject_primary', q.subsubject_primary,
      'exam_is_starred', coalesce(exam_ann.exam_is_starred, false),
      'exam_note_text', coalesce(exam_ann.exam_note_text, ''),
      'review_is_starred', coalesce(review_ann.review_is_starred, false),
      'review_note_text', coalesce(review_ann.review_note_text, ''),
      'active_seconds', coalesce(activity.active_seconds, 0)
    ) order by aq.display_order), '[]'::jsonb)
  ) into v_output
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  left join public.exam_papers ep on ep.paper_id = v_attempt.paper_id
  left join public.attempt_answers ans
    on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
  left join public.attempt_question_annotations exam_ann
    on exam_ann.attempt_id = aq.attempt_id and exam_ann.question_id = aq.question_id
  left join public.question_review_annotations review_ann
    on review_ann.user_id = v_user and review_ann.question_id = aq.question_id
  left join public.attempt_question_activity activity
    on activity.attempt_id = aq.attempt_id and activity.question_id = aq.question_id
  where aq.attempt_id = p_attempt_id
  group by ep.paper_id;

  return v_output;
end;
$$;

-- Return full result plus pacing, revisions, confidence, and error annotations.
create or replace function public.get_attempt_result(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_output jsonb;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id and ea.user_id = v_user;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status = 'in_progress' and v_attempt.is_timed and now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
  elsif v_attempt.status = 'in_progress' then
    raise exception 'Attempt is still in progress';
  end if;

  select jsonb_build_object(
    'attempt', jsonb_build_object(
      'id', v_attempt.id, 'paper_id', v_attempt.paper_id, 'attempt_mode', v_attempt.attempt_mode,
      'title', v_attempt.title, 'is_timed', v_attempt.is_timed,
      'status', v_attempt.status, 'duration_minutes', v_attempt.duration_minutes,
      'question_count', v_attempt.question_count, 'points_per_question', v_attempt.points_per_question,
      'started_at', v_attempt.started_at, 'expires_at', v_attempt.expires_at,
      'submitted_at', v_attempt.submitted_at, 'submit_reason', v_attempt.submit_reason,
      'correct_count', v_attempt.correct_count, 'unanswered_count', v_attempt.unanswered_count,
      'score', v_attempt.score, 'max_score', v_attempt.max_score,
      'elapsed_seconds', v_attempt.elapsed_seconds,
      'selected_years', v_attempt.selected_years, 'selected_subjects', v_attempt.selected_subjects,
      'selected_subsubjects', v_attempt.selected_subsubjects,
      'exam_date', v_attempt.exam_date,
      'default_question_count', v_attempt.default_question_count,
      'requested_question_count', v_attempt.requested_question_count,
      'selection_strategy', v_attempt.selection_strategy,
      'selected_paper_kinds', v_attempt.selected_paper_kinds,
      'source_attempt_ids', v_attempt.source_attempt_ids
    ),
    'paper', case when ep.paper_id is null then null else jsonb_build_object(
      'exam_year_roc', ep.exam_year_roc, 'paper_order', ep.paper_order,
      'paper_code', ep.paper_code, 'paper_title', ep.paper_title,
      'source_question_url', ep.source_question_url, 'source_answer_url', ep.source_answer_url
    ) end,
    'questions', coalesce(jsonb_agg(jsonb_build_object(
      'question_id', q.question_id, 'display_order', aq.display_order,
      'question_number', q.question_number, 'question_type', q.question_type,
      'question_points', q.question_points, 'question_text', q.question_text,
      'option_a', q.option_a, 'option_b', q.option_b, 'option_c', q.option_c,
      'option_d', q.option_d, 'option_e', q.option_e,
      'selected_answer', ans.selected_answer,
      'confidence_level', ans.confidence_level,
      'answered_at', ans.answered_at,
      'seconds_remaining_at_answer', ans.seconds_remaining_at_answer,
      'correct_answer', answer_key.final_answer,
      'correct_answers', answer_key.accepted_answers,
      'is_bonus', answer_key.is_bonus,
      'earned_points', scored.earned_points,
      'is_correct', scored.earned_points >= q.question_points,
      'is_unanswered', ans.selected_answer is null and not answer_key.is_bonus,
      'subject_primary', q.subject_primary, 'subsubject_primary', q.subsubject_primary,
      'review_status', q.review_status,
      'exam_is_starred', coalesce(exam_ann.exam_is_starred, false),
      'exam_note_text', coalesce(exam_ann.exam_note_text, ''),
      'review_is_starred', coalesce(review_ann.review_is_starred, false),
      'review_note_text', coalesce(review_ann.review_note_text, ''),
      'active_seconds', coalesce(activity.active_seconds, 0),
      'answer_revision_count', coalesce(revision_summary.revision_count, 0),
      'first_answer', revision_summary.first_answer,
      'first_earned_points', private.score_question_answer(q.question_id, revision_summary.first_answer),
      'primary_error_reason', error_ann.primary_error_reason,
      'secondary_error_reasons', coalesce(error_ann.secondary_error_reasons, '{}')
    ) order by aq.display_order), '[]'::jsonb)
  ) into v_output
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  join private.question_answer_keys answer_key on answer_key.question_id = q.question_id
  left join public.exam_papers ep on ep.paper_id = v_attempt.paper_id
  left join public.attempt_answers ans
    on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
  left join public.attempt_question_annotations exam_ann
    on exam_ann.attempt_id = aq.attempt_id and exam_ann.question_id = aq.question_id
  left join public.question_review_annotations review_ann
    on review_ann.user_id = v_user and review_ann.question_id = aq.question_id
  left join public.attempt_question_activity activity
    on activity.attempt_id = aq.attempt_id and activity.question_id = aq.question_id
  left join public.attempt_error_annotations error_ann
    on error_ann.attempt_id = aq.attempt_id and error_ann.question_id = aq.question_id
  left join lateral (
    select count(*)::integer as revision_count,
           (array_agg(r.to_answer order by r.changed_at, r.revision_id)
             filter (where r.to_answer is not null and r.to_answer <> ''))[1] as first_answer
    from public.attempt_answer_revisions r
    where r.attempt_id = aq.attempt_id and r.question_id = aq.question_id
  ) revision_summary on true
  cross join lateral (
    select private.score_question_answer(q.question_id, ans.selected_answer) as earned_points
  ) scored
  where aq.attempt_id = p_attempt_id
  group by ep.paper_id;

  return v_output;
end;
$$;


-- Backfill spaced-review state from existing completed attempts.
do $$
declare
  v_item record;
begin
  for v_item in
    select distinct ea.user_id, aq.question_id
    from public.exam_attempts ea
    join public.attempt_questions aq on aq.attempt_id = ea.id
    where ea.status <> 'in_progress' and ea.submitted_at is not null
  loop
    perform private.rebuild_review_state_for_questions(v_item.user_id, array[v_item.question_id]);
  end loop;
end;
$$;

revoke all on function private.learning_outcome(numeric,numeric,text) from public, anon, authenticated;
revoke all on function private.learning_interval_days(text,text) from public, anon, authenticated;
revoke all on function private.refresh_review_state_for_attempt(uuid) from public, anon, authenticated;
revoke all on function private.rebuild_review_state_for_questions(uuid,text[]) from public, anon, authenticated;
revoke all on function private.finalize_exam_attempt(uuid,public.submit_reason) from public, anon, authenticated;

revoke all on function public.save_attempt_answer(uuid,text,text) from public, anon;
revoke all on function public.save_attempt_confidence(uuid,text,text) from public, anon;
revoke all on function public.save_error_annotation(uuid,text,text,text[]) from public, anon;
revoke all on function public.get_due_review_summary() from public, anon;
revoke all on function public.get_learning_insights() from public, anon;
revoke all on function public.start_due_review_attempt(integer) from public, anon;
revoke all on function public.delete_my_attempt(uuid) from public, anon;
revoke all on function public.get_attempt_payload(uuid) from public, anon;
revoke all on function public.get_attempt_result(uuid) from public, anon;

grant execute on function public.save_attempt_answer(uuid,text,text) to authenticated;
grant execute on function public.save_attempt_confidence(uuid,text,text) to authenticated;
grant execute on function public.save_error_annotation(uuid,text,text,text[]) to authenticated;
grant execute on function public.get_due_review_summary() to authenticated;
grant execute on function public.get_learning_insights() to authenticated;
grant execute on function public.start_due_review_attempt(integer) to authenticated;
grant execute on function public.delete_my_attempt(uuid) to authenticated;
grant execute on function public.get_attempt_payload(uuid) to authenticated;
grant execute on function public.get_attempt_result(uuid) to authenticated;
