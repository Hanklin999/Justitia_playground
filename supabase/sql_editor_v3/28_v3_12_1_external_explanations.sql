-- Justitia's playground v3.12.1
-- Third-party external explanation links (repeat-safe)
-- Verified: 2026-07-25 12:34:33 UTC+8

create extension if not exists pgcrypto;

create table if not exists public.external_explanation_links (
  id uuid primary key default gen_random_uuid(),
  provider_name text not null,
  external_url text not null,
  coverage_year smallint not null check (coverage_year between 100 and 200),
  paper_type text not null check (paper_type in ('civil', 'criminal', 'public', 'commercial')),
  question_start smallint not null check (question_start > 0),
  question_end smallint not null check (question_end >= question_start),
  last_verified_at timestamptz not null default now(),
  link_status text not null default 'unverified'
    check (link_status in ('active', 'login_required', 'unverified', 'broken', 'retired')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider_name, coverage_year, paper_type, question_start, question_end),
  check (external_url ~ '^https://www[.]facebook[.]com/')
);

comment on table public.external_explanation_links is
  'Metadata-only links to third-party explanations. No external content is copied, embedded, OCRed, summarized, or modified.';
comment on column public.external_explanation_links.paper_type is
  'civil=民事法, criminal=刑事法, public=公法, commercial=商事法';
comment on column public.external_explanation_links.link_status is
  'active=content reachable; login_required=redirect reachable but Facebook may require login; unverified/broken/retired are hidden from users.';

create index if not exists external_explanation_lookup_idx
  on public.external_explanation_links (coverage_year, paper_type, question_start, question_end)
  where link_status in ('active', 'login_required');

alter table public.external_explanation_links enable row level security;

drop policy if exists "authenticated users read available external explanations"
  on public.external_explanation_links;
create policy "authenticated users read available external explanations"
  on public.external_explanation_links
  for select to authenticated
  using (link_status in ('active', 'login_required'));

revoke all on public.external_explanation_links from anon;
grant select on public.external_explanation_links to authenticated;

-- Store direct Facebook URLs instead of Bitly links. This removes one redirect
-- layer and lets the URL/status be updated in Supabase without redeploying.
insert into public.external_explanation_links (
  provider_name,
  external_url,
  coverage_year,
  paper_type,
  question_start,
  question_end,
  last_verified_at,
  link_status
)
values
  -- 113 民事法
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=921241516880961&set=a.2163796637117305', 113, 'civil', 1, 25, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=922022406802872&set=a.2163796637117305', 113, 'civil', 26, 50, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=950672707271175&set=a.568930865445363', 113, 'civil', 51, 80, '2026-07-25 12:34:33+08', 'login_required'),
  -- 113 刑事法
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=960117049660074&set=a.568930865445363', 113, 'criminal', 1, 20, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=960877562917356&set=a.568930865445363', 113, 'criminal', 21, 35, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=975130044825441&set=a.568930865445363', 113, 'criminal', 36, 60, '2026-07-25 12:34:33+08', 'login_required'),
  -- 113 公法
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=999946039010508&set=a.568930865445363', 113, 'public', 1, 20, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=991091009896011&set=a.568930865445363', 113, 'public', 21, 55, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=1002125735459205&set=a.568930865445363', 113, 'public', 66, 75, '2026-07-25 12:34:33+08', 'login_required'),
  -- 113 商事法（同一網址涵蓋兩個不連續區段，因此以兩筆 range metadata 共用網址）
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=1016387164033062&set=a.568930865445363', 113, 'commercial', 1, 15, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=1015471940791251&set=a.568930865445363', 113, 'commercial', 16, 25, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=1001400912198354&set=a.568930865445363', 113, 'commercial', 26, 35, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=1000758925595886&set=a.2163796637117305', 113, 'commercial', 36, 45, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=1001400912198354&set=a.568930865445363', 113, 'commercial', 46, 55, '2026-07-25 12:34:33+08', 'login_required'),

  -- 112 民事法
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=761217282883386&set=a.2163796637117305', 112, 'civil', 1, 50, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=763038086034639&set=a.2163796637117305', 112, 'civil', 51, 80, '2026-07-25 12:34:33+08', 'login_required'),
  -- 112 刑事法
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/posts/pfbid02MiFZUbrmYn2Bv1ekmKKroWxQZtJCVko1GeJhGsweeRfVztTAGTXsvjVC4sLLhSkol', 112, 'criminal', 1, 35, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/posts/pfbid03Vs35RCxrxqdrvd5AugMigPcUxMrZEwomkJNQwZ1NthAjHVCq4pFndqGkP1bNopZl', 112, 'criminal', 36, 60, '2026-07-25 12:34:33+08', 'login_required'),
  -- 112 公法
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=770642315274216&set=a.568930865445363', 112, 'public', 1, 20, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=769497545388693&set=a.568930865445363', 112, 'public', 21, 55, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=773485954989852&set=a.568930865445363', 112, 'public', 66, 75, '2026-07-25 12:34:33+08', 'login_required'),
  -- 112 商事法
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=763613189310462&set=a.568930865445363', 112, 'commercial', 1, 15, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=768921145446333&set=a.568930865445363', 112, 'commercial', 16, 25, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=772903418381439&set=a.568930865445363', 112, 'commercial', 26, 35, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=772330838438697&set=a.568930865445363', 112, 'commercial', 36, 45, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=772903418381439&set=a.568930865445363', 112, 'commercial', 46, 55, '2026-07-25 12:34:33+08', 'login_required'),

  -- 111 民事法
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=574076748264108&set=pb.100069853624023.-2207520000.', 111, 'civil', 1, 25, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=574145898257193&set=a.2163796637117305', 111, 'civil', 26, 50, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2466284906868475/', 111, 'civil', 51, 80, '2026-07-25 12:34:33+08', 'login_required'),
  -- 111 刑事法
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/posts/pfbid0CyCHo1V2EWi8kf87zXBro5JHuNjA3YuLtBszWwGMRb6VeNA3iRvF9x3uRfUAfbDzl', 111, 'criminal', 1, 35, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2452382348258731/', 111, 'criminal', 36, 60, '2026-07-25 12:34:33+08', 'login_required'),
  -- 111 公法（使用者提供清單未包含憲法 1–20 題，故不建立未經確認的連結）
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.2163796637117305/2451688938328072/', 111, 'public', 21, 55, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=572145271790589&set=a.568930865445363', 111, 'public', 66, 75, '2026-07-25 12:34:33+08', 'login_required'),
  -- 111 商事法
  ('全人法學中心', 'https://www.facebook.com/photo/?fbid=574204968251286&set=a.568930865445363', 111, 'commercial', 1, 35, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/photo.php?fbid=572722891732827&set=pb.100069853624023.-2207520000.&type=3', 111, 'commercial', 36, 45, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/posts/pfbid02ZGBAcLpkhDnRtrjBbznkcjXqme41BgjtNUNahiFw2mWHTJKkZEWPELhvj6NumEwml', 111, 'commercial', 46, 55, '2026-07-25 12:34:33+08', 'login_required'),

  -- 110 民事法
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/posts/pfbid02BeL2Xa3KvZC6M4PJ2fHJCDwAG7iArXeM9hSeP29RAtCjYxqzo7gqRyn9hKXGShxjl', 110, 'civil', 1, 50, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2185160401647595', 110, 'civil', 51, 80, '2026-07-25 12:34:33+08', 'login_required'),
  -- 110 刑事法
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2191430111020624/', 110, 'criminal', 1, 35, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2177426285754340', 110, 'criminal', 36, 60, '2026-07-25 12:34:33+08', 'login_required'),
  -- 110 公法
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2185168851646750', 110, 'public', 1, 55, '2026-07-25 12:34:33+08', 'login_required'),
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2185169724979996', 110, 'public', 56, 75, '2026-07-25 12:34:33+08', 'login_required'),
  -- 110 商事法
  ('全人法學中心', 'https://www.facebook.com/righteousnessbyfaith2016/photos/a.973701339460180/2169615859868716', 110, 'commercial', 1, 55, '2026-07-25 12:34:33+08', 'login_required')
on conflict (provider_name, coverage_year, paper_type, question_start, question_end)
do update set
  external_url = excluded.external_url,
  last_verified_at = excluded.last_verified_at,
  link_status = excluded.link_status,
  updated_at = now();

create or replace function public.list_attempt_external_explanations(p_attempt_id uuid)
returns table (
  link_id uuid,
  question_id text,
  provider_name text,
  external_url text,
  coverage_year smallint,
  paper_type text,
  question_start smallint,
  question_end smallint,
  last_verified_at timestamptz,
  link_status text
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    eel.id as link_id,
    aq.question_id,
    eel.provider_name,
    eel.external_url,
    eel.coverage_year,
    eel.paper_type,
    eel.question_start,
    eel.question_end,
    eel.last_verified_at,
    eel.link_status
  from public.attempt_questions aq
  join public.questions q
    on q.question_id = aq.question_id
  join public.exam_papers source_paper
    on source_paper.paper_id = q.paper_id
  join public.external_explanation_links eel
    on eel.coverage_year = source_paper.exam_year_roc
   and eel.paper_type = case source_paper.paper_code
      when '3301' then 'civil'
      when '1301' then 'criminal'
      when '2301' then 'public'
      when '4301' then 'commercial'
      else null
    end
   and q.question_number between eel.question_start and eel.question_end
   and eel.link_status in ('active', 'login_required')
  where aq.attempt_id = p_attempt_id
    and exists (
      select 1
      from public.exam_attempts a
      where a.id = p_attempt_id
        and a.user_id = auth.uid()
    )
  order by aq.display_order;
$$;

revoke all on function public.list_attempt_external_explanations(uuid) from public;
grant execute on function public.list_attempt_external_explanations(uuid) to authenticated;
