# Release notes — v3.12.5

Updated: 2026/07/25 (UTC+8)

含 v3.12.4 全部內容，另修正手機版「提前交卷」按不下去。

## 修正 1：手機底部工具列點不到

底部工具列的「離開」「提前交卷」是無邊框純文字按鈕（`.text-button { padding: 0 }`）。實測 390×844 時，「提前交卷」的可點區域只有 **52 × 18 px**，且下緣距畫面底部僅 19px，落在瀏覽器底部工具列與 iPhone home indicator 手勢區附近，實機非常難點到。

- ≤900px 時，兩顆按鈕改為 `min-height: 44px` 的膠囊（實測 82 × 44 px），加邊框與底色，明確看得出是可點控制項。
- 工具列 `min-height` 提為 62px，底部 padding 加上 `env(safe-area-inset-bottom)`。
- 左側「本次時長」文字改為單行省略，避免換行把工具列撐高。
- 工具列 `z-index` 18 → 25。
- sticky 的上一題／下一題改為依 `--exam-footer-height` 計算離底距離（原本寫死 58px），實測 320–430px 寬都與工具列保持 10px 淨空、不重疊。

## 修正 2：保存卡住會讓交卷鈕永久無法按

「交卷」與「提前交卷」的 `disabled` 條件含 `saveState === "saving"`。`save_attempt_answer` 若因網路問題永不 settle，`saveState` 會永遠停在 `saving`，兩顆交卷鈕就永久不能按；而 `.text-button` 當時沒有 disabled 樣式，外觀幾乎看不出被停用，症狀就是「按不下去」。

- 答案保存加上 10 秒逾時競賽，逾時就轉為 `error` 並提示「答案保存逾時…仍可交卷」，狀態不會再卡住。
- 新增 `.text-button:disabled { opacity: .5 }`，被停用時看得出來。

## Database

無 Supabase schema 變更。
