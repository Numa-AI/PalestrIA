-- ─── app_settings key/value store ─────────────────────────────────────────────
-- Tabella storica usata come blob store prima dell'introduzione di tabelle
-- strutturate (credits, manual_debts, schedule_overrides, ecc.). Le migration
-- successive (security_fixes, migrate_app_settings, security_hardening) la
-- referenziano, quindi va creata qui per un DB fresh. Nella demo parte vuota.

create table if not exists app_settings (
    key        text primary key,
    value      jsonb,
    updated_at timestamptz default now()
);
