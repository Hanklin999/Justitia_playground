"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { AnswerChoice, AttemptPayload } from "@/lib/types";

const choices: AnswerChoice[] = ["A", "B", "C", "D"];

function formatRemaining(totalSeconds: number): string {
  const safeSeconds = Math.max(0, totalSeconds);
  const minutes = Math.floor(safeSeconds / 60);
  const seconds = safeSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

export default function ExamPage() {
  const params = useParams<{ attemptId: string }>();
  const router = useRouter();
  const attemptId = params.attemptId;
  const [payload, setPayload] = useState<AttemptPayload | null>(null);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [answers, setAnswers] = useState<Record<string, AnswerChoice>>({});
  const [remainingSeconds, setRemainingSeconds] = useState(0);
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [errorMessage, setErrorMessage] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const autoSubmitStarted = useRef(false);

  const submitAttempt = useCallback(async () => {
    if (submitting) return;
    setSubmitting(true);
    setErrorMessage("");
    const supabase = getSupabaseBrowserClient();
    const { error } = await supabase.rpc("submit_exam_attempt", {
      p_attempt_id: attemptId,
    });

    if (error) {
      setSubmitting(false);
      setErrorMessage(`交卷失敗：${error.message}`);
      return;
    }

    router.replace(`/results/${attemptId}`);
  }, [attemptId, router, submitting]);

  useEffect(() => {
    let active = true;
    const supabase = getSupabaseBrowserClient();

    async function load() {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) {
        router.replace("/login");
        return;
      }

      const { data, error } = await supabase.rpc("get_attempt_payload", {
        p_attempt_id: attemptId,
      });

      if (!active) return;
      if (error) {
        setErrorMessage(`無法讀取考試：${error.message}`);
        return;
      }

      const nextPayload = data as AttemptPayload;
      if (nextPayload.attempt.status !== "in_progress") {
        router.replace(`/results/${attemptId}`);
        return;
      }

      const restoredAnswers: Record<string, AnswerChoice> = {};
      for (const question of nextPayload.questions) {
        if (question.selected_answer) {
          restoredAnswers[question.question_id] = question.selected_answer;
        }
      }
      setAnswers(restoredAnswers);
      setPayload(nextPayload);
    }

    void load();
    return () => {
      active = false;
    };
  }, [attemptId, router]);

  useEffect(() => {
    if (!payload) return;
    const expiresAt = payload.attempt.expires_at;

    function tick() {
      const seconds = Math.max(
        0,
        Math.ceil((new Date(expiresAt).getTime() - Date.now()) / 1000),
      );
      setRemainingSeconds(seconds);
      if (seconds <= 0 && !autoSubmitStarted.current) {
        autoSubmitStarted.current = true;
        void submitAttempt();
      }
    }

    tick();
    const timer = window.setInterval(tick, 1000);
    return () => window.clearInterval(timer);
  }, [payload, submitAttempt]);

  useEffect(() => {
    if (!payload) return;
    const warnBeforeLeave = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warnBeforeLeave);
    return () => window.removeEventListener("beforeunload", warnBeforeLeave);
  }, [payload]);

  const currentQuestion = payload?.questions[currentIndex];
  const answeredCount = Object.keys(answers).length;
  const progressPercent = payload ? (answeredCount / payload.questions.length) * 100 : 0;

  const optionMap = useMemo(() => {
    if (!currentQuestion) return {} as Record<AnswerChoice, string>;
    return {
      A: currentQuestion.option_a,
      B: currentQuestion.option_b,
      C: currentQuestion.option_c,
      D: currentQuestion.option_d,
    };
  }, [currentQuestion]);

  async function saveAnswer(choice: AnswerChoice) {
    if (!currentQuestion || submitting) return;
    const previous = answers[currentQuestion.question_id];
    setAnswers((current) => ({ ...current, [currentQuestion.question_id]: choice }));
    setSaveState("saving");
    setErrorMessage("");

    const supabase = getSupabaseBrowserClient();
    const { data, error } = await supabase.rpc("save_attempt_answer", {
      p_attempt_id: attemptId,
      p_question_id: currentQuestion.question_id,
      p_selected_answer: choice,
    });

    if (error) {
      setAnswers((current) => {
        const next = { ...current };
        if (previous) next[currentQuestion.question_id] = previous;
        else delete next[currentQuestion.question_id];
        return next;
      });
      setSaveState("error");
      setErrorMessage(`答案未保存：${error.message}`);
      return;
    }

    const response = data as { ok: boolean; status: string };
    if (!response.ok) {
      autoSubmitStarted.current = true;
      await submitAttempt();
      return;
    }

    setSaveState("saved");
    window.setTimeout(() => setSaveState("idle"), 1200);
  }

  function confirmSubmit() {
    if (saveState === "saving") {
      window.alert("答案正在保存，請稍後再交卷。");
      return;
    }
    const unanswered = payload ? payload.questions.length - answeredCount : 0;
    const message = unanswered > 0
      ? `尚有 ${unanswered} 題未作答。確定交卷嗎？交卷後不能修改答案。`
      : "確定交卷嗎？交卷後不能修改答案。";
    if (window.confirm(message)) void submitAttempt();
  }

  if (errorMessage && !payload) {
    return (
      <section className="container narrow page-section centered-panel">
        <h1>無法開啟考試</h1>
        <p className="error-message">{errorMessage}</p>
        <Link className="button primary" href="/practice">返回試卷列表</Link>
      </section>
    );
  }

  if (!payload || !currentQuestion) {
    return <section className="container page-section"><p className="muted">正在載入考試與已保存答案…</p></section>;
  }

  return (
    <div className="exam-shell">
      <header className="exam-header">
        <div>
          <div className="exam-kicker">{payload.paper.exam_year_roc} 年 · 第 {payload.paper.paper_order} 卷</div>
          <strong>{payload.paper.paper_title}</strong>
        </div>
        <div className={`timer ${remainingSeconds <= 300 ? "timer-warning" : ""}`}>
          <span>剩餘時間</span>
          <strong>{formatRemaining(remainingSeconds)}</strong>
        </div>
      </header>

      <div className="exam-progress" aria-label={`已作答 ${answeredCount} 題`}>
        <div style={{ width: `${progressPercent}%` }} />
      </div>

      <main className="exam-layout">
        <aside className="question-navigator">
          <div className="navigator-summary">
            <strong>{answeredCount} / {payload.questions.length}</strong>
            <span>已作答</span>
          </div>
          <div className="question-number-grid">
            {payload.questions.map((question, index) => (
              <button
                type="button"
                key={question.question_id}
                className={`${index === currentIndex ? "current" : ""} ${answers[question.question_id] ? "answered" : ""}`}
                onClick={() => setCurrentIndex(index)}
                aria-label={`第 ${question.question_number} 題${answers[question.question_id] ? "，已作答" : ""}`}
              >
                {question.question_number}
              </button>
            ))}
          </div>
        </aside>

        <section className="question-panel">
          <div className="question-toolbar">
            <span>第 {currentQuestion.question_number} 題</span>
            <span className={`save-indicator ${saveState}`}>
              {saveState === "saving" ? "保存中…" : saveState === "saved" ? "已保存" : saveState === "error" ? "未保存" : "自動保存"}
            </span>
          </div>

          <h1 className="question-text">{currentQuestion.question_text}</h1>

          <div className="answer-options">
            {choices.map((choice) => (
              <label
                className={`answer-option ${answers[currentQuestion.question_id] === choice ? "selected" : ""}`}
                key={choice}
              >
                <input
                  type="radio"
                  name={currentQuestion.question_id}
                  value={choice}
                  checked={answers[currentQuestion.question_id] === choice}
                  onChange={() => void saveAnswer(choice)}
                />
                <span className="choice-badge">{choice}</span>
                <span>{optionMap[choice]}</span>
              </label>
            ))}
          </div>

          {currentQuestion.review_status !== "verified_text_answer" && (
            <p className="review-note">此題由官方 PDF 自動擷取，尚待人工逐題複核。</p>
          )}
          {errorMessage && <p className="error-message">{errorMessage}</p>}

          <div className="question-actions">
            <button
              type="button"
              className="button secondary"
              disabled={currentIndex === 0}
              onClick={() => setCurrentIndex((index) => Math.max(0, index - 1))}
            >
              上一題
            </button>
            {currentIndex < payload.questions.length - 1 ? (
              <button
                type="button"
                className="button primary"
                onClick={() => setCurrentIndex((index) => Math.min(payload.questions.length - 1, index + 1))}
              >
                下一題
              </button>
            ) : (
              <button type="button" className="button primary" onClick={confirmSubmit} disabled={submitting || saveState === "saving"}>
                {submitting ? "交卷中…" : "交卷"}
              </button>
            )}
          </div>
        </section>
      </main>

      <footer className="exam-footer">
        <span>正式時長：{payload.attempt.duration_minutes} 分鐘</span>
        <button className="text-button danger" type="button" onClick={confirmSubmit} disabled={submitting || saveState === "saving"}>
          提前交卷
        </button>
      </footer>
    </div>
  );
}
