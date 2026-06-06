// app-watchdog.js — Watchdog globale di auto-guarigione.
//
// È lo strato di garanzia: se al rientro da uno stop prolungato (sleep del Mac,
// PWA in background, idle lungo) l'app NON riesce a confermarsi "sana" entro un
// tempo massimo, esegue un reload invisibile invece di lasciare l'utente bloccato
// a doverlo fare a mano. Protegge anche dai bug che non abbiamo ancora trovato:
// qualunque cosa wedge lo stato auth/lock, l'app si cura da sé.
//
// Detezione: al resume lancia una probe leggera (ensureValidSession con timeout).
// ensureValidSession è progettata per risolversi SEMPRE entro il suo timeout
// (fail-closed incluso); se non lo fa, lo strato auth/lock è davvero incastrato
// → reload. Su rete solo lenta NON scatta (la probe si risolve, anche con errore).
(function () {
    'use strict';

    var PROBE_TIMEOUT_MS       = 12000;  // tempo massimo per confermare salute
    var RESUME_HIDDEN_MS       = 60000;  // considera "resume" solo dopo ≥60s nascosto
    var MIN_RELOAD_INTERVAL_MS = 60000;  // non ricaricare più di 1 volta/minuto
    var MAX_RELOADS_PER_SESSION = 3;     // anti-loop: oltre, lascia stare

    var lastHiddenTs = 0;
    var probing = false;

    function _now() { return Date.now(); }

    function _ss(key, def) {
        try { var v = sessionStorage.getItem(key); return v === null ? def : v; }
        catch (_) { return def; }
    }
    function _ssSet(key, val) { try { sessionStorage.setItem(key, String(val)); } catch (_) {} }

    // Non distruggere input utente: se è aperto un modal/form con un campo valorizzato,
    // rimanda il reload (al prossimo resume riproveremo). Meglio un'attesa che perdere dati.
    function _hasDirtyVisibleForm() {
        try {
            var els = document.querySelectorAll('[id$="Modal"],[id$="modal"],.modal-overlay,.popup-overlay');
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var st = window.getComputedStyle(el);
                if (st.display === 'none' || st.visibility === 'hidden') continue;
                var r = el.getBoundingClientRect();
                if (r.width === 0 && r.height === 0) continue;
                var inputs = el.querySelectorAll('input, textarea');
                for (var j = 0; j < inputs.length; j++) {
                    var inp = inputs[j];
                    if (inp.type === 'hidden') continue;
                    if (inp.value && String(inp.value).trim() !== '') return true;
                }
            }
        } catch (_) {}
        return false;
    }

    function _canReload() {
        var count = parseInt(_ss('_wdReloadCount', '0'), 10) || 0;
        if (count >= MAX_RELOADS_PER_SESSION) return false;
        var last = parseInt(_ss('_wdLastReload', '0'), 10) || 0;
        return (_now() - last) > MIN_RELOAD_INTERVAL_MS;
    }

    function _selfHeal(reason) {
        if (_hasDirtyVisibleForm()) {
            console.warn('[watchdog] wedge rilevato (' + reason + ') ma form con dati aperto — rimando il reload');
            return;
        }
        if (!_canReload()) {
            console.warn('[watchdog] wedge rilevato (' + reason + ') ma reload non consentito ora (anti-loop) — skip');
            return;
        }
        _ssSet('_wdLastReload', _now());
        _ssSet('_wdReloadCount', (parseInt(_ss('_wdReloadCount', '0'), 10) || 0) + 1);
        console.warn('[watchdog] auto-guarigione: reload invisibile (' + reason + ')');
        try { window.location.reload(); } catch (_) {}
    }

    // Risolve true=sana, false=ha risposto con errore (comunque viva), 'timeout'=incastrata.
    function _probe(ms) {
        var settled = (typeof ensureValidSession === 'function')
            ? Promise.resolve(ensureValidSession({ timeoutMs: ms - 2000 })).then(function () { return true; }, function () { return false; })
            : Promise.resolve(true);
        var timeout = new Promise(function (res) { setTimeout(function () { res('timeout'); }, ms); });
        return Promise.race([settled, timeout]);
    }

    function _onResume(reason) {
        if (probing) return;
        if (typeof supabaseClient === 'undefined') return; // nessun backend → niente da curare
        probing = true;
        _probe(PROBE_TIMEOUT_MS).then(function (r) {
            if (r === 'timeout') _selfHeal('probe-timeout:' + reason);
        }).catch(function (e) {
            console.warn('[watchdog] probe error:', e && e.message);
        }).finally(function () { probing = false; });
    }

    // Trigger di resume: visibilità tornata visibile dopo ≥60s nascosto, ripristino
    // da bfcache, o ritorno online. Ognuno è un momento in cui lo stato può essere stantio.
    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'hidden') {
            lastHiddenTs = _now();
        } else if (document.visibilityState === 'visible') {
            var hiddenFor = lastHiddenTs ? (_now() - lastHiddenTs) : 0;
            if (hiddenFor >= RESUME_HIDDEN_MS) _onResume('visible');
        }
    });
    window.addEventListener('pageshow', function (e) {
        if (e && e.persisted) _onResume('bfcache');
    });
    window.addEventListener('online', function () { _onResume('online'); });

    // Esposto per test manuale da console: window._appWatchdogProbe()
    window._appWatchdogProbe = function () { return _onResume('manual'); };
})();
