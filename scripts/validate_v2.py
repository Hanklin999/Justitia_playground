"""Offline consistency checks for the V2 corpus and generated SQL."""
from __future__ import annotations

from pathlib import Path
import csv
import re
import sys
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
QUESTIONS = ROOT / "data" / "processed" / "questions_110_114.csv"
PAPERS = ROOT / "data" / "processed" / "papers_110_114.csv"
QA = ROOT / "data" / "processed" / "qa_report.csv"
SEED = ROOT / "supabase" / "migrations" / "0005_seed_110_114.sql"

EXPECTED_PAPER_COUNTS = {"2301": 75, "3301": 80, "4301": 70, "1301": 75}
EXPECTED_SUBJECT_COUNTS = {
    "2301": {"憲法": 20, "行政法": 35, "國際公法": 10, "國際私法": 10},
    "3301": {"民法": 50, "民事訴訟法": 30},
    "4301": {"公司法": 15, "保險法": 10, "票據法": 10, "證券交易法": 10, "強制執行法": 10, "法學英文": 15},
    "1301": {"刑法": 35, "刑事訴訟法": 25, "法律倫理": 15},
}


def fail(message: str) -> None:
    raise AssertionError(message)


def main() -> None:
    questions = pd.read_csv(QUESTIONS, dtype=str).fillna("")
    papers = pd.read_csv(PAPERS, dtype=str).fillna("")
    qa = pd.read_csv(QA, dtype=str).fillna("")

    if len(papers) != 20 or papers["paper_id"].nunique() != 20:
        fail(f"Expected 20 papers, got {len(papers)} rows / {papers['paper_id'].nunique()} unique")
    if len(questions) != 1500 or questions["question_id"].nunique() != 1500:
        fail(f"Expected 1,500 unique questions, got {len(questions)} rows")
    if set(questions["exam_year_roc"].astype(int)) != {110, 111, 112, 113, 114}:
        fail("Year coverage is not ROC 110-114")

    required = ["question_text", "option_a", "option_b", "option_c", "option_d", "correct_answer", "accepted_answers", "subject_primary"]
    for column in required:
        if (questions[column].str.strip() == "").any():
            fail(f"Blank required values in {column}")

    if (questions["subject_primary"] == "未分類").any():
        fail("Unclassified subject rows remain")

    for (year, code), group in questions.groupby(["exam_year_roc", "paper_code"]):
        expected = EXPECTED_PAPER_COUNTS[code]
        if len(group) != expected:
            fail(f"{year}-{code}: expected {expected}, got {len(group)}")
        actual_subjects = group.groupby("subject_primary").size().to_dict()
        if actual_subjects != EXPECTED_SUBJECT_COUNTS[code]:
            fail(f"{year}-{code}: subject mapping mismatch {actual_subjects}")

    civil_111 = questions[(questions["paper_id"] == "111-3301") & (questions["subject_primary"] == "民法")]
    split = civil_111.groupby("subsubject_primary").size().to_dict()
    if split != {"親屬繼承": 16, "財產法": 34}:
        fail(f"111 civil subsubject split mismatch: {split}")

    correction = questions.loc[questions["question_id"] == "111-2301-050"]
    if len(correction) != 1:
        fail("111-2301-050 missing")
    row = correction.iloc[0]
    if row["accepted_answers"] != "A|B" or row["official_answer_status"] != "corrected_multiple":
        fail("111-2301-050 correction is not A|B / corrected_multiple")

    if set(qa["status"]) != {"pass"} or len(qa) != 20:
        fail("QA report does not contain 20 passing papers")

    seed = SEED.read_text(encoding="utf-8")
    if "('111-2301-050','A','A',array['A','B']::text[],'corrected_multiple'" not in seed:
        fail("Generated seed does not contain the multi-answer correction")

    audit = (
        questions.groupby(["exam_year_roc", "paper_code", "paper_title", "subject_primary", "subsubject_primary"], dropna=False)
        .size().reset_index(name="question_count")
        .sort_values(["exam_year_roc", "paper_code", "subject_primary", "subsubject_primary"])
    )
    audit.to_csv(ROOT / "data" / "processed" / "subject_mapping_audit.csv", index=False, encoding="utf-8-sig", quoting=csv.QUOTE_MINIMAL)
    print("PASS: 20 papers / 1,500 questions / mappings / 111 Q50 correction")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
