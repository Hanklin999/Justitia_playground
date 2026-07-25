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
  if (mode === "subject_pool") return "自組模考";
  return "複習組卷";
}

function formatDuration(seconds: number | null): string {
  if (seconds === null) return "—";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m} 分 ${s} 秒`;
}

function scoreRate(attempt: AttemptHistoryItem): number | null {
  if (attempt.score === null || !attempt.max_score) return null;
  return attempt.score / attempt.max_score * 100;
}

type SortKey = "date_desc" | "date_asc" | "score_desc" | "score_asc";

const sortLabels: Record<SortKey, string> = {
  date_desc: "日期：新到舊",
  date_asc: "日期：舊到新",
  score_desc: "分數：高到低",
  score_asc: "分數：低到高",
};

function normalizeAttempt(attempt: AttemptHistoryItem): AttemptHistoryItem {
  return {
    ...attempt,
    selected_paper_kinds: attempt.selected_paper_kinds ?? [],
    selected_years: attempt.selected_years ?? [],
    selected_subjects: attempt.selected_subjects ?? [],
    selected_subsubjects: attempt.selected_subsubjects ?? [],
    source_attempt_ids: attempt.source_attempt_ids ?? [],
  };
}

export default function HistoryPage() {
  const router = useRouter();
  const [attempts, setAttempts] = useState<AttemptHistoryItem[]>([]);
  const [summaries, setSummaries] = useState<YearSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState("");
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [builderOpen, setBuilderOpen] = useState(false);
  const [modeFilter, setModeFilter] = useState<"all" | AttemptMode>("all");
  const [yearFilter, setYearFilter] = useState<number | "all">("all");
  const [paperKindFilter, setPaperKindFilter] = useState("all");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [minRate, setMinRate] = useState("");
  const [maxRate, setMaxRate] = useState("");
  const [sortKey, setSortKey] = useState<SortKey>("date_desc");
  const [reviewAttemptIds, setReviewAttemptIds] = useState<string[]>([]);
  const [includeWrong, setIncludeWrong] = useState(true);
  const [includeExamStarred, setIncludeExamStarred] = useState(false);
  const [includeReviewStarred, setIncludeReviewStarred] = useState(false);
  const [reviewTitle, setReviewTitle] = useState("");
  const [startingReview, setStartingReview] = useState(false);
  const [pendingReviewAttempt, setPendingReviewAttempt] = useState<AttemptHistoryItem | null>(null);
  const [pendingDeleteAttempt, setPendingDeleteAttempt] = useState<AttemptHistoryItem | null>(null);
  const [deletingAttempt, setDeletingAttempt] = useState(false);

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
    else setAttempts(((data ?? []) as AttemptHistoryItem[]).map(normalizeAttempt));
    setSummaries((summaryData ?? []) as YearSummary[]);
    setLoading(false);
  }

  useEffect(() => { void load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (reviewAttemptIds.length > 0) setBuilderOpen(true);
  }, [reviewAttemptIds.length]);

  const availableYears = useMemo(() => Array.from(new Set(attempts.flatMap((attempt) => attempt.exam_year_roc ? [attempt.exam_year_roc] : attempt.selected_years))).sort((a, b) => b - a), [attempts]);
  const availablePaperKinds = useMemo(() => Array.from(new Set(attempts.flatMap((attempt) => attempt.selected_paper_kinds ?? []).filter(Boolean))).sort(), [attempts]);

  const filteredAttempts = useMemo(() => {
    const min = minRate === "" ? null : Number(minRate);
    const max = maxRate === "" ? null : Number(maxRate);
    return attempts.filter((attempt) => {
      if (modeFilter !== "all" && attempt.attempt_mode !== modeFilter) return false;
      const years = attempt.exam_year_roc ? [attempt.exam_year_roc] : attempt.selected_years;
      if (yearFilter !== "all" && !years.includes(yearFilter)) return false;
      if (paperKindFilter !== "all" && !attempt.selected_paper_kinds.includes(paperKindFilter)) return false;
      if (dateFrom && attempt.exam_date < dateFrom) return false;
      if (dateTo && attempt.exam_date > dateTo) return false;
      const rate = scoreRate(attempt);
      if (min !== null && (rate === null || rate < min)) return false;
      if (max !== null && (rate === null || rate > max)) return false;
      return true;
    }).sort((left, right) => {
      const leftExamDate = new Date(`${left.exam_date}T00:00:00`).getTime();
      const rightExamDate = new Date(`${right.exam_date}T00:00:00`).getTime();
      if (sortKey === "date_asc") return leftExamDate - rightExamDate || new Date(left.started_at).getTime() - new Date(right.started_at).getTime();
      if (sortKey === "score_desc") return (scoreRate(right) ?? -1) - (scoreRate(left) ?? -1);
      if (sortKey === "score_asc") return (scoreRate(left) ?? 101) - (scoreRate(right) ?? 101);
      return rightExamDate - leftExamDate || new Date(right.started_at).getTime() - new Date(left.started_at).getTime();
    });
  }, [attempts, dateFrom, dateTo, maxRate, minRate, modeFilter, paperKindFilter, sortKey, yearFilter]);

  const completedFilteredAttempts = useMemo(() => filteredAttempts.filter((attempt) => attempt.status !== "in_progress"), [filteredAttempts]);

  const activeFilterChips = useMemo(() => {
    const chips: string[] = [];
    if (modeFilter !== "all") chips.push(`方式：${modeText(modeFilter)}`);
    if (yearFilter !== "all") chips.push(`年度：${yearFilter} 年`);
    if (paperKindFilter !== "all") chips.push(`卷種：${paperKindFilter}`);
    if (dateFrom) chips.push(`日期起：${dateFrom}`);
    if (dateTo) chips.push(`日期迄：${dateTo}`);
    if (minRate !== "") chips.push(`得分率 ≥ ${minRate}%`);
    if (maxRate !== "") chips.push(`得分率 ≤ ${maxRate}%`);
    return chips;
  }, [dateFrom, dateTo, maxRate, minRate, modeFilter, paperKindFilter, yearFilter]);

  const conditionSummary = useMemo(() => {
    const conditions: string[] = [];
    if (includeWrong) conditions.push("錯題");
    if (includeExamStarred) conditions.push("模考星號");
    if (includeReviewStarred) conditions.push("檢討星號");
    return conditions.length > 0 ? `抓題條件：${conditions.join("、")}` : "尚未勾選抓題條件";
  }, [includeExamStarred, includeReviewStarred, includeWrong]);

  function resetFilters() {
    setModeFilter("all");
    setYearFilter("all");
    setPaperKindFilter("all");
    setDateFrom("");
    setDateTo("");
    setMinRate("");
    setMaxRate("");
    setSortKey("date_desc");
  }

  function toggleReviewAttempt(attemptId: string) {
    setReviewAttemptIds((current) => current.includes(attemptId) ? current.filter((id) => id !== attemptId) : [...current, attemptId]);
  }

  function selectAllFiltered() {
    const allIds = completedFilteredAttempts.map((attempt) => attempt.id);
    const allSelected = allIds.length > 0 && allIds.every((id) => reviewAttemptIds.includes(id));
    setReviewAttemptIds(allSelected ? reviewAttemptIds.filter((id) => !allIds.includes(id)) : Array.from(new Set([...reviewAttemptIds, ...allIds])));
  }

  async function startReview() {
    if (reviewAttemptIds.length === 0) {
      setErrorMessage("請先選擇至少一回已完成的作答紀錄。");
      return;
    }
    if (!includeWrong && !includeExamStarred && !includeReviewStarred) {
      setErrorMessage("請至少勾選錯題、模考星號或檢討星號其中一項。");
      return;
    }
    setStartingReview(true);
    setErrorMessage("");
    const { data, error } = await getSupabaseBrowserClient().rpc("start_review_attempt", {
      p_source_attempt_ids: reviewAttemptIds,
      p_include_wrong: includeWrong,
      p_include_exam_starred: includeExamStarred,
      p_include_review_starred: includeReviewStarred,
      p_custom_title: reviewTitle || null,
    });
    if (error) {
      setErrorMessage(`無法建立複習組卷：${error.message}`);
      setStartingReview(false);
      return;
    }
    router.push(`/exam/${(data as StartAttemptResponse).attempt_id}`);
  }

  function openRecord(attempt: AttemptHistoryItem) {
    if (attempt.status === "in_progress") {
      router.push(`/exam/${attempt.id}`);
      return;
    }
    setPendingReviewAttempt(attempt);
  }

  function confirmOpenRecord() {
    if (!pendingReviewAttempt) return;
    const attemptId = pendingReviewAttempt.id;
    setPendingReviewAttempt(null);
    router.push(`/results/${attemptId}`);
  }

  async function confirmDeleteAttempt() {
    if (!pendingDeleteAttempt || deletingAttempt) return;
    setDeletingAttempt(true);
    setErrorMessage("");
    const deletedId = pendingDeleteAttempt.id;
    const { error } = await getSupabaseBrowserClient().rpc("delete_my_attempt", { p_attempt_id: deletedId });
    if (error) {
      setErrorMessage(`刪除失敗：${error.message}`);
      setDeletingAttempt(false);
      return;
    }
    setAttempts((current) => current.filter((attempt) => attempt.id !== deletedId));
    setReviewAttemptIds((current) => current.filter((id) => id !== deletedId));
    setPendingDeleteAttempt(null);
    setDeletingAttempt(false);
    const { data: summaryData } = await getSupabaseBrowserClient().rpc("list_my_year_summaries");
    setSummaries((summaryData ?? []) as YearSummary[]);
  }

  return <section className="container page-section">
    <div className="eyebrow">作答回合</div>
    <h1>歷史紀錄</h1>
    <p className="muted">每一筆代表一次完整作答回合。可依卷種、模考日期與得分率排序篩選，再挑選回合建立複習組卷。</p>

    {summaries.some((summary) => summary.is_complete) && <div className="year-summary-grid">
      {summaries.filter((summary) => summary.is_complete).map((summary) => <article className="year-summary-card" key={summary.exam_year_roc}><span>{summary.exam_year_roc} 年四卷完成</span><strong>{summary.total_score} / {summary.max_score}</strong><div><span>司法官 {summary.judicial_cutoff ?? "—"}</span><span>律師 {summary.lawyer_cutoff ?? "—"}</span></div></article>)}
    </div>}

    <section className="result-collapsible history-filter-collapsible">
      <button
        type="button"
        className="result-collapsible-summary"
        aria-expanded={filtersOpen}
        aria-controls="history-filter-body"
        onClick={() => setFiltersOpen((value) => !value)}
      >
        <span className="result-collapsible-title-stack">
          <span className="result-collapsible-eyebrow">篩選與排序</span>
          <strong className="result-collapsible-title">{activeFilterChips.length > 0 ? `已套用 ${activeFilterChips.length} 個條件` : "未套用篩選條件"}</strong>
          <small>顯示 {filteredAttempts.length} / {attempts.length} 回合・排序：{sortLabels[sortKey]}</small>
        </span>
        <span className="result-collapsible-action">
          {filtersOpen ? "收合" : "展開"}
          <span className={`result-collapsible-chevron ${filtersOpen ? "open" : ""}`} aria-hidden="true">⌄</span>
        </span>
      </button>
      {activeFilterChips.length > 0 && <div className="history-filter-chips">
        {activeFilterChips.map((chip) => <span key={chip}>{chip}</span>)}
        <button type="button" className="text-button" onClick={resetFilters}>清除全部篩選</button>
      </div>}
      {filtersOpen && <div className="result-collapsible-body" id="history-filter-body">
        <div className="history-toolbar history-toolbar-v31">
          <label><span>方式</span><select value={modeFilter} onChange={(event) => setModeFilter(event.target.value as "all" | AttemptMode)}><option value="all">全部</option><option value="official_paper">年度卷</option><option value="subject_pool">自組模考</option><option value="wrong_review">複習組卷</option></select></label>
          <label><span>年度</span><select value={yearFilter} onChange={(event) => setYearFilter(event.target.value === "all" ? "all" : Number(event.target.value))}><option value="all">全部</option>{availableYears.map((year) => <option key={year} value={year}>{year} 年</option>)}</select></label>
          <label><span>卷種</span><select value={paperKindFilter} onChange={(event) => setPaperKindFilter(event.target.value)}><option value="all">全部</option>{availablePaperKinds.map((kind) => <option key={kind} value={kind}>{kind}</option>)}</select></label>
          <label><span>模考日期起</span><input type="date" value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} /></label>
          <label><span>模考日期迄</span><input type="date" value={dateTo} onChange={(event) => setDateTo(event.target.value)} /></label>
          <label><span>最低得分率</span><input type="number" min="0" max="100" placeholder="0" value={minRate} onChange={(event) => setMinRate(event.target.value)} /></label>
          <label><span>最高得分率</span><input type="number" min="0" max="100" placeholder="100" value={maxRate} onChange={(event) => setMaxRate(event.target.value)} /></label>
          <label><span>排序</span><select value={sortKey} onChange={(event) => setSortKey(event.target.value as SortKey)}><option value="date_desc">日期：新到舊</option><option value="date_asc">日期：舊到新</option><option value="score_desc">分數：高到低</option><option value="score_asc">分數：低到高</option></select></label>
        </div>
        <div className="history-filter-footer">
          <span>符合條件 {filteredAttempts.length} 回合（其中已交卷 {completedFilteredAttempts.length} 回）</span>
          <button type="button" className="button secondary compact" onClick={resetFilters}>回到預設</button>
        </div>
      </div>}
    </section>

    <section className="result-collapsible review-builder-collapsible">
      <button
        type="button"
        className="result-collapsible-summary"
        aria-expanded={builderOpen}
        aria-controls="review-builder-body"
        onClick={() => setBuilderOpen((value) => !value)}
      >
        <span className="result-collapsible-title-stack">
          <span className="result-collapsible-eyebrow">複習組卷</span>
          <strong className="result-collapsible-title">{reviewAttemptIds.length > 0 ? `已選 ${reviewAttemptIds.length} 回作答紀錄` : "從指定回合抓題"}</strong>
          <small>{conditionSummary}・條件採聯集，重複題只出現一次</small>
        </span>
        <span className="result-collapsible-action">
          {builderOpen ? "收合" : "展開"}
          <span className={`result-collapsible-chevron ${builderOpen ? "open" : ""}`} aria-hidden="true">⌄</span>
        </span>
      </button>
      <div className="review-builder-quick-row">
        <button type="button" className="button secondary compact" onClick={selectAllFiltered}>{completedFilteredAttempts.length > 0 && completedFilteredAttempts.every((attempt) => reviewAttemptIds.includes(attempt.id)) ? "取消目前全部" : "選取目前篩選結果"}</button>
        {reviewAttemptIds.length > 0 && <button type="button" className="text-button" onClick={() => setReviewAttemptIds([])}>清除已選回合</button>}
      </div>
      {builderOpen && <div className="result-collapsible-body" id="review-builder-body">
        <div className="review-condition-row">
          <label><input type="checkbox" checked={includeWrong} onChange={(event) => setIncludeWrong(event.target.checked)} />錯題</label>
          <label><input type="checkbox" checked={includeExamStarred} onChange={(event) => setIncludeExamStarred(event.target.checked)} />模考星號</label>
          <label><input type="checkbox" checked={includeReviewStarred} onChange={(event) => setIncludeReviewStarred(event.target.checked)} />檢討星號</label>
          <label className="review-title-input"><span>名稱（選填）</span><input value={reviewTitle} onChange={(event) => setReviewTitle(event.target.value)} placeholder="預設依勾選條件命名" /></label>
          <button type="button" className="button primary" disabled={startingReview || reviewAttemptIds.length === 0} onClick={() => void startReview()}>{startingReview ? "建立中…" : `建立複習組卷（${reviewAttemptIds.length} 回）`}</button>
        </div>
      </div>}
    </section>

    {loading && <p className="muted">正在讀取紀錄…</p>}
    {errorMessage && <p className="error-message">{errorMessage}</p>}

    {!loading && filteredAttempts.length === 0 ? <div className="empty-state"><h2>目前沒有符合條件的紀錄</h2><p>調整篩選或開始一份新測驗。</p><Link className="button primary" href="/practice">選擇試卷</Link></div> : <div className="history-list">
      {filteredAttempts.map((attempt) => {
        const isLive = attempt.status === "in_progress";
        const wrongCount = attempt.correct_count === null || attempt.unanswered_count === null ? null : attempt.question_count - attempt.correct_count - attempt.unanswered_count;
        const rate = scoreRate(attempt);
        return <article className="history-card history-card-v31" key={attempt.id}>
          <label className={`attempt-select ${isLive ? "disabled" : ""}`} title={isLive ? "作答中的回合不能作為複習來源" : "選為複習來源"}>
            <input type="checkbox" disabled={isLive} checked={reviewAttemptIds.includes(attempt.id)} onChange={() => toggleReviewAttempt(attempt.id)} />
          </label>
          <div className="history-card-main">
            <div className="history-card-labels"><span className={`status-pill ${attempt.status}`}>{statusText(attempt.status)}</span><span className="mode-pill">{modeText(attempt.attempt_mode)}</span>{attempt.selected_paper_kinds.map((kind) => <span className="paper-kind-pill" key={kind}>{kind}</span>)}</div>
            <h2>{attempt.title}</h2>
            <p>{attempt.selected_subjects.length ? attempt.selected_subjects.join("、") : attempt.paper_title ?? ""}</p>
            <div className="history-annotation-counts"><span>模考星號 {attempt.exam_star_count}</span><span>檢討星號 {attempt.review_star_count}</span>{attempt.selection_strategy === "recent_10_wrong_priority" && <span>近 10 回錯題優先</span>}</div>
          </div>
          <div className="history-stats">
            <span>模考日期 {new Date(`${attempt.exam_date}T00:00:00`).toLocaleDateString("zh-TW")}</span>
            <span>開始 {new Date(attempt.started_at).toLocaleString("zh-TW")}</span>
            <span>{attempt.is_timed ? `設定 ${attempt.duration_minutes} 分鐘` : "不計時"} · 實際 {formatDuration(attempt.elapsed_seconds)}</span>
            {wrongCount !== null && <span>未滿分 {wrongCount} · 未答 {attempt.unanswered_count}</span>}
            <strong>{attempt.score === null ? "—" : `${attempt.score} / ${attempt.max_score}`}</strong>
            {rate !== null && <span>得分率 {rate.toFixed(1)}%</span>}
            <div className="history-card-actions"><button type="button" className="button secondary compact" onClick={() => openRecord(attempt)}>{isLive ? "繼續作答" : "查看作答紀錄"}</button><button type="button" className="text-button danger" onClick={() => setPendingDeleteAttempt(attempt)}>刪除此回合</button></div>
          </div>
        </article>;
      })}
    </div>}



    {pendingDeleteAttempt && <div className="modal-backdrop" role="presentation" onMouseDown={() => !deletingAttempt && setPendingDeleteAttempt(null)}>
      <div className="warning-modal danger-modal" role="dialog" aria-modal="true" aria-labelledby="delete-warning-title" onMouseDown={(event) => event.stopPropagation()}>
        <div className="warning-icon danger">!</div>
        <h2 id="delete-warning-title">永久刪除這回作答紀錄？</h2>
        <p>刪除後無法復原。該回合的答案、作答時間、模考星號、模考筆記、錯因與改答案紀錄都會一併刪除；受影響題目的間隔複習排程會依剩餘紀錄重新計算。</p>
        <div className="warning-attempt-summary"><strong>{pendingDeleteAttempt.title}</strong><span>{new Date(pendingDeleteAttempt.started_at).toLocaleString("zh-TW")}</span></div>
        <div className="modal-actions"><button type="button" className="button secondary" disabled={deletingAttempt} onClick={() => setPendingDeleteAttempt(null)}>取消</button><button type="button" className="button danger-button" disabled={deletingAttempt} onClick={() => void confirmDeleteAttempt()}>{deletingAttempt ? "刪除中…" : "確認永久刪除"}</button></div>
      </div>
    </div>}

    {pendingReviewAttempt && <div className="modal-backdrop" role="presentation" onMouseDown={() => setPendingReviewAttempt(null)}>
      <div className="warning-modal" role="dialog" aria-modal="true" aria-labelledby="review-warning-title" onMouseDown={(event) => event.stopPropagation()}>
        <div className="warning-icon">!</div>
        <h2 id="review-warning-title">即將查看完整作答紀錄</h2>
        <p>這會顯示該回合的完整題目、所有選項、你的答案與正確答案。建議確認已完成本次作答，再進入檢討。</p>
        <div className="warning-attempt-summary"><strong>{pendingReviewAttempt.title}</strong><span>{new Date(pendingReviewAttempt.started_at).toLocaleString("zh-TW")}</span></div>
        <div className="modal-actions"><button type="button" className="button secondary" onClick={() => setPendingReviewAttempt(null)}>取消</button><button type="button" className="button primary" onClick={confirmOpenRecord}>確認查看</button></div>
      </div>
    </div>}
  </section>;
}
