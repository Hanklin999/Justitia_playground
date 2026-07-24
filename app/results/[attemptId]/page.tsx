"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AnswerChoice, AttemptResult, ResultQuestion, YearSummary } from "@/lib/types";

type ResultFilter = "all" | "wrong" | "unanswered" | "correct" | "exam_starred" | "review_starred";
const allChoices: AnswerChoice[] = ["A", "B", "C", "D", "E"];

function formatDuration(seconds: number) {
  const safe = Math.max(0, seconds || 0);
  const h = Math.floor(safe / 3600);
  const m = Math.floor((safe % 3600) / 60);
  const s = safe % 60;
  return h > 0 ? `${h} 小時 ${m} 分 ${s} 秒` : `${m} 分 ${s} 秒`;
}

function optionText(question: ResultQuestion, choice: AnswerChoice) {
  return ({ A: question.option_a, B: question.option_b, C: question.option_c, D: question.option_d, E: question.option_e })[choice];
}

export default function ResultPage() {
  const params = useParams<{ attemptId: string }>();
  const router = useRouter();
  const attemptId = params.attemptId;
  const [result, setResult] = useState<AttemptResult | null>(null);
  const [yearSummaries, setYearSummaries] = useState<YearSummary[]>([]);
  const [errorMessage, setErrorMessage] = useState("");
  const [filter, setFilter] = useState<ResultFilter>("all");
  const [reviewStars, setReviewStars] = useState<Record<string, boolean>>({});
  const [reviewNotes, setReviewNotes] = useState<Record<string, string>>({});
  const [savingQuestionId, setSavingQuestionId] = useState<string | null>(null);

  async function load() {
    const supabase = getSupabaseBrowserClient();
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) {
      router.replace("/login");
      return;
    }
    const [{ data, error }, { data: summaryData }] = await Promise.all([
      supabase.rpc("get_attempt_result", { p_attempt_id: attemptId }),
      supabase.rpc("list_my_year_summaries"),
    ]);
    if (error) {
      setErrorMessage(`無法讀取成績：${error.message}`);
      return;
    }
    const next = data as AttemptResult;
    setResult(next);
    setReviewStars(Object.fromEntries(next.questions.map((question) => [question.question_id, question.review_is_starred])));
    setReviewNotes(Object.fromEntries(next.questions.map((question) => [question.question_id, question.review_note_text])));
    setYearSummaries((summaryData ?? []) as YearSummary[]);
  }

  useEffect(() => { void load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  async function saveReviewAnnotation(questionId: string, nextStar: boolean, nextNote: string) {
    setSavingQuestionId(questionId);
    setErrorMessage("");
    const { error } = await getSupabaseBrowserClient().rpc("save_review_annotation", {
      p_question_id: questionId,
      p_is_starred: nextStar,
      p_note_text: nextNote,
    });
    if (error) setErrorMessage(`檢討標記保存失敗：${error.message}`);
    setSavingQuestionId(null);
  }

  function toggleReviewStar(questionId: string) {
    const next = !reviewStars[questionId];
    setReviewStars((current) => ({ ...current, [questionId]: next }));
    void saveReviewAnnotation(questionId, next, reviewNotes[questionId] ?? "");
  }

  const filteredQuestions = useMemo(() => {
    if (!result) return [];
    if (filter === "wrong") return result.questions.filter((question) => !question.is_unanswered && !question.is_correct);
    if (filter === "unanswered") return result.questions.filter((question) => question.is_unanswered);
    if (filter === "correct") return result.questions.filter((question) => question.is_correct);
    if (filter === "exam_starred") return result.questions.filter((question) => question.exam_is_starred);
    if (filter === "review_starred") return result.questions.filter((question) => reviewStars[question.question_id]);
    return result.questions;
  }, [filter, result, reviewStars]);

  const breakdown = useMemo(() => {
    if (!result) return [];
    const groups = new Map<string, { subject: string; subsubject: string; total: number; wrong: number; unanswered: number; correct: number }>();
    for (const question of result.questions) {
      const subsubject = question.subsubject_primary && question.subsubject_primary !== "未分類" ? question.subsubject_primary : "";
      const key = `${question.subject_primary}::${subsubject}`;
      const item = groups.get(key) ?? { subject: question.subject_primary || "未分類", subsubject, total: 0, wrong: 0, unanswered: 0, correct: 0 };
      item.total += 1;
      if (question.is_unanswered) item.unanswered += 1;
      else if (question.is_correct) item.correct += 1;
      else item.wrong += 1;
      groups.set(key, item);
    }
    return Array.from(groups.values());
  }, [result]);

  if (errorMessage && !result) {
    return <section className="container narrow page-section centered-panel"><h1>成績尚未產生</h1><p className="error-message">{errorMessage}</p><Link className="button primary" href={`/exam/${attemptId}`}>返回考試</Link></section>;
  }
  if (!result) return <section className="container page-section"><p className="muted">正在計算成績…</p></section>;

  const wrongCount = result.questions.filter((question) => !question.is_unanswered && !question.is_correct).length;
  const percentage = Math.round(result.attempt.score / result.attempt.max_score * 100);
  const completeYear = result.paper ? yearSummaries.find((summary) => summary.exam_year_roc === result.paper!.exam_year_roc && summary.is_complete) : undefined;

  return <section className="container page-section result-page">
    <div className="eyebrow">{result.attempt.attempt_mode === "official_paper" ? "單卷成績" : result.attempt.attempt_mode === "wrong_review" ? "複習組卷結果" : "自組測驗結果"}</div>
    <h1>{result.attempt.title}</h1>
    {result.paper && <p className="muted">{result.paper.paper_title}</p>}

    <div className="score-hero">
      <div className="score-main"><strong>{result.attempt.score}</strong><span>/ {result.attempt.max_score} 分</span><small>{percentage}%</small></div>
      <div className="score-details">
        <div><strong>{result.attempt.correct_count}</strong><span>滿分題</span></div>
        <div><strong>{wrongCount}</strong><span>未滿分</span></div>
        <div><strong>{result.attempt.unanswered_count}</strong><span>未作答</span></div>
        <div><strong>{formatDuration(result.attempt.elapsed_seconds)}</strong><span>總花費時間</span></div>
      </div>
    </div>

    <div className="result-meta time-log">
      <span>模考日期：{new Date(`${result.attempt.exam_date}T00:00:00`).toLocaleDateString("zh-TW")}</span>
      <span>開始：{new Date(result.attempt.started_at).toLocaleString("zh-TW")}</span>
      <span>交卷：{new Date(result.attempt.submitted_at).toLocaleString("zh-TW")}</span>
      <span>{result.attempt.submit_reason === "timeout" ? "時間到自動交卷" : "手動交卷"}</span>
      <span>{result.attempt.is_timed ? `設定時長 ${result.attempt.duration_minutes} 分鐘` : "不計時練習"}</span>
      {result.paper && <a href={result.paper.source_answer_url} target="_blank" rel="noreferrer">官方答案來源</a>}
    </div>

    <section className="breakdown-section">
      <div className="section-heading"><div><div className="eyebrow">錯題分布</div><h2>各科與子科目</h2></div></div>
      <div className="breakdown-grid">{breakdown.map((item) => <article className="breakdown-card" key={`${item.subject}-${item.subsubject}`}><div><strong>{item.subject}</strong>{item.subsubject && <span>{item.subsubject}</span>}</div><div className="breakdown-numbers"><span>未滿分 {item.wrong}</span><span>未答 {item.unanswered}</span><span>共 {item.total}</span></div></article>)}</div>
    </section>

    {completeYear && <section className="year-total-card"><div><div className="eyebrow">年度四卷已完成</div><h2>{completeYear.exam_year_roc} 年總分 {completeYear.total_score} / {completeYear.max_score}</h2></div><div className="cutoff-comparison"><span className={completeYear.judicial_cutoff !== null && completeYear.total_score >= completeYear.judicial_cutoff ? "passed" : ""}>司法官門檻 {completeYear.judicial_cutoff ?? "—"}</span><span className={completeYear.lawyer_cutoff !== null && completeYear.total_score >= completeYear.lawyer_cutoff ? "passed" : ""}>律師門檻 {completeYear.lawyer_cutoff ?? "—"}</span>{completeYear.cutoff_source_url && <a href={completeYear.cutoff_source_url} target="_blank" rel="noreferrer">門檻資料來源</a>}</div></section>}

    <div className="filter-tabs" role="tablist" aria-label="答題結果篩選">
      {([
        ["all", `全部 ${result.questions.length}`],
        ["wrong", `未滿分 ${wrongCount}`],
        ["unanswered", `未作答 ${result.attempt.unanswered_count}`],
        ["correct", `滿分 ${result.attempt.correct_count}`],
        ["exam_starred", `模考星號 ${result.questions.filter((question) => question.exam_is_starred).length}`],
        ["review_starred", `檢討星號 ${result.questions.filter((question) => reviewStars[question.question_id]).length}`],
      ] as [ResultFilter, string][]).map(([value, label]) => <button key={value} type="button" className={filter === value ? "active" : ""} onClick={() => setFilter(value)}>{label}</button>)}
    </div>

    {errorMessage && <p className="error-message">{errorMessage}</p>}

    <div className="result-list">{filteredQuestions.map((question) => {
      const selected = question.selected_answer ?? "";
      const accepted = question.correct_answers?.length ? question.correct_answers : [question.correct_answer];
      const available = allChoices.filter((choice) => optionText(question, choice));
      const partial = !question.is_correct && !question.is_unanswered && question.earned_points > 0;
      const reviewStarred = Boolean(reviewStars[question.question_id]);
      return <article className={`result-question ${question.is_correct ? "correct" : "incorrect"}`} key={question.question_id}>
        <div className="result-question-header"><strong>第 {question.display_order} 題 · {question.subject_primary}{question.subsubject_primary !== "未分類" ? `／${question.subsubject_primary}` : ""}</strong><span>{question.is_bonus ? "送分" : question.is_correct ? "滿分" : question.is_unanswered ? "未作答" : partial ? "部分得分" : "答錯"}</span></div>
        <p className="result-question-text">{question.question_text}</p>
        <div className="result-option-list">{available.map((choice) => {
          const userSelected = selected.includes(choice);
          const officialOption = accepted.some((answer) => answer.includes(choice));
          return <div className={`result-option ${userSelected ? "user-selected" : ""} ${officialOption ? "official-option" : ""}`} key={choice}><span className="choice-badge">{choice}</span><span>{optionText(question, choice)}</span><div className="option-flags">{userSelected && <small>你的選擇</small>}{officialOption && <small>答案涉及</small>}</div></div>;
        })}</div>
        <div className="answer-comparison"><span>你的答案：<strong>{selected || "未作答"}</strong></span><span>可接受答案：<strong>{question.is_bonus ? "本題送分" : accepted.join("／")}</strong></span><span>得分：<strong>{question.earned_points} / {question.question_points}</strong></span><span>本題約 {formatDuration(question.active_seconds)}</span></div>

        <div className="annotation-comparison-grid">
          <section className="annotation-readonly-card">
            <div><strong>模考標記</strong><span>{question.exam_is_starred ? "★ 模考星號" : "未加星號"}</span></div>
            <p>{question.exam_note_text || "這回模考沒有留下筆記。"}</p>
            <small>模考標記在交卷後鎖定，保留當時作答脈絡。</small>
          </section>
          <section className="annotation-edit-card">
            <div className="annotation-edit-header"><strong>檢討標記</strong><button type="button" className={`star-button ${reviewStarred ? "active" : ""}`} onClick={() => toggleReviewStar(question.question_id)}>{reviewStarred ? "★ 已加入檢討星號" : "☆ 加入檢討星號"}</button></div>
            <textarea
              value={reviewNotes[question.question_id] ?? ""}
              placeholder="補上檢討後的考點、法條、錯因與下次判斷方式…"
              onChange={(event) => setReviewNotes((current) => ({ ...current, [question.question_id]: event.target.value }))}
              onBlur={() => void saveReviewAnnotation(question.question_id, reviewStarred, reviewNotes[question.question_id] ?? "")}
            />
            <small>{savingQuestionId === question.question_id ? "保存中…" : "檢討標記會跨回合保留，可用來建立複習組卷。"}</small>
          </section>
        </div>
      </article>;
    })}</div>

    <div className="actions"><Link className="button primary" href="/practice">再選一份測驗</Link><Link className="button secondary" href="/history">查看歷史紀錄</Link></div>
  </section>;
}
