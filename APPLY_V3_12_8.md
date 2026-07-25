# Justitia's playground v3.12.8 套用方式

完整檔案包，含 v3.12.4／3.12.5／3.12.6／3.12.8 全部內容。不論 repo 目前停在哪一版，覆蓋這包即可。

## 檔案

```
components/collapsible-panel.tsx   新增（共用收合元件）
app/exam/[attemptId]/page.tsx      取代
app/results/[attemptId]/page.tsx   取代
app/practice/page.tsx              取代
app/review/page.tsx                取代
app/history/page.tsx               取代
app/page.tsx                       取代（版本字串）
app/globals.css                    取代（原檔尾端逐版累加，未刪任何一行）
package.json                       版號 → 3.12.8
README.md                          取代（英文技術文件）
README.zh-TW.md                    新增（中文使用說明）
RELEASE_NOTES_v3.12.8.md           新增
APPLY_V3_12_8.md                   新增
```

`app/layout.tsx`、`lib/`、`supabase/`、`etl/` 都不動。**無 SQL 需要執行。**

注意：本包新增 `components/` 目錄，四個頁面都 `import CollapsiblePanel from "@/components/collapsible-panel"`，請確認這個檔案有一起放進去，否則 build 會失敗。

## 套用

```powershell
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

`globals.css` 改動大，手機請強制重新整理或清快取。

## 驗收

### 手機（≤900px）

1. 作答頁：頂端只剩卷名列與進度條；導覽列往下滑會整條讓出。
2. 換題列由左到右：星號、上一題、下一題；底部「提前交卷」是 44px 膠囊、按得到。
3. 檢討頁：滿分題只有一行摘要；篩選頁籤單行可左右滑；右下角出現「下一個未滿分」並能跳題。
4. 開始練習（依年度）：只有最新年度展開；（依科目）摘要列吸在底部。
5. 今日待複習：學習診斷預設收合，「開始複習」在首屏。

### 電腦

1. 作答頁左側題號索引常駐、信心與筆記常駐，看不到收合按鈕。
2. 檢討頁答案比較仍是單行排列；滿分題同樣預設收合（點一下展開）。
3. 依年度只有最新年度展開——這是刻意的，如果你希望電腦版全部展開，跟我說我改成只在 ≤900px 收合。
