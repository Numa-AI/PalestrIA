// ── Settings Tab ──────────────────────────────────────────────────────────────

function renderSettingsTab() {
    const mode = CancellationModeStorage.get();
    document.querySelectorAll('input[name="cancellationMode"]').forEach(radio => {
        radio.checked = radio.value === mode;
    });
    renderCertEditableUI();
    renderCertBlockUI();
    renderAssicBlockUI();
    renderBookingBadgesUI();
    renderWeekTemplatesUI();
    renderMaintenanceUI();
}

// ── Maintenance Mode ─────────────────────────────────────────────────────────

async function renderMaintenanceUI() {
    const toggle = document.getElementById('maintenanceModeToggle');
    const text = document.getElementById('maintenanceModeText');
    const adminToggle = document.getElementById('maintenanceAdminToggle');
    const adminText = document.getElementById('maintenanceAdminText');
    const msgInput = document.getElementById('maintenanceMessageInput');
    if (!toggle) return;

    try {
        const { data } = await _queryWithTimeout(supabaseClient
            .from('app_settings')
            .select('key, value')
            .in('key', ['maintenance_mode', 'maintenance_message', 'maintenance_admin']));
        const flags = Object.fromEntries((data || []).map(r => [r.key, r.value]));

        const modeOn = flags.maintenance_mode === true || flags.maintenance_mode === 'true';
        toggle.checked = modeOn;
        if (text) text.textContent = modeOn ? 'Attiva' : 'Non attiva';

        const adminOn = flags.maintenance_admin === true || flags.maintenance_admin === 'true';
        if (adminToggle) adminToggle.checked = adminOn;
        if (adminText) adminText.textContent = adminOn ? 'Admin bloccato' : 'Admin accessibile';

        if (msgInput) msgInput.value = (typeof flags.maintenance_message === 'string') ? flags.maintenance_message : '';
    } catch (e) { console.warn('[Maintenance] renderUI error:', e); }
}

async function saveMaintenanceMode(val) {
    const toggle = document.getElementById('maintenanceModeToggle');
    const text = document.getElementById('maintenanceModeText');
    if (text) text.textContent = val ? 'Attiva' : 'Non attiva';
    const now = new Date().toISOString();
    try {
        const { error } = await _queryWithTimeout(
            supabaseClient.from('app_settings').upsert({ key: 'maintenance_mode', value: val, updated_at: now })
        );
        if (error) throw error;
        showToast(val ? '🔧 Manutenzione attivata' : '✅ Manutenzione disattivata', val ? 'error' : 'success');
    } catch (e) {
        console.error('[Maintenance] saveMode error:', e);
        if (toggle) toggle.checked = !val;
        if (text) text.textContent = !val ? 'Attiva' : 'Non attiva';
        showToast('Errore salvataggio manutenzione', 'error');
    }
}

async function saveMaintenanceAdmin(val) {
    const toggle = document.getElementById('maintenanceAdminToggle');
    if (val) {
        const pwd = prompt('Inserisci la password per bloccare anche l\'admin:');
        if (pwd !== 'Maldive') {
            showToast('Password errata.', 'error');
            if (toggle) toggle.checked = false;
            return;
        }
    }
    const text = document.getElementById('maintenanceAdminText');
    if (text) text.textContent = val ? 'Admin bloccato' : 'Admin accessibile';
    const now = new Date().toISOString();
    try {
        const { error } = await _queryWithTimeout(
            supabaseClient.from('app_settings').upsert({ key: 'maintenance_admin', value: val, updated_at: now })
        );
        if (error) throw error;
        showToast(val ? '⚠️ Admin bloccato — sblocca da Supabase' : '✅ Admin sbloccato', val ? 'error' : 'success');
    } catch (e) {
        console.error('[Maintenance] saveAdmin error:', e);
        if (toggle) toggle.checked = !val;
        if (text) text.textContent = !val ? 'Admin bloccato' : 'Admin accessibile';
        showToast('Errore salvataggio', 'error');
    }
}

async function saveMaintenanceMessage() {
    const input = document.getElementById('maintenanceMessageInput');
    const msg = (input?.value || '').trim();
    const now = new Date().toISOString();
    try {
        const { error } = await _queryWithTimeout(
            supabaseClient.from('app_settings').upsert({ key: 'maintenance_message', value: msg, updated_at: now })
        );
        if (error) throw error;
        const savedMsg = document.getElementById('maintenanceMessageSaved');
        if (savedMsg) { savedMsg.style.display = 'block'; setTimeout(() => { savedMsg.style.display = 'none'; }, 2000); }
    } catch (e) {
        console.error('[Maintenance] saveMessage error:', e);
        showToast('Errore salvataggio messaggio', 'error');
    }
}

function saveCancellationMode(mode) {
    CancellationModeStorage.set(mode);
}

function renderCertEditableUI() {
    const editable = CertEditableStorage.get();
    const toggle = document.getElementById('certEditableToggle');
    const text   = document.getElementById('certEditableText');
    if (toggle) toggle.checked = editable;
    if (text)   text.textContent = editable ? 'Modificabile dal cliente' : 'Non modificabile';
}

function saveCertEditable(val) {
    CertEditableStorage.set(val);
    const text = document.getElementById('certEditableText');
    if (text) text.textContent = val ? 'Modificabile dal cliente' : 'Non modificabile';
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
    CertBookingStorage.setBlockIfExpired(val);
    const text = document.getElementById('certBlockExpiredText');
    if (text) text.textContent = val ? 'Bloccato' : 'Non bloccato';
}

function saveCertBlockNotSet(val) {
    CertBookingStorage.setBlockIfNotSet(val);
    const text = document.getElementById('certBlockNotSetText');
    if (text) text.textContent = val ? 'Bloccato' : 'Non bloccato';
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
    AssicBookingStorage.setBlockIfExpired(val);
    const text = document.getElementById('assicBlockExpiredText');
    if (text) text.textContent = val ? 'Bloccato' : 'Non bloccato';
}

function saveAssicBlockNotSet(val) {
    AssicBookingStorage.setBlockIfNotSet(val);
    const text = document.getElementById('assicBlockNotSetText');
    if (text) text.textContent = val ? 'Bloccato' : 'Non bloccato';
}

// ── Week Templates ──────────────────────────────────────────────────────────

function _getActiveTemplateName() {
    const templates = WeekTemplateStorage.getAll();
    const activeId = WeekTemplateStorage.getActiveId();
    const active = templates.find(t => t.id === activeId);
    return active ? active.name : 'Settimana Standard';
}

function renderWeekTemplatesUI() {
    const container = document.getElementById('weekTemplatesContainer');
    if (!container) return;

    const templates = WeekTemplateStorage.getAll();
    const activeId = WeekTemplateStorage.getActiveId();

    let html = '<div class="week-templates-list">';
    templates.forEach(tpl => {
        const isActive = tpl.id === activeId;
        html += `
            <div class="week-template-card ${isActive ? 'active' : ''}">
                <div class="week-template-info">
                    <div class="week-template-name-row">
                        <span class="week-template-name" id="tplName-${tpl.id}">${_escHtml(tpl.name)}</span>
                        <input type="text" class="week-template-name-input" id="tplNameInput-${tpl.id}" value="${_escHtml(tpl.name)}" style="display:none" maxlength="40"
                            onkeydown="if(event.key==='Enter'){saveTemplateName(${tpl.id});}" onblur="saveTemplateName(${tpl.id})">
                        <button class="btn-template-rename" onclick="startRenamingTemplate(${tpl.id})" title="Rinomina">✏️</button>
                    </div>
                    <span class="week-template-summary">${_getTemplateSummary(tpl.schedule)}</span>
                </div>
                <div class="week-template-actions">
                    ${isActive
                        ? '<span class="week-template-active-badge">✅ Attiva</span>'
                        : `<button class="btn-template-activate" onclick="activateWeekTemplate(${tpl.id})">Attiva</button>`
                    }
                    <button class="btn-template-edit" onclick="openTemplateEditor(${tpl.id})" title="Modifica settimana">✏️ Modifica</button>
                </div>
            </div>`;
    });
    html += '</div>';
    container.innerHTML = html;
}

function _getTemplateSummary(schedule) {
    if (!schedule) return 'Non configurata';
    const days = Object.keys(schedule);
    let personal = 0, smallGroup = 0, groupClass = 0, cleaning = 0;
    days.forEach(day => {
        (schedule[day] || []).forEach(slot => {
            if (slot.type === SLOT_TYPES.PERSONAL) personal++;
            else if (slot.type === SLOT_TYPES.SMALL_GROUP) smallGroup++;
            else if (slot.type === SLOT_TYPES.GROUP_CLASS) groupClass++;
            else if (slot.type === SLOT_TYPES.CLEANING) cleaning++;
        });
    });
    const parts = [];
    if (personal) parts.push(`🟢 ${personal}`);
    if (smallGroup) parts.push(`🟡 ${smallGroup}`);
    if (groupClass) parts.push(`🔴 ${groupClass}`);
    if (cleaning) parts.push(`🧹 ${cleaning}`);
    return parts.length ? parts.join('  ') : 'Vuota';
}

function startRenamingTemplate(id) {
    const nameEl = document.getElementById(`tplName-${id}`);
    const inputEl = document.getElementById(`tplNameInput-${id}`);
    if (nameEl) nameEl.style.display = 'none';
    if (inputEl) { inputEl.style.display = 'inline-block'; inputEl.focus(); inputEl.select(); }
}

function saveTemplateName(id) {
    const nameEl = document.getElementById(`tplName-${id}`);
    const inputEl = document.getElementById(`tplNameInput-${id}`);
    if (!inputEl) return;
    const newName = inputEl.value.trim();
    if (newName) {
        WeekTemplateStorage.updateTemplate(id, { name: newName });
    }
    if (nameEl) { nameEl.textContent = newName || nameEl.textContent; nameEl.style.display = ''; }
    inputEl.style.display = 'none';
}

function activateWeekTemplate(id) {
    WeekTemplateStorage.setActiveId(id);
    renderWeekTemplatesUI();
}

// ── Template Editor Popup ───────────────────────────────────────────────────

let _tplEditorState = { id: null, name: null, schedule: null, selectedDay: 'Lunedì' };
const TPL_DAY_NAMES = ['Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato', 'Domenica'];

function openTemplateEditor(id) {
    const templates = WeekTemplateStorage.getAll();
    const tpl = templates.find(t => t.id === id);
    if (!tpl) return;

    _tplEditorState = {
        id: id,
        name: tpl.name,
        schedule: JSON.parse(JSON.stringify(tpl.schedule)),
        selectedDay: 'Lunedì'
    };

    // Create or reuse overlay
    let overlay = document.getElementById('templateEditorOverlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'templateEditorOverlay';
        overlay.className = 'template-editor-overlay';
        document.body.appendChild(overlay);
    }
    overlay.style.display = 'flex';
    _renderTemplateEditorContent();
}

function _renderTemplateEditorContent() {
    const overlay = document.getElementById('templateEditorOverlay');
    if (!overlay) return;

    const name = _tplEditorState.name || 'Settimana Standard';
    const schedule = _tplEditorState.schedule;
    const selectedDay = _tplEditorState.selectedDay;
    const daySlots = schedule[selectedDay] || [];

    let html = `
        <div class="template-editor-popup">
            <div class="template-editor-header">
                <h3>✏️ ${_escHtml(name)}</h3>
                <button class="template-editor-close" onclick="closeTemplateEditor()">✕</button>
            </div>

            <div class="template-editor-day-tabs">
                ${TPL_DAY_NAMES.map(d => `<button class="tpl-day-tab ${d === selectedDay ? 'active' : ''}" onclick="_tplSelectDay('${d}')">${d.substring(0, 3)}</button>`).join('')}
            </div>

            <div class="template-editor-slots">
                <p style="color:#9ca3af; margin-bottom:0.75rem; font-size:0.85rem"><strong>${selectedDay}</strong> — configura il tipo per ogni fascia oraria</p>`;

    ALL_TIME_SLOTS.forEach(timeSlot => {
        const existing = daySlots.find(s => s.time === timeSlot);
        const currentType = existing ? existing.type : '';

        html += `
                <div class="tpl-slot-row">
                    <span class="tpl-slot-time">🕐 ${timeSlot}</span>
                    <select class="tpl-slot-select" onchange="_tplUpdateSlot('${timeSlot}', this.value)">
                        <option value="">-- Nessuna lezione --</option>
                        <option value="${SLOT_TYPES.PERSONAL}" ${currentType === SLOT_TYPES.PERSONAL ? 'selected' : ''}>Autonomia</option>
                        <option value="${SLOT_TYPES.SMALL_GROUP}" ${currentType === SLOT_TYPES.SMALL_GROUP ? 'selected' : ''}>Lezione di Gruppo</option>
                        <option value="${SLOT_TYPES.GROUP_CLASS}" ${currentType === SLOT_TYPES.GROUP_CLASS ? 'selected' : ''}>Slot prenotato</option>
                        <option value="${SLOT_TYPES.CLEANING}" ${currentType === SLOT_TYPES.CLEANING ? 'selected' : ''}>Pulizie</option>
                    </select>
                    ${currentType ? `<span class="tpl-slot-badge ${currentType}">${SLOT_NAMES[currentType]}</span>` : ''}
                </div>`;
    });

    html += `
            </div>

            <div class="template-editor-footer">
                <button class="btn-template-save" onclick="saveTemplateEditor()">💾 Salva</button>
                <button class="btn-template-cancel" onclick="closeTemplateEditor()">Annulla</button>
            </div>
        </div>`;

    overlay.innerHTML = html;
}

function _tplSelectDay(day) {
    _tplEditorState.selectedDay = day;
    _renderTemplateEditorContent();
}

function _tplUpdateSlot(timeSlot, newType) {
    const day = _tplEditorState.selectedDay;
    if (!_tplEditorState.schedule[day]) _tplEditorState.schedule[day] = [];
    let daySlots = _tplEditorState.schedule[day];

    const idx = daySlots.findIndex(s => s.time === timeSlot);
    if (newType === '') {
        if (idx !== -1) daySlots.splice(idx, 1);
    } else {
        if (idx !== -1) {
            daySlots[idx].type = newType;
            // Remove client fields for templates
            delete daySlots[idx].client;
            delete daySlots[idx].bookingId;
        } else {
            daySlots.push({ time: timeSlot, type: newType });
        }
    }
    daySlots.sort((a, b) => a.time.localeCompare(b.time));
    _tplEditorState.schedule[day] = daySlots;
    _renderTemplateEditorContent();
}

function saveTemplateEditor() {
    const { id, schedule } = _tplEditorState;
    // Clean template slots: remove client/bookingId fields
    const cleanSchedule = {};
    for (const day in schedule) {
        cleanSchedule[day] = (schedule[day] || []).map(s => ({ time: s.time, type: s.type }));
    }
    WeekTemplateStorage.updateTemplate(id, { schedule: cleanSchedule });
    closeTemplateEditor();
    renderWeekTemplatesUI();
}

function closeTemplateEditor() {
    const overlay = document.getElementById('templateEditorOverlay');
    if (overlay) overlay.style.display = 'none';
    _tplEditorState = { id: null, name: null, schedule: null, selectedDay: 'Lunedì' };
}

// ── Health Check ─────────────────────────────────────────────────────────────
const HEALTH_CHECKS = [
    { key: 'ghost_users',      label: '👻 Utenti senza profilo',         desc: 'Account auth.users senza riga in profiles', fix: 'Crea profilo da metadata' },
    { key: 'orphan_bookings',  label: '📅 Prenotazioni orfane',          desc: 'Prenotazioni con user_id che punta a profilo inesistente', fix: 'Scollega user_id (booking intatta)' },
    { key: 'email_mismatch',   label: '📧 Email non corrispondenti',     desc: 'Prenotazioni con email diversa dal profilo collegato (es. admin ha prenotato per conto del cliente)', fix: 'Ricollega user_id al profilo corretto' },
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
                    html += `<div style="font-size:0.8rem;color:#6b7280;padding:0.15rem 0 0.15rem 1.75rem;">• ${item.email || item.booking_email || '—'}${item.date ? ' (' + item.date + ')' : ''}${item.profile_email ? ' → profilo: ' + item.profile_email : ''}</div>`;
                });
                if (items.length > 10) html += `<div style="font-size:0.8rem;color:#6b7280;padding:0.15rem 0 0.15rem 1.75rem;">... e altri ${items.length - 10}</div>`;
            }
        });

        const summary = totalIssues === 0
            ? '<div style="padding:0.75rem;background:#f0fdf4;border-radius:8px;color:#16a34a;font-weight:600;text-align:center;margin-bottom:0.75rem">✅ Nessuna anomalia rilevata</div>'
            : `<div style="padding:0.75rem;background:#fef2f2;border-radius:8px;color:#dc2626;font-weight:600;text-align:center;margin-bottom:0.75rem">⚠️ ${totalIssues} anomalie rilevate</div>`;

        resultEl.innerHTML = summary + html;
        resultEl.style.display = 'block';

        // Mostra bottone fix solo se ci sono anomalie
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
    if (!confirm('Correggi tutte le anomalie?\n\nNessun dato verrà cancellato.\n• Utenti fantasma → crea profilo\n• Booking orfane → scollega user_id\n• Email mismatch → ricollega user_id al profilo corretto')) return;

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

        // Risincronizza le cache dopo il fix
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

// Visibility toggles for participant-card badges in admin Prenotazioni
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

function _setBadgeText(id, val) {
    const x = document.getElementById(id);
    if (x) x.textContent = val ? 'Visibile' : 'Nascosto';
}

function saveShowCertBadge(val)  { BookingBadgesStorage.setShowCert(val);  _setBadgeText('showCertBadgeText',  val); _refreshAdminCalendarIfVisible(); }
function saveShowAssicBadge(val) { BookingBadgesStorage.setShowAssic(val); _setBadgeText('showAssicBadgeText', val); _refreshAdminCalendarIfVisible(); }
function saveShowDocBadge(val)   { BookingBadgesStorage.setShowDoc(val);   _setBadgeText('showDocBadgeText',   val); _refreshAdminCalendarIfVisible(); }
function saveShowAnagBadge(val)  { BookingBadgesStorage.setShowAnag(val);  _setBadgeText('showAnagBadgeText',  val); _refreshAdminCalendarIfVisible(); }

function _refreshAdminCalendarIfVisible() {
    if (typeof renderAdminDayView === 'function' && window._currentAdminDate) {
        try { renderAdminDayView(window._currentAdminDate); } catch {}
    }
}

