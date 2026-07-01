// Service worker: registra e cerca aggiornamenti UNA volta all'avvio.
// NIENTE reload automatico: il nuovo SW si installa in background, prende il
// controllo in silenzio (skipWaiting + clients.claim in sw.js) e — essendo
// un'app multipagina — la versione aggiornata viene servita alla PRIMA
// navigazione naturale (HTML network-first → nuovi ?v=). Così l'utente non
// subisce ricariche "a sorpresa" dopo ogni deploy né alla prima presa di
// controllo del SW (prima visita / eviction SW iOS dopo ~7 giorni).
// (Prima: reload su ogni 'controllerchange'/'activated' → doppio refresh.)
(function () {
    if (!('serviceWorker' in navigator)) return;

    navigator.serviceWorker.register('sw.js', { updateViaCache: 'none' })
        .then(reg => { reg.update(); })
        .catch(() => { /* registrazione SW fallita: l'app funziona comunque */ });
})();
