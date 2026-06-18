# Da sistemare — Audit completo PalestrIA

> Generato il **2026-06-17** da una `/code-review` completa dell'intero codebase (~45.400 righe: SQL/RLS, Edge Functions, tutto `js/`, tutte le pagine HTML + Service Worker), eseguita con 10 agent specializzati per area + 1 agent dedicato alla caccia al codice morto.
>
> Legenda priorità: 🔴 **Critical** · 🟠 **High** · 🟡 **Medium** · ⚪ **Low**. Le voci con _(RLS)_ sono difesa-in-profondità: il server (RLS/RPC) resta l'autorità, ma il client/edge non dovrebbe fidarsi. Le voci con _(↔ todo.md)_ erano già accennate nell'audit precedente.

---

## ⚡ AZIONE IMMEDIATA — prima di tutto il resto

- [ ] **Verifica `open_access` in produzione**: esegui sul DB remoto `select open_access from platform_settings;`. Se è `true`, sei esposto a **C1** (breach cross-tenant totale): chiudilo subito (`select admin_platform_lock('email-owner-reale');` o `update platform_settings set open_access=false;`) e solo dopo procedi col resto.

---

## 🔴 CRITICAL

### C1 — Super-admin di piattaforma APERTO a chiunque per default
- **Dove**: [supabase/migrations/00000000000004_platform_admin.sql:38-53](supabase/migrations/00000000000004_platform_admin.sql#L38) — *(trovato da 3 agent indipendenti)*
- **Problema**: `platform_settings.open_access` è creato/seedato `TRUE`; `is_platform_admin()` fa `coalesce(open_access,false) OR exists(...)` → ritorna `true` per **qualunque utente autenticato**, anche un cliente finale. Nessuna migration/seed lo riporta a `false`.
- **Scenario**: un trainer o cliente chiama `supabaseClient.rpc('admin_platform_organizations')` → nome/email owner, conteggi, **fatturato e Stripe id di ogni studio**. Con `admin_platform_lock(...)` può estromettere il vero owner; con `admin_platform_set_org_status('suspended')` sospende i concorrenti.
- [ ] **Fix**: `open_access` default `false` + seed della riga `platform_admins` reale nel deploy; idealmente rimuovere lo short-circuit `open_access`. ([js/super-admin.js](js/super-admin.js) è già scritto correttamente — il buco è solo il default SQL.)

### C2 — `tablet.html` (kiosk) senza auth propria: legge/scrive i dati di chiunque
- **Dove**: [tablet.html:45](tablet.html#L45) (input manuale), [tablet.html:331-424](tablet.html#L331) (load), [js/supabase-client.js:172-200](js/supabase-client.js#L172)
- **Problema**: il kiosk non ha un proprio modello di auth e riusa il token `sb-*-auth-token` lasciato in localStorage dall'ultimo login (tipicamente l'admin). Accetta qualsiasi UUID da QR o dal campo manuale.
- **Scenario**: chiunque si avvicini al tablet incolla un UUID cliente → legge piano/nome/email/log di quel cliente e può modificarli/cancellarli con i privilegi dell'admin. (Gemello correttezza: senza sessione admin cachata il kiosk **non funziona affatto**, perché tutte le query come `anon` sono negate da RLS.)
- [ ] **Fix**: flusso dedicato a basso privilegio — RPC `security definer` che valida l'`uid` e ritorna solo il suo piano; `storageKey` isolato perché il kiosk non riusi mai una sessione admin.

---

## 🟠 HIGH

### H1 — Edge `notify-admin-*` spoofabili con la anon key pubblica  _(↔ todo.md)_
- **Dove**: [supabase/functions/notify-admin-new-client/index.ts](supabase/functions/notify-admin-new-client/index.ts), [notify-admin-booking/index.ts:33-39](supabase/functions/notify-admin-booking/index.ts#L33), [notify-admin-cancellation/index.ts:51](supabase/functions/notify-admin-cancellation/index.ts#L51), chiamata in [js/push.js:329](js/push.js#L329)
- **Problema**: `notify-admin-new-client` è invocata con `Bearer <ANON_KEY>` (JWT valido → gateway la accetta), non fa mai `getUser()` e si fida di `org_id` dal body. Le altre due risolvono `org_id` dal body senza validare il caller.
- **Scenario**: con la anon key (pubblica nel bundle) si fa loop di POST con l'`org_id` di una vittima → push spam a tutti i suoi admin + insert arbitrari in `admin_messages` di quel tenant.
- [ ] **Fix**: validare il Bearer con `getUser()` e derivare `org_id` dai `org_members`/`profiles` del caller (come fanno già correttamente `send-admin-message` e `notify-slot-available`).

### H2 — Bleed cross-tenant su device condiviso: il logout non smonta lo stato del tenant  _(↔ todo.md)_
- **Dove**: [js/auth.js:640-663](js/auth.js#L640) (`logoutUser`) + i moduli sotto
- **Problema**: `logoutUser()` pulisce solo `BookingStorage`/`UserStorage`. Restano non-namespaced e non ripuliti:
  - [ ] `workout_plans_cache_admin_v1` ([js/data.js](js/data.js), TTL 30 min) → piani+log dei clienti dell'org A mostrati all'admin dell'org B ([js/admin-schede.js:553](js/admin-schede.js#L553)).
  - [ ] `gym_stats` ([js/data.js:1517](js/data.js#L1517)) → fatturato/conteggi di A mostrati a B.
  - [ ] `_availabilityByKey` ([js/data.js:1270](js/data.js#L1270)) → capienze/posti residui stantii cross-org.
  - [ ] `push_subscription` ([js/push.js](js/push.js)) → endpoint push di A resta legato all'identità di A.
  - [ ] `OrgSettings._cache` + canale Realtime `org_settings_A` ([js/org-settings.js](js/org-settings.js)) → settings di A in memoria per B.
  - [ ] `_brandingSnapshot` ([js/branding-boot.js:13](js/branding-boot.js#L13), chiave unica) → B vede brand/logo/titolo di A prima del paint.
  - [ ] visitatori anonimi: [js/org-settings.js:44](js/org-settings.js#L44) usa la chiave letterale `'anon'` → due studi pubblici sullo stesso browser condividono `org_anon_*`.
- [ ] **Fix**: teardown completo in `logoutUser()` (azzerare `WorkoutPlanStorage`/`WorkoutLogStorage`/`_availabilityByKey`, rimuovere `gym_stats`/`push_subscription`/`_brandingSnapshot`, aggiungere `OrgSettings.reset()` con `removeChannel`); namespare per-org (o per-slug per gli anonimi) tutte queste chiavi.

### H3 — Import backup: injection/overwrite cross-tenant + delete distruttivo, dietro password finta
- **Dove**: [js/admin-backup.js:243-247](js/admin-backup.js#L243) (password), [js/admin-backup.js:336-475](js/admin-backup.js#L336) (import)
- **Problema**: unico gate = password hardcoded `'Palestra123'` (nel bundle pubblico). L'import fa `upsert` di righe grezze (`payments`, `profiles`, `client_packages`, `org_settings`…) con `org_id`/`id` presi dal file, e su `admin_audit_log`/`admin_messages`/`client_notifications` fa `.delete().neq('id',0)` prima di reinserire.
- **Scenario**: un file (anche di un altro tenant) inietta/sovrascrive `payments` con `org_id` arbitrario → fatturato falsificato; il blanket-delete cancella audit log/messaggi dell'org corrente.
- [ ] **Fix**: forzare `org_id = window._orgId` su ogni riga (scartare l'`org_id` in arrivo), niente `id` client per i ledger, mai `delete()` in blocco; passare per RPC server che valida l'ownership. Rimuovere la password finta.

### H4 — Stored XSS nella sessione admin (3 sink distinti)
- [ ] [js/admin-schede.js:1107](js/admin-schede.js#L1107) e [:1207](js/admin-schede.js#L1207) — nome cliente (anche da prenotazione pubblica anonima) in `onclick="...('${_escJs(name)}')"`: `_escJs` non basta in contesto attributo HTML → breakout `"><img onerror=...>`. **Fix**: usare `_escAttr()`.
- [ ] [js/admin-messaggi.js:23](js/admin-messaggi.js#L23) e [:32](js/admin-messaggi.js#L32) — nomi destinatari in `innerHTML` senza escape. **Fix**: `_escHtml(name)` + guardia su `getInitials` per non-stringhe.
- [ ] [tablet.html:565+](tablet.html#L565) e [allenamento.html:2486+](allenamento.html#L2486) — URL immagine/video da `imported_exercises` in `src="${...}"` senza escape; una riga del catalogo globale (`org_id is null`) avvelena ogni org. **Fix**: `_escHtml()` o assegnazione DOM `img.src=`.

### H5 — Fatturato sottostimato (due bug indipendenti)
- [ ] [js/admin-payments.js:158](js/admin-payments.js#L158) e [:167](js/admin-payments.js#L167) — "Incasso del mese" e conteggio calcolati su lista cappata a `.limit(50)` ([:138](js/admin-payments.js#L138)). **Fix**: KPI con filtro server `gte('created_at', inizioMese)`.
- [ ] [js/admin-analytics.js:990-993](js/admin-analytics.js#L990) — KPI "Fatturato reale" somma solo un sottoinsieme di label, **esclude i contanti** e il bucket "Altro" → due "fatturato reale" contraddittori. **Fix**: sommare tutti i pagamenti non-`gratuito` del periodo.

### H6 — Ruolo `staff`: modello di fiducia incoerente
- **Dove**: [js/admin.js:110](js/admin.js#L110) + [js/admin-calendar.js:340](js/admin-calendar.js#L340)
- **Problema**: il gate dà `adminAuth` solo a owner/admin → lo `staff` (ruolo valido) è escluso da tutta la UI admin; viceversa `sessionStorage.adminAuth='true'` da console fa renderizzare la dashboard. Scritture protette da RLS/RPC (no breach dati), ma design rotto.
- [ ] **Fix**: decidere l'accesso `staff` e gateare in modo coerente dal ruolo verificato server-side, non da un flag `sessionStorage`.

---

## 🟡 MEDIUM (correttezza)

- [ ] **M1** _(RLS)_ — [supabase/functions/stripe-webhook/index.ts:106-160](supabase/functions/stripe-webhook/index.ts#L106): org risolta da `metadata.org_id` influenzabile + idempotenza solo su `event.id` esatto → un evento mal-attribuito riscrive `subscriptions`/`organizations.status` di un'altra org. **Fix**: risolvere org da `stripe_customer_id` lato server e verificare il match.
- [ ] **M2** — [supabase/functions/generate-monthly-report/index.ts:680-712](supabase/functions/generate-monthly-report/index.ts#L680): gli INSERT in `monthly_reports` **omettono `org_id` (NOT NULL)** e `month` → ogni salvataggio fallisce, feature mai persistita, costo Anthropic pagato ad ogni chiamata. **Fix**: aggiungere `org_id`/`month`, riconciliare schema↔codice.
- [ ] **M3** _(RLS)_ — [generate-monthly-report/index.ts:603-638](supabase/functions/generate-monthly-report/index.ts#L603): lookup idempotenza/limite per `(user_id, year_month)` **senza `org_id`** → può leggere report di un'altra org. **Fix**: `.eq('org_id', …)`.
- [ ] **M4** — vedi **DC2** (dead code): [supabase/functions/create-checkout/index.ts:91](supabase/functions/create-checkout/index.ts#L91) top-up senza `org_id` → webhook lo scarta = pagamento incassato senza registrazione. La function è comunque orfana (sistema crediti rimosso): **dismettere**.
- [ ] **M5** — [js/calendar.js:109](js/calendar.js#L109), [js/booking.js:109+](js/booking.js#L109): uso della mappa legacy hardcoded `SLOT_NAMES[...]` invece di `getSlotName()` org-aware → slot type custom rendono `undefined` (badge, ICS, conferma). **Fix**: sostituire con `getSlotName()`.
- [ ] **M6** — [js/calendar.js:274](js/calendar.js#L274), [:558](js/calendar.js#L558) + [js/booking.js:107](js/booking.js#L107): bookability/capienze legacy hardcoded, ignorano `bookable`/`defaultCapacity` per-org di `_ORG_SLOT_TYPES`. **Fix**: derivare da `_ORG_SLOT_TYPES`.
- [ ] **M7** — [js/admin-schedule.js:560-567](js/admin-schedule.js#L560): cambio *tipo* di una cella template manda sempre `capacity=null`; il branch update applica capienza solo se `!==null` → capienza vecchia resta sul tipo nuovo. **Fix**: reset capienza a null al cambio tipo.
- [ ] **M8** — [js/admin-schedule.js:740-757](js/admin-schedule.js#L740): override indicizzati per etichetta `"HH:MM - HH:MM"`; modifica fascia → override fantasma invisibile ma ancora applicato da `resolve_slot_config`. **Fix**: indicizzare per `time_slot_id`.
- [ ] **M9** — [js/admin-calendar.js:428](js/admin-calendar.js#L428): `bookForClient` chiama `addExtraSpot` (incrementa capienza assoluta +1) all'overflow → il client gonfia permanentemente la capienza override (anti-pattern §12). **Fix**: lasciar fallire `book_slot` (`slot_full`); bump come azione esplicita.
- [ ] **M10** — [js/booking.js:299-310](js/booking.js#L299): re-check capienza pre-submit blocca su valore di cache (falso negativo): cache stantia "pieno" → utente negato per uno slot che il server concederebbe. **Fix**: togliere il blocco client, autorità a `book_slot`.
- [ ] **M11** — [js/booking.js:261-265](js/booking.js#L261): `new Date("YYYY-MM-DD")` = mezzanotte UTC + `setHours` locale → skew 1-2h sul cutoff "30 min dopo l'inizio", rotto vicino a mezzanotte/DST. **Fix**: costruire la data localmente (`new Date(y,mo-1,dy,h,m)`) come negli altri siti.
- [ ] **M12** — [js/admin-analytics.js:290-324](js/admin-analytics.js#L290): su errore/timeout del fetch payments, `_statsPayments` stantio servito come fresco contro il nuovo range. **Fix**: tracciare copertura range payments separata, blank su errore.
- [ ] **M13** _(RLS)_ — [js/entitlements.js:55-59](js/entitlements.js#L55): `has()` default **true** se gli entitlement non caricano → blip RPC sblocca feature client-side. **Fix**: mantenere fail-open solo se il server enforce-a ogni `data-feature`.
- [ ] **M14** — [js/allenamento-report.js:172](js/allenamento-report.js#L172): gate legge `app_metadata.role` (mai valorizzato) invece di `org_role` → tab Report irraggiungibile per gli admin reali. **Fix**: usare `org_role`.
- [ ] **M15** — vedi **TD1**: [js/allenamento-report.js:48](js/allenamento-report.js#L48) logica mese hard-wired al mese corrente "per test". **Fix**: ripristinare "mese precedente" prima del rilascio.
- [ ] **M16** — [js/chart-mini.js:27](js/chart-mini.js#L27): `drawLineChart` con range di un solo giorno → `stepX = width/0 = Infinity`, grafico vuoto senza messaggio. **Fix**: `denom = max(1, len-1)` + guard dati vuoti.
- [ ] **M17** — [js/admin-schedule.js:311](js/admin-schedule.js#L311),[:705](js/admin-schedule.js#L705) + [js/admin-schede.js:2433](js/admin-schede.js#L2433): `parseInt(...)||0` su capienza/serie: `0` valido e testo invalido collassano; clear del campo Serie salva `sets=0`. **Fix**: parse con `Number.isNaN` esplicito.
- [ ] **M18** — [js/auth.js:16-24](js/auth.js#L16): `normalizePhone` — mobile IT che inizia per `39` o numeri esteri forzati a `+39` → E.164 errato, collisioni `is_whatsapp_taken`. **Fix**: validare lunghezza nazionale prima del prefisso.
- [ ] **M19** (perf) — [js/admin-calendar.js:107](js/admin-calendar.js#L107): `getAllBookings()` dentro il loop giorni (21 parse per render) + ricalcolo capienza → jank navigazione settimana. **Fix**: hoistare fuori dal loop, memoizzare.

---

## ⚪ LOW (sicurezza minore · qualità · convenzioni)

- [ ] **L1** (borderline Medium) — [js/org-settings.js:197](js/org-settings.js#L197) + [js/branding-boot.js:79](js/branding-boot.js#L79): `company.maps_url` (impostabile dal trainer, esposto a `anon`) scritto in `<a href>` senza validare lo schema → `javascript:` URL = XSS sui visitatori del tenant. **Fix**: validare `http(s):` con `new URL()`.
- [ ] **L2** _(RLS)_ — [supabase/migrations/00000000000002_post_deploy_fixes.sql:21](supabase/migrations/00000000000002_post_deploy_fixes.sql#L21) (`login_events_insert`): `WITH CHECK` valida solo `user_id`, non `org_id` → insert forgiati in `login_events` di un'altra org. **Fix**: `and org_id = current_org_id()`.
- [ ] **L3** — [supabase/migrations/00000000000001_operational_rpcs.sql:96-109](supabase/migrations/00000000000001_operational_rpcs.sql#L96) (`get_slot_attendees`): RPC `anon` che enumera i nomi degli iscritti per slot via slug, senza rate-limit. **Fix**: confermare se è voluto pubblico.
- [ ] **L4** (dev) — [js/supabase-client.js:172](js/supabase-client.js#L172) + [js/auth.js:143](js/auth.js#L143): primo `sb-*-auth-token` vince (regex wildcard) → su origin condivisa può prendere il token del progetto sbagliato. **Fix**: pinnare il `ref` da `SUPABASE_URL`.
- [ ] **L5** — [js/maintenance.js:54](js/maintenance.js#L54): bypass manutenzione da `sessionStorage.adminAuth` (settabile a mano). **Fix**: derivare da `window._orgRole`.
- [ ] **L6** — [js/admin-clients.js:1052](js/admin-clients.js#L1052): `deleteClientData` dietro password hardcoded `'Palestra123'` (come H3; la cancellazione vera è server-side, ma `replaceAllBookings` locale parte comunque). **Fix**: rimuovere la password, usare conferma digitata.
- [ ] **L7** — [supabase/functions/image-proxy/index.ts:20](supabase/functions/image-proxy/index.ts#L20): allowlist `startsWith` bypassabile + segue redirect → relay/SSRF limitato su `apilyfta.com`. **Fix**: validare `hostname` esatto + `redirect:'manual'`.
- [ ] **L8** — [js/supabase-client.js:203](js/supabase-client.js#L203) / [prenotazioni.html:429](prenotazioni.html#L429): `logCreditClick` scrive in tabella telemetria da anon senza `org_id`; + **UUID utente hardcoded** (`b6461979-…`) leftover single-tenant. **Fix**: rimuovere o gateare.
- [ ] **L9** — convenzione cache-busting §6: [js/sw-update.js](js/sw-update.js)/[js/pwa-install.js](js/pwa-install.js) senza `?v=` ([admin.html:1167](admin.html#L1167), [allenamento.html:5201](allenamento.html#L5201)); `style.css?v=8` vs `?v=9` tra pagine; **`signup-trainer.html` assente da `APP_SHELL`** in [sw.js](sw.js). **Fix**: allineare `?v=` e sincronizzare `APP_SHELL`.
- [ ] **L10** (qualità) — [js/admin-calendar.js:18](js/admin-calendar.js#L18): `resize` listener aggiunto senza `removeEventListener` → leak su re-render dashboard (admin.js:67-69 lo fa correttamente). **Fix**: salvare il riferimento e rimuovere prima di ri-aggiungere.
- [ ] **L11** (qualità) — incassato divergente: [js/admin-registro.js:217](js/admin-registro.js#L217) somma `getBookingPrice` (prezzi correnti, da `bookings`) mentre [js/admin-analytics.js](js/admin-analytics.js) usa il ledger `payments` → totali non riconciliabili. **Fix**: guidare il registro dal ledger o rietichettare.
- [ ] **L12** (qualità) — [js/admin-schede.js](js/admin-schede.js): renderer desktop (`_renderExercisesForDay`) e mobile (`_renderMobileCardsForDay`) ~duplicati e già divergenti → fix da applicare in due punti. **Fix**: estrarre helper condiviso `_buildExerciseSpec`.

---

## 🧹 Codice morto (poco/moderato, ben circoscritto — ~900-1000 righe, dominato da 2 artefatti)

- [ ] **DC1** — [viewer.html](viewer.html) (~700 righe): tool "Backup Viewer" **orfano** (non linkato da nessuna pagina, solo in `sw.js` APP_SHELL). Opera su chiavi/colonne rimosse (`gym_credits`/`gym_bonus`/`gym_manual_debts`, `creditApplied`/`cancelledWithBonus`/`cancelledWithPenalty`) e tenta sync su `credit_history` inesistente. Già marcato "codice morto" in `todo.md:123`. **Azione**: rimuovere o archiviare in `_legacy/`.
- [ ] **DC2** — [supabase/functions/create-checkout/index.ts](supabase/functions/create-checkout/index.ts) (~110 righe): edge "Ricarica credito" (sistema crediti rimosso), registrata in `config.toml` ma **0 fetch dal client**. Sostituita da `billing-checkout`. **Azione**: dismettere (anche per M4 — incassa senza ledger).
- [ ] **DC3** — 7 funzioni definite e mai chiamate (verificate 0 call-site): [js/data.js:421](js/data.js#L421) `getSlotTypes()`, [js/data.js:2393](js/data.js#L2393) `hasPushEnabled()`, [js/admin-analytics.js:418](js/admin-analytics.js#L418) `calculateTotalWeeklySlots()`, [js/admin-schede.js:141](js/admin-schede.js#L141) `_buildExercisePicker()`, [js/admin-calendar.js:624](js/admin-calendar.js#L624) `_adminScrollIfFirstOpen()`, [js/admin-payments.js:432](js/admin-payments.js#L432) `onAmountInput()`, [js/push.js:182](js/push.js#L182) `_disabledSlotAvailableBroadcast()`. **Azione**: rimuovere.
- [ ] **DC4** — [js/data.js:639](js/data.js#L639): `static BOOKINGS_KEY = 'gym_bookings'` dichiarata e mai letta/scritta. **Azione**: rimuovere.
- [ ] **DC5** — codice irraggiungibile in [js/push.js:46](js/push.js#L46) (`return null` come prima istruzione → righe 48-100 morte) e [js/push.js:183](js/push.js#L183) (`return` → 184-228 morte). **Intenzionale** (push in "Demo"), ma nasconde la cleanup VAPID on-logout (vedi H2). **Azione**: gateare dietro un flag `PUSH_ENABLED` invece dell'early-return.
- [ ] **DC6** — ramo morto: i flag `with_bonus`/`with_mora` in [supabase/functions/notify-admin-cancellation/index.ts:104-105](supabase/functions/notify-admin-cancellation/index.ts#L104) non sono mai passati dal chiamante ([prenotazioni.html:615](prenotazioni.html#L615)) → rami sempre `false`. **Azione**: rimuovere i rami (residuo sistema crediti).
- [ ] **DC7** — 2 blocchi di codice commentato (vecchia autorizzazione self-service disabilitata) in [supabase/functions/generate-monthly-report/index.ts:540-553](supabase/functions/generate-monthly-report/index.ts#L540) e [:558-569](supabase/functions/generate-monthly-report/index.ts#L558). **Azione**: ripristinare o rimuovere (vedi TD2).

> Nota: i riferimenti a "credito/bonus/debito" in `org-settings.js` e nelle migration `0000…01` sono **solo commenti** che documentano la rimozione (verificato: zero codice vivo). Le occorrenze di "creditori"/"ricariche" nei pannelli admin sono terminologia **corrente** (clienti con pagamenti in sospeso), non codice morto.

---

## ⏳ Debito tecnico provvisorio spedito ("TEMPORANEO/TODO" in produzione)

Non è codice morto, ma codice provvisorio che va chiuso prima del rilascio:

- [ ] **TD1** — [js/allenamento-report.js:46-48](js/allenamento-report.js#L46) (mese corrente "per test") e [:169-171](js/allenamento-report.js#L169) (feature Report gated agli admin "in fase di test"). Ripristinare comportamento "mese precedente" + self-service.
- [ ] **TD2** — [supabase/functions/generate-monthly-report/index.ts:529-538](supabase/functions/generate-monthly-report/index.ts#L529) (solo admin "WIP") e [:556-569](supabase/functions/generate-monthly-report/index.ts#L556) (validazione mese disabilitata per test). Riallineare con TD1.
- [ ] **TD3** — [supabase/migrations/00000000000015_monthly_reports_schema.sql:15-19](supabase/migrations/00000000000015_monthly_reports_schema.sql#L15): nota che la generazione report **non è ancora org-scoped** → rischio data-leak cross-tenant segnalato. Da chiudere insieme a M2/M3.
- [ ] **TD4** — [js/admin-calendar.js:408](js/admin-calendar.js#L408),[:704](js/admin-calendar.js#L704),[:810](js/admin-calendar.js#L810): prezzo "slot condiviso" (15€) non più applicato, in attesa di supporto server-side in `book_slot` → due booking condivisi fatturati al prezzo default. Implementare il prezzo condiviso server-side.

---

## ✅ Aree verificate PULITE (per riferimento)

- Helper RLS `current_org_id()`/`is_org_admin()`: fail-closed corretto su `org_id` NULL; nessun `USING(true)` (eccetto `plans_read` pubblico intenzionale); tutte le `SECURITY DEFINER` con `search_path` fisso.
- Stripe webhook: firma verificata sul raw body, idempotenza via UNIQUE su `stripe_event_id` (residuo solo in M1).
- `billing-checkout`/`billing-portal`/`stripe-connect`: auth + org-scoping corretti, redirect da `SITE_URL`, OAuth `state` CSRF-safe.
- `custom-access-token-hook`: corretto, non si fida di input attaccante.
- Gate `admin.html` (commit recente): `_adminAccessGate` atteso da entrambi i boot path, redirect prima di sync/render, overlay anti-flash — solido.
- Prenotazione pubblica (`booking.js`/`calendar.js`): input anonimi via `_escHtml`, capienza/org risolti server-side da slug — il client non detta mai capienza/org.
- Org-scoping scritture admin (slot_types, settings, schedule): `.eq('org_id', …)` + guard consistenti; settings per-chiave (no clobbering jsonb).
- Nessun secret hardcoded (service-role/Stripe/VAPID) in HTML/JS; la anon key è pubblica per design.
- Modello AI in `generate-monthly-report`: `claude-haiku-4-5-20251001` corretto e attuale.
- 0 file JS morti su 35; nessun import rotto.
