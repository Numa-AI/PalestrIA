-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: monthly_reports permette MULTIPLI record per stesso (user, month)
-- Il cliente può rigenerare un report in toni diversi; ogni rigenerazione viene
-- salvata come nuovo record. L'Edge Function applica un limite di MAX 3
-- rigenerazioni generate con status='generated' per coppia (user, year_month).
-- ══════════════════════════════════════════════════════════════════════════════

-- Rimuovi UNIQUE constraint precedente su (user_id, year_month).
-- Il nome del constraint è quello autogenerato da Postgres per la UNIQUE inline.
ALTER TABLE monthly_reports
    DROP CONSTRAINT IF EXISTS monthly_reports_user_id_year_month_key;

-- Index per query di count + fetch del più recente per (user, month)
CREATE INDEX IF NOT EXISTS idx_monthly_reports_user_month_generated
    ON monthly_reports(user_id, year_month, generated_at DESC)
    WHERE status = 'generated';
