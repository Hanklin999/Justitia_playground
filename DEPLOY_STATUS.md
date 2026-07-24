# v3.1.0 deployment status

## 已完成

- v3.0.0 近十年題庫、單選／複選與部分得分完整保留。
- 模考與檢討標記分流。
- 歷史紀錄篩選、排序與查看答案警告視窗。
- 指定回合＋錯題／兩類星號的複習組卷。
- 自訂模考名稱、日期、題數與近 10 回同範圍錯題優先抽題。
- TypeScript／TSX 語法轉譯檢查：PASS。

## 仍需在使用者環境驗證

- 執行 Supabase `24`、`25` SQL。
- `npm.cmd install`、`npm.cmd run typecheck`、`npm.cmd run build`。
- 線上 E2E：模考標記鎖定、檢討標記保存、複習組卷、自訂題數抽題。

目前執行環境連 npm registry 逾時，因此未宣稱 production build 已完成。
