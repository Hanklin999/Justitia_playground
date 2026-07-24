"""Generate repeat-safe Supabase seed SQL/import CSVs for ROC 105-114."""
from __future__ import annotations
import csv
from pathlib import Path
import pandas as pd

ROOT=Path(__file__).resolve().parents[1]
PAPERS_CSV=ROOT/'data/processed/papers_105_114.csv'
QUESTIONS_CSV=ROOT/'data/processed/questions_105_114.csv'
IMPORT_DIR=ROOT/'data/import'
OUT_SQL=ROOT/'supabase/migrations/0008_seed_105_114.sql'
CHUNK_DIR=ROOT/'supabase/sql_editor_v3'

def missing(v):return pd.isna(v) or str(v).strip()==''
def sql_text(v):return 'null' if missing(v) else "'"+str(v).replace("'","''")+"'"
def sql_int(v):return 'null' if missing(v) else str(int(float(v)))
def sql_num(v):return 'null' if missing(v) else str(float(v)).rstrip('0').rstrip('.')
def sql_bool(v):return 'true' if str(v).lower() in {'true','1','yes'} else 'false'
def sql_array(v):
    if missing(v):return "'{}'::text[]"
    items=[x.strip() for x in str(v).split('|') if x.strip()]
    return 'array['+','.join(sql_text(x) for x in items)+']::text[]'
def batches(rows,size=70):
    for i in range(0,len(rows),size):yield rows[i:i+size]
def write_chunk(name,parts):
    CHUNK_DIR.mkdir(parents=True,exist_ok=True)
    (CHUNK_DIR/name).write_text('\n'.join(parts)+'\n',encoding='utf-8')

def main():
    papers=pd.read_csv(PAPERS_CSV,dtype=str,keep_default_na=False)
    questions=pd.read_csv(QUESTIONS_CSV,dtype=str,keep_default_na=False)
    IMPORT_DIR.mkdir(parents=True,exist_ok=True);OUT_SQL.parent.mkdir(parents=True,exist_ok=True)
    paper_import=papers.rename(columns={'expected_question_count':'question_count'}).copy()
    paper_import['included_subjects']=paper_import['included_subjects'].map(lambda x:'{'+','.join(str(x).split('|'))+'}')
    paper_import['is_published']=True
    paper_cols=['paper_id','exam_year_roc','exam_year_ad','exam_code','paper_order','paper_code','paper_group','paper_title','included_subjects','duration_minutes','question_count','points_per_question','max_score','source_question_url','source_answer_url','is_published']
    paper_import[paper_cols].to_csv(IMPORT_DIR/'exam_papers_105_114.csv',index=False,encoding='utf-8-sig')
    public_cols=['question_id','paper_id','question_number','question_type','question_points','question_text','option_a','option_b','option_c','option_d','option_e','subject_primary','subsubject_primary','subject_secondary','chapter','topic_primary','topic_secondary','law_refs','tags','source_page_start','source_page_end','extraction_status','review_status','notes','is_published']
    public_q=questions.copy()
    for c in ['subject_secondary','topic_secondary','law_refs','tags']:public_q[c]='{}'
    public_q['is_published']=True
    public_q[public_cols].to_csv(IMPORT_DIR/'questions_public_105_114.csv',index=False,encoding='utf-8-sig',quoting=csv.QUOTE_MINIMAL)
    keys=questions[['question_id','original_answer','correct_answer','accepted_answers','is_bonus','official_answer_status','official_notice_url']].rename(columns={'correct_answer':'final_answer'})
    keys['accepted_answers']=keys['accepted_answers'].map(lambda x:'{'+','.join(str(x).split('|'))+'}')
    keys.to_csv(IMPORT_DIR/'question_answer_keys_private_105_114.csv',index=False,encoding='utf-8-sig')
    prows=[];qrows=[];arows=[]
    for r in papers.to_dict('records'):
        prows.append('('+','.join([sql_text(r['paper_id']),sql_int(r['exam_year_roc']),sql_int(r['exam_year_ad']),sql_int(r['exam_code']),sql_int(r['paper_order']),sql_text(r['paper_code']),sql_text(r['paper_group']),sql_text(r['paper_title']),sql_array(r['included_subjects']),sql_int(r['duration_minutes']),sql_int(r['expected_question_count']),sql_num(r['points_per_question']),sql_num(r['max_score']),sql_text(r['source_question_url']),sql_text(r['source_answer_url']),'true'])+')')
    for r in questions.to_dict('records'):
        qrows.append('('+','.join([sql_text(r['question_id']),sql_text(r['paper_id']),sql_int(r['question_number']),sql_text(r['question_type']),sql_num(r['question_points']),sql_text(r['question_text']),sql_text(r['option_a']),sql_text(r['option_b']),sql_text(r['option_c']),sql_text(r['option_d']),sql_text(r['option_e']),sql_text(r['subject_primary']),sql_text(r['subsubject_primary']),"'{}'::text[]",'null','null',"'{}'::text[]","'{}'::text[]","'{}'::text[]",sql_int(r['source_page_start']),sql_int(r['source_page_end']),sql_text(r['extraction_status']),sql_text(r['review_status']),sql_text(r['notes']),'true'])+')')
        arows.append('('+','.join([sql_text(r['question_id']),sql_text(r['original_answer']),sql_text(r['correct_answer']),sql_array(r['accepted_answers']),sql_bool(r['is_bonus']),sql_text(r['official_answer_status']),sql_text(r['official_notice_url'])])+')')
    paper_sql=['begin;','insert into public.exam_papers (paper_id,exam_year_roc,exam_year_ad,exam_code,paper_order,paper_code,paper_group,paper_title,included_subjects,duration_minutes,question_count,points_per_question,max_score,source_question_url,source_answer_url,is_published) values',',\n'.join(prows),'on conflict (paper_id) do update set exam_year_roc=excluded.exam_year_roc,exam_year_ad=excluded.exam_year_ad,exam_code=excluded.exam_code,paper_order=excluded.paper_order,paper_code=excluded.paper_code,paper_group=excluded.paper_group,paper_title=excluded.paper_title,included_subjects=excluded.included_subjects,duration_minutes=excluded.duration_minutes,question_count=excluded.question_count,points_per_question=excluded.points_per_question,max_score=excluded.max_score,source_question_url=excluded.source_question_url,source_answer_url=excluded.source_answer_url,is_published=true,updated_at=now();','commit;']
    all_parts=['-- Official MOEX question seed ROC 105-114 (2,968 questions).']+paper_sql
    write_chunk('01_exam_papers.sql',paper_sql)
    for i,b in enumerate(batches(qrows,220),1):
        parts=['begin;','insert into public.questions (question_id,paper_id,question_number,question_type,question_points,question_text,option_a,option_b,option_c,option_d,option_e,subject_primary,subsubject_primary,subject_secondary,chapter,topic_primary,topic_secondary,law_refs,tags,source_page_start,source_page_end,extraction_status,review_status,notes,is_published) values',',\n'.join(b),'on conflict (question_id) do update set paper_id=excluded.paper_id,question_number=excluded.question_number,question_type=excluded.question_type,question_points=excluded.question_points,question_text=excluded.question_text,option_a=excluded.option_a,option_b=excluded.option_b,option_c=excluded.option_c,option_d=excluded.option_d,option_e=excluded.option_e,subject_primary=excluded.subject_primary,subsubject_primary=excluded.subsubject_primary,source_page_start=excluded.source_page_start,source_page_end=excluded.source_page_end,extraction_status=excluded.extraction_status,review_status=excluded.review_status,is_published=true,updated_at=now();','commit;']
        write_chunk(f'{i+1:02d}_questions.sql',parts);all_parts+=parts
    qbatch_count=i
    for j,b in enumerate(batches(arows,450),1):
        parts=['begin;','insert into private.question_answer_keys (question_id,original_answer,final_answer,accepted_answers,is_bonus,official_answer_status,official_notice_url) values',',\n'.join(b),'on conflict (question_id) do update set original_answer=excluded.original_answer,final_answer=excluded.final_answer,accepted_answers=excluded.accepted_answers,is_bonus=excluded.is_bonus,official_answer_status=excluded.official_answer_status,official_notice_url=excluded.official_notice_url,updated_at=now();','commit;']
        write_chunk(f'{qbatch_count+j+1:02d}_answers.sql',parts);all_parts+=parts
    verify=["select count(*) as papers from public.exam_papers where exam_year_roc between 105 and 114;","select count(*) as questions from public.questions where split_part(question_id,'-',1)::int between 105 and 114;","select count(*) as answer_keys from private.question_answer_keys where split_part(question_id,'-',1)::int between 105 and 114;","select count(*) as multiple_choice from public.questions where question_type='multiple_choice';","select count(*) as bonus_questions from private.question_answer_keys where is_bonus;"]
    write_chunk('99_seed_verify.sql',verify);all_parts+=verify
    OUT_SQL.write_text('\n'.join(all_parts)+'\n',encoding='utf-8')
    print('generated',len(papers),'papers',len(questions),'questions',qbatch_count,'q batches',j,'answer batches')
if __name__=='__main__':main()
