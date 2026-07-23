# Justitia_playground｜朱斯提亞練功房

> 簡單快速，找到題目。

司律一試正式綜合法學單卷模擬器。第一版收錄民國 113、114 年共 8 份官方試卷、600 題；依官方時長倒數，逐題自動保存，到時自動交卷並留下考試 Log。單卷完成後立即顯示分數、答錯與未作答，不提供詳解，也暫不開放自由選科。

## 已完成

- Next.js 16 App Router 藍白手機版介面
- Supabase Email Magic Link
- 113／114 年正式試卷列表
- 正式倒數與重新整理後恢復時間
- 逐題 RPC 自動保存
- 手動交卷／逾時交卷
- Supabase Cron 關閉頁面後仍可完成逾時 Log
- 單卷立即計分與答案對照
- 歷史考試紀錄
- RLS 與 private answer-key schema
- 考選部 PDF → CSV Python ETL
- 600 題 seed migration 與人工複核模板

## 快速開始

### 1. Supabase

在 Supabase SQL Editor 執行：

```text
supabase/setup_all.sql
```

或依序執行 `supabase/migrations/` 內三份 migration。

完整步驟：`docs/supabase-setup.md`

### 2. Next.js

```bash
npm install
npm run check:supabase
npm run dev
```

開啟 `http://localhost:3000`。

### 3. Netlify

參考 `docs/netlify-setup.md`。

## Python ETL

```bash
python -m venv .venv
# Windows PowerShell
.venv\Scripts\Activate.ps1
pip install -r etl/requirements.txt
python etl/extract_moex.py
python etl/generate_supabase_seed.py
```

主要輸出：

- `data/processed/questions_113_114.csv`
- `data/processed/papers_113_114.csv`
- `data/processed/qa_report.csv`
- `data/review/questions_review_template.csv`
- `supabase/migrations/0002_seed_113_114.sql`

## 尚待人工工作

目前 600 題皆標記為 `pending_manual_review`，方便先做產品與工程測試。正式公開前應逐題確認：

1. 題幹與 A–D 選項是否完整
2. 跨頁題目是否缺字
3. 官方答案是否與題號對齊
4. 是否有答案更正、複數答案或送分
5. 完成後將 `review_status` 改為 `verified_text_answer`

科目、章節、考點及法條欄位已保留，等文字與答案複核後再標記。

## 重要安全原則

Publishable Key 可出現在前端；Secret Key／`service_role` 不可。官方答案不在公開題目表，計分只在資料庫函式執行。

原始題目與標準答案來源：中華民國考選部考畢試題查詢平臺；完整來源網址位於 `etl/manifest.json`。
