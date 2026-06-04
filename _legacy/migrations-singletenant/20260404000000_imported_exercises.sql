-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: Imported Exercises catalog
-- Tabella per gli esercizi importati dall'admin dal catalogo completo (7200+)
-- Solo gli esercizi importati saranno disponibili nel picker delle schede
-- ══════════════════════════════════════════════════════════════════════════════

CREATE TABLE imported_exercises (
    id             UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    slug           TEXT UNIQUE NOT NULL,
    nome_it        TEXT NOT NULL,           -- nome italiano (rinominabile)
    nome_original  TEXT NOT NULL,           -- nome originale dal catalogo
    nome_en        TEXT,
    categoria      TEXT NOT NULL,
    immagine       TEXT,
    immagine_thumbnail TEXT,
    video          TEXT,
    popolarita     INT DEFAULT 0,
    imported_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_imported_exercises_categoria ON imported_exercises(categoria);
CREATE INDEX idx_imported_exercises_nome ON imported_exercises(nome_it);

ALTER TABLE imported_exercises ENABLE ROW LEVEL SECURITY;

-- Admin: full CRUD
CREATE POLICY imported_exercises_admin_all ON imported_exercises
    FOR ALL TO authenticated
    USING (is_admin()) WITH CHECK (is_admin());

-- Authenticated users: read only (for exercise picker in allenamento)
CREATE POLICY imported_exercises_select_auth ON imported_exercises
    FOR SELECT TO authenticated
    USING (true);

-- Trigger updated_at (reuses existing function)
CREATE OR REPLACE FUNCTION _trg_imported_exercises_updated_at()
RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_imported_exercises_updated_at
    BEFORE UPDATE ON imported_exercises
    FOR EACH ROW EXECUTE FUNCTION _trg_imported_exercises_updated_at();
