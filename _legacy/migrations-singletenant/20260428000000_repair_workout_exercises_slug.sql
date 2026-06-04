-- Repair one-shot: aggancia/sincronizza workout_exercises con imported_exercises.
-- Idempotente: rilanciarla non rompe nulla.

-- 1. Backfill slug + sync nome sulle orfane (case-insensitive, trimmed)
UPDATE workout_exercises we
SET    exercise_slug = ie.slug,
       exercise_name = ie.nome_it
FROM   imported_exercises ie
WHERE  we.exercise_slug IS NULL
  AND  (
        LOWER(TRIM(we.exercise_name)) = LOWER(TRIM(ie.nome_it))
     OR (ie.nome_original IS NOT NULL
         AND LOWER(TRIM(we.exercise_name)) = LOWER(TRIM(ie.nome_original)))
  );

-- 2. Sync nome sulle righe gia' linkate via slug ma desync (rinomine pre-fix)
UPDATE workout_exercises we
SET    exercise_name = ie.nome_it
FROM   imported_exercises ie
WHERE  we.exercise_slug IS NOT NULL
  AND  we.exercise_slug = ie.slug
  AND  we.exercise_name IS DISTINCT FROM ie.nome_it;
