# fix.md — Eliminare i freeze (e l'over-fetching) di una PWA (Supabase + JS vanilla)

Documentazione dettagliata dei fix applicati a PalestrIA per risolvere i freeze della PWA e
ridurre le chiamate ridondanti, pensata per essere **replicata su progetti simili**
(PWA zero-build + Supabase Auth/Realtime).

> Branch: `fix/pwa-freeze`. Diagnosi originale: workflow multi-agente (6 investigatori + verifica
> avversariale a 3 lenti). Sintomi e cause-radice nel `todo.md`, sez. "🧊 Stabilità / Freeze PWA".

---

## 0. Indice
1. [Sintomi e principio](#1-sintomi-e-il-principio)
2. [Fase A — timeout sulle operazioni async](#2-fase-a--timeout-sulle-operazioni-async)
3. [Fase B — il cuore: auth-lock (`navigator.locks`)](#3-fase-b--il-cuore-auth-lock-navigatorlocks)
4. [Watchdog globale di auto-guarigione](#4-watchdog-globale-di-auto-guarigione)
5. [Fase C — canali Realtime rivivibili](#5-fase-c--canali-realtime-rivivibili)
6. [Cache-busting (Service Worker)](#6-cache-busting-service-worker)
7. [Fase D — over-fetching / troppe chiamate](#7-fase-d--over-fetching--troppe-chiamate)
8. [Fase E — flash branding al refresh (FOUC)](#8-fase-e--flash-branding-al-refresh-fouc)
9. [Checklist di test](#9-checklist-di-test-devtools)
10. [Come replicare su un altro progetto](#10-come-replicare-su-un-altro-progetto)
11. [Riepilogo file toccati](#11-riepilogo-file-toccati)

---

## 1. Sintomi e il principio

**Sintomi:** la PWA va spesso chiusa/riaperta o refreshata; "alla 2ª prenotazione si freeza";
su desktop (Mac) lasciato acceso il sito si freeza e serve un refresh.

**Causa comune (≠ vero blocco della CPU):** non era il thread bloccato, ma **promise asincrone
che non si risolvono mai** (rete lenta, webview sospesa in background/sleep, lock auth non rilasciato).
Una promise che non settla blocca a catena tutto ciò che la aspetta → l'app *sembra* morta.

**🔑 Il principio replicabile (la regola d'oro):**
> 1. **Nessun `await` senza una scadenza.** Ogni chiamata di rete / lock ha un timeout che la fa
>    comunque settlare.
> 2. **Ogni lock/flag si auto-guarisce.** Niente flag che resta `true` per sempre se un await interno
>    si appende.
> 3. **Uno strato di auto-reload come backstop.** Se nonostante tutto l'app si incastra, si ricarica
>    da sola (invisibile) invece di richiedere l'utente.

Le Fasi A/B/C applicano i punti 1–2; il watchdog è il punto 3. La Fase D è efficienza (≠ freeze).

---

## 2. Fase A — timeout sulle operazioni async

Helper già presenti (riusati ovunque). Se nel tuo progetto non ci sono, **creali per primi**:

```js
// Wrappa una promise (RPC o query supabase-js) con timeout esplicito.
function _rpcWithTimeout(promise, ms = 12000) {
    let ac = null, racedPromise = promise;
    try {
        if (promise && typeof promise.abortSignal === 'function') {
            ac = new AbortController();
            racedPromise = promise.abortSignal(ac.signal);
        }
    } catch (_) {}
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { if (ac) { try { ac.abort(); } catch (_) {} } reject(new Error('rpc_timeout')); }, ms);
        Promise.resolve(racedPromise).then(
            (v) => { clearTimeout(timer); resolve(v); },
            (e) => { clearTimeout(timer); reject(e); }
        );
    });
}
const _queryWithTimeout = (promise, ms = 12000) => _rpcWithTimeout(promise, ms);
```

### C3 — RPC di scrittura senza timeout (es. `saveBookingForClient`)
**Problema:** la versione admin del booking chiamava la RPC **senza** AbortController/timeout, mentre
la versione utente ce l'aveva (45s). Su rete lenta il bottone restava disabilitato → freeze "alla 2ª".

**Fix (data.js):**
```js
// PRIMA
const { data, error } = await supabaseClient.rpc('book_slot', { /* ... */ });

// DOPO
const _abortCtrl = new AbortController();
const _abortTimer = setTimeout(() => _abortCtrl.abort(), 45000);
let data, error;
try {
    ({ data, error } = await supabaseClient.rpc('book_slot', { /* ... */ }).abortSignal(_abortCtrl.signal));
} catch (e) { clearTimeout(_abortTimer); return { ok: false, error: 'server_error', booking }; }
clearTimeout(_abortTimer);
```

### C11 — loop di paginazione con `await` nudo
**Problema:** il loop che pagina le righe (`while (!done) { ... await q; }`) usava una query raw senza
timeout. Su rete lenta dopo il wake bloccava l'intero sync → `refreshInFlight` non si resettava (vedi C7).
```js
// PRIMA: const { data: page, error: pageErr } = await q;
// DOPO:  const { data: page, error: pageErr } = await _queryWithTimeout(q, 12000);
```

### C5 — retry "fire-and-forget" senza timeout
**Problema:** `_retryPending` lanciava più `.insert().then()` **senza** timeout né `await`. Su rete lenta
restavano appese e saturavano la microtask queue, ritardando il booking successivo.
```js
static async _retryPending(pending, user) {
    for (const b of pending) {
        try { const { error } = await _rpcWithTimeout(supabaseClient.from('bookings').insert({ /* ... */ }), 12000); /* gestione */ }
        catch (e) { console.error('retry timeout/exception:', b.id, e && e.message); }
        await new Promise(r => setTimeout(r, 100)); // non saturare la microtask queue
    }
}
```

### C7 — flag `refreshInFlight` che resta `true` per sempre
**Problema:** in `silent-refresh.js`, se un `await` interno (es. un "master refresh" senza timeout proprio)
si appende, il `finally` non esegue mai → ad ogni attività futura la funzione esce subito → **nessun
refresh più possibile senza reload manuale**.
```js
function _withTimeout(p, ms, label) {
    return Promise.race([ Promise.resolve(p), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout:' + label)), ms)) ]);
}
async function _triggerSilentRefresh(reason) {
    if (refreshInFlight || /* throttle */) return;
    refreshInFlight = true;
    const _watchdog = setTimeout(() => { if (refreshInFlight) refreshInFlight = false; }, 30000); // ← sblocco garantito
    try {
        // rami senza timeout proprio ora avvolti:
        // await _withTimeout(window._silentMasterRefresh(reason), 20000, 'masterRefresh').catch(...);
    } finally { clearTimeout(_watchdog); refreshInFlight = false; }
}
```

### C8 — flag di auto-recovery mai resettato
**Problema:** un "cascade reload" settava `_cascadeReloadScheduled = true` ma non lo resettava mai. Se il
reload falliva (bfcache / lifecycle PWA), il flag restava `true` e l'auto-recovery **non ripartiva più**.
```js
setTimeout(() => { try { window.location.reload(); } catch (_) {} }, 200);
setTimeout(() => { _cascadeReloadScheduled = false; _watchdogFirings = []; }, 10000); // ← fallback
```

### C10 — Service Worker Network-First senza timeout sul `fetch`
**Problema:** su rete raggiungibile ma lentissima (Mac post-sleep), il `fetch` del SW resta appeso fino al
timeout di default del browser (~60s), congelando il caricamento dell'asset.
```js
function fetchWithTimeout(request, ms) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ms);
    return fetch(request, { signal: controller.signal }).finally(() => clearTimeout(timer));
}
// usare fetchWithTimeout(request, 8000) nei rami Network-First (navigate + .js/.css),
// con .catch(() => caches.match(request, { ignoreSearch: true }))
```

---

## 3. Fase B — il cuore: auth-lock (`navigator.locks`)

Causa principale del freeze "alla 2ª prenotazione" (utente normale) e del Mac idle.

**Contesto:** supabase-js usa la **Web Locks API** (`navigator.locks`) per serializzare il refresh del
token auth tra tab. Il progetto fornisce una `lock` custom con fallback mutex JS.

**Il bug preciso:**
```js
const ac = new AbortController();
setTimeout(() => ac.abort(), timeout);
return await navigator.locks.request(name, { signal: ac.signal }, fn); // ← fn NON protetta
```
L'`AbortController`/`signal` aborta **solo l'attesa di acquisizione** del lock, **non** l'esecuzione di
`fn` una volta acquisito (comportamento della Web Locks spec). Quindi se `fn` (refresh token / RPC auth)
si **appende dopo** aver preso il lock, lo tiene bloccato **per sempre**: ogni operazione auth successiva
muore in coda → app wedged finché non ricarichi.

**Fix (supabase-client.js):** avvolgere `fn` in un watchdog **anche dentro** il lock.
```js
function _withFnWatchdog(name, fn) {
    let timer;
    const fnPromise = Promise.resolve().then(fn).finally(() => clearTimeout(timer));
    fnPromise.catch(() => {}); // C4: niente unhandled rejection se fn rifiuta dopo il timeout
    const watchdog = new Promise((resolve) => { timer = setTimeout(() => { /* ...cascade... */ resolve(undefined); }, FALLBACK_FN_WATCHDOG_MS); });
    return Promise.race([fnPromise, watchdog]);
}
// PRIMA: navigator.locks.request(name, { signal: ac.signal }, fn)
// DOPO:  navigator.locks.request(name, { signal: ac.signal }, () => _withFnWatchdog(name, fn))   // ← C1
```
Applicato anche al ramo non-blocking (`ifAvailable`). Inoltre **C2:** la chain di serializzazione
(`_runSerialized`) **logga** l'errore invece di inghiottirlo con `.catch(() => {})` muto.

---

## 4. Watchdog globale di auto-guarigione

Lo **strato di garanzia** (punto 3 del principio): protegge anche dai bug non ancora trovati. File nuovo
`js/app-watchdog.js`. Al **resume** (visibilità tornata visibile dopo ≥60s nascosto / ripristino bfcache /
ritorno online) lancia una probe `ensureValidSession`; se non si risolve entro 12s lo stato auth è davvero
incastrato → **reload invisibile** (con guard anti-perdita-dati-form e anti-loop max 3/sessione).

Perché non scatta a vuoto su rete solo lenta: `ensureValidSession` è progettata per risolversi SEMPRE
entro il suo timeout (fail-closed incluso). Se NON lo fa, è genuinamente wedged.

```js
function _probe(ms) {
    const settled = (typeof ensureValidSession === 'function')
        ? Promise.resolve(ensureValidSession({ timeoutMs: ms - 2000 })).then(() => true, () => false)
        : Promise.resolve(true);
    const timeout = new Promise((res) => setTimeout(() => res('timeout'), ms));
    return Promise.race([settled, timeout]); // true=sana, false=errore-ma-viva, 'timeout'=incastrata
}
function _onResume(reason) {
    if (probing || typeof supabaseClient === 'undefined') return;
    probing = true;
    _probe(12000).then((r) => { if (r === 'timeout') _selfHeal('probe-timeout:' + reason); })
                 .finally(() => { probing = false; });
}
// _selfHeal: salta se c'è un form con dati aperto (no perdita input) o se hai già ricaricato di
//            recente (anti-loop via sessionStorage); altrimenti location.reload().
document.addEventListener('visibilitychange', () => { /* se visible dopo ≥60s nascosto → _onResume('visible') */ });
window.addEventListener('pageshow', (e) => { if (e && e.persisted) _onResume('bfcache'); });
window.addEventListener('online', () => _onResume('online'));
```
> Adatta la probe al tuo progetto (qualunque check leggero che conferma che backend/auth risponde).
> File completo: `js/app-watchdog.js`.

---

## 5. Fase C — canali Realtime rivivibili

**Problema:** i canali Supabase Realtime creati fuori da un "registry" centrale (es. moduli IIFE)
**muoiono nel sleep e non si riconnettono** dopo il wake → dati/branding stantii finché non ricarichi.

**Fix (pattern "registry"):** un piccolo registry in `silent-refresh.js` che (a) tiene i canali, (b) li
ripulisce su `beforeunload`, (c) li **rivive** dopo il wake (`_reconnectDeadChannels`), (d) fa
dedup-on-register. Ogni modulo registra il canale via factory invece di crearlo a mano.
```js
// PRIMA (canale orfano, non rivivibile):
const ch = supabaseClient.channel('maintenance-rt').on('postgres_changes', {...}, cb).subscribe();

// DOPO (registrato → rivivibile dopo il wake + cleanup automatico):
const factory = () => supabaseClient.channel('maintenance-rt').on('postgres_changes', {...}, cb).subscribe();
if (typeof window._registerRealtimeChannel === 'function') window._registerRealtimeChannel('maintenance-rt', factory);
else factory();
```
Dedup-on-register + cleanup centralizzato (silent-refresh.js):
```js
function _registerRealtimeChannel(name, factory) {
    const existing = channels.get(name);
    if (existing && existing.instance) { try { supabaseClient.removeChannel(existing.instance); } catch (_) {} } // no doppioni
    const instance = factory();
    channels.set(name, { factory, instance });
    return instance;
}
function _cleanupAllRealtimeChannels() {
    channels.forEach((e) => { if (e && e.instance) { try { supabaseClient.removeChannel(e.instance); } catch (_) {} } });
}
window.addEventListener('beforeunload', _cleanupAllRealtimeChannels);
```
> Nota onesta: in un'app **multi-pagina** (navigazione full-reload) il "leak cross-pagina" è già in gran
> parte mitigato (ogni pagina è un VM nuovo). Il valore vero è la **rivivibilità post-wake**.

---

## 6. Cache-busting (Service Worker)

⚠️ Ad **ogni** deploy di asset, altrimenti gli utenti PWA restano su file vecchi e incoerenti:
1. Bumpa `CACHE_NAME` in `sw.js` (es. `app-v531` → `app-v532`).
2. Aggiorna il `?v=` nei tag `<script>`/`<link>` dei file modificati (tienili **allineati** tra le pagine:
   un disallineamento è esso stesso un bug di cache).
3. Se aggiungi/rinomini un file, aggiornalo nella lista `APP_SHELL` di `sw.js`.

In questo intervento: `sw.js` **v532**, `supabase-client.js?v=6`, `silent-refresh.js?v=3`, `data.js?v=77`,
`org-settings.js?v=3`, `maintenance.js?v=2`, `app-watchdog.js?v=1` (nuovo, anche in APP_SHELL).
`index.html` è servito network-first → coperto dal bump di `CACHE_NAME`.

---

## 7. Fase D — over-fetching / troppe chiamate

> Risposta alla domanda "carico troppi dati / troppe chiamate, influisce?". **Sì, ma è un problema
> DIVERSO** dai freeze: non causa il *blocco duro* (quelli erano deadlock, già risolti) bensì
> **lentezza/jank e amplificazione** — e una UI abbastanza lenta *sembra* freezata, oltre ad aumentare
> le probabilità che una delle tante chiamate in volo si appenda.

### ✅ Applicato: debounce degli handler Realtime in `index.html`
**Problema:** `index.html` (calendario pubblico) era l'unica pagina con gli handler Realtime
**non-debounced**: ad **ogni** evento `bookings`/`app_settings`/`settings` faceva un `syncFromSupabase()`
completo (paginazione + disponibilità) **+** re-render. Su un calendario affollato: una persona prenota
→ *tutti* i client connessi ri-scaricano tutto. In un burst (N prenotazioni nello stesso minuto) →
N sync+render per client. (`prenotazioni.html` e `admin.html` già usavano un debounce 600ms.)

**Fix:** stesso pattern debounce 600ms già usato nelle altre pagine → i burst collassano in **un solo**
sync+render. Aggiunto anche il `.catch` mancante (un errore nel sync non salta più il render).
```js
let _bookingsRtTimer = null;
const _bookingsDebouncedSync = () => {
    clearTimeout(_bookingsRtTimer);
    _bookingsRtTimer = setTimeout(async () => {
        await BookingStorage.syncFromSupabase().catch(e => console.warn('[rt] bookings sync:', e?.message || e));
        _rerender();
    }, 600);
};
// handler: .on('postgres_changes', { table: 'bookings' }, _bookingsDebouncedSync)
```

### 🔎 Osservazioni residue (non applicate — più rischiose, vanno testate)
- **Re-sync completo invece di update incrementale.** Ogni evento Realtime ri-scarica l'intera finestra
  di prenotazioni invece di applicare la singola riga del payload (`payload.new`/`payload.old`).
  ⚠️ Per il calendario pubblico la griglia dipende dagli **aggregati di disponibilità** server-side
  (`get_availability_range`), non dalle righe grezze → l'update incrementale non è banale (serviva
  comunque rinfrescare l'aggregato). Fattibile e ad alto impatto per l'**admin** (cache di righe grezze),
  ma l'admin già fa debounce e la correttezza della dashboard dipende dalla cache completa → da testare.
- **Finestra dati ampia (~150 giorni, −60/+90).** Deliberata (storico "le mie prenotazioni" + stats).
  Restringerla a quella visibile ridurrebbe il payload ma può rompere quelle viste → audit necessario.
- **`select('id,local_id,...')` con ~25 colonne.** Il calendario ne usa poche, ma la stessa cache
  alimenta "le mie prenotazioni"/admin → servirebbe un path di select separato.
- **`ownOnly` su `index.html`.** Non forzato a `true` come in `prenotazioni.html`: lì è voluto perché
  anche gli admin sul calendario devono poter vedere tutte le prenotazioni (con `ownOnly` vedrebbero
  solo le proprie). Cambiarlo richiede verifica RLS + comportamento admin.
- **Skip sync se `document.hidden`.** Evita lavoro per tab in background; sicuro solo se al resume c'è
  comunque un sync (silent-refresh/watchdog/visibilitychange lo fanno) → da confermare per pagina.

### Raccomandazioni (in ordine di impatto/sforzo) se vuoi spingere oltre
1. ~~Debounce TUTTI i sync Realtime~~ ✅ fatto (era già su admin/prenotazioni; ora anche index).
2. **Update incrementale da payload** dove la cache è di righe grezze (admin) — il singolo cambiamento
   più efficace contro "troppe chiamate/troppi dati", ma da testare con cura.
3. **Restringi la finestra** di date a quella mostrata, caricando il resto on-demand.
4. **`select()` mirato** (solo colonne usate dal rendering).
5. **Riduci la churn su localStorage** (scrivi in debounce e solo se cambiato; valuta IndexedDB).
6. **Profila** con DevTools → Performance (long task >50ms su main thread durante sync/render) e
   → Memory (heap/listener che crescono su tab di lunga durata) per **misurare** prima di rifattorizzare.

---

## 8. Fase E — flash branding al refresh (FOUC)

**Sintomo:** al refresh, per qualche secondo si vede il placeholder "IL TUO NOME" e i colori di default
(viola PalestrIA) invece di nome/colori dello studio. È un **FOUC**: l'HTML parte con placeholder + CSS
default, e il branding si applica solo DOPO il `load()` async (round-trip al DB).

**Causa:** `OrgSettings.applyBranding()` gira solo a fine `load()` async, e gli `<script>` di pagina sono
a fondo `<body>` → placeholder e colori default vengono **dipinti prima**.

**Fix (pattern "snapshot pre-paint"):**
1. `applyBranding()` salva uno **snapshot** del branding in una chiave localStorage **stabile**
   (`_brandingSnapshot`, NON namespaced per org).
2. Nuovo `js/branding-boot.js` caricato **sincrono nell'`<head>`** (gira PRIMA del paint): legge lo
   snapshot e applica **colori** su `:root` subito (zero flash viola), favicon/titolo; il **nome** (+logo)
   appena il DOM è pronto, nascondendo `[data-org-name]` con `visibility:hidden` (niente layout shift)
   finché non lo applica → niente flash del placeholder.
3. I valori reali arrivano comunque da `OrgSettings.load()` async, che corregge se cambiati.

```js
// branding-boot.js (in <head>, sincrono):
var snap = JSON.parse(localStorage.getItem('_brandingSnapshot') || 'null');
if (snap) {
    var root = document.documentElement;
    if (snap.color)     root.style.setProperty('--primary-purple', snap.color);       // ← prima del paint
    if (snap.colorDark) root.style.setProperty('--primary-purple-dark', snap.colorDark);
    // nome/logo su DOMContentLoaded; [data-org-name] nascosto via <style> finché non rivelato
}
```
**Chiave del trucco:** lo snapshot è **non namespaced**, così è leggibile in `<head>` PRIMA che `_orgId`
sia noto (che richiede l'auth async). Funziona dal 2º caricamento in poi (alla prima visita assoluta non
c'è ancora branding salvato da mostrare → nessun flash da correggere). Per pagine platform-level (es.
super-admin) NON caricare il boot.

---

## 9. Checklist di test (DevTools)

1. **2 prenotazioni di fila** (anche con Network "Slow 3G") → la 2ª NON si blocca.
2. **Rete morta durante booking** (Network → Offline a metà) → si sblocca con toast entro ~45s.
3. **Idle/sleep-wake** (tab in background >2 min, o sleep del Mac) → riprende da sola; se incastrata,
   log `[watchdog] auto-guarigione` e reload entro ~12s.
4. **Tab aperta a lungo** → le modifiche Realtime si propagano ancora (canali rivivibili); listener
   count stabile (DevTools → Memory).
5. **Burst Realtime** (apri il calendario su 2 tab; prenota più volte rapidamente da una) → l'altra fa
   **un solo** re-render dopo ~600ms, non uno per evento (verifica i log `[rt] bookings sync`).
6. **Flash branding** (Fase E): con uno studio brandizzato (nome + colore custom), **refresha** la
   pagina (Ctrl/Cmd+R) → NON deve comparire "IL TUO NOME" né il viola di default, nemmeno per un istante.
   Testa anche con cache vuota (1ª visita: il placeholder può comparire una volta, poi non più).

---

## 10. Come replicare su un altro progetto

1. **Crea gli helper** `_rpcWithTimeout` / `_queryWithTimeout` (sez. 2) e usali per **ogni** chiamata
   Supabase awaited.
2. **Audita gli `await` nudi:** cerca `await supabaseClient.` e `await q;` e wrappali (o aggiungi
   `.abortSignal(...)` + timer).
3. **Proteggi ogni flag "in-flight"** con un watchdog che lo resetta comunque (sez. C7).
4. **Auth-lock:** se usi una `lock` custom per supabase-js, assicurati che `fn` sia **bounded** anche
   dentro `navigator.locks` (sez. 3). È il fix più importante e meno ovvio.
5. **Aggiungi `app-watchdog.js`** (sez. 4) come backstop di auto-guarigione, adattando la probe.
6. **Realtime via registry** rivivibile (sez. 5).
7. **Service Worker:** `fetch` con timeout (sez. C10) + ricordati il cache-busting (sez. 6).
8. **Debounce gli handler Realtime** (sez. 7) e poi valuta le ottimizzazioni più profonde con il profiler.

> Regola mentale unica: **"nessun `await` senza scadenza; ogni flag/lock si auto-guarisce; un reload
> invisibile come ultima rete di sicurezza."** E per l'efficienza: **collassa i burst (debounce) prima
> di rifattorizzare il modello dati.**

---

## 11. Riepilogo file toccati

| File | Fase | Cosa |
|---|---|---|
| `js/data.js` | A, D | timeout su saveBookingForClient/paginazione/_retryPending/schedule_overrides |
| `js/silent-refresh.js` | A, C | watchdog su refreshInFlight; registry canali (dedup + cleanup beforeunload) |
| `js/supabase-client.js` | A, B | reset cascade flag; `fn` bounded dentro `navigator.locks`; chain non muta |
| `js/app-watchdog.js` | watchdog | **nuovo** — auto-guarigione al resume |
| `js/branding-boot.js` | E | **nuovo** — applica il branding (snapshot) pre-paint in `<head>` |
| `js/maintenance.js` | C | canale registrato nel registry (rivivibile) |
| `js/org-settings.js` | C, E | (C) canale nel registry; (E) salva lo snapshot branding in `applyBranding()` |
| `sw.js` | A, cache | `fetchWithTimeout` Network-First; APP_SHELL + `CACHE_NAME` v533 |
| `index.html` | D | debounce 600ms sugli handler Realtime |
| `*.html` (15 pagine) | E, cache | `<script branding-boot>` in `<head>` (tranne super-admin); bump `?v=` asset |
