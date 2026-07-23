# Justitia_playground｜已確認產品決策

- 品牌：**Justitia's playground**
- 副標題：**司律陪考資料庫**
- 視覺：簡約、藍白、手機優先
- 第一版資料：113、114 年，共 8 份綜合法學試卷
- 模式：只做完整綜合法學試卷，不開放自由選科
- 資料庫仍保留 `subject/chapter/topic/law_refs` 欄位，供後續人工標記
- 題目來源：考選部官方考古題與標準答案 PDF
- 第一版不提供詳解
- 登入：Email Magic Link
- 每張試卷做完立即顯示該卷成績
- 超時自動交卷；一次 attempt 即一筆考試紀錄
- `duration_minutes` 必須複製進 attempt，避免日後試卷設定修改影響歷史紀錄
- Supabase、Netlify 在後續階段串接
