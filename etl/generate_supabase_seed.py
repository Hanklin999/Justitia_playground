"""Generate repeat-safe Supabase seed SQL and import CSVs for ROC 110-114."""
from __future__ import annotations

import csv
from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
PAPERS_CSV = ROOT / "data" / "processed" / "papers_110_114.csv"
QUESTIONS_CSV = ROOT / "data" / "processed" / "questions_110_114.csv"
IMPORT_DIR = ROOT / "data" / "import"
OUT_SQL = ROOT / "supabase" / "migrations" / "0005_seed_110_114.sql"


def missing(v: object) -> bool:
    return pd.isna(v) or str(v).strip() == ""


def sql_text(v: object) -> str:
    if missing(v):
        return "null"
    return "'" + str(v).replace("'", "''") + "'"


def sql_int(v: object) -> str:
    return "null" if missing(v) else str(int(float(v)))


def sql_num(v: object) -> str:
    return "null" if missing(v) else str(float(v)).rstrip("0").rstrip(".")


def sql_array(v: object) -> str:
    if missing(v):
        return "'{}'::text[]"
    items = [x.strip() for x in str(v).split("|") if x.strip()]
    return "array[" + ",".join(sql_text(x) for x in items) + "]::text[]"


def batches(rows: list[str], size: int = 80):
    for i in range(0, len(rows), size):
        yield rows[i:i+size]


def main() -> None:
    papers = pd.read_csv(PAPERS_CSV, dtype={"paper_id": str, "paper_code": str, "exam_code": str})
    questions = pd.read_csv(QUESTIONS_CSV, dtype={"question_id": str, "paper_id": str, "paper_code": str})
    IMPORT_DIR.mkdir(parents=True, exist_ok=True)
    OUT_SQL.parent.mkdir(parents=True, exist_ok=True)

    paper_import = papers.rename(columns={"expected_question_count":"question_count"}).copy()
    paper_import["included_subjects"] = paper_import["included_subjects"].map(lambda x: "{" + ",".join(str(x).split("|")) + "}")
    paper_import["is_published"] = True
    paper_cols = ["paper_id","exam_year_roc","exam_year_ad","exam_code","paper_order","paper_code","paper_group","paper_title","included_subjects","duration_minutes","question_count","points_per_question","max_score","source_question_url","source_answer_url","is_published"]
    paper_import[paper_cols].to_csv(IMPORT_DIR / "exam_papers.csv", index=False, encoding="utf-8-sig")

    public_cols = ["question_id","paper_id","question_number","question_type","question_text","option_a","option_b","option_c","option_d","subject_primary","subsubject_primary","subject_secondary","chapter","topic_primary","topic_secondary","law_refs","tags","source_page_start","source_page_end","extraction_status","review_status","notes","is_published"]
    public_q = questions.copy()
    for c in ["subject_secondary","topic_secondary","law_refs","tags"]:
        public_q[c] = "{}"
    public_q["is_published"] = True
    public_q[public_cols].to_csv(IMPORT_DIR / "questions_public.csv", index=False, encoding="utf-8-sig", quoting=csv.QUOTE_MINIMAL)

    keys = questions[["question_id","original_answer","correct_answer","accepted_answers","official_answer_status","official_notice_url"]].rename(columns={"correct_answer":"final_answer"})
    keys["accepted_answers"] = keys["accepted_answers"].map(lambda x: "{" + ",".join(str(x).split("|")) + "}")
    keys.to_csv(IMPORT_DIR / "question_answer_keys_private.csv", index=False, encoding="utf-8-sig")

    paper_rows=[]
    for r in papers.to_dict("records"):
        paper_rows.append("("+",".join([
            sql_text(r["paper_id"]),sql_int(r["exam_year_roc"]),sql_int(r["exam_year_ad"]),sql_int(r["exam_code"]),
            sql_int(r["paper_order"]),sql_text(r["paper_code"]),sql_text(r["paper_group"]),sql_text(r["paper_title"]),
            sql_array(r["included_subjects"]),sql_int(r["duration_minutes"]),sql_int(r["expected_question_count"]),
            sql_num(r["points_per_question"]),sql_num(r["max_score"]),sql_text(r["source_question_url"]),sql_text(r["source_answer_url"]),"true"
        ])+")")

    qrows=[]; arows=[]
    for r in questions.to_dict("records"):
        qrows.append("("+",".join([
            sql_text(r["question_id"]),sql_text(r["paper_id"]),sql_int(r["question_number"]),sql_text(r["question_type"]),
            sql_text(r["question_text"]),sql_text(r["option_a"]),sql_text(r["option_b"]),sql_text(r["option_c"]),sql_text(r["option_d"]),
            sql_text(r["subject_primary"]),sql_text(r["subsubject_primary"]),"'{}'::text[]","null","null","'{}'::text[]","'{}'::text[]","'{}'::text[]",
            sql_int(r["source_page_start"]),sql_int(r["source_page_end"]),sql_text(r["extraction_status"]),sql_text(r["review_status"]),sql_text(r["notes"]),"true"
        ])+")")
        arows.append("("+",".join([sql_text(r["question_id"]),sql_text(r["original_answer"]),sql_text(r["correct_answer"]),sql_array(r["accepted_answers"]),sql_text(r["official_answer_status"]),sql_text(r["official_notice_url"])])+ ")")

    out=["-- Official MOEX question seed: ROC 110-114 (1,500 questions).","begin;",
         "insert into public.exam_papers (paper_id,exam_year_roc,exam_year_ad,exam_code,paper_order,paper_code,paper_group,paper_title,included_subjects,duration_minutes,question_count,points_per_question,max_score,source_question_url,source_answer_url,is_published) values",
         ",\n".join(paper_rows),
         "on conflict (paper_id) do update set paper_title=excluded.paper_title,included_subjects=excluded.included_subjects,duration_minutes=excluded.duration_minutes,question_count=excluded.question_count,points_per_question=excluded.points_per_question,max_score=excluded.max_score,source_question_url=excluded.source_question_url,source_answer_url=excluded.source_answer_url,is_published=true,updated_at=now();",""]
    for i,b in enumerate(batches(qrows),1):
        out += [f"-- question batch {i}",
        "insert into public.questions (question_id,paper_id,question_number,question_type,question_text,option_a,option_b,option_c,option_d,subject_primary,subsubject_primary,subject_secondary,chapter,topic_primary,topic_secondary,law_refs,tags,source_page_start,source_page_end,extraction_status,review_status,notes,is_published) values",
        ",\n".join(b),
        "on conflict (question_id) do update set paper_id=excluded.paper_id,question_number=excluded.question_number,question_text=excluded.question_text,option_a=excluded.option_a,option_b=excluded.option_b,option_c=excluded.option_c,option_d=excluded.option_d,subject_primary=excluded.subject_primary,subsubject_primary=excluded.subsubject_primary,source_page_start=excluded.source_page_start,source_page_end=excluded.source_page_end,extraction_status=excluded.extraction_status,review_status=excluded.review_status,is_published=true,updated_at=now();",""]
    for i,b in enumerate(batches(arows),1):
        out += [f"-- answer batch {i}",
        "insert into private.question_answer_keys (question_id,original_answer,final_answer,accepted_answers,official_answer_status,official_notice_url) values",
        ",\n".join(b),
        "on conflict (question_id) do update set original_answer=excluded.original_answer,final_answer=excluded.final_answer,accepted_answers=excluded.accepted_answers,official_answer_status=excluded.official_answer_status,official_notice_url=excluded.official_notice_url,updated_at=now();",""]
    out += ["do $$ declare q integer; a integer; begin select count(*) into q from public.questions where split_part(question_id,'-',1)::int between 110 and 114; select count(*) into a from private.question_answer_keys where split_part(question_id,'-',1)::int between 110 and 114; if q<>1500 or a<>1500 then raise exception 'V2 seed failed: questions %, answers %',q,a; end if; end $$;","commit;",""]
    OUT_SQL.write_text("\n".join(out),encoding="utf-8")
    print(f"Generated {OUT_SQL.relative_to(ROOT)} with {len(questions)} questions")

if __name__ == '__main__': main()
