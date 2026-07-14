// ════════════════════════════════════════════════════════════════════════════
// Gestione Orari — Editor flessibile per-org (multi-tenant)
//
// Pannello admin che configura le tabelle orari del nuovo schema SaaS:
//   • slot_types            → tipi di slot (label, colore, capienza/prezzo default…)
//   • time_slots_config     → fasce orarie (start/end → label "HH:MM - HH:MM")
//   • weekly_schedule_templates + weekly_template_slots → griglia 7gg × N fasce
//   • schedule_overrides    → override puntuale per-data (capienza ASSOLUTA)
//
// Scrittura DIRETTA via supabaseClient.from(...): la RLS (*_admin con is_org_admin)
// autorizza solo owner/admin della org. OGNI insert include org_id = window._orgId.
//
// NB: l'unico bridge legacy sopravvissuto è getScheduleForDate, consumato da
// admin-calendar.js e admin-messaggi.js: resta invariato come bridge sulla
// cache localStorage (saveScheduleForDate/getScheduleWeekDates sono stati rimossi).
// ════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// Stato modulo
// ─────────────────────────────────────────────────────────────────────────────
let _schedActiveSection = 'types';   // 'types' | 'slots' | 'template' | 'activation' | 'overrides'
let _schedData = {
    slotTypes:  [],   // righe slot_types
    timeSlots:  [],   // righe time_slots_config
    templates:  [],   // righe weekly_schedule_templates
    tplSlots:   [],   // righe weekly_template_slots (del template selezionato)
    activated:  [],   // righe activated_weeks (settimane attivate della org)
    overrides:  []    // righe schedule_overrides (della data selezionata)
};
// Quante settimane future mostrare nell'editor di attivazione (oltre alla corrente).
const _SCHED_ACTIVATION_WEEKS = 12;
let _schedSelectedTemplateId = null;
let _schedOverrideDate = null;       // 'YYYY-MM-DD' per l'editor override

// Nomi giorni indicizzati per weekday (0=Domenica .. 6=Sabato), come da schema DB.
const _WEEKDAY_SHORT = ['Dom', 'Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab'];
// Ordine di visualizzazione griglia: Lun→Dom (weekday 1..6, poi 0)
const _WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0];

// ─────────────────────────────────────────────────────────────────────────────
// Helper comuni
// ─────────────────────────────────────────────────────────────────────────────

// Etichetta fascia dalla coppia start/end → "HH:MM - HH:MM" (come bookings.time)
function _schedSlotLabel(ts) {
    if (!ts) return '';
    const fmt = (t) => String(t || '').slice(0, 5);   // 'HH:MM:SS' → 'HH:MM'
    return `${fmt(ts.start_time)} - ${fmt(ts.end_time)}`;
}

// org_id corrente (autenticato). Senza org non si può scrivere.
function _schedOrgId() {
    return (typeof window !== 'undefined' && window._orgId) ? window._orgId : null;
}

function _schedToast(msg, type = 'success') {
    if (typeof showToast === 'function') showToast(msg, type);
    else console.log('[Schedule]', msg);
}

// Guard comune sulle azioni di scrittura
function _schedRequireOrg() {
    const org = _schedOrgId();
    if (!org) { _schedToast('⚠️ Organizzazione non disponibile. Riprova dopo il login.', 'error'); return null; }
    if (typeof supabaseClient === 'undefined') { _schedToast('⚠️ Connessione non disponibile.', 'error'); return null; }
    return org;
}

// ─────────────────────────────────────────────────────────────────────────────
// Caricamento dati dal DB (org-scoped via RLS)
// ─────────────────────────────────────────────────────────────────────────────
async function _schedLoadAll() {
    const org = _schedOrgId();
    if (!org || typeof supabaseClient === 'undefined') {
        _schedData = { slotTypes: [], timeSlots: [], templates: [], tplSlots: [], overrides: [] };
        return;
    }
    try {
        const [stRes, tsRes, tplRes, awRes] = await Promise.all([
            supabaseClient.from('slot_types').select('*').eq('org_id', org).order('sort_order', { ascending: true }),
            supabaseClient.from('time_slots_config').select('*').eq('org_id', org).order('sort_order', { ascending: true }).order('start_time', { ascending: true }),
            supabaseClient.from('weekly_schedule_templates').select('*').eq('org_id', org).order('created_at', { ascending: true }),
            supabaseClient.from('activated_weeks').select('*').eq('org_id', org).order('week_start', { ascending: true })
        ]);
        _schedData.slotTypes = stRes.data || [];
        _schedData.timeSlots = tsRes.data || [];
        _schedData.templates = tplRes.data || [];
        _schedData.activated = awRes.data || [];

        // Template selezionato: l'attivo, altrimenti il primo
        if (!_schedSelectedTemplateId || !_schedData.templates.find(t => t.id === _schedSelectedTemplateId)) {
            const active = _schedData.templates.find(t => t.is_active);
            _schedSelectedTemplateId = active ? active.id : (_schedData.templates[0]?.id || null);
        }
        await _schedLoadTemplateSlots();
    } catch (e) {
        console.error('[Schedule] load error:', e);
        _schedToast('⚠️ Errore nel caricamento orari.', 'error');
    }
}

async function _schedLoadTemplateSlots() {
    _schedData.tplSlots = [];
    const org = _schedOrgId();
    if (!org || !_schedSelectedTemplateId || typeof supabaseClient === 'undefined') return;
    try {
        const { data } = await supabaseClient
            .from('weekly_template_slots')
            .select('*')
            .eq('org_id', org)
            .eq('template_id', _schedSelectedTemplateId);
        _schedData.tplSlots = data || [];
    } catch (e) {
        console.error('[Schedule] template slots error:', e);
    }
}

async function _schedLoadOverrides(date) {
    _schedData.overrides = [];
    const org = _schedOrgId();
    if (!org || !date || typeof supabaseClient === 'undefined') return;
    try {
        const { data } = await supabaseClient
            .from('schedule_overrides')
            .select('*')
            .eq('org_id', org)
            .eq('date', date)
            .order('time', { ascending: true });
        _schedData.overrides = data || [];
    } catch (e) {
        console.error('[Schedule] overrides error:', e);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point (chiamato da admin.js: setupScheduleManager / renderScheduleManager)
// ─────────────────────────────────────────────────────────────────────────────
function setupScheduleManager() {
    renderScheduleManager();
}

async function renderScheduleManager() {
    const manager = document.getElementById('scheduleManager');
    if (!manager) return;

    // Skeleton immediato (lo switchTab mostra subito il contenitore)
    manager.innerHTML = `
        <div class="sched-head">
            <div class="sched-nav" id="schedNav">${_schedNavHtml()}</div>
        </div>
        <div id="schedBody"><div class="sched-loading">⏳ Caricamento configurazione orari…</div></div>
    `;

    await _schedLoadAll();
    _schedRenderActiveSection();
}

function _schedNavHtml() {
    const tabs = [
        { id: 'types',      icon: '🏷️', label: 'Tipi slot' },
        { id: 'slots',      icon: '🕐', label: 'Fasce orarie' },
        { id: 'template',   icon: '🗓️', label: 'Settimana tipo' },
        { id: 'activation', icon: '✅', label: 'Attiva settimane' },
        { id: 'overrides',  icon: '📌', label: 'Override per data' }
    ];
    return tabs.map(t => `
        <button class="sched-nav-btn ${_schedActiveSection === t.id ? 'active' : ''}"
                onclick="schedSwitchSection('${t.id}')">
            <span class="sched-nav-ico">${t.icon}</span><span class="sched-nav-lbl">${t.label}</span>
        </button>`).join('');
}

function schedSwitchSection(section) {
    _schedActiveSection = section;
    const nav = document.getElementById('schedNav');
    if (nav) nav.innerHTML = _schedNavHtml();
    _schedRenderActiveSection();
}

function _schedRenderActiveSection() {
    const body = document.getElementById('schedBody');
    if (!body) return;
    switch (_schedActiveSection) {
        case 'types':      body.innerHTML = _schedRenderTypes();      break;
        case 'slots':      body.innerHTML = _schedRenderSlots();      break;
        case 'template':   body.innerHTML = _schedRenderTemplate();   break;
        case 'activation': body.innerHTML = _schedRenderActivation(); break;
        case 'overrides':  body.innerHTML = _schedRenderOverrides();  break;
    }
}

// ════════════════════════════════════════════════════════════════════════════
// EDITOR 1 — TIPI SLOT (slot_types)
// ════════════════════════════════════════════════════════════════════════════
function _schedRenderTypes() {
    const list = _schedData.slotTypes;
    let rows = '';
    if (list.length === 0) {
        rows = '<div class="sched-empty">Nessun tipo di slot configurato. Creane uno per iniziare.</div>';
    } else {
        rows = list.map(st => `
            <div class="sched-row ${st.is_active ? '' : 'is-inactive'}">
                <span class="sched-color-dot" style="background:${_escHtml(st.color || '#8B5CF6')}"></span>
                <div class="sched-row-main">
                    <div class="sched-row-title">${_escHtml(st.label)}
                        ${st.bookable ? '' : '<span class="sched-badge sched-badge--muted">non prenotabile</span>'}
                        ${st.is_active ? '' : '<span class="sched-badge sched-badge--off">disattivo</span>'}
                    </div>
                    <div class="sched-row-sub">
                        capienza ${st.default_capacity} · €${Number(st.default_price || 0).toFixed(2)}
                    </div>
                </div>
                <div class="sched-row-actions">
                    <button class="sched-btn-icon" title="Modifica" onclick="schedEditType('${st.id}')">✏️</button>
                    <button class="sched-btn-icon sched-btn-icon--danger" title="Elimina" onclick="schedDeleteType('${st.id}')">🗑️</button>
                </div>
            </div>`).join('');
    }

    return `
        <div class="sched-section">
            <div class="sched-section-head">
                <div>
                    <h3 class="sched-section-title">Tipi di slot</h3>
                    <p class="sched-section-desc">Le categorie di lezione (es. Personal, Small Group). Capienza e prezzo qui sono i valori di default.</p>
                </div>
                <button class="sched-btn-primary" onclick="schedEditType()">+ Nuovo tipo</button>
            </div>
            <div class="sched-list">${rows}</div>
            <div id="schedTypeForm"></div>
        </div>`;
}

// Form crea/modifica tipo slot (inline)
function schedEditType(id) {
    const st = id ? _schedData.slotTypes.find(s => s.id === id) : null;
    const host = document.getElementById('schedTypeForm');
    if (!host) return;
    const v = st || { label: '', key: '', color: '#8B5CF6', default_capacity: 1, default_price: 0, bookable: true, is_active: true, sort_order: _schedData.slotTypes.length };

    host.innerHTML = `
        <div class="sched-form">
            <h4 class="sched-form-title">${st ? 'Modifica tipo' : 'Nuovo tipo di slot'}</h4>
            <div class="sched-form-grid">
                <label class="sched-field">
                    <span>Etichetta</span>
                    <input type="text" id="stLabel" value="${_escHtml(v.label)}" placeholder="Personal Training">
                </label>
                <label class="sched-field">
                    <span>Colore</span>
                    <input type="color" id="stColor" value="${_escHtml(v.color || '#8B5CF6')}">
                </label>
                <label class="sched-field">
                    <span>Capienza default</span>
                    <input type="number" id="stCapacity" min="0" step="1" value="${v.default_capacity}">
                </label>
                <label class="sched-field">
                    <span>Prezzo default (€)</span>
                    <input type="number" id="stPrice" min="0" step="0.01" value="${v.default_price}">
                </label>
                <label class="sched-field">
                    <span>Ordine</span>
                    <input type="number" id="stSort" step="1" value="${v.sort_order}">
                </label>
            </div>
            <div class="sched-form-checks">
                <label class="sched-check"><input type="checkbox" id="stBookable" ${v.bookable ? 'checked' : ''}> Prenotabile dai clienti</label>
                <label class="sched-check"><input type="checkbox" id="stActive" ${v.is_active ? 'checked' : ''}> Attivo</label>
            </div>
            <div class="sched-form-actions">
                <button class="sched-btn-ghost" onclick="schedCloseTypeForm()">Annulla</button>
                <button class="sched-btn-primary" onclick="schedSaveType(${st ? `'${st.id}'` : 'null'})">${st ? 'Salva modifiche' : 'Crea tipo'}</button>
            </div>
        </div>`;
    host.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function schedCloseTypeForm() {
    const host = document.getElementById('schedTypeForm');
    if (host) host.innerHTML = '';
}

// Parse di un intero non-negativo da input (capienza/serie/ordine).
// Distingue esplicitamente "vuoto/invalido" da uno 0 legittimo:
//   '' / testo non numerico → fallback; '0' → 0.
function _schedParseInt(raw, fallback = 0) {
    const trimmed = String(raw ?? '').trim();
    if (trimmed === '') return fallback;
    const n = parseInt(trimmed, 10);
    if (Number.isNaN(n)) return fallback;
    return n;
}

// Genera una chiave "slug" da un'etichetta
function _schedSlugify(s) {
    return String(s || '').toLowerCase().trim()
        .replace(/[àáâ]/g, 'a').replace(/[èé]/g, 'e').replace(/[ìí]/g, 'i')
        .replace(/[òó]/g, 'o').replace(/[ùú]/g, 'u')
        .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

// Genera una chiave univoca dall'etichetta, evitando collisioni con i tipi
// già esistenti (la chiave non è più modificabile dall'utente).
function _schedUniqueKey(label) {
    const base = _schedSlugify(label) || 'slot';
    const existing = new Set((_schedData.slotTypes || []).map(s => s.key));
    let key = base, i = 2;
    while (existing.has(key)) key = `${base}-${i++}`;
    return key;
}

async function schedSaveType(id) {
    const org = _schedRequireOrg();
    if (!org) return;

    const label = (document.getElementById('stLabel')?.value || '').trim();
    if (!label) { _schedToast('⚠️ Inserisci un\'etichetta.', 'error'); return; }
    // La chiave (key) non è più esposta in UI: per i nuovi tipi la generiamo
    // automaticamente dall'etichetta, garantendone l'unicità. Per i tipi esistenti
    // resta invariata (non è nel payload di update).
    const key = id ? null : _schedUniqueKey(label);

    const payload = {
        label,
        color: document.getElementById('stColor')?.value || '#8B5CF6',
        default_capacity: _schedParseInt(document.getElementById('stCapacity')?.value, 0),
        default_price: parseFloat(document.getElementById('stPrice')?.value || '0') || 0,
        bookable: !!document.getElementById('stBookable')?.checked,
        is_active: !!document.getElementById('stActive')?.checked,
        sort_order: _schedParseInt(document.getElementById('stSort')?.value, 0)
    };

    try {
        if (id) {
            const { error } = await supabaseClient.from('slot_types').update(payload).eq('id', id).eq('org_id', org);
            if (error) throw error;
            _schedToast('✅ Tipo aggiornato.');
        } else {
            const { error } = await supabaseClient.from('slot_types').insert({ ...payload, key, org_id: org });
            if (error) throw error;
            _schedToast('✅ Tipo creato.');
        }
        schedCloseTypeForm();
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] saveType:', e);
        const dup = e?.code === '23505' || /duplicate|unique/i.test(e?.message || '');
        _schedToast(dup ? '⚠️ Esiste già un tipo con questa chiave.' : '⚠️ Errore nel salvataggio.', 'error');
    }
}

async function schedDeleteType(id) {
    const org = _schedRequireOrg();
    if (!org) return;
    const st = _schedData.slotTypes.find(s => s.id === id);
    if (!await showConfirm(`Eliminare il tipo "${st?.label || ''}"? Verrà rimosso anche dalle settimane tipo.`)) return;
    try {
        const { error } = await supabaseClient.from('slot_types').delete().eq('id', id).eq('org_id', org);
        if (error) throw error;
        _schedToast('🗑️ Tipo eliminato.');
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] deleteType:', e);
        _schedToast('⚠️ Impossibile eliminare (potrebbe essere usato in prenotazioni).', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// EDITOR 2 — FASCE ORARIE (time_slots_config)
// ════════════════════════════════════════════════════════════════════════════
function _schedRenderSlots() {
    const list = _schedData.timeSlots;
    let rows = '';
    if (list.length === 0) {
        rows = '<div class="sched-empty">Nessuna fascia oraria configurata. Aggiungine una.</div>';
    } else {
        rows = list.map(ts => `
            <div class="sched-row ${ts.is_active ? '' : 'is-inactive'}">
                <span class="sched-time-chip">🕐 ${_escHtml(_schedSlotLabel(ts))}</span>
                <div class="sched-row-main">
                    <div class="sched-row-title">${_escHtml(ts.label || _schedSlotLabel(ts))}
                        ${ts.is_active ? '' : '<span class="sched-badge sched-badge--off">disattiva</span>'}
                    </div>
                    <div class="sched-row-sub">ordine ${ts.sort_order}</div>
                </div>
                <div class="sched-row-actions">
                    <button class="sched-btn-icon" title="Modifica" onclick="schedEditSlot('${ts.id}')">✏️</button>
                    <button class="sched-btn-icon sched-btn-icon--danger" title="Elimina" onclick="schedDeleteSlot('${ts.id}')">🗑️</button>
                </div>
            </div>`).join('');
    }

    return `
        <div class="sched-section">
            <div class="sched-section-head">
                <div>
                    <h3 class="sched-section-title">Fasce orarie</h3>
                    <p class="sched-section-desc">Gli intervalli prenotabili della giornata. L'etichetta usata nelle prenotazioni è "HH:MM - HH:MM".</p>
                </div>
                <button class="sched-btn-primary" onclick="schedEditSlot()">+ Nuova fascia</button>
            </div>
            <div class="sched-list">${rows}</div>
            <div id="schedSlotForm"></div>
        </div>`;
}

function schedEditSlot(id) {
    const ts = id ? _schedData.timeSlots.find(s => s.id === id) : null;
    const host = document.getElementById('schedSlotForm');
    if (!host) return;
    const v = ts || { start_time: '09:00', end_time: '10:00', label: '', sort_order: _schedData.timeSlots.length };

    host.innerHTML = `
        <div class="sched-form">
            <h4 class="sched-form-title">${ts ? 'Modifica fascia' : 'Nuova fascia oraria'}</h4>
            <div class="sched-form-grid">
                <label class="sched-field">
                    <span>Inizio</span>
                    <input type="time" id="tsStart" value="${_escHtml(String(v.start_time).slice(0,5))}">
                </label>
                <label class="sched-field">
                    <span>Fine</span>
                    <input type="time" id="tsEnd" value="${_escHtml(String(v.end_time).slice(0,5))}">
                </label>
                <label class="sched-field">
                    <span>Etichetta (opzionale)</span>
                    <input type="text" id="tsLabel" value="${_escHtml(v.label || '')}" placeholder="Mattina">
                </label>
                <label class="sched-field">
                    <span>Ordine</span>
                    <input type="number" id="tsSort" step="1" value="${v.sort_order}">
                </label>
            </div>
            <div class="sched-form-actions">
                <button class="sched-btn-ghost" onclick="schedCloseSlotForm()">Annulla</button>
                <button class="sched-btn-primary" onclick="schedSaveSlot(${ts ? `'${ts.id}'` : 'null'})">${ts ? 'Salva' : 'Crea fascia'}</button>
            </div>
        </div>`;
    host.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function schedCloseSlotForm() {
    const host = document.getElementById('schedSlotForm');
    if (host) host.innerHTML = '';
}

async function schedSaveSlot(id) {
    const org = _schedRequireOrg();
    if (!org) return;

    const start = document.getElementById('tsStart')?.value || '';
    const end = document.getElementById('tsEnd')?.value || '';
    if (!start || !end) { _schedToast('⚠️ Inserisci inizio e fine.', 'error'); return; }
    if (end <= start) { _schedToast('⚠️ La fine deve essere dopo l\'inizio.', 'error'); return; }

    const payload = {
        start_time: start,
        end_time: end,
        label: (document.getElementById('tsLabel')?.value || '').trim() || null,
        sort_order: parseInt(document.getElementById('tsSort')?.value || '0', 10) || 0
    };

    try {
        if (id) {
            const { error } = await supabaseClient.from('time_slots_config').update(payload).eq('id', id).eq('org_id', org);
            if (error) throw error;
            _schedToast('✅ Fascia aggiornata.');
        } else {
            const { error } = await supabaseClient.from('time_slots_config').insert({ ...payload, is_active: true, org_id: org });
            if (error) throw error;
            _schedToast('✅ Fascia creata.');
        }
        schedCloseSlotForm();
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] saveSlot:', e);
        const dup = e?.code === '23505' || /duplicate|unique/i.test(e?.message || '');
        _schedToast(dup ? '⚠️ Esiste già una fascia con questi orari.' : '⚠️ Errore nel salvataggio.', 'error');
    }
}

async function schedDeleteSlot(id) {
    const org = _schedRequireOrg();
    if (!org) return;
    const ts = _schedData.timeSlots.find(s => s.id === id);
    if (!await showConfirm(`Eliminare la fascia "${_schedSlotLabel(ts)}"? Verrà rimossa dalle settimane tipo.`)) return;
    try {
        const { error } = await supabaseClient.from('time_slots_config').delete().eq('id', id).eq('org_id', org);
        if (error) throw error;
        _schedToast('🗑️ Fascia eliminata.');
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] deleteSlot:', e);
        _schedToast('⚠️ Errore eliminazione.', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// EDITOR 3 — SETTIMANA TIPO (weekly_schedule_templates + weekly_template_slots)
// Griglia 7 giorni × N fasce: ogni cella sceglie slot_type + capacity (override riga).
// ════════════════════════════════════════════════════════════════════════════
function _schedRenderTemplate() {
    const templates = _schedData.templates;
    const slots = _schedData.timeSlots.filter(t => t.is_active);
    const types = _schedData.slotTypes.filter(t => t.is_active);

    // Selettore template + azioni
    const tplOptions = templates.map(t =>
        `<option value="${t.id}" ${t.id === _schedSelectedTemplateId ? 'selected' : ''}>${_escHtml(t.name)}</option>`
    ).join('');

    const current = templates.find(t => t.id === _schedSelectedTemplateId);

    let head = `
        <div class="sched-section-head">
            <div>
                <h3 class="sched-section-title">Settimana tipo</h3>
                <p class="sched-section-desc">Configura per ogni giorno e fascia il tipo di lezione e la capienza. I template sono <strong>modelli riutilizzabili</strong>: per metterli in calendario attiva le singole settimane in <strong>“Attiva settimane”</strong>.</p>
            </div>
            <button class="sched-btn-primary" onclick="schedNewTemplate()">+ Nuova settimana</button>
        </div>`;

    if (templates.length === 0) {
        return `<div class="sched-section">${head}
            <div class="sched-empty">Nessuna settimana tipo. Creane una per impostare la griglia ricorrente.</div></div>`;
    }

    const tplBar = `
        <div class="sched-tpl-bar">
            <label class="sched-field sched-field--inline">
                <span>Settimana</span>
                <select id="schedTplSelect" onchange="schedSelectTemplate(this.value)">${tplOptions}</select>
            </label>
            <div class="sched-tpl-actions">
                <button class="sched-btn-icon" title="Rinomina" onclick="schedRenameTemplate('${_schedSelectedTemplateId}')">✏️</button>
                <button class="sched-btn-icon sched-btn-icon--danger" title="Elimina settimana" onclick="schedDeleteTemplate('${_schedSelectedTemplateId}')">🗑️</button>
            </div>
        </div>`;

    if (slots.length === 0 || types.length === 0) {
        return `<div class="sched-section">${head}${tplBar}
            <div class="sched-empty">Per comporre la griglia servono almeno una <strong>fascia oraria</strong> e un <strong>tipo di slot</strong> attivi.</div></div>`;
    }

    // Mappa rapida cella → riga template (chiave "weekday|time_slot_id")
    const cellMap = {};
    _schedData.tplSlots.forEach(ws => { cellMap[`${ws.weekday}|${ws.time_slot_id}`] = ws; });

    // Header colonne = giorni
    let grid = '<div class="sched-grid-wrap"><table class="sched-grid"><thead><tr><th class="sched-grid-corner">Fascia</th>';
    _WEEKDAY_ORDER.forEach(wd => {
        grid += `<th>${_escHtml(_WEEKDAY_SHORT[wd])}</th>`;
    });
    grid += '</tr></thead><tbody>';

    // Righe = fasce orarie
    slots.forEach(ts => {
        const label = _schedSlotLabel(ts);
        grid += `<tr><th class="sched-grid-time">${_escHtml(label)}</th>`;
        _WEEKDAY_ORDER.forEach(wd => {
            const cell = cellMap[`${wd}|${ts.id}`];
            const stId = cell ? cell.slot_type_id : '';
            const cap = cell && cell.capacity != null ? cell.capacity : '';
            const st = types.find(t => t.id === stId);
            const dot = st ? `<span class="sched-cell-dot" style="background:${_escHtml(st.color || '#8B5CF6')}"></span>` : '';
            const typeOpts = `<option value="">—</option>` + types.map(t =>
                `<option value="${t.id}" ${t.id === stId ? 'selected' : ''}>${_escHtml(t.label)}</option>`).join('');
            grid += `
                <td class="sched-cell ${st ? 'has-type' : ''}">
                    <div class="sched-cell-inner">
                        ${dot}
                        <select class="sched-cell-type" onchange="schedSetCell(${wd}, '${ts.id}', this.value, null)">${typeOpts}</select>
                        <input class="sched-cell-cap" type="number" min="0" step="1" placeholder="cap"
                               value="${cap}" title="Capienza (vuoto = default del tipo)"
                               onchange="schedSetCellCapacity(${wd}, '${ts.id}', this.value)" ${st ? '' : 'disabled'}>
                    </div>
                </td>`;
        });
        grid += '</tr>';
    });
    grid += '</tbody></table></div>';

    return `<div class="sched-section">${head}${tplBar}
        <p class="sched-grid-hint">Seleziona il tipo per ogni cella. Il campo numerico imposta la capienza solo per quella cella (vuoto = capienza di default del tipo).</p>
        ${grid}</div>`;
}

function schedSelectTemplate(id) {
    _schedSelectedTemplateId = id || null;
    _schedLoadTemplateSlots().then(() => _schedRenderActiveSection());
}

async function schedNewTemplate() {
    const org = _schedRequireOrg();
    if (!org) return;
    const name = (await showPrompt('Nome della nuova settimana tipo:', `Settimana ${_schedData.templates.length + 1}`, { confirmText: 'Crea' }) || '').trim();
    if (!name) return;
    try {
        const isFirst = _schedData.templates.length === 0;
        const { data, error } = await supabaseClient
            .from('weekly_schedule_templates')
            .insert({ org_id: org, name, is_active: isFirst })
            .select('id')
            .single();
        if (error) throw error;
        _schedSelectedTemplateId = data.id;
        _schedToast('✅ Settimana creata.');
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] newTemplate:', e);
        _schedToast('⚠️ Errore creazione settimana.', 'error');
    }
}

async function schedRenameTemplate(id) {
    const org = _schedRequireOrg();
    if (!org) return;
    const tpl = _schedData.templates.find(t => t.id === id);
    const name = (await showPrompt('Nuovo nome:', tpl?.name || '', { confirmText: 'Rinomina' }) || '').trim();
    if (!name) return;
    try {
        const { error } = await supabaseClient.from('weekly_schedule_templates').update({ name }).eq('id', id).eq('org_id', org);
        if (error) throw error;
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] renameTemplate:', e);
        _schedToast('⚠️ Errore rinomina.', 'error');
    }
}

async function schedDeleteTemplate(id) {
    const org = _schedRequireOrg();
    if (!org) return;
    const tpl = _schedData.templates.find(t => t.id === id);
    if (!await showConfirm(`Eliminare la settimana "${tpl?.name || ''}" e tutte le sue celle?`)) return;
    try {
        // weekly_template_slots ha ON DELETE CASCADE sul template
        const { error } = await supabaseClient.from('weekly_schedule_templates').delete().eq('id', id).eq('org_id', org);
        if (error) throw error;
        _schedSelectedTemplateId = null;
        _schedToast('🗑️ Settimana eliminata.');
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] deleteTemplate:', e);
        _schedToast('⚠️ Errore eliminazione.', 'error');
    }
}

// Imposta il tipo di una cella (upsert/delete riga weekly_template_slots).
// stId vuoto → rimuove la riga (cella "—").
async function schedSetCell(weekday, timeSlotId, stId, capacity) {
    const org = _schedRequireOrg();
    if (!org || !_schedSelectedTemplateId) return;
    const existing = _schedData.tplSlots.find(w => w.weekday === weekday && w.time_slot_id === timeSlotId);

    try {
        if (!stId) {
            if (existing) {
                const { error } = await supabaseClient.from('weekly_template_slots').delete().eq('id', existing.id).eq('org_id', org);
                if (error) throw error;
            }
        } else if (existing) {
            // Al cambio TIPO della cella resettiamo SEMPRE la capienza (anche se è già null):
            // così la cella eredita la default_capacity del nuovo tipo invece di trattenere
            // la capienza assoluta del tipo precedente. Il null viene quindi persistito.
            const patch = { slot_type_id: stId, capacity };
            const { error } = await supabaseClient.from('weekly_template_slots').update(patch).eq('id', existing.id).eq('org_id', org);
            if (error) throw error;
        } else {
            const { error } = await supabaseClient.from('weekly_template_slots').insert({
                org_id: org,
                template_id: _schedSelectedTemplateId,
                weekday,
                time_slot_id: timeSlotId,
                slot_type_id: stId,
                capacity: capacity
            });
            if (error) throw error;
        }
        await _schedLoadTemplateSlots();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] setCell:', e);
        _schedToast('⚠️ Errore aggiornamento cella.', 'error');
    }
}

// Aggiorna SOLO la capienza di una cella esistente (vuoto = null = default tipo)
async function schedSetCellCapacity(weekday, timeSlotId, rawValue) {
    const org = _schedRequireOrg();
    if (!org) return;
    const existing = _schedData.tplSlots.find(w => w.weekday === weekday && w.time_slot_id === timeSlotId);
    if (!existing) return;   // nessun tipo selezionato: niente da fare
    // vuoto/invalido → null (= eredita default del tipo); '0' resta uno 0 legittimo
    const trimmed = String(rawValue).trim();
    const capacity = trimmed === '' ? null : _schedParseInt(trimmed, null);
    try {
        const { error } = await supabaseClient.from('weekly_template_slots').update({ capacity }).eq('id', existing.id).eq('org_id', org);
        if (error) throw error;
        await _schedLoadTemplateSlots();
        // niente re-render completo: aggiorna solo lo stato in memoria (evita flicker dell'input)
    } catch (e) {
        console.error('[Schedule] setCellCapacity:', e);
        _schedToast('⚠️ Errore capienza cella.', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// EDITOR 3.5 — ATTIVA SETTIMANE (activated_weeks)
// Il calendario si attiva UNA SETTIMANA ALLA VOLTA, manualmente: ogni settimana
// concreta punta a un template scelto. Le settimane non attivate non hanno slot;
// quelle già attivate restano invariate quando se ne attiva un'altra.
// ════════════════════════════════════════════════════════════════════════════

// Lunedì (Date) della settimana che contiene `d`. Allineato a date_trunc('week')
// di Postgres (settimana ISO lunedì→domenica) e a _mondayYMD() in data.js.
function _schedMondayOf(d) {
    const dt = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    const day = dt.getDay();                 // 0=Dom .. 6=Sab
    const diff = day === 0 ? -6 : 1 - day;   // → lunedì
    dt.setDate(dt.getDate() + diff);
    return dt;
}

function _schedYMD(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// "23/06" per le etichette del range settimana.
function _schedDM(d) {
    return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function _schedTemplateName(id) {
    const t = _schedData.templates.find(x => x.id === id);
    return t ? t.name : '—';
}

function _schedRenderActivation() {
    const templates = _schedData.templates;

    let head = `
        <div class="sched-section-head">
            <div>
                <h3 class="sched-section-title">Attiva settimane</h3>
                <p class="sched-section-desc">Attiva il calendario <strong>una settimana alla volta</strong>, scegliendo quale template applicare. Le settimane non attivate non mostrano slot; quelle già attivate restano invariate.</p>
            </div>
        </div>`;

    if (templates.length === 0) {
        return `<div class="sched-section">${head}
            <div class="sched-empty">Crea prima almeno una <strong>settimana tipo</strong> (tab “Settimana tipo”) da applicare alle settimane.</div></div>`;
    }

    // Mappa weekStart(YMD) → riga activated_weeks
    const activeMap = {};
    _schedData.activated.forEach(a => { activeMap[String(a.week_start).slice(0, 10)] = a; });

    // Default del select per riga: template già attivato per quella settimana,
    // altrimenti il template attualmente selezionato nell'editor (o il primo).
    const fallbackTpl = (_schedSelectedTemplateId && templates.find(t => t.id === _schedSelectedTemplateId))
        ? _schedSelectedTemplateId : templates[0].id;

    const startMon = _schedMondayOf(new Date());

    // Finestra: settimana corrente + N successive.
    const windowKeys = new Set();
    let rows = '';
    for (let i = 0; i <= _SCHED_ACTIVATION_WEEKS; i++) {
        const mon = new Date(startMon); mon.setDate(startMon.getDate() + i * 7);
        const sun = new Date(mon); sun.setDate(mon.getDate() + 6);
        const ymd = _schedYMD(mon);
        windowKeys.add(ymd);
        rows += _schedActivationRow(ymd, mon, sun, activeMap[ymd], templates, fallbackTpl, i === 0);
    }

    // Settimane attivate FUORI dalla finestra (passate o oltre l'orizzonte): mostrate
    // a parte per poterle disattivare/cambiare senza perderle di vista.
    const outside = _schedData.activated
        .map(a => String(a.week_start).slice(0, 10))
        .filter(k => !windowKeys.has(k))
        .sort();
    let outsideBlock = '';
    if (outside.length) {
        const orows = outside.map(ymd => {
            const [y, m, d] = ymd.split('-').map(Number);
            const mon = new Date(y, m - 1, d);
            const sun = new Date(mon); sun.setDate(mon.getDate() + 6);
            return _schedActivationRow(ymd, mon, sun, activeMap[ymd], templates, fallbackTpl, false);
        }).join('');
        outsideBlock = `
            <div class="sched-ovr-orphans">
                <p class="sched-section-desc">Altre settimane attivate (fuori dalle prossime ${_SCHED_ACTIVATION_WEEKS} settimane).</p>
                <div class="sched-list">${orows}</div>
            </div>`;
    }

    return `<div class="sched-section">${head}
        <div class="sched-list">${rows}</div>
        ${outsideBlock}</div>`;
}

// Una riga settimana: range + select template + attiva/aggiorna/disattiva.
function _schedActivationRow(ymd, mon, sun, activeRow, templates, fallbackTpl, isCurrent) {
    const isActive = !!activeRow;
    const selectedTpl = isActive ? activeRow.template_id : fallbackTpl;
    const tplOpts = templates.map(t =>
        `<option value="${t.id}" ${t.id === selectedTpl ? 'selected' : ''}>${_escHtml(t.name)}</option>`).join('');
    const range = `${_schedDM(mon)} – ${_schedDM(sun)}/${sun.getFullYear()}`;
    const badge = isActive
        ? `<span class="sched-badge">✅ attiva · ${_escHtml(_schedTemplateName(activeRow.template_id))}</span>`
        : `<span class="sched-badge sched-badge--off">non attiva</span>`;

    return `
        <div class="sched-row sched-ovr-row ${isActive ? 'has-ovr' : ''}">
            <span class="sched-time-chip">🗓️ ${range}${isCurrent ? ' · <strong>questa settimana</strong>' : ''}</span>
            <div class="sched-ovr-controls">
                <select id="awTpl-${ymd}" class="sched-ovr-type">${tplOpts}</select>
                <button class="sched-btn-primary sched-btn-sm" onclick="schedActivateWeek('${ymd}')">${isActive ? 'Aggiorna' : 'Attiva'}</button>
                ${isActive ? `<button class="sched-btn-icon sched-btn-icon--danger" title="Disattiva settimana" onclick="schedDeactivateWeek('${ymd}')">🗑️</button>` : ''}
            </div>
            ${badge}
        </div>`;
}

// Domenica (YMD) della settimana il cui lunedì è weekStartYMD.
function _schedWeekEnd(weekStartYMD) {
    const [y, m, d] = String(weekStartYMD).slice(0, 10).split('-').map(Number);
    const dt = new Date(y, m - 1, d);
    dt.setDate(dt.getDate() + 6);
    return _schedYMD(dt);
}

// True se nella settimana [lunedì..domenica] esiste almeno una prenotazione attiva
// (status != cancelled). Usato per impedire di cambiare/disattivare una settimana
// su cui qualcuno è già prenotato. In caso di errore di rete restituisce true
// (fail-safe: meglio bloccare che lasciar modificare una settimana con iscritti).
async function _schedWeekHasBookings(org, weekStart) {
    const weekEnd = _schedWeekEnd(weekStart);
    try {
        const { count, error } = await supabaseClient
            .from('bookings')
            .select('id', { count: 'exact', head: true })
            .eq('org_id', org)
            .neq('status', 'cancelled')
            .gte('date', weekStart)
            .lte('date', weekEnd);
        if (error) throw error;
        return (count || 0) > 0;
    } catch (e) {
        console.error('[Schedule] weekHasBookings:', e);
        return true;   // fail-safe: non sappiamo → blocca
    }
}

// Attiva (o aggiorna il template di) una settimana concreta.
async function schedActivateWeek(weekStart) {
    const org = _schedRequireOrg();
    if (!org) return;
    const tplId = document.getElementById(`awTpl-${weekStart}`)?.value || '';
    if (!tplId) { _schedToast('⚠️ Seleziona un template per la settimana.', 'error'); return; }

    // Guard: cambiare il TEMPLATE di una settimana già attiva ne ridefinisce
    // tipi/capienze degli slot → vietato se qualcuno è già prenotato in quella
    // settimana. La prima attivazione (additiva) e il "ri-applica stesso template"
    // (no-op) restano sempre consentiti.
    const existing = _schedData.activated.find(a => String(a.week_start).slice(0, 10) === weekStart);
    if (existing && existing.template_id !== tplId) {
        if (await _schedWeekHasBookings(org, weekStart)) {
            _schedToast('⚠️ Settimana con prenotazioni attive: non puoi cambiarne il template. Disdici/sposta prima le prenotazioni.', 'error');
            return;
        }
    }

    try {
        const { error } = await supabaseClient
            .from('activated_weeks')
            .upsert({ org_id: org, week_start: weekStart, template_id: tplId }, { onConflict: 'org_id,week_start' });
        if (error) throw error;
        _schedToast('✅ Settimana attivata.');
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] activateWeek:', e);
        _schedToast('⚠️ Errore attivazione settimana.', 'error');
    }
}

async function schedDeactivateWeek(weekStart) {
    const org = _schedRequireOrg();
    if (!org) return;

    // Guard: non disattivare una settimana con prenotazioni attive (gli slot
    // sparirebbero da sotto i clienti già iscritti).
    if (await _schedWeekHasBookings(org, weekStart)) {
        _schedToast('⚠️ Settimana con prenotazioni attive: non puoi disattivarla. Disdici/sposta prima le prenotazioni.', 'error');
        return;
    }

    if (!await showConfirm('Disattivare questa settimana? Gli slot non saranno più disponibili (le prenotazioni esistenti restano nel registro).')) return;
    try {
        const { error } = await supabaseClient
            .from('activated_weeks')
            .delete()
            .eq('org_id', org)
            .eq('week_start', weekStart);
        if (error) throw error;
        _schedToast('🗑️ Settimana disattivata.');
        await _schedLoadAll();
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] deactivateWeek:', e);
        _schedToast('⚠️ Errore disattivazione.', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// EDITOR 4 — OVERRIDE PER DATA (schedule_overrides)
// Capienza ASSOLUTA per uno specifico slot/data (sostituisce i +/- extra legacy).
// ════════════════════════════════════════════════════════════════════════════
function _schedRenderOverrides() {
    const slots = _schedData.timeSlots.filter(t => t.is_active);
    const types = _schedData.slotTypes;

    // Data di default: oggi
    if (!_schedOverrideDate) {
        const d = new Date();
        _schedOverrideDate = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    }

    // Mappa override per orario (la chiave è l'etichetta "HH:MM - HH:MM").
    // NB: schedule_overrides è indicizzato per label `time`, sia qui che server-side in
    // resolve_slot_config — non c'è un time_slot_id stabile sulla riga override.
    // Conseguenza: se si modifica l'orario di una fascia, l'etichetta cambia e l'override
    // salvato con la vecchia etichetta diventa "orfano" — invisibile sotto la nuova fascia
    // e non più applicato da resolve_slot_config (che cerca per label). Per evitare che resti
    // nascosto nel DB lo rendiamo visibile più sotto, così l'admin può rimuoverlo.
    // (Un fix completo "per id" richiede una colonna time_slot_id su schedule_overrides e la
    //  riscrittura di resolve_slot_config: fuori dallo scope di questo file.)
    const ovrMap = {};
    _schedData.overrides.forEach(o => { ovrMap[o.time] = o; });

    // Etichette delle fasce attive correnti → tutto ciò che non vi rientra è orfano.
    const activeLabels = new Set(slots.map(ts => _schedSlotLabel(ts)));
    const orphanOvrs = _schedData.overrides.filter(o => !activeLabels.has(o.time));

    let rows = '';
    if (slots.length === 0) {
        rows = '<div class="sched-empty">Configura prima le fasce orarie per impostare gli override.</div>';
    } else {
        rows = '<div class="sched-list">' + slots.map(ts => {
            const label = _schedSlotLabel(ts);
            const ovr = ovrMap[label];
            const stId = ovr ? (ovr.slot_type_id || '') : '';
            const st = types.find(t => t.id === stId);
            const cap = ovr && ovr.capacity != null ? ovr.capacity : '';
            const typeOpts = `<option value="">— Nessun override —</option>` + types.map(t =>
                `<option value="${t.id}" ${t.id === stId ? 'selected' : ''}>${_escHtml(t.label)}</option>`).join('');
            return `
                <div class="sched-row sched-ovr-row ${ovr ? 'has-ovr' : ''}">
                    <span class="sched-time-chip">🕐 ${_escHtml(label)}</span>
                    <div class="sched-ovr-controls">
                        <select id="ovrType-${ts.id}" class="sched-ovr-type">${typeOpts}</select>
                        <input id="ovrCap-${ts.id}" class="sched-ovr-cap" type="number" min="0" step="1"
                               placeholder="capienza" value="${cap}" title="Capienza assoluta per questa data">
                        <button class="sched-btn-primary sched-btn-sm" onclick="schedSaveOverride('${label}', '${ts.id}')">Salva</button>
                        ${ovr ? `<button class="sched-btn-icon sched-btn-icon--danger" title="Rimuovi override" onclick="schedDeleteOverride('${label}')">🗑️</button>` : ''}
                    </div>
                    ${st ? `<span class="sched-ovr-badge" style="background:${_escHtml(st.color || '#8B5CF6')}1a;color:${_escHtml(st.color || '#8B5CF6')}">${_escHtml(st.label)}${cap !== '' ? ` · cap ${cap}` : ''}</span>` : ''}
                </div>`;
        }).join('') + '</div>';
    }

    // Override "orfani": la loro etichetta non corrisponde più a nessuna fascia attiva
    // (tipicamente perché la fascia è stata modificata/rinominata o disattivata).
    // Resterebbero invisibili: li mostriamo per consentirne la rimozione.
    let orphanBlock = '';
    if (orphanOvrs.length) {
        const orphanRows = orphanOvrs.map(o => {
            const stO = types.find(t => t.id === (o.slot_type_id || ''));
            const capO = o.capacity != null ? o.capacity : '';
            return `
                <div class="sched-row sched-ovr-row has-ovr is-inactive">
                    <span class="sched-time-chip">⚠️ ${_escHtml(o.time)}</span>
                    <div class="sched-ovr-controls">
                        <span class="sched-row-sub">Override orfano: fascia non più attiva${stO ? ` · ${_escHtml(stO.label)}` : ''}${capO !== '' ? ` · cap ${capO}` : ''}</span>
                        <button class="sched-btn-icon sched-btn-icon--danger" title="Rimuovi override orfano" onclick="schedDeleteOverride('${_escHtml(o.time).replace(/'/g, "\\'")}')">🗑️</button>
                    </div>
                </div>`;
        }).join('');
        orphanBlock = `
            <div class="sched-ovr-orphans">
                <p class="sched-section-desc">⚠️ Override per orari non più tra le fasce attive (non vengono più applicati). Rimuovili per fare pulizia.</p>
                <div class="sched-list">${orphanRows}</div>
            </div>`;
    }

    return `
        <div class="sched-section">
            <div class="sched-section-head">
                <div>
                    <h3 class="sched-section-title">Override per data</h3>
                    <p class="sched-section-desc">Per una data specifica forza tipo e <strong>capienza assoluta</strong> di uno slot. Ha la precedenza sulla settimana tipo.</p>
                </div>
                <label class="sched-field sched-field--inline">
                    <span>Data</span>
                    <input type="date" id="schedOvrDate" value="${_escHtml(_schedOverrideDate)}" onchange="schedChangeOverrideDate(this.value)">
                </label>
            </div>
            ${rows}
            ${orphanBlock}
        </div>`;
}

function schedChangeOverrideDate(date) {
    _schedOverrideDate = date;
    _schedLoadOverrides(date).then(() => _schedRenderActiveSection());
}

// Salva/aggiorna un override puntuale (upsert su UNIQUE(org_id,date,time))
async function schedSaveOverride(timeLabel, tsId) {
    const org = _schedRequireOrg();
    if (!org || !_schedOverrideDate) return;
    const stId = document.getElementById(`ovrType-${tsId}`)?.value || '';
    const rawCap = (document.getElementById(`ovrCap-${tsId}`)?.value || '').trim();

    if (!stId) { _schedToast('⚠️ Seleziona un tipo di slot per l\'override.', 'error'); return; }
    // vuoto/invalido → null (= default del tipo); '0' resta uno 0 legittimo
    const capacity = rawCap === '' ? null : _schedParseInt(rawCap, null);

    if (capacity === null || capacity < 0) { _schedToast('⚠️ Inserisci una capienza valida (anche 0).', 'error'); return; }

    try {
        const { error } = await supabaseClient.rpc('admin_upsert_schedule_override', {
            p_date: _schedOverrideDate,
            p_time: timeLabel,
            p_slot_type_id: stId,
            p_capacity: capacity,
        });
        if (error) throw error;
        _schedToast('✅ Override salvato.');
        await _schedLoadOverrides(_schedOverrideDate);
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] saveOverride:', e);
        _schedToast('⚠️ Errore nel salvataggio override.', 'error');
    }
}

async function schedDeleteOverride(timeLabel) {
    const org = _schedRequireOrg();
    if (!org || !_schedOverrideDate) return;
    if (!await showConfirm(`Rimuovere l'override delle ${timeLabel} del ${_schedOverrideDate}?`)) return;
    try {
        const { error } = await supabaseClient.rpc('admin_delete_schedule_override', {
            p_date: _schedOverrideDate,
            p_time: timeLabel,
        });
        if (error) throw error;
        _schedToast('🗑️ Override rimosso.');
        await _schedLoadOverrides(_schedOverrideDate);
        _schedRenderActiveSection();
    } catch (e) {
        console.error('[Schedule] deleteOverride:', e);
        _schedToast('⚠️ Errore rimozione override.', 'error');
    }
}

// ════════════════════════════════════════════════════════════════════════════
// BRIDGE LEGACY — getScheduleForDate è consumata da admin-calendar.js e
// admin-messaggi.js: mantiene il contratto sulla cache localStorage degli
// override (BookingStorage) nel vecchio formato [{time,type,...}].
// ════════════════════════════════════════════════════════════════════════════

// Schedule effettivo per una data (slot configurati). Vecchio formato per il calendario.
function getScheduleForDate(dateFormatted, dayName) {
    try {
        const overrides = BookingStorage.getScheduleOverrides();
        // 1) override puntuale per questa data (eccezione) → ha la precedenza
        if (overrides[dateFormatted] && overrides[dateFormatted].length) return overrides[dateFormatted];
        // 2) altrimenti applica il template della SETTIMANA ATTIVATA che contiene la
        //    data (date-aware: vuoto se la settimana non è stata attivata a mano).
        if (typeof getWeeklySchedule === 'function') {
            const weekly = getWeeklySchedule(dateFormatted);
            if (weekly) {
                // nome giorno italiano derivato dalla data (robusto a mismatch di formato di dayName)
                let key = dayName;
                const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateFormatted || '');
                if (m) {
                    const wd = new Date(+m[1], (+m[2]) - 1, +m[3]).getDay(); // locale, niente shift UTC
                    key = ['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato'][wd];
                }
                if (weekly[key] && weekly[key].length) return weekly[key];
            }
        }
        return [];
    } catch {
        return [];
    }
}

