# Supabase v3.0.0 Upgrade Guide

適用：目前已經有 Justitia's playground V1、V2 或 V2.1 資料庫。

## 0. 升級前

- 不要重跑舊版 `setup_all.sql`。
- 不要刪除 `auth.users`、`exam_attempts`、`attempt_answers`。
- 建議先在 Supabase Dashboard 建立資料庫備份。

## 1. 執行 Schema 與 RPC

SQL Editor → New query：

```text
supabase/sql_editor_v3/00_v3_schema_and_rpc.sql
```

此步新增／更新：

- Option E、題型與單題配分
- 複選答案保存
- 安全計分函式
- 完整題目／選項結果 payload
- 年度卷、科目卷、錯題重刷 RPC
- 星號、筆記與每題活躍秒數

## 2. 匯入 40 卷與 2,968 題

依序執行：

```text
01_exam_papers.sql
02_questions.sql
03_questions.sql
...
15_questions.sql
16_answers.sql
17_answers.sql
...
22_answers.sql
```

每份成功後再執行下一份。全部使用 upsert，可重跑失敗的單一 chunk。

## 3. 匯入歷史門檻

```text
23_cutoffs_105_114.sql
```

## 4. 驗證

```text
99_verify_v3.sql
```

預期：

```text
papers             40
questions          2968
answer_keys        2968
multiple_choice    64
bonus_questions    3
cutoff_years       10
```

並確認 `111-2301-050` 的 `accepted_answers` 為 `{A,B}`。

## 5. 前端發布

```powershell
npm.cmd install
npm.cmd run validate:data
npm.cmd run typecheck
npm.cmd run build
git add .
git commit -m "Release v3.0.0"
git push
```

Netlify 會自動部署。

## 6. 最小 E2E

- 114 年正式單選卷：作答、刷新、交卷、成績。
- 105 年含複選題卷：checkbox、部分得分、完整歷史回看。
- 科目模式：選一年、多年、單科與整卷快捷鍵。
- 星號與筆記：刷新後仍存在。
- 歷史紀錄：完整顯示 A–E、你的答案與官方答案。
- 錯題重刷：不計時。
