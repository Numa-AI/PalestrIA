# Riassunto Progetto — PalestrIA SaaS

## Task: Audit codice multi-agente + fix bug gravi
**Data:** 2026-06-09
**Durata stimata:** ~1h lavoro Claude + ~5 min prompt utente

### Modifiche effettuate
Diagnosi con workflow dynamic (8 aree di analisi + verifica avversariale a 2 lenti): 11 bug gravi confermati (1 critical, 8 high, 2 medium), 0 confutati. Tutti fixati:

1. **`send-admin-message` (CRITICAL)** — broadcast push cross-tenant: aggiunta validazione Bearer, derivazione org da `org_members` (owner/admin attivo), scoping `org_id` su tutte le query, insert `client_notifications` con schema reale.
2. **Signup cliente senza org (HIGH)** — `registerUser` passa `org_slug`+`signup_type` (+ safety-net `join_organization`); modal "Completa profilo" in `login.html` salta gli admin e include `org_id`.
3. **Lezione gratuita → incasso fittizio (HIGH)** — `admin_pay_bookings` gestisce `'gratuito'` (amount 0).
4. **Cancellazione senza refund (HIGH)** — `book_slot` traccia pacchetto/membership consumati; `cancel_booking`/`admin_delete_booking` li rimborsano.
5. **`cancel_booking` aggirabile dal cliente (HIGH)** — cutoff temporale server-side per i non-admin (grace/24h/3gg nel timezone org).
6. **Stored XSS pannelli admin (HIGH)** — nuovo `_escAttr` per attributi onclick; applicato a clients/calendar/payments/registro.
7. **`replaceAllBookings` diff vuoto (HIGH)** — mutatori riscritti con oggetti immutabili (`_withBookingPatch`/`_cancelPatch`).
8. **Cache `scheduleOverrides` cross-tenant (HIGH)** — namespacing localStorage per org + cache org-aware + reset al logout.
9. **`notify-slot-available` (MEDIUM)** — auth + scoping org + fix filter-injection + insert corretto.
10. **`generate-monthly-report` (MEDIUM)** — ruolo/org da `org_members`, scoping `org_id` sul target.

### Decisioni prese
- **Refund deterministico**: aggiunte colonne `bookings.consumed_package_id`/`consumed_membership_id` (uuid soft, no FK per ordine di creazione tabelle) popolate in `book_slot`, invece di indovinare quale pacchetto rimborsare.
- **XSS**: un solo helper `_escAttr` (JS-escape poi HTML-escape) invece di toccare ogni call-site con logiche ad-hoc.
- **`cancel_booking`**: NON ristretta ad admin-only (i clienti la usano legittimamente per disdette >24h), ma aggiunto il cutoff server-side che replica la policy UI.
- **Encoding HTML**: i `?v=` bumpati con `[System.IO.File]::ReadAllText/WriteAllText` UTF-8 (il primo tentativo con `Get-Content -Raw` aveva corrotto i file — vedi `tasks/lessons.md`).

### File toccati
- `supabase/functions/send-admin-message/index.ts` — riscritta authz + org scoping
- `supabase/functions/notify-slot-available/index.ts` — riscritta authz + org scoping
- `supabase/functions/generate-monthly-report/index.ts` — claim/org scoping
- `supabase/migrations/00000000000000_baseline.sql` — colonne `consumed_*`, `book_slot`, `admin_pay_bookings`
- `supabase/migrations/00000000000001_operational_rpcs.sql` — `cancel_booking` (refund+cutoff), `admin_delete_booking` (refund)
- `js/ui.js` — nuovo `_escAttr`
- `js/auth.js` — `registerUser` org_slug + reset cache scheduleOverrides al logout
- `js/data.js` — `_withBookingPatch`/`_cancelPatch`, mutatori, namespacing `scheduleOverrides`
- `js/admin-clients.js`, `js/admin-calendar.js`, `js/admin-payments.js`, `js/admin-registro.js` — escaping `_escAttr`
- `login.html` — modal profilo (skip admin + org_id)
- `sw.js` (CACHE v542→v543) + tutti gli `*.html` (`?v=` bump: ui v3, data v83, auth v29, admin-calendar v17, admin-payments v16, admin-clients v8, admin-registro v7)
- `todo.md` — sezione audit con fix e residui

### Da fare dopo (deploy)
- `supabase db push` (schema + RPC) e `supabase functions deploy send-admin-message notify-slot-available generate-monthly-report`.
- Se il progetto remoto ha già la baseline applicata: creare migration ALTER TABLE per le colonne `consumed_*` invece di ri-applicare la baseline.

## Task: Riduzione egress — delta-sync bookings (Pattern A)
**Data:** 2026-06-14
**Durata stimata:** ~1h lavoro Claude + ~15 min prompt utente

### Modifiche effettuate
- `BookingStorage` (js/data.js): innestato un **delta-sync** sul fingerprint già esistente. Il path admin full-list ora decide tra SKIP (fingerprint invariato), DELTA (fingerprint cambiato + count non sceso → scarica solo le righe con `updated_at >= cursore`, merge upsert per `_sbId` preservando sintetici/pending) e FULL (primo load / count sceso = hard-delete / reconcile 5 min). Aggiunti `_DELTA_OVERLAP_MS`, `_parseFingerprint()`, `invalidateDelta()` e una guardia anti-race su `dataLastCleared` prima del commit cache.
- `invalidateDelta()` chiamato dopo le RPC di hard-delete: `admin_delete_booking` e `admin_delete_client_data` (admin-clients.js), `admin_clear_all_data` (admin-backup.js).
- Nuova migration `00000000000014_bookings_updated_at_idx.sql`: indice `bookings_org_updated_idx (org_id, updated_at)` per la query delta.
- Cache-busting: `data.js` v86→v87 (9 pagine), `admin-clients.js` v8→v9, `admin-backup.js` v4→v5, `sw.js` v553→v554.

### Decisioni prese
- **Riuso del fingerprint esistente** invece di sostituirlo: il `count` regala la rilevazione degli hard-delete (count scende → FULL forzato), rendendo il delta più sicuro del gemello single-tenant (che intercettava i DELETE via Realtime, qui assente per `bookings`).
- **Pattern B (TTL su `credit_history`) escluso**: tabella rimossa nella migrazione SaaS; gli storici pesanti rimasti (`profiles`, `workout_plans`) hanno già reconcile/TTL.
- **Solo path admin full-list** toccato (dove sta l'egress); path utente/anon/own invariati. Ramo FULL identico all'originale = fallback a basso rischio.
- **Cursore in RAM** (azzerato al reload): org-switch = reload = ripartenza FULL pulita, nessun rischio cross-tenant; isolamento garantito da RLS `current_org_id()`.

### File toccati
- `js/data.js` — stato delta, logica decisione delta/full, query `gte(updated_at)`, merge upsert-per-id, guardia anti-race.
- `js/admin-clients.js` — `invalidateDelta()` dopo i 2 hard-delete RPC.
- `js/admin-backup.js` — `invalidateDelta()` dopo `admin_clear_all_data`.
- `supabase/migrations/00000000000014_bookings_updated_at_idx.sql` — nuovo indice.
- `admin.html` + 8 pagine + `sw.js` — cache-busting.

### Da fare dopo (deploy)
- `supabase db push` per applicare l'indice + deploy GitHub Pages.
- Verifica: hook `egressReport()` su sessione admin reale (~10 min), confrontare KB su `/rest/v1/bookings` prima/dopo; controllare i log `admin DELTA: N righe cambiate` sui sync successivi al primo FULL; test multi-azione (insert/pagamento/annullo/hard-delete/reconcile) e check 2 org.

## Task: Fix errori console (app_settings 404 + monthly_reports.year_month 400 in loop)
**Data:** 2026-06-14
**Durata stimata:** ~25 min lavoro Claude + ~2 min prompt utente

### Modifiche effettuate
Due root cause distinte, residui della migrazione single-tenant → SaaS:

1. **404 su `app_settings`** — lo scrittore di `clearAllData` era già migrato a `org_settings` (RPC `upsert_org_setting`, key `data_cleared_at`), ma il lettore `syncAppSettingsFromSupabase` (data.js) interrogava ancora la tabella morta `app_settings`. Derivato il marker `data_cleared_at` dal risultato `org_settings` già fetchato e rimossa la query morta (una query in meno per page-load).
2. **400 in loop su `monthly_reports.year_month`** — (a) la baseline aveva uno STUB della tabella (`month`/`tone`/`content`) mentre tutto il codice usa lo schema ricco (`year_month`/`scorecard`/...): forward migration idempotente `00000000000015` che allinea le colonne di lettura; (b) il retry frontend (admin-schede.js) non incrementava il contatore fallimenti sul ramo `if(error)`, quindi il circuit-breaker non scattava mai → reschedule infinito al backoff minimo. Aggiunto l'incremento su errore hard in entrambe le funzioni Actual.

Gli errori `Permissions-Policy`/`content.js` provengono da un'estensione del browser, non dal codice.

### Decisioni prese
- **Scope mirato alla console**: fixati solo i path di LETTURA. La GENERAZIONE dei report AI NON è portata al SaaS (mancano le RPC org-scoped `generate_monthly_scorecard`/`build_*` e l'edge function non passa `org_id` nell'INSERT) → lasciata come TODO security-sensitive separato (rischio data-leak cross-tenant), non inclusa silenziosamente.
- **Realtime su tabelle morte** (`app_settings`/`settings` in index.html/admin.html): non generano errori console → segnalate come follow-up, non toccate (Impatto Minimo).

### File toccati
- `js/data.js` — lettore `data_cleared_at` da org_settings; rimossa query app_settings (v87→v88, 9 pagine)
- `js/admin-schede.js` — circuit-breaker su errore hard nelle 2 funzioni Actual (v44→v45)
- `supabase/migrations/00000000000015_monthly_reports_schema.sql` — nuovo: allinea colonne lettura monthly_reports
- `sw.js` — CACHE_NAME v554→v555

## Task: Fix CI rosso (db-baseline guard + deno check edge functions)
**Data:** 2026-06-14
**Durata stimata:** ~30 min lavoro Claude + ~2 min prompt utente

### Modifiche effettuate
Due job CI fallivano "da sempre", indipendenti dai fix precedenti:
1. **db-baseline — Guard statico USING(true)**: il grep matchava i COMMENTI della baseline che citano testualmente "USING(true)" → exit 1 in ~5s. Aggiunto strip dei commenti SQL (`sed 's/--.*//'`) prima del match in `.github/workflows/ci.yml`.
2. **functions — deno check**: 6 type error. 5× TS2322 da `npm:stripe@17` driftato a 17.7.0 (apiVersion literal `2025-02-24.acacia` vs `2024-12-18.acacia` nel codice) → cast `as any` per preservare la versione API testata. 1× TS18046 in `image-proxy` (`e.message` su `unknown`) → guard `instanceof Error`.

Verificato localmente (deno installato apposta): guard passa, `deno check --no-lock` exit 0. Gli step Docker-dipendenti di db-baseline (db reset, RLS test) non riproducibili in locale ma il guard era il blocco a 5s e la migration 00015 è idempotente.

### File toccati
- `.github/workflows/ci.yml` — guard ignora i commenti SQL
- `supabase/functions/{billing-checkout,billing-portal,create-checkout,stripe-connect,stripe-webhook}/index.ts` — cast apiVersion
- `supabase/functions/image-proxy/index.ts` — catch unknown-safe
