export type AttemptStatus = "in_progress" | "submitted" | "timed_out";
export type AnswerChoice = "A" | "B" | "C" | "D";

export interface ExamPaper {
  paper_id: string;
  exam_year_roc: number;
  exam_year_ad: number;
  paper_order: number;
  paper_code: string;
  paper_group: string;
  paper_title: string;
  included_subjects: string[];
  duration_minutes: number;
  question_count: number;
  points_per_question: number;
  max_score: number;
  source_question_url: string;
  is_published: boolean;
}

export interface StartAttemptResponse {
  attempt_id: string;
  resumed: boolean;
  started_at: string;
  expires_at: string;
  duration_minutes: number;
}

export interface AttemptQuestion {
  question_id: string;
  question_number: number;
  question_text: string;
  option_a: string;
  option_b: string;
  option_c: string;
  option_d: string;
  selected_answer: AnswerChoice | null;
  review_status: string;
}

export interface AttemptPayload {
  attempt: {
    id: string;
    paper_id: string;
    status: AttemptStatus;
    duration_minutes: number;
    question_count: number;
    points_per_question: number;
    max_score: number;
    started_at: string;
    expires_at: string;
    submitted_at: string | null;
    submit_reason: "manual" | "timeout" | null;
  };
  paper: {
    exam_year_roc: number;
    paper_order: number;
    paper_code: string;
    paper_title: string;
    included_subjects: string[];
    source_question_url: string;
  };
  questions: AttemptQuestion[];
}

export interface ResultQuestion extends AttemptQuestion {
  correct_answer: AnswerChoice;
  is_correct: boolean;
  is_unanswered: boolean;
}

export interface AttemptResult {
  attempt: {
    id: string;
    status: AttemptStatus;
    duration_minutes: number;
    started_at: string;
    expires_at: string;
    submitted_at: string;
    submit_reason: "manual" | "timeout";
    correct_count: number;
    unanswered_count: number;
    score: number;
    max_score: number;
  };
  paper: {
    exam_year_roc: number;
    paper_order: number;
    paper_code: string;
    paper_title: string;
    source_question_url: string;
    source_answer_url: string;
  };
  questions: ResultQuestion[];
}

export interface AttemptHistoryItem {
  id: string;
  status: AttemptStatus;
  duration_minutes: number;
  started_at: string;
  expires_at: string;
  submitted_at: string | null;
  submit_reason: "manual" | "timeout" | null;
  correct_count: number | null;
  unanswered_count: number | null;
  score: number | null;
  max_score: number;
  paper_id: string;
  exam_year_roc: number;
  paper_order: number;
  paper_title: string;
}
