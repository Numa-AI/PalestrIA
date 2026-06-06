// Supabase client — shared across all pages that need it
const SUPABASE_URL = 'https://rwaiekhllujximrqftmp.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_SDlyqyh2C78ZlQ42hQJClA_e1LIp2x5';

// Serializzazione intra-tab per-nome usata quando navigator.locks non è
// disponibile oppure quando il lock request va in timeout. Una Promise chain
// garantisce che le operazioni sullo stesso nome vengano eseguite una alla
// volta anche senza Web Locks — niente più "esecuzione senza lock" che
// permetteva refresh concorrenti dell'auth e sessioni incoerenti.
const _authLockChains = new Map();

const FALLBACK_FN_WATCHDOG_MS = 4000; // #7: era 8000 → col token già letto da storage (auth.js #5) il refresh appeso è inutile, mollalo prima (dimezza l'hang al rientro)
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

// #9: sulle pagine admin gestiamo NOI il refresh del token (auth.js _proactiveRefreshTick),
// disabilitando l'auto-refresh INTERNO di supabase-js (timer + suo listener visibilitychange)
// che al rientro da idle si appendeva sul lock auth bloccato. Sulle pagine utente
// (allenamento/prenotazioni) resta l'autoRefresh di supabase-js: lì funziona bene, non si tocca.
// NB: location.pathname.includes('admin.html') copre sia admin.html sia super-admin.html.
const _ADMIN_PAGE = (typeof location !== 'undefined') && location.pathname.includes('admin.html');

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: {
        autoRefreshToken: !_ADMIN_PAGE, // #9: su admin il refresh lo gestiamo noi
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
                const timeout = Math.min(acquireTimeout ?? LOCK_ACQUIRE_MS, LOCK_ACQUIRE_MS);
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

// #9: esposti per il refresh proattivo gestito da noi (auth.js _proactiveRefreshTick).
window._isManagedAuthPage = _ADMIN_PAGE;
window._manualTokenRefresh = function () { return supabaseClient.auth.refreshSession(); };

// Log click on "Andrea Pompili" credit link
function logCreditClick() {
    // Don't preventDefault — let the <a> open normally (critical for iOS PWA)
    const user = window._currentUser;
    supabaseClient.from('click_andrea_pompili').insert({
        user_name:  user?.name  || null,
        user_email: user?.email || null,
        page:       window.location.pathname
    }).then(({ error }) => {
        if (error) console.error('credit-click log failed:', error.message);
    }).catch(err => console.error('credit-click exception:', err));
}
