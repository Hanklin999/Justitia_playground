"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";

export default function AuthCompletePage() {
  const router = useRouter();
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    const queryParams = new URLSearchParams(window.location.search);
    const authError = hashParams.get("error_description") ?? queryParams.get("error_description");

    if (authError) {
      setErrorMessage(decodeURIComponent(authError.replace(/\+/g, " ")));
      return;
    }

    const supabase = getSupabaseBrowserClient();
    let active = true;

    void supabase.auth.getSession().then(({ data, error }) => {
      if (!active) return;
      if (error) {
        setErrorMessage(error.message);
      } else if (data.session) {
        router.replace("/practice");
      }
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, session) => {
      if (active && session) router.replace("/practice");
    });

    const timeout = window.setTimeout(() => {
      if (active) setErrorMessage("登入連結未能建立工作階段，可能已過期或尚未加入允許的 Redirect URL。");
    }, 8000);

    return () => {
      active = false;
      window.clearTimeout(timeout);
      subscription.subscription.unsubscribe();
    };
  }, [router]);

  return (
    <section className="container narrow page-section centered-panel">
      <div className="eyebrow">正在完成登入</div>
      <h1>{errorMessage ? "登入未完成" : "正在確認身分…"}</h1>
      {errorMessage ? (
        <>
          <p className="error-message">{errorMessage}</p>
          <Link className="button primary" href="/login">重新寄送登入連結</Link>
        </>
      ) : (
        <p className="muted">確認完成後會自動前往試卷列表。</p>
      )}
    </section>
  );
}
