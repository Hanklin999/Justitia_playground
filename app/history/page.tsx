"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AttemptHistoryItem } from "@/lib/types";

function statusText(status: AttemptHistoryItem["status"]): string {
  if (status === "in_progress") return "作答中";
  if (status === "timed_out") return "時間到";
  return "已交卷";
}

export default function HistoryPage() {
  const router = useRouter();
  const [attempts, setAttempts] = useState<AttemptHistoryItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    let active = true;
    const supabase = getSupabaseBrowserClient();

    async function load() {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) {
        router.replace("/login");
        return;
      }
      const { data, error } = await supabase.rpc("list_my_attempts");
      if (!active) return;
      if (error) setErrorMessage(error.message);
      else setAttempts((data ?? []) as AttemptHistoryItem[]);
      setLoading(false);
    }

    void load();
    return () => {
      active = false;
    };
  }, [router]);

  return (
    <section className="container page-section">
      <div className="eyebrow">作答 Log</div>
      <h1>歷史紀錄</h1>
      <p className="muted">每次開始單卷考試，都會保存官方時長、開始與交卷時間、交卷原因及分數。</p>

      {loading && <p className="muted">正在讀取紀錄…</p>}
      {errorMessage && <p className="error-message">{errorMessage}</p>}

      {!loading && attempts.length === 0 ? (
        <div className="empty-state">
          <h2>還沒有考試紀錄</h2>
          <p>選一份正式試卷開始第一次練習。</p>
          <Link className="button primary" href="/practice">選擇試卷</Link>
        </div>
      ) : (
        <div className="history-list">
          {attempts.map((attempt) => {
            const isLive = attempt.status === "in_progress";
            const href = isLive ? `/exam/${attempt.id}` : `/results/${attempt.id}`;
            return (
              <Link className="history-card" href={href} key={attempt.id}>
                <div>
                  <span className={`status-pill ${attempt.status}`}>{statusText(attempt.status)}</span>
                  <h2>{attempt.exam_year_roc} 年第 {attempt.paper_order} 卷</h2>
                  <p>{attempt.paper_title}</p>
                </div>
                <div className="history-stats">
                  <span>{new Date(attempt.started_at).toLocaleString("zh-TW")}</span>
                  <span>正式時長 {attempt.duration_minutes} 分鐘</span>
                  <strong>{attempt.score === null ? "—" : `${attempt.score} / ${attempt.max_score}`}</strong>
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </section>
  );
}
