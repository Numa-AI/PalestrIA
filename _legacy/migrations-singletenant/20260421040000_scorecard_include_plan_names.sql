-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: Scorecard include nomi e note delle schede usate nel mese
-- Aggiunge al JSONB di output un array `plans_used` con i piani di allenamento
-- che hanno prodotto log in quel mese. Serve al prompt AI per adattare tono
-- e contenuto quando la scheda è contestuale (es. "Recupero post infortunio",
-- "Mobilità", "Preparazione gara", ecc.).
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
    v_plans_used        JSONB;
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

    -- ── EXERCISES aggregati per nome pulito (da imported_exercises.nome_it) ──
    WITH logs_in_month AS (
        SELECT
            wl.exercise_id,
            COALESCE(ie.nome_it, we.exercise_name) AS exercise_name,
            we.muscle_group,
            wl.log_date,
            wl.set_number,
            wl.reps_done,
            wl.weight_done
        FROM workout_logs wl
        INNER JOIN workout_exercises we ON we.id = wl.exercise_id
        LEFT JOIN imported_exercises ie ON ie.slug = we.exercise_slug
        WHERE wl.user_id = p_user_id
          AND wl.log_date >= p_month_start
          AND wl.log_date <  p_month_end
    ),
    per_exercise AS (
        SELECT
            exercise_name,
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
            (SELECT weight_done FROM logs_in_month l3
             WHERE l3.exercise_name = l1.exercise_name AND weight_done IS NOT NULL
             ORDER BY log_date ASC, set_number ASC LIMIT 1) AS first_weight,
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

    -- ── VOLUME PER GRUPPO MUSCOLARE ────────────────────────────────────────
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

    -- ── SESSIONI LOGGATE UNICHE ────────────────────────────────────────────
    SELECT COUNT(DISTINCT log_date)::INT
    INTO v_sessions_count
    FROM workout_logs
    WHERE user_id = p_user_id
      AND log_date >= p_month_start
      AND log_date <  p_month_end;

    -- ── PLANS USED: quali schede hanno prodotto log nel mese ───────────────
    -- Utile al prompt AI per contestualizzare il report (es. se la scheda è
    -- "Recupero post infortunio", il tono/linguaggio vanno adattati).
    WITH plans_in_month AS (
        SELECT DISTINCT
            wp.id,
            wp.name,
            wp.notes,
            wp.start_date,
            wp.end_date,
            wp.active,
            COUNT(DISTINCT wl.log_date) AS sessions_in_plan
        FROM workout_logs wl
        INNER JOIN workout_exercises we ON we.id = wl.exercise_id
        INNER JOIN workout_plans      wp ON wp.id = we.plan_id
        WHERE wl.user_id = p_user_id
          AND wl.log_date >= p_month_start
          AND wl.log_date <  p_month_end
        GROUP BY wp.id, wp.name, wp.notes, wp.start_date, wp.end_date, wp.active
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'plan_name',        name,
            'plan_notes',       notes,
            'active',           active,
            'sessions_in_plan', sessions_in_plan
        )
        ORDER BY sessions_in_plan DESC
    ), '[]'::jsonb)
    INTO v_plans_used
    FROM plans_in_month;

    -- ── OUTPUT ─────────────────────────────────────────────────────────────
    RETURN jsonb_build_object(
        'month_start',           p_month_start,
        'month_end_exclusive',   p_month_end,
        'bookings',              v_bookings,
        'exercises',             v_exercises,
        'volume_by_muscle',      v_volume_by_muscle,
        'sessions_logged_count', v_sessions_count,
        'plans_used',            v_plans_used
    );
END;
$$;

REVOKE ALL ON FUNCTION build_month_scorecard_block(uuid, date, date) FROM public;
GRANT EXECUTE ON FUNCTION build_month_scorecard_block(uuid, date, date) TO service_role;
