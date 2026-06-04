-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: Schede Palestra (Workout Plans)
-- 3 tabelle: workout_plans, workout_exercises, workout_logs
-- + RLS policies + RPCs + indici + trigger updated_at
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. workout_plans ─────────────────────────────────────────────────────────
CREATE TABLE workout_plans (
    id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    start_date  DATE,
    end_date    DATE,
    notes       TEXT,
    active      BOOLEAN NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_workout_plans_user_active ON workout_plans(user_id, active);

ALTER TABLE workout_plans ENABLE ROW LEVEL SECURITY;

-- Admin: full CRUD
CREATE POLICY workout_plans_admin_all ON workout_plans
    FOR ALL TO authenticated
    USING (is_admin()) WITH CHECK (is_admin());

-- Client: read own plans only
CREATE POLICY workout_plans_select_own ON workout_plans
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

-- ── 2. workout_exercises ─────────────────────────────────────────────────────
CREATE TABLE workout_exercises (
    id             UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    plan_id        UUID NOT NULL REFERENCES workout_plans(id) ON DELETE CASCADE,
    day_label      TEXT NOT NULL DEFAULT 'Giorno A',
    exercise_name  TEXT NOT NULL,
    muscle_group   TEXT,
    sort_order     INT NOT NULL DEFAULT 0,
    sets           INT NOT NULL DEFAULT 3,
    reps           TEXT NOT NULL DEFAULT '10',
    weight_kg      NUMERIC(6,1),
    rest_seconds   INT DEFAULT 90,
    notes          TEXT
);

CREATE INDEX idx_workout_exercises_plan ON workout_exercises(plan_id, sort_order);

ALTER TABLE workout_exercises ENABLE ROW LEVEL SECURITY;

-- Admin: full CRUD
CREATE POLICY workout_exercises_admin_all ON workout_exercises
    FOR ALL TO authenticated
    USING (is_admin()) WITH CHECK (is_admin());

-- Client: read exercises of own plans only
CREATE POLICY workout_exercises_select_own ON workout_exercises
    FOR SELECT TO authenticated
    USING (plan_id IN (SELECT id FROM workout_plans WHERE user_id = auth.uid()));

-- ── 3. workout_logs ──────────────────────────────────────────────────────────
CREATE TABLE workout_logs (
    id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    exercise_id  UUID NOT NULL REFERENCES workout_exercises(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    log_date     DATE NOT NULL DEFAULT CURRENT_DATE,
    set_number   INT NOT NULL,
    reps_done    INT,
    weight_done  NUMERIC(6,1),
    rpe          INT CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10)),
    notes        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (exercise_id, user_id, log_date, set_number)
);

CREATE INDEX idx_workout_logs_exercise_date ON workout_logs(exercise_id, log_date);
CREATE INDEX idx_workout_logs_user          ON workout_logs(user_id);

ALTER TABLE workout_logs ENABLE ROW LEVEL SECURITY;

-- Admin: read all logs
CREATE POLICY workout_logs_admin_select ON workout_logs
    FOR SELECT TO authenticated
    USING (is_admin());

-- Client: insert own logs
CREATE POLICY workout_logs_own_insert ON workout_logs
    FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

-- Client: read own logs
CREATE POLICY workout_logs_own_select ON workout_logs
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

-- Client: update own logs
CREATE POLICY workout_logs_own_update ON workout_logs
    FOR UPDATE TO authenticated
    USING (user_id = auth.uid());

-- ── Trigger: auto-update updated_at on workout_plans ─────────────────────────
CREATE OR REPLACE FUNCTION trg_workout_plans_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER workout_plans_updated_at
    BEFORE UPDATE ON workout_plans
    FOR EACH ROW EXECUTE FUNCTION trg_workout_plans_updated_at();

-- ── RPC: duplica scheda ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_duplicate_plan(
    p_plan_id     UUID,
    p_new_user_id UUID,
    p_new_name    TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_new_plan_id UUID;
    v_source      workout_plans%ROWTYPE;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'unauthorized';
    END IF;

    SELECT * INTO v_source FROM workout_plans WHERE id = p_plan_id;
    IF v_source IS NULL THEN
        RAISE EXCEPTION 'plan_not_found';
    END IF;

    INSERT INTO workout_plans (user_id, name, start_date, end_date, notes, active)
    VALUES (
        p_new_user_id,
        COALESCE(p_new_name, v_source.name),
        CURRENT_DATE,
        NULL,
        v_source.notes,
        true
    )
    RETURNING id INTO v_new_plan_id;

    INSERT INTO workout_exercises (plan_id, day_label, exercise_name, muscle_group, sort_order, sets, reps, weight_kg, rest_seconds, notes)
    SELECT v_new_plan_id, day_label, exercise_name, muscle_group, sort_order, sets, reps, weight_kg, rest_seconds, notes
    FROM workout_exercises
    WHERE plan_id = p_plan_id
    ORDER BY sort_order;

    RETURN v_new_plan_id;
END;
$$;

-- ── RPC: suggerimenti esercizi (autocomplete) ────────────────────────────────
CREATE OR REPLACE FUNCTION get_exercise_suggestions()
RETURNS TABLE(exercise_name TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public AS $$
    SELECT DISTINCT we.exercise_name
    FROM workout_exercises we
    ORDER BY we.exercise_name;
$$;
