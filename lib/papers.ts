export type Paper = {
  paperId: string;
  year: number;
  order: number;
  code: string;
  title: string;
  durationMinutes: number;
  questionCount: number;
  maxScore: number;
};

export const papers: Paper[] = [
  { paperId: "114-2301", year: 114, order: 1, code: "2301", title: "綜合法學（一）：憲法、行政法、國際公法、國際私法", durationMinutes: 90, questionCount: 75, maxScore: 150 },
  { paperId: "114-3301", year: 114, order: 2, code: "3301", title: "綜合法學（二）：民法、民事訴訟法", durationMinutes: 100, questionCount: 80, maxScore: 160 },
  { paperId: "114-4301", year: 114, order: 3, code: "4301", title: "綜合法學（二）：公司法等商事法、強制執行法、法學英文", durationMinutes: 80, questionCount: 70, maxScore: 140 },
  { paperId: "114-1301", year: 114, order: 4, code: "1301", title: "綜合法學（一）：刑法、刑事訴訟法、法律倫理", durationMinutes: 90, questionCount: 75, maxScore: 150 },
  { paperId: "113-2301", year: 113, order: 1, code: "2301", title: "綜合法學（一）：憲法、行政法、國際公法、國際私法", durationMinutes: 90, questionCount: 75, maxScore: 150 },
  { paperId: "113-3301", year: 113, order: 2, code: "3301", title: "綜合法學（二）：民法、民事訴訟法", durationMinutes: 100, questionCount: 80, maxScore: 160 },
  { paperId: "113-4301", year: 113, order: 3, code: "4301", title: "綜合法學（二）：公司法等商事法、強制執行法、法學英文", durationMinutes: 80, questionCount: 70, maxScore: 140 },
  { paperId: "113-1301", year: 113, order: 4, code: "1301", title: "綜合法學（一）：刑法、刑事訴訟法、法律倫理", durationMinutes: 90, questionCount: 75, maxScore: 150 }
];
