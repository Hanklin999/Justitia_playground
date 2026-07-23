-- Justitia_playground repeat-safe setup v2
-- Safe to run after a partially failed setup or to rerun after successful setup.
-- Existing user attempts and answers are preserved.

-- ===== 0001_initial_schema.sql =====
-- Justitia_playground initial schema
-- Run on a fresh Supabase project through SQL Editor or Supabase CLI.

create extension if not exists pgcrypto;
create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'attempt_status'
  ) then
    create type public.attempt_status as enum ('in_progress', 'submitted', 'timed_out');
  end if;

  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'submit_reason'
  ) then
    create type public.submit_reason as enum ('manual', 'timeout');
  end if;
end
$$;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.exam_papers (
  paper_id text primary key,
  exam_year_roc smallint not null,
  exam_year_ad smallint not null,
  exam_code integer not null,
  paper_order smallint not null check (paper_order between 1 and 4),
  paper_code text not null,
  paper_group text not null,
  paper_title text not null,
  included_subjects text[] not null default '{}',
  duration_minutes smallint not null check (duration_minutes > 0),
  question_count smallint not null check (question_count > 0),
  points_per_question numeric(6,2) not null check (points_per_question > 0),
  max_score numeric(8,2) not null check (max_score > 0),
  source_question_url text not null,
  source_answer_url text not null,
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (exam_year_roc, paper_code)
);

-- Public question content intentionally excludes the official answer.
create table if not exists public.questions (
  question_id text primary key,
  paper_id text not null references public.exam_papers(paper_id) on delete cascade,
  question_number smallint not null,
  question_type text not null default 'single_choice'
    check (question_type = 'single_choice'),
  question_text text not null,
  option_a text not null,
  option_b text not null,
  option_c text not null,
  option_d text not null,
  subject_primary text,
  subject_secondary text[] not null default '{}',
  chapter text,
  topic_primary text,
  topic_secondary text[] not null default '{}',
  law_refs text[] not null default '{}',
  tags text[] not null default '{}',
  source_page_start smallint,
  source_page_end smallint,
  extraction_status text not null default 'parsed',
  review_status text not null default 'pending_manual_review',
  notes text,
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (paper_id, question_number)
);

-- Answer keys are stored outside the exposed public schema.
create table if not exists private.question_answer_keys (
  question_id text primary key references public.questions(question_id) on delete cascade,
  original_answer char(1) check (original_answer in ('A', 'B', 'C', 'D')),
  final_answer char(1) not null check (final_answer in ('A', 'B', 'C', 'D')),
  official_answer_status text not null default 'official_standard',
  official_notice_url text,
  updated_at timestamptz not null default now()
);

create table if not exists public.exam_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  paper_id text not null references public.exam_papers(paper_id),
  status public.attempt_status not null default 'in_progress',
  duration_minutes smallint not null,
  question_count smallint not null,
  points_per_question numeric(6,2) not null,
  max_score numeric(8,2) not null,
  started_at timestamptz not null,
  expires_at timestamptz not null,
  submitted_at timestamptz,
  submit_reason public.submit_reason,
  correct_count smallint,
  unanswered_count smallint,
  score numeric(8,2),
  created_at timestamptz not null default now(),
  check (expires_at > started_at),
  check (
    (status = 'in_progress' and submitted_at is null and submit_reason is null)
    or
    (status <> 'in_progress' and submitted_at is not null and submit_reason is not null)
  )
);

comment on column public.exam_attempts.duration_minutes is
  'Snapshot of the official paper duration when the attempt starts.';

create table if not exists public.attempt_questions (
  attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
  question_id text not null references public.questions(question_id),
  display_order smallint not null,
  primary key (attempt_id, question_id),
  unique (attempt_id, display_order)
);

create table if not exists public.attempt_answers (
  attempt_id uuid not null,
  question_id text not null,
  selected_answer char(1) not null check (selected_answer in ('A', 'B', 'C', 'D')),
  saved_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  foreign key (attempt_id, question_id)
    references public.attempt_questions(attempt_id, question_id)
    on delete cascade
);

create table if not exists public.question_bookmarks (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references public.questions(question_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, question_id)
);

create index if not exists exam_papers_year_order_idx
  on public.exam_papers (exam_year_roc desc, paper_order);
create index if not exists questions_paper_number_idx
  on public.questions (paper_id, question_number);
create index if not exists exam_attempts_user_started_idx
  on public.exam_attempts (user_id, started_at desc);
create index if not exists exam_attempts_expiry_idx
  on public.exam_attempts (status, expires_at)
  where status = 'in_progress';
create index if not exists attempt_answers_attempt_idx
  on public.attempt_answers (attempt_id);

-- Create a profile row automatically when a Magic Link user is created.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (user_id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Internal, idempotent scoring function.
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
  v_answered integer;
begin
  select * into v_attempt
  from public.exam_attempts
  where id = p_attempt_id
  for update;

  if not found then
    raise exception 'Attempt not found';
  end if;

  if v_attempt.status <> 'in_progress' then
    return v_attempt;
  end if;

  v_reason := case
    when now() >= v_attempt.expires_at then 'timeout'::public.submit_reason
    else coalesce(p_requested_reason, 'manual'::public.submit_reason)
  end;

  select
    count(*) filter (where aa.selected_answer = ak.final_answer),
    count(aa.selected_answer)
  into v_correct, v_answered
  from public.attempt_questions aq
  join private.question_answer_keys ak on ak.question_id = aq.question_id
  left join public.attempt_answers aa
    on aa.attempt_id = aq.attempt_id
   and aa.question_id = aq.question_id
  where aq.attempt_id = p_attempt_id;

  update public.exam_attempts
  set
    status = case
      when v_reason = 'timeout' then 'timed_out'::public.attempt_status
      else 'submitted'::public.attempt_status
    end,
    submit_reason = v_reason,
    submitted_at = case
      when v_reason = 'timeout' then expires_at
      else now()
    end,
    correct_count = v_correct,
    unanswered_count = question_count - v_answered,
    score = v_correct * points_per_question
  where id = p_attempt_id
  returning * into v_attempt;

  return v_attempt;
end;
$$;

create or replace function public.start_exam_attempt(p_paper_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_paper public.exam_papers%rowtype;
  v_attempt public.exam_attempts%rowtype;
  v_started_at timestamptz := clock_timestamp();
  v_question_count integer;
  v_expired record;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  -- Finalize stale attempts for this user before creating/resuming one.
  for v_expired in
    select id from public.exam_attempts
    where user_id = v_user_id
      and status = 'in_progress'
      and expires_at <= now()
  loop
    perform private.finalize_exam_attempt(v_expired.id, 'timeout');
  end loop;

  select * into v_paper
  from public.exam_papers
  where paper_id = p_paper_id
    and is_published = true;

  if not found then
    raise exception 'Published paper not found';
  end if;

  -- Resume the same active paper rather than creating duplicate live attempts.
  select * into v_attempt
  from public.exam_attempts
  where user_id = v_user_id
    and paper_id = p_paper_id
    and status = 'in_progress'
    and expires_at > now()
  order by started_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'attempt_id', v_attempt.id,
      'resumed', true,
      'started_at', v_attempt.started_at,
      'expires_at', v_attempt.expires_at,
      'duration_minutes', v_attempt.duration_minutes
    );
  end if;

  select count(*) into v_question_count
  from public.questions
  where paper_id = p_paper_id
    and is_published = true;

  if v_question_count <> v_paper.question_count then
    raise exception 'Paper % expects % questions but % are published',
      p_paper_id, v_paper.question_count, v_question_count;
  end if;

  insert into public.exam_attempts (
    user_id,
    paper_id,
    duration_minutes,
    question_count,
    points_per_question,
    max_score,
    started_at,
    expires_at
  ) values (
    v_user_id,
    v_paper.paper_id,
    v_paper.duration_minutes,
    v_question_count,
    v_paper.points_per_question,
    v_paper.max_score,
    v_started_at,
    v_started_at + make_interval(mins => v_paper.duration_minutes)
  ) returning * into v_attempt;

  insert into public.attempt_questions (attempt_id, question_id, display_order)
  select v_attempt.id, question_id, question_number
  from public.questions
  where paper_id = p_paper_id
    and is_published = true
  order by question_number;

  return jsonb_build_object(
    'attempt_id', v_attempt.id,
    'resumed', false,
    'started_at', v_attempt.started_at,
    'expires_at', v_attempt.expires_at,
    'duration_minutes', v_attempt.duration_minutes
  );
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
  v_user_id uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_saved_at timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_selected_answer not in ('A', 'B', 'C', 'D') then
    raise exception 'Invalid answer';
  end if;

  select * into v_attempt
  from public.exam_attempts
  where id = p_attempt_id
    and user_id = v_user_id
  for update;

  if not found then
    raise exception 'Attempt not found';
  end if;

  if v_attempt.status <> 'in_progress' then
    return jsonb_build_object('ok', false, 'status', v_attempt.status);
  end if;

  if now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
    return jsonb_build_object('ok', false, 'status', v_attempt.status);
  end if;

  if not exists (
    select 1 from public.attempt_questions
    where attempt_id = p_attempt_id
      and question_id = p_question_id
  ) then
    raise exception 'Question is not part of this attempt';
  end if;

  insert into public.attempt_answers (
    attempt_id, question_id, selected_answer, saved_at
  ) values (
    p_attempt_id, p_question_id, p_selected_answer::char(1), v_saved_at
  )
  on conflict (attempt_id, question_id)
  do update set
    selected_answer = excluded.selected_answer,
    saved_at = excluded.saved_at;

  return jsonb_build_object(
    'ok', true,
    'status', 'in_progress',
    'saved_at', v_saved_at
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
  v_user_id uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
  v_payload jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_attempt
  from public.exam_attempts
  where id = p_attempt_id
    and user_id = v_user_id;

  if not found then
    raise exception 'Attempt not found';
  end if;

  if v_attempt.status = 'in_progress' and now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
  end if;

  select jsonb_build_object(
    'attempt', jsonb_build_object(
      'id', a.id,
      'paper_id', a.paper_id,
      'status', a.status,
      'duration_minutes', a.duration_minutes,
      'question_count', a.question_count,
      'points_per_question', a.points_per_question,
      'max_score', a.max_score,
      'started_at', a.started_at,
      'expires_at', a.expires_at,
      'submitted_at', a.submitted_at,
      'submit_reason', a.submit_reason
    ),
    'paper', jsonb_build_object(
      'exam_year_roc', p.exam_year_roc,
      'paper_order', p.paper_order,
      'paper_code', p.paper_code,
      'paper_title', p.paper_title,
      'included_subjects', p.included_subjects,
      'source_question_url', p.source_question_url
    ),
    'questions', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'question_id', q.question_id,
          'question_number', q.question_number,
          'question_text', q.question_text,
          'option_a', q.option_a,
          'option_b', q.option_b,
          'option_c', q.option_c,
          'option_d', q.option_d,
          'selected_answer', aa.selected_answer,
          'review_status', q.review_status
        ) order by aq.display_order
      ),
      '[]'::jsonb
    )
  ) into v_payload
  from public.exam_attempts a
  join public.exam_papers p on p.paper_id = a.paper_id
  join public.attempt_questions aq on aq.attempt_id = a.id
  join public.questions q on q.question_id = aq.question_id
  left join public.attempt_answers aa
    on aa.attempt_id = aq.attempt_id
   and aa.question_id = aq.question_id
  where a.id = p_attempt_id
  group by a.id, p.paper_id;

  return v_payload;
end;
$$;

create or replace function public.submit_exam_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_attempt public.exam_attempts%rowtype;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.exam_attempts
    where id = p_attempt_id and user_id = v_user_id
  ) then
    raise exception 'Attempt not found';
  end if;

  v_attempt := private.finalize_exam_attempt(
    p_attempt_id,
    case when now() >= (
      select expires_at from public.exam_attempts where id = p_attempt_id
    ) then 'timeout'::public.submit_reason else 'manual'::public.submit_reason end
  );

  return jsonb_build_object(
    'attempt_id', v_attempt.id,
    'status', v_attempt.status,
    'submit_reason', v_attempt.submit_reason,
    'submitted_at', v_attempt.submitted_at,
    'score', v_attempt.score,
    'max_score', v_attempt.max_score,
    'correct_count', v_attempt.correct_count,
    'unanswered_count', v_attempt.unanswered_count
  );
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
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_attempt
  from public.exam_attempts
  where id = p_attempt_id
    and user_id = v_user_id;

  if not found then
    raise exception 'Attempt not found';
  end if;

  if v_attempt.status = 'in_progress' and now() >= v_attempt.expires_at then
    v_attempt := private.finalize_exam_attempt(p_attempt_id, 'timeout');
  elsif v_attempt.status = 'in_progress' then
    raise exception 'Attempt is still in progress';
  end if;

  select jsonb_build_object(
    'attempt', jsonb_build_object(
      'id', a.id,
      'status', a.status,
      'duration_minutes', a.duration_minutes,
      'started_at', a.started_at,
      'expires_at', a.expires_at,
      'submitted_at', a.submitted_at,
      'submit_reason', a.submit_reason,
      'correct_count', a.correct_count,
      'unanswered_count', a.unanswered_count,
      'score', a.score,
      'max_score', a.max_score
    ),
    'paper', jsonb_build_object(
      'exam_year_roc', p.exam_year_roc,
      'paper_order', p.paper_order,
      'paper_code', p.paper_code,
      'paper_title', p.paper_title,
      'source_question_url', p.source_question_url,
      'source_answer_url', p.source_answer_url
    ),
    'questions', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'question_id', q.question_id,
          'question_number', q.question_number,
          'question_text', q.question_text,
          'option_a', q.option_a,
          'option_b', q.option_b,
          'option_c', q.option_c,
          'option_d', q.option_d,
          'selected_answer', aa.selected_answer,
          'correct_answer', ak.final_answer,
          'is_correct', coalesce(aa.selected_answer = ak.final_answer, false),
          'is_unanswered', aa.selected_answer is null,
          'review_status', q.review_status
        ) order by aq.display_order
      ),
      '[]'::jsonb
    )
  ) into v_result
  from public.exam_attempts a
  join public.exam_papers p on p.paper_id = a.paper_id
  join public.attempt_questions aq on aq.attempt_id = a.id
  join public.questions q on q.question_id = aq.question_id
  join private.question_answer_keys ak on ak.question_id = q.question_id
  left join public.attempt_answers aa
    on aa.attempt_id = aq.attempt_id
   and aa.question_id = aq.question_id
  where a.id = p_attempt_id
  group by a.id, p.paper_id;

  return v_result;
end;
$$;

create or replace function public.list_my_attempts()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'status', case
          when a.status = 'in_progress' and a.expires_at <= now()
            then 'timed_out'
          else a.status::text
        end,
        'duration_minutes', a.duration_minutes,
        'started_at', a.started_at,
        'expires_at', a.expires_at,
        'submitted_at', a.submitted_at,
        'submit_reason', a.submit_reason,
        'correct_count', a.correct_count,
        'unanswered_count', a.unanswered_count,
        'score', a.score,
        'max_score', a.max_score,
        'paper_id', p.paper_id,
        'exam_year_roc', p.exam_year_roc,
        'paper_order', p.paper_order,
        'paper_title', p.paper_title
      ) order by a.started_at desc
    ),
    '[]'::jsonb
  )
  from public.exam_attempts a
  join public.exam_papers p on p.paper_id = a.paper_id
  where a.user_id = auth.uid();
$$;

-- Row-level security remains the final safety boundary for direct reads.
alter table public.profiles enable row level security;
alter table public.exam_papers enable row level security;
alter table public.questions enable row level security;
alter table public.exam_attempts enable row level security;
alter table public.attempt_questions enable row level security;
alter table public.attempt_answers enable row level security;
alter table public.question_bookmarks enable row level security;

drop policy if exists "published papers are readable" on public.exam_papers;
create policy "published papers are readable"
on public.exam_papers for select
using (is_published = true);

drop policy if exists "authenticated users read published questions" on public.questions;
create policy "authenticated users read published questions"
on public.questions for select to authenticated
using (is_published = true);

drop policy if exists "users read own profile" on public.profiles;
create policy "users read own profile"
on public.profiles for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile"
on public.profiles for update to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "users read own attempts" on public.exam_attempts;
create policy "users read own attempts"
on public.exam_attempts for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "users read own attempt questions" on public.attempt_questions;
create policy "users read own attempt questions"
on public.attempt_questions for select to authenticated
using (exists (
  select 1 from public.exam_attempts a
  where a.id = attempt_id and a.user_id = auth.uid()
));

drop policy if exists "users read own answers" on public.attempt_answers;
create policy "users read own answers"
on public.attempt_answers for select to authenticated
using (exists (
  select 1 from public.exam_attempts a
  where a.id = attempt_id and a.user_id = auth.uid()
));

drop policy if exists "users read own bookmarks" on public.question_bookmarks;
create policy "users read own bookmarks"
on public.question_bookmarks for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "users create own bookmarks" on public.question_bookmarks;
create policy "users create own bookmarks"
on public.question_bookmarks for insert to authenticated
with check (auth.uid() = user_id);

drop policy if exists "users delete own bookmarks" on public.question_bookmarks;
create policy "users delete own bookmarks"
on public.question_bookmarks for delete to authenticated
using (auth.uid() = user_id);

-- Explicit privileges. No direct client writes to attempts or answers.
revoke all on table public.profiles from anon, authenticated;
revoke all on table public.exam_papers from anon, authenticated;
revoke all on table public.questions from anon, authenticated;
revoke all on table public.exam_attempts from anon, authenticated;
revoke all on table public.attempt_questions from anon, authenticated;
revoke all on table public.attempt_answers from anon, authenticated;
revoke all on table public.question_bookmarks from anon, authenticated;

grant usage on schema public to anon, authenticated;
grant select on public.exam_papers to anon, authenticated;
grant select on public.questions to authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, updated_at) on public.profiles to authenticated;
grant select on public.exam_attempts to authenticated;
grant select on public.attempt_questions to authenticated;
grant select on public.attempt_answers to authenticated;
grant select, insert, delete on public.question_bookmarks to authenticated;

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function private.finalize_exam_attempt(uuid, public.submit_reason) from public, anon, authenticated;
revoke all on function public.start_exam_attempt(text) from public, anon;
revoke all on function public.save_attempt_answer(uuid, text, text) from public, anon;
revoke all on function public.get_attempt_payload(uuid) from public, anon;
revoke all on function public.submit_exam_attempt(uuid) from public, anon;
revoke all on function public.get_attempt_result(uuid) from public, anon;
revoke all on function public.list_my_attempts() from public, anon;

grant execute on function public.start_exam_attempt(text) to authenticated;
grant execute on function public.save_attempt_answer(uuid, text, text) to authenticated;
grant execute on function public.get_attempt_payload(uuid) to authenticated;
grant execute on function public.submit_exam_attempt(uuid) to authenticated;
grant execute on function public.get_attempt_result(uuid) to authenticated;
grant execute on function public.list_my_attempts() to authenticated;


