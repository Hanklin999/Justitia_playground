# Justitia's playground v3.12.6 套用方式

完整檔案包，含 v3.12.4 / v3.12.5 / v3.12.6 全部內容。不論目前 repo 停在哪一版，覆蓋這包即可。

## 覆蓋的檔案

```
app/exam/[attemptId]/page.tsx   完整取代
app/history/page.tsx            完整取代（內容自 v3.12.4 起未變）
app/globals.css                 完整取代（原檔尾端逐版累加，未刪任何一行）
package.json                    版號 → 3.12.6
RELEASE_NOTES_v3.12.6.md        新增
APPLY_V3_12_6.md                新增
```

`app/layout.tsx`、`app/results/[attemptId]/page.tsx`、`app/review/page.tsx` 與 Supabase 都不動。

## 套用

```powershell
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

`globals.css` 改動較大，手機請強制重新整理或清快取。

## 手機驗收（≤900px）

1. 進作答頁，最上面導覽列只有一行、無站名；往下滑時它會整條捲走，只剩卷名列與進度條吸在頂端。
2. 卷名列高度固定，卷名過長會以 `…` 省略、不換行；進度條緊貼在卷名列下方沒有縫。
3. 換題列由左到右是：星號、上一題、下一題（或交卷）。點星號會立即變成 ★ 與琥珀底，再點取消。
4. 「作答輔助」展開後只剩信心程度與筆記，沒有重複的星號按鈕。
5. 標星後展開題號索引，該題號仍顯示 ★ 標記。
