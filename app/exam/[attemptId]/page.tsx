"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AnswerChoice, AttemptPayload } from "@/lib/types";

const choices: AnswerChoice[] = ["A", "B", "C", "D"];

function formatSeconds(totalSeconds: number): string {
  const safe = Math.max(0, totalSeconds);
  const hours = Math.floor(safe / 3600);
  const minutes = Math.floor((safe % 3600) / 60);
  const seconds = safe % 60;
  return hours > 0
    ? `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    : `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

export default function ExamPage() {
  const params = useParams<{ attemptId: string }>();
  const router = useRouter();
  const attemptId = params.attemptId;
  const [payload, setPayload] = useState<AttemptPayload | null>(null);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [answers, setAnswers] = useState<Record<string, AnswerChoice>>({});
  const [stars, setStars] = useState<Record<string, boolean>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [remainingSeconds, setRemainingSeconds] = useState(0);
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [annotationState, setAnnotationState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [errorMessage, setErrorMessage] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const autoSubmitStarted = useRef(false);
  const trackedQuestionRef = useRef<string | null>(null);
  const trackedAtRef = useRef<number>(Date.now());

  const submitAttempt = useCallback(async () => {
    if (submitting) return;
    setSubmitting(true);
    setErrorMessage("");
    const supabase = getSupabaseBrowserClient();
    const { error } = await supabase.rpc("submit_exam_attempt", { p_attempt_id: attemptId });
    if (error) {
      setSubmitting(false);
      setErrorMessage(`交卷失敗：${error.message}`);
      return;
    }
    router.replace(`/results/${attemptId}`);
  }, [attemptId, router, submitting]);

  const flushQuestionTime = useCallback(async () => {
    const questionId = trackedQuestionRef.current;
    if (!questionId) return;
    const seconds = Math.min(300, Math.floor((Date.now() - trackedAtRef.current) / 1000));
    trackedAtRef.current = Date.now();
    if (seconds < 1) return;
    const supabase = getSupabaseBrowserClient();
    await supabase.rpc("add_question_active_seconds", {
      p_attempt_id: attemptId,
      p_question_id: questionId,
      p_seconds: seconds,
    });
  }, [attemptId]);

  useEffect(() => {
    let active = true;
    const supabase = getSupabaseBrowserClient();
    async function load() {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) {
        router.replace("/login");
        return;
      }
      const { data, error } = await supabase.rpc("get_attempt_payload", { p_attempt_id: attemptId });
      if (!active) return;
      if (error) {
        setErrorMessage(`無法讀取考試：${error.message}`);
        return;
      }
      const next = data as AttemptPayload;
      if (next.attempt.status !== "in_progress") {
        router.replace(`/results/${attemptId}`);
        return;
      }
      setPayload(next);
      setAnswers(Object.fromEntries(next.questions.filter((q) => q.selected_answer).map((q) => [q.question_id, q.selected_answer!])));
      setStars(Object.fromEntries(next.questions.map((q) => [q.question_id, q.is_starred])));
      setNotes(Object.fromEntries(next.questions.map((q) => [q.question_id, q.note_text])));
      const startMs = new Date(next.attempt.started_at).getTime();
      setElapsedSeconds(Math.max(0, Math.floor((Date.now() - startMs) / 1000)));
      if (next.attempt.is_timed && next.attempt.expires_at) {
        setRemainingSeconds(Math.max(0, Math.floor((new Date(next.attempt.expires_at).getTime() - Date.now()) / 1000)));
      }
    }
    void load();
    return () => { active = false; };
  }, [attemptId, router]);

  useEffect(() => {
    if (!payload) return;
    const tick = window.setInterval(() => {
      setElapsedSeconds(Math.max(0, Math.floor((Date.now() - new Date(payload.attempt.started_at).getTime()) / 1000)));
      if (payload.attempt.is_timed && payload.attempt.expires_at) {
        setRemainingSeconds(Math.max(0, Math.floor((new Date(payload.attempt.expires_at).getTime() - Date.now()) / 1000)));
      }
    }, 1000);
    return () => window.clearInterval(tick);
  }, [payload]);

  useEffect(() => {
    if (!payload?.attempt.is_timed || remainingSeconds > 0 || autoSubmitStarted.current) return;
    autoSubmitStarted.current = true;
    void flushQuestionTime().finally(() => void submitAttempt());
  }, [flushQuestionTime, payload?.attempt.is_timed, remainingSeconds, submitAttempt]);

  const currentQuestion = payload?.questions[currentIndex] ?? null;

  useEffect(() => {
    if (!currentQuestion) return;
    void flushQuestionTime();
    trackedQuestionRef.current = currentQuestion.question_id;
    trackedAtRef.current = Date.now();
  }, [currentQuestion?.question_id, flushQuestionTime]);

  useEffect(() => {
    const interval = window.setInterval(() => void flushQuestionTime(), 15000);
    return () => {
      window.clearInterval(interval);
      void flushQuestionTime();
    };
  }, [flushQuestionTime]);

  const answeredCount = useMemo(() => Object.keys(answers).length, [answers]);

  async function saveAnswer(choice: AnswerChoice) {
    if (!currentQuestion) return;
    setAnswers((current) => ({ ...current, [currentQuestion.question_id]: choice }));
    setSaveState("saving");
    const supabase = getSupabaseBrowserClient();
    const { error } = await supabase.rpc("save_attempt_answer", {
      p_attempt_id: attemptId,
      p_question_id: currentQuestion.question_id,
      p_selected_answer: choice,
    });
    if (error) {
      setSaveState("error");
      setErrorMessage(`答案保存失敗：${error.message}`);
    } else {
      setSaveState("saved");
      window.setTimeout(() => setSaveState("idle"), 1200);
    }
  }

  async function saveAnnotation(questionId: string, nextStar: boolean, nextNote: string) {
    setAnnotationState("saving");
    const supabase = getSupabaseBrowserClient();
    const { error } = await supabase.rpc("save_question_annotation", {
      p_question_id: questionId,
      p_is_starred: nextStar,
      p_note_text: nextNote,
    });
    if (error) {
      setAnnotationState("error");
      setErrorMessage(`標記保存失敗：${error.message}`);
    } else {
      setAnnotationState("saved");
      window.setTimeout(() => setAnnotationState("idle"), 1200);
    }
  }

  function toggleStar() {
    if (!currentQuestion) return;
    const next = !stars[currentQuestion.question_id];
    setStars((current) => ({ ...current, [currentQuestion.question_id]: next }));
    void saveAnnotation(currentQuestion.question_id, next, notes[currentQuestion.question_id] ?? "");
  }

  function confirmSubmit() {
    const unanswered = (payload?.questions.length ?? 0) - answeredCount;
    if (window.confirm(unanswered > 0 ? `還有 ${unanswered} 題未作答，確定交卷？` : "確定交卷？")) {
      void flushQuestionTime().finally(() => void submitAttempt());
    }
  }

  if (!payload || !currentQuestion) {
    return <section className="container page-section"><p className="muted">正在載入考試…</p>{errorMessage && <p className="error-message">{errorMessage}</p>}</section>;
  }

  const optionMap: Record<AnswerChoice, string> = { A: currentQuestion.option_a, B: currentQuestion.option_b, C: currentQuestion.option_c, D: currentQuestion.option_d };
  const progress = (answeredCount / payload.questions.length) * 100;

  return (
    <div className="exam-shell">
      <header className="exam-header">
        <div>
          <div className="exam-kicker">{payload.attempt.attempt_mode === "official_paper" && payload.paper ? `${payload.paper.exam_year_roc} 年第 ${payload.paper.paper_order} 卷` : payload.attempt.attempt_mode === "wrong_review" ? "錯題重刷" : "科目自組測驗"}</div>
          <strong>{payload.attempt.title}</strong>
        </div>
        <div className={`timer ${payload.attempt.is_timed && remainingSeconds <= 300 ? "timer-warning" : ""}`}>
          <span>{payload.attempt.is_timed ? "剩餘時間" : "已作答時間"}</span>
          <strong>{formatSeconds(payload.attempt.is_timed ? remainingSeconds : elapsedSeconds)}</strong>
        </div>
      </header>
      <div className="exam-progress"><div style={{ width: `${progress}%` }} /></div>

      <main className="exam-layout">
        <aside className="question-navigator">
          <div className="navigator-summary"><strong>{answeredCount}</strong><span>/ {payload.questions.length} 已作答</span></div>
          <div className="question-number-grid">
            {payload.questions.map((question, index) => (
              <button
                type="button"
                key={question.question_id}
                className={`${answers[question.question_id] ? "answered" : ""} ${index === currentIndex ? "current" : ""} ${stars[question.question_id] ? "starred" : ""}`}
                onClick={() => setCurrentIndex(index)}
                title={stars[question.question_id] ? "已標記不會" : undefined}
              >
                {stars[question.question_id] && <span className="nav-star">★</span>}{index + 1}
              </button>
            ))}
          </div>
        </aside>

        <section className="question-panel">
          <div className="question-toolbar">
            <span>第 {currentIndex + 1} / {payload.questions.length} 題</span>
            <span className={`save-indicator ${saveState}`}>{saveState === "saving" ? "保存中…" : saveState === "saved" ? "已保存" : saveState === "error" ? "保存失敗" : annotationState === "saving" ? "標記保存中…" : annotationState === "saved" ? "標記已保存" : ""}</span>
          </div>
          <div className="question-tags"><span>{currentQuestion.subject_primary}</span>{currentQuestion.subsubject_primary !== "未分類" && <span>{currentQuestion.subsubject_primary}</span>}</div>
          <p className="question-text">{currentQuestion.question_text}</p>
          <div className="answer-options">
            {choices.map((choice) => (
              <label className={`answer-option ${answers[currentQuestion.question_id] === choice ? "selected" : ""}`} key={choice}>
                <input type="radio" name={currentQuestion.question_id} value={choice} checked={answers[currentQuestion.question_id] === choice} onChange={() => void saveAnswer(choice)} />
                <span className="choice-badge">{choice}</span><span>{optionMap[choice]}</span>
              </label>
            ))}
          </div>

          <div className="annotation-panel">
            <button type="button" className={stars[currentQuestion.question_id] ? "star-button active" : "star-button"} onClick={toggleStar}>
              {stars[currentQuestion.question_id] ? "★ 已標記不會" : "☆ 標記不會"}
            </button>
            <label>
              <span>本題筆記</span>
              <textarea
                value={notes[currentQuestion.question_id] ?? ""}
                placeholder="記下易錯點、待查法條或自己的判斷…"
                onChange={(event) => setNotes((current) => ({ ...current, [currentQuestion.question_id]: event.target.value }))}
                onBlur={() => void saveAnnotation(currentQuestion.question_id, Boolean(stars[currentQuestion.question_id]), notes[currentQuestion.question_id] ?? "")}
              />
            </label>
          </div>

          {currentQuestion.review_status !== "verified_text_answer" && <p className="review-note">此題由官方 PDF 自動擷取，尚待人工逐題複核。</p>}
          {errorMessage && <p className="error-message">{errorMessage}</p>}
          <div className="question-actions">
            <button type="button" className="button secondary" disabled={currentIndex === 0} onClick={() => setCurrentIndex((index) => Math.max(0, index - 1))}>上一題</button>
            {currentIndex < payload.questions.length - 1 ? (
              <button type="button" className="button primary" onClick={() => setCurrentIndex((index) => Math.min(payload.questions.length - 1, index + 1))}>下一題</button>
            ) : (
              <button type="button" className="button primary" onClick={confirmSubmit} disabled={submitting || saveState === "saving"}>{submitting ? "交卷中…" : "交卷"}</button>
            )}
          </div>
        </section>
      </main>

      <footer className="exam-footer">
        <span>{payload.attempt.is_timed ? `本次時長：${payload.attempt.duration_minutes} 分鐘` : "錯題重刷不計時"}</span>
        <div><Link className="text-button" href="/practice">離開</Link><button className="text-button danger" type="button" onClick={confirmSubmit} disabled={submitting || saveState === "saving"}>提前交卷</button></div>
      </footer>
    </div>
  );
}
