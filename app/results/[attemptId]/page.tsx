"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AnswerChoice, AttemptResult, ConfidenceLevel, ErrorReason, ResultQuestion, YearSummary } from "@/lib/types";

type ResultFilter = "all" | "wrong" | "unanswered" | "correct" | "exam_starred" | "review_starred";
const allChoices: AnswerChoice[] = ["A", "B", "C", "D", "E"];
const primaryErrorOptions: Array<{ value: ErrorReason; label: string }> = [
  { value: "unfamiliar_rule", label: "不熟悉規則" },
  { value: "forgot_exception", label: "忘記例外" },
  { value: "misread_stem", label: "題幹誤讀" },
  { value: "option_confusion", label: "選項混淆" },
  { value: "time_pressure", label: "時間不足" },
  { value: "careless", label: "粗心" },
  { value: "guessed", label: "純猜" },
];
const secondaryErrorOptions = [
  { value: "law_article", label: "法條記錯" },
  { value: "case_law", label: "實務見解混淆" },
  { value: "question_uncertain", label: "題意不確定" },
];
const confidenceLabels: Record<ConfidenceLevel, string> = { confident: "確定", unsure: "不確定", guess: "純猜" };

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

function rate(earned: number, possible: number) {
  return possible > 0 ? Math.round(earned / possible * 100) : 0;
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
  const [primaryReasons, setPrimaryReasons] = useState<Record<string, ErrorReason | null>>({});
  const [secondaryReasons, setSecondaryReasons] = useState<Record<string, string[]>>({});
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
    setPrimaryReasons(Object.fromEntries(next.questions.map((question) => [question.question_id, question.primary_error_reason])));
    setSecondaryReasons(Object.fromEntries(next.questions.map((question) => [question.question_id, question.secondary_error_reasons ?? []])));
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

  async function saveErrorReason(questionId: string, primary: ErrorReason | null, secondary: string[]) {
    setSavingQuestionId(questionId);
    const { error } = await getSupabaseBrowserClient().rpc("save_error_annotation", {
      p_attempt_id: attemptId,
      p_question_id: questionId,
      p_primary_error_reason: primary,
      p_secondary_error_reasons: secondary,
    });
    if (error) setErrorMessage(`錯因保存失敗：${error.message}`);
    setSavingQuestionId(null);
  }

  function toggleSecondaryReason(questionId: string, value: string) {
    const current = secondaryReasons[questionId] ?? [];
    const next = current.includes(value) ? current.filter((item) => item !== value) : [...current, value];
    setSecondaryReasons((state) => ({ ...state, [questionId]: next }));
    void saveErrorReason(questionId, primaryReasons[questionId] ?? null, next);
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
    const groups = new Map<string, { subject: string; subsubject: string; total: number; wrong: number; unanswered: number; correct: number; active: number; points: number; earned: number }>();
    for (const question of result.questions) {
      const subsubject = question.subsubject_primary && question.subsubject_primary !== "未分類" ? question.subsubject_primary : "";
      const key = `${question.subject_primary}::${subsubject}`;
      const item = groups.get(key) ?? { subject: question.subject_primary || "未分類", subsubject, total: 0, wrong: 0, unanswered: 0, correct: 0, active: 0, points: 0, earned: 0 };
      item.total += 1;
      item.active += question.active_seconds || 0;
      item.points += question.question_points;
      item.earned += question.earned_points;
      if (question.is_unanswered) item.unanswered += 1;
      else if (question.is_correct) item.correct += 1;
      else item.wrong += 1;
      groups.set(key, item);
    }
    return Array.from(groups.values());
  }, [result]);

  const paceAnalysis = useMemo(() => {
    if (!result) return null;
    const targetSeconds = result.attempt.is_timed && result.questions.length ? result.attempt.duration_minutes * 60 / result.questions.length : 0;
    const sortedByTime = [...result.questions].sort((a, b) => b.active_seconds - a.active_seconds).slice(0, 5);
    const midpoint = Math.ceil(result.questions.length / 2);
    const halves = [result.questions.slice(0, midpoint), result.questions.slice(midpoint)].map((items) => ({
      questions: items.length,
      earned: items.reduce((sum, q) => sum + q.earned_points, 0),
      possible: items.reduce((sum, q) => sum + q.question_points, 0),
      active: items.reduce((sum, q) => sum + q.active_seconds, 0),
      unanswered: items.filter((q) => q.is_unanswered).length,
    }));
    const lastTen = result.attempt.is_timed
      ? result.questions.filter((q) => q.seconds_remaining_at_answer !== null && q.seconds_remaining_at_answer <= 600)
      : [];
    const rapidLastTen = targetSeconds > 0 ? lastTen.filter((q) => q.active_seconds < targetSeconds * 0.3) : [];
    const changed = result.questions.filter((q) => q.answer_revision_count > 1 && q.first_answer);
    const revisions = {
      improved: changed.filter((q) => q.earned_points > q.first_earned_points).length,
      harmed: changed.filter((q) => q.earned_points < q.first_earned_points).length,
      unchanged: changed.filter((q) => q.earned_points === q.first_earned_points).length,
    };
    const confidence = {
      confidentWrong: result.questions.filter((q) => q.confidence_level === "confident" && !q.is_correct).length,
      unsureCorrect: result.questions.filter((q) => q.confidence_level === "unsure" && q.is_correct).length,
      guessWrong: result.questions.filter((q) => q.confidence_level === "guess" && !q.is_correct).length,
      recorded: result.questions.filter((q) => q.confidence_level).length,
    };
    return { targetSeconds, sortedByTime, halves, lastTen, rapidLastTen, lastTenGuesses: lastTen.filter((q) => q.confidence_level === "guess").length, revisions, confidence, changedCount: changed.length };
  }, [result]);

  if (errorMessage && !result) {
    return <section className="container narrow page-section centered-panel"><h1>成績尚未產生</h1><p className="error-message">{errorMessage}</p><Link className="button primary" href={`/exam/${attemptId}`}>返回考試</Link></section>;
  }
  if (!result || !paceAnalysis) return <section className="container page-section"><p className="muted">正在計算成績…</p></section>;

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

    <section className="pacing-report">
      <div className="section-heading"><div><div className="eyebrow">Pacing report</div><h2>答題節奏診斷</h2></div><span>切換到背景分頁的時間不計入單題活躍時間</span></div>
      <div className="pacing-grid">
        {breakdown.map((item) => <article key={`${item.subject}-${item.subsubject}`}><strong>{item.subject}{item.subsubject ? `／${item.subsubject}` : ""}</strong><span>平均 {item.total ? Math.round(item.active / item.total) : 0} 秒／題</span>{paceAnalysis.targetSeconds > 0 && <small>目標約 {Math.round(paceAnalysis.targetSeconds)} 秒／題</small>}<em>得分率 {rate(item.earned, item.points)}%</em></article>)}
      </div>
      <div className="pacing-insight-grid">
        <article><strong>前後半卷</strong><p>前半：{rate(paceAnalysis.halves[0].earned, paceAnalysis.halves[0].possible)}%，平均 {paceAnalysis.halves[0].questions ? Math.round(paceAnalysis.halves[0].active / paceAnalysis.halves[0].questions) : 0} 秒／題</p><p>後半：{rate(paceAnalysis.halves[1].earned, paceAnalysis.halves[1].possible)}%，平均 {paceAnalysis.halves[1].questions ? Math.round(paceAnalysis.halves[1].active / paceAnalysis.halves[1].questions) : 0} 秒／題</p></article>
        <article><strong>最後 10 分鐘</strong>{result.attempt.is_timed ? <><p>完成 {paceAnalysis.lastTen.length} 題，其中 {paceAnalysis.rapidLastTen.length} 題低於目標時間 30%。</p><p>該區得分率 {rate(paceAnalysis.lastTen.reduce((s, q) => s + q.earned_points, 0), paceAnalysis.lastTen.reduce((s, q) => s + q.question_points, 0))}%；其中 {paceAnalysis.lastTenGuesses} 題標記純猜。</p></> : <p>本回不計時，無最後十分鐘分析。</p>}</article>
        <article><strong>修改答案</strong><p>實際改答案 {paceAnalysis.changedCount} 題</p><p>錯→較好 {paceAnalysis.revisions.improved}｜較好→較差 {paceAnalysis.revisions.harmed}｜不變 {paceAnalysis.revisions.unchanged}</p></article>
        <article><strong>信心校準</strong><p>確定但未滿分 {paceAnalysis.confidence.confidentWrong} 題</p><p>不確定但答對 {paceAnalysis.confidence.unsureCorrect}｜純猜未滿分 {paceAnalysis.confidence.guessWrong}</p><small>本回記錄 {paceAnalysis.confidence.recorded}／{result.questions.length} 題信心</small></article>
      </div>
      <div className="slow-question-list"><strong>最耗時題目</strong>{paceAnalysis.sortedByTime.map((question) => <a key={question.question_id} href={`#question-${question.question_id}`}>第 {question.display_order} 題 · {question.active_seconds} 秒 · {question.is_correct ? "滿分" : "未滿分"}</a>)}</div>
    </section>

    <section className="breakdown-section">
      <div className="section-heading"><div><div className="eyebrow">錯題分布</div><h2>各科與子科目</h2></div></div>
      <div className="breakdown-grid">{breakdown.map((item) => <article className="breakdown-card" key={`${item.subject}-${item.subsubject}`}><div><strong>{item.subject}</strong>{item.subsubject && <span>{item.subsubject}</span>}</div><div className="breakdown-numbers"><span>未滿分 {item.wrong}</span><span>未答 {item.unanswered}</span><span>共 {item.total}</span></div></article>)}</div>
    </section>

    {completeYear && <section className="year-total-card"><div><div className="eyebrow">年度四卷已完成</div><h2>{completeYear.exam_year_roc} 年總分 {completeYear.total_score} / {completeYear.max_score}</h2></div><div className="cutoff-comparison"><span className={completeYear.judicial_cutoff !== null && completeYear.total_score >= completeYear.judicial_cutoff ? "passed" : ""}>司法官門檻 {completeYear.judicial_cutoff ?? "—"}</span><span className={completeYear.lawyer_cutoff !== null && completeYear.total_score >= completeYear.lawyer_cutoff ? "passed" : ""}>律師門檻 {completeYear.lawyer_cutoff ?? "—"}</span>{completeYear.cutoff_source_url && <a href={completeYear.cutoff_source_url} target="_blank" rel="noreferrer">門檻資料來源</a>}</div></section>}

    <div className="spaced-review-callout"><div><strong>間隔複習已排程</strong><span>依本回得分與信心程度，題目會安排在 1／3／7／14／30 天後再次出現。</span></div><Link className="button secondary compact" href="/review">查看今日待複習</Link></div>

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
      const primaryReason = primaryReasons[question.question_id] ?? null;
      const secondary = secondaryReasons[question.question_id] ?? [];
      return <article id={`question-${question.question_id}`} className={`result-question ${question.is_correct ? "correct" : "incorrect"}`} key={question.question_id}>
        <div className="result-question-header"><strong>第 {question.display_order} 題 · {question.subject_primary}{question.subsubject_primary !== "未分類" ? `／${question.subsubject_primary}` : ""}</strong><span>{question.is_bonus ? "送分" : question.is_correct ? "滿分" : question.is_unanswered ? "未作答" : partial ? "部分得分" : "答錯"}</span></div>
        <p className="result-question-text">{question.question_text}</p>
        <div className="result-option-list">{available.map((choice) => {
          const userSelected = selected.includes(choice);
          const officialOption = accepted.some((answer) => answer.includes(choice));
          return <div className={`result-option ${userSelected ? "user-selected" : ""} ${officialOption ? "official-option" : ""}`} key={choice}><span className="choice-badge">{choice}</span><span>{optionText(question, choice)}</span><div className="option-flags">{userSelected && <small>你的選擇</small>}{officialOption && <small>答案涉及</small>}</div></div>;
        })}</div>
        <div className="answer-comparison"><span>你的答案：<strong>{selected || "未作答"}</strong></span><span>可接受答案：<strong>{question.is_bonus ? "本題送分" : accepted.join("／")}</strong></span><span>得分：<strong>{question.earned_points} / {question.question_points}</strong></span><span>本題約 {formatDuration(question.active_seconds)}</span>{question.confidence_level && <span>信心：<strong>{confidenceLabels[question.confidence_level]}</strong></span>}{question.answer_revision_count > 1 && <span>修改答案：<strong>{question.answer_revision_count - 1} 次</strong></span>}</div>

        {!question.is_correct && <section className="error-diagnosis-card">
          <div><strong>這題為什麼沒拿滿分？</strong><span>錯因綁定本次作答，可在跨回合報告中累積分析。</span></div>
          <label><span>主要原因</span><select value={primaryReason ?? ""} onChange={(event) => { const next = (event.target.value || null) as ErrorReason | null; setPrimaryReasons((state) => ({ ...state, [question.question_id]: next })); void saveErrorReason(question.question_id, next, secondary); }}><option value="">尚未標記</option>{primaryErrorOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
          <div className="secondary-reason-grid">{secondaryErrorOptions.map((option) => <label key={option.value}><input type="checkbox" checked={secondary.includes(option.value)} onChange={() => toggleSecondaryReason(question.question_id, option.value)} /><span>{option.label}</span></label>)}</div>
        </section>}

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
