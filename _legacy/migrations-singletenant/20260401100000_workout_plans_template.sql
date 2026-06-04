-- ══════════════════════════════════════════════════════════════════════════════
-- Schede template: user_id diventa opzionale (NULL = template standard)
-- ══════════════════════════════════════════════════════════════════════════════

ALTER TABLE workout_plans ALTER COLUMN user_id DROP NOT NULL;
