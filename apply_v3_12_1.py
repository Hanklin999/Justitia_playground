#!/usr/bin/env python3
# Apply Justitia's playground v3.12.1 to the current repository.
# Run from the repository root: python apply_v3_12_1.py
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

VERSION = "3.12.1"
UPDATED_AT = "2026/07/25 12:34:33 (UTC+8)"
MARKER = "/* v3.12.1: third-party external explanations */"


def fail(message: str) -> None:
    raise RuntimeError(message)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        fail(f"{label}: expected source block not found; repository may differ from v3.12.0")
    return text.replace(old, new, 1)


def copy_file(src_root: Path, repo: Path, relative: str) -> None:
    src = src_root / relative
    dest = repo / relative
    if src.resolve() == dest.resolve():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)


def patch_home(repo: Path) -> None:
    path = repo / "app/page.tsx"
    text = path.read_text(encoding="utf-8")
    old = '''      <div className="eyebrow">ROC 105–114</div>\n      <h1>Justitia&apos;s playground</h1>\n      <p className="lead">司律陪考資料庫</p>'''
    new = '''      <div className="eyebrow">105-114 司律一試備考工具</div>\n      <h1>Justitia&apos;s playground</h1>\n      <p className="lead">司律陪考資料庫 | 攻克國考有如神助</p>\n      <p className="release-meta">v.3.12.1，last updated 2026/07/25 12:34:33 (UTC+8)</p>'''
    path.write_text(replace_once(text, old, new, str(path)), encoding="utf-8")


def patch_result_page(repo: Path) -> None:
    path = repo / "app/results/[attemptId]/page.tsx"
    text = path.read_text(encoding="utf-8")

    old = 'type ResultFilter = "all" | "wrong" | "unanswered" | "correct" | "exam_starred" | "review_starred";\n'
    new = old + '''type ExternalExplanationLink = {\n  link_id: string;\n  question_id: string;\n  provider_name: string;\n  external_url: string;\n  coverage_year: number;\n  paper_type: "civil" | "criminal" | "public" | "commercial";\n  question_start: number;\n  question_end: number;\n  last_verified_at: string;\n  link_status: "active" | "login_required";\n};\nconst paperTypeLabels: Record<ExternalExplanationLink["paper_type"], string> = { civil: "民事法", criminal: "刑事法", public: "公法", commercial: "商事法" };\n'''
    text = replace_once(text, old, new, str(path))

    old = '  const [yearSummaries, setYearSummaries] = useState<YearSummary[]>([]);\n'
    new = old + '  const [externalLinks, setExternalLinks] = useState<Record<string, ExternalExplanationLink>>({});\n'
    text = replace_once(text, old, new, str(path))

    old = '''    const [{ data, error }, { data: summaryData }] = await Promise.all([\n      supabase.rpc("get_attempt_result", { p_attempt_id: attemptId }),\n      supabase.rpc("list_my_year_summaries"),\n    ]);'''
    new = '''    const [{ data, error }, { data: summaryData }, { data: externalData, error: externalError }] = await Promise.all([\n      supabase.rpc("get_attempt_result", { p_attempt_id: attemptId }),\n      supabase.rpc("list_my_year_summaries"),\n      supabase.rpc("list_attempt_external_explanations", { p_attempt_id: attemptId }),\n    ]);'''
    text = replace_once(text, old, new, str(path))

    old = '    setYearSummaries((summaryData ?? []) as YearSummary[]);\n'
    new = '''    setYearSummaries((summaryData ?? []) as YearSummary[]);\n    if (externalError) {\n      console.error("External explanation links are unavailable", externalError);\n      setExternalLinks({});\n    } else {\n      const rows = (externalData ?? []) as ExternalExplanationLink[];\n      setExternalLinks(Object.fromEntries(rows.map((row) => [row.question_id, row])));\n    }\n'''
    text = replace_once(text, old, new, str(path))

    old = '      const secondary = secondaryReasons[question.question_id] ?? [];\n'
    new = old + '      const externalLink = externalLinks[question.question_id];\n'
    text = replace_once(text, old, new, str(path))

    anchor = '        {!question.is_correct && <section className="error-diagnosis-card">\n'
    block = '''        {externalLink && <section className="external-reference-card" aria-label={`第 ${question.display_order} 題第三方外部參考`}>\n          <div className="external-reference-kicker">第三方外部參考</div>\n          <strong>來源：{externalLink.provider_name}</strong>\n          <p>外部詳解涵蓋該卷第 {externalLink.question_start}～{externalLink.question_end} 題，開啟後請找到第 {question.question_number} 題。</p>\n          <a\n            className="external-reference-link"\n            href={externalLink.external_url}\n            target="_blank"\n            rel="noopener noreferrer"\n            referrerPolicy="no-referrer"\n          >\n            {externalLink.provider_name}｜{externalLink.coverage_year} 年{paperTypeLabels[externalLink.paper_type]}第 {externalLink.question_start}～{externalLink.question_end} 題詳解，前往 Facebook 查看\n          </a>\n          {externalLink.link_status === "login_required" && <span className="external-reference-status">Facebook 可能要求登入。</span>}\n          <small>此連結為外部第三方內容，解析著作權及內容責任歸原發布者所有；本平台未重製或修改其內容。</small>\n        </section>}\n'''
    text = replace_once(text, anchor, block + anchor, str(path))
    path.write_text(text, encoding="utf-8")


def patch_css(repo: Path) -> None:
    path = repo / "app/globals.css"
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return
    css = r'''

/* v3.12.1: third-party external explanations */
.release-meta { margin: -8px 0 0; color: var(--muted); font-size: 12px; line-height: 1.6; }
.external-reference-card { display: grid; gap: 8px; margin-top: 16px; padding: 15px; border: 1px solid var(--line); border-radius: 13px; background: var(--blue-050); }
.external-reference-kicker { color: var(--blue-700); font-size: 12px; font-weight: 800; letter-spacing: .04em; }
.external-reference-card > strong { color: var(--blue-950); }
.external-reference-card p { margin: 0; color: var(--text); line-height: 1.65; }
.external-reference-link { display: inline-flex; width: fit-content; max-width: 100%; align-items: center; gap: 6px; color: var(--blue-700); font-weight: 800; line-height: 1.6; overflow-wrap: anywhere; text-decoration: underline; text-underline-offset: 3px; touch-action: manipulation; }
.external-reference-link::after { content: "↗"; flex: 0 0 auto; }
.external-reference-link:focus-visible { outline: 3px solid rgba(31, 93, 168, .2); outline-offset: 3px; border-radius: 4px; }
.external-reference-status { width: fit-content; border-radius: 999px; padding: 4px 8px; background: var(--amber-100); color: var(--amber-700); font-size: 12px; font-weight: 700; }
.external-reference-card small { color: var(--muted); line-height: 1.55; }
@media (max-width: 700px) {
  .external-reference-link { width: 100%; justify-content: space-between; padding: 10px 0; }
}
'''
    path.write_text(text.rstrip() + css + "\n", encoding="utf-8")


def patch_versions(repo: Path) -> None:
    package_path = repo / "package.json"
    package = json.loads(package_path.read_text(encoding="utf-8"))
    package["version"] = VERSION
    package_path.write_text(json.dumps(package, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lock_path = repo / "package-lock.json"
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = VERSION
    if "" in lock.get("packages", {}):
        lock["packages"][""]["version"] = VERSION
    lock_path.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def patch_readme(repo: Path) -> None:
    path = repo / "README.md"
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")
    text = text.replace("# Justitia's playground v3.12.0", "# Justitia's playground v3.12.1", 1)
    marker = "## v3.12.0 重點"
    section = '''## v3.12.1 重點\n\n- 首頁更新產品小標、副標與版本時間。\n- 110–113 年檢討題目依年度、卷別與原始題號顯示全人法學中心第三方外部參考。\n- 僅提供新分頁連結與來源聲明；不嵌入、抓取、OCR、摘要或修改第三方內容。\n- 外部網址、驗證時間與狀態由 Supabase 管理，更新網址不需重新部署。\n\n'''
    if section not in text and marker in text:
        text = text.replace(marker, section + marker, 1)
    old_upgrade = '''既有 v3.1.0 資料庫依序執行：\n\n1. `supabase/sql_editor_v3/26_v3_12_pacing_learning.sql`\n2. `supabase/sql_editor_v3/27_verify_v3_12.sql`\n\n不需要重跑題庫 seed。詳細說明：`supabase/V3_12_UPGRADE.md`。'''
    new_upgrade = '''既有 v3.12.0 資料庫依序執行：\n\n1. `supabase/sql_editor_v3/28_v3_12_1_external_explanations.sql`\n2. `supabase/sql_editor_v3/29_verify_v3_12_1.sql`\n\n若從 v3.1.0 升級，請先完成 `26`、`27`，再執行 `28`、`29`。不需要重跑題庫 seed。詳細說明：`supabase/V3_12_1_UPGRADE.md`。'''
    if old_upgrade in text:
        text = text.replace(old_upgrade, new_upgrade, 1)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    bundle = Path(__file__).resolve().parent
    required = [repo / "app/page.tsx", repo / "app/results/[attemptId]/page.tsx", repo / "app/globals.css", repo / "package.json", repo / "package-lock.json"]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        fail("Run this script from the Justitia_playground repository root. Missing: " + ", ".join(missing))

    patch_home(repo)
    patch_result_page(repo)
    patch_css(repo)
    patch_versions(repo)
    patch_readme(repo)

    for relative in [
        "supabase/migrations/0012_v3_12_1_external_explanations.sql",
        "supabase/sql_editor_v3/28_v3_12_1_external_explanations.sql",
        "supabase/sql_editor_v3/29_verify_v3_12_1.sql",
        "supabase/V3_12_1_UPGRADE.md",
        "docs/EXTERNAL_REFERENCE_POLICY.md",
        "RELEASE_NOTES_v3.12.1.md",
    ]:
        copy_file(bundle, repo, relative)

    print(f"Applied Justitia's playground v{VERSION}")
    print(f"Homepage timestamp: {UPDATED_AT}")
    print("Next: run Supabase SQL 28, then 29; run npm.cmd run typecheck and npm.cmd run build.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
