# Netlify 部署｜v3.0.0

## GitHub

將專案推到 GitHub。`.env.local` 已列入 `.gitignore`，不會被提交。

## 建立或更新 Netlify Site

1. Netlify → Add new site → Import an existing project，或沿用既有 `exam-justitia-playground`。
2. Build command：`npm run build`
3. Next.js publish output 交由 Netlify adapter 自動處理；不要手動改成 static export。
4. Node.js：22（`netlify.toml` 已設定）。

## Environment Variables

在 Site configuration → Environment variables 新增：

```text
NEXT_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

至少套用 Production；需要 Deploy Preview 時也一起套用。

新增或修改環境變數後，使用 **Clear cache and deploy site** 重新建置，因為 `NEXT_PUBLIC_*` 會在 build 時寫入前端 bundle。

## 部署順序

1. 先完成 Supabase v3 migration。
2. 本機執行 `npm.cmd run build`。
3. Push GitHub。
4. 確認 Netlify deploy 為 Published。
5. 用正式站測試 Magic Link、年度卷、科目卷與歷史回看。
