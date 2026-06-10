// ─────────────────────────────────────────────────────────────────────────────
// Namespacing del localStorage per le chiavi "globali" del calendario.
//
// PalestrIA nasce come fork di un gestionale single-tenant e ne ha ereditato
// alcune chiavi localStorage NON namespacizzate (gym_bookings, gym_stats,
// weeklyScheduleTemplate, scheduleVersion, gym_week_templates,
// gym_active_week_template). La pagina del calendario, al primo paint, disegna
// la griglia SUBITO da queste chiavi (cache locale) e solo dopo sincronizza da
// Supabase. Se sullo stesso origin (stesso host:porta — tipico in sviluppo
// locale: piu' progetti serviti sulla stessa porta di localhost) gira un altro
// progetto che usa le STESSE chiavi, il browser condivide il localStorage e per
// un istante si vedrebbe il calendario dell'altro progetto ("flash"). Lo stesso
// accadrebbe cambiando tenant sullo stesso device (logout A -> login B).
//
// Soluzione: queste 6 chiavi vengono salvate FISICAMENTE con prefisso
// `palestria:` in modo TRASPARENTE. Il resto del codice continua a usare i nomi
// logici ("gym_bookings", ...), cosi' restano intatti:
//   - la mappatura gym_ -> chiave DB di _upsertSetting() (data.js)
//   - il formato dei backup (admin-backup.js usa i nomi logici come proprieta')
// NON tocchiamo: i token Supabase `sb-*`, le impostazioni `gym_*` (cancellation,
// cert, ...), ne' le chiavi gia' namespaced per-org (scheduleOverrides_<id>,
// _orgSchedSnap_<id>, org_<id>_*). Anche le iterazioni localStorage.key(i)
// restano invariate (cercano solo `sb-*-auth-token`, mai queste chiavi).
//
// Nota: la prima volta dopo il deploy le chiavi `palestria:*` non esistono ->
// la cache locale risulta vuota e viene ripopolata al primo sync da Supabase
// (re-sync una tantum, innocuo). Le vecchie chiavi "nude" restano orfane ma non
// vengono piu' lette.
//
// IMPORTANTE: questo file DEVE caricarsi PRIMA di js/data.js (data.js legge
// queste chiavi gia' in fase di valutazione del modulo).
// ─────────────────────────────────────────────────────────────────────────────
(function () {
    'use strict';
    var PREFIX = 'palestria:';
    // Allowlist delle SOLE chiavi da isolare. Tutto il resto passa invariato.
    var NS = {
        'gym_bookings': 1,
        'gym_stats': 1,
        'weeklyScheduleTemplate': 1,
        'scheduleVersion': 1,
        'gym_week_templates': 1,
        'gym_active_week_template': 1
    };

    var P;
    try { P = window.Storage && window.Storage.prototype; } catch (_) { return; }
    if (!P || P.__nsPatched) return;

    var rawGet = P.getItem;
    var rawSet = P.setItem;
    var rawRemove = P.removeItem;

    function phys(key) {
        return (NS[key] === 1) ? PREFIX + key : key;
    }

    // Override sul prototype Storage: vale per local+sessionStorage, ma rimappa
    // SOLO le 6 chiavi in allowlist (che sessionStorage non usa) -> innocuo.
    // `this` preserva l'istanza corretta (localStorage vs sessionStorage).
    P.getItem = function (key) { return rawGet.call(this, phys(key)); };
    P.setItem = function (key, value) { return rawSet.call(this, phys(key), value); };
    P.removeItem = function (key) { return rawRemove.call(this, phys(key)); };
    P.__nsPatched = true;
})();
