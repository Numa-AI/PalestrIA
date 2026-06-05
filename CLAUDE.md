# CLAUDE.md — PalestrIA SaaS

Guida per agenti AI (e umani) che lavorano su questo repository. Leggila prima di modificare il codice.

---

## 0. Stato del progetto e tracciamento (LEGGI PRIMA)

- **Dove siamo rimasti**: lo stato di avanzamento è nel file di **memoria** `stato-progetto` (in `…/.claude/projects/<questo-progetto>/memory/stato-progetto.md`, indicizzato in `MEMORY.md`). Va **letto a inizio sessione** per sapere cos'è fatto, dov'è deployato e cosa manca. Altre memorie utili: `github-repo-saas`, `super-admin-dashboard`, `stripe-connect-trainer`.
- **Cose da fare**: **`todo.md`** (root del repo) è la **fonte di verità** delle attività residue, organizzata per priorità (Sicurezza, Stripe, Dominio/PWA, Rifiniture, Go-to-market, QA).
- **⚠️ Regola operativa**: ogni volta che **concludi un task**, **controlla e aggiorna `todo.md`** — spunta/rimuovi ciò che è fatto e aggiungi le nuove cose future emerse. Aggiorna anche il file di memoria `stato-progetto` con il punto a cui sei arrivato. (E ricordati il cache-busting del §6 ad ogni deploy di asset.)

---

## 1. Cos'è PalestrIA e visione SaaS

**PalestrIA** è un gestionale completo per personal trainer e studi fitness: prenotazioni con calendario, schede di allenamento, gestione clienti, report, notifiche push, PWA installabile.

**Visione SaaS**: la piattaforma è **multi-tenant pooled, self-serve**. Ogni studio/trainer (con staff opzionale) è un **tenant isolato** (`organizations`). Chiunque può registrarsi, creare il proprio studio e iniziare con un **trial di 30 giorni**, poi paga un **abbonamento mensile Stripe** alla piattaforma. I dati di ogni tenant sono isolati a livello DB tramite **`org_id` + Row Level Security**.

Due flussi di denaro **distinti**, da non confondere:
1. **Abbonamento SaaS** — il *trainer paga la piattaforma* (te). Ricorrente mensile, gestito da **Impostazioni → Billing SaaS**. Usa l'account Stripe **della piattaforma**. 3 tier per numero di clienti iscritti: `starter` €39,99 (≤50), `pro` €79,99 (≤200), `business` €149,99 (illimitato) + trial 30 gg.
2. **Pagamenti-cliente** — il *cliente paga il trainer* per le lezioni (a entrata / mensile / pacchetto / gratuito). Modulo **configurabile** dalle Impostazioni. L'integrazione Stripe per i pagamenti online è gestita a livello piattaforma (API key configurate dall'owner della piattaforma); i pagamenti registrati a mano (contanti/carta/bonifico) funzionano senza Stripe.

> ⚠️ **Stato della migrazione**: il progetto nasce da un gestionale **single-tenant**. La trasformazione a SaaS è in corso secondo il piano in `C:\Users\andrea\.claude\plans\voglio-che-questo-progetto-immutable-pillow.md`. Il **nuovo schema** vive in `supabase/migrations/00000000000000_baseline.sql` (consolidato, per progetto Supabase greenfield). Le ~119 vecchie migration incrementali single-tenant sono state archiviate in `_legacy/migrations-singletenant/` come riferimento storico: **non** vanno applicate al nuovo progetto (resterebbero rotte sopra la baseline).

---

## 2. Stack e architettura

- **Frontend**: HTML + CSS + JavaScript **vanilla, zero-build**. Niente bundler, niente framework. Dipendenze esterne via CDN (Supabase JS, jsPDF, PDF.js). Una pagina = un file `.html` con i suoi `<script src="js/*.js">`.
- **Backend**: **Supabase** — Postgres (con RLS), Auth, Edge Functions (Deno/TypeScript), Storage, Realtime.
- **PWA**: Service Worker offline-first (`sw.js`), manifest installabile, supporto iOS/Android.
- **Hosting**: statico (GitHub Pages oggi; per il SaaS valutare hosting con sottodomini per-tenant).
- **Logica dati lato client**: classi *Storage* in `js/data.js` con pattern **dual-layer** (cache localStorage + sync Supabase).

---

## 3. Modello multi-tenant (`org_id` + RLS)

Il cuore del SaaS. Regole **non negoziabili**:

- **Tabelle di tenancy**: `organizations` (il tenant: slug, branding, timezone, valuta, stato), `org_members` (staff: `role` ∈ `owner`/`admin`/`staff`), e `profiles.org_id` (i clienti finali appartengono a una org).
- **Ogni tabella business porta `org_id NOT NULL`** + indice su `org_id`.
- **Helper SQL** (definiti nella baseline):
  - `current_org_id()` — ricava la org dell'utente dal claim JWT `app_metadata.org_id`, con fallback a `org_members`/`profiles`.
  - `is_org_admin([p_org_id])` — true se l'utente è owner/admin della org.
  - `org_id_for_slug(slug)` — risolve la org per le RPC pubbliche (client anonimi).
  - `is_admin()` è mantenuta come **alias di `is_org_admin()`** per compatibilità con i call-site storici.
- **RLS pattern uniforme** su ogni tabella: `SELECT` → `org_id = current_org_id()`; scritture → `org_id = current_org_id() AND (is_org_admin() OR user_id = auth.uid())`. **Mai** `USING (true)`.
- **Le RPC `SECURITY DEFINER` bypassano RLS**: DEVONO filtrare `org_id` esplicitamente nei `WHERE`/`INSERT`. È il rischio di data-leak #1.
- **`org_id` nel JWT**: iniettato via **Custom Access Token Hook** (`supabase/functions/custom-access-token-hook`).
- **Client anonimi** (prenotazione pubblica): nessun JWT → la org si risolve dallo **slug** in URL/sottodominio; le RPC pubbliche ricevono `p_org_slug`.

---

## 4. Struttura cartelle e file chiave

```
/*.html                  Pagine (index, login, prenotazioni, admin, allenamento, ...)
/css/                    Stili per pagina (admin.css, allenamento.css, style.css, ...)
/js/
  supabase-client.js     Init client Supabase + lock handling PWA
  auth.js                Auth, sessione, ruoli, normalizePhone
  data.js                Storage layer (booking, schedule, settings, ...) + RPC
  booking.js             Form prenotazione cliente
  calendar.js            Vista calendario pubblica
  admin.js               Bootstrap admin + switchTab
  admin-*.js             Pannelli admin (clients, schedule, analytics, settings, schede, ...)
  org-settings.js        (nuovo) modulo Impostazioni org-aware
  push.js, silent-refresh.js, pull-to-refresh.js, ...   PWA/runtime
/supabase/
  migrations/            00000000000000_baseline.sql (SaaS, unica migration)
/_legacy/migrations-singletenant/   storico single-tenant (riferimento, NON applicato)
  functions/             Edge Functions Deno (billing-*, stripe-webhook, notify-*, ...)
  config.toml            Config Supabase CLI
  seed.sql               Seed demo (1 org, slot types, piani SaaS)
/data/                   Database esercizi (CSV/JSON)
sw.js, manifest*.json    PWA
```

---

## 5. Moduli funzionali

- **5.1 Prenotazioni** — `bookings`; prenotazione **server-authoritative** via RPC `book_slot` con advisory lock anti-overbooking (la capienza è decisa dal server, non dal client).
- **5.2 Orari flessibili** — `slot_types`, `time_slots_config`, `weekly_schedule_templates`/`weekly_template_slots`, `schedule_overrides` (con `capacity` assoluta). RPC `resolve_slot_config(org,date,time)` = unica fonte di verità di tipo-slot e capienza. Ogni tenant definisce le proprie fasce, tipi e capienze.
- **5.3 Schede allenamento** — `workout_plans`/`workout_exercises`/`workout_logs`, esercizi importati, report PDF, progressi.
- **5.4 Billing-cliente configurabile** — `billing_settings` (modello default per-org), `client_billing_profiles` (override per-cliente), `client_memberships` (mensile), `client_packages` (carnet), **`payments`** (ledger unificato = unica fonte del fatturato). Modelli: `pay_per_session`, `monthly`, `package`, `free`. Gating/decremento integrati in `book_slot`.
- **5.5 Impostazioni** — `org_settings(org_id, key, value jsonb)` org-scoped + Realtime. Modulo JS `OrgSettings` (cache + localStorage namespaced `org_<id>_<key>`). 11 sotto-tab: Branding, Localizzazione, Dati azienda/fiscali, Pagamenti cliente, Policy prenotazione/cancellazione, Notifiche, Staff/Membri, GDPR/Privacy, Feature flags, Billing SaaS, Sicurezza/Manutenzione.
- **5.6 Billing-SaaS Stripe** — `plans`/`subscriptions`/`subscription_events`; edge `billing-checkout` (mode=subscription mensile, trial 30gg), `billing-portal`; `stripe-webhook` gestisce gli eventi subscription; entitlements + feature gating per piano.
- **5.7 Notifiche** — `push_subscriptions`, `client_notifications`, reminder (`send-reminders`), `notify-admin-*` (push agli admin **della org**, niente UUID hardcoded).
- **5.8 PWA** — Service Worker offline, install prompt, update flow.

---

## 6. Convenzioni di codice, cache-busting e Service Worker

- **Lingua**: commenti e UI in **italiano** (coerenza col progetto).
- **Storage dual-layer**: le classi in `data.js` leggono da localStorage e sincronizzano su Supabase. L'helper `_upsertSetting()` (org-aware) è condiviso da più setting — **non rimuoverlo**.
- **Riferimenti file in markdown**: usa `[testo](path)` relativo, non backtick (vedi sezione VSCode).
- **⚠️ Cache-busting obbligatorio ad ogni deploy di asset**:
  1. Bumpa `CACHE_NAME` in `sw.js` (es. `palestria-vNNN` → `vNNN+1`).
  2. Aggiorna il query-string `?v=` nei tag `<script>`/`<link>` modificati.
  3. Se aggiungi/rinomini un file JS/CSS/HTML, aggiornalo nella lista `APP_SHELL` di `sw.js`.
  Saltare questo passo = gli utenti PWA vedono asset vecchi e incoerenti.

---

## 7. Flusso auth e ruoli

- **Auth**: Supabase Auth (email/password).
- **Ruoli**: `owner`/`admin`/`staff` via `org_members`; i **clienti** sono `profiles` con `org_id` (non in `org_members`).
- **Signup trainer** (self-serve): registrazione → `create_organization(name, slug)` crea org + `org_members(owner)` + seed settings → `refreshSession()` per ottenere il claim `org_id`.
- **Signup cliente**: avviene nel contesto di una org (slug in URL); `handle_new_user`/`join_organization` assegna `org_id`; un trigger collega le prenotazioni anonime (stessa email + org) al nuovo profilo.
- **Gating client-side**: `auth.js` legge `app_metadata.org_role` (owner/admin → `adminAuth`) e `app_metadata.org_id` → `window._orgId`. Il server resta l'autorità (RLS + RPC).

---

## 8. Edge Functions

Pattern comune: CORS → validazione Bearer via `supabase.auth.getUser(token)` → fail-fast sui secret → logica.

- `custom-access-token-hook` — inietta `org_id`/`org_role` nel JWT.
- `billing-checkout` — Stripe Checkout **mode=subscription** (piattaforma), trial 30gg.
- `billing-portal` — Stripe Customer Portal.
- `stripe-webhook` — eventi Stripe: subscription (SaaS) + payment (cliente). `verify_jwt=false` (verifica firma Stripe).
- `notify-admin-booking|cancellation|new-client` — push agli admin **della org**.
- `notify-slot-available`, `send-reminders`, `send-admin-message`, `generate-monthly-report` (Anthropic), `image-proxy`.

---

## 9. Comandi e deploy

```bash
# DB (nuovo progetto Supabase)
supabase db reset                 # applica baseline + seed in locale
supabase db push                  # applica migration al progetto remoto
supabase functions deploy <name>  # deploy edge function
supabase secrets set KEY=value    # imposta secret edge

# Sviluppo locale
supabase start                    # stack locale (Postgres, Auth, ...)
deno check supabase/functions/**/index.ts
```

Deploy CI/CD: `.github/workflows/ci.yml` (lint/deno check/RLS test) e `deploy.yml` (Pages + db push + functions deploy, gated per environment).

---

## 10. Env e secrets

| Secret | Dove | Uso |
|---|---|---|
| `SUPABASE_URL`, anon key | client (pubblici) | init `supabase-client.js` |
| `SUPABASE_SERVICE_ROLE_KEY` | edge | operazioni privilegiate |
| `STRIPE_SECRET_KEY` | edge (piattaforma) | billing SaaS + pagamenti cliente |
| `STRIPE_WEBHOOK_SECRET` | edge | verifica firma webhook |
| `SITE_URL` | edge | redirect checkout/portal |
| `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY` | edge/client | web push |
| `ANTHROPIC_API_KEY` | edge | report mensili AI |

L'anon key è pubblica nel client (protetta da RLS). I secret stanno **solo** lato edge.

---

## 11. Cosa è stato RIMOSSO rispetto al single-tenant

Il vecchio sistema **crediti/debiti/bonus** (rigido, legato a un singolo trainer) è stato sostituito dal modulo billing-cliente configurabile (§5.4). Rimossi:

- Tabelle `credits`, `credit_history`, `manual_debts`, `bonuses`.
- ~18 RPC: `admin_add_credit`, `apply_credit_*`, `apply_credit_to_past_bookings(_all)`, `get_debtors`, `stripe_topup_credit`, `get_unpaid_past_debt`, `get_or_reset_bonus`, `normalize_phone`, `revert_future_credit_payments`, `admin_change_payment_method`.
- Classi JS `CreditStorage`, `ManualDebtStorage`, `BonusStorage`, `DebtThresholdStorage`, `RechargeBonusStorage`.
- Tab Pagamenti legacy, cron `apply_credit_all`, top-up Stripe one-time.
- Colonne `bookings.credit_applied`, `cancelled_with_bonus`, `cancelled_with_penalty`.

**RESTANO** (riusati): `_upsertSetting()` (org-aware), `admin_pay_bookings` (refactor → registra su `payments`), `bookings.paid`/`payment_method`/`paid_at`/`custom_price`, advisory lock di `book_slot`.

Il **fatturato** in `admin-analytics.js` (prima con 37 dipendenze da `credit_history`) si ricostruisce ora dal ledger **`payments`**.

---

## 12. Gotchas noti

- **Timezone**: tutto orientato a `Europe/Rome`, ora **configurabile per-org** (`locale.timezone`). Gli orari sono salvati come testo `"HH:MM - HH:MM"`. Attenzione a DST nel calcolo dell'inizio lezione (ICS/gcal e RPC con cutoff).
- **RLS**: ogni nuova tabella senza policy org-scoped è un **data-leak cross-tenant**. Aggiungi sempre le policy e includi un test a 2 org nel CI.
- **SW cache**: dopo un deploy, se non bumpi versione (§6) gli utenti restano su asset vecchi.
- **`navigator.locks`** può bloccarsi su PWA mobile: `supabase-client.js` ha un fallback mutex JS + rilevazione lock bloccati.
- **Prezzi**: niente più hardcoded (storicamente 5/10/50 in SQL vs 30 nel JS — incoerenza sanata). I prezzi vengono da `slot_types`/`billing_settings` per-org.
- **Capienza**: server-authoritative. Non fidarsi mai del valore di capienza inviato dal client.
