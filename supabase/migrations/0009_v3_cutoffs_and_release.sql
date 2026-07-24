-- Justitia's playground v3.0.0
-- Complete ROC 105-114 first-stage cutoffs. Repeat-safe.

insert into public.exam_cutoffs
  (exam_year_roc, judicial_cutoff, lawyer_cutoff, source_url, verification_status)
values
  (105,388.80,376.40,'https://wwwc.moex.gov.tw/main/content/wHandMenuFile.ashx?file_id=117','verified_official_report'),
  (106,385.60,372.80,'https://wwwc.moex.gov.tw/main/content/wHandMenuFile.ashx?file_id=117','verified_official_report'),
  (107,366.00,354.00,'https://wwwc.moex.gov.tw/main/content/wHandMenuFile.ashx?file_id=117','verified_official_report'),
  (108,372.00,362.00,'https://wwwc.moex.gov.tw/main/examreport/wHandStatisticsFile.ashx?file_id=1823','verified_official_statistics'),
  (109,378.00,370.00,'https://wwwc.moex.gov.tw/main/examreport/wHandStatisticsFile.ashx?file_id=1921','verified_official_statistics'),
  (110,410.00,402.00,'https://data.gov.tw/dataset/164772','verified_official_open_data'),
  (111,382.00,372.00,'https://wwwc.moex.gov.tw/main/examreport/','verified'),
  (112,384.00,374.00,'https://wwwc.moex.gov.tw/main/examreport/wHandStatisticsFile.ashx?file_id=2219','verified_official_statistics'),
  (113,362.00,354.00,'https://wwwc.moex.gov.tw/main/examreport/','verified'),
  (114,368.00,360.00,'https://wwwc.moex.gov.tw/main/examreport/wHandStatisticsFile.ashx?file_id=3435','verified_official_statistics')
on conflict (exam_year_roc) do update set
  judicial_cutoff=excluded.judicial_cutoff,
  lawyer_cutoff=excluded.lawyer_cutoff,
  source_url=excluded.source_url,
  verification_status=excluded.verification_status,
  updated_at=now();
