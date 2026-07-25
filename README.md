# Justitia's playground v3.12.8

> 司律陪考資料庫 — a practice, mock-exam and spaced-review platform for Taiwan's Bar & Judicial first-stage examination (司法官／律師第一試).

Question bank: official Ministry of Examination past papers, ROC years 105–114 — **40 papers, 2,968 questions**.

Chinese user guide (使用說明): [`README.zh-TW.md`](./README.zh-TW.md)

<!-- IMAGE: hero shot — see "Screenshots" below for the full list -->

## What it does

| Area | Capability |
| --- | --- |
| Practice | Official year papers (original question order, official duration) and custom subject papers (pick years + subjects, set name, mock date and question count) |
| Answering | Autosave, countdown with auto-submit on timeout, A–E multiple-select with official partial credit for ROC 105–106, per-question confidence, star + note |
| Diagnosis | Effective time per question (background tabs excluded), answer revisions, pace coach, front/back-half comparison, last-ten-minutes analysis, confidence calibration |
| Review | Full answer review with official answers, error-reason tagging, review stars/notes kept across attempts, third-party explanation links |
| Spaced review | 1 / 3 / 7 / 14 / 30 day scheduling driven by score and confidence; daily due list |
| History | Per-attempt records, filtering and sorting, permanent per-attempt deletion, review papers built from selected attempts |

Exam and review annotations are kept separate: **模考星號／筆記** are locked to one attempt and frozen at submit; **檢討星號／筆記** persist across attempts and feed the review-paper builder.

## v3.12.8 highlights

Mobile-first pass over every surface, using collapse instead of removal — no feature is hidden or deleted, only folded away by default.

- **Answering page**: pinned top chrome cut from 208px to 59px at 390×844 (question + option area 574px → 723px). Question index collapses to a pill in the top-left; prev/next sticks above the footer; star toggle now lives in the prev/next row; confidence and notes fold into 作答輔助.
- **Review page**: full-mark questions collapse to a one-line summary, filter tabs scroll on a single row, answer summary becomes a two-column grid, time/source log folds away, floating 下一個未滿分 jumps to the next imperfect question.
- **Practice page**: each exam year is a collapsible section (newest open by default); the builder summary sticks to the bottom on phones so 建立自組模考 is always reachable.
- **Today's review**: 科目分布 and 學習診斷 fold away so the start button is above the fold.
- **History**: filters/sorting and the review-paper builder are collapsible with an active-condition chip row.
- Footer actions are now 44px tap targets; answer saves are bounded by a 10s timeout so the submit buttons can never stay disabled.

Full list: [`RELEASE_NOTES_v3.12.8.md`](./RELEASE_NOTES_v3.12.8.md)

## Tech stack

- Next.js 16, React 19, TypeScript
- Supabase — PostgreSQL, Auth (email magic link), RLS, database functions
- Netlify deployment
- Python, pandas, PyMuPDF / pdfplumber for the ETL pipeline

Official answers live in a private schema and are never returned by the public API before submission.

## Local setup

```powershell
npm.cmd install
npm.cmd run validate:data
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

### Environment variables

```env
NEXT_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Never put a secret or service-role key in the frontend or in Git.

## Supabase migrations

v3.12.8 requires **no** schema change. Coming from an older database, run these in the Supabase SQL editor in order:

| From | Run |
| --- | --- |
| v3.1.0 | `26_v3_12_pacing_learning.sql`, `27_verify_v3_12.sql`, `28_v3_12_1_external_explanations.sql`, `29_verify_v3_12_1.sql` |
| v3.12.0 | `28_v3_12_1_external_explanations.sql`, `29_verify_v3_12_1.sql` |
| v3.12.1+ | nothing |

All files are under `supabase/sql_editor_v3/`. Details: `supabase/V3_12_1_UPGRADE.md`. The question-bank seed never needs re-running.

## Repository layout

```
app/                 Next.js App Router pages
  exam/[attemptId]   answering screen
  results/[attemptId] review screen
  practice/          paper & custom-paper picker
  history/           attempt history + review-paper builder
  review/            spaced-review dashboard
components/          shared UI (collapsible-panel)
lib/                 Supabase browser client, shared types
supabase/sql_editor_v3/  ordered SQL migrations
etl/                 PDF → structured question pipeline
data/                source manifests and notices
scripts/             data validation, TS syntax check
```

## Screenshots

Put images in `docs/images/` and reference them from both READMEs. Recommended set:

| File | Shot | Why |
| --- | --- | --- |
| `home-desktop.png` | Landing page, desktop | Hero image at the top of the README |
| `practice-year-collapsed.png` | 依年度 with year sections collapsed | Shows the collapse-first design |
| `practice-subject-builder.png` | 依科目 three-step builder with the summary bar | Explains custom papers |
| `exam-mobile.png` | Answering screen on a phone, index collapsed | The headline v3.12.8 change |
| `exam-mobile-index-open.png` | Same screen with the index expanded | Shows nothing was removed |
| `exam-desktop.png` | Answering screen on desktop with the left index | Desktop layout is unchanged |
| `results-overview.png` | Score hero + pace report expanded | Diagnosis capability |
| `results-question-wrong.png` | One imperfect question with error tagging open | Core review loop |
| `review-dashboard.png` | 今日待複習 with due counts | Spaced review |
| `history-filters.png` | History with the filter panel expanded and chips visible | Filtering/sorting |

Use 2× device pixel ratio, crop out browser chrome, and use a real attempt with plausible data. For mobile shots, 390×844 matches the measurements quoted above. Avoid showing a real email address in the header — sign in with a test account or blur it.

## Licence & notice

Application source code and the Ministry of Examination source PDFs are separate works. See [`NOTICE.md`](./NOTICE.md), `data/raw/SOURCE_NOTICE.md` and `etl/manifest.json`. Third-party explanation links open in a new tab; their content is neither copied nor modified.
