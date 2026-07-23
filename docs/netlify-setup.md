# Netlify 部署

## 1. GitHub

將專案推到 GitHub。`.env.local` 已列入 `.gitignore`，不會被提交。

## 2. 建立 Netlify Site

1. Netlify → Add new site → Import an existing project
2. 選擇 GitHub repo
3. Build command：`npm run build`
4. Publish directory：`.next`
5. Node.js：22（`netlify.toml` 已設定）

## 3. Environment Variables

在 Netlify → Site configuration → Environment variables 新增：

```text
NEXT_PUBLIC_SUPABASE_URL=https://keonwqfgudmheyuuucti.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_8OelteOl_RNZ0DK3zZW2iA_VQjpF7wQ
```

建議至少套用 Production 與 Deploy Previews。

## 4. 回 Supabase 設定 Redirect URL

取得 `*.netlify.app` 網址後，依 `docs/supabase-setup.md` 更新 Site URL 與 Redirect URLs，再重新測試 Magic Link。
