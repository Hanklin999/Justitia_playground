Justitia V2 seed - SQL Editor safe chunks

Prerequisite:
Run Justitia_V2_step_1_schema.sql successfully first.

In Supabase SQL Editor, create a new query for each file and run in numeric order:
00_exam_papers.sql
01_questions_batches_01_02.sql
02_questions_batches_03_04.sql
03_questions_batches_05_06.sql
04_questions_batches_07_08.sql
05_questions_batches_09_10.sql
06_questions_batches_11_12.sql
07_questions_batches_13_14.sql
08_questions_batches_15_16.sql
09_questions_batches_17_18.sql
10_questions_batch_19.sql
11_answers_batches_01_06.sql
12_answers_batches_07_12.sql
13_answers_batches_13_19.sql
14_verify.sql

Every seed chunk uses upsert/on conflict and has its own transaction. Rerunning a chunk is safe.
