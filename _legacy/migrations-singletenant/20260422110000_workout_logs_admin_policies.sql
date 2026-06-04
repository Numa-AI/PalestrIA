-- ─── workout_logs: admin bypass ───────────────────────────────────────────────
-- L'admin deve poter inserire/aggiornare/cancellare log per i propri clienti
-- (es. registrando un allenamento da tablet con uid cliente, o rettifiche dal
-- pannello admin). Le policy per-utente esistenti restano attive.

DROP POLICY IF EXISTS workout_logs_admin_insert ON workout_logs;
CREATE POLICY workout_logs_admin_insert ON workout_logs
    FOR INSERT TO authenticated
    WITH CHECK (is_admin());

DROP POLICY IF EXISTS workout_logs_admin_update ON workout_logs;
CREATE POLICY workout_logs_admin_update ON workout_logs
    FOR UPDATE TO authenticated
    USING (is_admin());

DROP POLICY IF EXISTS workout_logs_admin_delete ON workout_logs;
CREATE POLICY workout_logs_admin_delete ON workout_logs
    FOR DELETE TO authenticated
    USING (is_admin());
