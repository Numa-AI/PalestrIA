// entitlements.js — Feature gating client-side per piano SaaS (org-aware)
//
// Sorgente di verità: RPC get_tenant_entitlements() (authenticated), che ritorna
// { plan, status, max_clients, features, trial_end, current_period_end, clients_count }.
// Il server resta l'autorità (RLS + RPC): questo modulo è solo UX — nasconde/disabilita
// gli elementi che il piano corrente non include, ma NON sostituisce l'enforcement DB.
//
// Uso tipico (boot admin):
//   await Entitlements.load();
//   Entitlements.applyFeatureGating();
//
// Gli elementi da gateare portano l'attributo data-feature="<flag>" (es. "workout_plans",
// "messaging", "ai_reports", "client_online_payments"). Quando has(flag) === false vengono
// nascosti/disabilitati e, sui tab, marcati con un badge "Disponibile nel piano superiore".

(function () {
    'use strict';

    // Cache in memoria delle entitlements caricate (null finché load() non è andata a buon fine).
    let _ent = null;
    // True solo dopo che load() ha completato con esito noto (anche null = nessuna subscription).
    // Distingue "non ancora caricato" (blip/in corso) da "caricato senza la feature":
    // finché è false NON sblocchiamo feature premium (fail-closed prudente lato UI).
    let _loaded = false;

    // Stati di abbonamento considerati "attivi" (accesso pieno alle feature del piano).
    const ACTIVE_STATUSES = ['trialing', 'active'];

    // Carica le entitlements dal server e le mette in cache (memoria + window._entitlements).
    // Idempotente: se già caricate, ritorna la cache senza richiamare la RPC.
    // In caso di errore NON marca _loaded → has() resta in stato "in caricamento"
    // (feature premium ancora bloccate lato UI). L'autorità resta comunque server-side.
    async function load(opts) {
        const force = opts && opts.force;
        if (_loaded && !force) return _ent;
        if (typeof supabaseClient === 'undefined') return _ent;
        try {
            const { data, error } = await supabaseClient.rpc('get_tenant_entitlements');
            if (error) {
                console.warn('[Entitlements] RPC get_tenant_entitlements error:', error.message);
                return _ent; // _loaded resta false → non sblocchiamo nulla su un blip RPC
            }
            // La RPC ritorna jsonb (oggetto) oppure null se non c'è subscription per la org.
            _ent = data || null;
            _loaded = true; // esito noto: da ora has() riflette il piano reale
            window._entitlements = _ent;
        } catch (e) {
            console.warn('[Entitlements] load() fallita:', e && e.message);
        }
        return _ent;
    }

    // Oggetto features del piano (vuoto se non caricate).
    function _features() {
        return (_ent && _ent.features) || {};
    }

    // true se la feature è inclusa nel piano.
    //
    // ⚠️ L'autorità sull'accesso resta SEMPRE server-side (RLS + RPC): questo è solo gating UX.
    // Default sicuro (fail-closed) quando l'esito del load NON è ancora noto (_loaded false:
    // prima del load o dopo un blip RPC) → le feature premium restano bloccate, così un errore
    // di rete non sblocca nulla client-side. A esito noto (_loaded true) riflette il piano reale:
    // _ent null = nessuna subscription → nessuna feature; altrimenti "off" solo se esplicitamente false.
    function has(flag) {
        if (!_loaded) return false;   // in caricamento / blip RPC → non sbloccare premium
        if (!_ent) return false;      // esito noto: nessuna subscription → nessuna feature premium
        const f = _features();
        return f[flag] !== false;
    }

    // Codice del piano (starter/pro/business) o null.
    function plan() {
        return (_ent && _ent.plan) || null;
    }

    // Stato dell'abbonamento (trialing/active/past_due/...) o null.
    function status() {
        return (_ent && _ent.status) || null;
    }

    // true se l'abbonamento è in uno stato attivo (trial o pagante).
    function isActive() {
        return ACTIVE_STATUSES.indexOf(status()) !== -1;
    }

    // Numero massimo di clienti del piano (null = illimitato, anche se non caricate).
    function maxClients() {
        return (_ent && _ent.max_clients != null) ? _ent.max_clients : null;
    }

    // Numero di clienti attualmente iscritti alla org.
    function clientsCount() {
        return (_ent && typeof _ent.clients_count === 'number') ? _ent.clients_count : 0;
    }

    // true se la org ha raggiunto/superato il limite clienti del piano.
    // Piano illimitato (maxClients null) → mai al limite.
    function atClientLimit() {
        const max = maxClients();
        return max != null && clientsCount() >= max;
    }

    // Clienti ancora aggiungibili prima del limite (null = illimitato).
    function remainingClients() {
        const max = maxClients();
        if (max == null) return null;
        return Math.max(max - clientsCount(), 0);
    }

    // Crea (o riusa) un badge "Disponibile nel piano superiore" associato a un elemento.
    function _ensureUpgradeBadge(el) {
        // Tab button: il badge va come figlio del bottone (riconoscibile via classe).
        let badge = el.querySelector(':scope > .ent-upgrade-badge');
        if (!badge) {
            badge = document.createElement('span');
            badge.className = 'ent-upgrade-badge';
            badge.textContent = '🔒 Piano superiore';
            badge.title = 'Disponibile nel piano superiore';
            el.appendChild(badge);
        }
        return badge;
    }

    // Applica il gating UI: per ogni [data-feature] non incluso nel piano,
    // nasconde i contenuti e disabilita/segnala i controlli (tab, bottoni, option).
    function applyFeatureGating(root) {
        const scope = root || document;
        const nodes = scope.querySelectorAll('[data-feature]');
        nodes.forEach((el) => {
            const flag = el.getAttribute('data-feature');
            if (!flag) return;
            const allowed = has(flag);

            // Tab button della dashboard admin (resta visibile ma disabilitato + badge,
            // così l'utente vede cosa sblocca con l'upgrade).
            const isTabButton = el.classList.contains('admin-tab') && el.hasAttribute('data-tab');

            if (allowed) {
                // Ripristina eventuale gating precedente (es. dopo un cambio piano).
                el.classList.remove('ent-locked');
                if (isTabButton) {
                    el.disabled = false;
                    el.removeAttribute('aria-disabled');
                    const b = el.querySelector(':scope > .ent-upgrade-badge');
                    if (b) b.remove();
                } else if (el.dataset.entHidden === '1') {
                    el.style.display = el.dataset.entPrevDisplay || '';
                    delete el.dataset.entHidden;
                    delete el.dataset.entPrevDisplay;
                }
                return;
            }

            // Feature NON inclusa nel piano.
            el.classList.add('ent-locked');
            if (isTabButton) {
                el.disabled = true;
                el.setAttribute('aria-disabled', 'true');
                _ensureUpgradeBadge(el);
            } else {
                // Contenuti/sezioni/option/bottoni: nascondi salvando il display precedente.
                if (el.dataset.entHidden !== '1') {
                    el.dataset.entPrevDisplay = el.style.display || '';
                    el.dataset.entHidden = '1';
                }
                el.style.display = 'none';
            }
        });
    }

    // Inietta gli stili minimi del gating (badge + tab bloccato) una sola volta.
    function _injectStyles() {
        if (document.getElementById('ent-gating-styles')) return;
        const css = `
            .admin-tab.ent-locked { opacity: .55; cursor: not-allowed; }
            .ent-upgrade-badge {
                display: inline-block;
                margin-left: 6px;
                padding: 1px 6px;
                font-size: 10px;
                font-weight: 600;
                line-height: 1.4;
                color: #92400e;
                background: #fef3c7;
                border: 1px solid #fde68a;
                border-radius: 999px;
                vertical-align: middle;
                white-space: nowrap;
            }`;
        const style = document.createElement('style');
        style.id = 'ent-gating-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', _injectStyles);
    } else {
        _injectStyles();
    }

    // API pubblica globale.
    window.Entitlements = {
        load,
        has,
        plan,
        status,
        isActive,
        maxClients,
        clientsCount,
        atClientLimit,
        remainingClients,
        applyFeatureGating
    };
})();
