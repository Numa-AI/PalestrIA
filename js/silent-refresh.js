// Silent refresh: rinfresca sessione, dati e canali realtime quando la PWA
// rientra da idle, senza reload visibile e senza interrompere form aperti.
(function () {
    var IDLE_THRESHOLD_MS = 5 * 60 * 1000;
    var MIN_REFRESH_INTERVAL_MS = 60 * 1000;
    var ACTIVITY_THROTTLE_MS = 1000;
    var lastActivityTs = Date.now();
    var lastRefreshTs = 0;
    var activityThrottleTs = 0;
    var refreshInFlight = false;
    var channels = new Map();

    function _registerRealtimeChannel(name, factory) {
        if (typeof factory !== 'function') return null;
        // Dedup difensiva: se un canale con questo nome esiste già, rimuovilo prima
        // di ricrearlo, così non si accumulano sottoscrizioni doppie nella stessa sessione.
        var existing = channels.get(name);
        if (existing && existing.instance && typeof supabaseClient !== 'undefined') {
            try { supabaseClient.removeChannel(existing.instance); } catch (_) {}
        }
        var instance = null;
        try { instance = factory(); } catch (e) {
            console.warn('[silent-refresh] register failed:', name, e);
        }
        channels.set(name, { factory: factory, instance: instance });
        return instance;
    }

    // Cleanup di TUTTI i canali registrati: chiamato su beforeunload così la
    // navigazione tra pagine non lascia sottoscrizioni stantie sul client Supabase.
    function _cleanupAllRealtimeChannels() {
        if (typeof supabaseClient === 'undefined') return;
        channels.forEach(function (entry) {
            if (entry && entry.instance) {
                try { supabaseClient.removeChannel(entry.instance); } catch (_) {}
            }
        });
    }

    async function _reconnectDeadChannels() {
        if (typeof supabaseClient === 'undefined') return;
        var entries = [];
        channels.forEach(function (entry, name) { entries.push([name, entry]); });
        for (var i = 0; i < entries.length; i++) {
            var name = entries[i][0];
            var entry = entries[i][1];
            try {
                var state = entry.instance && entry.instance.state;
                if (state === 'joined' || state === 'joining') continue;
                console.log('[silent-refresh] reconnecting dead channel:', name, 'state was:', state);
                if (entry.instance) {
                    try { supabaseClient.removeChannel(entry.instance); } catch (_) {}
                }
                entry.instance = entry.factory();
                await new Promise(function (r) { setTimeout(r, 100); });
            } catch (e) {
                console.warn('[silent-refresh] reconnect failed:', name, e && e.message);
            }
        }
    }

    function _hasOpenModalWithInput() {
        var selectors = ['.modal-overlay', '.popup-overlay', '[id$="Modal"]', '[id$="modal"]', '[id$="ModalOverlay"]', '[id*="popup"]'];
        for (var i = 0; i < selectors.length; i++) {
            var els = document.querySelectorAll(selectors[i]);
            for (var j = 0; j < els.length; j++) {
                var el = els[j];
                try {
                    var style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity || '1') === 0) continue;
                    var rect = el.getBoundingClientRect();
                    if (rect.width === 0 && rect.height === 0) continue;
                    var inputs = el.querySelectorAll('input, textarea, select');
                    for (var k = 0; k < inputs.length; k++) {
                        var inp = inputs[k];
                        if (inp.type === 'hidden') continue;
                        var iStyle = window.getComputedStyle(inp);
                        if (iStyle.display !== 'none' && iStyle.visibility !== 'hidden') return true;
                    }
                } catch (_) {}
            }
        }
        return false;
    }

    async function _syncStoragesQuietly() {
        async function add(label, fn) {
            if (typeof fn !== 'function') return;
            try { await fn(); } catch (e) { console.warn('[silent-refresh] sync error:', label, e && e.message); }
        }
        await add('BookingStorage', function () { return typeof BookingStorage !== 'undefined' && BookingStorage.syncFromSupabase(); });
        await add('AppSettings', function () { return typeof BookingStorage !== 'undefined' && BookingStorage.syncAppSettingsFromSupabase && BookingStorage.syncAppSettingsFromSupabase(); });
        await add('SlotAccessRequestStorage', function () { return typeof SlotAccessRequestStorage !== 'undefined' && SlotAccessRequestStorage.syncFromSupabase(); });
    }

    // Race una promise contro un timeout: se l'await interno si appende (rete morta,
    // refresh master senza timeout proprio), non blocca il ciclo all'infinito.
    function _withTimeout(p, ms, label) {
        return Promise.race([
            Promise.resolve(p),
            new Promise(function (_, rej) { setTimeout(function () { rej(new Error('timeout:' + label)); }, ms); })
        ]);
    }

    async function _triggerSilentRefresh(reason) {
        var now = Date.now();
        if (refreshInFlight || now - lastRefreshTs < MIN_REFRESH_INTERVAL_MS) return;
        lastRefreshTs = now;
        refreshInFlight = true;
        // Watchdog di sicurezza: qualunque await interno si appenda, dopo 30s sblocca
        // SEMPRE refreshInFlight, così i refresh futuri restano possibili senza che
        // l'utente debba ricaricare la pagina a mano (causa radice C7 del freeze idle).
        var _watchdog = setTimeout(function () {
            if (refreshInFlight) {
                console.warn('[silent-refresh] watchdog 30s — forzo refreshInFlight=false');
                refreshInFlight = false;
            }
        }, 30000);
        try {
            console.log('[silent-refresh] trigger:', reason);
            var formOpen = _hasOpenModalWithInput();
            if (formOpen) {
                if (typeof ensureValidSession === 'function') {
                    // FIX #2: force SOLO su 'online'. Su wake/idle niente force (evita il
                    // cascade-lock: refreshSession su token valido resta appeso sul lock auth).
                    try { await ensureValidSession({ force: reason === 'online', timeoutMs: 12000 }); } catch (e) { console.warn('[silent-refresh] session:', e && e.message); }
                }
                await _syncStoragesQuietly();
            } else if (typeof window._adminRefreshAfterResume === 'function') {
                await _withTimeout(window._adminRefreshAfterResume('silent:' + reason, 0), 20000, 'adminRefresh').catch(function (e) { console.warn('[silent-refresh]', e && e.message); });
            } else if (typeof window._silentMasterRefresh === 'function') {
                await _withTimeout(window._silentMasterRefresh(reason), 20000, 'masterRefresh').catch(function (e) { console.warn('[silent-refresh]', e && e.message); });
            } else {
                if (typeof ensureValidSession === 'function') {
                    // FIX #2: force SOLO su 'online' (vedi sopra).
                    try { await ensureValidSession({ force: reason === 'online', timeoutMs: 12000 }); } catch (_) {}
                }
                await _syncStoragesQuietly();
                if (typeof renderCalendar === 'function') renderCalendar();
                if (typeof renderMobileCalendar === 'function') renderMobileCalendar();
            }
            await _reconnectDeadChannels();
        } finally {
            clearTimeout(_watchdog);
            refreshInFlight = false;
        }
    }

    function _markActivity() {
        var now = Date.now();
        if (now - activityThrottleTs < ACTIVITY_THROTTLE_MS) return;
        activityThrottleTs = now;
        var wasIdle = (now - lastActivityTs) > IDLE_THRESHOLD_MS;
        lastActivityTs = now;
        if (wasIdle) _triggerSilentRefresh('wake-from-idle');
    }

    ['mousemove', 'mousedown', 'keydown', 'touchstart', 'wheel'].forEach(function (ev) {
        document.addEventListener(ev, _markActivity, { passive: true, capture: true });
    });
    window.addEventListener('online', function () { _triggerSilentRefresh('online'); });

    window.addEventListener('beforeunload', _cleanupAllRealtimeChannels);

    window._registerRealtimeChannel = _registerRealtimeChannel;
    window._cleanupAllRealtimeChannels = _cleanupAllRealtimeChannels;
    window._triggerSilentRefresh = _triggerSilentRefresh;
})();
