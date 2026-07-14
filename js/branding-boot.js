// branding-boot.js — applica il branding salvato PRIMA del primo paint, per eliminare
// il flash di "IL TUO NOME" + colori di default (viola PalestrIA) al refresh.
//
// Va caricato SINCRONO nell'<head>, prima del <body>: così i colori vengono applicati
// su :root prima che la pagina venga dipinta, e il nome appena il DOM è pronto. I valori
// reali arrivano comunque poco dopo da OrgSettings.load() (async), che corregge se cambiati.
// Lo snapshot è scritto da OrgSettings.applyBranding() sotto la chiave stabile (non
// namespaced) `_brandingSnapshot`: alla prima visita assoluta non esiste ancora (nessun
// flash da correggere), dal refresh successivo in poi il branding è immediato.
(function () {
    'use strict';
    var snap;
    try { snap = JSON.parse(localStorage.getItem('_brandingSnapshot') || 'null'); } catch (_) { snap = null; }
    if (!snap || typeof snap !== 'object') return;

    var root = document.documentElement;

    // L1: valida l'URL maps accettando SOLO http:/https: (scarta javascript:, data:, ...).
    // Lo snapshot può provenire da una versione precedente al fix in org-settings.js.
    function safeHttpUrl(raw) {
        if (!raw) return '';
        try {
            var u = new URL(String(raw), location.href);
            return (u.protocol === 'http:' || u.protocol === 'https:') ? u.href : '';
        } catch (_) { return ''; }
    }

    // 1) COLORI — su :root subito (in <head>, prima del paint) → niente flash viola.
    //    L'inline style su documentElement vince su qualsiasi regola :root del CSS.
    if (snap.color)     root.style.setProperty('--primary-purple', snap.color);
    if (snap.colorDark) root.style.setProperty('--primary-purple-dark', snap.colorDark);
    if (snap.color) {
        var tm = document.querySelector('meta[name="theme-color"]');
        if (tm) tm.setAttribute('content', snap.color);
    }

    // 2) FAVICON / TITOLO — elementi già presenti nell'<head>.
    if (snap.favicon) {
        var fav = document.querySelector('link[rel="icon"]');
        if (fav) fav.setAttribute('href', snap.favicon);
    }
    if (snap.title) {
        document.title = snap.title;
        var at = document.querySelector('meta[name="apple-mobile-web-app-title"]');
        if (at) at.setAttribute('content', snap.title);
    }

    // 3) NOME / INDIRIZZO / DURATA (+ logo, link maps) — sono nel <body>, non ancora
    //    parsati qui. Per non mostrare i valori statici vecchi (es. "Via Demo 1 — Milano"),
    //    nascondiamo gli elementi di testo (visibility → niente layout shift) finché non
    //    applichiamo i valori dalla cache, poi riveliamo con html[data-branded]. Pochi ms.
    var hideSel = [];
    if (snap.name)     hideSel.push('[data-org-name]');
    if (snap.address)  hideSel.push('[data-org-address]');
    if (snap.duration) hideSel.push('[data-org-duration]');
    if (hideSel.length) {
        var style = document.createElement('style');
        style.setAttribute('data-branding-boot', '1');
        var hiddenRule = hideSel.join(',') + '{visibility:hidden}';
        var shownRule = hideSel.map(function (s) { return 'html[data-branded] ' + s; }).join(',') + '{visibility:visible}';
        style.textContent = hiddenRule + shownRule;
        (document.head || root).appendChild(style);
    }

    function applyDom() {
        if (snap.name) {
            var els = document.querySelectorAll('[data-org-name]');
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                if (el.dataset && el.dataset.brandLocked === '1') continue; // override manuale ?pt=
                el.textContent = snap.name;
            }
        }
        if (snap.logo) {
            var imgs = document.querySelectorAll('img[data-org-logo]');
            for (var j = 0; j < imgs.length; j++) {
                if (!imgs[j].dataset.brandDefault) imgs[j].dataset.brandDefault = imgs[j].getAttribute('src') || '';
                imgs[j].src = snap.logo;
            }
        }
        if (snap.address) {
            var addrEls = document.querySelectorAll('[data-org-address]');
            for (var a = 0; a < addrEls.length; a++) addrEls[a].textContent = snap.address;
        }
        if (snap.duration) {
            var durEls = document.querySelectorAll('[data-org-duration]');
            for (var d = 0; d < durEls.length; d++) durEls[d].textContent = snap.duration;
        }
        var safeMaps = safeHttpUrl(snap.maps);
        if (safeMaps) {
            // L'elemento è nascosto di default nell'HTML: si mostra solo con URL configurato
            var mapEls = document.querySelectorAll('a[data-org-maps]');
            for (var m = 0; m < mapEls.length; m++) { mapEls[m].href = safeMaps; mapEls[m].style.display = ''; }
        }
        root.setAttribute('data-branded', '1'); // rivela gli elementi nascosti in ogni caso
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', applyDom);
    else applyDom();
})();
