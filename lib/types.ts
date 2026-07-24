export type AttemptStatus = "in_progress" | "submitted" | "timed_out";
export type AttemptMode = "official_paper" | "subject_pool" | "wrong_review";
export type AnswerChoice = "A" | "B" | "C" | "D" | "E";
export type QuestionType = "single_choice" | "multiple_choice";
export type ConfidenceLevel = "confident" | "unsure" | "guess";
export type ErrorReason = "unfamiliar_rule" | "forgot_exception" | "misread_stem" | "option_confusion" | "time_pressure" | "careless" | "guessed";
export type SelectionStrategy = "default_scope" | "recent_10_wrong_priority" | "review_union" | "official_order" | "spaced_review";

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

export interface SubjectConfig {
  config_key: string;
  subject_name: string;
  subsubject_name: string | null;
  paper_code: string;
  target_question_count: number;
  seconds_per_question: number;
  display_order: number;
}

export interface StartAttemptResponse {
  attempt_id: string;
  resumed: boolean;
  started_at: string;
  expires_at: string | null;
  duration_minutes: number;
  question_count?: number;
}

export interface AttemptQuestion {
  question_id: string;
  display_order: number;
  question_number: number;
  question_type: QuestionType;
  question_points: number;
  question_text: string;
  option_a: string;
  option_b: string;
  option_c: string;
  option_d: string;
  option_e: string | null;
  selected_answer: string | null;
  review_status: string;
  subject_primary: string;
  subsubject_primary: string;
  exam_is_starred: boolean;
  exam_note_text: string;
  review_is_starred: boolean;
  review_note_text: string;
  active_seconds: number;
  confidence_level: ConfidenceLevel | null;
  answered_at: string | null;
  seconds_remaining_at_answer: number | null;
}

export interface AttemptMeta {
  id: string;
  paper_id: string | null;
  attempt_mode: AttemptMode;
  title: string;
  is_timed: boolean;
  status: AttemptStatus;
  duration_minutes: number;
  question_count: number;
  points_per_question: number;
  max_score: number;
  started_at: string;
  expires_at: string | null;
  submitted_at: string | null;
  submit_reason: "manual" | "timeout" | null;
  selected_years: number[];
  selected_subjects: string[];
  selected_subsubjects: string[];
  exam_date: string;
  default_question_count: number;
  requested_question_count: number;
  selection_strategy: SelectionStrategy;
  selected_paper_kinds: string[];
}

export interface AttemptPayload {
  attempt: AttemptMeta;
  paper: {
    exam_year_roc: number;
    paper_order: number;
    paper_code: string;
    paper_title: string;
    included_subjects: string[];
    source_question_url: string;
  } | null;
  questions: AttemptQuestion[];
}

export interface ResultQuestion extends AttemptQuestion {
  correct_answer: string;
  correct_answers: string[];
  is_bonus: boolean;
  earned_points: number;
  is_correct: boolean;
  is_unanswered: boolean;
  answer_revision_count: number;
  first_answer: string | null;
  first_earned_points: number;
  primary_error_reason: ErrorReason | null;
  secondary_error_reasons: string[];
}

export interface AttemptResult {
  attempt: AttemptMeta & {
    submitted_at: string;
    submit_reason: "manual" | "timeout";
    correct_count: number;
    unanswered_count: number;
    score: number;
    elapsed_seconds: number;
    source_attempt_ids: string[];
  };
  paper: {
    exam_year_roc: number;
    paper_order: number;
    paper_code: string;
    paper_title: string;
    source_question_url: string;
    source_answer_url: string;
  } | null;
  questions: ResultQuestion[];
}

export interface AttemptHistoryItem {
  id: string;
  attempt_mode: AttemptMode;
  title: string;
  is_timed: boolean;
  status: AttemptStatus;
  duration_minutes: number;
  question_count: number;
  started_at: string;
  exam_date: string;
  expires_at: string | null;
  submitted_at: string | null;
  submit_reason: "manual" | "timeout" | null;
  elapsed_seconds: number | null;
  correct_count: number | null;
  unanswered_count: number | null;
  score: number | null;
  max_score: number;
  paper_id: string | null;
  exam_year_roc: number | null;
  paper_order: number | null;
  paper_title: string | null;
  paper_kind: string | null;
  selected_paper_kinds: string[];
  selected_years: number[];
  selected_subjects: string[];
  selected_subsubjects: string[];
  default_question_count: number;
  requested_question_count: number;
  selection_strategy: SelectionStrategy;
  source_attempt_ids: string[];
  exam_star_count: number;
  review_star_count: number;
}

export interface YearSummary {
  exam_year_roc: number;
  completed_papers: number;
  is_complete: boolean;
  total_score: number;
  max_score: number;
  completed_at: string;
  judicial_cutoff: number | null;
  lawyer_cutoff: number | null;
  cutoff_source_url: string | null;
}


export interface DueReviewSummary {
  due_count: number;
  upcoming_count: number;
  next_due_at: string | null;
  due_by_subject: Array<{ subject: string; count: number }>;
}

export interface LearningInsights {
  recent_attempt_count: number;
  top_error_reasons: Array<{ reason: ErrorReason; count: number }>;
  confidence: {
    confident_wrong: number;
    unsure_correct: number;
    guess_wrong: number;
    recorded: number;
  };
}
