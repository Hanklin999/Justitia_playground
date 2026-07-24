-- Justitia's playground V2 feature migration.
-- Repeat-safe: may be rerun after a partial failure.

create extension if not exists pgcrypto;

-- Official corrections can accept more than one answer (for example ROC 111 public-law Q50).
alter table private.question_answer_keys
  add column if not exists accepted_answers text[] not null default '{}'::text[];
update private.question_answer_keys
set accepted_answers = array[final_answer::text]
where coalesce(cardinality(accepted_answers), 0) = 0;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'private.question_answer_keys'::regclass
      and conname = 'question_answer_keys_accepted_answers_check'
  ) then
    alter table private.question_answer_keys
      add constraint question_answer_keys_accepted_answers_check
      check (cardinality(accepted_answers) > 0 and accepted_answers <@ array['A','B','C','D']::text[]);
  end if;
end $$;

alter table public.questions
  add column if not exists subsubject_primary text not null default '未分類';
update public.questions set subject_primary = '未分類' where subject_primary is null or btrim(subject_primary) = '';
update public.questions set subsubject_primary = '未分類' where subsubject_primary is null or btrim(subsubject_primary) = '';

alter table public.exam_attempts add column if not exists attempt_mode text not null default 'official_paper';
alter table public.exam_attempts add column if not exists title text;
alter table public.exam_attempts add column if not exists is_timed boolean not null default true;
alter table public.exam_attempts add column if not exists selected_years smallint[] not null default '{}';
alter table public.exam_attempts add column if not exists selected_subjects text[] not null default '{}';
alter table public.exam_attempts add column if not exists selected_subsubjects text[] not null default '{}';
alter table public.exam_attempts add column if not exists elapsed_seconds integer;

update public.exam_attempts a
set title = coalesce(a.title, p.exam_year_roc || ' 年第 ' || p.paper_order || ' 卷'),
    selected_years = case when cardinality(a.selected_years)=0 then array[p.exam_year_roc]::smallint[] else a.selected_years end,
    selected_subjects = case when cardinality(a.selected_subjects)=0 then p.included_subjects else a.selected_subjects end
from public.exam_papers p
where p.paper_id = a.paper_id;
update public.exam_attempts set title = coalesce(title, '刷題紀錄');
alter table public.exam_attempts alter column title set not null;
alter table public.exam_attempts alter column paper_id drop not null;
alter table public.exam_attempts alter column expires_at drop not null;

-- Drop legacy anonymous checks so custom untimed attempts can use a null deadline.
do $$
declare r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'public.exam_attempts'::regclass
      and contype = 'c'
      and (
        pg_get_constraintdef(oid) ilike '%expires_at > started_at%'
        or pg_get_constraintdef(oid) ilike '%status =%in_progress%'
      )
  loop
    execute format('alter table public.exam_attempts drop constraint if exists %I', r.conname);
  end loop;
end $$;

alter table public.exam_attempts drop constraint if exists exam_attempts_mode_check;
alter table public.exam_attempts add constraint exam_attempts_mode_check
  check (attempt_mode in ('official_paper','subject_pool','wrong_review'));
alter table public.exam_attempts drop constraint if exists exam_attempts_deadline_check;
alter table public.exam_attempts add constraint exam_attempts_deadline_check
  check ((is_timed = true and expires_at is not null and expires_at > started_at)
      or (is_timed = false and expires_at is null));
alter table public.exam_attempts drop constraint if exists exam_attempts_status_fields_check;
alter table public.exam_attempts add constraint exam_attempts_status_fields_check
  check ((status = 'in_progress' and submitted_at is null and submit_reason is null)
      or (status <> 'in_progress' and submitted_at is not null and submit_reason is not null));
alter table public.exam_attempts drop constraint if exists exam_attempts_official_paper_check;
alter table public.exam_attempts add constraint exam_attempts_official_paper_check
  check (attempt_mode <> 'official_paper' or paper_id is not null);

create table if not exists public.subject_exam_config (
  config_key text primary key,
  subject_name text not null,
  subsubject_name text,
  paper_code text not null,
  target_question_count smallint not null check (target_question_count > 0),
  seconds_per_question numeric(8,3) not null check (seconds_per_question > 0),
  display_order smallint not null,
  is_active boolean not null default true
);

insert into public.subject_exam_config
  (config_key,subject_name,subsubject_name,paper_code,target_question_count,seconds_per_question,display_order)
values
  ('憲法','憲法',null,'2301',20,72,10),
  ('行政法','行政法',null,'2301',35,72,20),
  ('國際公法','國際公法',null,'2301',10,72,30),
  ('國際私法','國際私法',null,'2301',10,72,40),
  ('民法','民法',null,'3301',50,75,50),
  ('民法/財產法','民法','財產法','3301',35,75,51),
  ('民法/親屬繼承','民法','親屬繼承','3301',15,75,52),
  ('民事訴訟法','民事訴訟法',null,'3301',30,75,60),
  ('公司法','公司法',null,'4301',15,68.571,70),
  ('保險法','保險法',null,'4301',10,68.571,80),
  ('票據法','票據法',null,'4301',10,68.571,90),
  ('證券交易法','證券交易法',null,'4301',10,68.571,100),
  ('強制執行法','強制執行法',null,'4301',10,68.571,110),
  ('法學英文','法學英文',null,'4301',15,68.571,120),
  ('刑法','刑法',null,'1301',35,72,130),
  ('刑事訴訟法','刑事訴訟法',null,'1301',25,72,140),
  ('法律倫理','法律倫理',null,'1301',15,72,150)
on conflict (config_key) do update set
  subject_name=excluded.subject_name,
  subsubject_name=excluded.subsubject_name,
  paper_code=excluded.paper_code,
  target_question_count=excluded.target_question_count,
  seconds_per_question=excluded.seconds_per_question,
  display_order=excluded.display_order,
  is_active=true;

create table if not exists public.question_annotations (
  user_id uuid not null references auth.users(id) on delete cascade,
  question_id text not null references public.questions(question_id) on delete cascade,
  is_starred boolean not null default false,
  note_text text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id,question_id)
);

create table if not exists public.attempt_question_activity (
  attempt_id uuid not null,
  question_id text not null,
  active_seconds integer not null default 0 check (active_seconds >= 0),
  first_viewed_at timestamptz not null default now(),
  last_viewed_at timestamptz not null default now(),
  primary key (attempt_id,question_id),
  foreign key (attempt_id,question_id)
    references public.attempt_questions(attempt_id,question_id) on delete cascade
);

create table if not exists public.exam_cutoffs (
  exam_year_roc smallint primary key,
  judicial_cutoff numeric(8,2),
  lawyer_cutoff numeric(8,2),
  source_url text not null,
  verification_status text not null default 'verified',
  updated_at timestamptz not null default now()
);

insert into public.exam_cutoffs (exam_year_roc,judicial_cutoff,lawyer_cutoff,source_url,verification_status)
values
  (110,410,402,'https://data.gov.tw/dataset/164772','verified_from_official_open_data'),
  (111,382,372,'https://wwwc.moex.gov.tw/main/examreport/','verified'),
  (112,384,374,'https://wwwc.moex.gov.tw/main/examreport/wHandStatisticsFile.ashx?file_id=2219','verified_from_official_distribution'),
  (113,362,354,'https://wwwc.moex.gov.tw/main/examreport/','verified'),
  (114,368,360,'https://wwwc.moex.gov.tw/main/examreport/wHandStatisticsFile.ashx?file_id=3435','verified')
on conflict (exam_year_roc) do update set
  judicial_cutoff=excluded.judicial_cutoff,
  lawyer_cutoff=excluded.lawyer_cutoff,
  source_url=excluded.source_url,
  verification_status=excluded.verification_status,
  updated_at=now();

create index if not exists questions_subject_year_idx
  on public.questions (subject_primary,subsubject_primary,paper_id);
create index if not exists annotations_user_star_idx
  on public.question_annotations (user_id,is_starred);

-- Complete and score one attempt. Official answers remain in the private schema.
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
  select * into v_attempt from public.exam_attempts where id=p_attempt_id for update;
  if not found then raise exception 'Attempt not found'; end if;
  if v_attempt.status <> 'in_progress' then return v_attempt; end if;

  v_reason := case
    when v_attempt.is_timed and now() >= v_attempt.expires_at then 'timeout'::public.submit_reason
    else coalesce(p_requested_reason,'manual'::public.submit_reason)
  end;

  select count(*) filter (where aa.selected_answer::text = any(ak.accepted_answers)), count(aa.selected_answer)
  into v_correct,v_answered
  from public.attempt_questions aq
  join private.question_answer_keys ak on ak.question_id=aq.question_id
  left join public.attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=aq.question_id
  where aq.attempt_id=p_attempt_id;

  update public.exam_attempts set
    status=case when v_reason='timeout' then 'timed_out'::public.attempt_status else 'submitted'::public.attempt_status end,
    submit_reason=v_reason,
    submitted_at=case when v_reason='timeout' then expires_at else now() end,
    correct_count=v_correct,
    unanswered_count=question_count-v_answered,
    score=v_correct*points_per_question,
    elapsed_seconds=greatest(0,extract(epoch from ((case when v_reason='timeout' then expires_at else now() end)-started_at))::integer)
  where id=p_attempt_id returning * into v_attempt;
  return v_attempt;
end $$;

create or replace function public.start_exam_attempt(p_paper_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  u uuid:=auth.uid(); p public.exam_papers%rowtype; a public.exam_attempts%rowtype;
  started timestamptz:=clock_timestamp(); n integer; stale record;
begin
  if u is null then raise exception 'Authentication required'; end if;
  for stale in select id from public.exam_attempts where user_id=u and status='in_progress' and is_timed and expires_at<=now()
  loop perform private.finalize_exam_attempt(stale.id,'timeout'); end loop;
  select * into p from public.exam_papers where paper_id=p_paper_id and is_published;
  if not found then raise exception 'Published paper not found'; end if;
  select * into a from public.exam_attempts where user_id=u and paper_id=p_paper_id and attempt_mode='official_paper' and status='in_progress' and expires_at>now() order by started_at desc limit 1;
  if found then return jsonb_build_object('attempt_id',a.id,'resumed',true,'started_at',a.started_at,'expires_at',a.expires_at,'duration_minutes',a.duration_minutes); end if;
  select count(*) into n from public.questions where paper_id=p_paper_id and is_published;
  if n<>p.question_count then raise exception 'Paper expects % questions but % are published',p.question_count,n; end if;
  insert into public.exam_attempts(user_id,paper_id,attempt_mode,title,is_timed,selected_years,selected_subjects,duration_minutes,question_count,points_per_question,max_score,started_at,expires_at)
  values(u,p.paper_id,'official_paper',p.exam_year_roc||' 年第 '||p.paper_order||' 卷',true,array[p.exam_year_roc]::smallint[],p.included_subjects,p.duration_minutes,n,p.points_per_question,p.max_score,started,started+make_interval(mins=>p.duration_minutes)) returning * into a;
  insert into public.attempt_questions(attempt_id,question_id,display_order)
  select a.id,question_id,question_number from public.questions where paper_id=p_paper_id and is_published order by question_number;
  return jsonb_build_object('attempt_id',a.id,'resumed',false,'started_at',a.started_at,'expires_at',a.expires_at,'duration_minutes',a.duration_minutes);
end $$;

create or replace function public.start_subject_attempt(
  p_years smallint[],
  p_subjects text[],
  p_subsubjects text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  u uuid:=auth.uid(); a public.exam_attempts%rowtype; started timestamptz:=clock_timestamp();
  n integer; total_seconds integer; attempt_title text;
begin
  if u is null then raise exception 'Authentication required'; end if;
  if coalesce(cardinality(p_years),0)=0 then raise exception 'Select at least one year'; end if;
  if coalesce(cardinality(p_subjects),0)=0 and coalesce(cardinality(p_subsubjects),0)=0 then raise exception 'Select at least one subject'; end if;

  select string_agg(label,'＋' order by display_order)
  into attempt_title
  from (
    select distinct c.display_order,coalesce(c.subsubject_name,c.subject_name) label
    from public.subject_exam_config c
    where c.is_active and (
      (c.subsubject_name is not null and c.subsubject_name=any(coalesce(p_subsubjects,'{}'::text[])))
      or (c.subsubject_name is null and c.subject_name=any(coalesce(p_subjects,'{}'::text[]))
          and not (c.subject_name='民法' and coalesce(cardinality(p_subsubjects),0)>0))
    )
  ) s;
  if attempt_title is null then raise exception 'No matching subject configuration'; end if;

  insert into public.exam_attempts(user_id,paper_id,attempt_mode,title,is_timed,selected_years,selected_subjects,selected_subsubjects,duration_minutes,question_count,points_per_question,max_score,started_at,expires_at)
  values(u,null,'subject_pool',attempt_title||'｜自組測驗',true,p_years,p_subjects,coalesce(p_subsubjects,'{}'),1,1,2,2,started,started+interval '1 minute') returning * into a;

  with configs as (
    select c.*,
      case
        when cardinality(p_years)=1 then (
          select count(*)::smallint
          from public.questions q2
          join public.exam_papers p2 on p2.paper_id=q2.paper_id
          where q2.is_published
            and p2.exam_year_roc=p_years[1]
            and q2.subject_primary=c.subject_name
            and (c.subsubject_name is null or q2.subsubject_primary=c.subsubject_name)
        )
        else c.target_question_count
      end as effective_target_count
    from public.subject_exam_config c
    where c.is_active and (
      (c.subsubject_name is not null and c.subsubject_name=any(coalesce(p_subsubjects,'{}'::text[])))
      or (c.subsubject_name is null and c.subject_name=any(coalesce(p_subjects,'{}'::text[]))
          and not (c.subject_name='民法' and coalesce(cardinality(p_subsubjects),0)>0))
    )
  ), candidates as (
    select q.question_id,c.config_key,c.display_order,c.effective_target_count as target_question_count,c.seconds_per_question,
           row_number() over(partition by c.config_key order by random()) rn
    from configs c
    join public.questions q on q.subject_primary=c.subject_name
      and (c.subsubject_name is null or q.subsubject_primary=c.subsubject_name)
    join public.exam_papers p on p.paper_id=q.paper_id
    where q.is_published and p.exam_year_roc=any(p_years)
  ), chosen as (
    select * from candidates where rn<=target_question_count
  )
  insert into public.attempt_questions(attempt_id,question_id,display_order)
  select a.id,question_id,row_number() over(order by display_order,random())::smallint
  from chosen;

  select count(*),ceil(sum(c.seconds_per_question))::integer
  into n,total_seconds
  from public.attempt_questions aq
  join public.questions q on q.question_id=aq.question_id
  join public.subject_exam_config c on c.is_active
    and c.subject_name=q.subject_primary
    and (
      (c.subsubject_name is not null and c.subsubject_name=q.subsubject_primary and c.subsubject_name=any(coalesce(p_subsubjects,'{}'::text[])))
      or (c.subsubject_name is null and c.subject_name=any(coalesce(p_subjects,'{}'::text[]))
          and not (c.subject_name='民法' and coalesce(cardinality(p_subsubjects),0)>0))
    )
  where aq.attempt_id=a.id;
  if coalesce(n,0)=0 then delete from public.exam_attempts where id=a.id; raise exception 'No published questions match the selection'; end if;
  total_seconds:=greatest(total_seconds,60);
  update public.exam_attempts set duration_minutes=ceil(total_seconds/60.0)::smallint,question_count=n,max_score=n*2,expires_at=started+make_interval(secs=>total_seconds) where id=a.id returning * into a;
  return jsonb_build_object('attempt_id',a.id,'resumed',false,'started_at',a.started_at,'expires_at',a.expires_at,'duration_minutes',a.duration_minutes,'question_count',a.question_count);
end $$;

create or replace function public.start_wrong_review_attempt(
  p_years smallint[] default null,
  p_subjects text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare u uuid:=auth.uid(); a public.exam_attempts%rowtype; n integer; started timestamptz:=clock_timestamp();
begin
  if u is null then raise exception 'Authentication required'; end if;
  insert into public.exam_attempts(user_id,paper_id,attempt_mode,title,is_timed,selected_years,selected_subjects,duration_minutes,question_count,points_per_question,max_score,started_at,expires_at)
  values(u,null,'wrong_review','錯題重刷｜不計時',false,coalesce(p_years,'{}'),coalesce(p_subjects,'{}'),0,1,2,2,started,null) returning * into a;
  with wrong as (
    select distinct aq.question_id
    from public.exam_attempts olda
    join public.attempt_questions aq on aq.attempt_id=olda.id
    join private.question_answer_keys ak on ak.question_id=aq.question_id
    join public.attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=aq.question_id
    join public.questions q on q.question_id=aq.question_id
    join public.exam_papers p on p.paper_id=q.paper_id
    where olda.user_id=u and olda.status<>'in_progress' and not (aa.selected_answer::text = any(ak.accepted_answers))
      and (p_years is null or cardinality(p_years)=0 or p.exam_year_roc=any(p_years))
      and (p_subjects is null or cardinality(p_subjects)=0 or q.subject_primary=any(p_subjects))
  )
  insert into public.attempt_questions(attempt_id,question_id,display_order)
  select a.id,question_id,row_number() over(order by random())::smallint from wrong;
  select count(*) into n from public.attempt_questions where attempt_id=a.id;
  if n=0 then delete from public.exam_attempts where id=a.id; raise exception 'No wrong questions match the filters'; end if;
  update public.exam_attempts set question_count=n,max_score=n*2 where id=a.id returning * into a;
  return jsonb_build_object('attempt_id',a.id,'resumed',false,'started_at',a.started_at,'expires_at',null,'duration_minutes',0,'question_count',n);
end $$;

create or replace function public.save_attempt_answer(p_attempt_id uuid,p_question_id text,p_selected_answer text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare u uuid:=auth.uid(); a public.exam_attempts%rowtype; t timestamptz:=clock_timestamp();
begin
  if u is null then raise exception 'Authentication required'; end if;
  if p_selected_answer not in ('A','B','C','D') then raise exception 'Invalid answer'; end if;
  select * into a from public.exam_attempts where id=p_attempt_id and user_id=u for update;
  if not found then raise exception 'Attempt not found'; end if;
  if a.status<>'in_progress' then return jsonb_build_object('ok',false,'status',a.status); end if;
  if a.is_timed and now()>=a.expires_at then a:=private.finalize_exam_attempt(p_attempt_id,'timeout'); return jsonb_build_object('ok',false,'status',a.status); end if;
  if not exists(select 1 from public.attempt_questions where attempt_id=p_attempt_id and question_id=p_question_id) then raise exception 'Question is not part of this attempt'; end if;
  insert into public.attempt_answers(attempt_id,question_id,selected_answer,saved_at) values(p_attempt_id,p_question_id,p_selected_answer::char(1),t)
  on conflict(attempt_id,question_id) do update set selected_answer=excluded.selected_answer,saved_at=excluded.saved_at;
  return jsonb_build_object('ok',true,'status','in_progress','saved_at',t);
end $$;

create or replace function public.save_question_annotation(p_question_id text,p_is_starred boolean,p_note_text text default '')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.questions where question_id=p_question_id) then raise exception 'Question not found'; end if;
  insert into public.question_annotations(user_id,question_id,is_starred,note_text,updated_at)
  values(u,p_question_id,coalesce(p_is_starred,false),left(coalesce(p_note_text,''),4000),now())
  on conflict(user_id,question_id) do update set is_starred=excluded.is_starred,note_text=excluded.note_text,updated_at=now();
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.add_question_active_seconds(p_attempt_id uuid,p_question_id text,p_seconds integer)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid:=auth.uid();
begin
  if u is null then raise exception 'Authentication required'; end if;
  if p_seconds<1 or p_seconds>300 then raise exception 'Invalid seconds delta'; end if;
  if not exists(select 1 from public.exam_attempts where id=p_attempt_id and user_id=u and status='in_progress') then raise exception 'Active attempt not found'; end if;
  if not exists(select 1 from public.attempt_questions where attempt_id=p_attempt_id and question_id=p_question_id) then raise exception 'Question is not part of this attempt'; end if;
  insert into public.attempt_question_activity(attempt_id,question_id,active_seconds,last_viewed_at)
  values(p_attempt_id,p_question_id,p_seconds,now())
  on conflict(attempt_id,question_id) do update set active_seconds=public.attempt_question_activity.active_seconds+excluded.active_seconds,last_viewed_at=now();
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.get_attempt_payload(p_attempt_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare u uuid:=auth.uid(); a public.exam_attempts%rowtype; out jsonb;
begin
  if u is null then raise exception 'Authentication required'; end if;
  select * into a from public.exam_attempts where id=p_attempt_id and user_id=u;
  if not found then raise exception 'Attempt not found'; end if;
  if a.status='in_progress' and a.is_timed and now()>=a.expires_at then a:=private.finalize_exam_attempt(p_attempt_id,'timeout'); end if;
  select jsonb_build_object(
    'attempt',jsonb_build_object('id',a.id,'paper_id',a.paper_id,'attempt_mode',a.attempt_mode,'title',a.title,'is_timed',a.is_timed,'status',a.status,'duration_minutes',a.duration_minutes,'question_count',a.question_count,'points_per_question',a.points_per_question,'max_score',a.max_score,'started_at',a.started_at,'expires_at',a.expires_at,'submitted_at',a.submitted_at,'submit_reason',a.submit_reason,'selected_years',a.selected_years,'selected_subjects',a.selected_subjects,'selected_subsubjects',a.selected_subsubjects),
    'paper',case when p.paper_id is null then null else jsonb_build_object('exam_year_roc',p.exam_year_roc,'paper_order',p.paper_order,'paper_code',p.paper_code,'paper_title',p.paper_title,'included_subjects',p.included_subjects,'source_question_url',p.source_question_url) end,
    'questions',coalesce(jsonb_agg(jsonb_build_object('question_id',q.question_id,'display_order',aq.display_order,'question_number',q.question_number,'question_text',q.question_text,'option_a',q.option_a,'option_b',q.option_b,'option_c',q.option_c,'option_d',q.option_d,'selected_answer',aa.selected_answer,'review_status',q.review_status,'subject_primary',q.subject_primary,'subsubject_primary',q.subsubject_primary,'is_starred',coalesce(ann.is_starred,false),'note_text',coalesce(ann.note_text,''),'active_seconds',coalesce(act.active_seconds,0)) order by aq.display_order),'[]'::jsonb)
  ) into out
  from public.exam_attempts a
  left join public.exam_papers p on p.paper_id=a.paper_id
  join public.attempt_questions aq on aq.attempt_id=a.id
  join public.questions q on q.question_id=aq.question_id
  left join public.attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=aq.question_id
  left join public.question_annotations ann on ann.user_id=a.user_id and ann.question_id=q.question_id
  left join public.attempt_question_activity act on act.attempt_id=a.id and act.question_id=q.question_id
  where a.id=p_attempt_id group by a.id,p.paper_id;
  return out;
end $$;

create or replace function public.submit_exam_attempt(p_attempt_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare u uuid:=auth.uid(); a public.exam_attempts%rowtype;
begin
  if u is null then raise exception 'Authentication required'; end if;
  select * into a from public.exam_attempts where id=p_attempt_id and user_id=u;
  if not found then raise exception 'Attempt not found'; end if;
  a:=private.finalize_exam_attempt(p_attempt_id,case when a.is_timed and now()>=a.expires_at then 'timeout'::public.submit_reason else 'manual'::public.submit_reason end);
  return jsonb_build_object('attempt_id',a.id,'status',a.status,'submit_reason',a.submit_reason,'submitted_at',a.submitted_at,'score',a.score,'max_score',a.max_score,'correct_count',a.correct_count,'unanswered_count',a.unanswered_count);
end $$;

create or replace function public.get_attempt_result(p_attempt_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare u uuid:=auth.uid(); a public.exam_attempts%rowtype; out jsonb;
begin
  if u is null then raise exception 'Authentication required'; end if;
  select * into a from public.exam_attempts where id=p_attempt_id and user_id=u;
  if not found then raise exception 'Attempt not found'; end if;
  if a.status='in_progress' and a.is_timed and now()>=a.expires_at then a:=private.finalize_exam_attempt(p_attempt_id,'timeout');
  elsif a.status='in_progress' then raise exception 'Attempt is still in progress'; end if;
  select jsonb_build_object(
    'attempt',jsonb_build_object('id',a.id,'attempt_mode',a.attempt_mode,'title',a.title,'is_timed',a.is_timed,'status',a.status,'duration_minutes',a.duration_minutes,'question_count',a.question_count,'started_at',a.started_at,'expires_at',a.expires_at,'submitted_at',a.submitted_at,'submit_reason',a.submit_reason,'correct_count',a.correct_count,'unanswered_count',a.unanswered_count,'score',a.score,'max_score',a.max_score,'elapsed_seconds',a.elapsed_seconds,'selected_years',a.selected_years,'selected_subjects',a.selected_subjects,'selected_subsubjects',a.selected_subsubjects),
    'paper',case when p.paper_id is null then null else jsonb_build_object('exam_year_roc',p.exam_year_roc,'paper_order',p.paper_order,'paper_code',p.paper_code,'paper_title',p.paper_title,'source_question_url',p.source_question_url,'source_answer_url',p.source_answer_url) end,
    'questions',coalesce(jsonb_agg(jsonb_build_object('question_id',q.question_id,'display_order',aq.display_order,'question_number',q.question_number,'question_text',q.question_text,'option_a',q.option_a,'option_b',q.option_b,'option_c',q.option_c,'option_d',q.option_d,'selected_answer',aa.selected_answer,'correct_answer',ak.final_answer,'correct_answers',ak.accepted_answers,'is_correct',coalesce(aa.selected_answer::text = any(ak.accepted_answers),false),'is_unanswered',aa.selected_answer is null,'subject_primary',q.subject_primary,'subsubject_primary',q.subsubject_primary,'is_starred',coalesce(ann.is_starred,false),'note_text',coalesce(ann.note_text,''),'active_seconds',coalesce(act.active_seconds,0)) order by aq.display_order),'[]'::jsonb)
  ) into out
  from public.exam_attempts a
  left join public.exam_papers p on p.paper_id=a.paper_id
  join public.attempt_questions aq on aq.attempt_id=a.id
  join public.questions q on q.question_id=aq.question_id
  join private.question_answer_keys ak on ak.question_id=q.question_id
  left join public.attempt_answers aa on aa.attempt_id=aq.attempt_id and aa.question_id=q.question_id
  left join public.question_annotations ann on ann.user_id=a.user_id and ann.question_id=q.question_id
  left join public.attempt_question_activity act on act.attempt_id=a.id and act.question_id=q.question_id
  where a.id=p_attempt_id group by a.id,p.paper_id;
  return out;
end $$;

create or replace function public.list_my_attempts()
returns jsonb language sql security definer set search_path=public,pg_temp stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',a.id,'attempt_mode',a.attempt_mode,'title',a.title,'is_timed',a.is_timed,
    'status',case when a.status='in_progress' and a.is_timed and a.expires_at<=now() then 'timed_out' else a.status::text end,
    'duration_minutes',a.duration_minutes,'question_count',a.question_count,'started_at',a.started_at,'expires_at',a.expires_at,'submitted_at',a.submitted_at,'submit_reason',a.submit_reason,
    'elapsed_seconds',a.elapsed_seconds,'correct_count',a.correct_count,'unanswered_count',a.unanswered_count,'score',a.score,'max_score',a.max_score,
    'paper_id',p.paper_id,'exam_year_roc',p.exam_year_roc,'paper_order',p.paper_order,'paper_title',p.paper_title,
    'selected_years',a.selected_years,'selected_subjects',a.selected_subjects,'selected_subsubjects',a.selected_subsubjects
  ) order by a.started_at desc),'[]'::jsonb)
  from public.exam_attempts a left join public.exam_papers p on p.paper_id=a.paper_id where a.user_id=auth.uid();
$$;

create or replace function public.list_my_year_summaries()
returns jsonb language sql security definer set search_path=public,pg_temp stable as $$
with ranked as (
  select a.*,p.exam_year_roc,p.paper_code,p.paper_order,
         row_number() over(partition by p.exam_year_roc,p.paper_code order by a.submitted_at desc) rn
  from public.exam_attempts a join public.exam_papers p on p.paper_id=a.paper_id
  where a.user_id=auth.uid() and a.attempt_mode='official_paper' and a.status<>'in_progress'
), latest as (select * from ranked where rn=1), sums as (
  select exam_year_roc,count(distinct paper_code) completed_papers,sum(score) total_score,sum(max_score) max_score,max(submitted_at) completed_at
  from latest group by exam_year_roc
)
select coalesce(jsonb_agg(jsonb_build_object('exam_year_roc',s.exam_year_roc,'completed_papers',s.completed_papers,'is_complete',s.completed_papers=4,'total_score',s.total_score,'max_score',s.max_score,'completed_at',s.completed_at,'judicial_cutoff',c.judicial_cutoff,'lawyer_cutoff',c.lawyer_cutoff,'cutoff_source_url',c.source_url) order by s.exam_year_roc desc),'[]'::jsonb)
from sums s left join public.exam_cutoffs c on c.exam_year_roc=s.exam_year_roc;
$$;

alter table public.subject_exam_config enable row level security;
alter table public.question_annotations enable row level security;
alter table public.attempt_question_activity enable row level security;
alter table public.exam_cutoffs enable row level security;

drop policy if exists "subject config readable" on public.subject_exam_config;
create policy "subject config readable" on public.subject_exam_config for select using (is_active=true);
drop policy if exists "cutoffs readable" on public.exam_cutoffs;
create policy "cutoffs readable" on public.exam_cutoffs for select using (true);
drop policy if exists "users read own annotations" on public.question_annotations;
create policy "users read own annotations" on public.question_annotations for select to authenticated using(auth.uid()=user_id);
drop policy if exists "users read own activity" on public.attempt_question_activity;
create policy "users read own activity" on public.attempt_question_activity for select to authenticated using(exists(select 1 from public.exam_attempts a where a.id=attempt_id and a.user_id=auth.uid()));

revoke all on public.subject_exam_config,public.question_annotations,public.attempt_question_activity,public.exam_cutoffs from anon,authenticated;
grant select on public.subject_exam_config,public.exam_cutoffs to anon,authenticated;
grant select on public.question_annotations,public.attempt_question_activity to authenticated;

revoke all on function private.finalize_exam_attempt(uuid,public.submit_reason) from public,anon,authenticated;
revoke all on function public.start_exam_attempt(text) from public,anon;
revoke all on function public.start_subject_attempt(smallint[],text[],text[]) from public,anon;
revoke all on function public.start_wrong_review_attempt(smallint[],text[]) from public,anon;
revoke all on function public.save_attempt_answer(uuid,text,text) from public,anon;
revoke all on function public.save_question_annotation(text,boolean,text) from public,anon;
revoke all on function public.add_question_active_seconds(uuid,text,integer) from public,anon;
revoke all on function public.get_attempt_payload(uuid) from public,anon;
revoke all on function public.submit_exam_attempt(uuid) from public,anon;
revoke all on function public.get_attempt_result(uuid) from public,anon;
revoke all on function public.list_my_attempts() from public,anon;
revoke all on function public.list_my_year_summaries() from public,anon;

grant execute on function public.start_exam_attempt(text) to authenticated;
grant execute on function public.start_subject_attempt(smallint[],text[],text[]) to authenticated;
grant execute on function public.start_wrong_review_attempt(smallint[],text[]) to authenticated;
grant execute on function public.save_attempt_answer(uuid,text,text) to authenticated;
grant execute on function public.save_question_annotation(text,boolean,text) to authenticated;
grant execute on function public.add_question_active_seconds(uuid,text,integer) to authenticated;
grant execute on function public.get_attempt_payload(uuid) to authenticated;
grant execute on function public.submit_exam_attempt(uuid) to authenticated;
grant execute on function public.get_attempt_result(uuid) to authenticated;
grant execute on function public.list_my_attempts() to authenticated;
grant execute on function public.list_my_year_summaries() to authenticated;


-- BEGIN V2 paper_id ambiguity hotfix
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

-- END V2 paper_id ambiguity hotfix
