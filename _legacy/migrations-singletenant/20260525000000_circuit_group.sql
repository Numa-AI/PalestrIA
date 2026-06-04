-- Migration: Add circuit_group column to workout_exercises
-- Allows grouping N (>=2) exercises as a "Circuito" (circuit).
-- Esercizi che condividono lo stesso circuit_group UUID formano un circuito.
-- Gli esercizi non-finali (per sort_order) hanno rest_seconds = 0; l'ultimo ha
-- il riposo dopo ogni giro. Il numero di giri è memorizzato in sets (uguale
-- per tutti gli esercizi del gruppo).

ALTER TABLE workout_exercises
ADD COLUMN IF NOT EXISTS circuit_group UUID DEFAULT NULL;

-- Index for fast lookup of circuit groups
CREATE INDEX IF NOT EXISTS idx_workout_exercises_circuit_group
ON workout_exercises (circuit_group)
WHERE circuit_group IS NOT NULL;
