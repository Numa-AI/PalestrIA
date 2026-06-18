// Supabase client — shared across all pages that need it
const SUPABASE_URL = 'https://rwaiekhllujximrqftmp.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_SDlyqyh2C78ZlQ42hQJClA_e1LIp2x5';

// Serializzazione intra-tab per-nome usata quando navigator.locks non è
// disponibile oppure quando il lock request va in timeout. Una Promise chain
// garantisce che le operazioni sullo stesso nome vengano eseguite una alla
// volta anche senza Web Locks — niente più "esecuzione senza lock" che
// permetteva refresh concorrenti dell'auth e sessioni incoerenti.
const _authLockChains = new Map();

const FALLBACK_FN_WATCHDOG_MS = 2000; // #7→split: 8000→4000→2000. Ormai dal lock passa SOLO l'auth (le query dati usano il client con accessToken, zero lock); un refresh abbandonato dal watchdog continua in background e il poll di ensureValidSession lo raccoglie.
let _watchdogFirings = [];
const WATCHDOG_CASCADE_THRESHOLD = 2;
const WATCHDOG_CASCADE_WINDOW_MS = 60000;
let _cascadeReloadScheduled = false;

function _withFnWatchdog(name, fn) {
    let timer;
    const fnPromise = Promise.resolve().then(fn).finally(() => clearTimeout(timer));
    // Se la fn rifiuta DOPO che il watchdog ha già vinto la race, evita l'unhandled
    // rejection (rumore in console) senza alterare il flusso: la chain è già sbloccata.
    fnPromise.catch(() => {});
    const watchdog = new Promise((resolve) => {
        timer = setTimeout(() => {
            console.warn(`[Supabase Auth] fallback fn() "${name}" oltre ${FALLBACK_FN_WATCHDOG_MS}ms - sblocco la chain`);
            // #4: NON contare il firing né ricaricare se la tab è in background (il lock si
            // sblocca da solo al ritorno in foreground) o se un recovery utente sta già
            // girando (silent-refresh/resume marcano window._userRecoveryDepth): lì il reload
            // è solo disturbo, il recovery graceful recupera da sé. Il safety net "F5 di
            // emergenza" resta attivo SOLO a pagina visibile senza recovery in corso.
            const _suppressReload = (typeof document !== 'undefined' && document.hidden) ||
                                    (typeof window !== 'undefined' && window._userRecoveryDepth > 0);
            if (!_suppressReload) {
                const now = Date.now();
                _watchdogFirings = _watchdogFirings.filter(t => now - t < WATCHDOG_CASCADE_WINDOW_MS);
                _watchdogFirings.push(now);
                if (_watchdogFirings.length >= WATCHDOG_CASCADE_THRESHOLD && !_cascadeReloadScheduled) {
                    _cascadeReloadScheduled = true;
                    console.warn(`[Supabase Auth] cascade rilevata (${_watchdogFirings.length} watchdog in ${WATCHDOG_CASCADE_WINDOW_MS / 1000}s) - ricarico la pagina`);
                    setTimeout(() => {
                        try { window.location.reload(); } catch (_) {}
                    }, 200);
                    // Fallback: se il reload non avviene (bfcache / lifecycle PWA), azzera il
                    // flag dopo 10s così l'auto-recovery può ritentare invece di restare morto.
                    setTimeout(() => {
                        _cascadeReloadScheduled = false;
                        _watchdogFirings = [];
                    }, 10000);
                }
            }
            resolve(undefined);
        }, FALLBACK_FN_WATCHDOG_MS);
    });
    return Promise.race([fnPromise, watchdog]);
}

function _runSerialized(name, fn) {
    const prev = _authLockChains.get(name) || Promise.resolve();
    const wrapped = () => _withFnWatchdog(name, fn);
    const run = prev.then(wrapped, wrapped); // prosegue anche se la precedente è fallita
    // La chain memorizzata non si "avvelena": _withFnWatchdog risolve sempre entro
    // FALLBACK_FN_WATCHDOG_MS, quindi la prossima operazione parte comunque. Logghiamo
    // l'eventuale errore invece di inghiottirlo in silenzio (così è diagnosticabile).
    _authLockChains.set(name, run.catch((e) => {
        console.warn(`[Supabase Auth] chain "${name}" errore (non blocca le successive):`, e && e.message);
    }));
    return run;
}

// Stuck-lock detection: su PWA mobile navigator.locks può restare appeso quando
// l'OS sospende la webview in background. Dopo 2 timeout entro 30s assumiamo il
// lock API rotto e saltiamo direttamente al fallback JS per 60s → niente più
// "ogni chiamata attende 3s di timeout a vuoto".
let _locksBrokenUntil  = 0;
let _recentLockTimeouts = [];
const LOCK_ACQUIRE_MS       = 500;     // era 3000 → troppo alto, blocca l'UI
const LOCKS_BROKEN_WINDOW_MS = 30000;
const LOCKS_BROKEN_PENALTY_MS = 60000;

// ════════════════════════════════════════════════════════════════════════════
// ARCHITETTURA A DUE CLIENT (fix resume lento 11-14s → ~1-2s)
// ────────────────────────────────────────────────────────────────────────────
// Causa radice: ogni query dati di supabase-js (.from/.rpc/.channel/.storage) chiama
// internamente auth.getSession(), che acquisisce il lock auth. Dopo idle/sospensione
// navigator.locks resta appeso (bug PWA iOS/Mac) → ogni query pagava 2×500ms di lock
// timeout + deadlock da rientranza + abbandono dal watchdog. Tre operazioni serializzate
// + retry = 11-14s di resume, con errori "Cannot destructure 'data'".
//
//  • supabaseAuth  → client AUTH: lock custom su navigator.locks + autoRefreshToken:false
//    (refresh gestito da noi, auth.js _proactiveRefreshTick). TUTTO il codice di sessione
//    (getSession/refreshSession/signIn/signOut/onAuthStateChange/...) gira QUI.
//  • supabaseClient → client DATI: opzione accessToken (token letto da localStorage, ZERO
//    lock). Con accessToken il namespace .auth è DISABILITATO e lancia se chiamato.
//    Tutte le query/RPC/Realtime/Storage restano su questo nome (call-site invariati).
//
// #9: autoRefreshToken:false ovunque + refresh proattivo nostro (window._isManagedAuthPage).
const supabaseAuth = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
        autoRefreshToken: false, // #9: il refresh lo gestiamo NOI su tutte le pagine (auth.js _proactiveRefreshTick)
        // Contratto supabase-js:
        //   acquireTimeout === 0 → "non-blocking": se il lock è già preso,
        //     NON aspettare, salta l'operazione. Usato dall'auto-refresh tick
        //     per evitare di accodare tick ridondanti.
        //   acquireTimeout > 0 o assente → blocking con cap.
        lock: async (name, acquireTimeout, fn) => {
            const nonBlocking = acquireTimeout === 0;
            const locksUsable = navigator?.locks && Date.now() > _locksBrokenUntil;

            if (locksUsable) {
                if (nonBlocking) {
                    // ifAvailable: la callback riceve null se il lock è occupato
                    return navigator.locks.request(name, { ifAvailable: true }, (lock) => {
                        if (!lock) return; // occupato → skip, come richiesto
                        return _withFnWatchdog(name, fn);
                    });
                }
                // supabase-js può passare acquireTimeout = -1 ("attendi indefinitamente"):
                // Math.min(-1, 500) darebbe -1 → l'AbortController abortirebbe SUBITO ogni
                // acquisizione e navigator.locks verrebbe marcato "rotto" anche da sano.
                // Accetta solo timeout positivi, altrimenti usa il cap LOCK_ACQUIRE_MS.
                const timeout = (typeof acquireTimeout === 'number' && acquireTimeout > 0)
                    ? Math.min(acquireTimeout, LOCK_ACQUIRE_MS)
                    : LOCK_ACQUIRE_MS;
                const ac = new AbortController();
                const timer = setTimeout(() => ac.abort(), timeout);
                try {
                    // ⚠️ Causa radice del freeze su Mac idle / "alla 2ª prenotazione":
                    // l'AbortController aborta solo l'ATTESA di acquisizione del lock, NON
                    // l'esecuzione di fn una volta acquisito. Se fn (refresh token / RPC
                    // auth) si appende dopo aver preso il lock, lo tiene bloccato per
                    // sempre e ogni operazione successiva muore in coda. Avvolgendo fn nel
                    // watchdog, dopo 8s il lock viene comunque rilasciato e la chain riparte.
                    return await navigator.locks.request(name, { signal: ac.signal }, () => _withFnWatchdog(name, fn));
                } catch (e) {
                    if (e.name !== 'AbortError') throw e;
                    const now = Date.now();
                    _recentLockTimeouts = _recentLockTimeouts.filter(t => now - t < LOCKS_BROKEN_WINDOW_MS);
                    _recentLockTimeouts.push(now);
                    if (_recentLockTimeouts.length >= 2) {
                        _locksBrokenUntil = now + LOCKS_BROKEN_PENALTY_MS;
                        _recentLockTimeouts = [];
                        console.warn(`[Supabase Auth] navigator.locks appeso — disabilito per ${LOCKS_BROKEN_PENALTY_MS/1000}s (uso fallback JS)`);
                    } else {
                        console.warn(`[Supabase Auth] Lock timeout (${timeout}ms) — fallback mutex JS`);
                    }
                } finally {
                    clearTimeout(timer);
                }
            }

            // Fallback senza navigator.locks (o locks temporaneamente disabilitati).
            if (nonBlocking && _authLockChains.has(name)) return;
            return _runSerialized(name, fn);
        }
    }
});

window.supabaseAuth = supabaseAuth;

// #9: esposti per il refresh proattivo gestito da noi (auth.js _proactiveRefreshTick).
// _isManagedAuthPage = true su OGNI pagina → il tick proattivo gira ovunque (non più solo admin).
window._isManagedAuthPage = true;
window._manualTokenRefresh = function () { return supabaseAuth.auth.refreshSession(); };

// ── Token diretto da localStorage (ZERO lock) per il client DATI ──
// Legge la chiave sb-<ref>-auth-token (anche encoding "base64-") e ne estrae l'access_token.
// Ritorna ANCHE un token scaduto: meglio un 401 puntuale dal server che bloccare la query in
// attesa del lock. Logged out → null → supabase-js usa la anon key (identico a prima). Il
// refresh proattivo (auth.js) tiene il token in storage praticamente sempre fresco.
let _lastKnownAccessToken = null;
// Ref del progetto ricavato da SUPABASE_URL (sottodominio prima di .supabase.co):
// usiamo la chiave esatta sb-<ref>-auth-token, mai una wildcard (su origin condivisa
// la wildcard può pescare il token di un altro progetto Supabase).
const _SB_PROJECT_REF = (SUPABASE_URL.match(/^https?:\/\/([^.]+)\.supabase\.co/) || [])[1] || '';
const _SB_AUTH_TOKEN_KEY = `sb-${_SB_PROJECT_REF}-auth-token`;
function _readAccessTokenDirect() {
    try {
        let raw = _SB_PROJECT_REF ? localStorage.getItem(_SB_AUTH_TOKEN_KEY) : null;
        if (!raw) return null; // logged out → anon key
        if (raw.slice(0, 7) === 'base64-') {
            const b64 = raw.slice(7).replace(/-/g, '+').replace(/_/g, '/');
            const bin = atob(b64);
            try { raw = new TextDecoder().decode(Uint8Array.from(bin, c => c.charCodeAt(0))); }
            catch (_) { raw = bin; }
        }
        const parsed = JSON.parse(raw);
        const s = (parsed && parsed.access_token) ? parsed
                : (parsed && (parsed.currentSession || parsed.session)) || null;
        if (s && s.access_token) _lastKnownAccessToken = s.access_token;
        return (s && s.access_token) || null;
    } catch (e) {
        return _lastKnownAccessToken; // localStorage inaccessibile (transitorio)
    }
}

// Client DATI: SOLO accessToken (niente blocco auth:{}, alcune versioni di supabase-js
// rifiutano la combinazione). Tutte le query/RPC/Realtime/Storage girano qui.
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    accessToken: async () => _readAccessTokenDirect()
});
