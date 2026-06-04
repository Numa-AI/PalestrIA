// Auto-update service worker: rileva nuove versioni e ricarica la pagina
(function () {
    if (!('serviceWorker' in navigator)) return;

    // Guard contro reload loop: max 3 reload in 30 secondi
    const RELOAD_KEY = 'sw_reload_ts';
    const MAX_RELOADS = 3;
    const WINDOW_MS = 30000;
    function safeReload() {
        try {
            const now = Date.now();
            const stamps = JSON.parse(sessionStorage.getItem(RELOAD_KEY) || '[]')
                .filter(t => now - t < WINDOW_MS);
            if (stamps.length >= MAX_RELOADS) {
                console.warn('[SW] Troppe ricariche in 30s — loop interrotto');
                return;
            }
            stamps.push(now);
            sessionStorage.setItem(RELOAD_KEY, JSON.stringify(stamps));
        } catch (e) { /* sessionStorage non disponibile — procedi */ }
        window.location.reload();
    }

    // Flag unico per prevenire doppio reload (activated + controllerchange)
    let refreshing = false;
    function reloadOnce() {
        if (refreshing) return;
        refreshing = true;
        safeReload();
    }

    navigator.serviceWorker.register('sw.js', { updateViaCache: 'none' }).then(reg => {
        // Controlla aggiornamenti una sola volta all'apertura dell'app
        reg.update();

        // Nuovo SW trovato (installing o waiting)
        function onNewSW(worker) {
            worker.addEventListener('statechange', () => {
                if (worker.state === 'activated') {
                    reloadOnce();
                }
            });
        }

        if (reg.waiting) onNewSW(reg.waiting);
        reg.addEventListener('updatefound', () => {
            if (reg.installing) onNewSW(reg.installing);
        });
    });

    // Quando un nuovo SW prende il controllo, ricarica
    navigator.serviceWorker.addEventListener('controllerchange', () => {
        reloadOnce();
    });
})();
