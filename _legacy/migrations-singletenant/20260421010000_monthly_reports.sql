-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: AI Monthly Report — Schema
-- Tabella monthly_reports + colonne profili (tone preference + GDPR opt-in)
-- + RLS + indici + trigger updated_at
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Tabella monthly_reports ───────────────────────────────────────────────
CREATE TABLE monthly_reports (
    id             UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id        UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    year_month     TEXT NOT NULL CHECK (year_month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
    tone           TEXT NOT NULL DEFAULT 'motivational'
                        CHECK (tone IN ('serious', 'motivational', 'ironic')),
    scorecard      JSONB NOT NULL,
    narrative      TEXT,
    status         TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'generated', 'failed', 'skipped')),
    model_used     TEXT,
    input_tokens   INT,
    output_tokens  INT,
    cost_usd       NUMERIC(8,5),
    error_message  TEXT,
    generated_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, year_month)
);

CREATE INDEX idx_monthly_reports_user_month ON monthly_reports(user_id, year_month DESC);
CREATE INDEX idx_monthly_reports_status     ON monthly_reports(status);
CREATE INDEX idx_monthly_reports_month      ON monthly_reports(year_month);

ALTER TABLE monthly_reports ENABLE ROW LEVEL SECURITY;

-- Admin: full CRUD
CREATE POLICY monthly_reports_admin_all ON monthly_reports
    FOR ALL TO authenticated
    USING (is_admin()) WITH CHECK (is_admin());

-- Client: read own reports only, and only if already generated
CREATE POLICY monthly_reports_select_own ON monthly_reports
    FOR SELECT TO authenticated
    USING (user_id = auth.uid() AND status = 'generated');

-- ── 2. Trigger updated_at ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_monthly_reports_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER monthly_reports_updated_at
    BEFORE UPDATE ON monthly_reports
    FOR EACH ROW EXECUTE FUNCTION trg_monthly_reports_updated_at();

-- ── 3. Colonne su profiles per preferenza tono + GDPR opt-in ─────────────────
ALTER TABLE profiles
    ADD COLUMN report_tone_preference TEXT NOT NULL DEFAULT 'motivational'
        CHECK (report_tone_preference IN ('serious', 'motivational', 'ironic'));

ALTER TABLE profiles
    ADD COLUMN report_ai_consent BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE profiles
    ADD COLUMN report_ai_consent_at TIMESTAMPTZ;

-- ── 4. RPC: aggiorna preferenza tono del cliente (self-service) ──────────────
CREATE OR REPLACE FUNCTION set_report_tone_preference(p_tone TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
    IF p_tone NOT IN ('serious', 'motivational', 'ironic') THEN
        RAISE EXCEPTION 'invalid_tone';
    END IF;

    UPDATE profiles
    SET report_tone_preference = p_tone
    WHERE id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION set_report_tone_preference(text) FROM public;
GRANT EXECUTE ON FUNCTION set_report_tone_preference(text) TO authenticated;

-- ── 5. RPC: consenso GDPR cliente (self-service) ─────────────────────────────
CREATE OR REPLACE FUNCTION set_report_ai_consent(p_consent BOOLEAN)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
    UPDATE profiles
    SET report_ai_consent = p_consent,
        report_ai_consent_at = CASE WHEN p_consent THEN now() ELSE NULL END
    WHERE id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION set_report_ai_consent(boolean) FROM public;
GRANT EXECUTE ON FUNCTION set_report_ai_consent(boolean) TO authenticated;
