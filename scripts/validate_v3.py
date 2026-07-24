"""Offline release gate for Justitia's playground v3.0.0.

Validates the 105-114 corpus, subject mapping, old-format multiple-choice
questions, scoring totals, official corrections, and generated SQL artifacts.
"""
from __future__ import annotations

from pathlib import Path
import csv
import sys

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
QUESTIONS = ROOT / "data" / "processed" / "questions_105_114.csv"
PAPERS = ROOT / "data" / "processed" / "papers_105_114.csv"
QA = ROOT / "data" / "processed" / "qa_report_105_114.csv"
CORRECTIONS = ROOT / "data" / "processed" / "official_corrections_audit_105_114.csv"
SEED = ROOT / "supabase" / "migrations" / "0008_seed_105_114.sql"
SQL_DIR = ROOT / "supabase" / "sql_editor_v3"

STANDARD_COUNTS = {
    "1301": {"刑法": 35, "刑事訴訟法": 25, "法律倫理": 15},
    "2301": {"憲法": 20, "行政法": 35, "國際公法": 10, "國際私法": 10},
    "3301": {"民法": 50, "民事訴訟法": 30},
    "4301": {"公司法": 15, "保險法": 10, "票據法": 10, "證券交易法": 10, "強制執行法": 10, "法學英文": 15},
}
OLD_COUNTS = {
    "1301": {"刑法": 32, "刑事訴訟法": 23, "法律倫理": 15},
    "2301": {"憲法": 18, "行政法": 32, "國際公法": 10, "國際私法": 10},
    "3301": {"民法": 46, "民事訴訟法": 28},
    "4301": STANDARD_COUNTS["4301"],
}
EXPECTED_PAPER_COUNTS = {
    105: {"1301": 70, "2301": 70, "3301": 74, "4301": 70},
    106: {"1301": 70, "2301": 70, "3301": 74, "4301": 70},
}
for year in range(107, 115):
    EXPECTED_PAPER_COUNTS[year] = {"1301": 75, "2301": 75, "3301": 80, "4301": 70}


def fail(message: str) -> None:
    raise AssertionError(message)


def normalize_bool(series: pd.Series) -> pd.Series:
    return series.astype(str).str.lower().isin({"true", "1", "yes"})


def main() -> None:
    questions = pd.read_csv(QUESTIONS, dtype=str).fillna("")
    papers = pd.read_csv(PAPERS, dtype=str).fillna("")
    qa = pd.read_csv(QA, dtype=str).fillna("")
    corrections = pd.read_csv(CORRECTIONS, dtype=str).fillna("")

    if len(papers) != 40 or papers["paper_id"].nunique() != 40:
        fail(f"Expected 40 papers, got {len(papers)} rows / {papers['paper_id'].nunique()} unique")
    if len(questions) != 2968 or questions["question_id"].nunique() != 2968:
        fail(f"Expected 2,968 unique questions, got {len(questions)} rows / {questions['question_id'].nunique()} unique")

    years = set(questions["exam_year_roc"].astype(int))
    if years != set(range(105, 115)):
        fail(f"Year coverage mismatch: {sorted(years)}")

    required = [
        "question_text", "option_a", "option_b", "option_c", "option_d",
        "correct_answer", "accepted_answers", "subject_primary", "question_type",
        "question_points", "source_question_url", "source_answer_url",
    ]
    for column in required:
        if (questions[column].str.strip() == "").any():
            fail(f"Blank required values in {column}")

    if (questions["subject_primary"] == "未分類").any():
        fail("Unclassified primary subjects remain")

    for (year_raw, code_raw), group in questions.groupby(["exam_year_roc", "paper_code"]):
        year = int(year_raw)
        code = str(code_raw)
        expected_count = EXPECTED_PAPER_COUNTS[year][code]
        if len(group) != expected_count:
            fail(f"{year}-{code}: expected {expected_count} questions, got {len(group)}")
        actual_subjects = group.groupby("subject_primary").size().to_dict()
        expected_subjects = OLD_COUNTS[code] if year in {105, 106} else STANDARD_COUNTS[code]
        if actual_subjects != expected_subjects:
            fail(f"{year}-{code}: subject mapping mismatch {actual_subjects}; expected {expected_subjects}")

    civil_splits = {
        105: {"財產法": 37, "親屬繼承": 9},
        106: {"財產法": 34, "親屬繼承": 12},
        111: {"財產法": 34, "親屬繼承": 16},
    }
    for year in range(105, 115):
        civil = questions[(questions["exam_year_roc"].astype(int) == year) & (questions["paper_code"] == "3301") & (questions["subject_primary"] == "民法")]
        actual = civil.groupby("subsubject_primary").size().to_dict()
        expected = civil_splits.get(year, {"財產法": 35, "親屬繼承": 15})
        if actual != expected:
            fail(f"{year} civil subsubject split mismatch: {actual}; expected {expected}")

    type_counts = questions["question_type"].value_counts().to_dict()
    if type_counts != {"single_choice": 2904, "multiple_choice": 64}:
        fail(f"Question type counts mismatch: {type_counts}")

    multiple = questions[questions["question_type"] == "multiple_choice"]
    if set(multiple["exam_year_roc"].astype(int)) != {105, 106}:
        fail("Multiple-choice questions must occur only in ROC 105-106")
    if (multiple["option_e"].str.strip() == "").any():
        fail("Multiple-choice questions with missing option E")
    if (multiple["question_points"].astype(float) != 3.0).any():
        fail("Old-format multiple-choice questions must be worth 3 points")

    single = questions[questions["question_type"] == "single_choice"]
    if (single["question_points"].astype(float) != 2.0).any():
        fail("Single-choice questions must be worth 2 points")

    for year, group in questions.groupby(questions["exam_year_roc"].astype(int)):
        by_paper = group.groupby("paper_code")["question_points"].apply(lambda s: pd.to_numeric(s).sum()).to_dict()
        expected_points = {"1301": 150.0, "2301": 150.0, "3301": 160.0, "4301": 140.0}
        if by_paper != expected_points:
            fail(f"{year} paper score totals mismatch: {by_paper}")
        if abs(pd.to_numeric(group["question_points"]).sum() - 600.0) > 1e-9:
            fail(f"{year} total score is not 600")

    bonus_mask = normalize_bool(questions["is_bonus"])
    if int(bonus_mask.sum()) != 3:
        fail(f"Expected 3 bonus questions, got {int(bonus_mask.sum())}")
    if int((questions["official_answer_status"] != "official_standard").sum()) != 15:
        fail("Expected 15 official correction/bonus rows")
    if len(corrections) != 15:
        fail(f"Correction audit should contain 15 rows, got {len(corrections)}")

    correction = questions.loc[questions["question_id"] == "111-2301-050"]
    if len(correction) != 1:
        fail("111-2301-050 missing")
    row = correction.iloc[0]
    if row["accepted_answers"] != "A|B" or row["official_answer_status"] != "corrected_multiple":
        fail("111-2301-050 must accept A or B")

    if len(qa) != 40 or set(qa["status"]) != {"pass"}:
        fail("QA report must contain 40 passing papers")

    if not SEED.exists() or SEED.stat().st_size < 1_000_000:
        fail("Full 105-114 seed is missing or unexpectedly small")
    seed_text = SEED.read_text(encoding="utf-8")
    if "111-2301-050" not in seed_text or "array['A','B']::text[]" not in seed_text:
        fail("Seed does not include the 111 Q50 A/B correction")

    expected_sql = [
        "00_v3_schema_and_rpc.sql", "01_exam_papers.sql", "23_cutoffs_105_114.sql", "99_verify_v3.sql"
    ] + [f"{index:02d}_questions.sql" for index in range(2, 16)] + [f"{index:02d}_answers.sql" for index in range(16, 23)]
    missing_sql = [name for name in expected_sql if not (SQL_DIR / name).exists()]
    if missing_sql:
        fail(f"Missing SQL Editor chunks: {missing_sql}")

    audit = (
        questions.groupby(
            ["exam_year_roc", "paper_code", "paper_title", "subject_primary", "subsubject_primary", "question_type"],
            dropna=False,
        )
        .size()
        .reset_index(name="question_count")
        .sort_values(["exam_year_roc", "paper_code", "subject_primary", "subsubject_primary", "question_type"])
    )
    audit.to_csv(
        ROOT / "data" / "processed" / "subject_mapping_audit_v3.csv",
        index=False,
        encoding="utf-8-sig",
        quoting=csv.QUOTE_MINIMAL,
    )

    print("PASS: v3.0.0 release gate")
    print("  papers=40 questions=2968 single=2904 multiple=64")
    print("  years=105-114 points=600/year corrections=15 bonus=3")
    print("  subject mappings, civil splits, SQL chunks, and 111 Q50 correction verified")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
