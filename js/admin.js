/**
 * admin.js — Bootstrap e orchestrazione del pannello admin (entry point della dashboard).
 *
 * COSA FA
 * Inizializza la dashboard admin, gestisce la navigazione a tab, l'accesso per ruolo,
 * gli offset sticky dell'header e la modalità "privacy" che maschera i dati sensibili.
 * È il file che lega insieme gli altri moduli admin-* (calendar/clients/analytics/registro/...).
 *
 * COME FUNZIONA
 * - Init: initAdmin() (guard window._adminInitialized) prepara il contesto org via
 *   _ensureAdminOrgContext() — legge org_id/role da org_members quando il claim JWT è assente —
 *   poi showDashboard()/hideDashboard().
 * - Accesso: ADMIN_UI_ROLES = ['owner','admin','staff']; hasAdminUiAccess() (UI visibile a tutti
 *   e tre) e isOrgAdminRole() (solo owner/admin) si basano sul ruolo verificato window._orgRole,
 *   NON sul flag sessionStorage. Il server resta l'autorità (RLS/RPC).
 * - Tab: setupTabs() + switchTab(tabName) commutano tra i pannelli (Prenotazioni, Clienti,
 *   Dashboard/Stats, Registro, Schede, Impostazioni, ...) delegando il render ai rispettivi
 *   file admin-*.js.
 * - Sticky/privacy: setupAdminStickyOffsets() gestisce navbar/.admin-tabs/.admin-calendar-controls/
 *   .admin-day-selector su scroll/resize; SENSITIVE_IDS + toggleSensitiveData()/_applyPrivacyMask()/
 *   sensitiveSet() mascherano (***) importi e liste debitori/creditori (stato in
 *   localStorage 'adminSensitiveHidden', pulsante #btnToggleSensitive).
 *
 * CONNESSIONI
 * - Legge la sessione/contesto org via supabaseAuth/supabaseClient (tabella org_members),
 *   org-scoped da RLS; popola window._orgId/_orgRole.
 * - Coordina i moduli: admin-calendar.js, admin-clients.js, admin-analytics.js,
 *   admin-registro.js, admin-backup.js e gli altri admin-*.js (schede/settings/...).
 */
// Admin dashboard functionality


// ── Privacy toggle ──────────────────────────────────────────────────────────
const SENSITIVE_IDS = ['totalUnpaid','totalDebtors','totalCreditors','totalCreditAmount','monthlyRevenue','revenueChange'];
let _sensitiveHidden = localStorage.getItem('adminSensitiveHidden') === 'true';

// Scrive il valore nell'elemento e lo salva in dataset; rispetta la modalità privacy
function sensitiveSet(id, value) {
    const el = document.getElementById(id);
    if (!el) return;
    el.dataset.realValue = value;
    el.textContent = _sensitiveHidden ? '***' : value;
}

function _applyPrivacyMask() {
    SENSITIVE_IDS.forEach(id => {
        const el = document.getElementById(id);
        if (!el) return;
        if (_sensitiveHidden) {
            if (!el.dataset.realValue) el.dataset.realValue = el.textContent;
            el.textContent = '***';
        } else {
            if (el.dataset.realValue) el.textContent = el.dataset.realValue;
        }
    });
    // Liste debitori/creditori: nascondile del tutto quando i dati sono nascosti
    const dl = document.getElementById('debtorsList');
    const cl = document.getElementById('creditsList');
    if (_sensitiveHidden) {
        if (dl) dl.style.display = 'none';
        if (cl) cl.style.display = 'none';
    }
    const btn = document.getElementById('btnToggleSensitive');
    if (btn) btn.textContent = _sensitiveHidden ? '🙈' : '👁';
}

function toggleSensitiveData() {
    _sensitiveHidden = !_sensitiveHidden;
    localStorage.setItem('adminSensitiveHidden', _sensitiveHidden ? 'true' : 'false');
    _applyPrivacyMask();
}
// ────────────────────────────────────────────────────────────────────────────

let _adminStickyResizeHandler = null;
let _adminScrollHandler = null;
function setupAdminStickyOffsets() {
    const navbar = document.querySelector('.navbar');
    const tabs = document.querySelector('.admin-tabs');
    const controls = document.querySelector('.admin-calendar-controls');
    const daySelector = document.querySelector('.admin-day-selector');
    if (!navbar || !tabs) return;

    const _apply = () => {
        const navH = navbar.offsetHeight - 1;
        tabs.style.top = navH + 'px';
        if (window.innerWidth <= 768) {
            if (controls) controls.style.top = '';
            if (daySelector) daySelector.style.top = '';
        } else {
            const tabsBottom = navH + tabs.offsetHeight;
            if (controls) controls.style.top = tabsBottom + 'px';
            if (daySelector && controls) daySelector.style.top = (tabsBottom + controls.offsetHeight) + 'px';
        }
    };
    _apply();
    if (_adminStickyResizeHandler) window.removeEventListener('resize', _adminStickyResizeHandler);
    _adminStickyResizeHandler = _apply;
    window.addEventListener('resize', _adminStickyResizeHandler);

    // Hide week nav once scrolled past threshold, show only at top
    if (_adminScrollHandler) window.removeEventListener('scroll', _adminScrollHandler);
    _adminScrollHandler = () => {
        if (!controls) return;
        const sy = window.scrollY;
        if (sy > 120 && !controls.classList.contains('scroll-hidden')) {
            controls.classList.add('scroll-hidden');
            if (daySelector && window.innerWidth > 768) {
                const tabsBottom = (navbar.offsetHeight - 1) + tabs.offsetHeight;
                daySelector.style.top = tabsBottom + 'px';
            }
        } else if (sy <= 10 && controls.classList.contains('scroll-hidden')) {
            controls.classList.remove('scroll-hidden');
            _apply();
        }
    };
    window.addEventListener('scroll', _adminScrollHandler, { passive: true });
}

// Ruoli con accesso alla UI admin: owner/admin/staff (verificati server-side via
// org_members / claim JWT). Le scritture restano protette da RLS/RPC: lo staff
// vede la dashboard ma non può fare ciò che il server gli nega.
const ADMIN_UI_ROLES = ['owner', 'admin', 'staff'];

// True se l'utente ha accesso alla UI admin in base al RUOLO verificato
// (window._orgRole), NON al flag sessionStorage (manipolabile da console).
function hasAdminUiAccess() {
    return ADMIN_UI_ROLES.includes(window._orgRole);
}

// True solo per owner/admin: per azioni/UI che lo staff non deve vedere.
function isOrgAdminRole() {
    return window._orgRole === 'owner' || window._orgRole === 'admin';
}

// Garantisce window._orgId/_orgRole leggendo da org_members quando il claim JWT
// è assente (auth hook disabilitato): l'owner/staff non ha il claim, ma MOLTE
// feature admin (orari, impostazioni) inseriscono org_id = window._orgId.
async function _ensureAdminOrgContext() {
    if (window._orgId && window._orgRole) return window._orgId;
    if (typeof supabaseClient === 'undefined') return window._orgId || null;
    try {
        const { data: { session } } = await supabaseAuth.auth.getSession();
        if (!session) return window._orgId || null;
        const { data: m } = await supabaseClient
            .from('org_members')
            .select('org_id, role')
            .eq('user_id', session.user.id)
            .eq('status', 'active')
            .order('created_at', { ascending: true })
            .limit(1)
            .maybeSingle();
        if (m) {
            window._orgId   = window._orgId   || m.org_id;
            window._orgRole = window._orgRole || m.role;
            // Propaga il flag legacy a sessionStorage per i ruoli con accesso UI
            // (incluso staff): alcuni boot path / moduli fuori scope lo leggono.
            // L'autorità resta il RUOLO verificato + RLS/RPC lato server.
            if (ADMIN_UI_ROLES.includes(window._orgRole)) sessionStorage.setItem('adminAuth', 'true');
        }
    } catch (_) { /* offline / nessuna membership */ }
    return window._orgId || null;
}

async function initAdmin() {
    if (window._adminInitialized) return;
    window._adminInitialized = true;

    // 0) Gate accesso admin: attende la verifica del ruolo fatta dal boot di
    //    admin.html (window._adminAccessGate). I non-admin sono già rediretti dal
    //    gate; qui ci limitiamo a NON renderizzare nulla (niente showDashboard).
    if (window._adminAccessGate && (await window._adminAccessGate) !== true) return;

    // 1) Contesto org PRIMA di tutto (serve a orari/impostazioni per gli insert org_id).
    await _ensureAdminOrgContext();

    // 1b) Gate basato sul RUOLO verificato server-side (owner/admin/staff), non sul
    //     flag sessionStorage. È l'autorità di accesso UI dentro questo scope: se il
    //     ruolo non è tra quelli abilitati, non renderizziamo nulla (le scritture
    //     restano comunque protette da RLS/RPC).
    if (!hasAdminUiAccess()) return;
    // 2) Ricarica config orari (slot_types/fasce/template attivo) e impostazioni org
    //    ora che window._orgId è disponibile → calendario e settings mostrano i dati giusti.
    if (typeof loadOrgScheduleConfig === 'function') { try { await loadOrgScheduleConfig(); } catch (_) {} }
    if (typeof OrgSettings !== 'undefined') {
        try { await OrgSettings.load(); if (OrgSettings.applyBranding) OrgSettings.applyBranding(); } catch (_) {}
    }

    // 3) Entitlements del piano SaaS + feature gating UI (fail-open).
    if (typeof Entitlements !== 'undefined') {
        try {
            await Entitlements.load();
            Entitlements.applyFeatureGating();
        } catch (e) {
            console.warn('[admin] feature gating non applicato:', e && e.message);
        }
    }

    showDashboard();
    setupAdminStickyOffsets();

    // Close search dropdown when clicking outside
    document.addEventListener('click', (e) => {
        const search = document.querySelector('.payment-search');
        if (search && !search.contains(e.target)) {
            closeSearchDropdown();
        }
    });
}


function showDashboard() {
    // Difesa-in-profondità: assicura la rimozione dell'overlay del gate accesso
    // (di norma già rimosso dal boot quando adminAuth è confermato).
    document.getElementById('adminGateOverlay')?.remove();
    // Rimuove l'inline style precedente (da hideDashboard), lascia decidere al CSS
    // (su desktop >=1024px .dashboard-section diventa flex per il layout sidebar+main).
    document.getElementById('dashboardSection').style.display = '';
    setupTabs();
    setupAdminCalendar();
    setupScheduleManager();
    updateNonChartData();
    checkWeeklyReportBanner();
    // Ripristina il tab attivo dal refresh (default: bookings)
    const savedTab = sessionStorage.getItem('adminActiveTab');
    if (savedTab && document.getElementById(`tab-${savedTab}`)) {
        switchTab(savedTab);
    }
    // Anti-flash: rimuove il marker setato dall'inline script in <head>,
    // così le regole CSS non interferiscono con i cambi tab successivi.
    document.documentElement.removeAttribute('data-initial-tab');
}

// Tab Management
function setupTabs() {
    const tabs = document.querySelectorAll('.admin-tab');
    tabs.forEach(tab => {
        tab.addEventListener('click', () => {
            const tabName = tab.dataset.tab;
            if (!tabName) return;
            switchTab(tabName);
        });
    });
}

function switchTab(tabName) {
    // "Importa" è ora un sub-tab di Schede: remap retroattivo.
    let _schedeJumpToImporta = false;
    if (tabName === 'importa') {
        tabName = 'schede';
        _schedeJumpToImporta = true;
    }

    // Persisti il tab attivo per il refresh
    try { sessionStorage.setItem('adminActiveTab', tabName); } catch {}

    // Update tab buttons
    document.querySelectorAll('.admin-tab').forEach(tab => {
        tab.classList.remove('active');
        if (tab.dataset.tab === tabName) {
            tab.classList.add('active');
        }
    });

    // Container sempre "wide" (1280px): allinea il div tab-content sotto
    // alla barra .admin-tabs (anch'essa cap 1280px) → larghezze coerenti
    // fra tutte le tab, non solo Importa.
    const adminContainer = document.querySelector('.dashboard-section .container');
    if (adminContainer) adminContainer.classList.add('container--wide');

    // Update tab content
    document.querySelectorAll('.tab-content').forEach(content => {
        content.classList.remove('active');
    });
    document.getElementById(`tab-${tabName}`).classList.add('active');

    // Mostra/nascondi FAB Pagamenti
    const fab = document.getElementById('paymentsFab');
    if (fab) fab.style.display = tabName === 'payments' ? 'flex' : 'none';

    window.scrollTo({ top: 0 });

    // Mostra/nascondi FAB Slot Corrente (solo tab bookings)
    const scrollFab = document.getElementById('scrollToSlotFab');
    if (scrollFab) scrollFab.style.display = tabName === 'bookings' ? 'flex' : 'none';

    // Carica i dati del tab in modo asincrono: il browser renderizza prima il tab
    // (mostra il contenuto/spinner) e poi esegue il lavoro pesante senza congelare la UI.
    const loader = {
        analytics: () => requestAnimationFrame(() => requestAnimationFrame(() => loadDashboardData())),
        bookings:  () => { renderAdminCalendar(); },
        payments:  () => renderPaymentsTab('switchTab'),
        clients:   () => renderClientsTab(),
        schedule:  () => renderScheduleManager(),
        settings:  () => renderSettingsTab(),
        registro:  () => renderRegistroTab(),
        messaggi:  () => renderMessaggiTab(),
        schede:    () => {
            if (_schedeJumpToImporta && typeof _schedeSwitchSection === 'function') {
                _schedeSwitchSection('importa');
            } else {
                renderSchedeTab();
            }
        },
    }[tabName];
    if (loader) setTimeout(loader, 0);
}

function hideDashboard() {
    document.getElementById('dashboardSection').style.display = 'none';
}
