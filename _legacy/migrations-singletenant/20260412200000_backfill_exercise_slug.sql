-- ── Backfill exercise_slug su workout_exercises esistenti ────────────────────
-- Prova prima il match su nome_it (nome corrente), poi su nome_original
-- (nome al momento dell'importazione, invariante anche dopo rinomina).
-- Le righe che non matchano nessuno dei due restano NULL e useranno il
-- fallback nome-based nel codice frontend.

-- 1. Match su nome corrente (nome_it)
UPDATE workout_exercises we
SET    exercise_slug = ie.slug
FROM   imported_exercises ie
WHERE  we.exercise_slug IS NULL
  AND  we.exercise_name = ie.nome_it;

-- 2. Match su nome originale (per esercizi già rinominati in Importa)
UPDATE workout_exercises we
SET    exercise_slug = ie.slug
FROM   imported_exercises ie
WHERE  we.exercise_slug IS NULL
  AND  we.exercise_name = ie.nome_original;
