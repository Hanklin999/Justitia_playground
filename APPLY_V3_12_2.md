# Justitia's playground v3.12.2 套用說明

本更新將測驗結果與錯題回顧頁的次要資訊改為預設收合，降低頁面長度與行動版認知負荷。

## 套用

1. 將本壓縮檔內容解壓縮到 `Justitia_playground` 專案根目錄。
2. 在 PowerShell 執行：

```powershell
node .\apply_v3_12_2.mjs
```

此腳本不需要 Python。若本機尚未完整套用 v3.12.1，會一併補上第三方外部參考所需的前端程式與檔案。

## Supabase

v3.12.2 沒有新增資料表或欄位。

若 v3.12.1 的 SQL 尚未執行，請在 Supabase SQL Editor 依序執行：

1. `supabase/sql_editor_v3/28_v3_12_1_external_explanations.sql`
2. `supabase/sql_editor_v3/29_verify_v3_12_1.sql`

## 驗證

```powershell
npm.cmd install
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

檢查測驗結果頁：

- Pacing report 預設收合。
- 第三方外部參考預設收合。
- 未滿分錯因預設收合。
- 題目外層只顯示模考是否標記與加入／移除檢討標記。
- 模考筆記與檢討筆記位於「標記與筆記詳情」內。
- 手機點擊 summary 可正常展開與收合。

## 推送

```powershell
git status
git add .
git commit -m "release: v3.12.2 collapse result details"
git push origin main
```
