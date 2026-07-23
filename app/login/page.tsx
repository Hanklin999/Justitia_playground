"use client";

import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const supabase = getSupabaseBrowserClient();
    void supabase.auth.getSession().then(({ data }) => {
      if (data.session) router.replace("/practice");
    });
  }, [router]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoading(true);
    setMessage("");

    try {
      const supabase = getSupabaseBrowserClient();
      const { error } = await supabase.auth.signInWithOtp({
        email: email.trim(),
        options: {
          emailRedirectTo: `${window.location.origin}/auth/complete`,
          shouldCreateUser: true,
        },
      });

      setMessage(error ? `寄送失敗：${error.message}` : "登入連結已寄出，請查看信箱。連結有效期間依 Supabase 設定為準。");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "無法連線至 Supabase。");
    } finally {
      setLoading(false);
    }
  }

  return (
    <section className="container narrow page-section">
      <div className="eyebrow">Email Magic Link</div>
      <h1>登入練功房</h1>
      <p className="muted">不用設定密碼。輸入 Email，再從信件連結回到練功房。</p>
      <form className="login-form" onSubmit={submit}>
        <label htmlFor="email">Email</label>
        <input
          id="email"
          type="email"
          required
          autoComplete="email"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          placeholder="you@example.com"
        />
        <button className="button primary" type="submit" disabled={loading}>
          {loading ? "寄送中…" : "寄送登入連結"}
        </button>
      </form>
      {message && <p className="status-message" aria-live="polite">{message}</p>}
    </section>
  );
}
