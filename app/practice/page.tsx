"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { ExamPaper, StartAttemptResponse } from "@/lib/types";

export default function PracticePage() {
  const router = useRouter();
  const [papers, setPapers] = useState<ExamPaper[]>([]);
  const [loading, setLoading] = useState(true);
  const [startingPaperId, setStartingPaperId] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState("");
  const [isSignedIn, setIsSignedIn] = useState<boolean | null>(null);

  useEffect(() => {
    let active = true;
    const supabase = getSupabaseBrowserClient();

    async function load() {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!active) return;
      setIsSignedIn(Boolean(sessionData.session));

      const { data, error } = await supabase
        .from("exam_papers")
        .select("paper_id, exam_year_roc, exam_year_ad, paper_order, paper_code, paper_group, paper_title, included_subjects, duration_minutes, question_count, points_per_question, max_score, source_question_url, is_published")
        .eq("is_published", true)
        .order("exam_year_roc", { ascending: false })
        .order("paper_order", { ascending: true });

      if (!active) return;
      if (error) {
        setErrorMessage(`尚未讀取到題庫：${error.message}`);
      } else {
        setPapers((data ?? []) as ExamPaper[]);
      }
      setLoading(false);
    }

    void load();
    return () => {
      active = false;
    };
  }, []);

  const years = useMemo(
    () => Array.from(new Set(papers.map((paper) => paper.exam_year_roc))).sort((a, b) => b - a),
    [papers],
  );

  async function startExam(paperId: string) {
    if (!isSignedIn) {
      router.push("/login");
      return;
    }

    setStartingPaperId(paperId);
    setErrorMessage("");
    const supabase = getSupabaseBrowserClient();
    const { data, error } = await supabase.rpc("start_exam_attempt", {
      p_paper_id: paperId,
    });

    if (error) {
      setErrorMessage(`無法開始考試：${error.message}`);
      setStartingPaperId(null);
      return;
    }

    const response = data as StartAttemptResponse;
    router.push(`/exam/${response.attempt_id}`);
  }

  return (
    <section className="container page-section">
      <div className="eyebrow">正式綜合法學試卷</div>
      <h1>選擇年度與試卷</h1>
      <p className="muted">
        第一版依官方單卷時長進行模擬；不拆自由選科。每次開始都會建立一筆考試紀錄。
      </p>

      {isSignedIn === false && (
        <div className="notice-card">
          <strong>開始前需要 Email 登入</strong>
          <span>登入後才能保存答案、計時與成績。</span>
          <Link className="button primary compact" href="/login">前往登入</Link>
        </div>
      )}

      {errorMessage && (
        <div className="error-card" role="alert">
          <strong>Supabase 尚未完成設定</strong>
          <span>{errorMessage}</span>
          <span>請先執行 `0001_initial_schema.sql` 與 `0002_seed_113_114.sql`。</span>
        </div>
      )}

      {loading ? (
        <p className="muted">正在讀取試卷…</p>
      ) : papers.length === 0 ? (
        <div className="empty-state">
          <h2>目前沒有已發布試卷</h2>
          <p>完成 Supabase migration 與 seed 後，113、114 年共 8 份試卷會出現在這裡。</p>
        </div>
      ) : (
        years.map((year) => (
          <section key={year} className="year-section">
            <h2>{year} 年</h2>
            <div className="paper-grid">
              {papers.filter((paper) => paper.exam_year_roc === year).map((paper) => (
                <article className="paper-card" key={paper.paper_id}>
                  <div className="paper-meta">第 {paper.paper_order} 卷 · 代號 {paper.paper_code}</div>
                  <h3>{paper.paper_title}</h3>
                  <div className="paper-stats">
                    <span>{paper.question_count} 題</span>
                    <span>{paper.duration_minutes} 分鐘</span>
                    <span>滿分 {paper.max_score}</span>
                  </div>
                  <p>{paper.included_subjects.join("、")}</p>
                  <div className="paper-actions">
                    <a href={paper.source_question_url} target="_blank" rel="noreferrer" className="source-link">
                      官方試題
                    </a>
                    <button
                      className="button primary"
                      type="button"
                      disabled={startingPaperId !== null}
                      onClick={() => void startExam(paper.paper_id)}
                    >
                      {startingPaperId === paper.paper_id ? "建立考試中…" : "開始這一卷"}
                    </button>
                  </div>
                </article>
              ))}
            </div>
          </section>
        ))
      )}
    </section>
  );
}
