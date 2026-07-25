# Justitia's playground v3.12.3

> 司律陪考資料庫

司法官／律師第一試刷題、正式模考、節奏診斷與間隔複習平台。題庫涵蓋民國 105–114 年考選部官方考古題，共 40 卷、2,968 題。

## v3.12.3 重點

- 改用 React 狀態控制的收合元件，所有內容預設不渲染，使用者按下「展開」後才顯示。
- 收合範圍：Pacing report／答題節奏診斷、第三方外部參考、這題為什麼沒拿滿分、其他標記與筆記。
- 每題外層只常駐顯示「模考有沒有標記」與「加入／移除檢討標記」。
- 支援手機點擊、鍵盤操作與 aria-expanded；本版不需新增 Supabase schema。

## v3.12.1 重點

- 首頁更新產品小標、副標與版本時間。
- 110–113 年檢討題目依年度、卷別與原始題號顯示全人法學中心第三方外部參考。
- 僅提供新分頁連結與來源聲明；不嵌入、抓取、OCR、摘要或修改第三方內容。
- 外部網址、驗證時間與狀態由 Supabase 管理，更新網址不需重新部署。

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

既有 v3.12.0 資料庫依序執行：

1. `supabase/sql_editor_v3/28_v3_12_1_external_explanations.sql`
2. `supabase/sql_editor_v3/29_verify_v3_12_1.sql`

若從 v3.1.0 升級，請先完成 `26`、`27`，再執行 `28`、`29`。不需要重跑題庫 seed。詳細說明：`supabase/V3_12_1_UPGRADE.md`。

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
