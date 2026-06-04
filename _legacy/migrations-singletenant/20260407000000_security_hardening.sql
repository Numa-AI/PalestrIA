-- ─── Security hardening: search_path + RLS policies ─────────────────────────
-- 1. Aggiunge SET search_path = public a tutte le funzioni SECURITY DEFINER
--    che ne erano prive (previene schema pollution attacks).
-- 2. Restringe app_settings INSERT/UPDATE/DELETE a is_admin() (prima era
--    aperto a qualsiasi utente autenticato).
-- 3. Restringe bookings INSERT policy a user_id = auth.uid() (prima era
--    WITH CHECK (true) per qualsiasi autenticato).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. SET search_path = public sulle funzioni SECURITY DEFINER che ne erano prive
-- ═══════════════════════════════════════════════════════════════════════════════

-- book_slot_atomic (13 parametri, ultima versione da track_actor.sql)
ALTER FUNCTION book_slot_atomic(text, uuid, text, text, text, integer, text, text, text, text, timestamptz, text)
    SET search_path = public;

-- Trigger functions (schema_hardening.sql)
ALTER FUNCTION _trg_audit_credit_change()
    SET search_path = public;
ALTER FUNCTION _trg_audit_debt_change()
    SET search_path = public;
ALTER FUNCTION _trg_audit_bonus_change()
    SET search_path = public;

-- handle_new_user (trigger, indirizzo_residenza.sql)
ALTER FUNCTION handle_new_user()
    SET search_path = public;

-- get_all_profiles (ultima versione da privacy_prenotazioni.sql)
ALTER FUNCTION get_all_profiles()
    SET search_path = public;

-- get_slot_attendees (privacy_prenotazioni.sql)
ALTER FUNCTION get_slot_attendees(date, text)
    SET search_path = public;

-- auto_link_credit_user_id (trigger, fix_credits_user_visibility.sql)
ALTER FUNCTION auto_link_credit_user_id()
    SET search_path = public;

-- link_anonymous_on_register (trigger, fix_credits_user_visibility.sql)
ALTER FUNCTION link_anonymous_on_register()
    SET search_path = public;

-- mark_booking_arrived (proximity_tracking.sql)
ALTER FUNCTION mark_booking_arrived(uuid)
    SET search_path = public;

-- set_geo_enabled (proximity_tracking.sql)
ALTER FUNCTION set_geo_enabled(boolean)
    SET search_path = public;

-- get_push_enabled_users (proximity_tracking.sql)
ALTER FUNCTION get_push_enabled_users()
    SET search_path = public;

-- set_push_enabled (push_enabled_profile.sql)
ALTER FUNCTION set_push_enabled(boolean)
    SET search_path = public;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. app_settings: solo admin può modificare
-- ═══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "app_settings_auth_insert" ON app_settings;
DROP POLICY IF EXISTS "app_settings_auth_update" ON app_settings;
DROP POLICY IF EXISTS "app_settings_auth_delete" ON app_settings;

CREATE POLICY "app_settings_admin_insert"
    ON app_settings FOR INSERT TO authenticated
    WITH CHECK (is_admin());

CREATE POLICY "app_settings_admin_update"
    ON app_settings FOR UPDATE TO authenticated
    USING (is_admin());

CREATE POLICY "app_settings_admin_delete"
    ON app_settings FOR DELETE TO authenticated
    USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. bookings INSERT: solo il proprio user_id (la RPC book_slot_atomic è
--    SECURITY DEFINER e bypassa RLS, quindi continua a funzionare normalmente)
-- ═══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "bookings_authenticated_insert" ON bookings;

CREATE POLICY "bookings_authenticated_insert"
    ON bookings FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid() OR is_admin());
