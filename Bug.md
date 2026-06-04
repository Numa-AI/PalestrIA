# Bug.md — Bug, rischi e qualità del codice (PalestrIA + progetti gemelli)

Questo documento raccoglie i problemi emersi dall'analisi del codebase **PalestrIA**, con un occhio a quelli **portabili ai progetti gemelli** (Thomas Bresciani, Giacomo Zeni, D'Amico) — costruiti per copia/port dallo stesso codice, quindi probabilmente affetti dagli stessi difetti.

> 📁 Le migration single-tenant citate qui sono state archiviate in `_legacy/migrations-singletenant/` (sostituite dalla baseline SaaS). I link puntano lì.

## Come leggere questo file
- 🔴 **Confermato** = verificato leggendo il codice (file:linea citati).
- 🟡 **Da verificare** = segnalato dall'analisi statica, plausibile ma non confermato al 100% in ogni call-site.
- ⚪️ **Falso allarme** = sembrava un bug ma il codice è corretto (incluso per trasparenza, così non si "corregge" ciò che funziona).
- 🧬 **Gemelli** = molto probabilmente presente anche negli altri progetti (codice condiviso/portato).

> Nota: in PalestrIA molti di questi sono già **risolti** nel refactor SaaS (baseline multi-tenant). Qui restano elencati perché **vanno corretti anche nei progetti gemelli**, che non hanno ricevuto il refactor.

---

## 🔴 Bug confermati — da correggere

### 1. Incoerenza prezzo `group-class`: 30 € (JS) vs 50 € (SQL) 🧬
- **Dove**: [js/data.js:143](js/data.js#L143) `SLOT_PRICES['group-class'] = 30` — ma le RPC SQL usano **50** (`apply_credits_to_bookings`, `get_unpaid_past_debt`, `admin_role.sql`: `when 'group-class' then 50`).
- **Impatto**: il prezzo mostrato/calcolato lato client (30 €) **non coincide** con quello con cui il server scala il credito e calcola il debito (50 €). Fatturato, debiti e auto-pagamenti risultano sbagliati di 20 € a lezione group-class.
- **Fix**: unica fonte di verità per i prezzi. In PalestrIA SaaS i prezzi vivono in `slot_types.default_price` per-org. Nei gemelli: allineare i due valori (decidere 30 **o** 50) sia in `data.js` sia in **tutte** le RPC, oppure leggere il prezzo da un'unica tabella/funzione (`get_org_price`).

### 2. Capienza slot decisa dal client (overbooking aggirabile) 🧬
- **Dove**: [_legacy/migrations-singletenant/20260512000000_book_slot_atomic_no_wait.sql](_legacy/migrations-singletenant/20260512000000_book_slot_atomic_no_wait.sql) — `book_slot_atomic(... p_max_capacity integer ...)` riceve la **capienza dal browser**. Il controllo `if v_count >= p_max_capacity` usa un valore che il client può falsificare (DevTools/replay della chiamata RPC).
- **Impatto**: un utente può inviare `p_max_capacity` alto e **superare la capienza reale** dello slot (overbooking). L'advisory lock garantisce l'atomicità ma non l'integrità del limite.
- **Fix**: rendere la capienza **server-authoritative** — il server ricava la capienza dalla configurazione (in PalestrIA SaaS: `resolve_slot_config()`), non la accetta come parametro. Nei gemelli: derivare `max_capacity` server-side da una tabella di config, ignorando il parametro client.

### 3. RLS `using(true)` sulle prenotazioni — dati personali leggibili da chiunque 🧬
- **Dove**: [_legacy/migrations-singletenant/20260225000000_init.sql:60-66](_legacy/migrations-singletenant/20260225000000_init.sql#L60-L66) — `bookings_public_read ... for select using (true)` (+ `bookings_public_insert ... with check (true)`).
- **Impatto**: qualsiasi utente (anche anonimo, via anon key) può fare `from('bookings').select('*')` e leggere **nome, email, WhatsApp, note di TUTTI**. La RPC `get_slot_attendees` anonimizza correttamente, ma la tabella grezza è esposta e bypassa quell'anonimizzazione. È un problema GDPR.
- **Fix**: niente policy `using(true)` su tabelle con dati personali. Limitare la SELECT al proprietario (`user_id = auth.uid()`) + admin. L'inserimento pubblico (booking anonimo) va incanalato in una RPC `SECURITY DEFINER`, non in una policy insert aperta. (In PalestrIA SaaS già fatto: policy org-scoped + `book_slot`.)

### 4. RPC credito eseguibile da anonimi 🧬
- **Dove**: `apply_credit_on_booking` con `GRANT EXECUTE ... TO anon` ([20260311200000_apply_credit_on_booking.sql](_legacy/migrations-singletenant/20260311200000_apply_credit_on_booking.sql)). Nessun controllo `auth.uid()`, solo match per email.
- **Impatto**: un anonimo che conosce un'email può tentare di applicare il credito di quell'utente a una prenotazione. Superficie d'attacco sul saldo crediti.
- **Fix**: revocare l'esecuzione ad `anon`; richiedere autenticazione e verificare che il chiamante sia il proprietario. (In PalestrIA SaaS il sistema crediti è stato rimosso del tutto; nei gemelli che lo mantengono, blindare l'RPC.)

---

## 🟡 Problemi probabili — da verificare nei singoli call-site

### 5. Disallineamento cache locale ↔ server dopo cancellazione 🧬
- **Dove**: `data.js` (funzioni `cancel*` / `syncFromSupabase`). L'architettura è offline-first: lo stato viene mutato in cache locale e sincronizzato in modo asincrono.
- **Rischio**: se la PWA va offline tra la mutazione locale e la conferma server, lo stato diverge (es. uno slot appare libero in locale ma è occupato sul server). L'utente vede dati non veri finché non risincronizza.
- **Mitigazione**: rendere il server l'autorità per le viste critiche (disponibilità slot), ridurre la fiducia nella cache per i conteggi, e ri-fetchare dal server dopo ogni mutazione invece di fidarsi della cache.

### 6. Race: cambio tipo-slot admin durante una cancellazione concorrente 🧬
- **Dove**: [js/admin-schedule.js](js/admin-schedule.js) `updateSlotType` controlla le prenotazioni attive e poi applica il cambio, senza transazione che copra i due passi.
- **Rischio**: tra il controllo e l'applicazione può arrivare una cancellazione (realtime/altra tab) → il cambio procede su uno stato ormai diverso.
- **Mitigazione**: spostare la verifica+azione in un'unica RPC transazionale server-side.

### 7. Reconnect realtime senza backoff (PWA) 🧬
- **Dove**: [js/silent-refresh.js](js/silent-refresh.js) — i canali realtime morti vengono ricreati senza backoff né max-retry; soglia idle bassa (5 min).
- **Rischio**: in caso di errore ripetuto della factory o rate-limit di Supabase, retry a raffica → spreco risorse / esaurimento quota connessioni realtime.
- **Mitigazione**: backoff esponenziale + tetto ai tentativi.

### 8. Saturazione pool RPC senza retry 🧬
- **Dove**: [js/admin-payments.js](js/admin-payments.js) — guardia `_paymentsRpcInFlight` che, se una RPC va in timeout, lascia la UI ferma fino al cooldown (≈2 min) senza retry/backoff.
- **Mitigazione**: timeout + retry con backoff, indicatore "sync in corso".

### 9. Mutazione diretta della cache admin prima della conferma RPC 🧬
- **Dove**: [js/admin-calendar.js](js/admin-calendar.js) (es. `_cache.push(booking)` e mutazioni `customPrice`) eseguite prima di verificare l'esito della RPC.
- **Rischio**: se la RPC fallisce lato server (es. `is_admin()` negato), la cache locale resta modificata → UI incoerente.
- **Mitigazione**: mutare la cache **solo** dopo conferma della RPC.

### 10. Disciplina cache-busting Service Worker (processo) 🧬
- **Dove**: `sw.js` — `CACHE_NAME` (`palestria-vNNN`) e i `?v=` nei tag vanno bumpati **a mano** ad ogni deploy.
- **Rischio**: dimenticarsene → gli utenti PWA restano su asset vecchi/incoerenti (classe di "bug fantasma" difficili da riprodurre).
- **Mitigazione**: automatizzare il bump in CI (hash del contenuto) e tenere allineata la lista `APP_SHELL`.

---

## ⚪️ Falsi allarmi (verificati: NON sono bug)
Inclusi per trasparenza — **non** "correggerli".
- **Privacy iscritti**: `get_slot_attendees` ([20260328000000_privacy_prenotazioni.sql:9-19](_legacy/migrations-singletenant/20260328000000_privacy_prenotazioni.sql#L9-L19)) **anonimizza server-side** (`CASE WHEN privacy_prenotazioni THEN 'Anonimo'`). La privacy è enforce-ata lato server. (Unico limite: nessun filtro `org_id` — rilevante solo in multi-tenant, già gestito nel SaaS.)
- **`normalizePhone` null/prefisso 39X**: [auth.js:16-24](js/auth.js#L16-L24) e il duplicato [viewer.html:600-608](viewer.html#L600-L608) hanno **entrambi** la guardia `if (!raw) return ''` e il fix `length === 12`. In sync, corretti.
- **XSS note**: nel render principale [admin-calendar.js:590](js/admin-calendar.js#L590) le note passano per `_escHtml(...)`. (Comunque: vale la pena fare un audit di **tutti** i punti che stampano contenuto utente — vedi qualità del codice.)

---

## 🧱 Come è scritto il codice (qualità)

**Punti di forza**
- RPC admin protette da `SECURITY DEFINER` + `is_admin()`; prenotazione atomica con `pg_advisory_xact_lock`; idempotenza su top-up Stripe (`stripe_session_id`).
- Gestione sessione robusta (fail-closed, fallback mutex per `navigator.locks` su PWA mobile, watchdog anti-blocco).
- Escaping (`_escHtml`) applicato in molti render.

**Debolezze strutturali (causa dei bug sopra)**
- **Hardcoding diffuso**: prezzi (5/10/50/30), orari (12 fasce fisse), timezone (`Europe/Rome`), UUID admin, branding (`#8B5CF6`, logo). È la radice della rigidità "mono-trainer". → Spostare in configurazione.
- **File monolitici molto grandi**: `data.js` (~150 KB), `admin-schedule.js`, `admin-analytics.js`, `allenamento.html` (~270 KB). Difficili da modificare senza regressioni.
- **Logica duplicata tra pagine**: `normalizePhone` esiste in `auth.js`, `viewer.html`, `tablet.html`. Oggi sono in sync, ma è **drift-prone**: un fix in un punto va replicato a mano (è già successo). → Centralizzare in un modulo condiviso.
- **Architettura offline-first con cache ottimistica**: localStorage + sync asincrona Supabase. Genera tutta la classe di bug "cache vs server" (#5, #9). Il server dovrebbe essere l'autorità per i dati condivisi/critici.
- **~125 migration incrementali**, molte `fix_*` (timezone, telefoni, ricalcoli credito): segnale di aree storicamente fragili (gestione tempo, contabilità credito).
- **Cache-busting manuale**: vedi #10.

---

## ✅ Checklist da applicare ai progetti gemelli (Thomas, Giacomo, D'Amico)
Priorità per impatto:
1. [ ] **#3 RLS `using(true)`**: sostituire con policy per-proprietario + admin; chiudere la lettura pubblica di `bookings` (privacy/GDPR). **Alta priorità.**
2. [ ] **#2 Capienza server-side**: non fidarsi di `p_max_capacity` dal client; derivarla server-side.
3. [ ] **#1 Prezzi coerenti**: allineare JS e SQL su un'unica fonte (verificare i valori reali di ogni progetto — possono differire dal 30/50 di PalestrIA).
4. [ ] **#4 RPC credito non-anon**: revocare `anon`, richiedere auth + ownership.
5. [ ] **#5/#9 Cache vs server**: ri-fetch dopo mutazione, mutare cache solo post-conferma.
6. [ ] **#10 Cache-busting**: automatizzare in CI.
7. [ ] **#6/#7/#8**: transazioni server-side per cambi di stato concorrenti; backoff su reconnect/RPC.
8. [ ] Centralizzare `normalizePhone` e altre utility duplicate.

> Verifica sempre i **valori specifici** in ogni progetto prima di correggere: i gemelli possono avere prezzi/orari/UUID diversi pur condividendo la struttura dei bug.
