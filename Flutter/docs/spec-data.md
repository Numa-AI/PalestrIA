# PalestrIA — Specifica completa dello strato DATI + AUTH (per riscrittura Flutter/Dart)

> **Scopo**: questo documento è autosufficiente. Contiene tutto ciò che serve per riscrivere in
> Dart (`supabase_flutter`) un data layer equivalente a quello web (vanilla JS) **senza leggere il
> codice originale**. Fonti: `js/supabase-client.js`, `js/auth.js`, `js/data.js`,
> `js/org-settings.js`, `js/entitlements.js`, `js/ls-namespace.js`, `js/silent-refresh.js`,
> `supabase/migrations/*` (baseline + 26 migration incrementali), `supabase/functions/*`,
> `supabase/config.toml`, `login.html`, `signup-trainer.html`, `js/booking.js`, `js/push.js`.
>
> Architettura: **multi-tenant pooled** su Supabase — ogni studio/trainer è una riga di
> `organizations`; ogni tabella business porta `org_id NOT NULL` + RLS; il claim JWT
> `app_metadata.org_id` è iniettato dal Custom Access Token Hook. Il server è SEMPRE l'autorità
> (capienze, prezzi, prenotazioni, billing): il client è solo cache/display.

---

## 1. CONFIG SUPABASE

Valori **pubblici** (protetti da RLS lato DB), hardcoded in `js/supabase-client.js`:

```
SUPABASE_URL      = https://rwaiekhllujximrqftmp.supabase.co
SUPABASE_ANON_KEY = sb_publishable_SDlyqyh2C78ZlQ42hQJClA_e1LIp2x5
PROJECT_REF       = rwaiekhllujximrqftmp
```

- Libreria web: `@supabase/supabase-js@2.99.1` (UMD via CDN jsdelivr).
- Chiave sessione in localStorage (web): `sb-rwaiekhllujximrqftmp-auth-token`
  (valore JSON, a volte con encoding prefissato `base64-`).

### 1.1 Architettura web a DUE client (⚠️ NON replicare in Flutter)

Il web usa due client per aggirare il bug `navigator.locks` delle PWA mobile (lock auth appeso
dopo sospensione della webview → resume 11-14 s):

1. **`supabaseAuth`** — client AUTH: tutta la sessione (`getSession/refreshSession/signIn/
   signOut/onAuthStateChange`). Opzioni: `auth.autoRefreshToken: false` (il refresh è gestito a
   mano, v. §2.6) + `auth.lock` custom: `navigator.locks` con timeout 500 ms, fallback a un mutex
   JS (Promise-chain per-nome), watchdog 2 s che sblocca la chain, rilevazione "locks rotti"
   (2 timeout in 30 s → disabilitati 60 s), reload di emergenza su cascata di watchdog (2 firing
   in 60 s, solo a pagina visibile e senza recovery in corso).
2. **`supabaseClient`** — client DATI: opzione `accessToken: async () => _readAccessTokenDirect()`
   che legge l'access token **direttamente da localStorage** (zero lock; ritorna anche un token
   scaduto: meglio un 401 puntuale che bloccare la query). Tutte le query/RPC/Realtime/Storage
   passano da qui. Con `accessToken` il namespace `.auth` è disabilitato.

Espone anche: `window._isManagedAuthPage = true` e
`window._manualTokenRefresh = () => supabaseAuth.auth.refreshSession()`.

**In Flutter**: un solo `SupabaseClient` (`Supabase.initialize(url, anonKey)`), con
`autoRefreshToken` di default (true). Tutta la macchineria lock/watchdog/dual-client è
web-specific e va omessa (v. §8).

---

## 2. AUTH FLOW

### 2.1 Ruoli e modello

| Attore | Dove vive | Come si riconosce |
|---|---|---|
| **owner / admin / staff** (staff dello studio) | `org_members(role)` | claim JWT `app_metadata.org_role` ∈ `owner|admin|staff` |
| **cliente finale** | `profiles` (con `org_id`) | ha una riga `profiles`, NESSUN `org_role` |
| **anonimo** (prenotazione pubblica) | — | nessun JWT; org risolta dallo **slug** (`?org=slug` o sottodominio) |
| **platform super-admin** | `platform_admins` (whitelist) | RPC `is_platform_admin()` |

Gating client-side (solo UX, il server resta autorità):
- `window._orgId` = claim `app_metadata.org_id` (fallback: query `org_members`).
- `window._orgRole` = claim `app_metadata.org_role`.
- `isOrgAdmin = (org_role == 'owner' || org_role == 'admin')` → nel web setta
  `sessionStorage.adminAuth = 'true'` (in Flutter: stato in memoria).
- `window._orgSlug` = slug org pubblico risolto da: `window._orgSlug` → sottodominio (primo
  segmento host se `host.length>2` e non `www`/`app`) → query string `?org=`.

### 2.2 Claim JWT — Custom Access Token Hook

Edge function `custom-access-token-hook` (registrata in **Auth → Hooks**; `verify_jwt=false`,
chiamata da GoTrue a OGNI emissione di token, login e refresh). Payload GoTrue:
`{ user_id, claims }` → risponde con l'intero payload arricchendo `claims.app_metadata`:

1. cerca membership attiva in `org_members` (`status='active'`, la più vecchia per
   `created_at`) → `org_id` + `org_role`;
2. altrimenti `profiles.org_id` → solo `org_id` (i clienti non hanno `org_role`);
3. nessuna org → claims invariati (utente pre-onboarding).

⚠️ Se il hook NON è registrato, il client fa fallback con una query a `org_members` a ogni boot
(più lento). Dopo `create_organization`/`join_organization` serve **`refreshSession()`** per
ottenere il claim aggiornato.

### 2.3 `initAuth()` — boot di ogni pagina (ordine esatto)

1. Attende l'evento **`INITIAL_SESSION`** di `onAuthStateChange` (non `getSession()`: evita la
   race PWA in cui `getSession()` torna null durante un refresh in corso). Fallback: se non
   arriva entro **6 s** → `ensureValidSession()` (v. 2.5).
2. Se c'è sessione: esegue **in parallelo** (`Promise.all`) — è il boot parallelizzato:
   - `_loadProfile(session.user.id)` — `SELECT` su `profiles` delle colonne:
     `id, name, email, whatsapp, medical_cert_expiry, medical_cert_history, insurance_expiry,
     insurance_history, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap,
     documento_firmato, privacy_prenotazioni, created_at` con `.maybeSingle()` (owner/staff non
     hanno riga profiles → null senza errore). Se il profilo ha `name` non capitalizzato, lo
     capitalizza e fa write-back asincrono. In errore NON azzera `_currentUser` (evita falsi
     logout su blip di rete).
   - `_applyOrgContext(session.user)` — setta `_orgId`/`_orgRole` dai claim (fallback query
     `org_members` attiva più vecchia) e il flag admin.
3. Se `_loadProfile` fallisce e `_currentUser` è null → fallback: costruisce l'utente dai
   `user_metadata` (`full_name/name/email/whatsapp/codice_fiscale/indirizzo_*`).
4. Se NON c'è sessione: azzera `_currentUser`, `_orgId`, `_orgRole`, flag admin.
5. Registra (una sola volta) il listener persistente `onAuthStateChange`:
   - `SIGNED_IN` / `TOKEN_REFRESHED` → reset flag `_isManualLogout`, ricarica profilo + org context.
   - `SIGNED_OUT`: se `_isManualLogout` → pulizia completa. Altrimenti è uno **SIGNED_OUT
     spurio** (race di refresh Supabase in PWA): NON azzerare l'utente, tenta
     `ensureValidSession()`; solo se fallisce definitivamente pulisce lo stato.
6. Registra (una volta) il listener `visibilitychange`: al ritorno in foreground attende 500 ms,
   `ensureValidSession()` → ricarica profilo + org context; se il background è durato ≥ 120 s,
   `BookingStorage.syncFromSupabase()`.
7. Aggiorna la UI di navigazione e ritorna la sessione.

### 2.4 Login / Signup

**`loginWithPassword(email, password)`**: `signInWithPassword` → `_loadProfile` +
`_applyOrgContext` → `_trackLoginEvent('login')` → `{ok:true}` | `{ok:false, error}` (messaggi
d'errore mappati in italiano: "Email o password errata.", "Email già registrata.", ecc.).

**`registerUser(name, email, whatsapp, password, codiceFiscale, indirizzo)` — signup CLIENTE**:
1. Se `whatsapp` presente → RPC `is_whatsapp_taken(phone)` → se preso, errore.
2. Capitalizza il nome (ogni parola: prima maiuscola, resto minuscolo).
3. **org slug obbligatorio** (`window._orgSlug` o `_resolveOrgSlug()`): senza, il trigger
   `handle_new_user` non creerebbe il profilo → errore "Studio non identificato…".
4. `auth.signUp({email, password, options: { emailRedirectTo: <origin>/login.html, data: {
   signup_type: 'client', org_slug, full_name, whatsapp, codice_fiscale (UPPERCASE),
   indirizzo_via, indirizzo_paese (normalizeComune), indirizzo_cap } }})`.
5. Il trigger DB `handle_new_user` (su `auth.users` AFTER INSERT) crea la riga `profiles` nella
   org dello slug e **collega le prenotazioni anonime** (stessa email + org, `user_id IS NULL`).
6. Safety-net: se `data.session` è già attiva (conferma email OFF) → RPC
   `join_organization({p_org_slug})` idempotente.
7. `_trackLoginEvent('signup')`.

**Signup TRAINER (self-serve, `signup-trainer.html`)**:
1. `signUp({email, password, options:{ emailRedirectTo: login.html, data: { full_name,
   signup_type: 'trainer' } }})` — `signup_type='trainer'` fa sì che `handle_new_user` NON crei
   il profilo cliente.
2. Se non c'è sessione (conferma email ON o utente esistente) → tenta `signInWithPassword`;
   se serve conferma → salva `sessionStorage.pendingOrg = {name, slug}` e mostra messaggio
   (l'org verrà creata al primo login).
3. RPC **`create_organization(p_name, p_slug)`** (errori: `slug_taken`, `invalid_slug`,
   `not_authenticated`). Lo slug è derivato dal nome studio (regex slug `^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$`).
4. **`auth.refreshSession()`** per ottenere il claim `org_id` → redirect `admin.html`.

**OAuth Google** (`login.html`): `signInWithOAuth({provider:'google', options:{redirectTo:
<origin>/login.html}})`. Al ritorno: `handleOAuthReturn()` controlla
`session.user.app_metadata.provider !== 'email'`; se l'anagrafica è incompleta
(`isAnagraficaComplete`: servono whatsapp, codice_fiscale, indirizzo_via/paese/cap) mostra il
modal "Completa profilo" → valida whatsapp E.164 `+\d{10,15}`, CF 16 char, CAP 5 cifre → RPC
`is_whatsapp_taken(phone, exclude_user_id)` → se `_orgId` mancante, RPC
`join_organization(p_org_slug)` (ritorna l'uuid org) → upsert `profiles`
`{id, org_id, name, email, whatsapp, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap}`.

### 2.5 `ensureValidSession({timeoutMs=12000, force=false})` — refresh centralizzato fail-closed

Un solo refresh in-flight per tab (chi arriva attende la stessa Promise). Algoritmo:
1. **Leggi la sessione** (nel web: `getSession()` con cap 3 s; al timeout, lettura diretta da
   localStorage con validazione `access_token`+`expires_at`+`refresh_token`). Se `!force` e
   fresca (> 30 s alla scadenza) → ritornala.
2. Se non esiste NESSUNA sessione in storage → utente non autenticato → `null` silenzioso
   (niente toast "sessione scaduta").
3. Se c'è un refresh in-flight → attendilo con cap `timeoutMs`; oltre il cap → riprova a leggere
   la sessione; se non fresca → `null`.
4. Altrimenti avvia `refreshSession()` con race contro `timeoutMs`.
5. Se fallisce: polla la sessione 3 volte ogni 400 ms (l'auto-refresh interno potrebbe aver
   completato).
6. **FAIL-CLOSED**: se ancora niente → `signOut({scope:'local'})`, azzera stato, dispatch evento
   `auth:session-lost` (un handler globale mostra il toast "Sessione scaduta. Effettua di nuovo
   l'accesso." e reindirizza a login dopo 1.5 s) → ritorna `null`.

### 2.6 Refresh proattivo del token (web: `_initProactiveTokenRefresh`)

Con `autoRefreshToken:false`, un tick ogni **60 s** (primo a 15 s dal boot):
- salta se pagina nascosta;
- legge `expires_at` dalla sessione in storage;
- se mancano **< 5 min** (300 s) → refresh; tra 90 s e 5 min rimanda se l'utente sta scrivendo
  (`activeElement` input/textarea/contentEditable) o se una pagina segnala "occupato" via
  `window._authBusyChecks` (array di predicate); **sotto 90 s** rinnova comunque;
- traccia i fallimenti: dopo ≥ 2 fallimenti con token ≤ 90 s → dispatch `auth:session-lost`
  (finestra fallimenti 10 min).

**In Flutter non serve**: `supabase_flutter` gestisce l'auto-refresh nativamente. Mantieni solo
il concetto di "assicurati sessione fresca prima di RPC non-idempotenti" (v. §8).

### 2.7 Recovery password e PKCE

- **Richiesta**: `auth.resetPasswordForEmail(email, {redirectTo: <origin>/login.html})`.
- **Reset**: al click sul link email GoTrue emette l'evento **`PASSWORD_RECOVERY`**
  (listener registrato PRIMA di `initAuth`) → la UI mostra il form nuova password →
  `auth.updateUser({password})` (min 6 caratteri).
- **PKCE**: il progetto usa il flusso PKCE — i link email (conferma signup, recovery) tornano
  come `?code=...` che supabase-js **consuma automaticamente** all'init del client (nessun
  `exchangeCodeForSession` manuale). La detection "email confirmation" legacy legge l'hash URL
  (`#type=signup|email_change`), ma con PKCE l'hash non contiene `type=signup`: per questo la
  notifica "nuovo iscritto" NON è gateata sull'hash bensì su **`maybeNotifyNewClient(session)`**:
  invia la push admin se l'account è stato creato da **< 120 s**, con dedup su chiave locale
  `new_client_notified = user.id` (in Flutter: shared_preferences), chiamata sia dopo `initAuth`
  sia al submit con conferma OFF.
- **Cambio email**: `auth.updateUser({email})` richiede conferma via email; il profilo `profiles`
  viene aggiornato solo dopo (flag `emailPendingConfirmation`).
- In Flutter: `supabase_flutter` usa PKCE di default; configurare **deep link** come redirect
  (al posto di `login.html`) per conferma email/recovery/OAuth.

### 2.8 Logout — teardown completo per-tenant (device condiviso)

`logoutUser()` pulisce PRIMA lo stato locale, POI chiama `signOut({scope:'local'})` con timeout
3 s (se Supabase non risponde si procede comunque). Teardown (ordine non critico, best-effort):
- `_isManualLogout = true`; `_currentUser = null`; rimozione flag admin;
- `BookingStorage._cache = []` + `_clearPersistedCache()` (rimuove chiavi
  `gym_bookings_cache_v2:*`, `gym_stats_cache_v1:*`, `gym_users_cache_v1`);
- `UserStorage._cache = []`;
- invalidazione cache overrides (`_scheduleOverridesCache = null`);
- `BookingStorage.clearStats()` (rimuove `gym_stats`) e `clearAvailability()`;
- `WorkoutPlanStorage.clearCache()` e `WorkoutLogStorage.clearCache()`;
- `teardownPushOnLogout()` (rimuove backup locale subscription + unsubscribe);
- `OrgSettings.reset()` (svuota cache, rimuove chiavi `org_<id>_*`, chiude canale Realtime);
- rimozione `_brandingSnapshot`;
- `_orgId = _orgRole = _orgSlug = null`.

### 2.9 Tracking login (`login_events`)

A ogni login/signup esplicito, insert **fail-silent** su `login_events`:
`{org_id, user_id, event, event_type ('login'|'signup'), device_hash (SHA-256 di
ua|screen|timezone|language), user_agent (max 500 char), platform (ios|android|windows|mac|
linux|other), browser, screen_size ("WxH"), timezone (IANA), language, is_pwa (bool)}`.
RLS insert: `user_id = auth.uid() AND org_id IS NOT DISTINCT FROM current_org_id()`.

### 2.10 Utility di normalizzazione (da replicare identiche in Dart)

**`normalizePhone(raw)`** → E.164:
1. rimuovi `[\s\-().]`;
2. inizia con `+` → invariato; con `00` → `+` + resto;
3. inizia con `0` (fisso nazionale) → `+39` + numero senza lo 0;
4. `^\d{9,10}$` (mobile/fisso IT plausibile) → `+39` + numero (NB: i mobile IT iniziano spesso
   per 39 — non scambiarli per prefisso già presente);
5. altrimenti → invariato.

**`normalizeComune(input)`** → title-case italiano (replicata identica lato SQL in
`normalize_comune()`, migration 0026):
1. apostrofi curvi `’‘ʼ` → `'`; trim; collapse spazi;
2. lowercase totale, poi maiuscola a inizio stringa e dopo spazio/apostrofo/trattino;
3. dalle parole 2..n: connettivi interi minuscoli (`di del dei della delle dello degli da dal
   dai dalle dagli dallo in nel nei nella nelle nello negli a ai al alla alle allo agli e ed con
   su sul sui sulla sulle sullo sugli per tra fra la le lo il i gli l`); prefissi con apostrofo
   (`dell' nell' sull' dall' all' d' l'`, match dal più lungo) → minuscolo solo il prefisso.
   Es. `sant'ambrogio di valpolicella` → `Sant'Ambrogio di Valpolicella`.

**`isAnagraficaComplete(user)`**: true se `whatsapp`, `codice_fiscale`, `indirizzo_via`,
`indirizzo_paese`, `indirizzo_cap` sono tutti valorizzati (trim non vuoto).

---

## 3. SCHEMA DB

Convenzioni: tutti gli id sono `uuid default gen_random_uuid()`; `org_id uuid NOT NULL
references organizations(id) on delete cascade` (salvo dove indicato); date come `date`, orari
degli slot come **testo `"HH:MM - HH:MM"`** (colonna `time text`). Trigger `updated_at = now()`
su: `organizations`, `workout_plans`, `subscriptions`, `bookings`, `profiles`.

### 3.1 Tenancy

**`organizations`** — il tenant.
| colonna | tipo | note |
|---|---|---|
| id | uuid PK | |
| created_at / updated_at | timestamptz | |
| name | text NOT NULL | nome studio (il branding runtime vive in `org_settings`) |
| slug | text NOT NULL UNIQUE | usato dalle RPC pubbliche |
| owner_user_id | uuid → auth.users, on delete set null | |
| timezone | text default 'Europe/Rome' | |
| currency | text default 'EUR' | |
| locale | text default 'it' | |
| branding | jsonb default '{}' | (non usato dal client: usa org_settings) |
| status | text default 'trialing' | check ∈ trialing/active/past_due/suspended/cancelled |
| created_via | text default 'self_serve' | |
| stripe_account_id | text | Stripe Connect (mig. 0006); scrivibile SOLO service_role (trigger `_guard_org_stripe_cols`) |
| stripe_charges_enabled | boolean default false | idem |
| stripe_account_email | text | idem |
| stripe_connected_at | timestamptz | idem |

**`org_members`** — staff. `(org_id, user_id)` UNIQUE.
| colonna | tipo |
|---|---|
| id uuid PK; org_id; user_id uuid → auth.users cascade; role text check ∈ owner/admin/staff; status text default 'active' check ∈ active/invited/revoked; invited_email text; created_at |

**`profiles`** — clienti finali. PK = `id uuid references auth.users(id) on delete cascade`.
`(org_id, email)` UNIQUE.
| colonna | tipo | note |
|---|---|---|
| id | uuid PK = auth.users.id | |
| org_id | uuid NOT NULL | |
| created_at, updated_at | timestamptz | updated_at da mig. 0009 (serve al fingerprint-skip) |
| name | text NOT NULL | |
| email | text NOT NULL | ⚠️ trigger blocca il cambio SELF di email valorizzata (non-admin) — mig. 0025 |
| whatsapp | text | E.164 |
| medical_cert_expiry | date | scadenza certificato medico |
| medical_cert_history | jsonb default '[]' | array `[{scadenza, aggiornatoIl}]` append-only |
| insurance_expiry | date | |
| insurance_history | jsonb default '[]' | idem |
| codice_fiscale | text | UPPERCASE |
| indirizzo_via / indirizzo_cap / indirizzo_paese | text | paese normalizzato title-case (mig. 0026) |
| documento_firmato | boolean default false | ⚠️ ADMIN-ONLY: trigger reverte il self-update (mig. 0023) |
| privacy_prenotazioni | boolean default true | true → compare come "Anonimo" negli attendees |
| push_enabled | boolean default false | |
| geo_enabled | boolean default false | |
| report_ai_consent | boolean default false | mig. 0002 |

### 3.2 Prenotazioni

**`bookings`**
| colonna | tipo | note |
|---|---|---|
| id | uuid PK | |
| org_id | uuid NOT NULL | |
| local_id | text | id generato dal client (`"<Date.now()>-<rand36>"`), per idempotenza/matching |
| user_id | uuid → profiles, set null | può essere NULL (prenotazione anonima) |
| created_at / updated_at | timestamptz | updated_at guida il delta-sync |
| date | date NOT NULL | |
| time | text NOT NULL | `"HH:MM - HH:MM"` |
| slot_type | text NOT NULL | key del tipo (es. 'small-group') |
| slot_type_id | uuid → slot_types, set null | |
| name / email / whatsapp / notes / date_display | text | dati denormalizzati del cliente |
| status | text default 'confirmed' | valori usati: `confirmed`, `cancellation_requested`, `cancelled` |
| paid | boolean default false | |
| payment_method | text | 'contanti'/'carta'/'iban'/'stripe'/'gratuito'/'pacchetto'/'abbonamento' |
| paid_at | timestamptz | |
| custom_price | numeric(10,2) | override prezzo per-booking |
| consumed_package_id / consumed_membership_id | uuid (soft, no FK) | cosa è stato decrementato da book_slot → per il refund su cancel |
| cancellation_requested_at / cancelled_at | timestamptz | |
| cancelled_payment_method / cancelled_paid_at | text / timestamptz | snapshot pagamento pre-annullo |
| cancelled_refund_pct | integer | |
| created_by / cancelled_by | uuid | attore (auth.uid()) |
| arrived_at | timestamptz | check-in |
| reminder_24h_sent / reminder_1h_sent | boolean default false | usati da send-reminders |

Indici: `(org_id,date)`, `(org_id,date,time)`, `(org_id,email)`, `(user_id)`,
parziale `(org_id,date,time,slot_type) WHERE status IN ('confirmed','cancellation_requested')`,
`(org_id,updated_at)` (mig. 0014, per il delta-sync).

### 3.3 Scheduling flessibile

**`slot_types`** — tipi di lezione per-org. `(org_id, key)` UNIQUE.
`id, org_id, key text ('personal-training'…), label text, color text default '#8B5CF6',
default_capacity int default 1, default_price numeric(10,2) default 0, bookable bool default
true, is_active bool default true, trainer_id uuid → auth.users (opzionale), sort_order int
default 0, created_at`.
Default creati da `create_organization`: `personal-training` (#8B5CF6, cap 1),
`small-group` (#22C55E, cap 5), `group-class` (#F59E0B, cap 12).

**`time_slots_config`** — fasce orarie per-org. `(org_id, start_time, end_time)` UNIQUE.
`id, org_id, start_time time, end_time time, label text, sort_order int, is_active bool, created_at`.
L'etichetta client è `to_char(start,'HH24:MI') || ' - ' || to_char(end,'HH24:MI')` = formato di `bookings.time`.

**`weekly_schedule_templates`** — `id, org_id, name text, is_active bool default false, created_at`.
⚠️ `is_active` NON guida più la risoluzione (solo "default selezionato" nell'editor): dal
modello per-settimana (mig. 0020) conta `activated_weeks`.

**`weekly_template_slots`** — `(template_id, weekday, time_slot_id)` UNIQUE.
`id, template_id → weekly_schedule_templates cascade, org_id, weekday smallint 0-6 (0=Domenica,
come extract(dow)), time_slot_id → time_slots_config cascade, slot_type_id → slot_types cascade,
capacity int (NULL = default_capacity dello slot_type)`.

**`activated_weeks`** (mig. 0020) — attivazione manuale per-settimana. `(org_id, week_start)` UNIQUE.
`id, org_id, week_start date (LUNEDÌ della settimana, = date_trunc('week')), template_id →
weekly_schedule_templates cascade, created_at`. Settimana non attivata = nessuno slot prenotabile.

**`schedule_overrides`** — override puntuale per-data con capienza ASSOLUTA. `(org_id, date, time)` UNIQUE.
`id, org_id, created_at, date date, time text, slot_type text, slot_type_id uuid → slot_types
set null, capacity int (assoluta; NULL = default del tipo), client_name/client_email/
client_whatsapp text (per "Slot prenotato" nominativo), booking_id text`.

Risoluzione capienza/tipo (server = `resolve_slot_config`, client = `getEffectiveCapacity`):
**override → template della settimana attivata → default slot_type → (niente) non prenotabile**.

### 3.4 Billing-cliente (il cliente paga il trainer)

**`billing_settings`** — PK `org_id`. `default_model text default 'pay_per_session'` check ∈
`pay_per_session/monthly/package/free`; `block_unpaid_threshold numeric default 0 (0=nessun
blocco)`; `block_if_membership_expired bool default true`; `block_if_no_package bool default
true`; `grace_days int default 0`; `package_auto_decrement bool default true`; `updated_at`.

**`client_billing_profiles`** — override per-cliente. `(org_id, user_id)` UNIQUE.
`id, org_id, user_id → profiles cascade, client_email text, model_override text check come
sopra, custom_price numeric, notes text, created_at`.

**`client_memberships`** — abbonamento mensile cliente.
`id, org_id, user_id NOT NULL → profiles cascade, plan_label text, period_start date,
period_end date, lessons_quota int (NULL = illimitato), lessons_used int default 0, status text
default 'active' check ∈ active/expired/cancelled, auto_renew bool default false,
price numeric, created_at`.

**`client_packages`** — carnet prepagato.
`id, org_id, user_id NOT NULL → profiles cascade, label text, total_sessions int NOT NULL,
remaining_sessions int NOT NULL, purchased_at timestamptz default now(), expires_at date (NULL =
non scade), status text default 'active' check ∈ active/exhausted/expired/cancelled,
price numeric, created_at`.

**`payments`** — **LEDGER UNIFICATO** = unica fonte del fatturato.
`id, org_id, created_at, client_user_id uuid → profiles set null, client_email text,
amount numeric(10,2) NOT NULL, currency text default 'EUR', method text check ∈
contanti/contanti-report/carta/iban/stripe/gratuito, kind text check ∈
session/membership/package_purchase/penalty_mora/adjustment, booking_id uuid → bookings set
null, membership_id uuid → client_memberships set null, package_id uuid → client_packages set
null, period_start/period_end date, note text, created_by uuid, stripe_payment_intent text UNIQUE`.
Indice UNIQUE parziale: `payments(booking_id) WHERE kind='session'` → idempotenza (un booking
non genera due righe 'session').

### 3.5 Billing-SaaS (il trainer paga la piattaforma)

**`plans`** — catalogo. `id, code text UNIQUE (starter|pro|business), name, stripe_price_id_monthly
text, price_eur numeric, max_clients int (NULL=illimitato), features jsonb default '{}',
sort_order int, active bool default true`.
Seed: starter €39.99/50 clienti `{workout_plans:true, messaging:true, ai_reports:false,
client_online_payments:false}`; pro €79.99/200 (tutto true); business €149.99/illimitato (tutto true).

**`subscriptions`** — 1 per org (`org_id` UNIQUE). `id, org_id, plan_id → plans, stripe_customer_id
text, stripe_subscription_id text UNIQUE, status text default 'trialing' check ∈
trialing/active/past_due/canceled/unpaid/incomplete, current_period_end timestamptz,
cancel_at_period_end bool default false, trial_end timestamptz, created_at, updated_at`.
⚠️ Scritture SOLO da service_role (webhook/edge) — nessuna policy write per authenticated.

**`subscription_events`** — `id, org_id (nullable), stripe_event_id text UNIQUE (idempotenza
webhook), type text, payload jsonb, created_at`.

### 3.6 Settings

**`org_settings`** — PK `(org_id, key)`. `value jsonb NOT NULL default 'null', updated_at,
updated_by uuid → auth.users set null`. V. §6 per le chiavi.

### 3.7 Workout

**`workout_plans`** — `id, org_id (default current_org_id() — mig. 0012: gli INSERT client non
passano org_id), user_id NOT NULL → profiles cascade, name text NOT NULL, start_date date,
end_date date, notes text, active bool default true, created_at, updated_at`.
Indice `(org_id, user_id, active)`.

**`workout_exercises`** — `id, org_id (default current_org_id()), plan_id NOT NULL →
workout_plans cascade, day_label text default 'Giorno A', exercise_name text NOT NULL,
exercise_slug text, muscle_group text, sort_order int default 0, sets int default 3, reps text
default '10', weight_kg numeric(6,1), rest_seconds int default 90, superset_group uuid,
circuit_group uuid, notes text`. Indice `(plan_id, sort_order)`.
Superserie = 2 esercizi con lo stesso `superset_group` (il primo con rest_seconds=0);
circuito = N≥2 esercizi con lo stesso `circuit_group` (stesso `sets` = giri; solo l'ultimo per
sort_order ha rest > 0).

**`workout_logs`** — UNIQUE `(exercise_id, user_id, log_date, set_number)`.
`id, org_id (default current_org_id()), exercise_id NOT NULL → workout_exercises cascade,
user_id NOT NULL → profiles cascade, log_date date default current_date, set_number int NOT
NULL, reps_done int, weight_done numeric(6,1), rest_done int, rpe int check 1-10, notes text,
created_at`. Indici `(exercise_id, log_date)`, `(user_id)`.

**`imported_exercises`** — catalogo esercizi importato per-org (org_id NULLABLE: NULL = catalogo
globale piattaforma; default current_org_id()). Colonne (post mig. 0011): `id, org_id, slug,
nome_it, nome_original, nome_en, categoria, immagine, immagine_thumbnail, video, popolarita int
default 0, data jsonb`. Indice `(org_id, slug)`.

### 3.8 Notifiche / report / eventi

**`push_subscriptions`** — UNIQUE `(endpoint)`. `id, org_id, user_id NOT NULL → auth.users
cascade, endpoint text NOT NULL, p256dh text, auth text, created_at`.

**`client_notifications`** — `id, org_id, user_id → profiles cascade, title, body, read bool
default false, created_at`.

**`admin_messages`** — registro notifiche admin. `id, org_id, kind text ('booking',
'cancellation', …), title, body, read bool, created_at`.

**`monthly_reports`** (schema "ricco", mig. 0015) — `id, org_id, user_id → profiles cascade,
year_month text (ex `month`), tone text, content text, scorecard jsonb, narrative text, status
text default 'pending', model_used text, input_tokens int, output_tokens int,
cost_usd numeric(8,5), error_message text, generated_at timestamptz, updated_at, created_at`.
Indice parziale `(org_id, user_id, year_month, generated_at desc) WHERE status='generated'`.

**`login_events`** — v. §2.9. `id, org_id (nullable), user_id → auth.users set null, event,
event_type, device_hash, user_agent, platform, browser, screen_size, timezone, language,
is_pwa, created_at`.

### 3.9 Piattaforma / Stripe Connect

**`platform_admins`** — `user_id uuid PK → auth.users cascade, email, created_at, note`.
**`platform_settings`** — riga unica (`id boolean PK default true check(id)`), `open_access bool
default true` (accesso dev aperto), `updated_at`.
**`stripe_oauth_states`** — `state text PK, org_id, user_id, created_at`. RLS deny-all
(solo service_role via edge).

### 3.10 Pattern RLS (riassunto)

- SELECT: `org_id = current_org_id()` (+ per dati personali: `user_id = auth.uid() OR
  is_org_admin(org_id)`).
- Scritture business: solo admin (`is_org_admin`) — eccezioni: `profiles` (self-update),
  `workout_logs` (own write), `push_subscriptions` (own), `login_events` (insert own).
- `bookings`: INSERT SOLO via RPC `book_slot` (nessuna policy insert per il cliente).
- `plans`: lettura libera per authenticated. `subscriptions`: sola lettura per la propria org.
- **Client anonimi non leggono MAI tabelle**: solo le RPC dell'allowlist anon (v. §4.6).
- Data API grants (mig. 0013): `GRANT SELECT/INSERT/UPDATE/DELETE ... TO authenticated`
  (mai ad `anon`), anche come default privilege per le tabelle future.

---

## 4. RPC / FUNZIONI — firme esatte e semantica

Tutte `SECURITY DEFINER` + `set search_path = public`. Convenzione errori: le funzioni "jsonb"
ritornano `{success:false, error:'<code>'}`; le altre sollevano `raise exception 'unauthorized'`
ecc. (arriva come errore PostgREST).

### 4.1 Helper tenancy (usati dalle policy; chiamabili anche dal client)

- **`current_org_id() returns uuid`** — claim `app_metadata.org_id` → fallback `org_members`
  (attiva, più vecchia) → fallback `profiles.org_id`.
- **`current_org_role() returns text`** — claim `app_metadata.org_role` → fallback membership.
- **`is_org_admin(p_org_id uuid default null) returns boolean`** — esiste membership attiva
  owner/admin per `coalesce(p_org_id, current_org_id())`.
- **`is_admin() returns boolean`** — alias di `is_org_admin()` (compat storica).
- **`org_id_for_slug(p_slug text) returns uuid`** — `organizations.slug = lower(trim(p_slug))
  AND status <> 'cancelled'`.
- **`get_org_price(p_org_id uuid, p_slot_type text) returns numeric`** — `slot_types.default_price`
  del tipo attivo, else 0.
- **`org_at_client_limit(p_org_id uuid) returns boolean`** — true se `count(profiles della org)
  >= plans.max_clients` (via subscription); NULL (=nessun limite) se max_clients NULL o nessuna
  subscription.
- **`normalize_comune(input text) returns text`** — replica SQL di `normalizeComune` (v. §2.10).

### 4.2 Scheduling / disponibilità / prenotazione

- **`resolve_slot_config(p_org_id uuid, p_date date, p_time text)
  returns table(slot_type text, slot_type_id uuid, capacity integer, price numeric, bookable boolean)`**
  — unica fonte di verità di tipo/capienza: 1) `schedule_overrides` per (org,data,ora) —
  capacity = `coalesce(override.capacity, slot_type.default_capacity)`; se l'override non ha
  slot_type_id valido → capacity = `coalesce(override.capacity,0)`, price 0, bookable true;
  2) template della **settimana attivata** (`activated_weeks.week_start = date_trunc('week',
  p_date)`) + `time_slots_config` risolto dall'etichetta `p_time`; 3) niente → `(null, null, 0,
  0, false)`.

- **`book_slot(p_org_slug text, p_local_id text, p_date text, p_time text, p_name text,
  p_email text, p_whatsapp text, p_notes text, p_date_display text default '',
  p_for_user_id uuid default null) returns jsonb`** — prenotazione server-authoritative.
  Flusso: org = `coalesce(org_id_for_slug(p_org_slug), current_org_id())`; attribuzione
  `user_id`: `p_for_user_id` (solo se caller admin e profilo della org) → caller se ha profilo
  nella org → NULL; validazioni: email regex, nome obbligatorio, data passata vietata ai
  non-admin, `resolve_slot_config` (bookable && capacity>0), cutoff non-admin
  `now() > inizio_lezione(+tz org) + 30 min` → `too_late`; **advisory lock**
  `pg_try_advisory_xact_lock(hashtext(org|date|time|slot_type))` → `slot_busy`; conteggio
  occupati (`status IN ('confirmed','cancellation_requested')`) vs capacity → `slot_full`;
  **gating billing** (solo se user_id risolto): modello =
  `coalesce(client_billing_profiles.model_override, billing_settings.default_model,
  'pay_per_session')`: `free` → paid=true metodo 'gratuito'; `package` → decrementa il pacchetto
  attivo più vecchio (FOR UPDATE; esaurito → status 'exhausted'), traccia
  `consumed_package_id`, paid=true metodo 'pacchetto'; se nessun pacchetto e
  `block_if_no_package` → `no_package`; `monthly` → membership attiva più recente, controlla
  `period_end + grace_days` → `membership_expired`, quota → `quota_exceeded`, incrementa
  `lessons_used`, traccia `consumed_membership_id`, paid=true metodo 'abbonamento';
  `pay_per_session` → paid=false. INSERT bookings → **ritorna
  `{success:true, booking_id:'<uuid>', paid:bool}`**. Errori possibili: `org_not_found`,
  `invalid_email`, `missing_name`, `past_date`, `not_bookable`, `too_late`, `slot_busy`,
  `slot_full`, `no_package`, `membership_expired`, `quota_exceeded`, `duplicate_booking`
  (unique_violation). Grant: anon + authenticated.

- **`get_availability_range(p_org_slug text, p_from date, p_to date) returns jsonb`** —
  array di `{date, time, slot_type, capacity, confirmed_count, remaining}` aggregati per gli
  slot CON almeno una prenotazione occupante (`status IN ('confirmed','cancellation_requested')`
  — mig. 0024, allineato a book_slot; il campo si chiama `confirmed_count` per retro-compat ma
  conta gli OCCUPATI). capacity da `resolve_slot_config`;
  `remaining = greatest(capacity - occupati, 0)`. `[]` se slug ignoto. Grant anon+auth.
  ⚠️ NB: ritorna solo slot con ≥1 prenotazione — gli slot vuoti si deducono dalla config locale.

- **`get_slot_availability(p_org_slug text, p_date date) returns jsonb`** — come sopra per una
  sola data: array di `{time, slot_type, capacity, confirmed_count, remaining}`.

- **`get_slot_attendees(p_org_slug text, p_date date, p_time text)
  returns table(name text, slot_type text)`** (firma post mig. 0027) — nomi degli iscritti
  confermati allo slot; chi ha `privacy_prenotazioni=true` compare come **'Anonimo'**. Solo
  prenotazioni con `user_id` (join profiles). Ordinata per slot_type, poi anonimi in fondo,
  poi nome. Il client raggruppa per `slot_type` quando lo slot ospita 2+ tipi. Grant anon+auth.

### 4.3 Booking management (admin) e cancellazioni

- **`admin_update_booking(p_booking_id uuid, p_status text, p_paid boolean default false,
  p_payment_method text default null, p_paid_at timestamptz default null,
  p_custom_price numeric default null, p_cancellation_requested_at timestamptz default null,
  p_cancelled_at timestamptz default null, p_cancelled_payment_method text default null,
  p_cancelled_paid_at timestamptz default null, p_cancelled_refund_pct integer default null,
  p_arrived_at timestamptz default null, p_expected_updated_at timestamptz default null)
  returns jsonb`** — richiede admin. Optimistic locking: se `p_expected_updated_at` ≠
  `updated_at` corrente → `{success:false, error:'stale_data', server_updated_at}`. Altrimenti
  aggiorna TUTTE le colonne elencate (⚠️ **è un update totale**: i parametri omessi cadono al
  default `null` e SOVRASCRIVONO — in particolare `custom_price` e `arrived_at`. Il web li
  omette in `replaceAllBookings`: nel port Flutter passare SEMPRE i valori correnti di
  `p_custom_price`/`p_arrived_at` per non azzerarli). Successo:
  `{success:true, updated_at:now()}`.
- **`admin_delete_booking(p_booking_id uuid) returns void`** — admin; refund
  pacchetto/membership consumati (se non già 'cancelled') poi DELETE fisico.
- **`user_request_cancellation(p_booking_id uuid) returns jsonb`** — proprietario o admin;
  richiede status 'confirmed'; setta `cancellation_requested` + timestamp + `cancelled_by`.
  Errori: `booking_not_found`, `unauthorized`, `not_confirmed`.
- **`cancel_booking(p_booking_id uuid) returns jsonb`** — proprietario o admin. Cutoff
  server-side per non-admin (grace 10 min dalla creazione = sempre annullabile; poi:
  group-class annullabile solo se lezione > 3 giorni; altri tipi > 24h, timezone org) →
  `cancellation_window_closed`. Refund del pacchetto (`remaining_sessions+1`, 'exhausted' →
  'active') o membership (`lessons_used-1`); poi status 'cancelled' con snapshot pagamento
  (`cancelled_payment_method/paid_at`), `paid=false`, azzeramento `consumed_*` (no doppio
  refund). Se era `group-class` → upsert `schedule_overrides` riconvertendo lo slot a
  `small-group`. Errori: `booking_not_found`, `unauthorized`, `already_cancelled`,
  `cancellation_window_closed`.
- **`process_pending_cancellations() returns integer`** — SOLO service_role (cron ~15 min):
  riporta a 'confirmed' le richieste con lezione entro 2h (finestra date ±48h, tz per-org).
- **`admin_pay_bookings(p_booking_ids uuid[], p_method text, p_paid_at timestamptz default
  now()) returns integer`** — admin; per ogni booking non pagato della org: setta
  paid/method/paid_at e INSERISCE nel ledger `payments` (kind 'session', amount =
  `coalesce(custom_price, get_org_price(org, slot_type))`, ma **0 se metodo 'gratuito'**;
  method whitelisted, fallback 'contanti'; `on conflict (booking_id) where kind='session' do
  nothing`). Ritorna il numero di booking saldati.

### 4.4 Profili / clienti / org

- **`get_all_profiles() returns table(id uuid, name text, email text, whatsapp text,
  medical_cert_expiry text, medical_cert_history jsonb, insurance_expiry text,
  insurance_history jsonb, codice_fiscale text, indirizzo_via text, indirizzo_cap text,
  indirizzo_paese text, documento_firmato boolean, geo_enabled boolean, push_enabled boolean,
  privacy_prenotazioni boolean)`** — admin only, tutti i profili della org, order by name.
  Le date sono castate a `text`.
- **`get_all_profiles_basic()`** — identica ma SENZA le due colonne `*_history` (egress). Il
  client prova prima questa e ricade sulla full se assente/errore.
- **`is_whatsapp_taken(phone text, exclude_user_id uuid default null) returns boolean`** —
  esiste un profilo nella org corrente con quel whatsapp (escluso l'id opzionale).
  Grant anon+auth.
- **`create_organization(p_name text, p_slug text) returns uuid`** — richiede login.
  Valida slug (`^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$`, unico). Crea: org 'trialing' →
  org_members(owner) → billing_settings default → subscription trial 30 gg su piano starter →
  3 slot_types default → org_settings di base (`branding.studio_name`, `branding.primary_color`
  '#8B5CF6', `locale.timezone` 'Europe/Rome', `locale.currency` 'EUR',
  `booking.policy.free_cancel_hours` 24, `booking.policy.penalty_pct` 50). Eccezioni:
  `not_authenticated`, `invalid_slug`, `slug_taken`. **Dopo: refreshSession()**.
- **`join_organization(p_org_slug text) returns uuid`** — utente autenticato si associa come
  cliente alla org dello slug; enforcement `org_at_client_limit` → eccezione
  `client_limit_reached`; crea `profiles` (on conflict do nothing) e aggancia i bookings
  anonimi con la stessa email. Ritorna l'uuid della org.
- **`invite_org_member(p_email text, p_role text) returns void`** — admin; role ∈
  admin/staff; upsert membership per l'utente con quell'email (se esiste in auth.users).
- **`admin_rename_client(p_old_email text, p_old_whatsapp text default null, p_new_name text
  default null, p_new_email text default null, p_new_whatsapp text default null) returns jsonb`**
  — admin; allinea `profiles` + `bookings` (match per email O whatsapp);
  `{success, profiles_updated, bookings_updated}`.
- **`admin_delete_client_data(p_email text default null, p_whatsapp text default null)
  returns jsonb`** (firma post mig. 0023) — admin; cancella bookings (match email/whatsapp) +
  memberships + packages + notifications + billing_profiles del cliente. NON tocca `payments`
  (ledger) né la riga `profiles`. `{success, bookings_deleted, memberships_deleted,
  packages_deleted, billing_profiles_deleted, notifications_deleted}`.
- **`set_report_ai_consent(p_consent boolean) returns void`** — self-update di
  `profiles.report_ai_consent`.

### 4.5 Settings / entitlements / billing / manutenzione

- **`upsert_org_setting(p_key text, p_value jsonb) returns void`** — admin; upsert su
  `org_settings(org corrente, key)`.
- **`get_public_org_settings(p_org_slug text) returns jsonb`** — oggetto `{key: value}` con la
  **whitelist pubblica**: `branding.%`, `locale.%`, `booking.policy.%`,
  `billing_client.prices%`, `maintenance.%`, più `company.maps_url` e `company.address`.
  Grant anon+auth.
- **`get_tenant_entitlements() returns jsonb`** — `{plan, status, max_clients, features,
  trial_end, current_period_end, clients_count}` dalla subscription della org (null se
  assente). Client-side (entitlements.js): fail-closed finché non caricato; stati "attivi" =
  `trialing`,`active`; `has(flag) = features[flag] !== false` (a esito noto).
- **`admin_sell_package(p_user_id uuid, p_label text, p_sessions integer, p_price numeric,
  p_method text default 'contanti', p_expires date default null) returns uuid`** — admin; crea
  `client_packages` + riga `payments` kind 'package_purchase'. Ritorna l'id pacchetto.
- **`admin_record_membership_payment(p_user_id uuid, p_label text, p_price numeric,
  p_period_start date, p_period_end date, p_lessons_quota integer default null, p_method text
  default 'contanti') returns uuid`** — admin; crea `client_memberships` attiva + riga
  `payments` kind 'membership'.
- **`admin_clear_all_data() returns jsonb`** — admin; azzera i dati OPERATIVI della sola org:
  payments, workout (logs→exercises→plans), packages/memberships/billing_profiles,
  schedule_overrides, bookings, client_notifications, admin_messages, monthly_reports.
  NON tocca organizations/org_members/profiles/plans/subscriptions.
- **`admin_prune_old_data(p_cutoff date) returns jsonb`** — admin; DELETE bookings con
  `date < cutoff` + bookings demo (`local_id like 'demo-%'`).
  `{success, bookings_deleted, demo_deleted}`.
- **`admin_health_check() / admin_health_fix() returns jsonb`** — stub `{success:true}` (admin).
- **`admin_duplicate_plan(p_plan_id uuid, p_new_user_id uuid, p_new_name text default null)
  returns uuid`** — admin; duplica scheda+esercizi su un altro cliente della org (start_date =
  oggi, active). Eccezioni: `plan_not_found`, `user_not_in_org`.
- **`get_exercise_suggestions() returns table(exercise_name text)`** — nomi distinti degli
  esercizi della org (autocomplete).
- **`save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_email text
  default null, p_user_id uuid default null) returns void`** — upsert su
  `push_subscriptions(endpoint)` con org corrente.
- **`get_push_enabled_users() returns setof uuid`** — id dei profili della org con
  `push_enabled=true`.

### 4.6 Grant / allowlist ANON (mig. 0022)

Le UNICHE funzioni eseguibili da `anon`: `book_slot`, `get_availability_range`,
`get_slot_availability`, `get_slot_attendees`, `is_whatsapp_taken`, `get_public_org_settings`,
e le `kiosk_*`. `process_pending_cancellations` è solo service_role. Tutto il resto:
solo `authenticated` (le admin_* si autoproteggono con `is_org_admin`).

### 4.7 RPC piattaforma (super-admin dashboard)

`is_platform_admin() returns boolean` (open_access OR whitelist);
`admin_platform_overview() returns jsonb` (KPI: total_orgs, orgs_per_status, new_orgs_30d,
trials_expiring_7d, total_clients, total_bookings, mrr, gmv_clients_total, gmv_clients_30d);
`admin_platform_organizations() returns table(org_id, name [preferisce
branding.studio_name], slug, status, created_at, created_via, owner_email, owner_name,
plan_code, plan_name, plan_price, sub_status, trial_end, current_period_end,
cancel_at_period_end, stripe_customer_id, client_count, member_count, booking_count,
bookings_30d, revenue_total, revenue_30d, last_activity, stripe_account_id,
stripe_charges_enabled)`;
`admin_platform_set_org_status(p_org_id uuid, p_status text)`;
`admin_platform_extend_trial(p_org_id uuid, p_days integer default 30)`;
`admin_platform_set_plan(p_org_id uuid, p_plan_code text)`;
`admin_platform_lock(p_email text)` (whitelista l'email e chiude open_access).

### 4.8 RPC kiosk (tablet condiviso, client anonimo — opzionali per il port mobile)

Modello di fiducia: il chiamante conosce l'uid del cliente (QR) e accede SOLO ai suoi dati
workout. `kiosk_load_workout(p_uid uuid) returns jsonb` `{user_name, plan, exercises[], logs[]
(30gg)}`; `kiosk_load_progress(p_uid) returns jsonb` `{exercises[], logs[] (90gg)}`;
`kiosk_exercise_catalog(p_uid) returns jsonb`; `kiosk_save_logs(p_uid, p_logs jsonb) returns
jsonb` (upsert batch, ownership per riga); `kiosk_delete_logs(p_uid, p_exercise_id, p_date)`;
`kiosk_update_exercise(p_uid, p_ex_id, p_updates jsonb)`; `kiosk_add_exercises(p_uid,
p_plan_id, p_rows jsonb)`; `kiosk_reorder_exercises(p_uid, p_orders jsonb)`;
`kiosk_delete_exercise(p_uid, p_ex_id)`; `kiosk_delete_superset(p_uid, p_group_id)`;
`kiosk_rename_plan(p_uid, p_plan_id, p_name)`.

### 4.9 Trigger DB rilevanti (comportamenti da conoscere)

- `handle_new_user` (AFTER INSERT auth.users) — v. §2.4.
- `trg_set_updated_at` su organizations/workout_plans/subscriptions/bookings/profiles.
- `_trg_profiles_block_self_admin_flags` (BEFORE UPDATE profiles) — reverte in silenzio il
  self-update di `documento_firmato` e di `email` (se già valorizzata) per i non-admin.
- `_guard_org_stripe_cols` (BEFORE UPDATE organizations) — i campi stripe_* sono scrivibili
  solo dal service_role (eccezione `stripe_fields_readonly`).

---

## 5. STORAGE LAYER JS (da mappare su repository Dart)

### 5.1 Helper trasversali

- `_localDateStr(d)` → `YYYY-MM-DD` in **fuso locale** (mai UTC: off-by-one dopo le 23 CET).
- `_parseSlotTime("HH:MM - HH:MM")` → `{startH,startM,endH,endM}`.
- `_rpcWithTimeout(promise, ms=12000)` / `_queryWithTimeout` — timeout esplicito su OGNI
  query/RPC (con abort). Timeout usati: default 12 s; fingerprint 10 s; CRUD workout 15 s;
  fetchForAdmin/history 15 s; workout sync 30 s; book_slot 45 s (abort).
- `fetchAllPaginated(queryBuilderFn, {timeoutMs=30000, maxRows=500000})` — pagina a batch di
  1000 (`range`) superando il cap PostgREST; il builder crea una query fresca per pagina;
  SEMPRE con tiebreaker `.order('id')` per pagine stabili.
- `_mondayYMD(dateStr)` — lunedì ISO della settimana (allineato a `date_trunc('week')`).
- `getBookingPrice(booking)` — prezzo display: `custom_price` → `OrgSettings
  'billing_client.prices'[slotType]` → `price.<slotType>` (legacy) → listino hardcoded
  deprecato. (L'importo REALE incassato lo decide il server in `admin_pay_bookings`.)

### 5.2 Config orari per-org (runtime)

`loadOrgScheduleConfig()` (su pageload e in `syncAppSettingsFromSupabase`) carica in parallelo:
- `slot_types` → mappa `_ORG_SLOT_TYPES[key] = {id, key, label, color, defaultCapacity,
  defaultPrice, bookable, isActive, sortOrder}` (solo attivi, order by sort_order);
- `time_slots_config` → `_ORG_TIME_SLOTS` = array etichette `'HH:MM - HH:MM'` attive ordinate;
- `activated_weeks` → `_ORG_ACTIVE_WEEKS[mondayYMD] = templateId`;
- `weekly_template_slots` (join `time_slots_config` + `slot_types`) →
  `_ORG_TPL_WEEKLY[templateId][weekday 0-6][time] = {slotTypeId, slotTypeKey, capacity}`
  (capacity = riga o default del tipo).

**Snapshot sincrono anti-flash**: dopo il load persiste `_orgSchedSnap_<orgId>` (JSON delle 4
strutture) + `_lastOrgId` (puntatore stabile). Al boot successivo `_hydrateOrgScheduleFromCache()`
idrata SUBITO dalla cache (prima che l'auth risolva l'orgId) → niente flash di orari altrui.
Accessor: `getSlotName(key)`, `getSlotColor(key)` (fallback '#8B5CF6'), `getTimeSlots()`,
`getWeeklySchedule(dateStr)` (**date-aware**: usa il template della settimana attivata; in
contesto org senza settimana attivata → griglia VUOTA, mai il default legacy single-tenant).

### 5.3 BookingStorage (la classe più complessa)

**Cache in memoria** `_cache`: array di booking mappati dal DB con `_mapRow`:
`{id: local_id||id, _sbId: id, userId, date, time, slotType, dateDisplay, name, email,
whatsapp, notes, status, paid, paymentMethod, paidAt, customPrice, createdAt,
cancellationRequestedAt, cancelledAt, cancelledPaymentMethod, cancelledPaidAt,
cancelledRefundPct, updatedAt, createdBy, cancelledBy, arrivedAt}`.

**`syncFromSupabase({ownOnly=false, forceFull=false})`** — dedup in-flight per chiave
('own'/'all'). Tre percorsi per identità:

1. **ANON** (no user, no admin): SOLO `get_availability_range(slug, oggi, +90gg)` → costruisce
   **booking sintetici** senza dati personali (`id: '_avail_<date>_<time>_<type>_<i>'`, uno per
   posto occupato) + indicizza `_availabilityByKey['date|time|type'] = {capacity, remaining,
   confirmedCount}` (server-authoritative).
2. **UTENTE autenticato**: SELECT delle proprie righe (finestra sotto, `ownOnly` filtra
   `user_id=eq`) + `get_availability_range` in parallelo → sintetici per i posti ALTRUI
   (occupati − propri confermati).
3. **ADMIN full-list**: SELECT completo org (RLS) con **strategia egress a 3 livelli**:
   - **Finestra FULL**: `date <= oggi+90gg AND (date >= oggi-60gg OR (paid=false AND
     status<>'cancelled'))` — cioè 60 gg passati + 90 futuri + TUTTI i debiti vecchi non pagati.
     Colonne esplicite (v. `_mapRow`), paginate a 1000 con tiebreaker id.
   - **Fingerprint** `"<count>|<maxUpdatedAt>"` (1 query: count exact + prima riga per
     updated_at desc, STESSO filtro della full): se invariato → **SKIP** totale.
   - **DELTA**: se il fingerprint cambia senza delete (count non sceso) e il reconcile non è
     dovuto → scarica SOLO `updated_at >= cursore − 5 s` (overlap anti clock-skew), senza floor
     di data; merge idempotente per `_sbId` (Map). Aggiorna il fingerprint al valore server.
   - **Reconcile**: FULL forzato ogni 5 min (`_BK_RECONCILE_MS`) — safety net per hard-delete.
   - `forceFull` bypassa tutto (usato dal Registro/audit).
   - Prima delle query: `ensureValidSession({timeoutMs:3000})` best-effort (token fresco).

**Persistenza cross-pagina** (web MPA): chiave
`gym_bookings_cache_v2:<syncKey>:<identity>` (identity = 'admin' o user.id; anon = niente
persist) con `{savedAt, clearedAt, fingerprint, lastFull, rows}` (solo righe reali con _sbId,
max **8000** righe, TTL **15 min**). `_hydrateCache` la ripristina al primo sync di pagina
(scartata se `dataLastCleared` è cambiato o oltre TTL) → il sync diventa skip/delta.

**Cache disponibilità** `_availCache` — dedup di `get_availability_range` per chiave
`slug|from|to`, TTL **60 s**; invalidata da ogni azione che cambia la capienza
(prenota/annulla/converti).

**Scritture** (tutte server-authoritative):
- `saveBooking(booking)` — genera `id = "<Date.now()>-<rand36(9)>"` e `createdAt`;
  `ensureValidSession()` best-effort; RPC `book_slot` (senza p_for_user_id) con abort 45 s;
  su success: `_sbId = booking_id`, `paid` dal server, push in cache, `updateStats`,
  invalidazione avail-cache. Ritorna `{ok, error?, booking}` (error: 'offline',
  'server_error', o il codice della RPC).
- `saveBookingForClient(booking, clientUserId)` — come sopra ma con `p_for_user_id`
  (gate admin client-side + server-side).
- `replaceAllBookings(bookings)` — sostituisce la cache e fa il **diff** con la precedente
  (per id) sui campi `status/paid/paymentMethod/paidAt/cancellationRequestedAt/cancelledAt`;
  per ogni cambiato con `_sbId` chiama `admin_update_booking` (con
  `p_expected_updated_at = updatedAt` per l'optimistic locking; su errore o `stale_data` →
  toast + re-sync completo). ⚠️ Richiede oggetti NUOVI per i patch (mai mutare in place, il
  diff diventerebbe vuoto): helper `_withBookingPatch(all, id, patch)`.
- `_cancelPatch(b)` — patch standard di annullo: preserva `cancelledPaymentMethod/PaidAt`,
  status 'cancelled', `cancelledAt`, paid=false, method/paidAt null.
- `cancelDirectly(id)`, `cancelAndConvertSlot(id)` (group-class → small-group in overrides),
  `requestCancellation(id)` (→ 'cancellation_requested'), `fulfillPendingCancellations(date,
  time)` (FIFO sul più vecchio richiedente), `processPendingCancellations()` (client-side, solo
  pagine admin; l'autorità è il cron server). NB: le pagine cliente usano le RPC
  `cancel_booking`/`user_request_cancellation` direttamente (prenotazioni.html).
- `removeBookingById(id)` — marca cancelled via replaceAllBookings.
- `_retryPending(pending, user)` — ritenta via `book_slot` (MAI insert diretto) i booking
  locali senza `_sbId` più giovani di 30 min.

**Letture di capienza**:
- `getEffectiveCapacity(date, time, slotType)` — precedenza: `_availabilityByKey` (server) →
  override locale (`capacity` assoluta; tipo diverso → 0) → template settimana attivata →
  `_ORG_SLOT_TYPES[type].defaultCapacity` (fallback legacy).
- `getRemainingSpots(date, time, slotType)` — conta in cache i confermati +
  `cancellation_requested` del tipo; se non ci sono righe reali locali si fida del `remaining`
  server.
- `addExtraSpot`/`removeExtraSpot` — incrementa/decrementa la capacity assoluta dell'override.

**Schedule overrides (client)**:
- chiave localStorage **`scheduleOverrides_<orgId>`** ('anon' se sconosciuta) — formato
  `{ 'YYYY-MM-DD': [ {time, type, capacity?, slotTypeId?, client?{name,email,whatsapp},
  bookingId?} ] }`; cache in memoria org-scoped (invalidata al cambio org).
- `saveScheduleOverrides(overrides, changedDates)` — scrive LS, poi async: upsert su
  `schedule_overrides` (`onConflict: 'org_id,date,time'`, righe con org_id, slot_type_id
  risolto dalla key) + DELETE degli slot rimossi dalle date cambiate (o, in full-sync, delle
  righe assenti in locale **entro il cutoff**).
- **Cutoff egress** `_overridesCutoff()`: admin = 1° gennaio dell'anno precedente; altri =
  oggi − 30 gg. Usato sia nel fetch che nel confronto-delete.
- `saveScheduleOverride(date, time, slotType, capacity, extra)` — wrapper puntuale.

**`syncAppSettingsFromSupabase()`** — orchestratore del boot dati: 1) `loadOrgScheduleConfig()`;
2) in parallelo: fetch finestrato `schedule_overrides` (colonne: date,time,slot_type,
slot_type_id,capacity,client_name,client_email,client_whatsapp,booking_id) + `org_settings`
(autenticato: select key,value per org; anonimo: `get_public_org_settings(slug)`);
3) **marker clear**: se `org_settings['data_cleared_at'].ts` > `dataLastCleared` locale →
svuota TUTTE le cache e setta i marker `dataLastCleared`/`dataClearedByUser` (propagazione
cross-device del "cancella tutto"); 4) applica overrides a LS; 5) mappa le chiavi settings DB →
chiavi LS legacy `gym_*` (v. §5.6).

**Stats locali** (`gym_stats`): `{totalBookings, totalRevenue, typeDistribution{}, dailyBookings{}}`
— contatore display-only aggiornato a ogni saveBooking; azzerato al logout.

### 5.4 UserStorage (profili clienti, admin)

- `syncUsersFromSupabase()` — fingerprint-skip identico ai bookings (`"<count>|<maxUpd>"` su
  `profiles`, reconcile 5 min) → RPC `get_all_profiles_basic` (fallback `get_all_profiles`) →
  **merge**: i dati anagrafici Supabase sono autoritativi, cert/assicurazione locali vincono se
  il server è null, gli utenti solo-locali (senza account) sono preservati. Dedup per email
  (lowercase) e telefono (ultime 10 cifre). Campi mappati:
  `{userId, name, email, whatsapp, certificatoMedicoScadenza, certificatoMedicoHistory,
  assicurazioneScadenza, assicurazioneHistory, codiceFiscale, indirizzoVia, indirizzoPaese,
  indirizzoCap, documentoFirmato, privacyPrenotazioni, geoEnabled, pushEnabled, stripeEnabled}`.
- **Snapshot cross-pagina**: chiave `gym_users_cache_v1` `{cache, fp, savedAt, clearedAt, org}`
  — admin-only, org-scoped, TTL **24 h**, ma `savedAt` fa valere il TTL di rete 5 min
  cross-pagina.
- `getAll()` — contatti unificati: profili registrati + clienti unici dalla history bookings
  (dedup email/telefono), ordinati per nome. `search(query)` min 2 char su nome/email/whatsapp.
- `syncPushEnabledUsers()` — RPC `get_push_enabled_users` → `Set<uuid>` per le icone admin.

### 5.5 WorkoutPlanStorage / WorkoutLogStorage

**WorkoutPlanStorage**:
- `syncFromSupabase({adminMode, force})` — query `workout_plans` con **embed**
  `select('*, workout_exercises(*)')`; client mode: solo proprie schede `active=true`; order
  by updated_at desc; esercizi ordinati per sort_order. **Due TTL**: localStorage 30 min
  (chiavi `workout_plans_cache_admin_v1` / `workout_plans_cache_client_v1`,
  `{ts, data}`) + TTL di RETE 5 min (`_NET_TTL_MS`, salta il re-fetch se cache popolata;
  `force` bypassa). Dedup in-flight per modo.
- CRUD (tutte con timeout 15 s, aggiornano la cache localmente):
  `createPlan({user_id, name, start_date, end_date, notes})` (insert + select single, active
  true); `updatePlan(planId, updates)`; `deletePlan(planId)`; `duplicatePlan(planId, newUserId,
  newName)` → RPC `admin_duplicate_plan` + resync; `addExercise(planId, data)` (sort_order:
  max dal DB + 1 se non passato); `addSuperset(planId, ex1, ex2)` (uuid `superset_group`
  condiviso, primo con rest 0); `addCircuit(planId, items[])` (uuid `circuit_group`);
  `updateExercise(id, updates)`; `deleteExercise(id)`; `reorderExercises(planId, orderedIds)`
  (rinumera dal MIN sort_order del gruppo — non collide con gli altri giorni).

**WorkoutLogStorage** (solo memoria, no LS):
- `syncForPlan(planId)` — logs `in('exercise_id', ids)` PAGINATI (`fetchAllPaginated`), order
  log_date desc + set_number asc + id; colonne
  `id,exercise_id,user_id,log_date,set_number,reps_done,weight_done,rest_done,rpe,notes`.
- `syncForUser(userId)` — idem per tutti i piani (grafici cross-plan).
- `logSet({...})` — **upsert** con `onConflict: 'exercise_id,user_id,log_date,set_number'`.
- `deleteLog(logId)`.

### 5.6 Settings legacy (dual-key: LS `gym_*` ↔ DB `org_settings` senza prefisso)

Helper `_upsertSetting(lsKey, value)` — fire-and-forget: mappa `gym_cancellation_mode` →
`cancellation_mode` ecc., coercion a jsonb ('true'/'false' → bool; stringa JSON → parsata),
RPC `upsert_org_setting`. Classi e chiavi:

| Classe | Chiave LS | Chiave DB | Default |
|---|---|---|---|
| CancellationModeStorage | `gym_cancellation_mode` | `cancellation_mode` | `'penalty-50'` |
| CertEditableStorage | `gym_cert_scadenza_editable` | `cert_scadenza_editable` | true |
| CertBookingStorage | `gym_cert_block_expired` / `gym_cert_block_not_set` | `cert_block_expired` / `cert_block_not_set` | false |
| AssicBookingStorage | `gym_assic_block_expired` / `gym_assic_block_not_set` | `assic_block_expired` / `assic_block_not_set` | false |
| BookingBadgesStorage | `gym_show_cert_badge` / `gym_show_assic_badge` / `gym_show_doc_badge` / `gym_show_anag_badge` | `show_*_badge` | true |
| WeekTemplateStorage | `gym_week_templates` / `gym_active_week_template` | `week_templates` / `active_week_template` | 3 template default / 1 |

Il sync inverso (DB → LS) avviene in `syncAppSettingsFromSupabase` (§5.3). Nel port Flutter
queste classi si possono unificare in `OrgSettings` (le chiavi DB restano quelle sopra).

### 5.7 ls-namespace (web-only)

Patch trasparente di `Storage.prototype`: le 6 chiavi legacy NON namespacizzate
(`gym_bookings`, `gym_stats`, `weeklyScheduleTemplate`, `scheduleVersion`,
`gym_week_templates`, `gym_active_week_template`) vengono fisicamente salvate con prefisso
`palestria:` per evitare collisioni su origin condivisa. **Non replicare in Flutter** (lo
storage è già per-app); replicare invece il namespacing PER-ORG delle altre chiavi.

### 5.8 Realtime subscriptions

- **Unico canale attivo del data layer**: `org_settings_<orgId>` — `postgres_changes` su
  `public.org_settings` con filtro `org_id=eq.<orgId>` (INSERT/UPDATE/DELETE) → aggiorna
  cache+LS, notifica i listener `onChange(key, value)`, ri-applica il branding se la chiave
  inizia per `branding.`.
- Registry canali (silent-refresh): `window._registerRealtimeChannel(name, factory)` — dedup
  per nome, cleanup su `beforeunload`, **`_reconnectDeadChannels()`** al resume (ricrea i
  canali con `state` ≠ joined/joining).

### 5.9 Silent refresh (resume da idle — logica da tradurre in lifecycle nativo)

- Trigger: attività utente dopo ≥ **5 min** di idle (`wake-from-idle`) o evento `online`.
  Throttle: max 1 refresh / 60 s; dedup `refreshInFlight` con watchdog 30 s.
- Comportamento: se c'è un modal con input aperto → solo `ensureValidSession` (+ force solo su
  'online') + sync silenzioso (BookingStorage + AppSettings); altrimenti delega a
  `window._adminRefreshAfterResume(reason)` o `window._silentMasterRefresh(reason)` (hook per
  pagina, cap 20 s) o fallback sync+render. Sempre alla fine: `_reconnectDeadChannels()`.
- Marca `window._userRecoveryDepth` durante il recovery (il watchdog del client non fa reload).

### 5.10 Chiavi localStorage complete (riferimento)

| Chiave | Contenuto | Scope/TTL |
|---|---|---|
| `sb-rwaiekhllujximrqftmp-auth-token` | sessione supabase-js | gestita dalla lib |
| `gym_bookings_cache_v2:<all\|own>:<admin\|userId>` | snapshot bookings + watermark | 15 min, ≤8000 righe |
| `gym_users_cache_v1` | snapshot profili admin | 24 h, org-scoped |
| `gym_stats` (fisica `palestria:gym_stats`) | stats display | fino a logout/clear |
| `scheduleOverrides_<orgId>` | override calendario | org-scoped |
| `_orgSchedSnap_<orgId>` / `_lastOrgId` | snapshot config orari | org-scoped |
| `workout_plans_cache_admin_v1` / `_client_v1` | schede + esercizi | 30 min |
| `org_<orgId\|slug\|anon>_<key>` | org_settings per-tenant | org-scoped |
| `_brandingSnapshot` | branding per il paint pre-auth | non namespaced (rimosso al logout) |
| `dataLastCleared` / `dataClearedByUser` | marker clear cross-device | permanenti |
| `new_client_notified` | dedup notifica nuovo iscritto | = user.id |
| `push_subscription` | backup subscription push | |
| `gym_week_templates`, `gym_active_week_template`, `weeklyScheduleTemplate`, `scheduleVersion` | template legacy (prefisso fisico `palestria:`) | legacy |
| `gym_cancellation_mode`, `gym_cert_*`, `gym_assic_*`, `gym_show_*_badge` | settings legacy | mirror org_settings |

---

## 6. ORG SETTINGS — chiavi e struttura del value (jsonb)

Lette con `OrgSettings.get/getBool/getNumber/getString(key, default)`; scritte con
`OrgSettings.set(key, value)` → RPC `upsert_org_setting`. Cache: memoria → LS
`org_<id>_<key>` → default. `OrgSettings.load()`: autenticato = select `org_settings` per org;
anonimo = `get_public_org_settings(slug)`. `OrgSettings.reset()` al logout.

| Chiave | Tipo value | Note |
|---|---|---|
| `branding.studio_name` | string | seed = nome org |
| `branding.logo_url` | string (url) | |
| `branding.favicon_url` | string (url) | |
| `branding.primary_color` | string hex | seed '#8B5CF6'; deriva anche la variante dark (−10%) |
| `branding.pwa_name` | string | titolo app/PWA |
| `branding.home_duration` | string | es. "80 minuti" |
| `locale.timezone` | string IANA | default 'Europe/Rome' |
| `locale.currency` | string | default 'EUR' |
| `locale.language` | string | |
| `locale.date_format` | string | |
| `locale.first_day_of_week` | number | |
| `company.legal_name` / `company.vat_number` / `company.tax_code` / `company.pec` / `company.sdi_code` / `company.invoice_prefix` | string | PRIVATE (non nella whitelist anon) |
| `company.address` | object `{via, cap, citta, provincia, paese}` | pubblica |
| `company.maps_url` | string url (solo http/https!) | pubblica |
| `billing_client.prices` | object `{<slotTypeKey>: number}` | listino display cliente; pubblica |
| `booking.policy.free_cancel_hours` | number | seed 24 |
| `booking.policy.penalty_pct` | number | seed 50 |
| `booking.policy.max_advance_days` | number | |
| `booking.policy.requires_account` | bool | |
| `booking.policy.cancel_mode` | string | |
| `notif.booking_confirmation` / `notif.reminder_enabled` / `notif.admin_new_booking` | bool | |
| `notif.reminder_hours` | number | |
| `notif.channels` | object | |
| `gdpr.privacy_url` / `gdpr.terms_url` | string | |
| `gdpr.data_retention_days` | number | |
| `features.<flag>` | bool | feature flag per-org (UI) |
| `maintenance.mode` | bool | blocco manutenzione (letto anche da anon) |
| `maintenance.message` | string | |
| `data_cleared_at` | object `{ts: string ISO}` | marker clear cross-device |
| `cancellation_mode` | string ('penalty-50', …) | mirror legacy |
| `cert_scadenza_editable`, `cert_block_expired`, `cert_block_not_set`, `assic_block_expired`, `assic_block_not_set`, `show_cert_badge`, `show_assic_badge`, `show_doc_badge`, `show_anag_badge` | bool | mirror legacy |
| `week_templates` | array (JSON dei template legacy) | mirror legacy |
| `active_week_template` | string (id numerico) | mirror legacy |

**Whitelist pubblica (anon)**: `branding.%`, `locale.%`, `booking.policy.%`,
`billing_client.prices%`, `maintenance.%`, `company.maps_url`, `company.address`.

---

## 7. EDGE FUNCTIONS

Base URL: `https://rwaiekhllujximrqftmp.supabase.co/functions/v1/<name>`. Pattern comune:
CORS (`POST, OPTIONS`), validazione Bearer con `supabase.auth.getUser(token)` interna,
service-role per le query. `verify_jwt` da `config.toml`:

| Function | verify_jwt | Metodo | Request | Response | Auth |
|---|---|---|---|---|---|
| `custom-access-token-hook` | false | POST (da GoTrue) | `{user_id, claims}` | payload con `claims.app_metadata.org_id/org_role` | GoTrue hook |
| `billing-checkout` | true | POST | `{plan_code: 'starter'\|'pro'\|'business'}` | `{url}` (Stripe Checkout, mode=subscription, trial 30 gg) / `{error, code}` | Bearer owner/admin |
| `billing-portal` | true | POST | (nessun body) | `{url}` (Stripe Customer Portal) | Bearer owner/admin |
| `stripe-webhook` | false | POST | evento Stripe (firma `STRIPE_WEBHOOK_SECRET`) | 200 | firma Stripe; idempotenza via `subscription_events.stripe_event_id`; sincronizza `subscriptions` + `organizations.status`; registra pagamenti-cliente nel ledger `payments` |
| `stripe-connect` | false | POST `{action:'start'}` / GET `?action=callback&code&state` / POST `{action:'disconnect'}` | v. sx | `{url}` per start; redirect per callback | start/disconnect: Bearer (validato internamente); callback: state anti-CSRF (`stripe_oauth_states`) |
| `notify-admin-booking` | true | POST | `{name, date_display, time, date, slot_type, max_capacity, booking_id}` — org MAI dal body: risolta da bookings.org_id (booking_id) o dal caller | `{ok, sent, failed}` | Bearer (anche anon key: verify_jwt gateway) |
| `notify-admin-cancellation` | true | POST | come sopra (dati presentazione + booking_id) | `{ok, sent, failed}` | idem |
| `notify-admin-new-client` | true | POST | `{name}` (org derivata dal profilo del caller) | `{ok, sent, failed}` | Bearer OBBLIGATORIO |
| `notify-slot-available` | true | POST | `{date_display, date, time, exclude_user_id, spots_available, max_capacity}` | `{ok, …}` | Bearer obbligatorio; org dal caller |
| `send-admin-message` | true | POST | destinatari per giorno o giorno+ora + titolo/corpo | `{ok, …}` | Bearer owner/admin |
| `send-reminders` | true (cron) | POST | — (cron ogni 5 min) | — | service; promemoria 24h/1h prima, flag `reminder_24h_sent`/`reminder_1h_sent` |
| `generate-monthly-report` | true | POST | `{user_id, year_month, tone: 'serious'\|'motivational'\|'ironic', …}` | report AI (scrive `monthly_reports`) | Bearer admin; usa ANTHROPIC_API_KEY (Claude Haiku) |
| `image-proxy` | false | GET | `?url=` (SOLO `https://apilyfta.com/static/...`) | immagine con CORS | pubblica |

Push web: VAPID (`VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`), libreria `web-push`; endpoint morti
(410/404) vengono cancellati da `push_subscriptions`. Le notify-* registrano anche una riga in
`admin_messages`. **In Flutter**: `push_subscriptions` (endpoint/p256dh/auth) è Web-Push-specific
— per il mobile nativo servirà FCM/APNs (nuova colonna/tabella token o riuso di `endpoint` come
token FCM, decisione da prendere; le edge andrebbero estese).

Secrets edge (mai nel client): `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET`, `STRIPE_CONNECT_CLIENT_ID`, `SITE_URL`, `VAPID_*`, `ANTHROPIC_API_KEY`.

---

## 8. MAPPATURA FLUTTER CONSIGLIATA

### 8.1 Client e auth

- **Un solo client**: `Supabase.initialize(url: SUPABASE_URL, anonKey: SUPABASE_ANON_KEY)`;
  `supabase_flutter` usa **PKCE di default**, persiste la sessione (shared_preferences) e fa
  auto-refresh del token → **eliminare**: dual-client, lock custom, watchdog, cascade-reload,
  `_readAccessTokenDirect`, `_readSessionFromStorageDirect`, refresh proattivo manuale,
  `ensureValidSession` con polling (ridurlo a: `if (session scaduta) await
  auth.refreshSession()` con try/catch prima delle RPC non-idempotenti — book_slot,
  admin_pay_bookings).
- `onAuthStateChange` di supabase_flutter sostituisce INITIAL_SESSION/SIGNED_OUT-spurio: il
  problema "SIGNED_OUT spurio da lock PWA" non esiste in nativo; mantenere solo la distinzione
  logout volontario vs sessione persa (evento `signedOut` + redirect login).
- **Boot**: replicare l'ordine di `initAuth` con `Future.wait([loadProfile(), applyOrgContext()])`
  in parallelo; org context = `session.user.appMetadata['org_id'/'org_role']` con fallback query
  `org_members`. Dopo `create_organization`/`join_organization`: `auth.refreshSession()`.
- **Deep links** al posto dei redirect `login.html`: configurare
  `emailRedirectTo`/`redirectTo` con lo scheme dell'app per conferma email, recovery
  (`AuthChangeEvent.passwordRecovery`) e OAuth Google (`signInWithOAuth` nativo).
- `adminAuth` (sessionStorage) → provider/stato in memoria derivato dai claim.

### 8.2 Dual-layer cache

- **Sostituto di localStorage**: `shared_preferences` per chiavi piccole (org settings mirror,
  marker `dataLastCleared`, `_lastOrgId`, branding snapshot, dedup `new_client_notified`);
  **Hive/Isar/Drift** per gli snapshot grossi (bookings ≤8000 righe, profili, schede) — un
  box/tabella **per org** (`box('bookings_<orgId>')`) sostituisce il namespacing manuale
  `org_<id>_*`/`scheduleOverrides_<id>`; la patch `ls-namespace` NON serve.
- **Mantieni identiche** (sono la parte di valore): le strategie egress —
  fingerprint `"<count>|<maxUpdatedAt>"` + SKIP/DELTA (overlap 5 s) + reconcile 5 min per
  bookings e profili; finestra bookings 60/90 gg + debiti non pagati; TTL: avail-cache 60 s,
  snapshot bookings 15 min, workout LS 30 min + rete 5 min, profili 24 h; cutoff overrides
  (admin: 1 gen anno prec.; client: −30 gg); paginazione 1000 con tiebreaker `.order('id')`.
- I marker `dataLastCleared`/`data_cleared_at` (org_settings) vanno replicati per la
  propagazione cross-device del reset dati.
- I "booking sintetici" per anon/utente possono restare (o meglio: modellare la disponibilità
  come struttura dedicata `Availability{date,time,type,capacity,remaining}` invece di finti
  booking — il calendario Flutter può leggerla direttamente).

### 8.3 Lifecycle e realtime

- **Lock PWA / navigator.locks: N/A in nativo** — rimuovere tutto.
- **silent-refresh** → `AppLifecycleListener`/`WidgetsBindingObserver`: su `resumed` dopo ≥5 min
  di background: refresh sessione (lo fa già la lib), re-sync storages (throttle 60 s),
  **ri-sottoscrizione canali realtime morti** (questa serve anche in nativo: dopo sospensione i
  socket cadono — controllare `channel.state` o ricreare il canale `org_settings_<orgId>`).
  Evento `online` → `connectivity_plus`.
- Realtime: un solo canale `org_settings_<orgId>` con filtro `org_id=eq.<id>`; teardown al
  logout/cambio org.

### 8.4 Cosa NON portare in Flutter

- Service Worker / cache-busting / APP_SHELL / PWA install / sw-update.
- `_withFnWatchdog`, `_runSerialized`, stuck-lock detection, cascade reload.
- Fallback DEFAULT_WEEKLY_SCHEDULE / TIME_SLOTS / SLOT_PRICES hardcoded single-tenant (nel SaaS
  con org context la griglia senza config è VUOTA; usare solo i dati per-org dal DB).
- `initializeDemoData` (demo seeding client-side) e i booking `demo-*`.
- Auto-capitalizzazione write-back del nome in `_loadProfile` (farla solo in scrittura).
- La detection hash `type=signup` (implicit flow legacy) — con PKCE/deep link basta l'evento.
- Il retry "pending bookings" da localStorage può semplificarsi in una coda offline esplicita
  (ma SEMPRE via `book_slot`, mai insert diretto su `bookings`).

### 8.5 Invarianti NON negoziabili (identici al web)

1. Prenotazione SOLO via RPC `book_slot`; capienza/prezzo mai decisi dal client.
2. Ogni update admin di booking via `admin_update_booking` con `p_expected_updated_at`
   (gestire `stale_data` → re-sync) e passando TUTTI i parametri (v. caveat §4.3).
3. Fatturato = ledger `payments` (mai ricostruito dai booking).
4. Org risolta: autenticato → claim `org_id`; anonimo → slug → RPC pubbliche con `p_org_slug`.
5. Cache display-only, identity/org-scoped, svuotate al logout (teardown §2.8).
6. Timeout espliciti su ogni query/RPC (12–45 s) — anche in Dart (`.timeout()`).

---
*Generato il 2026-07-06 dall'analisi integrale del codice PalestrIA (branch saas-main).*
