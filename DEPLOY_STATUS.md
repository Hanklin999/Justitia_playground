# v3.0.0 deployment status

## 已完成

- 105–114 年 40 卷、2,968 題 ETL。
- 2,904 題單選、64 題舊制五選項複選。
- 每年度四卷配分合計均為 600 分。
- 15 筆官方更正／送分規則結構化，其中 3 題送分。
- 所有題目皆命中主要科目規則。
- 105、106、111 年民法特殊子科目切分已套用。
- 年度卷、科目自組卷與不計時錯題重刷。
- 單選／複選作答、自動保存、星號、筆記與每題活躍時間。
- 結果／歷史紀錄完整回看題幹、A–E 選項、使用者答案與官方可接受答案。
- 105–114 年司法官／律師歷史門檻資料表。
- Supabase v3 repeat-safe migration 與分段 SQL Editor 檔。
- Python v3 release gate：pass。

## 尚需在使用者環境執行

1. 依 `supabase/V3_UPGRADE.md` 執行 Supabase migration 與 seed chunks。
2. `npm.cmd install`
3. `npm.cmd run validate:data`
4. `npm.cmd run typecheck`
5. `npm.cmd run build`
6. 本機 E2E：年度卷、科目卷、單選、複選、部分得分、星號／筆記、完整歷史回看。
7. Push GitHub，讓 Netlify 自動重新部署。

## Release gate

```text
40 papers
2,968 questions
2,904 single-choice
64 multiple-choice
600 points per year
15 correction/bonus rows
3 bonus questions
```
