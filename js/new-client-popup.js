// ─── POPUP "NUOVO CLIENTE ISCRITTO" (solo admin, solo mobile/PWA) ───────────────
// COSA FA: quando un nuovo cliente ha completato TUTTA l'anagrafica (telefono +
// codice fiscale + indirizzo), mostra all'admin un popup con Nome Cognome + numero e
// due bottoni — WhatsApp e Telefono — per salvarlo al volo in rubrica.
//
// COME FUNZIONA (100% client-side, nessuna modifica al backend):
//  • Fonte dati: UserStorage._cache, già sincronizzata da get_all_profiles_basic nel
//    boot di admin.html. La RPC è org-scoped (RLS + is_org_admin), quindi si vedono solo
//    i clienti della PROPRIA org (nessun leak cross-tenant). Da lì filtra i completi.
//  • "Nuovo" = profilo completo il cui userId NON è ancora nel set "già visti" salvato
//    su localStorage (per-dispositivo, NAMESPACED per org). Al PRIMO avvio in assoluto
//    semina il set con tutti i clienti attuali (baseline) → nessun popup per la base
//    esistente; da lì in poi mostra solo i nuovi completi.
//  • Alla chiusura del popup (✕/backdrop) i clienti mostrati vengono segnati come visti
//    → non ricompaiono mai più su quel dispositivo.
//  • Ricontrolla anche al rientro in primo piano (visibilitychange).
//
// GATE: gira solo su admin.html, solo con sessionStorage.adminAuth==='true' e solo su
// mobile/PWA (standalone oppure viewport ≤768px). Su desktop admin non compare.
//
// Dipendenze globali (già caricate da data.js / auth.js / ui.js): UserStorage,
// _escHtml, window._orgId. Stile self-contained (.ncp-*), accento viola brand PalestrIA.

(function () {
    'use strict';

    const SEEN_BASE     = 'palestria_newClientSeen';      // array di userId già mostrati/acquisiti
    const BASELINE_BASE = 'palestria_newClientBaseline';   // '1' dopo la prima semina (anti-flood)
    // Namespacing per org: lo stesso dispositivo può servire admin di org diverse; la baseline
    // e il set "già visti" devono essere separati per tenant (i roster sono già org-scoped).
    const _orgSuffix = () => `_${(typeof window !== 'undefined' && window._orgId) ? window._orgId : 'default'}`;
    const SEEN_KEY     = () => SEEN_BASE + _orgSuffix();
    const BASELINE_KEY = () => BASELINE_BASE + _orgSuffix();

    let _booted    = false;
    let _wasHidden = false;
    let _shownIds  = [];   // userId attualmente nel popup (acquisiti alla chiusura)

    // Icona "aggiungi contatto" (persona con +) per l'header del popup.
    const ICON_ADD = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><line x1="19" y1="8" x2="19" y2="14"/><line x1="22" y1="11" x2="16" y2="11"/></svg>';
    // Logo WhatsApp (glifo bianco su bottone verde).
    const ICON_WA  = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M17.5 14.4c-.3-.15-1.77-.87-2.04-.97-.27-.1-.47-.15-.67.15-.2.3-.77.97-.94 1.17-.17.2-.35.22-.65.07-.3-.15-1.26-.46-2.4-1.48-.89-.79-1.49-1.77-1.66-2.07-.17-.3-.02-.46.13-.61.14-.13.3-.35.45-.52.15-.17.2-.3.3-.5.1-.2.05-.37-.02-.52-.07-.15-.67-1.62-.92-2.22-.24-.58-.49-.5-.67-.51l-.57-.01c-.2 0-.52.07-.8.37-.27.3-1.05 1.02-1.05 2.49 0 1.47 1.08 2.89 1.23 3.09.15.2 2.11 3.22 5.12 4.51.71.31 1.27.49 1.7.63.72.23 1.37.2 1.88.12.57-.09 1.77-.72 2.02-1.42.25-.7.25-1.3.17-1.42-.07-.12-.27-.2-.57-.35z"/><path d="M12 2C6.48 2 2 6.48 2 12c0 1.85.5 3.58 1.38 5.07L2 22l5.05-1.32A9.96 9.96 0 0 0 12 22c5.52 0 10-4.48 10-10S17.52 2 12 2zm0 18.2c-1.68 0-3.24-.49-4.55-1.34l-.33-.2-2.99.78.8-2.9-.21-.34A8.16 8.16 0 0 1 3.8 12 8.2 8.2 0 1 1 12 20.2z"/></svg>';
    // Cornetta telefono (glifo bianco su bottone viola).
    const ICON_TEL = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M6.62 10.79c1.44 2.83 3.76 5.14 6.59 6.59l2.2-2.2c.27-.27.67-.36 1.02-.24 1.12.37 2.33.57 3.57.57.55 0 1 .45 1 1V20c0 .55-.45 1-1 1-9.39 0-17-7.61-17-17 0-.55.45-1 1-1h3.5c.55 0 1 .45 1 1 0 1.25.2 2.45.57 3.57.11.35.03.74-.25 1.02l-2.18 2.18z"/></svg>';
    // Icona "i" (cerchio + gambo + puntino) per il bottone info.
    const ICON_INFO = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="11"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>';

    function esc(s) { return typeof _escHtml === 'function' ? _escHtml(s) : String(s ?? ''); }

    // ── Parsing codice fiscale → { sesso, eta } (campi null se non ricavabili) ────────
    // Struttura CF (car. 1-based): 7-8 anno (2 cifre), 9 mese (lettera), 10-11 giorno
    // (per le donne = giorno + 40). Secolo (euristica): prova 2000+YY, se la data cade nel
    // futuro usa 1900+YY (nessun cliente ha >100 anni). Il sesso resta noto anche se il
    // giorno è implausibile; l'età si omette se mese/giorno non validi.
    function parseCF(cf) {
        const s = String(cf || '').toUpperCase().trim();
        const out = { sesso: null, eta: null };
        if (s.length < 11) return out;
        let day = parseInt(s.slice(9, 11), 10);
        if (!Number.isNaN(day)) {
            out.sesso = day > 40 ? 'Donna' : 'Uomo';
            if (day > 40) day -= 40;
        }
        const yy = parseInt(s.slice(6, 8), 10);
        const monthMap = { A:1, B:2, C:3, D:4, E:5, H:6, L:7, M:8, P:9, R:10, S:11, T:12 };
        const mo = monthMap[s.charAt(8)];
        if (!Number.isNaN(yy) && mo && !Number.isNaN(day) && day >= 1 && day <= 31) {
            const now = new Date();
            let year = 2000 + yy;
            let birth = new Date(year, mo - 1, day);
            if (birth > now) { year = 1900 + yy; birth = new Date(year, mo - 1, day); }
            let age = now.getFullYear() - year;
            const mDiff = now.getMonth() - (mo - 1);
            if (mDiff < 0 || (mDiff === 0 && now.getDate() < day)) age--;
            if (age >= 0 && age <= 120) out.eta = age;
        }
        return out;
    }

    // ── Gate ambiente ─────────────────────────────────────────────────────────────
    function isAdmin() {
        try { return sessionStorage.getItem('adminAuth') === 'true'; } catch (_) { return false; }
    }
    function isMobileOrPwa() {
        const standalone = window.navigator.standalone === true ||
            (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches);
        return standalone || window.innerWidth <= 768;
    }

    // ── Set "già visti" su localStorage (namespaced per org) ────────────────────────
    function loadSeen() {
        try {
            const raw = localStorage.getItem(SEEN_KEY());
            const arr = raw ? JSON.parse(raw) : [];
            return new Set(Array.isArray(arr) ? arr : []);
        } catch (_) { return new Set(); }
    }
    function saveSeen(set) {
        try { localStorage.setItem(SEEN_KEY(), JSON.stringify([...set])); } catch (_) {}
    }
    function markSeen(ids) {
        if (!ids || !ids.length) return;
        const set = loadSeen();
        ids.forEach(id => id && set.add(id));
        saveSeen(set);
    }
    function baselineDone() {
        try { return localStorage.getItem(BASELINE_KEY()) === '1'; } catch (_) { return false; }
    }
    function setBaselineDone() {
        try { localStorage.setItem(BASELINE_KEY(), '1'); } catch (_) {}
    }

    // ── Anagrafica completa (stesso criterio di auth.js isAnagraficaComplete, su
    //    campi camelCase del roster admin UserStorage) ──────────────────────────────
    function isComplete(u) {
        return !!(
            u && u.userId &&
            String(u.whatsapp || '').trim() &&
            String(u.codiceFiscale || '').trim() &&
            String(u.indirizzoVia || '').trim() &&
            String(u.indirizzoPaese || '').trim() &&
            String(u.indirizzoCap || '').trim()
        );
    }

    // Profili registrati completi (solo account reali: _fromSupabase + userId)
    function completeClients() {
        if (typeof UserStorage === 'undefined' || !Array.isArray(UserStorage._cache)) return [];
        return UserStorage._cache.filter(u => u && u._fromSupabase && isComplete(u));
    }

    // ── CSS (iniettato una sola volta) ──────────────────────────────────────────────
    function injectStyles() {
        if (document.getElementById('ncp-styles')) return;
        const css = `
.ncp-overlay {
    position: fixed; inset: 0; z-index: 3000;
    background: rgba(0,0,0,0.55); backdrop-filter: blur(2px);
    display: flex; align-items: center; justify-content: center; padding: 16px;
    animation: ncpFade .2s ease;
}
@keyframes ncpFade { from { opacity: 0 } to { opacity: 1 } }
.ncp-box {
    position: relative; width: 100%; max-width: 420px;
    max-height: 85vh; overflow-y: auto;
    background: #fff; border-radius: 18px;
    box-shadow: 0 20px 60px rgba(0,0,0,0.3);
    padding: 26px 20px 20px;
    animation: ncpPop .25s cubic-bezier(.18,.89,.32,1.28);
}
@keyframes ncpPop { from { transform: translateY(12px) scale(.96); opacity: 0 } to { transform: none; opacity: 1 } }
.ncp-close {
    position: absolute; top: 12px; right: 12px;
    width: 32px; height: 32px; border: none; border-radius: 50%;
    background: #f1f3f5; color: #555; font-size: 15px; line-height: 32px; cursor: pointer;
}
.ncp-close:hover { background: #e2e6ea; }
.ncp-head { text-align: center; margin-bottom: 18px; }
.ncp-icon {
    width: 56px; height: 56px; margin: 0 auto 12px;
    display: flex; align-items: center; justify-content: center;
    background: rgba(139,92,246,0.12); color: #8B5CF6; border-radius: 50%;
}
.ncp-icon svg { width: 30px; height: 30px; }
.ncp-title { font-size: 1.15rem; font-weight: 800; color: #1a1a1a; }
.ncp-sub { font-size: .9rem; color: #666; margin-top: 4px; }
.ncp-list { display: flex; flex-direction: column; gap: 12px; }
.ncp-item { position: relative; border: 1px solid #eceff1; border-radius: 14px; padding: 14px; background: #fafbfc; }
.ncp-item__name { font-weight: 800; color: #1a1a1a; font-size: 1.05rem; padding-right: 36px; }
.ncp-info-btn {
    position: absolute; top: 12px; right: 12px;
    width: 28px; height: 28px; border: none; border-radius: 50%;
    background: rgba(139,92,246,0.10); color: #8B5CF6; cursor: pointer;
    display: flex; align-items: center; justify-content: center;
    transition: background-color .2s, transform .1s;
}
.ncp-info-btn svg { width: 16px; height: 16px; }
.ncp-info-btn:hover { background: rgba(139,92,246,0.18); }
.ncp-info-btn:active { transform: scale(.92); }
.ncp-info-btn.is-active { background: #8B5CF6; color: #fff; }
.ncp-info {
    display: none; margin-top: 10px;
    background: #f6f4fb; border: 1px solid #ece7f6; border-radius: 10px;
    padding: 10px 12px;
}
.ncp-info.is-open { display: block; animation: ncpInfo .18s ease; }
@keyframes ncpInfo { from { opacity: 0; transform: translateY(-4px) } to { opacity: 1; transform: none } }
.ncp-info__row { display: flex; align-items: center; gap: 8px; font-size: .92rem; color: #34404b; }
.ncp-info__row + .ncp-info__row { margin-top: 7px; }
.ncp-info__ico { font-size: 1rem; line-height: 1; width: 20px; text-align: center; flex: 0 0 auto; }
.ncp-info__val { font-weight: 700; color: #1a1a1a; }
.ncp-item__phone { font-size: .95rem; color: #5a6672; margin-top: 3px; letter-spacing: .2px; }
.ncp-item__actions { display: flex; gap: 8px; margin-top: 12px; }
.ncp-btn {
    flex: 1; display: inline-flex; align-items: center; justify-content: center; gap: 7px;
    padding: 11px 12px; border: none; border-radius: 10px;
    font-size: .92rem; font-weight: 700; cursor: pointer; text-decoration: none;
    transition: transform .1s, background-color .2s, opacity .2s;
}
.ncp-btn:active { transform: scale(.97); }
.ncp-btn svg { width: 18px; height: 18px; }
.ncp-btn--wa  { background: #25d366; color: #fff; }
.ncp-btn--wa:hover  { background: #1fb757; }
.ncp-btn--tel { background: #8B5CF6; color: #fff; }
.ncp-btn--tel:hover { background: #7C3AED; }
body.ncp-open { overflow: hidden; }`;
        const style = document.createElement('style');
        style.id = 'ncp-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }

    // ── Popup ───────────────────────────────────────────────────────────────────────
    function ensureRoot() {
        let root = document.getElementById('newClientPopup');
        if (root) return root;
        root = document.createElement('div');
        root.id = 'newClientPopup';
        root.className = 'ncp-overlay';
        root.style.display = 'none';
        root.addEventListener('click', (e) => { if (e.target === root) closePopup(); });
        document.body.appendChild(root);
        return root;
    }

    function renderPopup(clients) {
        const root = ensureRoot();
        const n = clients.length;
        const subtitle = n === 1
            ? 'Aggiungilo alla rubrica'
            : `Hai <b>${n}</b> nuovi clienti da aggiungere`;
        const items = clients.map(c => {
            const name  = c.name || 'Nuovo cliente';
            const phone = String(c.whatsapp || '').trim();
            const telHref = 'tel:' + phone.replace(/[^\d+]/g, '');       // solo + e cifre
            const waHref  = 'https://wa.me/' + phone.replace(/\D/g, ''); // solo cifre
            // Pannello info (👤 sesso / 🎂 età dal CF, 📍 comune dall'anagrafica)
            const cf = parseCF(c.codiceFiscale);
            const comune = String(c.indirizzoPaese || '').trim();
            const rows = [];
            if (cf.sesso)      rows.push(`<div class="ncp-info__row"><span class="ncp-info__ico">👤</span><span class="ncp-info__val">${esc(cf.sesso)}</span></div>`);
            if (cf.eta != null) rows.push(`<div class="ncp-info__row"><span class="ncp-info__ico">🎂</span><span class="ncp-info__val">${esc(cf.eta + ' anni')}</span></div>`);
            if (comune)        rows.push(`<div class="ncp-info__row"><span class="ncp-info__ico">📍</span><span class="ncp-info__val">${esc(comune)}</span></div>`);
            const infoHTML = rows.length ? rows.join('')
                : `<div class="ncp-info__row"><span class="ncp-info__val" style="color:#8a95a1;font-weight:600">Dati non disponibili</span></div>`;
            return `
                <div class="ncp-item">
                    <button class="ncp-info-btn" type="button" aria-label="Info cliente" aria-expanded="false">${ICON_INFO}</button>
                    <div class="ncp-item__name">${esc(name)}</div>
                    <div class="ncp-item__phone">${esc(phone)}</div>
                    <div class="ncp-info">${infoHTML}</div>
                    <div class="ncp-item__actions">
                        <a class="ncp-btn ncp-btn--wa" href="${esc(waHref)}" target="_blank" rel="noopener">${ICON_WA}WhatsApp</a>
                        <a class="ncp-btn ncp-btn--tel" href="${esc(telHref)}">${ICON_TEL}Telefono</a>
                    </div>
                </div>`;
        }).join('');
        root.innerHTML = `
            <div class="ncp-box" role="dialog" aria-modal="true" aria-label="Nuovo cliente iscritto">
                <button class="ncp-close" type="button" aria-label="Chiudi">✕</button>
                <div class="ncp-head">
                    <div class="ncp-icon" aria-hidden="true">${ICON_ADD}</div>
                    <div class="ncp-title">${n === 1 ? 'Nuovo cliente iscritto' : `${n} nuovi clienti iscritti`}</div>
                    <div class="ncp-sub">${subtitle}</div>
                </div>
                <div class="ncp-list">${items}</div>
            </div>`;
        root.querySelector('.ncp-close').addEventListener('click', closePopup);
        // Toggle del pannello info (delegato): apre/chiude e sincronizza stato del bottone.
        const list = root.querySelector('.ncp-list');
        if (list) list.addEventListener('click', (e) => {
            const btn = e.target.closest('.ncp-info-btn');
            if (!btn) return;
            const panel = btn.closest('.ncp-item')?.querySelector('.ncp-info');
            if (!panel) return;
            const open = panel.classList.toggle('is-open');
            btn.classList.toggle('is-active', open);
            btn.setAttribute('aria-expanded', open ? 'true' : 'false');
        });
    }

    function openPopup(clients) {
        if (!clients.length) return;
        _shownIds = clients.map(c => c.userId).filter(Boolean);
        renderPopup(clients);
        ensureRoot().style.display = 'flex';
        document.body.classList.add('ncp-open');
    }

    // Chiusura volontaria: acquisisce i clienti mostrati → non ricompaiono più
    function closePopup() {
        const root = document.getElementById('newClientPopup');
        if (root) root.style.display = 'none';
        document.body.classList.remove('ncp-open');
        markSeen(_shownIds);
        _shownIds = [];
    }

    // ── Decisione (no rete): confronta roster completo con il set "già visti" ─────────
    function decide() {
        if (!isAdmin()) return;
        const clients = completeClients();

        // Primo avvio in assoluto (per questa org): semina la baseline → niente popup
        if (!baselineDone()) {
            markSeen(clients.map(c => c.userId));
            setBaselineDone();
            return;
        }

        const root = document.getElementById('newClientPopup');
        if (root && root.style.display !== 'none') return; // già aperto: non ridisegnare

        const seen = loadSeen();
        const fresh = [];
        const freshKeys = new Set();
        for (const c of clients) {
            if (!c.userId || seen.has(c.userId) || freshKeys.has(c.userId)) continue;
            freshKeys.add(c.userId);
            fresh.push(c);
        }
        if (fresh.length) openPopup(fresh);
    }

    // Attende che il roster admin sia stato sincronizzato almeno una volta (il boot di
    // admin.html chiama UserStorage.syncUsersFromSupabase() prima del primo render).
    async function _waitForRoster(maxMs = 15000, stepMs = 300) {
        let waited = 0;
        while (waited < maxMs) {
            if (typeof UserStorage !== 'undefined' &&
                Array.isArray(UserStorage._cache) && UserStorage._cache.length) return true;
            await new Promise(r => setTimeout(r, stepMs));
            waited += stepMs;
        }
        return typeof UserStorage !== 'undefined' && Array.isArray(UserStorage._cache) && UserStorage._cache.length > 0;
    }

    async function syncAndDecide() {
        try {
            if (typeof UserStorage !== 'undefined' && UserStorage.syncUsersFromSupabase) {
                await UserStorage.syncUsersFromSupabase(); // rispetta il TTL/fingerprint: cheap
            }
        } catch (_) {}
        decide();
    }

    // ── Boot ──────────────────────────────────────────────────────────────────────
    function boot() {
        if (_booted) return;
        // Gate mobile/PWA qui (sincrono e stabile). Il gate ADMIN NON va qui: al
        // DOMContentLoaded initAuth() (async) potrebbe non aver ancora impostato
        // sessionStorage.adminAuth → gaterebbe fuori il popup per sempre. L'admin è
        // verificato in decide() e, di fatto, atteso: il roster (get_all_profiles_basic,
        // is_org_admin server-side) si popola solo DOPO che initAuth ha settato adminAuth.
        if (!isMobileOrPwa()) return;
        _booted = true;
        injectStyles();

        _waitForRoster().then(decide);

        document.addEventListener('visibilitychange', () => {
            if (document.hidden) { _wasHidden = true; return; }
            if (_wasHidden) {
                _wasHidden = false;
                _waitForRoster().then(syncAndDecide);
            }
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }

    // API per debug / integrazione manuale
    window.NewClientPopup = { refresh: syncAndDecide, _decide: decide };
})();
