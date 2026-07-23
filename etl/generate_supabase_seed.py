"""Generate Supabase seed SQL and import-ready CSV files.

The public questions table intentionally excludes official answers. Answer keys are
written to the private schema and are only exposed after an attempt is submitted.
"""
from __future__ import annotations

import csv
from pathlib import Path
from typing import Any

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
PAPERS_CSV = ROOT / "data" / "processed" / "papers_113_114.csv"
QUESTIONS_CSV = ROOT / "data" / "processed" / "questions_113_114.csv"
OUT_SQL = ROOT / "supabase" / "migrations" / "0002_seed_113_114.sql"
IMPORT_DIR = ROOT / "data" / "import"


def is_missing(value: Any) -> bool:
    return value is None or (isinstance(value, float) and pd.isna(value)) or pd.isna(value)


def sql_text(value: Any) -> str:
    if is_missing(value):
        return "null"
    text = str(value).replace("'", "''")
    return f"'{text}'"


def sql_int(value: Any) -> str:
    if is_missing(value):
        return "null"
    return str(int(value))


def sql_numeric(value: Any) -> str:
    if is_missing(value):
        return "null"
    return str(float(value)).rstrip("0").rstrip(".") if "." in str(float(value)) else str(int(value))


def sql_array(pipe_text: Any) -> str:
    if is_missing(pipe_text) or not str(pipe_text).strip():
        return "'{}'::text[]"
    items = [item.strip() for item in str(pipe_text).split("|") if item.strip()]
    return "array[" + ", ".join(sql_text(item) for item in items) + "]::text[]"


def batched(rows: list[str], size: int = 100) -> list[list[str]]:
    return [rows[i : i + size] for i in range(0, len(rows), size)]


def generate() -> None:
    papers = pd.read_csv(PAPERS_CSV, dtype={"paper_id": str, "paper_code": str})
    questions = pd.read_csv(QUESTIONS_CSV, dtype={"question_id": str, "paper_id": str})

    IMPORT_DIR.mkdir(parents=True, exist_ok=True)
    OUT_SQL.parent.mkdir(parents=True, exist_ok=True)

    public_question_columns = [
        "question_id",
        "paper_id",
        "question_number",
        "question_type",
        "question_text",
        "option_a",
        "option_b",
        "option_c",
        "option_d",
        "subject_primary",
        "subject_secondary",
        "chapter",
        "topic_primary",
        "topic_secondary",
        "law_refs",
        "tags",
        "source_page_start",
        "source_page_end",
        "extraction_status",
        "review_status",
        "notes",
        "is_published",
    ]

    public_questions = questions.copy()
    for column in ["subject_secondary", "topic_secondary", "law_refs", "tags"]:
        public_questions[column] = "{}"
    public_questions["is_published"] = True
    public_questions[public_question_columns].to_csv(
        IMPORT_DIR / "questions_public.csv",
        index=False,
        encoding="utf-8-sig",
        quoting=csv.QUOTE_MINIMAL,
    )

    answer_keys = questions[
        ["question_id", "correct_answer", "official_answer_status"]
    ].rename(
        columns={
            "correct_answer": "final_answer",
        }
    )
    answer_keys.insert(1, "original_answer", answer_keys["final_answer"])
    answer_keys["official_notice_url"] = ""
    answer_keys.to_csv(
        IMPORT_DIR / "question_answer_keys_private.csv",
        index=False,
        encoding="utf-8-sig",
    )

    paper_import = papers.rename(columns={"expected_question_count": "question_count"}).copy()
    paper_import["included_subjects"] = paper_import["included_subjects"].apply(
        lambda value: "{" + ",".join(str(value).split("|")) + "}"
    )
    paper_import["is_published"] = True
    paper_columns = [
        "paper_id",
        "exam_year_roc",
        "exam_year_ad",
        "exam_code",
        "paper_order",
        "paper_code",
        "paper_group",
        "paper_title",
        "included_subjects",
        "duration_minutes",
        "question_count",
        "points_per_question",
        "max_score",
        "source_question_url",
        "source_answer_url",
        "is_published",
    ]
    paper_import[paper_columns].to_csv(
        IMPORT_DIR / "exam_papers.csv",
        index=False,
        encoding="utf-8-sig",
    )

    paper_rows: list[str] = []
    for row in papers.to_dict("records"):
        paper_rows.append(
            "(" + ", ".join(
                [
                    sql_text(row["paper_id"]),
                    sql_int(row["exam_year_roc"]),
                    sql_int(row["exam_year_ad"]),
                    sql_int(row["exam_code"]),
                    sql_int(row["paper_order"]),
                    sql_text(row["paper_code"]),
                    sql_text(row["paper_group"]),
                    sql_text(row["paper_title"]),
                    sql_array(row["included_subjects"]),
                    sql_int(row["duration_minutes"]),
                    sql_int(row["expected_question_count"]),
                    sql_numeric(row["points_per_question"]),
                    sql_numeric(row["max_score"]),
                    sql_text(row["source_question_url"]),
                    sql_text(row["source_answer_url"]),
                    "true",
                ]
            ) + ")"
        )

    question_rows: list[str] = []
    answer_rows: list[str] = []
    for row in questions.to_dict("records"):
        question_rows.append(
            "(" + ", ".join(
                [
                    sql_text(row["question_id"]),
                    sql_text(row["paper_id"]),
                    sql_int(row["question_number"]),
                    sql_text(row["question_type"]),
                    sql_text(row["question_text"]),
                    sql_text(row["option_a"]),
                    sql_text(row["option_b"]),
                    sql_text(row["option_c"]),
                    sql_text(row["option_d"]),
                    "null",
                    "'{}'::text[]",
                    "null",
                    "null",
                    "'{}'::text[]",
                    "'{}'::text[]",
                    "'{}'::text[]",
                    sql_int(row["source_page_start"]),
                    sql_int(row["source_page_end"]),
                    sql_text(row["extraction_status"]),
                    sql_text(row["review_status"]),
                    sql_text(row["notes"]),
                    "true",
                ]
            ) + ")"
        )
        answer_rows.append(
            "(" + ", ".join(
                [
                    sql_text(row["question_id"]),
                    sql_text(row["correct_answer"]),
                    sql_text(row["correct_answer"]),
                    sql_text(row["official_answer_status"]),
                    "null",
                ]
            ) + ")"
        )

    parts = [
        "-- Seed generated from official MOEX PDFs for ROC years 113 and 114.",
        "-- Questions are published for MVP testing but remain marked pending_manual_review.",
        "begin;",
        "",
        "insert into public.exam_papers (",
        "  paper_id, exam_year_roc, exam_year_ad, exam_code, paper_order, paper_code,",
        "  paper_group, paper_title, included_subjects, duration_minutes, question_count,",
        "  points_per_question, max_score, source_question_url, source_answer_url, is_published",
        ") values",
        ",\n".join(paper_rows),
        "on conflict (paper_id) do update set",
        "  paper_title = excluded.paper_title,",
        "  included_subjects = excluded.included_subjects,",
        "  duration_minutes = excluded.duration_minutes,",
        "  question_count = excluded.question_count,",
        "  points_per_question = excluded.points_per_question,",
        "  max_score = excluded.max_score,",
        "  source_question_url = excluded.source_question_url,",
        "  source_answer_url = excluded.source_answer_url,",
        "  is_published = excluded.is_published,",
        "  updated_at = now();",
        "",
    ]

    for index, batch in enumerate(batched(question_rows), start=1):
        parts.extend(
            [
                f"-- Question batch {index}",
                "insert into public.questions (",
                "  question_id, paper_id, question_number, question_type, question_text,",
                "  option_a, option_b, option_c, option_d, subject_primary, subject_secondary,",
                "  chapter, topic_primary, topic_secondary, law_refs, tags, source_page_start,",
                "  source_page_end, extraction_status, review_status, notes, is_published",
                ") values",
                ",\n".join(batch),
                "on conflict (question_id) do update set",
                "  paper_id = excluded.paper_id,",
                "  question_number = excluded.question_number,",
                "  question_text = excluded.question_text,",
                "  option_a = excluded.option_a,",
                "  option_b = excluded.option_b,",
                "  option_c = excluded.option_c,",
                "  option_d = excluded.option_d,",
                "  source_page_start = excluded.source_page_start,",
                "  source_page_end = excluded.source_page_end,",
                "  extraction_status = excluded.extraction_status,",
                "  review_status = excluded.review_status,",
                "  is_published = excluded.is_published,",
                "  updated_at = now();",
                "",
            ]
        )

    for index, batch in enumerate(batched(answer_rows), start=1):
        parts.extend(
            [
                f"-- Answer-key batch {index}",
                "insert into private.question_answer_keys (",
                "  question_id, original_answer, final_answer, official_answer_status, official_notice_url",
                ") values",
                ",\n".join(batch),
                "on conflict (question_id) do update set",
                "  original_answer = excluded.original_answer,",
                "  final_answer = excluded.final_answer,",
                "  official_answer_status = excluded.official_answer_status,",
                "  official_notice_url = excluded.official_notice_url,",
                "  updated_at = now();",
                "",
            ]
        )

    parts.extend(
        [
            "do $$",
            "declare",
            "  v_questions integer;",
            "  v_answers integer;",
            "begin",
            "  select count(*) into v_questions from public.questions where paper_id like '113-%' or paper_id like '114-%';",
            "  select count(*) into v_answers from private.question_answer_keys where question_id like '113-%' or question_id like '114-%';",
            "  if v_questions <> 600 or v_answers <> 600 then",
            "    raise exception 'Seed validation failed: questions %, answers %', v_questions, v_answers;",
            "  end if;",
            "end $$;",
            "",
            "commit;",
            "",
        ]
    )

    OUT_SQL.write_text("\n".join(parts), encoding="utf-8")
    print(f"Generated {OUT_SQL.relative_to(ROOT)} ({len(questions)} questions)")
    print(f"Generated import CSV files under {IMPORT_DIR.relative_to(ROOT)}")


if __name__ == "__main__":
    generate()
