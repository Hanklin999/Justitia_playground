"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import CollapsiblePanel from "@/components/collapsible-panel";
import type { ExamPaper, StartAttemptResponse, SubjectConfig } from "@/lib/types";

type PracticeMode = "year" | "subject";

const presets: { label: string; description: string; subjects: string[] }[] = [
  { label: "公法卷", description: "憲法＋行政法＋國際公法＋國際私法", subjects: ["憲法", "行政法", "國際公法", "國際私法"] },
  { label: "民事法卷", description: "民法＋民事訴訟法", subjects: ["民法", "民事訴訟法"] },
  { label: "商事法卷", description: "公司法、保險法、票據法、證交法、強執與法學英文", subjects: ["公司法", "保險法", "票據法", "證券交易法", "強制執行法", "法學英文"] },
  { label: "刑事法卷", description: "刑法＋刑事訴訟法＋法律倫理", subjects: ["刑法", "刑事訴訟法", "法律倫理"] },
];

function todayLocal() {
  return new Date().toLocaleDateString("en-CA");
}

export default function PracticePage() {
  const router = useRouter();
  const [mode, setMode] = useState<PracticeMode>("year");
  const [papers, setPapers] = useState<ExamPaper[]>([]);
  const [configs, setConfigs] = useState<SubjectConfig[]>([]);
  const [loading, setLoading] = useState(true);
  const [startingKey, setStartingKey] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState("");
  const [isSignedIn, setIsSignedIn] = useState<boolean | null>(null);
  const [selectedYears, setSelectedYears] = useState<number[]>([]);
  const [selectedSubjects, setSelectedSubjects] = useState<string[]>([]);
  const [selectedSubsubjects, setSelectedSubsubjects] = useState<string[]>([]);
  const [customTitle, setCustomTitle] = useState("");
  const [titleEdited, setTitleEdited] = useState(false);
  const [examDate, setExamDate] = useState(todayLocal());
  const [targetQuestionCount, setTargetQuestionCount] = useState(0);

  useEffect(() => {
    let active = true;
    const supabase = getSupabaseBrowserClient();
    async function load() {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!active) return;
      setIsSignedIn(Boolean(sessionData.session));
      const [{ data: paperData, error: paperError }, { data: configData, error: configError }] = await Promise.all([
        supabase.from("exam_papers").select("paper_id, exam_year_roc, exam_year_ad, paper_order, paper_code, paper_group, paper_title, included_subjects, duration_minutes, question_count, points_per_question, max_score, source_question_url, is_published").eq("is_published", true).order("exam_year_roc", { ascending: false }).order("paper_order", { ascending: true }),
        supabase.from("subject_exam_config").select("config_key, subject_name, subsubject_name, paper_code, target_question_count, seconds_per_question, display_order").eq("is_active", true).order("display_order", { ascending: true }),
      ]);
      if (!active) return;
      if (paperError || configError) {
        setErrorMessage(`尚未讀取到 v3.1.0 題庫設定：${paperError?.message ?? configError?.message}`);
      } else {
        const nextPapers = (paperData ?? []) as ExamPaper[];
        setPapers(nextPapers);
        setConfigs((configData ?? []) as SubjectConfig[]);
        const allYears = Array.from(new Set(nextPapers.map((paper) => paper.exam_year_roc))).sort((a, b) => b - a);
        setSelectedYears(allYears.slice(0, 1));
      }
      setLoading(false);
    }
    void load();
    return () => { active = false; };
  }, []);

  const years = useMemo(() => Array.from(new Set(papers.map((paper) => paper.exam_year_roc))).sort((a, b) => b - a), [papers]);
  const subjectConfigs = useMemo(() => configs.filter((config) => config.subsubject_name === null), [configs]);
  const civilSubsubjects = useMemo(() => configs.filter((config) => config.subject_name === "民法" && config.subsubject_name), [configs]);

  const activeConfigs = useMemo(() => {
    const fullSubjects = subjectConfigs.filter((config) => selectedSubjects.includes(config.subject_name) && !(config.subject_name === "民法" && selectedSubsubjects.length > 0));
    const subs = civilSubsubjects.filter((config) => config.subsubject_name && selectedSubsubjects.includes(config.subsubject_name));
    return [...fullSubjects, ...subs].sort((a, b) => a.display_order - b.display_order);
  }, [civilSubsubjects, selectedSubjects, selectedSubsubjects, subjectConfigs]);

  function effectiveTargetCount(config: SubjectConfig): number {
    if (selectedYears.length !== 1) return config.target_question_count;
    const year = selectedYears[0];
    const oldFormatCounts: Record<number, Record<string, number>> = {
      105: { 憲法: 18, 行政法: 32, 國際公法: 10, 國際私法: 10, 民法: 46, "民法/財產法": 37, "民法/親屬繼承": 9, 民事訴訟法: 28, 刑法: 32, 刑事訴訟法: 23, 法律倫理: 15 },
      106: { 憲法: 18, 行政法: 32, 國際公法: 10, 國際私法: 10, 民法: 46, "民法/財產法": 34, "民法/親屬繼承": 12, 民事訴訟法: 28, 刑法: 32, 刑事訴訟法: 23, 法律倫理: 15 },
      111: { "民法/財產法": 34, "民法/親屬繼承": 16 },
    };
    return oldFormatCounts[year]?.[config.config_key] ?? config.target_question_count;
  }

  function effectiveSecondsPerQuestion(config: SubjectConfig): number {
    const sourcePapers = papers.filter((paper) => selectedYears.includes(paper.exam_year_roc) && paper.paper_code === config.paper_code);
    if (sourcePapers.length === 0) return Number(config.seconds_per_question);
    return sourcePapers.reduce((sum, paper) => sum + (paper.duration_minutes * 60) / paper.question_count, 0) / sourcePapers.length;
  }

  const estimatedQuestions = activeConfigs.reduce((sum, config) => sum + effectiveTargetCount(config), 0);
  const estimatedSeconds = activeConfigs.reduce((sum, config) => sum + effectiveTargetCount(config) * effectiveSecondsPerQuestion(config), 0);
  const defaultTitle = activeConfigs.length ? `${activeConfigs.map((config) => config.subsubject_name ?? config.subject_name).join("＋")}｜自組測驗` : "自組測驗";
  const selectedCount = Math.max(0, targetQuestionCount || estimatedQuestions);
  const estimatedCustomMinutes = estimatedQuestions > 0 ? Math.ceil(estimatedSeconds * selectedCount / estimatedQuestions / 60) : 0;
  const usesCustomCount = selectedCount > 0 && selectedCount !== estimatedQuestions;

  useEffect(() => {
    setTargetQuestionCount(estimatedQuestions);
  }, [estimatedQuestions]);

  useEffect(() => {
    if (!titleEdited) setCustomTitle(defaultTitle);
  }, [defaultTitle, titleEdited]);

  function requireLogin(): boolean {
    if (!isSignedIn) {
      router.push("/login");
      return false;
    }
    return true;
  }

  async function startOfficialExam(paperId: string) {
    if (!requireLogin()) return;
    setStartingKey(paperId);
    setErrorMessage("");
    const { data, error } = await getSupabaseBrowserClient().rpc("start_exam_attempt", { p_paper_id: paperId });
    if (error) {
      setErrorMessage(`無法開始考試：${error.message}`);
      setStartingKey(null);
      return;
    }
    router.push(`/exam/${(data as StartAttemptResponse).attempt_id}`);
  }

  async function startSubjectExam() {
    if (!requireLogin()) return;
    if (selectedYears.length === 0 || activeConfigs.length === 0) {
      setErrorMessage("請至少選擇一個年度與一個科目。");
      return;
    }
    if (selectedCount < 1) {
      setErrorMessage("出題數量至少為 1 題。");
      return;
    }
    setStartingKey("subject");
    setErrorMessage("");
    const { data, error } = await getSupabaseBrowserClient().rpc("start_custom_subject_attempt", {
      p_years: selectedYears,
      p_subjects: selectedSubjects,
      p_subsubjects: selectedSubsubjects,
      p_target_question_count: selectedCount,
      p_custom_title: customTitle || null,
      p_exam_date: examDate,
    });
    if (error) {
      setErrorMessage(`無法建立自組測驗：${error.message}`);
      setStartingKey(null);
      return;
    }
    router.push(`/exam/${(data as StartAttemptResponse).attempt_id}`);
  }

  function toggleYear(year: number) {
    setSelectedYears((current) => current.includes(year) ? current.filter((item) => item !== year) : [...current, year].sort((a, b) => b - a));
  }

  function toggleSubject(subject: string) {
    setSelectedSubjects((current) => {
      if (current.includes(subject)) {
        if (subject === "民法") setSelectedSubsubjects([]);
        return current.filter((item) => item !== subject);
      }
      return [...current, subject];
    });
    if (subject === "民法") setSelectedSubsubjects([]);
  }

  function toggleSubsubject(subsubject: string) {
    setSelectedSubjects((current) => current.includes("民法") ? current : [...current, "民法"]);
    setSelectedSubsubjects((current) => current.includes(subsubject) ? current.filter((item) => item !== subsubject) : [...current, subsubject]);
  }

  function applyPreset(subjects: string[]) {
    setSelectedSubjects(subjects);
    setSelectedSubsubjects([]);
    setTitleEdited(false);
  }

  return <section className="container page-section">
    <div className="eyebrow">近十年司律一試題庫</div>
    <h1>選擇你的練習方式</h1>
    <p className="muted">正式年度卷保留原始題序與時長；科目模式可自訂名稱、模考日期與題數。</p>

    <div className="mode-switch" role="tablist" aria-label="刷題模式">
      <button type="button" className={mode === "year" ? "active" : ""} onClick={() => setMode("year")}>依年度</button>
      <button type="button" className={mode === "subject" ? "active" : ""} onClick={() => setMode("subject")}>依科目</button>
    </div>

    {isSignedIn === false && <div className="notice-card"><strong>開始前需要 Email 登入</strong><span>登入後才能保存答案、模考標記、檢討標記、計時與成績。</span><Link className="button primary compact" href="/login">前往登入</Link></div>}
    {errorMessage && <div className="error-card" role="alert"><strong>目前無法完成操作</strong><span>{errorMessage}</span></div>}
    {loading && <p className="muted">正在讀取題庫…</p>}

    {!loading && mode === "year" && years.map((year, yearIndex) => <CollapsiblePanel
      key={year}
      className="year-collapsible"
      eyebrow="年度正式卷"
      title={`${year} 年`}
      hint={`${papers.filter((paper) => paper.exam_year_roc === year).length} 卷・${yearIndex === 0 ? "預設展開" : "點擊展開試卷清單"}`}
      defaultOpen={yearIndex === 0}
    ><div className="paper-grid">{papers.filter((paper) => paper.exam_year_roc === year).map((paper) => <article className="paper-card" key={paper.paper_id}><div className="paper-meta">第 {paper.paper_order} 卷 · 代號 {paper.paper_code}</div><h3>{paper.paper_title}</h3><div className="paper-stats"><span>{paper.question_count} 題</span><span>{paper.duration_minutes} 分鐘</span><span>滿分 {paper.max_score}</span></div><p>{paper.included_subjects.join("、")}</p><div className="paper-actions"><a href={paper.source_question_url} target="_blank" rel="noreferrer" className="source-link">官方試題</a><button className="button primary" type="button" disabled={startingKey !== null} onClick={() => void startOfficialExam(paper.paper_id)}>{startingKey === paper.paper_id ? "建立考試中…" : "開始這一卷"}</button></div></article>)}</div></CollapsiblePanel>)}

    {!loading && mode === "subject" && <div className="subject-builder">
      <section className="builder-card"><div className="builder-step"><span>1</span><div><h2>複選年度</h2><p>題目會從所選年度混合抽樣。</p></div></div><div className="choice-chip-grid">{years.map((year) => <button key={year} type="button" className={selectedYears.includes(year) ? "choice-chip selected" : "choice-chip"} onClick={() => toggleYear(year)}>{year} 年</button>)}</div></section>

      <section className="builder-card"><div className="builder-step"><span>2</span><div><h2>快速選卷或自由選科</h2><p>完整卷還原相近題數與時長；單科按原卷每題平均時間等比例計時。</p></div></div><div className="preset-grid">{presets.map((preset) => <button key={preset.label} type="button" className="preset-card" onClick={() => applyPreset(preset.subjects)}><strong>{preset.label}</strong><span>{preset.description}</span></button>)}</div><div className="subject-chip-grid">{subjectConfigs.map((config) => <button key={config.config_key} type="button" className={selectedSubjects.includes(config.subject_name) && !(config.subject_name === "民法" && selectedSubsubjects.length > 0) ? "choice-chip selected" : "choice-chip"} onClick={() => toggleSubject(config.subject_name)}>{config.subject_name}<small>{config.target_question_count} 題</small></button>)}</div><div className="subsubject-row"><span>民法子科目：</span>{civilSubsubjects.map((config) => config.subsubject_name && <button key={config.config_key} type="button" className={selectedSubsubjects.includes(config.subsubject_name) ? "choice-chip selected" : "choice-chip"} onClick={() => toggleSubsubject(config.subsubject_name!)}>{config.subsubject_name}<small>{config.target_question_count} 題</small></button>)}</div></section>

      <section className="builder-card"><div className="builder-step"><span>3</span><div><h2>設定這回模考</h2><p>名稱與日期會顯示在歷史紀錄；題數預設為目前 scope 的標準配置。</p></div></div><div className="custom-exam-fields"><label><span>模考名稱</span><input value={customTitle} onChange={(event) => { setCustomTitle(event.target.value); setTitleEdited(true); }} placeholder={defaultTitle} /></label><label><span>模考日期</span><input type="date" value={examDate} onChange={(event) => setExamDate(event.target.value)} /></label><label><span>出題數量</span><input type="number" min="1" value={targetQuestionCount || ""} onChange={(event) => setTargetQuestionCount(Number(event.target.value))} /><small>預設 {estimatedQuestions} 題</small></label></div>{usesCustomCount && <div className="strategy-notice"><strong>近 10 回錯題優先模式</strong><span>先從最近 10 次與本次 scope 有交集的已完成作答中，隨機抽取同 scope 的答錯題；不足的題數再從 scope 內排除已選題後隨機補足。</span></div>}</section>

      <section className="builder-summary"><div><span>年度</span><strong>{selectedYears.length ? selectedYears.join("、") : "尚未選擇"}</strong></div><div><span>題數</span><strong>{selectedCount} 題</strong></div><div><span>預估時長</span><strong>{estimatedCustomMinutes} 分鐘</strong></div><div><span>抽題方式</span><strong>{usesCustomCount ? "近 10 回錯題優先" : "標準配置"}</strong></div><button type="button" className="button primary" disabled={startingKey !== null || selectedCount === 0 || selectedYears.length === 0} onClick={() => void startSubjectExam()}>{startingKey === "subject" ? "抽題中…" : "建立自組模考"}</button></section>
      <p className="fine-print">科目模式為自組測驗，不等同正式年度模擬。若指定題數超過可用題池，系統會自動縮減為可用題數。</p>
    </div>}
  </section>;
}
