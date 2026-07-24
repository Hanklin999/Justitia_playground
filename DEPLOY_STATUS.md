# V2 deployment status

## Ready in this package

- Next.js V2 UI：依年度、依科目、自組卷、錯題重刷
- Email Magic Link client flow
- 110–114 年 20 卷、1,500 題
- 科目／民法子科目自動標記
- 111 年公法卷第 50 題 A／B 複數有效答案
- 正式卷與比例計時自組卷
- 答案、星號、私人筆記與題目活躍秒數
- 結果頁科目錯題分布與年度四卷總分
- 歷史紀錄年度／模式／科目／結果篩選
- Supabase V2 schema、RLS、RPC 與 private answer keys
- Netlify 設定檔

## Existing V1 project upgrade

In Supabase SQL Editor, run in order:

1. `supabase/v2_step_1_schema.sql`
2. `supabase/v2_step_2_seed.sql`
3. `supabase/v2_step_3_verify.sql`

Expected verification:

- papers = 20
- questions = 1500
- answer_keys = 1500
- `111-2301-050.accepted_answers = {A,B}`

Then replace／merge the project files, run locally:

```powershell
npm.cmd install
npm.cmd run build
npm.cmd run dev
```

Push to GitHub; Netlify will redeploy from the connected repository.

## Validation completed offline

- Python ETL: pass
- 20 paper QA rows: pass
- 1,500 unique questions: pass
- All subject mappings: pass
- 111 civil split 34／16: pass
- 111 Q50 correction: pass
- TypeScript／TSX syntax transpilation: pass
- Generated SQL lexical checks: pass

## Still requires your environment

This execution environment could not finish downloading npm dependencies, and it has no access to execute SQL against your Supabase project. A real `npm run build`, remote migration and end-to-end browser test must therefore run locally／on Netlify after the SQL upgrade.

## V2.1 hotfix
- Fixed PostgreSQL RPC error: `column reference "a.paper_id" is ambiguous`.
- The affected functions were `get_attempt_payload` and `get_attempt_result`.
- Existing Supabase projects should run `supabase/v2_hotfix_ambiguous_paper_id.sql` once.
