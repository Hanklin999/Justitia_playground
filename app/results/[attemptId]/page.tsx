"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AttemptResult, YearSummary } from "@/lib/types";

type ResultFilter = "all" | "wrong" | "unanswered" | "correct" | "starred";

function formatDuration(seconds: number): string {
  const safe = Math.max(0, seconds || 0);
  const h = Math.floor(safe / 3600);
  const m = Math.floor((safe % 3600) / 60);
  const s = safe % 60;
  if (h > 0) return `${h} 小時 ${m} 分 ${s} 秒`;
  return `${m} 分 ${s} 秒`;
}

export default function ResultPage() {
  const params = useParams<{ attemptId: string }>();
  const router = useRouter();
  const attemptId = params.attemptId;
  const [result, setResult] = useState<AttemptResult | null>(null);
  const [yearSummaries, setYearSummaries] = useState<YearSummary[]>([]);
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
      const [{ data, error }, { data: summaryData }] = await Promise.all([
        supabase.rpc("get_attempt_result", { p_attempt_id: attemptId }),
        supabase.rpc("list_my_year_summaries"),
      ]);
      if (!active) return;
      if (error) setErrorMessage(`無法讀取成績：${error.message}`);
      else setResult(data as AttemptResult);
      setYearSummaries((summaryData ?? []) as YearSummary[]);
    }
    void load();
    return () => { active = false; };
  }, [attemptId, router]);

  const filteredQuestions = useMemo(() => {
    if (!result) return [];
    if (filter === "wrong") return result.questions.filter((q) => !q.is_unanswered && !q.is_correct);
    if (filter === "unanswered") return result.questions.filter((q) => q.is_unanswered);
    if (filter === "correct") return result.questions.filter((q) => q.is_correct);
    if (filter === "starred") return result.questions.filter((q) => q.is_starred);
    return result.questions;
  }, [filter, result]);

  const breakdown = useMemo(() => {
    if (!result) return [];
    const groups = new Map<string, { subject: string; subsubject: string; total: number; wrong: number; unanswered: number; correct: number }>();
    for (const q of result.questions) {
      const sub = q.subsubject_primary && q.subsubject_primary !== "未分類" ? q.subsubject_primary : "";
      const key = `${q.subject_primary}::${sub}`;
      const item = groups.get(key) ?? { subject: q.subject_primary || "未分類", subsubject: sub, total: 0, wrong: 0, unanswered: 0, correct: 0 };
      item.total += 1;
      if (q.is_unanswered) item.unanswered += 1;
      else if (q.is_correct) item.correct += 1;
      else item.wrong += 1;
      groups.set(key, item);
    }
    return Array.from(groups.values());
  }, [result]);

  if (errorMessage) {
    return <section className="container narrow page-section centered-panel"><h1>成績尚未產生</h1><p className="error-message">{errorMessage}</p><Link className="button primary" href={`/exam/${attemptId}`}>返回考試</Link></section>;
  }
  if (!result) return <section className="container page-section"><p className="muted">正在計算成績…</p></section>;

  const wrongCount = result.questions.length - result.attempt.correct_count - result.attempt.unanswered_count;
  const percentage = Math.round((result.attempt.score / result.attempt.max_score) * 100);
  const completeYear = result.paper ? yearSummaries.find((summary) => summary.exam_year_roc === result.paper!.exam_year_roc && summary.is_complete) : undefined;

  return (
    <section className="container page-section result-page">
      <div className="eyebrow">{result.attempt.attempt_mode === "official_paper" ? "單卷成績" : result.attempt.attempt_mode === "wrong_review" ? "錯題重刷結果" : "自組測驗結果"}</div>
      <h1>{result.attempt.title}</h1>
      {result.paper && <p className="muted">{result.paper.paper_title}</p>}

      <div className="score-hero">
        <div className="score-main"><strong>{result.attempt.score}</strong><span>/ {result.attempt.max_score} 分</span><small>{percentage}%</small></div>
        <div className="score-details">
          <div><strong>{result.attempt.correct_count}</strong><span>答對</span></div>
          <div><strong>{wrongCount}</strong><span>答錯</span></div>
          <div><strong>{result.attempt.unanswered_count}</strong><span>未作答</span></div>
          <div><strong>{formatDuration(result.attempt.elapsed_seconds)}</strong><span>總花費時間</span></div>
        </div>
      </div>

      <div className="result-meta time-log">
        <span>開始：{new Date(result.attempt.started_at).toLocaleString("zh-TW")}</span>
        <span>交卷：{new Date(result.attempt.submitted_at).toLocaleString("zh-TW")}</span>
        <span>{result.attempt.submit_reason === "timeout" ? "時間到自動交卷" : "手動交卷"}</span>
        <span>{result.attempt.is_timed ? `設定時長 ${result.attempt.duration_minutes} 分鐘` : "不計時練習"}</span>
        {result.paper && <a href={result.paper.source_answer_url} target="_blank" rel="noreferrer">官方答案來源</a>}
      </div>

      <section className="breakdown-section">
        <div className="section-heading"><div><div className="eyebrow">錯題分布</div><h2>各科與子科目</h2></div></div>
        <div className="breakdown-grid">
          {breakdown.map((item) => (
            <article className="breakdown-card" key={`${item.subject}-${item.subsubject}`}>
              <div><strong>{item.subject}</strong>{item.subsubject && <span>{item.subsubject}</span>}</div>
              <div className="breakdown-numbers"><span>錯 {item.wrong}</span><span>未答 {item.unanswered}</span><span>共 {item.total}</span></div>
            </article>
          ))}
        </div>
      </section>

      {completeYear && (
        <section className="year-total-card">
          <div><div className="eyebrow">年度四卷已完成</div><h2>{completeYear.exam_year_roc} 年總分 {completeYear.total_score} / {completeYear.max_score}</h2></div>
          <div className="cutoff-comparison">
            <span className={completeYear.judicial_cutoff !== null && completeYear.total_score >= completeYear.judicial_cutoff ? "passed" : ""}>司法官門檻 {completeYear.judicial_cutoff ?? "—"}</span>
            <span className={completeYear.lawyer_cutoff !== null && completeYear.total_score >= completeYear.lawyer_cutoff ? "passed" : ""}>律師門檻 {completeYear.lawyer_cutoff ?? "—"}</span>
            {completeYear.cutoff_source_url && <a href={completeYear.cutoff_source_url} target="_blank" rel="noreferrer">門檻資料來源</a>}
          </div>
        </section>
      )}

      <div className="filter-tabs" role="tablist" aria-label="答題結果篩選">
        {([
          ["all", `全部 ${result.questions.length}`], ["wrong", `答錯 ${wrongCount}`], ["unanswered", `未作答 ${result.attempt.unanswered_count}`], ["correct", `答對 ${result.attempt.correct_count}`], ["starred", `星號 ${result.questions.filter((q) => q.is_starred).length}`],
        ] as [ResultFilter, string][]).map(([value, label]) => <button key={value} type="button" className={filter === value ? "active" : ""} onClick={() => setFilter(value)}>{label}</button>)}
      </div>

      <div className="result-list">
        {filteredQuestions.map((question) => (
          <article className={`result-question ${question.is_correct ? "correct" : "incorrect"}`} key={question.question_id}>
            <div className="result-question-header">
              <strong>{question.is_starred ? "★ " : ""}第 {question.display_order} 題 · {question.subject_primary}{question.subsubject_primary !== "未分類" ? `／${question.subsubject_primary}` : ""}</strong>
              <span>{question.is_correct ? "答對" : question.is_unanswered ? "未作答" : "答錯"}</span>
            </div>
            <p>{question.question_text}</p>
            <div className="answer-comparison"><span>你的答案：<strong>{question.selected_answer ?? "未作答"}</strong></span><span>正確答案：<strong>{question.correct_answers?.length ? question.correct_answers.join("／") : question.correct_answer}</strong></span><span>本題約 {formatDuration(question.active_seconds)}</span></div>
            {question.note_text && <div className="saved-note"><strong>筆記</strong><p>{question.note_text}</p></div>}
          </article>
        ))}
      </div>

      <div className="actions"><Link className="button primary" href="/practice">再選一份測驗</Link><Link className="button secondary" href="/history">查看歷史紀錄</Link></div>
    </section>
  );
}
