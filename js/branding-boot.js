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

    // 3) NOME (+ logo) — gli elementi [data-org-name]/img[data-org-logo] sono nel <body>,
    //    non ancora parsati qui. Per non mostrare il placeholder, nascondiamo
    //    [data-org-name] (visibility → nessun layout shift) finché non applichiamo il nome
    //    dalla cache, poi riveliamo con html[data-branded]. Tutto entro pochi ms.
    if (snap.name) {
        var style = document.createElement('style');
        style.setAttribute('data-branding-boot', '1');
        style.textContent = '[data-org-name]{visibility:hidden}html[data-branded] [data-org-name]{visibility:visible}';
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
        root.setAttribute('data-branded', '1'); // rivela [data-org-name] in ogni caso
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', applyDom);
    else applyDom();
})();
