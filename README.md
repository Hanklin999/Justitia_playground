# Justitia_playground｜Justitia's playground

> 司律陪考資料庫

司法官／律師第一試刷題與正式單卷模擬平台。V2 收錄民國 110–114 年共 20 份官方綜合法學試卷、1,500 題，支援「依年度正式卷」與「依科目自組卷」兩種模式。

## V2 已完成

- Next.js App Router 藍白、手機優先介面
- Supabase Email Magic Link
- 110–114 年正式試卷，共 20 卷、1,500 題
- 依年度：年份 → 正式試卷 → 依官方時長作答
- 依科目：複選年份與科目，從題池抽取對應題數
- 自組卷按原正式卷平均每題秒數計時；錯題重刷不計時
- 公法卷、民事法卷、商事法卷、刑事法卷快速選擇
- 題號星號標記「不會」與私人筆記
- 逐題答案、星號、筆記與活躍時間自動保存
- 手動交卷／逾時交卷與歷史考試 Log
- 結果顯示開始、交卷、總花費時間與每題約略活躍時間
- 各科／子科目答對、答錯、未答分布
- 同年度四張正式卷完成後顯示總分與歷史門檻比較
- 歷史紀錄依年度、模式、科目篩選
- 針對錯題建立不計時重刷
- 官方答案存於 private schema，支援複數有效答案，前端無法在交卷前取得
- RLS 與 Security Definer RPC
- 考選部 PDF → CSV Python ETL

## 快速升級 V2

既有 Supabase V1 專案只需在 SQL Editor 執行：

```text
supabase/setup_v2.sql
```

這份檔案會：

1. 新增 V2 schema、RLS 與 RPC
2. upsert 110–114 年 20 卷、1,500 題與 private answer keys
3. 保留既有使用者、歷史 attempt 與作答紀錄

接著本機執行：

```powershell
npm.cmd install
npm.cmd run build
npm.cmd run dev
```

開啟 `http://localhost:3000`。

## Python ETL

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r etl/requirements.txt
python etl/extract_moex.py
python etl/generate_supabase_seed.py
```

主要輸出：

- `data/processed/questions_110_114.csv`
- `data/processed/papers_110_114.csv`
- `data/processed/qa_report.csv`
- `data/review/questions_review_template.csv`
- `supabase/migrations/0005_seed_110_114.sql`

## 題目分類

V2 依官方試卷題號自動填入 `subject_primary` 與 `subsubject_primary`。未命中規則的題目會標為「未分類」。目前 1,500 題全部命中既定規則。

後續仍需人工標記或複核：

- 章節與考點
- 法條
- 跨科題目的次要科目
- 答案更正、送分或複數答案（ETL 已納入已知官方更正）
- PDF 抽取的文字與特殊符號

## 計時定義

- 正式卷：使用該年度該卷官方時長。
- 科目自組卷：依原卷 `正式秒數 ÷ 正式題數 × 抽取題數` 計算。
- 民事法卷：民法 50 題＋民事訴訟法 30 題，合計 80 題／100 分鐘。
- 錯題重刷：不計時。
- 每題時間是使用者停留在該題頁面的累積活躍秒數，用於學習分析，不是防作弊的精密監考數據。
- 111 年公法卷第 50 題依考選部更正公告，A 或 B 均計分。

## 重要安全原則

Publishable Key 可出現在前端；Secret Key／`service_role` 不可。官方答案不在公開題目表，計分只透過資料庫函式執行。

原始題目與標準答案來源：中華民國考選部考畢試題查詢平臺；完整來源網址位於 `etl/manifest.json`。
