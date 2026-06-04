-- Migration: Add superset_group column to workout_exercises
-- Allows pairing two exercises as a "Super Serie" (superset)
-- Two exercises sharing the same superset_group UUID form a superset pair.
-- The first exercise (by sort_order) has rest_seconds = 0; the second has the actual rest.

ALTER TABLE workout_exercises
ADD COLUMN IF NOT EXISTS superset_group UUID DEFAULT NULL;

-- Index for fast lookup of superset pairs
CREATE INDEX IF NOT EXISTS idx_workout_exercises_superset_group
ON workout_exercises (superset_group)
WHERE superset_group IS NOT NULL;
