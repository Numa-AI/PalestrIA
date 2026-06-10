-- ─────────────────────────────────────────────────────────────────────────────
-- Migration incrementale — org_id default su workout_plans/exercises/logs
-- ─────────────────────────────────────────────────────────────────────────────
-- Sintomo: la creazione scheda fallisce con
--   null value in column "org_id" of relation "workout_plans" violates not-null constraint
-- (idem aggiungendo esercizi/superserie → workout_exercises, e log set → workout_logs).
-- Causa: il frontend (WorkoutPlanStorage/WorkoutLogStorage in js/data.js) e' codice
-- nato single-tenant: gli INSERT in workout_plans/workout_exercises/workout_logs NON
-- passano org_id, ma nello schema SaaS quelle colonne sono NOT NULL (senza default).
-- Fix (stesso pattern di 00000000000011 su imported_exercises): org_id default =
-- current_org_id() cosi' l'INSERT eredita la org corrente e soddisfa anche la RLS
-- di scrittura (workout_*_admin → is_org_admin(org_id); workout_logs_own_write →
-- org_id = current_org_id() AND user_id = auth.uid()). Nessuna modifica al JS, nessun
-- cache-bust. Le RPC che gia' impostano org_id esplicitamente (es. admin_duplicate_plan)
-- non sono toccate: il default si applica solo quando org_id e' omesso.
--
-- NOTA: bookings ha lo stesso INSERT senza org_id nel path offline-retry
-- (data.js _retryPending), ma li' un default non basterebbe: la policy
-- bookings_admin_write richiede is_org_admin, quindi le prenotazioni utente devono
-- passare comunque dalla RPC book_slot (che imposta org_id server-side). Non toccato qui.
-- ─────────────────────────────────────────────────────────────────────────────

alter table workout_plans     alter column org_id set default current_org_id();
alter table workout_exercises alter column org_id set default current_org_id();
alter table workout_logs      alter column org_id set default current_org_id();
