"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";

export default function AuthStatus() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const supabase = getSupabaseBrowserClient();

    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      setReady(true);
    });

    return () => subscription.subscription.unsubscribe();
  }, []);

  async function signOut() {
    const supabase = getSupabaseBrowserClient();
    await supabase.auth.signOut();
    window.location.href = "/";
  }

  if (!ready) return <span className="nav-muted">連線中</span>;

  if (!session) {
    return <Link href="/login">登入</Link>;
  }

  return (
    <div className="auth-nav">
      <span className="nav-email" title={session.user.email ?? undefined}>
        {session.user.email}
      </span>
      <button className="text-button" type="button" onClick={signOut}>
        登出
      </button>
    </div>
  );
}
