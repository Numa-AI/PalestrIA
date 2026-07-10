// ══════════════════════════════════════════════════════════════════════════════
// admin-settings.js — Tab Impostazioni org-aware, riorganizzato in 11 sotto-tab.
//
// Pattern lazy a sezioni (come schedSwitchSection / _schedeSwitchSection):
//   - nav interna in #settNav
//   - corpo renderizzato in #settBody dalla sezione attiva (settSwitchSection)
//
// Tutte le sezioni leggono/scrivono via:
//   - OrgSettings (js/org-settings.js)  → org_settings(key, value jsonb)
//   - from('billing_settings'|'slot_types'|'org_members') diretto (RLS admin)
//   - RPC invite_org_member / get_tenant_entitlements / admin_clear_all_data
//   - edge functions billing-checkout / billing-portal
//
// Gating UI: solo owner/admin vedono Staff, Billing SaaS, Sicurezza (window._orgRole).
// Le funzioni globali invocate dal markup sono definite qui.
// ══════════════════════════════════════════════════════════════════════════════

// ── Stato sezione attiva ──────────────────────────────────────────────────────
let _settActiveSection = 'branding';

// Timezone IANA comuni (lista breve, copre i casi reali per studi italiani/UE).
const SETT_TIMEZONES = [
    'Europe/Rome', 'Europe/London', 'Europe/Paris', 'Europe/Berlin',
    'Europe/Madrid', 'Europe/Lisbon', 'Europe/Zurich', 'Europe/Athens',
    'Europe/Bucharest', 'Europe/Moscow', 'America/New_York', 'America/Chicago',
    'America/Denver', 'America/Los_Angeles', 'America/Sao_Paulo', 'UTC'
];
const SETT_CURRENCIES   = ['EUR', 'USD', 'GBP', 'CHF'];
const SETT_LANGUAGES    = [['it', 'Italiano'], ['en', 'English'], ['es', 'Español'], ['de', 'Deutsch'], ['fr', 'Français']];
const SETT_DATE_FORMATS = ['DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD'];
const SETT_WEEK_DAYS    = [[1, 'Lunedì'], [0, 'Domenica']];

// Solo owner/admin possono vedere/modificare le sezioni sensibili.
function _settIsAdmin() {
    return window._orgRole === 'owner' || window._orgRole === 'admin';
}

// ── Definizione sezioni (id, icona, label, render fn, gating) ──────────────────
function _settSections() {
    const adminOnly = _settIsAdmin();
    return [
        { id: 'branding',     icon: '🎨', label: 'Branding',       render: _settRenderBranding },
        { id: 'locale',       icon: '🌍', label: 'Localizzazione', render: _settRenderLocale },
        { id: 'company',      icon: '🏢', label: 'Azienda',        render: _settRenderCompany },
        { id: 'payments',     icon: '💳', label: 'Pagamenti',      render: _settRenderPayments },
        { id: 'policy',       icon: '🛡️', label: 'Prenotazioni',   render: _settRenderPolicy },
        { id: 'notif',        icon: '🔔', label: 'Notifiche',      render: _settRenderNotif },
        { id: 'staff',        icon: '👥', label: 'Staff',          render: _settRenderStaff,    adminOnly: true },
        { id: 'gdpr',         icon: '📜', label: 'GDPR',           render: _settRenderGdpr },
        { id: 'features',     icon: '🧩', label: 'Funzionalità',   render: _settRenderFeatures },
        { id: 'billing-saas', icon: '💎', label: 'Abbonamento',    render: _settRenderBillingSaas, adminOnly: true },
        { id: 'security',     icon: '⚠️', label: 'Sicurezza',      render: _settRenderSecurity, adminOnly: true },
    ].filter(s => !s.adminOnly || adminOnly);
}

// ── Bootstrap del tab (chiamato da switchTab) ─────────────────────────────────
async function renderSettingsTab() {
    const root = document.getElementById('tab-settings');
    if (!root) return;

    // Shell: nav + corpo. Idempotente: ricrea solo se mancante.
    if (!document.getElementById('settNav')) {
        root.innerHTML = `
            <div class="sett-hub">
                <div class="sett-header">
                    <h3>Impostazioni</h3>
                    <span class="sett-header-badge">🔧 Configurazione</span>
                </div>
                <div class="sett-nav" id="settNav"></div>
                <div id="settBody"><div class="sett-loading">⏳ Caricamento impostazioni…</div></div>
            </div>`;
    }

    // Assicura che la cache OrgSettings sia popolata.
    try { if (window.OrgSettings && OrgSettings.load) await OrgSettings.load(); } catch (_) {}

    // Applica il branding persistito (nome/logo/favicon/colore/titolo) all'apertura del tab.
    _settApplyBrandingExtras();

    // Se la sezione attiva non è più visibile (es. cambio ruolo), torna a branding.
    const visible = _settSections().map(s => s.id);
    if (!visible.includes(_settActiveSection)) _settActiveSection = 'branding';

    _settRenderNav();
    _settRenderActiveSection();
}

function _settRenderNav() {
    const nav = document.getElementById('settNav');
    if (!nav) return;
    nav.innerHTML = _settSections().map(s => `
        <button class="sett-nav-btn ${s.id === _settActiveSection ? 'active' : ''}"
                onclick="settSwitchSection('${s.id}')">
            <span class="sett-nav-ico">${s.icon}</span><span class="sett-nav-lbl">${s.label}</span>
        </button>`).join('');
}

function settSwitchSection(section) {
    _settActiveSection = section;
    _settRenderNav();
    _settRenderActiveSection();
}

async function _settRenderActiveSection() {
    const body = document.getElementById('settBody');
    if (!body) return;
    const sec = _settSections().find(s => s.id === _settActiveSection);
    if (!sec) { body.innerHTML = ''; return; }
    try {
        // I render possono essere sync o async (payments/staff/billing-saas): await
        // copre entrambi i casi e cattura i reject che altrimenti lascerebbero il
        // placeholder "Caricamento…" senza messaggio d'errore.
        await sec.render(body);
    } catch (e) {
        console.error('[Settings] render error:', e);
        body.innerHTML = `<div class="sett-card"><p class="sett-card-desc">Errore nel caricamento della sezione.</p></div>`;
    }
}

// Helper: valore di un campo input/select per id.
function _settVal(id) {
    const el = document.getElementById(id);
    return el ? el.value : '';
}
function _settChecked(id) {
    const el = document.getElementById(id);
    return !!(el && el.checked);
}

// Helper salvataggio OrgSettings con feedback toast.
async function _settSave(key, value, okMsg) {
    try {
        await OrgSettings.set(key, value);
        if (okMsg !== false) showToast(okMsg || '✅ Impostazione salvata', 'success');
        return true;
    } catch (e) {
        console.error('[Settings] save error', key, e);
        showToast('Errore salvataggio impostazione', 'error');
        return false;
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 1 — BRANDING
// ════════════════════════════════════════════════════════════════════════════
//
// Applicazione del branding a runtime. La fonte di verità è la globale
// OrgSettings.applyBranding() (js/org-settings.js), che gestisce nome studio
// ([data-org-name]), logo (img[data-org-logo]), favicon, colore primario (+ dark
// derivata e <meta theme-color>) e titolo/nome PWA. Qui ci limitiamo a invocarla,
// con un fallback minimo per logo/favicon/colore nel caso (improbabile) in cui
// fosse caricata una versione più vecchia della funzione globale.
function _settApplyBrandingExtras() {
    try {
        if (window.OrgSettings && typeof OrgSettings.applyBranding === 'function') {
            OrgSettings.applyBranding();
            return;
        }
        // Fallback difensivo (versione legacy di applyBranding senza logo/favicon).
        const logo    = OrgSettings.getString('branding.logo_url', '');
        const favicon = OrgSettings.getString('branding.favicon_url', '');
        const color   = OrgSettings.getString('branding.primary_color', '');
        if (logo) document.querySelectorAll('img[data-org-logo]').forEach(img => { img.src = logo; });
        if (favicon) { const fav = document.querySelector('link[rel="icon"]'); if (fav) fav.href = favicon; }
        if (color && /^#[0-9a-fA-F]{6}$/.test(color)) {
            document.documentElement.style.setProperty('--primary-purple', color);
            const themeMeta = document.querySelector('meta[name="theme-color"]');
            if (themeMeta) themeMeta.content = color;
        }
    } catch (e) {
        console.warn('[Settings] applyBrandingExtras error:', e);
    }
}

function _settRenderBranding(body) {
    const name    = OrgSettings.getString('branding.studio_name', '');
    const logo    = OrgSettings.getString('branding.logo_url', '');
    const color   = OrgSettings.getString('branding.primary_color', '#8B5CF6');
    const favicon = OrgSettings.getString('branding.favicon_url', '');
    const pwaName = OrgSettings.getString('branding.pwa_name', '');
    const duration = OrgSettings.getString('branding.home_duration', '');

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--purple">🎨</span>
                <div>
                    <h4 class="sett-card-title">Branding studio</h4>
                    <p class="sett-card-desc">Nome, logo e colore mostrati ai clienti e nell'app installabile.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field">
                    <label class="sett-input-label">Nome studio</label>
                    <input type="text" id="brandStudioName" class="sett-text-input" value="${_escHtml(name)}" placeholder="Es. Studio Fitness Rossi">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Nome PWA (app installata)</label>
                    <input type="text" id="brandPwaName" class="sett-text-input" value="${_escHtml(pwaName)}" placeholder="Es. PalestrIA">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Durata sessione (home)</label>
                    <input type="text" id="brandHomeDuration" class="sett-text-input" value="${_escHtml(duration)}" placeholder="Es. 80 minuti">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">URL logo</label>
                    <input type="url" id="brandLogoUrl" class="sett-text-input" value="${_escHtml(logo)}" placeholder="https://…/logo.png">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">URL favicon</label>
                    <input type="url" id="brandFaviconUrl" class="sett-text-input" value="${_escHtml(favicon)}" placeholder="https://…/favicon.png">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Colore primario</label>
                    <div class="sett-color-row">
                        <input type="color" id="brandPrimaryColor" class="sett-color-input" value="${_escHtml(color || '#8B5CF6')}"
                               oninput="document.getElementById('brandPrimaryColorHex').value=this.value">
                        <input type="text" id="brandPrimaryColorHex" class="sett-text-input sett-text-input--hex" value="${_escHtml(color || '#8B5CF6')}"
                               oninput="document.getElementById('brandPrimaryColor').value=this.value" maxlength="7">
                    </div>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--purple" onclick="saveBrandingSettings()">💾 Salva branding</button>
            </div>
        </div>`;

    // Applica subito il branding persistito (logo/favicon/titolo/colore) così
    // l'admin vede lo stato reale anche aprendo il tab senza salvare.
    _settApplyBrandingExtras();
}

async function saveBrandingSettings() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    const name    = _settVal('brandStudioName').trim();
    const pwaName = _settVal('brandPwaName').trim();
    const logo    = _settVal('brandLogoUrl').trim();
    const favicon = _settVal('brandFaviconUrl').trim();
    const color   = (_settVal('brandPrimaryColorHex') || _settVal('brandPrimaryColor')).trim();

    try {
        await OrgSettings.set('branding.studio_name', name);
        await OrgSettings.set('branding.pwa_name', pwaName);
        await OrgSettings.set('branding.logo_url', logo);
        await OrgSettings.set('branding.favicon_url', favicon);
        await OrgSettings.set('branding.primary_color', color);
        await OrgSettings.set('branding.home_duration', _settVal('brandHomeDuration').trim());
        // Applica subito il branding (nome, logo, favicon, colore, titolo) a runtime.
        _settApplyBrandingExtras();
        showToast('✅ Branding salvato', 'success');
    } catch (e) {
        console.error('[Settings] branding save error:', e);
        showToast('Errore salvataggio branding', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 2 — LOCALIZZAZIONE
// ════════════════════════════════════════════════════════════════════════════
function _settRenderLocale(body) {
    const tz     = OrgSettings.getString('locale.timezone', 'Europe/Rome');
    const cur    = OrgSettings.getString('locale.currency', 'EUR');
    const lang   = OrgSettings.getString('locale.language', 'it');
    const dfmt   = OrgSettings.getString('locale.date_format', 'DD/MM/YYYY');
    const fdow   = OrgSettings.getNumber('locale.first_day_of_week', 1);

    const tzOpts   = SETT_TIMEZONES.map(t => `<option value="${t}" ${t === tz ? 'selected' : ''}>${t}</option>`).join('');
    const curOpts  = SETT_CURRENCIES.map(c => `<option value="${c}" ${c === cur ? 'selected' : ''}>${c}</option>`).join('');
    const langOpts = SETT_LANGUAGES.map(([v, l]) => `<option value="${v}" ${v === lang ? 'selected' : ''}>${l}</option>`).join('');
    const dfmtOpts = SETT_DATE_FORMATS.map(f => `<option value="${f}" ${f === dfmt ? 'selected' : ''}>${f}</option>`).join('');
    const fdowOpts = SETT_WEEK_DAYS.map(([v, l]) => `<option value="${v}" ${v === fdow ? 'selected' : ''}>${l}</option>`).join('');

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--blue">🌍</span>
                <div>
                    <h4 class="sett-card-title">Localizzazione</h4>
                    <p class="sett-card-desc">Fuso orario, valuta, lingua e formati usati in tutta la piattaforma.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field">
                    <label class="sett-input-label">Fuso orario</label>
                    <select id="locTimezone" class="sett-select">${tzOpts}</select>
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Valuta</label>
                    <select id="locCurrency" class="sett-select">${curOpts}</select>
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Lingua</label>
                    <select id="locLanguage" class="sett-select">${langOpts}</select>
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Formato data</label>
                    <select id="locDateFormat" class="sett-select">${dfmtOpts}</select>
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Primo giorno settimana</label>
                    <select id="locFirstDay" class="sett-select">${fdowOpts}</select>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--blue" onclick="saveLocaleSettings()">💾 Salva localizzazione</button>
            </div>
        </div>`;
}

async function saveLocaleSettings() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    try {
        await OrgSettings.set('locale.timezone', _settVal('locTimezone'));
        await OrgSettings.set('locale.currency', _settVal('locCurrency'));
        await OrgSettings.set('locale.language', _settVal('locLanguage'));
        await OrgSettings.set('locale.date_format', _settVal('locDateFormat'));
        await OrgSettings.set('locale.first_day_of_week', parseInt(_settVal('locFirstDay'), 10));
        showToast('✅ Localizzazione salvata', 'success');
    } catch (e) {
        console.error('[Settings] locale save error:', e);
        showToast('Errore salvataggio localizzazione', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 3 — DATI AZIENDA / FISCALI
// ════════════════════════════════════════════════════════════════════════════
function _settRenderCompany(body) {
    const legal   = OrgSettings.getString('company.legal_name', '');
    const vat     = OrgSettings.getString('company.vat_number', '');
    const tax     = OrgSettings.getString('company.tax_code', '');
    const addr    = OrgSettings.get('company.address', {}) || {};
    const pec     = OrgSettings.getString('company.pec', '');
    const sdi     = OrgSettings.getString('company.sdi_code', '');
    const prefix  = OrgSettings.getString('company.invoice_prefix', '');
    const maps    = OrgSettings.getString('company.maps_url', '');

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--green">🏢</span>
                <div>
                    <h4 class="sett-card-title">Dati azienda &amp; fiscali</h4>
                    <p class="sett-card-desc">Ragione sociale, partita IVA e dati per la fatturazione.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field">
                    <label class="sett-input-label">Ragione sociale</label>
                    <input type="text" id="coLegalName" class="sett-text-input" value="${_escHtml(legal)}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Partita IVA</label>
                    <input type="text" id="coVatNumber" class="sett-text-input" value="${_escHtml(vat)}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Codice fiscale</label>
                    <input type="text" id="coTaxCode" class="sett-text-input" value="${_escHtml(tax)}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">PEC</label>
                    <input type="email" id="coPec" class="sett-text-input" value="${_escHtml(pec)}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Codice SDI</label>
                    <input type="text" id="coSdiCode" class="sett-text-input" value="${_escHtml(sdi)}" maxlength="7">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Prefisso fattura</label>
                    <input type="text" id="coInvoicePrefix" class="sett-text-input" value="${_escHtml(prefix)}" placeholder="Es. 2026/">
                </div>
            </div>
            <div class="sett-subheader">Indirizzo</div>
            <div class="sett-form-grid">
                <div class="sett-field sett-field--wide">
                    <label class="sett-input-label">Via</label>
                    <input type="text" id="coAddrVia" class="sett-text-input" value="${_escHtml(addr.via || '')}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">CAP</label>
                    <input type="text" id="coAddrCap" class="sett-text-input" value="${_escHtml(addr.cap || '')}" maxlength="5">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Città</label>
                    <input type="text" id="coAddrCitta" class="sett-text-input" value="${_escHtml(addr.citta || '')}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Provincia</label>
                    <input type="text" id="coAddrProvincia" class="sett-text-input" value="${_escHtml(addr.provincia || '')}" maxlength="2">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Paese</label>
                    <input type="text" id="coAddrPaese" class="sett-text-input" value="${_escHtml(addr.paese || 'Italia')}">
                </div>
                <div class="sett-field sett-field--wide">
                    <label class="sett-input-label">Link Google Maps (mostrato nella home)</label>
                    <input type="url" id="coMapsUrl" class="sett-text-input" value="${_escHtml(maps)}" placeholder="Es. https://maps.app.goo.gl/...">
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--green" onclick="saveCompanySettings()">💾 Salva dati azienda</button>
            </div>
        </div>`;
}

async function saveCompanySettings() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    const address = {
        via:       _settVal('coAddrVia').trim(),
        cap:       _settVal('coAddrCap').trim(),
        citta:     _settVal('coAddrCitta').trim(),
        provincia: _settVal('coAddrProvincia').trim().toUpperCase(),
        paese:     _settVal('coAddrPaese').trim(),
    };
    try {
        await OrgSettings.set('company.legal_name', _settVal('coLegalName').trim());
        await OrgSettings.set('company.vat_number', _settVal('coVatNumber').trim());
        await OrgSettings.set('company.tax_code', _settVal('coTaxCode').trim());
        await OrgSettings.set('company.pec', _settVal('coPec').trim());
        await OrgSettings.set('company.sdi_code', _settVal('coSdiCode').trim().toUpperCase());
        await OrgSettings.set('company.invoice_prefix', _settVal('coInvoicePrefix').trim());
        await OrgSettings.set('company.address', address);
        await OrgSettings.set('company.maps_url', _settVal('coMapsUrl').trim());
        showToast('✅ Dati azienda salvati', 'success');
    } catch (e) {
        console.error('[Settings] company save error:', e);
        showToast('Errore salvataggio dati azienda', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 4 — PAGAMENTI CLIENTE (billing_settings + listino slot_types)
// ════════════════════════════════════════════════════════════════════════════
let _settLoadedBillingModel = 'pay_per_session';

function _settSelectPaymentModel(model) {
    document.querySelectorAll('.sett-model-opt').forEach(el => {
        el.classList.toggle('active', el.querySelector('input')?.value === model);
    });
    const sections = {
        pay_per_session: 'pay', package: 'package', monthly: 'membership',
        free: 'free'
    };
    document.querySelectorAll('[data-billing-section]').forEach(el => {
        el.style.display = el.dataset.billingSection === sections[model] ? '' : 'none';
    });
}

async function _settRenderPayments(body) {
    body.innerHTML = `<div class="sett-loading">⏳ Caricamento configurazione pagamenti…</div>`;

    let billing = null, slotTypes = [], orgStripe = null;
    try {
        const [bRes, sRes, oRes] = await Promise.all([
            _queryWithTimeout(supabaseClient.from('billing_settings').select('*').eq('org_id', window._orgId).maybeSingle()),
            _queryWithTimeout(supabaseClient.from('slot_types').select('id,key,label,default_price,is_active').eq('org_id', window._orgId).order('sort_order')),
            _queryWithTimeout(supabaseClient.from('organizations').select('stripe_account_id,stripe_charges_enabled,stripe_account_email').eq('id', window._orgId).maybeSingle()),
        ]);
        billing = bRes && bRes.data;
        slotTypes = (sRes && sRes.data) || [];
        orgStripe = (oRes && oRes.data) || null;
    } catch (e) {
        console.warn('[Settings] payments load error:', e);
    }

    const baseModel = (billing && billing.default_model) || 'pay_per_session';
    const model     = baseModel;
    _settLoadedBillingModel = model;
    const threshold = (billing && billing.block_unpaid_threshold) || 0;
    const blockMemb = billing ? !!billing.block_if_membership_expired : true;
    const blockPkg  = billing ? !!billing.block_if_no_package : true;
    const graceDays = (billing && billing.grace_days) || 0;
    const autoDec   = billing ? !!billing.package_auto_decrement : true;

    const MODELS = [
        ['pay_per_session', '🎟️ A entrata',   'Il cliente paga ogni singola lezione.'],
        ['package',         '🎫 Pacchetto',    'Carnet di ingressi prepagato (decremento automatico).'],
        ['monthly',         '📆 Abbonamento', 'Un solo modello con pacchetti da 1, 3 o 12 mesi.'],
        ['free',            '🎁 Gratuito',     'Nessun pagamento richiesto.'],
    ];

    const packageLabel = (billing && billing.package_label) || 'Pacchetto 10 ingressi';
    const packageSessions = Number((billing && billing.package_sessions) || 10);
    const packagePrice = Number((billing && billing.package_price) || 0);
    const monthlyPrice = Number((billing && billing.membership_monthly_price) || 0);
    const quarterlyPrice = Number((billing && billing.membership_quarterly_price) || 0);
    const annualPrice = Number((billing && billing.membership_annual_price) || 0);

    const pricesCache = OrgSettings.get('billing_client.prices', {}) || {};
    const priceRows = slotTypes.map(st => {
        const price = (st.default_price != null) ? st.default_price : (pricesCache[st.key] != null ? pricesCache[st.key] : 0);
        return `
            <div class="sett-price-row">
                <span class="sett-price-label">${_escHtml(st.label)} ${st.is_active ? '' : '<span class="sett-badge-off">disattivo</span>'}</span>
                <div class="sett-price-input-wrap">
                    <span class="sett-price-cur">€</span>
                    <input type="number" min="0" step="0.01" class="sett-price-input"
                           data-slot-id="${st.id}" data-slot-key="${_escHtml(st.key)}"
                           value="${Number(price).toFixed(2)}">
                </div>
            </div>`;
    }).join('');

    // ── Card Stripe Connect: il trainer collega il PROPRIO account Stripe ──────
    const _hasAcct   = !!(orgStripe && orgStripe.stripe_account_id);
    const _chOk      = !!(orgStripe && orgStripe.stripe_charges_enabled);
    const _acctEmail = (orgStripe && orgStripe.stripe_account_email) || '';
    const stripeConnectCard = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--green">🔗</span>
                <div>
                    <h4 class="sett-card-title">Incassi online — Stripe</h4>
                    <p class="sett-card-desc">Collega il TUO account Stripe: i pagamenti dei clienti arrivano direttamente a te, la piattaforma non trattiene nulla.</p>
                </div>
            </div>
            ${_hasAcct ? `
                <div class="sett-stripe-status ${_chOk ? 'ok' : 'pending'}">
                    ${_chOk
                        ? `✅ <strong>Account collegato e attivo.</strong>`
                        : `⏳ <strong>Account collegato — onboarding da completare</strong> su Stripe per poter ricevere pagamenti.`}
                    ${_acctEmail ? `<div class="sett-stripe-acct">${_escHtml(_acctEmail)}</div>` : ''}
                </div>
                <div class="sett-btn-row">
                    ${_chOk ? '' : `<button class="sett-action-btn sett-action-btn--green" onclick="connectStripeAccount()">↗ Completa su Stripe</button>`}
                    <button class="sett-action-btn sett-action-btn--ghost" onclick="disconnectStripeAccount()">Scollega</button>
                </div>
            ` : `
                <div class="sett-btn-row">
                    <button class="sett-action-btn sett-action-btn--green" onclick="connectStripeAccount()">🔗 Collega il mio account Stripe</button>
                </div>
            `}
        </div>`;

    body.innerHTML = `
        ${stripeConnectCard}
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--green">💳</span>
                <div>
                    <h4 class="sett-card-title">Modello di pagamento predefinito</h4>
                    <p class="sett-card-desc">Modalità economica predefinita dello studio. Il cambio coinvolge tutti i clienti e richiede tre conferme di sicurezza.</p>
                </div>
            </div>
            <div class="sett-model-grid">
                ${MODELS.map(([v, lbl, desc]) => `
                    <label class="sett-model-opt ${v === model ? 'active' : ''}">
                        <input type="radio" name="payDefaultModel" value="${v}" ${v === model ? 'checked' : ''}
                               onchange="_settSelectPaymentModel(this.value)">
                        <span class="sett-model-title">${lbl}</span>
                        <span class="sett-model-desc">${desc}</span>
                    </label>`).join('')}
            </div>
        </div>

        <div class="sett-card" data-billing-section="pay">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--blue">💶</span>
                <div>
                    <h4 class="sett-card-title">A entrata · listino per lezione</h4>
                    <p class="sett-card-desc">Ogni prenotazione congela il prezzo del relativo tipo di slot. Nel profilo cliente il credito mostra quanto è già dovuto e quanto maturerà dalle lezioni future.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field">
                    <label class="sett-input-label">Soglia debito massimo (€, 0 = nessun blocco)</label>
                    <input type="number" min="0" step="0.01" id="payThreshold" class="sett-text-input" value="${Number(threshold).toFixed(2)}">
                </div>
            </div>
            <div class="sett-price-list">${priceRows || '<p class="sett-card-desc">Nessun tipo di slot configurato. Aggiungili da Gestione Orari → Tipi slot.</p>'}</div>
        </div>

        <div class="sett-card" data-billing-section="package">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--green">🎫</span>
                <div>
                    <h4 class="sett-card-title">Pacchetto · listino</h4>
                    <p class="sett-card-desc">Un solo prezzo di riferimento per il carnet. Nessun credito a lezione viene mostrato nel profilo cliente.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field"><label class="sett-input-label">Nome pacchetto</label><input id="payPackageLabel" class="sett-text-input" maxlength="120" value="${_escAttr(packageLabel)}"></div>
                <div class="sett-field"><label class="sett-input-label">Ingressi inclusi</label><input type="number" min="1" step="1" id="payPackageSessions" class="sett-text-input" value="${packageSessions}"></div>
                <div class="sett-field"><label class="sett-input-label">Prezzo pacchetto (€)</label><input type="number" min="0" step="0.01" id="payPackagePrice" class="sett-text-input" value="${packagePrice.toFixed(2)}"></div>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row"><div class="sett-toggle-text"><strong>Blocca senza pacchetto</strong><span>Impedisce la prenotazione se il carnet è assente o esaurito.</span></div><label class="settings-toggle-wrap"><input type="checkbox" id="payBlockPkg" ${blockPkg ? 'checked' : ''}><span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span></label></div>
                <div class="sett-toggle-row"><div class="sett-toggle-text"><strong>Decremento automatico</strong><span>Scala un ingresso dal pacchetto a ogni prenotazione.</span></div><label class="settings-toggle-wrap"><input type="checkbox" id="payAutoDecrement" ${autoDec ? 'checked' : ''}><span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span></label></div>
            </div>
        </div>

        <div class="sett-card" data-billing-section="membership">
            <div class="sett-card-header sett-card-header--top"><span class="sett-card-icon sett-card-icon--green">📅</span><div><h4 class="sett-card-title">Abbonamento · pacchetti per durata</h4><p class="sett-card-desc">Un solo modello con tre pacchetti: 1 mese, 3 mesi o 12 mesi. Nel profilo cliente compare la copertura attiva, non un credito a lezione.</p></div></div>
            <div class="sett-form-grid">
                <div class="sett-field"><label class="sett-input-label">Pacchetto 1 mese (€)</label><input type="number" min="0" step="0.01" id="payMonthlyPrice" class="sett-text-input" value="${monthlyPrice.toFixed(2)}"></div>
                <div class="sett-field"><label class="sett-input-label">Pacchetto 3 mesi (€)</label><input type="number" min="0" step="0.01" id="payQuarterlyPrice" class="sett-text-input" value="${quarterlyPrice.toFixed(2)}"></div>
                <div class="sett-field"><label class="sett-input-label">Pacchetto 12 mesi (€)</label><input type="number" min="0" step="0.01" id="payAnnualPrice" class="sett-text-input" value="${annualPrice.toFixed(2)}"></div>
                <div class="sett-field"><label class="sett-input-label">Giorni di tolleranza</label><input type="number" min="0" step="1" id="payGraceDays" class="sett-text-input" value="${graceDays}"></div>
            </div>
            <div class="sett-toggle-list"><div class="sett-toggle-row"><div class="sett-toggle-text"><strong>Blocca abbonamento scaduto</strong><span>Impedisce la prenotazione senza una copertura valida.</span></div><label class="settings-toggle-wrap"><input type="checkbox" id="payBlockMemb" ${blockMemb ? 'checked' : ''}><span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span></label></div></div>
        </div>

        <div data-billing-section="free"></div>

        <div class="sett-btn-row">
            <button class="sett-action-btn sett-action-btn--green" onclick="savePaymentsSettings()">💾 Salva pagamenti</button>
        </div>`;
    _settSelectPaymentModel(model);
}

// ── Stripe Connect: collega / scollega il conto Stripe del trainer ───────────
async function connectStripeAccount() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    try {
        const { data, error } = await supabaseClient.functions.invoke('stripe-connect', { body: { action: 'start' } });
        if (error) throw error;
        if (!data || !data.url) throw new Error((data && data.error) || 'Avvio collegamento non riuscito');
        window.location.href = data.url;   // → pagina di autorizzazione Stripe
    } catch (e) {
        console.error('[Settings] stripe connect error:', e);
        showToast('Errore collegamento Stripe: ' + (e.message || e), 'error');
    }
}

async function disconnectStripeAccount() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    if (!await showConfirm('Scollegare il tuo account Stripe? I clienti non potranno più pagarti online finché non lo ricolleghi.')) return;
    try {
        const { error } = await supabaseClient.functions.invoke('stripe-connect', { body: { action: 'disconnect' } });
        if (error) throw error;
        showToast('Account Stripe scollegato', 'success');
        setTimeout(() => location.reload(), 700);
    } catch (e) {
        console.error('[Settings] stripe disconnect error:', e);
        showToast('Errore: ' + (e.message || e), 'error');
    }
}

async function savePaymentsSettings() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    const orgId = window._orgId;
    if (!orgId) { showToast('Organizzazione non identificata', 'error'); return; }

    const modelEl = document.querySelector('input[name="payDefaultModel"]:checked');
    const model = modelEl ? modelEl.value : 'pay_per_session';

    try {
        const priceInputs = Array.from(document.querySelectorAll('.sett-price-input'));
        const pricesMap = {};
        priceInputs.forEach(inp => {
            const key = inp.dataset.slotKey;
            const val = parseFloat(inp.value) || 0;
            if (key) pricesMap[key] = val;
        });

        let impact = { model_changed: false };
        if (model !== _settLoadedBillingModel) {
            const { data, error } = await _queryWithTimeout(
                supabaseClient.rpc('get_billing_model_change_impact', { p_model: model })
            );
            if (error) throw error;
            impact = data || impact;
            const names = {
                pay_per_session: 'A entrata', package: 'Pacchetto', monthly: 'Abbonamento',
                quarterly: 'Abbonamento (3 mesi)', annual: 'Abbonamento (12 mesi)', free: 'Gratuito'
            };
            if (!await showConfirm(`1/3 · Cambio modello\n\nStai passando da “${names[_settLoadedBillingModel] || _settLoadedBillingModel}” a “${names[model] || model}”. Questa operazione modifica il modello predefinito di tutti i clienti.`)) return;
            if (!await showConfirm(`2/3 · Stati operativi da annullare\n\nSaranno annullati: ${impact.open_session_balances || 0} saldi/crediti a lezione, ${impact.active_packages || 0} pacchetti, ${impact.active_memberships || 0} abbonamenti e ${impact.client_overrides || 0} override cliente.`)) return;
            if (!await showConfirm('3/3 · Conferma definitiva\n\nPagamenti già registrati, incassi e statistiche storiche resteranno invariati. Confermi il cambio del modello?')) return;
        }

        const params = {
            p_model: model,
            p_block_unpaid_threshold: parseFloat(_settVal('payThreshold')) || 0,
            p_block_if_membership_expired: _settChecked('payBlockMemb'),
            p_block_if_no_package: _settChecked('payBlockPkg'),
            p_grace_days: parseInt(_settVal('payGraceDays'), 10) || 0,
            p_package_auto_decrement: _settChecked('payAutoDecrement'),
            p_package_label: _settVal('payPackageLabel').trim() || 'Pacchetto 10 ingressi',
            p_package_sessions: parseInt(_settVal('payPackageSessions'), 10) || 10,
            p_package_price: parseFloat(_settVal('payPackagePrice')) || 0,
            p_monthly_price: parseFloat(_settVal('payMonthlyPrice')) || 0,
            p_quarterly_price: parseFloat(_settVal('payQuarterlyPrice')) || 0,
            p_annual_price: parseFloat(_settVal('payAnnualPrice')) || 0,
            p_slot_prices: pricesMap,
            p_expected_current_model: _settLoadedBillingModel,
            p_confirm_1: model !== _settLoadedBillingModel,
            p_confirm_2: model !== _settLoadedBillingModel,
            p_confirm_3: model !== _settLoadedBillingModel,
        };
        const { data, error } = await _queryWithTimeout(
            supabaseClient.rpc('admin_save_default_billing_model', params), 30000
        );
        if (error) throw error;
        _settLoadedBillingModel = model;
        if (typeof OrgSettings !== 'undefined') await OrgSettings.load(true);
        if (data && data.model_changed) {
            showToast(`✅ Modello aggiornato · ${data.voided_session_balances || 0} saldi, ${data.cancelled_packages || 0} pacchetti e ${data.cancelled_memberships || 0} abbonamenti annullati`, 'success', 6500);
        } else showToast('✅ Pagamenti salvati', 'success');
    } catch (e) {
        console.error('[Settings] payments save error:', e);
        showToast('Errore salvataggio pagamenti', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 5 — POLICY PRENOTAZIONE / CANCELLAZIONE
//     (include cert/assicurazione/badge migrati dalle card legacy)
// ════════════════════════════════════════════════════════════════════════════
function _settRenderPolicy(body) {
    const freeHours = OrgSettings.getNumber('booking.policy.free_cancel_hours', 24);
    const penalty   = OrgSettings.getNumber('booking.policy.penalty_pct', 50);
    const maxAdv    = OrgSettings.getNumber('booking.policy.max_advance_days', 0);
    const reqAcc    = OrgSettings.getBool('booking.policy.requires_account', false);
    const cancelMd  = OrgSettings.getString('booking.policy.cancel_mode', 'penalty');

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--purple">🛡️</span>
                <div>
                    <h4 class="sett-card-title">Policy prenotazione &amp; cancellazione</h4>
                    <p class="sett-card-desc">Regole su anticipo, finestra di cancellazione gratuita e penali.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field">
                    <label class="sett-input-label">Ore di cancellazione gratuita</label>
                    <input type="number" min="0" step="1" id="polFreeHours" class="sett-text-input" value="${freeHours}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Penale cancellazione tardiva (%)</label>
                    <input type="number" min="0" max="100" step="1" id="polPenalty" class="sett-text-input" value="${penalty}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Anticipo massimo prenotazione (giorni, 0 = illimitato)</label>
                    <input type="number" min="0" step="1" id="polMaxAdvance" class="sett-text-input" value="${maxAdv}">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Modalità cancellazione</label>
                    <select id="polCancelMode" class="sett-select">
                        <option value="penalty"  ${cancelMd === 'penalty'  ? 'selected' : ''}>Penale percentuale</option>
                        <option value="block"    ${cancelMd === 'block'    ? 'selected' : ''}>Blocca cancellazione tardiva</option>
                        <option value="free"     ${cancelMd === 'free'     ? 'selected' : ''}>Sempre gratuita</option>
                    </select>
                </div>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Richiedi account per prenotare</strong>
                        <span>Se attivo, solo i clienti registrati possono prenotare.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="polRequiresAccount" ${reqAcc ? 'checked' : ''}>
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    </label>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--purple" onclick="savePolicySettings()">💾 Salva policy</button>
            </div>
        </div>

        <!-- Certificato medico (modificabile dal cliente) -->
        <div class="sett-card">
            <div class="sett-card-header">
                <span class="sett-card-icon sett-card-icon--cyan">🏥</span>
                <div>
                    <h4 class="sett-card-title">Certificato medico</h4>
                    <p class="sett-card-desc">Se attivo, i clienti possono modificare la scadenza del proprio certificato nel profilo.</p>
                </div>
                <label class="settings-toggle-wrap">
                    <input type="checkbox" id="certEditableToggle" onchange="saveCertEditable(this.checked)">
                    <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    <span class="settings-toggle-text" id="certEditableText"></span>
                </label>
            </div>
        </div>

        <!-- Blocco prenotazioni cert -->
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--red">🚫</span>
                <div>
                    <h4 class="sett-card-title">Blocco prenotazioni per certificato medico</h4>
                    <p class="sett-card-desc">Impedisci ai clienti di prenotare in base allo stato del certificato medico.</p>
                </div>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Certificato scaduto</strong>
                        <span>Blocca la prenotazione se il certificato medico risulta scaduto.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="certBlockExpiredToggle" onchange="saveCertBlockExpired(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="certBlockExpiredText"></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Certificato non impostato</strong>
                        <span>Blocca la prenotazione se il cliente non ha ancora inserito la scadenza.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="certBlockNotSetToggle" onchange="saveCertBlockNotSet(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="certBlockNotSetText"></span>
                    </label>
                </div>
            </div>
        </div>

        <!-- Blocco prenotazioni assicurazione -->
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--red">🚫</span>
                <div>
                    <h4 class="sett-card-title">Blocco prenotazioni per assicurazione</h4>
                    <p class="sett-card-desc">Impedisci ai clienti di prenotare in base allo stato dell'assicurazione.</p>
                </div>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Assicurazione scaduta</strong>
                        <span>Blocca la prenotazione se l'assicurazione risulta scaduta.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="assicBlockExpiredToggle" onchange="saveAssicBlockExpired(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="assicBlockExpiredText"></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Assicurazione non impostata</strong>
                        <span>Blocca la prenotazione se il cliente non ha ancora inserito la scadenza.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="assicBlockNotSetToggle" onchange="saveAssicBlockNotSet(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="assicBlockNotSetText"></span>
                    </label>
                </div>
            </div>
        </div>

        <!-- Visualizza badge partecipante -->
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--cyan">👁️</span>
                <div>
                    <h4 class="sett-card-title">Badge sulla card partecipante</h4>
                    <p class="sett-card-desc">Quali badge mostrare nella vista Prenotazioni admin.</p>
                </div>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text"><strong>🏥 Certificato medico</strong></div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="showCertBadgeToggle" onchange="saveShowCertBadge(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="showCertBadgeText"></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text"><strong>📋 Assicurazione</strong></div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="showAssicBadgeToggle" onchange="saveShowAssicBadge(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="showAssicBadgeText"></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text"><strong>📝 Documento non firmato</strong></div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="showDocBadgeToggle" onchange="saveShowDocBadge(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="showDocBadgeText"></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text"><strong>📋 Completa anagrafica</strong></div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="showAnagBadgeToggle" onchange="saveShowAnagBadge(this.checked)">
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        <span class="settings-toggle-text" id="showAnagBadgeText"></span>
                    </label>
                </div>
            </div>
        </div>

        <!-- Settimane standard → rimando a Gestione Orari -->
        <div class="sett-card">
            <div class="sett-card-header">
                <span class="sett-card-icon sett-card-icon--cyan">🗓️</span>
                <div>
                    <h4 class="sett-card-title">Settimane standard</h4>
                    <p class="sett-card-desc">La configurazione delle settimane tipo è stata spostata in Gestione Orari → Settimana tipo.</p>
                </div>
                <button class="sett-action-btn sett-action-btn--cyan" onclick="switchTab('schedule')">Vai a Gestione Orari</button>
            </div>
        </div>`;

    // Popola i toggle legacy (leggono dalle Storage classes esistenti).
    renderCertEditableUI();
    renderCertBlockUI();
    renderAssicBlockUI();
    renderBookingBadgesUI();
}

async function savePolicySettings() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    try {
        await OrgSettings.set('booking.policy.free_cancel_hours', parseInt(_settVal('polFreeHours'), 10) || 0);
        await OrgSettings.set('booking.policy.penalty_pct', parseInt(_settVal('polPenalty'), 10) || 0);
        await OrgSettings.set('booking.policy.max_advance_days', parseInt(_settVal('polMaxAdvance'), 10) || 0);
        await OrgSettings.set('booking.policy.requires_account', _settChecked('polRequiresAccount'));
        await OrgSettings.set('booking.policy.cancel_mode', _settVal('polCancelMode'));
        showToast('✅ Policy salvata', 'success');
    } catch (e) {
        console.error('[Settings] policy save error:', e);
        showToast('Errore salvataggio policy', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 6 — NOTIFICHE
// ════════════════════════════════════════════════════════════════════════════
function _settRenderNotif(body) {
    const conf      = OrgSettings.getBool('notif.booking_confirmation', true);
    const remEnab   = OrgSettings.getBool('notif.reminder_enabled', true);
    const remHours  = OrgSettings.getNumber('notif.reminder_hours', 24);
    const adminNew  = OrgSettings.getBool('notif.admin_new_booking', true);
    const channels  = OrgSettings.get('notif.channels', { push: true, email: false, whatsapp: false }) || {};

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--blue">🔔</span>
                <div>
                    <h4 class="sett-card-title">Notifiche</h4>
                    <p class="sett-card-desc">Conferme, promemoria e avvisi agli admin.</p>
                </div>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Conferma prenotazione al cliente</strong>
                        <span>Invia una notifica al cliente quando prenota.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="notifConfirmation" ${conf ? 'checked' : ''}>
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Promemoria lezione</strong>
                        <span>Invia un promemoria prima della lezione.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="notifReminderEnabled" ${remEnab ? 'checked' : ''}>
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    </label>
                </div>
                <div class="sett-toggle-row sett-toggle-row--input">
                    <label class="sett-input-label">Anticipo promemoria (ore)</label>
                    <input type="number" min="1" step="1" id="notifReminderHours" class="sett-text-input sett-text-input--sm" value="${remHours}">
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text">
                        <strong>Avvisa admin su nuova prenotazione</strong>
                        <span>Notifica push agli admin della org per ogni nuova prenotazione.</span>
                    </div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="notifAdminNew" ${adminNew ? 'checked' : ''}>
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    </label>
                </div>
            </div>
        </div>

        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--purple">📡</span>
                <div>
                    <h4 class="sett-card-title">Canali di invio</h4>
                    <p class="sett-card-desc">Quali canali usare per le notifiche.</p>
                </div>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text"><strong>📲 Push</strong></div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="notifChanPush" ${channels.push !== false ? 'checked' : ''}>
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text"><strong>✉️ Email</strong></div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="notifChanEmail" ${channels.email ? 'checked' : ''}>
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    </label>
                </div>
                <div class="sett-toggle-row">
                    <div class="sett-toggle-text"><strong>💬 WhatsApp</strong></div>
                    <label class="settings-toggle-wrap">
                        <input type="checkbox" id="notifChanWhatsapp" ${channels.whatsapp ? 'checked' : ''}>
                        <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    </label>
                </div>
            </div>
        </div>

        <div class="sett-btn-row">
            <button class="sett-action-btn sett-action-btn--blue" onclick="saveNotifSettings()">💾 Salva notifiche</button>
        </div>`;
}

async function saveNotifSettings() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    try {
        await OrgSettings.set('notif.booking_confirmation', _settChecked('notifConfirmation'));
        await OrgSettings.set('notif.reminder_enabled', _settChecked('notifReminderEnabled'));
        await OrgSettings.set('notif.reminder_hours', parseInt(_settVal('notifReminderHours'), 10) || 24);
        await OrgSettings.set('notif.admin_new_booking', _settChecked('notifAdminNew'));
        await OrgSettings.set('notif.channels', {
            push:     _settChecked('notifChanPush'),
            email:    _settChecked('notifChanEmail'),
            whatsapp: _settChecked('notifChanWhatsapp'),
        });
        showToast('✅ Notifiche salvate', 'success');
    } catch (e) {
        console.error('[Settings] notif save error:', e);
        showToast('Errore salvataggio notifiche', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 7 — STAFF / MEMBRI (org_members)
// ════════════════════════════════════════════════════════════════════════════
async function _settRenderStaff(body) {
    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--purple">👥</span>
                <div>
                    <h4 class="sett-card-title">Invita un membro dello staff</h4>
                    <p class="sett-card-desc">Inserisci l'email di un utente registrato e assegna un ruolo.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field sett-field--wide">
                    <label class="sett-input-label">Email</label>
                    <input type="email" id="staffInviteEmail" class="sett-text-input" placeholder="nome@esempio.it">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Ruolo</label>
                    <select id="staffInviteRole" class="sett-select">
                        <option value="staff">Staff</option>
                        <option value="admin">Admin</option>
                    </select>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--purple" onclick="inviteStaffMember()">➕ Invita membro</button>
            </div>
        </div>

        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--blue">📋</span>
                <div>
                    <h4 class="sett-card-title">Membri dello staff</h4>
                    <p class="sett-card-desc">Ruoli e stato dei membri della tua organizzazione.</p>
                </div>
            </div>
            <div id="staffMembersList"><div class="sett-loading">⏳ Caricamento membri…</div></div>
        </div>`;

    await _settLoadStaffList();
}

async function _settLoadStaffList() {
    const list = document.getElementById('staffMembersList');
    if (!list) return;
    try {
        const { data, error } = await _queryWithTimeout(
            supabaseClient.from('org_members')
                .select('id,user_id,role,status,invited_email')
                .eq('org_id', window._orgId)
                .order('role')
        );
        if (error) throw error;
        const members = data || [];

        // Risolvi nome/email dai profiles (se il membro è anche cliente) per visualizzazione.
        const userIds = members.map(m => m.user_id).filter(Boolean);
        let profMap = {};
        if (userIds.length) {
            const { data: profs } = await _queryWithTimeout(
                supabaseClient.from('profiles').select('id,name,email').in('id', userIds)
            );
            (profs || []).forEach(p => { profMap[p.id] = p; });
        }

        if (!members.length) {
            list.innerHTML = '<p class="sett-card-desc">Nessun membro oltre al proprietario.</p>';
            return;
        }

        const myRole = window._orgRole;
        list.innerHTML = `<div class="sett-staff-list">${members.map(m => {
            const prof = profMap[m.user_id] || {};
            const displayName = prof.name || m.invited_email || prof.email || '—';
            const displayEmail = prof.email || m.invited_email || '';
            const isOwner = m.role === 'owner';
            const roleBadge = `<span class="sett-role-badge sett-role-badge--${m.role}">${_settRoleLabel(m.role)}</span>`;
            const statusBadge = m.status !== 'active'
                ? `<span class="sett-badge-off">${m.status === 'invited' ? 'invitato' : 'revocato'}</span>` : '';
            // Owner non modificabile; solo owner/admin possono agire e non su un owner.
            const canManage = (myRole === 'owner' || myRole === 'admin') && !isOwner;
            const actions = canManage ? `
                <div class="sett-staff-actions">
                    <select class="sett-select sett-select--sm" onchange="changeStaffRole('${m.id}', this.value)">
                        <option value="staff" ${m.role === 'staff' ? 'selected' : ''}>Staff</option>
                        <option value="admin" ${m.role === 'admin' ? 'selected' : ''}>Admin</option>
                    </select>
                    <button class="sett-action-btn sett-action-btn--red sett-action-btn--sm" onclick="revokeStaffMember('${m.id}')">Revoca</button>
                </div>` : '';
            return `
                <div class="sett-staff-row">
                    <div class="sett-staff-info">
                        <span class="sett-staff-name">${_escHtml(displayName)} ${roleBadge} ${statusBadge}</span>
                        <span class="sett-staff-email">${_escHtml(displayEmail)}</span>
                    </div>
                    ${actions}
                </div>`;
        }).join('')}</div>`;
    } catch (e) {
        console.error('[Settings] staff load error:', e);
        list.innerHTML = '<p class="sett-card-desc">Errore nel caricamento dei membri.</p>';
    }
}

function _settRoleLabel(role) {
    return { owner: 'Proprietario', admin: 'Admin', staff: 'Staff' }[role] || role;
}

async function inviteStaffMember() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    const email = _settVal('staffInviteEmail').trim().toLowerCase();
    const role  = _settVal('staffInviteRole');
    if (!email || !email.includes('@')) { showToast('Inserisci un\'email valida', 'error'); return; }

    try {
        const { error } = await _rpcWithTimeout(
            supabaseClient.rpc('invite_org_member', { p_email: email, p_role: role })
        );
        if (error) throw error;
        showToast('✅ Invito inviato', 'success');
        const inp = document.getElementById('staffInviteEmail');
        if (inp) inp.value = '';
        await _settLoadStaffList();
    } catch (e) {
        console.error('[Settings] invite error:', e);
        const msg = (e && e.message && e.message.includes('unauthorized')) ? 'Permesso negato'
                  : (e && e.message && e.message.includes('invalid_role')) ? 'Ruolo non valido'
                  : 'Errore: l\'utente deve essere registrato per essere invitato';
        showToast(msg, 'error');
    }
}

async function changeStaffRole(memberId, newRole) {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    if (newRole !== 'admin' && newRole !== 'staff') return;
    try {
        const { error } = await _queryWithTimeout(
            supabaseClient.from('org_members').update({ role: newRole })
                .eq('id', memberId).eq('org_id', window._orgId).neq('role', 'owner')
        );
        if (error) throw error;
        showToast('✅ Ruolo aggiornato', 'success');
        await _settLoadStaffList();
    } catch (e) {
        console.error('[Settings] change role error:', e);
        showToast('Errore aggiornamento ruolo', 'error');
        await _settLoadStaffList();
    }
}

async function revokeStaffMember(memberId) {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    if (!await showConfirm('Revocare l\'accesso a questo membro?')) return;
    try {
        const { error } = await _queryWithTimeout(
            supabaseClient.from('org_members').update({ status: 'revoked' })
                .eq('id', memberId).eq('org_id', window._orgId).neq('role', 'owner')
        );
        if (error) throw error;
        showToast('✅ Membro revocato', 'success');
        await _settLoadStaffList();
    } catch (e) {
        console.error('[Settings] revoke error:', e);
        showToast('Errore revoca membro', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 8 — GDPR / PRIVACY
// ════════════════════════════════════════════════════════════════════════════
function _settRenderGdpr(body) {
    const privacy   = OrgSettings.getString('gdpr.privacy_url', '');
    const terms     = OrgSettings.getString('gdpr.terms_url', '');
    const retention = OrgSettings.getNumber('gdpr.data_retention_days', 0);

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--green">📜</span>
                <div>
                    <h4 class="sett-card-title">GDPR &amp; Privacy</h4>
                    <p class="sett-card-desc">Link ai documenti legali e conservazione dei dati.</p>
                </div>
            </div>
            <div class="sett-form-grid">
                <div class="sett-field sett-field--wide">
                    <label class="sett-input-label">URL informativa privacy</label>
                    <input type="url" id="gdprPrivacyUrl" class="sett-text-input" value="${_escHtml(privacy)}" placeholder="https://…/privacy">
                </div>
                <div class="sett-field sett-field--wide">
                    <label class="sett-input-label">URL termini e condizioni</label>
                    <input type="url" id="gdprTermsUrl" class="sett-text-input" value="${_escHtml(terms)}" placeholder="https://…/termini">
                </div>
                <div class="sett-field">
                    <label class="sett-input-label">Conservazione dati (giorni, 0 = illimitato)</label>
                    <input type="number" min="0" step="1" id="gdprRetention" class="sett-text-input" value="${retention}">
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--green" onclick="saveGdprSettings()">💾 Salva GDPR</button>
            </div>
        </div>`;
}

async function saveGdprSettings() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    try {
        await OrgSettings.set('gdpr.privacy_url', _settVal('gdprPrivacyUrl').trim());
        await OrgSettings.set('gdpr.terms_url', _settVal('gdprTermsUrl').trim());
        await OrgSettings.set('gdpr.data_retention_days', parseInt(_settVal('gdprRetention'), 10) || 0);
        showToast('✅ GDPR salvato', 'success');
    } catch (e) {
        console.error('[Settings] gdpr save error:', e);
        showToast('Errore salvataggio GDPR', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 9 — FEATURE FLAGS
// ════════════════════════════════════════════════════════════════════════════
function _settRenderFeatures(body) {
    const FEATURES = [
        ['workout_plans',          '💪 Schede di allenamento', 'Modulo schede, esercizi e progressi.'],
        ['nutrition',              '🥗 Nutrizione',            'Piani alimentari per i clienti.'],
        ['messaging',              '💬 Messaggistica',         'Notifiche push broadcast ai clienti.'],
        ['ai_reports',             '🤖 Report AI',             'Report mensili generati con AI.'],
        ['client_online_payments', '💳 Pagamenti online',      'I clienti pagano le lezioni online con Stripe.'],
    ];

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--purple">🧩</span>
                <div>
                    <h4 class="sett-card-title">Funzionalità</h4>
                    <p class="sett-card-desc">Attiva/disattiva i moduli per la tua organizzazione. La disponibilità per piano è gestita a parte.</p>
                </div>
            </div>
            <div class="sett-toggle-list">
                ${FEATURES.map(([key, lbl, desc]) => {
                    const on = OrgSettings.getBool('features.' + key, false);
                    return `
                    <div class="sett-toggle-row">
                        <div class="sett-toggle-text">
                            <strong>${lbl}</strong>
                            <span>${desc}</span>
                        </div>
                        <label class="settings-toggle-wrap">
                            <input type="checkbox" id="feat_${key}" ${on ? 'checked' : ''}
                                   onchange="saveFeatureFlag('${key}', this.checked)">
                            <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                        </label>
                    </div>`;
                }).join('')}
            </div>
        </div>`;
}

async function saveFeatureFlag(key, val) {
    if (!_settIsAdmin()) {
        showToast('Permesso negato', 'error');
        const el = document.getElementById('feat_' + key);
        if (el) el.checked = !val;
        return;
    }
    await _settSave('features.' + key, val, val ? '✅ Funzionalità attivata' : 'Funzionalità disattivata');
}

// ════════════════════════════════════════════════════════════════════════════
// 10 — BILLING SaaS (sola lettura stato + checkout/portal)
// ════════════════════════════════════════════════════════════════════════════
async function _settRenderBillingSaas(body) {
    body.innerHTML = `<div class="sett-loading">⏳ Caricamento abbonamento…</div>`;

    let ent = null;
    try {
        const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('get_tenant_entitlements'));
        if (error) throw error;
        ent = data;
    } catch (e) {
        console.warn('[Settings] entitlements error:', e);
    }

    const PLANS = [
        { code: 'starter',  name: 'Starter',  price: '€39,99', limit: '≤ 50 clienti',      feats: ['Schede', 'Notifiche push'] },
        { code: 'pro',      name: 'Pro',      price: '€79,99', limit: '≤ 200 clienti',     feats: ['Tutto Starter', 'Report AI', 'Pagamenti online'] },
        { code: 'business', name: 'Business', price: '€149,99', limit: 'Clienti illimitati', feats: ['Tutto Pro', 'Priorità supporto'] },
    ];

    const plan      = ent && ent.plan;
    const status    = (ent && ent.status) || '—';
    const maxClients = ent ? ent.max_clients : null;
    const clients   = (ent && ent.clients_count) != null ? ent.clients_count : '—';
    const trialEnd  = ent && ent.trial_end;
    const periodEnd = ent && ent.current_period_end;

    const statusLabels = {
        trialing: '🎁 In prova', active: '✅ Attivo', past_due: '⚠️ Pagamento in ritardo',
        canceled: '⛔ Annullato', unpaid: '⚠️ Non pagato', incomplete: '⏳ Incompleto',
    };
    const limitTxt = maxClients == null ? '∞' : maxClients;
    const dateTxt = (d) => { try { return d ? new Date(d).toLocaleDateString('it-IT') : '—'; } catch { return '—'; } };

    const stateInfo = status === 'trialing' && trialEnd
        ? `Prova fino al <strong>${dateTxt(trialEnd)}</strong>`
        : periodEnd ? `Rinnovo: <strong>${dateTxt(periodEnd)}</strong>` : '';

    body.innerHTML = `
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--purple">💎</span>
                <div>
                    <h4 class="sett-card-title">Il tuo abbonamento</h4>
                    <p class="sett-card-desc">Stato dell'abbonamento PalestrIA della tua organizzazione.</p>
                </div>
            </div>
            <div class="sett-saas-status">
                <div class="sett-saas-stat">
                    <span class="sett-saas-stat-lbl">Piano</span>
                    <span class="sett-saas-stat-val">${plan ? _escHtml(plan.charAt(0).toUpperCase() + plan.slice(1)) : '—'}</span>
                </div>
                <div class="sett-saas-stat">
                    <span class="sett-saas-stat-lbl">Stato</span>
                    <span class="sett-saas-stat-val">${statusLabels[status] || _escHtml(status)}</span>
                </div>
                <div class="sett-saas-stat">
                    <span class="sett-saas-stat-lbl">Clienti</span>
                    <span class="sett-saas-stat-val">${clients} / ${limitTxt}</span>
                </div>
            </div>
            ${stateInfo ? `<p class="sett-saas-period">${stateInfo}</p>` : ''}
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--blue" onclick="openBillingPortal()">⚙️ Gestisci abbonamento</button>
            </div>
        </div>

        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--green">🚀</span>
                <div>
                    <h4 class="sett-card-title">Cambia piano</h4>
                    <p class="sett-card-desc">Scegli il piano più adatto al numero di clienti.</p>
                </div>
            </div>
            <div class="sett-plan-grid">
                ${PLANS.map(p => `
                    <div class="sett-plan-card ${plan === p.code ? 'current' : ''}">
                        <div class="sett-plan-name">${p.name}</div>
                        <div class="sett-plan-price">${p.price}<span>/mese</span></div>
                        <div class="sett-plan-limit">${p.limit}</div>
                        <ul class="sett-plan-feats">${p.feats.map(f => `<li>${f}</li>`).join('')}</ul>
                        ${plan === p.code
                            ? '<button class="sett-action-btn sett-action-btn--muted" disabled>Piano attuale</button>'
                            : `<button class="sett-action-btn sett-action-btn--green" onclick="changeSaasPlan('${p.code}')">Scegli</button>`}
                    </div>`).join('')}
            </div>
        </div>`;
}

async function changeSaasPlan(planCode) {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    try {
        showToast('Reindirizzamento al checkout…', 'success');
        const { data, error } = await supabaseClient.functions.invoke('billing-checkout', { body: { plan_code: planCode } });
        if (error) throw error;
        if (data && data.url) { window.location = data.url; }
        else throw new Error('URL checkout mancante');
    } catch (e) {
        console.error('[Settings] checkout error:', e);
        showToast('Errore avvio checkout', 'error');
    }
}

async function openBillingPortal() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    try {
        showToast('Apertura portale…', 'success');
        const { data, error } = await supabaseClient.functions.invoke('billing-portal');
        if (error) throw error;
        if (data && data.url) { window.location = data.url; }
        else throw new Error('URL portale mancante');
    } catch (e) {
        console.error('[Settings] portal error:', e);
        showToast('Errore apertura portale', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// 11 — SICUREZZA / MANUTENZIONE
// ════════════════════════════════════════════════════════════════════════════
function _settRenderSecurity(body) {
    const maintOn  = OrgSettings.getBool('maintenance.mode', false);
    const maintMsg = OrgSettings.getString('maintenance.message', '');

    body.innerHTML = `
        <!-- Modalità manutenzione -->
        <div class="sett-card sett-card--danger">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--red">🔧</span>
                <div>
                    <h4 class="sett-card-title">Modalità manutenzione</h4>
                    <p class="sett-card-desc">Quando attiva, i clienti vedono un overlay "sistema non disponibile". L'admin continua ad accedere.</p>
                </div>
                <label class="settings-toggle-wrap">
                    <input type="checkbox" id="maintenanceModeToggle" ${maintOn ? 'checked' : ''} onchange="saveMaintenanceMode(this.checked)">
                    <span class="settings-toggle-track"><span class="settings-toggle-thumb"></span></span>
                    <span class="settings-toggle-text" id="maintenanceModeText">${maintOn ? 'Attiva' : 'Non attiva'}</span>
                </label>
            </div>
            <div class="sett-toggle-list">
                <div class="sett-toggle-row sett-toggle-row--input">
                    <label class="sett-input-label">Messaggio personalizzato (opzionale)</label>
                    <div class="sett-input-row">
                        <input type="text" id="maintenanceMessageInput" placeholder="Sistema temporaneamente non disponibile…" class="sett-text-input" value="${_escHtml(maintMsg)}">
                        <button class="sett-save-btn" onclick="saveMaintenanceMessage()">Salva</button>
                        <span id="maintenanceMessageSaved" class="sett-saved-msg" style="display:none">Salvato</span>
                    </div>
                </div>
            </div>
        </div>

        <!-- Verifica integrità dati -->
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--purple">🔍</span>
                <div>
                    <h4 class="sett-card-title">Verifica integrità dati</h4>
                    <p class="sett-card-desc">Controlla anomalie: utenti senza profilo, prenotazioni orfane, email non corrispondenti.</p>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--purple" id="healthCheckBtn" onclick="runHealthCheck()">🔍 Verifica</button>
                <button class="sett-action-btn sett-action-btn--red" id="healthFixBtn" onclick="runHealthFix()" style="display:none">🔧 Correggi anomalie</button>
            </div>
            <div id="healthCheckResult" style="display:none; margin-top:1rem;"></div>
        </div>

        <!-- Backup & Ripristino -->
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--blue">💾</span>
                <div>
                    <h4 class="sett-card-title">Backup &amp; Ripristino</h4>
                    <p class="sett-card-desc">Esporta tutti i dati della tua organizzazione. Il ripristino sovrascrive i dati attuali.</p>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--blue" onclick="exportBackup('json')">📤 Esporta JSON</button>
                <button class="sett-action-btn sett-action-btn--purple" onclick="exportBackup('csv')">📤 Esporta CSV</button>
                <button class="sett-action-btn sett-action-btn--green" onclick="document.getElementById('importBackupFile').click()">📥 Importa backup</button>
            </div>
            <input type="file" id="importBackupFile" accept=".json" style="display:none" onchange="importBackup(this)">
            <div id="backupStatus" class="sett-status-text"></div>
        </div>

        <!-- Report fiscali -->
        <div class="sett-card">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--green">🧾</span>
                <div>
                    <h4 class="sett-card-title">Report pagamenti</h4>
                    <p class="sett-card-desc">Scarica i report XLSX dei pagamenti fiscali (carta, bonifico, Stripe, contanti con report).</p>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--blue" onclick="downloadWeeklyReport()">📥 Report settimanale</button>
                <button class="sett-action-btn sett-action-btn--green" id="fiscalReportBtn" onclick="downloadFiscalReport()">🧾 Report fiscale completo</button>
            </div>
        </div>

        <!-- Cancella tutti i dati (org-scoped) -->
        <div class="sett-card sett-card--danger">
            <div class="sett-card-header sett-card-header--top">
                <span class="sett-card-icon sett-card-icon--red">🗑️</span>
                <div>
                    <h4 class="sett-card-title">Cancella tutti i dati</h4>
                    <p class="sett-card-desc">Elimina prenotazioni, schede, pagamenti e configurazioni della tua organizzazione. Account e abbonamento restano. Operazione irreversibile.</p>
                </div>
            </div>
            <div class="sett-btn-row">
                <button class="sett-action-btn sett-action-btn--red" onclick="clearAllOrgData()">🗑️ Cancella dati org</button>
            </div>
        </div>`;
}

async function clearAllOrgData() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    if (!await showConfirm('Cancellare TUTTI i dati operativi della tua organizzazione?\n\nVerranno eliminati: prenotazioni, schede, pagamenti, override calendario, notifiche e report.\nAccount, membri e abbonamento NON saranno toccati.\n\nL\'operazione è IRREVERSIBILE.')) return;
    const confirmText = await showPrompt('Per confermare, scrivi ELIMINA in maiuscolo:', '', { confirmText: 'Conferma' });
    if (confirmText !== 'ELIMINA') { showToast('Operazione annullata', 'error'); return; }

    try {
        const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('admin_clear_all_data'), 30000);
        if (error) throw error;
        if (data && data.success === false) throw new Error(data.error || 'Errore');
        showToast('✅ Dati organizzazione cancellati', 'success');
    } catch (e) {
        console.error('[Settings] clear data error:', e);
        showToast('Errore cancellazione dati', 'error');
    }
}

// ── Modalità manutenzione (ora su OrgSettings: maintenance.mode / maintenance.message) ──
async function saveMaintenanceMode(val) {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); const t = document.getElementById('maintenanceModeToggle'); if (t) t.checked = !val; return; }
    const toggle = document.getElementById('maintenanceModeToggle');
    const text = document.getElementById('maintenanceModeText');
    if (text) text.textContent = val ? 'Attiva' : 'Non attiva';
    try {
        await OrgSettings.set('maintenance.mode', val);
        showToast(val ? '🔧 Manutenzione attivata' : '✅ Manutenzione disattivata', val ? 'error' : 'success');
    } catch (e) {
        console.error('[Maintenance] saveMode error:', e);
        if (toggle) toggle.checked = !val;
        if (text) text.textContent = !val ? 'Attiva' : 'Non attiva';
        showToast('Errore salvataggio manutenzione', 'error');
    }
}

async function saveMaintenanceMessage() {
    if (!_settIsAdmin()) { showToast('Permesso negato', 'error'); return; }
    const input = document.getElementById('maintenanceMessageInput');
    const msg = (input && input.value || '').trim();
    try {
        await OrgSettings.set('maintenance.message', msg);
        const savedMsg = document.getElementById('maintenanceMessageSaved');
        if (savedMsg) { savedMsg.style.display = 'block'; setTimeout(() => { savedMsg.style.display = 'none'; }, 2000); }
    } catch (e) {
        console.error('[Maintenance] saveMessage error:', e);
        showToast('Errore salvataggio messaggio', 'error');
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// TOGGLE LEGACY (cert / assicurazione / badge)
//
// Le Storage classes in data.js (CertEditableStorage, CertBookingStorage, …) sono
// fire-and-forget: scrivono su localStorage (chiave gym_*) e lanciano _upsertSetting
// senza await né gestione errori UI. Qui le avvolgiamo per ottenere i 3 criteri:
//   - gate admin (con rollback del checkbox in caso di permesso negato)
//   - persistenza AWAITABLE: scriviamo via OrgSettings.set(dbKey, bool) — org-scoped,
//     cache localStorage NAMESPACED (org_<id>_<key>) → niente bleed cross-tenant —
//     e in PARALLELO aggiorniamo anche la chiave legacy gym_* via la Storage class
//     così i consumer in-session (gating book_slot lato client, render badge) restano
//     coerenti senza ricaricare la pagina.
//   - feedback toast success/error + rollback del toggle se la RPC fallisce.
//
// dbKey = chiave org_settings SENZA prefisso gym_ (combacia con syncAppSettingsFromSupabase
// in data.js, che ripopola le gym_* da queste chiavi al boot).
// ══════════════════════════════════════════════════════════════════════════════

// Salva un toggle booleano legacy con gate admin, persistenza awaitable e feedback.
//  - toggleId : id del <input type=checkbox>
//  - textId   : id dello <span> di stato (può essere null)
//  - dbKey    : chiave org_settings (senza gym_)
//  - val      : nuovo valore (bool)
//  - labels   : { on, off } testo di stato
//  - legacySetter(val) : applica anche alla Storage class legacy (sync in-session)
//  - after()  : callback opzionale post-successo (es. refresh calendario)
async function _settSaveLegacyToggle(toggleId, textId, dbKey, val, labels, legacySetter, after) {
    const toggle = document.getElementById(toggleId);
    const text   = textId ? document.getElementById(textId) : null;

    if (!_settIsAdmin()) {
        showToast('Permesso negato', 'error');
        if (toggle) toggle.checked = !val;               // rollback UI
        return;
    }

    // Aggiornamento ottimistico dello stato testuale.
    if (text) text.textContent = val ? labels.on : labels.off;

    try {
        // Persistenza autoritativa awaitable (org-scoped, namespaced).
        await OrgSettings.set(dbKey, val);
        // Allinea la cache legacy in-session per i consumer di data.js.
        try { if (typeof legacySetter === 'function') legacySetter(val); } catch (_) {}
        if (typeof after === 'function') { try { after(); } catch (_) {} }
        showToast('✅ Impostazione salvata', 'success');
    } catch (e) {
        console.error('[Settings] legacy toggle save error', dbKey, e);
        if (toggle) toggle.checked = !val;               // rollback UI
        if (text) text.textContent = !val ? labels.on : labels.off;
        showToast('Errore salvataggio impostazione', 'error');
    }
}

function renderCertEditableUI() {
    const editable = CertEditableStorage.get();
    const toggle = document.getElementById('certEditableToggle');
    const text   = document.getElementById('certEditableText');
    if (toggle) toggle.checked = editable;
    if (text)   text.textContent = editable ? 'Modificabile dal cliente' : 'Non modificabile';
}

function saveCertEditable(val) {
    return _settSaveLegacyToggle('certEditableToggle', 'certEditableText', 'cert_scadenza_editable', val,
        { on: 'Modificabile dal cliente', off: 'Non modificabile' },
        (v) => CertEditableStorage.set(v));
}

function renderCertBlockUI() {
    const expiredToggle = document.getElementById('certBlockExpiredToggle');
    const expiredText   = document.getElementById('certBlockExpiredText');
    const notSetToggle  = document.getElementById('certBlockNotSetToggle');
    const notSetText    = document.getElementById('certBlockNotSetText');
    if (expiredToggle) expiredToggle.checked = CertBookingStorage.getBlockIfExpired();
    if (expiredText)   expiredText.textContent = CertBookingStorage.getBlockIfExpired() ? 'Bloccato' : 'Non bloccato';
    if (notSetToggle)  notSetToggle.checked = CertBookingStorage.getBlockIfNotSet();
    if (notSetText)    notSetText.textContent = CertBookingStorage.getBlockIfNotSet() ? 'Bloccato' : 'Non bloccato';
}

function saveCertBlockExpired(val) {
    return _settSaveLegacyToggle('certBlockExpiredToggle', 'certBlockExpiredText', 'cert_block_expired', val,
        { on: 'Bloccato', off: 'Non bloccato' },
        (v) => CertBookingStorage.setBlockIfExpired(v));
}

function saveCertBlockNotSet(val) {
    return _settSaveLegacyToggle('certBlockNotSetToggle', 'certBlockNotSetText', 'cert_block_not_set', val,
        { on: 'Bloccato', off: 'Non bloccato' },
        (v) => CertBookingStorage.setBlockIfNotSet(v));
}

function renderAssicBlockUI() {
    const expiredToggle = document.getElementById('assicBlockExpiredToggle');
    const expiredText   = document.getElementById('assicBlockExpiredText');
    const notSetToggle  = document.getElementById('assicBlockNotSetToggle');
    const notSetText    = document.getElementById('assicBlockNotSetText');
    if (expiredToggle) expiredToggle.checked = AssicBookingStorage.getBlockIfExpired();
    if (expiredText)   expiredText.textContent = AssicBookingStorage.getBlockIfExpired() ? 'Bloccato' : 'Non bloccato';
    if (notSetToggle)  notSetToggle.checked = AssicBookingStorage.getBlockIfNotSet();
    if (notSetText)    notSetText.textContent = AssicBookingStorage.getBlockIfNotSet() ? 'Bloccato' : 'Non bloccato';
}

function saveAssicBlockExpired(val) {
    return _settSaveLegacyToggle('assicBlockExpiredToggle', 'assicBlockExpiredText', 'assic_block_expired', val,
        { on: 'Bloccato', off: 'Non bloccato' },
        (v) => AssicBookingStorage.setBlockIfExpired(v));
}

function saveAssicBlockNotSet(val) {
    return _settSaveLegacyToggle('assicBlockNotSetToggle', 'assicBlockNotSetText', 'assic_block_not_set', val,
        { on: 'Bloccato', off: 'Non bloccato' },
        (v) => AssicBookingStorage.setBlockIfNotSet(v));
}

function renderBookingBadgesUI() {
    const pairs = [
        ['showCertBadgeToggle',  'showCertBadgeText',  BookingBadgesStorage.getShowCert()],
        ['showAssicBadgeToggle', 'showAssicBadgeText', BookingBadgesStorage.getShowAssic()],
        ['showDocBadgeToggle',   'showDocBadgeText',   BookingBadgesStorage.getShowDoc()],
        ['showAnagBadgeToggle',  'showAnagBadgeText',  BookingBadgesStorage.getShowAnag()],
    ];
    for (const [tId, txtId, val] of pairs) {
        const t = document.getElementById(tId);
        const x = document.getElementById(txtId);
        if (t) t.checked = val;
        if (x) x.textContent = val ? 'Visibile' : 'Nascosto';
    }
}

function saveShowCertBadge(val)  {
    return _settSaveLegacyToggle('showCertBadgeToggle', 'showCertBadgeText', 'show_cert_badge', val,
        { on: 'Visibile', off: 'Nascosto' }, (v) => BookingBadgesStorage.setShowCert(v), _refreshAdminCalendarIfVisible);
}
function saveShowAssicBadge(val) {
    return _settSaveLegacyToggle('showAssicBadgeToggle', 'showAssicBadgeText', 'show_assic_badge', val,
        { on: 'Visibile', off: 'Nascosto' }, (v) => BookingBadgesStorage.setShowAssic(v), _refreshAdminCalendarIfVisible);
}
function saveShowDocBadge(val)   {
    return _settSaveLegacyToggle('showDocBadgeToggle', 'showDocBadgeText', 'show_doc_badge', val,
        { on: 'Visibile', off: 'Nascosto' }, (v) => BookingBadgesStorage.setShowDoc(v), _refreshAdminCalendarIfVisible);
}
function saveShowAnagBadge(val)  {
    return _settSaveLegacyToggle('showAnagBadgeToggle', 'showAnagBadgeText', 'show_anag_badge', val,
        { on: 'Visibile', off: 'Nascosto' }, (v) => BookingBadgesStorage.setShowAnag(v), _refreshAdminCalendarIfVisible);
}

function _refreshAdminCalendarIfVisible() {
    if (typeof renderAdminDayView === 'function' && window._currentAdminDate) {
        try { renderAdminDayView(window._currentAdminDate); } catch {}
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// HEALTH CHECK — invariato (org-scoped lato RPC admin_health_check/fix)
// ══════════════════════════════════════════════════════════════════════════════
const HEALTH_CHECKS = [
    { key: 'ghost_users',      label: '👻 Utenti senza profilo',         desc: 'Account auth.users senza riga in profiles', fix: 'Crea profilo da metadata' },
    { key: 'orphan_bookings',  label: '📅 Prenotazioni orfane',          desc: 'Prenotazioni con user_id che punta a profilo inesistente', fix: 'Scollega user_id (booking intatta)' },
    { key: 'email_mismatch',   label: '📧 Email non corrispondenti',     desc: 'Prenotazioni con email diversa dal profilo collegato', fix: 'Ricollega user_id al profilo corretto' },
];

async function runHealthCheck() {
    const btn = document.getElementById('healthCheckBtn');
    const fixBtn = document.getElementById('healthFixBtn');
    const resultEl = document.getElementById('healthCheckResult');
    if (!resultEl) return;

    btn.disabled = true;
    btn.textContent = '⏳ Verifica in corso...';
    fixBtn.style.display = 'none';
    resultEl.style.display = 'none';

    try {
        const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('admin_health_check'), 30000);
        if (error) throw new Error(error.message);
        if (!data.success) throw new Error(data.error || 'Errore sconosciuto');

        let totalIssues = 0;
        let html = '';

        HEALTH_CHECKS.forEach(c => {
            const items = data[c.key] || [];
            totalIssues += items.length;
            const ok = items.length === 0;
            html += `<div style="display:flex;align-items:center;gap:0.5rem;padding:0.4rem 0;${ok ? '' : 'color:#dc2626;font-weight:600'}">
                <span>${ok ? '✅' : '⚠️'}</span>
                <span>${c.label}</span>
                <span style="margin-left:auto;font-size:0.85rem;${ok ? 'color:#16a34a' : 'color:#dc2626'}">${ok ? 'OK' : items.length + ' problemi'}</span>
            </div>`;
            if (!ok) {
                html += `<div style="font-size:0.8rem;color:#6b7280;padding:0.2rem 0 0.2rem 1.75rem;">${c.desc}</div>`;
                html += `<div style="font-size:0.8rem;color:#2563eb;padding:0 0 0.5rem 1.75rem;">Correzione: ${c.fix}</div>`;
                items.slice(0, 10).forEach(item => {
                    // XSS: email/date arrivano dai dati cliente (prenotazioni orfane/mismatch)
                    // e finiscono in innerHTML → sempre escapati.
                    html += `<div style="font-size:0.8rem;color:#6b7280;padding:0.15rem 0 0.15rem 1.75rem;">• ${_escHtml(item.email || item.booking_email || '—')}${item.date ? ' (' + _escHtml(item.date) + ')' : ''}${item.profile_email ? ' → profilo: ' + _escHtml(item.profile_email) : ''}</div>`;
                });
                if (items.length > 10) html += `<div style="font-size:0.8rem;color:#6b7280;padding:0.15rem 0 0.15rem 1.75rem;">... e altri ${items.length - 10}</div>`;
            }
        });

        const summary = totalIssues === 0
            ? '<div style="padding:0.75rem;background:#f0fdf4;border-radius:8px;color:#16a34a;font-weight:600;text-align:center;margin-bottom:0.75rem">✅ Nessuna anomalia rilevata</div>'
            : `<div style="padding:0.75rem;background:#fef2f2;border-radius:8px;color:#dc2626;font-weight:600;text-align:center;margin-bottom:0.75rem">⚠️ ${totalIssues} anomalie rilevate</div>`;

        resultEl.innerHTML = summary + html;
        resultEl.style.display = 'block';
        fixBtn.style.display = totalIssues > 0 ? '' : 'none';
    } catch (e) {
        resultEl.innerHTML = `<div style="color:#dc2626">Errore: ${_escHtml(e.message)}</div>`;
        resultEl.style.display = 'block';
    } finally {
        btn.disabled = false;
        btn.textContent = '🔍 Verifica';
    }
}

async function runHealthFix() {
    if (!await showConfirm('Correggi tutte le anomalie?\n\nNessun dato verrà cancellato.\n• Utenti fantasma → crea profilo\n• Booking orfane → scollega user_id\n• Email mismatch → ricollega user_id al profilo corretto')) return;

    const btn = document.getElementById('healthFixBtn');
    const resultEl = document.getElementById('healthCheckResult');
    btn.disabled = true;
    btn.textContent = '⏳ Correzione in corso...';

    try {
        const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('admin_health_fix'), 30000);
        if (error) throw new Error(error.message);
        if (!data.success) throw new Error(data.error || 'Errore sconosciuto');

        const fixes = [
            { key: 'fixed_ghosts',   label: 'Profili creati' },
            { key: 'fixed_bookings', label: 'Prenotazioni scollegate' },
            { key: 'fixed_emails',   label: 'Email allineate' },
        ];

        const totalFixed = fixes.reduce((s, f) => s + (data[f.key] || 0), 0);
        let html = `<div style="padding:0.75rem;background:#f0fdf4;border-radius:8px;color:#16a34a;font-weight:600;text-align:center;margin-bottom:0.75rem">🔧 ${totalFixed} correzioni applicate</div>`;
        fixes.forEach(f => {
            const n = data[f.key] || 0;
            if (n > 0) html += `<div style="padding:0.3rem 0;color:#16a34a">✅ ${f.label}: ${n}</div>`;
        });
        if (totalFixed === 0) html += `<div style="padding:0.3rem 0;color:#6b7280">Nessuna correzione necessaria.</div>`;

        resultEl.innerHTML = html;
        btn.style.display = 'none';

        await Promise.all([
            UserStorage.syncUsersFromSupabase(),
            BookingStorage.syncFromSupabase(),
        ]);
        showToast('Integrità dati corretta.', 'success');
    } catch (e) {
        resultEl.innerHTML = `<div style="color:#dc2626">Errore: ${_escHtml(e.message)}</div>`;
        resultEl.style.display = 'block';
    } finally {
        btn.disabled = false;
        btn.textContent = '🔧 Correggi anomalie';
    }
}
