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

---

## Task: Port "security review" dal gemello Thomas (XSS admin, blocco email, edge notify)
**Data:** 2026-07-03
**Durata stimata:** ~40 min lavoro Claude + ~5 min prompt utente

Portati dall'entry `2026-07-03 — Security review` del changelog Thomas **solo i finding applicabili**. Ricognizione con 3 subagent paralleli (XSS admin / RPC SQL / edge notify) prima di toccare codice. La maggioranza dei fix SQL del gemello è **N/A**: agiscono sul sistema crediti rimosso in PalestrIA o su feature/flussi assenti.

### Modifiche effettuate
- **Migration `00000000000025_profiles_block_self_email.sql`** (incrementale sopra 0023) — estende la trigger function `_trg_profiles_block_self_admin_flags` per bloccare anche il **self-change di `profiles.email`** verso un valore diverso. Vettore: un cliente non-admin che via PostgREST cambia la propria email in quella di un altro utente della org per agganciarne le prenotazioni guest (link per email+org). Blocco non distruttivo (revert del valore) mirato a `auth.uid() = old.id AND NOT is_org_admin`; esenti prima-assegnazione, admin e contesti server (service_role → `auth.uid()` NULL). `documento_firmato` invariato.
- **XSS frontend (3 sink residui)** — gli altri 8 sink del gemello erano già `_escAttr`/`_escHtml` in PalestrIA:
  - `js/admin-settings.js` (health-check) — `item.email`/`booking_email`/`profile_email`/`date` (dati cliente) finivano grezzi in innerHTML → `_escHtml`. Unico vero vettore cliente→admin ancora aperto.
  - `js/admin-schede.js` ×2 — `_escHtml(name).replace(/'/g,"\\'")` (solo-apice, breakout via `\`) → `_escAttr`.
  - `js/admin-clients.js` 713/715 (`plan.name` in onclick) — 715 non escapava l'apice (XSS + bug reale su nomi con apostrofo) → `_escAttr`.
- **Edge notify anti-spoofing** — `name` mostrato agli admin (push + `admin_messages`) non più dal body forgiabile ma server-side:
  - `notify-admin-new-client` — dal profilo del chiamante (`select org_id, name where id = auth.uid()`); body fallback.
  - `notify-admin-booking` / `notify-admin-cancellation` — dalla riga `bookings` (`select org_id, name` via `booking_id`, scritto da `book_slot`); body fallback. Adattamento chiave rispetto al gemello: qui il client autentica con **anon key** (no `auth.uid()`), quindi la fonte server è la prenotazione, non il profilo.
- **Fix UI plurali** (`admin-payments.js` `openDebtPopup`) — il sottotitolo del popup "Registra incasso" appendeva una lettera invece di sostituire la vocale finale → per il plurale mostrava "lezione**i**/pagata**e**/passata**e**/futura**e**". Ora forma corretta "lezioni/pagate/passate/future". (Unico gap UI reale emerso dal check completo del changelog Thomas: tutto il resto — redesign tab Clienti, card partecipante, popup nuovo cliente, stats anti-skeleton, SW no-reload, registro fetch autoritativo — è già presente o N/A per crediti/Richieste assenti.)
- **Cache-busting**: `sw.js` `CACHE_NAME` → **palestria-v577**; `admin.html` `?v=` admin-settings 9→10 / admin-clients 15→16 / admin-schede 51→52 / admin-payments 19→20. `node --check` OK su tutti i JS.

### Decisioni prese
- **Scope guidato dall'architettura, non copia alla cieca**: il `.lnk` `Aggiornamenti Thomas.md` aveva TargetPath vuoto (creato su altra macchina, utente `andrea`) → letto il file vero (`Thomas Bresciani/Aggiornamenti.md`). Verificato ogni finding nel codice PalestrIA prima di decidere.
- **N/A confermati**: `apply_credit_on_booking`/`apply_credit_to_past_bookings`/`fulfill_pending_cancellation` (crediti rimossi, refund già server-side, niente grant anon), `book_slot_atomic` identity-spoofing (`book_slot` usa già `p_for_user_id` dietro `is_org_admin`+appartenenza org), `notify-access-request-update`/git-history purge/repo privato (feature Thomas assenti o fuori scope PalestrIA).
- **Blocco email mirato a self-update** (`auth.uid()=old.id`) invece del solo `NOT is_org_admin`: evita di rompere admin, signup (INSERT) e edge/service-role, che sono i soli flussi legittimi di cambio email.

### File toccati
- `supabase/migrations/00000000000025_profiles_block_self_email.sql` — nuovo (blocco self-change email)
- `js/admin-settings.js`, `js/admin-schede.js`, `js/admin-clients.js` — escaping XSS sink
- `supabase/functions/notify-admin-{booking,cancellation,new-client}/index.ts` — nome server-side anti-spoofing
- `sw.js` (CACHE_NAME v577), `admin.html` (bump `?v=`) — cache-busting
- `todo.md`, memoria `stato-progetto` — tracking

### Follow-up aperti
- **DEPLOY**: `supabase db push` (0025) + `supabase functions deploy notify-admin-booking notify-admin-cancellation notify-admin-new-client` + push branch (Pages, cache-bust v577). `deno check` da far girare in CI (deno non installato in locale).
- **QA produzione**: (1) cliente non-admin non cambia la propria `profiles.email` via PostgREST, admin sì, signup/edit-admin OK; (2) nome-body forgiato ≠ nome booking → la notifica admin mostra quello della prenotazione; (3) health-check settings con email cliente contenente HTML → nessuna esecuzione.

---

## Task: Setup toolchain Flutter/Android su nuovo PC + build & install APK aggiornato sul telefono
**Data:** 2026-07-08
**Durata stimata:** ~40 min lavoro Claude + ~5 min prompt utente

### Contesto
L'utente voleva installare l'app Flutter aggiornata sul proprio Galaxy A54 collegato via USB, ma **questo PC** (`C:\Users\andre`) non aveva alcuna toolchain (né Flutter, né Java, né Android SDK): l'app finora veniva compilata sull'**altro PC** (`C:\Users\andrea\VM-Nextcloud`). L'APK in `build/` era di ieri (sincronizzato via Nextcloud) e mancava i fix onboarding del commit `e4dd8dd`. L'utente ha chiesto esplicitamente di **installare tutta la toolchain qui e compilare da qui**.

### Modifiche effettuate (ambiente, nessun codice progetto toccato in modo permanente)
- **JDK 21 Temurin** installato via winget → `C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot`.
- **Flutter 3.44.5 stable** (Dart 3.12.2, combacia col pubspec `^3.12.2`) clonato in `C:\flutter`.
- **Android SDK** in `C:\Users\andre\AppData\Local\Android\Sdk`: cmdline-tools + platform-tools 37 + `platforms;android-36` + `build-tools;36.0.0` (+ NDK 28.2 e CMake 3.22 auto-installati da Gradle). Licenze accettate via redirezione `cmd < yes.txt` (il pipe PowerShell verso lo script `.bat` non propagava lo stdin).
- `flutter config --android-sdk … --jdk-dir …` + `flutter pub get`.
- Compilato `app-release.apk` (64.1 MB) e installato sul Galaxy A54 (uninstall+install per firma diversa), avvio verificato.

### Problemi risolti durante il build
1. **Path assoluti stale dell'altro PC** (`C:\Users\andrea\VM-Nextcloud\…`) dentro `build/`, `.dart_tool/`, `android/.gradle/` (gitignorati ma **sincronizzati via Nextcloud**) → `Failed to create parent directory 'C:\Users\andrea'`. Risolto con `flutter clean` + rimozione `android/.gradle`.
2. **`android/key.properties`** (gitignorato, sincronizzato dall'altro PC) punta al keystore `C:/Users/andrea/keystores/palestria-upload.jks` (vera upload key Play Store, assente qui) → `validateSigningRelease` fallito. Risolto **spostando temporaneamente** `key.properties` (la `build.gradle.kts` ripiega su firma debug) e **rimettendolo subito a posto** — senza modificare nulla di sincronizzato in modo permanente (una modifica si sarebbe propagata all'altro PC rompendogli la firma).
3. **Firma debug ≠ firma release installata** → `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Risolto con `adb uninstall com.palestria.app` + `adb install` (persi solo i dati locali; il resto è su Supabase → re-login).

### Decisioni prese
- **Non toccare `key.properties`/`build.gradle.kts` in modo permanente**: il progetto è in cartella Nextcloud condivisa; qualsiasi modifica ai file sincronizzati si sarebbe propagata all'altro PC. Preferito lo spostamento temporaneo self-healing.
- **Keystore locale al path `C:\Users\andrea\…` non creabile** (permessi Windows su `C:\Users`) → scartata l'idea di generare un keystore fittizio lì; usata la firma di debug prevista dal fallback della build.
- **Per il Play Store si continua a usare l'altro PC** (ha la vera upload key). Questo PC serve solo per build/test locali.

### File toccati
- Nessun file del progetto modificato in modo permanente (`key.properties` spostato e ripristinato; cache `build/`/`.dart_tool/`/`android/.gradle` ripulite e rigenerate).
- Nuova memoria di progetto: `memory/build-env-flutter.md` (toolchain + gotcha Nextcloud).

### Follow-up aperti
- **Consigliato**: escludere `build/`, `.dart_tool/`, `android/.gradle/` dalla sincronizzazione Nextcloud (sono per-macchina, pesanti, gitignorati) per evitare il ripresentarsi dei path stale ad ogni build.
- L'APK installato è **firmato debug** (ok per test personale, NON per Play Store).

---

## Task: Uniformazione grafica app Flutter (design system) + audit parità PWA↔Flutter
**Data:** 2026-07-08
**Durata stimata:** ~3h lavoro Claude (11 subagent: 7 audit + 9 fix in 2 ondate) + ~10 min prompt utente

### Contesto
Nel port PWA→Flutter la grafica era divergente (ogni schermata reinventava card/empty/pill/ombre; ~250 colori hardcoded, 342 `TextStyle` ad-hoc, 0 font custom) e mancavano parecchie funzioni/pagine. Richiesta utente: uniformare lo stile "come un graphic designer" con un **file di riferimento**, colmare le differenze/mancanze, **tenendo** l'app nativa (no menù laterale/web) e la **bottom nav cliente** (Prenotazioni/Allenamento/Profilo).

### Modifiche effettuate
**Fondazione design system:**
- Font unico **Inter** bundlato in `assets/fonts` (5 pesi 400–800), cablato nel tema in un punto solo (`kFontFamily`) — sostituisce il Roboto di default.
- **`Flutter/palestria_app/docs/DESIGN_SYSTEM.md`**: reference unico (tipografia, palette org-aware vs semantica, spacing 4-based, radius, ombre, componenti, pattern, checklist, regole d'oro).
- **`lib/core/theme/ui_kit.dart`** (nuovo): AppCard, SectionHeader, StatusPill, AppEmptyState, GradientButton, AppStatCard, DarkHero, AppLoading, AppErrorRetry, AppSnack, brandGradient.
- **`tokens.dart`** esteso: superfici soft, verdi attivo/incassato, stati documento, spotsOrange, blu, `AppGradients.workoutHero`.

**9 aree uniformate** (9 subagent su aree disgiunte, `core/theme` off-limits, ognuno con `flutter analyze` pulito sul proprio scope): Auth&Shell, Prenotazioni, Allenamento, Profilo (cliente); Clienti, Prenotazioni/Orari, Statistiche/Pagamenti, Registro/Messaggi, Impostazioni/Schede (admin). Pattern ricorrente: hardcoded→token; elementi branded→`colorScheme` (dock/tab/selezioni org-aware); card/empty/loading/error→UI kit; SnackBar esito→`AppSnack` (verde/rosso, prima tutti navy); `StatusPill` per i badge; 3 stati async distinti ovunque. Micro-fix inclusi: logo studio in login+header admin, back-to-login, logout rosso, off-by-one certificato, maxLength CF/CAP, password nascosta per OAuth, gating cert editabile, badge Assicurazione, importi Registro via `bookingPrice`, data/ora lezione, messaggi (maxLength+conferma+validazione), dropdown vincolati fuso/valuta (sicurezza DST), plural + virgola decimale + "seleziona tutto" pagamenti, header "Serie", PDF "Fatto ✓", drag handle + guard swipe.

**Verifica:** `flutter analyze lib` full → **No issues found**. 50 file toccati. **NON committato/buildato** (lo fa l'utente).

### Decisioni prese
- **Font bundlato** (non `google_fonts` runtime): offline, nessuna chiamata a Google (data-safety Play), rendering deterministico dal primo frame.
- **Non pixel-perfect col web** ma **linguaggio unico coerente** (richiesta utente): il confronto 1:1 col web serve alla parità **funzionale**/pagine mancanti, non a copiare i pixel.
- **Bottom nav cliente + dock admin lasciati** (app nativa, no menù laterale); reso solo il **colore** org-aware.
- **Subagent paralleli** su aree disgiunte con `core/theme` come contratto condiviso immutabile + auto-verifica `analyze` per scope; **funzioni grosse mancanti NON costruite** in questa passata grafica → elenco **DEFERITE** in `todo.md` per prioritizzazione.

### File toccati
- **Nuovi**: `assets/fonts/Inter-{Regular,Medium,SemiBold,Bold,ExtraBold}.ttf`, `docs/DESIGN_SYSTEM.md`, `lib/core/theme/ui_kit.dart`.
- **Modificati**: `pubspec.yaml`, `lib/core/theme/{tokens,org_theme}.dart` + 46 file feature (auth, client/*, admin/*).

---

## Task: Profilo cliente — sezioni Prossime/Passate/Transazioni + tab Prenotazioni ridotto al solo calendario
**Data:** 2026-07-08
**Durata stimata:** ~40 min lavoro Claude + ~5 min prompt utente

### Contesto
Richiesta utente sull'area cliente: (1) togliere la pill-bar *Calendario / Le mie* dal tab Prenotazioni (→ solo calendario); (2) spostare "Le mie" nel **Profilo**; (3) nel Profilo tre sezioni **Prossime / Passate / Transazioni** "come sul PWA"; (4) togliere il "recap dati" dal Profilo; (5) mostrare **Nome e Cognome**. Chiarito con domanda mirata: "Transazioni" = **storico pagamenti** dal ledger `payments`, da fare in **Flutter + PWA** (parità §0.3), dato che non esisteva ancora in nessuno dei due frontend.

### Modifiche effettuate
**Flutter (app cliente):**
- `booking_screen.dart` → `ConsumerWidget` con `body: CalendarView()` (rimossa la pill-bar + import `MyBookingsView`).
- Nuovo `core/models/client_payment.dart` (`ClientPayment.fromRow`/`selectColumns`).
- `BookingRepository.fetchOwnPayments(userId)` (query `payments` per `client_user_id`, order desc, limit 200) + `ownPaymentsProvider` accanto a `ownBookingsProvider`.
- Nuovo `booking/booking_card.dart` = `BookingCard` (ConsumerWidget) con badge pagamento + regole di annullo, estratto da `my_bookings_view.dart` (poi **eliminato**).
- `profile_screen.dart` riscritto → `ConsumerStatefulWidget` con pill-bar **Prossime/Passate/Transazioni** (paginazione 5→+20), hero con **nome+cognome**, **rimosso `_infoCard`** (recap dati); card transazione con colore bordo per `kind` (Lezione/Abbonamento/Pacchetto/Mora/Rettifica) + importo/metodo/data/periodo/nota.
- `flutter analyze lib` → **No issues found**.

**PWA (parità §0.3):**
- `prenotazioni.html`: 3ª tab `#tabTransazioni`; `switchPrenoTab`/`showMore` con branch `transactions`; nuove `_ensurePayments()` (query `payments` client-side, RLS own-only, cache lazy), `renderTransactions()`, `buildTransactionCard()`, `_fmtTxDate()`; invalidazione cache + re-render nel realtime full-sync; hero → nome completo.
- Cache-bust `sw.js` v584→**v585** (`prenotazioni.html` è in `APP_SHELL`, JS inline). `node --check` inline → 0 errori su 3 blocchi.

### Decisioni prese
- **Domanda mirata prima di costruire**: "Transazioni" non esisteva nel PWA (solo Prossime/Passate) → chiesto contenuto + scope; risposta: storico pagamenti, entrambi i frontend.
- **Riuso, non duplicazione**: estratta `BookingCard` invece di duplicare ~200 righe di card+annullo nel profilo.
- **RLS come sicurezza**: la lettura transazioni si appoggia alla policy `payments_select` (`client_user_id = auth.uid()` OR admin) — nessuna nuova RPC/migration necessaria.
- **Full-name anche sul PWA** (oltre al Flutter richiesto): coerenza §0.3 (il PWA mostrava solo il nome proprio nell'hero). Il "recap dati" è specifico Flutter (il PWA non ce l'ha) → nessuna modifica lì.
- **Nessun build APK**: `flutter analyze` (che fa il type-check completo, nessun codegen nel modulo) è sufficiente per queste modifiche UI; il build richiederebbe la gestione key.properties/cache Nextcloud senza aggiungere garanzie.

### File toccati
- **Nuovi**: `Flutter/palestria_app/lib/core/models/client_payment.dart`, `Flutter/palestria_app/lib/features/client/booking/booking_card.dart`.
- **Modificati**: `Flutter/palestria_app/lib/features/client/booking/booking_screen.dart`, `.../booking/booking_providers.dart`, `.../core/data/booking_repository.dart`, `.../client/profile/profile_screen.dart`; `prenotazioni.html`, `sw.js`.
- **Eliminato**: `Flutter/palestria_app/lib/features/client/booking/my_bookings_view.dart`.
- **Tracking**: `todo.md`, `Aggiornamento.md`, memoria `stato-progetto`.

### Follow-up aperti
- **NON committato/buildato/deployato** (lo fa l'utente): rebuild AAB Flutter + push ramo web → GitHub Pages (cache-bust v585 già applicato).
- **QA**: Prenotazioni = solo calendario; Profilo = hero nome+cognome, no recap, 3 tab; Prossime/Passate con annulla/richiedi annullo; Transazioni con importo/metodo/data ed empty-state; idem PWA.

---

## Task: Fix bug live — prenotazione impossibile con modello "A entrata" (`book_slot`)

**Data:** 2026-07-10
**Durata stimata:** ~15 min lavoro Claude + ~2 min prompt utente

### Contesto
Bug report utente dai log console: `book_slot` rispondeva 400 con `null value in column "paid" of relation "bookings" violates not-null constraint` ad ogni tentativo di prenotazione per un cliente con modello di pagamento "A entrata" (`pay_per_session`).

### Causa radice
In `book_slot` (introdotta da migration `00000000000042_realtime_and_deferred_package_consumption.sql`), il check di idempotenza su `local_id` riusava la variabile `v_paid`:
```sql
select id,paid into v_id,v_paid from bookings where org_id=v_org and local_id=p_local_id order by created_at limit 1;
```
In PL/pgSQL, quando una `select ... into` non trova righe (caso normale per una prenotazione nuova, con `local_id` mai visto), i target vengono impostati a **NULL**, non lasciati invariati. Questo sovrascriveva il default `v_paid:=false` con NULL. Più sotto, i modelli `free`/`package`/`monthly` risettavano esplicitamente `v_paid:=true`, mascherando il problema; il ramo `pay_per_session` lo tocca **solo** se c'è una soglia di saldo scoperto configurata (`v_threshold>0`) — altrimenti `v_paid` restava NULL fino all'`insert into bookings(...)`, che fallisce per via del vincolo `NOT NULL` sulla colonna `paid`.

### Modifiche effettuate
- Nuova migration `supabase/migrations/00000000000045_fix_book_slot_paid_null.sql`: ridefinisce `book_slot` isolando il check di idempotenza in una variabile dedicata `v_existing_paid`, così `v_paid` mantiene il suo default `false` per i booking realmente nuovi. Nessun'altra logica toccata (impatto minimo).
- **Applicata sul remoto** (`supabase db push --yes`), confermata con `supabase migration list` (Local/Remote/Applied tutti a 45).

### Decisioni prese
- Fix come **nuova migration** (non editare la 42 in place): la 42 risultava già applicata sul progetto Supabase remoto (`supabase migration list` mostrava fino alla 44 applicata), quindi modificarla non si sarebbe propagata — serviva un `create or replace function` successivo.
- Deploy in produzione **confermato con l'utente** prima di eseguirlo (modifica DB condivisa, azione difficile da annullare), nonostante la policy generale su bug report autonomi: qui la richiesta di conferma resta giustificata trattandosi di stato condiviso in produzione.

### File toccati
- **Nuovo**: `supabase/migrations/00000000000045_fix_book_slot_paid_null.sql`.
- **Tracking**: `todo.md` (sez. "Modello di pagamento predefinito"), memoria `stato-progetto`.

### Follow-up aperti
- Nessuno lato codice frontend (RPC server-side, nessun cache-bust necessario).
- Migration non ancora committata su git (in attesa di indicazione utente per il commit).
- QA consigliata: ripetere una prenotazione reale con un cliente in modello "A entrata" per confermare che il 400 sia sparito.
