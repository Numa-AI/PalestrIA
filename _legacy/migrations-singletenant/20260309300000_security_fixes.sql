-- ─── SECURITY FIXES ──────────────────────────────────────────────────────────

-- 1. UNIQUE su local_id: evita che retry di scrittura creino booking duplicati.
--    Indice parziale: ignora le righe con local_id NULL (booking pre-migrazione).
alter table bookings
    add column if not exists local_id text;

create unique index if not exists bookings_local_id_unique
    on bookings (local_id)
    where local_id is not null;

-- 2. app_settings: attiva RLS e limita le scritture ai soli utenti autenticati.
--    Le letture rimangono pubbliche (prezzi, impostazioni visibili nel sito).
--    Le scritture (crediti, debiti, orari) le fa solo l'admin → sempre autenticato.
alter table app_settings enable row level security;

drop policy if exists "app_settings_public_read" on app_settings;
create policy "app_settings_public_read"
    on app_settings for select using (true);

drop policy if exists "app_settings_auth_insert" on app_settings;
create policy "app_settings_auth_insert"
    on app_settings for insert to authenticated with check (true);

drop policy if exists "app_settings_auth_update" on app_settings;
create policy "app_settings_auth_update"
    on app_settings for update to authenticated using (true);

drop policy if exists "app_settings_auth_delete" on app_settings;
create policy "app_settings_auth_delete"
    on app_settings for delete to authenticated using (true);
