"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase-browser";
import type { ExamPaper, StartAttemptResponse, SubjectConfig } from "@/lib/types";

type PracticeMode = "year" | "subject";

const presets: { label: string; description: string; subjects: string[] }[] = [
  { label: "公法卷", description: "憲法＋行政法＋國際公法＋國際私法", subjects: ["憲法", "行政法", "國際公法", "國際私法"] },
  { label: "民事法卷", description: "民法＋民事訴訟法，完整配置為 100 分鐘", subjects: ["民法", "民事訴訟法"] },
  { label: "商事法卷", description: "公司法、保險法、票據法、證交法、強執與法學英文", subjects: ["公司法", "保險法", "票據法", "證券交易法", "強制執行法", "法學英文"] },
  { label: "刑事法卷", description: "刑法＋刑事訴訟法＋法律倫理", subjects: ["刑法", "刑事訴訟法", "法律倫理"] },
];

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

  useEffect(() => {
    let active = true;
    const supabase = getSupabaseBrowserClient();

    async function load() {
      const { data: sessionData } = await supabase.auth.getSession();
      if (!active) return;
      setIsSignedIn(Boolean(sessionData.session));

      const [{ data: paperData, error: paperError }, { data: configData, error: configError }] = await Promise.all([
        supabase
          .from("exam_papers")
          .select("paper_id, exam_year_roc, exam_year_ad, paper_order, paper_code, paper_group, paper_title, included_subjects, duration_minutes, question_count, points_per_question, max_score, source_question_url, is_published")
          .eq("is_published", true)
          .order("exam_year_roc", { ascending: false })
          .order("paper_order", { ascending: true }),
        supabase
          .from("subject_exam_config")
          .select("config_key, subject_name, subsubject_name, paper_code, target_question_count, seconds_per_question, display_order")
          .eq("is_active", true)
          .order("display_order", { ascending: true }),
      ]);

      if (!active) return;
      if (paperError || configError) {
        setErrorMessage(`尚未讀取到 V2 題庫設定：${paperError?.message ?? configError?.message}`);
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
    return () => {
      active = false;
    };
  }, []);

  const years = useMemo(
    () => Array.from(new Set(papers.map((paper) => paper.exam_year_roc))).sort((a, b) => b - a),
    [papers],
  );

  const subjectConfigs = useMemo(() => configs.filter((config) => config.subsubject_name === null), [configs]);
  const civilSubsubjects = useMemo(() => configs.filter((config) => config.subject_name === "民法" && config.subsubject_name), [configs]);

  const activeConfigs = useMemo(() => {
    const fullSubjects = subjectConfigs.filter((config) => selectedSubjects.includes(config.subject_name) && !(config.subject_name === "民法" && selectedSubsubjects.length > 0));
    const subs = civilSubsubjects.filter((config) => config.subsubject_name && selectedSubsubjects.includes(config.subsubject_name));
    return [...fullSubjects, ...subs];
  }, [civilSubsubjects, selectedSubjects, selectedSubsubjects, subjectConfigs]);

  function effectiveTargetCount(config: SubjectConfig): number {
    if (selectedYears.length === 1 && selectedYears[0] === 111) {
      if (config.config_key === "民法/財產法") return 34;
      if (config.config_key === "民法/親屬繼承") return 16;
    }
    return config.target_question_count;
  }

  const estimatedQuestions = activeConfigs.reduce((sum, config) => sum + effectiveTargetCount(config), 0);
  const estimatedSeconds = activeConfigs.reduce((sum, config) => sum + effectiveTargetCount(config) * Number(config.seconds_per_question), 0);
  const estimatedMinutes = estimatedQuestions > 0 ? Math.ceil(estimatedSeconds / 60) : 0;

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
    const supabase = getSupabaseBrowserClient();
    const { data, error } = await supabase.rpc("start_exam_attempt", { p_paper_id: paperId });
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
    setStartingKey("subject");
    setErrorMessage("");
    const supabase = getSupabaseBrowserClient();
    const { data, error } = await supabase.rpc("start_subject_attempt", {
      p_years: selectedYears,
      p_subjects: selectedSubjects,
      p_subsubjects: selectedSubsubjects,
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
  }

  return (
    <section className="container page-section">
      <div className="eyebrow">近五年司律一試題庫</div>
      <h1>選擇你的練習方式</h1>
      <p className="muted">正式年度卷保留原始題序與時長；科目模式會從所選年度題池隨機抽出對應題數。</p>

      <div className="mode-switch" role="tablist" aria-label="刷題模式">
        <button type="button" className={mode === "year" ? "active" : ""} onClick={() => setMode("year")}>依年度</button>
        <button type="button" className={mode === "subject" ? "active" : ""} onClick={() => setMode("subject")}>依科目</button>
      </div>

      {isSignedIn === false && (
        <div className="notice-card">
          <strong>開始前需要 Email 登入</strong>
          <span>登入後才能保存答案、星號、筆記、計時與成績。</span>
          <Link className="button primary compact" href="/login">前往登入</Link>
        </div>
      )}

      {errorMessage && <div className="error-card" role="alert"><strong>目前無法完成操作</strong><span>{errorMessage}</span></div>}
      {loading && <p className="muted">正在讀取題庫…</p>}

      {!loading && mode === "year" && years.map((year) => (
        <section key={year} className="year-section">
          <h2>{year} 年</h2>
          <div className="paper-grid">
            {papers.filter((paper) => paper.exam_year_roc === year).map((paper) => (
              <article className="paper-card" key={paper.paper_id}>
                <div className="paper-meta">第 {paper.paper_order} 卷 · 代號 {paper.paper_code}</div>
                <h3>{paper.paper_title}</h3>
                <div className="paper-stats"><span>{paper.question_count} 題</span><span>{paper.duration_minutes} 分鐘</span><span>滿分 {paper.max_score}</span></div>
                <p>{paper.included_subjects.join("、")}</p>
                <div className="paper-actions">
                  <a href={paper.source_question_url} target="_blank" rel="noreferrer" className="source-link">官方試題</a>
                  <button className="button primary" type="button" disabled={startingKey !== null} onClick={() => void startOfficialExam(paper.paper_id)}>
                    {startingKey === paper.paper_id ? "建立考試中…" : "開始這一卷"}
                  </button>
                </div>
              </article>
            ))}
          </div>
        </section>
      ))}

      {!loading && mode === "subject" && (
        <div className="subject-builder">
          <section className="builder-card">
            <div className="builder-step"><span>1</span><div><h2>複選年度</h2><p>題目會從所選年度混合抽樣。</p></div></div>
            <div className="choice-chip-grid">
              {years.map((year) => <button key={year} type="button" className={selectedYears.includes(year) ? "choice-chip selected" : "choice-chip"} onClick={() => toggleYear(year)}>{year} 年</button>)}
            </div>
          </section>

          <section className="builder-card">
            <div className="builder-step"><span>2</span><div><h2>快速選卷或自由選科</h2><p>完整卷會自然還原正式時長；單科則按原卷每題平均時間等比例計時。</p></div></div>
            <div className="preset-grid">
              {presets.map((preset) => (
                <button key={preset.label} type="button" className="preset-card" onClick={() => applyPreset(preset.subjects)}>
                  <strong>{preset.label}</strong><span>{preset.description}</span>
                </button>
              ))}
            </div>
            <div className="subject-chip-grid">
              {subjectConfigs.map((config) => (
                <button key={config.config_key} type="button" className={selectedSubjects.includes(config.subject_name) && !(config.subject_name === "民法" && selectedSubsubjects.length > 0) ? "choice-chip selected" : "choice-chip"} onClick={() => toggleSubject(config.subject_name)}>
                  {config.subject_name}<small>{config.target_question_count} 題</small>
                </button>
              ))}
            </div>
            <div className="subsubject-row">
              <span>民法子科目：</span>
              {civilSubsubjects.map((config) => config.subsubject_name && (
                <button key={config.config_key} type="button" className={selectedSubsubjects.includes(config.subsubject_name) ? "choice-chip selected" : "choice-chip"} onClick={() => toggleSubsubject(config.subsubject_name!)}>
                  {config.subsubject_name}<small>{config.target_question_count} 題</small>
                </button>
              ))}
            </div>
          </section>

          <section className="builder-summary">
            <div><span>年度</span><strong>{selectedYears.length ? selectedYears.join("、") : "尚未選擇"}</strong></div>
            <div><span>題數</span><strong>{estimatedQuestions} 題</strong></div>
            <div><span>預估時長</span><strong>{estimatedMinutes} 分鐘</strong></div>
            <button type="button" className="button primary" disabled={startingKey !== null || estimatedQuestions === 0 || selectedYears.length === 0} onClick={() => void startSubjectExam()}>
              {startingKey === "subject" ? "抽題中…" : "建立自組測驗"}
            </button>
          </section>
          <p className="fine-print">科目模式為自組測驗，不等同正式年度模擬。實際題數若題池不足，系統會按可用題數縮減。</p>
        </div>
      )}
    </section>
  );
}
