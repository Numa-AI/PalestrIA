# Aggiornamento

Changelog delle modifiche **nate in PalestrIA** (non portate dal gemello Thomas), da
**duplicare su un altro progetto simile**. Voci nuove in cima. Ogni voce ha descrizione +
una *Parte tecnica* autosufficiente (file, identificatori, prima/dopo, deploy).

> Vedi `CLAUDE.md` §0.2 per la regola. Per le modifiche **portate da** Thomas vedi invece il
> suo `Aggiornamenti.md` (collegato da `Aggiornamenti Thomas.md.lnk`).

---

<!-- Le prossime voci vanno qui, in cima. -->
## 2026-07-10 - Modello di pagamento predefinito separato e cambio sicuro

**Problema/feature.** La configurazione mostrava sempre insieme modello, blocchi e listino slot, anche quando non erano pertinenti. Mancavano i pacchetti abbonamento da 1/3/12 mesi, un listino dedicato, il credito derivato delle lezioni a entrata e una transizione sicura tra modelli. Un cambio diretto poteva inoltre lasciare attivi pacchetti, membership e override incompatibili. Il modello è unico (**Abbonamento**): mensile/trimestrale/annuale sono soltanto durate commerciali, non tipi di pagamento distinti.

### Parte tecnica

- Migration `00000000000039_default_billing_models.sql` (schema finale riportato anche nella baseline):
  - `billing_settings`: unico `default_model='monthly'` per Abbonamento; `default_membership_period` resta metadata compatibile per la durata, mentre i prezzi `membership_monthly_price/membership_quarterly_price/membership_annual_price` rappresentano i pacchetti da 1/3/12 mesi; listino carnet `package_label/package_sessions/package_price`, `model_changed_at`;
  - `client_billing_profiles.membership_period_override`, `client_memberships.billing_period`;
  - `bookings.billing_voided_at/billing_void_reason`: annullano una posizione economica operativa senza eliminare la prenotazione o alterare il ledger storico;
  - `apply_client_booking_price()` ora fotografa sempre `custom_price` per il modello a entrata usando prima l'override cliente e poi `get_org_price(org_id, slot_type)`. Il cambio successivo del listino non riscrive lezioni già prenotate;
  - `get_billing_model_change_impact(model)` restituisce i conteggi mostrati prima della conferma;
  - `admin_save_default_billing_model(...)` è la sola transizione autorizzata: lock della riga per-org, confronto col modello atteso, obbligo dei tre flag di conferma, annullamento atomico di saldi aperti/pacchetti/membership/override, salvataggio dei listini slot e audit `default_billing_model_changed`. Le durate 1/3/12 mesi vengono normalizzate nello stesso modello e il loro cambio non attiva annullamenti globali. `payments` non viene modificata;
  - trigger `guard_default_billing_model_transition` blocca i vecchi frontend che provano un `UPDATE` diretto; `guard_voided_booking_payment` impedisce di incassare una posizione annullata;
  - `get_client_financial_summary()` espone per l'entrata `unpaid` (maturato), `scheduled` (futuro) e `credit` (totale); per pacchetto/gratuito/abbonamenti i valori credito sono zero;
  - `admin_record_membership_payment(..., p_billing_period)` registra mensile, trimestrale o annuale e mantiene la periodicità nell'override cliente.
- PWA: `js/admin-settings.js` separa quattro scelte (**A entrata / Pacchetto / Abbonamento / Gratuito**) e mostra solo la card pertinente; Abbonamento contiene i tre pacchetti 1/3/12 mesi. Il cambio di tipo esegue tre `showConfirm`; `js/admin-payments.js` calcola automaticamente le tre durate. `prenotazioni.html` e `js/admin-clients.js` mostrano il credito a entrata come maturato + futuro.
- Flutter: nuovo contratto puro `client_billing_models.dart` con quattro tipi; `settings_payments.dart` replica sezioni e tre `AlertDialog`; `client_sale_sheet.dart` gestisce pacchetti abbonamento da 1/3/12 mesi; profilo cliente e pannello trainer distinguono credito a entrata da copertura abbonamento.
- Test: `flutter analyze lib test` pulito; `flutter test --no-pub` 9/9; nuovo `client_billing_models_test.dart`; `node --check` sui quattro asset JS e compilazione dei tre script inline di `prenotazioni.html`; `git diff --check` pulito. QA visiva locale admin non eseguita perché la sessione browser localhost non era autenticata.
- Cache busting PWA finale: `sw.js` `palestria-v591` → `palestria-v593`; `data.js?v=102`, `admin-settings.js?v=12`, `admin-payments.js?v=24`, `admin-clients.js?v=21`.

### Deploy

1. Eseguire `supabase db push` per applicare la migration 39 prima di pubblicare il frontend.
2. Pubblicare gli asset PWA e verificare l'attivazione di `palestria-v592`.
3. Ricostruire AAB/APK Flutter.
4. QA autenticata: provare tutti i sei modelli, i tre alert, il mantenimento del ledger storico, la vendita da listino e due organizzazioni per escludere effetti cross-tenant.

## 2026-07-10 - Modulo operativo SaaS per clienti, pacchetti, mensili e override capienza

**Problema/feature.** Il trainer non poteva vendere entitlement dall'app Flutter, modificare il modello economico di un cliente o aumentare in sicurezza la capienza di una singola data. La PWA esponeva parti del flusso, ma senza una transazione unica e senza una vista salute coerente. I retry potevano inoltre duplicare vendite o consumi.

### Parte tecnica

- Migration 00000000000031_client_operations_hardening.sql: payments.idempotency_key e indice univoco parziale per organizzazione.
- Migration 00000000000032_trainer_billing_operations.sql: ledger auditabile (admin_audit_log), vincoli su sessioni/prezzi/periodi e RPC idempotenti admin_sell_package / admin_record_membership_payment.
- Migration 00000000000033_client_financial_health.sql: RPC per modello cliente, rettifiche, cancellazione entitlement, modifica/archiviazione/reset cliente e riepilogo economico. I clienti archiviati non consumano il limite del piano.
- Migration 00000000000034_schedule_override_and_booking_guards.sql: upsert/delete sicuri degli override; book_slot blocca overbooking, identita errata, archiviati, debiti e copertura assente. Usa la data della lezione, consuma pacchetto/quota sotto lock e deduplica tramite local_id.
- Migration 00000000000035_atomic_stripe_client_payment.sql: record_stripe_client_payment riservata a service_role; entitlement e ledger sono atomici e deduplicati per PaymentIntent. stripe-webhook usa questa RPC.
- Migration 00000000000036_profiles_archived_state.sql: roster admin con archived_at.
- Migration 00000000000037_pay_per_session_custom_price.sql: trigger BEFORE INSERT che fotografa su booking il prezzo concordato per-cliente.
- Migration 00000000000038_billing_coverage_health.sql: health economica coerente con modello, quota mensile e grace period.
- Edge admin-manage-client: valida Bearer e membership owner/admin, aggiorna i dati via RPC tenant-scoped e sincronizza il cambio email con Supabase Auth.
- Flutter: client_operations.dart, client_sale_sheet.dart, client_financial_panel.dart, client_manage_sheet.dart, override_editor.dart; integrazione nei tab Clienti, Pagamenti e Orari. UI con banner salute, KPI, progressi entitlement, azioni guidate e layout responsive.
- PWA: admin-clients.js, admin-payments.js, admin-schedule.js, booking.js, data.js e admin-saas-ops.css; stessa copertura funzionale, messaggi errore azionabili e controlli accessibili.
- Test: client_operations_test.dart; dart analyze lib test pulito, 7 test Flutter passati, node --check pulito. Cache bust finale: admin-clients.js?v=20, admin-payments.js?v=22, booking.js?v=26, CSS v=2, service worker palestria-v591.

### Deploy

1. Eseguire supabase db push per le migration 31-38 (insieme alle precedenti non ancora remote).
2. Eseguire supabase functions deploy admin-manage-client stripe-webhook.
3. Pubblicare gli asset statici PWA e forzare l'aggiornamento del service worker.
4. Eseguire QA con due organizzazioni, concorrenza su ultimo posto, retry delle vendite, consumo/refund entitlement, grace period, cambio email e webhook Stripe reale.

## 2026-07-10 — Chiusura bug funzionali Flutter: auth, staff, feature SaaS, notifiche e dati profilo

**Problema/feature.** La seconda review ha individuato flussi apparentemente disponibili ma non completi: cambio email non sincronizzato, inviti staff fittizi, ruolo staff senza destinazione, feature SaaS non enforceate, notifiche mancanti nell'app, recovery password incompleta, membership e grafici con selezione dati errata.

### Parte tecnica

- Migration `00000000000030_auth_email_and_invite_hardening.sql`: trigger `on_auth_user_email_changed` su `auth.users` → `sync_confirmed_auth_email()` aggiorna `profiles.email` e `bookings.email` soltanto dopo il cambio confermato; RPC legacy `invite_org_member` ora fallisce su utente inesistente; helper `is_org_staff()` e policy read-only per profili/prenotazioni staff.
- Edge `invite-org-member`: autentica owner/admin, deriva `org_id` dalla membership, trova o invita davvero l'utente con Admin Auth, impedisce membership/profilo in altra org e upserta `org_members`. `config.toml`: `verify_jwt=true`.
- `billing_saas.dart`: `Entitlements.features`, `featureEnabledProvider` e `FeatureGate`. Gate UI su schede, messaggi, report AI e Connect; toggle disabilitati se non inclusi nel piano. Le Edge `send-admin-message`, `generate-monthly-report` e `stripe-connect` ripetono il controllo server-side su subscription + org setting.
- Recovery: `resetPasswordForEmail(... redirectTo: 'palestria://app/recovery')`, nuova route/schermata `recovery_screen.dart`, intent Android `/recovery`. Configurare lo stesso URL nella allowlist Auth remota.
- Prenotazioni Flutter: dopo successo invoca `notify-admin-booking`; dopo annullo invoca `notify-admin-cancellation` e `notify-slot-available`, sempre best-effort.
- Staff: nuova `/staff` protetta e `StaffScreen`, agenda odierna read-only; nessuna promozione implicita ad admin.
- Dati: membership filtrata `status=active` e `period_end>=oggi`; finestra storico prenotazioni 60→190 giorni; entitlements invalidati su resume dopo Stripe.
- Test: aggiunto `billing_saas_test.dart`; analyze pulito e 4 test passati. Build AAB da rifare fuori dal path Nextcloud virtualizzato.

### Deploy

1. `supabase db push`.
2. `supabase functions deploy invite-org-member send-admin-message generate-monthly-report stripe-connect` (oppure un deploy per funzione).
3. Supabase Auth → Redirect URLs: aggiungere `palestria://app/recovery`.
4. Ricostruire AAB e fare QA su dispositivo.
## 2026-07-10 — Hardening sicurezza app Flutter/Android

**Problema/feature.** Una code review pre-pubblicazione ha rilevato: fallback della build release alla firma debug, route admin montabile da qualsiasi sessione, registrazione trainer differita non legata all'account, URL Stripe aperti senza validazione, intent custom troppo ampio e test Flutter rimasto al template Counter.

### Parte tecnica

- `android/app/build.gradle.kts`: rilevare i task il cui nome contiene `release` e lanciare `GradleException` se manca `key.properties`; il fallback debug resta raggiungibile solo durante la configurazione di task non-release.
- `lib/core/router.dart`: sostituire il builder diretto di `/admin` con `_AdminGate`, che mostra `AdminShell` solo per `OrgContext.isOrgAdmin`; gli altri utenti vengono rinviati a `/client/prenotazioni`. RLS e RPC restano i controlli autoritativi.
- `lib/core/auth/auth_repository.dart`: salvare in `pending_studio` anche email normalizzata e `created_at`; completare lo studio solo per la stessa email ed entro 48 ore; eliminare la chiave al logout.
- Nuovo `lib/core/security/external_url.dart`: `trustedExternalUri()` accetta solo HTTPS senza user-info e host applicativi o `stripe.com`/sottodomini. Usarlo in `billing_saas.dart` e `settings_payments.dart` prima di `launchUrl`.
- `AndroidManifest.xml`: limitare lo schema custom a host `app` e path `/join`; per QR/inviti preferire sempre l'App Link HTTPS verificato.
- Eliminare `test/widget_test.dart` del template e aggiungere `test/external_url_test.dart` con casi positivi e tentativi di bypass della allowlist.

Non sono richiesti migration DB, deploy edge o cache-bust PWA. Dopo il port eseguire `dart format`, `flutter analyze` e `flutter test`.

## 2026-07-08 — Profilo cliente: sezioni Prossime/Passate/Transazioni + tab Prenotazioni ridotto al solo calendario

**Problema/feature.** Nell'area cliente il tab "Prenotazioni" conteneva due sotto-viste (pill-bar *Calendario* + *Le mie*). Richiesta: (1) togliere la pill-bar → il tab Prenotazioni mostra **solo il calendario**; (2) spostare l'elenco "Le mie" **dentro il Profilo**; (3) nel Profilo tre sezioni **Prossime / Passate / Transazioni** (queste ultime = storico pagamenti del cliente); (4) rimuovere dal Profilo il "recap dati" personali; (5) mostrare **Nome e Cognome** (non solo il nome) nel Profilo.

La sezione **Transazioni** è la novità portabile: legge il **ledger unico `payments`** filtrando le sole righe del cliente. La RLS di `payments` deve consentire la lettura al cliente delle proprie righe:
```sql
-- policy attesa su payments (baseline PalestrIA):
create policy payments_select on payments for select to authenticated
  using (org_id = current_org_id() and (client_user_id = auth.uid() or is_org_admin(org_id)));
```
Colonne usate: `id, amount, currency, method, kind, created_at, note, period_start, period_end`.
- `kind` ∈ `session|membership|package_purchase|penalty_mora|adjustment` → etichette *Lezione/Abbonamento/Pacchetto/Mora/Rettifica*.
- `method` ∈ `contanti|contanti-report|carta|iban|stripe|gratuito` → etichette con emoji (💵/🧾/💳/🏦/💳/🎁).

### Parte tecnica

**Web/PWA (fonte storica).**
1. In `prenotazioni.html` (pagina profilo cliente) aggiungere la terza tab accanto a Prossime/Passate:
   ```html
   <button class="preno-tab" id="tabTransazioni" onclick="switchPrenoTab('transactions')">Transazioni</button>
   ```
2. `switchPrenoTab(tab)`: aggiungere il toggle `active` su `#tabTransazioni` e il branch `if (tab==='transactions') renderTransactions(); else renderPrenoList();`. Idem in `showMore()` (branch su `_currentTab`).
3. Nuove funzioni JS (client-side, la RLS limita alle proprie righe):
   ```js
   let _paymentsCache = null;
   const _fmtTxDate = d => { if(!d) return ''; const s=String(d).slice(0,10).split('-'); return s.length===3?`${s[2]}/${s[1]}/${s[0]}`:d; };
   async function _ensurePayments(){ if(_paymentsCache) return _paymentsCache; const u=getCurrentUser(); if(!u) return (_paymentsCache=[]);
     const {data,error}=await supabaseClient.from('payments')
       .select('id, amount, currency, method, kind, created_at, note, period_start, period_end')
       .eq('client_user_id', u.id).order('created_at',{ascending:false}).limit(200);
     _paymentsCache = error ? [] : (data||[]); return _paymentsCache; }
   async function renderTransactions(){ /* lazy-load + slice(_visibleCount) + map(buildTransactionCard) + "Mostra altro" */ }
   function buildTransactionCard(p){ /* card .preno-card con border-left-color per kind, badge importo, meta metodo/periodo/nota */ }
   ```
   Valuta: `OrgSettings.getString('locale.currency','EUR')` → simbolo `€` per EUR.
4. Invalidare `_paymentsCache=null` nel realtime full-sync (nuovo pagamento) e ri-renderizzare se la tab attiva è `transactions`.
5. (Opzionale, coerenza) hero: mostrare `user.name` completo invece di `user.name.split(' ')[0]`.
6. **Cache-busting**: bump `CACHE_NAME` in `sw.js` (qui v584→v585). `prenotazioni.html` è in `APP_SHELL` → il bump basta (JS inline).

**App Flutter (se presente).**
- `booking_screen.dart`: rimuovere la pill-bar; `body: const CalendarView()`. Eliminare `my_bookings_view.dart`.
- Estrarre la card prenotazione in `booking_card.dart` (`BookingCard{booking, config, showCancel}`) riusabile.
- `core/models/client_payment.dart`: modello `ClientPayment.fromRow` + `selectColumns`.
- `BookingRepository.fetchOwnPayments(userId)`: `from('payments').select(cols).eq('client_user_id',userId).order('created_at',desc).limit(200)`.
- `ownPaymentsProvider` (FutureProvider) accanto a `ownBookingsProvider`.
- `profile_screen.dart` → `ConsumerStatefulWidget` con pill-bar 3 tab (Prossime/Passate/Transazioni), paginazione `_visible` 5→+20; hero con nome completo; rimosso `_infoCard`; card transazione con colore bordo per `kind`.
