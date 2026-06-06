-- ──────────────────────────────────────────────────────────────────────────────
-- 00000000000009_profiles_updated_at
--
-- Aggiunge updated_at + trigger a `profiles`, così il client può usare il
-- fingerprint-skip (count + max(updated_at)) anche su syncUsersFromSupabase e saltare
-- il re-fetch dei profili al wake quando nulla è cambiato (resume parallelo → il
-- wall-clock = il più lento dei sync; serve velocizzare anche profiles, non solo bookings).
--
-- Additivo e sicuro: su DB vuoto nessuna riga; il default now() backfilla eventuali
-- righe esistenti, il trigger lo aggiorna ad ogni UPDATE. trg_set_updated_at() è la
-- stessa funzione già usata da bookings/organizations/subscriptions/workout_plans.
-- ──────────────────────────────────────────────────────────────────────────────

alter table profiles add column if not exists updated_at timestamptz not null default now();

drop trigger if exists profiles_updated_at on profiles;
create trigger profiles_updated_at before update on profiles
    for each row execute function trg_set_updated_at();
