-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: Svuota tutti i dati vecchi di schede/esercizi/log
-- workout_plans CASCADE elimina anche workout_exercises e workout_logs (FK)
-- ══════════════════════════════════════════════════════════════════════════════

TRUNCATE workout_logs, workout_exercises, workout_plans CASCADE;
