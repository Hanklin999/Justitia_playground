# Release notes — v3.12.3

Updated: 2026/07/25 16:46:05 (UTC+8)

## 修正

v3.12.2 雖規劃使用收合區塊，但未能可靠地讓使用者看到預設收合結果。v3.12.3 改用 React state 控制，不再依賴瀏覽器原生 `details` 行為。

## 行為

- `CollapsiblePanel` 初始狀態固定為 `false`。
- 關閉時內容完全不渲染。
- 使用者點擊按鈕後才載入內容。
- 按鈕顯示「展開／收合」，並提供 `aria-expanded`。

## 收合區域

- Pacing report／答題節奏診斷
- 每題第三方外部參考
- 每題「這題為什麼沒拿滿分？」
- 每題其他標記與筆記

每題常駐區域只保留模考標記狀態與檢討標記按鈕。

## Database

無 Supabase schema 變更。
