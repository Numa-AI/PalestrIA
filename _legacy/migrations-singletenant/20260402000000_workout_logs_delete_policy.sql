-- Consenti ai client di eliminare i propri log di allenamento
CREATE POLICY workout_logs_own_delete ON workout_logs
    FOR DELETE TO authenticated
    USING (user_id = auth.uid());
