# Current deployment status

## Ready

- Supabase URL and Publishable Key configured in local `.env.local`
- Database schema, RLS, RPC scoring and private answer keys
- 113／114 year seed: 8 papers, 600 questions
- Email Magic Link UI and callback
- Timed exam runner, autosave, manual submit and timeout submit
- Result page and attempt history
- Optional/recommended one-minute timeout Cron
- Netlify configuration and deployment guide

## One manual action required now

Open Supabase Dashboard → SQL Editor and run:

```text
supabase/setup_all.sql
```

Then configure Authentication URL settings as described in `docs/supabase-setup.md`.

## Not yet verified remotely

The current execution environment cannot resolve the supplied Supabase host or reach npm, so it could not run the remote health check or a real `npm install && npm run build`. TypeScript source syntax, local strict-null checks with external module shims, Python ETL and CSV QA have been run successfully.
