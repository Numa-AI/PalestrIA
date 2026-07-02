# Fix code-review.md - guida di replica

Data lavoro: 2026-07-02

Questo documento descrive, in modo replicabile, i fix applicati ai finding di
`code-review.md`. L'obiettivo non e' solo elencare i file toccati, ma spiegare
cosa portare in un progetto simile, in quale ordine, e quali test fare dopo.

Nota importante: i fix sono pensati per un'app Supabase + frontend statico con
client admin e client utente. In un progetto simile vanno adattati i nomi di
tabelle, colonne, RPC e funzioni helper locali.

## Ordine consigliato

1. Applicare prima la migration SQL di hardening.
2. Aggiornare `supabase/config.toml`.
3. Aggiornare le Edge Function.
4. Aggiornare gli helper frontend condivisi.
5. Aggiornare i flussi admin distruttivi/monetari.
6. Aggiornare allenamento/tablet/PDF.
7. Eseguire smoke test su staging prima della produzione.

## 1. Migration SQL unica

File creato:

- `supabase/migrations/20260702010000_code_review_fixes.sql`

La migration e' idempotente dove possibile e contiene piu' fix correlati. In un
progetto simile conviene mantenere la stessa struttura a sezioni.

### 1.1 Bookings: blocco update/insert diretti cliente

Problema risolto:

- un utente autenticato poteva aggiornare proprie prenotazioni via PostgREST e
  cambiare campi monetari come `paid`, `payment_method`, `credit_applied`;
- lo stesso tipo di accesso poteva bypassare la RPC atomica di prenotazione e
  quindi la capienza.

Modifica:

- droppare `bookings_update_own`;
- creare solo policy update admin:

```sql
DROP POLICY IF EXISTS bookings_update_own ON public.bookings;
DROP POLICY IF EXISTS bookings_update_admin ON public.bookings;
CREATE POLICY bookings_update_admin ON public.bookings
  FOR UPDATE TO authenticated
  USING (is_admin())
  WITH CHECK (is_admin());
```

- sostituire la policy insert autenticata con insert diretto solo admin:

```sql
DROP POLICY IF EXISTS bookings_authenticated_insert ON public.bookings;
CREATE POLICY bookings_authenticated_insert ON public.bookings
  FOR INSERT TO authenticated
  WITH CHECK (is_admin());
```

Nota replica: il client normale deve continuare a prenotare tramite RPC tipo
`book_slot_atomic`, non via `.from('bookings').insert(...)`.

### 1.2 Profiles: blocco self-update dei flag admin

Problema risolto:

- l'utente poteva auto-assegnarsi flag admin-only come `documento_firmato`,
  `stripe_enabled`, `autonomia_enabled`.

Modifica:

- ricreare `profiles_update` con `USING` e `WITH CHECK`;
- aggiungere trigger `BEFORE UPDATE` che permette all'admin tutto, ma blocca
  all'utente normale il cambio dei campi admin-only.

Campi protetti:

- `documento_firmato`
- `stripe_enabled`
- `autonomia_enabled`

Funzione aggiunta:

- `public._trg_profiles_block_self_admin_flags()`

Trigger aggiunto:

- `trg_profiles_block_self_admin_flags`

### 1.3 Workout logs: schema `rest_done` e RLS admin/kiosk

Problemi risolti:

- `rest_done` era usato dal frontend ma non garantito nello schema;
- il tablet/kiosk con sessione admin non poteva scrivere log per un cliente
  diverso per via delle RLS solo "own".

Modifiche:

```sql
ALTER TABLE public.workout_logs
  ADD COLUMN IF NOT EXISTS rest_done INT;
```

Policy sostituite:

- `workout_logs_insert`
- `workout_logs_update`
- `workout_logs_delete`

Nuova logica:

- admin: puo' inserire/modificare/cancellare log di qualunque utente;
- utente normale: puo' farlo solo su `user_id = auth.uid()`.

### 1.4 Duplicazione schede: preservare `circuit_group`

Problema risolto:

- `admin_duplicate_plan` copiava `superset_group` ma non `circuit_group`, quindi
  i circuiti diventavano esercizi singoli dopo template/duplicazione.

Modifica:

- ridefinire `public.admin_duplicate_plan(...)`;
- includere `circuit_group` nella lista colonne di `INSERT INTO workout_exercises`
  e nella `SELECT`.

Colonne copiate ora:

- `superset_group`
- `circuit_group`

### 1.5 QR tablet: token opaco a scadenza

Problema risolto:

- il QR conteneva `tablet.html?uid=<uuid>`, permanente e copiabile;
- chiunque con UUID poteva aprire una scheda sul tablet.

Modifiche DB:

- creare tabella `public.tablet_access_tokens`;
- salvare solo `token_hash`, mai il token in chiaro;
- aggiungere `expires_at` e `revoked_at`;
- RLS: nessun accesso diretto alla tabella.

Tabella:

```sql
CREATE TABLE IF NOT EXISTS public.tablet_access_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ
);
```

RPC aggiunte:

- `public.create_tablet_access_token(p_user_id UUID DEFAULT NULL, p_ttl_minutes INT DEFAULT 720)`
- `public.resolve_tablet_access_token(p_token TEXT)`

Dettagli:

- token generato con `gen_random_bytes(32)` e codificato hex;
- hash `sha256` salvato in tabella;
- TTL clampato tra 5 minuti e 1440 minuti;
- default 720 minuti, cioe' 12 ore;
- `create_tablet_access_token` consente token per se stessi o, se admin, per un
  altro utente;
- `resolve_tablet_access_token` ritorna `user_id` solo se token esiste, non e'
  revocato e non e' scaduto.

Grant:

- entrambe le RPC sono eseguibili da `authenticated`;
- la tabella resta chiusa via RLS.

### 1.6 Restore backup credit_history transazionale

Problema risolto:

- restore cancellava `credit_history` e poi reinseriva righe con FK vecchie;
- se l'insert falliva, la tabella era gia' stata svuotata.

Modifica DB:

- nuova RPC `public.admin_replace_credit_history(p_rows JSONB)`.

Comportamento:

- solo admin;
- accetta solo array JSON;
- valida che ogni `credit_id` esista in `credits`;
- dentro la stessa transazione cancella `credit_history` e reinserisce;
- se qualcosa fallisce, rollback completo.

Campi gestiti:

- `id`
- `credit_id`
- `amount`
- `display_amount`
- `note`
- `method`
- `stripe_session_id`
- `created_at`
- `booking_ref` come UUID
- `booking_id` come UUID
- `hidden`

### 1.7 Delete cliente server-side per email e/o WhatsApp

Problema risolto:

- prima la cancellazione server veniva saltata se mancava email;
- gli errori RPC erano ignorati;
- il toast di successo poteva comparire anche con server non pulito.

Modifica DB:

- sostituita `admin_delete_client_data(TEXT)` con:

```sql
public.admin_delete_client_data(p_email TEXT DEFAULT NULL, p_whatsapp TEXT DEFAULT NULL)
```

Comportamento:

- solo admin;
- richiede almeno email o WhatsApp;
- cancella `credit_history` collegata ai crediti del cliente;
- cancella da:
  - `bookings`
  - `credits`
  - `manual_debts`
  - `bonuses`
- ritorna conteggi cancellati.

### 1.8 Prune storico server-side

Problema risolto:

- il vecchio prune cancellava solo cache locali o dati RAM;
- al reload i dati vecchi tornavano da Supabase.

Modifica DB:

- nuova RPC `public.admin_prune_old_data(p_cutoff DATE)`.

Comportamento:

- solo admin;
- cancella prenotazioni con `date < p_cutoff`;
- cancella prenotazioni demo con `local_id LIKE 'demo-%'`;
- cancella `credit_history` con `created_at::date < p_cutoff`;
- mantiene invariati i saldi correnti.

### 1.9 Stripe top-up: debt gate corretto

Problema risolto:

- il debt gate per bonus Stripe non considerava `couple`;
- ignorava `custom_price`;
- un debitore poteva ricevere bonus ricarica indebito.

Modifica:

- ridefinita `public.stripe_topup_credit(UUID, NUMERIC, TEXT)`;
- calcolo debito booking:

```sql
coalesce(
  custom_price,
  ('{"personal-training":5,"small-group":10,"group-class":30,"couple":20}'::jsonb ->> slot_type)::numeric,
  0
) - coalesce(credit_applied, 0)
```

Grant finale:

- `REVOKE ALL ... FROM public`
- `GRANT EXECUTE ... TO service_role`

Nota replica: se nel progetto simile la RPC viene chiamata anche da utenti
autenticati, adattare il grant; qui viene chiamata da Edge Function con service
role.

## 2. Supabase config Edge Functions

File modificato:

- `supabase/config.toml`

Problemi risolti:

- due function invocate dal client non erano in `verify_jwt=false`;
- con rollover Signing Keys, il gateway poteva rifiutare prima della auth interna.

Aggiunto:

```toml
[functions.notify-access-request-update]
verify_jwt = false

[functions.image-proxy]
verify_jwt = false
```

Nota replica: farlo solo se la function valida internamente il token o se e'
intenzionalmente pubblica/protetta con altre regole. Nel caso `image-proxy`, la
protezione attesa e' whitelist dominio/proxy controllato.

## 3. Edge Function report mensile

File modificato:

- `supabase/functions/generate-monthly-report/index.ts`

### 3.1 Consenso AI non bypassabile da cliente

Problema risolto:

- `skip_consent_check` arrivava dal body ed era onorato anche per utenti non
  admin.

Modifica:

```ts
const canSkipConsentCheck = isAdmin && skip_consent_check === true;
```

Poi:

```ts
if (!profile.report_ai_consent && !canSkipConsentCheck) {
  ...
}
```

### 3.2 Rate limit report sempre attivo per non-admin

Problema risolto:

- limite 3/mese applicato solo se `force_regenerate && !isAdmin`.

Modifica:

```ts
if (!isAdmin) {
  // count monthly_reports generated
}
```

Quindi il limite vale per tutti i non-admin, indipendentemente da
`force_regenerate`.

## 4. Helper frontend condiviso

File modificato:

- `js/ui.js`

Problema risolto:

- `_escHtml()` non e' sufficiente per valori inseriti dentro handler inline
  `onclick="fn('...')"`;
- apostrofi/backslash/newline potevano rompere JS o diventare injection.

Helper aggiunti:

```js
function _escJsArg(str) {
    return String(str ?? '')
        .replace(/\\/g, '\\\\')
        .replace(/'/g, "\\'")
        .replace(/\r/g, '\\r')
        .replace(/\n/g, '\\n')
        .replace(/</g, '\\x3C')
        .replace(/>/g, '\\x3E');
}

function _escOnclickArg(str) {
    return _escHtml(_escJsArg(str));
}
```

Uso consigliato:

- testo visibile in HTML: `_escHtml(value)`;
- valore dentro stringa JS inline: `_escOnclickArg(value)`;
- se possibile, in futuro preferire `addEventListener` invece di inline onclick.

## 5. Admin privacy / analytics / XSS

File modificati:

- `js/admin.js`
- `js/admin-analytics.js`
- `js/admin-payments.js`
- `js/admin-schedule.js`

### 5.1 Privacy mask incompleta

File:

- `js/admin.js`

Modifica:

- aggiunto `checkFisicoChange` a `SENSITIVE_IDS`.

Prima il toggle privacy non mascherava la card "Check Fisici".

### 5.2 Importi nei dettagli analytics

File:

- `js/admin-analytics.js`

Modifiche:

- `checkFisicoChange` aggiornato con `sensitiveSet(...)`;
- in `renderClientiDetail` aggiunta funzione locale tipo:
  - ritorna `***` se `_sensitiveHidden`;
  - altrimenti ritorna importo formattato;
- applicata la stessa logica a:
  - maggior fatturato cliente;
  - bonus risparmiati;
  - more;
  - check fisici incassato/medio/metodo/lista.

### 5.3 XSS stored nei nomi cliente

File:

- `js/admin-analytics.js`
- `js/admin-payments.js`
- `js/admin-schedule.js`

Modifiche:

- ogni nome cliente interpolato in `innerHTML` usa `_escHtml(...)`;
- i valori passati a `onclick` usano `_escOnclickArg(...)`.

Esempi:

- `${_escHtml(c.name)}`
- `const safeN = _escOnclickArg(u.name || '')`

### 5.4 Date locali nel grafico fatturato

File:

- `js/admin-analytics.js`

Problema:

- lookup con `day.toISOString().split('T')[0]` spostava date in UTC e poteva
  leggere il giorno precedente in Europe/Rome.

Modifica:

- sostituiti i lookup con `_localDateStr(day)`.

## 6. Admin clients

File modificato:

- `js/admin-clients.js`

### 6.1 Popup modifica contatto: onclick sicuro

Problema:

- nomi con apostrofo rompevano gli handler;
- possibile injection in bottoni popup.

Modifica:

- in `openEditClientPopup`, usare `_escOnclickArg(...)` su WhatsApp, email,
  nome cliente.

### 6.2 `saveClientEdit`: controllare `data.success`

Problema:

- RPC `admin_rename_client` poteva tornare `{ success:false, error:'...' }`
  senza errore di trasporto;
- il client mostrava successo e aggiornava dati locali.

Modifica:

- dopo la RPC:
  - se `error`, mostra errore e ritorna;
  - se `!data?.success`, mappa errori e ritorna;
  - solo dopo successo sincronizza cache e profilo.

Errori mappati:

- `new_email_required`
- `new_name_required`
- `email_already_exists`
- `unauthorized`

### 6.3 `deleteClientData`: server-first e conferma non segreta

Problemi:

- password hardcoded pubblica;
- cancellazione saltata se mancava email;
- errori server ignorati;
- match locale WhatsApp errato.

Modifiche:

- prompt richiede di scrivere `ELIMINA`;
- niente password segreta lato JS;
- recupera cliente per email o WhatsApp normalizzato;
- blocca se mancano entrambi;
- chiama RPC:

```js
supabaseClient.rpc('admin_delete_client_data', {
  p_email: clientEmail || null,
  p_whatsapp: clientPhone || null,
})
```

- se RPC fallisce o ritorna `success:false`, non pulisce localmente e mostra
  errore;
- se RPC riesce:
  - invalida delta/cache;
  - rimuove localmente booking, crediti, debiti, bonus per email o telefono;
  - mostra conteggi server.

## 7. Admin backup / restore / prune

File modificato:

- `js/admin-backup.js`

### 7.1 Import backup: niente password hardcoded

Problema:

- gate distruttivo con password pubblica `Palestra123`.

Modifica:

- conferma testuale: scrivere `IMPORTA`.

### 7.2 Export backup: includere mapping crediti raw

Problema:

- per rimappare `credit_history` serve sapere quale vecchio `credit_id`
  apparteneva a quale email.

Modifica:

- nel formato di backup aggiunto `_credits_raw`;
- usato come mappa `old credit_id -> email` durante restore.

### 7.3 Restore credit_history: rimappatura FK e RPC transazionale

Modifica flusso:

1. Aspettare il completamento upsert `credits`.
2. Ricaricare crediti correnti da Supabase.
3. Creare mappa `email -> current credit_id`.
4. Leggere `_credits_raw` per mappa `old credit_id -> email`.
5. Per ogni riga history:
   - calcolare email da `h.email` o dal vecchio credit id;
   - trovare il nuovo `credit_id`;
   - costruire `histRows`.
6. Se qualche riga non e' rimappabile:
   - loggare errore;
   - non chiamare la RPC.
7. Altrimenti chiamare:

```js
supabaseClient.rpc('admin_replace_credit_history', { p_rows: histRows })
```

### 7.4 Tabelle ausiliarie restore: upsert invece di delete+insert

Tabelle convertite a upsert con `onConflict: 'id'`:

- `admin_audit_log`
- `admin_messages`
- `client_notifications`
- `credit_link_clicks`

Scopo:

- ridurre rischio perdita dati in caso di errore a meta' restore.

### 7.5 Prune storico: RPC server-side

Problema:

- prima il prune dichiarava cancellazione definitiva ma puliva solo cache locali.

Modifica:

- chiamare:

```js
supabaseClient.rpc('admin_prune_old_data', { p_cutoff: cutoffStr })
```

- se la RPC fallisce o torna `success:false`, abortire senza mostrare successo;
- dopo successo, potare anche cache locali e invalidare delta/stat cache.

## 8. Admin settings

File modificato:

- `js/admin-settings.js`

Problema:

- password hardcoded pubblica `Maldive` per manutenzione/blocco.

Modifica:

- sostituita con conferma testuale `BLOCCA`;
- niente segreti hardcoded nel JS pubblico.

## 9. Data layer

File modificato:

- `js/data.js`

### 9.1 `WorkoutLogStorage` include `rest_done` e `notes`

Problema:

- sync dei log non selezionava `rest_done`;
- al re-save il riposo poteva tornare al default.

Modifiche:

- in `syncForPlan` e `syncForUser`, select aggiornata:

```js
.select('id,exercise_id,user_id,log_date,set_number,reps_done,weight_done,rpe,rest_done,notes')
```

### 9.2 Reorder esercizi per giorno senza collisione tra giorni

Problema:

- `reorderExercises(planId, orderedIds)` riceveva solo esercizi del giorno attivo
  e riscriveva `sort_order` da `0..N-1`;
- questo poteva collidere con altri giorni.

Modifica:

- caricare tutti gli esercizi del piano;
- individuare il minimo `sort_order` tra gli esercizi riordinati;
- usare quel minimo come base;
- aggiornare solo gli ID passati;
- ordinare l'intero piano finale per `sort_order`.

### 9.3 Retry pending booking: usare RPC atomica

Problema:

- retry offline poteva usare insert diretto `bookings.insert`, bypassando RPC.

Modifica:

- sostituire insert diretto con RPC `book_slot_atomic`;
- passare gli stessi argomenti usati dal flusso normale;
- mantenere timeout/safety.

## 10. Allenamento frontend

File modificato:

- `allenamento.html`

### 10.1 Offline queue: dequeue quando si cancella un log

Problema:

- se un save era rimasto in coda offline e poi il log veniva eliminato, al flush
  successivo poteva ricrearsi.

Modifiche:

- in `deleteTodayLog`: chiamare `_dequeueOp(exerciseId + ':' + today)`;
- in `deleteStoricoLog`: trovare il log da cache e chiamare
  `_dequeueOp(log.exercise_id + ':' + log.log_date)`;
- in `deleteStoricoDay`: chiamare `_dequeueOp(exerciseId + ':' + logDate)`.

### 10.2 QR tablet: generare token, non UID

Problema:

- QR permanente `tablet.html?uid=<user.id>`.

Modifica:

- introdotta variabile `_tabletQrLink`;
- `renderTabletQR()` ora e' async;
- chiama:

```js
supabaseClient.rpc('create_tablet_access_token', {
  p_user_id: user.id,
  p_ttl_minutes: 720
})
```

- se successo, genera link:

```js
tablet.html?t=<token>
```

- QR mostra hint: scade dopo 12 ore;
- `_copyTabletLink()` copia `_tabletQrLink`, non costruisce piu' URL con UID.

### 10.3 PDF scheda: circuiti e immagini corrette

Problemi:

- i circuiti erano renderizzati come esercizi singoli;
- immagini cercate per nome, non per slug/scheda.

Modifiche:

- usare `_findExForCard(ex)` per trovare esercizio/immagine;
- cache immagini con chiave:

```js
const _pdfImgKey = ex => ex.exercise_slug || ex.exercise_name;
```

- aggiungere mappe:
  - `ccMap`
  - `ccRendered`

- aggiungere `_measureCircuit(items)`;
- nel loop PDF:
  - se `ex.circuit_group` non renderizzato, crea blocco "CIRCUITO";
  - stampa lista esercizi;
  - stampa numero giri e pausa finale;
  - renderizza ogni esercizio nel blocco;
  - salta gli altri membri gia' renderizzati.

## 11. Tablet/kiosk

File modificato:

- `tablet.html`

### 11.1 Parsing token e rimozione UID

Problema:

- caricamento da `?uid=` o UUID raw.

Modifiche:

- placeholder manuale: "link tablet o token";
- aggiunto `_extractTabletToken(text)`:
  - accetta URL con parametro `t`;
  - accetta token raw hex da 64 caratteri;
  - rifiuta UUID raw;
- boot da URL usa solo `params.get('t')`;
- se vede vecchio `uid`, lo rimuove dall'URL e resta nello scanner.

### 11.2 Risoluzione server-side token

Modifica:

- `loadUserWorkout(userId, accessToken = null)`;
- se `accessToken` presente:

```js
supabaseClient.rpc('resolve_tablet_access_token', { p_token: accessToken })
```

- solo se RPC ritorna `success:true` e `user_id`, carica profilo/scheda;
- URL persistito contiene solo `t`, mai `uid`.

### 11.3 Tablet read-only sulla scheda

Problema:

- con sessione admin nel browser, tablet poteva rinominare piano, aggiungere,
  modificare, riordinare o cancellare esercizi.

Modifiche:

- aggiunta costante:

```js
const TAB_PLAN_READONLY = true;
```

- hide rename button;
- hide FAB add;
- non inizializzare swipe/drag;
- rimuovere dal DOM:
  - `.tab-ex-delete-action`
  - `.tab-ex-edit-btn`

- guard early-return in funzioni mutanti:
  - `renameTabPlan`
  - `showTabEditExercise`
  - `tabSaveEditExercise`
  - `tabFabAction`
  - `_tabShowFabSheet`
  - `_tabOpenExercisePicker`
  - `tabPickExercise`
  - `_tabOpenSupersetPicker`
  - `_tabSaveSupersetPair`
  - `_initTabSwipeAndDrag`
  - `_onTabTouchStart`
  - `_startTabDrag`
  - `_endTabDrag`
  - `deleteExerciseFromTabPlan`
  - `deleteSupersetFromTabPlan`

Nota: il salvataggio/cancellazione dei log resta disponibile. La read-only e'
solo sulla struttura scheda.

### 11.4 Tablet logs: includere `rest_done`

Modifica:

- select log in caricamento iniziale e refresh background:

```js
.select('id,exercise_id,user_id,log_date,set_number,reps_done,weight_done,rpe,rest_done')
```

## 12. Verifiche eseguite localmente

Comandi eseguiti:

```powershell
node --check js/ui.js
node --check js/admin.js
node --check js/admin-analytics.js
node --check js/admin-backup.js
node --check js/admin-clients.js
node --check js/admin-payments.js
node --check js/admin-schedule.js
node --check js/admin-settings.js
node --check js/data.js
node --check js/admin-calendar.js
node --check js/pull-to-refresh.js
node --check sw.js
node --check supabase/functions/generate-monthly-report/index.ts
```

Risultato:

- OK.

Controllo script inline HTML:

- estratti e parsati gli script inline di:
  - `allenamento.html`
  - `tablet.html`
  - `admin.html`

Risultato:

- OK.

Altro controllo:

```powershell
git diff --check
```

Risultato:

- OK, solo warning Git LF/CRLF.

Tentativo DB:

```powershell
supabase db lint --local --fail-on error
```

Risultato:

- non eseguito per DB locale non avviato su `127.0.0.1:54322`.

## 13. Checklist staging prima della produzione

DB / migration:

- fare backup DB;
- applicare migration su staging;
- verificare che tutte le RPC compilino;
- verificare grant e RLS con utente admin e utente normale.

Booking:

- utente normale prenota via UI;
- tentativo diretto PostgREST `bookings.update` deve fallire;
- tentativo diretto PostgREST `bookings.insert` deve fallire;
- admin deve ancora poter gestire prenotazioni.

Profiles:

- utente normale puo' aggiornare campi profilo consentiti;
- utente normale non puo' cambiare `documento_firmato`, `stripe_enabled`,
  `autonomia_enabled`;
- admin puo' modificarli.

Tablet:

- QR generato contiene `?t=`, non `?uid=`;
- token valido apre scheda;
- token scaduto o invalido non apre scheda;
- rename/add/edit/delete/drag scheda non sono disponibili;
- log workout si salva e si cancella.

Backup/restore:

- export con `_credits_raw`;
- restore su staging dopo clear dati;
- verificare che `credit_history` venga rimappata e non persa;
- verificare admin audit/messages/notifications/clicks.

Delete cliente:

- cliente con email;
- cliente solo WhatsApp;
- errore RPC deve bloccare pulizia locale.

Prune:

- dati vecchi rimossi sul server;
- saldi correnti invariati;
- al reload i dati potati non ricompaiono.

Stripe:

- webhook top-up normale;
- reconcile Stripe;
- cliente con debito `couple` oltre soglia non riceve bonus;
- `custom_price` viene considerato.

Report AI:

- non-admin senza consenso riceve `CONSENT_REQUIRED` anche se manda
  `skip_consent_check:true`;
- admin puo' bypassare consenso se necessario;
- non-admin ha limite 3 report generati per mese.

PDF allenamento:

- scheda con circuito mostra blocco "CIRCUITO";
- immagini esercizi rinominati ancora presenti;
- superset e circuiti non duplicano esercizi.

Admin UI:

- nomi con apostrofo non rompono pulsanti;
- nome malevolo tipo `<img onerror=...>` viene mostrato come testo;
- privacy mask nasconde anche dettagli clienti/check fisici.

## 14. Note su modifiche fuori dal perimetro code-review

Nel working tree erano presenti anche modifiche a:

- `admin.html`
- `css/admin.css`
- `js/admin-calendar.js`
- `js/pull-to-refresh.js`
- `sw.js`

Queste riguardano una shell mobile anti-detach iOS PWA e bump cache/service
worker. Non sono necessarie per replicare i 23 finding di `code-review.md`.
Se il progetto simile non ha lo stesso bug iOS PWA, non copiarle come parte di
questo pacchetto sicurezza.
