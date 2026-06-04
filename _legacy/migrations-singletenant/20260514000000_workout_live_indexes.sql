-- Indici per evitare timeout nelle query polling della Live Schede.

create index if not exists idx_workout_logs_log_date
    on workout_logs (log_date);

create index if not exists idx_monthly_reports_year_month
    on monthly_reports (year_month);
