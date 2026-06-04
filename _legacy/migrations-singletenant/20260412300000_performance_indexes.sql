-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: Indici performance per tab Schede / Importa
-- Risolve rpc_timeout su get_exercise_suggestions, sync admin, catalogo importati
-- ══════════════════════════════════════════════════════════════════════════════

-- 1. workout_exercises.exercise_name — usato dalla RPC get_exercise_suggestions()
--    che fa SELECT DISTINCT exercise_name ORDER BY exercise_name
CREATE INDEX IF NOT EXISTS idx_workout_exercises_name
    ON workout_exercises(exercise_name);

-- 2. workout_plans.updated_at DESC — usato dal sync admin che ordina per updated_at
CREATE INDEX IF NOT EXISTS idx_workout_plans_updated_at
    ON workout_plans(updated_at DESC);

-- 3. imported_exercises(categoria, nome_it) composito — sostituisce i due indici
--    separati per la query ORDER BY categoria, nome_it usata da Schede e Importa
CREATE INDEX IF NOT EXISTS idx_imported_exercises_cat_nome
    ON imported_exercises(categoria, nome_it);
