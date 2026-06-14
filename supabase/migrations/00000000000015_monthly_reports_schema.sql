-- ══════════════════════════════════════════════════════════════════════════════
-- PalestrIA SaaS — Allinea lo schema di monthly_reports al codice applicativo
-- ──────────────────────────────────────────────────────────────────────────────
-- La baseline aveva portato uno STUB della tabella (colonne month/tone/content),
-- ma tutto il codice (js/admin-schede.js, js/allenamento-report.js e l'edge
-- function generate-monthly-report) usa lo schema "ricco" del report AI:
-- year_month + scorecard/narrative/status/model_used/tokens/cost_usd/generated_at.
-- Risultato: i SELECT su year_month tornavano 400 ("column ... does not exist")
-- e martellavano la console dal tab Schede → Actual.
--
-- Questa migration ripristina le colonne di LETTURA così le query tornano 200.
-- Idempotente e sicura: la tabella è di fatto vuota sul progetto SaaS (gli INSERT
-- dell'edge function fallivano già per le colonne mancanti).
--
-- ⚠️ NOTA — la GENERAZIONE dei report NON è ancora portata al SaaS e resta un TODO
-- a parte (security-sensitive): mancano le RPC org-scoped generate_monthly_scorecard
-- /build_month_scorecard_block/build_scorecard_delta e l'edge function non passa
-- org_id nell'INSERT. Vanno portate con filtro org_id esplicito (rischio data-leak
-- cross-tenant, cfr. CLAUDE.md §3) prima di abilitare la generazione.
-- ══════════════════════════════════════════════════════════════════════════════

-- 1. month → year_month (solo se serve: rename idempotente)
do $$
begin
    if exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'monthly_reports' and column_name = 'month'
    ) and not exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'monthly_reports' and column_name = 'year_month'
    ) then
        alter table monthly_reports rename column month to year_month;
    end if;
end $$;

-- 2. Colonne dello schema "ricco" usate da lettori + edge function
alter table monthly_reports
    add column if not exists year_month    text,
    add column if not exists scorecard     jsonb,
    add column if not exists narrative     text,
    add column if not exists status        text not null default 'pending',
    add column if not exists model_used    text,
    add column if not exists input_tokens  int,
    add column if not exists output_tokens int,
    add column if not exists cost_usd      numeric(8,5),
    add column if not exists error_message text,
    add column if not exists generated_at  timestamptz,
    add column if not exists updated_at    timestamptz not null default now();

-- 3. Indice di lettura (badge "report generato" per (user, mese) + fetch più recente)
create index if not exists monthly_reports_user_month_idx
    on monthly_reports (org_id, user_id, year_month, generated_at desc)
    where status = 'generated';
