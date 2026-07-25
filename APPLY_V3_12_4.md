# Justitia's playground v3.12.4 套用方式

本版直接提供完整檔案，不使用 patch 腳本（v3.12.2 找不到區塊就是 patch 比對造成的）。覆蓋即可。

## 覆蓋的檔案

```
app/exam/[attemptId]/page.tsx   完整取代
app/history/page.tsx            完整取代
app/globals.css                 完整取代（= v3.12.3 內容，檔尾新增 v3.12.4 區塊，未刪任何一行）
package.json                    版號 3.12.3 → 3.12.4
RELEASE_NOTES_v3.12.4.md        新增
APPLY_V3_12_4.md                新增
```

`app/results/[attemptId]/page.tsx` 與 Supabase 完全不動。

## 套用

解壓縮到 `Justitia_playground` 專案根目錄覆蓋同名檔案，然後：

```powershell
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

`globals.css` 有改動，瀏覽器請用 `Ctrl + F5` 強制重新整理。手機用實機或 DevTools 裝置模擬（寬度 ≤900px）驗收。

## 畫面驗收

### 作答頁，手機（≤900px）

1. 進入任一 in_progress 回合，第一眼只有：左上角膠囊「題號索引 · 已作答 n / N」、題目資訊列、題目、選項。
2. 題號格線不得直接出現，按膠囊才展開；點任一題號後自動收合並回到頂端。
3. 上一題／下一題固定貼在底部工具列上方，往下滑不會消失。
4. 「作答輔助」在換題按鈕之下，預設收合；展開後才有信心程度與標記筆記。該題已加星號時，標題列出現「· 已標記 ★」。
5. 計時卷不會出現節奏診斷，也看不到「顯示節奏」。

### 作答頁，桌機（>900px）

與 v3.12.3 相同：左側索引側欄常駐、信心與標記常駐、計時卷仍可用「顯示節奏」，看不到收合按鈕。

### 歷史紀錄

1. 初次進入，篩選欄位與複習組卷勾選列都不得展開，只看到兩條標題列。
2. 篩選展開後才顯示八個欄位與「回到預設」；設定條件後收合，chip 列仍在並可一鍵清除。
3. 勾選任一回合的核取方塊時，複習組卷區塊自動展開，標題列顯示「已選 n 回作答紀錄」。

本版不需執行新的 Supabase SQL。
