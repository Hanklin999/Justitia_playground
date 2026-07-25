# Justitia's playground v3.12.1

Last updated: 2026/07/25 12:34:33 (UTC+8)

## 首頁

- 小標題：`105-114 司律一試備考工具`
- 主標題維持：`Justitia's playground`
- 副標題：`司律陪考資料庫 | 攻克國考有如神助`
- 顯示版本與最後更新時間。

## 檢討頁第三方外部參考

- 110–113 年已提供範圍內，每題依來源年度、卷別與官方題號自動對應同一筆 range link。
- 使用者會看到來源、涵蓋題號、目前題號與第三方聲明。
- 新分頁開啟，使用 `noopener noreferrer`；不使用 JavaScript `window.open` 或 Facebook app deep link。
- 不嵌入、抓取、OCR、摘要或修改第三方詳解。

## Supabase

新增 `external_explanation_links` 與 RPC `list_attempt_external_explanations(uuid)`。
短網址已轉為 Facebook 直連；URL、`last_verified_at` 與 `link_status` 可直接在 Supabase 更新，不需重新部署。
