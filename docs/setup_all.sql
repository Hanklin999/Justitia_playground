-- ===== 0001_initial_schema.sql =====
-- Justitia_playground initial schema
-- Run on a fresh Supabase project through SQL Editor or Supabase CLI.

create extension if not exists pgcrypto;
create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

create type public.attempt_status as enum ('in_progress', 'submitted', 'timed_out');
create type public.submit_reason as enum ('manual', 'timeout');

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.exam_papers (
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
create table public.questions (
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
create table private.question_answer_keys (
  question_id text primary key references public.questions(question_id) on delete cascade,
  original_answer char(1) check (original_answer in ('A', 'B', 'C', 'D')),
  final_answer char(1) not null check (final_answer in ('A', 'B', 'C', 'D')),
  official_answer_status text not null default 'official_standard',
  official_notice_url text,
  updated_at timestamptz not null default now()
);

create table public.exam_attempts (
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

create table public.attempt_questions (
  attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
  question_id text not null references public.questions(question_id),
  display_order smallint not null,
  primary key (attempt_id, question_id),
  unique (attempt_id, display_order)
);

create table public.attempt_answers (
  attempt_id uuid not null,
  question_id text not null,
  selected_answer char(1) not null check (selected_answer in ('A', 'B', 'C', 'D')),
  saved_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  foreign key (attempt_id, question_id)
    references public.attempt_questions(attempt_id, question_id)
    on delete cascade
);

create table public.question_bookmarks (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references public.questions(question_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, question_id)
);

create index exam_papers_year_order_idx
  on public.exam_papers (exam_year_roc desc, paper_order);
create index questions_paper_number_idx
  on public.questions (paper_id, question_number);
create index exam_attempts_user_started_idx
  on public.exam_attempts (user_id, started_at desc);
create index exam_attempts_expiry_idx
  on public.exam_attempts (status, expires_at)
  where status = 'in_progress';
create index attempt_answers_attempt_idx
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

create policy "published papers are readable"
on public.exam_papers for select
using (is_published = true);

create policy "authenticated users read published questions"
on public.questions for select to authenticated
using (is_published = true);

create policy "users read own profile"
on public.profiles for select to authenticated
using (auth.uid() = user_id);

create policy "users update own profile"
on public.profiles for update to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy "users read own attempts"
on public.exam_attempts for select to authenticated
using (auth.uid() = user_id);

create policy "users read own attempt questions"
on public.attempt_questions for select to authenticated
using (exists (
  select 1 from public.exam_attempts a
  where a.id = attempt_id and a.user_id = auth.uid()
));

create policy "users read own answers"
on public.attempt_answers for select to authenticated
using (exists (
  select 1 from public.exam_attempts a
  where a.id = attempt_id and a.user_id = auth.uid()
));

create policy "users read own bookmarks"
on public.question_bookmarks for select to authenticated
using (auth.uid() = user_id);

create policy "users create own bookmarks"
on public.question_bookmarks for insert to authenticated
with check (auth.uid() = user_id);

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


-- ===== 0002_seed_113_114.sql =====
-- Seed generated from official MOEX PDFs for ROC years 113 and 114.
-- Questions are published for MVP testing but remain marked pending_manual_review.
begin;

insert into public.exam_papers (
  paper_id, exam_year_roc, exam_year_ad, exam_code, paper_order, paper_code,
  paper_group, paper_title, included_subjects, duration_minutes, question_count,
  points_per_question, max_score, source_question_url, source_answer_url, is_published
) values
('113-2301', 113, 2024, 113110, 1, '2301', '綜合法學(一)', '綜合法學(一)（憲法、行政法、國際公法、國際私法）', array['憲法', '行政法', '國際公法', '國際私法']::text[], 90, 75, 2, 150, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0101&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0101&t=S', true),
('113-3301', 113, 2024, 113110, 2, '3301', '綜合法學(二)', '綜合法學(二)（民法、民事訴訟法）', array['民法', '民事訴訟法']::text[], 100, 80, 2, 160, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0201&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0201&t=S', true),
('113-4301', 113, 2024, 113110, 3, '4301', '綜合法學(二)', '綜合法學(二)（公司法、保險法、票據法、證券交易法、強制執行法、法學英文）', array['公司法', '保險法', '票據法', '證券交易法', '強制執行法', '法學英文']::text[], 80, 70, 2, 140, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0202&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0202&t=S', true),
('113-1301', 113, 2024, 113110, 4, '1301', '綜合法學(一)', '綜合法學(一)（刑法、刑事訴訟法、法律倫理）', array['刑法', '刑事訴訟法', '法律倫理']::text[], 90, 75, 2, 150, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0301&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=113110&q=1&s=0301&t=S', true),
('114-2301', 114, 2025, 114110, 1, '2301', '綜合法學(一)', '綜合法學(一)（憲法、行政法、國際公法、國際私法）', array['憲法', '行政法', '國際公法', '國際私法']::text[], 90, 75, 2, 150, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0101&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0101&t=S', true),
('114-3301', 114, 2025, 114110, 2, '3301', '綜合法學(二)', '綜合法學(二)（民法、民事訴訟法）', array['民法', '民事訴訟法']::text[], 100, 80, 2, 160, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0201&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0201&t=S', true),
('114-4301', 114, 2025, 114110, 3, '4301', '綜合法學(二)', '綜合法學(二)（公司法、保險法、票據法、證券交易法、強制執行法、法學英文）', array['公司法', '保險法', '票據法', '證券交易法', '強制執行法', '法學英文']::text[], 80, 70, 2, 140, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0202&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0202&t=S', true),
('114-1301', 114, 2025, 114110, 4, '1301', '綜合法學(一)', '綜合法學(一)（刑法、刑事訴訟法、法律倫理）', array['刑法', '刑事訴訟法', '法律倫理']::text[], 90, 75, 2, 150, 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0301&t=Q', 'https://wwwq.moex.gov.tw/exam/wHandExamQandA_File.ashx?c=303&code=114110&q=1&s=0301&t=S', true)
on conflict (paper_id) do update set
  paper_title = excluded.paper_title,
  included_subjects = excluded.included_subjects,
  duration_minutes = excluded.duration_minutes,
  question_count = excluded.question_count,
  points_per_question = excluded.points_per_question,
  max_score = excluded.max_score,
  source_question_url = excluded.source_question_url,
  source_answer_url = excluded.source_answer_url,
  is_published = excluded.is_published,
  updated_at = now();

-- Question batch 1
insert into public.questions (
  question_id, paper_id, question_number, question_type, question_text,
  option_a, option_b, option_c, option_d, subject_primary, subject_secondary,
  chapter, topic_primary, topic_secondary, law_refs, tags, source_page_start,
  source_page_end, extraction_status, review_status, notes, is_published
) values
('113-2301-001', '113-2301', 1, 'single_choice', '關於貨物應許自由流通之憲法規定，下列敘述何者錯誤？', '體系上屬基本國策章之規定，並非全無規範效力', '為確保該規定目標得以實現，國家公權力之行使至少不應與其背道而馳', '本條規定係以全國為空間範圍，故跨地方轄區間之貨物自由流通應受到保障', '地方自治立法禁止特定之合法商品於轄內進行交易，屬地方自治權之行使，應優先於本條適用', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-2301-002', '113-2301', 2, 'single_choice', '關於憲法人身自由之規定，依司法院解釋意旨，下列敘述何者正確？', '憲法第8 條第1 項所稱之法院，指有審判權之法官所構成之獨任或合議之法院', '憲法第8 條第1 項所稱之司法機關，並不包括檢察機關', '憲法第8 條有關提審之規定，以非法逮捕拘禁為要件', '憲法第8 條第1 項所稱之審問機關，包含法院以外之機關', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-2301-003', '113-2301', 3, 'single_choice', '有關遷徙自由，下列敘述何者錯誤？', '於臺灣地區設有住所而有戶籍之國民得隨時返回我國，無待許可', '僑居國外具有中華民國國籍之國民若非於臺灣地區設有住所而有戶籍，仍應適用相關法律之規定， 始得返國', '大陸地區人民進入臺灣地區設有限制，係法律特別規定，應符合憲法增修條文第11 條之意旨', '香港澳門地區人民進入臺灣地區之限制，係比照外國人，適用入出國及移民法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-2301-004', '113-2301', 4, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於政黨之敘述，下列何者錯誤？', '政黨為人民之政治性結社團體，受憲法結社自由之保障', '政黨之目的，危害自由民主之憲政秩序者，得由憲法法庭宣告解散之', '政黨在民主競爭下，享有公平參與選舉及平等接近使用各種公共資源之機會', '政黨經營營利事業，受憲法保障，法律不得限制之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-2301-005', '113-2301', 5, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於法規範差別待遇之合憲性審查標準，下列敘述何者正確？', '法規範採取性別分類而形成差別待遇者，因係以難以改變之個人特徵、歷史性或系統性之刻板印象 為差別待遇之標準，應採嚴格審查', '法規範就僅父或母為原住民者，附加「從具原住民身分之父或母之姓或原住民傳統名字」之要求， 因未涉及原住民身分認同之重要基本權利，應採中度審查', '法規範以媒合是否涉及跨國（境）婚姻為分類，而對跨國（境）婚姻媒合給予相對不利之差別待遇， 未涉及可疑分類，亦未涉及攸關個人人格發展及人性尊嚴之重要基本權利，應採中度審查', '法規範將特定犯罪規定為告訴乃論之罪，係屬刑事立法政策之選擇，其因此與其他非告訴乃論之罪 形成之差別待遇，應採寬鬆審查', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-2301-006', '113-2301', 6, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於財產權之社會義務性，下列敘述何者錯誤？', '行使財產權應依法受社會責任及環境生態責任之限制，形成個人利益之特別犧牲時，既係因社會責 任所生，當無補償之必要', '法律限制對土地之利用至為輕微，則屬人民享受財產權同時所應負擔之社會義務，騎樓即為適例', '財產權人之財產已由過去不受限制支配之絕對性，轉變成並非聽由財產權人任意為之，而須注意到 公共利益', '基於增進公共利益之必要，對人民依法取得之土地所有權，國家並非不得以法律為合理之限制', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-2301-007', '113-2301', 7, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於憲法上工作權之保障及其限制，下列敘述何者錯誤？', '職業自由為人民充實生活內涵及自由發展人格所必要，不因職業之性質為公益或私益、營利或非營 利而有異', '人民之工作權保障，包括選擇職業之自由', '憲法工作權保障人民有開業、停業與否及從事營業之時間、地點、對象及方式之自由', '營業場所之選定亦受營業自由保障，僅得以法律為必要之限制，不得授權主管機關發布法規命令為 規範', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-008', '113-2301', 8, 'single_choice', '憲法上人民權利救濟請求權，下列敘述何者正確？', '訴願作為行政訴訟之先行程序，係對人民訴訟權施予不必要之限制', '訴願審理之範圍必須與法院審理之範圍相同', '人民請願未獲得行政機關積極處理時，得提起訴願', '憲法並未規定訴願審議委員會之具體組成方式', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-009', '113-2301', 9, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，有關人民之受教育權，下列敘述何者錯誤？', '國民受教育之機會，一律平等。對於原住民族、身心障礙者之教育，考慮其自主性及特殊性，應依 法令予以特別保障', '已逾學齡未受基本教育之國民，有受補習教育之權利', '憲法所稱6 歲至12 歲之學齡兒童，一律受基本教育，係屬最低標準', '受國民教育以外教育者，尚包括賦予人民請求給予入學許可、提供特定教育給付之權利', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-010', '113-2301', 10, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，有關法律保留原則，下列敘述何者錯誤？', '凡是限制人民自由權利之事項，概應由立法者以法律直接規定之', '屬於執行法律之技術性或細節性之事項，法律得交由主管機關發布命令為必要之規範', '法律授權行政機關以命令補充規定者，母法之授權必須明確', '基於法律授權而訂定法規命令，不得逾越授權範圍', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-011', '113-2301', 11, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於未成年人之人格權，下列敘述何者錯誤？', '受概括基本權之保障，屬具憲法位階之權利', '公權力措施涉及未成年人之人格權時，應以維護未成年人之最佳利益為依歸', '家事非訟程序中，為尊重未成年人之人格獨立與主體性，法院應踐行給予陳述意見機會之正當法律 程序', '公權力措施涉及未成年人與父母意見不一致時，本於人格權之保障，概以未成年人意願為優先', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-012', '113-2301', 12, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於基本權之保障，下列敘述何者錯誤？', '公立大學就各科系學生畢業條件之規定，受憲法大學自治之保障', '中央與地方合資經營之公營公司，概不受憲法財產權之保障', '少年若涉及少年保護事件處理程序，其到庭陳述意見，應受正當法律程序之保障', '街頭藝人之藝文活動受憲法藝術表現自由之保障', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-013', '113-2301', 13, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於總統之權力，下列敘述何者錯誤？', '總統於憲法及憲法增修條文所賦予之行政權範圍內，為最高行政首長', '總統得經由其任命之行政院院長，變更先前存在，與其政見未洽之施政方針或政策', '總統之刑事豁免權不得事前、概括拋棄，但於個案中仍得拋棄，而使檢察官以總統為被告提起公訴', '總統就有關國家安全、國防及外交資訊之公開與否，享有國家機密特權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-014', '113-2301', 14, 'single_choice', '依憲法及司法院解釋意旨與憲法法庭裁判，下列何者有至立法院委員會，就相關法律案及預算案備詢 之義務？', '司法院秘書長', '監察院院長', '臺北市市長', '考試委員', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-2301-015', '113-2301', 15, 'single_choice', '依憲法、司法院解釋意旨及憲法法庭裁判，下列何者非屬監察院之職權？', '向行政院及其各部會調閱其所發布之命令及各種有關文件', '為行使職權，按行政院及其各部會之工作，分設若干委員會', '彈劾、糾舉及審計權為憲法明定之職權', '對於所有中央民選公職人員提出彈劾案', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-016', '113-2301', 16, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，下列何者就法官審理程序有關之技術性事項有規則制定權？', '司法院', '法務部', '立法院', '審判長', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-017', '113-2301', 17, 'single_choice', '依憲法訴訟法規定，有關立法委員聲請憲法法庭為法規範憲法審查之敘述，下列何者正確？', '若緊急命令有違憲之疑慮，符合法定人數之立法委員得提出聲請', '須由現有總額至少五分之一以上之立法委員提出聲請', '若少數立法委員認為多數立法委員於法律議案表決時侵害其受憲法保障之權力，即得提出聲請', '須於違憲爭議事件發生後6 個月內提出聲請', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-018', '113-2301', 18, 'single_choice', '關於憲法訴訟法規定之機關爭議案件，下列敘述何者錯誤？', '此一訴訟種類為憲法訴訟法新增，以往並無類此之案件類型', '限於國家最高機關之間憲法上權限之爭議', '應先由爭議之機關進行協商', '應於法定之6 個月不變期間內提出聲請', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-019', '113-2301', 19, 'single_choice', '甲縣主管機關所為之下列行為，何者中央主管機關僅得為合法性監督，而不得為合目的性監督？', '依道路交通管理處罰條例所為之行為', '依公職人員選舉罷免法辦理立法委員之選舉', '依該縣自治條例所為之行為', '依該縣委辦規則所為之行為', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-020', '113-2301', 20, 'single_choice', '有關憲法保障之基本權利，下列敘述何者錯誤？', '基本權利之限制適用法律保留原則', '法人作為基本權利主體，僅限於私法人', '保障基本權利是自由民主憲政秩序之基礎', '基本權利之保障規定，其拘束對象，原則上為公權力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-021', '113-2301', 21, 'single_choice', '依我國司法實務之見解，下列何者非屬私法性質之爭議？', '台灣電力公司關於發電機組採購案之決標爭議', '台灣自來水公司與用戶間關於水費之爭議', '臺灣銀行股份有限公司與退休公務人員間關於優惠存款契約之爭議', '既成道路之土地所有權人依民法物上請求權請求市政府刨除柏油路面並返還土地', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-022', '113-2301', 22, 'single_choice', '依司法院解釋意旨，關於權利救濟途徑之敘述，下列何者正確？', '政府依實施耕者有其田條例所為之耕地徵收，耕地所有權人得以權利受損為理由，提起民事訴訟， 請求返還土地', '政府機關與承租人就國民住宅租賃契約所生之爭議，應循行政爭訟程序解決之', '人民依國有財產法第52 條之2 規定申請讓售國有非公用財產之不動產所生之爭議，應循民事訴訟程 序解決之', '人民依國有林地濫墾地補辦清理作業要點申請訂立租地契約遭否准時，可提起行政爭訟以為救濟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-023', '113-2301', 23, 'single_choice', '有關行政之敘述，下列何者錯誤？', '行政不同於司法，具有主動性，行政機關得本於職權依法排除並裁罰人民之違章行為', '行政具有手段多樣性，除法規另有規定外，享有法律形式與行為形式之選擇自由', '行政首重層級指揮體系，任何下級機關事務之執行，皆應受上級機關之合法性及合目的性監督', '行政雖具有個案性，但並不排除得依法律授權訂定法規命令及本於職權訂定行政規則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-2301-024', '113-2301', 24, 'single_choice', '依司法實務見解，關於法律保留原則，下列敘述何者錯誤？', '行政機關限制人民基本權利，單有組織法上之依據，並不足以符合法律保留原則之要求', '地方自治團體在自治事項範圍內，原則上得以自治條例限制居民之基本權利', '行政機關訂定行政規則，須有法律之授權', '法律授權行政機關訂定法規命令，若無轉委任之授權，行政機關不得再委由其所屬機關訂定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-025', '113-2301', 25, 'single_choice', '行政機關依其自行訂定的裁量基準作成裁罰處分，受理訴願機關或行政法院對於該裁罰處分之審查， 下列敘述何者正確？', '基於行政規則之間接對外效力，受理訴願機關或行政法院應受裁罰基準之拘束', '裁量基準為行政規則，具內部拘束力，原處分符合裁量基準即無違法或不當可言', '原處分機關依裁量基準作成之裁罰處分，如違反比例原則，受理訴願機關或行政法院仍得予以撤銷', '裁量基準為法規命令，如侵害人民權利，受理訴願機關或行政法院應聲請法規範憲法審查', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-026', '113-2301', 26, 'single_choice', '有關設置中央行政機關之權限，下列敘述何者錯誤？', '行政院經行政院會議及立法院之決議，得增設、裁併各部各委員會，或其他所屬機關', '四級機關之組織得以行政命令定之', '行政院為因應突發或新興之重大事務，得設臨時性之機關', '行政機關內部單位之分工職掌，得以處務規程或辦事細則定之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-027', '113-2301', 27, 'single_choice', '關於行政機關管轄權之敘述，依法律規定及司法實務見解，下列何者錯誤？', '管轄權非依法律或依法律授權所訂定之法規命令，不得設定或變更', '管轄權移轉未為公告，並不影響其效力', '地方政府於必要之情形下，不排除得依法規將自治事項委託由中央行政機關執行之', '授權行政機關得為管轄權移轉之法規，原則上應與設定該機關管轄權之法規相同位階', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-028', '113-2301', 28, 'single_choice', '依現行規定，關於鄉自治條例之敘述，下列何者正確？', '就違反地方自治事項之行政業務者，得規定處以最高新臺幣20 萬元以下之罰鍰或其他種類之行政罰', '規定處以其他種類行政罰之鄉自治條例，不以於一定期限內限制或禁止為一定行為之不利處分為限', '規定有罰則之鄉自治條例，經鄉民代表會議決後，應報中央各該主管機關核定後發布', '鄉自治條例經監督機關函告無效時，鄉依法定程序用盡審級救濟後受不利確定終局裁判者，得聲請 憲法法庭為違憲宣告之判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-029', '113-2301', 29, 'single_choice', '依現行法規及司法院解釋意旨，關於公務（人）員之敘述，下列何者正確？', '現行與公務員有關之法規，凡使用公務人員名稱者，除常任文官外，亦可適用於武職人員', '凡依法令受有俸給之文武職公務員，均為公務人員保障法之適用對象而受其規範', '公務員之任命程序與其職務有必然之關聯性，凡經總統提名，立法院同意任命者，其職務性質即為 相同', '直轄市長、縣（市）長、鄉（鎮、市）長亦適用公務員服務法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-030', '113-2301', 30, 'single_choice', '關於公務員懲戒制度，下列敘述何者正確？', '公務員有懲戒事由，得逕由其服務機關之首長移送懲戒法庭審理', '公務員懲戒程序以書面審理為原則', '公務員懲戒事件採一審終結，並無上訴制度', '政務人員與地方民選首長得受懲戒處分之種類相同', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-031', '113-2301', 31, 'single_choice', '下列何種爭議事件，不適用公務人員保障法之救濟程序？', '行政機關依事務管理規則僱用之工友遭檢察官起訴而被停職，於無罪判決確定後，請求補發薪資遭 拒絕', '公立學校兼任行政職之教師請求增加主管加給金額遭拒絕', '公務人員因執行職務發生意外，申請受傷慰問金遭拒絕', '公務人員依法執行職務涉訟，向服務機關申請為其延聘律師遭拒絕', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-2301-032', '113-2301', 32, 'single_choice', '下列何者非屬行政機關訂定之法規？', '職權命令', '委辦規則', '職務命令', '行政規則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-033', '113-2301', 33, 'single_choice', 'A 公司獲B 市政府經濟發展局（下稱經發局）核定補助新臺幣200 萬元，限定用於產品創新研發（但 附加僅限定用於產品創新研發之附款）。A 公司獲補助後將補助款挪作他用，經發局欲命A 公司返還 補助款。依司法實務見解，下列敘述何者正確？', '經發局未廢棄該補助處分前，該補助處分仍有存續力，該金錢給與仍有法律上原因', '為使該補助處分溯及既往失其效力，經發局應撤銷該補助處分', 'A 公司受領補助逾5 年，經發局即不得再為請求', '經發局廢棄該補助處分後得作成行政處分限期命A 公司返還補助款，縱使A 公司提起訴願，仍得 移送行政執行', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-034', '113-2301', 34, 'single_choice', '下列何者非屬行政程序法所規定行政處分之附款？', '主管機關核准甲於人行道上擺攤，但要求甲於收攤時應清理周邊垃圾', '主管機關核定甲留學獎金資格時，一併要求甲應於1 年內出國，否則喪失資格', '主管機關核給公務員甲出國進修津貼，要求甲回國後應繳交特定領域相關之研究報告', '主管機關核准甲之遊行申請，但於其申請範圍內限制遊行路線', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-035', '113-2301', 35, 'single_choice', '依法規及司法院解釋意旨，關於行政契約，下列敘述何者正確？', '行政契約之締結，應以書面為之，所謂書面係指雙方的意思須共同記載於同一份文書', '限制人民權利之契約內容，必須符合法律保留原則', '甲與機關A 締結行政契約後，若該行政契約之內容對公益造成重大危害，A 得不經甲之同意，於必 要範圍內調整契約內容', '機關A 作成行政處分，依法應經機關B 同意，若A 欲締結行政契約代替行政處分之作成，則此時 A 無須經B 之同意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-036', '113-2301', 36, 'single_choice', '依司法實務見解，下列何者非屬行政契約？', '衛生福利部中央健康保險署與特約醫院約定提供被保險人醫療服務之契約', '某國立醫學院學生與主管機關協議，學生領取公費補助，畢業後則願接受分發至公立衛生醫療機構 服務', '地方政府將其所設立之實驗小學委託民間經營所簽訂之委託經營契約', '台灣電力公司與民間水力發電業者所簽訂之購售電契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-037', '113-2301', 37, 'single_choice', '依司法實務見解，下列何者有行政罰法之適用？', '主管機關命違法採取土石之甲回復土地原狀', '主管機關限制欠稅之營利事業負責人乙出境', '主管機關命逾期不自行拆除違章建築之丙繳納新臺幣100 萬元代履行費用', '主管機關通知借用他人名義投標之廠商丁，將刊登政府採購公報停權3 年', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-038', '113-2301', 38, 'single_choice', '關於行政罰法第14 條所定之共同違反行政法上義務行為，下列敘述何者正確？', '共同實施違法行為之情況包含共同行為人之直接故意、間接故意及過失參與之情況', '對於共同行為人分別處罰之，並依個別行為情節之輕重審酌其罰鍰之金額', '因身分關係成立違反行政法上義務行為時，共同行為人中無該身分者，減輕或免除處罰', '對於共同行為人之處罰，罰鍰合計之總額不得逾法定罰鍰額之上限', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-039', '113-2301', 39, 'single_choice', '甲公司僱用乙負責機器設備檢查及維護工作，因乙施作不慎引發火警，造成空氣污染，主管機關乃對 甲公司裁處新臺幣6 萬元罰鍰。甲公司主張係乙施作不慎引發火警，非其故意過失導致空氣污染，提 起訴願。訴願機關應為下列何項判定？', '行政罰不以故意、過失為要件，甲公司仍應受罰', '行政罰以故意過失為要件，甲公司並無故意過失，不得對之裁處罰鍰', '行政罰以故意過失為要件，乙之故意過失，視為甲公司之故意過失，甲公司仍應受罰', '行政罰以故意過失為要件，乙之故意過失，推定甲公司有故意過失，甲公司仍應受罰', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-2301-040', '113-2301', 40, 'single_choice', '關於公物，下列敘述何者錯誤？', '未經徵收之既成道路雖為私有，但仍屬公物', '公物一律不得為設定目的外之使用', '行政機關設定某物為公物的行為，性質上為行政處分', '除了由行政機關主動設定，公物亦得於符合事實上一定要件而成立', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-2301-041', '113-2301', 41, 'single_choice', '下列何者非屬行政事實行為？', '行政機關以暴雨即將來襲為由，依法要求在河邊露營之民眾立即撤離', '行政機關依法對某批已核定之低收入戶實際發放補貼金', '行政機關出於錯誤認知，向某尋求諮商之市民提供不正確資訊', '行政機關依法對某鼓吹極端言論之遊行錄影蒐證', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-2301-042', '113-2301', 42, 'single_choice', '下列何者非屬行政執行法上之直接強制措施？', '命廠商停止營業未果後，主管機關之執法公務員逕自斷絕營業場所之水電', '命建築物所有人自行拆除違章建築未果後，市政府拆除大隊強制拆除違章建築', '消防隊基於救火需要，緊急將合法停放於路邊停車格之汽車拖離現場', '主管機關裁處沒入乙之汽車，乙拒絕交付該車，經主管機關查獲該車停放路邊，強制將該車移至保 管處所', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-2301-043', '113-2301', 43, 'single_choice', '甲市政府工務局以A 函通知乙所有之某房屋為違建，請乙於文到後1 個月內補辦執照，逾期依違章 建築處理辦法辦理。乙逾期未補辦執照，工務局以B 函通知乙應限期自行執行拆除，逾期將依行政執 行法強制執行。乙逾期未自行拆除，工務局遂以C 函通知乙，拆除大隊「將於X 年X 月X 日前往拆 除，事先請自行遷移室內一切存放物品，未遷移者，視同廢棄物」。執行完畢後，工務局以D 函通知 乙繳納新臺幣200 萬元拆除費用。依司法實務見解及相關法理，下列何者非屬行政處分？', 'A 函', 'B 函', 'C 函', 'D 函', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-2301-044', '113-2301', 44, 'single_choice', '下列何者非屬適用或準用行政執行法之執行行為？', '甲公務員受懲戒法庭判決新臺幣90 萬元罰款確定後，因逾期未繳納，而遭到拘提', '乙喝酒駕車，經員警酒測，其酒測值已達不能安全駕駛之程度，遭主管機關當場吊扣駕照', '丙因滯欠稅款，經查其財產不足清償債務，卻生活奢華，被禁止進入特定之高消費場所消費', '丁消防人員強行破壞並進入火災處所周邊之建築物，以有效撲滅火源，搶救受困民眾', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-2301-045', '113-2301', 45, 'single_choice', '下列何者非屬行政程序法所規定應自行迴避之人？', '公務員處理其配偶申請之建築案件', '公務員處理其前配偶申請之補助案件', '公務員處理其任職大學教授時指導之博士生所提出之申請案件', '公務員處理其擔任律師時曾代理之案件', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-2301-046', '113-2301', 46, 'single_choice', '主管機關A 對甲公司為停止營業1 年之處分（下稱原處分），6 個月後甲公司以事實或法律有變更為 由，依行政程序法第128 條向A 申請廢棄原處分，A 函覆甲。該函覆依其記載內容，下列敘述何者 錯誤？', '若僅重申原處分內容，其法律性質為重覆處置，甲不得對之提起行政爭訟', '若表示甲之申請不合法而駁回之，甲得對之提起行政爭訟', '若表示甲之申請符合法定要件，惟原處分為正當而駁回之，甲得對之提起行政爭訟', '若表示甲之申請有理由而廢止原處分，法律上利害關係人乙若不服，得提起行政爭訟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-2301-047', '113-2301', 47, 'single_choice', '關於政府資訊公開之敘述，下列何者正確？', '刑事判決確定且再審期間經過後，申請閱覽訴訟卷宗，應適用政府資訊公開法相關規定', '人民申請閱覽業經歸檔管理之檔案，行政機關應適用政府資訊公開法之規定拒絕其申請', '依政府資訊公開法應限制公開或不予提供之政府資訊，若因情事變更已無限制公開或拒絕提供之必 要時，政府機關應一律主動公開', '政府資訊中如部分含有限制公開或不予提供之事項，就該其他部分之資訊，仍不得公開或提供之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-2301-048', '113-2301', 48, 'single_choice', '下列何種行為不相當於訴願之決定？', '公務人員保障暨培訓委員會之復審決定', '政府採購申訴審議委員會審議判斷', '犯罪被害人補償覆審會之覆議決定', '律師懲戒覆審委員會之覆審決定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-2301-049', '113-2301', 49, 'single_choice', '關於行政訴訟暫時權利保護制度之敘述，下列何者錯誤？', '當事人不服罰鍰處分，提起撤銷訴訟，應適用停止執行程序', '當事人依法申請行政機關許可遭否准，提起課予義務訴訟，應適用假處分程序', '當事人請求行政機關返還已繳納之罰鍰，提起給付訴訟，應適用假處分程序', '當事人提起確認行政處分無效訴訟，應適用假處分程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-2301-050', '113-2301', 50, 'single_choice', '甲與A 市政府簽訂契約，因履約紛爭以A 市政府為被告，向臺北地方法院（下稱臺北地院）提起民 事訴訟，但臺北地院認為本案涉及行政契約之履約爭議，性質上為公法事件，應由行政法院審理，下 列敘述何者錯誤？', '臺北地院應將本案以裁定移送管轄之行政法院審理', '若受移送之行政法院亦認為對本案無審判權，應裁定停止審理，並聲請司法院解釋', '若當事人對移送裁定不服提起救濟，最高法院認民事法院就本案無審判權，受移送之行政法院即應 受理本案', '若受移送之行政法院對該移送裁定不爭執而為本案審理並為裁判，上級審之行政法院不得以行政法 院無審判權為由而撤銷或廢棄裁判', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-2301-051', '113-2301', 51, 'single_choice', '依行政訴訟法規定，關於收容聲請事件之敘述，下列何者錯誤？', '依臺灣地區與大陸地區人民關係條例提起之收容異議事件，屬收容聲請事件', '收容聲請事件，以受收容人所在地之地方行政法院為第一審管轄法院', '行政法院得以有聲音及影像相互傳送之科技設備審理收容聲請事件', '對於收容處分不服者，除得依收容異議程序救濟，亦得提起撤銷訴訟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-2301-052', '113-2301', 52, 'single_choice', '甲有土地一筆遭到徵收，惟土地徵收機關違反土地法規定，未於公告期滿15 日內給付徵收補償款。 甲若欲主張徵收處分失其效力而提起行政訴訟時，依司法實務見解，下列敘述何者正確？', '甲應經訴願程序後提起撤銷訴訟', '甲應提起確認行政處分違法訴訟', '甲應提起確認行政處分無效訴訟', '甲應提起確認徵收法律關係不存在訴訟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-2301-053', '113-2301', 53, 'single_choice', '下列何種起訴不合法之情形，行政法院於裁定駁回前應先定期命補正？', '訴訟事件不屬行政訴訟審判之權限者', '當事人就已起訴之事件，於訴訟繫屬中更行起訴者', '訴訟事件不屬受訴行政法院管轄而不能請求指定管轄，亦不能為移送訴訟之裁定者', '由訴訟代理人起訴，而其代理權有欠缺者', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-2301-054', '113-2301', 54, 'single_choice', '關於國家賠償責任，下列敘述何者正確？', '欲成立怠於執行職務國家賠償請求權，須法律明文規定，人民對於該項職務之執行擁有請求權', '若行政機關對於是否執行職務有裁量權時，原則上不因該職務之未執行而成立怠於執行職務國家賠 償責任，除非裁量空間已收縮至零', '公共設施委託民間團體或個人管理時，因管理欠缺導致人民死亡時，由受託之私人負民法上的賠償 責任，不成立國家賠償責任', '公共設施瑕疵國家賠償責任之成立，需主管機關在設置上或管理上有故意或重大過失方可', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-2301-055', '113-2301', 55, 'single_choice', '有關國家賠償義務機關之敘述，下列何者錯誤？', '行政委託事件中，受託之私人團體執行職務侵害人民權利，由委託機關負國家賠償責任', '公共設施瑕疵所引起之國家賠償責任，一律由該設施管理機關承擔國家賠償責任', '賠償義務機關有爭議時，當事人得請求上級機關確定之。該上級機關逾20 日不為確定時，得以該 上級機關為賠償義務機關', '賠償義務機關被裁撤，且引發國家賠償責任之職務領域並未安排承接機關，則以賠償義務機關裁撤 前之上級機關為賠償義務機關', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-2301-056', '113-2301', 56, 'single_choice', '關於習慣國際法，下列敘述何者錯誤？', '習慣國際法必須經多國普遍且重複實踐，不能僅存於兩國之間', '一國自始持續反對他國之慣行，可以阻止習慣國際法之形成', '一國對他國行為的聲明、抗議、發布的新聞稿，都可能被當成是否對習慣國際法具有法之確信的證據', '習慣國際法也可能被成文化為條約之內容', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-2301-057', '113-2301', 57, 'single_choice', '日內瓦公約規定對非國際戰爭戰俘亦應提供最低程度待遇，在國際法上被認為具有習慣國際法之 性質。若甲國為日內瓦公約之締約國，乙國不是締約國，丙國曾是締約國但之後退出。下列敘述何者 錯誤？', '乙國對於非國際戰爭戰俘，有義務提供最低程度待遇', '丙國主張退出日內瓦公約後即欠缺法之確信，毋須對非國際戰爭戰俘提供最低程度待遇', '丙國退出日內瓦公約後，該公約對丙國無條約之拘束力', '日內瓦公約對乙國無條約之拘束力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-2301-058', '113-2301', 58, 'single_choice', '關於國際法上非國家政治實體，下列敘述何者錯誤？', '二戰後之託管地在完成獨立或與他國結合之前，得被歸類為非國家政治實體', '有效控制特定領土而被承認之交戰團體，得被歸類為非國家政治實體', '非國家政治實體之流亡政府，指對其領土喪失有效統治而迫遷他國的政府', '非國家政治實體之民族解放團體，在未完成獨立並獲承認前，不得參與聯合國或其專門機構舉行之 會議', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-2301-059', '113-2301', 59, 'single_choice', '關於國際法中之國家承認，下列敘述何者錯誤？', '對於交戰團體之承認，可能違反不干涉（預）原則', '國家承認亦得藉由默示方式為之', '對一國家之承認，不得附加任何條件', '既存國家無國際法上之義務承認新國家', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-2301-060', '113-2301', 60, 'single_choice', '關於國際組織，下列敘述何者錯誤？', '國際組織之權能，必須受其所由創設之法律文件規定之限制', '為了實現其設立之目的與宗旨，即使章程未明文規定，國際組織也可能擁有某些隱有的權能', '因維也納條約法公約之除外規定，國際組織無法成為締結條約之主體', '國際組織得自設行政法庭處理其與雇員間之勞資爭議，並依條約豁免駐在地法院之管轄', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-2301-061', '113-2301', 61, 'single_choice', '依二次大戰後之國際法原則，關於國家取得領土主權之方式，下列敘述何者錯誤？', '國家得以合意交換方式取得領土主權', '對於公海上因自然力形成之島嶼，國家得先占取得其領土主權', '國家得藉由人工方式改造領海外之專屬經濟海域中低潮高地為島嶼，從而取得其領土主權', '國家不得以合法行使武力之方式取得他國領土主權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-2301-062', '113-2301', 62, 'single_choice', '關於海域執法，下列敘述何者錯誤？', '除非條約另有約定，否則一國海巡船舶不得於公海對他國船舶之毒品運送行為進行登檢', 'B 國籍船舶與C 國籍船舶在A 國鄰接區內準備共同走私毒品至D 國，A 國對該二船不得行使管轄權', '發動緊追之政府船舶，如不在被緊追之外國船舶目視範圍內，即不得發動緊追', '用於航行之國際海峽沿海國，有權制定與執行該海峽分道航行之規則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-2301-063', '113-2301', 63, 'single_choice', '關於國家管轄之豁免，下列敘述何者錯誤？', '一國元首於他國出訪時為子女購物所生之消費糾紛，得主張豁免該國法院之管轄', '一國之國營銀行就出具之信用狀於他國所生之爭執，得主張豁免該國法院之管轄', '一國依科學合作條約於他國領海探勘之公務船舶所致之損害，得主張豁免該國法院之管轄', '一國卸任元首對其在任期間之職務行為，得主張豁免他國法院之管轄', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-2301-064', '113-2301', 64, 'single_choice', '個人向國際人權條約監督機構提起訴訟或申訴前，應「窮盡當地救濟」。設定該尋求國際人權機構救 濟條件之理由，下列敘述何者錯誤？', '尊重國際人權條約所載不干涉（預）原則條款', '允許被告國有機會修正錯誤或賠償損失', '內國程序訴訟效率較高且有利判決執行', '推定國家法體系正常運作以尊重管轄權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-2301-065', '113-2301', 65, 'single_choice', '依羅馬規約之規定，下列何者不屬於國際刑事法院行使管轄權之條件？', '聯合國認證之人道組織向檢察官提交情勢', '締約國向檢察官提交本國情勢', '聯合國安全理事會依憲章第七章決議向檢察官提交情勢', '國際刑事法院檢察官依職權主動發動偵查', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-2301-066', '113-2301', 66, 'single_choice', 'A 國為一複數法域國家，A 國人甲與我國人乙締結貨物買賣契約，約定關於契約之爭議適用A 國之B 州法，貨物交付地點為A 國之C 州。設甲在A 國之主要營業地為C 州，對於甲、乙之契約爭議，我 國法院應如何適用法律？', '適用我國法', '適用B 州法', '適用C 州法', '我國法、B 州法、C 州法任擇其一', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-2301-067', '113-2301', 67, 'single_choice', '甲、乙二人均具有我國之國籍。甲因在美國出生，亦具有美國籍，且定居在美國。乙因其母為德國人， 雖亦具有德國籍，然自幼與父母定居在我國。甲、乙二人成年後在臺北一見鍾情，在臺北登記結婚。 下列敘述何者正確？', '甲、乙均有國籍積極衝突，故應以其各自之住所地法決定其本國法', '甲、乙之國籍積極衝突為內外國籍之衝突，故應以我國法為其本國法', '關於結婚成立之實質要件，甲應依美國法，乙應依我國法', '甲、乙婚後，關於婚姻之效力應依其共同之本國法，亦即應依我國法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-2301-068', '113-2301', 68, 'single_choice', '甲為A 國人，住所設在B 國。甲死亡時，在我國遺有不動產，在B 國遺有動產。甲之繼承人就遺產 繼承涉訟於我國法院。依A 國國際私法規定，繼承依被繼承人死亡時之住所地法。依B 國國際私法 規定，動產之繼承，依被繼承人死亡時之住所地法；不動產之繼承，依不動產所在地法。我國法院應 以何國法為準據法？', '全部遺產之繼承，應以A 國法為準據法', '全部遺產之繼承，應以B 國法為準據法', '動產之繼承應以A 國法為準據法，不動產之繼承應以我國法為準據法', '動產之繼承應以B 國法為準據法，不動產之繼承應以我國法為準據法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-2301-069', '113-2301', 69, 'single_choice', '涉外民事法律適用法第20 條第3 項規定「法律行為所生之債務中有足為該法律行為之特徵者，負擔 該債務之當事人行為時之住所地法，推定為關係最切之法律。」下列何種涉外債權契約，難以用此項 規定推定關係最切之法律？', '贈與契約', '保證契約', '承攬契約', '互易契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-2301-070', '113-2301', 70, 'single_choice', 'A 國人甲欲收養我國人乙，關於收養之成立要件問題，我國法院應如何適用法律？', '選擇適用A 國法或我國法', '累積適用A 國法和我國法', '並行適用A 國法和我國法', '適用關係最切之我國法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-2301-071', '113-2301', 71, 'single_choice', 'A 國人甲將美金100 萬元貸予B 國人乙，約定借貸契約之準據法為A 國法，並以住於B 國之B 國人 丙為保證人。其後甲將其對乙所有之借款債權賣給C 國人丁，約定此買賣契約之準據法為C 國法， 並為債權移轉。關於此債權讓與相關之準據法，下列敘述何者正確？', '債權讓與對於債務人乙之效力，依A 國法', '債權讓與對於債務人乙之效力，依B 國法', '債權讓與對於保證人丙之效力，依C 國法', '債權讓與對於保證人丙之效力，依關係最切國之法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-2301-072', '113-2301', 72, 'single_choice', '關於涉外物權事件之法律適用，下列敘述何者錯誤？', '物之所在地如有變更，其物權之取得、喪失或變更，依其原因事實完成時物之所在地法', '物權之法律行為，其方式依該行為所應適用之法律，但依行為地法所定之方式者，亦為有效', '動產於託運期間，其物權之取得、設定、喪失或變更，依其目的地法', '自外國輸入我國領域之動產，於輸入前依其所在地法成立之物權，其效力依我國法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-2301-073', '113-2301', 73, 'single_choice', '我國女子甲到美國工作，結識日本男子乙，二人於加拿大結婚，於美國生下一子丙。關於丙之身分可 得適用之法律，不包括下列何者？', '我國法', '日本法', '加拿大法', '美國法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-2301-074', '113-2301', 74, 'single_choice', '我國人甲男與A 國人乙女，生有一子丙。甲死亡時遺有在我國之不動產B 屋及在A 國之不動產C 屋。 關於甲之遺產繼承，下列敘述何者正確？', '關於B 屋之繼承，應適用我國法；關於C 屋之繼承，應適用A 國法', '關於C 屋之繼承，依A 國國際私法應適用A 國法時，我國法院應適用A 國法', '乙對甲之遺產是否有繼承權，應先依我國涉外民事法律適用法判斷甲、乙婚姻是否有效', '丙對甲之遺產是否有繼承權，應定性為父母與子女間之法律關係，依我國法而定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-2301-075', '113-2301', 75, 'single_choice', '已經訴訟繫屬於外國法院之事件，若該事件之原告又於我國法院就同一事件對被告提起訴訟。下列敘 述何者正確？', '法院得在外國法院判決確定前，足認該外國判決有被承認之可能，且無重大應訴不便，以裁定停止 訴訟程序', '我國法院對後繫屬之訴訟無國際管轄權，應裁定駁回之', '因不得重複審理，我國法院應裁定駁回於我國重複起訴之事件', '此為國際訴訟競合，我國法院訴訟繫屬因外國法院判決而自動消滅', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-3301-001', '113-3301', 1, 'single_choice', '下列關於消滅時效規定之敘述，何者錯誤？', '時效因請求而中斷者，於請求後六個月內不起訴，視為不中斷', '夫對於妻或妻對於夫之權利，於婚姻關係消滅後一年內，其時效不完成', '以不行為為目的之請求權，消滅時效自為行為時起算', '請求權罹於時效，債務人仍為履行之給付者，得依不當得利請求返還', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-3301-002', '113-3301', 2, 'single_choice', '乙為甲之意定代理人，下列敘述，何者正確？', '意定代理與委任不可分', '乙以甲之名義與丙訂立買賣契約，使甲間接與丙發生買賣之效力', '乙以自己名義為法律行為，雖未以本人甲之名義為之，但有為本人之意思，此項意思為相對人明知 或可得而知者，稱為隱名代理', '乙以自己名義為法律行為，雖未以本人甲之名義為之，但有為本人之意思，此項意思為相對人明知 者，亦構成直接代理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-3301-003', '113-3301', 3, 'single_choice', '甲受輔助宣告，未經輔助人同意，將其所有之A 屋出賣並移轉所有權登記於乙。嗣後，乙因財務困 窘，未能依約給付價金。下列敘述，何者錯誤？', '買賣契約效力未定', '不動產所有權移轉行為效力未定', '甲依所有物返還請求權，向乙主張返還A 屋，應經輔助人同意', '甲對乙提起民事訴訟，應經輔助人同意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-3301-004', '113-3301', 4, 'single_choice', '甲將A 屋出租於乙，乙與其配偶丙及子女丁住於A 屋。下列敘述，何者錯誤？', '承租人乙應以善良管理人之注意義務保管A 屋，如因承租人乙之配偶丙應負責任之事由，致A 屋 毀損時，乙應負擔損害賠償責任', '因乙之輕過失導致A 屋失火而毀損時，甲得對乙主張侵害所有權之損害賠償責任', '乙依約定之方法對A 屋為使用收益致有毀損，無須對甲負損害賠償責任', '租賃關係存續中，租賃物如有修繕之必要，應由出租人負責者，承租人應即通知出租人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-3301-005', '113-3301', 5, 'single_choice', '下列關於雙方或自己代理禁止之敘述，何者正確？', '禁止自己代理之規定，僅適用於意定代理，不及於法定代理', '甲父贈與A 地於二歲之子乙，甲父得代理其子乙與自己訂立有效之贈與契約', '甲贈與秘書乙A 地一筆，乙代理甲辦理移轉A 地所有權移轉登記於自己名下，該移轉登記效力未定', '甲未經出賣人乙與買受人丙之許諾，代理雙方訂立A 地買賣契約，該買賣契約無效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-3301-006', '113-3301', 6, 'single_choice', '下列關於法人責任之敘述，何者錯誤？', '法人對於其董事因執行職務所加於他人之損害，僅由法人單獨負賠償責任', '董事代表法人與他人訂立之契約，由法人單獨負擔履約與債務不履行之責任', '法人之受僱人因執行職務，不法侵害他人之權利者，原則上由法人與該行為人連帶負損害賠償責任', '法人之代理人，關於債之履行有故意或過失時，法人應與自己之故意或過失負同一責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-3301-007', '113-3301', 7, 'single_choice', '甲畫家受監護宣告，在心智清醒時，將代理權授與乙，讓乙代理銷售甲之畫作。假設乙無過失不知甲 受監護宣告，以甲之代理人名義與丙訂立買賣契約，並以移轉所有權之意思將甲之畫作交付於善意無 過失之丙。詎料甲之監護人拒絕承認乙之代理行為，下列敘述，何者正確？', '丙是善意無過失，故可以善意取得甲之畫作', '甲在心智清醒時授與乙代理權，該授權有效', '乙縱使無過失，仍然須對丙負損害賠償責任', '乙因非故意，所以無須對丙負損害賠償責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-008', '113-3301', 8, 'single_choice', '甲為避免債權人之強制執行，遂將名下之A 地與乙通謀虛偽訂立買賣契約，並辦理所有權移轉登記 於乙名下。乙去世後，由其子丙繼承A 地，並辦理登記完畢。嗣後丙將該地出租於丁，並設定普通抵 押權於戊。丙、丁及戊皆善意不知上述通謀虛偽情事。下列何人得主張民法第759 條之1 登記公信力 之保護？', '僅丁一人', '僅戊一人', '丁及戊', '丙、丁及戊', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-009', '113-3301', 9, 'single_choice', '乙自稱其為甲之代理人，將甲之高級音響出售於丙，於收受約定價金後，交付該音響。下列敘述，何 者錯誤？', '乙為無權代理，其以甲之名義所為之法律行為效力未定', '丙得定相當期限，催告甲確答是否承認', '丙得善意取得該音響之所有權', '僅於丙不知乙無代理權時，丙得於甲承認前撤回其法律行為', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-010', '113-3301', 10, 'single_choice', '50 歲之某甲於民國（下同）99 年12 月1 日出國自助旅行，未如期返家，其配偶乙到處打聽遍尋不 著，至100 年1 月7 日仍音訊全無，乙於107 年6 月1 日向法院聲請對甲為死亡宣告，法院於107 年 12 月1 日對甲為死亡宣告，該裁定於107 年12 月21 日確定，甲被推定死亡之時間為何？', '107 年1 月1 日', '107 年1 月7 日', '107 年12 月1 日', '107 年12 月21 日', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-011', '113-3301', 11, 'single_choice', '下列何種契約，其標的雖陷於自始客觀不能，仍為有效？', '特定物之買賣契約', '債權買賣契約', '不動產租賃契約', '動產贈與契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-012', '113-3301', 12, 'single_choice', '甫上高中16 歲之甲，為上學之便，逕以父母給予之壓歲錢向自行車行老闆乙購買新臺幣8,000 元之 自行車一台。雙方達成合意後，乙為製作售後服務卡，並登錄消費者資料時，始發現甲原來尚未成年。 下列敘述，何者正確？', '甲未得法定代理人同意，故甲、乙間之買賣契約無效', '甲係以允許處分之財產購買自行車，故甲、乙間之買賣契約有效', '甲購買自行車上學，非屬依其年齡及身分之日常生活所必需，故甲、乙間之買賣契約無效', '若甲之法定代理人知悉後，認以自行車上學過於危險，為保護未成年人之利益，得撤銷甲、乙間之 買賣契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-013', '113-3301', 13, 'single_choice', '甲向乙表示願以新臺幣（下同）50 萬元購買其所有之A 車，並支付乙10 萬元定金，但乙隔日卻後悔 不賣了。依民法規定，下列敘述，何者正確？', '因乙已收受定金，視為雙方買賣契約成立', '定金為不要物之從契約，雙方約定即可成立', '因乙之反悔不賣，甲得請求乙給付20 萬元', '乙僅須返還甲10 萬元，即可後悔不賣', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-014', '113-3301', 14, 'single_choice', '下列關於民法第425 條之1 租賃關係推定之敘述，何者錯誤？', '土地及其土地上之房屋不同屬於一人所有，而將土地所有權讓與他人時，推定在土地受讓人與房屋 所有權人間，有租賃關係存在', '該條規定於移轉之房屋為「未辦保存登記之違章建築」，亦有其適用', '該條規定之土地上之房屋，須有相當之價值', '該條規定，適用於其增訂前發生之事實', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-015', '113-3301', 15, 'single_choice', '甲居住於臺南市，向高雄市之乙購買乙所有之A 車，約定於5 月5 日交付，但乙因事未於當日依約 交付。嗣後發現A 車於5 月6 日毀於高雄市發生之火災。下列敘述，何者正確？', '火災為通常事變，甲不得請求損害賠償', '不可歸責於乙，乙依民法第225 條規定免除責任', '甲得依民法第226 條有關給付不能規定，請求損害賠償', '乙不負遲延給付之損害賠償責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-3301-016', '113-3301', 16, 'single_choice', '下列關於要約與要約引誘之敘述，何者錯誤？', '要約僅得向特定人為之，要約引誘，則得對不特定人為之', '甲建商在報上刊登廣告宣傳將在臺北車站附近推出新建案，此則廣告屬要約引誘', '設置自動販賣機陳列商品標價販售，係為要約', '要約引誘是一種意思通知', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-017', '113-3301', 17, 'single_choice', '甲委託乙依其身高及需求，設計製作一套工作桌椅。甲乙之契約屬於下列何種類型？', '委任契約', '買賣契約', '僱傭契約', '承攬契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-018', '113-3301', 18, 'single_choice', '甲將自己所有之A 牌機車贈與乙，乙表示同意。下列敘述，何者正確？', '贈與為單獨行為', '甲於贈與成立後，若事後反悔，在贈與物之權利未移轉前，原則上得撤銷甲與乙間之贈與', '甲與乙之贈與經公證後，在贈與物之權利未移轉前，甲得撤銷贈與', '贈與之物如有瑕疵，贈與人原則上應負擔瑕疵擔保責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-019', '113-3301', 19, 'single_choice', '甲為古畫修復師，承接乙博物館古畫修復工程。由於古畫修復需要特殊材料，因此，雙方約定，由甲 提供材料協助古畫修復，並於工作完成時給付報酬。下列敘述，何者錯誤？', '古畫修復師承接古畫修復工程，屬承攬契約', '甲縱使提供材料致古畫價值提升，依約乙仍保有其所有權', '由於甲以自己材料修復古畫，該材料已與古畫附合，且經甲之加工，致古畫價值倍增，則甲取得古 畫之所有權', '如甲乙間之修復契約不成立時，因甲提供材料修復古畫，該材料與古畫附合，故古畫可視為主物， 古畫所有權屬於乙', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-020', '113-3301', 20, 'single_choice', '甲男與乙女結婚，育有二子丙、丁，皆未成年。甲因車禍死亡，甲生前是家中唯一經濟來源，甲之父 母戊、己同住。甲還有從小感情就很好未婚同住但已有固定工作之妹妹庚。下列關於肇事者侵權責任 之敘述，何者錯誤？', '乙女對肇事者得請求精神慰撫金', '丙與丁得對肇事者請求扶養費用之賠償', '庚因甲之過世對肇事者請求精神慰撫金損害賠償', '戊、己得向肇事者請求餘命期間之扶養費損害賠償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-021', '113-3301', 21, 'single_choice', '甲乙丙丁四人與A 約定負連帶責任，向A 借用新臺幣（下同）500 萬元，其內部分擔比例為 2：2：5：1。嗣後，A 免除甲分擔部分之債務後，對乙之財產聲請強制執行並全部獲償。乙向其他連 帶債務人求償時，因丙破產毫無財產可為清償時，乙得向何人分別求償多少金額？', '對甲求償160 萬元、對丁求償80 萬元', '對甲求償100 萬元、對丁求償100 萬元', '對丁求償133 萬元（四捨五入）', '對丁求償50 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-022', '113-3301', 22, 'single_choice', '2024 年3 月1 日，甲於報紙上刊登一則廣告，表示在同年3 月10 日前能答出其所出之數學難題，將 給付新臺幣（下同）2 萬元報酬作為獎勵。乙、丙、丁先後在不同地方解出正確答案。乙最先完成解 答，但丙最先通知甲完成解答，甲檢視答案為正確後，立即匯出報酬於丙。下列敘述，何者正確？', '若甲於刊登廣告之翌日，未有人提出解答前，得無條件撤回廣告', '乙有報酬請求權，得向丙主張不當得利，請求交付所受領之2 萬元報酬', '乙、丙、丁得向甲請求平分報酬', '甲必須再對乙支付報酬，不得拒絕。惟甲得事後對丙主張不當得利，請求返還報酬', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-023', '113-3301', 23, 'single_choice', '甲向乙借款新臺幣10 萬元，丙與乙訂立保證契約，擔保該借款債務之履行。下列關於保證契約之敘 述，何者正確？', '甲對乙因借款契約所生之抗辯，丙不得主張之', '丙不得以甲對乙之債權主張抵銷', '若乙對甲起訴請求返還借款，其對丙基於保證契約所生之債權，發生中斷時效之效力', '縱丙拋棄先訴抗辯權，仍得於乙就甲之財產強制執行而無效果前，對於乙拒絕清償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-3301-024', '113-3301', 24, 'single_choice', '甲向乙購買乙使用2 年之A 手錶，該錶之表面有輕微刮傷，惟乙於締約時故意不告知甲，雖甲於締約 時已檢查看過，但於交付後始發現該瑕疵。下列敘述，何者正確？', '甲得對乙主張權利瑕疵擔保責任', '甲得請求乙另行交付無瑕疵之手錶', '如甲因重大過失未發現手錶瑕疵，甲僅得對乙行使契約解除權', '如甲因重大過失未發現手錶瑕疵，甲仍得對乙請求減少價金', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-3301-025', '113-3301', 25, 'single_choice', '甲向乙購買一批貨物，該貨物之貨款為新臺幣（下同）1 萬元，於清償期屆至後1 年，甲仍未清償。 下列敘述，何者錯誤？', '乙得請求依法定利率計算該貨款1 萬元之遲延利息。但約定利率較高者，仍從其約定利率', '若甲乙間無債權不得讓與之特約時，乙得將該1 萬元買賣價金請求權讓與於第三人丙。但非經乙或 丙通知甲，對於甲不生效力', '若甲乙間無債權不得讓與之特約，乙將該1 萬元買賣價金請求權讓與於第三人丙時，丙將乙所立之 讓與字據提示於甲者，對於甲即生效力', '若第三人丁與甲訂立契約承擔該1 萬元買賣價金債務，於契約成立時，該債務即由丁承擔', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true)
on conflict (question_id) do update set
  paper_id = excluded.paper_id,
  question_number = excluded.question_number,
  question_text = excluded.question_text,
  option_a = excluded.option_a,
  option_b = excluded.option_b,
  option_c = excluded.option_c,
  option_d = excluded.option_d,
  source_page_start = excluded.source_page_start,
  source_page_end = excluded.source_page_end,
  extraction_status = excluded.extraction_status,
  review_status = excluded.review_status,
  is_published = excluded.is_published,
  updated_at = now();

-- Question batch 2
insert into public.questions (
  question_id, paper_id, question_number, question_type, question_text,
  option_a, option_b, option_c, option_d, subject_primary, subject_secondary,
  chapter, topic_primary, topic_secondary, law_refs, tags, source_page_start,
  source_page_end, extraction_status, review_status, notes, is_published
) values
('113-3301-026', '113-3301', 26, 'single_choice', '甲向乙無息借款新臺幣（下同）500 萬元，並將其名下市值700 萬元之A 地，設定第一順位普通抵押 權於乙。嗣後，甲向丙無息借款600 萬元，遂就A 地設定第二順位普通抵押權於丙。乙死亡時，甲為 乙之唯一繼承人。下列敘述，何者正確？', '第一順位抵押權為甲之利益，仍為存續', 'A 地之所有權與第一順位抵押權均歸屬於甲，甲之A 地所有權因混同而消滅', '丙得受完全之清償', '丙從第二順位抵押權人，升進為第一順位抵押權人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-3301-027', '113-3301', 27, 'single_choice', '甲乃A 地所有人與A 地上之B 屋所有人，並登記為A 地所有人與B 屋所有人。B 屋左側有車庫。該 車庫獨立於B 屋，但可由B 屋直通車庫。甲於民國113 年間，僅以B 屋設定普通抵押權於乙，用以 擔保其對乙所負新臺幣（下同）5,000 萬元借款債務與因該筆借款所生之100 萬元利息債務。甲屆期 遲未清償5,000 萬元借款及100 萬元利息。下列何者不為乙之B 屋抵押權之效力所及？', 'A 地', 'B 屋之車庫', '100 萬元利息債務', '甲對乙所負之遲延利息債務', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-3301-028', '113-3301', 28, 'single_choice', '甲名下有一間公寓，該公寓之專有部分包括A 騎樓。詎該公寓所屬管理委員會乙未經甲之同意，擅自 將A 騎樓出租並交付於善意之丙，丙搭建衣物網架，供夜市擺攤使用。下列敘述，何者錯誤？', '甲得依所有權妨害除去與所有物返還請求權，訴請丙拆除衣物網架並交還A 騎樓', '雖乙、丙間之租約有效，但甲得向丙請求返還相當於租金之不當得利', '對甲而言，丙占用A 騎樓乃善意之無權占有人', '甲得向乙請求返還其出租A 騎樓所收取租金之不當得利', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-3301-029', '113-3301', 29, 'single_choice', '甲、乙、丙、丁共有市價新臺幣（下同）300 萬元之A 地，應有部分均等，約定A 地由丙管理。嗣 後，丙對甲、乙、丁表示變為以行使地上權之意思而占有，復和平、公然、繼續占有A 地達20 年。 之後，甲因需錢孔急，各向乙、丁借款50 萬元，甲並就其應有部分設定同額之第一次序普通抵押權 （下同）於乙、第二次序抵押權於丁。乙死亡時，甲為乙之唯一繼承人。下列敘述，何者正確？', '乙之抵押權因混同而消滅，丁則遞升為第一次序抵押權人', '丙得請求登記為A 地之地上權人', '甲得僅以其應有部分已達半數為由，主張A 地由其管理', '甲應按其對於乙所負債務數額，由甲之應繼分內扣還', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-3301-030', '113-3301', 30, 'single_choice', '甲好意順道駕車載送其同事乙返家，途中不慎與對向由丙駕駛之車輛互撞。經鑑定結果，就此交通事 故之發生，甲之過失比例為30%、丙之過失比例為70%。因該事故而受傷住院治療月餘之乙，於請求 甲、丙賠償其因此所受損害時，下列敘述，何者錯誤？', '乙得對丙請求賠償全部損害', '乙得對甲請求賠償全部損害', '乙僅得對甲、丙分別請求賠償按其過失比例之損害', '乙請求丙賠償全部損害時，丙得主張乙應承擔甲之過失，故僅賠償乙所受損害之70%', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-3301-031', '113-3301', 31, 'single_choice', '甲、乙、丙、丁、戊公同共有A 車，並分別共有B 地與未辦保存登記之C 屋，應有部分均等。除契 約另有約定者外，下列敘述，何者錯誤？', '處分A 車共有物，得經甲、乙、丙三人同意行之', 'B 地設定農育權，得經甲、丙、丁三人同意行之', '改良B 地，得經丙、丁、戊三人同意行之', '簡易修繕C 屋，得由乙單獨為之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-3301-032', '113-3301', 32, 'single_choice', '甲為A 地所有人，乙為B 地所有人，並登記於土地登記簿，A 地與B 地相鄰。甲於A 地上建築C 屋， 因測量有誤，致C 屋有部分位於B 地之上。下列敘述，何者正確？', '若乙於C 屋建築時明知該屋越界，則乙於C 屋建成1 年後，請求甲拆除C 屋越界建築之部分，有 理由', '若乙知甲越界建築時即向甲提出異議，則法院不得斟酌公共利益與當事人利益，命甲免為全部或一 部之移除', '若乙於C 屋建成之時，方知甲越界建築且即時提出異議，則乙得請求甲拆除越界建築', '若甲故意越界建築，乙於C 屋建築時明知此事，但並未即向甲提出異議，則乙請求甲拆除C 屋越 界建築之部分，無理由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-3301-033', '113-3301', 33, 'single_choice', '甲名下有A 地及A 地上之B 屋，甲於民國113 年2 月僅以A 地設定典權於乙，詎B 屋於同年7 月因 豪雨土石流致全部滅失。下列敘述，何者正確？', '甲乙間原本推定之租賃關係，於B 屋滅失後歸於消滅', '甲乙間原本視為已有地上權之設定，於B 屋滅失後歸於消滅', 'B 屋因土石流而滅失後，乙之典權即歸於消滅', '甲乙間原本視為已有地上權之設定，於B 屋滅失後並未消滅', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-3301-034', '113-3301', 34, 'single_choice', '甲將其名下之A 地，設定普通地上權於乙建築房屋，約定每年地租新臺幣（下同）30 萬元，存續期 間20 年。乙於A 地上建築B 屋後，為週轉資金，將該地上權與B 屋同時設定普通抵押權於丙，均已 辦畢登記。丁擅自占用A 地與B 屋放置廢棄物，致抵押標的價值減少，乙屢次勸阻無效，擬請求排 除侵害，或拋棄其地上權。下列敘述，何者錯誤？', '丙得請求乙於所受利益之限度內，提出與減少價值相當之擔保', '乙拋棄其地上權，非經丙之同意，不得為之', '乙得向甲支付未到期之地租30 萬元後，拋棄其地上權', '乙得訴請丁清空廢棄物、遷出B 屋並交還A 地', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-3301-035', '113-3301', 35, 'single_choice', '甲乃A 汽車所有人，乙經營貨運行。甲請求乙答應出借新臺幣（下同）10 萬元於自己。乙告知：甲 應以A 車，作為該筆10 萬元借款債務之擔保，乙始可能出借10 萬元於甲。下列關於A 汽車之可能 擔保型態，何者錯誤？', '甲將A 汽車所有權讓與擔保於乙', '甲得以A 汽車設定抵押權於乙', '甲得以A 汽車設定留置權於乙', '甲得以A 汽車設定質權於乙', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-3301-036', '113-3301', 36, 'single_choice', '甲男與乙女結婚後，生子丙。丁男與戊女結婚後，生女庚。於甲過世，且丁、戊離婚之後，乙與丁再 婚。丙與庚成年後，他們是否可以結婚？', '不可以，因為丙與庚為旁系血親二親等之親屬', '不可以，因為丙與庚為旁系姻親二親等之親屬', '可以，因為丙與庚為旁系姻親二親等之親屬', '可以，因為丙與庚既不是血親也不是姻親', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-037', '113-3301', 37, 'single_choice', '甲男與乙女為夫妻，甲婚後與乙之姪女丙發生外遇，乙忿而與甲離婚，甲於離婚後與丙結婚，甲丙婚 姻效力為何？', '有效', '無效', '得撤銷', '效力未定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-038', '113-3301', 38, 'single_choice', '甲男、乙女婚後生下丙男、丁男。丙男成年後與戊女結婚，生下己男。在己八歲時，某日，丙男不幸 死亡，留下戊、己孤兒寡母，生活艱難。丁男經常予以關懷，遂與戊女日久生情，也與己男有良好互 動。丁男得否與戊女結婚？若戊同意，丁得否收養己？', '丁不得與戊結婚，亦不得收養己', '丁不得與戊結婚，但得收養己', '丁得與戊結婚，亦得收養己', '丁得與戊結婚，但不得收養己', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-039', '113-3301', 39, 'single_choice', '甲男乙女結婚後，未約定夫妻財產制。甲婚前有X 屋一棟，價值新臺幣（下同）1,500 萬元，但貸款 300 萬元。婚後，甲將該房屋出租，每月租金5 萬元，並以之償還貸款，五年後清償完畢。婚後甲又 以其營業所得1,000 萬元購買價值2,500 萬元之Y 屋，先向銀行貸款1,500 萬元。嗣後，甲將X 屋出 賣，得款1,500 萬元，並償還銀行貸款。甲乙離婚時，乙無任何財產。乙得向甲請求多少金額剩餘財 產分配？', '550 萬元', '600 萬元', '650 萬元', '700 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-040', '113-3301', 40, 'single_choice', '夫妻離婚時，關於擔任未成年子女親權人之規定，下列敘述，何者錯誤？', '夫妻為兩願離婚時，得協議何者擔任親權人，一方或雙方共同擔任均可', '夫妻於判決離婚時，不得協議何者擔任親權人，應由法院依子女最佳利益酌定之', '關於親權人之協議不利於子女時，法院得依職權為子女之利益改定之', '法院得依職權，為未擔任親權人之一方酌定其與未成年子女會面交往之方式及期間', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-041', '113-3301', 41, 'single_choice', '甲男與乙女結婚後，與甲之寡母同住並生有二女。乙自懷孕生子後即辭職在家照顧女兒，操持家務， 孝敬婆婆。婚後十年，甲有外遇，與丙女同居長達五年而不返家，丙為甲生下一子。下列敘述，何者 錯誤？', '乙得向甲請求分居五年期間之家庭生活費用', '甲為唯一有責者，但依其情形，仍有可能得向乙女提起裁判離婚之訴訟', '乙女得依民法第1052 條第1 項規定，以絕對裁判離婚事由向法院請求離婚', '甲乙依法為兩願離婚登記後，乙因無過失尚得向甲請求給付贍養費', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-042', '113-3301', 42, 'single_choice', '甲男與乙女結婚後，甲罹患重大不治之精神疾病。乙訴請法院裁判離婚獲准。嗣後，甲欲主張裁判離 婚後陷於生活困難，請求乙給付贍養費，是否有理由？', '甲罹患精神疾病，係因己方之事由導致裁判離婚，屬於有過失之一方，故甲請求乙給付贍養費無理由', '甲罹患精神疾病，並無過失，故甲請求乙給付贍養費有理由', '乙對於離婚事由並無可歸責之處，屬於無過失之一方，故甲請求乙給付贍養費無理由', '甲罹患精神病之過失，較諸乙主動請求離婚之過失為輕，故甲請求乙給付贍養費有理由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-043', '113-3301', 43, 'single_choice', '甲男與乙女為夫妻，育有5 歲之子丙。嗣後，甲乙離婚，約定由乙獨立擔任丙之親權人。下列敘述， 何者正確？', '甲對丙之親權未停止', '甲因未擔任丙之親權人，故得停止支付對丙之扶養費', '經甲同意時，乙得代理丙將丙出養於丁', '若甲反對，乙不得代理丙出賣丙之A 屋', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-3301-044', '113-3301', 44, 'single_choice', '60 歲之甲受輔助宣告，甲有配偶乙、子女丙。下列何種情形符合民法之規定？', '以遺囑指定乙之應繼分為三分之二，丙之應繼分為三分之一', '乙受監護宣告，甲擔任乙之監護人', '朋友丁作成代筆遺囑時，甲擔任遺囑見證人', '乙留有遺囑後死亡，甲擔任乙之遺囑執行人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-045', '113-3301', 45, 'single_choice', '甲中年喪妻，有乙丙丁三子。某日，甲無權代理乙，將乙之A 車出賣於善意之戊。隔日，甲因故死 亡。下列敘述，何者錯誤？', '甲之無權代理行為，因乙之繼承甲而有效', '乙得拒絕承認甲之無權代理行為', '戊在乙未承認或拒絕甲之無權代理行為前，得撤回之', '若甲之無權代理行為不生效力，乙丙丁因繼承甲而對戊，負損害賠償責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-046', '113-3301', 46, 'single_choice', '有關民法第1149 條規定之遺產酌給請求權，下列敘述，何者正確？', '遺產酌給權人之子女得因酌給權人之死亡，而繼承請求酌給權利', '受酌給人原則上應為不能維持生活而無謀生能力之人', '就遺產酌給之數額，僅得由法院酌給於權利人', '民法明定酌給之數額，不得侵害特留分', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-047', '113-3301', 47, 'single_choice', '甲有乙丙丁戊四子，民國111 年1 月1 日甲死亡後，乙隱匿甲遺產中之一幅名畫，且丙詐害債權人己 之權利而將甲之遺產毀損。假設甲之遺產不足清償己之全部債務，依民法規定，己就不足清償之部分， 不得從下列繼承人之固有財產中清償？', '丙與戊', '丁與戊', '乙與丁', '丙與丁', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-048', '113-3301', 48, 'single_choice', '甲得知妻乙懷孕，喜出望外，卻不幸執勤時因公殉職。甲之父丙因悲哀過度亦隨即病歿。丙遺有房屋 一棟，其配偶已死亡，其子女除甲外，尚有甲之姐丁。丁主張應由其單獨繼承丙之房屋，有無理由？', '有理由。因甲已死亡，應由丁繼承', '無理由。因胎兒有代位繼承權', '有理由。因丙死亡時，胎兒仍未出生', '無理由。因胎兒未出生前，應由乙繼承', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-049', '113-3301', 49, 'single_choice', '甲父母雙亡，有一子丙已成年。乙有一子丁，丁有一子戊已成年，長年住在國外。其後，甲與乙結婚， 並收養丁為養子，但戊並不知情。乙與丙感情不睦，某日二人激烈衝突，丙竟持刀殺乙既遂，而受刑 之宣告。丙服刑期間，甲丁因事故同時死亡。甲之遺產應由何人繼承？', '丙單獨繼承', '丁單獨繼承', '戊單獨繼承', '無人可繼承', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-050', '113-3301', 50, 'single_choice', '甲有乙丙丁三子，乙有一子戊。甲因乙分居而給與新臺幣（下同）150 萬元，因丙出國而給與150 萬 元，因丁結婚而給與150 萬元。乙先甲死亡。甲死亡時，留有300 萬元遺產。甲之遺產應如何分配？', '戊50 萬元、丙200 萬元、丁50 萬元', '戊100 萬元、丙100 萬元、丁100 萬元', '戊150 萬元、丙150 萬元、丁0 元', '戊200 萬元、丙50 萬元、丁50 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-051', '113-3301', 51, 'single_choice', '關於民事訴訟法與憲法之關係，下列敘述，何者錯誤？', '民事訴訟制度應避免突襲裁判，並確立當事人之程序主體地位', '法官迴避制度具有確保當事人公正程序請求權之意義', '三級三審制度係憲法上司法救濟請求權之要素，不容當事人處分或立法簡化', '法律安定性及個案正義，均為民事訴訟法建構制度時之基本信念，但因二者偶而會發生衝突，故有 權衡之必要', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-3301-052', '113-3301', 52, 'single_choice', '甲居住於臺中，乙居住於臺北，甲向臺灣臺中地方法院（下稱臺中地院）起訴，請求被告乙返還借款。 甲乙間之借貸契約並無合意管轄法院之約款。乙於接獲法院通知後，前往臺中地院開庭，並提出清償 抗辯。下列敘述，何者錯誤？', '臺中地院因被告乙為本案言詞辯論，已取得管轄權', '乙於辯論終結前，聲請臺中地院移轉管轄至臺灣臺北地方法院（下稱臺北地院），臺中地院於尚未 辯論終結前，應移轉至臺北地院', '如經臺中地院判決後，敗訴之當事人提起上訴，第二審法院不得以管轄錯誤為理由，廢棄原判決', '如經臺中地院判決後，當事人均未上訴而確定時，敗訴之一造不得以本件確定判決無管轄權為由， 提起再審之訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-3301-053', '113-3301', 53, 'single_choice', '關於普通法院之審判權，下列敘述，何者錯誤？', '當事人未於事實審爭執普通法院欠缺審判權者，仍得據以為上訴第三審法院之理由', '普通法院就行政法院移送之訴訟認無審判權者，如當事人合意願由普通法院審判，即應審判之', '普通法院認受理之事件為行政爭訟事件而無審判權者，應依職權將訴訟移送至該管行政法院', '普通法院就私法關係所生之爭議，有審判權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-3301-054', '113-3301', 54, 'single_choice', '原告甲列乙、丙、丁、戊等四人為被告，起訴聲明求為判決乙應將A 地中A1 部分、丙應將A2 部分、 丁應將A3 部分、戊應將A4 部分分別返還予甲，主張事實及理由略為：A 地為甲所有，其中A1 部分 遭乙、A2 部分遭丙、A3 部分遭丁、A4 部分遭戊分別無權占有，均拒不返還，為此，本於所有物返還 請求權起訴等旨。此訴訟經第一審判決甲全部勝訴，下列敘述，何者正確？', '乙提起上訴，主張：甲曾同意將A 地之A1、A2、A3、A4 分別出租予乙、丙、丁、戊等四人，故有 使用土地之正當權利等語。受理乙上訴之上級審法院應將未曾提起上訴之丙、丁及戊等人均列為上 訴人進行本案審理', '乙提起上訴後，丙受原判決之送達而逾上訴期間未表明上訴時，其尚得向受理乙上訴之第二審法院 追加為上訴人（當事人）', '乙及丙均提起上訴，丙於上訴審程序承認甲就A 地有所有權之事實後，乙不得再就此事實加以爭執', '乙及丙均提起上訴，各主張自己基於租賃權使用系爭地，為此乙聲請訊問證人X，法院就訊問X 之 結果，經兩造辯論後，得作為認定丙有租賃權之基礎', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-3301-055', '113-3301', 55, 'single_choice', '甲為英屬開曼群島之外國法人，主張乙侵害其商標權，於臺灣臺北地方法院提起侵權行為損害賠償訴 訟，請求乙賠償新臺幣500 萬元。於第一次言詞辯論期日，乙抗辯甲應提供訴訟費用之擔保。下列敘 述，何者錯誤？', '法院應先調查甲在我國境內有無事務所及營業所，或有無足以賠償訴訟費用之資產', '於法院尚未對訴訟費用擔保為裁定或准訴訟費用擔保而原告未提供擔保前，被告得拒絕本案辯論', '法院定擔保額時，應將第一、二、三審之裁判費及各審之律師費計入', '法院命供訴訟費用擔保之裁定，得為抗告', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-3301-056', '113-3301', 56, 'single_choice', '關於一造辯論判決，下列敘述，何者正確？', '得聲請一造辯論而為判決者，以原告為限，被告不得為之', '法院不得依職權由一造辯論而為判決', '當事人有正當理由不到場時，法院不得依他造聲請由其一造辯論而為判決', '於訴訟標的須合一確定之共同訴訟，言詞辯論期日共同訴訟中一人到場，他造全體不到場時，雖經 到場者聲請，法院不得為一造辯論之判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-3301-057', '113-3301', 57, 'single_choice', '甲、乙、丙三人共有A 地，甲列乙、丙為被告，起訴請求法院裁判分割該地。下列敘述，何者錯誤？', '法院裁判准分割A 地時，不受原告訴之聲明就如何分割A 地所表明之分割方法所拘束，但此項表 明可資以促使本案審理集中化', '在乙抗辯共有人間已有分割之協議時，甲得追加請求判決命乙及丙履行該協議', '如乙之應有部分於訴訟繫屬前已讓與丁，則甲之起訴欠缺被告適格', '如乙之應有部分於其收受甲之起訴狀後讓與丙，則自丙受讓之時起，乙喪失被告適格', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-3301-058', '113-3301', 58, 'single_choice', '下列所示證人之證言或提出之書狀，何者屬於法院不得逕採為認定事實之證據？', '以元首為證人，在其所在地經命其具結後詢問所錄取之證言', '經兩造同意，證人於法院外以書狀為陳述並將具結結文附於書狀，經公證人認證後，向法院提出', '法院通知證人到庭作證，證人因故無法出席，獨自前往公證人面前作成陳述書狀及具結結文向法院 提出', '法院於命證人具結後，運用聲音及影像相互傳送之科技設備直接訊問證人所錄取之證言', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-3301-059', '113-3301', 59, 'single_choice', '甲列乙為被告，訴請給付租賃A 屋之租金新臺幣（下同）100 萬元，於訴狀送達後，甲擬追加請求法 院判命乙給付買賣B 貨物之價金200 萬元。下列敘述，何者正確？', '如甲於第一審程序中追加，兩項請求之基礎事實同一，法院應准許追加', '如甲於第一審程序中追加，兩項請求之基礎事實不同一，乙不同意且無擬制同意存在，有礙訴訟終 結時，法院應不許追加', '如甲係於第二審程序中追加，兩項請求之基礎事實同一，無須乙同意，法院應准許追加', '如甲係於第二審程序中追加，兩項請求之基礎事實不同一，即使乙不同意，法院得以不甚礙乙之防 禦及訴訟終結准許追加', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-3301-060', '113-3301', 60, 'single_choice', '甲與乙於某日訂立買賣契約，以甲所有之A 地為標的物，約定以價金新臺幣（下同）200 萬元出賣予 乙，嗣後雙方就該契約已否因一方行使解除權而消滅發生爭執，有意循訴訟程序解決紛爭。關於程序 之選擇，下列敘述，何者錯誤？', '甲為原告訴請確認系爭買賣契約所生買賣關係不存在時，得與被告乙合意請求受訴法院適用簡易訴 訟程序為審判', '甲起訴請求被告乙給付價金200 萬元時，不得與乙合意請求受訴法院適用小額訴訟程序為審判', '乙起訴請求判決命被告甲將A 地所有權移轉登記予乙，經第一審法院以乙之請求無理由判決其敗 訴後，在上訴期間內，如兩造間已合意承認該第一審判決所為事實認定無誤，得合意逕向第三審上訴', '甲與乙得合意由甲起訴請求法院判決確認解除權不存在，並於其裁判後逕向第三審上訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-3301-061', '113-3301', 61, 'single_choice', '關於訴訟上和解，下列敘述，何者錯誤？', '原告欲使被告以外之第三人參與和解，應先將其追加為被告', '成立訴訟上和解後，當事人得聲請退還該審級裁判費三分之二', '因試行和解或定和解方案，法院得命當事人或法定代理人本人到場', '當事人間所成立之訴訟上和解，與確定判決有同一之效力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-3301-062', '113-3301', 62, 'single_choice', '乙本於A 地所有權，訴請甲塗銷A 地所有權移轉登記，主張其與甲訂有買賣A 地契約，並辦畢所有 權移轉登記予甲，惟該買賣契約與物權契約有無效之事由。下列敘述，何者正確？', '乙向法院聲請裁定許可為訴訟繫屬事實登記，法院不得准許', '如乙起訴合法，法院應依其聲請，裁定許可為訴訟繫屬事實之登記', '乙聲請裁定許可訴訟繫屬事實登記時，就本案請求釋明如有不足，法院得命其供相當之擔保後准許之', '乙聲請裁定許可訴訟繫屬事實登記時，為避免甲脫產，法院為裁定前，不得使甲有陳述意見之機會', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-3301-063', '113-3301', 63, 'single_choice', '當事人於法院通知期日未到場者，下列敘述，何者錯誤？', '原告於準備程序期日未到場，而被告拒絕陳述時，視為合意停止訴訟', '當事人均未到場，依法視為合意停止訴訟後，法院得依職權續行訴訟', '當事人一造未到場時，法院仍得調查證據', '小額事件依法進行調解程序者，被告經合法通知無正當理由未到場時，原告得聲請即為訴訟之辯論， 而為一造辯論判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-3301-064', '113-3301', 64, 'single_choice', '原告甲為被告乙公司之股東，提起確認之訴，請求確認乙公司於民國110 年12 月10 日所召開之董事 會（下稱系爭董事會）確有通過A 決議，並請求確認乙公司於另案刑事訴訟中所提出系爭董事會會議 紀錄遭變造。乙公司於訴訟中就系爭董事會確有通過A 決議一事並不爭執，惟否認有變造系爭董事 會會議紀錄。下列敘述，何者錯誤？', '甲請求確認系爭董事會有通過A 決議部分，無確認利益', '甲請求確認系爭董事會會議紀錄遭變造部分，非屬確認證書真偽之訴', '確認法律關係基礎事實存否之訴，不限於確認現在之法律關係基礎事實存否', '如A 決議係解任乙公司之總經理丙，甲不得於訴訟中變更為請求確認乙、丙間之委任關係不存在', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-3301-065', '113-3301', 65, 'single_choice', '甲列乙、丙為被告，起訴請求確認乙、丙間買賣關係不存在，關於訴訟中之證據方法，下列敘述，何 者錯誤？', '法院得依職權訊問乙、丙，但不得命其具結', '甲得聲請法院裁定命乙、丙提出系爭買賣契約原本', '甲得聲請法院裁定命第三人仲介公司提出其所保管之系爭買賣契約原本，如仲介公司拒絕，法院得 以裁定命為強制處分', '如關於買賣契約條款之解釋有爭執，乙、丙於訴訟中已自行提出買賣契約影本，而拒絕依法院之命 提出原本，法院得依自由心證斷定該影本之證據力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-3301-066', '113-3301', 66, 'single_choice', '甲對乙提起訴訟後，受訴法院詢問兩造有無調解意願，經兩造陳明願意進行調解程序後，將本件訴訟 移付調解。關於調解程序，下列敘述，何者錯誤？', '經移付調解後，訴訟程序停止進行，應待調解之結果而決定有無繼續進行訴訟程序之必要', '兩造於調解期間均不到場，如法院認有調解成立之可能，仍得另定調解期日', '關於財產權爭議之調解，如經兩造同意，得由調解委員酌定解決事件之調解條款', '關於財產權爭議之調解，法院依職權提出解決事件之方案後，須經當事人明示同意，方得認為調解 成立', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-3301-067', '113-3301', 67, 'single_choice', '關於簡易訴訟程序，下列敘述，何者錯誤？', '原告提起財產權之訴訟，其標的金額為新臺幣（下同）50 萬元者，亦屬於50 萬元以下之財產權訴 訟，法院應適用簡易訴訟程序審理', '原告起訴請求確認與被告間就某一面額100 萬元之本票債權不存在之訴，係屬本於票據有所請求而 涉訟，法院應適用簡易訴訟程序審理', '產物保險公司代位道路交通事故被害人向加害者請求交通事故損害賠償80 萬元事件，屬於本於道 路交通事故有所請求而涉訟，法院應適用簡易訴訟程序審理', '原告於刑事簡易程序第二審提起附帶民事訴訟，刑事庭判決刑事被告有罪後，將附帶民事訴訟移送 同法院民事庭，為適用刑事簡易訴訟程序案件之附帶民事訴訟，經裁定移送民事庭者，民事庭應適 用簡易訴訟程序之第一審程序審理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-3301-068', '113-3301', 68, 'single_choice', '甲、乙分別為經營成衣買賣之供貨、銷售公司，甲起訴請求乙給付貨款新臺幣（下同）5 萬元。下列 敘述，何者錯誤？', '法院應先行調解程序，如調解不成立，即適用小額訴訟程序審理', '乙於調解期日7 日前經合法通知，無正當理由而未到場，法院得依到場甲之聲請，命即為訴訟之辯 論，並依職權由甲一造辯論而為判決', '甲依定型化契約約款向合意管轄法院起訴時，乙得抗辯小額訴訟程序無合意管轄規定之適用', '乙對甲反訴請求債務不履行之損害賠償60 萬元，法院應以其反訴不合法，裁定駁回', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-3301-069', '113-3301', 69, 'single_choice', '關於在第二審為訴之變更或追加，下列敘述，何者正確？', '一律均須得他造之同意，始得為之', '將離婚之訴變更為撤銷婚姻之訴，不須經他造同意', '追加必須合一確定之原非當事人之人為他造當事人，須得原為他造當事人之人同意，始屬合法', '因訴之變更為以新訴取代舊訴，舊訴視為撤回，第二審法院專就新訴為審判，故訴之變更倘不合法， 即應駁回該新訴，無須就舊訴續為審理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-3301-070', '113-3301', 70, 'single_choice', '甲起訴請求法院判命乙給付新臺幣（下同）300 萬元，第一審法院判決命乙給付甲200 萬元，並駁回 甲其餘之訴。甲就其敗訴全部合法提起第二審上訴，乙於第二審程序就其敗訴全部為附帶上訴。下列 敘述，何者錯誤？', '甲在第二審程序聲明撤回上訴，若乙不同意，就不生撤回上訴之效力', '乙就其敗訴全部曾提起上訴並經撤回後，見甲提起上訴，始在程序進行中，再提附帶上訴，則其上 訴權已因撤回上訴而消滅，附帶上訴不合法，第二審法院應以裁定駁回附帶上訴', '乙於逾上訴期間後始在第二審程序提附帶上訴，附帶上訴雖非不合法，惟若甲之上訴經第二審法院 以不合法為由而駁回者，該附帶上訴即失其效力，第二審法院無須為任何裁判', '乙於提起附帶上訴後撤回附帶上訴，第二審法院審理後為駁回甲上訴之判決，甲不服上訴，第三審 法院將原判決廢棄發回，乙在第二審更審程序，不得再提起附帶上訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-3301-071', '113-3301', 71, 'single_choice', '下列敘述之情形，何者不屬當事人得在第二審法院提出之新攻擊或防禦方法？', '在第一審請求承租人給付積欠租金之原告，追加請求自租期屆滿日起至返還租賃物之日止相當於租 金額之損害金', '請求履行債務事件之被告於第一審受敗訴判決後，為部分清償，因而抗辯原告之請求在該清償範圍 內為無理由', '請求返還借款事件之原告，就曾交付借款一事提出支票乙紙為證，被告否認受借款之交付。第一審 法院未經整理證據上爭點即以原告不能證明有交付借款之事實為由，駁回原告之請求。原告上訴後， 為證明該借款已交付之事實，聲請訊問證人某甲', '被告於第一審言詞辯論終結後向原告表明就原告主張之債權為抵銷，並於第二審提出該抵銷之抗辯', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-3301-072', '113-3301', 72, 'single_choice', '下列何者之原告，得提起第三審上訴？', '原告就第二審駁回其請求離婚及贍養費新臺幣（下同）50 萬元之判決提起上訴', '原告就其敗訴之100 萬元部分上訴，被告就其敗訴之200 萬元部分上訴', '原告起訴請求拆屋還地時之土地價值經法院核定為90 萬元，並據此繳納一、二審裁判費。於原告 提起第三審上訴日該地價值已升值為180 萬元', '原告就敗訴之140 萬元聲明不服，並於上訴第三審之同時擴張請求30 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-3301-073', '113-3301', 73, 'single_choice', '關於第三審上訴之審理，下列敘述，何者正確？', '第三審原則上應經言詞辯論，故無關本案請求有無理由之攻擊防禦方法，無須記載於答辯狀', '第三審法院在行言詞辯論程序時，宜先曉諭法律上爭點', '第三審行言詞辯論時雖得試行和解，但不得使兩造成立訴訟上和解', '第二審法院判決廢棄家事法院所為確認收養關係存在之第一審本案判決後，當事人不得對此第二審 判決提起第三審上訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-3301-074', '113-3301', 74, 'single_choice', '關於再審管轄權，下列敘述，何者正確？', '經第二審法院判決確定之事件，當事人對於同一事件之第一審及第二審判決同時聲明不服，提起再 審之訴，專屬原第一審法院管轄', '當事人對第二審判決提起上訴，經第三審法院以上訴不合法裁定駁回。當事人以適用法規顯有錯誤 為由，對於第二審判決提起再審之訴，並對第三審裁定聲請再審，專屬原第二審法院合併管轄', '當事人對第三審判決以適用法規顯有錯誤為理由，提起再審之訴，專屬該第三審法院管轄', '經第三審法院判決確定之事件，當事人對該第二審、第三審判決提起再審之訴，專屬第三審法院合 併管轄', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-3301-075', '113-3301', 75, 'single_choice', '甲基於侵權行為之損害賠償請求權，向某地方法院起訴請求判命被告乙賠償新臺幣800 萬元，並向受 訴法院聲請訴訟救助。受訴法院就訴訟救助聲請部分，裁定予以准許後，乙不服提起抗告。下列敘述， 何者錯誤？', '乙於收受准予訴訟救助之裁定後，得於法定期間內提起抗告。但乙如在裁定送達前提起抗告，亦有 效力', '乙提起抗告，若未依法繳納抗告裁判費，經原受訴法院定期命其補正而未補正者，原受訴法院得以 裁定駁回其抗告', '准予訴訟救助之裁定經宣示後，為裁定之法院應受其羈束，故縱原審法院認為乙之抗告為有理由， 亦不得自行撤銷或變更原裁定', '抗告法院認為乙之抗告有理由者，應以裁定廢棄或變更原裁定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-3301-076', '113-3301', 76, 'single_choice', '甲對乙有新臺幣500 萬元之本票債權，乙拒不清償，下列敘述，何者錯誤？', '因請求金額過大，甲不得向法院聲請發支付命令', '甲提起給付票款訴訟時，應適用簡易訴訟程序', '甲聲請法院調解時，法院得逕以裁定駁回', '甲得聲請法院裁定本票准予強制執行', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-3301-077', '113-3301', 77, 'single_choice', '甲、乙婚姻關係存續中，甲與丙通姦，乙對甲、丙起訴主張甲、丙通姦而請求侵權行為損害賠償。嗣 乙另對甲起訴，以不堪甲同居之虐待及甲通姦為由，請求裁判離婚，並酌定對於甲、乙所生未成年子 女A 之權利義務之行使負擔。下列敘述，何者錯誤？', '離婚訴訟應先行家事調解程序，並得經甲、乙、丙合意，將乙對甲、丙之損害賠償訴訟合併於離婚 事件調解', '甲、乙若於離婚訴訟中本人親自到場同意離婚，並合意對於A 權利義務之行使負擔由乙任之，且符 合A 之最佳利益，即可以該合意內容成立和解，並載明於和解筆錄', '甲在調解程序中自承有通姦的事實，於調解不成立後，法院不得採為離婚訴訟裁判之基礎', '乙雖於調解程序中放棄「甲通姦」離婚事由之主張，並就此成立書面協議，於調解不成立後，仍得 於裁判離婚訴訟中主張該離婚事由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-3301-078', '113-3301', 78, 'single_choice', '關於家事事件之審理原則，下列敘述，何者錯誤？', '在改定監護人事件，法院不受聲請人表明之監護人選所拘束，此乃職權主義（公權主義）之展現', '在確認婚姻無效事件，法院不受當事人自認關於婚姻有效或無效之事實所拘束，此乃職權探知主義 之展現', '在認可收養事件，當事人於請求法院裁判前，應經法院調解，此乃調解前置及促成合意原則之展現', '離婚事件與酌定未成年子女親權事件合併請求，此乃統合處理原則之展現', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-3301-079', '113-3301', 79, 'single_choice', '印度籍之甲夫與臺灣籍之乙妻結婚，婚後生有未成年子丙，全家居住於甲夫之工作地點新竹，後甲、 乙不合，甲離開臺灣前往菲律賓工作，之後失去連絡，乙攜丙回娘家屏東居住。關於審理程序，下列 敘述，何者錯誤？', '乙以甲離家失聯，長期未同居，有重大事由請求裁判離婚，有關我國法院程序之規定，應適用中華 民國法律', '乙請求甲償還先前代甲墊付丙之扶養費事件，應另行起訴，不得與乙對甲之離婚事件合併請求', '丙請求甲給付扶養費事件，屏東地方法院有管轄權', '在乙對甲請求裁判離婚之訴訟繫屬中，乙得合併請求對丙權利義務之行使負擔由乙任之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-3301-080', '113-3301', 80, 'single_choice', '甲夫、乙妻有未成年之婚生子丙，乙婚前另與丁男交往，甲死亡後，其母戊認為丙非甲之子，提起確 認親子關係不存在訴訟。下列敘述，何者正確？', '戊應以乙、丙、丁為共同被告，當事人始適格', '如丙受婚生子女推定，則戊所提訴訟為無理由', '為監督法官之審理，此類訴訟所有民眾皆可旁聽', '受訴法院得命被告乙本人到場，如乙無正當理由不到場，法院得裁罰，並命拘提', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-4301-001', '113-4301', 1, 'single_choice', '依公司法第22 條之1 規定，公司應每年定期以電子方式，將內部人之資料申報至臺灣集中保管結算 所建置維護之資訊平臺，下列何者非須申報之內部人？', '董事、監察人、經理人', '董事、監察人、經理人之配偶、未成年子女及為其持有公司股票者', '持有已發行股份總數超過10%之股東', '出資超過資本總額10%之股東', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-4301-002', '113-4301', 2, 'single_choice', '依公司法中有關公司登記之規定，下列敘述何者正確？', '公司申請設立登記之資本額，應經會計師查核簽證，公司應於申請設立登記時或設立登記後3 個月 內，檢送經會計師查核簽證之文件', '公司應收之股款，股東並未實際繳納，而以申請文件表明收足，公司負責人經法院判決有罪確定。 在此判決確定前，公司縱已完成補正，中央主管機關因系爭確定判決仍應撤銷或廢止公司登記', '公司負責人犯偽造文書印文罪章之罪辦理增資登記，經法院判決有罪確定後，利害關係人得申請中 央主管機關撤銷其增資登記', '公司申請變更登記之資本額，無須會計師查核簽證', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-4301-003', '113-4301', 3, 'single_choice', 'X 公司持有Y 公司已發行股份總數5%的股份，擬參與Y 公司經營，正評估以X 公司名義或由X 公 司代表人擔任董事之利弊。依公司法規定，下列敘述何者錯誤？', '如X 公司擔任Y 公司董事，其應指定自然人代表行使職務，而在董事任期內，X 公司得隨時改派 代表人補足其任期', '如X 公司代表人甲及乙二人同時當選為Y 公司董事時，在董事任期內，X 公司得改派丁及戊補足 其任期', '如Y 公司為公開發行股票之公司，X 公司代表人甲擔任Y 公司董事，X 公司在甲之董事任期內將 Y 公司持股全數轉讓給他人時，甲即喪失其董事資格', '如Y 公司為公開發行股票之公司，X 公司在擔任Y 公司董事時，將Y 公司持股全數設質，X 公司 即喪失其董事資格', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-4301-004', '113-4301', 4, 'single_choice', 'A 有限公司（下稱A 公司）本身進行金融科技產業，欲擴大公司規模，故欲尋覓合作對象，以追求企 業合併綜效。下列有關有限公司合併之敘述，何者錯誤？', 'A 公司須經全體股東同意，方可與B 有限公司合併', '若A 公司欲與C 股份有限公司進行存續合併，則存續公司必須為C 股份有限公司', 'A 公司決議與D 有限公司合併後，則應通知各債權人，並指定30 日以上期限，聲明債權人得於期 限內提出異議', '若A 公司決議與E 有限公司合併卻漏未通知債權人，則不得以其合併對抗債權人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-4301-005', '113-4301', 5, 'single_choice', '關於有限公司股東權限之敘述，下列何者正確？', '股東按出資多寡比例分配表決權，但得以章程訂定，不論出資多寡，每一股東均有一表決權', '有限公司的股東有自由移轉其出資額之權利', '在有限公司增資情況，如股東同意該議案，將負等比例承購義務', '會計年度終了之會計表冊承認，應經股東表決權過半數之同意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-4301-006', '113-4301', 6, 'single_choice', 'A 有限公司（下稱A 公司）有甲、乙、丙、丁及戊共5 位股東，各出資新臺幣100 萬元，章程規定 設置董事3 人，董事長1 人，由甲、乙、丙當選董事，下列關於A 公司董事、董事長之敘述，何者 正確？', 'A 公司之董事長應經股東表決權三分之二以上之同意選任之', 'A 公司董事長應經董事全體同意選任之', 'A 公司董事，非有特約，不得向公司請求報酬', 'A 公司若有董事為自己或他人為與公司同類業務之行為，應對全體董事說明其行為之重要內容，並 經董事過半數之同意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-4301-007', '113-4301', 7, 'single_choice', '關於公司虧損時所得採取行為之相關規範，下列敘述何者錯誤？', '董事會為彌補公司虧損，提出減少資本議案，應於股東會開會30 日前交監察人查核後，提請股東 會決議', '公司虧損達實收資本額三分之二時，董事會應於最近一次股東會報告', '公司資產顯有不足抵償其所負債務時，除得進入重整程序外，董事會應即聲請宣告破產', '公司如最近連續二年有虧損者，原則上不得公開發行新股', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-4301-008', '113-4301', 8, 'single_choice', 'A 上市公司（下稱A 公司）持有B 公司已發行有表決權之股份總數51%，B 公司持有C 公司已發行 有表決權之股份總數49%，並指派代表人當選C 公司過半數之董事，A 公司對C 公司則無持股，C 公 司對A 公司及B 公司各持有已發行有表決權之股份總數1%，下列關於收買股份或有無表決權之敘 述，依公司法規定及最高法院之見解，何者正確？', 'B 公司得收買A 公司之股份', 'C 公司不得收買B 公司之股份', 'C 公司持有A 公司之1%股份，有表決權', 'C 公司持有B 公司之1%股份，無表決權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-4301-009', '113-4301', 9, 'single_choice', '關於公司法第214 條之股東代表訴訟制度，下列敘述何者正確？', '欲行使本條之少數股東權，須為繼續6 個月以上，持有已發行股份總數百分之三以上之股東', '符合本條規定之股東提起訴訟時，為避免濫訴，應以書面先向董事會請求', '為求減低負擔，股東提起代表訴訟時，其裁判費超過新臺幣100 萬元部分免收', '股東提起代表訴訟時，法院得依聲請為原告選任律師為訴訟代理人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-4301-010', '113-4301', 10, 'single_choice', '關於公司法第235 條之1 股份有限公司員工酬勞分派之規定及其實務見解，下列敘述何者錯誤？', '計算員工、董監事酬勞時，應以當年度獲利扣除累積虧損後，再就餘額計算員工、董監事酬勞', '公司應於章程訂明以當年度獲利狀況之定額或比率，分派員工酬勞。所謂比率須為固定比例（例如 1%），不得為一定區間（例如1-3%）', '員工酬勞得以發放現金或股票為之，經董事會特別決議並報告股東會即可', '公司董事長兼任員工時，可基於員工身分受員工酬勞之分派', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-4301-011', '113-4301', 11, 'single_choice', '關於閉鎖性股份有限公司，下列敘述何者錯誤？', '股東人數不得超過五十人，亦不得為公開發行股票公司', '不得分次發行股份', '公司可於證券主管機關許可之證券商經營之股權群眾募資平臺募資', '公司股份轉讓之限制應於章程載明', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-4301-012', '113-4301', 12, 'single_choice', '股票未公開發行之A 股份有限公司擁有股東約50 人，下列對於該公司董事會與董事之相關敘述，何 者錯誤？', '該公司得依章程規定不設董事會', '董事選舉必須採累積投票制', '董事選舉必須採候選人提名制', '董事缺額達三分之一時，應於30 日內召開股東臨時會補選', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-4301-013', '113-4301', 13, 'single_choice', '甲公司董事會決議向其大股東A 借款8,000 萬元，年息百分之十，但目前銀行之企業貸款年息約百分 之三。甲公司之章程明訂，公司對外借款超過5,000 萬元應經過股東會同意。甲公司監察人B 及持股 已達2 年之股東C，對董事會自行決定且未得到股東會同意，便自行借款的情事均表示不滿，欲制止 董事會，下列敘述何者正確？', '若股東C 未持有甲公司已發行有表決權股份總數之百分之一以上股份，不得自行行使制止請求權', '若股東C 未持股百分之一以上，應先請求監察人B 制止董事會；如監察人B 無正當理由不行使， 始得由股東C 自行制止之', '因為本案已經董事會討論並通過，故監察人B、股東C 二人皆不得行使制止請求權', '監察人B、股東C 二人均能立即行使制止請求權，並無何者須優先行使的次序要求', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-4301-014', '113-4301', 14, 'single_choice', 'A 股份有限公司（下稱A 公司）為一從事食品加工的非公開發行公司，該公司章程規定公司股份總數 為100 萬股，全數均為普通股，並以每股票面金額新臺幣10 元全數發行。目前A 公司之實收資本額 為新臺幣1,000 萬元，其中X 股份有限公司（下稱X 公司）持有A 公司股份35 萬股，X 公司之從屬 公司Y 股份有限公司亦持有A 公司股份25 萬股。其後，A 公司為擴大公司規模，打算再發行50 萬 普通股。新股發行除依法保留總數百分之十的股份由A 公司員工承購外，其餘全數由原股東按其原 有持股比例認購完畢。依公司法規定，下列敘述何者正確？', 'A 公司此次發行新股只要董事會同意即可，無須經股東會同意', 'X 公司於此次發行新股僅能以現金出資方式認購，不得以A 公司事業所需之財產為出資', 'A 公司此次發行新股保留由原股東認購者，A 公司得限制其在2 年內不得轉讓', 'A 公司不論增資發行新股前後，X 公司與A 公司之關係屬於控制公司與從屬公司之關係', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-4301-015', '113-4301', 15, 'single_choice', 'A 醫院轉投資B 有限公司、C 股份有限公司、D 商號、E 有限合夥，均取得有表決權之股份或出資額 超過半數。此五家組織中，有幾家彼此間可能構成公司法上之關係企業？', '2', '3', '4', '5', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-4301-016', '113-4301', 16, 'single_choice', '下列關於人壽保險契約之相關規定敘述，何者錯誤？', '保險費到期未交付者，除契約另有訂定外，經催告到達後屆30 日仍不交付時，保險契約之效力停止', '被保險人年齡不實，而其真實年齡已超過保險人所定保險年齡限度者，其契約無效，保險人應退還 所繳交保險費', '即使契約中已指定受益人，除要保人聲明放棄處分權者外，仍得以契約或遺囑變更之', '保險費付足二年以上者，要保人方得以保險契約為質，向保險人借款', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-4301-017', '113-4301', 17, 'single_choice', '下列關於保險法涉及保險契約訂立之規定，何者錯誤？', '人身保險不得為指示式或無記名式', '保險契約由代理人訂立者，適用民法之相關規定即可，無庸再行載明代訂之意旨', '保險契約由合夥人或共有人中之一人或數人訂立，而其利益及於全體合夥人或共有人者，應載明為 全體合夥人或共有人訂立之意旨', '保險人得約定保險標的物之一部份，應由要保人自行負擔由危險而生之損失。有此約定時，要保人 不得將未經保險之部份，另向他保險人訂立保險契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-4301-018', '113-4301', 18, 'single_choice', '甲以其即將大學畢業之子乙為被保險人向A 壽險公司（下稱A 公司）投保傷害保險，保險契約條款 約定：「被保險人職業變更時應書面通知保險人；未通知者，保險契約自動解除」。乙畢業後參加政府 所舉辦的短期電工技職訓練班，未通知保險人A 公司，訓練期間與其他學員外出旅遊時，巧遇旅館失 火而死亡。試問保險人A 公司主張不負保險責任，有無理由？', '有理由，被保險人未通知，契約自動解除', '有理由，被保險人未通知，保險人仍須行使解除權，契約方解除', '無理由，應通知而未通知，保險人僅得請求損害賠償，仍負給付保險金之責', '無理由，損害之發生不影響保險人之負擔，保險人仍應全額賠償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-4301-019', '113-4301', 19, 'single_choice', '甲以其所有之房屋（廠房兼住家）向A 產險公司（下稱A 公司）投保火災保險500 萬元，並以配偶 乙為被保險人向B 壽險公司（下稱B 公司）投保意外保險1,000 萬元。今甲之受僱人丙因工資報酬問 題與甲產生糾紛，遂故意縱火，導致廠房全損及乙罹難火場。A 公司、B 公司分別為保險理賠後，對 丙主張保險代位求償，有無理由？', 'A 公司、B 公司均有理由', 'A 公司、B 公司均無理由', 'A 公司有理由，B 公司無理由', 'A 公司無理由，B 公司有理由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-4301-020', '113-4301', 20, 'single_choice', '甲於民國112 年（下同）6 月1 日參加大學同學會，經昔日同窗乙招攬，詳細說明保單相關內容後， 決定以自己為被保險人向A 保險公司（下稱A 公司）投保人壽保險契約，乙於次日將甲填載完成之 要保書回傳A 公司完成要保程序，並於同日印出繳費單，甲於6 月5 日於超商繳費完成。甲於6 月 10 日收到A 公司所寄發核保通過簡訊，A 公司並於6 月15 日寄出保險單。然甲已於6 月12 日因意 外事故死亡。下列敘述何者正確？', '依保險法規定，保險契約應以保險單或暫保單為之。甲死亡時保險契約尚未成立生效，保險人無需 為保險給付', '保險契約為要物契約，甲於6 月5 日完成繳費，契約成立生效，保險人應為保險給付', '乙為保險公司業務員，為A 公司向甲招攬，甲完成要保書回傳並繳費，雙方意思表示合致，契約於 6 月5 日成立生效，保險人應理賠', '保險契約為不要式不要物契約，保險人核保時，雙方意思表示已經合致，契約成立生效，保險人應 依約給付', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-4301-021', '113-4301', 21, 'single_choice', '疏浚業者甲以其所有的一艘老抽砂船向產險業者乙投保船舶保險，該船市價及保險金額同為3,000 萬 元，因船舶老舊且非航行用船，保單特別約定「保險期間船舶航行不得超出臺北港」並約定適用中華 民國法。保險期間，甲另外承攬澎湖馬公港疏浚工程，抽砂船駛往馬公港途中於臺中港外海擱淺受損， 甲耗費2,000 萬元進行船舶救助，另船舶維修費2,500 萬元。如依實務判決見解，本案乙保險人責任 為何？', '主張甲違反特約條款，自違反之時起，保單即刻失效，乙無須理賠', '主張甲違反特約條款，乙如於一個月內解除契約，即無須理賠', '特約條款顯失公平，應屬無效，乙應賠償保險金額3,000 萬元', '特約條款顯失公平，應屬無效，並依保險法第33 條規定，乙應賠償4,500 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-4301-022', '113-4301', 22, 'single_choice', 'A 遊樂場向B 保險公司（下稱B 公司）投保責任保險。甲於A 遊樂場遊玩時，因設施故障而受傷， 事故後1 個月，A 遊樂場破產結束營業。甲求償無門，乃依保險法第94 條向B 公司為直接請求損害 賠償。B 公司主張A 遊樂場未繳保費且違反遊樂設施定期保養特約條款規定，於事故發生後2 週已解 除契約，自不負理賠責任。下列關於B 公司之主張有無理由之敘述，何者正確？', '有理由，因保險契約已經解除，保險人不負理賠責任', '無理由，保險契約效力屬B 保險公司與A 被保險人間之內部關係，不影響受害第三人甲對B 保險 人之直接請求權', '有理由，因A 遊樂場未賠付甲之前，損失尚未確實發生，B 公司本無須負責', '無理由，B 公司仍應理賠，理賠後再向已破產的A 遊樂場為主張', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-4301-023', '113-4301', 23, 'single_choice', '依我國保險法之規定，保險業之同業公會為會員之健全經營及維護同業之聲譽，應辦理相關事項。下 列敘述何者錯誤？', '訂定自律規範並請專家審核後即可提供會員遵循', '就會員所經營業務發生紛爭時為必要協調', '辦理保險主管機關委託辦理之事項', '訂立實務作業規定時得要求會員提供相關資料', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-4301-024', '113-4301', 24, 'single_choice', '關於未來事項之特約條款，在訂約地為不合法而未履行者，保險契約之效力為何？', '因客觀不能而契約無效', '不拘束保險人', '依然有效', '不拘束被保險人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-4301-025', '113-4301', 25, 'single_choice', '下列有關保險代理人、保險經紀人與公證人之敘述，何者錯誤？', '保險經紀人應以善良管理人之注意義務，為被保險人洽訂保險契約或提供相關服務，並負忠實義務', '兼有保險代理人、經紀人、公證人資格者，得同時申領執業證照，但保險代理人與經紀人應擇一申領', '銀行得經主管機關許可擇一兼營保險代理人或保險經紀人業務', '保險經紀人應經主管機關許可，繳存保證金並投保責任保險與保證保險，領有執業證照後，始得經 營或執行業務', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-026', '113-4301', 26, 'single_choice', '甲簽發發票日為某年5 月1 日，到期日為同年10 月1 日，面額20 萬元之本票一張交付乙，乙將本票 背書交付丙，丙背書交付丁。如乙於該票據背面簽名旁記載免作拒絕證書，丁於同年10 月3 日請求 甲付款，遭甲拒絕，丁遲至次年10 月2 日始對乙追索，乙對丁有無抗辯事由？', '乙對丁有抗辯事由，因追索權時效至次年9 月30 日止', '乙對丁有抗辯事由，因追索權時效至次年10 月1 日止', '乙對丁無抗辯事由，因追索權時效至次年10 月3 日止', '乙對丁有抗辯事由，因丁未遵期為付款提示', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-027', '113-4301', 27, 'single_choice', '甲簽發本票一張予乙，以清償所欠貨款新臺幣（下同）10 萬元，然於簽發之際錯看收據上所載數字， 誤填金額為16 萬元。乙於票據到期前將該票背書轉讓予善意之丙，購買丙市價約15 萬元之設備，該 票到期後，丙持以向甲請求付款，下列敘述何者正確？', '該票據因金額誤載而無效，甲無須付款', '甲可主張該票據所欲清償之債務為10 萬元，而得僅支付10 萬元，就剩餘之6 萬元，丙應向乙請求', '因票載金額與實際交易不符，若甲可證明實際債權數額僅10 萬元，則丙僅得請求10 萬元', '票載金額為16 萬元，則甲應支付16 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-028', '113-4301', 28, 'single_choice', '甲未經乙之授權，以乙之名義簽發受款人為丙之本票，丙所執之本票被丁所盜，其後丁偽造丙之簽名 轉讓予戊，戊再背書轉讓予善意不知情且有給付對價之己。若己到期不獲付款時，得向何人行使追 索權？', '甲', '乙', '丁', '戊', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-029', '113-4301', 29, 'single_choice', '乙執有甲簽發之記名匯票，票載付款人為丙。下列何種情況，乙不得於到期日前行使追索權？', '丙拒絕承兌', '甲死亡', '丙受破產宣告', '丙行蹤不明，無從為承兌之提示', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-030', '113-4301', 30, 'single_choice', '甲因協助A 公司介紹一筆生意而可獲得A 公司給付之佣金，甲擬以由A 公司擔任甲簽發匯票之付款 人方式獲得該佣金，為保證將來A 公司會承兌該票據，A 公司與甲並簽訂書面之契約。甲後來即簽發 一紙以A 公司為付款人之匯票予乙，並將A 公司承諾之事告知乙，乙將該匯票背書轉讓予丙，惟乙 之背書附註該背書須待A 公司履行承兌之承諾始生效力，丙於到期日持匯票向A 公司請求付款，A 公司稱因甲所介紹之生意因故未成交，所以拒絕付款，丙得向何人請求票款？', 'A 公司、甲、乙', 'A 公司、甲', 'A 公司、乙', '甲、乙', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-031', '113-4301', 31, 'single_choice', '甲與乙為姐妹，為盡孝道扶養行動不方便之母親丙，決定在臺北市購買一間位於一樓之公寓供丙居住。 兩人向銀行貸款時，共同簽發本票並經丙背書予銀行。因房貸之繳款不正常，銀行遂欲以本票行使追 索權，此時乙已因病猝逝，財產由其子丁單獨繼承。依據司法實務之見解，得對何人聲請法院裁定後 強制執行？', '僅甲', '僅甲丙', '僅甲丁', '甲丙丁', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-032', '113-4301', 32, 'single_choice', '關於本票之背書，下列何種行為，非票據法所許？', '以委任取款之目的而為背書', '執票人將背書塗銷', '背書人記載預備付款人', '背書人於票上為禁止轉讓之記載', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-033', '113-4301', 33, 'single_choice', '甲於民國109 年7 月1 日簽發記名支票一紙予乙，金額為新臺幣100 萬元，發票地與付款地均為臺南 市，匆忙間，甲漏未記載發票日。下列關於該支票之敘述，何者正確？', '以實際發票日為發票日', '以乙提示付款日為發票日', '該支票視為見票即付', '該支票無效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-4301-034', '113-4301', 34, 'single_choice', '支票之發票人在下列何期限內，不得撤銷付款之委託？', '發票日後3 年內', '發行滿1 年後起2 年內', '發行滿1 年以前', '提示期限內', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-035', '113-4301', 35, 'single_choice', '依票據法之規定，下列有關支票之敘述，何者正確？', '支票在票載發票日前，執票人為付款之提示，付款人應於見票時無條件付款', '支票發票人應照支票文義擔保支票付款，其付款責任與匯票承兌人相同', '支票發票地與付款地均為新北市，如發票日後七日執票人不為付款之提示，對於發票人以外之前手， 喪失追索權', '支票、匯票、本票發票時，發票日及到期日均為絕對必要記載事項', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-036', '113-4301', 36, 'single_choice', 'A 股份有限公司（下稱A 公司）為一家從事食品加工之上市公司，並依法設置審計委員會。最近，A 公司擬召開審計委員會，討論年度財務報告等事宜。依證券交易法之規定，下列敘述何者錯誤？', 'A 公司因已設置審計委員會，所以無須再設置監察人', 'A 公司審計委員會得決議請公司相關部門經理人員、內部稽核人員、會計師、法律顧問或其他人員 列席會議及提供相關必要之資訊。但討論及表決時應離席', '審計委員會之召集，應載明召集事由，於三日前通知委員會各獨立董事成員。但有緊急情事者，不 在此限', 'A 公司如有正當理由致審計委員會無法召開時，年度財務報告等事項應以全體董事三分之二以上 同意行之。但年度財務報告事項仍應由獨立董事成員出具同意意見', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-037', '113-4301', 37, 'single_choice', 'A 公司為一家從事醫療器材製造的上市公司，該公司設有薪資報酬委員會。甲最近剛被選任為A 公 司薪資報酬委員會成員，由於甲是首次擔任薪資報酬委員會成員，因此想要了解下列有關薪資報酬委 員會之敘述，何者錯誤？', '薪資報酬委員會成員由董事會決議委任之，其人數不得少於三人', '薪資報酬委員會得經決議，委任律師、會計師或其他專業人員，就行使職權有關之事項為必要之查 核或提供諮詢，其費用由公司負擔', 'A 公司董事會通過之薪資報酬如優於薪資報酬委員會之建議，除應就差異情形及原因於董事會議 事錄載明外，並應於董事會通過之即日起算二日內於主管機關指定之資訊申報網站辦理公告申報', '薪資報酬委員會應至少每年召開四次，並於薪資報酬委員會組織規程中訂明之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-038', '113-4301', 38, 'single_choice', '甲為A 上市公司（下稱A 公司）持股超過百分之十的大股東。若甲所持有的A 公司股票有所變動時， 其應於次月幾日以前將上月份持有股數變動之情形，向公司申報？公司應於每月幾日以前，彙總向主 管機關申報？', '1 日；10 日', '5 日；10 日', '5 日；15 日', '10 日；15 日', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-039', '113-4301', 39, 'single_choice', '股票上市之A 公司有法定盈餘公積新臺幣（下同）5 億元，保留盈餘1 億元，發行股份溢價及已實現 之資本公積2 億元，A 公司擬買回股份，依證券交易法之規定，其買回總金額之上限為何？', '3 億元', '6 億元', '7 億元', '8 億元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-040', '113-4301', 40, 'single_choice', '公開發行公司募集無擔保轉換公司債，依證券交易法令，原則上其額度限制為何？', '不得逾全部資產減去全部負債餘額之50%', '不得逾全部資產減去全部負債之餘額', '不得逾全部資產減去全部負債餘額之200%', '不得逾全部資產減去全部負債餘額之400%', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-041', '113-4301', 41, 'single_choice', '依證券交易法發行股票公司之董事、監察人、經理人或持有公司股份超過股份總額10%之股東，依證 券交易法之規定對其股票轉讓之限制，下列敘述何者錯誤？', '向主管機關申報生效後，得向非特定人為之', '依主管機關所定持有期間及每一交易日得轉讓數量比例，於向主管機關申報之日起3 日後，得向符 合主管機關所定條件之特定人為轉讓', '於向主管機關申報之日起3 日內，向符合主管機關所定條件之特定人為之', '該股票轉讓方式之限制，亦適用董事之配偶與未成年子女', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-4301-042', '113-4301', 42, 'single_choice', '依據證券交易法第22 條第3 項及「發行人募集與發行有價證券處理準則」之規定，下列何者為公開 招募？', '發起人於公司成立前，對非特定人招募股票之行為', '發行公司於發行前，對非特定人招募股票之行為', '有價證券持有人為出售其所持有之股票，而對非特定人招募之行為', '公開發行公司對特定人招募股票之行為', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-4301-043', '113-4301', 43, 'single_choice', '下列何者為證券交易法所稱之發行人？', 'A 上市公司之總經理甲', '以發起設立方式設立B 股份有限公司之發起人乙', '募集發行新股之C 股份有限公司', '募集發行新股之D 股份有限公司之董事長丙', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-4301-044', '113-4301', 44, 'single_choice', 'A 公司為一家生產車用電池的上市公司，甲為該公司的獨立董事。近期，A 公司擬討論內部稽核主管 之任免事宜。依證券交易法之規定，下列敘述何者錯誤？', 'A 公司所設置之獨立董事，人數不得少於三人', '甲在獨立董事任期中若轉讓超過選任當時所持有之A 公司股份數額二分之一時，其獨立董事當然 解任', 'A 公司獨立董事均解任時，公司應自事實發生之日起六十日內，召開股東臨時會補選之', '如有正當理由致審計委員會無法召開時，內部稽核主管之任免應以全體董事三分之二以上同意行之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-4301-045', '113-4301', 45, 'single_choice', 'A 上市公司（下稱A 公司）總經理甲於今年3 月初買進自家公司上市股票100 張，並於同年5 月中 將其全數賣出，共獲利新臺幣200 萬元。A 公司的股東乙認為甲的行為違反證券交易法短線交易之規 定，公司應積極主張其權利。下列敘述何者錯誤？', 'A 公司應請求甲將其利益歸於公司，此一請求權自獲得利益之日起1 年間不行使而消滅', 'A 公司不行使歸入權時，不限持股多寡，任何股東皆得以30 日之限期，請求董事行使之；逾期不 行使時，請求之股東得為公司行使此一請求權', '董事不為公司行使歸入權以致A 公司受損害時，對公司負連帶賠償之責', '甲之行為並無刑事責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true)
on conflict (question_id) do update set
  paper_id = excluded.paper_id,
  question_number = excluded.question_number,
  question_text = excluded.question_text,
  option_a = excluded.option_a,
  option_b = excluded.option_b,
  option_c = excluded.option_c,
  option_d = excluded.option_d,
  source_page_start = excluded.source_page_start,
  source_page_end = excluded.source_page_end,
  extraction_status = excluded.extraction_status,
  review_status = excluded.review_status,
  is_published = excluded.is_published,
  updated_at = now();

-- Question batch 3
insert into public.questions (
  question_id, paper_id, question_number, question_type, question_text,
  option_a, option_b, option_c, option_d, subject_primary, subject_secondary,
  chapter, topic_primary, topic_secondary, law_refs, tags, source_page_start,
  source_page_end, extraction_status, review_status, notes, is_published
) values
('113-4301-046', '113-4301', 46, 'single_choice', '甲執命乙給付金錢之確定判決，聲請強制執行乙對A 地所有權之應有部分；乙之債權人丙就該應有 部分有抵押權，然未聲明參與分配或聲請強制執行；丁為A 地共有人，乙之承租人戊於查封前已占用 A 地。下列何種情形不得依強制執行法第12 條規定聲請或聲明異議？', '執行法院定期112 年8 月15 日第一次拍賣，拍賣公告記載「拍定後點交」，戊以拍賣公告記載錯誤 為由，聲請更正記載為「拍定後不點交」', '執行法院定期112 年8 月10 日第一次拍賣，拍賣公告於同年7 月29 日揭示在法院公告欄，乙以執 行法院公告時間距離拍賣期日不足法定最短天數為由聲明異議', 'A 地應有部分拍定收足價金後，執行法院逕行核發權利移轉證書予拍定人，丁以其未獲通知是否 優先承買為由聲明異議', 'A 地應有部分拍定收足價金後，執行法院作成分配表定期113 年2 月5 日分配，並於同年月1 日 將分配表繕本送達丙，丙以送達時間距離分配期日不足法定最短天數為由聲明異議', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-4301-047', '113-4301', 47, 'single_choice', '有關執行名義之種類，下列敘述，何者正確？', '我國法院撤銷暴利行為之判決確定者，得為執行名義', '我國法院經宣告假執行之租金給付判決，遭上級審廢棄者，仍得為執行名義', '我國公證人就一定數額之違約金債務載明應逕受強制執行之公證書，得為執行名義', '日本法院之貨款給付判決確定者，得逕為執行名義', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-4301-048', '113-4301', 48, 'single_choice', '甲於民國（下同）112 年12 月12 日持乙簽發發票日109 年7 月7 日，面額新臺幣200 萬元之支票， 聲請法院對乙核發支付命令獲准，嗣於113 年3 月4 日持該支付命令聲請對乙為強制執行。下列敘述， 何者正確？', '倘甲之債權經執行後未獲足額清償，得依強制執行法第27 條規定，聲請執行法院核發債權憑證', '乙抗辯甲之票款給付請求權已罹於消滅時效期間，並於甲聲請支付命令前已拒絕給付票款，得依強 制執行法第14 條第1 項規定，於強制執行程序終結前，提起債務人異議之訴，以排除強制執行程序', '乙提起債務人異議之訴後，受訴法院應依強制執行法第18 條第2 項規定，以職權裁定乙不須供擔 保而停止強制執行', '基於支付命令之即時確定，甲聲請強制執行不須檢附支付命令之確定證明書', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-4301-049', '113-4301', 49, 'single_choice', '甲對乙有貨款債權新臺幣（下同）500 萬元，取得確定勝訴判決後，聲請法院強制執行乙所有之市價 1,000 萬元A 地。該地業經乙設定最高限額700 萬元抵押權予丙，以擔保丙對乙尚未屆清償期之借款 債權。下列敘述，何者錯誤？', '丙無執行名義，且未聲明參與分配，執行法院仍應通知丙參與分配', '丙為保護其期限利益，得拒絕參與分配，而主張拍定後不得塗銷其抵押權設定登記', '丙於A 地拍定後始以500 萬元抵押借款債權聲明參與分配，執行法院仍應將丙申報之債權金額列 入分配，並得優先受償', '執行法院通知丙參與分配，丙未聲明參與分配，執行法院仍應將丙之700 萬元債權金額列入分配， 並得優先受償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-4301-050', '113-4301', 50, 'single_choice', '有關動產之拍賣與不動產之拍賣，下列敘述，何者正確？', '拍定人就拍賣物皆無物之瑕疵擔保請求權', '所定底價皆應記載於拍賣公告', '皆以投標方式為之', '皆須預定拍賣物之底價', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-4301-051', '113-4301', 51, 'single_choice', '執行法院依債權人甲之聲請，實現其金錢債權新臺幣（下同）100 萬元，就債務人乙對第三債務人丙 之金錢債權50 萬元發扣押命令，並就乙之不動產為查封後，乙之債權人丁就其金錢債權100 萬元聲 明參與分配，執行法院逕就乙對丙之債權發移轉命令，將該金錢債權移轉予甲。關於丁之救濟，下列 敘述，何者正確？', '上開執行程序於移轉命令核發時已告終結，丁無從聲明異議，關於丁之權利受損已無法救濟', '因不動產執行程序尚在進行中，故丁仍得聲明異議，聲請執行法院撤銷該移轉命令', '丁得對甲提起不當得利之訴訟，請求返還其原應受分配額之利益', '執行法院應依職權撤銷該移轉命令', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-4301-052', '113-4301', 52, 'single_choice', '債權人甲訴請債務人乙交付A 上市公司股票100 張，獲勝訴判決確定後，持該判決聲請執行法院對 乙為強制執行，乙除B 土地外，已無其他財產。下列敘述，何者正確？', '執行法院應適用對於不動產執行之規定，查封拍賣B 土地，於A 上市公司股票100 張之市價範圍 內，將執行所得分配予甲，由甲在公開市場上自行購買100 張A 上市公司股票', '乙就交付A 上市公司股票100 張陷於給付不能，甲以不能之給付為執行標的，執行法院應裁定駁 回甲之強制執行聲請', '執行法院應命乙自動履行，如不依限履行，得估算代履行費用，以裁定命乙支付。乙不支付，甲得 以此裁定為執行名義，聲請執行法院查封拍賣B 土地，以執行所得支付代履行費用', '執行法院應定期命乙交付100 張A 上市公司股票予甲，逾期不履行，得處新臺幣3 萬元以上30 萬 元以下之怠金，經再次定期履行，仍不履行者，得再處怠金或管收', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-4301-053', '113-4301', 53, 'single_choice', '債權人甲訴請債務人乙遷讓A 房屋獲勝訴判決確定，乙拒絕搬遷，甲持該判決聲請執行法院強制執 行。下列敘述，何者正確？', '執行法院應尊重甲依確定判決執行之權利，不得勸導甲與乙互相讓步，約定自行遷讓之期間', '執行法院強制乙遷離後，乙當日夜間折返A 房屋開門進入居住，甲毋須另取得執行名義，得繳納執 行費聲請再為執行', '乙之配偶丙，因與乙同居而使用A 房屋，因丙非執行名義之判決當事人，執行法院不得依甲之聲 請，命丙遷離', '乙如為孤寡老弱殘障，應由社會福利機關（構）主動關懷協助，執行法院不可勸甲協助乙尋覓暫時 安身處所', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-4301-054', '113-4301', 54, 'single_choice', '債權人甲為保全對債務人乙之債權新臺幣（下同）500 萬元，聲請法院裁定准許假扣押，甲於收受假 扣押裁定後30 日內，向執行法院聲請查封乙所有價值200 萬元之A 地，經執行後，甲查得乙有另一 筆價值300 萬元之B 地，聲請追加查封。關於甲追加查封之聲請，下列敘述，何者正確？', '甲追加查封之聲請，應於第一次查封聲請後30 日內為之，始為合法', '甲追加查封之聲請，應於收受假扣押裁定後30 日內為之，始為合法', '甲追加查封之聲請，須另行取得假扣押裁定，並於收受該裁定後30 日內為之，始為合法', '甲追加查封之聲請，雖已逾收受假扣押裁定、第一次查封聲請30 日，仍屬合法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-055', '113-4301', 55, 'single_choice', '債權人甲聲請法院拍賣債務人乙所有之A 地，經拍定後法院發給拍定人不動產權利移轉證書，乙之 另一債權人丙於價金分配前，聲請對A 地為假扣押之強制執行，執行法院應如何處理？', '因執行程序已終結，故不論分配後有無餘額，均駁回丙之執行聲請', '通知丙不動產已非乙所有，應另具狀聲請執行賣得價金', '將價金依甲、丙之債權比例分配，丙部分並予提存', '將甲受償餘額分配給丙並予提存', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-056', '113-4301', 56, 'single_choice', 'An actor is negligent if, without excuse, he/she violates a statute that is designed to protect against the type of accident that the actor’s conduct causes, and if the accident victim is within the class of persons the statute is designed to protect. Such rule is usually called .', 'negligence ab initio', 'negligence bona fide', 'negligence per se', 'negligence non liquet', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-057', '113-4301', 57, 'single_choice', 'Peter signed a release for personal injury before he took a diving class but he was bitten by a sea snake under water. If Peter decides to sue the diving school, what is the strongest argument the school may raise against him?', 'self-defense', 'necessity', 'assumption of the risk', 'consent', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-058', '113-4301', 58, 'single_choice', 'The purpose of tort law is to provide relief for the victim for harm actually done, which is expressed in money terms, shall include replacement of property destroyed and reimbursement for medical expenses. Damages for these harm are called .', 'nominal damages', 'punitive damages', 'equitable remedies', 'compensatory damages', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-059', '113-4301', 59, 'single_choice', 'A(n) is an agreement made between two contracting parties to allow for the substitution of a new party for an existing one. The new party replaces the original contracting party as a party to the contract. The original party who is replaced gives up any rights it has against the other original party to the contract.', 'insolvent', 'novation', 'third-party beneficiary contract', 'delegation', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-060', '113-4301', 60, 'single_choice', 'is an amount of money agreed upon by both parties to a contract which one will pay to the other upon breaching the agreement or if a lawsuit arises due to the breach.', 'Installment', 'Liquidated damages', 'Incidental damages', 'Punitive damages', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-061', '113-4301', 61, 'single_choice', 'A(n) is an event, not certain to occur, which must occur, unless its non-occurrence is excused, before performance under a contract becomes due.', 'condition', 'predicament', 'contingency', 'accustom', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-062', '113-4301', 62, 'single_choice', 'Based on Taiwan’s Company Act, which of the following can be applied to the public company?', 'Multiple voting rights shares', 'Voting Agreement', 'Restrictions on the transfer of shares', 'No voting rights shares', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-063', '113-4301', 63, 'single_choice', 'The term as used in Taiwan’s Securities and Exchange Act means an explanatory written statement that an issuer provides to the general public for the purpose of offering or selling securities.', 'warranty', 'proxy statement', 'representation', 'prospectus', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-4301-064', '113-4301', 64, 'single_choice', 'A(n) is a person entering or remaining upon land in the possession of another without a privilege to do so created by the possessor’s consent or otherwise, who is not an invitee entering or remaining on the land upon an invitation.', 'business visitor', 'social guest', 'trespasser', 'offender', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-4301-065', '113-4301', 65, 'single_choice', 'Which of the following statements regarding search and seizure is correct?', 'A search warrant shall be issued on the basis of reasonable suspicion.', 'A seizure cannot be used for the purpose of confiscation.', 'A search warrant should be implemented by first issuing a subpoena duces tecum, if the subject does not comply with the subpoena, then a search warrant will be executed.', 'A search warrant shall particularly specify the places to be searched and the items or effects to be seized.', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-4301-066', '113-4301', 66, 'single_choice', 'Which of the following statements is INCORRECT with regard to property offenses?', 'A theft is when the perpetrator destroys the possessory interest of the property owner and intends to claim its entitlement.', 'If a person’s new house encroaches on his neighbor’s land, it is embezzlement.', 'A fraud is a crime of getting money or other illegal interests by deceiving or tricking other persons.', 'A person who uses violence, threats, drugs, hypnosis, or other means to cause the victim to be unable to resist and to take away property of another or cause him to hand it over for the purpose of exercising unlawful control over other’s property for himself or for a third person commits robbery.', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-4301-067', '113-4301', 67, 'single_choice', 'Congress and the states will be free, without any First Amendment , to criminalize speech soliciting violations of the vast range of administrative and regulatory laws that govern us today.', 'surety', 'sanction', 'scrutiny', 'surveillance', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-4301-068', '113-4301', 68, 'single_choice', 'According to the Constitutional Court Procedure Act, after exhaustion of all ordinary judicial remedies, any person who believes that a final court decision that finds against her or him contravenes the Constitution may lodge a petition with the Constitutional Court for a judgment declaring the decision unconstitutional. This proceeding is called a .', 'constitutional appeal', 'constitutional determination', 'constitutional complaint', 'constitituional interpretation', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-4301-069', '113-4301', 69, 'single_choice', 'A company produces a medication that is widely used to treat a certain medical condition. After a few years, patients who have taken the medication begin to report severe side effects, such as heart problems and kidney failure. It is later discovered that the medication was defective and the company knew about the defects but failed to warn patients or recall the product. If the patients want to file a tortious claim against the company, which of the following action is the most practical form to pursue such a claim?', 'A subrogation action', 'A class action', 'A shareholder derivative action', 'A medical malpractice action', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-4301-070', '113-4301', 70, 'single_choice', 'In a breach of contract case, which statement concerning burden of proof is INCORRECT pursuant to the Code of Civil Procedure?', 'The plaintiff bears the burden of proof to show that there is a contract existed between the parties.', 'The defendant bears the burden of proof to show that the contract has been rescinded when he or she claims so.', 'The plaintiff bears the burden of proof to show that the statute of limitations has not run out.', 'The defendant bears the burden of proof to show that there is an arbitration clause in the contract when he or she claims so.', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-1301-001', '113-1301', 1, 'single_choice', '下列何者非屬刑法第125 條濫權追訴處罰罪之實行行為？', '明知不應受理而受理刑事訴訟案件', '意圖取得供述而對被告施強暴脅迫', '濫用公務員之職權而為逮捕或羈押', '明知為有罪之人而無故不使其受追訴或處罰', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-1301-002', '113-1301', 2, 'single_choice', '有關公務員之解釋，依實務見解，下列敘述何者錯誤？', '國立大學教授接受民間委託或補助執行研究計畫，並參與相關採購事務，就所參與之採購事務，為 刑法上之公務員', '依政府採購法規定之各公營事業之承辦、監辦採購等人員，為「授權公務員」', '委託公務員，必須以受國家、地方自治團體所屬機關依法律、法律授權之法規命令、職權命令、自 治條例、自治規則、委辦規則或其他對多數不特定人民就一般事項所作對外發生法律效果之規定， 從事與委託機關權限有關之公共事務者為其要件', '身分公務員，不限制其任用方式係出於考試晉用、選舉產生、約聘僱用或政治任命，或其任用身分 及時間久暫，凡有法令依據而服務於國家或地方自治團體而具有法定職務權限者，均屬之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-1301-003', '113-1301', 3, 'single_choice', '甲對乙居住之透天厝的木門潑灑汽油並點火，木門被燒壞之後火勢隨即熄滅，並未繼續延燒。下列敘 述何者正確？', '木門雖係附連於透天厝之物，然僅燒壞木門仍構成毀損建築物罪', '燒壞之木門為透天厝之重要部分，甲構成刑法第173 條第1 項放火既遂罪', '甲所為僅為放火燒燬透天厝之預備行為，成立刑法第173 條第4 項放火預備罪', '甲並未使透天厝喪失其效用，因此成立刑法第173 條第3 項放火未遂罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-1301-004', '113-1301', 4, 'single_choice', '甲懷疑配偶乙有外遇，於是在乙的車上裝設衛星定位系統（GPS）追蹤器，錄下並分析比對其車輛移 動的位置訊息，以掌握乙的行蹤，依實務見解，下列何者錯誤？', '衛星定位系統追蹤器屬於刑法第315 條之1 第1 款之工具與設備', '由於車輛在公開環境中行走，故車輛移動位置之資訊屬於公開活動', '甲以追蹤器錄下乙所在位置資訊之行為屬於竊錄行為', '依近期實務判決，甲懷疑配偶有外遇而竊錄其行蹤之行為，不是正當理由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-1301-005', '113-1301', 5, 'single_choice', '甲與乙素有嫌隙，一日見乙在路上閒晃，遂出手毆打乙，乙遭毆後大驚，即轉身要逃，卻不小心掉落 路邊施工坑洞，導致乙身上除了被甲所毆之身體挫傷之外，右腳小腿還因此粉碎性骨折而截肢。依實 務見解，下列敘述何者正確？', '乙轉身要逃，自己不小心掉落路邊施工坑洞，應屬被害人乙自我負責之行為，甲僅就毆打乙頭部之 挫傷負刑法第277 條第1 項普通傷害罪之責', '乙右腳僅小腿骨折而截肢，不符合刑法第10 條第4 項第4 款規定「毀敗或嚴重減損一肢以上之機 能」之重傷', '甲對於乙受毆逃跑掉落坑洞而右腳截肢之結果，應具有客觀預見可能性，甲應負刑法第277 條第2 項後段傷害致重傷罪之責', '乙之截肢結果並非源自頭部挫傷之加重後果，故不成立刑法第277 條第2 項後段傷害致重傷罪之責', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('113-1301-006', '113-1301', 6, 'single_choice', '有關過失犯敘述，依實務見解，下列何者錯誤？', '在判斷醫療過失時，不得一律以醫學中心之醫療水準為判斷標準', '他人之交通違規事實已極為明顯，且行為人有充足時間可避免發生交通事故時，行為人即不能主張 信賴原則免責', '由於醫師在進行手術前，可信賴護理師已先正確確認患者人別，故即使主刀醫師開刀前未再核對患 者之身分，而對錯誤之患者開刀時，醫師也不用負過失傷害之責任', '在過失不作為犯的情形，依實務見解，過失犯的注意義務和不作為犯的作為義務屬於不同層次問題， 不得混為一談', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-1301-007', '113-1301', 7, 'single_choice', '關於「得被害人之承諾」作為超法規阻卻違法事由，下列敘述何者正確？', '被害人之承諾能力，不以民法上之行為能力為標準，而是依個案之認識與判斷能力而定', '被害人因受行為人詐欺而為承諾者，承諾之效力未定，被害人得事後選擇撤銷或不撤銷其承諾', '被害人得承諾放棄的法益，除個人法益之外，尚可包含社會法益', '基於個人自主權之尊重，得被害人承諾之範圍可包括生命法益', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-1301-008', '113-1301', 8, 'single_choice', '某行政機關科長甲，因涉嫌偽造文書，經檢察官偵查。對此，甲供稱，當時直屬長官乙命令自己實行 該行為，甲雖明知自己偽造文書，但無奈乙宣稱會負責一切責任，甲不得已只好照辦。經查，甲所述 屬實，下列敘述何者正確？', '甲得主張依所屬上級公務員命令之行為，阻卻違法', '甲得主張無期待可能性，阻卻責任', '乙是偽造文書罪的間接正犯', '乙是偽造文書罪的教唆犯', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-1301-009', '113-1301', 9, 'single_choice', '有關刑法第16 條規定，依實務見解，下列敘述何者正確？', '第16 條之規定係專指行為人自認其行為存在與阻卻違法事由相關之事實，故其行為合法而言', '若行為人對行為是否涉及不法有所懷疑，必要時有向具有專業能力之人或機構等查詢之義務', '第16 條之規定，是對於行為人不知法律之情形，區分不同法律效果，僅有行為人對於違法性錯誤 無正當理由而屬可避免者，始應免除其刑事責任', '誤想犯有第16 條規定之適用', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-1301-010', '113-1301', 10, 'single_choice', '有關自首之敘述，依實務見解，下列何者錯誤？', '甲開車不慎撞傷某乙，於犯罪尚未被偵查機關發覺前，向到場處理之員警表明確係其開車撞傷乙， 但辯稱自己完全無過失，事故發生均是乙的過失。則甲因未承認犯罪，不能認有自首之適用', '甲犯具有想像競合關係之A、B 二罪（B 罪法定刑較重），其於偵查機關已發覺A 罪後，另向偵查 機關申告尚未被發覺的B 罪亦係其所為，則B 罪部分仍有自首之適用', '甲向偵查機關申告尚未被發覺之犯罪後，隨即逃匿無蹤，經發布通緝後始到案，則甲並無自首之適用', '甲就未發覺之罪，原想親自至地方檢察署自首，但因恐即遭檢察官向法院聲請羈押，遂先委由友人 乙至地方檢察署聲明該案為甲所為，以及其欲自首之意，甲雖委託乙代行自首之意，仍有自首之適用', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-1301-011', '113-1301', 11, 'single_choice', '有關現行實務採「相對總額原則」之利得沒收，下列何者屬司法院憲法法庭111 年憲判字第18 號判 決之內容？', '不受罪刑法定原則拘束', '沒收之目的除欲制裁個人犯罪行為外，亦欲回復犯罪前之合法財產秩序', '對違法交易所生犯罪所得之沒收須先扣除所有犯罪成本', '非善意第三人得對沒收新制實施前之應沒收之物主張信賴保護', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-1301-012', '113-1301', 12, 'single_choice', '關於刑法第195 條偽造貨幣罪，依實務見解，下列敘述何者錯誤？', '外國貨幣雖然在國內具有流通力，但不具有強制流通力，因此不屬於本罪之通用貨幣', '偽造幣券需以摹擬真正幣券以為製造，若偽造出事實上不存在的通貨，則非偽造行為', '偽造係指無通用貨幣發行權者製作假幣券之行為，縱偽造技術拙劣，不足以使一般人誤信為真幣， 仍屬偽造行為', '本罪所謂「意圖供行使之用」係指意圖將偽造變造之貨幣充作真正加以流通者而言，若僅將之作為 拍戲道具使用者，非屬之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('113-1301-013', '113-1301', 13, 'single_choice', '有關易科罰金，下列敘述何者錯誤？', '易科罰金應於裁判確定後2 個月內完納，但依其經濟或信用狀況，不能於2 個月內完納者，得許期 滿後1 年內分期繳納', '易科罰金應依行為人個人平均每日所得之數額，折算1 日', '甲犯刑法第335 條第1 項侵占罪，受2 月有期徒刑之宣告，得易科罰金', '甲犯刑法第339 條第1 項詐欺取財罪，受6 月有期徒刑之宣告，得易科罰金', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-1301-014', '113-1301', 14, 'single_choice', '甲為立法委員，在承諾民間廠商幫助其取得和國營企業的契約後，利用其身分的影響力對國營企業關 說，國營企業迫於壓力，於是和該民間廠商訂約，甲因此接受廠商提供的性招待，依實務見解，下列 敘述何者錯誤？', '甲屬於刑法第10 條第2 項之公務員', '性招待屬於賄賂罪之不正利益', '甲利用身分影響力的行為不該當賄賂罪的職務上行為', '性招待與關說行為之間具有對價關係', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-1301-015', '113-1301', 15, 'single_choice', '甲遭起訴犯殺人罪，其辯護人乙向甲陳稱，甲之案件受命法官丙是大學同窗，可代為行賄關說，為甲 爭取無罪判決。甲聽信於乙，遂交付新臺幣（下同）100 萬元現金給乙。乙則私下拜訪丙，並交付給 丙50 萬元現金，請託丙判甲無罪。丙收取50 萬元現金後，當場承諾會判甲無罪。然在經審理程序 後，丙認為甲的案件完全沒有判決無罪的可能性，遂又請人將50 萬元現金返還給乙。乙收回此50 萬 元現金後，並未告知甲此一情事。甲隨後遭依法判處有罪，始檢舉乙與丙二人。下列敘述何者正確？', '甲實行之行為為交付乙現金，實際實行行賄行為之人為乙，故甲之行為並不構成行賄罪', '丙收取50 萬元現金後又返還給乙，難認賄款業已收受，故不構成公務員受賄罪', '乙雖非為自己行賄，而係代甲向丙交付賄款，以求對甲為無罪判決，其行為仍構成行賄罪', '丙於收受50 萬元現金作為判決甲無罪之對價、承諾判決無罪時，即已構成濫權不追訴罪，後續丙 又依法對甲判處有罪，僅影響該罪之量刑', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-1301-016', '113-1301', 16, 'single_choice', '關於貪污治罪條例第6 條第1 項第4、5 款之公務員圖利罪，依實務見解，下列敘述何者錯誤？', '關於主管或監督事務圖利罪之主管或監督事務，應依各機關的組織法規或相關法令予以認定', '公務員與圖利之對象仍有成立圖利罪之共同正犯的可能', '主管或監督事務圖利罪和非主管或監督事務圖利罪之違背法令應做相同解釋', '不管是主管或監督事務圖利罪和非主管或監督事務圖利罪，均以獲得利益為必要', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-1301-017', '113-1301', 17, 'single_choice', '關於侵害國家權力運作法益的犯罪敘述，依實務見解，下列何者錯誤？', '刑法第161 條第2 項以強暴脅迫脫逃之罪為第135 條妨害公務罪之特別規定，於該當二者之構成要 件時，應直接適用前者', '妨害公務罪，以公務員依法執行職務時加以妨害為要件，若超越職務範圍以外之行為，即不得謂為 依法執行職務', '刑法第143 條所謂有投票權之人，包括收賄時尚不具投票資格，但收賄後獲得投票權而得履行期約 事項之人', '刑法第131 條圖利罪所謂直接或間接圖自己或其他私人不法利益，僅指一切有形增加之財產數額， 不包括法律上應減少而未減少之利益', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-1301-018', '113-1301', 18, 'single_choice', '犯人甲為逃避刑罰，躲藏數日後，去找其兄乙哭訴；乙自幼愛護甲，知悉情形後，安排甲躲藏於住家 密室。下列敘述何者正確？', '甲為了逃避刑罰而自行藏匿，屬於自我庇護行為，不成立藏匿人犯罪；乙為甲的近親，藏匿甲為人 之常情，法律不強人所難，故不成立犯罪', '甲為了逃避刑罰而自行藏匿，雖屬於自我庇護行為，但仍成立藏匿人犯罪；乙為甲的近親，藏匿甲 為人之常情，法律不強人所難，故不成立犯罪', '甲為了逃避刑罰而自行藏匿，屬於自我庇護行為，不成立藏匿人犯罪；乙為甲的近親，藏匿甲為人 之常情，雖成立藏匿人犯罪，但依法減免處罰', '甲為了逃避刑罰而自行藏匿，雖屬自我庇護行為，但仍成立藏匿人犯罪；乙為甲的近親，藏匿甲為 人之常情，雖成立藏匿人犯罪，但依法減免處罰', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('113-1301-019', '113-1301', 19, 'single_choice', '甲、乙、丙三人因夜市擺攤糾紛，毆打隔壁攤位的丁，使丁受到輕傷，但並未波及其他攤位或周邊居 民，正在巡邏的警察戊剛好在夜市裡購買晚餐，聽到有吵鬧聲及警網通報前往處理時，甲、乙、丙因 害怕被逮捕，一起將圓凳砸向戊之後，拔腿就跑。依實務見解，甲、乙、丙可能構成下列何罪？', '刑法第135 條第1 項妨害公務罪', '刑法第150 條第1 項妨害秩序罪', '刑法第161 條第1 項脫逃罪', '刑法第283 條聚眾鬥毆罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-020', '113-1301', 20, 'single_choice', '下列公共危險行為與可能成立之刑法罪名間的對應，何者錯誤？', '通勤時間在公路上競速飆車：第185 條第1 項損壞壅塞道路罪', '在行進中之火車上引爆炸彈致火車損壞脫軌：第184 條第1 項損壞軌道罪', '放火燒燬路旁停放之情敵機車，且波及兩旁的車：第175 條第1 項放火燒燬他人所有物罪', '因過失致自己持有區分所有權且使用中的住家大樓被燒燬：第173 條第2 項失火燒燬現供人使用住 宅罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-021', '113-1301', 21, 'single_choice', '依我國實務見解，有關偽造文書罪，下列敘述何者錯誤？', '變更真正文書之製作人為自己，係屬偽造', '無製作權之人冒用他人名義製作文書，係屬偽造', '以他人名義製作文書，如行為人基於名義人之授權而有製作之權，即不成立偽造文書罪', '會議記錄人員以自己之名義作成會議紀錄，如內容涉及不實，除構成刑法第215 條業務登載不實 罪，亦構成偽造私文書罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-022', '113-1301', 22, 'single_choice', '小學教師甲利用自己的身分，告訴其13 歲的學生乙如果想要考試加分，就與其性交，乙受到引誘， 所以同意了甲的要求。依照實務見解，在討論各種競合可能性之後，甲應論以何罪？', '強制性交罪', '乘機性交罪', '利用權勢性交罪', '對於未滿14 歲之男女為性交罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-023', '113-1301', 23, 'single_choice', '依實務見解，下列何種情形中，甲之行為構成刑法第221 條之強制性交罪？', '醫師甲為女病患乙手術時，趁乙麻醉後昏迷時，當場見色心喜，以其手指插入乙之陰道滿足自己性慾', '神棍甲告知前來問卦之乙女，若不與其性交，將被小鬼纏身，乙信以為真，任由甲以陰莖插入乙之 陰道', '甲以手指沾上自己之精液，強行插入乙女之口腔內', '甲女強行以其舌頭插入乙男之口腔，欲與乙男舌吻', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-024', '113-1301', 24, 'single_choice', '有關妨害風化罪章，下列敘述何者錯誤？', '公然為猥褻行為，如非出於供人觀覽之意圖，即不成立公然猥褻罪', '於賓館性交易時為嫖客脫衣陪酒，不構成公然猥褻罪', '意圖營利而公然為猥褻行為者，成立加重公然猥褻罪', '公然陳列或播放猥褻影像者，成立公然猥褻罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-025', '113-1301', 25, 'single_choice', '有關刑法第240 條、第241 條和誘、略誘罪之敘述，依實務見解，下列何者錯誤？', '甲欲與A 性交，乃將A 略誘帶至某旅館，甲隨即請知情的B 代為看管A，B 乃依甲的指示看管A， 因略誘行為已結束，B 不會與甲成立略誘罪之共同正犯', '母親意圖使未滿7 歲之子女脫離父親親權之行使，而未經父親同意，將該子女帶往他地以阻隔父親 行使親權者，仍可能成罪，不因母親同有親權而受影響', '甲在略誘A 的期間中，因A 想要逃跑，甲遂出言恐嚇：「如果你敢跑走，我會揍你」，甲不會另外 成立恐嚇罪', '所謂和誘，係指被誘人知拐誘之目的而予同意者而言；如果違反被誘人之意思，而將其置於自己實 力支配之下，則為略誘', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-026', '113-1301', 26, 'single_choice', '有關賭博罪章，下列敘述何者錯誤？', '於自家住宅等非公眾得出入之處所賭博，不成立刑法第266 條之犯罪', '年節時與家人小賭怡情，即使公然為之，亦不成立犯罪', '以網際網路方式賭博財物，不成立犯罪', '提供自家住宅供人賭博，意圖借抽頭賺取利益者，成立犯罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('113-1301-027', '113-1301', 27, 'single_choice', '關於傷害罪，依實務見解，下列敘述何者正確？', '刑法第278 條「重傷」之標準，乃是以傷害初始之檢驗狀況為準', '若聚眾鬥毆時，在場助勢之人與實行傷害行為之行為人間有犯意聯絡和行為分擔時，才能成立聚眾 鬥毆罪', '刑法第286 條之凌虐行為不以長期性、持續性、多次性為必要', '殺人罪與傷害致死罪之間，以受傷處是否為致命部位為其區別基準', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-1301-028', '113-1301', 28, 'single_choice', '有關妨害自由罪章之敘述，下列何者錯誤？', '甲因乙擋其財路，遂郵寄含有子彈之郵包予乙，成立刑法第305 條恐嚇危安罪', '甲乙鄰居發生爭執，甲氣不過，遂大罵乙「我詛咒你不得好死」，成立刑法第305 條恐嚇危安罪', '警員甲持偽造公文書向檢察官乙騙取拘票，拘提丙，導致丙因受訊問，歷經一日始獲諭知請回，就 自由法益之保護，甲成立刑法第134 條、第302 條第1 項公務員假借職務上之方法剝奪他人行動自 由罪', '甲趁乙洗澡時，將其衣物取走，使乙無法離開澡堂，成立刑法第302 條剝奪他人行動自由罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-1301-029', '113-1301', 29, 'single_choice', '有關刑法誹謗罪之敘述，依實務見解，下列何者錯誤？', '依司法院釋字第509 號解釋，行為人雖不能證明言論內容為真實，但依其所提證據資料，認為行為 人有相當理由確信其為真實者，仍不能以誹謗罪論處', '刑法上的誹謗罪跟公然侮辱罪雖均足以使他人之社會評價受到損害，但「誹謗」乃是針對具體事實 為指摘或傳述；而「侮辱」則是抽象謾罵或嘲弄', '本於憲法平等原則，行為人就其所指摘之事，不論是茶餘飯後閒談聊天之資或利用記者會傳播，查 證義務均應相同，而無高低之分', '甲於1 月1 日在A 所居住的大樓大廳張貼誹謗A 之大字報，且一直到該年底均未撕下，A 在甲張 貼當日即見聞此事，但遲至同年10 月1 日始提告訴，雖然誹謗的文字圖畫繼續存在，A 之提告已 逾告訴期間', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-1301-030', '113-1301', 30, 'single_choice', '有關妨害性自主罪章，依實務見解，下列敘述何者錯誤？', '對未滿7 歲之人為性交，一律成立刑法第222 條第1 項加重強制性交罪', '對7 歲以上未滿14 歲之人為合意性交，成立刑法第227 條第1 項與幼年人性交罪', '行為人明知被害人酒量不佳，故意對被害人灌酒，使其泥醉而陷入意識模糊狀態，進而與之性交， 成立刑法第225 條第1 項乘機性交罪', '甲、乙共謀對丙為強制性交，約定由甲壓制丙，由乙對丙為性交行為，甲、乙皆成立刑法第222 條 第1 項加重強制性交罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-1301-031', '113-1301', 31, 'single_choice', '成年人甲、乙、丙與13 歲的丁共同謀議進入某豪宅行竊，其中甲負責竊盜的謀議與計畫，而僅由乙、 丙、丁前往現場行竊。犯罪當日，甲在家中等待，乙、丙、丁前往目標現場，由乙負責在豪宅門口把 風，丙、丁則入內行竊，於竊得大筆財物後，坐上乙接應的車輛離去，並回到甲家中由四人均分所得 贓款。本案關於是否符合刑法第321 條第1 項第4 款「結夥三人以上」加重竊盜罪，依實務見解，下 列敘述何者錯誤？', '甲應計入結夥人數', '乙應計入結夥人數', '丙應計入結夥人數', '丁應不計入結夥人數', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-1301-032', '113-1301', 32, 'single_choice', '有關甲之行為，依實務見解，下列何者不構成刑法第332 條強盜結合罪？', '甲為避免其所竊得之物遭被害人乙奪回，在行竊當場將乙殺死', '甲壓制乙，欲對乙為性交卻未果，憤而起意拔取乙配戴的鑽石戒指，據為己有', '甲在強盜乙的財物後，立即縱火燒燬乙的鄰居丙所有房屋以轉移眾人焦點，而得以順利逃離現場', '甲強押乙至山區後，壓制乙並從乙身上奪取皮夾與金項鍊，其後又為避免遭乙指認而持刀刺瞎乙雙眼', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('113-1301-033', '113-1301', 33, 'single_choice', '甲至市集購買蔬果，見乙蕃茄攤販正進行蕃茄裝箱促銷活動，分別有裝滿新臺幣（以下同）360 元與 600 元兩種蕃茄價格，甲見乙忙碌，遂偷將高價蕃茄先裝進箱子，最後將低價蕃茄鋪於表面，乙結帳 時並未察覺，即以360 元計價。依實務見解，甲應論以何罪？', '竊盜罪', '搶奪罪', '強盜罪', '詐欺罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-034', '113-1301', 34, 'single_choice', '下列敘述甲透過犯罪所取得者，何者無法成為刑法第349 條第1 項贓物罪的行為客體？', '甲順手從路邊牽走未上鎖之A 所有腳踏車', '甲持槍至銀樓壓制老闆A 後取得的金項鍊', '甲綑綁並毆打遲不還款的債務人A，A 因而轉帳返還所欠款項', '甲謊稱A 所持有的真正古董花瓶為贗品，並要求A 贈與該花瓶給自己，A 信以為真，乃將該花瓶 贈與甲', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-035', '113-1301', 35, 'single_choice', '甲教唆友人乙，趁鄰居丙上班時前往丙家偷竊財物，乙乃聽從其建議，於某日侵入住宅竊取相機、電 腦，乙於得手後，將相機贈送甲以表達感謝，甲決定收下該相機。依實務見解，甲之刑責為何？', '甲僅成立刑法第349 條第1 項收受贓物罪', '甲成立刑法第321 條第1 項加重竊盜罪之教唆犯', '甲成立刑法第321 條第1 項加重竊盜罪之教唆犯與收受贓物罪，二罪數罪併罰', '甲成立刑法第321 條第1 項加重竊盜罪之教唆犯與收受贓物罪，二罪想像競合', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-036', '113-1301', 36, 'single_choice', '關於卷證獲知之敘述，下列何者正確？', '被告於審判中得檢閱卷宗及證物並得抄錄、重製或攝影', '被告之代理人於審判中不得檢閱卷宗及證物，亦不得抄錄、重製或攝影', '告訴人之代理人於審判中不得檢閱卷宗及證物，亦不得抄錄、重製或攝影', '自訴人之代理人於審判中得檢閱卷宗及證物並得抄錄、重製或攝影', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-037', '113-1301', 37, 'single_choice', '甲涉嫌投票受賄罪，收受1,000 元賄賂，承諾會支持特定候選人。甲因家境清寒，在檢察官偵查階段 並未選任辯護人，下列敘述何者錯誤？', '若甲為低收入戶，當其向檢察官聲請指定辯護時，檢察官應通知法律扶助機構指派律師辯護', '若甲為原住民時，檢察官應通知法律扶助機構指派律師辯護', '若甲因身心障礙，致無法為完全之陳述時，檢察官應通知法律扶助機構指派律師辯護', '若檢察官聲請羈押甲，審判長應指定公設辯護人或律師為甲辯護', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-038', '113-1301', 38, 'single_choice', '司法警察（官）因調查犯罪情形及蒐集證據之必要，得使用通知書，通知犯罪嫌疑人到場接受詢問。 下列敘述何者錯誤？', '通知書之記載，如同拘票應記載事項，包含無正當理由不到場者，得命拘提', '若司法警察（官），因情況急迫而有必要時，臨時以電話、親自登門或其他方式，告知案由後請犯 罪嫌疑人到場接受詢問，亦屬合法', '司法警察（官）使用通知書，通知犯罪嫌疑人到場詢問，不具直接強制效果，犯罪嫌疑人得依其自 由意思決定是否到場接受詢問，或到場後隨時均可自由離去', '犯罪嫌疑人收到通知書到場接受詢問後，縱其身心未受拘束，司法警察（官）仍應依刑事訴訟法第 95 條第1 項踐行告知義務', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-039', '113-1301', 39, 'single_choice', '關於拘提之敘述，下列何者錯誤？', '拘票應備二聯，執行拘提時，應以一聯交被告或其家屬', '司法警察或司法警察官如非必要，不得於管轄區域外執行拘提', '司法警察官或司法警察偵查犯罪時，因線民供述，認為有事實足認為共犯嫌疑重大者，即得逕行拘 提之', '拘提，由司法警察或司法警察官執行，並得限制其執行之期間', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-040', '113-1301', 40, 'single_choice', '甲毆打乙之配偶丙，經警當場以現行犯逕行逮捕，甲供出受乙教唆，警方通知後乙拒絕到場說明。依 實務見解，下列敘述何者正確？', '乙係教唆甲實施傷害罪之現行犯，警方得逕行逮捕之', '乙被甲指為教唆犯罪者，係準現行犯，警方得逕行逮捕之', '乙教唆甲犯告訴乃論之罪，犯告訴乃論之罪之人，不得以現行犯逕行逮捕', '乙不得依現行犯或準現行犯逕行逮捕', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('113-1301-041', '113-1301', 41, 'single_choice', '偵查中，檢察官向法院聲請羈押殺人案件之被告甲。下列敘述何者正確？', '法院訊問甲後，僅因認其涉犯殺人罪嫌重大，非予羈押顯難進行追訴，即裁定羈押', '檢察官請求法院限制或禁止甲及其辯護人獲知卷證時，應到場敘明理由，並指明限制或禁止之範圍， 以維護甲在訴訟上的防禦權', '法官訊問甲時，檢察官應到場陳述聲請羈押理由及提出必要證據', '法官訊問甲時，原則上毋庸辯護人在場', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-1301-042', '113-1301', 42, 'single_choice', '甲因販賣毒品案件遭到通緝，被警員乙於實施臨檢時緝獲，於逮捕之際，乙對甲之身體、衣物等處進 行搜索。在此過程中，乙聽聞甲自稱其小客車停在約五百公尺外的停車場，乙遂將甲上銬並搭上警車， 帶往該停車場欲搜索甲之小客車。關於甲可否拒絕乙搜索其小客車，下列敘述何者正確？', '不得拒絕。此為甲所使用之交通工具，依法乙得實施附帶搜索', '不得拒絕。甲仍有可能將犯罪相關物證藏匿於車上，有附帶搜索之必要', '可以拒絕。因為該小客車不在逮捕之現場，且非甲可立即觸及之處所，不符合附帶搜索之要件', '可以拒絕。因為甲並非因現行犯逮捕，不得為附帶搜索', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-1301-043', '113-1301', 43, 'single_choice', '司法警察官乙因接獲線報指稱甲於自宅內經營賭場，遂帶隊前往一探究竟。抵達甲宅後，按門鈴並出 示證件、告知來意，取得甲之同意後，乙帶隊進入其住宅內搜索。雖查無經營賭場之相關事證，惟在 離去前，乙瞥見甲之窗戶花檯上種有多株大麻，遂將該批植物予以扣押。關於搜索、扣押等作為，下 列敘述何者正確？', '扣押大麻植栽之作為，係屬「另案扣押」', '先前經同意之搜索既已結束，則不得再為任何搜索或扣押，此舉為違法搜索、違法扣押', '司法警察官未持搜索票，屬無令狀之搜索，故不得為另案扣押', '種植大麻之部分，既未發動偵查也未經起訴，則無扣押之必要性', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-1301-044', '113-1301', 44, 'single_choice', '依實務見解，下列何種情形下取得之證據，不適用刑事訴訟法第158 條之4 權衡法則？', '審判長違反刑事訴訟法第186 條第2 項之拒絕證言權告知義務', '犯罪嫌疑人身心未受拘束之情形下，司法警察違反刑事訴訟法第95 條之告知義務', '司法警察詢問受拘提、逮捕之被告，無辯護人之被告表示已選任辯護人，司法警察未立即停止詢問', '法院違法未通知當事人及辯護人於勘驗時到場', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-1301-045', '113-1301', 45, 'single_choice', '甲、乙兩人共同闖入便利商店行搶，案經檢察官提起公訴，下列敘述何者正確？', '審理過程中，店員證稱：「案發當時，聽到共犯一人高喊甲的名字，催促離開」。若以店員供述證明 當時呼叫之對象為甲，乃屬傳聞證據', '審理過程中，甲之友人證稱：「甲曾請託其作偽證稱：案發時甲在其住處睡覺」。若以甲之友人之供 述作為甲不在場係屬虛偽之證明，乃屬傳聞證據', '審理過程中，乙之友人證稱：「乙曾邀約：一起到該便利商店行搶」。若以乙之友人供述證明乙曾邀 約共同犯案，乃屬傳聞證據', '審理過程中，乙證稱：「案發當時，甲曾向店員喊：拿錢來，不然砍下去喔」。若以乙之供述證明甲 脅迫店員，非屬傳聞證據', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-1301-046', '113-1301', 46, 'single_choice', '受命法官於準備程序，就檢察官聲請調查之被告甲之警詢自白，未訊問甲有關該份筆錄的證據能力之 意見，甲也未主動表示意見。甲於審判程序才抗辯該份警詢自白係出於刑求所致，並提出驗傷單為證。 依實務見解，法院對甲之抗辯是否應依職權調查？', '否。當事人關於證據能力之意見，應於準備程序表示；甲遲至於審判程序才提出抗辯，發生失權效， 法院毋庸依職權調查', '是。甲主張警詢自白係出於刑求，並已提出驗傷單為證，依刑事訴訟法第163 條第2 項但書，法院 為發現真實並維護被告之利益，自應依職權調查', '否。有關刑求抗辯之調查，屬於檢察官之舉證責任事項，而非法院職權調查事項', '是。但法院得於調查其他犯罪事實之證據後再行調查', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('113-1301-047', '113-1301', 47, 'single_choice', '甲駕車搭載前未婚妻乙返家途中肇事逃逸，警方通知乙作證，詢問時未命其具結，亦未告知得拒絕證 言，乙遂詳細說明案發經過。審判中，檢察官以乙之警詢筆錄舉證甲有罪，甲之辯護人聲請法院傳喚 乙作證，乙到庭後卻表示記憶已經模糊了，不太記得甲有無肇事。法院遂以乙之警詢筆錄作為認定甲 有罪之證據之一，依實務見解，其採證是否合法？', '不合法。因為員警未命乙具結，警詢筆錄無證據能力', '不合法。因為員警未告知乙得拒絕證言，警詢筆錄無證據能力', '合法。因為員警詢問乙之程序合法，且其陳述出於真意，相對於審判中之不一致陳述，其警詢陳述 經證明具有較可信之特別情況，故有證據能力', '合法。因為員警詢問乙之程序合法，且其陳述出於真意，乙到庭後無正當理由拒絕陳述，警詢筆錄 即有證據能力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-1301-048', '113-1301', 48, 'single_choice', '甲對乙提出傷害罪之告訴，惟檢察官偵查終結作成不起訴處分，甲不服聲請再議，惟遭上級檢察機關 以無理由駁回。關於甲對此請求救濟之敘述，下列何者正確？', '甲可以直接向管轄法院提起自訴', '甲可以在接受上開再議駁回之處分書後10 日內，委任律師提出理由狀，向管轄第一審法院聲請准 許提起自訴', '此時不起訴處分已經確定，甲在現行法之下，並無任何救濟管道', '再議駁回之處分，性質上屬於行政處分之一，得以訴願之方式救濟之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-1301-049', '113-1301', 49, 'single_choice', '甲因涉嫌與跨國境詐欺集團之人共犯加重詐欺、洗錢等罪嫌，已被羈押。甲之辯護人與甲接見時，替 甲傳遞教其他人避罪的紙條予詐欺集團之人。檢察官認此有串證之虞，是否可直接命令看守所限制辯 護人與羈押之被告甲接見或互通書信？', '可以，檢察官偵查中對此有強制處分權', '原則上不可以，檢察官必須向法院聲請核發限制書，但遇有急迫情形時，得先為必要之處分，並應 於24 小時內聲請該管法院補發限制書', '原則上不可以，檢察官必須向法院聲請核發限制書，但遇有急迫情形時，得先為必要之處分，並應 於3 日內聲請該管法院補發限制書', '一律不可以，檢察官僅得向法院聲請核發限制書', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-1301-050', '113-1301', 50, 'single_choice', '甲向法院自訴乙對其涉有刑法第339 條第1 項之詐欺取財罪嫌，法院審理中，甲具狀撤回對乙之自 訴，法院應如何處理，下列敘述何者正確？', '認撤回合法，為不受理判決', '認撤回合法，以行政報結，並由書記官將撤回自訴事由通知被告', '認撤回不合法，繼續審理', '認撤回不合法，以裁定駁回', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-1301-051', '113-1301', 51, 'single_choice', '檢察官從報上得知甲接受專訪時表示曾於10 年前，因不堪乙苦苦哀求，幫一心尋死的乙注射毒藥， 檢察官於簽准分案後，命檢察事務官進行案情分析及擬定偵查策略，乙之妻丙亦在報紙得知上開消息 後，立即委請律師向法院提起自訴甲犯加工自殺罪。下列敘述何者正確？', '丙非犯罪之直接被害人，依法不得提起自訴', '本件已開始偵查，丙依法不得提起自訴', '甲所涉及之加工自殺罪係已得乙之囑託，且乙之遺書亦清楚表示「不得為難甲」，故丙因不得與乙 明示之意思相反，而不得提起自訴', '本件檢察官雖已得知有犯罪嫌疑，命檢察事務官進行相關案情分析，尚未開始偵查，故丙雖提起自 訴在後，仍得為之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('113-1301-052', '113-1301', 52, 'single_choice', '甲涉犯過失傷害罪嫌，經檢察官偵查終結，為緩起訴處分，緩起訴期間2 年。依實務見解，下列敘述 何者正確？', '檢察官命被告向公庫支付一定金額，須得被告之同意', '檢察官命被告向被害人道歉，須得被害人同意', '緩起訴期間屆滿後，未經撤銷時，本案仍無實質確定力', '緩起訴期間，被害人得提起自訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-1301-053', '113-1301', 53, 'single_choice', '法院依據國民法官法完成審理程序後，進入評議階段，經職業法官與國民法官針對案情進行討論後， 經評議有罪者五票（含一票職業法官），無罪者四票（含兩票職業法官）。此時合議庭應如何處理？', '應為無罪判決', '適用國民法官法之案件均為重大刑事案件，合議庭應為一致決', '審判長應向國民法官提示審理過程中之特定重要證據，請國民法官重新審酌', '因有罪認定已取得多數票，且包括一名職業法官，因此審判長可以結束評議程序，並由合議庭作成 有罪判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-1301-054', '113-1301', 54, 'single_choice', '下列何種情形，被告未到庭，法院不得逕行審判？', '被告心神喪失或因疾病不能到庭，顯有應諭知無罪或免刑判決之情形', '應諭知有期徒刑之適用簡式審判程序案件', '法院認為應科拘役、罰金或應諭知免刑或無罪之案件，被告經合法傳喚無正當理由不到庭者', '最重本刑為拘役或專科罰金之罪得僅由代理人到庭之案件', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-1301-055', '113-1301', 55, 'single_choice', '對於法院形式判決之敘述，依實務見解，下列何者錯誤？', '通姦罪判決確定後，通姦罪經大法官解釋宣告違憲並自宣示之日起失其效力，檢察總長就原因案件 提起非常上訴，最高法院應諭知免訴', '個案非屬我國刑法適用法效力範圍時，法院應諭知不受理', '無管轄權之自訴案件，應諭知管轄錯誤，並同時諭知移送於管轄法院', '免訴、不受理與管轄錯誤之判決，得不經言詞辯論為之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-1301-056', '113-1301', 56, 'single_choice', '行合議審判之案件，審判長指定一人為受命法官行準備程序，下列關於準備程序受命法官得為訴訟行 為之敘述，何者錯誤？', '詢問檢察官起訴範圍及是否要變更起訴法條', '被告主張警詢自白係遭警察刑求，受命法官遂於準備庭中勘驗被告於警詢中之錄音光碟', '被告主張證人警詢筆錄為傳聞證據無證據能力，受命法官當庭裁定證人警詢筆錄無證據能力，並曉 諭檢察官聲請傳喚證人到庭', '被告經合法傳喚無正當理由不到庭者，受命法官仍可對到庭之人行準備程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-1301-057', '113-1301', 57, 'single_choice', '辯護人於準備程序向法院聲請於審判期日調查證人甲後，法院得知甲將於近日被派往倫敦分公司任 職，應無法於審判期日出庭。下列敘述何者正確？', '法院應駁回調查證人甲之聲請', '法院逕行傳喚甲，並不待當事人到場直接訊問', '法院不傳喚甲，直接以偵查中筆錄作為書證，於審判期日調查之', '法院得於審判期日前先行訊問甲，並應行交互詰問程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-1301-058', '113-1301', 58, 'single_choice', '檢察官起訴被告於民國109 年間同時持有A、B 二把改造手槍，涉想像競合犯非法持有手槍1 罪嫌。 第一審法院判決被告持有A 槍有罪，持有B 槍部分則於理由內說明不另為無罪之諭知。第二審法院 駁回檢察官及被告之上訴，維持第一審法院判決。下列敘述何者正確？', '非法持有手槍罪係得上訴第三審之案件，檢察官就第二審判決全部都可以提起第三審上訴，不受任 何限制', '被告僅對第二審有罪部分上訴，檢察官未上訴，上訴範圍不及於不另為無罪諭知部分', '被告僅對第二審有罪部分上訴，檢察官未上訴。第三審如認被告上訴有理由，基於審判不可分原則， 應將不另為無罪諭知部分併同發回第二審更為審理', '僅檢察官對第二審有罪部分上訴，依上訴不可分原則，及於不另為無罪諭知部分，第三審法院應全 部審理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('113-1301-059', '113-1301', 59, 'single_choice', '甲因偽造文書等案件，經第二審法院判處相關罪刑後，甲於法定上訴期間內提起第三審上訴，然其上 訴書狀並未敘述上訴理由，僅記載「理由後補」。第二審法院收受甲提出之上訴書狀後，應如何處理， 最為正確？', '以裁定定期命甲補提上訴理由，逾期不補正，則以裁定駁回上訴', '以裁定定期命甲補提上訴理由，逾期不補正，則以判決駁回上訴', '毋庸以裁定定期命甲補提上訴理由，直接以判決駁回上訴', '毋庸以裁定定期命甲補提上訴理由，直接送最高法院審判', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-1301-060', '113-1301', 60, 'single_choice', 'A 因使用GPS 追蹤器調查他人行蹤，一審法院判決A 有罪，二審法院認原審判決適用法條有誤，撤 銷後亦改判有罪。A 上訴第三審，第三審法院以上訴違背法律上之程式，判決駁回。關於本件之非常 上訴，下列敘述何者正確？', '檢察總長為被告利益，應以第三審程序判決為對象提起非常上訴', '檢察總長應以第二審實體判決為對象提起非常上訴', '檢察總長得以最高法院法律見解已有變更作為非常上訴理由', '非常上訴採強制辯護制度，A 未選任辯護人者，應由審判長為其指定公設辯護人或律師', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-1301-061', '113-1301', 61, 'single_choice', '關於法官、檢察官及律師依照專業倫理應遵守事項，下列何者錯誤？', '法官於任職期間，不但應該避免參加政治活動，也不可以在上班以外的時間公開支持、反對或評論 任何政黨、政治團體', '檢察官應嚴守偵查不公開原則，但媒體報導之內容與偵查案件事實不符而有澄清之必要時，得經所 屬機關首長授權，對外就案情為必要之說明', '律師先受房屋租約雙方委任，擔任某租賃契約之見證人。嗣後，律師受該出租人委任向該承租人起 訴請求返還系爭租賃物，其受委任毋庸取得該承租人之同意', '提升專業能力為法律人重要的基本倫理，法官、檢察官及律師均負有從事在職進修之義務', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-1301-062', '113-1301', 62, 'single_choice', '法官甲及法官乙為夫妻關係，服務於同一法院。法官甲審理承租人A 主張終止租約，請求出租人B 返 還押租金之爭議。言詞辯論期日，對於A 與B 間是否繼續存在租賃關係之爭點，當庭致電法官乙（另 案承辦A 與B 間給付租金事件）詢問其對於系爭爭點之心證，並以該心證作為勸諭和解之基礎。法 官甲之行為是否違反法官倫理規範？', '違反，因為法官甲、乙既為配偶關係，不應分別承辦相關案件，應屬當然迴避事由', '違反，因為法官甲當庭致電法官乙，逕依法官乙之認定作為和解基礎，易使當事人對於法官審判獨 立性產生疑慮', '不違反，因為法官甲用心良苦，係為避免兩案見解歧異，產生裁判矛盾之風險', '不違反，因為法官甲基於便民措施，目的乃為促成和解，減少訟源', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-1301-063', '113-1301', 63, 'single_choice', '甲法官擔任刑事審判工作多年，經驗豐富著有聲譽，獲某大學邀聘講學，甲即合法申報，並獲機關首 長許可後兼職授課。下列行為何者違反法官倫理規範？', '甲於授課內容批評最高法院之確定判決見解錯誤，重大影響當事人權利', '甲應邀參加學校期末聚餐，席間並與多名學生合影。嗣後學生乙將合影照片張貼於社群媒體，並標 註甲之司法公職身分', '甲於授課過程中，學生A 因家族成員之民事糾紛涉訟，向甲請教相關法律問題。經甲詢問案情後即 於課堂答覆A，並提供具體之法律意見及訴訟策略', '甲選擇由某出版社為其出版之著作，以之作為課程教材，並商請出版社以七折特別價惠價出售給修 課學生', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('113-1301-064', '113-1301', 64, 'single_choice', '甲法官與其夫乙為某航空公司貴賓會員，某日在使用機場貴賓室時，乙因故摔倒受傷，甲法官當場表 明法官身分揚言提告，航空公司依甲當場之要求，隔日派員至甲之辦公室商談和解事宜，下列敘述何 者正確？', '甲法官如係利用下班時間為之，並未違反法官倫理規範', '甲法官如獲乙授權談判，並未違反法官倫理規範', '甲法官表明法官身分，利用辦公處所進行私人事務之行為已違反法官倫理規範', '甲法官所為係行使其法定權利，並未違反法官倫理規範', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-1301-065', '113-1301', 65, 'single_choice', '關於法院首長對於所屬法官進行職務監督時，下列何者非屬法院首長職務監督的處分樣態？', '制止法官違法行使職權', '糾正法官不當言行', '督促法官依法迅速執行職務', '命令移轉法官審理中之個案，改由其他法官審理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-1301-066', '113-1301', 66, 'single_choice', '甲、乙、丙、丁四人為大學同學，甲為執業律師，乙、丙、丁於民國105 年間擔任檢察官，惟丙於109 年轉任律師，並與甲合夥經營律師事務所，甲於111 年和A 女結婚。下列何者違反檢察官倫理？', '丙轉任律師時，乙和丁基於同事情誼，具名致送花籃書寫「開幕致慶」', '乙出席甲和A 的婚宴時，包禮金3,000 元給甲', '甲律師、乙檢察官同時擔任行政院公共工程委員會之申訴委員', '乙出席甲和A 的婚宴時，丙當時擔任乙承辦案件中被告B 的辯護人，且婚宴中乙與丙、B 同桌， 因屬正常社交，乙繼續用餐至婚宴結束', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-1301-067', '113-1301', 67, 'single_choice', '甲檢察官偕同書記官、法醫外出執行相驗屍體外勤任務，於現場相驗完畢後，已逾中午用餐時間，下 列何者不違反檢察官倫理規範之要求？', '為求方便且有助於檢、警聯繫，甲檢察官與共同前往相驗書記官、法醫，接受報驗之轄區司法警察 招待用餐', '甲檢察官自行出錢，就近請書記官、法醫便餐', '甲檢察官自行前往他處用餐，請報驗之轄區司法警察招待書記官、法醫便餐', '甲檢察官與所率書記官、法醫，均不可接受報驗之轄區司法警察招待用餐，但可接受相驗之家屬付 費訂餐', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-1301-068', '113-1301', 68, 'single_choice', '為端正檢察官風紀、促使檢察官嚴守辦案程序、遵守檢察官倫理規範，對違反之檢察官有懲戒之規定。 下列敘述何者正確？', '檢察官應受懲戒之同一行為，不受二次懲戒', '檢察官應受懲戒之同一行為已受刑罰或行政罰之處罰者，因一行為不二罰，不得再予以懲戒', '法官與檢察官性質不同，法官之懲戒由懲戒法院職務法庭審理，檢察官之懲戒由法務部下設檢察官 人事審議委員會審理', '檢察官違反檢察官倫理規範，不分情節輕重，均應付個案評鑑，認有懲戒之必要者，得移送懲戒', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-1301-069', '113-1301', 69, 'single_choice', '律師之執行職務行為，下列何者不違反律師倫理？', '擔任詐欺罪之刑事案件之辯護人，與被告約定若獲無罪判決，以詐欺所得金額的百分之二十作為後 酬', '代理原告起訴請求移轉不動產所有權，約定若勝訴，原告應以該不動產價值之十分之一作為後酬', '代理土地所有權人請求拆屋還地，在訴訟進行中，受讓該土地所有權', '代理妻起訴同時請求離婚及離婚後之剩餘財產，並約定全部勝訴後，以法院判決剩餘財產金額之百 分之十作為後酬', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-1301-070', '113-1301', 70, 'single_choice', '當事人A 委任甲律師進行民事訴訟，訴訟進行中，A 要求甲律師將卷宗資料全部影印一份給A，甲律 師應如何處理？', '訴訟還在進行中，不可以影印給A，要等到訴訟終結之後才可以影印給A', '甲律師自己寫的狀紙以及法院筆錄可以影印給當事人，對造律師的狀紙則必須先取得對造律師同意 才可以影印', '甲應該依照A 的要求將卷宗內的資料全部影印給A', '甲律師自己寫的狀紙可以影印給當事人，但法院筆錄及對造律師的狀紙要取得法院及對造律師同意 才可以影印給A', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('113-1301-071', '113-1301', 71, 'single_choice', '有關利益衝突之敘述，下列何者未違反律師倫理規範？', 'A 曾委託甲律師處理其對B 之請求禁止B 侵害A 之專利權訴訟事件。該案件終結後，第三人C 委 託甲律師對A 提起分割某不動產之訴訟', 'A 與B 原為夫妻，後協議離婚，A 委請甲律師擔任離婚協議書之見證人。後A 與B 因離婚協議書 約定事項發生爭議，B 委任甲律師對A 提起訴訟', '甲律師曾受A 公司委任對於董事B 的競業禁止事項出具意見。甲後來接受B 的委任，對A 公司請 求停止執行關於B 的競業禁止之董事會決議', '甲律師聘僱乙律師，甲允許乙自行接案。若乙律師受當事人A 之委任，甲得同時接受同一案件對造 B 的委任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-1301-072', '113-1301', 72, 'single_choice', '甲律師擔任A 公司之法律顧問，因而得知A 公司所推出的金融商品其實是一個詐欺騙局，會讓投資 大眾遭受重大的財產損失。其後，甲律師終止與A 公司的委任關係。在某次參加大學同學聚會時，甲 律師的同學乙談到想要投資A 公司的該金融商品，甲可不可以警告乙該商品其實是一個詐欺騙局？', '可以，A 公司推出的金融商品是會造成乙財產重大損害的犯罪行為，可以揭露', '不可以，律師應該為當事人保守秘密，絕對不可以洩漏', '不可以，因為金融詐欺只會造成財產損害，沒有危害到生命或身體', '如果甲律師還是A 公司的顧問就不可以，現在已經不是顧問，應該就可以', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-1301-073', '113-1301', 73, 'single_choice', '某大學法律系甲教授擔任A 及B 兩人間工程承攬爭議事件之主任仲裁人，仲裁判斷有利於A。不久， 甲教授便離開教職，從事律師工作。B 因不服該仲裁結果，提起撤銷仲裁判斷之訴訟，A 欲聘請甲律 師擔任其訴訟代理人，下列敘述何者正確？', '因仲裁判斷結果有利於A，甲可以受任擔任A 之訴訟代理人，因其熟悉案情，有助於維護A 之權益', '甲律師先前擔任仲裁人，即使得A 與B 之同意，甲律師仍不得在撤銷仲裁判斷之訴訟中擔任A 之 訴訟代理人', '因A 聘請甲律師擔任訴訟代理人時，等同A 已認可並接受該利害衝突，故甲律師接受委任未違反 律師倫理', '甲不可接受委任，因其未得仲裁協會同意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-1301-074', '113-1301', 74, 'single_choice', '甲是律師事務所的合夥人，乙為事務所的受僱律師。乙為求勝訴，私下會見已委任律師之對造當事人。 下列敘述何者正確？', '乙之行為有助於當事人勝訴，縱使違反其他法令，但不違反律師倫理規範', '委任人是委任甲處理案件，乙只是甲的受僱律師，乙之行為不影響甲的律師倫理義務', '乙律師知道對造已委任律師，不應該私下會見對造', '因乙為甲所僱用，甲不得將此事通知乙所屬之律師公會進行懲戒程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('113-1301-075', '113-1301', 75, 'single_choice', '甲律師受僱於某事務所並被指派承辦當事人A 的案件，因為甲律師即將離職，受僱於另一事務所，甲 律師就向A 說明因只有他最清楚案情，希望A 能夠與原事務所終止委任，繼續由甲律師承辦。甲律 師之行為有沒有違反律師倫理相關規範？', '有，受僱律師離職時不能夠促使當事人轉委任自己為受任人', '沒有，律師業務的競爭本來就各憑本事，除非甲律師有惡意詐欺脅迫之行為，否則要求並促使當事 人轉委任自己，為法之所許', '如果這個案件真的只有甲律師瞭解，甲律師可以促請當事人轉委任自己。如果原事務所還有其他律 師瞭解案情就不可以', '如果甲律師新任職的事務所同意就可以，不同意就不行', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true)
on conflict (question_id) do update set
  paper_id = excluded.paper_id,
  question_number = excluded.question_number,
  question_text = excluded.question_text,
  option_a = excluded.option_a,
  option_b = excluded.option_b,
  option_c = excluded.option_c,
  option_d = excluded.option_d,
  source_page_start = excluded.source_page_start,
  source_page_end = excluded.source_page_end,
  extraction_status = excluded.extraction_status,
  review_status = excluded.review_status,
  is_published = excluded.is_published,
  updated_at = now();

-- Question batch 4
insert into public.questions (
  question_id, paper_id, question_number, question_type, question_text,
  option_a, option_b, option_c, option_d, subject_primary, subject_secondary,
  chapter, topic_primary, topic_secondary, law_refs, tags, source_page_start,
  source_page_end, extraction_status, review_status, notes, is_published
) values
('114-2301-001', '114-2301', 1, 'single_choice', '憲法本文及增修條文之下列何種規定，得導出我國有民主國之性質？', '總統及立法院均由人民直接選舉產生', '總統公布法律、發布命令，須經行政院院長之副署', '國家重要事項須經行政院院會議決', '國家權力劃分為五權，分設五院行使之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-2301-002', '114-2301', 2, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於憲法第155 條：「人民之老弱殘廢，無力生活，……國家應 予以適當之扶助與救濟」，下列敘述何者錯誤？', '租稅優惠為國家得採取保障人民生存與生活之扶助措施之一', '國家保障視障者之工作權屬特別重要公共利益', '憲法特別著重弱勢者之保障，第155 條即為例證之一', '對身心障礙者優惠性差別待遇之合憲性，應採寬鬆之合理性審查', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-2301-003', '114-2301', 3, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於政黨之敘述，下列何者錯誤？', '政黨應服膺自由民主憲政秩序', '政黨與其他團體受憲法保障與限制之程度無平等原則之適用', '國家應致力於建立並確保複數政黨得以自由形成發展與公平參與選舉之法治環境', '國家得對政黨之財產權加以更多限制或給予政黨補助金', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-2301-004', '114-2301', 4, 'single_choice', '有關家庭暴力防治法中之保護令，依司法院解釋意旨及憲法法庭裁判，下列敘述何者錯誤？', '涉及人身自由之限制，應以法律定之', '法律已就人身之處置為明文規定者，得透過具體明確之授權，委由主管機關執行之', '有關人身自由限制之決定，得由法院依法定程序以裁定為之', '民事保護令並不涉及人身自由之限制', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-2301-005', '114-2301', 5, 'single_choice', '下列何者非屬釋憲實務對於宗教自由保障之意旨？', '宗教結社屬宗教自由之絕對保障', '國家考試不得基於人民之特定信仰給與加分優待', '國家不得基於人民之特定信仰為理由予以不利益', '不許人民以宗教理由免除服兵役義務', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-2301-006', '114-2301', 6, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於大學自治之敘述，下列何者錯誤？', '為避免學術自由受國家不當干預，立法機關僅得在合理之範圍內對大學事務加以規範', '大學為確保學位之授予具備一定之水準，得於合理及必要之範圍內，訂定有關取得學位之資格條件', '審理大學學生提起行政爭訟事件，應本於維護大學自治之原則，對大學之專業判斷予以適度之尊重', '大學法明定大學應設教務處、學生事務處、總務處之內部組織，限制大學之自主組織權而與保障大 學自治之意旨相牴觸', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-2301-007', '114-2301', 7, 'single_choice', '關於生命權保障，下列敘述何者錯誤？', '我國憲法對生命權之保障依據，依司法院解釋意旨及憲法法庭裁判，應係憲法第22 條其他自由權 利的保障範圍', '公民及政治權利國際公約規定，任何被判處死刑的人應有權請求赦免或減刑，但赦免法未有類似規 定，使被判處死刑的人有權請求獲得赦免', '法律規定不得對未滿18 歲之人處以死刑，符合兒童權利公約之精神', '公民及政治權利國際公約規定，未廢除死刑之國家，非犯情節最重大之罪，不得科處死刑', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-2301-008', '114-2301', 8, 'single_choice', '有關平等原則，下列敘述何者錯誤？', '人民無權主張不法之平等', '行政機關依裁量基準而形成之慣例，發生間接對外效力，屬於平等原則之內涵', '平等原則可以導出行政機關須受行政慣例之自我拘束', '夜市攤販甲因逃漏營業稅而應予補稅，甲有權請求稅務機關要求其他夜市攤販補稅', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-009', '114-2301', 9, 'single_choice', '關於訴訟權保障，下列敘述何者錯誤？', '訴訟救濟由何種法院審理，為訴訟權保障之核心內容，非屬立法形成自由', '受刑事有罪判決之被告，應有上訴救濟之機會，屬於訴訟權保障之核心內容', '直接審理、言詞辯論、對審及辯護制度係本於正當法律程序之原則', '有權利即有救濟，權利受公權力侵害者，皆享有訴訟救濟之基本權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-010', '114-2301', 10, 'single_choice', '計程車駕駛人觸犯法定之罪，經法院判決有期徒刑以上之刑，吊扣或廢止其執業登記，依司法院解釋 意旨及憲法法庭裁判，係對於何種自由之限制？', '遷徙自由', '職業選擇自由之主觀條件', '職業選擇自由之客觀條件', '職業自由之執行方式', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-011', '114-2301', 11, 'single_choice', '關於服兵役之義務，下列敘述何者錯誤？', '甲男因宗教信仰而不願使用武器，向主管機關申請獲准服替代役，故甲男因此免除服兵役之義務', '中華民國男子依法有服兵役之義務，係立法者鑒於男女之生理上差異，所為之合理差別待遇', '為防衛國家之安全，在實施徵兵制之國家，即規定人民有服兵役之義務', '因有痼疾不堪服役者，得依法律規定免除服兵役之義務', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-012', '114-2301', 12, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，憲法第22 條規定之基本權利，下列何者受絕對保障？', '原住民之身分認同權', '原住民依循文化傳承從事狩獵活動', '個人自主控制其個人資料之資訊隱私權', '人民內在精神活動之思想自由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-013', '114-2301', 13, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於人民健康權之敘述，下列何者錯誤？', '國家對於健康權負有最低限度之保護義務', '公務員之值勤與健康權無涉', '旨在保障人民生理及心理機能之完整性，不受任意侵害', '健康權為憲法第22 條所保障之基本權利', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-014', '114-2301', 14, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，何者非屬憲法上之制度性保障？', '學術自由', '人身自由', '地方自治', '一般行動自由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-015', '114-2301', 15, 'single_choice', '下列何者之任命無須經立法院同意？', '行政院政務委員', '審計長', '考試委員', '監察委員', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-016', '114-2301', 16, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，立法院若長期、消極不行使監察委員人事同意權，下列敘述何者 正確？', '此乃政治問題，非司法院大法官審查範圍', '立法院於何時行使人事同意權，純屬國會自治事項，並不違憲', '應許總統行使緊急處分權，先行任命監察委員，以免影響憲政體制之正常運行', '如致監察院無從行使職權、發揮功能，憲政制度之完整遭受破壞，即為憲法所不許', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-017', '114-2301', 17, 'single_choice', '依憲法訴訟法規定，有關人民得聲請憲法法庭為宣告裁判違憲之程序，下列敘述何者錯誤？', '聲請書應記載確定終局裁判所適用之法規範或該裁判違憲之情形，及所涉憲法條文或憲法上權利', '對於適用大法庭裁定見解之不利確定終局裁判，不得聲請裁判憲法審查', '凡案件具憲法重要性，或為貫徹聲請人基本權利所必要者，憲法法庭得受理之', '聲請應於不利確定終局裁判送達後6 個月之不變期間內為之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-2301-018', '114-2301', 18, 'single_choice', '關於審計長之敘述，下列何者正確？', '審計長由監察院院長提名，經立法院同意任命之', '審計長由總統提名，經監察院同意後任命之', '審計長完成決算審核後，至遲應於3 個月內向立法院提出審核報告', '依職務性質，審計長不隨執政黨更迭而進退', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-019', '114-2301', 19, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，下列何者並非憲法上法官？', '司法院大法官', '懲戒法院法官', '智慧財產及商業法院法官', '臺灣高雄地方檢察署檢察官', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-020', '114-2301', 20, 'single_choice', '依司法院解釋意旨及憲法法庭裁判，關於地方自治受憲法制度性保障之敘述，下列何者錯誤？', '省、縣、直轄市作為地方自治團體之資格，源自憲法本文之規定', '在不侵犯核心領域之範圍內，法律對地方自治權予以限制，尚不違反制度性保障之意旨', '本於制度性保障，縣及直轄市就其轄內之所有事物，享有自行規劃及決定之立法與執行權', '為落實制度性保障意旨，縣及直轄市之自治權遭受監督機關侵害時，得循法律途徑救濟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-021', '114-2301', 21, 'single_choice', '關於行政法之法源，下列敘述何者正確？', '自治條例雖無須特定法律之授權，仍可限制人民權利', '總統發布之緊急命令，乃是位階等同於法規命令之成文法源', '大法庭制度施行後，法官審判時即不得再參考判例及決議', '行政程序法施行後，基於依法行政原則，習慣法已失其法源地位', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-022', '114-2301', 22, 'single_choice', '環保機關查獲地下油槽滲漏污染地下水，通知負責人限期改善，否則依法處罰，惟在限期改善期限屆 至前，即對油槽之負責人裁處罰鍰。關於環保機關之裁罰行為，下列敘述何者正確？', '違反比例原則', '裁罰處分無效', '基於維護公益並未違法', '違反誠實信用原則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-023', '114-2301', 23, 'single_choice', '依據學說與司法實務見解，對於不確定法律概念是否具有判斷餘地，下列敘述何者錯誤？', '考試成績之評定，閱卷委員應有判斷餘地，但若試題屬簡答題且評分標準已客觀明確，即無判斷餘地', '學校依據性別平等教育法就校園性別事件組成之調查小組，其調查報告對於性騷擾之事實認定屬於 判斷餘地，法院應受拘束', '行政機關就其事項雖具有判斷餘地，但若有出於與事物無關之考量之情事，法院仍得介入審查', '獨立委員會所作成的評價決定具有判斷餘地，行政法院之審查應受到限制，但涉及人民基本權利屬 性的判斷，仍應提高審查密度', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-024', '114-2301', 24, 'single_choice', '行政機關依職權訂定裁量基準，其所屬機關在處理具體個案時認為個案情形特殊，未依此裁量基準作 成個案裁量決定，有關此個案裁量決定，下列敘述何者正確？', '即使具體個案情況特殊，所屬機關仍須遵守裁量基準', '裁量基準為行政指導準則，對所屬機關具事實拘束力', '裁量本屬個案決定，故具通案性質之裁量基準係供下屬參考用', '為達成具體個案之公平正義，此裁量可依個案特殊情形而定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-025', '114-2301', 25, 'single_choice', '下列何者不發生行政法之法律關係？', '人民因亂丟垃圾而受主管機關裁處罰鍰', '行政機關與人民締結契約，授予人民行使公權力之權限', '政府採購案之得標廠商與採購機關所訂定之採購契約', '地方政府之垃圾車於執行職務時撞傷人民', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-026', '114-2301', 26, 'single_choice', '下列行政機關之委員，何者不受依法獨立行使職權之保障？', '中央選舉委員會', '公務人員保障暨培訓委員會', '金融監督管理委員會', '國家運輸安全調查委員會', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-2301-027', '114-2301', 27, 'single_choice', '組織法規修正後，甲機關之某項職掌移由乙機關管轄時，下列敘述何者錯誤？', '若相關行政法規仍規定甲機關為管轄機關，且甲機關仍存續時，甲機關與乙機關得聯名公告變更管 轄之事項', '若甲機關被裁撤，其中部分職掌由乙機關承受，但相關行政法規仍載明甲機關為管轄機關，得由乙 機關單獨公告變更管轄之事項', '關於機關管轄變更之公告，原則上自公告之日起算至第3 日起發生移轉管轄權之效力', '若甲機關尚有1 件已受理之申請案，甲機關雖然存續但已不再具有本案管轄權，則甲機關原則上仍 得繼續處理本案', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-028', '114-2301', 28, 'single_choice', '建築法規定，非縣政府所在地之鄉、鎮，適用本法之地區，非供公眾使用之建築物或雜項工作物，得 委由鄉、鎮公所依規定核發執照。若鄉、鎮公所欲就核發此執照之事項形成相關規定，應以下列何種 規範為之？', '自治規則', '委辦規則', '委託規則', '自律規則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-029', '114-2301', 29, 'single_choice', '教育部委託大學入學考試中心辦理大學入學考試事務，該中心所為之行政處分，當事人如有不服，應 向何機關提起訴願？', '行政院', '教育部高等教育司', '大學入學考試中心', '教育部', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-030', '114-2301', 30, 'single_choice', '下列何者適用或準用公務人員保障法之規定？', '政務官', '公營事業依法任用之人員', '公立學校聘任之教師', '民選公職人員', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-031', '114-2301', 31, 'single_choice', '關於給付行政之概念，下列敘述何者錯誤？', '給付行政是指提供人民給付、服務或給與其他利益的行政作用', '行政機關對於給付行政的實施有較大之選擇自由，得以公法型態或私法型態為之', '凡是給付行政涉及金錢或財務給予者，縱無預算作為依據，亦得為給付行政', '行政機關事後廢棄給付行政的具體處分時，應考量相對人的信賴利益', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-032', '114-2301', 32, 'single_choice', '內政部就平均地權條例有關銷售預售屋書面契據不得轉讓之規定所為之統一解釋，其性質為何？', '行政處分', '行政計畫', '行政指導', '行政規則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-033', '114-2301', 33, 'single_choice', '甲工廠向乙行政機關請領裝設先進環保設備之補助，乙機關慮及，若甲未將環保設備實際用於生產過 程，得立即追回該補助，並避免因此產生補償責任，乙機關應如何處置最為妥適？', '直接作成發放補助之處分，並在確認甲未實際運用設備時，撤銷該行政處分', '直接作成發放補助之處分，並在確認甲未實際運用設備時，廢止該行政處分', '作成發放補助之處分，並於該處分中，附加「甲應將設備運用於生產過程」之附款；在確認甲未實 際運用設備時，溯及廢止該行政處分', '作成發放補助之處分，並於該處分中，附加「甲應將設備運用於生產過程」之附款，否則嗣後將向 行政法院訴請返還該補助', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-034', '114-2301', 34, 'single_choice', '關於行政處分性質之敘述，下列何者正確？', '判定役男甲體位為免役體位，係形成處分', '核准外國人乙歸化為中華民國國民，係確認處分', '任命丙為公務人員，係下命處分', '撤銷丁建築執照發放，係形成處分', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-035', '114-2301', 35, 'single_choice', '下列何者非屬行政處分之附款？', '交通主管機關核發小型車普通駕駛執照，註記不得駕駛聯結車、大客車與大貨車', '建築主管機關核發建築執照，註記須向機關提供合法廢土棄置場所之證明後，始得開工', '農業主管機關核定同意農地設置太陽能發電設備，但核定書內敘明，若未依核定計畫內容設置，得 廢止之', '主管機關核准餐廳經營之營業許可，但註明須設置噪音污染防制設備', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-2301-036', '114-2301', 36, 'single_choice', '人民如與A 直轄市之原住民族事務主管機關締結行政契約後，下列何機關於該行政契約關係外行使 公權力，有補償規定之適用？', '內政部', 'A 直轄市地政主管機關', '原住民族委員會', 'A 直轄市山地原住民區之區公所', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-037', '114-2301', 37, 'single_choice', '關於行政契約之法律效果，下列敘述何者錯誤？', '行政機關與人民以行政契約約定國家考試之錄取決定，該行政契約無效', '行政契約若締約機關欠缺事務管轄權而構成重大明顯之瑕疵者，該行政契約無效', '行政機關與人民締結之行政契約，未依行政程序法規定以書面方式為之，該行政契約無效', '行政機關與人民締結侵害第三人權利之行政契約，若締約前未經該第三人書面同意，該行政契約無效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-038', '114-2301', 38, 'single_choice', '甲使用特定建築物經營商業，違反建築法中建築物不得變更使用之法定義務，同時甲所經營之商業項 目，未向主管機關申領營利事業登記證，也違反商業登記法中商業登記之作為義務。就甲於本案所應 受之行政罰，下列敘述何者正確？', '本案共存在兩項違法行為，應依建築法與商業登記法分別裁處行政罰', '本案僅存在單一違法行為，屬於想像競合從一重處斷，故應以建築法裁處行政罰', '本案僅存在單一違法行為，不作為義務應優先於作為義務，故應以建築法裁處行政罰', '本案僅存在單一違法行為，主要違法目的在於違規經營商業，故應以商業登記法裁處行政罰', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-039', '114-2301', 39, 'single_choice', '關於行政罰與刑罰之敘述，下列何者錯誤？', '與刑法有別，行政罰法對於共同違法行為，並不區分共同正犯、教唆或幫助者', '行為非出於故意或過失者，不予處罰，過失行為之處罰，以有特別規定者為限', '不得因不知法律或法規而免除刑事或行政處罰責任。但按其情節，得減輕或免除其刑或處罰', '行政罰法以處罰違反行政法上義務為限', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-040', '114-2301', 40, 'single_choice', '關於公物，下列敘述何者錯誤？', '公物之所有權人得為私人', '公物得依事實行為而提供公用', '公務所必需之公物，得為行政執行之標的物', '公物得為自然山域或水域', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-041', '114-2301', 41, 'single_choice', '關於行政程序法之代理人規定，下列敘述何者錯誤？', '代理權之授與，及於該行政程序有關之全部程序行為。但申請之撤回，非受特別授權，不得為之', '代理人有二人以上者，為避免個別代理行為之矛盾產生，故必須以共同代理方式為之', '代理人與當事人間有基於信任之契約關係，故代理人經本人同意後，始得委任他人為複代理人', '代理權不因本人死亡或其行政程序行為能力喪失而消滅，法定代理有變更或行政機關經裁併或變更 者亦同', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-042', '114-2301', 42, 'single_choice', '下列何者非屬行政處分？', '交通警察在十字路口以手勢指揮交通', '海巡人員以向海面開槍之方式，命越界捕魚之船隻退離', '道路管理機關在既成道路上鋪設柏油', '衛生主管機關以通知單要求特定人於指定日期，讓公務員進入其住居所噴灑藥劑，撲滅病媒蚊', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-043', '114-2301', 43, 'single_choice', '依行政程序法、訴願法及行政訴訟法規定，關於寄存送達之敘述，下列何者正確？', '行政程序及訴願之寄存送達，自送達完畢時即發生效力', '訴願及行政訴訟之寄存送達，自送達完畢時即發生效力', '行政程序及訴願之寄存送達，自寄存之日起，經10 日發生效力', '訴願及行政訴訟之寄存送達，自寄存之日起，經10 日發生效力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-044', '114-2301', 44, 'single_choice', '關於政府資訊公開法規定之敘述，下列何者正確？', '與人民權益攸關之施政、措施及其他有關之政府資訊，不待國民申請，原則上即應主動公開', '國民申請提供政府資訊，以主張或維護其法律上利益有必要者為要件', '國民申請提供之政府資訊包含有侵害個人隱私之部分時，全部均不得提供', '申請提供政府資訊遭到拒絕而不服者，不得單獨就該拒絕決定提起行政救濟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-2301-045', '114-2301', 45, 'single_choice', '有關行政執行法對於將公法上金錢給付義務人予以管收之要件，下列何者錯誤？', '執行機關不得在命義務人提供擔保、限期履行前，即向法院聲請裁定管收', '管收要件包含義務人有逃匿之虞，或其可能履行義務，卻故不履行，或為虛偽財產報告或拒絕報告', '義務人經通知不到場而受拘提後，才能予以管收，如義務人自行到場接受調查者，不得予以管收', '義務人如因管收難以維持家計或罹患疾病無法治療，應逕予停止管收，無須聲請法院裁定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-046', '114-2301', 46, 'single_choice', 'A 公司在其工廠旁違法搭建了一處臨時倉庫，經主管機關查獲後，依建築法相關規定，命令A 公司於 30 日內自行拆除該違建，並於處分書中明確告知逾期不履行將予以強制執行。A 公司逾期未拆除，且 未提出任何異議。關於此類行為義務之強制執行，下列敘述何者正確？', '主管機關可直接派員拆除該違建，並將拆除費用加計行政成本全額向A 公司追償', '主管機關應先對A 公司處以怠金，若A 公司仍不履行，方可進行強制拆除', '主管機關應向法院聲請強制執行，由法院執行處負責拆除該違建', '主管機關可委託第三人代為拆除該違建，並將拆除費用估計後，命A 公司預先繳納', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-047', '114-2301', 47, 'single_choice', '下列何者非屬確認訴訟之標的？', '確認道路交通安全規則無效', '確認當事人是否屬於某公法人之會員', '確認某筆土地是否具有公用地役關係', '確認當事人是否具有中華民國國籍', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-048', '114-2301', 48, 'single_choice', '依司法實務見解，公立大學依法解聘其教師甲，並議決1 年不得聘任為教師。甲對上開解聘及1 年不 得聘任為教師不服而提起救濟時，下列敘述何者正確？', '甲就解聘，得向教育部提起訴願', '甲就解聘，得以教育部為被告，提起確認聘任法律關係存在之訴', '甲就1 年不得聘任為教師，得提起確認聘任法律關係存在之訴', '甲就1 年管制期間，得以教育部為原處分機關，提起訴願', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-049', '114-2301', 49, 'single_choice', '人民甲與行政機關締結行政契約後，甲因情事變更，向行政機關申請調整契約內容，但行政機關函覆 「本案不符情事重大變更之法定要件」，拒絕調整。依最高行政法院實務見解，甲應如何提起行政訴訟？', '提起課予義務訴訟，請求法院判命行政機關作成同意調整之行政處分', '提起一般確認訴訟，請求法院為確認情事變更法律關係存在之判決', '提起一般給付訴訟，請求法院判命行政機關為同意調整之意思表示', '提起撤銷訴訟，並請求法院為增、減給付或變更其他原有效果之判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-050', '114-2301', 50, 'single_choice', '下列何者非屬應適用律師強制代理之事件或案件？', '高等行政法院管轄之環境保護、土地爭議之第一審通常訴訟程序事件', '都市計畫審查程序事件', '人民聲請憲法法庭就法規範及裁判憲法審查之案件', '人民向最高行政法院提起之事件', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-051', '114-2301', 51, 'single_choice', '關於審判權之爭議，下列敘述何者正確？', '行政法院對人民提起之行政訴訟事件，認無審判權而屬於刑事法院之審判權時，得逕予裁定駁回其訴', '民事法院認無審判權移送行政法院，行政法院亦認其無審判權，應聲請大法官就審判權爭議作成統 一解釋', '依現行制度，難以區分法律關係屬於公法或私法時，當事人可以合意定審判權之歸屬，受理之法院 受其拘束，不得再依職權審查審判權之有無', '行政法院受理訴訟認無審判權，以裁定移送民事法院審理，該裁定確定後，民事法院認其亦無審判 權，應裁定停止訴訟程序，並向最高法院請求指定有審判權之管轄法院', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-052', '114-2301', 52, 'single_choice', '因作業疏失，甲行政機關誤撥付款項予乙人民，下列敘述何者正確？', '甲對乙雖因撥款錯誤之行政事實行為而取得對乙之不當得利返還請求權，但尚不得作成下命處分命 乙返還', '甲得作成書面行政處分，限期命乙返還', '甲機關得逕行移送行政執行', '甲須向普通法院訴請乙返還所受領之不當得利', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-2301-053', '114-2301', 53, 'single_choice', '人民於下列何種情形之下得請求損失補償？', '被違規行駛之垃圾車撞傷', '因為跌入未設警告標誌之馬路坑洞而受傷', '因為搭乘臺灣鐵路公司之火車出軌而受傷', '主管機關依法徵收前已埋設地下設施物，妨礙土地所有權人之權利行使', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-054', '114-2301', 54, 'single_choice', '行政機關對甲作成行政處分，但處分書中未記明理由，如無依法得不記明理由之情事，關於行政機關 之補正，下列敘述何者錯誤？', '甲無向原處分機關請求補正之權利，僅得提起行政爭訟請求撤銷原處分', '僅有原處分機關可以補正處分理由，其上級機關不得為之', '只要在行政訴訟事實審言詞辯論終結前補正處分理由，均屬適法', '補正理由雖不足以支持原處分之合法性，亦不影響補正之效力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-055', '114-2301', 55, 'single_choice', '依行政程序法規定，有關聽證之敘述，下列何者正確？', '非經法規明文規定，行政機關不得舉行聽證', '聽證，必要時得舉行預備聽證；但聽證終結後，行政機關不得再為聽證', '聽證主持人，不論行政機關首長或其指定人員擔任，均應具備法制專長', '不服依聽證作成之行政處分，其行政救濟程序，免除訴願及其先行程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-056', '114-2301', 56, 'single_choice', '關於國際法上禁反言原則，下列敘述何者正確？', '通常是指若因自身之行為致他方信賴並依循，即不得再為相反之主張致他方受損害', '在領土判決中常成為判斷領域主權歸屬的最重要因素', '國家元首於聯合國大會發表關於主權範圍之一次性聲明，他國得據以主張禁反言原則', '禁反言原則已成為習慣國際法原則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-057', '114-2301', 57, 'single_choice', '關於國際法上之非自治領土，下列敘述何者錯誤？', '非自治領土人民有權主張人民自決權', '聯合國託管理事會已停止運作', '聯合國憲章並未要求會員須承認非自治領土獨立', '目前世界上已無非自治領土', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-058', '114-2301', 58, 'single_choice', '關於國際法上徵收外國人或公司財產之國際責任，下列敘述何者錯誤？', '地主國徵收外國公司財產給予之補償是否「適當」，得由徵收國片面規定或裁量', '地主國對於徵收之補償，在形式上必須符合「適時、合宜與有效」原則', '地主國得與被徵收公司所屬國明文約定排除「窮盡當地救濟」原則之適用', '「窮盡當地救濟」原則並非習慣國際法原則，除非兩國明文規定為行使外交保護要件，否則不應適用', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-059', '114-2301', 59, 'single_choice', '甲國為經濟社會文化權利國際公約（ICESCR）之締約國。於甲國就業之移工A，認其健康權遭甲國 恣意侵害而欠缺有效救濟，遂以個人名義向經濟社會文化權利委員會提出申訴而未獲受理。下列何者 為不受理之可能理由？', '經濟社會文化權利委員會無權受理個人申訴案', '經濟社會文化權利委員會僅受理工會或團體申訴', '甲國未加入經濟社會文化權利國際公約議定書', '移工A 並非甲國公民，不符合申訴人適格', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-060', '114-2301', 60, 'single_choice', '關於國際太空法原則，下列敘述何者錯誤？', '依據月球條約，月球屬於人類共同遺產', '月球條約關於月球之條款，亦適用於太陽系內地球以外之其他星體', '依據外太空條約，一國不論是為本國或他國從事發射活動，發射國均須對所造成其他國家之損害負責', '拯救條約之締約國對墜落其領土境內具危險性之太空客體，應與發射國共同行使搜救之指揮監督權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-061', '114-2301', 61, 'single_choice', '關於聯合國海洋法公約之解釋與適用爭端，下列敘述何者正確？', '涉及訴訟時，爭端締約國僅得選擇由國際海洋法法庭解決相關爭端', '涉及調解時，爭端締約國僅得從調解員名單中指定人選進行調解', '締約國得以書面聲明就海域劃界事項不接受強制爭端解決程序', '沿海國有義務將專屬經濟區內生物資源主權權利事項交付強制爭端解決程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-2301-062', '114-2301', 62, 'single_choice', '關於國際地役，下列敘述何者正確？', '兩國依條約約定在其中一國領土境內設置核子廢棄物儲存設施，屬於一種國際地役', '若甲國領土被乙國繼承時，原本丙國依條約取得通行甲國領土之地役權，當然終止', '在國際地役權存續期間，供役範圍之領土主權發生暫時移轉之效果', '駐在國外館之不可侵犯權屬於一種國際地役', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-063', '114-2301', 63, 'single_choice', '關於條約在我國國內法上的地位，下列敘述何者正確？', '憲法明文規定條約具有國內法的效力', '符合憲法規定所締結之條約，其位階高於法律', '名稱為條約或公約而附有批准條款者，應送立法院審議', '我國與國際組織間締結之書面協定，雖直接涉及人民權利義務，仍無須送立法院審議', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-064', '114-2301', 64, 'single_choice', '關於領土割讓後，被割讓領土上人民之國籍歸屬，下列敘述何者正確？', '被割讓領土之人民於喪失讓與國國籍後，當然取得受讓國國籍', '被割讓領土之人民繼續保有讓與國國籍，不當然取得受讓國國籍', '被割讓領土之人民繼續保有讓與國國籍，並當然取得受讓國國籍而擁有雙重國籍', '被割讓領土之人民，通常被賦予取得受讓國國籍或保有讓與國國籍之擇一權利', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-065', '114-2301', 65, 'single_choice', '關於國際組織，下列敘述何者正確？', '國際組織成立後須向聯合國秘書處為登記，始取得國際法主體之地位', '國際組織之多數決議，對所有會員國均生直接之拘束力', '國際組織所享有之權能，不以該組織章程明文規定者為限', '基於主權平等原則，所有國際組織之決議投票均為票票等值，無權重差異', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-066', '114-2301', 66, 'single_choice', '下列何者非屬涉外民事事件？', '我國人甲於新竹向我國人乙購買一輛德國製之汽車，後因該買賣契約是否成立生效於我國法院進行 訴訟', '我國人甲於日本向我國人乙購買一棟位於新竹之房屋，後因該買賣契約是否成立生效於我國法院進 行訴訟', '我國人甲在臺南開車不慎，撞傷日本人乙，乙於我國法院對甲提起訴訟，請求侵權行為之損害賠償', '我國人甲在日本收養日本人乙，收養後甲、乙長期居住於我國，關於該收養是否成立生效於我國法 院進行訴訟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-067', '114-2301', 67, 'single_choice', '關於當事人本國法之認定，下列敘述何者正確？', '當事人有多數國籍時，應適用其住所地法', '當事人有多數國籍，而其中之一為我國國籍時，應以我國法為其本國法', '當事人無國籍，且住所不明時，應適用其居所地法', '當事人無國籍時，應適用其關係最切之法律', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-068', '114-2301', 68, 'single_choice', '下列何者不屬於外國公司之內部事項？', '公司董事之選任方式及程序', '董事對外代表公司之職權範圍', '董事與其他公司簽訂買賣契約', '公司修訂章程限定董事之權限', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-069', '114-2301', 69, 'single_choice', 'A 國人甲在B 國擁有一處莊園，與乙在C 國簽訂受讓該莊園之書面契約，並約定該契約以D 國法為 準據法，然而該契約未經公證。A 國、B 國以及C 國均未規定不動產買賣契約應經公證，而D 國法 律則規定不動產買賣契約經公證方能生效。下列敘述何者正確？', '該契約有效，係因買賣不動產之法律行為方式可依行為地C 國法', '該契約有效，係因買賣不動產之法律行為方式可依物之所在地B 國法', '該契約無效，係因買賣不動產之法律行為方式應依該契約之準據法D 國法', '該契約無效，係因買賣不動產之法律行為方式應符合行為地C 國法與該契約之準據法D 國法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-2301-070', '114-2301', 70, 'single_choice', '住在加州之美國人甲以新臺幣100 萬元向住在臺北之我國人乙購買20 公噸之鳳梨。關於鳳梨品質有 瑕疵之爭議，甲與乙買賣鳳梨契約之法律適用，下列敘述何者正確？', '若甲與乙以電話約定以美國法為準據法，因僅有口頭約定而未有書面，故應認為甲與乙未明示合意 應適用之法律', '若甲與乙之買賣契約有「以美國加州法院為管轄法院」之合意管轄條款，故而可以認為甲與乙有以 美國法為準據法之合意', '若甲與乙未明示合意應適用之法律，應推定締約時乙之住所地法，即我國法為關係最切之法律，而 以之為準據法', '若甲與乙合意以日本法為準據法，則該合意為無效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-2301-071', '114-2301', 71, 'single_choice', 'A 國人甲男與B 國人乙女在我國相識結婚，並育有一子丙（具A 國籍），三人一起定居於臺中市。不 料，多年後甲、乙感情生變，甲向臺灣臺中地方法院訴請裁判離婚。訴訟中，針對離婚後應由何人擔 任未成年子女丙之親權人一事，我國法院應如何適用法律？', '本案應定性為離婚之效力問題，依夫妻共同住所地法之我國法', '本案應定性為親子間法律關係之問題，依子女本國法之A 國法', '本案應定性為監護之問題，依受監護人本國法之A 國法', '本案應定性為扶養之問題，依關係最切地法之我國法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-2301-072', '114-2301', 72, 'single_choice', '我國人甲女在德國留學時與德國人乙男結婚，婚後甲、乙定居我國，爾後甲向我國法院起訴請求判決 與乙離婚，乙在起訴後搭機返回德國。關於準據法之決定及其理由，下列敘述何者正確？', '德國法。甲、乙在德國結婚，關係最切之法為德國法', '德國法。德國法院有管轄權，故準據法為德國法', '我國法。起訴時之共同住所地國為我國', '我國法。起訴時關係最切之法為我國法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-2301-073', '114-2301', 73, 'single_choice', 'A 國人甲與B 國人乙結婚多年，居住於臺北，生活困頓，時常爭吵，之後協議離婚。離婚後1 個月， 乙女發現已懷胎4 個月，5 個月後產下一子丙，下列敘述何者正確？', '關於丙之身分，僅得依出生時其母之本國法，即B 國法為婚生子女時，丙為婚生子女', '丙出生時，甲、乙兩人已經離婚，關於丙之身分僅得依婚姻關係消滅時其母之本國法，方能符合兩 性平等保障女性之思潮', '關於子女之身分，近代國際私法之思維多有藉累積適用多數國家之法律，儘量承認子女婚生之趨勢', '關於丙之身分，若依甲、乙婚姻關係消滅時甲之本國法，即A 國法之規定為婚生子女時，則丙為婚 生子女', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-2301-074', '114-2301', 74, 'single_choice', '我國人甲與A 國人乙為夫妻，甲起訴請求離婚，並合併請求乙給付贍養費。乙抗辯依A 國法，夫妻 離婚不得請求贍養費，僅得請求婚姻破裂之補償。下列敘述何者正確？', '贍養費為離婚後財產上之請求，應依夫妻財產制之選法規則', '離婚後贍養費之請求，應依扶養事件之選法規則', '離婚後贍養費之請求，應依離婚效力之選法規則', 'A 國法規定不得請求贍養費，僅得依侵權行為之選法規則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-2301-075', '114-2301', 75, 'single_choice', '中華民國國民甲與A 國人乙，因為給付買賣價金糾紛，經過A 國法院判命甲應給付乙買賣價金 100 萬元及懲罰性賠償金1,000 萬元。乙持該確定判決向中華民國法院聲請強制執行，下列敘述何者 錯誤？', 'A 國與中華民國雖無外交承認，但若A 國法院沒有不承認中華民國法院判決之情形，符合民事訴 訟法第402 條第1 項第4 款之要件', 'A 國懲罰性賠償金之判決，性質上屬於民事判決，仍然具有外國判決承認之適格', '乙可直接持A 國判決為執行名義，在我國聲請強制執行', '為判決之A 國法院是否有國際管轄權，按民事訴訟法第402 條第1 項第1 款之規定，依中華民國 法律定之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-3301-001', '114-3301', 1, 'single_choice', '甲受輔助宣告，下列何項行為，無須經其輔助人同意？', '為獨資之負責人', '向銀行借款新臺幣10 萬元', '受贈一台筆記型電腦', '對車禍肇事者提起侵權訴訟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-3301-002', '114-3301', 2, 'single_choice', '甲將附有備胎之貨車以新臺幣150 萬元出賣於乙。下列敘述，何者錯誤？', '關於車子上之四個輪胎為買賣標的物之構成部分，非獨立之物', '車子之備胎是從物，為獨立之物', '除非甲、乙有約定買賣標的物不及於備胎，否則買賣契約之效力及於備胎', '備胎有瑕疵而解除契約者，效力及於買賣契約之全部', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-3301-003', '114-3301', 3, 'single_choice', '依民法代理之規定，下列敘述，何者正確？', '意定代理之代理人有數人者，除法律另有規定或本人另有意思表示外，各代理人均得各自行使之', '代理適用於法律行為，包括一切身分行為', '無行為能力人不得為代理人，限制行為能力人得為代理人', '代理人逾越代理權，以本人名義所為之意思表示，直接對本人發生效力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-3301-004', '114-3301', 4, 'single_choice', '下列關於限制行為能力人之敘述，何者正確？', '限制行為能力人為無權代理，經本人承認後，得主張契約不生效力', '限制行為能力人未得法定代理人之允許所訂立之契約，得撤銷', '限制行為能力人將父母歷年所給之零用錢購買汽車，毋須父母同意', '限制行為能力人偽造父母同意書所訂立之契約，該契約有效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-3301-005', '114-3301', 5, 'single_choice', '下列關於清償之敘述，何者正確？', '非與債務之清償有利害關係之第三人，不得為第三人清償', '債務人對非債權人之債權準占有人為清償時，依法院實務見解，須以其善意且無過失者，始生效力', '債權證書已返還者，視為其債之關係消滅', '清償人所提出之給付，得以雙方合意變更應先抵充費用、利息、原本之次序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-3301-006', '114-3301', 6, 'single_choice', '甲基於買賣契約，得請求乙支付價金，共新臺幣（下同）30 萬元。若甲將對乙之30 萬元價金債權出 賣於丙，下列敘述，何者正確？', '甲原則上應對丙擔保乙之支付能力', '若乙於訂立買賣契約時，已為受監護宣告者，善意之丙得請求甲負擔權利瑕疵擔保責任', '若乙無法對丙提出給付，甲應負擔代為履行之責', '甲將對乙之債權出賣於丙，應於甲通知丙後，始生效力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-3301-007', '114-3301', 7, 'single_choice', '民法關於主權利與從權利之規定，下列敘述，何者正確？', '以抵押權擔保之債權，其請求權已因時效而消滅，如抵押權人，於消滅時效完成後，3 年間不實行 其抵押權者，其抵押權消滅', '以留置權擔保之債權，其請求權已因時效而消滅，如留置權人，於消滅時效完成後，5 年間不實行 其留置權者，其留置權消滅', '讓與債權時，該債權之擔保及其他從屬之權利，一律隨同移轉於受讓人', '以質權擔保之債權，其請求權雖經時效消滅，質權人仍得就其質物取償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-3301-008', '114-3301', 8, 'single_choice', '甲欲出售其所有之A 屋，遂委託房屋仲介商乙代為銷售。某日，乙帶領丙前來賞屋完畢後，丙甚為喜 歡，表示願以新臺幣（下同）1500 萬元購屋之意願；離去之際，適逢甲前來查看售屋狀況，甲、乙、 丙三人簡單寒暄後，便各自離開。嗣後，甲透過友人得知丙之聯絡方式，遂聯繫丙向其表示願意減價 50 萬，直接出售A 屋於丙，以避免雙方支付高額仲介費。下列敘述，何者錯誤？', '甲委託仲介銷售之契約，性質上乃屬於居間，係為他方報告訂約之機會或為訂約之媒介，故其既不 屬隱名代理，亦不屬雙方代理', '乙為媒介居間人，僅以契約因其媒介而成立時，始得請求報酬，故若甲、丙自行訂立買賣契約時， 乙無從請求甲、丙支付仲介報酬', '甲自行聯繫丙並與其訂立買賣契約，該當於民法第101 條第1 項視為條件已成就之情形，故甲、丙 二人仍應給付仲介報酬於乙', '甲故意拒絕因乙媒介而成立之契約，而自行與丙訂立同一內容之契約者，應認為違反誠信原則', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-3301-009', '114-3301', 9, 'single_choice', '甲於2024 年6 月6 日向丙汽車商購買一款新車。不料於2025 年1 月1 日元旦與好友乙出遊時，新車 突然發生暴衝，甲雖及時緊踩煞車，仍發生車禍意外，造成甲與乙皆因衝撞而受傷。事故後，新車嚴 重撞毀已不值得修繕，甲乙受傷住院。經事故鑑定報告，汽車暴衝係因該款汽車系統程式瑕疵問題所 致，而甲於汽車暴衝時之處置，並無過失。下列敘述，何者錯誤？', '因汽車系統程式瑕疵導致汽車暴衝，屬無法即知之瑕疵問題，丙汽車商仍負物之瑕疵擔保責任', '汽車暴衝係因其系統程式瑕疵問題，汽車商丙對甲可能同時負有不完全給付責任與物之瑕疵擔保責任', '甲、乙所受之身體傷害，皆不得依民法規定請求固有利益之損害賠償', '甲、乙所受之身體傷害，屬瑕疵結果損害，得依民法規定，請求損害賠償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-3301-010', '114-3301', 10, 'single_choice', '受監護宣告之甲，由其父母任監護人。某日，甲於公園中遊玩，在垃圾桶中發現一台無人所有之玩具 飛機，遂拾起把玩許久。嗣後，就讀國小三年級之乙見狀，便央求甲將該玩具飛機贈送於己，甲便欣 然同意。甲隔日再於公園遇見乙，兩人便共同玩著射飛機，遊玩間，孰料玩具飛機不慎飛射撞上坐在 公園休息之遊民丙，丙頭部因此受傷，而向兩人之父母求償醫療費及精神慰撫金。下列敘述，何者 錯誤？', '甲拾得玩具飛機據為己有，屬一事實行為，故甲取得該玩具飛機之所有權', '甲贈與乙玩具飛機之行為，對乙而言，屬純獲法律上利益，故該贈與契約有效', '甲、乙二人遊玩間因飛機誤射而令丙頭部受傷，原則上屬甲、乙兩人共同侵害丙之身體健康權', '甲、乙與其二人之父母原則上對丙負損害賠償責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-3301-011', '114-3301', 11, 'single_choice', '甲與中古車商乙訂立買賣契約，向乙購買A 車。乙之業務員丙明知該車曾經發生車禍，卻向甲偽稱該 車未遭車禍，致甲決定訂約。關於買賣契約之效力，下列敘述，何者正確？', '買賣契約無效', '買賣契約效力未定', '甲得撤銷購買A 車之意思表示', '以乙明知其事實或可得而知者為限，甲始得撤銷', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-3301-012', '114-3301', 12, 'single_choice', '甲為臺南市某歐洲進口傢俱公司，乙之女兒即將結婚，婚後住在臺北市，乙到甲公司門市部購買並指 定A 進口傢俱為其女兒嫁妝，甲公司表明該公司在臺南市是免費送到府，並以臺南市為清償地，無送 外縣市之服務。經甲與乙雙方討論後，改以臺北市作為交付處所，由甲委託並交付A 傢俱於丙貨運公 司運送。運送途中，因為高速公路連環車禍，該批傢俱因此滅失，對此連環車禍，丙貨運公司之駕駛 並無過失。下列敘述，何者錯誤？', '該進口傢俱於運送途中車禍，致A 傢俱滅失，屬給付不能', '依民法第373 條有關危險負擔之規定，A 傢俱滅失之風險尚未移轉於乙，乙得請求甲重新交付新傢俱', '在甲將傢俱交付於丙貨運公司運送時，A 傢俱滅失之風險已移轉於乙，乙不得請求返還價金', '乙得請求甲讓與其對車禍肇事者之損害賠償請求權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-3301-013', '114-3301', 13, 'single_choice', '甲、乙、丙合夥成立一家民宿，甲、乙為出名營業人，丙為隱名合夥人，下列關於甲、乙、丙間合夥 契約終止之敘述，何者正確？', '丙死亡時，丙之隱名合夥契約當然終止', '丙受監護宣告時，丙與甲、乙間之隱名合夥契約當然終止', '隱名合夥契約終止時，丙之出資因損失而減少者，僅返還其餘存額', '隱名合夥契約終止後，甲、乙、丙間之合夥關係，即生解散之效力', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-3301-014', '114-3301', 14, 'single_choice', '乙經營A 餐廳，受新冠疫情衝擊，該餐廳生意受到嚴重影響，於是與甲訂立消費借貸契約。為確保乙 對甲新臺幣（下同）2000 萬元債務之清償，甲要求乙提供擔保，乙提供自己所有A 餐廳之不動產所 有權，為甲之債權設定普通抵押權，並委任其好友丙，提供連帶保證。但乙最終仍因經營不善，將其 所經營之A 餐廳全部（包含乙對甲之債務）轉讓於丁。嗣後，丁因投資股票不利而破產，甲直接向丙 請求3000 萬債務之履行，但甲拋棄對A 餐廳之抵押權。下列敘述，何者正確？', '基於物保優先原則，丙得向甲主張，甲應先就乙自己所提供之A 餐廳物權擔保行使抵押權', '甲雖得向丙請求債務之清償，但丙得對甲行使先訴抗辯權', '連帶保證人對債權人清償後，不得承受債權人對主債務人之債權', '丙得主張，丁承擔乙之債務時，並未事先經其同意，其保證債務已因債務之承擔而消滅', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-3301-015', '114-3301', 15, 'single_choice', '甲向乙購買商品一批轉賣於丙，甲、乙雙方約定付款之期限為：「丙付款於甲後，甲應立即支付貨款 於乙」。嗣後，丙因經營不善倒閉而未能支付貨款於甲。下列敘述，何者正確？', '甲、乙之約定，不影響雙方之買賣契約之效力，乙仍得隨時請求甲付款', '丙之付款為甲付款於乙之條件，因丙倒閉致條件不成就，乙不得請求甲付款', '丙之付款為甲付款於乙之不確定期限，於丙倒閉時，甲應付款於乙之清償期屆至', '丙之付款為甲付款於乙之不確定期限，於丙倒閉時，甲應即對乙負給付遲延責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-3301-016', '114-3301', 16, 'single_choice', '甲將A 屋出租於乙，每月租金新臺幣（下同）4 萬元，並由乙交付5 萬元押租金於甲。下列敘述，何 者正確？', '押租金與租賃契約為個別獨立之契約，租賃契約消滅，押租金契約原則上不隨同消滅', '押租金與租賃契約為個別獨立之契約，租賃契約之成立，不以押租金之交付為要件', '押租金具有擔保租賃債務之功能，屬於民法上法定擔保物權', '押租金契約原則上為諾成契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-3301-017', '114-3301', 17, 'single_choice', '甲、乙、丙共同出資合夥經營A 飲料店，因購買原料積欠丁債務。下列敘述，何者正確？', '丁得逕請求甲、乙、丙、A 負連帶清償責任', '丁得逕請求甲、乙、丙負連帶清償責任', '丁僅得向A 請求清償債務', 'A 之財產不足清償對丁之債務時，丁始得請求甲、乙、丙負連帶清償責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-3301-018', '114-3301', 18, 'single_choice', '買受人就買賣標的物之瑕疵，主張基於物之瑕疵擔保責任與不完全給付之債務不履行責任而解除契 約。下列敘述，何者錯誤？', '二者均以出賣人就物之瑕疵有故意或過失者，買受人始得解除契約', '瑕疵可補正者，主張不完全給付之買受人，須於催告出賣人補正而其不補正時，始得解除契約', '買受人向出賣人主張物有瑕疵者，出賣人得定相當期限，催告買受人於其期限內是否解除契約', '依物之瑕疵擔保責任而解除契約顯失公平之情形，買受人仍得依不完全給付之規定而解除契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-3301-019', '114-3301', 19, 'single_choice', '甲有A 建地，並登記為A 地所有人。乙未經甲之同意，無權占有A 地建屋居住長達25 年之久。甲移 居海外，不知乙無權占用A 地一事，未曾請求乙返還A 地。下列敘述，何者正確？', '關於消滅時效之規定，適用於A 地返還請求權', '乙得因時效取得，請求登記為A 地之地上權人', '乙因時效取得A 地所有權而免除占用A 地之損害賠償責任', '乙得時效取得A 地租賃權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-3301-020', '114-3301', 20, 'single_choice', '甲、乙與丙合夥經營事業，A 地乃合夥財產，合夥股份各三分之一。甲未經乙與丙同意，將A 地出租 且交付於丁占有。下列敘述，何者正確？', '乙與丙均得單獨請求丁返還A 地於自己', '乙與丙均僅得共同請求丁返還A 地於甲', '乙與丙均得共同請求丁返還A 地於乙與丙', '乙與丙均得單獨請求丁返還A 地於甲、乙與丙全體', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-3301-021', '114-3301', 21, 'single_choice', '甲之A 地與乙之B 地相鄰，兩地均與公路有適宜聯絡，甲於民國80 年起，於A 地設置道路供自己快 速直接通行至公路，並同意乙使用該道路通行。因該道路未設柵欄，雖甲已在路口設置私人道路告示， 惟仍有不少民眾為方便而通行該道路。丙市府為維公眾通行安全，在該道路舖設柏油路面，並劃設交 通標線。下列敘述，何者正確？', '乙得甲同意通行使用該道路，即成立不動產役權，乙亦得於該道路上設置廣告看板', '乙得依鄰地通行權之相鄰關係，通行使用系爭道路', '丙若在系爭道路範圍內之私有土地均辦理徵收，但因認定該道路已成為既成道路有公用地役關係， 而以命令規定繼續使用，得不予同時徵收補償', '如無特別法令依據，於該私設道路已符合司法院釋字第400 號解釋意旨所稱既成道路前，甲非不得 請求予以除去丙之道路維護行為', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-3301-022', '114-3301', 22, 'single_choice', '甲有A 轎車，乙有B 轎車，二車同廠牌同類型。A 轎車之引擎故障，甲取B 轎車之引擎，裝在A 轎 車上。甲與丙訂立買賣契約，將A 轎車（裝有B 轎車之引擎）出賣於惡意之丙，並以移轉所有權之 意思交付於丙。關於B 轎車引擎之所有權歸屬，下列敘述，何者正確？', '歸屬於乙所有', '歸屬於甲所有', '歸屬甲、丙共有', '歸屬乙、丙共有', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-3301-023', '114-3301', 23, 'single_choice', '甲與乙分別共有A 地，應有部分各二分之一，並登記於土地登記簿。甲與乙就共有之A 地並未成立 分管契約。甲以其應有部分設定普通抵押權於丙。嗣後乙向法院提起裁判分割共有物之訴。下列敘述， 何者正確？', '甲與乙應經共有人全體之同意，始得訴請分割A 地', '自共有物分割效力發生時起，各共有人得請求其他共有人移轉其分得部分之所有權', '若法院之確定分割判決，變價分配於甲，則丙之抵押權因抵押物滅失而消滅', '若丙經訴訟告知，則其抵押權移存於甲分得之部分', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-3301-024', '114-3301', 24, 'single_choice', '甲與乙訂立A 地之借名登記契約，由甲將自丙所購買之A 地所有權直接移轉登記於乙，以節省稅賦。 乙未經甲同意，竟將A 地出賣於善意不知該借名登記情事之丁，並已完成所有權移轉登記。依法院實 務見解，下列敘述，何者正確？', '不動產借名登記契約為借名人甲與出名人乙間之物權契約', '乙將A 地移轉登記於丁之處分行為，為有權處分', '乙將A 地移轉登記於丁之處分行為，因係無權處分，其效力未定', '甲若不欲承認乙之處分行為，得起訴主張乙違反委任契約，並代位乙請求丁塗銷A 地登記返還於乙', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-3301-025', '114-3301', 25, 'single_choice', '下列關於普通地上權之敘述，何者正確？', '地上權設定時，不以地上建築物或工作物之存在為必要，設定後亦不因建築物或工作物之滅失而消滅', '未定期限而有支付地租約定之地上權，地上權人依法應於支付未到期之3 年分地租後，始得拋棄其 權利', '地上權設定後，因不可抗力妨礙其土地之使用，依原定地租給付顯失公平者，地上權人得請求法院 減免之', '因不可歸責於地上權人之事由，致土地不能達原來使用之目的時，地上權當然消滅', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true)
on conflict (question_id) do update set
  paper_id = excluded.paper_id,
  question_number = excluded.question_number,
  question_text = excluded.question_text,
  option_a = excluded.option_a,
  option_b = excluded.option_b,
  option_c = excluded.option_c,
  option_d = excluded.option_d,
  source_page_start = excluded.source_page_start,
  source_page_end = excluded.source_page_end,
  extraction_status = excluded.extraction_status,
  review_status = excluded.review_status,
  is_published = excluded.is_published,
  updated_at = now();

-- Question batch 5
insert into public.questions (
  question_id, paper_id, question_number, question_type, question_text,
  option_a, option_b, option_c, option_d, subject_primary, subject_secondary,
  chapter, topic_primary, topic_secondary, law_refs, tags, source_page_start,
  source_page_end, extraction_status, review_status, notes, is_published
) values
('114-3301-026', '114-3301', 26, 'single_choice', '依現行民法規定，下列關於地上權之敘述，何者正確？', '在他人土地上種植竹木而使用其土地者，得設定普通地上權', '普通地上權不得約定超過30 年，超過者縮短為30 年', '普通地上權人就土地之使用收益有約定使用方法者，關於該方法之約定，非經登記，不得對抗第三人', '區分地上權人與其設定之土地上下有使用、收益權利之人，約定相互間使用收益之限制時，如未得 土地所有人同意者，該約定無效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-3301-027', '114-3301', 27, 'single_choice', '下列何者非屬權利質權設定之標的？', '股份有限公司股票', '普通抵押權所擔保之債權', '清光緒年間所製造發行之大清銀幣', '著作財產權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-3301-028', '114-3301', 28, 'single_choice', '甲係經許可以受質為營業者，乙為借錢而移轉占有其首飾項鍊於甲，俾擔保甲之債權受償。乙屆期無 力償債，未於取贖期間屆滿後5 日內，取贖其首飾項鍊。下列敘述，何者正確？', '甲不得請求乙清償債務', '甲應於拍賣該首飾項鍊前通知乙', '甲得就首飾項鍊行使其權利，但所擔保之債權，若未全額受償，不足清償部分之債權，仍未消滅', '甲對乙負有清算義務，甲須經清算，始取得首飾項鍊之所有權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-3301-029', '114-3301', 29, 'single_choice', '甲將其土地設定普通抵押權於乙，嗣後甲將該土地設定普通地上權於丙建築房屋。屆期甲未清償債務， 乙實行抵押權而無人應買。關於丙房屋之處置，下列敘述，何者正確？', '甲非經抵押權人乙之同意，不得設定地上權於丙建築房屋，故乙得請求丙拆屋還地', '因可歸責於甲之事由致土地價值減少時，乙得因此主張實行抵押權，拍賣抵押物', '乙於必要時，得聲請法院將房屋與土地併付拍賣，但對房屋賣得價金不得主張優先受清償', '乙得主張基於物權優先效力，先設定之抵押權效力及於地上權及地上房屋，一併拍賣而優先受清償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-3301-030', '114-3301', 30, 'single_choice', '甲有登記其名下之A 地及A 地上之B 屋，甲僅以B 屋設定典權於乙，約定期限20 年，並附有到期 不贖即作絕賣之條款，但該條款未經登記。嗣後，甲將A 地讓售於丙，並完成所有權移轉登記。甲於 典期屆滿後，不以原典價回贖。下列敘述，何者錯誤？', '甲於典期屆滿後，不以原典價回贖，乙不負清算義務，即取得B 屋所有權', '甲於典期屆滿後，不以原典價回贖，乙、丙間推定有租賃關係', '甲於典期屆滿後，不以原典價回贖，縱使絕賣條款未經登記，乙仍取得B 屋所有權', '甲於典期屆滿後，不以原典價回贖，丙訴請乙拆除B 屋返還土地，並無理由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-3301-031', '114-3301', 31, 'single_choice', '甲為A 車所有人，A 車乃古董車，全車原廠維修，且已報廢登記車籍。乙竊得A 車，半年後，乙因 酒駕致A 車毀損。下列敘述，何者錯誤？', '甲請求乙返還占有A 車之使用利益，有理由', '甲請求乙賠償因A 車毀損所受之損害，有理由', '若乙於占有期間為A 車整車之車體鍍金，則其請求該筆費用，有理由', '若乙竊得A 車後，隨即出賣且交付A 車於丙。丙不知A 車乃贓車，且就其不知無過失，則甲請求 乙賠償因此所受之損害，有理由', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-3301-032', '114-3301', 32, 'single_choice', '成年年齡由20 歲下降至18 歲，影響有關未成年人所為或所受身分行為之規定。下列關於民法規定之 敘述，何者正確？', '夫妻之一方收養他方子女時，應長於被收養者16 歲以上', '未成年人結婚，應得法定代理人之同意', '收養者之年齡，應長於被收養者18 歲以上', '男未滿17 歲，女未滿15 歲者，不得訂定婚約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-3301-033', '114-3301', 33, 'single_choice', '甲男與乙女為夫妻，於婚姻期間，甲與丙女外遇，乙亦與丁男外遇。下列敘述，何者錯誤？', '乙得向法院請求與甲離婚', '乙因判決離婚生活陷於困難，得向法院請求甲給付相當之贍養費', '乙不得因判決離婚請求所受之非財產上之損害賠償', '若甲、乙為協議離婚，並未為贍養費之約定，雙方亦不得再向法院請求贍養費之給付', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-3301-034', '114-3301', 34, 'single_choice', '甲男與乙女結婚後，因甲登山失蹤滿7 年，法院依聲請為甲死亡宣告之裁定。嗣後，乙女與丙男結婚， 而甲卻在乙、丙婚後生存歸來，法院為撤銷甲死亡宣告之裁定。關於乙之婚姻關係，下列敘述，何 者正確？', '乙、丙雙方均善意時，乙、丙之後婚有效，甲、乙之前婚消滅', '乙、丙中一人善意時，乙、丙之後婚有效，甲、乙之前婚消滅', '不論乙、丙是否善意，乙、丙之後婚有效，甲、乙之前婚消滅', '由乙決定甲、乙前婚或乙、丙後婚有效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-3301-035', '114-3301', 35, 'single_choice', '甲男乙女原為夫妻，於協議離婚時，約定由甲單獨行使或負擔未成年子女丙之權利、義務。嗣後，因 丙考上知名高中，甲之父親丁贈送名牌A 腳踏車一輛於丙。下列敘述，何者錯誤？', '甲依法有權管理丙之A 腳踏車', '甲依法得自由處分丙之A 腳踏車', '甲依法有權使用丙之A 腳踏車', '甲依法不須取得乙之同意，即得單獨管理丙之A 腳踏車', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-036', '114-3301', 36, 'single_choice', '下列何種情事，依民法規定，不得請求法院酌定之？', '父母於子女出生登記前，就子女從父姓或母姓約定不成', '父母對於未成年子女重大事項權利之行使意思不一致', '夫妻之住所協議不成', '夫妻離婚時，對於未成年子女權利義務之行使或負擔協議不成', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-037', '114-3301', 37, 'single_choice', '下列何者非屬剩餘財產分配之範圍？', '夫或妻婚前財產，於婚姻關係存續中所生之孳息', '夫或妻婚後無償取得之財產，於婚姻關係存續中所生之孳息', '夫或妻於婚姻關係存續中，改用法定財產制前所得之薪資', '夫或妻於婚姻關係存續中，對他方所生之一般債權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-038', '114-3301', 38, 'single_choice', '依民法規定，關於法院成立之調解離婚，婚姻關係於何時消滅？', '法院調解離婚成立時消滅', '法院向戶政機關為調解離婚成立通知時消滅', '一方當事人向戶政機關為離婚登記時消滅', '雙方當事人向戶政機關為離婚登記時消滅', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-039', '114-3301', 39, 'single_choice', '甲女之胎兒丙，在丙出生前，即由甲及丙之生父乙代丙與丁訂立收養契約，作為丁之養子女。嗣後， 戊醫師在甲懷孕丙期間為甲輸血，因戊之過失致甲感染病毒，並傳染於丙，而侵害丙之身體健康。下 列敘述，何者正確？', '丙與丁之收養契約有效；在丙出生前，丙即得向戊請求損害賠償', '丙與丁收養契約得撤銷；須於丙完全出生（非死產）時，丙始得向戊請求損害賠償', '丙與丁收養契約無效；在丙出生前，丙即得向戊請求損害賠償', '丙與丁之收養契約效力未定；須於丙完全出生（非死產）時，丙始得向戊請求損害賠償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-040', '114-3301', 40, 'single_choice', '依民法規定，下列何者不得向法院聲請宣告變更為父姓或母姓？', '父母一方生死不明未滿三年者', '父母雙方死亡者', '父母離婚但約定共同行使權利者', '父母一方遺棄子女多年者', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-041', '114-3301', 41, 'single_choice', '甲女單身收養乙男，經過5 年，甲女與丙男結婚。乙男成年後，與丁女結婚。又經過多年，甲女死亡， 法院許可乙男聲請終止甲、乙之收養關係。若乙男死亡，丁女與丙男結婚時，其效力如何？', '有效', '無效', '效力未定', '得撤銷', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-042', '114-3301', 42, 'single_choice', '關於遺產酌給之請求及遺產管理，下列敘述，何者錯誤？', '遺產分割之費用，由遺產中支付之', '遺產管理人應編製遺產清冊及為保存遺產必要之處置', '被繼承人生前繼續扶養之人，應由遺產管理人決定酌給遺產', '遺產管理人得請求報酬，由遺產中支付之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-043', '114-3301', 43, 'single_choice', '甲男乙女為夫妻，有一未成年子丙。甲受監護宣告，法院指定甲之父戊為甲之監護人。乙立遺囑指定 丁為丙之監護人。乙死亡後，下列何者為丙之監護人？', '甲', '丁', '戊', '社會福利機構', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-044', '114-3301', 44, 'single_choice', '下列關於遺囑能力之敘述，何者正確？', '無意識或精神錯亂中所為之遺囑，得於回復常態後撤銷之', '無行為能力人不得自為遺囑，須由其法定代理人代為之', '滿16 歲之限制行為能力人所為之遺囑，爾後不論成年與否，均得依遺囑方式撤回', '未滿16 歲之限制行為能力人，須得法定代理人允許，所為之遺囑方為有效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-3301-045', '114-3301', 45, 'single_choice', '繼承人未開具遺產清冊時，關於清償被繼承人之債務，下列敘述，何者錯誤？', '繼承人對於被繼承人債權人之無擔保債權，仍應按其數額，比例計算，以遺產分別償還', '繼承人在違法清償後，得對不當受領之債權人，請求返還其不當受領之數額', '繼承人按其行為能力，於違法清償被繼承人之債務時，異其責任', '債權人得向法院聲請命繼承人於三個月內提出遺產清冊', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-046', '114-3301', 46, 'single_choice', '單親父親甲有子女乙、丙、丁、戊四人，其中乙育有一女己，丙育有一女庚，丁育有一子辛，戊育有 一子壬。甲死亡時，下列關於代位繼承之敘述，何者錯誤？', '若乙與甲飛機失事同時死亡，己得代位繼承乙之應繼分', '若丙於甲生前故意殺丁未遂但被判刑確定者，甲死亡時，由庚代位繼承丙之應繼分', '若丁於甲死後首先發現其遺囑，但立即將其燒燬湮滅時，由辛代位繼承丁之應繼分', '若戊於甲死後，依法辦理拋棄繼承時，由壬代位繼承戊之應繼分', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-047', '114-3301', 47, 'single_choice', '下列何種紛爭，當事人無法請求法院定之？', '繼承人就遺產之管理方法，既無法達成協議，亦無法達成民法第828 條第2 項準用第820 條第1 項 有關共有物管理規定之決定', '夫妻離婚時，就未成年子女權利義務之行使或負擔，無法協議達成由一方或雙方共同任之', '扶養義務人與扶養權利人，就扶養費之金額，無法達成協議', '繼承人與遺囑執行人，就遺囑執行之報酬，無法達成協議', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-048', '114-3301', 48, 'single_choice', '被繼承人甲有妻乙、子丙、孫丁與母戊，下列何者非屬民法第1145 條所謂故意致應繼承人於死之 情形？', '乙殺害丙', '丁殺害戊', '丙殺害乙', '丁殺害丙', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-049', '114-3301', 49, 'single_choice', '甲有一子乙已成年。甲生前對丙、丁各負有債務新臺幣（下同）100 萬元。甲死亡時，僅有遺產100 萬元。乙未開具遺產清冊陳報法院，因此僅知甲對丙負有債務，對丁之部分，則毫無所知。乙將甲之 遺產全部對丙清償。下列敘述，何者正確？', '乙依法負有限責任，對丁之部分，無須償還', '乙得對丙請求返還50 萬元', '乙應以自己之財產，對丁償還100 萬元', '乙應以自己之財產，對丁償還50 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-050', '114-3301', 50, 'single_choice', '甲、乙為夫妻，甲死亡時，乙與甲之兄妹丙、丁二人共同繼承。乙分得市價新臺幣（下同）600 萬元 之房屋。丙、丁各分得300 萬元之古董、土地。丙分得之古董有瑕疵，經重新鑑價結果，僅價值180 萬元。丙向乙、丁請求損害賠償時，丁已無支付能力，不能償還其分擔額。乙應分擔多少金額之損害？', '80 萬元', '75 萬元', '60 萬元', '90 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-051', '114-3301', 51, 'single_choice', '關於民事訴訟上之訴訟權保障，下列敘述，何者正確？', '基於有權利即有救濟之憲法原則，非因犯罪而受損害之人，於刑事訴訟程序附帶提起民事訴訟者， 如經刑事庭移送至民事庭，應許原告補繳裁判費，以補正起訴程式之欠缺', '為保障當事人之聽審請求權，交付法庭錄音光碟之聲請，縱已逾越法定期限，亦應准許之', '當事人因重大過失，逾時始行提出攻擊或防禦方法，有礙訴訟之終結者，法院仍應許其提出，以保 障聽審請求權', '基於當事人訴訟權之保障，上訴人有律師為訴訟代理人者，如未依規定預納上訴審之裁判費，法院 亦應給予補正之機會，不得逕認上訴不合法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-052', '114-3301', 52, 'single_choice', '下列何種情形，受訴法院有管轄權？', '甲住臺南市，乙住臺中市，甲、乙共有坐落臺南市之A 地，甲向乙住所所在之臺灣臺中地方法院起 訴，請求分割A 地', '甲住新竹市，乙住新竹縣，甲所有坐落苗栗縣之A 建物遭乙無權占有，甲向臺灣新竹地方法院（下 稱新竹地院）提起所有物返還訴訟，請求乙騰空返還A 建物，乙已到庭應訴為本案之言詞辯論', '甲住新竹市，乙住桃園市，甲向乙購買坐落桃園市之A 地，雙方簽訂不動產買賣契約書之書面，契 約書載有如因該買賣契約爭議而涉訟，以新竹地院為第一審管轄法院，嗣乙拒絕履行該買賣契約， 甲向新竹地院起訴請求乙履行契約移轉A 地', '甲住新竹市，乙住新竹縣，甲所有坐落苗栗縣之A 地遭人冒名設定抵押權予乙，甲乃以該抵押權不 存在為由，向新竹地院起訴，請求乙塗銷該抵押權登記', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-3301-053', '114-3301', 53, 'single_choice', '甲列乙為被告向行政法院起訴，經行政法院移送到民事法院，民事法院認為無審判權，下列敘述，何 者錯誤？', '原則上民事法院應裁定停止訴訟程序，請求最高法院指定有審判權之管轄法院', '甲、乙均具狀或記明筆錄表示合意由民事法院裁判，則民事法院不得裁定停止訴訟程序', '於指定有審判權之管轄法院前，甲和乙應有陳述意見之機會', '民事法院就行政法院移送之訴訟為裁判，上級法院仍可以無審判權為由廢棄裁判', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-3301-054', '114-3301', 54, 'single_choice', '未成年人甲1、甲2 共同毆打乙致傷，乙乃列甲1 之法定代理人丙1、甲2 之法定代理人丙2 為共同 被告，均依民法第187 條第1 項規定起訴請求賠償。下列敘述，何者錯誤？', '第一審法院判決乙全部勝訴者，如僅丙1 提起上訴，有關丙2 部分之判決即先行確定', '丙1 為時效完成得拒絕給付之抗辯者，縱丙2 未援用該抗辯，法院仍得據以駁回乙所提全部之訴', '乙得僅與丙2 成立訴訟上和解，並續行對於丙1 部分之訴訟', '乙主張其受有肢體傷害之事實經丙1 自認者，如丙2 並未自認，有關丙2 部分之訴訟，法院不受丙 1 之自認所拘束', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-3301-055', '114-3301', 55, 'single_choice', '甲為投資客，向乙買受A 屋後又轉賣予丙，丙嗣後主張A 屋有漏水情事，起訴請求甲減少價金。甲 表示其持有A 屋時間不到1 個月，對A 屋實際上狀況不清楚，應該是乙比較清楚實際上屋況，遂請 求法院對乙為訴訟告知。下列敘述，何者正確？', '甲於言詞辯論期日得以言詞為訴訟告知之表示，並由書記官記明筆錄，再將筆錄送達予乙即可', '訴訟告知之目的在使受告知人得準備為訴訟行為，故如甲提出告知書狀時，非由甲逕自送達乙，而 應由法院將書狀送達給乙及丙', '乙受訴訟告知後，因有利害關係，故必須參加訴訟，但對於參加於甲或丙之訴訟，有其自由', '告知訴訟後，為確保乙權益，法院應於乙參加前裁定停止訴訟程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-3301-056', '114-3301', 56, 'single_choice', '同日在A 公司經營之樂園遊玩，因設備故障受有損害之甲、乙、丙等共30 人，擬起訴向A 公司請求 損害賠償。關於選定當事人制度，下列敘述，何者錯誤？', '甲、乙、丙等共30 人得在30 人中選定甲1 個人或同時選定甲、乙、丙，為30 人全體起訴', '訴訟繫屬後，甲、乙、丙等共30 人選定甲1 個人為被選定人，則其他29 人脫離訴訟', '選定乙為被選定人及其更換、增減，均應以文書證之', '選定人不得在文書上載明或以書狀提出於法院限制被選定人丙捨棄、認諾、撤回、和解之權限', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-3301-057', '114-3301', 57, 'single_choice', '關於訴訟標的價額之計算，下列敘述，何者錯誤？', '因撤銷詐害債權涉訟，以債權人主張之債權額為準；但被撤銷法律行為標的之價額低於債權人所主 張之債權額時，以該被撤銷之標的價額為準', '債權人代位債務人向第三人提起訴訟者，以債務人與第三人間之權利義務關係為準', '因分割遺產涉訟，以全部遺產於起訴時之總價值為準', '訴訟標的之價額不能核定者，以民事訴訟法所定不得上訴第三審之最高利益額數加十分之一定之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-3301-058', '114-3301', 58, 'single_choice', '關於民事訴訟上法院命合併或分別辯論之職權，下列敘述，何者錯誤？', '甲、乙分別對丙提起之訴訟，經法院命合併辯論者，應依共同訴訟之規定辦理之', '經合併辯論之數宗訴訟，其當事人俱不相同或僅有一造相同者，法院不得合併裁判', '甲合併對乙、丙提起之訴訟，其訴訟標的對於乙、丙必須合一確定者，法院不得命分別辯論', '甲對乙提起預備合併之訴，其先、備位之訴不能同時併存者，法院不得命分別辯論', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-3301-059', '114-3301', 59, 'single_choice', '當事人經合法送達，關於其無正當理由而未於期日到場之效力，下列敘述，何者錯誤？', '言詞辯論期日原告到場、被告未到場時，原告得聲請一造辯論判決', '言詞辯論期日原告未到場、被告到場時，如被告拒絕辯論，則視為合意停止訴訟程序', '言詞辯論期日，兩造均未到場時，除別有規定外，視為合意停止訴訟程序', '言詞辯論期日原告未到場時，被告不能聲請一造辯論判決，僅能由法院依職權判定是否宜一造辯論 而為判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-3301-060', '114-3301', 60, 'single_choice', '關於民事訴訟上之突襲性裁判，下列敘述，何者錯誤？', '原告於言詞辯論期日當庭追加某請求權基礎，此前被告就該請求權基礎未有主張聲明或陳述之機會 者，如法院逕諭知辯論終結，並依該請求權基礎判決原告勝訴，應屬突襲性裁判', '當事人主張之事實，究竟該當於發生何項法律關係，乃屬法官依職權所為之法律適用問題，不受當 事人主張或陳述之拘束，是法院所認當事人間之法律關係，與當事人所陳述或表明者，縱有不同， 逕採為判決之基礎，亦無突襲性裁判可言', '當事人所未提出之事實，係法院於審理過程中知悉其存在者，如法院遽行以之為判決之基礎，即生 突襲性裁判', '原告已陳明僅主張甲請求權基礎，沒有要主張乙請求權基礎者，如法院認甲請求權基礎不存在，即 行判決原告敗訴，尚非突襲性裁判', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-3301-061', '114-3301', 61, 'single_choice', '甲機關起訴主張乙於任職期間，借用A 宿舍，現乙已退休，使用借貸之目的完畢，請求乙返還A 宿 舍。乙則抗辯使用借貸之目的尚未完畢，如法院認其仍應返還宿舍，因其每月之退休金僅新臺幣（下 同）2 萬元，生活困難，聲請法院酌給適當履行期間，利其謀得棲身之所。第一審法院審理結果，認 為乙應返還A 宿舍予甲，並定履行期間。關於履行期間部分，下列敘述，何者錯誤？', '就應否給予履行期間，法院應令甲、乙進行辯論', '訴訟中經甲同意，法院得給予乙1 年之履行期間', '甲、乙未能達成合意，第一審法院審理後發現乙確實生活困難，孤身一人，並無親友，得酌定給予 2 年之履行期間', '第一審於民國111 年3 月13 日宣示判決乙應返還宿舍，但履行期間2 年。甲得提供150 萬元為乙 擔保後得假執行。該判決於111 年3 月16 日送達乙，於同年4 月30 日確定。甲未供擔保聲請假執 行，乙之履行期間應自判決確定之日起算', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-3301-062', '114-3301', 62, 'single_choice', '原告甲列乙為被告，向該管法院起訴，訴之聲明為：乙應給付甲新臺幣（下同）200 萬元。其事實主 張略以：乙於民國110 年1 月10 日向甲購買貨品一批，價金為200 萬元，乙為支付該價金，乃簽發 同額支票交付予甲，經提示後竟遭退票，爰依票據關係，求為判決如訴之聲明等語。經受訴法院向甲 闡明，依其聲明及事實上之陳述，尚得主張買賣價金給付請求權。下列敘述，何者正確？', '經闡明後，不問甲有無表明要主張價金給付請求權，依法官知法原則，應就甲之票款給付請求權及 買賣價金給付請求權是否有理由均逐一為本案審理，並為本案判決', '經闡明後，如甲表明要合併主張依買賣關係請求乙給付價金時，甲不得請求依選擇合併之方式為本 案審理', '經闡明後，甲表明在本件訴訟亦要一併主張依買賣關係請求時，則受訴法院應適用通常訴訟程序為 本案審判', '經闡明後，甲表明在本件訴訟亦要一併主張依買賣關係請求，而乙抗辯甲之票款請求已經罹於消滅 時效時，甲不得請求受訴法院先就價金債權存否為本案審判', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-3301-063', '114-3301', 63, 'single_choice', '原告甲列乙為被告，向管轄法院起訴請求判決命乙給付新臺幣（下同）200 萬元，主張：丙於某日向 甲借用200 萬元，由乙為其保證人，未依約定期限償還借款，為此提起本訴訟等語。對此，乙聲明求 為判決駁回甲之請求，辯稱：丙對甲不負有借款債務，所以乙無須負保證責任云云。下列敘述，何者 錯誤？', '丙經法院許可後，得參加本訴訟之和解', '丙於參加本訴訟之和解後，得與甲、乙一同提出書狀向本訴訟之受訴法院表明在甲請求金額之150 萬元以內，三人均願意照法院所定方案來解決紛爭', '在本訴訟之和解程序上，甲與丙同意由丙償還系爭借款200 萬元經記明和解筆錄後，甲得據此為執 行名義', '法院將和解方案送達於聲請定和解方案之丙時，視為和解成立，與確定判決有同一之效力，此後在 甲訴請丙償還系爭借款債務（主債務）之後訴訟，該2 人均不得再爭執該主債務存否', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-3301-064', '114-3301', 64, 'single_choice', '關於判決基礎資料之蒐集，得否將當事人本人作為證據方法加以調查，下列敘述，何者錯誤？', '在受訴法院認為當事人本人所親身經歷之事實可資以推定應證事實存否時，法院得命該當事人本人 到庭為陳述，無須先經他造當事人之同意', '法院為了蒐集證據資料以形成心證認為有需通知某一造當事人本人在言詞辯論期日到庭陳述時，如 該本人不從法院之命而無正當理由不到場，法院於必要時，尚得命將該本人拘提到庭', '受訴法院認為當事人本人所親身經歷之事實可資以推定應證事實存否，乃命該本人到庭，此時如受 訊問事項涉及其職務上或業務上應遵守秘密義務者，該本人得拒絕陳述', '法院為了蒐集證據資料以形成心證認為有需通知某一造當事人本人在言詞辯論期日到庭陳述時，如 該本人到庭而拒不陳述，經法院闡明後亦不說明具體之理由，則法院得予以審酌並依自由心證認定 應證事實之存否', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-3301-065', '114-3301', 65, 'single_choice', '下列何者，不符合民事訴訟法規定之證據調查方法？', '囑託臺灣證券交易所調查被告在集中交易市場之證券交易明細', '囑託他法院詢問住在當地之證人', '前往法院轄區外勘驗房屋狀態、利用狀況，並囑託內政部國土測繪中心測量該房屋坐落位置及面積', '囑託臺北市結構工程工業技師公會鑑定房屋結構安全，並命該公會指派之主辦鑑定技師在結文具結 後，作成鑑定報告送交法院', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-3301-066', '114-3301', 66, 'single_choice', '關於法院進行之調解，下列敘述，何者錯誤？', '當事人成立之調解，與確定判決具有相同之效力', '移付調解限於第一審程序，第二審程序不得為之', '起訴前之調解成立後，當事人得提起宣告調解無效或撤銷調解之訴', '當事人合意起訴前應先行調解者，一方逕行起訴，經他方為本案之言詞辯論後，不得再抗辯調解先行', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-3301-067', '114-3301', 67, 'single_choice', '關於簡易訴訟程序與通常訴訟程序之轉換，下列敘述，何者錯誤？', '甲訴請乙返還借款新臺幣（下同）40 萬元，嗣於訴訟中擴張為60 萬元，除甲、乙合意繼續適用簡 易訴訟程序外，應由簡易庭法官裁定改用通常訴訟程序並繼續審理', '甲訴請乙返還借款40 萬元，嗣於訴訟中擴張為60 萬元，如乙逕為本案言詞辯論，應視為已有適用 簡易訴訟程序之合意，並繼續適用簡易訴訟程序審理', '甲訴請乙返還借款60 萬元，嗣於訴訟中減縮為40 萬元，應由普通庭法官裁定改用簡易訴訟程序並 繼續審理', '甲訴請乙返還借款60 萬元，嗣於訴訟中減縮為40 萬元，然法院仍繼續適用通常訴訟程序審理並判 決，經乙向高等法院提起上訴，高等法院應適用通常訴訟事件第二審程序審理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-3301-068', '114-3301', 68, 'single_choice', '關於小額訴訟之審理程序，下列敘述，何者錯誤？', '法院認為適用小額程序不適當，得依職權以裁定改用簡易程序，並由原法官繼續審理', '當事人均不得為適用小額程序而為一部請求', '調查證據所需時間、費用與當事人請求顯不相當時，法院得不調查證據，審酌一切情況，認定事實， 為公平之裁判', '當事人為訴之變更、追加或提起反訴，致請求給付超過新臺幣10 萬元，除兩造合意繼續適用小額 程序並經法院認為適當外，不得為之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-3301-069', '114-3301', 69, 'single_choice', '甲以其他全部共有人乙、丙、丁為被告，起訴請求分割共有土地，經一審法院判決後，乙對一審判決 聲明不服，合法提起上訴。下列敘述，何者正確？', '若丙、丁對一審判決並未聲明不服，乙上訴效力即不及於丙、丁2 人', '乙於二審法院審理中，向法院具狀撤回上訴，無待通知其他當事人，即生撤回上訴之效力', '丙於二審法院審理中，將其應有部分移轉予戊，法院應依聲請或依職權命戊承受訴訟', '訴外人己主張丁之應有部分實為其借名登記，己已取得確定判決命丁返還該借名登記之應有部分， 惟尚未依確定判決辦理登記，己可聲請參加訴訟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-3301-070', '114-3301', 70, 'single_choice', '甲主張乙侵害其名譽權，依民法第184 條第1 項前段、第195 條第1 項規定，起訴請求乙賠償非財產 上損害新臺幣180 萬元。經第一審法院判決甲全部敗訴，甲提起第二審上訴，仍遭第二審法院駁回上 訴。下列敘述，何者正確？', '甲所委任之律師，以第二審判決有不備理由之違法，提起第三審上訴，不必於上訴理由狀中具體敘 述為從事法之續造，確保裁判之一致性或其他所涉及之法律見解具有原則上重要性之理由', '甲就第二審判決，委任律師提起第三審上訴，不論上訴理由為何，均毋庸經第三審法院許可', '甲委任律師為訴訟代理人提起第三審上訴，如被上訴人乙未委任律師為訴訟代理人，法院應速命其 補正', '甲不得提起第三審上訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-3301-071', '114-3301', 71, 'single_choice', '原告甲起訴請求判決命被告乙返還借款新臺幣（下同）900 萬元，主張：乙向甲借款900 萬元，於民 國113 年6 月6 日簽發面額1,000 萬元、到期日為同年10 月6 日之本票一紙交予甲作為清償方法， 屆期經提示未獲兌現，為此請求乙返還借款等語。第一審經本案審理後判決駁回原告之訴，甲上訴後， 第二審改判命乙償還借款1,000 萬元，乙上訴於第三審。下列敘述，何者正確？', '第二審法院為訴外裁判，屬違背法令，第三審法院應將第二審判決廢棄，全部發回更審', '第三審法院發回更審時，指出乙有無向甲借款900 萬元之事實尚待查明，第二審更審法院須受該發 回意旨之拘束，僅得調查該事實', '第二審判決命乙給付超過甲請求金額100 萬元之部分，既為訴外裁判，當然無效，乙不須上訴，第 三審法院亦不須將該部分廢棄', '乙在事實審始終否認借款之事實，第二審法院僅以乙有簽發本票之事實為憑，別無其他佐證，即認 定兩造間因訂立消費借貸契約而有借貸關係，第三審法院得以第二審法院之事實認定違背經驗法則 及證據法則為由，廢棄原判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-3301-072', '114-3301', 72, 'single_choice', '關於簡易訴訟程序之第二審判決提起第三審上訴者，下列敘述，何者錯誤？', '當事人於判決送達後提起第三審上訴，但未同時表明上訴理由者，法院應命其補正之', '當事人提起第三審上訴，惟該事件所涉之法律見解如不具有原則上重要性者，原法院應駁回其上訴', '若其上訴利益額已逾上訴第三審之上訴利益額者，當事人應以其適用法規顯有錯誤為理由，向最高 法院提起上訴', '當事人提起第三審上訴時，應經原裁判法院之許可', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-3301-073', '114-3301', 73, 'single_choice', '甲向臺灣臺北地方法院（下稱臺北地院）起訴請求判命乙應返還借款新臺幣100 萬元及其法定遲延利 息，法院適用通常訴訟程序審理之結果，認為甲之請求無理由，乃判決駁回原告甲之訴，甲對該判決 不服提起上訴。關於第二審上訴，下列敘述，何者正確？', '甲所提上訴，其管轄法院仍為臺北地院，並非臺灣高等法院，惟臺北地院之第二審審判須以合議為 之，不得由獨任法官審判', '甲逾法定上訴期間所為之上訴，臺北地院不得以上訴不合法為由裁定駁回上訴', '甲未於上訴狀內表明上訴理由，為上訴不合法，臺北地院應定期命提出，如逾期未補正者，第二審 法院應以裁定駁回上訴', '甲上訴未繳納上訴裁判費，若臺北地院曾定期命其補正而未補正，第二審法院得不再命補正，逕予 裁定駁回上訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-3301-074', '114-3301', 74, 'single_choice', '關於再審訴訟之裁判，下列敘述，何者錯誤？', '再審原告提起再審之訴已逾30 日之不變期間者，法院應以再審之訴不合法，以裁定駁回之', '法院認再審之訴合法，但無再審理由者，應以判決駁回再審之訴', '法院認有再審理由者，應為開始再審之裁定，待裁定確定後，始依其審級之程序更為本案審理', '法院認再審之訴雖有再審理由，但原確定判決為正當者，仍應以判決駁回再審之訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-3301-075', '114-3301', 75, 'single_choice', '甲持有付款人為乙銀行之系爭支票1 張，因故不慎遺失，經辦理票據掛失止付後，擬向法院聲請公示 催告及除權判決。下列敘述，何者錯誤？', '法院依書面審理，審查聲請人所提出之事證，如認符合法律規定，即得以除權判決宣告系爭支票無效', '甲得於公示催告裁定所定申報權利之期間已滿後3 個月內，聲請除權判決', '甲具狀向法院聲請公示催告後，法院應就該聲請為裁定；法院准許聲請者，應為公示催告', '應由證券所載履行地之法院，即付款人乙銀行所在地之法院管轄', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-3301-076', '114-3301', 76, 'single_choice', '甲列乙為被告，提起給付新臺幣200 萬元之訴訟，第一審法院准許甲之假扣押聲請，乙不服提起抗告。 關於抗告法院所為之裁定及後續之程序，下列敘述，何者錯誤？', '抗告法院認乙之抗告有理由，廢棄原裁定而自為裁定，若非適用法規顯有錯誤，甲不得再為抗告', '抗告法院認乙之抗告無理由，而為駁回之裁定，若非適用法規顯有錯誤，乙不得再為抗告', '無論抗告法院認乙之抗告有無理由而為裁定，抗告權人欲再為抗告而未委任律師為訴訟代理人者， 抗告不因此而不合法', '抗告法院認乙之抗告不合法而駁回者，乙不得再為抗告，但得提出異議', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-3301-077', '114-3301', 77, 'single_choice', '甲男與前妻育有一子丙，後甲與乙女未婚生下一子丁，甲拒不認領丁，乙遂以甲為被告提起認領子女 之訴（下稱A 訴訟），並基於不當得利返還請求權合併請求甲返還乙過去支出之子女扶養費（下稱B 訴訟）。下列敘述，何者正確？', '如乙於判決確定前死亡，丁得於知悉乙死亡時起10 日內聲明承受A 訴訟，B 訴訟則視為終結', '如甲於判決確定前死亡，其繼承人丙得承受A 訴訟與B 訴訟', '甲與乙得就A 訴訟與B 訴訟成立訴訟上和解', '如甲就A 訴訟與B 訴訟之訴訟標的為認諾，為求訴訟經濟，法院應為甲敗訴之本案判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-3301-078', '114-3301', 78, 'single_choice', '關於家事非訟事件之定性，下列敘述，何者錯誤？', '父母之一方，依民法第1090 條規定，請求法院宣告停止他方對於未成年子女之權利者，其事件為 家事非訟事件', '養父母、養子女之一方，依民法第1081 條規定，請求法院宣告終止雙方之收養關係者，其事件為 家事非訟事件', '子女之一之友人，依民法第179 條規定，請求其他子女返還其代墊該子女之父母日常生活費用者， 其事件為家事非訟事件', '家庭暴力之受害人，依家庭暴力防治法相關規定，請求法院對於家庭暴力之加害人核發通常保護令 者，其事件為家事非訟事件', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-3301-079', '114-3301', 79, 'single_choice', '關於家事身分訴訟事件之審理原則，下列敘述，何者正確？', '應限制處分權主義，是離婚訴訟之當事人不得為訴訟上和解', '應限制辯論主義，是撤銷婚姻訴訟之當事人，就構成撤銷婚姻之原因事實為自認者，不生效力', '應限制公開主義，是確認親子關係存在之訴，縱經法律上利害關係人聲請，其處理程序亦不許旁聽', '應限制言詞主義，是認領之訴，其判決得不經言詞辯論為之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-3301-080', '114-3301', 80, 'single_choice', '甲之繼承人為其妻乙及子丙、丁，丁起訴請求依甲之遺囑分割遺產後，乙另對丙、丁起訴，請求分配 甲、乙間之夫妻剩餘財產。下列敘述，何者錯誤？', '乙、丙、丁對於夫妻剩餘財產分配及分割遺產縱使達成合意，不可成立訴訟上和解，仍應由法院裁判', '在分割遺產訴訟，若乙或丙認為丁提出之遺囑非屬真正，得反請求確認遺囑無效', '丁提起分割遺產訴訟，應以乙、丙為共同被告', '法院得將乙提起之夫妻剩餘財產分配訴訟，移送由分割遺產訴訟法院合併審理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-4301-001', '114-4301', 1, 'single_choice', '非公開發行且非閉鎖性之A 股份有限公司，不得於章程中明訂發行下列何種之特別股？', '每股有10 個表決權之特別股', '得當選一席董事之特別股', '對經理人任免具否決權之特別股', '附轉讓限制之特別股', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-4301-002', '114-4301', 2, 'single_choice', 'A 有限公司（下稱A 公司）之股東為甲、乙、丙、丁及戊5 人，每位股東出資新臺幣（下同）50 萬 元，股東表決權係按出資比例分配。A 公司擬增資100 萬元，甲、乙及丙表示贊成，丁及戊反對。依 公司法之規定，下列敘述何者正確？', '甲贊成本件增資案，故有按出資比例進行增資之義務', '丙贊成本件增資案，但不負出資義務', '乙贊成本件增資案，但因資金短缺，得自行邀請第三人辛出資而成為新股東', '丁反對本件增資案，但得將其分配到之增資額度，自行邀請第三人庚出資而成為新股東', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-4301-003', '114-4301', 3, 'single_choice', '下列有關公司名稱之敘述，何者正確？', '公司不得使用與其他公司相同之名稱，但若該公司業經廢止登記，自廢止登記之日起，逾10 年未 清算完結者，原則上該公司名稱仍得申請核准使用', '公司名稱被法院判決確定不得使用，公司於判決確定後6 個月內未辦妥名稱變更登記者，主管機關 應即命令公司解散', '公司名稱不得使用易於使人誤認其與公益團體有關之名稱，除非獲得該公益團體之同意，則可不受 限制', '兩公司之特取名稱雖相同，但只要公司名稱中有標明不同公司種類，則視為不相同', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-4301-004', '114-4301', 4, 'single_choice', '股票未公開發行之A 公司（下稱A 公司）為B 上櫃公司（下稱B 公司）之原料供應商，某次A 公司 增資發行新股時，就原有股東未認購之部分，洽B 公司認購，B 公司章程並未有轉投資之相關規定。 依公司法之規定，下列敘述何者正確？', 'A 公司股票未公開發行，無論B 公司認購A 公司股份之金額多寡，僅須董事會決議即得為之', 'B 公司章程並未有轉投資之相關規定，故B 公司認購A 公司股份之金額並無限制', 'B 公司認購A 公司股份之金額如超過B 公司實收股本之40%，則須經過B 公司股東會特別決議始 得為之', 'A 公司股票未公開發行，B 公司不得認購A 公司股份', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-4301-005', '114-4301', 5, 'single_choice', '甲為已成年之自然人，擬設立一家公司。依公司法規定，下列敘述何者錯誤？', '如甲選擇設立有限公司，得以勞務作為出資方式', '如甲選擇設立股份有限公司，須再找一名股東始得設立', '如甲選擇設立有限公司，甲一人即可設立', '如甲選擇設立股份有限公司，得以技術作為出資方式', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-4301-006', '114-4301', 6, 'single_choice', 'A 股份有限公司（下稱A 公司）持有B 股份有限公司（下稱B 公司）已發行有表決權股份總數5%之 股權，但A 公司對B 公司之人事、財務與業務具有實質掌控力。民國110 年1 月至12 月，B 公司向 A 公司採購產品，惟A 公司索取之對價為超乎市場價格之不當高價，造成B 公司蒙受新臺幣（下同） 1,000 萬元之損失，下列敘述何者錯誤？', 'A 公司及其董事對B 公司之1,000 萬元損害負連帶賠償責任', '若B 公司對A 公司本有1,000 萬元之債權，A 公司不得主張以其對B 公司所有之上述1,000 萬元貨 款債權抵銷之', 'A 公司對B 公司因上述交易而產生之1,000 萬元貨款債權，在B 公司破產時，不得優先於其他債 權人受償，其受償次序與一般債權人同', 'A 公司與B 公司間之交易若使B 公司受有損害，繼續1 年以上持有B 公司已發行有表決權股份總 數1%以上之股東，得以自己名義，請求A 公司向B 公司為損害賠償', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-4301-007', '114-4301', 7, 'single_choice', '公司法中關於有限公司之規定，下列敘述何者正確？', '有限公司之清算，準用無限公司相關規定', '有限公司變更章程，應經股東表決權四分之三以上之同意', '有限公司解散時，應有全體股東之同意', '有限公司合併時，應經股東表決權過半數之同意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-008', '114-4301', 8, 'single_choice', 'A 股份有限公司（下稱A 公司）為非公開發行股票公司，因業務擴展，有擴建廠房及擴充設備需求， 有意向大眾投資人募資。依公司法規定，有關公司對外公開發行股票之規定，下列敘述何者錯誤？', 'A 公司對外募集股份，仍需保留發行新股總數百分之十至十五之股份由公司員工承購', 'A 公司有資產不足抵償債務之情形，惟依其事業性質，須有較長準備期間或具有健全之營業計畫， 確能改善營利能力者，仍得對外公開發行', 'A 公司公開發行新股時，應以現金為股款', 'A 公司若最近3 年皆為虧損，不得公開發行具有優先權利之特別股', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-009', '114-4301', 9, 'single_choice', 'A 上市公司（下稱A 公司）因財務困難，由最大債權人B 銀行向法院聲請重整，經法院審理後裁定 開始重整，依法律規定及實務見解，下列關於法院所為重整裁定之敘述，何者正確？', '法院不得選派A 公司之董事擔任重整人', 'B 銀行雖為法人組織，法院仍得選派B 銀行為重整人', '關係人會議分組行使表決權之結果，有任何一組主張另行選定重整人時，得提出候選人名單，聲請 法院選派之', '法院為重整裁定時，應選任A 公司之獨立董事或獨立監察人為重整監督人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-010', '114-4301', 10, 'single_choice', '公司法於民國104 年7 月引進閉鎖性股份有限公司制度，關於此制，下列敘述何者錯誤？', '閉鎖性股份有限公司專節增訂後，公司法第2 條規定之公司種類增加為5 種', '閉鎖性股份有限公司必為非公開發行股票公司', '閉鎖性股份有限公司雖不得公開發行或募集有價證券，但得經由證券商經營股權群眾募資平臺募資', '閉鎖性股份有限公司之股東人數上限，中央主管機關得視社會經濟情況及實際需要增加之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-011', '114-4301', 11, 'single_choice', 'A 有限公司（下稱A 公司）資本額新臺幣（下同）300 萬元，經營績效良好，歷年提撥之法定盈餘公 積已達300 萬元，有甲、乙及丙等3 位股東各出資100 萬元，由甲擔任董事，章程並訂明以當年度獲 利狀況之10%，分派員工酬勞。關於其今年財務及會計處理之敘述，下列何者正確？', 'A 公司於彌補虧損完納一切稅捐後，分派盈餘時，應先提出10%為法定盈餘公積', '每屆會計年度終了，董事甲應依法造具各項表冊，分送各股東，請其承認；其承認應經股東表決權 三分之二之同意', 'A 公司得以章程訂定，或經股東表決權三分之二以上之同意，另提特別盈餘公積', '董事甲得決定員工酬勞以股票為之，並向乙及丙報告', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-012', '114-4301', 12, 'single_choice', 'A 股份有限公司（下稱A 公司）進行下列何事項時，須變更公司章程？', 'A 公司章程規定：「本公司資本總額定為新臺幣5,000 萬元，分為500 萬股。每股金額新臺幣10 元。」若A 公司已發行股份為300 萬股，A 公司為改善財務結構，減資100 萬股彌補虧損，再增資 100 萬股，引進新資金', 'A 公司已發行之甲種特別股享有兩倍股息及紅利之權利，A 公司近年獲利情況不佳，欲縮減甲種 特別股股東股息與紅利', 'A 公司因公開發行成本過高，申請停止公開發行', 'A 公司之股東會為解散之決議', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-013', '114-4301', 13, 'single_choice', 'A 股份有限公司為非公開發行股票公司，若將公司之盈餘分派從年度分派，改為每季分派，下列敘述 何者正確？', '公司做每季分派不需章程規定，惟須經董事會特別決議後始得為之', '若要進行分派，公司當季需有獲利，惟公司累積虧損得待會計年度終了後，再進行彌補', '第三季終了後分派盈餘，若發放股票股利，無須經股東會決議通過', '第一季終了後分派盈餘，若發放現金股利，僅須經董事會決議通過', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-014', '114-4301', 14, 'single_choice', 'A 有限公司（下稱A 公司）共有甲、乙、丙、丁及戊5 位股東，甲及乙擔任董事。依公司法相關規 定，下列敘述何者正確？', 'A 公司章程設置董事長之規定，應經股東表決權過半數之同意選任之', 'A 公司章程未設置董事長者，董事甲和乙均得代表公司', '丙行使監察權時，得代表公司委託律師或會計師審核之，但應自行負擔費用', '丁行使監察權時，得經法院許可，向董事甲和乙質詢公司營業情形，查閱財產文件、帳簿及表冊', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-4301-015', '114-4301', 15, 'single_choice', 'A 股份有限公司（下稱A 公司）持有B 股份有限公司（下稱B 公司）已發行股份總數百分之六十， 並指派其代表人甲擔任B 公司董事。A 公司與B 公司擬合併，於B 公司董事會、股東會表決「與A 公司合併」議案時，甲、A 公司應否迴避表決？', '甲、A 公司皆應迴避', '僅甲應迴避', '僅A 公司應迴避', '甲、A 公司皆無須迴避', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-4301-016', '114-4301', 16, 'single_choice', '有關保險業、銀行、保險經紀人及代理人可經營的業務範圍，下列何者錯誤？', '財產保險業經營財產保險，人身保險業經營人身保險，同一保險業不得兼營財產保險及人身保險業 務。但財產保險業經主管機關核准經營傷害保險及健康保險者，不在此限', '銀行經主管機關許可，可擇一兼營保險代理人或保險經紀人或保險公證人業務', '經紀人公司得申請經營保險經紀業務、再保險經紀業務、或同時經營保險經紀業務及再保險經紀業 務；經紀人同時具備財產保險及人身保險經紀人資格者，得同時申領財產保險及人身保險經紀人執 業證照', '代理人同時具備財產保險及人身保險代理人資格者，除經主管機關核准外，僅得擇一申領財產保險 或人身保險代理人執業證照', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-4301-017', '114-4301', 17, 'single_choice', '甲以其所有作為營業用之A 房屋，向X 保險公司（下稱X 公司）投保商業火險，於保險期間，因所 營業務狀況不好，甲遂結束於A 屋之營業並將A 屋作為純住宅使用。依我國保險法之規定，下列敘 述何者正確？', '甲應於結束A 屋之營業前10 日通知X 公司', '甲只需於A 屋之營業結束後通知X 公司即可', 'X 公司得終止契約', '甲得請求X 公司重新核定保險費', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-4301-018', '114-4301', 18, 'single_choice', '甲向乙以附條件買賣方式租買新車乙部，甲分期支付租買價金，三年支付全部價金後，甲取得汽車所 有權。甲以自己為被保險人向A 保險公司投保汽車之甲式車損及竊盜險新臺幣300 萬元，並約定乙 為事故損失保險金受款人。租買及保險期間，汽車在甲返交乙進行定期保養時，乙違規駕駛致汽車全 損，乙向A 保險公司請求全額車損賠償，A 保險公司主張本件無保險利益，保單失其效力，試問有無 理由？', '有理由，甲非汽車所有權人，無保險利益', '無理由，甲為汽車之承租人，具保險利益', '有理由，甲對汽車的保險利益應至清償所有分期租買款項取得汽車所有權時方具保險利益', '無理由，乙為事故損失保險金受款人且為契約所有權人，具保險利益，因此保單有效', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-4301-019', '114-4301', 19, 'single_choice', '甲以其配偶乙為被保險人，指定甲為受益人，投保死亡保險，並約定保險金額，經乙書面同意。數年 後，甲、乙離婚，乙於離婚後一年死亡，死亡前尚未撤回同意。下列敘述何者正確？', '甲不得請求保險給付，因離婚後甲對乙已無保險利益，契約失其效力', '甲不得請求保險給付，因離婚後甲喪失受益人資格', '甲得請求保險給付，因契約訂立時甲為乙之配偶，且保險契約仍持續具效力', '甲得請求保險給付，但因甲、乙已離婚，保險公司只須退還甲保險費', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-4301-020', '114-4301', 20, 'single_choice', '為保障保戶及股東權益，保險法規定保險業自有資本與風險資本之比率及淨值比率，不得低於一定比 率，並劃分為數種資本等級。其中針對資本顯著不足的保險業，主管機關得令其降低對負責人、經理 人之報酬。其降低後之報酬不得超過該保險業資本等級列入資本顯著不足等級前十二個月內對該負責 人支給平均報酬之百分比為何？', '百分之七十', '百分之七十五', '百分之八十', '百分之九十', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-4301-021', '114-4301', 21, 'single_choice', '關於人壽保險契約保險費到期未交付之催告、契約效力之停效與復效相關規定，下列敘述何者正確？', '人壽保險之保險費到期未交付者，經催告到達後屆二十日仍不交付時，保險契約之效力停止', '催告應送達於要保人，或負有交付保險費義務之人之最後住所或居所，保險費經催告後，應依與保 險人約定之交付方法交付之；保險人並應將前開催告通知被保險人以確保其權益。對被保險人之通 知，依最後留存於保險人之聯絡資料，限於以書面發出通知時，視為已完成', '停止效力之保險契約，於停止效力之日起九個月內清償保險費、保險契約約定之利息及其他費用後， 翌日上午零時起，開始恢復其效力', '保險契約所定申請恢復效力之期限，自停止效力之日起不得低於二年，並不得遲於保險期間之屆滿日', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-4301-022', '114-4301', 22, 'single_choice', '甲向A 保險公司（下稱A 公司）投保傷害保險新臺幣（下同）200 萬元，並以價值70 萬元之汽車向 B 保險公司（下稱B 公司）投保車體險並約定自負額5 萬元。某日因乙之駕車過失，導致甲失能、汽 車全毀。A 公司就失能部分依保險契約理賠100 萬元，B 公司就車損理賠65 萬元。設甲對於肇事原 因並無過失時，有關本案適用保險代位之情形，下列敘述何者正確？', 'A 公司與B 公司均不得行使代位權', 'A 公司不得行使代位權，B 公司得代位求償65 萬元', 'A 公司得代位求償100 萬元，B 公司得代位求償70 萬元', 'A 公司得代位求償100 萬元，B 公司得代位求償65 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-4301-023', '114-4301', 23, 'single_choice', '甲以自己為被保險人向A 保險公司（下稱A 公司）投保傷害保險，並以乙為其死亡時之受益人。下 列敘述何者錯誤？', 'A 公司於甲遭受意外傷害及其所致失能或死亡時，負給付保險金之責', '甲故意自殺，或因犯罪行為，所致傷害、失能或死亡，A 公司不負給付保險金之責', '乙故意傷害甲未遂時，甲得撤銷其受益權利', '乙故意傷害甲者，A 公司不負保險金給付之責', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-4301-024', '114-4301', 24, 'single_choice', '甲於民國107 年（下同）5 月1 日以自己為被保險人，向A 保險公司（下稱A 公司）投保人壽保險， 約定死亡保險金額1,000 萬元，指定其妻乙為受益人。A 公司於5 月15 日以簡訊告知甲核保通過， 並告知其應繳交之保險費金額與繳交日期。然甲於次日赴A 公司交付保險費途中發生車禍，甲當場 死亡。乙請求保險金給付時，A 公司得否拒絕？', 'A 公司以簡訊告知已核保通過，保險契約即已成立，除另有以保險費之交付為要件者外，A 公司不 得拒絕乙之請求', '甲尚未繳付保險費，保險契約未成立，A 公司得拒絕給付保險金', 'A 公司雖已核保通過，但尚未交付保險單，保險契約尚未成立，A 公司無須給付', '甲與A 公司間保險契約雖已成立，但因甲尚未履行其給付對價之義務，故A 公司亦無須給付', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-4301-025', '114-4301', 25, 'single_choice', '要保人暨被保險人甲向A 壽險公司（下稱A 公司）投保意外傷害死亡險新臺幣300 萬元，保單附約 約定「被保險人職業有變更，依本公司職業分類，其危險性增加者，應通知本公司，本公司於接到通 知後，自職業變更之日起，按差額比例增收未滿期保險費；未通知而發生保險事故者，本公司按其原 收保險費與應收保險費之比率折算保險金給付。」甲於要保時，要保書上的職業欄填無，投保後因疫 情及經濟問題開始從事膠筏漁業工作，未通知A 公司，漁業工作時發生落海事故死亡。保險人A 公 司下列主張，何者正確？', 'A 公司得依保險法第64 條規定，以被保險人違反最大誠信之理由，解除契約，無庸負責', 'A 公司得依保險法第59 條第2 項及第57 條規定，以怠於通知危險增加之理由，解除契約，無庸 負責', '職業從「無」變更為「膠筏漁業工作」，無涉危險增加，保險人A 公司應全額負責', '職業從「無」變更為「膠筏漁業工作」，涉危險增加，但未通知，保險人A 公司應依約負比例責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-4301-026', '114-4301', 26, 'single_choice', '甲於某年3 月1 日簽發本票一紙予乙，到期日為同年3 月18 日，並免除作成拒絕證書。乙於同年3 月5 日背書轉讓予丙。丙至遲應於何日向甲提示請求付款，始符票據法之規定？', '同年3 月18 日提示', '同年3 月19 日提示', '同年3 月20 日提示', '同年3 月21 日提示', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-4301-027', '114-4301', 27, 'single_choice', '甲為喜好放空股市之風險追求者，但因操作不力，資金套牢。其之前曾簽發發票日為民國109 年4 月 8 日之支票，但存款帳戶內資金僅能支應該支票面額1/5 之票款。為等待股市走向再度翻轉，甲商請 執票人晚些提示，執票人遂在提示期限經過後3 個月始提示。假設甲之資金仍舊套牢，依票據法之規 定，下列敘述何者錯誤？', '銀行可予以付款', '銀行可不予付款', '甲得撤銷付款之委託', '銀行不得僅支付1/5 之票款，必須先幫發票人墊付，再向發票人請求全額償還', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-4301-028', '114-4301', 28, 'single_choice', '在肺炎疫情期間，口罩短缺，居住苗栗市之善心人士甲先生，發起由當地之社區發展協會以家庭代工 方式製作口罩套以協助政府防疫，遂向高雄市之原料廠商A 公司進貨一批，簽發支票一紙予A 公司， 發票地在苗栗市、付款地在高雄市。本紙支票之提示期限為何？', '發票日後7 日內', '發票日後14 日內', '發票日後15 日內', '發票日後2 個月內', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-4301-029', '114-4301', 29, 'single_choice', 'A 公司於某年2 月14 日簽發匯票予B 公司，付款人為C 銀行，票上記載免除作成拒絕證書，到期日 記載為同年3 月14 日，B 公司至同年3 月15 日始向C 銀行提示付款。下列敘述何者正確？', 'B 公司之提示尚未逾法定期限', 'B 公司之提示已逾法定期限，但仍在發票日後6 個月內，故提示仍為有效', 'B 公司之提示已逾法定期限，惟若獲得C 銀行之同意，提示仍屬有效', '此張匯票既已免除作成拒絕證書，則根本不必提示', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-030', '114-4301', 30, 'single_choice', '甲欲向丙借調現金，但丙擔心甲信用不足，甲與乙簽訂擔保契約請求乙擔任支票之背書人，並簽發無 記名支票一紙交由乙收執，再由乙在支票背面空白背書後交給甲，甲持由乙空白背書之支票向丙調借， 丙於是將相當於票款之現金交付給甲，經丙遵期提示後，不獲付款。下列敘述何者正確？', '乙不必負背書責任，因為該支票背書不連續', '乙不必負背書責任，因為該支票為發票人甲回頭背書之票據', '乙應負背書責任，因為乙在支票背面背書', '乙應負背書責任，因為甲、乙間訂有擔保契約', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-031', '114-4301', 31, 'single_choice', '甲日常習慣於皮夾中保存一張已完成簽名蓋章之支票，以應不時之需。某日，知甲有此習慣之乙遂偷 偷從甲皮夾中取走該票據，完成金額及所缺之應記載事項，並記載乙自己為受款人後，再將該票背書 轉讓予善意且給付合理對價之丙。甲於票據遭竊後，未進行任何票據遺失之救濟程序，丙持該票向銀 行請求付款遭拒後，得否向甲主張？', '因甲未於該票上填載金額，該票欠缺應記載事項而無效，故甲不負票據責任', '因丙為善意取得已具備票據法規定應記載事項之票據，甲不得主張該票據原欠缺應記載事項而拒絕 付款', '因該票應記載事項係由乙完成填載，是以丙僅得向乙主張，而不得向甲主張', '甲需證明該票原欠缺應記載事項，始得對抗善意之丙而拒絕付款', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-032', '114-4301', 32, 'single_choice', '甲簽發本票一紙交付予乙，乙於到期日前背書轉讓予丙，丙於到期日向甲提示付款遭拒後並依法作成 拒絕證書，下列關於丙行使權利之敘述，何者錯誤？', '向甲追索時，丙得聲請法院裁定後強制執行', '丙行使追索權時，甲與乙連帶對丙負責', '向乙追索時，丙得直接聲請法院裁定後強制執行', '丙行使追索權時，可直接先向甲追索', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-033', '114-4301', 33, 'single_choice', '甲於民國（下同）105 年1 月1 日簽發面額為新臺幣（下同）20 萬元之本票一紙與乙，以清償所欠款 項20 萬元，唯該本票上漏未記載到期日。乙隨後將該本票背書後無償讓與其友丙，賀其小店開張。 丙即以該本票償付積欠廠商丁之貨款。丁返家後將該本票置於抽屜後即忘記持票請求，於109 年整理 抽屜時始發現該本票而欲主張其權利。下列敘述何者正確？', '該本票因未記載到期日，欠缺法定應記載事項而無效，丁無從主張其權利', '丁得持該票向甲主張付款，甲為發票人，不得拒絕', '乙係無償讓與該票，故乙不負任何票據責任，但丁仍可向丙請求', '丁僅得向甲主張利益償還請求權', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-034', '114-4301', 34, 'single_choice', '乙執有甲簽發之匯票一紙，乙記名背書轉讓予丙，以支付貨款，乙於簽名旁加註：「若丙未交貨時， 此背書無效」。下列對該匯票之敘述，何者正確？', '背書無效', '匯票無效', '乙於簽名旁之加註有效', '乙無條件負背書責任', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-035', '114-4301', 35, 'single_choice', 'A 公司為經營江浙菜館之業者，開立匯票予販售肉品之B 公司，購買一個月份之肉品，並由自己擔任 付款人，匯票到期日為民國109 年4 月6 日。惟民眾於此段期間內，為避免群聚而增加感染新冠肺炎 的風險，大多在家自炊，餐飲業者業績大受影響。A 公司也因此現金周轉不靈，於B 公司在到期日提 示時，A 公司希望延期付款，依票據法之規定，下列敘述何者正確？', '須得B 公司之同意，無特定期限之限制', '須得B 公司之同意，但以提示後2 日為限', '須得B 公司之同意，但以提示後3 日為限', '須得B 公司之同意，但以提示後4 日為限', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-036', '114-4301', 36, 'single_choice', '下列何者不是證券交易法所稱之發行人？', '以公開招募方式出售持有A 股份有限公司股票之持股人甲', '作為募集設立B 股份有限公司之發起人的自然人乙', '作為募集設立C 股份有限公司之發起人的D 股份有限公司', '辦理現金增資而募集發行股票之E 股份有限公司', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-4301-037', '114-4301', 37, 'single_choice', 'A 上市公司（下稱A 公司）章程規定設有七席董事，該公司並設置審計委員會。其中，審計委員會之 成員由甲、乙、丙三人組成。依證券交易法之規定，下列敘述何者錯誤？', '甲、乙、丙三人必須皆為獨立董事，且至少一人應具備會計或財務專長', '審計委員會之決議，應有過半數成員之出席，出席成員過半數之同意行之', 'A 公司之年度財務報告如未經審計委員會決議通過，仍不得由全體董事三分之二以上同意行之', '若甲、乙、丙三人均解任時，A 公司應自事實發生之日起60 日內，召開股東臨時會補選之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-038', '114-4301', 38, 'single_choice', 'A 股份有限公司（下稱A 公司）股票已公開發行，但尚未上市（櫃），A 公司如未能於本年6 月30 日 前召開股東常會，得否報請主管機關核准延期召開本年度股東常會？', 'A 公司僅須報請經濟部核准，即得延期召開股東常會', 'A 公司僅須報請金融監督管理委員會核准，即得延期召開股東常會', 'A 公司不得報請經濟部或金融監督管理委員會核准延期召開股東常會', 'A 公司如得經濟部及金融監督管理委員會核准，即得延期召開股東常會', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-039', '114-4301', 39, 'single_choice', '股票上市之A 公司實收資本額新臺幣10 億元，設7 席董事，近日公告買回其股份之內容如下列選項， 何者不符合證券交易法規定？', '買回目的：配合附認股權公司債', '預定買回股份占公司已發行股份總數之比率：1.5%', '董事會決議買回股份之紀錄：4 席董事出席，經主席徵詢全體出席董事無異議通過', '買回方式：自集中交易市場買回', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-040', '114-4301', 40, 'single_choice', 'A 股份有限公司（下稱A 公司）為一家從事資訊服務的上市公司，該公司設有常務董事，則A 公司 常務董事中獨立董事人數不得少於幾人，且不得少於常務董事席次多少比例？', '常務董事中獨立董事人數不得少於一人，且不得少於常務董事席次三分之一', '常務董事中獨立董事人數不得少於二人，且不得少於常務董事席次五分之一', '常務董事中獨立董事人數不得少於一人，且不得少於常務董事席次五分之一', '常務董事中獨立董事人數不得少於二人，且不得少於常務董事席次三分之一', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-041', '114-4301', 41, 'single_choice', 'A 上市公司（下稱A 公司）設有甲、乙、丙三名獨立董事，並由甲、乙、丙三人組成薪資報酬委員會。 關於薪資報酬委員會之敘述，下列何者正確？', '依公司法規定，董事報酬為股東會決議事項，所以A 公司薪資報酬委員會不得就董事報酬加以討論', 'A 公司薪資報酬委員會應至少每年召開2 次', 'A 公司薪資報酬委員會所討論之經理人薪酬範圍，僅限於經理人之薪資，而不應包含經理人所享 有之股票選擇權', 'A 公司董事會討論薪資報酬委員會之建議時，若不採納薪資報酬委員會之建議，應由董事會全體 董事同意行之，並於決議中具體說明通過之薪資報酬有無優於薪資報酬委員會之建議', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-042', '114-4301', 42, 'single_choice', '公開收購條件成就後，應賣人於何時得不經催告而逕行解約？', '隨時均可任意解約', '公開收購人未於公開收購說明書記載之支付收購對價時間完成支付者', '公開收購人縮短公開收購期間時', '公開收購人調降公開收購價格時', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-043', '114-4301', 43, 'single_choice', 'A 公司當選為B 上市公司（下稱B 公司）之法人董事，並指派代表人甲行使董事之職權，甲利用其 配偶之名義，於民國113 年7 月31 日買進B 公司普通股股票，A 公司於同年12 月18 日改派其代表 人為乙，甲復於同年12 月20 日賣出B 公司有表決權特別股股票，依目前主管機關之見解，B 公司不 得向甲行使短線交易歸入權之理由為何？', '因法人董事之代表人甲並不受短線交易之規範', '因買進B 公司股票之人為甲之配偶，賣出B 公司股票之人為甲，兩者無法行使歸入權', '因甲於賣出B 公司之特別股時，已不具備法人董事代表人之身分', '因買進之有價證券為B 公司普通股，賣出之有價證券為B 公司有表決權特別股', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-044', '114-4301', 44, 'single_choice', '下列關於我國現行證券集中保管制度之敘述，何者錯誤？', '集中保管之有價證券係以帳簿劃撥方式辦理買賣交割', '集中保管有價證券之設質交付，適用民法第九百零八條之規定', '上市（櫃）公司發行股票應採帳簿劃撥交付之無實體發行', '集中保管之股票係以證券集中保管事業之名義登載於股票發行公司股東名簿', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-4301-045', '114-4301', 45, 'single_choice', 'A 上市公司（下稱A 公司）之產品以外銷為主，A 公司主要客戶於某年4 月1 日片面停止與A 公司 之全部業務往來，同年4 月2 日即有國外媒體加以報導，4 月3 日國內媒體亦陸續報導，當日股價即 大幅向下修正。A 公司迫於輿論壓力於4 月4 日清明節上午召開記者會說明，隨即於下午將系爭消息 輸入公開資訊觀測站。依主管機關規定之公開方式，系爭重大消息何時公開？', '4 月2 日國外媒體開始報導時', '4 月3 日國內媒體開始報導時', '4 月4 日上午召開記者會說明時', '4 月4 日下午將系爭消息輸入公開資訊觀測站時', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true)
on conflict (question_id) do update set
  paper_id = excluded.paper_id,
  question_number = excluded.question_number,
  question_text = excluded.question_text,
  option_a = excluded.option_a,
  option_b = excluded.option_b,
  option_c = excluded.option_c,
  option_d = excluded.option_d,
  source_page_start = excluded.source_page_start,
  source_page_end = excluded.source_page_end,
  extraction_status = excluded.extraction_status,
  review_status = excluded.review_status,
  is_published = excluded.is_published,
  updated_at = now();

-- Question batch 6
insert into public.questions (
  question_id, paper_id, question_number, question_type, question_text,
  option_a, option_b, option_c, option_d, subject_primary, subject_secondary,
  chapter, topic_primary, topic_secondary, law_refs, tags, source_page_start,
  source_page_end, extraction_status, review_status, notes, is_published
) values
('114-4301-046', '114-4301', 46, 'single_choice', '甲將其B 屋租給乙，約定2 年後乙須返還租賃物；乙每個月須支付租金新臺幣（下同）3 萬元，並約 定遲延給付租金達2 個月以上時，以上皆載明可逕為強制執行，另於租期屆滿後甲須返還乙押租金。 上述之事項均已經公證人作成公證書。下列敘述，何者正確？', '就租賃物返還部分，於租期屆滿乙仍不返還，甲不得以此一公證書作為執行名義', '租期屆滿甲未返還押租金，雖未記載可逕為強制執行時，乙仍得以此一公證書作為執行名義', '乙積欠甲租金2 個月共6 萬元，甲得以此一公證書作為執行名義', '乙不慎將B 屋中甲所有之C 衣櫃損毀，就此所生之損害賠償8 萬元，甲得以此一公證書作為執行 名義', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-4301-047', '114-4301', 47, 'single_choice', '甲、乙共有土地一塊，甲之應有部分為三分之一，乙之應有部分三分之二。嗣甲以乙為被告，起訴請 求分割土地，經法院判決變價分割確定後，乙遂以該確定終局判決為執行名義，向執行法院聲請就土 地變價分割。執行法院應如何課徵執行費？', '以土地全部價額核定之', '以土地價額三分之二核定之', '以土地價額三分之一核定之', '以乙之應有部分預估價額命先暫繳，待拍定時再按拍定總額計徵執行費用', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-4301-048', '114-4301', 48, 'single_choice', '甲以乙積欠其借款新臺幣100 萬元為由，向法院聲請發支付命令獲准，並寄送至乙之戶籍地址，未 據乙提出異議。甲乃執系爭支付命令，聲請執行乙之財產，經執行法院開始強制執行。下列敘述，何 者錯誤？', '乙得以其並未住居於系爭支付命令所寄送之戶籍地址，系爭支付命令因未合法送達而失效為由，聲 明異議', '乙得以甲並未交付系爭借款，甲之債權不成立為由，提起異議之訴', '乙得以其已於強制執行開始後清償系爭借款，甲之債權已消滅為由，提起異議之訴', '乙以甲之債權已因抵銷而消滅為由，提起異議之訴，遭駁回確定後，得再以其與甲並無借貸合意， 甲之債權不成立為由，提起異議之訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-4301-049', '114-4301', 49, 'single_choice', '債權人甲訴請債務人乙將A 土地所有權移轉登記予自己，獲勝訴判決確定後，持該判決聲請執行法 院對乙為強制執行，請求乙辦理所有權移轉登記。關於執行法院之處置，下列敘述，何者正確？', '甲未撤回強制執行之聲請時，應裁定駁回', '發執行命令，命乙向地政機關辦理及賠償甲代為預納之執行費用', '發執行命令，命甲直接向地政機關辦理，並命乙賠償甲代為預納之執行費用', '函請地政機關依確定判決辦理，並命乙賠償甲代為預納之執行費用', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-4301-050', '114-4301', 50, 'single_choice', '關於金錢請求權之動產與不動產執行程序，下列敘述，何者正確？', '兩者均得為強制管理', '兩者均須經拍賣程序予以換價', '動產拍賣預定有底價者，應於拍賣公告載明', '將不動產及其上動產合併拍賣時，適用關於不動產之拍賣規定', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-4301-051', '114-4301', 51, 'single_choice', '乙欠甲貨款新臺幣（下同）100 萬元，甲取得確定之支付命令後，執以聲請法院強制執行乙所有之A 車。該車另設定動產抵押權予丙，以擔保丙對乙之120 萬元債權。下列敘述，何者正確？', '執行法院查封A 車後，如鑑估其價額為100 萬元，則不必詢問債權人之意見，即可撤銷查封，將A 車返還乙', '執行法院查封A 車後，如鑑估其價額為100 萬元，甲仍得聲明於A 車賣得價金不超過120 萬元及 其執行費用時，願負擔其費用，請求繼續拍賣', '執行法院於強制執行時，如發現A 車上有丙之抵押權120 萬元，則不得查封A 車', '丙對A 車之強制執行程序得提起第三人異議之訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-4301-052', '114-4301', 52, 'single_choice', '債權人甲以債務人乙未依買賣契約移轉A 地所有權，聲請法院對A 地為禁止乙為移轉、設定負擔之 假處分，並據之向執行法院聲請為假處分執行後，乙之另一債權人丙復持同法院命乙給付新臺幣600 萬元本息之確定終局判決，聲請對A 地為終局執行。下列敘述，何者正確？', '禁止處分之假處分，僅禁止債務人乙之任意處分，並不禁止強制執行所為之處分，執行法院應准許 丙聲請對A 地之終局執行', 'A 地既經禁止處分之假處分執行，執行法院應駁回丙聲請對A 地之終局執行', 'A 地雖經甲聲請為假處分執行，惟丙仍得聲請執行法院對A 地為查封，但不許換價程序', '執行法院應裁定命乙提供其他財產供甲擔保後，撤銷對A 地之假處分執行，而准許丙對A 地之終 局執行', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-053', '114-4301', 53, 'single_choice', '關於假扣押之執行，下列敘述，何者正確？', '假扣押裁定須確定後始能執行', '基於假扣押裁定而為執行，法院查封動產後，債務人再處分該動產之行為，絕對無效', '對於假扣押之執行，不得藉由聲請假處分而使其停止執行', '基於假扣押裁定，執行法院不得發債務人對第三人金錢債權之扣押命令', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-054', '114-4301', 54, 'single_choice', '甲列乙為相對人，向法院聲請定暫時狀態處分，命乙容忍甲通行乙所有之A 地獲准。下列敘述，何者 錯誤？', '執行法院應將系爭處分送達於乙', '甲收受系爭處分已逾30 日後，乙開始妨礙甲通行A 地者，甲仍得執以聲請強制執行', '乙設置圍牆妨礙甲通行A 地者，甲得聲請拆除之', '系爭處分依乙之抗告經廢棄確定者，執行法院應依乙之聲請，命甲返還通行A 地之利益', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-055', '114-4301', 55, 'single_choice', '債權人甲持命乙給付金錢之確定判決，聲請法院執行乙所有之A 地後，丙、丁、戊、己分別提出證明 文件，具狀向執行法院聲明參與分配。下列敘述，何者正確？', '丙提出和解筆錄者，如其上所載金錢債權未屆清償期，於聲明參與分配時視同已屆期，丙得參與分配', '丁提出禁止處分A 地之假處分者，因其於查封階段與系爭執行程序不相牴觸，故丁得參與分配', '戊提出A 地之抵押權設定契約書、他項權利證明書及借據者，雖該等文件並非執行名義，戊仍得參 與分配', '己提出乙作為雇主歇業前積欠其3 個月工資之切結書者，雖未取得執行名義，因該工資債權依法有 優先受償之地位，故己得參與分配', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-056', '114-4301', 56, 'single_choice', 'Under Article 185 of R.O.C. Civil Code, liability is where the whole or a distinct part of the damage suffered by the victim is attributable to two or more persons.', 'joint and several', 'discrete', 'independent', 'increased', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-057', '114-4301', 57, 'single_choice', 'Oliver liked to play music extremely loud and it always woke up Mr. and Mrs. Smith at midnight. Oliver was liable to Mr. and Mrs. Smith for .', 'trespass', 'nuisance', 'pain and suffering', 'mental distress', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-058', '114-4301', 58, 'single_choice', 'In certain circumstances, A can be held liable for the torts committed by B simply because B is A’s employee or agent or independent contractor, and despite the fact that injury or damage caused by B’s tort may not have been the result of any fault on the part of A. What is the type of the aforementioned tortious liability？', 'Contributory liability', 'Vicarious liability', 'Strict liability', 'Joint liability', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-059', '114-4301', 59, 'single_choice', 'is liability regardless of fault. The plaintiff does not have to prove either that the defendant was at fault or that the defendant was not at fault.', 'Negligent liability', 'Intentional liability', 'Strict liability', 'Inducing liability', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-060', '114-4301', 60, 'single_choice', 'Adam agreed to sell and Rosa agreed to buy Adam’s house located in Europe. Unfortunately, Adam did not know that his house has burnt down two days ago. Under Article 246 of R.O.C. Civil Code, the contract is .', 'void', 'reversible', 'revocable', 'unlawful', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-4301-061', '114-4301', 61, 'single_choice', 'When a corporate issuer wishes to raise money and to offer the securities only to professional investors, such as insurance companies or pension funds, etc., outside of a public offering, we call this offering as .', 'gun-jumping', 'private placement', 'public issuance', 'spin-off', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-062', '114-4301', 62, 'single_choice', 'Which of the following statements regarding sentencing in Taiwan’s Code of Criminal Law is correct?', 'Both retribution and deterrence are the goals of penalties in Taiwan’s Code of Criminal Law.', 'Pursuant to Taiwan’s Constitutional Court Ruling, the recidivist must be punished with an enhanced penalty, which might be up to one and a half times the penalty of the offense committed.', 'Imposing a sentence shall not consider the circumstantial evidence with regard to the defendant’s character, the attitudes after the crime, and the life circumstances.', 'A probation cannot be imposed with additional condition(s).', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-063', '114-4301', 63, 'single_choice', 'The emergency decree issued by the President shall be presented to the Legislative Yuan for within 10 days of issuance.', 'ratification', 'response', 'reconciliation', 'examination', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-064', '114-4301', 64, 'single_choice', 'In a civil case, any method of resolving disputes without litigation is called , including arbitration and mediation.', 'non-litigation adjudication', 'advanced dispute replacement', 'extrajudicial settlement', 'alternative dispute resolution', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-065', '114-4301', 65, 'single_choice', 'A(An) is an agreement between two parties: a principal and an attorney, which gives the attorney rights to act in the principal’s position. For example, a lawyer needs to have her client sign such the agreement before representing the client to speak in court.', 'agency agreement', 'power of attorney', 'authorizing statement', 'contract of empowerment', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-066', '114-4301', 66, 'single_choice', 'The level of essentially dictates the lens through which the court will analyze the governmental action. Its highest level means that the court will not defer to the government for its purpose or method at all.', 'security', 'protection', 'deference', 'scrutiny', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-067', '114-4301', 67, 'single_choice', 'Which of the following statements regarding sentencing is correct?', 'Sentencing is at the discretion of the prosecutor.', 'Sentencing should be imposed based only on consideration of the material elements of the offense.', 'Sentencing should comply with the proportionality principle.', 'The death penalty can be imposed and executed on juveniles.', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-068', '114-4301', 68, 'single_choice', 'In the process of electing directors at a shareholders’ meeting, is a voting system in which each voter may cast more than one vote for the same candidate, the number of which exercisable in respect of one share shall be the same as the number of directors to be elected, and the total number of votes per share may be consolidated for election of one candidate.', 'cumulative voting', 'straight voting', 'collective voting', 'accumulative voting', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-069', '114-4301', 69, 'single_choice', 'ABC Co. holds 80% of DEF Co.’s shares. DEF Co., in turn, holds all of GHI Co.’s shares. In the meantime, ABC Co. also holds 60% of JKL Co.’s shares. According to Chapter VI-I on Affiliate Enterprises of Taiwan’s Company Act, which of the following statement is correct?', 'ABC Co. is the controlling company of GHI Co.', 'DEF Co. is the controlling company of JKL Co.', 'JKL Co. is the controlling company of DEF Co.', 'JKL Co. is the controlling company of GHI Co.', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-4301-070', '114-4301', 70, 'single_choice', 'A basic rule of contracts holds that whether an offer has been made depends on the reasonableness of the alleged ’s belief that the advertisement or solicitation was intended as an offer.', 'objective, offeror', 'subjective, offeror', 'objective, offeree', 'subjective, offeree', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-1301-001', '114-1301', 1, 'single_choice', '有關刑法上錯誤論敘述，下列何者正確？', '甲把乙從橋上推到河中，希望乙溺斃，但乙最後頭部撞到橋墩而死，此時應否定甲的殺人故意', '甲以殺人之意思緊勒乙，導致乙昏迷，但甲誤認乙已死，故將其埋入土中，最後乙因被土覆蓋口鼻 而窒息死亡，此時依實務見解甲仍應負擔殺人罪責', '甲想要殺乙，所以看準了乙和丙、丁同在一間房間時，用一顆炸彈丟進三人所在的房間，導致在爆 炸範圍的乙、丙、丁均因爆炸而死，此時僅能肯定甲對乙有殺人故意，對於丙、丁只能成立過失犯', '甲以殺人的意思，在公眾使用道路放地雷想要炸死乙，偶然經過的丙踏到地雷被炸死，此時應否定 甲殺人的故意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-1301-002', '114-1301', 2, 'single_choice', '甲為17 歲之高中生，為博取心怡對象的好感，而願意接受紋身師傅乙於其手臂刺一個十元硬幣大小 的愛心圖案。下列敘述何者正確？', '甲不具民法上之行為能力，故其承諾無效', '未成年人對自己的身體並無處分權，須由其父母代為承諾始可', '乙不得主張推測承諾以阻卻傷害罪之違法性', '手臂刺青難以回復原樣，屬刑法第10 條之重傷', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-1301-003', '114-1301', 3, 'single_choice', '有關罪刑法定原則，下列敘述何者正確？', '原則禁止類推適用，但如有利於行為人者，則例外允許', '習慣法不得作為論罪科刑之依據，縱依習慣法為有利於行為人之認定者，亦同', '要求司法者僅能根據「行為時」之刑法規定論罪科刑，沒收亦同', '罪刑明確性原則不僅要求構成要件必須明確，法律效果亦須明確，但例外時允許絕對不定期刑之規 範方式', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-1301-004', '114-1301', 4, 'single_choice', '甲在偏遠山區開雙人座跑車載母親乙兜風回程下山途中，因打滑失控而撞上由丙所騎機車，致乙、丙 受傷，但因甲見丙只有手臂擦傷而乙傷勢嚴重有生命危險，故不顧丙的傷勢而將乙載往山下某醫院進 行救治。有關甲之行為，下列敘述何者錯誤？', '不得主張正當防衛', '得主張義務衝突', '欠缺刑法第185 條之4 發生交通事故逃逸罪之逃逸故意', '甲之行為該當刑法第185 條之4 發生交通事故逃逸罪之逃逸行為', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-1301-005', '114-1301', 5, 'single_choice', '關於刑法上有責性（罪責）的敘述，下列何者錯誤？', '一般認為責任能力的要素有二，即刑法第19 條內所稱「不能辨識其行為違法」之辨識能力，以及 「依其辨識而行為」之控制能力', '若行為人在行為時因精神障礙導致責任能力欠缺，但審判時已因治療而改善或痊癒，仍不能以後階 段具備責任能力為由，肯定行為時的罪責', '刑法上的有責性程度有輕重之別，且可能因此導致法律效果的差異', '依實務多數見解，刑法第19 條關於行為人能否辨識其行為違法及依其辨識而行為，屬於責任要素 中的生理原因，應由專業鑑定人判斷之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 1, 1, 'parsed', 'pending_manual_review', null, true),
('114-1301-006', '114-1301', 6, 'single_choice', '村長時常炫耀家中財富，引起村民甲的厭惡。某日，甲得知村長買入新的高檔豪車後，決定深夜前去 村長家，以鐵棍破壞村長的車，給村長一個教訓。甲持鐵棍到了村長家，卻發現村長開車外出，只好 作罷。沒想到，甲於返家途中，巧遇村長停車在對街的便利商店門口，便順手撿起路邊石塊，擲向村 長的車；沒想到石塊卻反彈砸中剛好路過的村民乙之車，使得乙車的車窗玻璃破碎。下列敘述何者 正確？', '村長開車外出，出乎甲意料之外，甲成立毀損罪的障礙未遂犯', '村長開車外出，使得甲無法損壞村長的車，甲成立毀損罪的不能未遂犯', '甲朝村長的車丟擲石塊，但未能砸中，故甲成立毀損罪的普通未遂犯', '甲朝村長的車丟擲石塊，卻砸中乙車，但毀損罪不罰過失，故甲不成立犯罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-1301-007', '114-1301', 7, 'single_choice', '關於刑法第150 條妨害秩序罪之敘述，下列何者錯誤？', '構成要件中之聚集，指三人以上集合有隨時可以增加之狀況者而言，若僅結合特定之人則不屬之', '意圖供行使之用攜帶兇器犯本罪，得加重其刑至二分之一', '本罪規範目的在保護社會秩序，故雖有聚集眾人之事實，仍須實質審酌其行為是否已達危害秩序安 寧之程度', '主觀上，行為人須具備妨害秩序之故意，若僅意在侵害特定人之身體或自由法益者，不能論以本罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-1301-008', '114-1301', 8, 'single_choice', '公務員甲透過非公務員之友人乙充當白手套，由乙出面向丙收受賄賂，而為違背職務之行為，依實務 見解乙有無犯罪？', '沒有，乙非公務員，不會構成犯罪', '沒有，乙沒有為任何違背職務之行為，單純當白手套，只是間接正犯之工具，現行法沒有處罰機制， 係立法漏洞', '有，乙雖非公務員，不會構成公務員收受賄賂罪，但應構成背信罪', '有，乙雖非公務員，但與具有公務員身分之人共同犯罪，仍會構成公務員收受賄賂罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-1301-009', '114-1301', 9, 'single_choice', '甲犯四案件，於同一判決中獲判有罪，其罪刑之宣告分別為：殺人既遂罪判有期徒刑15 年，褫奪公 權5 年；強盜致死罪判有期徒刑15 年，褫奪公權2 年，沒收其犯罪所得新臺幣（以下同）50 萬元； 收受贓物罪判有期徒刑2 年，併科罰金10 萬元，並沒收其收受之贓物；詐欺既遂罪判有期徒刑3 年， 併科罰金30 萬元，並沒收其犯罪所得100 萬元。下列定應執行刑之結果，何者符合我國刑法之規定？', '有期徒刑35 年，褫奪公權7 年，罰金40 萬元，沒收其收受之贓物與犯罪所得120 萬元', '有期徒刑25 年，褫奪公權5 年，罰金35 萬元，沒收其收受之贓物與犯罪所得150 萬元', '有期徒刑25 年，褫奪公權7 年，罰金40 萬元，沒收其收受之贓物與犯罪所得150 萬元', '有期徒刑25 年，褫奪公權5 年，罰金35 萬元，沒收其收受之贓物與犯罪所得120 萬元', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-1301-010', '114-1301', 10, 'single_choice', '甲急需籌款，將他人託其保管的三級毒品據為己有，並販賣予他人。警方先發覺甲之侵占罪嫌，拘提 到案後，甲主動供出其販賣毒品之事實，警方始一併偵辦。依實務見解，甲自動供出販賣第三級毒品 犯罪部分，是否構成刑法第62 條自首？', '不構成，因為甲一行為犯侵占與販賣三級毒品，屬裁判上一罪，為訴訟法上之單一案件，無從分割', '不構成，因為甲被警方所發覺者屬較重之罪行，甲所坦承者係較輕之罪行', '構成，因為想像競合之一部分犯罪雖經偵查機關發覺，其他部分之犯罪係經甲自首，始得悉犯罪之 全貌，仍屬未發覺之犯罪', '構成，因為法院對甲之誠實表現應予以獎勵而必減其刑', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-1301-011', '114-1301', 11, 'single_choice', '關於緩刑撤銷事由（包括應撤銷及得撤銷事由），下列敘述何者正確？', '緩刑前，因過失犯他罪，而在緩刑期內受6 月有期徒刑之宣告確定者', '緩刑期內，因故意犯他罪，而在緩刑期內受逾6 月有期徒刑之宣告確定者', '緩刑期內，因過失更犯罪，而在緩刑期內受拘役之宣告確定者', '緩刑期內，因故意犯他罪，在緩刑期內受無罪之宣告，但令入相當處所施以一年之保護管束確定者', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 2, 2, 'parsed', 'pending_manual_review', null, true),
('114-1301-012', '114-1301', 12, 'single_choice', '根據司法院釋字第799 號解釋，有關性犯罪者刑後強制治療，下列敘述何者正確？', '刑後強制治療之要件，限於犯所列舉之罪名，且應經鑑定、評估，認有再犯之危險者，始得為之， 並未違反明確性原則', '強制治療期間至再犯危險顯著降低為止，未規定最長期間，猶如不定期刑，違反比例原則', '性侵害犯罪防治法第22 條之1 第1 項規定，對民國95 年刑法第91 條之1 規定修正施行前，曾犯 性侵害犯罪之加害人施以強制治療，違反法律不溯及既往原則', '強制治療制度長年運作結果雖趨近於刑罰，並未悖離與刑罰執行應明顯區隔之憲法要求', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-1301-013', '114-1301', 13, 'single_choice', '市立醫院小兒科醫師乙，受病患家屬託付，代轉紅包新臺幣（以下同）8 萬元予心臟科醫師甲，以答 謝其幫忙插隊開刀之情。乙起貪念，從中取2 萬元中飽私囊，餘款轉交於甲。甲、乙行為之刑責如何？', '甲成立不違背職務受賄罪，乙從屬於正犯甲應負幫助犯刑責', '甲、乙均成立不違背職務受賄罪，但欠缺犯意之聯絡，不負共同正犯之刑責', '甲、乙均成立背信罪，並不成立不違背職務受賄罪', '甲、乙均不成立不違背職務受賄罪，乙成立侵占罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-1301-014', '114-1301', 14, 'single_choice', '甲係在監獄擔任崗哨及巡邏勤務的替代役男，其於值勤期間發現受刑人乙在房舍內藏有未經許可之金 錢，但甲未予舉報，仍由乙繼續保有該筆金錢，嗣後甲向乙告知，如不欲受舉報即需支付新臺幣3 萬 元封口費，始能繼續保有該筆金錢。乙拒絕之。有關甲之行為，下列敘述何者正確？', '甲非刑法上公務員，故僅成立恐嚇取財未遂罪', '甲僅告知乙，縱乙拒絕甲，甲仍成立公務員要求賄賂罪', '甲未獲得積極之財產利益，故不成立犯罪', '甲未主動舉發乙之違法行為，故甲成立包庇罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-1301-015', '114-1301', 15, 'single_choice', '司法警察甲尚未取得拘提竊盜案被告丙之拘票時，因心急而提早對丙執行拘提並解送於檢察官乙，嗣 後乙為取得丙的供詞而謊稱已取得關鍵證據並要丙老實交代案情。有關甲、乙之行為是否成立刑法第 125 條濫權追訴處罰罪，依實務見解，下列敘述何者正確？', '甲不具本罪行為人適格，故不成立本罪', '甲尚未取得拘票即拘提之行為，已達濫權程度，故成立本罪', '甲雖濫用職權，但因僅係對丙拘提而非逮捕，故不成立本罪', '乙以詐術取得供詞之行為，屬本罪規定之不正訊問方式，故成立本罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-1301-016', '114-1301', 16, 'single_choice', '關於公務員所為的犯罪或對公務員所為的犯罪敘述，下列何者錯誤？', '公務員同時該當刑法第122 條違背職務受賄罪與第131 條圖利罪之構成要件時，應優先適用前者', '公務員違犯刑法第213 條明知不實而登載於職務上所掌公文書罪時，另得依刑法第134 條加重其刑', '刑法第135 條第1 項妨害公務罪，倘非於公務員依法執行職務時而對其施強暴脅迫者，即無妨害公 務可言', '刑法第138 條所謂公務員職務上掌管之物品，以該物品由公務員本於職務上之關係所掌管者為已 足，與物品之所有權無涉', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-1301-017', '114-1301', 17, 'single_choice', '有關刑法第150 條「在公共場所或公眾得出入之場所聚集3 人以上，施強暴脅迫」之聚眾施強暴脅迫 罪，下列敘述何者錯誤？', '依實務見解，本條聚眾犯意的形成，一定要於聚集時即對於將實施強暴脅迫有所認識，方能構成本 罪；若聚集後始有本條犯意，則不成立本罪', '該條所指之「聚集」，不論是自動聚集或被動聚集，均包括在內，而不限於自動聚集的情形', '雖然條文沒有明文，但依實務見解，聚眾實施強暴脅迫之人，主觀上應具有妨害秩序之故意，始能 成立本罪', '依實務見解，本條是抽象危險犯，不以發生實害結果為必要，倘因而侵害其他法益而成立他罪（如 傷害罪），應視情節不同，分依競合關係或數罪關係予以處罰', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-1301-018', '114-1301', 18, 'single_choice', '關於妨害秩序罪，下列敘述何者正確？', '甲、乙、丙三人會合，於夜間將A 賣菜的攤位以鐵鍊綑綁，藉以教訓其不交保護費，甲、乙、丙三 人構成刑法第150 條第1 項之聚眾施強暴脅迫罪', '甲冒充警察攔下乙之車輛，要求乙出示證件配合盤查，甲構成刑法第158 條冒充公務員罪', '甲參加密室逃脫遊戲時將自己裝扮成中華民國陸軍軍官，甲構成刑法第159 條冒用公務員服飾罪', '甲於通訊軟體Line 傳訊給友人乙，告知明日將持槍掃射捷運站，甲構成刑法第151 條恐嚇公眾危 害安全罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 3, 3, 'parsed', 'pending_manual_review', null, true),
('114-1301-019', '114-1301', 19, 'single_choice', '甲參加婚宴，席間喝了一瓶高粱，散會後腳步踉蹌，卻堅持自行駕車返家。甲於倒車時撞倒一拾荒老 人乙致其輕傷，卻渾然未覺，仍駕車離去。途中甲超速駕駛並於十字路口闖紅燈，撞飛過馬路之行人 丙，甲驚覺闖禍，加速駛離現場。丙經路人立即送醫，但於到院前已死亡。甲遭警方攔阻，測得吐氣 酒精濃度達每公升0.5 毫克。依實務見解，下列敘述何者正確？', '甲撞倒乙，成立過失致傷害罪與發生交通事故逃逸罪，兩罪想像競合', '甲撞倒乙，成立過失致傷害罪、遺棄罪、發生交通事故逃逸罪，三罪想像競合', '甲撞飛丙，成立不能安全駕駛罪、過失致人於死罪及發生交通事故逃逸罪，不能安全駕駛罪及過失 致人於死罪為想像競合犯，再和發生交通事故逃逸罪數罪併罰', '甲撞飛丙，成立不能安全駕駛致人於死罪及發生交通事故逃逸罪，兩罪數罪併罰', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-1301-020', '114-1301', 20, 'single_choice', '關於偽造文書罪，下列敘述何者正確？', '偽造統一發票應構成刑法第212 條偽造特種文書罪', '偽造私文書，係指製作之文書內容為虛偽', '偽造文書後行使之，依實務見解僅構成行使偽造文書罪', '偽造大學畢業證書所成立之罪，其法定刑較偽造一般文書之罪為重', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-1301-021', '114-1301', 21, 'single_choice', '有關各罪間之吸收關係，依實務見解，下列敘述何者錯誤？', '行為人本行使偽造私文書之意，先偽造私文書，復持以行使，則其偽造之行為被行使之行為所吸收， 而論以行使偽造私文書罪', '行為人本意圖供行使之用，而偽造貨幣並進而行使時，其行使偽造貨幣之行為應被偽造貨幣之行為 所吸收，而論以偽造貨幣罪', '行為人本意圖供行使之用，而偽造有價證券並進而行使時，其行使有價證券之行為應被偽造有價證 券之行為所吸收，而論以偽造有價證券罪', '行為人偽造私文書並持之誣告他人犯罪，其偽造、行使偽造私文書之行為，均應被誣告之行為所吸 收，而論以誣告罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-1301-022', '114-1301', 22, 'single_choice', '甲、乙均已成年，甲某日潛入乙家中，見乙正在熟睡中，色心大起，遂起意觸摸乙之胸部、生殖器， 乙因有異狀而醒來，甲見狀擔心乙聲張此事，遂另以其係神明轉世，告知乙若不與其發生性行為，將 遭天譴。乙聞言大驚，心裡便害怕起來，遂同意與甲發生性行為。甲於性行為過程中，在乙不知情之 下，手持智慧型手機開啟拍攝功能拍攝與乙間之性交過程。依實務見解，下列敘述何者錯誤？', '甲在乙熟睡階段觸摸乙身體及生殖器之行為，構成乘機猥褻罪', '甲以遭天譴之事告以乙而使乙同意與其性交，雖然是怪力亂神之事，但乙之同意仍為有效', '甲成立刑法第222 條加重強制性交罪', '甲若構成加重強制性交罪，則毋庸另論刑法第315 條之1 第2 款之無故竊錄他人身體隱私部位罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-1301-023', '114-1301', 23, 'single_choice', '甲男為使剛認識之18 歲乙女脫離其父親而與甲在外同居，以溫情攻勢成功說服乙女後，乙女不顧父 親反對而偷偷離開家庭與甲同居。有關甲之行為，下列敘述何者正確？', '成立刑法第240 條之和誘罪', '成立刑法第241 條之略誘罪', '成立刑法第298 條之略誘婦女罪', '無罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-1301-024', '114-1301', 24, 'single_choice', '甲發現市郊有一墳墓荒煙漫草，應已多年無人掃墓，但甲判斷該墳墓應是昔日大戶人家的墳，其中應 有值錢財物，乃挖墳盜寶，且小心翼翼不傷及棺木內的屍體。下列敘述何者正確？', '挖掘墳墓，盜取屍體，無論是否損壞屍體，都成立刑法第249 條之罪', '甲盜取墓內財物，未損壞屍體，是竊盜行為，不成立刑法第249 條之罪', '因墳墓已經無人清理，故甲挖墳不會成立刑法第248 條之罪', '若挖墳發現，墳墓內有二具棺木，是夫妻合葬之墳，甲挖墳成立兩個刑法第248 條之罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-1301-025', '114-1301', 25, 'single_choice', '關於刑法賭博罪的處罰規定，依實務見解，下列何者正確？', '所謂詐賭係以賭博行為作為詐欺之手段，因此該行為應成立賭博罪與詐欺罪', '賭博罪係屬對向犯，對賭之人就以偶然事實決定勝負具犯意聯絡，屬刑法第28 條之共同正犯', '赴供不特定之人得以出入之私人住宅賭博者，應成立刑法第266 條第1 項之公然賭博罪', '賭博行為進行中，置於賭檯上之現金，必須為賭博罪之犯罪行為人所有，始為沒收之對象', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 4, 4, 'parsed', 'pending_manual_review', null, true),
('114-1301-026', '114-1301', 26, 'single_choice', '甲平日不事生產、遊手好閒，一日，甲又因求職失利而大怒，回到家見到配偶A 與6 歲之女兒B 正 在吃飯，一怒之下將飯菜全掃落在地上，大罵兩人竟然還有心情吃飯，並說要禁止A、B 兩人吃晚餐。 A 見狀便要甲節制一點，不要找女兒的麻煩，有事全衝著自己來，甲一聽便說是你自找的喔，便用力 打了A 一個耳光，導致A 口鼻流血。A 之母C 正巧在旁，也上前攔阻甲，甲則將C 用力推倒在地， C 則幸未受傷，但卻不巧將B 也撞倒在地，導致B 頭部挫傷。有關甲之刑責，下列敘述何者正確？', '甲將飯菜掃落在地，並禁止B 吃晚餐之行為，已構成刑法第286 條之對於未滿18 歲之人施以凌虐 之行為', '甲在A 表示有事衝著自己來之後打A 耳光之行為，屬於已得A 之承諾所為之傷害行為，應構成刑 法第282 條第1 項規定之受他人囑託或得其承諾而傷害之罪', '甲將C 推倒在地，C 雖未受傷，但其推C 之行為應已構成刑法第281 條施強暴於直系血親尊親屬罪', '甲推倒C 卻將B 也撞倒在地之行為，已構成刑法第284 條之過失傷害罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-1301-027', '114-1301', 27, 'single_choice', '關於刑法上遺棄罪之敘述，下列何者錯誤？', '刑法第293 條之不違背義務遺棄罪，係以積極作為方式為遺棄行為者為限', '駕駛汽車肇事致被害人受輕傷而逃逸者，同時該當刑法第185 條之4 發生交通事故逃逸罪與第294 條違背義務遺棄罪，想像競合', '甲見路旁醉漢因酒醉而昏迷，遂以黑色大垃圾袋蓋在其身上，令外人無法發現，仍屬刑法第293 條 之積極遺棄行為', '扶養權利人因原來之扶養方法不合其意，要求義務人換扶養方式，未獲如願，而拒不就養，義務人 並不該當違背義務遺棄罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-1301-028', '114-1301', 28, 'single_choice', '關於刑法第302 條私行拘禁罪，依實務見解，下列敘述何者正確？', '對於被害人為瞬間之拘束，至多只能構成強制罪', '保母將其照顧之6 歲兒童鎖在房間內，不構成私行拘禁罪', '要成立私行拘禁罪，必須使被害人陷於不能抗拒', '當剝奪他人行動自由時，另行基於傷害之犯意對被害人實施輕傷行為時，直接論以私行拘禁罪即可', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-1301-029', '114-1301', 29, 'single_choice', '有關刑法中妨害秘密罪之敘述，依實務見解，下列何者錯誤？', '甲未經許可，在A 的車輛上裝設GPS 追蹤器，因車輛移動及其位置之信息，等同車輛使用人之行 動信息，故行為人仍可成立刑法第315 條之1 的妨害秘密罪', '甲因懷疑其妻A 外遇，乃在A 的行動電話中植入程式，以窺視、竊聽A 的行蹤與通話對象，縱使 夫妻間互負忠貞義務，甲仍可成立刑法第315 條之1 的妨害秘密罪', '甲知悉偶像歌手A 即將與友人B 至某KTV 的101 室包廂內唱歌，遂在該包廂內裝置竊聽器，以竊 錄A、B 唱歌及對話之內容，並確實竊得該等內容，因KTV 為公開場合，故甲至多僅有民事責任 而不會成立妨害秘密罪', '甲報社總編輯取得A 遭他人在密室內性侵害過程中被拍攝之照片一張，隨即將該照片刊登於報紙 上，甲仍可能成立妨害秘密罪章之罪，而不能以新聞自由為名，主張阻卻違法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-1301-030', '114-1301', 30, 'single_choice', '公司主管將裝有1 萬元現金之信封袋交給員工甲，並要求甲在當天下班回家或隔天上班途經A 銀行 時，將此1 萬元全數存入公司帳戶內，但甲在下班後卻先將該筆現金花光，數日後甲又因良心不安， 再另行從自己的銀行帳戶轉帳1 萬元至公司帳戶。有關甲之行為，下列敘述何者正確？', '成立刑法第335 條第1 項普通侵占罪', '成立刑法第336 條第2 項業務侵占罪', '成立刑法第320 條第1 項普通竊盜罪', '無罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-1301-031', '114-1301', 31, 'single_choice', '甲因沉迷賭博，賭輸鉅款而負債累累，竟起意行搶。某日，甲於路旁發現獨自夜歸的女子A，隨即持 刀強扯A 之手提包欲將其奪走，A 努力護住其手提包而與甲產生拉扯，甲一怒之下竟臨時起意持刀 將A 殺死，之後再將A 的皮包奪走。依實務見解，甲之行為應如何論罪？', '成立強盜致死罪', '成立加重搶奪罪與故意殺人罪，數罪併罰', '成立強盜殺人罪', '成立加重強盜罪與故意殺人罪，數罪併罰', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-1301-032', '114-1301', 32, 'single_choice', '有關甲之行為，下列何者構成刑法第342 條背信罪？', '職棒球員甲在比賽中故意失誤而使球隊輸球，導致觀眾不再願意進場看球賽', '上市公司董事長甲為支付家中裝潢費用，乃未經董事會同意，請裝潢設計師向公司請款核銷該筆費用', '醫師甲故意違反醫療準則而對病人實施錯誤治療，導致病人須再次花費進行醫治', '甲受乙委託投資股票，但因甲疏忽未注意股市動向，導致乙之投資付諸流水', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 5, 5, 'parsed', 'pending_manual_review', null, true),
('114-1301-033', '114-1301', 33, 'single_choice', '甲與乙為鄰居，素來相處不睦，某日甲見乙將車停在甲住處門口，心生不滿，乃持一大桶難以清洗之 紅漆潑灑乙之名貴汽車，致令汽車外觀難以回復，依實務見解，甲之刑責為何？', '甲成立刑法第304 條第1 項強制罪', '甲成立刑法第309 條第2 項之強暴侮辱罪', '甲成立刑法第354 條毀損器物罪', '甲不成立任何犯罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-1301-034', '114-1301', 34, 'single_choice', '關於現在司法實務對於累犯之統一見解，下列敘述何者錯誤？', '事實審法院對於被告有無構成累犯之事實及應否適用刑法第47 條規定加重其刑，即屬法院認定事 實與適用法律之基礎事項，客觀上有調查之必要性，應依職權加以調查。檢察官並無主張並具體指 出證明方法之責任', '依照司法院釋字第775 號解釋意旨，累犯不應不分情節輕重一律加重', '被告構成累犯之事實及應加重其刑之事項，均應由檢察官主張並具體指出證明之方法後，經法院踐 行調查、辯論程序，方得作為論以累犯及是否加重其刑之裁判基礎', '被告構成累犯之事實及應加重其刑之事項，檢察官若未主張或具體指出證明方法，法院因而未論以 累犯或依累犯規定加重其刑，仍得就被告可能構成累犯之前科、素行資料，列為刑法第57 條第5 款所定「犯罪行為人之品行」之審酌事項', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-1301-035', '114-1301', 35, 'single_choice', '甲懷疑配偶乙有外遇，於是偷偷用乙的帳號密碼登入電腦，把電腦中乙外遇的證據拷貝備份並刪除之。 依照實務見解，關於甲的刑責，下列敘述何者錯誤？', '甲輸入乙帳號登入其電腦的行為，成立入侵他人電腦罪', '甲雖以調查外遇為理由，但仍屬「無故」取得他人電磁紀錄', '雖然甲刪除乙的電磁紀錄，但只要該紀錄仍有回復的可能，即不該當無故刪除他人電磁紀錄罪', '甲所犯之罪，均屬於告訴乃論之罪', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-1301-036', '114-1301', 36, 'single_choice', '甲與乙、丙共同販賣海洛因，另又單獨竊取他人財物，嗣甲為免其犯行曝光，遂向偵辦的員警丁行賄， 請求丁包庇。檢察官因發覺甲販賣海洛因犯行而提起公訴；嗣於第一審中，甲因與戊有怨隙，誣指其 毒品上游為戊。有關管轄之敘述，下列何者錯誤？', '甲所涉竊盜及行賄犯行，與已起訴之販賣毒品犯行，係「一人犯數罪」，屬於相牽連案件，檢察官 得於第一審辯論終結前，追加起訴', '乙所涉販賣毒品部分，與已起訴之甲販賣毒品犯行，係「數人共犯一罪」，屬於相牽連案件，檢察 官得於第一審辯論終結前，追加起訴', '甲誣指戊之行為，係「犯與本罪有關係之誣告罪」，屬於相牽連案件，檢察官得於第一審辯論終結 前，追加起訴', '丁收受賄賂犯行，與甲業經追加起訴之行賄犯行，屬於相牽連案件，檢察官得於第一審辯論終結前， 追加起訴', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-1301-037', '114-1301', 37, 'single_choice', '法官迴避制度乃確保公正審判，屬憲法訴訟權保障之核心內容。依實務見解，下列何種情形，刑事法 官甲不得就同一案件再次參與審判？', '甲曾參與第二審審判，案經上訴第三審後撤銷發回更審，又參與第二審之更審審判', '甲僅參與第一審判決宣示，案經上訴第二審而確定。當事人向第二審法院聲請再審，甲又參與該再 審程序', '甲曾參與第一審審判，案經上訴第二審被撤銷改判確定。檢察總長認該確定判決違背法令，向最高 法院提起非常上訴，甲又參與該非常上訴程序', '甲曾參與第二審審判，案件確定後，當事人向第二審法院聲請再審，由乙法官審理。乙為再審有理 由之裁定並確定，甲又參與開始再審後之本案審判', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 6, 6, 'parsed', 'pending_manual_review', null, true),
('114-1301-038', '114-1301', 38, 'single_choice', '關於財產可能被沒收的第三人參與沒收程序之敘述，下列何者正確？', '參與沒收程序之證據調查，不適用交互詰問規定', '第三人參與沒收程序之規定，亦適用於簡易程序及協商程序', '檢察官須於起訴時一併主張有無應沒收第三人財產之事實，若於審理中始認為應沒收第三人財產 者，不得再為主張或聲請', '參與人經合法傳喚或通知而不到庭者，不得逕行判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-039', '114-1301', 39, 'single_choice', '甲涉犯擄人勒贖罪嫌，警察人員未經檢察官之指揮及未持搜索票下，逕赴甲宅並得甲同意後搜索。依 實務見解，下列敘述何者正確？', '甲沒有在辯護律師陪同下，基於自由意思所為之同意搜索不合法', '警察人員經甲同意後所為之搜索，應向法院陳報，始為合法', '甲主張同意搜索程序不合法，審理法官如認搜索程序不合法，所扣得之物得宣告不得作為證據', '甲於搜索中反悔，不再同意搜索，警察仍得續行搜索', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-040', '114-1301', 40, 'single_choice', '關於通緝之敘述，下列何者正確？', '檢察官懷疑被告有逃亡之虞，即可向法院聲請通緝書', '通緝屬於強制處分之一種，而通緝書一律由法院簽發', '通緝書僅須記載被告姓名、被訴事實、通緝理由以及應解送之處所，不應記載其犯罪之時間與地點', '通緝經通知或公告後，司法警察官得拘提被告或逕行逮捕之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-041', '114-1301', 41, 'single_choice', '關於被告在場權之保障，下列訴訟程序何者違反規定？', '一審法院傳喚被告及告訴人到庭，被告因與告訴人吵架，自認受辱而未經審判長許可就離庭，法院 得不待其陳述逕行判決', '車禍過失傷害案件，受命法官為了節省開庭時間，就自己在辦公室勘驗現場光碟，並製成勘驗筆錄， 但為保障被告之陳述權，故於審判庭中提示勘驗筆錄給被告表示意見', '二審法院合法傳喚被告，但被告選擇不出庭，法院得不待其陳述逕行判決', '證人明確表明被告在場會妨礙其自由陳述，審判長於聽取檢察官、辯護人意見後，得命被告暫時退庭', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-042', '114-1301', 42, 'single_choice', '司法警察調查犯罪，因嫌疑重大，情況急迫而得為逕行拘提之情形，下列敘述何者錯誤？', '犯罪嫌疑人在公共場所賭博財物，經警盤查而逃逸者', '因現行犯之供述，且有事實足認為共犯嫌疑重大者', '犯罪嫌疑人因犯強盜罪而故意殺人，有事實足認有逃亡之虞者', '發覺犯罪嫌疑人是另案通緝中之被告', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-043', '114-1301', 43, 'single_choice', '關於逮捕之敘述，下列何者錯誤？', '犯罪嫌疑人抗拒逮捕者，司法警察得用強制力逮捕之，但不得逾越必要之程度', '無偵查犯罪權限之人亦可逮捕現行犯，但隨後應即送交法院', '司法警察逮捕犯罪嫌疑人時，雖無搜索票，亦得逕行搜索其身體', '司法警察執行逮捕時，應當場告知犯罪嫌疑人逮捕之原因', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-044', '114-1301', 44, 'single_choice', '甲因涉嫌竊盜遭警方以現行犯逮捕。下列何種狀況取得甲之自白，原則上不得作為證據？', '甲於夜間移送檢察署，經檢察官夜間訊問時，甲自白犯罪之筆錄', '甲同意警方夜間詢問，於警方夜間詢問時所製作甲自白犯罪之筆錄', '移送檢察署，經檢察官訊問後，命被告甲具保，甲於等候具保四小時後，無法具保，甲於檢察官訊 問時自白犯罪之筆錄', '警詢時甲要求選任辯護人到場，於等候辯護人到場前之四小時內，甲於警詢時自白犯罪之筆錄', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-045', '114-1301', 45, 'single_choice', '甲涉嫌殺人未遂，經檢察官傳喚到庭，檢察官訊問後。下列處置何者違法？', '認甲涉嫌尚非重大，逕予釋放', '認甲無羈押必要，諭知具保、責付或限制住居', '認甲有羈押原因與必要，逕行聲請法院羈押之', '認甲有羈押原因與必要，應予逮捕並告知逮捕所依據之事實後，再聲請法院羈押之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 7, 7, 'parsed', 'pending_manual_review', null, true),
('114-1301-046', '114-1301', 46, 'single_choice', '檢察官偵辦候選人甲的賄選案件，傳喚證人乙證明甲的樁腳行賄，偵訊時進行錄音，並依法命其具結 後製作偵訊筆錄。審判中，甲的辯護人主張乙之偵訊筆錄無證據能力。其所提出之下列主張，何者為 最高法院實務見解所採認？', '檢察官偵訊乙時，依法不得錄音，故偵訊程序違法', '偵訊筆錄之記載與偵訊錄音之重要內容不一致', '偵訊筆錄係由訊問之檢察官自行製作，非由書記官製作', '偵訊筆錄未逐字記錄，即屬於顯有不可信情況之傳聞證據', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-1301-047', '114-1301', 47, 'single_choice', '刑事訴訟法交互詰問程序，關於誘導詰問之敘述，下列何者錯誤？', '主詰問時，就證人、鑑定人故為規避之事項，得為誘導詰問', '行主詰問時，對於鑑定人為與先前不符之陳述時，詰問者就該鑑定人先前之陳述亦得為誘導詰問', '行反詰問於必要時，得為誘導詰問', '行主詰問時，就當事人顯無爭執之事項，不得為誘導詰問', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-1301-048', '114-1301', 48, 'single_choice', '強盜案件的犯罪嫌疑人甲在被以現行犯逮捕後，當場供稱乙為共犯。警察掌握其他事實，認乙確共犯 嫌疑重大且情況急迫。下列敘述何者正確？', '檢察官應先傳喚乙，乙經合法傳喚，無正當理由不到場者，得拘提之', '為掌握犯罪偵查效率，警察得先行拘提乙，再報請檢察官核發拘票', '因乙涉嫌觸犯的是最輕本刑5 年有期徒刑以上之罪，僅能由檢察官逕行拘提之', '警察應取得檢察官簽發之拘票後，始得拘提乙', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-1301-049', '114-1301', 49, 'single_choice', '甲、乙為警當場查獲涉嫌共同販賣毒品予丙，甲、乙於警詢時，一致指稱與丁有販賣毒品予丙之犯意 聯絡及行為分擔等情，並經依法調取甲與乙、丁共同販賣毒品予丙過程之行動電話通信（聯）紀錄， 甲、乙、丁均經提起公訴。於審判中，甲、乙以證人身分作證時，均否認其等於警詢中所為不利於丁 之證述係屬實在，丁則抗辯甲、乙於警詢之陳述，不具證據能力。下列敘述何者正確？', '甲、乙於警詢中所為陳述，與審判中不符，如為證明犯罪事實所必要者，即得依刑事訴訟法第159 條之2 之規定，均具有證據能力', '刑事訴訟法第155 條第1 項前段之規定，證據之證明力，由法院本於確信自由判斷。故法院不違背 經驗法則及論理法則，依憑甲、乙所為不利於丁之證述，即據以認定丁共同販賣毒品予丙之犯罪事 實，採證合法', '證人即甲之友人戊於審判中具結後證述，甲曾向戊表示其係與乙、丁共同販賣毒品予丙等情，具有 證據能力，且可作為判斷甲於警詢中所為不利於丁之陳述係屬真實之補強證據', '甲與乙、丁共同販賣毒品予丙過程之行動電話通信（聯）紀錄，具有證據能力，且可作為判斷甲於 警詢中所為不利於丁之陳述係屬真實之補強證據', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-1301-050', '114-1301', 50, 'single_choice', '關於證據法則之敘述，下列何者錯誤？', '法院於第一次審判期日前，認為檢察官指出之證明方法顯不足認定被告有成立犯罪之可能時，得視 情況通知檢察官補正，或直接以裁定駁回起訴', '當事人、代理人、辯護人或輔佐人應就調查證據之範圍、次序及方法提出意見', '法院為發見真實，得依職權調查證據。但於公平正義之維護或對被告之利益有重大關係事項，法院 應依職權調查之', '當事人、代理人、辯護人或輔佐人聲請調查之證據，法院認為不必要者，得以裁定駁回之', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-1301-051', '114-1301', 51, 'single_choice', '甲與被害人發生衝突，因而與乙共同持棍毆傷被害人，被害人因不知乙之姓名，僅先對甲提起傷害罪 之告訴，甲經檢察官起訴後，第一審審理中，檢察官另案查出乙之姓名，被害人於另案偵查中與乙達 成和解，並撤回對乙之告訴後，甲始經法院判處傷害罪刑確定，甲知悉上情後，主張應依非常救濟程 序，改諭知不受理判決。依實務見解，其主張有無理由？', '無理由，因甲是正犯，且被害人未對甲撤回告訴，本應對甲論罪判刑', '無理由，已經判刑確定，不可救濟', '有理由，法院本應諭知公訴不受理，但應由甲聲請再審救濟', '有理由，法院本應諭知公訴不受理，且應以非常上訴救濟', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 8, 8, 'parsed', 'pending_manual_review', null, true),
('114-1301-052', '114-1301', 52, 'single_choice', '甲男因故遭乙男毆打成傷，其妻丙於案發7 個月後的某日，整理抽屜時偶然發現甲男就醫主訴遭乙男 毆打的驗傷診斷證明書，經質問甲後，甲男告稱因酒後辱罵乙男之女友，而遭乙男毆打，自認理虧而 不願提告，丙聽聞後認為必須讓乙付出代價，因而於翌日以自己為甲之配偶的名義向警方提出乙涉嫌 傷害甲之告訴。關於丙之告訴，下列敘述何者最為正確？', '甲之告訴期間已經屆滿，丙為其配偶，自不得再行告訴，其告訴為不合法', '丙為甲之配偶，有獨立告訴權，其告訴為合法', '丙之告訴合法，但甲為被害人，可隨時撤回丙之告訴', '丙並非被害人，其告訴因與甲明示之意思相反，因此不合法', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-1301-053', '114-1301', 53, 'single_choice', '甲同時毆傷乙、丙二人，乙向檢察官告訴，嗣甲與乙和解後，乙撤回告訴，檢察官即依刑事訴訟法第 252 條第5 款規定為不起訴處分，丙嗣於合法告訴期間內又對甲傷害提出自訴，有關法院判決之敘述， 下列何者正確？', '自訴合法，法院應為實體判決', '自訴合法，法院應為不受理判決', '自訴不合法，法院應為不受理判決', '自訴不合法，法院應裁定駁回', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-1301-054', '114-1301', 54, 'single_choice', '行國民參與審判之案件與行一般通常審判程序之案件，關於訴訟程序之規定，下列敘述何者錯誤？', '行國民參與審判之案件，檢察官起訴時，應向管轄法院提出起訴書，並不得將卷宗及證物一併送交 法院；一般通常審判程序之案件，檢察官提起公訴，應由檢察官向管轄法院提出起訴書，且起訴時， 應將卷宗及證物一併送交法院', '行國民參與審判及一般通常審判程序之案件，第一次準備程序期日之傳票或通知，至遲均應於14 日前送達', '證物及書證之調查，行國民參與審判之案件，原則上由聲請調查之當事人向國民法官法庭提示或宣 讀；一般通常審判程序之案件，則由審判長行之', '關於有罪判決書認定犯罪事實理由之記載，行國民參與審判之案件，得僅記載證據名稱及對重要爭 點判斷之理由；一般通常審判程序之案件，則應詳細記載認定犯罪事實所憑之證據及其認定之理由、 對於被告有利之證據不採納之理由等事項', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-1301-055', '114-1301', 55, 'single_choice', '被告涉犯搶奪罪於準備程序中為有罪之陳述，辯護人主張被告因精神障礙有阻卻責任事由之存在，法 院一方面同意將被告送精神鑑定，另一方面告知被告簡式審判程序之旨，經詢問後辯護人亦無其他意 見，裁定進行簡式審判程序。法院之處理是否合法？', '合法。法院既已同意送鑑定，已顧及被告之抗辯，辯護人亦無意見，對被告防禦權並無危害。若案 件已臻明確，應容許改行簡式審判程序', '合法。實務上之鑑定多半採機關鑑定，即鑑定人不會出庭接受交互詰問，因此認定罪責之精神鑑定 與簡式審判程序並無衝突', '不合法。辯護人之抗辯若與被告本人相矛盾，應以被告本人之意思為準，此時法院既裁定行簡式審 判程序，即不得再送精神鑑定', '不合法。簡式審判程序以被告為有罪陳述為前提，若被告主張有阻卻罪責事由，即不得改採簡式審 判程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-1301-056', '114-1301', 56, 'single_choice', '有關國民法官之選任程序，下列何者錯誤？', '國民法官選任程序不公開', '兩造均有不附理由之拒卻權，得行使之次數與被告被起訴之法條有關，起訴法條罪名越重，不附理 由拒卻權次數越多，至多可達6 次', '兩造附理由之拒卻權，無行使次數之限制', '無足夠候選國民法官可受抽選為國民法官或備位國民法官時，法院不得逕行抽選部分國民法官或備 位國民法官，應重新踐行選任程序', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 9, 9, 'parsed', 'pending_manual_review', null, true),
('114-1301-057', '114-1301', 57, 'single_choice', '甲係立法院行政科室之公務員，因涉嫌索取回扣，經檢察官偵辦後發現甲涉嫌貪污罪嫌重大，認有搜 索之必要，下列敘述何者錯誤？', '如無急迫情形，檢察官應以書面，檢附理由，向該管法院聲請核發搜索票，於法院核發搜索票後， 可交由司法警察執行搜索', '檢察官可向法院聲請對甲位於立法院院內之辦公室核發搜索票', '甲之妻乙係某大學教授，雖係第三人，但如有理由認甲將索取回扣資料存放於乙於學校之教授研究 室內，檢察官亦可向法院聲請對乙於大學內之教授研究室核發搜索票', '檢察官可向法院聲請對甲之身體核發搜索票，但不得聲請搜索第三人乙之身體', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-1301-058', '114-1301', 58, 'single_choice', '甲自訴乙犯誹謗罪，經第一審法院判處乙有期徒刑3 月，乙合法提起第二審上訴，甲於第二審未委任 律師為代理人，經第二審法院定期間命甲補正，甲逾期仍不委任，有關第二審法院之處理，依實務見 解，下列敘述何者正確？', '第一審所為判決，於程序上並無違誤，第二審應為實體判決', '第二審應類推適用刑事訴訟法第332 條規定，通知檢察官擔當訴訟後判決', '該上訴審程序本質上仍屬自訴性質，自訴人未委任律師為代理人，應撤銷第一審判決改判諭知不受理', '自訴人第一審選任律師為代理人之效力，於第二審仍有效，第二審無庸命補正，應為實體判決', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-1301-059', '114-1301', 59, 'single_choice', '甲涉犯普通竊盜及強制罪嫌之裁判上一罪，經檢察官向臺灣臺北地方法院提起公訴。臺灣臺北地方法 院審理結果，就甲被訴強制罪嫌部分判決有罪，被訴普通竊盜罪嫌部分，則於判決理由內說明不另為 無罪之諭知。檢察官及甲均不服提起上訴，臺灣高等法院審理結果，認定檢察官之上訴有理由，甲之 上訴則無理由，因而撤銷第一審判決，改依想像競合犯之規定，從一重論處甲犯普通竊盜罪刑確定。 甲不服欲向法院聲請再審，關於聲請再審程序之敘述，依實務見解，下列何者正確？', '甲聲請再審，應向臺灣臺北地方法院提起', '甲聲請再審倘經裁定駁回，對於普通竊盜罪部分，得提起抗告，對於強制罪部分，不得提起抗告', '甲聲請再審倘經裁定駁回，對於普通竊盜罪及強制罪部分，均不得提起抗告', '甲聲請再審倘經裁定駁回，對於普通竊盜罪及強制罪部分，均得提起抗告', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-1301-060', '114-1301', 60, 'single_choice', '被告因竊盜案件，經檢察官提起公訴，被告於準備程序中，就被訴事實為認罪之陳述，檢察官因而聲 請改依協商程序而為判決。依現行法及實務見解，下列敘述何者錯誤？', '協商程序之開啟僅能由檢察官主動向法院為聲請，被告或其辯護人、自訴人都無聲請權', '檢察官向法院聲請改依協商程序而為判決前，應先徵詢被害人之意見並取得其同意', '檢辯雙方於協商程序開啟後，得就被告願受科刑及沒收之範圍或願意接受緩刑之宣告', '檢察官就「被告向被害人道歉」與「被告支付相當數額之賠償金」與被告協商時，應取得被害人之 同意', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-1301-061', '114-1301', 61, 'single_choice', '關於道德、法律及倫理性質之敘述，下列何者正確？', '道德、法律及倫理，皆應形諸明文規定，才能具有社會行為之拘束力', '甲法官夜間駕車行經鄉村道路，發現陌生機車騎士倒臥路旁，但因擔心誤會被控肇事，因此並未停 車救助。甲法官不僅道德有損，倫理有違，如因不作為而導致騎士死亡，即應承擔法律責任', '乙法官與丙律師兩人為大學同學，有感於法學教育與實務應用之落差，共同投資設立「法律實務教 育訓練中心」提供課程講授，以合理學費招收有志學習法律以提昇職場競爭力之上班族。上述舉措 符合道德標準、法律規定及倫理價值', '道德即是人性尊嚴的本質，但標準及內涵可能因人而異。法律則是最低的道德標準，所有人都必須 遵守的義務。倫理乃是社會群體基於某些特殊屬性，共同形成的價值規範', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-1301-062', '114-1301', 62, 'single_choice', '甲檢察官因未接受檢察長不應起訴之書面命令，自行起訴，遭檢察長移送評鑑。關於檢察一體及檢察 官職權之行使，下列敘述何者正確？', '因為檢察一體，檢察官並無任何獨立辦案之空間，檢察長之命令，檢察官一定要遵守', '檢察官收到檢察長之書面指揮監督命令，檢察官不同意時，得以書面敘明理由，請求檢察長行使職 務移轉權', '檢察官與法官同屬司法官，故享有與法官完全相同之獨立保障，可自行決定是否起訴', '檢察官可以獨立行使職權，但基於檢察一體，如法律意見與檢察長不同，應遭受懲戒', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 10, 10, 'parsed', 'pending_manual_review', null, true),
('114-1301-063', '114-1301', 63, 'single_choice', '甲法官在審理A 與B（外國籍）間之感情及債務糾紛所引發之刑事詐欺案件時，不認同B 態度輕佻， 於審理中糾正斥責：「你們外國人就是想賺錢」、「你們都來臺灣騙臺灣人的錢」、「你以為我們臺灣啊 是隨便你這樣子的喔！」、「你對我們臺灣這個社會有什麼幫助啊！蛤？」等語。下列何者不是甲法官 所違反法官倫理規範之內容？', '法官執行職務，應保持公正、客觀、中立，不得有損及人民對司法信賴之行為', '法官不得因性別、種族、地域、宗教、國籍、年齡而有差別待遇行為', '法官應維持法庭莊嚴，不得對在庭之人辱罵、無理之責備或有其他損其尊嚴之行為', '法官對於繫屬中或即將繫屬之案件，不得公開發表可能影響裁判或程序公正之言論', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-1301-064', '114-1301', 64, 'single_choice', '關於法官參與集會、結社等活動，下列敘述何者正確？', '集會、結社係憲法保障之基本人權，法官亦屬公民，不受任何限制', '法官不得為無黨籍候選人之募款餐會從事募款', '法官不得成為大學校友會會員', '法官不得成為救援流浪動物協會會員', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-1301-065', '114-1301', 65, 'single_choice', '下列情形，何者不違反法官倫理規範？', '甲法官審理某政治人物貪污案，判決公布後許多新聞媒體認為量刑過輕，連日批評已造成法院不堪 其擾。甲法官為維護司法獨立形象，上政論節目表明立場，與現場來賓辯論', '乙法官在某件合議審判案件擔任受命法官，評議時與審判長丙對法律意見不同，雖陪席法官丁表示 與丙意見相同。乙仍堅持應再開辯論，否則判決書應改由審判長撰寫', '戊法官審理一件民事賠償案件，該案原告訴狀理由有明顯瑕疵，但被告因未委任律師而未能提出有 效抗辯，戊乃私下打電話給被告建議其可提出某等攻擊防禦方法', '己法官經任職法院同意在某大學兼課每週2 小時，並經常利用週末參與法律座談會或演講', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-1301-066', '114-1301', 66, 'single_choice', '甲律師受僱於A 律師事務所，即將離職。甲的行為，下列何者不違反律師倫理？', '通知自己所承辦案件客戶，告知其即將離職，並檢附A 事務所內接手律師的連絡資訊', '通知A 事務所全部客戶，告知其即將離職，到下一個單位任職，有案件歡迎聯繫委託', '通知自己承辦案件的客戶，表明自己最熟悉該案件，促請其轉委託自己承辦', '離職後，未知會A 事務所，逕行通知其在A 事務所時所承辦案件的客戶，歡迎他們諮詢與前案相 關的問題', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-1301-067', '114-1301', 67, 'single_choice', '法官甲於審理案件時，當庭於被告A 及其辯護律師乙面前，向被告A 說：「……選任律師要小心，有 些律師到處在外招搖撞騙，沒學問也沒時間研究案情，告的辯的一塌糊塗……；像這個辯護狀雖然有 律師具名，一點也不像律師寫的……」。針對法官甲之行為，下列敘述何者正確？', '法官甲當庭的言行，僅為善意提醒，有助於當事人慎選律師，沒有違反法官倫理', '法官甲當庭的言行，並不至於損及律師的尊嚴，沒有違反法官倫理', '法官甲對律師的意見，應私下告知當事人，不可在法庭上講', '法官甲當庭的言行不當，有違法官倫理', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-1301-068', '114-1301', 68, 'single_choice', '甲檢察官與乙律師是好朋友，乙邀請甲投資房地產。甲因資金不足，乙表示可以借貸新臺幣500 萬元 給甲。關於甲之行為，下列敘述何者正確？', '因借貸契約屬私法自治，只要甲未因償還借款而貪污，其行為並未違反檢察官倫理規範', '因為甲為檢察官，基於倫理規範，甲不應為任何商業投資行為，避免受到輿論批評', '因為甲為檢察官，甲不應與擔任律師的乙有金錢借貸關係，以避免損害司法公正形象', '因甲、乙為好友，甲向乙借款並無不當。重點是甲應該依據借貸契約規定，準時還錢', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-1301-069', '114-1301', 69, 'single_choice', '檢察官為避免違反檢察官倫理規範，不得兼任或擔任下列何種職務或工作？', '兼任財團法人法律扶助基金會各地分會的審查委員會委員', '兼任私立大學董事會的監察人', '應邀擔任私立高中開學典禮的法治宣講講座', '擔任法務部移送懲戒法院審理案件之代理人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 11, 11, 'parsed', 'pending_manual_review', null, true),
('114-1301-070', '114-1301', 70, 'single_choice', '律師下列之行為，何者不違反律師倫理規範？', '在民事訴訟中提出對造當事人聲請傳訊之證人有偽證之前科，並主張該證人之證詞完全不具可信度', '於受A 公司監察人委任到A 公司查帳時，因認為A 公司之職員甲不配合，對甲稱：「因你不配合， 我會告你，我事務所做別的不會，做毀滅性的東西很會」', '為蒐集證據以供談判破裂時訴訟使用，與對造當事人協調和解意願與條件時私下錄音，未告知對造 當事人', '與原不認識且初次到事務所諮詢的當事人，在諮詢後利用當事人的無助心理狀態下隨即在辦公室發 生性行為', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-1301-071', '114-1301', 71, 'single_choice', '甲律師受任為A 撰寫遺囑並為遺囑的見證人。A 死亡後其繼承人X、Y、Z 對遺囑之真實性、內容及 解釋有不同見解而進行民事訴訟。甲律師可否在訴訟中擔任X 之代理人？', '可以，但若甲律師在訴訟中充當證人時，必須據實陳述', '可以，因為甲律師最瞭解遺囑的來龍去脈，有助於真實發現', '不可以，除非得到訴訟中所有當事人的同意', '不可以，因為甲律師為A 撰寫遺囑並為遺囑的見證人，依法即不得再擔任該訟爭性事件之代理人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-1301-072', '114-1301', 72, 'single_choice', '甲律師擔任A 公司法律顧問。A 公司對外都宣稱公司所擁有的核心專利是由老板B 親自設計，但甲 擔任顧問處理相關侵害專利權糾紛，因而得知實際上是由C 所設計。現在該專利權已經過期，甲也不 再擔任A 公司顧問，而最近B、C 相繼過世，社會上對該專利發明人究竟為誰多有傳聞，記者想要訪 問甲，甲律師對該專利發明人為誰的情事，是否還負有保密義務？', '沒有，甲已經不再是公司的顧問，對於因擔任公司顧問而得知的情事已經不負保密義務', '沒有，該專利都已經過期，與該專利有關的設計事務當然也不再受保密義務約束', '有，但B、C 如果僅有一人死亡，甲就不負保密義務', '有，律師的保密義務會一直存在，只要該秘密之情事沒有公開，律師都還是負保密義務', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-1301-073', '114-1301', 73, 'single_choice', '甲擔任臺灣臺北地方法院法官，其子乙先在臺灣彰化地方法院擔任司法替代役，1 年服役期滿，即至 臺灣基隆地方法院任職法官助理。任職滿3 個月時，乙考上律師。乙考上律師屆滿1 年，甲也立即離 職轉任律師，同時與乙共同開設律師事務所。下列何者未違反律師法或律師倫理規範？', '甲在臺灣臺北地方法院曾經審理之某案件，該案件被告上訴二審時委託甲擔任辯護人', '在臺灣彰化地方法院提起家事訴訟事件的當事人，委託乙擔任訴訟代理人', '開設事務所當天，在臺灣臺北地方法院提起訴訟之刑事案件當事人，委託甲擔任辯護人', '乙在臺灣基隆地方法院協助法官處理的某民事事件，該案件當事人上訴二審時委任乙擔任訴訟代理人', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-1301-074', '114-1301', 74, 'single_choice', '甲律師和A 代書是多年好友，甲律師的客戶如果有不動產登記案件，甲律師都介紹給A 代書，A 代 書的客戶如果有訴訟案件，A 代書也都引介給甲律師。對於每一個A 代書引介來的案件，甲律師都回 饋A 代書引介案件的費用。甲律師的回饋行為有無違反律師倫理規範的規定？', '違反，律師不能對引介案件的人支付報酬', '沒有違反，因為雙方本來就有業務合作的關係', '如果雙方互相在引介案件時都有支付回饋金就沒有違反，如果只有單方面有支付就不可以', '必須雙方先簽定互相引介案件條件對等的合作協定才沒有違反，否則就違反律師倫理規範的要求', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true),
('114-1301-075', '114-1301', 75, 'single_choice', '甲律師和當事人A 初步商談案情之後，甲查閱相關法令及實務見解，判斷該訴訟案件應會勝訴，A 問 甲該案件會不會勝訴，甲應如何回應始符合法律倫理的要求？', '甲應向A 擔保該案件將獲有利之結果，以取得信賴', '甲應向A 說明依現行的法律見解，初步判斷該案件對A 有利，有勝訴機會', '甲不可將法律意見告知A，以免A 認為無委任專業律師之必要而不委任律師', '甲可向A 說明該訴訟案件對A 不利，如果不委任律師，將會敗訴，以促請A 委任甲', null, '{}'::text[], null, null, '{}'::text[], '{}'::text[], '{}'::text[], 12, 12, 'parsed', 'pending_manual_review', null, true)
on conflict (question_id) do update set
  paper_id = excluded.paper_id,
  question_number = excluded.question_number,
  question_text = excluded.question_text,
  option_a = excluded.option_a,
  option_b = excluded.option_b,
  option_c = excluded.option_c,
  option_d = excluded.option_d,
  source_page_start = excluded.source_page_start,
  source_page_end = excluded.source_page_end,
  extraction_status = excluded.extraction_status,
  review_status = excluded.review_status,
  is_published = excluded.is_published,
  updated_at = now();

-- Answer-key batch 1
insert into private.question_answer_keys (
  question_id, original_answer, final_answer, official_answer_status, official_notice_url
) values
('113-2301-001', 'D', 'D', 'official_standard', null),
('113-2301-002', 'A', 'A', 'official_standard', null),
('113-2301-003', 'D', 'D', 'official_standard', null),
('113-2301-004', 'D', 'D', 'official_standard', null),
('113-2301-005', 'D', 'D', 'official_standard', null),
('113-2301-006', 'A', 'A', 'official_standard', null),
('113-2301-007', 'D', 'D', 'official_standard', null),
('113-2301-008', 'D', 'D', 'official_standard', null),
('113-2301-009', 'D', 'D', 'official_standard', null),
('113-2301-010', 'A', 'A', 'official_standard', null),
('113-2301-011', 'D', 'D', 'official_standard', null),
('113-2301-012', 'B', 'B', 'official_standard', null),
('113-2301-013', 'C', 'C', 'official_standard', null),
('113-2301-014', 'A', 'A', 'official_standard', null),
('113-2301-015', 'D', 'D', 'official_standard', null),
('113-2301-016', 'A', 'A', 'official_standard', null),
('113-2301-017', 'A', 'A', 'official_standard', null),
('113-2301-018', 'A', 'A', 'official_standard', null),
('113-2301-019', 'C', 'C', 'official_standard', null),
('113-2301-020', 'B', 'B', 'official_standard', null),
('113-2301-021', 'A', 'A', 'official_standard', null),
('113-2301-022', 'D', 'D', 'official_standard', null),
('113-2301-023', 'C', 'C', 'official_standard', null),
('113-2301-024', 'C', 'C', 'official_standard', null),
('113-2301-025', 'C', 'C', 'official_standard', null),
('113-2301-026', 'A', 'A', 'official_standard', null),
('113-2301-027', 'B', 'B', 'official_standard', null),
('113-2301-028', 'D', 'D', 'official_standard', null),
('113-2301-029', 'D', 'D', 'official_standard', null),
('113-2301-030', 'D', 'D', 'official_standard', null),
('113-2301-031', 'A', 'A', 'official_standard', null),
('113-2301-032', 'C', 'C', 'official_standard', null),
('113-2301-033', 'A', 'A', 'official_standard', null),
('113-2301-034', 'D', 'D', 'official_standard', null),
('113-2301-035', 'C', 'C', 'official_standard', null),
('113-2301-036', 'D', 'D', 'official_standard', null),
('113-2301-037', 'D', 'D', 'official_standard', null),
('113-2301-038', 'B', 'B', 'official_standard', null),
('113-2301-039', 'D', 'D', 'official_standard', null),
('113-2301-040', 'B', 'B', 'official_standard', null),
('113-2301-041', 'A', 'A', 'official_standard', null),
('113-2301-042', 'C', 'C', 'official_standard', null),
('113-2301-043', 'C', 'C', 'official_standard', null),
('113-2301-044', 'B', 'B', 'official_standard', null),
('113-2301-045', 'C', 'C', 'official_standard', null),
('113-2301-046', 'A', 'A', 'official_standard', null),
('113-2301-047', 'A', 'A', 'official_standard', null),
('113-2301-048', 'D', 'D', 'official_standard', null),
('113-2301-049', 'D', 'D', 'official_standard', null),
('113-2301-050', 'B', 'B', 'official_standard', null),
('113-2301-051', 'D', 'D', 'official_standard', null),
('113-2301-052', 'D', 'D', 'official_standard', null),
('113-2301-053', 'D', 'D', 'official_standard', null),
('113-2301-054', 'B', 'B', 'official_standard', null),
('113-2301-055', 'B', 'B', 'official_standard', null),
('113-2301-056', 'A', 'A', 'official_standard', null),
('113-2301-057', 'B', 'B', 'official_standard', null),
('113-2301-058', 'D', 'D', 'official_standard', null),
('113-2301-059', 'C', 'C', 'official_standard', null),
('113-2301-060', 'C', 'C', 'official_standard', null),
('113-2301-061', 'C', 'C', 'official_standard', null),
('113-2301-062', 'B', 'B', 'official_standard', null),
('113-2301-063', 'B', 'B', 'official_standard', null),
('113-2301-064', 'A', 'A', 'official_standard', null),
('113-2301-065', 'A', 'A', 'official_standard', null),
('113-2301-066', 'B', 'B', 'official_standard', null),
('113-2301-067', 'C', 'C', 'official_standard', null),
('113-2301-068', 'D', 'D', 'official_standard', null),
('113-2301-069', 'D', 'D', 'official_standard', null),
('113-2301-070', 'C', 'C', 'official_standard', null),
('113-2301-071', 'A', 'A', 'official_standard', null),
('113-2301-072', 'B', 'B', 'official_standard', null),
('113-2301-073', 'C', 'C', 'official_standard', null),
('113-2301-074', 'C', 'C', 'official_standard', null),
('113-2301-075', 'A', 'A', 'official_standard', null),
('113-3301-001', 'D', 'D', 'official_standard', null),
('113-3301-002', 'C', 'C', 'official_standard', null),
('113-3301-003', 'C', 'C', 'official_standard', null),
('113-3301-004', 'B', 'B', 'official_standard', null),
('113-3301-005', 'B', 'B', 'official_standard', null),
('113-3301-006', 'A', 'A', 'official_standard', null),
('113-3301-007', 'C', 'C', 'official_standard', null),
('113-3301-008', 'B', 'B', 'official_standard', null),
('113-3301-009', 'C', 'C', 'official_standard', null),
('113-3301-010', 'B', 'B', 'official_standard', null),
('113-3301-011', 'B', 'B', 'official_standard', null),
('113-3301-012', 'B', 'B', 'official_standard', null),
('113-3301-013', 'C', 'C', 'official_standard', null),
('113-3301-014', 'A', 'A', 'official_standard', null),
('113-3301-015', 'C', 'C', 'official_standard', null),
('113-3301-016', 'A', 'A', 'official_standard', null),
('113-3301-017', 'D', 'D', 'official_standard', null),
('113-3301-018', 'B', 'B', 'official_standard', null),
('113-3301-019', 'C', 'C', 'official_standard', null),
('113-3301-020', 'C', 'C', 'official_standard', null),
('113-3301-021', 'B', 'B', 'official_standard', null),
('113-3301-022', 'B', 'B', 'official_standard', null),
('113-3301-023', 'C', 'C', 'official_standard', null),
('113-3301-024', 'D', 'D', 'official_standard', null),
('113-3301-025', 'D', 'D', 'official_standard', null)
on conflict (question_id) do update set
  original_answer = excluded.original_answer,
  final_answer = excluded.final_answer,
  official_answer_status = excluded.official_answer_status,
  official_notice_url = excluded.official_notice_url,
  updated_at = now();

-- Answer-key batch 2
insert into private.question_answer_keys (
  question_id, original_answer, final_answer, official_answer_status, official_notice_url
) values
('113-3301-026', 'A', 'A', 'official_standard', null),
('113-3301-027', 'A', 'A', 'official_standard', null),
('113-3301-028', 'B', 'B', 'official_standard', null),
('113-3301-029', 'B', 'B', 'official_standard', null),
('113-3301-030', 'C', 'C', 'official_standard', null),
('113-3301-031', 'A', 'A', 'official_standard', null),
('113-3301-032', 'C', 'C', 'official_standard', null),
('113-3301-033', 'A', 'A', 'official_standard', null),
('113-3301-034', 'C', 'C', 'official_standard', null),
('113-3301-035', 'C', 'C', 'official_standard', null),
('113-3301-036', 'D', 'D', 'official_standard', null),
('113-3301-037', 'A', 'A', 'official_standard', null),
('113-3301-038', 'C', 'C', 'official_standard', null),
('113-3301-039', 'C', 'C', 'official_standard', null),
('113-3301-040', 'B', 'B', 'official_standard', null),
('113-3301-041', 'D', 'D', 'official_standard', null),
('113-3301-042', 'B', 'B', 'official_standard', null),
('113-3301-043', 'C', 'C', 'official_standard', null),
('113-3301-044', 'A', 'A', 'official_standard', null),
('113-3301-045', 'A', 'A', 'official_standard', null),
('113-3301-046', 'B', 'B', 'official_standard', null),
('113-3301-047', 'B', 'B', 'official_standard', null),
('113-3301-048', 'B', 'B', 'official_standard', null),
('113-3301-049', 'D', 'D', 'official_standard', null),
('113-3301-050', 'A', 'A', 'official_standard', null),
('113-3301-051', 'C', 'C', 'official_standard', null),
('113-3301-052', 'B', 'B', 'official_standard', null),
('113-3301-053', 'A', 'A', 'official_standard', null),
('113-3301-054', 'D', 'D', 'official_standard', null),
('113-3301-055', 'C', 'C', 'official_standard', null),
('113-3301-056', 'C', 'C', 'official_standard', null),
('113-3301-057', 'D', 'D', 'official_standard', null),
('113-3301-058', 'C', 'C', 'official_standard', null),
('113-3301-059', 'B', 'B', 'official_standard', null),
('113-3301-060', 'D', 'D', 'official_standard', null),
('113-3301-061', 'A', 'A', 'official_standard', null),
('113-3301-062', 'C', 'C', 'official_standard', null),
('113-3301-063', 'A', 'A', 'official_standard', null),
('113-3301-064', 'D', 'D', 'official_standard', null),
('113-3301-065', 'A', 'A', 'official_standard', null),
('113-3301-066', 'D', 'D', 'official_standard', null),
('113-3301-067', 'D', 'D', 'official_standard', null),
('113-3301-068', 'C', 'C', 'official_standard', null),
('113-3301-069', 'B', 'B', 'official_standard', null),
('113-3301-070', 'B', 'B', 'official_standard', null),
('113-3301-071', 'A', 'A', 'official_standard', null),
('113-3301-072', 'A', 'A', 'official_standard', null),
('113-3301-073', 'B', 'B', 'official_standard', null),
('113-3301-074', 'C', 'C', 'official_standard', null),
('113-3301-075', 'C', 'C', 'official_standard', null),
('113-3301-076', 'A', 'A', 'official_standard', null),
('113-3301-077', 'D', 'D', 'official_standard', null),
('113-3301-078', 'C', 'C', 'official_standard', null),
('113-3301-079', 'B', 'B', 'official_standard', null),
('113-3301-080', 'B', 'B', 'official_standard', null),
('113-4301-001', 'B', 'B', 'official_standard', null),
('113-4301-002', 'C', 'C', 'official_standard', null),
('113-4301-003', 'D', 'D', 'official_standard', null),
('113-4301-004', 'A', 'A', 'official_standard', null),
('113-4301-005', 'D', 'D', 'official_standard', null),
('113-4301-006', 'C', 'C', 'official_standard', null),
('113-4301-007', 'B', 'B', 'official_standard', null),
('113-4301-008', 'C', 'C', 'official_standard', null),
('113-4301-009', 'D', 'D', 'official_standard', null),
('113-4301-010', 'B', 'B', 'official_standard', null),
('113-4301-011', 'B', 'B', 'official_standard', null),
('113-4301-012', 'C', 'C', 'official_standard', null),
('113-4301-013', 'D', 'D', 'official_standard', null),
('113-4301-014', 'D', 'D', 'official_standard', null),
('113-4301-015', 'A', 'A', 'official_standard', null),
('113-4301-016', 'D', 'D', 'official_standard', null),
('113-4301-017', 'B', 'B', 'official_standard', null),
('113-4301-018', 'D', 'D', 'official_standard', null),
('113-4301-019', 'C', 'C', 'official_standard', null),
('113-4301-020', 'D', 'D', 'official_standard', null),
('113-4301-021', 'B', 'B', 'official_standard', null),
('113-4301-022', 'A', 'A', 'official_standard', null),
('113-4301-023', 'A', 'A', 'official_standard', null),
('113-4301-024', 'C', 'C', 'official_standard', null),
('113-4301-025', 'B', 'B', 'official_standard', null),
('113-4301-026', 'A', 'A', 'official_standard', null),
('113-4301-027', 'D', 'D', 'official_standard', null),
('113-4301-028', 'D', 'D', 'official_standard', null),
('113-4301-029', 'B', 'B', 'official_standard', null),
('113-4301-030', 'D', 'D', 'official_standard', null),
('113-4301-031', 'A', 'A', 'official_standard', null),
('113-4301-032', 'C', 'C', 'official_standard', null),
('113-4301-033', 'D', 'D', 'official_standard', null),
('113-4301-034', 'D', 'D', 'official_standard', null),
('113-4301-035', 'C', 'C', 'official_standard', null),
('113-4301-036', 'C', 'C', 'official_standard', null),
('113-4301-037', 'D', 'D', 'official_standard', null),
('113-4301-038', 'C', 'C', 'official_standard', null),
('113-4301-039', 'A', 'A', 'official_standard', null),
('113-4301-040', 'C', 'C', 'official_standard', null),
('113-4301-041', 'B', 'B', 'official_standard', null),
('113-4301-042', 'C', 'C', 'official_standard', null),
('113-4301-043', 'C', 'C', 'official_standard', null),
('113-4301-044', 'B', 'B', 'official_standard', null),
('113-4301-045', 'A', 'A', 'official_standard', null)
on conflict (question_id) do update set
  original_answer = excluded.original_answer,
  final_answer = excluded.final_answer,
  official_answer_status = excluded.official_answer_status,
  official_notice_url = excluded.official_notice_url,
  updated_at = now();

-- Answer-key batch 3
insert into private.question_answer_keys (
  question_id, original_answer, final_answer, official_answer_status, official_notice_url
) values
('113-4301-046', 'C', 'C', 'official_standard', null),
('113-4301-047', 'C', 'C', 'official_standard', null),
('113-4301-048', 'A', 'A', 'official_standard', null),
('113-4301-049', 'B', 'B', 'official_standard', null),
('113-4301-050', 'A', 'A', 'official_standard', null),
('113-4301-051', 'D', 'D', 'official_standard', null),
('113-4301-052', 'C', 'C', 'official_standard', null),
('113-4301-053', 'B', 'B', 'official_standard', null),
('113-4301-054', 'D', 'D', 'official_standard', null),
('113-4301-055', 'D', 'D', 'official_standard', null),
('113-4301-056', 'C', 'C', 'official_standard', null),
('113-4301-057', 'C', 'C', 'official_standard', null),
('113-4301-058', 'D', 'D', 'official_standard', null),
('113-4301-059', 'B', 'B', 'official_standard', null),
('113-4301-060', 'B', 'B', 'official_standard', null),
('113-4301-061', 'A', 'A', 'official_standard', null),
('113-4301-062', 'D', 'D', 'official_standard', null),
('113-4301-063', 'D', 'D', 'official_standard', null),
('113-4301-064', 'C', 'C', 'official_standard', null),
('113-4301-065', 'D', 'D', 'official_standard', null),
('113-4301-066', 'B', 'B', 'official_standard', null),
('113-4301-067', 'C', 'C', 'official_standard', null),
('113-4301-068', 'C', 'C', 'official_standard', null),
('113-4301-069', 'B', 'B', 'official_standard', null),
('113-4301-070', 'C', 'C', 'official_standard', null),
('113-1301-001', 'A', 'A', 'official_standard', null),
('113-1301-002', 'A', 'A', 'official_standard', null),
('113-1301-003', 'D', 'D', 'official_standard', null),
('113-1301-004', 'B', 'B', 'official_standard', null),
('113-1301-005', 'C', 'C', 'official_standard', null),
('113-1301-006', 'C', 'C', 'official_standard', null),
('113-1301-007', 'A', 'A', 'official_standard', null),
('113-1301-008', 'D', 'D', 'official_standard', null),
('113-1301-009', 'B', 'B', 'official_standard', null),
('113-1301-010', 'A', 'A', 'official_standard', null),
('113-1301-011', 'A', 'A', 'official_standard', null),
('113-1301-012', 'C', 'C', 'official_standard', null),
('113-1301-013', 'B', 'B', 'official_standard', null),
('113-1301-014', 'C', 'C', 'official_standard', null),
('113-1301-015', 'C', 'C', 'official_standard', null),
('113-1301-016', 'C', 'C', 'official_standard', null),
('113-1301-017', 'D', 'D', 'official_standard', null),
('113-1301-018', 'C', 'C', 'official_standard', null),
('113-1301-019', 'A', 'A', 'official_standard', null),
('113-1301-020', 'B', 'B', 'official_standard', null),
('113-1301-021', 'D', 'D', 'official_standard', null),
('113-1301-022', 'D', 'D', 'official_standard', null),
('113-1301-023', 'B', 'B', 'official_standard', null),
('113-1301-024', 'D', 'D', 'official_standard', null),
('113-1301-025', 'A', 'A', 'official_standard', null),
('113-1301-026', 'C', 'C', 'official_standard', null),
('113-1301-027', 'C', 'C', 'official_standard', null),
('113-1301-028', 'B', 'B', 'official_standard', null),
('113-1301-029', 'C', 'C', 'official_standard', null),
('113-1301-030', 'C', 'C', 'official_standard', null),
('113-1301-031', 'A', 'A', 'official_standard', null),
('113-1301-032', 'B', 'B', 'official_standard', null),
('113-1301-033', 'D', 'D', 'official_standard', null),
('113-1301-034', 'C', 'C', 'official_standard', null),
('113-1301-035', 'B', 'B', 'official_standard', null),
('113-1301-036', 'D', 'D', 'official_standard', null),
('113-1301-037', 'A', 'A', 'official_standard', null),
('113-1301-038', 'A', 'A', 'official_standard', null),
('113-1301-039', 'C', 'C', 'official_standard', null),
('113-1301-040', 'D', 'D', 'official_standard', null),
('113-1301-041', 'B', 'B', 'official_standard', null),
('113-1301-042', 'C', 'C', 'official_standard', null),
('113-1301-043', 'A', 'A', 'official_standard', null),
('113-1301-044', 'C', 'C', 'official_standard', null),
('113-1301-045', 'D', 'D', 'official_standard', null),
('113-1301-046', 'B', 'B', 'official_standard', null),
('113-1301-047', 'C', 'C', 'official_standard', null),
('113-1301-048', 'B', 'B', 'official_standard', null),
('113-1301-049', 'B', 'B', 'official_standard', null),
('113-1301-050', 'C', 'C', 'official_standard', null),
('113-1301-051', 'B', 'B', 'official_standard', null),
('113-1301-052', 'A', 'A', 'official_standard', null),
('113-1301-053', 'A', 'A', 'official_standard', null),
('113-1301-054', 'B', 'B', 'official_standard', null),
('113-1301-055', 'C', 'C', 'official_standard', null),
('113-1301-056', 'C', 'C', 'official_standard', null),
('113-1301-057', 'D', 'D', 'official_standard', null),
('113-1301-058', 'B', 'B', 'official_standard', null),
('113-1301-059', 'D', 'D', 'official_standard', null),
('113-1301-060', 'B', 'B', 'official_standard', null),
('113-1301-061', 'C', 'C', 'official_standard', null),
('113-1301-062', 'B', 'B', 'official_standard', null),
('113-1301-063', 'C', 'C', 'official_standard', null),
('113-1301-064', 'C', 'C', 'official_standard', null),
('113-1301-065', 'D', 'D', 'official_standard', null),
('113-1301-066', 'D', 'D', 'official_standard', null),
('113-1301-067', 'B', 'B', 'official_standard', null),
('113-1301-068', 'A', 'A', 'official_standard', null),
('113-1301-069', 'B', 'B', 'official_standard', null),
('113-1301-070', 'C', 'C', 'official_standard', null),
('113-1301-071', 'A', 'A', 'official_standard', null),
('113-1301-072', 'A', 'A', 'official_standard', null),
('113-1301-073', 'B', 'B', 'official_standard', null),
('113-1301-074', 'C', 'C', 'official_standard', null),
('113-1301-075', 'A', 'A', 'official_standard', null)
on conflict (question_id) do update set
  original_answer = excluded.original_answer,
  final_answer = excluded.final_answer,
  official_answer_status = excluded.official_answer_status,
  official_notice_url = excluded.official_notice_url,
  updated_at = now();

-- Answer-key batch 4
insert into private.question_answer_keys (
  question_id, original_answer, final_answer, official_answer_status, official_notice_url
) values
('114-2301-001', 'A', 'A', 'official_standard', null),
('114-2301-002', 'D', 'D', 'official_standard', null),
('114-2301-003', 'B', 'B', 'official_standard', null),
('114-2301-004', 'D', 'D', 'official_standard', null),
('114-2301-005', 'A', 'A', 'official_standard', null),
('114-2301-006', 'D', 'D', 'official_standard', null),
('114-2301-007', 'A', 'A', 'official_standard', null),
('114-2301-008', 'D', 'D', 'official_standard', null),
('114-2301-009', 'A', 'A', 'official_standard', null),
('114-2301-010', 'B', 'B', 'official_standard', null),
('114-2301-011', 'A', 'A', 'official_standard', null),
('114-2301-012', 'D', 'D', 'official_standard', null),
('114-2301-013', 'B', 'B', 'official_standard', null),
('114-2301-014', 'D', 'D', 'official_standard', null),
('114-2301-015', 'A', 'A', 'official_standard', null),
('114-2301-016', 'D', 'D', 'official_standard', null),
('114-2301-017', 'B', 'B', 'official_standard', null),
('114-2301-018', 'D', 'D', 'official_standard', null),
('114-2301-019', 'D', 'D', 'official_standard', null),
('114-2301-020', 'C', 'C', 'official_standard', null),
('114-2301-021', 'A', 'A', 'official_standard', null),
('114-2301-022', 'D', 'D', 'official_standard', null),
('114-2301-023', 'B', 'B', 'official_standard', null),
('114-2301-024', 'D', 'D', 'official_standard', null),
('114-2301-025', 'C', 'C', 'official_standard', null),
('114-2301-026', 'C', 'C', 'official_standard', null),
('114-2301-027', 'D', 'D', 'official_standard', null),
('114-2301-028', 'B', 'B', 'official_standard', null),
('114-2301-029', 'D', 'D', 'official_standard', null),
('114-2301-030', 'B', 'B', 'official_standard', null),
('114-2301-031', 'C', 'C', 'official_standard', null),
('114-2301-032', 'D', 'D', 'official_standard', null),
('114-2301-033', 'C', 'C', 'official_standard', null),
('114-2301-034', 'D', 'D', 'official_standard', null),
('114-2301-035', 'A', 'A', 'official_standard', null),
('114-2301-036', 'B', 'B', 'official_standard', null),
('114-2301-037', 'D', 'D', 'official_standard', null),
('114-2301-038', 'A', 'A', 'official_standard', null),
('114-2301-039', 'B', 'B', 'official_standard', null),
('114-2301-040', 'C', 'C', 'official_standard', null),
('114-2301-041', 'B', 'B', 'official_standard', null),
('114-2301-042', 'C', 'C', 'official_standard', null),
('114-2301-043', 'D', 'D', 'official_standard', null),
('114-2301-044', 'A', 'A', 'official_standard', null),
('114-2301-045', 'C', 'C', 'official_standard', null),
('114-2301-046', 'D', 'D', 'official_standard', null),
('114-2301-047', 'A', 'A', 'official_standard', null),
('114-2301-048', 'D', 'D', 'official_standard', null),
('114-2301-049', 'C', 'C', 'official_standard', null),
('114-2301-050', 'C', 'C', 'official_standard', null),
('114-2301-051', 'D', 'D', 'official_standard', null),
('114-2301-052', 'A', 'A', 'official_standard', null),
('114-2301-053', 'D', 'D', 'official_standard', null),
('114-2301-054', 'C', 'C', 'official_standard', null),
('114-2301-055', 'D', 'D', 'official_standard', null),
('114-2301-056', 'A', 'A', 'official_standard', null),
('114-2301-057', 'D', 'D', 'official_standard', null),
('114-2301-058', 'D', 'D', 'official_standard', null),
('114-2301-059', 'C', 'C', 'official_standard', null),
('114-2301-060', 'D', 'D', 'official_standard', null),
('114-2301-061', 'C', 'C', 'official_standard', null),
('114-2301-062', 'A', 'A', 'official_standard', null),
('114-2301-063', 'C', 'C', 'official_standard', null),
('114-2301-064', 'D', 'D', 'official_standard', null),
('114-2301-065', 'C', 'C', 'official_standard', null),
('114-2301-066', 'A', 'A', 'official_standard', null),
('114-2301-067', 'C', 'C', 'official_standard', null),
('114-2301-068', 'C', 'C', 'official_standard', null),
('114-2301-069', 'A', 'A', 'official_standard', null),
('114-2301-070', 'C', 'C', 'official_standard', null),
('114-2301-071', 'B', 'B', 'official_standard', null),
('114-2301-072', 'C', 'C', 'official_standard', null),
('114-2301-073', 'D', 'D', 'official_standard', null),
('114-2301-074', 'C', 'C', 'official_standard', null),
('114-2301-075', 'C', 'C', 'official_standard', null),
('114-3301-001', 'C', 'C', 'official_standard', null),
('114-3301-002', 'D', 'D', 'official_standard', null),
('114-3301-003', 'C', 'C', 'official_standard', null),
('114-3301-004', 'D', 'D', 'official_standard', null),
('114-3301-005', 'D', 'D', 'official_standard', null),
('114-3301-006', 'B', 'B', 'official_standard', null),
('114-3301-007', 'D', 'D', 'official_standard', null),
('114-3301-008', 'B', 'B', 'official_standard', null),
('114-3301-009', 'C', 'C', 'official_standard', null),
('114-3301-010', 'B', 'B', 'official_standard', null),
('114-3301-011', 'C', 'C', 'official_standard', null),
('114-3301-012', 'B', 'B', 'official_standard', null),
('114-3301-013', 'C', 'C', 'official_standard', null),
('114-3301-014', 'D', 'D', 'official_standard', null),
('114-3301-015', 'C', 'C', 'official_standard', null),
('114-3301-016', 'B', 'B', 'official_standard', null),
('114-3301-017', 'D', 'D', 'official_standard', null),
('114-3301-018', 'A', 'A', 'official_standard', null),
('114-3301-019', 'B', 'B', 'official_standard', null),
('114-3301-020', 'D', 'D', 'official_standard', null),
('114-3301-021', 'D', 'D', 'official_standard', null),
('114-3301-022', 'A', 'A', 'official_standard', null),
('114-3301-023', 'D', 'D', 'official_standard', null),
('114-3301-024', 'B', 'B', 'official_standard', null),
('114-3301-025', 'A', 'A', 'official_standard', null)
on conflict (question_id) do update set
  original_answer = excluded.original_answer,
  final_answer = excluded.final_answer,
  official_answer_status = excluded.official_answer_status,
  official_notice_url = excluded.official_notice_url,
  updated_at = now();

-- Answer-key batch 5
insert into private.question_answer_keys (
  question_id, original_answer, final_answer, official_answer_status, official_notice_url
) values
('114-3301-026', 'C', 'C', 'official_standard', null),
('114-3301-027', 'C', 'C', 'official_standard', null),
('114-3301-028', 'A', 'A', 'official_standard', null),
('114-3301-029', 'C', 'C', 'official_standard', null),
('114-3301-030', 'B', 'B', 'official_standard', null),
('114-3301-031', 'C', 'C', 'official_standard', null),
('114-3301-032', 'A', 'A', 'official_standard', null),
('114-3301-033', 'B', 'B', 'official_standard', null),
('114-3301-034', 'A', 'A', 'official_standard', null),
('114-3301-035', 'B', 'B', 'official_standard', null),
('114-3301-036', 'A', 'A', 'official_standard', null),
('114-3301-037', 'C', 'C', 'official_standard', null),
('114-3301-038', 'A', 'A', 'official_standard', null),
('114-3301-039', 'C', 'C', 'official_standard', null),
('114-3301-040', 'A', 'A', 'official_standard', null),
('114-3301-041', 'B', 'B', 'official_standard', null),
('114-3301-042', 'C', 'C', 'official_standard', null),
('114-3301-043', 'B', 'B', 'official_standard', null),
('114-3301-044', 'C', 'C', 'official_standard', null),
('114-3301-045', 'B', 'B', 'official_standard', null),
('114-3301-046', 'D', 'D', 'official_standard', null),
('114-3301-047', 'A', 'A', 'official_standard', null),
('114-3301-048', 'B', 'B', 'official_standard', null),
('114-3301-049', 'D', 'D', 'official_standard', null),
('114-3301-050', 'A', 'A', 'official_standard', null),
('114-3301-051', 'A', 'A', 'official_standard', null),
('114-3301-052', 'C', 'C', 'official_standard', null),
('114-3301-053', 'D', 'D', 'official_standard', null),
('114-3301-054', 'B', 'B', 'official_standard', null),
('114-3301-055', 'B', 'B', 'official_standard', null),
('114-3301-056', 'D', 'D', 'official_standard', null),
('114-3301-057', 'C', 'C', 'official_standard', null),
('114-3301-058', 'B', 'B', 'official_standard', null),
('114-3301-059', 'D', 'D', 'official_standard', null),
('114-3301-060', 'B', 'B', 'official_standard', null),
('114-3301-061', 'D', 'D', 'official_standard', null),
('114-3301-062', 'C', 'C', 'official_standard', null),
('114-3301-063', 'D', 'D', 'official_standard', null),
('114-3301-064', 'B', 'B', 'official_standard', null),
('114-3301-065', 'D', 'D', 'official_standard', null),
('114-3301-066', 'B', 'B', 'official_standard', null),
('114-3301-067', 'D', 'D', 'official_standard', null),
('114-3301-068', 'B', 'B', 'official_standard', null),
('114-3301-069', 'D', 'D', 'official_standard', null),
('114-3301-070', 'A', 'A', 'official_standard', null),
('114-3301-071', 'D', 'D', 'official_standard', null),
('114-3301-072', 'A', 'A', 'official_standard', null),
('114-3301-073', 'D', 'D', 'official_standard', null),
('114-3301-074', 'C', 'C', 'official_standard', null),
('114-3301-075', 'A', 'A', 'official_standard', null),
('114-3301-076', 'C', 'C', 'official_standard', null),
('114-3301-077', 'B', 'B', 'official_standard', null),
('114-3301-078', 'C', 'C', 'official_standard', null),
('114-3301-079', 'B', 'B', 'official_standard', null),
('114-3301-080', 'A', 'A', 'official_standard', null),
('114-4301-001', 'C', 'C', 'official_standard', null),
('114-4301-002', 'B', 'B', 'official_standard', null),
('114-4301-003', 'A', 'A', 'official_standard', null),
('114-4301-004', 'C', 'C', 'official_standard', null),
('114-4301-005', 'A', 'A', 'official_standard', null),
('114-4301-006', 'C', 'C', 'official_standard', null),
('114-4301-007', 'A', 'A', 'official_standard', null),
('114-4301-008', 'B', 'B', 'official_standard', null),
('114-4301-009', 'B', 'B', 'official_standard', null),
('114-4301-010', 'A', 'A', 'official_standard', null),
('114-4301-011', 'C', 'C', 'official_standard', null),
('114-4301-012', 'B', 'B', 'official_standard', null),
('114-4301-013', 'D', 'D', 'official_standard', null),
('114-4301-014', 'B', 'B', 'official_standard', null),
('114-4301-015', 'D', 'D', 'official_standard', null),
('114-4301-016', 'B', 'B', 'official_standard', null),
('114-4301-017', 'D', 'D', 'official_standard', null),
('114-4301-018', 'B', 'B', 'official_standard', null),
('114-4301-019', 'C', 'C', 'official_standard', null),
('114-4301-020', 'A', 'A', 'official_standard', null),
('114-4301-021', 'D', 'D', 'official_standard', null),
('114-4301-022', 'B', 'B', 'official_standard', null),
('114-4301-023', 'D', 'D', 'official_standard', null),
('114-4301-024', 'A', 'A', 'official_standard', null),
('114-4301-025', 'D', 'D', 'official_standard', null),
('114-4301-026', 'C', 'C', 'official_standard', null),
('114-4301-027', 'D', 'D', 'official_standard', null),
('114-4301-028', 'C', 'C', 'official_standard', null),
('114-4301-029', 'A', 'A', 'official_standard', null),
('114-4301-030', 'C', 'C', 'official_standard', null),
('114-4301-031', 'B', 'B', 'official_standard', null),
('114-4301-032', 'C', 'C', 'official_standard', null),
('114-4301-033', 'D', 'D', 'official_standard', null),
('114-4301-034', 'D', 'D', 'official_standard', null),
('114-4301-035', 'C', 'C', 'official_standard', null),
('114-4301-036', 'A', 'A', 'official_standard', null),
('114-4301-037', 'B', 'B', 'official_standard', null),
('114-4301-038', 'A', 'A', 'official_standard', null),
('114-4301-039', 'C', 'C', 'official_standard', null),
('114-4301-040', 'C', 'C', 'official_standard', null),
('114-4301-041', 'B', 'B', 'official_standard', null),
('114-4301-042', 'B', 'B', 'official_standard', null),
('114-4301-043', 'C', 'C', 'official_standard', null),
('114-4301-044', 'B', 'B', 'official_standard', null),
('114-4301-045', 'D', 'D', 'official_standard', null)
on conflict (question_id) do update set
  original_answer = excluded.original_answer,
  final_answer = excluded.final_answer,
  official_answer_status = excluded.official_answer_status,
  official_notice_url = excluded.official_notice_url,
  updated_at = now();

-- Answer-key batch 6
insert into private.question_answer_keys (
  question_id, original_answer, final_answer, official_answer_status, official_notice_url
) values
('114-4301-046', 'C', 'C', 'official_standard', null),
('114-4301-047', 'B', 'B', 'official_standard', null),
('114-4301-048', 'D', 'D', 'official_standard', null),
('114-4301-049', 'A', 'A', 'official_standard', null),
('114-4301-050', 'D', 'D', 'official_standard', null),
('114-4301-051', 'B', 'B', 'official_standard', null),
('114-4301-052', 'A', 'A', 'official_standard', null),
('114-4301-053', 'C', 'C', 'official_standard', null),
('114-4301-054', 'D', 'D', 'official_standard', null),
('114-4301-055', 'C', 'C', 'official_standard', null),
('114-4301-056', 'A', 'A', 'official_standard', null),
('114-4301-057', 'B', 'B', 'official_standard', null),
('114-4301-058', 'B', 'B', 'official_standard', null),
('114-4301-059', 'C', 'C', 'official_standard', null),
('114-4301-060', 'A', 'A', 'official_standard', null),
('114-4301-061', 'B', 'B', 'official_standard', null),
('114-4301-062', 'A', 'A', 'official_standard', null),
('114-4301-063', 'A', 'A', 'official_standard', null),
('114-4301-064', 'D', 'D', 'official_standard', null),
('114-4301-065', 'B', 'B', 'official_standard', null),
('114-4301-066', 'D', 'D', 'official_standard', null),
('114-4301-067', 'C', 'C', 'official_standard', null),
('114-4301-068', 'A', 'A', 'official_standard', null),
('114-4301-069', 'A', 'A', 'official_standard', null),
('114-4301-070', 'C', 'C', 'official_standard', null),
('114-1301-001', 'B', 'B', 'official_standard', null),
('114-1301-002', 'C', 'C', 'official_standard', null),
('114-1301-003', 'A', 'A', 'official_standard', null),
('114-1301-004', 'C', 'C', 'official_standard', null),
('114-1301-005', 'D', 'D', 'official_standard', null),
('114-1301-006', 'D', 'D', 'official_standard', null),
('114-1301-007', 'A', 'A', 'official_standard', null),
('114-1301-008', 'D', 'D', 'official_standard', null),
('114-1301-009', 'B', 'B', 'official_standard', null),
('114-1301-010', 'C', 'C', 'official_standard', null),
('114-1301-011', 'B', 'B', 'official_standard', null),
('114-1301-012', 'A', 'A', 'official_standard', null),
('114-1301-013', 'D', 'D', 'official_standard', null),
('114-1301-014', 'B', 'B', 'official_standard', null),
('114-1301-015', 'A', 'A', 'official_standard', null),
('114-1301-016', 'B', 'B', 'official_standard', null),
('114-1301-017', 'A', 'A', 'official_standard', null),
('114-1301-018', 'B', 'B', 'official_standard', null),
('114-1301-019', 'D', 'D', 'official_standard', null),
('114-1301-020', 'C', 'C', 'official_standard', null),
('114-1301-021', 'D', 'D', 'official_standard', null),
('114-1301-022', 'B', 'B', 'official_standard', null),
('114-1301-023', 'D', 'D', 'official_standard', null),
('114-1301-024', 'A', 'A', 'official_standard', null),
('114-1301-025', 'C', 'C', 'official_standard', null),
('114-1301-026', 'D', 'D', 'official_standard', null),
('114-1301-027', 'B', 'B', 'official_standard', null),
('114-1301-028', 'A', 'A', 'official_standard', null),
('114-1301-029', 'C', 'C', 'official_standard', null),
('114-1301-030', 'B', 'B', 'official_standard', null),
('114-1301-031', 'C', 'C', 'official_standard', null),
('114-1301-032', 'B', 'B', 'official_standard', null),
('114-1301-033', 'C', 'C', 'official_standard', null),
('114-1301-034', 'A', 'A', 'official_standard', null),
('114-1301-035', 'C', 'C', 'official_standard', null),
('114-1301-036', 'C', 'C', 'official_standard', null),
('114-1301-037', 'D', 'D', 'official_standard', null),
('114-1301-038', 'A', 'A', 'official_standard', null),
('114-1301-039', 'C', 'C', 'official_standard', null),
('114-1301-040', 'D', 'D', 'official_standard', null),
('114-1301-041', 'B', 'B', 'official_standard', null),
('114-1301-042', 'A', 'A', 'official_standard', null),
('114-1301-043', 'B', 'B', 'official_standard', null),
('114-1301-044', 'D', 'D', 'official_standard', null),
('114-1301-045', 'C', 'C', 'official_standard', null),
('114-1301-046', 'B', 'B', 'official_standard', null),
('114-1301-047', 'D', 'D', 'official_standard', null),
('114-1301-048', 'B', 'B', 'official_standard', null),
('114-1301-049', 'D', 'D', 'official_standard', null),
('114-1301-050', 'A', 'A', 'official_standard', null),
('114-1301-051', 'D', 'D', 'official_standard', null),
('114-1301-052', 'B', 'B', 'official_standard', null),
('114-1301-053', 'A', 'A', 'official_standard', null),
('114-1301-054', 'B', 'B', 'official_standard', null),
('114-1301-055', 'D', 'D', 'official_standard', null),
('114-1301-056', 'B', 'B', 'official_standard', null),
('114-1301-057', 'D', 'D', 'official_standard', null),
('114-1301-058', 'C', 'C', 'official_standard', null),
('114-1301-059', 'D', 'D', 'official_standard', null),
('114-1301-060', 'B', 'B', 'official_standard', null),
('114-1301-061', 'D', 'D', 'official_standard', null),
('114-1301-062', 'B', 'B', 'official_standard', null),
('114-1301-063', 'D', 'D', 'official_standard', null),
('114-1301-064', 'B', 'B', 'official_standard', null),
('114-1301-065', 'D', 'D', 'official_standard', null),
('114-1301-066', 'A', 'A', 'official_standard', null),
('114-1301-067', 'D', 'D', 'official_standard', null),
('114-1301-068', 'C', 'C', 'official_standard', null),
('114-1301-069', 'B', 'B', 'official_standard', null),
('114-1301-070', 'A', 'A', 'official_standard', null),
('114-1301-071', 'C', 'C', 'official_standard', null),
('114-1301-072', 'D', 'D', 'official_standard', null),
('114-1301-073', 'B', 'B', 'official_standard', null),
('114-1301-074', 'A', 'A', 'official_standard', null),
('114-1301-075', 'B', 'B', 'official_standard', null)
on conflict (question_id) do update set
  original_answer = excluded.original_answer,
  final_answer = excluded.final_answer,
  official_answer_status = excluded.official_answer_status,
  official_notice_url = excluded.official_notice_url,
  updated_at = now();

do $$
declare
  v_questions integer;
  v_answers integer;
begin
  select count(*) into v_questions from public.questions where paper_id like '113-%' or paper_id like '114-%';
  select count(*) into v_answers from private.question_answer_keys where question_id like '113-%' or question_id like '114-%';
  if v_questions <> 600 or v_answers <> 600 then
    raise exception 'Seed validation failed: questions %, answers %', v_questions, v_answers;
  end if;
end $$;

commit;


-- ===== 0003_timeout_cron.sql =====
-- Recommended: finalize expired exam attempts even when the browser is closed.
-- Supabase Cron uses pg_cron and runs entirely inside Postgres.

create extension if not exists pg_cron with schema pg_catalog;

create or replace function private.finalize_expired_attempts()
returns integer
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_attempt record;
  v_finalized integer := 0;
begin
  for v_attempt in
    select id
    from public.exam_attempts
    where status = 'in_progress'
      and expires_at <= now()
    order by expires_at
    limit 500
  loop
    perform private.finalize_exam_attempt(v_attempt.id, 'timeout');
    v_finalized := v_finalized + 1;
  end loop;

  return v_finalized;
end;
$$;

revoke all on function private.finalize_expired_attempts() from public, anon, authenticated;

select cron.schedule(
  'justitia-finalize-expired-attempts',
  '* * * * *',
  $$select private.finalize_expired_attempts();$$
);


