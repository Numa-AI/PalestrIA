# TODO — PalestrIA SaaS

Cose ancora da fare per portare il SaaS in produzione. Aggiornato: 2026-06-05.

> Stato: la piattaforma multi-tenant funziona (signup self-serve, orari flessibili, clienti, prenotazioni, billing-cliente, impostazioni 11 sotto-tab, branding). Deployata su Supabase `rwaiekhllujximrqftmp` + GitHub Pages (`renumaa.github.io/PalestrIA`). Mancano soprattutto: incassi reali (Stripe), dominio/landing, e alcune rifiniture + chiusure di sicurezza.

---

## 🔴 Sicurezza / da chiudere PRIMA della produzione
- [ ] **Chiudere la super-admin dashboard** — oggi `platform_settings.open_access = true` → qualsiasi utente loggato vede i dati di TUTTI i tenant (data-leak cross-tenant, accettato solo in dev). Chiudere con `admin_platform_lock('email@scelta')` (bottone "Limita a una sola email") o SQL: insert in `platform_admins` + `update platform_settings set open_access=false`. ⚠️ **Urgenza alzata** (audit RPC): con `open_access=true` qualsiasi utente loggato può chiamare `admin_platform_lock` e auto-nominarsi platform-admin *permanente* (privilege escalation → potrebbe bloccare fuori te stesso). Da chiudere prima di esporre il signup a estranei.
- [ ] **Conferma email** su Supabase: riattivarla (ora OFF per i test) + cablare il flusso "conferma email → crea studio" (gancio `pendingOrg` già in `signup-trainer.html`, da completare in `login.html`).
- [ ] **Site URL / Redirect URLs** su Supabase (Authentication → URL Configuration): impostare il dominio reale (ora `localhost`/github.io) — serve a email e redirect Stripe.
- [ ] **Auth hook `custom_access_token`**: abilitare dal Dashboard (Authentication → Hooks → la function `custom-access-token-hook` è già deployata). Ora si usa il fallback `org_members` (funziona ma è 1 query in più per richiesta).
- [x] **Test RLS cross-tenant** (automatici in CI): [tests/rls/cross_tenant.sql](tests/rls/cross_tenant.sql) crea 2 studi (A/B) via `create_organization`, popola dati reali in entrambi e — impersonando l'owner con `set local role authenticated` + claim JWT — verifica isolamento bidirezionale su SELECT/UPDATE/DELETE/INSERT(WITH CHECK), più lo scoping delle RPC pubbliche per-slug e di `get_all_profiles()`. Cablato nel job `db-baseline` di [ci.yml](.github/workflows/ci.yml) (riapplica le migration post-baseline → esegue lo script con `ON_ERROR_STOP=1`). Aggiunto anche un guard statico anti-`USING(true)`. ⚠️ Da confermare al primo run CI con Docker (sviluppato/validato staticamente: niente Docker in locale).
- [ ] **`get_slot_attendees` espone PII senza login** (emerso dall'audit RPC, leakRisk *medium*): RPC pubblica/anon che, dato lo slug di QUALSIASI studio, restituisce i NOMI degli iscritti a uno slot (di chi non ha `privacy_prenotazioni`). Org-scoped ma senza autenticazione → divulgazione PII. Da rivedere (es. esporre i nomi solo a utenti loggati della stessa org, o limitare al proprio slot). Vedi anche `get_availability_range`/`get_slot_availability` (solo aggregati, ok).
- [ ] **`save_push_subscription` — takeover endpoint cross-org** (audit RPC, leakRisk *low*): l'`ON CONFLICT (endpoint) DO UPDATE` sovrascrive `org_id`/`user_id`, quindi un endpoint già registrato da un'altra org verrebbe riassegnato alla org corrente. Impatto limitato (serve conoscere l'endpoint altrui). Valutare di non riassegnare l'org su conflitto.
- [ ] **GDPR**: adattare `privacy.html` / `termini.html` al SaaS (dati + pagamenti).

## 💳 Pagamenti / Stripe
### Abbonamento SaaS (trainer → piattaforma)
- [ ] Creare i **3 prodotti Stripe** mensili (39,99 / 79,99 / 149,99) → `UPDATE plans SET stripe_price_id_monthly='price_...'`.
- [ ] `supabase secrets set STRIPE_SECRET_KEY=... STRIPE_WEBHOOK_SECRET=... SITE_URL=https://renumaa.github.io/PalestrIA`.
- [ ] `supabase functions deploy billing-checkout billing-portal stripe-webhook`.
- [ ] Registrare il **webhook Stripe** → `.../functions/v1/stripe-webhook` (eventi subscription.* + checkout.session.completed + invoice.*).
- [ ] Verificare il cron `enforce_subscription_state` (degrado/sospensione su scaduto/non pagato).

### Pagamenti-cliente (cliente → trainer) via Stripe Connect
- [ ] **Config owner** (senza, il bottone "Collega Stripe" dà `config_missing`): abilitare Connect sull'account piattaforma; `supabase secrets set STRIPE_CONNECT_CLIENT_ID=ca_...`; registrare redirect URI `https://rwaiekhllujximrqftmp.supabase.co/functions/v1/stripe-connect?action=callback`; `SITE_URL` corretto.
- [ ] **⭐ Checkout cliente online (MANCANTE)** — creare i pagamenti `on_behalf_of` / header `Stripe-Account: acct_…` con la chiave piattaforma. Oggi il trainer può COLLEGARSI ma i clienti non pagano ancora online. È il pezzo che chiude il flusso incassi-cliente.

## 🌐 Dominio / Hosting / PWA
- [ ] Comprare **`palestria.it`** + configurare DNS (`palestria.it`/`www` → marketing; `app` → app SaaS).
- [ ] Decidere il **routing tenant**:
  - **A) `?org=<slug>`** — pronto subito su GitHub Pages, zero infra.
  - **B) sottodominio `<slug>.palestria.it`** — più "pro" + PWA installabile per-studio, ma richiede wildcard DNS + **migrazione hosting a Cloudflare Pages / Netlify / Vercel** (GitHub Pages non fa wildcard).
- [ ] **Manifest PWA dinamico per-org** (nome/icona/colore dell'app installata) — oggi statico "PalestrIA" generico. (Naturale coi sottodomini; su dominio condiviso serve manifest dinamico.)
- [ ] (Se si resta su `?org=`) **fallback localStorage** dello slug, così la PWA installata da anonimo non perde il contesto studio al rilancio.

## 🧊 Stabilità / Freeze PWA (diagnosi multi-agente 2026-06-06)
Sintomi: PWA va spesso chiusa/riaperta o refreshata; freeze "alla 2ª prenotazione"; su Mac idle il sito si freeza e serve refresh. Causa comune: **operazioni async senza timeout** che restano appese su rete lenta / webview sospesa.
- [x] **Fase A — quick-win (rischio ~0, applicati)**: timeout 45s su `saveBookingForClient` (data.js, C3); `_queryWithTimeout` sul loop paginazione bookings (data.js:639, C11); timeout 12s + pausa su `_retryPending` (data.js, C5); watchdog 30s che sblocca `refreshInFlight` in silent-refresh (C7); reset di `_cascadeReloadScheduled` su reload fallito (supabase-client.js, C8); `fetchWithTimeout` 8s sui Network-First del SW (sw.js, C10). Cache bumpata: `sw.js` v530→v531, `supabase-client.js?v=5`, `silent-refresh.js?v=2`, `data.js?v=76` (unificato, prima disallineato 74/75).
- [x] **Fase B — cuore auth-lock (branch `fix/pwa-freeze`)**: `fn` ora avvolta dal watchdog ANCHE dentro `navigator.locks.request` (supabase-client.js) — l'AbortController abortava solo l'*attesa* di acquisizione, non l'esecuzione: se `fn` si appendeva dopo aver preso il lock lo teneva bloccato per sempre (C1, causa del freeze su Mac idle + "2ª prenotazione" utente normale). `_withFnWatchdog` non lascia più la `fn` rejection unhandled (C4); `_runSerialized` logga invece di inghiottire muto, e la chain non si avvelena perché il watchdog risolve sempre entro 8s (C2).
- [x] **Watchdog globale di auto-guarigione** (`js/app-watchdog.js`, nuovo): al resume (visibilitychange dopo ≥60s nascosto / bfcache / online) lancia una probe `ensureValidSession`; se non si risolve entro 12s lo stato auth è incastrato → **reload invisibile** (con guard anti-perdita-dati-form e anti-loop max 3/sessione). È lo strato che garantisce il recupero anche dai bug ignoti. Registrato in `sw.js` APP_SHELL + caricato su tutte le 11 pagine con silent-refresh.
- [x] **Fase C — canali Realtime rivivibili + cleanup**: `_registerRealtimeChannel` ora dedup-on-register; `_cleanupAllRealtimeChannels` su `beforeunload` (silent-refresh.js); `maintenance.js` e `org-settings.js` registrano i loro canali nel registry → **rivivibili da `_reconnectDeadChannels` dopo il wake** (prima morivano nel sleep → dati/branding stantii finché non ricaricavi). Nota: il "leak cross-pagina" era già in gran parte mitigato dalla navigazione full-reload; il valore vero è la rivivibilità post-wake.
- [x] **Sweep timeout**: il data layer è quasi tutto già su `_rpcWithTimeout`/`_queryWithTimeout`; wrappate anche le ultime scoperte (`schedule_overrides` upsert/select/delete in data.js).
- [x] **Fase D — over-fetching (parziale)**: `index.html` era l'unica pagina con gli handler Realtime **non-debounced** (sync+render completo ad OGNI evento `bookings`/`app_settings`/`settings`) → allineato al debounce 600ms già usato in `prenotazioni.html`/`admin.html`: i burst collassano in un solo sync. Documentazione completa + raccomandazioni residue (update incrementale da payload, finestra date, select mirato, ownOnly) in **`fix.md`** (root, nuovo). Le residue sono più rischiose (correttezza disponibilità) → da fare con profiling/test.
- [x] **Fase E — flash branding al refresh (FOUC)**: al refresh si vedeva "IL TUO NOME" + viola di default per qualche secondo (branding applicato solo dopo `OrgSettings.load()` async). Fix: nuovo `js/branding-boot.js` caricato **sincrono in `<head>`** che applica uno **snapshot** del branding (chiave stabile `_brandingSnapshot` scritta da `applyBranding()`) PRIMA del paint — colori subito su `:root`, nome/logo appena pronto il DOM (placeholder nascosto nel frattempo). Aggiunto a 15 pagine (tranne super-admin). Vedi `fix.md` sez. 8.
- [ ] **QA freeze + branding (DA FARE prima del merge/deploy)**: test manuale con DevTools — vedi checklist sotto (incl. test flash branding). Cache bumpata: `sw.js` v533, `supabase-client.js?v=6`, `silent-refresh.js?v=3`, `data.js?v=77`, `org-settings.js?v=4`, `maintenance.js?v=2`, `app-watchdog.js?v=1`, `branding-boot.js?v=1`.

### ✅ Checklist test freeze (DevTools)
1. **2 prenotazioni di fila**: prenota, conferma, prenota di nuovo subito → la 2ª NON deve bloccarsi. Ripeti con Network throttled a "Slow 3G".
2. **Rete morta durante booking**: DevTools → Network → Offline a metà prenotazione → deve sbloccarsi con toast errore entro ~45s, bottone riutilizzabile.
3. **Idle/sleep-wake (il principale)**: lascia la tab in background >2 min (o simula: DevTools → More tools → Sensors, oppure metti il Mac in sleep) → torna sulla tab → l'app deve riprendere da sola; se era incastrata, watchdog ricarica entro ~12s (vedi log `[watchdog] auto-guarigione`).
4. **Tab aperta a lungo**: lascia aperta ore con Realtime attivo → le modifiche admin devono ancora propagarsi (canali rivivibili); nessun accumulo (DevTools → Memory, listener count stabile).
5. **Lock deadlock simulato**: in console, verifica i log `[Supabase Auth]`; non devono comparire catene infinite di watchdog senza recovery.

## 🧩 Funzionalità da completare / rifinire
- [ ] **Pagina pubblica per anonimi**: la griglia slot per il cliente NON loggato deve venire dalla RPC pubblica `get_availability_range`/config — oggi gli orari si caricano "pieni" solo da loggato (la RLS non espone slot_types/template agli anonimi). Necessario per i link pubblici `?org=<slug>`.
- [ ] **UI cambio modello billing per-cliente**: oggi il modello si imposta solo *vendendo* un abbonamento/pacchetto (auto-override). Aggiungere un selettore nel dettaglio cliente per impostarlo a mano (incl. tornare a "a entrata").
- [ ] **Calendario**: refresh automatico dopo modifica della settimana tipo (oggi serve ricaricare la pagina).
- [ ] **Notifiche**: `supabase secrets set VAPID_PUBLIC_KEY/VAPID_PRIVATE_KEY` + deploy `notify-admin-*`, `notify-slot-available`, `send-reminders`; verificare che leggano le chiavi `notif.*` per-org.
- [ ] **Report AI mensili**: `supabase secrets set ANTHROPIC_API_KEY` + deploy `generate-monthly-report`.
- [ ] **admin_health_check/fix**: oggi sono stub che ritornano "ok" — implementare controlli reali org-scoped se serve la sezione Sicurezza.
- [ ] **viewer.html** (tool backup offline legacy): ripulire i residui credito/debito (non tocca il nuovo schema, ma è codice morto).
- [ ] **Storage buckets**: creare `tenant-assets` (logo/branding) + `documenti` se si vuole l'upload del logo dalle Impostazioni (oggi è un campo URL).

## 📣 Go-to-market
- [ ] **Landing SaaS** su `palestria.it`: trasformare `PalestrIA WebSite/` in una landing multi-tenant con CTA "Crea il tuo studio gratis" (→ `signup-trainer.html`) + sezione prezzi (39,99/79,99/149,99 + trial 30gg).
- [ ] Testi/asset marketing (vedi `PalestrIA WebSite/instagram-briefs.md`).
- [ ] **Ads Instagram** → solo DOPO che il funnel è monetizzabile (Stripe live) e i flussi core sono solidi.

## ✅ Testing / QA (prima del lancio)
- [ ] Test end-to-end: signup trainer → orari → clienti → prenotazioni → 4 modelli pagamento → billing SaaS → portal.
- [ ] Test multi-tenant: 2 studi, isolamento dati verificato.
- [ ] Test PWA install + push su iOS/Android.
- [ ] Giro `node --check` + bump cache (`sw.js` `CACHE_NAME` + `?v=`) ad ogni deploy.

---

### Riferimenti
- Piano: `C:\Users\andrea\.claude\plans\voglio-che-questo-progetto-immutable-pillow.md`
- Guida progetto: `CLAUDE.md`
- Repo: https://github.com/ReNumaa/PalestrIA.git
