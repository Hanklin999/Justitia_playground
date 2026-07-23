# 題庫標準欄位

## 目前即可自動取得

| 欄位 | 用途 |
|---|---|
| `question_id` | 唯一鍵，格式 `年度-試卷代號-題號` |
| `exam_year_roc` / `exam_year_ad` | 民國年／西元年 |
| `exam_code` | 考選部考試代碼 |
| `exam_name` / `exam_stage` | 考試名稱與第一試 |
| `paper_id` / `paper_code` / `paper_order` | 試卷識別、官方代號與順序 |
| `paper_group` / `paper_title` | 綜合法學（一／二）與完整名稱 |
| `included_subjects` | 該卷包含的科目，以 `|` 分隔 |
| `duration_minutes` | 正式考試時長；建立 attempt 時複製保存 |
| `expected_question_count` | 官方題數 |
| `points_per_question` / `max_score` | 配分與滿分 |
| `question_number` | 該卷題號 |
| `question_type` | 第一版固定 `single_choice` |
| `question_text` | 題幹 |
| `option_a`–`option_d` | 四個選項 |
| `correct_answer` | 官方標準答案 |
| `official_answer_status` | 第一版為 `official_standard` |
| `source_*` | 官方網址、PDF 檔案與頁碼 |
| `extraction_status` | PDF 是否成功解析 |
| `review_status` | 人工 QA 狀態 |

## 先保留、第二階段人工標記

| 欄位 | 建議填法 |
|---|---|
| `subject_primary` | 主要科目，只填一個標準值 |
| `subject_secondary` | 次要科目，可用 `|` 分隔 |
| `chapter` | 章節 |
| `topic_primary` | 主要考點 |
| `topic_secondary` | 次要考點，可用 `|` 分隔 |
| `law_refs` | 法規與條號，例如 `民法§184|民法§185` |
| `tags` | 其他搜尋標籤 |
| `notes` | 疑義、舊法或人工校正紀錄 |

## 第一輪人工 QA

第一輪不是做法律考點標記，而是確認：題號、題幹、四個選項、官方答案、頁碼與試卷是否對齊。確認後將 `review_status` 改為 `verified_text_answer`。之後才進入科目與考點標記。
