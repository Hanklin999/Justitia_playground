-- Justitia's playground v3.12.1 verification
-- Run after 28_v3_12_1_external_explanations.sql.

-- Expected: 43 range records.
select count(*) as external_explanation_range_count
from public.external_explanation_links
where provider_name = '全人法學中心'
  and coverage_year between 110 and 113;

-- Expected: 0. Production rows should not depend on Bitly.
select count(*) as short_url_count
from public.external_explanation_links
where external_url ilike '%bit.ly%';

-- Expected: 0. All seeded production URLs are HTTPS Facebook URLs.
select count(*) as invalid_external_url_count
from public.external_explanation_links
where external_url !~ '^https://www[.]facebook[.]com/';

-- Expected: 0. No question range should overlap another range in the same year/paper.
select count(*) as overlapping_range_count
from public.external_explanation_links a
join public.external_explanation_links b
  on a.id < b.id
 and a.provider_name = b.provider_name
 and a.coverage_year = b.coverage_year
 and a.paper_type = b.paper_type
 and int4range(a.question_start, a.question_end, '[]') && int4range(b.question_start, b.question_end, '[]');

-- Expected: one row, prokind = f.
select p.proname, p.prokind
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'list_attempt_external_explanations';

-- Inspect status/verification timestamps.
select coverage_year, paper_type, question_start, question_end,
       link_status, last_verified_at, external_url
from public.external_explanation_links
order by coverage_year desc, paper_type, question_start;
