"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AttemptResult } from "@/lib/types";

type ResultFilter = "all" | "wrong" | "unanswered" | "correct";

export default function ResultPage() {
  const params = useParams<{ attemptId: string }>();
  const router = useRouter();
  const attemptId = params.attemptId;
  const [result, setResult] = useState<AttemptResult | null>(null);
  const [errorMessage, setErrorMessage] = useState("");
  const [filter, setFilter] = useState<ResultFilter>("all");

  useEffect(() => {
    let active = true;
    const supabase = getSupabaseBrowserClient();

    async function load() {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) {
        router.replace("/login");
        return;
      }

      const { data, error } = await supabase.rpc("get_attempt_result", {
        p_attempt_id: attemptId,
      });
      if (!active) return;
      if (error) setErrorMessage(`無法讀取成績：${error.message}`);
      else setResult(data as AttemptResult);
    }

    void load();
    return () => {
      active = false;
    };
  }, [attemptId, router]);

  const filteredQuestions = useMemo(() => {
    if (!result) return [];
    if (filter === "wrong") return result.questions.filter((question) => !question.is_unanswered && !question.is_correct);
    if (filter === "unanswered") return result.questions.filter((question) => question.is_unanswered);
    if (filter === "correct") return result.questions.filter((question) => question.is_correct);
    return result.questions;
  }, [filter, result]);

  if (errorMessage) {
    return (
      <section className="container narrow page-section centered-panel">
        <h1>成績尚未產生</h1>
        <p className="error-message">{errorMessage}</p>
        <Link className="button primary" href={`/exam/${attemptId}`}>返回考試</Link>
      </section>
    );
  }

  if (!result) {
    return <section className="container page-section"><p className="muted">正在計算成績…</p></section>;
  }

  const wrongCount = result.questions.length - result.attempt.correct_count - result.attempt.unanswered_count;
  const percentage = Math.round((result.attempt.score / result.attempt.max_score) * 100);

  return (
    <section className="container page-section result-page">
      <div className="eyebrow">單卷成績</div>
      <h1>{result.paper.exam_year_roc} 年第 {result.paper.paper_order} 卷</h1>
      <p className="muted">{result.paper.paper_title}</p>

      <div className="score-hero">
        <div className="score-main">
          <strong>{result.attempt.score}</strong>
          <span>/ {result.attempt.max_score} 分</span>
          <small>{percentage}%</small>
        </div>
        <div className="score-details">
          <div><strong>{result.attempt.correct_count}</strong><span>答對</span></div>
          <div><strong>{wrongCount}</strong><span>答錯</span></div>
          <div><strong>{result.attempt.unanswered_count}</strong><span>未作答</span></div>
          <div><strong>{result.attempt.duration_minutes}</strong><span>考試時長（分鐘）</span></div>
        </div>
      </div>

      <div className="result-meta">
        <span>{result.attempt.submit_reason === "timeout" ? "時間到自動交卷" : "手動交卷"}</span>
        <span>交卷時間：{new Date(result.attempt.submitted_at).toLocaleString("zh-TW")}</span>
        <a href={result.paper.source_answer_url} target="_blank" rel="noreferrer">官方答案來源</a>
      </div>

      <div className="filter-tabs" role="tablist" aria-label="答題結果篩選">
        {([
          ["all", `全部 ${result.questions.length}`],
          ["wrong", `答錯 ${wrongCount}`],
          ["unanswered", `未作答 ${result.attempt.unanswered_count}`],
          ["correct", `答對 ${result.attempt.correct_count}`],
        ] as [ResultFilter, string][]).map(([value, label]) => (
          <button key={value} type="button" className={filter === value ? "active" : ""} onClick={() => setFilter(value)}>
            {label}
          </button>
        ))}
      </div>

      <div className="result-list">
        {filteredQuestions.map((question) => (
          <article className={`result-question ${question.is_correct ? "correct" : "incorrect"}`} key={question.question_id}>
            <div className="result-question-header">
              <strong>第 {question.question_number} 題</strong>
              <span>{question.is_correct ? "答對" : question.is_unanswered ? "未作答" : "答錯"}</span>
            </div>
            <p>{question.question_text}</p>
            <div className="answer-comparison">
              <span>你的答案：<strong>{question.selected_answer ?? "未作答"}</strong></span>
              <span>正確答案：<strong>{question.correct_answer}</strong></span>
            </div>
          </article>
        ))}
      </div>

      <div className="actions">
        <Link className="button primary" href="/practice">再選一份試卷</Link>
        <Link className="button secondary" href="/history">查看歷史紀錄</Link>
      </div>
    </section>
  );
}
