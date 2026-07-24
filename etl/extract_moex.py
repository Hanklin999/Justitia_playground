"""Extract Taiwan MOEX judicial/lawyer first-stage PDFs into reviewable CSV files.

Supports ROC 105-114, including the five-option multiple-choice format used in
ROC 105-106 and official corrected/bonus answers declared in manifest.json.
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

OPTION_MARKERS = {"\ue18c":"A","\ue18d":"B","\ue18e":"C","\ue18f":"D","\ue190":"E"}
OUTPUT_COLUMNS = [
    "question_id","exam_year_roc","exam_year_ad","exam_code","exam_name","exam_stage","candidate_scope",
    "paper_id","paper_order","paper_code","paper_group","paper_title","included_subjects","duration_minutes",
    "expected_question_count","points_per_question","max_score","question_number","question_type","question_points",
    "question_text","option_a","option_b","option_c","option_d","option_e","original_answer","correct_answer",
    "accepted_answers","is_bonus","official_answer_status","official_notice_url","source_question_url","source_answer_url",
    "source_question_pdf","source_answer_pdf","source_page_start","source_page_end","extraction_status","review_status",
    "subject_primary","subsubject_primary","subject_secondary","chapter","topic_primary","topic_secondary","law_refs","tags","notes",
]

class ExtractionError(RuntimeError): pass

@dataclass(frozen=True)
class QuestionBlock:
    number:int; page_start:int; page_end:int; lines:list[str]

def normalize_text(value:str)->str:
    value=value.replace("\u00a0"," ").replace("\ufeff","")
    value=re.sub(r"[ \t]+"," ",value)
    value=re.sub(r"\s+([，。；：？！、）】])",r"\1",value)
    value=re.sub(r"([（【])\s+",r"\1",value)
    return value.strip()

def normalize_answer(value:str)->str:
    letters=sorted(set(re.findall(r"[A-E]",str(value).upper())))
    return "".join(letters)

def clean_pdf_line(line:str)->str:
    line=line.replace("\u00a0"," ").strip()
    if not line:return ""
    if re.match(r"^代號：?\s*\d+",line) or re.match(r"^頁次：?",line):return ""
    if line.startswith("類") and "科：" in line:return ""
    if line.startswith("科") and "目：" in line:return ""
    if line.startswith(("考試時間：","座號：","※注意：")):return ""
    if line.startswith(("\ue129","\ue12a","\ue12b")):return ""
    if "公務人員特種考試司法官考試" in line:return ""
    if "專門職業及技術人員高等考試律師考試" in line:return ""
    if line == "第一試試題":return ""
    return line

def extract_question_blocks(pdf_path:Path,expected_count:int)->list[QuestionBlock]:
    rows=[]
    with fitz.open(pdf_path) as document:
        for page_number,page in enumerate(document,start=1):
            # sort=True preserves left-to-right order for horizontally arranged options.
            for raw_line in page.get_text("text", sort=True).splitlines():
                line=clean_pdf_line(raw_line)
                if line:rows.append((page_number,line))
    blocks=[]; current_number=None; current_start=current_end=0; current_lines=[]; expected_number=1
    for page_number,line in rows:
        match=re.match(r"^(\d{1,3})(?:\s+|$)(.*)$",line)
        if match and int(match.group(1))==expected_number:
            if current_number is not None: blocks.append(QuestionBlock(current_number,current_start,current_end,current_lines))
            current_number=expected_number; current_start=current_end=page_number; current_lines=[]; expected_number+=1
            remainder=match.group(2).strip()
            if remainder: current_lines.append(remainder)
        elif current_number is not None:
            current_end=page_number; current_lines.append(line)
    if current_number is not None:blocks.append(QuestionBlock(current_number,current_start,current_end,current_lines))
    if len(blocks)!=expected_count:raise ExtractionError(f"{pdf_path}: expected {expected_count} questions, extracted {len(blocks)}")
    return blocks

def question_format(exam_year_roc:int,paper_code:str,question_number:int)->tuple[str,list[str],float]:
    if exam_year_roc in (105,106):
        multi=(paper_code in {"2301","1301"} and 61<=question_number<=70) or (paper_code=="3301" and 63<=question_number<=74)
        if multi:return "multiple_choice",list("ABCDE"),3.0
    return "single_choice",list("ABCD"),2.0

def split_question(block:QuestionBlock,expected_labels:list[str])->dict[str,str|int]:
    text=" ".join(block.lines)
    for label in expected_labels:
        marker=next(k for k,v in OPTION_MARKERS.items() if v==label)
        text=re.sub(rf"[（(]{label}[）)]",marker,text)
    positions=sorted((text.find(marker),marker,label) for marker,label in OPTION_MARKERS.items() if label in expected_labels and text.find(marker)>=0)
    if len(positions)!=len(expected_labels) or [x[2] for x in positions]!=expected_labels:
        raise ExtractionError(f"Question {block.number}: expected {expected_labels}, found {[x[2] for x in positions]}")
    question_text=normalize_text(text[:positions[0][0]])
    options={}
    for i,(position,_marker,label) in enumerate(positions):
        end=positions[i+1][0] if i+1<len(positions) else len(text)
        options[label]=normalize_text(text[position+1:end])
    if not question_text or any(not options[x] for x in expected_labels):raise ExtractionError(f"Question {block.number}: empty question text or option")
    return {"question_number":block.number,"question_text":question_text,
            "option_a":options.get("A",""),"option_b":options.get("B",""),"option_c":options.get("C",""),
            "option_d":options.get("D",""),"option_e":options.get("E",""),
            "source_page_start":block.page_start,"source_page_end":block.page_end}

def extract_answers(pdf_path:Path,expected_count:int)->list[str]:
    answers_by_number={}
    with pdfplumber.open(pdf_path) as document:
        for page in document.pages:
            for table in page.extract_tables() or []:
                if len(table)<2:continue
                header,values=table[0],table[1]
                if not header or not values or header[0]!="題號" or values[0]!="答案":continue
                for qcell,acell in zip(header[1:],values[1:]):
                    if not qcell or not acell:continue
                    nm=re.search(r"第\s*(\d+)\s*題",qcell)
                    ans=normalize_answer(acell)
                    if nm and ans:answers_by_number[int(nm.group(1))]=ans
    answers=[answers_by_number.get(n,"") for n in range(1,expected_count+1)]
    missing=[n for n,a in enumerate(answers,1) if not a]
    if missing:raise ExtractionError(f"{pdf_path}: missing official answers for {missing}")
    return answers

def classify_question(year:int,paper_code:str,q:int)->tuple[str,str]:
    subject=sub="未分類"
    if year<=106:
        if paper_code=="1301":
            if 1<=q<=26 or 61<=q<=66:subject="刑法"
            elif 27<=q<=45 or 67<=q<=70:subject="刑事訴訟法"
            elif 46<=q<=60:subject="法律倫理"
        elif paper_code=="2301":
            if 1<=q<=14 or 61<=q<=64:subject="憲法"
            elif 15<=q<=40 or 65<=q<=70:subject="行政法"
            elif 41<=q<=50:subject="國際公法"
            elif 51<=q<=60:subject="國際私法"
        elif paper_code=="3301":
            if year==105:
                prop=set(range(1,33))|set(range(63,68)); family=set(range(33,39))|set(range(68,71))
            else:
                prop=set(range(1,29))|set(range(63,69)); family=set(range(29,39))|set(range(69,71))
            if q in prop:subject,sub="民法","財產法"
            elif q in family:subject,sub="民法","親屬繼承"
            elif 39<=q<=62 or 71<=q<=74:subject="民事訴訟法"
        elif paper_code=="4301":
            for start,end,label in [(1,15,"公司法"),(16,25,"保險法"),(26,35,"票據法"),(36,45,"證券交易法"),(46,55,"強制執行法"),(56,70,"法學英文")]:
                if start<=q<=end:subject=label;break
        return subject,sub
    if paper_code=="1301":
        if 1<=q<=35:subject="刑法"
        elif 36<=q<=60:subject="刑事訴訟法"
        elif 61<=q<=75:subject="法律倫理"
    elif paper_code=="2301":
        if 1<=q<=20:subject="憲法"
        elif 21<=q<=55:subject="行政法"
        elif 56<=q<=65:subject="國際公法"
        elif 66<=q<=75:subject="國際私法"
    elif paper_code=="3301":
        if 1<=q<=50:
            subject="民法"
            if year==111:
                prop=set(range(1,9))|set(range(10,35))|{36}; family={9,35}|set(range(37,51))
                if q in prop:sub="財產法"
                elif q in family:sub="親屬繼承"
            elif q<=35:sub="財產法"
            else:sub="親屬繼承"
        elif 51<=q<=80:subject="民事訴訟法"
    elif paper_code=="4301":
        for start,end,label in [(1,15,"公司法"),(16,25,"保險法"),(26,35,"票據法"),(36,45,"證券交易法"),(46,55,"強制執行法"),(56,70,"法學英文")]:
            if start<=q<=end:subject=label;break
    return subject,sub

def write_csv(path:Path,columns:list[str],rows:Iterable[dict])->None:
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open("w",encoding="utf-8-sig",newline="") as h:
        w=csv.DictWriter(h,fieldnames=columns,extrasaction="ignore");w.writeheader();w.writerows(rows)

def build_dataset(root:Path,manifest_path:Path):
    manifest=json.loads(manifest_path.read_text(encoding="utf-8")); all_questions=[];paper_rows=[];qa_rows=[]
    for paper in manifest["papers"]:
        qpdf=root/paper["question_pdf"]; apdf=root/paper["answer_pdf"]; expected=int(paper["expected_question_count"])
        blocks=extract_question_blocks(qpdf,expected); answers=extract_answers(apdf,expected); parsed=[]
        for block in blocks:
            qtype,labels,qpoints=question_format(int(paper["exam_year_roc"]),str(paper["paper_code"]),block.number)
            parsed.append((split_question(block,labels),qtype,qpoints))
        for (item,qtype,qpoints),answer in zip(parsed,answers):
            qn=int(item["question_number"]); subject,sub=classify_question(int(paper["exam_year_roc"]),str(paper["paper_code"]),qn)
            override=(paper.get("answer_overrides") or {}).get(str(qn),{})
            accepted=[normalize_answer(x) for x in (override.get("accepted_answers") or [answer])]
            if any(not x or not re.fullmatch(r"[A-E]{1,5}",x) for x in accepted):raise ExtractionError(f"{paper['paper_id']} q{qn}: invalid answer override {accepted}")
            is_bonus=bool(override.get("is_bonus",False))
            row={**paper,**item,"question_id":f'{paper["paper_id"]}-{qn:03d}',"question_type":qtype,"question_points":qpoints,
                 "original_answer":answer,"correct_answer":accepted[0],"accepted_answers":"|".join(dict.fromkeys(accepted)),"is_bonus":is_bonus,
                 "official_answer_status":override.get("official_answer_status","official_standard"),"official_notice_url":override.get("official_notice_url",""),
                 "source_question_pdf":paper["question_pdf"],"source_answer_pdf":paper["answer_pdf"],"extraction_status":"parsed","review_status":"pending_manual_review",
                 "subject_primary":subject,"subsubject_primary":sub,"subject_secondary":"","chapter":"","topic_primary":"","topic_secondary":"","law_refs":"","tags":"","notes":""}
            row.pop("question_pdf",None);row.pop("answer_pdf",None);row.pop("answer_overrides",None);all_questions.append(row)
        clean={k:v for k,v in paper.items() if k not in {"question_pdf","answer_pdf","answer_overrides"}}
        paper_rows.append(clean)
        missing_options=0
        for item,qtype,_ in parsed:
            labels="ABCDE" if qtype=="multiple_choice" else "ABCD"
            if any(not item[f"option_{x.lower()}"] for x in labels):missing_options+=1
        qa_rows.append({"paper_id":paper["paper_id"],"expected_question_count":expected,"extracted_question_count":len(parsed),"answer_count":len(answers),
                        "multiple_choice_count":sum(qtype=="multiple_choice" for _,qtype,_ in parsed),"missing_question_text":sum(not x[0]["question_text"] for x in parsed),
                        "missing_options":missing_options,"missing_answers":sum(not a for a in answers),"status":"pass"})
    return all_questions,paper_rows,qa_rows

def main()->int:
    parser=argparse.ArgumentParser();parser.add_argument("--root",default=".");parser.add_argument("--manifest",default="etl/manifest.json");args=parser.parse_args()
    root=Path(args.root).resolve();manifest=(root/args.manifest).resolve()
    try:questions,papers,qa=build_dataset(root,manifest)
    except (OSError,ValueError,ExtractionError) as exc:print(f"ETL failed: {exc}",file=sys.stderr);return 1
    out=root/"data"/"processed"
    write_csv(out/"questions_105_114.csv",OUTPUT_COLUMNS,questions)
    write_csv(out/"papers_105_114.csv",list(papers[0]),papers)
    write_csv(out/"qa_report_105_114.csv",list(qa[0]),qa)
    write_csv(root/"data"/"review"/"questions_review_template_105_114.csv",OUTPUT_COLUMNS,questions)
    print(f"Wrote {len(questions)} questions across {len(papers)} papers.")
    return 0
if __name__=="__main__":raise SystemExit(main())
