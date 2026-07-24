"""Extract Taiwan MOEX judicial/lawyer first-stage PDFs into reviewable CSV files.

Usage:
    python etl/extract_moex.py
    python etl/extract_moex.py --manifest etl/manifest.json --root .

The script deliberately keeps future manual-tagging columns blank. It validates
question counts, four options, and official answer counts before writing output.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import fitz  # PyMuPDF
import pdfplumber

OPTION_MARKERS = {
    "\ue18c": "A",
    "\ue18d": "B",
    "\ue18e": "C",
    "\ue18f": "D",
}
OUTPUT_COLUMNS = [
    "question_id", "exam_year_roc", "exam_year_ad", "exam_code",
    "exam_name", "exam_stage", "candidate_scope", "paper_id",
    "paper_order", "paper_code", "paper_group", "paper_title",
    "included_subjects", "duration_minutes", "expected_question_count",
    "points_per_question", "max_score", "question_number",
    "question_type", "question_text", "option_a", "option_b", "option_c",
    "option_d", "original_answer", "correct_answer", "accepted_answers", "official_answer_status", "official_notice_url",
    "source_question_url", "source_answer_url", "source_question_pdf",
    "source_answer_pdf", "source_page_start", "source_page_end",
    "extraction_status", "review_status", "subject_primary",
    "subsubject_primary", "subject_secondary", "chapter", "topic_primary", "topic_secondary",
    "law_refs", "tags", "notes",
]


class ExtractionError(RuntimeError):
    """Raised when source data fails a structural validation."""


@dataclass(frozen=True)
class QuestionBlock:
    number: int
    page_start: int
    page_end: int
    lines: list[str]


def normalize_text(value: str) -> str:
    value = value.replace("\u00a0", " ").replace("\ufeff", "")
    value = re.sub(r"[ \t]+", " ", value)
    value = re.sub(r"\s+([，。；：？！、）】])", r"\1", value)
    value = re.sub(r"([（【])\s+", r"\1", value)
    return value.strip()


def clean_pdf_line(line: str) -> str:
    line = line.replace("\u00a0", " ").strip()
    if not line:
        return ""
    if re.match(r"^代號：?\s*\d+", line) or re.match(r"^頁次：?", line):
        return ""
    if line.startswith("類") and "科：" in line:
        return ""
    if line.startswith("科") and "目：" in line:
        return ""
    if line.startswith(("考試時間：", "座號：", "※注意：")):
        return ""
    if line.startswith(("\ue129", "\ue12a", "\ue12b")):
        return ""
    if "公務人員特種考試司法官考試" in line:
        return ""
    if "專門職業及技術人員高等考試律師考試" in line:
        return ""
    if line == "第一試試題":
        return ""
    return line


def extract_question_blocks(pdf_path: Path, expected_count: int) -> list[QuestionBlock]:
    rows: list[tuple[int, str]] = []
    with fitz.open(pdf_path) as document:
        for page_number, page in enumerate(document, start=1):
            for raw_line in page.get_text("text").splitlines():
                line = clean_pdf_line(raw_line)
                if line:
                    rows.append((page_number, line))

    blocks: list[QuestionBlock] = []
    current_number: int | None = None
    current_start = 0
    current_end = 0
    current_lines: list[str] = []
    expected_number = 1

    for page_number, line in rows:
        if re.fullmatch(r"\d{1,3}", line) and int(line) == expected_number:
            if current_number is not None:
                blocks.append(QuestionBlock(current_number, current_start, current_end, current_lines))
            current_number = expected_number
            current_start = page_number
            current_end = page_number
            current_lines = []
            expected_number += 1
        elif current_number is not None:
            current_end = page_number
            current_lines.append(line)

    if current_number is not None:
        blocks.append(QuestionBlock(current_number, current_start, current_end, current_lines))

    if len(blocks) != expected_count:
        raise ExtractionError(
            f"{pdf_path}: expected {expected_count} questions, extracted {len(blocks)}"
        )
    return blocks


def split_question(block: QuestionBlock) -> dict[str, str | int]:
    text = " ".join(block.lines)
    marker_chars = list(OPTION_MARKERS)
    for index, label in enumerate("ABCD"):
        text = re.sub(rf"[（(]{label}[）)]", marker_chars[index], text)

    positions = sorted(
        (text.find(marker), marker, label)
        for marker, label in OPTION_MARKERS.items()
        if text.find(marker) >= 0
    )
    if len(positions) != 4 or [item[2] for item in positions] != list("ABCD"):
        raise ExtractionError(
            f"Question {block.number}: expected A-D markers, found {[item[2] for item in positions]}"
        )

    question_text = normalize_text(text[: positions[0][0]])
    options: dict[str, str] = {}
    for index, (position, _marker, label) in enumerate(positions):
        end = positions[index + 1][0] if index + 1 < len(positions) else len(text)
        options[label] = normalize_text(text[position + 1 : end])

    if not question_text or any(not options[label] for label in "ABCD"):
        raise ExtractionError(f"Question {block.number}: empty question text or option")

    return {
        "question_number": block.number,
        "question_text": question_text,
        "option_a": options["A"],
        "option_b": options["B"],
        "option_c": options["C"],
        "option_d": options["D"],
        "source_page_start": block.page_start,
        "source_page_end": block.page_end,
    }


def extract_answers(pdf_path: Path, expected_count: int) -> list[str]:
    answers_by_number: dict[int, str] = {}
    with pdfplumber.open(pdf_path) as document:
        for page in document.pages:
            for table in page.extract_tables() or []:
                if len(table) < 2:
                    continue
                header, values = table[0], table[1]
                if not header or not values or header[0] != "題號" or values[0] != "答案":
                    continue
                for question_cell, answer_cell in zip(header[1:], values[1:]):
                    if not question_cell or not answer_cell:
                        continue
                    number_match = re.search(r"第\s*(\d+)\s*題", question_cell)
                    answer_match = re.fullmatch(r"\s*([A-D])\s*", answer_cell)
                    if number_match and answer_match:
                        answers_by_number[int(number_match.group(1))] = answer_match.group(1)

    answers = [answers_by_number.get(number, "") for number in range(1, expected_count + 1)]
    missing = [number for number, answer in enumerate(answers, start=1) if not answer]
    if missing:
        raise ExtractionError(f"{pdf_path}: missing official answers for {missing}")
    return answers



def classify_question(exam_year_roc: int, paper_code: str, question_number: int) -> tuple[str, str]:
    """Apply deterministic first-stage subject ranges supplied by the product owner."""
    subject = "未分類"
    subsubject = "未分類"

    if paper_code == "1301":
        if 1 <= question_number <= 35:
            subject = "刑法"
        elif 36 <= question_number <= 60:
            subject = "刑事訴訟法"
        elif 61 <= question_number <= 75:
            subject = "法律倫理"
    elif paper_code == "2301":
        if 1 <= question_number <= 20:
            subject = "憲法"
        elif 21 <= question_number <= 55:
            subject = "行政法"
        elif 56 <= question_number <= 65:
            subject = "國際公法"
        elif 66 <= question_number <= 75:
            subject = "國際私法"
    elif paper_code == "3301":
        if 1 <= question_number <= 50:
            subject = "民法"
            if exam_year_roc == 111:
                property_numbers = set(range(1, 9)) | set(range(10, 35)) | {36}
                family_numbers = {9, 35} | set(range(37, 51))
                if question_number in property_numbers:
                    subsubject = "財產法"
                elif question_number in family_numbers:
                    subsubject = "親屬繼承"
            elif 1 <= question_number <= 35:
                subsubject = "財產法"
            elif 36 <= question_number <= 50:
                subsubject = "親屬繼承"
        elif 51 <= question_number <= 80:
            subject = "民事訴訟法"
    elif paper_code == "4301":
        ranges = [
            (1, 15, "公司法"), (16, 25, "保險法"), (26, 35, "票據法"),
            (36, 45, "證券交易法"), (46, 55, "強制執行法"),
            (56, 70, "法學英文"),
        ]
        for start, end, label in ranges:
            if start <= question_number <= end:
                subject = label
                break

    return subject, subsubject

def write_csv(path: Path, columns: list[str], rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def build_dataset(project_root: Path, manifest_path: Path) -> tuple[list[dict], list[dict], list[dict]]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    all_questions: list[dict] = []
    paper_rows: list[dict] = []
    qa_rows: list[dict] = []

    for paper in manifest["papers"]:
        question_pdf = project_root / paper["question_pdf"]
        answer_pdf = project_root / paper["answer_pdf"]
        expected_count = int(paper["expected_question_count"])
        blocks = extract_question_blocks(question_pdf, expected_count)
        parsed_questions = [split_question(block) for block in blocks]
        answers = extract_answers(answer_pdf, expected_count)

        for parsed, answer in zip(parsed_questions, answers):
            question_number = int(parsed["question_number"])
            subject_primary, subsubject_primary = classify_question(
                int(paper["exam_year_roc"]), str(paper["paper_code"]), question_number
            )
            override = (paper.get("answer_overrides") or {}).get(str(question_number), {})
            accepted_answers = override.get("accepted_answers") or [answer]
            if not accepted_answers or any(choice not in {"A", "B", "C", "D"} for choice in accepted_answers):
                raise ExtractionError(f"{paper['paper_id']} question {question_number}: invalid answer override")
            final_answer = accepted_answers[0]
            row = {
                **paper,
                **parsed,
                "question_id": f'{paper["paper_id"]}-{question_number:03d}',
                "question_type": "single_choice",
                "original_answer": answer,
                "correct_answer": final_answer,
                "accepted_answers": "|".join(accepted_answers),
                "official_answer_status": override.get("official_answer_status", "official_standard"),
                "official_notice_url": override.get("official_notice_url", ""),
                "source_question_pdf": paper["question_pdf"],
                "source_answer_pdf": paper["answer_pdf"],
                "extraction_status": "parsed",
                "review_status": "pending_manual_review",
                "subject_primary": subject_primary,
                "subsubject_primary": subsubject_primary,
                "subject_secondary": "",
                "chapter": "",
                "topic_primary": "",
                "topic_secondary": "",
                "law_refs": "",
                "tags": "",
                "notes": "",
            }
            row.pop("question_pdf", None)
            row.pop("answer_pdf", None)
            all_questions.append(row)

        paper_rows.append({key: value for key, value in paper.items() if key not in {"question_pdf", "answer_pdf"}})
        qa_rows.append({
            "paper_id": paper["paper_id"],
            "expected_question_count": expected_count,
            "extracted_question_count": len(parsed_questions),
            "answer_count": len(answers),
            "missing_question_text": sum(not row["question_text"] for row in parsed_questions),
            "missing_options": sum(any(not row[f"option_{label.lower()}"] for label in "ABCD") for row in parsed_questions),
            "missing_answers": sum(not answer for answer in answers),
            "status": "pass",
        })

    return all_questions, paper_rows, qa_rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="Project root containing data/ and etl/")
    parser.add_argument("--manifest", default="etl/manifest.json")
    args = parser.parse_args()

    project_root = Path(args.root).resolve()
    manifest_path = (project_root / args.manifest).resolve()
    try:
        questions, papers, qa = build_dataset(project_root, manifest_path)
    except (OSError, ValueError, ExtractionError) as exc:
        print(f"ETL failed: {exc}", file=sys.stderr)
        return 1

    output_dir = project_root / "data" / "processed"
    write_csv(output_dir / "questions_110_114.csv", OUTPUT_COLUMNS, questions)
    write_csv(output_dir / "papers_110_114.csv", list(papers[0]), papers)
    write_csv(output_dir / "qa_report.csv", list(qa[0]), qa)
    write_csv(project_root / "data" / "review" / "questions_review_template.csv", OUTPUT_COLUMNS, questions)

    print(f"Wrote {len(questions)} questions across {len(papers)} papers.")
    print(f"Output: {output_dir / 'questions_110_114.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
