-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: AI Monthly Report — Scorecard Aggregation
-- Funzione deterministica che calcola la scorecard di un utente per un mese:
-- - stats prenotazioni (aderenza, completate, annullate)
-- - progressione esercizi (max/min peso, sessioni, volumi)
-- - volume per gruppo muscolare
-- - confronto con mese precedente + delta
-- - metadata (soglia minima sessioni per report)
-- Output: JSONB strutturato pronto per essere dato in pasto al prompt AI.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION generate_monthly_scorecard(
    p_user_id     UUID,
    p_year_month  TEXT  -- formato 'YYYY-MM'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    -- Autorizzazione: solo admin o service_role (edge function) possono chiamarla
    v_caller_is_service BOOLEAN := auth.uid() IS NULL;
    -- Bounds temporali
    v_month_start        DATE;
    v_month_end          DATE;
    v_prev_month_start   DATE;
    v_prev_month_end     DATE;
    v_year_month_prev    TEXT;
    -- Aggregati
    v_current            JSONB;
    v_previous           JSONB;
    v_delta              JSONB;
    v_metadata           JSONB;
    v_sessions_current   INT;
    v_sessions_previous  INT;
    v_min_sessions       CONSTANT INT := 3;
BEGIN
    -- ── Autorizzazione ─────────────────────────────────────────────────────
    IF NOT v_caller_is_service AND NOT is_admin() THEN
        RAISE EXCEPTION 'unauthorized';
    END IF;

    -- Validazione formato year_month
    IF p_year_month !~ '^\d{4}-(0[1-9]|1[0-2])$' THEN
        RAISE EXCEPTION 'invalid_year_month_format: expected YYYY-MM, got %', p_year_month;
    END IF;

    -- ── Calcolo bounds ─────────────────────────────────────────────────────
    v_month_start      := (p_year_month || '-01')::DATE;
    v_month_end        := (v_month_start + interval '1 month')::DATE;
    v_prev_month_start := (v_month_start - interval '1 month')::DATE;
    v_prev_month_end   := v_month_start;
    v_year_month_prev  := to_char(v_prev_month_start, 'YYYY-MM');

    -- ══════════════════════════════════════════════════════════════════════
    -- MESE CORRENTE
    -- ══════════════════════════════════════════════════════════════════════
    v_current := build_month_scorecard_block(p_user_id, v_month_start, v_month_end);
    v_sessions_current := (v_current->>'sessions_logged_count')::INT;

    -- ══════════════════════════════════════════════════════════════════════
    -- MESE PRECEDENTE
    -- ══════════════════════════════════════════════════════════════════════
    v_previous := build_month_scorecard_block(p_user_id, v_prev_month_start, v_prev_month_end);
    v_sessions_previous := (v_previous->>'sessions_logged_count')::INT;

    -- ══════════════════════════════════════════════════════════════════════
    -- DELTA (cambiamenti mese corrente vs precedente)
    -- ══════════════════════════════════════════════════════════════════════
    v_delta := build_scorecard_delta(v_current, v_previous);

    -- ══════════════════════════════════════════════════════════════════════
    -- METADATA (decisione se generare report, soglia minima, ecc.)
    -- ══════════════════════════════════════════════════════════════════════
    v_metadata := jsonb_build_object(
        'minimum_sessions_threshold', v_min_sessions,
        'minimum_sessions_met', v_sessions_current >= v_min_sessions,
        'has_previous_month_data', v_sessions_previous > 0,
        'can_generate_full_report', v_sessions_current >= v_min_sessions,
        'report_type', CASE
            WHEN v_sessions_current = 0 THEN 'no_data'
            WHEN v_sessions_current < v_min_sessions THEN 'encouragement'
            WHEN v_sessions_previous = 0 THEN 'first_month'
            ELSE 'full'
        END
    );

    -- ══════════════════════════════════════════════════════════════════════
    -- ASSEMBLAGGIO OUTPUT
    -- ══════════════════════════════════════════════════════════════════════
    RETURN jsonb_build_object(
        'user_id', p_user_id,
        'year_month', p_year_month,
        'previous_year_month', v_year_month_prev,
        'generated_at', now(),
        'current', v_current,
        'previous', v_previous,
        'delta', v_delta,
        'metadata', v_metadata
    );
END;
$$;

REVOKE ALL ON FUNCTION generate_monthly_scorecard(uuid, text) FROM public;
GRANT EXECUTE ON FUNCTION generate_monthly_scorecard(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION generate_monthly_scorecard(uuid, text) TO service_role;


-- ══════════════════════════════════════════════════════════════════════════════
-- Helper interna: aggrega un singolo blocco (un mese) della scorecard
-- Restituisce JSONB con: bookings, exercises, volume_by_muscle, sessions count
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION build_month_scorecard_block(
    p_user_id      UUID,
    p_month_start  DATE,
    p_month_end    DATE  -- esclusivo
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_bookings          JSONB;
    v_exercises         JSONB;
    v_volume_by_muscle  JSONB;
    v_sessions_count    INT;
BEGIN
    -- ── BOOKINGS ───────────────────────────────────────────────────────────
    WITH agg AS (
        SELECT
            COUNT(*)::INT AS total,
            COUNT(*) FILTER (WHERE status = 'confirmed')::INT              AS completed,
            COUNT(*) FILTER (WHERE status = 'cancelled')::INT              AS cancelled,
            COUNT(*) FILTER (WHERE status = 'cancellation_requested')::INT AS pending_cancellation,
            COUNT(*) FILTER (WHERE paid = true)::INT                       AS paid_count
        FROM bookings
        WHERE user_id = p_user_id
          AND date >= p_month_start
          AND date <  p_month_end
    ),
    slot_type_agg AS (
        SELECT jsonb_object_agg(slot_type, cnt) AS by_slot_type
        FROM (
            SELECT slot_type, COUNT(*)::INT AS cnt
            FROM bookings
            WHERE user_id = p_user_id
              AND date >= p_month_start
              AND date <  p_month_end
              AND slot_type IS NOT NULL
            GROUP BY slot_type
        ) s
    )
    SELECT jsonb_build_object(
        'total',                agg.total,
        'completed',            agg.completed,
        'cancelled',            agg.cancelled,
        'pending_cancellation', agg.pending_cancellation,
        'paid_count',           agg.paid_count,
        'adherence_pct',
            CASE WHEN agg.total > 0
                 THEN ROUND((agg.completed::NUMERIC / agg.total) * 100, 1)
                 ELSE 0 END,
        'by_slot_type',         COALESCE(slot_type_agg.by_slot_type, '{}'::jsonb)
    )
    INTO v_bookings
    FROM agg, slot_type_agg;

    -- ── EXERCISES aggregati per nome esercizio ─────────────────────────────
    -- Per ogni esercizio: max peso, min peso, n. sessioni loggate, totale set,
    -- somma reps complete, muscle_group dominante (dal piano)
    WITH logs_in_month AS (
        SELECT
            wl.exercise_id,
            we.exercise_name,
            we.muscle_group,
            wl.log_date,
            wl.set_number,
            wl.reps_done,
            wl.weight_done
        FROM workout_logs wl
        INNER JOIN workout_exercises we ON we.id = wl.exercise_id
        WHERE wl.user_id = p_user_id
          AND wl.log_date >= p_month_start
          AND wl.log_date <  p_month_end
    ),
    per_exercise AS (
        SELECT
            exercise_name,
            -- muscle group: prende il più frequente (in caso di esercizi omonimi su più piani)
            (SELECT muscle_group
             FROM logs_in_month l2
             WHERE l2.exercise_name = l1.exercise_name
               AND muscle_group IS NOT NULL
             GROUP BY muscle_group
             ORDER BY COUNT(*) DESC
             LIMIT 1) AS muscle_group,
            COUNT(DISTINCT log_date)::INT               AS sessions_logged,
            MAX(weight_done)                            AS max_weight,
            MIN(weight_done) FILTER (WHERE weight_done IS NOT NULL) AS min_weight,
            COUNT(*)::INT                               AS total_sets,
            COALESCE(SUM(reps_done), 0)::INT            AS total_reps_sum,
            -- peso inizio mese (prima data)
            (SELECT weight_done FROM logs_in_month l3
             WHERE l3.exercise_name = l1.exercise_name AND weight_done IS NOT NULL
             ORDER BY log_date ASC, set_number ASC LIMIT 1) AS first_weight,
            -- peso fine mese (ultima data)
            (SELECT weight_done FROM logs_in_month l4
             WHERE l4.exercise_name = l1.exercise_name AND weight_done IS NOT NULL
             ORDER BY log_date DESC, set_number DESC LIMIT 1) AS last_weight
        FROM logs_in_month l1
        GROUP BY exercise_name
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'exercise_name',   exercise_name,
            'muscle_group',    muscle_group,
            'sessions_logged', sessions_logged,
            'max_weight',      max_weight,
            'min_weight',      min_weight,
            'first_weight',    first_weight,
            'last_weight',     last_weight,
            'total_sets',      total_sets,
            'total_reps_sum',  total_reps_sum
        )
        ORDER BY sessions_logged DESC, max_weight DESC NULLS LAST
    ), '[]'::jsonb)
    INTO v_exercises
    FROM per_exercise;

    -- ── VOLUME PER GRUPPO MUSCOLARE (totale set nel mese) ──────────────────
    WITH muscle_vol AS (
        SELECT
            COALESCE(we.muscle_group, 'Non classificato') AS muscle_group,
            COUNT(*)::INT AS total_sets
        FROM workout_logs wl
        INNER JOIN workout_exercises we ON we.id = wl.exercise_id
        WHERE wl.user_id = p_user_id
          AND wl.log_date >= p_month_start
          AND wl.log_date <  p_month_end
        GROUP BY we.muscle_group
    )
    SELECT COALESCE(jsonb_object_agg(muscle_group, total_sets), '{}'::jsonb)
    INTO v_volume_by_muscle
    FROM muscle_vol;

    -- ── SESSIONI LOGGATE UNICHE (= giorni distinti con almeno 1 log) ───────
    SELECT COUNT(DISTINCT log_date)::INT
    INTO v_sessions_count
    FROM workout_logs
    WHERE user_id = p_user_id
      AND log_date >= p_month_start
      AND log_date <  p_month_end;

    -- ── OUTPUT ─────────────────────────────────────────────────────────────
    RETURN jsonb_build_object(
        'month_start',           p_month_start,
        'month_end_exclusive',   p_month_end,
        'bookings',              v_bookings,
        'exercises',             v_exercises,
        'volume_by_muscle',      v_volume_by_muscle,
        'sessions_logged_count', v_sessions_count
    );
END;
$$;

REVOKE ALL ON FUNCTION build_month_scorecard_block(uuid, date, date) FROM public;
GRANT EXECUTE ON FUNCTION build_month_scorecard_block(uuid, date, date) TO service_role;


-- ══════════════════════════════════════════════════════════════════════════════
-- Helper interna: calcola delta tra mese corrente e mese precedente
-- Restituisce JSONB con cambiamenti per: aderenza, sessioni, esercizi, muscoli
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION build_scorecard_delta(
    p_current   JSONB,
    p_previous  JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_adherence_delta  NUMERIC;
    v_sessions_delta   INT;
    v_exercises_delta  JSONB;
    v_muscle_delta     JSONB;
    v_cur_adherence    NUMERIC;
    v_prev_adherence   NUMERIC;
BEGIN
    -- ── Delta aderenza ─────────────────────────────────────────────────────
    v_cur_adherence  := COALESCE((p_current->'bookings'->>'adherence_pct')::NUMERIC, 0);
    v_prev_adherence := COALESCE((p_previous->'bookings'->>'adherence_pct')::NUMERIC, 0);
    v_adherence_delta := ROUND(v_cur_adherence - v_prev_adherence, 1);

    -- ── Delta sessioni loggate ─────────────────────────────────────────────
    v_sessions_delta :=
        COALESCE((p_current->>'sessions_logged_count')::INT, 0) -
        COALESCE((p_previous->>'sessions_logged_count')::INT, 0);

    -- ── Delta esercizi (su max_weight, per nome) ───────────────────────────
    WITH cur AS (
        SELECT
            (el->>'exercise_name')                  AS exercise_name,
            (el->>'max_weight')::NUMERIC            AS max_weight,
            (el->>'sessions_logged')::INT           AS sessions_logged
        FROM jsonb_array_elements(COALESCE(p_current->'exercises', '[]'::jsonb)) AS el
    ),
    prev AS (
        SELECT
            (el->>'exercise_name')                  AS exercise_name,
            (el->>'max_weight')::NUMERIC            AS max_weight
        FROM jsonb_array_elements(COALESCE(p_previous->'exercises', '[]'::jsonb)) AS el
    ),
    joined AS (
        SELECT
            c.exercise_name,
            c.max_weight AS current_max,
            p.max_weight AS previous_max,
            (c.max_weight - p.max_weight) AS weight_change,
            CASE WHEN p.max_weight > 0 AND c.max_weight IS NOT NULL
                 THEN ROUND(((c.max_weight - p.max_weight) / p.max_weight) * 100, 1)
                 ELSE NULL
            END AS weight_pct_change,
            CASE
                WHEN p.max_weight IS NULL THEN 'new'
                WHEN c.max_weight > p.max_weight THEN 'progressed'
                WHEN c.max_weight = p.max_weight THEN 'stable'
                WHEN c.max_weight < p.max_weight THEN 'regressed'
                ELSE 'unknown'
            END AS trend
        FROM cur c
        LEFT JOIN prev p USING (exercise_name)
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'exercise_name',     exercise_name,
            'current_max',       current_max,
            'previous_max',      previous_max,
            'weight_change',     weight_change,
            'weight_pct_change', weight_pct_change,
            'trend',             trend
        )
        ORDER BY ABS(COALESCE(weight_change, 0)) DESC
    ), '[]'::jsonb)
    INTO v_exercises_delta
    FROM joined;

    -- ── Delta volume per gruppo muscolare ──────────────────────────────────
    WITH cur_vol AS (
        SELECT key AS muscle, value::INT AS sets
        FROM jsonb_each_text(COALESCE(p_current->'volume_by_muscle', '{}'::jsonb))
    ),
    prev_vol AS (
        SELECT key AS muscle, value::INT AS sets
        FROM jsonb_each_text(COALESCE(p_previous->'volume_by_muscle', '{}'::jsonb))
    ),
    all_muscles AS (
        SELECT muscle FROM cur_vol
        UNION
        SELECT muscle FROM prev_vol
    )
    SELECT COALESCE(jsonb_object_agg(
        am.muscle,
        jsonb_build_object(
            'current',  COALESCE(c.sets, 0),
            'previous', COALESCE(p.sets, 0),
            'change',   COALESCE(c.sets, 0) - COALESCE(p.sets, 0)
        )
    ), '{}'::jsonb)
    INTO v_muscle_delta
    FROM all_muscles am
    LEFT JOIN cur_vol  c ON c.muscle = am.muscle
    LEFT JOIN prev_vol p ON p.muscle = am.muscle;

    -- ── OUTPUT ─────────────────────────────────────────────────────────────
    RETURN jsonb_build_object(
        'adherence_pct_change', v_adherence_delta,
        'sessions_change',      v_sessions_delta,
        'exercises',            v_exercises_delta,
        'volume_by_muscle',     v_muscle_delta
    );
END;
$$;

REVOKE ALL ON FUNCTION build_scorecard_delta(jsonb, jsonb) FROM public;
GRANT EXECUTE ON FUNCTION build_scorecard_delta(jsonb, jsonb) TO service_role;
