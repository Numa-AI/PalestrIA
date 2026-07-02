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

## Task: Port "code review 1" dal gemello Thomas (fix.md)
**Data:** 2026-07-02
**Durata stimata:** ~2h lavoro Claude + ~5 min prompt utente

### Modifiche effettuate
Portati da `fix.md` (guida di replica del gemello single-tenant Thomas) **solo i finding realmente applicabili** a PalestrIA: dei 23 finding, la maggior parte era già coperta dalla baseline SaaS o non applicabile (sistema crediti rimosso, feature Thomas assenti). Ricognizione fatta con 3 subagent paralleli (DB, frontend, HTML/edge) per mappare ogni fix allo stato reale. `code-review2.md` rimandata su richiesta utente.

- **Migration `00000000000023_code_review_fixes.sql`** (incrementale, org-scoped, idempotente):
  - 1.2 — trigger `_trg_profiles_block_self_admin_flags` anti self-update di `documento_firmato` (unico flag admin-only presente).
  - 1.7 — `admin_delete_client_data(p_email, p_whatsapp)`: firma estesa + delete cliente esteso alle tabelle billing/notifiche (payments preservato).
  - 1.8 — `admin_prune_old_data(cutoff)`: prune server-side org-scoped.
- **Frontend**: `admin-analytics.js` (mask `***` importi + escape nomi in renderClientiDetail), `admin-clients.js` (escAttr onclick + guard data.success + deleteClientData server-first/whatsapp), `admin-backup.js` (prune via RPC), `data.js` (`,notes` select log + reorderExercises base-min + `_retryPending` via `book_slot`), `allenamento.html` (dequeue coda offline su delete log + blocco CIRCUITO nel PDF), `generate-monthly-report/index.ts` (rate-limit `!isAdmin`).
- **Cache-busting**: `sw.js` v574→v575; `data.js?v=94→95` (9 pagine); admin-analytics v10→11, backup v9→10, clients v14→15.

### Decisioni prese
- **Tablet resta editabile** (11.3 NON portato): il kiosk di PalestrIA è editabile per scelta (migration 00016 con RPC `kiosk_*` + ownership); portare il read-only del gemello avrebbe rimosso una feature voluta. Decisione utente.
- **Token QR tablet rimandato** (1.5/10.2/11.1/11.2): sostituire l'UUID permanente nel QR con token opaco a scadenza è hardening reale ma richiede un cantiere DB org-aware (tabella + 2 RPC + adattamento delle 12 RPC kiosk da `p_uid` a token). Task separato. Decisione utente.
- **Delete cliente conservativo**: cancella dati operativi + artefatti billing, ma NON la riga `profiles` né il ledger `payments` (storico fatturato), coerente con il pattern esistente.
- **Non toccati i punti già coperti/N/A**: RLS bookings, workout_logs.rest_done, circuit_group in duplicate_plan, `_localDateStr`, escaping admin-payments/calendar, conferme IMPORTA/ELIMINA/BLOCCA, tutto ciò che dipendeva da crediti/credit_history/stripe_topup (rimossi).

### File toccati
- `supabase/migrations/00000000000023_code_review_fixes.sql` — nuovo (trigger + 2 RPC)
- `supabase/functions/generate-monthly-report/index.ts` — rate-limit `!isAdmin`
- `js/admin-analytics.js` — mask importi + escape nomi (v11)
- `js/admin-clients.js` — escAttr + guard data.success + deleteClientData server-first (v15)
- `js/admin-backup.js` — pruneOldData via RPC (v10)
- `js/data.js` — select notes + reorder base-min + retry via book_slot (v95, 9 pagine)
- `allenamento.html` — dequeue offline + PDF circuiti
- `sw.js` — CACHE_NAME v575
- `todo.md`, memoria `stato-progetto` — tracking

### Follow-up aperti
- DEPLOY: `supabase db push` (mig.0023) + `functions deploy generate-monthly-report` + push Pages + QA staging (checklist `fix.md` §13).
- TODO futuro: token QR tablet opaco; `code-review2.md` (20 item, rimandata).

## Task: Port "code review 2" + voci UI Thomas (2° batch)
**Data:** 2026-07-02
**Durata stimata:** ~2.5h lavoro Claude + ~10 min prompt utente

### Modifiche effettuate
Portati da `code-review2.md` e dalle voci nuove del changelog Thomas **solo i punti applicabili** (molti N/A: sistema crediti rimosso, flussi/tab Thomas assenti, funzioni morte già rimosse dall'audit). Ricognizione con 3 subagent paralleli.

- **Migration `00000000000024_availability_capacity_coherence.sql`** (#1 HIGH) — `get_availability_range`/`get_slot_availability` contano `cancellation_requested` come `book_slot` (fix "posto fantasma" + "richiedi annullamento" rotto). Applicata sul remoto.
- **data.js** — `getRemainingSpots` allineato (conta `cancellation_requested`); `getStats()` via `_lsGetJSON` (#4).
- **admin-calendar.js** — badge "Pagato/Da pagare" per-lezione in `_buildParticipantCard` (era aggregato); `_scrollToCurrentAdminSlot` dual-mode (shell).
- **admin-payments.js + admin.html** — toggle "Seleziona passate" in `openDebtPopup` (+ `_syncDebtToggleStates`).
- **Shell iOS strutturale (solo admin.html)** — `css/admin.css` sezione shell scopata a `html.adm-shell-page`; rimossa IIFE `--adm-fixed-correction-y`; `pull-to-refresh.js`/`admin.js` dual-mode.
- **Codice morto** rimosso (showInlineError/hideInlineError/weekHasSlots/hideDashboard/toggleRegistroFiltersPanel); **modulo_viewer.html** eliminato + tolto da APP_SHELL.
- **CSS `?v=` allineati** (#6): login.css v6, allenamento.css v57. Cache-bust `sw.js` palestria-v576.

### Decisioni prese
- **Shell iOS strutturale portata (solo admin, come Thomas)** su richiesta utente; da testare su iPhone (io non posso). Scopata a iOS-standalone ≤768px + `html.adm-shell-page` (super-admin.html non toccata).
- **Codice morto — rimozione selettiva**: rimosse le funzioni di puro cruft; TENUTI `exportRegistro` (export Excel latente, TB-branded), `_schedeViewProgress`/`_renderProgressView` (vista Progressi schede) e `openProfileModal` (profile-modal in 5 HTML) perché sono entry-point di feature latenti / catene la cui rimozione parziale lascerebbe più morto di quanto ne tolga. Segnalati come cleanup futuro.
- **N/A confermati**: #2 accept_offered_request (flusso assente), #3 admin_pay_bookings/admin_add_credit (crediti rimossi), tab Richieste (modulo assente), client-credit items.

### File toccati
- `supabase/migrations/00000000000024_availability_capacity_coherence.sql` — nuovo
- `js/data.js`, `js/admin-calendar.js`, `js/admin-payments.js`, `admin.html` — fix funzionali + shell
- `css/admin.css` — sezione shell; `js/pull-to-refresh.js`, `js/admin.js` — dual-mode shell
- `js/ui.js`, `js/calendar.js`, `js/admin-registro.js` — rimozione codice morto
- `modulo_viewer.html` — eliminato; `sw.js` — APP_SHELL + CACHE_NAME v576
- 11 pagine HTML — bump `?v=` asset; `todo.md`/memoria — tracking

### Follow-up aperti
- DEPLOY Pages: push branch (fatto in coda al task).
- QA: **shell iOS su iPhone reale** (barra ferma su fling, cambio tab, PTR da cima, tastiera, chiusura/riapertura); capienza slot con annullamento pendente; badge per-lezione; "Seleziona passate".
- Cleanup futuro opzionale: exportRegistro / vista Progressi schede / openProfileModal.
