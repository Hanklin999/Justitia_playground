"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AttemptHistoryItem, AttemptMode, StartAttemptResponse, YearSummary } from "@/lib/types";

function statusText(status: AttemptHistoryItem["status"]): string {
  if (status === "in_progress") return "作答中";
  if (status === "timed_out") return "時間到";
  return "已交卷";
}

function modeText(mode: AttemptMode): string {
  if (mode === "official_paper") return "年度卷";
  if (mode === "subject_pool") return "科目卷";
  return "錯題重刷";
}

function formatDuration(seconds: number | null): string {
  if (seconds === null) return "—";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m} 分 ${s} 秒`;
}

export default function HistoryPage() {
  const router = useRouter();
  const [attempts, setAttempts] = useState<AttemptHistoryItem[]>([]);
  const [summaries, setSummaries] = useState<YearSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState("");
  const [modeFilter, setModeFilter] = useState<"all" | AttemptMode>("all");
  const [yearFilter, setYearFilter] = useState<number | "all">("all");
  const [subjectFilter, setSubjectFilter] = useState<string>("all");
  const [resultFilter, setResultFilter] = useState<"all" | "wrong" | "perfect" | "in_progress">("all");
  const [startingWrong, setStartingWrong] = useState(false);

  async function load() {
    const supabase = getSupabaseBrowserClient();
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) {
      router.replace("/login");
      return;
    }
    const [{ data, error }, { data: summaryData }] = await Promise.all([
      supabase.rpc("list_my_attempts"),
      supabase.rpc("list_my_year_summaries"),
    ]);
    if (error) setErrorMessage(error.message);
    else setAttempts((data ?? []) as AttemptHistoryItem[]);
    setSummaries((summaryData ?? []) as YearSummary[]);
    setLoading(false);
  }

  useEffect(() => { void load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const availableYears = useMemo(() => Array.from(new Set(attempts.flatMap((attempt) => attempt.exam_year_roc ? [attempt.exam_year_roc] : attempt.selected_years))).sort((a, b) => b - a), [attempts]);
  const availableSubjects = useMemo(() => Array.from(new Set(attempts.flatMap((attempt) => attempt.selected_subjects))).sort(), [attempts]);

  const filteredAttempts = useMemo(() => attempts.filter((attempt) => {
    if (modeFilter !== "all" && attempt.attempt_mode !== modeFilter) return false;
    const years = attempt.exam_year_roc ? [attempt.exam_year_roc] : attempt.selected_years;
    if (yearFilter !== "all" && !years.includes(yearFilter)) return false;
    if (subjectFilter !== "all" && !attempt.selected_subjects.includes(subjectFilter)) return false;
    const wrongCount = attempt.correct_count === null || attempt.unanswered_count === null ? null : attempt.question_count - attempt.correct_count - attempt.unanswered_count;
    if (resultFilter === "in_progress" && attempt.status !== "in_progress") return false;
    if (resultFilter === "wrong" && !(wrongCount !== null && wrongCount > 0)) return false;
    if (resultFilter === "perfect" && !(wrongCount === 0 && attempt.unanswered_count === 0)) return false;
    return true;
  }), [attempts, modeFilter, resultFilter, subjectFilter, yearFilter]);

  async function startWrongReview() {
    setStartingWrong(true);
    setErrorMessage("");
    const supabase = getSupabaseBrowserClient();
    const { data, error } = await supabase.rpc("start_wrong_review_attempt", {
      p_years: yearFilter === "all" ? null : [yearFilter],
      p_subjects: subjectFilter === "all" ? null : [subjectFilter],
    });
    if (error) {
      setErrorMessage(`無法建立錯題練習：${error.message}`);
      setStartingWrong(false);
      return;
    }
    router.push(`/exam/${(data as StartAttemptResponse).attempt_id}`);
  }

  return (
    <section className="container page-section">
      <div className="eyebrow">作答 Log</div>
      <h1>歷史紀錄</h1>
      <p className="muted">依年度、練習方式與科目篩選；點進已交卷紀錄，可重看完整題目、所有選項、你的答案與正確答案。</p>

      {summaries.some((summary) => summary.is_complete) && (
        <div className="year-summary-grid">
          {summaries.filter((summary) => summary.is_complete).map((summary) => (
            <article className="year-summary-card" key={summary.exam_year_roc}>
              <span>{summary.exam_year_roc} 年四卷完成</span>
              <strong>{summary.total_score} / {summary.max_score}</strong>
              <div><span>司法官 {summary.judicial_cutoff ?? "—"}</span><span>律師 {summary.lawyer_cutoff ?? "—"}</span></div>
            </article>
          ))}
        </div>
      )}

      <div className="history-toolbar">
        <label><span>方式</span><select value={modeFilter} onChange={(event) => setModeFilter(event.target.value as "all" | AttemptMode)}><option value="all">全部</option><option value="official_paper">年度卷</option><option value="subject_pool">科目卷</option><option value="wrong_review">錯題重刷</option></select></label>
        <label><span>年度</span><select value={yearFilter} onChange={(event) => setYearFilter(event.target.value === "all" ? "all" : Number(event.target.value))}><option value="all">全部</option>{availableYears.map((year) => <option key={year} value={year}>{year} 年</option>)}</select></label>
        <label><span>科目</span><select value={subjectFilter} onChange={(event) => setSubjectFilter(event.target.value)}><option value="all">全部</option>{availableSubjects.map((subject) => <option key={subject} value={subject}>{subject}</option>)}</select></label>
        <label><span>結果</span><select value={resultFilter} onChange={(event) => setResultFilter(event.target.value as typeof resultFilter)}><option value="all">全部</option><option value="wrong">只顯示有錯題</option><option value="perfect">全對</option><option value="in_progress">作答中</option></select></label>
        <button type="button" className="button primary" disabled={startingWrong} onClick={() => void startWrongReview()}>{startingWrong ? "整理錯題中…" : "只刷錯題（不計時）"}</button>
      </div>

      {loading && <p className="muted">正在讀取紀錄…</p>}
      {errorMessage && <p className="error-message">{errorMessage}</p>}

      {!loading && filteredAttempts.length === 0 ? (
        <div className="empty-state"><h2>目前沒有符合條件的紀錄</h2><p>調整篩選或開始一份新測驗。</p><Link className="button primary" href="/practice">選擇試卷</Link></div>
      ) : (
        <div className="history-list">
          {filteredAttempts.map((attempt) => {
            const isLive = attempt.status === "in_progress";
            const wrongCount = attempt.correct_count === null || attempt.unanswered_count === null ? null : attempt.question_count - attempt.correct_count - attempt.unanswered_count;
            return (
              <Link className="history-card" href={isLive ? `/exam/${attempt.id}` : `/results/${attempt.id}`} key={attempt.id}>
                <div>
                  <div className="history-card-labels"><span className={`status-pill ${attempt.status}`}>{statusText(attempt.status)}</span><span className="mode-pill">{modeText(attempt.attempt_mode)}</span></div>
                  <h2>{attempt.title}</h2>
                  <p>{attempt.selected_subjects.length ? attempt.selected_subjects.join("、") : attempt.paper_title ?? ""}</p>
                </div>
                <div className="history-stats">
                  <span>{new Date(attempt.started_at).toLocaleString("zh-TW")}</span>
                  <span>{attempt.is_timed ? `設定 ${attempt.duration_minutes} 分鐘` : "不計時"} · 實際 {formatDuration(attempt.elapsed_seconds)}</span>
                  {wrongCount !== null && <span>未滿分 {wrongCount} · 未答 {attempt.unanswered_count}</span>}
                  <strong>{attempt.score === null ? "—" : `${attempt.score} / ${attempt.max_score}`}</strong>
                  {!isLive && <span className="history-review-link">查看完整題目與選項 →</span>}
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </section>
  );
}
