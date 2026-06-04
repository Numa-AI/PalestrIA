-- ── Add exercise_slug to workout_exercises ───────────────────────────────────
-- Stores the stable slug from imported_exercises so renames in the catalog
-- do not break the link between a scheda exercise and its media/video.
ALTER TABLE workout_exercises ADD COLUMN IF NOT EXISTS exercise_slug TEXT;
