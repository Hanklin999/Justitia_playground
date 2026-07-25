# Justitia's playground v3.12.5 套用方式

本包是 **v3.12.4 + 手機交卷鈕修正** 的完整檔案。不論你是否已 push v3.12.4，直接覆蓋這包都會得到一致的 v3.12.5。

## 覆蓋的檔案

```
app/exam/[attemptId]/page.tsx   完整取代
app/history/page.tsx            完整取代（內容與 v3.12.4 相同）
app/globals.css                 完整取代（v3.12.3 內容 + v3.12.4 區塊 + v3.12.5 區塊，未刪任何一行）
package.json                    版號 → 3.12.5
RELEASE_NOTES_v3.12.5.md        新增
APPLY_V3_12_5.md                新增
```

`app/results/[attemptId]/page.tsx`、`app/layout.tsx` 與 Supabase 都不動。

## 套用

```powershell
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

`globals.css` 有改動，手機瀏覽器請強制重新整理（或清一次快取），否則會沿用舊 CSS、按鈕仍是舊的小尺寸。

## 手機驗收（≤900px）

1. 底部「離開」「提前交卷」是有邊框的膠囊，高度 44px，「提前交卷」偏紅底。
2. 用拇指隨意點膠囊中央即可觸發，不需對準。
3. sticky 的上一題／下一題與底部工具列之間有明顯間隔，兩者不重疊。
4. 斷網後點一個選項：約 10 秒後出現「答案保存逾時…仍可交卷」，此時「提前交卷」仍可按。
5. 保存中的 1 秒內按鈕呈半透明，可清楚看出暫時停用。

若實機仍點不到，請告訴我是哪一種情形：按鈕呈半透明（狀態問題）、或按下去完全沒反應（覆蓋問題）、或手指根本碰不到那個位置（安全區問題）。第三種我會再加 `viewportFit: "cover"` 到 `app/layout.tsx`，那需要你實機確認頂部導覽不會被瀏海遮到。
