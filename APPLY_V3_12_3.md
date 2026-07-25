# Justitia's playground v3.12.3 套用方式

本版修正 v3.12.2 未確實呈現收合效果的問題，改用 React state 明確控制：

- 初始值固定為 `isOpen = false`
- 收合時，內容不會出現在 DOM
- 使用者按下「展開」後才渲染內容
- 再按一次「收合」即移除內容

## 套用

將 ZIP 全部解壓縮到 `Justitia_playground` 專案根目錄，讓：

- `apply_v3_12_3.mjs`
- `package.json`
- `app/`

位於同一層。

PowerShell 執行：

```powershell
node .\apply_v3_12_3.mjs
node .\verify_v3_12_3.mjs
npm.cmd run check:syntax
npm.cmd run typecheck
npm.cmd run build
npm.cmd run dev
```

瀏覽器請用 `Ctrl + F5` 強制重新整理，再檢查結果頁。

## 畫面驗收

進入任一已交卷結果頁，初始畫面只能看到以下標題列：

1. Pacing report／答題節奏診斷
2. 第三方外部參考
3. 這題為什麼沒拿滿分？
4. 其他標記與筆記

其下內容不得直接出現。按下右側「展開」後才顯示。

每題標記區外層只留下：

- 模考有沒有標記
- 加入／移除檢討標記

本版不需執行新的 Supabase SQL。
