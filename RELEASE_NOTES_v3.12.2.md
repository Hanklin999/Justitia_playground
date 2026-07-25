# Release Notes — v3.12.2

Updated: 2026/07/25 16:20:58 (UTC+8)

## Result page UX

- The pacing report is collapsed by default and expands on demand.
- Third-party external references are collapsed per question.
- The error-diagnosis form is collapsed per incomplete question.
- The always-visible annotation row now contains only:
  - whether the question was marked during the exam;
  - the add/remove review-mark action.
- Exam notes and review notes are placed inside a collapsed details panel.

## Accessibility and mobile

- Uses native HTML `details` and `summary`.
- Supports keyboard activation without custom JavaScript state.
- Adds clear expand/collapse labels and mobile-friendly tap targets.

## Data and backend

- No new Supabase migration is required for v3.12.2.
- v3.12.1 external-reference SQL files remain bundled for installations that have not completed that upgrade.
