// ─────────────────────────────────────────────────────────────────────────────
// egress-debug.js — strumento diagnostico OPT-IN per misurare l'egress per endpoint.
//
// A COSA SERVE: l'egress Supabase è dominato da PostgREST (query dati). Per ottimizzare
// in modo mirato (non a caso) serve sapere QUALI query/RPC pesano di più in produzione.
// Questo script intercetta le risposte fetch verso Supabase e ne somma i byte per endpoint.
//
// SICUREZZA: è DISATTIVATO di default. Quando il flag non c'è, lo script esce subito e NON
// installa nulla (zero overhead, nessun wrap di fetch). Solo lettura/log, nessuna modifica ai dati.
//
// USO:
//   1. Sul dispositivo da misurare, in console:  localStorage.setItem('egressDebug','1')  poi ricarica.
//   2. Usa l'app normalmente per qualche minuto (apri pagine, naviga, lascia girare il realtime).
//   3. In console:  _egressReport()   → tabella ordinata per KB con i top endpoint + totale.
//   4. Per azzerare i contatori:  _egressReset()
//   5. Per disattivare:  localStorage.removeItem('egressDebug')  poi ricarica.
//
// NOTA: i byte misurati sono DECOMPRESSI (il browser decomprime prima di darceli). L'egress
// fatturato è compresso (~5–10× meno), ma il RANKING relativo tra endpoint resta valido — ed è
// quello che serve per capire dove intervenire. Deve caricarsi PRIMA di supabase-client.js così
// il wrap di fetch è attivo prima che il client venga creato. Il realtime (WebSocket) non passa
// per fetch e non viene misurato (è comunque ~0.7% dell'egress).
// ─────────────────────────────────────────────────────────────────────────────
(function () {
    try {
        if (localStorage.getItem('egressDebug') !== '1') return;       // OFF di default → esci subito
    } catch (_) { return; }
    if (window.__egressDebugInstalled) return;
    window.__egressDebugInstalled = true;

    var stats = Object.create(null); // endpoint -> { bytes, count }
    var origFetch = window.fetch ? window.fetch.bind(window) : null;
    if (!origFetch) return;

    // Estrae un'etichetta leggibile dall'URL Supabase: tabella, "rpc:<fn>", o servizio.
    function _label(url) {
        try {
            var u = new URL(url, location.origin);
            if (u.hostname.indexOf('supabase') === -1) return null;     // solo richieste Supabase
            var m = u.pathname.match(/\/rest\/v1\/(rpc\/)?([^/?]+)/);
            if (m) return (m[1] ? 'rpc:' : 'tab:') + m[2];
            var m2 = u.pathname.match(/\/(auth|storage|functions)\/v1\//);
            if (m2) return m2[1];
            return u.pathname;
        } catch (_) { return null; }
    }

    window.fetch = function (input, init) {
        var url = (typeof input === 'string') ? input : (input && input.url) || '';
        var label = _label(url);
        var p = origFetch(input, init);
        if (!label) return p;
        return p.then(function (res) {
            try {
                var clone = res.clone();
                clone.arrayBuffer().then(function (buf) {
                    var s = stats[label] || (stats[label] = { bytes: 0, count: 0 });
                    s.bytes += buf.byteLength;
                    s.count += 1;
                }).catch(function () { /* corpo non leggibile: ignora */ });
            } catch (_) { /* clone fallito: ignora */ }
            return res;
        });
    };

    window._egressReport = function () {
        var rows = Object.keys(stats).map(function (k) {
            var v = stats[k];
            return {
                endpoint: k,
                KB: Math.round(v.bytes / 1024 * 10) / 10,
                richieste: v.count,
                KB_medi: Math.round(v.bytes / v.count / 1024 * 10) / 10
            };
        }).sort(function (a, b) { return b.KB - a.KB; });
        var totKB = Math.round(rows.reduce(function (s, r) { return s + r.KB; }, 0) * 10) / 10;
        var totReq = rows.reduce(function (s, r) { return s + r.richieste; }, 0);
        if (console.table) console.table(rows);
        console.log('[egress] TOTALE sessione (decompresso): ' + totKB + ' KB su ' + totReq + ' richieste — fatturato ~5-10x meno (compresso)');
        return rows;
    };

    window._egressReset = function () {
        Object.keys(stats).forEach(function (k) { delete stats[k]; });
        console.log('[egress] contatori azzerati');
    };

    console.log('%c[egress-debug] ATTIVO — usa _egressReport() in console per il riepilogo per endpoint', 'color:#0a0;font-weight:bold');
})();
