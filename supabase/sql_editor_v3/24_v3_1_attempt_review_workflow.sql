-- Justitia's playground v3.1.0
-- Separate exam-time and review-time annotations, richer attempt metadata,
-- selectable review sets, and custom subject attempts with recent-ten-attempt wrong-question priority.
-- Repeat-safe; existing attempts and annotations are preserved.

create schema if not exists private;

create or replace function private.paper_kind(p_paper_code text)
returns text
language sql
immutable
as $$
  select case p_paper_code
    when '1301' then '刑事法卷'
    when '2301' then '公法卷'
    when '3301' then '民事法卷'
    when '4301' then '商事法卷'
    else '未分類卷'
  end;
$$;

alter table public.exam_attempts
  add column if not exists exam_date date;
alter table public.exam_attempts
  add column if not exists default_question_count smallint;
alter table public.exam_attempts
  add column if not exists requested_question_count smallint;
alter table public.exam_attempts
  add column if not exists selection_strategy text not null default 'default_scope';
alter table public.exam_attempts
  add column if not exists selected_paper_kinds text[] not null default '{}';
alter table public.exam_attempts
  add column if not exists source_attempt_ids uuid[] not null default '{}';
alter table public.exam_attempts
  add column if not exists review_include_wrong boolean not null default false;
alter table public.exam_attempts
  add column if not exists review_include_exam_starred boolean not null default false;
alter table public.exam_attempts
  add column if not exists review_include_review_starred boolean not null default false;

update public.exam_attempts
set exam_date = coalesce(exam_date, (started_at at time zone 'Asia/Taipei')::date),
    default_question_count = coalesce(default_question_count, question_count),
    requested_question_count = coalesce(requested_question_count, question_count)
where exam_date is null
   or default_question_count is null
   or requested_question_count is null;

update public.exam_attempts
set selection_strategy = 'official_order'
where attempt_mode = 'official_paper';

update public.exam_attempts a
set selected_paper_kinds = x.paper_kinds
from (
  select aq.attempt_id,
         array_agg(distinct private.paper_kind(ep.paper_code) order by private.paper_kind(ep.paper_code)) as paper_kinds
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  join public.exam_papers ep on ep.paper_id = q.paper_id
  group by aq.attempt_id
) x
where x.attempt_id = a.id
  and coalesce(cardinality(a.selected_paper_kinds), 0) = 0;

alter table public.exam_attempts alter column exam_date set default ((now() at time zone 'Asia/Taipei')::date);
alter table public.exam_attempts alter column exam_date set not null;

alter table public.exam_attempts drop constraint if exists exam_attempts_selection_strategy_check;

update public.exam_attempts
set selection_strategy = 'recent_10_wrong_priority'
where selection_strategy = 'wrong_priority_50';

alter table public.exam_attempts add constraint exam_attempts_selection_strategy_check
  check (selection_strategy in ('default_scope','recent_10_wrong_priority','review_union','official_order'));

create table if not exists public.attempt_question_annotations (
  attempt_id uuid not null,
  question_id text not null,
  exam_is_starred boolean not null default false,
  exam_note_text text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  foreign key (attempt_id, question_id)
    references public.attempt_questions(attempt_id, question_id)
    on delete cascade
);

create table if not exists public.question_review_annotations (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references public.questions(question_id) on delete cascade,
  review_is_starred boolean not null default false,
  review_note_text text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, question_id)
);

-- Legacy global annotations cannot be reliably assigned to one exam round.
-- Preserve them as review annotations instead of discarding user data.
insert into public.question_review_annotations
  (user_id, question_id, review_is_starred, review_note_text, created_at, updated_at)
select user_id, question_id, is_starred, note_text, created_at, updated_at
from public.question_annotations
on conflict (user_id, question_id) do nothing;

create index if not exists attempt_question_annotations_star_idx
  on public.attempt_question_annotations (attempt_id, exam_is_starred);
create index if not exists review_annotations_user_star_idx
  on public.question_review_annotations (user_id, review_is_starred);
create index if not exists exam_attempts_user_exam_date_idx
  on public.exam_attempts (user_id, exam_date desc, started_at desc);

alter table public.attempt_question_annotations enable row level security;
alter table public.question_review_annotations enable row level security;

drop policy if exists "users read own exam annotations" on public.attempt_question_annotations;
create policy "users read own exam annotations"
on public.attempt_question_annotations for select to authenticated
using (
  exists (
    select 1 from public.exam_attempts ea
    where ea.id = attempt_id and ea.user_id = auth.uid()
  )
);

drop policy if exists "users read own review annotations" on public.question_review_annotations;
create policy "users read own review annotations"
on public.question_review_annotations for select to authenticated
using (user_id = auth.uid());

revoke all on public.attempt_question_annotations, public.question_review_annotations from anon, authenticated;
grant select on public.attempt_question_annotations, public.question_review_annotations to authenticated;

create or replace function public.save_exam_annotation(
  p_attempt_id uuid,
  p_question_id text,
  p_is_starred boolean,
  p_note_text text default ''
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

  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.id = p_attempt_id and ea.user_id = v_user
  for update;

  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status <> 'in_progress' then raise exception 'Exam annotations are locked after submission'; end if;
  if v_attempt.attempt_mode = 'wrong_review' then raise exception 'Review attempts use review annotations'; end if;
  if not exists (
    select 1 from public.attempt_questions aq
    where aq.attempt_id = p_attempt_id and aq.question_id = p_question_id
  ) then raise exception 'Question is not part of this attempt'; end if;

  insert into public.attempt_question_annotations
    (attempt_id, question_id, exam_is_starred, exam_note_text, updated_at)
  values
    (p_attempt_id, p_question_id, coalesce(p_is_starred, false), left(coalesce(p_note_text, ''), 4000), now())
  on conflict (attempt_id, question_id) do update set
    exam_is_starred = excluded.exam_is_starred,
    exam_note_text = excluded.exam_note_text,
    updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.save_review_annotation(
  p_question_id text,
  p_is_starred boolean,
  p_note_text text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.questions q where q.question_id = p_question_id) then
    raise exception 'Question not found';
  end if;

  insert into public.question_review_annotations
    (user_id, question_id, review_is_starred, review_note_text, updated_at)
  values
    (v_user, p_question_id, coalesce(p_is_starred, false), left(coalesce(p_note_text, ''), 4000), now())
  on conflict (user_id, question_id) do update set
    review_is_starred = excluded.review_is_starred,
    review_note_text = excluded.review_note_text,
    updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.start_exam_attempt(p_paper_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_paper public.exam_papers%rowtype;
  v_attempt public.exam_attempts%rowtype;
  v_started timestamptz := clock_timestamp();
  v_count integer;
  v_stale record;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  for v_stale in
    select ea.id from public.exam_attempts ea
    where ea.user_id = v_user and ea.status = 'in_progress'
      and ea.is_timed and ea.expires_at <= now()
  loop
    perform private.finalize_exam_attempt(v_stale.id, 'timeout');
  end loop;

  select ep.* into v_paper
  from public.exam_papers ep
  where ep.paper_id = p_paper_id and ep.is_published;
  if not found then raise exception 'Published paper not found'; end if;

  select ea.* into v_attempt
  from public.exam_attempts ea
  where ea.user_id = v_user and ea.paper_id = p_paper_id
    and ea.attempt_mode = 'official_paper' and ea.status = 'in_progress'
    and ea.expires_at > now()
  order by ea.started_at desc limit 1;
  if found then
    return jsonb_build_object('attempt_id', v_attempt.id, 'resumed', true,
      'started_at', v_attempt.started_at, 'expires_at', v_attempt.expires_at,
      'duration_minutes', v_attempt.duration_minutes, 'question_count', v_attempt.question_count);
  end if;

  select count(*) into v_count
  from public.questions q
  where q.paper_id = p_paper_id and q.is_published;
  if v_count <> v_paper.question_count then
    raise exception 'Paper expects % questions but % are published', v_paper.question_count, v_count;
  end if;

  insert into public.exam_attempts(
    user_id, paper_id, attempt_mode, title, is_timed,
    selected_years, selected_subjects, duration_minutes, question_count,
    points_per_question, max_score, started_at, expires_at, exam_date,
    default_question_count, requested_question_count, selection_strategy,
    selected_paper_kinds
  ) values (
    v_user, v_paper.paper_id, 'official_paper',
    v_paper.exam_year_roc || ' 年第 ' || v_paper.paper_order || ' 卷', true,
    array[v_paper.exam_year_roc]::smallint[], v_paper.included_subjects,
    v_paper.duration_minutes, v_count, v_paper.points_per_question, v_paper.max_score,
    v_started, v_started + make_interval(mins => v_paper.duration_minutes),
    (v_started at time zone 'Asia/Taipei')::date,
    v_count, v_count, 'official_order', array[private.paper_kind(v_paper.paper_code)]
  ) returning * into v_attempt;

  insert into public.attempt_questions(attempt_id, question_id, display_order)
  select v_attempt.id, q.question_id, q.question_number
  from public.questions q
  where q.paper_id = p_paper_id and q.is_published
  order by q.question_number;

  return jsonb_build_object('attempt_id', v_attempt.id, 'resumed', false,
    'started_at', v_attempt.started_at, 'expires_at', v_attempt.expires_at,
    'duration_minutes', v_attempt.duration_minutes, 'question_count', v_attempt.question_count);
end;
$$;

create or replace function public.start_custom_subject_attempt(
  p_years smallint[],
  p_subjects text[],
  p_subsubjects text[] default '{}',
  p_target_question_count integer default null,
  p_custom_title text default null,
  p_exam_date date default null
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
  v_default_count integer;
  v_target_count integer;
  v_scope_count integer;
  v_count integer;
  v_total_seconds integer;
  v_max_score numeric;
  v_default_title text;
  v_final_title text;
  v_base_result jsonb;
  v_attempt_id uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if coalesce(cardinality(p_years), 0) = 0 then raise exception 'Select at least one year'; end if;
  if coalesce(cardinality(p_subjects), 0) = 0 and coalesce(cardinality(p_subsubjects), 0) = 0 then
    raise exception 'Select at least one subject';
  end if;

  with configs as (
    select c.*,
      case when cardinality(p_years) = 1 then (
        select count(*)::integer
        from public.questions q2
        join public.exam_papers p2 on p2.paper_id = q2.paper_id
        where q2.is_published
          and p2.exam_year_roc = p_years[1]
          and q2.subject_primary = c.subject_name
          and (c.subsubject_name is null or q2.subsubject_primary = c.subsubject_name)
      ) else c.target_question_count::integer end as effective_target_count
    from public.subject_exam_config c
    where c.is_active and (
      (c.subsubject_name is not null and c.subsubject_name = any(coalesce(p_subsubjects, '{}'::text[])))
      or (
        c.subsubject_name is null
        and c.subject_name = any(coalesce(p_subjects, '{}'::text[]))
        and not (c.subject_name = '民法' and coalesce(cardinality(p_subsubjects), 0) > 0)
      )
    )
  )
  select coalesce(sum(effective_target_count), 0),
         string_agg(coalesce(subsubject_name, subject_name), '＋' order by display_order)
  into v_default_count, v_default_title
  from configs;

  if v_default_count <= 0 or v_default_title is null then
    raise exception 'No matching subject configuration';
  end if;

  select count(*) into v_scope_count
  from public.questions q
  join public.exam_papers ep on ep.paper_id = q.paper_id
  where q.is_published
    and ep.exam_year_roc = any(p_years)
    and (
      (q.subsubject_primary = any(coalesce(p_subsubjects, '{}'::text[])))
      or (
        q.subject_primary = any(coalesce(p_subjects, '{}'::text[]))
        and not (q.subject_primary = '民法' and coalesce(cardinality(p_subsubjects), 0) > 0)
      )
    );

  if v_scope_count = 0 then raise exception 'No published questions match the selection'; end if;
  v_target_count := least(coalesce(p_target_question_count, v_default_count), v_scope_count);
  if v_target_count <= 0 then raise exception 'Question count must be positive'; end if;
  v_final_title := coalesce(nullif(btrim(p_custom_title), ''), v_default_title || '｜自組測驗');

  if v_target_count = v_default_count then
    v_base_result := public.start_subject_attempt(p_years, p_subjects, coalesce(p_subsubjects, '{}'::text[]));
    v_attempt_id := (v_base_result ->> 'attempt_id')::uuid;
    update public.exam_attempts ea set
      title = v_final_title,
      exam_date = coalesce(p_exam_date, (v_started at time zone 'Asia/Taipei')::date),
      default_question_count = v_default_count,
      requested_question_count = v_target_count,
      selection_strategy = 'default_scope',
      selected_paper_kinds = (
        select array_agg(distinct private.paper_kind(ep.paper_code) order by private.paper_kind(ep.paper_code))
        from public.attempt_questions aq
        join public.questions q on q.question_id = aq.question_id
        join public.exam_papers ep on ep.paper_id = q.paper_id
        where aq.attempt_id = v_attempt_id
      )
    where ea.id = v_attempt_id
    returning ea.* into v_attempt;

    return jsonb_build_object(
      'attempt_id', v_attempt.id,
      'resumed', false,
      'started_at', v_attempt.started_at,
      'expires_at', v_attempt.expires_at,
      'duration_minutes', v_attempt.duration_minutes,
      'question_count', v_attempt.question_count
    );
  end if;

  insert into public.exam_attempts(
    user_id, paper_id, attempt_mode, title, is_timed,
    selected_years, selected_subjects, selected_subsubjects,
    duration_minutes, question_count, points_per_question, max_score,
    started_at, expires_at, exam_date,
    default_question_count, requested_question_count, selection_strategy
  ) values (
    v_user, null, 'subject_pool', v_final_title, true,
    p_years, p_subjects, coalesce(p_subsubjects, '{}'::text[]),
    1, 1, 2, 2,
    v_started, v_started + interval '1 minute',
    coalesce(p_exam_date, (v_started at time zone 'Asia/Taipei')::date),
    v_default_count, v_target_count, 'recent_10_wrong_priority'
  ) returning * into v_attempt;

  with scope as (
    select q.question_id, q.question_points,
           ep.duration_minutes * 60.0 / ep.question_count as seconds_per_question
    from public.questions q
    join public.exam_papers ep on ep.paper_id = q.paper_id
    where q.is_published
      and ep.exam_year_roc = any(p_years)
      and (
        q.subsubject_primary = any(coalesce(p_subsubjects, '{}'::text[]))
        or (
          q.subject_primary = any(coalesce(p_subjects, '{}'::text[]))
          and not (q.subject_primary = '民法' and coalesce(cardinality(p_subsubjects), 0) > 0)
        )
      )
  ), recent_scope_attempts as (
    select ea.id
    from public.exam_attempts ea
    where ea.user_id = v_user
      and ea.status <> 'in_progress'
      and ea.submitted_at is not null
      and exists (
        select 1
        from public.attempt_questions recent_aq
        join scope recent_scope on recent_scope.question_id = recent_aq.question_id
        where recent_aq.attempt_id = ea.id
      )
    order by ea.submitted_at desc, ea.started_at desc
    limit 10
  ), recent_wrong_pool as (
    select distinct recent_aq.question_id
    from recent_scope_attempts recent_attempt
    join public.attempt_questions recent_aq on recent_aq.attempt_id = recent_attempt.id
    join scope recent_scope on recent_scope.question_id = recent_aq.question_id
    join public.questions recent_q on recent_q.question_id = recent_aq.question_id
    left join public.attempt_answers recent_answer
      on recent_answer.attempt_id = recent_aq.attempt_id
     and recent_answer.question_id = recent_aq.question_id
    where recent_answer.selected_answer is not null
      and private.score_question_answer(recent_q.question_id, recent_answer.selected_answer) < recent_q.question_points
  ), priority_candidates as (
    select recent_wrong.question_id
    from recent_wrong_pool recent_wrong
    order by random()
    limit v_target_count
  ), random_candidates as (
    select scope_question.question_id
    from scope scope_question
    where not exists (
      select 1
      from priority_candidates priority_question
      where priority_question.question_id = scope_question.question_id
    )
    order by random()
    limit greatest(v_target_count - (select count(*) from priority_candidates), 0)
  ), chosen as (
    select question_id from priority_candidates
    union all
    select question_id from random_candidates
  )
  insert into public.attempt_questions(attempt_id, question_id, display_order)
  select v_attempt.id, c.question_id, row_number() over(order by random())::smallint
  from chosen c;

  select count(*),
         ceil(sum(ep.duration_minutes * 60.0 / ep.question_count))::integer,
         sum(q.question_points)
  into v_count, v_total_seconds, v_max_score
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  join public.exam_papers ep on ep.paper_id = q.paper_id
  where aq.attempt_id = v_attempt.id;

  if coalesce(v_count, 0) = 0 then
    delete from public.exam_attempts ea where ea.id = v_attempt.id;
    raise exception 'No questions were selected';
  end if;

  v_total_seconds := greatest(v_total_seconds, 60);
  update public.exam_attempts ea set
    duration_minutes = ceil(v_total_seconds / 60.0)::smallint,
    question_count = v_count,
    max_score = v_max_score,
    expires_at = v_started + make_interval(secs => v_total_seconds),
    selected_paper_kinds = (
      select array_agg(distinct private.paper_kind(ep.paper_code) order by private.paper_kind(ep.paper_code))
      from public.attempt_questions aq
      join public.questions q on q.question_id = aq.question_id
      join public.exam_papers ep on ep.paper_id = q.paper_id
      where aq.attempt_id = v_attempt.id
    )
  where ea.id = v_attempt.id
  returning ea.* into v_attempt;

  return jsonb_build_object(
    'attempt_id', v_attempt.id,
    'resumed', false,
    'started_at', v_attempt.started_at,
    'expires_at', v_attempt.expires_at,
    'duration_minutes', v_attempt.duration_minutes,
    'question_count', v_attempt.question_count
  );
end;
$$;

create or replace function public.start_review_attempt(
  p_source_attempt_ids uuid[],
  p_include_wrong boolean default true,
  p_include_exam_starred boolean default false,
  p_include_review_starred boolean default false,
  p_custom_title text default null
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
  v_labels text[] := '{}';
  v_title text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if coalesce(cardinality(p_source_attempt_ids), 0) = 0 then raise exception 'Select at least one attempt'; end if;
  if not (coalesce(p_include_wrong, false) or coalesce(p_include_exam_starred, false) or coalesce(p_include_review_starred, false)) then
    raise exception 'Select at least one review condition';
  end if;
  if exists (
    select 1 from unnest(p_source_attempt_ids) source_id
    left join public.exam_attempts ea on ea.id = source_id and ea.user_id = v_user
    where ea.id is null or ea.status = 'in_progress'
  ) then raise exception 'One or more source attempts are unavailable'; end if;

  if p_include_wrong then v_labels := array_append(v_labels, '錯題'); end if;
  if p_include_exam_starred then v_labels := array_append(v_labels, '模考星號'); end if;
  if p_include_review_starred then v_labels := array_append(v_labels, '檢討星號'); end if;
  v_title := coalesce(nullif(btrim(p_custom_title), ''), array_to_string(v_labels, '＋') || '｜複習組卷');

  insert into public.exam_attempts(
    user_id, paper_id, attempt_mode, title, is_timed,
    selected_years, selected_subjects, selected_subsubjects,
    duration_minutes, question_count, points_per_question, max_score,
    started_at, expires_at, exam_date,
    default_question_count, requested_question_count, selection_strategy,
    source_attempt_ids, review_include_wrong,
    review_include_exam_starred, review_include_review_starred
  ) values (
    v_user, null, 'wrong_review', v_title, false,
    '{}', '{}', '{}',
    0, 1, 2, 2,
    v_started, null, (v_started at time zone 'Asia/Taipei')::date,
    1, 1, 'review_union',
    p_source_attempt_ids, coalesce(p_include_wrong, false),
    coalesce(p_include_exam_starred, false), coalesce(p_include_review_starred, false)
  ) returning * into v_attempt;

  with source_questions as (
    select distinct aq.question_id
    from unnest(p_source_attempt_ids) source_id
    join public.exam_attempts source_attempt
      on source_attempt.id = source_id and source_attempt.user_id = v_user and source_attempt.status <> 'in_progress'
    join public.attempt_questions aq on aq.attempt_id = source_attempt.id
    join public.questions q on q.question_id = aq.question_id
    left join public.attempt_answers ans
      on ans.attempt_id = aq.attempt_id and ans.question_id = aq.question_id
    left join public.attempt_question_annotations exam_ann
      on exam_ann.attempt_id = aq.attempt_id and exam_ann.question_id = aq.question_id
    left join public.question_review_annotations review_ann
      on review_ann.user_id = v_user and review_ann.question_id = aq.question_id
    where
      (coalesce(p_include_wrong, false)
        and ans.selected_answer is not null
        and private.score_question_answer(q.question_id, ans.selected_answer) < q.question_points)
      or (coalesce(p_include_exam_starred, false) and coalesce(exam_ann.exam_is_starred, false))
      or (coalesce(p_include_review_starred, false) and coalesce(review_ann.review_is_starred, false))
  )
  insert into public.attempt_questions(attempt_id, question_id, display_order)
  select v_attempt.id, sq.question_id, row_number() over(order by random())::smallint
  from source_questions sq;

  select count(*), coalesce(sum(q.question_points), 0)
  into v_count, v_max_score
  from public.attempt_questions aq
  join public.questions q on q.question_id = aq.question_id
  where aq.attempt_id = v_attempt.id;

  if v_count = 0 then
    delete from public.exam_attempts ea where ea.id = v_attempt.id;
    raise exception 'No questions match the selected review conditions';
  end if;

  update public.exam_attempts ea set
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
    ),
    selected_subsubjects = (
      select coalesce(array_agg(distinct q.subsubject_primary order by q.subsubject_primary)
               filter (where q.subsubject_primary <> '未分類'), '{}')
      from public.attempt_questions aq
      join public.questions q on q.question_id = aq.question_id
      where aq.attempt_id = v_attempt.id
    ),
    selected_paper_kinds = (
      select array_agg(distinct private.paper_kind(ep.paper_code) order by private.paper_kind(ep.paper_code))
      from public.attempt_questions aq
      join public.questions q on q.question_id = aq.question_id
      join public.exam_papers ep on ep.paper_id = q.paper_id
      where aq.attempt_id = v_attempt.id
    )
  where ea.id = v_attempt.id
  returning ea.* into v_attempt;

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
      'selected_answer', ans.selected_answer, 'review_status', q.review_status,
      'subject_primary', q.subject_primary, 'subsubject_primary', q.subsubject_primary,
      'review_status', q.review_status,
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
      'question_count', v_attempt.question_count, 'points_per_question', v_attempt.points_per_question, 'started_at', v_attempt.started_at,
      'expires_at', v_attempt.expires_at, 'submitted_at', v_attempt.submitted_at,
      'submit_reason', v_attempt.submit_reason, 'correct_count', v_attempt.correct_count,
      'unanswered_count', v_attempt.unanswered_count, 'score', v_attempt.score,
      'max_score', v_attempt.max_score, 'elapsed_seconds', v_attempt.elapsed_seconds,
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
      'selected_answer', ans.selected_answer, 'correct_answer', answer_key.final_answer,
      'correct_answers', answer_key.accepted_answers, 'is_bonus', answer_key.is_bonus,
      'earned_points', scored.earned_points,
      'is_correct', scored.earned_points >= q.question_points,
      'is_unanswered', ans.selected_answer is null and not answer_key.is_bonus,
      'subject_primary', q.subject_primary, 'subsubject_primary', q.subsubject_primary,
      'review_status', q.review_status,
      'exam_is_starred', coalesce(exam_ann.exam_is_starred, false),
      'exam_note_text', coalesce(exam_ann.exam_note_text, ''),
      'review_is_starred', coalesce(review_ann.review_is_starred, false),
      'review_note_text', coalesce(review_ann.review_note_text, ''),
      'active_seconds', coalesce(activity.active_seconds, 0)
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
  cross join lateral (
    select private.score_question_answer(q.question_id, ans.selected_answer) as earned_points
  ) scored
  where aq.attempt_id = p_attempt_id
  group by ep.paper_id;

  return v_output;
end;
$$;

create or replace function public.list_my_attempts()
returns jsonb
language sql
security definer
set search_path = public, private, pg_temp
stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ea.id,
    'attempt_mode', ea.attempt_mode,
    'title', ea.title,
    'is_timed', ea.is_timed,
    'status', case when ea.status = 'in_progress' and ea.is_timed and ea.expires_at <= now()
                   then 'timed_out' else ea.status::text end,
    'duration_minutes', ea.duration_minutes,
    'question_count', ea.question_count,
    'started_at', ea.started_at,
    'exam_date', ea.exam_date,
    'expires_at', ea.expires_at,
    'submitted_at', ea.submitted_at,
    'submit_reason', ea.submit_reason,
    'elapsed_seconds', ea.elapsed_seconds,
    'correct_count', ea.correct_count,
    'unanswered_count', ea.unanswered_count,
    'score', ea.score,
    'max_score', ea.max_score,
    'paper_id', ep.paper_id,
    'exam_year_roc', ep.exam_year_roc,
    'paper_order', ep.paper_order,
    'paper_title', ep.paper_title,
    'paper_kind', case when ep.paper_code is null then null else private.paper_kind(ep.paper_code) end,
    'selected_paper_kinds', case
      when coalesce(cardinality(ea.selected_paper_kinds), 0) > 0 then ea.selected_paper_kinds
      when ep.paper_code is not null then array[private.paper_kind(ep.paper_code)]
      else '{}'::text[] end,
    'selected_years', ea.selected_years,
    'selected_subjects', ea.selected_subjects,
    'selected_subsubjects', ea.selected_subsubjects,
    'default_question_count', ea.default_question_count,
    'requested_question_count', ea.requested_question_count,
    'selection_strategy', ea.selection_strategy,
    'source_attempt_ids', ea.source_attempt_ids,
    'exam_star_count', (
      select count(*) from public.attempt_question_annotations ann
      where ann.attempt_id = ea.id and ann.exam_is_starred
    ),
    'review_star_count', (
      select count(*)
      from public.attempt_questions aq
      join public.question_review_annotations rann
        on rann.question_id = aq.question_id and rann.user_id = ea.user_id and rann.review_is_starred
      where aq.attempt_id = ea.id
    )
  ) order by ea.started_at desc), '[]'::jsonb)
  from public.exam_attempts ea
  left join public.exam_papers ep on ep.paper_id = ea.paper_id
  where ea.user_id = auth.uid();
$$;

revoke all on function private.paper_kind(text) from public, anon, authenticated;
revoke all on function public.start_exam_attempt(text) from public, anon;
revoke all on function public.save_exam_annotation(uuid,text,boolean,text) from public, anon;
revoke all on function public.save_review_annotation(text,boolean,text) from public, anon;
revoke all on function public.start_custom_subject_attempt(smallint[],text[],text[],integer,text,date) from public, anon;
revoke all on function public.start_review_attempt(uuid[],boolean,boolean,boolean,text) from public, anon;
revoke all on function public.get_attempt_payload(uuid) from public, anon;
revoke all on function public.get_attempt_result(uuid) from public, anon;
revoke all on function public.list_my_attempts() from public, anon;

grant execute on function public.start_exam_attempt(text) to authenticated;
grant execute on function public.save_exam_annotation(uuid,text,boolean,text) to authenticated;
grant execute on function public.save_review_annotation(text,boolean,text) to authenticated;
grant execute on function public.start_custom_subject_attempt(smallint[],text[],text[],integer,text,date) to authenticated;
grant execute on function public.start_review_attempt(uuid[],boolean,boolean,boolean,text) to authenticated;
grant execute on function public.get_attempt_payload(uuid) to authenticated;
grant execute on function public.get_attempt_result(uuid) to authenticated;
grant execute on function public.list_my_attempts() to authenticated;
