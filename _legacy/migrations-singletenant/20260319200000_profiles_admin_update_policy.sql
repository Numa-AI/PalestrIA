-- ─── Aggiunge policy admin UPDATE su profiles ──────────────────────────────
-- La policy profiles_update_own (auth.uid() = id) impedisce all'admin di
-- aggiornare i profili degli altri utenti (es. nome, cert, assicurazione).
-- Questa policy consente all'admin di modificare qualsiasi profilo.

DROP POLICY IF EXISTS "profiles_admin_update" ON profiles;
CREATE POLICY "profiles_admin_update"
    ON profiles FOR UPDATE TO authenticated
    USING (is_admin());
