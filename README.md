# Justitia's playground v3.12.0

> 司律陪考資料庫

司法官／律師第一試刷題、正式模考、節奏診斷與間隔複習平台。題庫涵蓋民國 105–114 年考選部官方考古題，共 40 卷、2,968 題。

## v3.12.0 重點

### P0：答題節奏教練

- 即時顯示有效平均秒數、每題目標與預估完成題數。
- 正式年度卷預設關閉提示，自組模考預設開啟，可隨時切換。
- 背景分頁不計入單題時間，但正式倒數不暫停。
- 結果頁提供各科速度、最耗時題目、前後半卷、最後十分鐘與改答案效果。
- 每次答案修改、最終作答時間與當時剩餘秒數皆保留。

### P1：錯誤診斷與間隔複習

- 每題可選「確定／不確定／純猜」。
- 未滿分題可標主要錯因與補充標籤。
- 最近五回顯示常見錯因與信心校準風險。
- 依得分與信心安排 1／3／7／14／30 天後再次複習。
- 「今日待複習」可選 10／20／30／全部，建立不計時組卷。

### 歷史紀錄

- 以 attempt 為單位永久刪除作答紀錄。
- 刪除前顯示二次確認視窗。
- 刪除後重算受影響題目的間隔複習排程。
- 模考星號／模考筆記隨 attempt 刪除；跨回合檢討星號／筆記保留。

## 既有能力

- 105–114 年正式年度卷與科目自組卷。
- 105–106 年 A–E 複選與官方部分得分。
- Email Magic Link、Autosave、倒數與逾時交卷。
- 模考與檢討星號／筆記分流。
- 指定作答回合建立錯題／星號複習組卷。
- 官方答案位於 private schema，交卷前不由公開 API 回傳。

## Supabase 升級

既有 v3.1.0 資料庫依序執行：

1. `supabase/sql_editor_v3/26_v3_12_pacing_learning.sql`
2. `supabase/sql_editor_v3/27_verify_v3_12.sql`

不需要重跑題庫 seed。詳細說明：`supabase/V3_12_UPGRADE.md`。

## 本機驗證

```powershell
npm.cmd install
npm.cmd run validate:data
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

## 環境變數

```env
NEXT_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Secret／service-role key 不可放進前端或 GitHub。

## 技術架構

- Next.js 16、React 19、TypeScript
- Supabase PostgreSQL、Auth、RLS、Database Functions
- Netlify deployment
- Python、pandas、PyMuPDF／pdfplumber ETL
