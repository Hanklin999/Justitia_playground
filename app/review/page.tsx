"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { DueReviewSummary, LearningInsights, StartAttemptResponse } from "@/lib/types";

const limits = [10, 20, 30, 200];
const errorReasonLabels: Record<string, string> = {
  unfamiliar_rule: "不熟悉規則",
  forgot_exception: "忘記例外",
  misread_stem: "題幹誤讀",
  option_confusion: "選項混淆",
  time_pressure: "時間不足",
  careless: "粗心",
  guessed: "純猜",
};

export default function ReviewPage() {
  const router = useRouter();
  const [summary, setSummary] = useState<DueReviewSummary | null>(null);
  const [insights, setInsights] = useState<LearningInsights | null>(null);
  const [limit, setLimit] = useState(20);
  const [loading, setLoading] = useState(true);
  const [starting, setStarting] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    let active = true;
    async function load() {
      const supabase = getSupabaseBrowserClient();
      const { data: sessionData } = await supabase.auth.getSession();
      if (!sessionData.session) {
        router.replace("/login");
        return;
      }
      const [{ data, error }, { data: insightData, error: insightError }] = await Promise.all([
        supabase.rpc("get_due_review_summary"),
        supabase.rpc("get_learning_insights"),
      ]);
      if (!active) return;
      if (error) setErrorMessage(`無法讀取複習排程：${error.message}`);
      else setSummary(data as DueReviewSummary);
      if (insightError) setErrorMessage((current) => current || `無法讀取學習診斷：${insightError.message}`);
      else setInsights(insightData as LearningInsights);
      setLoading(false);
    }
    void load();
    return () => { active = false; };
  }, [router]);

  async function startReview() {
    if (!summary?.due_count) return;
    setStarting(true);
    setErrorMessage("");
    const { data, error } = await getSupabaseBrowserClient().rpc("start_due_review_attempt", { p_limit: limit });
    if (error) {
      setErrorMessage(`無法建立今日複習：${error.message}`);
      setStarting(false);
      return;
    }
    router.push(`/exam/${(data as StartAttemptResponse).attempt_id}`);
  }

  return <section className="container page-section review-dashboard">
    <div className="eyebrow">Spaced review</div>
    <h1>今日待複習</h1>
    <p className="muted">系統依得分與信心程度安排 1／3／7／14／30 天後再次出題。答錯會回到 1 天，連續兩次「確定且答對」會延長到 30 天。</p>

    {loading && <p className="muted">正在整理今日題目…</p>}
    {errorMessage && <p className="error-message">{errorMessage}</p>}

    {summary && <>
      <div className="review-hero-card">
        <div><span>今天到期</span><strong>{summary.due_count}</strong><small>題</small></div>
        <div><span>尚未到期</span><strong>{summary.upcoming_count}</strong><small>題</small></div>
        <div><span>下一批</span><strong className="review-next-date">{summary.next_due_at ? new Date(summary.next_due_at).toLocaleDateString("zh-TW") : "—"}</strong></div>
      </div>

      {summary.due_by_subject.length > 0 && <section className="due-subject-section"><h2>今日科目分布</h2><div className="due-subject-grid">{summary.due_by_subject.map((item) => <article key={item.subject}><strong>{item.subject}</strong><span>{item.count} 題</span></article>)}</div></section>}

      {insights && insights.recent_attempt_count > 0 && <section className="learning-insights-section">
        <div className="section-heading"><div><div className="eyebrow">最近五回</div><h2>學習診斷</h2></div><span>依已標記錯因與作答信心彙整</span></div>
        <div className="learning-insight-grid">
          <article><strong>最常見錯因</strong>{insights.top_error_reasons.length ? insights.top_error_reasons.slice(0, 3).map((item) => <p key={item.reason}>{errorReasonLabels[item.reason] ?? item.reason}<span>{item.count} 題</span></p>) : <p>尚未標記錯因</p>}</article>
          <article><strong>高風險錯誤認知</strong><p>確定但未滿分<span>{insights.confidence.confident_wrong} 題</span></p><p>純猜且未滿分<span>{insights.confidence.guess_wrong} 題</span></p></article>
          <article><strong>尚未穩定掌握</strong><p>不確定但答對<span>{insights.confidence.unsure_correct} 題</span></p><p>已記錄信心<span>{insights.confidence.recorded} 題</span></p></article>
        </div>
      </section>}

      {summary.due_count > 0 ? <section className="review-start-card">
        <div><h2>開始不計時複習</h2><p>優先順序：答錯 → 猜對 → 不確定答對 → 其他到期題目。</p></div>
        <label><span>本回題數</span><select value={limit} onChange={(event) => setLimit(Number(event.target.value))}>{limits.map((value) => <option key={value} value={value}>{value === 200 ? "全部（最多 200 題）" : `${value} 題`}</option>)}</select></label>
        <button type="button" className="button primary" disabled={starting} onClick={() => void startReview()}>{starting ? "建立中…" : `開始複習 ${Math.min(limit, summary.due_count)} 題`}</button>
      </section> : <div className="empty-state"><h2>今天沒有到期題目</h2><p>完成新的模考或回來檢討後，系統會持續更新複習日期。</p><Link className="button primary" href="/practice">開始一份測驗</Link></div>}
    </>}
  </section>;
}
