-- ─── WRITE POLICIES PER L'ADMIN + SCHEMA ADDITIONS ──────────────────────────
-- Necessarie per consentire al JS (supabaseClient con anon key + JWT admin)
-- di scrivere direttamente sulle tabelle dedicate.

-- ── Aggiungi free_balance a credits ───────────────────────────────────────────
alter table credits
    add column if not exists free_balance numeric(10,2) not null default 0;

-- ── credits ───────────────────────────────────────────────────────────────────
drop policy if exists "credits_admin_all" on credits;
create policy "credits_admin_all"
    on credits for all to authenticated
    using (is_admin()) with check (is_admin());

-- ── credit_history ────────────────────────────────────────────────────────────
drop policy if exists "credit_history_admin_all" on credit_history;
create policy "credit_history_admin_all"
    on credit_history for all to authenticated
    using (is_admin()) with check (is_admin());

-- ── manual_debts ──────────────────────────────────────────────────────────────
drop policy if exists "manual_debts_admin_all" on manual_debts;
create policy "manual_debts_admin_all"
    on manual_debts for all to authenticated
    using (is_admin()) with check (is_admin());

-- ── bonuses ───────────────────────────────────────────────────────────────────
drop policy if exists "bonuses_admin_all" on bonuses;
create policy "bonuses_admin_all"
    on bonuses for all to authenticated
    using (is_admin()) with check (is_admin());

-- ── schedule_overrides ────────────────────────────────────────────────────────
alter table schedule_overrides
    add column if not exists extras jsonb not null default '[]';

drop policy if exists "schedule_overrides_admin_all" on schedule_overrides;
create policy "schedule_overrides_admin_all"
    on schedule_overrides for all to authenticated
    using (is_admin()) with check (is_admin());

-- ── manual_debts: unique su email (necessario per upsert) ────────────────────
-- Sicuro: manual_debts è vuoto (gym_manual_debts era {})
create unique index if not exists manual_debts_email_unique on manual_debts (email);
