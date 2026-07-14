// Auth — Supabase Auth
// Sostituisce il vecchio sistema localStorage.
// Mantiene le stesse firme di funzione per compatibilità con il resto dell'app.

// Utente corrente in memoria — popolato da initAuth() all'avvio di ogni pagina
window._currentUser = null;
// Flag per distinguere logout manuale da SIGNED_OUT spurio di Supabase (token scaduto in background PWA)
let _isManualLogout = false;

// ── Phone normalization ───────────────────────────────────────────────────────
// Restituisce il formato E.164 (+39XXXXXXXXXX) per la compatibilità con le API WhatsApp.
// Regole (valutate in quest'ordine):
//   1) prefisso internazionale già presente (+ o 00) → preservalo, non forzare +39;
//   2) numero nazionale con 0 iniziale (fisso, es. 030...) → +39 + numero senza lo 0;
//   3) numero plausibilmente italiano (mobile 9-10 cifre) → antepone +39;
//      ATTENZIONE: i mobile IT iniziano spesso per 3 (e quindi 39, 392, 393...) → NON
//      vanno scambiati per "hanno già il prefisso 39". Si applica +39 SOLO dopo aver
//      validato la lunghezza nazionale; un "39XXXXXXXX" (cellulare che inizia per 39)
//      ottiene quindi +39 39... correttamente, senza perdere le prime due cifre;
//   4) numeri non plausibilmente italiani → restituiti senza forzare +39.
function normalizePhone(raw) {
    if (!raw) return '';
    let n = String(raw).replace(/[\s\-().]/g, '');

    // 1) Già in formato internazionale: preserva.
    if (n.startsWith('+'))   return n;
    if (n.startsWith('00'))  return '+' + n.slice(2);

    // 2) Numero nazionale con 0 iniziale (tipico dei fissi): +39 senza lo 0.
    if (n.startsWith('0'))   return '+39' + n.slice(1);

    // 3) Numero nazionale plausibilmente italiano (9-10 cifre, solo numerico):
    //    es. mobile "3xx xxxxxxx" (10 cifre) o fisso compatto (9-10) → +39.
    if (/^\d{9,10}$/.test(n)) return '+39' + n;

    // 4) Non plausibilmente italiano (lunghezza fuori range): non forzare +39.
    return n;
}

// ── Comune di residenza: normalizzazione title-case italiano ───────────────────
// Alcuni clienti inseriscono il comune tutto minuscolo o tutto maiuscolo. Lo
// normalizziamo a title-case IT: prima lettera di ogni parola maiuscola, ma
// preposizioni/articoli minuscoli se NON prima parola. Es:
//   "sant'ambrogio di valpolicella" → "Sant'Ambrogio di Valpolicella"
//   "reggio nell'emilia"            → "Reggio nell'Emilia"
//   "VERONA"                        → "Verona"
// La regola è replicata IDENTICA lato SQL (funzione normalize_comune nella
// migration 00000000000026) per il backfill dei dati già presenti.
// Connettivi (parole intere) che restano minuscoli se non sono la prima parola:
const _COMUNE_CONN = new Set([
    'di','del','dei','della','delle','dello','degli','da','dal','dai','dalle','dagli','dallo',
    'in','nel','nei','nella','nelle','nello','negli','a','ai','al','alla','alle','allo','agli',
    'e','ed','con','su','sul','sui','sulla','sulle','sullo','sugli','per','tra','fra',
    'la','le','lo','il','i','gli','l'
]);
// Prefissi con apostrofo: minuscolo solo il prefisso, la parte dopo resta maiuscola
// (es. "nell'Emilia"). Ordinati dal più lungo al più corto per un match corretto.
const _COMUNE_CONN_AP = ["dell'", "nell'", "sull'", "dall'", "all'", "d'", "l'"];

function normalizeComune(input) {
    if (!input) return '';
    // 1) apostrofo curvo → dritto, trim, collapse spazi multipli.
    let s = String(input).replace(/[’‘ʼ]/g, "'").trim().replace(/\s+/g, ' ');
    if (!s) return '';
    // 2) title-case: minuscolo tutto, poi maiuscola a inizio/dopo spazio/apostrofo/trattino.
    s = s.toLowerCase().replace(/(^|[\s'\-])([a-zàèéìòùäöüç])/g,
        (_m, sep, ch) => sep + ch.toUpperCase());
    // 3) minuscolo sui connettivi quando NON prima parola.
    const words = s.split(' ');
    for (let i = 1; i < words.length; i++) {
        const w = words[i];
        const lw = w.toLowerCase();
        if (_COMUNE_CONN.has(lw)) { words[i] = lw; continue; }
        for (const ap of _COMUNE_CONN_AP) {
            if (lw.startsWith(ap)) { words[i] = ap + w.slice(ap.length); break; }
        }
    }
    return words.join(' ');
}
window.normalizeComune = normalizeComune;

function isAnagraficaComplete(user) {
    return !!(
        user &&
        String(user.whatsapp || '').trim() &&
        String(user.codice_fiscale || '').trim() &&
        String(user.indirizzo_via || '').trim() &&
        String(user.indirizzo_paese || '').trim() &&
        String(user.indirizzo_cap || '').trim()
    );
}

window.isAnagraficaComplete = isAnagraficaComplete;

// ── Error message mapping ─────────────────────────────────────────────────────
function _authError(error) {
    const msg = error?.message || '';
    if (msg.includes('already registered') || msg.includes('already been registered'))
        return 'Email già registrata.';
    if (msg.includes('Invalid login credentials') || msg.includes('invalid_credentials'))
        return 'Email o password errata.';
    if (msg.includes('Email not confirmed'))
        return 'Controlla la tua email per confermare la registrazione.';
    if (msg.includes('Password should be at least'))
        return 'La password deve essere di almeno 6 caratteri.';
    if (msg.includes('User not found'))
        return 'Email non trovata.';
    return msg || 'Errore sconosciuto. Riprova.';
}

// ── Org context dai claim JWT ─────────────────────────────────────────────────
// Imposta window._orgId / window._orgRole dai claim app_metadata (org_id/org_role)
// e propaga adminAuth a sessionStorage se il ruolo è owner/admin.
// Risoluzione org lato client: window._orgId (autenticato), window._orgSlug (slug pubblico).
async function _applyOrgContext(sessionUser) {
    const meta = sessionUser?.app_metadata || {};
    let orgId   = meta.org_id   || null;
    let orgRole = meta.org_role || null;
    // Fallback se l'auth hook non è attivo (claim org_id/org_role assenti nel JWT):
    // ricava org e ruolo da org_members (la RLS lo consente via current_org_id()).
    if ((!orgId || !orgRole) && sessionUser?.id && typeof supabaseClient !== 'undefined') {
        try {
            const { data: m } = await supabaseClient
                .from('org_members')
                .select('org_id, role')
                .eq('user_id', sessionUser.id)
                .eq('status', 'active')
                .order('created_at', { ascending: true })
                .limit(1)
                .maybeSingle();
            if (m) { orgId = orgId || m.org_id; orgRole = orgRole || m.role; }
        } catch (_) { /* offline / nessuna membership */ }
    }
    window._orgId   = orgId;
    window._orgRole = orgRole;
    const isOrgAdmin = orgRole === 'owner' || orgRole === 'admin';
    if (isOrgAdmin) {
        sessionStorage.setItem('adminAuth', 'true');
    } else {
        // Utente loggato ma non admin: pulisce eventuali flag legacy
        sessionStorage.removeItem('adminAuth');
    }
    return isOrgAdmin;
}

// ── Load profile from Supabase ────────────────────────────────────────────────
// Returns true on success, false on error (does NOT null out _currentUser on error
// to prevent false logouts on transient network failures in PWA).
async function _loadProfile(userId) {
    let profile = null, error = null;
    try {
        const _r = await supabaseClient
            .from('profiles')
            .select('id, name, email, whatsapp, medical_cert_expiry, medical_cert_history, insurance_expiry, insurance_history, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap, documento_firmato, privacy_prenotazioni, created_at')
            .eq('id', userId)
            .maybeSingle();   // owner/staff non hanno riga profiles → null senza errore 406
        profile = _r && _r.data; error = _r && _r.error;
    } catch (e) {
        // #5: query appesa sul lock (tab background) → niente uncaught rpc_timeout nei
        // chiamanti async (onAuthStateChange/visibilitychange). Si ritenta al sync successivo.
        console.warn('[Auth] _loadProfile query fallita (timeout/lock):', e && e.message);
        return false;
    }

    if (profile && !error) {
        window._currentUser = profile;
        // Auto-fix: capitalizza nomi esistenti con lettere minuscole (es. utenti Gmail)
        if (profile.name) {
            const capitalized = profile.name.trim().replace(/\S+/g, w => w[0].toUpperCase() + w.slice(1).toLowerCase());
            if (capitalized !== profile.name) {
                supabaseClient.from('profiles').update({ name: capitalized }).eq('id', userId)
                    .then(() => { window._currentUser.name = capitalized; });
            }
        }
        return true;
    }
    if (error) console.error('[Auth] _loadProfile error:', error.message);
    return false;
}

// ── Refresh centralizzato della sessione ──────────────────────────────────────
// Un solo refresh per volta nella tab: chi arriva mentre è in corso aspetta la
// stessa Promise invece di lanciare refresh paralleli che lasciano la sessione
// in stato incoerente (access_token stale in memoria mentre un altro handler
// scrive il nuovo in storage → PostgREST risponde 401 al prossimo call).
//
// Se la sessione in cache è ancora fresca (>30s al limite), evitiamo del tutto
// la network call.
//
// Ritorna la session o null (refresh fallito/timeout/nessun refresh_token).
let _refreshInFlight = null;

// #5 — Lettura sessione DIRETTA da localStorage, bypassando navigator.locks.
// Su tab in background il lock di supabase-js può bloccarsi → getSession() si appende.
// Qui leggiamo il token salvato (chiave sb-<ref>-auth-token, anche encoding "base64-")
// e validiamo access_token + expires_at. Difensiva: qualunque errore → null → resta il
// comportamento esistente. NON rinfresca: serve solo a evitare il refresh forzato che
// intasa la chain quando una sessione valida è già in storage.
function _readSessionFromStorageDirect() {
    try {
        let raw = null;
        // L4: pinna il ref del progetto ricavandolo da SUPABASE_URL (sottodominio prima
        // di .supabase.co) e costruisci la chiave esatta sb-<ref>-auth-token. Su origin
        // condivisa la regex wildcard poteva prendere il token del progetto sbagliato.
        let projectRef = null;
        try {
            if (typeof SUPABASE_URL !== 'undefined') {
                const host = new URL(SUPABASE_URL).hostname; // <ref>.supabase.co
                projectRef = host.split('.')[0] || null;
            }
        } catch (_) {}
        if (projectRef) {
            raw = localStorage.getItem(`sb-${projectRef}-auth-token`);
        }
        // Fallback: se la chiave pinnata non è presente, ripiega sulla scansione wildcard.
        if (!raw) {
            for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i);
                if (k && /^sb-.*-auth-token$/.test(k)) { raw = localStorage.getItem(k); break; }
            }
        }
        if (!raw) return null;
        if (raw.startsWith('base64-')) {
            // H2: decode UTF-8 robusto (TextDecoder) — niente atob() nudo che corromperebbe
            // silenziosamente caratteri non-ASCII facendo poi fallire JSON.parse.
            try {
                const _bytes = Uint8Array.from(atob(raw.slice(7)), c => c.charCodeAt(0));
                raw = new TextDecoder('utf-8').decode(_bytes);
            } catch (e) {
                console.warn('[Auth] _readSessionFromStorageDirect: base64 decode fallito:', e && e.message);
                return null;
            }
        }
        const obj = JSON.parse(raw);
        const session = obj && (obj.access_token ? obj : (obj.currentSession || obj.session)) || null;
        // H1: valida ANCHE refresh_token — senza, un access_token futuro ma con refresh_token
        // revocato (es. cambio password su altro device) verrebbe letto come "fresco" → il
        // refresh poi fallisce con ~12s di hang. Richiedere refresh_token fa fail-fast.
        if (session && session.access_token && session.expires_at && session.refresh_token) return session;
        return null;
    } catch (e) { console.warn('[Auth] _readSessionFromStorageDirect parse error:', e && e.message); return null; }
}

// Strategia fail-closed:
//   1. getSession() (storage, no lock contention) → se fresco, return
//   2. Se c'è un refresh in-flight, attendi con CAP separato; se supera il cap,
//      non rimanere in limbo → leggi storage e se non valido ritorna null.
//   3. Avvia refresh manuale con timeout.
//   4. Se timeout, polla getSession (auto-refresh interno può aver completato).
//   5. Se ancora niente → sessione persa: signOut locale, evento auth:session-lost,
//      ritorna null. Il chiamante chiede un relogin.
async function ensureValidSession({ timeoutMs = 12000, force = false } = {}) {
    const readSession = async () => {
        try {
            // getSession() con cap 3s: se il lock è bloccato (tab background) si appende.
            // Allo scadere → lettura diretta da localStorage (#5), niente refresh forzato.
            const TIMEOUT = Symbol('getSession-timeout');
            const r = await Promise.race([
                supabaseAuth.auth.getSession().then(({ data }) => (data && data.session) || null),
                new Promise(res => setTimeout(() => res(TIMEOUT), 3000)),
            ]);
            if (r !== TIMEOUT) return r;
            const direct = _readSessionFromStorageDirect();
            if (direct) console.warn('[Auth] readSession: getSession timeout → sessione diretta da localStorage');
            return direct;
        } catch (_) { return _readSessionFromStorageDirect(); }
    };
    const isFresh = (s, minLeftSec = 30) => {
        if (!s?.access_token || !s.expires_at) return false;
        return s.expires_at - Math.floor(Date.now() / 1000) > minLeftSec;
    };

    // Step 1 — storage
    const stored = await readSession();
    if (!force && isFresh(stored)) {
        console.log(`[Auth] ensureValidSession: storage OK (expires in ${stored.expires_at - Math.floor(Date.now()/1000)}s)`);
        return stored;
    }

    // Pre-check: se non c'è proprio una sessione in storage, NON è una "scadenza"
    // — è un utente non autenticato (es. su /login.html). Non ha senso tentare un
    // refresh (non c'è refresh_token) né scatenare il fail-closed che mostra il
    // toast "Sessione scaduta". Bail silenzioso.
    if (!stored) {
        console.log('[Auth] ensureValidSession: nessuna sessione in storage → null silenzioso');
        return null;
    }

    // Step 2 — in-flight: attendi con cap, poi fallback getSession
    if (_refreshInFlight) {
        console.log('[Auth] ensureValidSession: refresh già in corso, attendo (cap)');
        const TIMEOUT = Symbol('wait-timeout');
        const r = await Promise.race([
            _refreshInFlight,
            new Promise(resolve => setTimeout(() => resolve(TIMEOUT), timeoutMs)),
        ]);
        if (r !== TIMEOUT) {
            console.log(r?.access_token
                ? '[Auth] ensureValidSession: in-flight completato con sessione'
                : '[Auth] ensureValidSession: in-flight completato senza sessione');
            return r;
        }
        console.warn('[Auth] ensureValidSession: attesa in-flight oltre cap, provo getSession');
        const s = await readSession();
        if (isFresh(s, 0)) {
            console.log('[Auth] ensureValidSession: recuperato via getSession dopo cap');
            return s;
        }
        console.warn('[Auth] ensureValidSession: nessuna sessione dopo cap → null');
        return null;
    }

    // Step 3 — nuovo refresh manuale
    _refreshInFlight = (async () => {
        const t0 = performance.now();
        console.log(`[Auth] ensureValidSession: refresh manuale avviato (force=${force}, timeout=${timeoutMs}ms)`);
        try {
            const refreshP = supabaseAuth.auth.refreshSession();
            const timeoutP = new Promise((_, reject) =>
                setTimeout(() => reject(new Error('refresh timeout')), timeoutMs)
            );
            const _res = await Promise.race([refreshP, timeoutP]);
            const { data, error } = _res || {}; // #5: niente "Cannot destructure 'data'" se la race risolve undefined
            if (error) throw error;
            if (data?.session?.access_token) {
                console.log(`[Auth] ensureValidSession: refresh OK in ${Math.round(performance.now() - t0)}ms`);
                return data.session;
            }
            console.warn('[Auth] ensureValidSession: refresh completato senza sessione');
        } catch (e) {
            console.warn(`[Auth] ensureValidSession: refresh fallito (${Math.round(performance.now() - t0)}ms): ${e.message}`);
        } finally {
            _refreshInFlight = null;
        }

        // Step 4 — polling storage (auto-refresh interno può essere arrivato)
        for (let i = 1; i <= 3; i++) {
            await new Promise(r => setTimeout(r, 400));
            const s = await readSession();
            if (isFresh(s, 0)) {
                console.log(`[Auth] ensureValidSession: recuperato via getSession (poll ${i})`);
                return s;
            }
        }

        // Step 5 — FAIL-CLOSED: sessione persa, forza relogin
        console.warn('[Auth] ensureValidSession: FAIL-CLOSED — signOut locale, relogin richiesto');
        _isManualLogout = true; // previene loop di "SIGNED_OUT spurio → recovery"
        try { await supabaseAuth.auth.signOut({ scope: 'local' }); } catch (_) {}
        window._currentUser = null;
        sessionStorage.removeItem('adminAuth');
        try { window.dispatchEvent(new CustomEvent('auth:session-lost')); } catch (_) {}
        try { if (typeof updateNavAuth === 'function') updateNavAuth(); } catch (_) {}
        return null;
    })();

    return _refreshInFlight;
}

window.ensureValidSession = ensureValidSession;

// #9 — Refresh PROATTIVO del token, gestito da noi, su TUTTE le pagine (supabase-client ha
// messo autoRefreshToken:false ovunque, non più solo admin). L'auto-refresh interno di supabase-js
// si appendeva sul lock al rientro da idle; rinnovando noi a tempo controllato (token vicino
// alla scadenza, a pagina VISIBILE, quando l'utente NON sta scrivendo) si evita il clog.
// A pagina nascosta non rinnoviamo: il recupero avviene al foreground via ensureValidSession (#5).
// Gate: window._isManagedAuthPage (ora = true su ogni pagina).
(function _initProactiveTokenRefresh() {
    if (typeof window === 'undefined' || !window._isManagedAuthPage) return;
    var REFRESH_BEFORE_SEC = 5 * 60;  // rinnova se mancano < 5 min alla scadenza
    var FORCE_BELOW_SEC    = 90;      // sotto 90s rinnova comunque (anche se "occupato")
    var _busy = false;
    var _failCount = 0, _lastFailTs = 0;

    // B4: traccia i fallimenti del refresh proattivo. Escala a "sessione persa" SOLO se il
    // token è ormai criticamente basso (sta per scadere) E il refresh continua a fallire →
    // evita prompt di relogin prematuri su fallimenti transitori mentre il token è ancora valido.
    function _registerFail(msg, leftSec) {
        var now = Date.now();
        if (now - _lastFailTs > 10 * 60 * 1000) _failCount = 0; // reset finestra 10 min
        _failCount++; _lastFailTs = now;
        console.warn('[Auth] refresh proattivo fallito (' + _failCount + ', left=' + leftSec + 's): ' + (msg || ''));
        if (_failCount >= 2 && leftSec <= FORCE_BELOW_SEC) {
            console.warn('[Auth] refresh proattivo: token critico e refresh fallito → segnalo sessione persa');
            try { window.dispatchEvent(new CustomEvent('auth:session-lost')); } catch (_) {}
        }
    }

    async function _tick() {
        if (_busy) return;
        if (typeof document !== 'undefined' && document.hidden) return; // niente refresh a tab nascosta
        var session = (typeof _readSessionFromStorageDirect === 'function') ? _readSessionFromStorageDirect() : null;
        if (!session || !session.expires_at) return;
        var leftSec = session.expires_at - Math.floor(Date.now() / 1000);
        if (leftSec > REFRESH_BEFORE_SEC) return; // ancora lontano dalla scadenza
        if (leftSec > FORCE_BELOW_SEC) {
            // Rimanda se il trainer sta scrivendo in un campo.
            var ae = document.activeElement;
            var typing = !!ae && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA' || ae.isContentEditable);
            if (typing) { console.log('[Auth] refresh proattivo rimandato (occupato), left=' + leftSec + 's'); return; }
        }
        if (typeof window._manualTokenRefresh !== 'function') return;
        _busy = true;
        try {
            console.log('[Auth] refresh proattivo token (left=' + leftSec + 's)');
            // refreshSession() risolve {data,error} (NON lancia su errore auth): controlla
            // l'esito per distinguere successo da fallimento (B4).
            var _r = await window._manualTokenRefresh();
            if (_r && _r.data && _r.data.session && _r.data.session.access_token && !_r.error) {
                _failCount = 0; // successo → azzera
            } else {
                _registerFail(_r && _r.error && _r.error.message, leftSec);
            }
        } catch (e) {
            _registerFail(e && e.message, leftSec);
        } finally {
            _busy = false;
        }
    }

    setInterval(_tick, 60000);  // ogni 60s
    setTimeout(_tick, 15000);   // primo check dopo il boot
})();

// Handler globale per fail-closed: mostra messaggio chiaro all'utente invece
// di lasciare la pagina in stato ambiguo. Registrato una sola volta.
if (!window._authSessionLostHandlerActive) {
    window._authSessionLostHandlerActive = true;
    window.addEventListener('auth:session-lost', () => {
        if (window._authSessionLostNotified) return;
        window._authSessionLostNotified = true;
        try {
            if (typeof showToast === 'function') {
                showToast('Sessione scaduta. Effettua di nuovo l\'accesso.', 'error', 5000);
            }
        } catch (_) {}
        // Redirect al login dopo breve delay (lascia leggere il toast).
        setTimeout(() => {
            const onLogin = location.pathname.endsWith('/login.html') || location.pathname.endsWith('/') || location.pathname.endsWith('/index.html');
            if (!onLogin) location.href = 'login.html';
        }, 1500);
    });
}

// ── Init: recupera la sessione e carica il profilo ────────────────────────────
// Chiamata su ogni pagina prima di qualsiasi operazione auth.
// Ritorna la sessione Supabase (o null).
// Usa INITIAL_SESSION invece di getSession() per evitare la race condition
// in PWA: getSession() può tornare null mentre il refresh del token è in corso,
// INITIAL_SESSION si risolve solo dopo che il refresh è completato.
let _authListenerActive = false;
async function initAuth() {
    const session = await new Promise((resolve) => {
        let resolved = false;
        const { data: { subscription } } = supabaseAuth.auth.onAuthStateChange((event, session) => {
            if (event === 'INITIAL_SESSION' && !resolved) {
                resolved = true;
                subscription.unsubscribe();
                resolve(session);
            }
        });
        // Fallback: se INITIAL_SESSION non arriva entro 6s, risolviamo tramite
        // ensureValidSession — unica fonte di verità, valida il token e
        // all'occorrenza forza un refresh (evita di accettare sessioni stale da
        // getSession diretto con expires_at futuro ma token revocato).
        setTimeout(async () => {
            if (!resolved) {
                resolved = true;
                subscription.unsubscribe();
                const recovered = await ensureValidSession().catch(() => null);
                resolve(recovered || null);
            }
        }, 6000);
    });

    if (session) {
        // _loadProfile (query profiles) e _applyOrgContext (claim org, con eventuale
        // fallback org_members) sono INDIPENDENTI: girano in parallelo per non pagare
        // due round-trip in serie sul path della gate "verifica accesso". _applyOrgContext
        // non tocca _currentUser, quindi il fallback metadata sotto resta corretto.
        const [ok] = await Promise.all([
            _loadProfile(session.user.id),
            _applyOrgContext(session.user),   // imposta org context + propaga adminAuth
        ]);
        if (!ok && !window._currentUser) {
            // Fallback: profilo non trovato (trigger fallito) — usa user_metadata
            const meta = session.user.user_metadata || {};
            window._currentUser = {
                id:              session.user.id,
                email:           session.user.email || meta.email || '',
                name:            meta.full_name || meta.name || session.user.email || '',
                whatsapp:        meta.whatsapp || '',
                codice_fiscale:  meta.codice_fiscale || null,
                indirizzo_via:   meta.indirizzo_via || null,
                indirizzo_paese: meta.indirizzo_paese || null,
                indirizzo_cap:   meta.indirizzo_cap || null,
                medical_cert_expiry: null,
                insurance_expiry:    null,
            };
        }
    } else {
        window._currentUser = null;
        window._orgId = null;
        window._orgRole = null;
        sessionStorage.removeItem('adminAuth');
    }
    // Rimuovi sempre il vecchio flag localStorage (era persistente a vita, causa di falsi positivi)
    localStorage.removeItem('adminAuthenticated');

    // Registra il listener persistente una sola volta (evita duplicati su bfcache restore)
    if (!_authListenerActive) {
        _authListenerActive = true;
        supabaseAuth.auth.onAuthStateChange(async (event, session) => {
            if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
                // Reset del flag: se un precedente fail-closed l'aveva alzato,
                // un login/refresh riuscito lo riabbassa così futuri SIGNED_OUT
                // spuri potranno di nuovo tentare la recovery.
                _isManualLogout = false;
                if (session) {
                    await _loadProfile(session.user.id);
                    await _applyOrgContext(session.user);
                }
            } else if (event === 'SIGNED_OUT') {
                if (_isManualLogout) {
                    // Logout esplicito: pulisci tutto
                    window._currentUser = null;
                    window._orgId = null;
                    window._orgRole = null;
                    sessionStorage.removeItem('adminAuth');
                } else {
                    // SIGNED_OUT spurio (token refresh fallito, race condition Supabase)
                    // NON nullificare _currentUser — tenta il recupero della sessione
                    console.warn('[Auth] SIGNED_OUT spurio — tentativo di recupero sessione');
                    (async () => {
                        const recovered = await ensureValidSession();
                        if (recovered) {
                            await _loadProfile(recovered.user.id);
                            await _applyOrgContext(recovered.user);
                            console.log('[Auth] Sessione recuperata dopo SIGNED_OUT spurio');
                        } else {
                            // Refresh fallito definitivamente — sessione realmente persa
                            window._currentUser = null;
                            window._orgId = null;
                            window._orgRole = null;
                            sessionStorage.removeItem('adminAuth');
                        }
                        updateNavAuth();
                    })();
                    return; // Non chiamare updateNavAuth() qui — lo fa l'async sopra
                }
            }
            updateNavAuth();
        });
    }

    // Quando l'app PWA torna in foreground dopo un periodo in background,
    // ri-valida la sessione e ri-sincronizza i dati se è passato abbastanza tempo.
    if (!window._visibilityAuthActive) {
        window._visibilityAuthActive = true;
        let _lastHiddenAt = 0;
        document.addEventListener('visibilitychange', async () => {
            if (document.hidden) { _lastHiddenAt = Date.now(); return; }
            // Ri-sincronizza solo se l'app è stata in background per almeno 30 secondi
            const bgSeconds = _lastHiddenAt ? (Date.now() - _lastHiddenAt) / 1000 : 0;
            // Attendi che il lock Supabase si liberi prima di tentare il refresh
            await new Promise(r => setTimeout(r, 500));
            const session = await ensureValidSession();
            if (session) {
                await _loadProfile(session.user.id);
                await _applyOrgContext(session.user);
            }
            updateNavAuth();

            // Ri-sincronizza dati dopo background prolungato (≥2min)
            if (bgSeconds >= 120 && typeof BookingStorage !== 'undefined') {
                console.log(`[Auth] App in foreground dopo ${Math.round(bgSeconds)}s — re-sync dati`);
                try {
                    await BookingStorage.syncFromSupabase();
                } catch (e) {
                    console.warn('[Auth] re-sync foreground fallito:', e.message);
                }
            }
        });
    }

    updateNavAuth();
    return session;
}

// ── Session accessors (sync — usa il valore cached da initAuth) ───────────────
function getCurrentUser() {
    return window._currentUser;
}

// ── Login event tracking (device fingerprint) ────────────────────────────────
// Scrive una riga in login_events a ogni login/signup esplicito. Fail-silent:
// qualsiasi errore (RLS, rete, tabella mancante) non deve bloccare il login.
async function _trackLoginEvent(userId, eventType) {
    if (!userId) return;
    try {
        const ua = navigator.userAgent || '';
        const platform =
            /iPad|iPhone|iPod/.test(ua) ? 'ios' :
            /Android/i.test(ua) ? 'android' :
            /Windows/i.test(ua) ? 'windows' :
            /Macintosh|Mac OS X/.test(ua) ? 'mac' :
            /Linux/i.test(ua) ? 'linux' : 'other';
        const browser =
            /Edg\//.test(ua) ? 'edge' :
            /OPR\/|Opera/.test(ua) ? 'opera' :
            /Chrome\//.test(ua) ? 'chrome' :
            /Firefox\//.test(ua) ? 'firefox' :
            /Safari\//.test(ua) ? 'safari' : 'other';
        const screen_size = `${screen.width}x${screen.height}`;
        const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
        const language = navigator.language || '';
        const is_pwa = window.matchMedia('(display-mode: standalone)').matches
                    || window.navigator.standalone === true;
        // Hash stabile del device: ua + screen + timezone + language
        const fpData = new TextEncoder().encode(`${ua}|${screen_size}|${timezone}|${language}`);
        const hashBuf = await crypto.subtle.digest('SHA-256', fpData);
        const device_hash = Array.from(new Uint8Array(hashBuf))
            .map(b => b.toString(16).padStart(2, '0')).join('');

        await supabaseClient.from('login_events').insert({
            org_id: window._orgId || null,
            user_id: userId,
            event: eventType || 'login',
            event_type: eventType || 'login',
            device_hash,
            user_agent: ua.slice(0, 500),
            platform,
            browser,
            screen_size,
            timezone,
            language,
            is_pwa,
        });
    } catch (e) {
        console.warn('[Auth] trackLoginEvent skipped:', e?.message || e);
    }
}

// ── Register ──────────────────────────────────────────────────────────────────
// Il profilo viene creato automaticamente dal trigger handle_new_user su auth.users.
// Passiamo nome e whatsapp come user_metadata così il trigger li riceve.
async function registerUser(name, email, whatsapp, password, codiceFiscale, indirizzo) {
    // Controlla se il numero WhatsApp è già usato da un altro utente
    if (whatsapp) {
        const { data: taken } = await supabaseClient.rpc('is_whatsapp_taken', { phone: whatsapp });
        if (taken) return { ok: false, error: 'Questo numero WhatsApp è già associato a un altro account.' };
    }

    const capitalized = (name || '').trim().replace(/\S+/g, w => w[0].toUpperCase() + w.slice(1).toLowerCase());
    const addr = indirizzo || {};

    // La org del cliente si risolve dallo slug pubblico (URL/sottodominio).
    // SENZA org_slug, handle_new_user NON crea il profilo (l'account nascerebbe
    // orfano: current_org_id() null, RLS non mostra nulla). Quindi è obbligatorio.
    const orgSlug = window._orgSlug
        || (typeof _resolveOrgSlug === 'function' ? _resolveOrgSlug() : null);
    if (!orgSlug) {
        return { ok: false, error: 'Studio non identificato. Apri il link di registrazione del tuo studio (es. ?org=nome-studio) e riprova.' };
    }

    // Verifica che lo studio ESISTA davvero PRIMA di creare l'account: se lo slug
    // non corrisponde a nessuna org, handle_new_user non crea il profilo e l'utente
    // nascerebbe orfano (nessuna palestra). Meglio bloccare qui con un errore chiaro.
    try {
        const { data: orgCheck } = await supabaseClient.rpc('get_public_org_settings', { p_org_slug: orgSlug });
        if (!orgCheck || Object.keys(orgCheck).length === 0) {
            return { ok: false, error: `Palestra non riconosciuta (codice "${orgSlug}"). Controlla il link di invito del tuo studio.` };
        }
    } catch (_) {
        return { ok: false, error: 'Impossibile verificare lo studio in questo momento. Riprova tra qualche istante.' };
    }

    const { data, error } = await supabaseAuth.auth.signUp({
        email,
        password,
        options: {
            emailRedirectTo: new URL('login.html', window.location.href).href,
            data: {
                signup_type: 'client',
                org_slug: orgSlug,
                full_name: capitalized,
                whatsapp,
                codice_fiscale: (codiceFiscale || '').toUpperCase() || null,
                indirizzo_via: addr.via || null,
                indirizzo_paese: normalizeComune(addr.paese) || null,
                indirizzo_cap: addr.cap || null,
            }
        }
    });
    if (error) return { ok: false, error: _authError(error) };
    if (!data.user?.id) return { ok: false, error: 'Errore durante la registrazione.' };

    // Il trigger handle_new_user crea il profilo lato server in modo sincrono.
    // Rete di sicurezza: se la sessione è già attiva (conferma email OFF) ma il
    // profilo/org non risulta (slug non risolto server-side, race), tenta il join
    // idempotente. join_organization fa ON CONFLICT DO NOTHING: innocuo se già fatto.
    if (data.session) {
        try { await supabaseClient.rpc('join_organization', { p_org_slug: orgSlug }); }
        catch (e) { console.warn('[Auth] join_organization safety-net skipped:', e?.message || e); }
    }

    // onAuthStateChange (SIGNED_IN) caricherà il profilo non appena la sessione è pronta.
    _trackLoginEvent(data.user.id, 'signup');
    return { ok: true };
}

// ── Login con email + password ────────────────────────────────────────────────
async function loginWithPassword(email, password) {
    const { data, error } = await supabaseAuth.auth.signInWithPassword({ email, password });
    if (error) return { ok: false, error: _authError(error) };
    await _loadProfile(data.user.id);
    await _applyOrgContext(data.user);
    _trackLoginEvent(data.user.id, 'login');
    return { ok: true };
}

// ── Logout ────────────────────────────────────────────────────────────────────
async function logoutUser() {
    // Pulisce stato locale PRIMA di attendere Supabase — così l'UX non si blocca
    // se il token è scaduto o la rete è lenta
    _isManualLogout = true;
    window._currentUser = null;
    localStorage.removeItem('adminAuthenticated');
    sessionStorage.removeItem('adminAuth');

    // ── Teardown completo dello stato per-tenant (H2: bleed cross-tenant su device
    //    condiviso). PRIMA i reset in-memory/localStorage, POI il signOut esistente.
    //    Tutto best-effort: un errore non deve bloccare il logout/redirect.
    // Svuota cache in memoria booking/utenti
    try { BookingStorage._cache = []; } catch (_) {}
    // Snapshot bookings persistito cross-pagina (contiene PII se admin) → via dal device condiviso
    try { BookingStorage._clearPersistedCache(); } catch (_) {}
    try { UserStorage._cache = []; } catch (_) {}
    // Invalida la cache override (namespaced per org): evita bleed tra account diversi
    try { BookingStorage._scheduleOverridesCache = null; BookingStorage._scheduleOverridesCacheOrg = null; } catch (_) {}
    // gym_stats: ledger statistiche locale → rimuovi da localStorage + reset cache
    try { if (typeof BookingStorage.clearStats === 'function') BookingStorage.clearStats(); } catch (_) {}
    // _availabilityByKey: capienze/posti residui server-authoritative → reset Map/oggetto
    try { if (typeof BookingStorage.clearAvailability === 'function') BookingStorage.clearAvailability(); } catch (_) {}
    // Schede + log allenamento: cache in memoria + localStorage TTL (admin e client)
    try { if (typeof WorkoutPlanStorage !== 'undefined' && WorkoutPlanStorage.clearCache) WorkoutPlanStorage.clearCache(); } catch (_) {}
    try { if (typeof WorkoutLogStorage !== 'undefined' && WorkoutLogStorage.clearCache) WorkoutLogStorage.clearCache(); } catch (_) {}
    // Push: rimuove backup locale + unsubscribe best-effort
    try { if (typeof teardownPushOnLogout === 'function') await teardownPushOnLogout(); } catch (_) {}
    // OrgSettings: svuota cache, chiavi localStorage org_* correnti, canale Realtime
    try { if (typeof OrgSettings !== 'undefined' && OrgSettings.reset) OrgSettings.reset(); } catch (_) {}
    // Branding snapshot (chiave unica non namespaced): evita flash brand di A su B
    try { localStorage.removeItem('_brandingSnapshot'); } catch (_) {}

    // Pulisce il contesto org (claim app_metadata)
    window._orgId = null;
    window._orgRole = null;
    window._orgSlug = null;
    // signOut con timeout: se Supabase non risponde entro 3s, procedi comunque
    try {
        await Promise.race([
            supabaseAuth.auth.signOut({ scope: 'local' }),
            new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 3000))
        ]);
    } catch { /* sessione locale già pulita, il token scadrà da solo */ }
}

// ── Aggiorna profilo ──────────────────────────────────────────────────────────
// updates: { name?, email?, whatsapp?, certificatoMedicoScadenza?, assicurazioneScadenza? }
// newPassword: stringa opzionale
async function updateUserProfile(currentEmail, updates, newPassword) {
    const user = getCurrentUser();
    if (!user) return { ok: false, error: 'Non autenticato.' };

    const profileUpdate = {};
    let emailPendingConfirmation = false;

    if (updates.name     !== undefined) profileUpdate.name     = (updates.name || '').trim().replace(/\S+/g, w => w[0].toUpperCase() + w.slice(1).toLowerCase());
    if (updates.whatsapp !== undefined) {
        profileUpdate.whatsapp = updates.whatsapp;
        // Controlla che il numero non sia già usato da un altro utente
        if (updates.whatsapp && updates.whatsapp !== (user.whatsapp || '')) {
            const { data: taken } = await supabaseClient.rpc('is_whatsapp_taken', { phone: updates.whatsapp, exclude_user_id: user.id });
            if (taken) return { ok: false, error: 'Questo numero WhatsApp è già associato a un altro account.' };
        }
    }
    // Email: aggiorna nel profilo SOLO se non è cambiata (altrimenti aspettiamo la conferma)
    if (updates.email !== undefined && updates.email.toLowerCase() === currentEmail.toLowerCase()) {
        profileUpdate.email = updates.email.toLowerCase();
    }

    // Codice fiscale
    if (updates.codiceFiscale !== undefined) {
        profileUpdate.codice_fiscale = (updates.codiceFiscale || '').toUpperCase() || null;
    }

    // Indirizzo di residenza
    if (updates.indirizzoVia !== undefined)   profileUpdate.indirizzo_via   = updates.indirizzoVia || null;
    if (updates.indirizzoPaese !== undefined) profileUpdate.indirizzo_paese = normalizeComune(updates.indirizzoPaese) || null;
    if (updates.indirizzoCap !== undefined)   profileUpdate.indirizzo_cap   = updates.indirizzoCap || null;

    // Certificato medico: aggiorna scadenza e mantieni storico
    if (updates.certificatoMedicoScadenza !== undefined) {
        const newScad = updates.certificatoMedicoScadenza || null;
        if (newScad !== (user.medical_cert_expiry || null)) {
            profileUpdate.medical_cert_expiry = newScad;
            const history = Array.isArray(user.medical_cert_history) ? [...user.medical_cert_history] : [];
            history.push({ scadenza: newScad, aggiornatoIl: new Date().toISOString() });
            profileUpdate.medical_cert_history = history;
        }
    }

    // Assicurazione: aggiorna scadenza e mantieni storico
    if (updates.assicurazioneScadenza !== undefined) {
        const newScad = updates.assicurazioneScadenza || null;
        if (newScad !== (user.insurance_expiry || null)) {
            profileUpdate.insurance_expiry = newScad;
            const history = Array.isArray(user.insurance_history) ? [...user.insurance_history] : [];
            history.push({ scadenza: newScad, aggiornatoIl: new Date().toISOString() });
            profileUpdate.insurance_history = history;
        }
    }

    // Privacy prenotazioni
    if (updates.privacyPrenotazioni !== undefined) {
        profileUpdate.privacy_prenotazioni = updates.privacyPrenotazioni;
    }

    // Aggiorna profilo su Supabase (upsert: crea il profilo se il trigger handle_new_user non l'ha fatto)
    if (Object.keys(profileUpdate).length > 0) {
        // Garantisci che name e email siano sempre presenti per l'upsert (colonne NOT NULL)
        const upsertData = {
            id: user.id,
            name: user.name || updates.name || '',
            email: (user.email || updates.email || '').toLowerCase(),
            // org_id è NOT NULL + richiesto dalla RLS: senza, l'INSERT del profilo fallisce (403)
            ...(window._orgId ? { org_id: window._orgId } : {}),
            ...profileUpdate
        };
        const { error } = await supabaseClient
            .from('profiles')
            .upsert(upsertData);
        if (error) return { ok: false, error: error.message };
    }

    // Cambio email su Supabase Auth (richiede conferma via email — NON aggiorniamo il profilo subito)
    if (updates.email && updates.email.toLowerCase() !== currentEmail.toLowerCase()) {
        const { error } = await supabaseAuth.auth.updateUser({ email: updates.email });
        if (error) return { ok: false, error: error.message };
        emailPendingConfirmation = true;
    }

    // Cambio password su Supabase Auth
    if (newPassword) {
        const { error } = await supabaseAuth.auth.updateUser({ password: newPassword });
        if (error) return { ok: false, error: error.message };
    }

    // Aggiorna subito in memoria così i dati sono disponibili anche se _loadProfile fallisce
    if (window._currentUser) {
        Object.assign(window._currentUser, profileUpdate);
    }
    // Ricarica profilo dal server (sovrascrive con dati autorevoli)
    await _loadProfile(user.id);

    // Sincronizza cert/assic nella cache UserStorage (letto da admin.js)
    if (profileUpdate.medical_cert_expiry !== undefined || profileUpdate.insurance_expiry !== undefined) {
        try {
            const gymUsers = UserStorage._cache;
            const email = (updates.email || user.email || '').toLowerCase();
            let idx = gymUsers.findIndex(u => u.email?.toLowerCase() === email);
            if (idx === -1 && user.whatsapp) {
                const normWa = user.whatsapp;
                idx = gymUsers.findIndex(u => u.whatsapp === normWa);
            }
            if (idx !== -1) {
                if (profileUpdate.medical_cert_expiry !== undefined)
                    gymUsers[idx].certificatoMedicoScadenza = profileUpdate.medical_cert_expiry;
                if (profileUpdate.insurance_expiry !== undefined)
                    gymUsers[idx].assicurazioneScadenza = profileUpdate.insurance_expiry;
            }
        } catch {}
    }

    return { ok: true, emailPendingConfirmation };
}

// ── Le mie prenotazioni ───────────────────────────────────────────────────────
// Legge ancora da localStorage finché non migriamo bookings (Fase 3).
function getUserBookings() {
    const user = getCurrentUser();
    if (!user) return { upcoming: [], past: [] };

    const allBookings = BookingStorage.getAllBookings();
    const now   = new Date();
    const today = _localDateStr();

    const myPhone = user.whatsapp ? normalizePhone(user.whatsapp) : '';
    const mine = allBookings.filter(b => {
        // Match primario: user_id (più affidabile, non cambia con nome/email/telefono)
        if (b.userId && user.id && b.userId === user.id) return true;
        // Fallback: email (per prenotazioni vecchie senza user_id)
        if (!user.email || !b.email) return false;
        if (b.email.toLowerCase() !== user.email.toLowerCase()) return false;
        if (myPhone && b.whatsapp && normalizePhone(b.whatsapp) !== myPhone) return false;
        return true;
    });

    function isBookingPast(b) {
        if (b.date < today) return true;
        if (b.date > today) return false;
        const endTimeStr = b.time ? b.time.split(' - ')[1]?.trim() : null;
        if (!endTimeStr) return false;
        const [h, m] = endTimeStr.split(':').map(Number);
        const endDt = new Date(`${b.date}T${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:00`);
        return endDt <= now;
    }

    return {
        upcoming: mine.filter(b => !isBookingPast(b)).sort((a, b) => a.date.localeCompare(b.date) || a.time.localeCompare(b.time)),
        past:     mine.filter(b =>  isBookingPast(b)).sort((a, b) => b.date.localeCompare(a.date) || b.time.localeCompare(a.time))
    };
}

// ── Navbar ────────────────────────────────────────────────────────────────────
function updateNavAuth() {
    document.body.classList.add('auth-loaded');
    const user    = getCurrentUser();
    const isAdmin = sessionStorage.getItem('adminAuth') === 'true';
    const loginLink = document.getElementById('navLoginLink');
    const userMenu  = document.getElementById('navUserMenu');
    const userName  = document.getElementById('navUserName');

    _removeDynamicNavLinks();

    if (user || isAdmin) {
        if (loginLink) loginLink.style.display = 'none';
        if (userMenu)  userMenu.style.display  = 'flex';
        if (userName)  userName.textContent    = user ? (user.name || user.email).split(' ')[0] : 'PT';
        if (user) _injectNavLinkFirst('prenotazioni.html', 'Le mie prenotazioni', 'nav-prenotazioni-link');
        if (isAdmin) {
            _injectNavLinkLast('admin.html', 'Amministrazione', 'nav-admin-link');
            // Mostra voce Allenamento nella sidebar per tutti gli admin
            const _navAll = document.getElementById('navAllenamento');
            if (_navAll) _navAll.style.display = '';
        } else if (user && typeof supabaseClient !== 'undefined') {
            // Utente non admin: mostra Allenamento solo se ha almeno una scheda attiva
            supabaseClient.from('workout_plans').select('id', { count: 'exact', head: true })
                .eq('user_id', user.id).eq('active', true)
                .then(({ count }) => {
                    if (count > 0) {
                        const _navAll = document.getElementById('navAllenamento');
                        if (_navAll) _navAll.style.display = '';
                    }
                });
        }
        _injectSidebarLogout();
    } else {
        if (loginLink) loginLink.style.display = 'flex';
        if (userMenu)  userMenu.style.display  = 'none';
    }
}

function _injectNavLinkFirst(href, label, cssClass) {
    ['.nav-desktop-links', '.nav-sidebar-links'].forEach(sel => {
        const nav = document.querySelector(sel);
        if (!nav || nav.querySelector('.' + cssClass)) return;
        const li = document.createElement('li');
        li.setAttribute('data-nav-dynamic', '');
        li.innerHTML = `<a href="${href}" class="${cssClass}">${label}</a>`;
        nav.prepend(li);
    });
}

function _injectNavLinkLast(href, label, cssClass) {
    ['.nav-desktop-links', '.nav-sidebar-links'].forEach(sel => {
        const nav = document.querySelector(sel);
        if (!nav || nav.querySelector('.' + cssClass)) return;
        const li = document.createElement('li');
        li.setAttribute('data-nav-dynamic', '');
        li.innerHTML = `<a href="${href}" class="${cssClass}">${label}</a>`;
        nav.append(li);
    });
}

function _removeDynamicNavLinks() {
    document.querySelectorAll('[data-nav-dynamic]').forEach(el => el.remove());
    // Nascondi invece di rimuovere — preserva l'event listener del bottone Esci
    document.querySelectorAll('.nav-sidebar-logout-item').forEach(el => el.style.display = 'none');
}

function _injectSidebarLogout() {
    const sidebar = document.querySelector('.nav-sidebar-links');
    if (!sidebar) return;
    // Riusa il bottone esistente invece di ricrearlo (evita perdita event listener)
    const existing = sidebar.querySelector('.nav-sidebar-logout');
    if (existing) {
        const li = existing.closest('.nav-sidebar-logout-item');
        li.style.display = '';
        // Sposta in fondo per garantire che sia sempre l'ultimo elemento
        sidebar.append(li);
        return;
    }
    const li = document.createElement('li');
    li.className = 'nav-sidebar-logout-item';
    const btn = document.createElement('button');
    btn.className = 'nav-sidebar-logout';
    btn.textContent = 'Esci';
    btn.addEventListener('click', async () => {
        await logoutUser();
        window.location.href = 'index.html';
    });
    li.appendChild(btn);
    sidebar.append(li);
}

// ── Hamburger sidebar ─────────────────────────────────────────────────────────
function toggleNavMenu() {
    const sidebar = document.getElementById('navSidebar');
    const overlay = document.getElementById('navSidebarOverlay');
    if (!sidebar) return;
    const isOpen = sidebar.classList.toggle('open');
    if (overlay) overlay.classList.toggle('open', isOpen);
    document.body.classList.toggle('nav-open', isOpen);
}

// ── Profile modal ─────────────────────────────────────────────────────────────
function openProfileModal() {
    const user = getCurrentUser();
    if (!user) return;
    const modal = document.getElementById('profileModal');
    if (!modal) return;
    document.getElementById('profileUserName').textContent = user.name;
    renderProfileTab('upcoming');
    modal.style.display = 'flex';
    document.body.style.overflow = 'hidden';
}

function closeProfileModal() {
    const modal = document.getElementById('profileModal');
    if (modal) modal.style.display = 'none';
    document.body.style.overflow = '';
}

function renderProfileTab(tab) {
    const { upcoming, past } = getUserBookings();
    const list = tab === 'upcoming' ? upcoming : past;

    document.querySelectorAll('.profile-tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));

    const container = document.getElementById('profileBookingsList');
    if (!container) return;
    if (!list.length) {
        container.innerHTML = `<p class="profile-empty">${tab === 'upcoming' ? 'Nessuna prenotazione futura.' : 'Nessuna prenotazione passata.'}</p>`;
        return;
    }

    container.innerHTML = list.map(b => `
        <div class="profile-booking-card ${b.slotType}">
            <div class="profile-booking-date">📅 ${b.dateDisplay || b.date}</div>
            <div class="profile-booking-time">🕐 ${b.time}</div>
            <div class="profile-booking-type">${(window.SLOT_NAMES && window.SLOT_NAMES[b.slotType]) || b.slotType}</div>
        </div>
    `).join('');
}

// ── Init on DOM ready ─────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    const hamburger = document.getElementById('navHamburger');
    if (hamburger) hamburger.addEventListener('click', toggleNavMenu);

    const logoutBtn = document.getElementById('navLogoutBtn');
    if (logoutBtn) {
        logoutBtn.addEventListener('click', async () => {
            await logoutUser();
            window.location.href = 'index.html';
        });
    }

    const profileBtn = document.getElementById('navUserName');
    if (profileBtn) {
        profileBtn.style.cursor = 'pointer';
        profileBtn.addEventListener('click', () => {
            window.location.href = 'prenotazioni.html';
        });
    }
});
