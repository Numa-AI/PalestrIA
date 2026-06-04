-- ─── FIX PRE GO-LIVE ─────────────────────────────────────────────────────────

-- ── 1. settings: policy di scrittura per l'admin ──────────────────────────────
-- La tabella aveva solo settings_select_public (lettura pubblica).
-- Senza questa policy, _upsertSetting() fallisce silenziosamente per l'admin.
drop policy if exists "settings_admin_write" on settings;
create policy "settings_admin_write"
    on settings for all to authenticated
    using (is_admin()) with check (is_admin());

-- ── 2. profiles: lettura admin di tutti i profili ─────────────────────────────
-- profiles_select_own permette solo auth.uid() = id.
-- L'admin deve poter leggere tutti i profili (dati anagrafici, cert, assicurazione).
drop policy if exists "profiles_admin_read" on profiles;
create policy "profiles_admin_read"
    on profiles for select to authenticated
    using (is_admin());
