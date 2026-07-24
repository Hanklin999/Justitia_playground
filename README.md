# Justitia's playground v3.1.0

> 司律陪考資料庫

司法官／律師第一試刷題與單卷模擬平台。v3.1.0 延續民國 105–114 年考選部官方考古題，共 40 卷、2,968 題。

## v3.1.0 重點

- 分離模考與檢討星號／筆記，保留作答當下與考後檢討兩種脈絡。
- 歷史紀錄可按卷種、模考日期與得分率篩選排序。
- 可由指定作答回合的錯題／模考星號／檢討星號建立複習組卷。
- 科目自組模考可自訂名稱、日期與題數；非預設題數會優先從最近 10 回同範圍答錯題隨機抽取，再從題池不重複補足。

- 題庫擴充至近十年：105–114 年。
- 年度模式保留官方題序、題數、配分與考試時長。
- 科目模式可複選年度與科目，自動由題池組卷並按來源試卷平均秒數計時。
- 105–106 年完整支援 A–E 五選項複選題與部分得分。
- 題幹字級縮小、選項字級放大，強化長題閱讀與作答辨識。
- 作答中可加星號、寫私人筆記並自動保存。
- 結果與歷史紀錄可重看完整題目、A–E 選項、你的答案、可接受答案、單題得分與筆記。
- 顯示開始、交卷、總耗時與每題活躍時間。
- 顯示各科與民法子科目的未滿分／未答分布。
- 同年度四卷完成後顯示 600 分總分及司法官／律師歷史門檻。
- 錯題可依年度與科目建立不計時重刷。
- 官方答案放在 private schema，交卷前不由公開 API 回傳。

## 資料驗證

```powershell
python scripts/validate_v3.py
```

預期：

```text
PASS: v3.1.0 release gate
papers=40 questions=2968 single=2904 multiple=64
```

## Supabase 升級

既有 V2／V2.1 資料庫請依序在 SQL Editor 執行：

1. `supabase/sql_editor_v3/00_v3_schema_and_rpc.sql`
2. `01_exam_papers.sql`
3. `02_questions.sql` 至 `15_questions.sql`
4. `16_answers.sql` 至 `22_answers.sql`
5. `23_cutoffs_105_114.sql`
6. `99_verify_v3.sql`
7. v3.1.0 再執行 `24_v3_1_attempt_review_workflow.sql` 與 `25_verify_v3_1.sql`

全部採 repeat-safe／upsert 寫法，既有使用者、作答、星號與筆記不會被刪除。

驗證預期：

- papers = 40
- questions = 2968
- answer_keys = 2968
- multiple_choice = 64
- bonus_questions = 3
- cutoff_years = 10

完整步驟：`supabase/V3_UPGRADE.md`

## 本機啟動

```powershell
npm.cmd install
npm.cmd run validate:data
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

瀏覽：`http://localhost:3000`

## 環境變數

複製 `.env.example` 為 `.env.local`：

```env
NEXT_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Publishable Key 可以提供給前端；Secret／service-role key 不可放入前端、GitHub 或公開文件。

## 主要資料輸出

- `data/processed/questions_105_114.csv`
- `data/processed/papers_105_114.csv`
- `data/processed/qa_report_105_114.csv`
- `data/processed/subject_mapping_audit_v3.csv`
- `data/processed/official_corrections_audit_105_114.csv`
- `supabase/sql_editor_v3/`

## 技術架構

- Next.js 16 + React 19 + TypeScript
- Supabase PostgreSQL、Auth、RLS、Database Functions
- Netlify deployment
- Python + pandas + PyMuPDF／pdfplumber ETL
