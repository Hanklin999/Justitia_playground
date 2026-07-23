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

do $$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname = 'justitia-finalize-expired-attempts'
  order by jobid desc
  limit 1;

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;
end
$$;

select cron.schedule(
  'justitia-finalize-expired-attempts',
  '* * * * *',
  $$select private.finalize_expired_attempts();$$
);


