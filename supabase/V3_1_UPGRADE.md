# Supabase v3.1.0 升級

已完成 v3.0.0 的專案，只需到 Supabase SQL Editor 依序執行：

1. `sql_editor_v3/24_v3_1_attempt_review_workflow.sql`
2. `sql_editor_v3/25_verify_v3_1.sql`

不需要重跑 105–114 年題庫 seed。

## 這次新增

- `attempt_question_annotations`：每一回模考自己的星號與筆記；交卷後鎖定。
- `question_review_annotations`：跨回合保留的檢討星號與筆記。
- 模考日期、指定題數、預設題數、抽題策略、卷種與複習來源回合。
- `start_custom_subject_attempt`：自訂名稱、日期與題數。
- `start_review_attempt`：從指定回合，以錯題／模考星號／檢討星號聯集組卷。

## 自訂題數抽題規則

只有指定題數與預設題數不同時才啟用：

1. 找出該使用者最近 10 次與本次 scope 有交集的已完成作答回合。
2. 從上述回合中，將同 scope 且未拿滿分的題目去重後隨機抽取。
3. 若錯題不足，再從完整 scope 排除已選題後，不重複隨機補足。
4. 未作答不列入答錯題優先池；複選題部分得分屬於未拿滿分，會列入。

既有 `question_annotations` 資料會保留並匯入檢討標記，不會刪除。
若曾執行過早期 v3.1 草稿，舊的 `wrong_priority_50` 紀錄會自動轉成 `recent_10_wrong_priority`。

## 驗證

執行第二份 SQL 後，以下欄位與表應顯示 `true` 或 `1`：

- `exam_date_column`
- `paper_kinds_column`
- `source_attempts_column`
- `strategy_column`
- `exam_annotations_table`
- `review_annotations_table`
- `recent_scope_attempts_present`
- `recent_attempt_limit_is_10`
- `recent_wrong_pool_present`
