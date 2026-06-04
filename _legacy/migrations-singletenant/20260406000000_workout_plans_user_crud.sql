-- ═══════════════════════════════════════════════════════════════════════════════
-- Permette agli utenti di creare/modificare/eliminare le PROPRIE schede
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── workout_plans: INSERT/UPDATE/DELETE own ──────────────────────────────────
CREATE POLICY workout_plans_insert_own ON workout_plans
    FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

CREATE POLICY workout_plans_update_own ON workout_plans
    FOR UPDATE TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY workout_plans_delete_own ON workout_plans
    FOR DELETE TO authenticated
    USING (user_id = auth.uid());

-- ── workout_exercises: INSERT/UPDATE/DELETE on own plans ─────────────────────
CREATE POLICY workout_exercises_insert_own ON workout_exercises
    FOR INSERT TO authenticated
    WITH CHECK (plan_id IN (SELECT id FROM workout_plans WHERE user_id = auth.uid()));

CREATE POLICY workout_exercises_update_own ON workout_exercises
    FOR UPDATE TO authenticated
    USING (plan_id IN (SELECT id FROM workout_plans WHERE user_id = auth.uid()))
    WITH CHECK (plan_id IN (SELECT id FROM workout_plans WHERE user_id = auth.uid()));

CREATE POLICY workout_exercises_delete_own ON workout_exercises
    FOR DELETE TO authenticated
    USING (plan_id IN (SELECT id FROM workout_plans WHERE user_id = auth.uid()));

-- ── workout_logs: DELETE own ─────────────────────────────────────────────────
-- Policy workout_logs_own_delete già presente su Supabase (creata manualmente)
