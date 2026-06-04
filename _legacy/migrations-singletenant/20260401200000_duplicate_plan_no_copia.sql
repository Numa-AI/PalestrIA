-- Fix: rimuove " (copia)" dal nome della scheda duplicata
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
