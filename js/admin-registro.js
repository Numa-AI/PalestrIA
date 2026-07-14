/**
 * admin-registro.js — Tab "Registro" del pannello admin: log/cronologia eventi del tenant.
 *
 * COSA FA
 * Aggrega in un unico registro consultabile tutti gli eventi della org (prenotazioni create,
 * pagamenti, richieste di annullamento, annullamenti) con filtri per tipo/data/ordinamento,
 * paginazione, ricerca, vista desktop+mobile ed export. Include sotto-tab per i messaggi e le
 * notifiche cliente.
 *
 * COME FUNZIONA
 * - Aggregazione: buildRegistroEntries() trasforma ogni booking in più eventi
 *   (booking_created/booking_paid/booking_cancellation_req/booking_cancelled), determinando
 *   l'attore (user/admin/system) via _isAdminAction() confrontando createdBy/cancelledBy con
 *   userId; SLOT_LABEL mappa i tipi slot. Esclude i booking sintetici (_avail_*).
 * - Stato/filtri: _registroState (range, customFrom/To, sortField, sortDir, page) +
 *   REGISTRO_PAGE_SIZE; applyRegistroFilters() (debounced via _debouncedRegistroFilter)
 *   produce _registroFiltered; toggleRegistroType()/setRegistroRange()/toggleRegistroSort()/
 *   applyRegistroCustomRange()/resetRegistroFilters() pilotano i filtri; registroNextPage()/
 *   registroPrevPage() la paginazione.
 * - Render: renderRegistroTable() (desktop) e renderRegistroMobile() (card); _updateRegistroSummary()
 *   per i totali; exportRegistro() per l'esport. renderRegistroTab() è l'entry point.
 * - Sotto-tab: switchRegistroSubtab() commuta tra Registro, Messaggi (loadMessaggi/
 *   renderMessaggiTable, da admin_messages) e Notifiche cliente (loadClientNotifications/
 *   renderClientNotifTable, da client_notifications); _registroRefreshData() ricarica i dati.
 *
 * CONNESSIONI
 * - Eventi prenotazione da BookingStorage.getAllBookings() (js/data.js); prezzo via
 *   getBookingPrice(). Messaggi/notifiche da tabelle admin_messages e client_notifications
 *   via supabaseClient (org-scoped da RLS).
 * - Helper condivisi: _debounce, _localDateStr (definiti altrove).
 */
// REGISTRO / LOG DB
// ══════════════════════════════════════════════════════════════════════════════

var _debouncedRegistroFilter = _debounce(() => applyRegistroFilters(), 250);

let _registroState = {
    range:      'all',
    customFrom: null,
    customTo:   null,
    sortField:  'timestamp',
    sortDir:    'desc',
    page:       0,
};
const REGISTRO_PAGE_SIZE = 50;
let _registroFiltered = [];
let _registroAuditRows = [];
let _registroRealtimeChannel = null;
let _registroRealtimeOrg = null;

const _REGISTRO_BILLING_CONFIG = {
    lesson_booked:                { icon:'📅', cls:'rtype-booking', label:'Lezione a entrata', group:'lesson_billing' },
    lesson_charge_applied:        { icon:'➖', cls:'rtype-pending', label:'Addebito lezione', group:'lesson_billing' },
    lesson_charge_reversed:       { icon:'↩️', cls:'rtype-paid', label:'Storno lezione', group:'lesson_billing' },
    lesson_payment_recorded:      { icon:'💶', cls:'rtype-paid', label:'Incasso lezione', group:'lesson_billing', payment:true },
    lesson_waived:                { icon:'🎁', cls:'rtype-paid', label:'Lezione abbuonata', group:'lesson_billing' },
    lesson_waiver_reversed:       { icon:'↩️', cls:'rtype-pending', label:'Revoca abbuono', group:'lesson_billing' },
    client_credit_added:          { icon:'⬆️', cls:'rtype-paid', label:'Credito aggiunto', group:'lesson_billing' },
    client_debt_added:            { icon:'⬇️', cls:'rtype-pending', label:'Debito aggiunto', group:'lesson_billing' },
    client_payment_recorded:      { icon:'💶', cls:'rtype-paid', label:'Saldo incassato', group:'lesson_billing', payment:true },
    client_balance_reset:         { icon:'🧹', cls:'rtype-cancelled', label:'Saldo annullato', group:'lesson_billing' },
    package_sold:                 { icon:'🎟️', cls:'rtype-paid', label:'Pacchetto venduto', group:'package_billing', payment:true },
    package_payment_recorded:     { icon:'🎟️', cls:'rtype-paid', label:'Pacchetto incassato', group:'package_billing', payment:true },
    package_lesson_reserved:      { icon:'🔒', cls:'rtype-booking', label:'Ingresso riservato', group:'package_billing' },
    package_lesson_consumed:      { icon:'🎫', cls:'rtype-paid', label:'Ingresso scalato', group:'package_billing' },
    package_reservation_released: { icon:'🔓', cls:'rtype-cancelled', label:'Riserva liberata', group:'package_billing' },
    package_lesson_restored:      { icon:'↩️', cls:'rtype-paid', label:'Ingresso restituito', group:'package_billing' },
    package_cancelled:            { icon:'❌', cls:'rtype-cancelled', label:'Pacchetto annullato', group:'package_billing' },
    membership_sold:              { icon:'🪪', cls:'rtype-paid', label:'Abbonamento incassato', group:'membership_billing', payment:true },
    membership_payment_recorded:  { icon:'🪪', cls:'rtype-paid', label:'Abbonamento incassato', group:'membership_billing', payment:true },
    membership_lesson_used:       { icon:'✅', cls:'rtype-booking', label:'Lezione in abbonamento', group:'membership_billing' },
    membership_lesson_restored:   { icon:'↩️', cls:'rtype-paid', label:'Quota abbonamento restituita', group:'membership_billing' },
    membership_cancelled:         { icon:'❌', cls:'rtype-cancelled', label:'Abbonamento annullato', group:'membership_billing' },
    free_lesson_booked:           { icon:'🎁', cls:'rtype-booking', label:'Lezione gratuita', group:'lesson_billing' },
};

function _registroNormalizeAuditRow(row) {
    if (row?.action !== 'stripe_client_payment') return row;
    const kind = row.metadata?.kind;
    const action = kind === 'package_purchase' ? 'package_payment_recorded'
                 : kind === 'membership' ? 'membership_payment_recorded'
                 : 'lesson_payment_recorded';
    return { ...row, action, metadata: { ...(row.metadata || {}), method:'stripe' } };
}

// ── Aggrega tutti gli eventi da tutte le sorgenti dati ─────────────────────
function buildRegistroEntries() {
    const SLOT_LABEL = {
        'personal-training': 'Autonomia',
        'small-group':       'Lezione di Gruppo',
        'group-class':       'Slot prenotato',
        'cleaning':          'Pulizie',
    };

    const entries = [];
    const auditBookingCreated = new Set();
    const auditBookingPaid = new Set();

    for (const row of _registroAuditRows) {
        const cfg = _REGISTRO_BILLING_CONFIG[row.action];
        if (!cfg) continue;
        const m = row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
        const bookingId = m.booking_id || (row.target_type === 'booking' ? row.target_id : null);
        if (bookingId && ['lesson_booked','package_lesson_reserved','membership_lesson_used','free_lesson_booked'].includes(row.action)) {
            auditBookingCreated.add(String(bookingId));
            if (row.action !== 'lesson_booked') auditBookingPaid.add(String(bookingId));
        }
        if (bookingId && ['lesson_payment_recorded','client_payment_recorded'].includes(row.action)) {
            auditBookingPaid.add(String(bookingId));
        }
    }

    // Helper: determina se un'azione è stata fatta da admin
    // (created_by/cancelled_by diverso da user_id = qualcun altro ha agito per conto dell'utente)
    const _isAdminAction = (actorId, userId) => {
        if (!actorId) return false;            // sconosciuto (dati vecchi) → non marcare
        if (!userId) return !!actorId;         // booking anonimo ma con attore → admin
        return actorId !== userId;             // attore diverso dal proprietario → admin
    };

    // 1. Prenotazioni → eventi: created, paid, cancellation_requested, cancelled
    // Escludi booking sintetici (_avail_*) — placeholder senza dati personali per slot occupati da altri
    const bookings = BookingStorage.getAllBookings().filter(b => !b.id?.startsWith('_avail_'));
    for (const b of bookings) {
        const base = {
            bookingId:   b.id,
            clientName:  b.name  || '—',
            clientPhone: b.whatsapp || '',
            clientEmail: b.email   || '',
            lessonDate:  b.date    || null,
            lessonTime:  b.time    || null,
            slotType:    b.slotType || null,
            slotLabel:   SLOT_LABEL[b.slotType] || b.slotType || '',
            notes:       b.notes  || '',
        };

        // Evento: prenotazione creata
        const createdAt = b.createdAt
            ? new Date(b.createdAt)
            : new Date((b.date || '2000-01-01') + 'T08:00:00');
        const createdByAdmin   = _isAdminAction(b.createdBy, b.userId);
        const cancelledByAdmin = _isAdminAction(b.cancelledBy, b.userId);

        if (!auditBookingCreated.has(String(b.sbId || b.id))) {
            entries.push({
                ...base,
                eventType:     'booking_created',
                timestamp:     createdAt,
                amount:        getBookingPrice(b),
                paymentMethod: b.paymentMethod || (b.status === 'cancelled' ? b.cancelledPaymentMethod : null) || null,
                bookingStatus: b.status,
                bookingPaid:   b.paid || (b.status === 'cancelled' && !!b.cancelledPaidAt),
                actorType:     createdByAdmin ? 'admin' : 'user',
            });
        }

        // Evento: pagamento ricevuto
        // Per prenotazioni annullate-dopo-pagamento usiamo cancelledPaidAt/cancelledPaymentMethod
        const paidAtTs  = b.paidAt || (b.status === 'cancelled' ? b.cancelledPaidAt  : null);
        const paidMeth  = b.paymentMethod || (b.status === 'cancelled' ? b.cancelledPaymentMethod : null);
        if (paidAtTs && !auditBookingPaid.has(String(b.sbId || b.id))) {
            entries.push({
                ...base,
                eventType:     'booking_paid',
                timestamp:     new Date(paidAtTs),
                amount:        getBookingPrice(b),
                paymentMethod: paidMeth,
                bookingStatus: b.status,
                bookingPaid:   true,
                actorType:     createdByAdmin ? 'admin' : 'user',
            });
        }

        // Evento: richiesta annullamento
        if (b.cancellationRequestedAt) {
            entries.push({
                ...base,
                eventType:     'booking_cancellation_req',
                timestamp:     new Date(b.cancellationRequestedAt),
                amount:        null,
                paymentMethod: null,
                bookingStatus: 'cancellation_requested',
                bookingPaid:   b.paid,
                actorType:     cancelledByAdmin ? 'admin' : 'user',
            });
        }

        // Evento: annullamento effettivo
        if (b.status === 'cancelled' && b.cancelledAt) {
            // Se cancelledBy è null ma il booking aveva cancellationRequestedAt,
            // è stato completato dal sistema (fulfill_pending_cancellation)
            const cancelIsSystem = !b.cancelledBy && !!b.cancellationRequestedAt;

            entries.push({
                ...base,
                eventType:     'booking_cancelled',
                timestamp:     new Date(b.cancelledAt),
                amount:        null,
                paymentMethod: null,
                bookingStatus: 'cancelled',
                bookingPaid:   false,
                actorType:     cancelIsSystem ? 'system' : (cancelledByAdmin ? 'admin' : 'user'),
            });
        }
    }

    // 2. Ledger/audit server: vendite, riserve, scalature all'inizio lezione,
    // addebiti, crediti/debiti e storni. Sono gli eventi autoritativi e persistono
    // anche quando lo stato corrente di booking/pacchetto/abbonamento cambia.
    const users = typeof UserStorage !== 'undefined' && UserStorage.getAll ? UserStorage.getAll() : [];
    for (const row of _registroAuditRows) {
        const cfg = _REGISTRO_BILLING_CONFIG[row.action];
        if (!cfg) continue;
        const m = row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
        const user = m.client_user_id ? users.find(u => String(u.userId) === String(m.client_user_id)) : null;
        const bookingId = m.booking_id || (row.target_type === 'booking' ? row.target_id : null);
        const amount = m.amount == null ? null : Number(m.amount);
        entries.push({
            bookingId,
            eventType: row.action,
            eventGroup: cfg.group,
            timestamp: new Date(row.created_at),
            clientName: m.client_name || user?.name || m.client_email || 'Cliente',
            clientPhone: m.client_phone || user?.whatsapp || '',
            clientEmail: m.client_email || user?.email || '',
            lessonDate: m.lesson_date || null,
            lessonTime: m.lesson_time || null,
            slotType: m.slot_type || null,
            slotLabel: SLOT_LABEL[m.slot_type] || m.slot_type || '',
            notes: m.note || '',
            amount: Number.isFinite(amount) ? amount : null,
            paymentMethod: m.payment_method || m.method || null,
            bookingStatus: m.status || null,
            bookingPaid: cfg.payment ? true : null,
            actorType: row.actor_user_id ? 'admin' : 'system',
            isPayment: cfg.payment === true,
        });
    }

    return entries;
}

// ── Calcola il range di date per il filtro periodo ─────────────────────────
function _registroGetDateRange() {
    const now = new Date();
    const s   = _registroState;
    switch (s.range) {
        case 'all': return null;
        case 'this-month':
            return {
                from: new Date(now.getFullYear(), now.getMonth(), 1),
                to:   new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999),
            };
        case 'last-month': {
            const m = now.getMonth() === 0 ? 11 : now.getMonth() - 1;
            const y = now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
            return { from: new Date(y, m, 1), to: new Date(y, m + 1, 0, 23, 59, 59, 999) };
        }
        case 'this-year':
            return {
                from: new Date(now.getFullYear(), 0, 1),
                to:   new Date(now.getFullYear(), 11, 31, 23, 59, 59, 999),
            };
        case 'custom':
            return {
                from: s.customFrom ? new Date(s.customFrom + 'T00:00:00') : null,
                to:   s.customTo   ? new Date(s.customTo   + 'T23:59:59') : null,
            };
        default: return null;
    }
}

// ── Toggle singolo pill tipo evento ───────────────────────────────────────
function toggleRegistroType(btn) {
    btn.classList.toggle('active');
    applyRegistroFilters();
}

// ── Applica tutti i filtri e rirenderizza ──────────────────────────────────
function applyRegistroFilters() {
    const all          = buildRegistroEntries();
    const range        = _registroGetDateRange();
    const activeTypes  = Array.from(document.querySelectorAll('.rfilter-type-pills .rfilter-btn.active')).map(b => b.dataset.etype);
    const filterSlot   = document.getElementById('registroFilterSlot')?.value   || 'all';
    const filterMethod = document.getElementById('registroFilterMethod')?.value || 'all';
    const filterStatus = document.getElementById('registroFilterStatus')?.value || 'all';
    const search       = (document.getElementById('registroSearch')?.value || '').toLowerCase().trim();

    let filtered = all.filter(e => {
        // Periodo (su timestamp dell'evento)
        if (range) {
            if (range.from && e.timestamp < range.from) return false;
            if (range.to   && e.timestamp > range.to)   return false;
        }
        // Tipo evento (multi-selezione: nessun bottone attivo = tutti)
        if (activeTypes.length > 0 && !activeTypes.includes(e.eventType) && !activeTypes.includes(e.eventGroup)) return false;
        // Tipo lezione
        if (filterSlot !== 'all' && e.slotType !== filterSlot) return false;
        // Metodo pagamento
        if (filterMethod !== 'all' && e.paymentMethod !== filterMethod) return false;
        // Stato
        if (filterStatus !== 'all') {
            if (filterStatus === 'paid' && e.bookingPaid !== true) return false;
            if (filterStatus === 'unpaid') {
                if (e.eventType !== 'booking_created') return false;
                if (e.bookingPaid !== false) return false;
                if (e.bookingStatus === 'cancelled') return false;
            }
            if (filterStatus === 'cancelled' && e.bookingStatus !== 'cancelled') return false;
        }
        // Ricerca cliente
        if (search) {
            const hay = `${e.clientName} ${e.clientPhone} ${e.clientEmail}`.toLowerCase();
            if (!hay.includes(search)) return false;
        }
        return true;
    });

    // Ordinamento
    const dir   = _registroState.sortDir === 'asc' ? 1 : -1;
    const field = _registroState.sortField;
    filtered.sort((a, b) => {
        if (field === 'timestamp')  return dir * (a.timestamp - b.timestamp);
        if (field === 'lessonDate') return dir * (a.lessonDate || '').localeCompare(b.lessonDate || '');
        return 0;
    });

    _registroFiltered        = filtered;
    _registroState.page      = 0;
    _updateRegistroSummary(filtered);
    renderRegistroTable();
}

// ── Aggiorna le card summary ───────────────────────────────────────────────
// ⚠️ L11: `totalPaid` è il VALORE TEORICO delle prenotazioni (somma di getBookingPrice
// sui booking_paid, cioè i prezzi correnti da `bookings`), NON l'incassato del ledger
// `payments` usato in admin-analytics. I due totali possono divergere (prezzi cambiati,
// pacchetti/abbonamenti, rettifiche). Rietichettiamo qui (tooltip) per non farlo passare
// per "incassato" riconciliabile: il fatturato reale resta quello del ledger.
function _updateRegistroSummary(filtered) {
    const totalEvents   = filtered.length;
    const totalPaid     = filtered
        .filter(e => e.eventType === 'booking_paid' || e.isPayment === true)
        .reduce((s, e) => s + (e.amount || 0), 0);
    const totalBookings = filtered.filter(e => e.eventType === 'booking_created').length;

    const el = id => document.getElementById(id);
    if (el('registroTotalEvents'))   el('registroTotalEvents').textContent   = totalEvents;
    if (el('registroTotalPaid')) {
        el('registroTotalPaid').textContent = `€${totalPaid.toFixed(2)}`;
        // Tooltip chiarificatore: distingue il valore teorico dall'incassato del ledger.
        el('registroTotalPaid').title =
            'Valore teorico delle prenotazioni (prezzi correnti). Per l\'incassato reale vedi Statistiche → Fatturato (ledger pagamenti).';
    }
    if (el('registroTotalBookings')) el('registroTotalBookings').textContent = totalBookings;
}

// ── Renderizza la tabella (pagina corrente) ────────────────────────────────
function renderRegistroTable() {
    const tbody = document.getElementById('registroTableBody');
    if (!tbody) return;

    const total = _registroFiltered.length;
    const page  = _registroState.page;
    const start = page * REGISTRO_PAGE_SIZE;
    const end   = Math.min(start + REGISTRO_PAGE_SIZE, total);
    const slice = _registroFiltered.slice(start, end);

    // Paginazione
    const info = document.getElementById('registroPaginationInfo');
    if (info) info.textContent = total === 0 ? 'Nessun risultato' : `${start + 1}–${end} di ${total}`;
    const prev = document.getElementById('registroPrevBtn');
    const next = document.getElementById('registroNextBtn');
    if (prev) prev.disabled = page === 0;
    if (next) next.disabled = end >= total;

    if (slice.length === 0) {
        tbody.innerHTML = `<tr><td colspan="10" class="registro-empty">Nessun evento trovato con i filtri selezionati.</td></tr>`;
        const mobile = document.getElementById('registroMobileList');
        if (mobile) mobile.innerHTML = `<div class="registro-mobile-empty">Nessun evento trovato con i filtri selezionati.</div>`;
        return;
    }

    const EVENT_CONFIG = {
        booking_created:          { icon: '📅', cls: 'rtype-booking',    label: 'Prenotazione' },
        booking_paid:             { icon: '✅', cls: 'rtype-paid',       label: 'Pagamento' },
        booking_cancelled:        { icon: '❌', cls: 'rtype-cancelled',  label: 'Annullamento' },
        booking_cancellation_req: { icon: '⏳', cls: 'rtype-pending',    label: 'Rich. Annullamento' },
        ..._REGISTRO_BILLING_CONFIG,
    };
    const METHOD_ICON  = { contanti: '💵', 'contanti-report': '🧾', carta: '💳', iban: '🏦' };
    const METHOD_LABEL = { contanti: 'Contanti', 'contanti-report': 'Contanti con Report', carta: 'Carta', iban: 'Bonifico' };

    const statusHTML = (e) => {
        if (e.bookingStatus === 'cancelled')              return `<span class="rstatus-badge rstatus-cancelled">Annullato</span>`;
        if (e.bookingStatus === 'cancellation_requested') return `<span class="rstatus-badge rstatus-pending">In attesa</span>`;
        if (e.bookingPaid === true)                       return `<span class="rstatus-badge rstatus-paid">Pagato</span>`;
        if (e.bookingPaid === false)                      return `<span class="rstatus-badge rstatus-unpaid">Non pagato</span>`;
        return '—';
    };

    const fmtTs = d => d
        ? d.toLocaleString('it-IT', { day:'2-digit', month:'2-digit', year:'2-digit', hour:'2-digit', minute:'2-digit' })
        : '—';
    const fmtDate = str => {
        if (!str) return '—';
        const [y, m, d] = str.split('-');
        return `${d}/${m}/${y}`;
    };

    tbody.innerHTML = slice.map(e => {
        const cfg    = EVENT_CONFIG[e.eventType] || { icon: '•', cls: '', label: e.eventType };
        const mi     = e.paymentMethod ? METHOD_ICON[e.paymentMethod]  || '' : '';
        const ml     = e.paymentMethod ? METHOD_LABEL[e.paymentMethod] || e.paymentMethod : '—';
        const amount = e.amount != null ? `€${Number(e.amount).toFixed(2)}` : '—';
        const rowCls = e.actorType === 'admin' ? 'registro-row registro-admin'
                     : e.actorType === 'system' ? 'registro-row registro-system'
                     : 'registro-row';
        return `<tr class="${rowCls}">
            <td class="registro-ts">${fmtTs(e.timestamp)}</td>
            <td><span class="rtype-badge ${cfg.cls}">${cfg.icon} ${cfg.label}</span></td>
            <td class="registro-client">
                <span class="registro-client-name">${_escHtml(e.clientName)}</span>
            </td>
            <td>${fmtDate(e.lessonDate)}</td>
            <td class="registro-time">${_escHtml(e.lessonTime || '—')}</td>
            <td>${_escHtml(e.slotLabel || '—')}</td>
            <td class="registro-amount">${amount}</td>
            <td class="registro-method">${mi} ${_escHtml(ml)}</td>
            <td>${statusHTML(e)}</td>
            <td class="registro-note" title="${_escHtml(e.notes || '')}">${_escHtml(e.notes || '—')}</td>
        </tr>`;
    }).join('');

    renderRegistroMobile(slice, EVENT_CONFIG, METHOD_ICON, METHOD_LABEL, statusHTML, fmtDate);
}

// ── Helper condivisi mobile (date + escape + azione "Vedi cliente") ───────
function _regDayKey(d) {
    if (!(d instanceof Date)) d = new Date(d);
    return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}
function _regShortDate(d) {
    if (!(d instanceof Date)) d = new Date(d);
    const M = ['gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic'];
    return `${d.getDate()} ${M[d.getMonth()]}`;
}
function _regFullDate(d) {
    if (!(d instanceof Date)) d = new Date(d);
    const D = ['Dom','Lun','Mar','Mer','Gio','Ven','Sab'];
    return `${D[d.getDay()]} · ${_regShortDate(d)} ${d.getFullYear()}`;
}
function _regBtnArg(s) {
    // Sicuro per onclick="fn('${...}')": neutralizza sia il contesto attributo HTML
    // (" < > &) sia la stringa JS (\ '). Vedi _escAttr in ui.js.
    return _escAttr(s);
}

function regMobOpenClient(name) {
    if (typeof switchTab === 'function') switchTab('clients');
    // Delay: lascia che switchTab→renderClientsTab finisca, così non ci sovrascrive.
    setTimeout(() => {
        // Apri DIRETTAMENTE la card del cliente (già espansa).
        if (typeof openClientCardByName === 'function' && openClientCardByName(name)) return;
        // Fallback (cliente non trovato per nome): riempi la barra di ricerca.
        const inputs = document.querySelectorAll('#tab-clients input[type="text"], #tab-clients input[type="search"]');
        for (const inp of inputs) {
            const ph = (inp.placeholder || '').toLowerCase();
            if (ph.includes('cerca') || ph.includes('cliente') || ph.includes('nome')) {
                inp.value = name;
                inp.dispatchEvent(new Event('input', { bubbles: true }));
                inp.scrollIntoView({ behavior: 'smooth', block: 'center' });
                break;
            }
        }
    }, 60);
}

function _regSVG() {
    return {
        book:     `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="3" y1="10" x2="21" y2="10"/></svg>`,
        check:    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>`,
        x:        `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`,
        ban:      `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><line x1="5.6" y1="5.6" x2="18.4" y2="18.4"/></svg>`,
        clock:    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15 14"/></svg>`,
        list:     `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>`,
        bell:     `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>`,
        megaphone:`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 13 7 13 17 3 13"/><path d="M13 7v10l4 4V3z"/></svg>`,
        wallet:   `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="6" width="20" height="14" rx="2"/><path d="M16 13h2"/><path d="M22 10V8a2 2 0 0 0-2-2H4"/></svg>`,
        userPlus: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="8.5" cy="7" r="4"/><line x1="20" y1="8" x2="20" y2="14"/><line x1="23" y1="11" x2="17" y2="11"/></svg>`,
        signal:   `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.55a11 11 0 0 1 14.08 0"/><path d="M1.42 9a16 16 0 0 1 21.16 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><line x1="12" y1="20" x2="12.01" y2="20"/></svg>`,
    };
}

// ── Render mobile list (Variante A) per il subtab Registro ─────────────────
function renderRegistroMobile(slice, EVENT_CONFIG, METHOD_ICON, METHOD_LABEL, statusHTML, fmtDate) {
    const list = document.getElementById('registroMobileList');
    if (!list) return;

    if (!slice.length) {
        list.innerHTML = `<div class="registro-mobile-empty">Nessun evento trovato con i filtri selezionati.</div>`;
        return;
    }

    const SVG = _regSVG();
    const TAG = {
        booking_created:          { cls:'book',    svg: SVG.book },
        booking_paid:             { cls:'pay',     svg: SVG.check },
        booking_cancelled:        { cls:'cancel',  svg: SVG.ban },
        booking_cancellation_req: { cls:'warn',    svg: SVG.clock },
    };

    const POSITIVE = new Set(['booking_paid']);
    const NEGATIVE = new Set([]);

    const todayKey = _regDayKey(new Date());
    const yKey     = (() => { const d = new Date(); d.setDate(d.getDate() - 1); return _regDayKey(d); })();
    const dayLabel = (key, d) => {
        if (key === todayKey) return `Oggi · ${_regShortDate(d)}`;
        if (key === yKey)     return `Ieri · ${_regShortDate(d)}`;
        return _regFullDate(d);
    };

    const groups = [];
    let cur = null;
    for (const e of slice) {
        const ts = e.timestamp || new Date(0);
        const k  = _regDayKey(ts);
        if (!cur || cur.key !== k) { cur = { key: k, date: ts, items: [] }; groups.push(cur); }
        cur.items.push(e);
    }

    list.innerHTML = groups.map(g => {
        const rows = g.items.map(e => {
            const t   = TAG[e.eventType] || { cls:'neutral', svg: SVG.list };
            const cfg = EVENT_CONFIG[e.eventType] || { icon: '•', label: e.eventType };
            const ts  = e.timestamp || null;
            const hh  = ts ? String(ts.getHours()).padStart(2,'0') + ':' + String(ts.getMinutes()).padStart(2,'0') : '—';
            const tsKey  = ts ? _regDayKey(ts) : '';
            const subDay = tsKey === todayKey ? 'oggi' : (tsKey === yKey ? 'ieri' : (ts ? _regShortDate(ts) : '—'));

            let amtHTML;
            if (e.eventType === 'booking_created' || e.eventType === 'booking_cancellation_req') {
                const tStart = e.lessonTime ? String(e.lessonTime).split(' - ')[0].trim() : '';
                let dStr = '';
                if (e.lessonDate) {
                    const [, mm, dd] = e.lessonDate.split('-');
                    if (dd && mm) dStr = `${dd}/${mm}`;
                }
                if (dStr && tStart) {
                    amtHTML = `<span class="reg-mob-amt reg-mob-amt-stack"><b>${tStart}</b><i>${dStr}</i></span>`;
                } else if (tStart) {
                    amtHTML = `<span class="reg-mob-amt">${_escHtml(tStart)}</span>`;
                } else if (dStr) {
                    amtHTML = `<span class="reg-mob-amt">${dStr}</span>`;
                } else {
                    amtHTML = `<span class="reg-mob-amt">—</span>`;
                }
            } else if (e.amount != null) {
                const n = Number(e.amount);
                const sign = POSITIVE.has(e.eventType) ? 'plus' : (NEGATIVE.has(e.eventType) ? 'minus' : '');
                const prefix = sign === 'plus' ? '+' : (sign === 'minus' ? '−' : '');
                amtHTML = `<span class="reg-mob-amt ${sign}">${prefix}€${n.toFixed(2)}</span>`;
            } else {
                amtHTML = `<span class="reg-mob-amt">—</span>`;
            }

            const lessonRange = e.lessonTime ? _escHtml(e.lessonTime) : '—';
            const lessonDate  = e.lessonDate ? fmtDate(e.lessonDate) : '—';
            const slotLine    = (e.lessonDate || e.lessonTime)
                ? `${lessonDate}${e.lessonTime ? ' · ' + lessonRange : ''}`
                : '—';
            const methodIcon  = e.paymentMethod ? (METHOD_ICON[e.paymentMethod]  || '') : '';
            const methodLabel = e.paymentMethod ? (METHOD_LABEL[e.paymentMethod] || e.paymentMethod) : '';
            const slotBadge   = e.slotLabel
                ? `<span class="reg-mob-badge auto">${_escHtml(e.slotLabel)}</span>`
                : '—';
            const amtFull = e.amount != null ? `€ ${Number(e.amount).toFixed(2)}` : '—';
            const actorBadge = e.actorType === 'admin'  ? `<span class="reg-mob-badge admin">Admin</span>`
                             : e.actorType === 'system' ? `<span class="reg-mob-badge system">Sistema</span>`
                             : '';
            const noteRow = e.notes
                ? `<dt>Nota</dt><dd>${_escHtml(e.notes)}</dd>`
                : '';
            const methodRow = e.paymentMethod
                ? `<dt>Metodo</dt><dd>${methodIcon} ${_escHtml(methodLabel)}</dd>`
                : '';

            const clientArg = _regBtnArg(e.clientName);

            const rowExtraCls    = e.actorType === 'admin'  ? ' reg-mob-row--admin'
                                 : e.actorType === 'system' ? ' reg-mob-row--system'
                                 : '';
            const detailExtraCls = e.actorType === 'admin'  ? ' reg-mob-detail--admin'
                                 : e.actorType === 'system' ? ' reg-mob-detail--system'
                                 : '';

            return `
                <div class="reg-mob-row${rowExtraCls}" data-reg-row>
                    <div class="reg-mob-time"><b>${hh}</b>${_escHtml(subDay)}</div>
                    <div class="reg-mob-tag ${t.cls}">${t.svg}</div>
                    <div class="reg-mob-name">${_escHtml(e.clientName || '—')}</div>
                    ${amtHTML}
                    <span class="reg-mob-chev"></span>
                </div>
                <div class="reg-mob-detail${detailExtraCls}">
                    <dl class="reg-mob-grid">
                        <dt>Tipo</dt><dd>${cfg.icon} ${_escHtml(cfg.label)}${actorBadge ? ' ' + actorBadge : ''}</dd>
                        <dt>${e.eventType === 'booking_created' ? 'Slot' : 'Prenotaz.'}</dt><dd>${slotLine}</dd>
                        <dt>Modalità</dt><dd>${slotBadge}</dd>
                        <dt>Importo</dt><dd>${amtFull}</dd>
                        ${methodRow}
                        <dt>Stato</dt><dd>${statusHTML(e)}</dd>
                        ${noteRow}
                    </dl>
                    <div class="reg-mob-actions">
                        <button class="reg-mob-btn primary" onclick="event.stopPropagation();regMobOpenClient('${clientArg}')">Vedi cliente</button>
                    </div>
                </div>`;
        }).join('');

        return `
            <div class="reg-mob-sep">${dayLabel(g.key, g.date)}</div>
            <div class="reg-mob-group">${rows}</div>`;
    }).join('');

    list.querySelectorAll('[data-reg-row]').forEach(r => {
        r.addEventListener('click', () => {
            const wasOpen = r.classList.contains('open');
            list.querySelectorAll('.reg-mob-row.open').forEach(x => x.classList.remove('open'));
            if (!wasOpen) r.classList.add('open');
        });
    });
}

// _escHtml è definita in ui.js (caricato prima di admin.js su tutte le pagine)

// ── Ordinamento colonne ────────────────────────────────────────────────────
function toggleRegistroSort(field) {
    if (_registroState.sortField === field) {
        _registroState.sortDir = _registroState.sortDir === 'asc' ? 'desc' : 'asc';
    } else {
        _registroState.sortField = field;
        _registroState.sortDir   = 'desc';
    }
    const tsIcon = document.getElementById('registroSortTs');
    const lsIcon = document.getElementById('registroSortLesson');
    if (tsIcon) tsIcon.textContent = field === 'timestamp'  ? (_registroState.sortDir === 'desc' ? '↓' : '↑') : '';
    if (lsIcon) lsIcon.textContent = field === 'lessonDate' ? (_registroState.sortDir === 'desc' ? '↓' : '↑') : '';
    applyRegistroFilters();
}

// ── Filtro periodo ─────────────────────────────────────────────────────────
function setRegistroRange(range, btn) {
    _registroState.range = range;
    document.querySelectorAll('.rfilter-btn[data-range]').forEach(b => b.classList.remove('active'));
    if (btn) btn.classList.add('active');
    const customDiv = document.getElementById('registroCustomDates');
    if (range === 'custom') {
        if (customDiv) customDiv.style.display = 'flex';
        return; // attende Applica
    }
    if (customDiv) customDiv.style.display = 'none';
    applyRegistroFilters();
}

function applyRegistroCustomRange() {
    const from = document.getElementById('registroDateFrom')?.value;
    const to   = document.getElementById('registroDateTo')?.value;
    if (!from || !to) { showAlert('Seleziona entrambe le date.', { type:'warn' }); return; }
    if (from > to)    { showAlert('La data di inizio deve essere precedente alla data di fine.', { type:'warn' }); return; }
    _registroState.customFrom = from;
    _registroState.customTo   = to;
    applyRegistroFilters();
}

// ── Reset filtri ───────────────────────────────────────────────────────────
function resetRegistroFilters() {
    _registroState.range      = 'all';
    _registroState.customFrom = null;
    _registroState.customTo   = null;
    _registroState.sortField  = 'timestamp';
    _registroState.sortDir    = 'desc';
    _registroState.page       = 0;

    document.querySelectorAll('.rfilter-btn[data-range]').forEach(b => {
        b.classList.toggle('active', b.dataset.range === 'all');
    });
    const customDiv = document.getElementById('registroCustomDates');
    if (customDiv) customDiv.style.display = 'none';

    document.querySelectorAll('.rfilter-type-pills .rfilter-btn').forEach(b => b.classList.remove('active'));
    ['registroFilterSlot', 'registroFilterMethod', 'registroFilterStatus'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.value = 'all';
    });
    const searchEl = document.getElementById('registroSearch');
    if (searchEl) searchEl.value = '';

    const tsIcon = document.getElementById('registroSortTs');
    const lsIcon = document.getElementById('registroSortLesson');
    if (tsIcon) tsIcon.textContent = '↓';
    if (lsIcon) lsIcon.textContent = '';

    applyRegistroFilters();
}

// ── Paginazione ────────────────────────────────────────────────────────────
function registroNextPage() {
    const maxPage = Math.ceil(_registroFiltered.length / REGISTRO_PAGE_SIZE) - 1;
    if (_registroState.page < maxPage) { _registroState.page++; renderRegistroTable(); }
}
function registroPrevPage() {
    if (_registroState.page > 0) { _registroState.page--; renderRegistroTable(); }
}

// ── Toggle pannello filtri (generico, usato da tutti i subtab) ──────────
function toggleRegFilters(btn) {
    const container = btn.parentElement;
    const body = container.querySelector('.reg-filters-collapsible');
    const icon = btn.querySelector('.reg-filters-toggle-icon');
    if (!body) return;
    body.classList.toggle('open');
    if (icon) icon.classList.toggle('open');
}

// ── Sub-tab switching dentro Registro ────────────────────────────────────
function switchRegistroSubtab(name, btn) {
    document.querySelectorAll('.registro-subtab').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.registro-subtab-content').forEach(c => c.classList.remove('active'));
    btn.classList.add('active');
    const panel = document.getElementById('registroSubtab-' + name);
    if (panel) panel.classList.add('active');

    // Lazy-load dati alla prima apertura
    if (name === 'notifiche-admin' && typeof loadMessaggi === 'function') loadMessaggi();
    if (name === 'notifiche-clienti' && typeof loadClientNotifications === 'function') loadClientNotifications();
}

// ── Refresh mirato dei dati del Registro ──────────────────────────────────
// Sync di Booking (unica sorgente letta da buildRegistroEntries). Guard
// doppia: non rifetcha se c'è già un sync in corso e non più di 1 fetch
// ogni REGISTRO_SYNC_COOLDOWN_MS.
// Questa funzione è invocata SOLO da renderRegistroTab() (entrata nel tab):
// i re-render interni dovuti a filtri/ordinamento passano per
// applyRegistroFilters() direttamente e non toccano la rete.
const REGISTRO_SYNC_COOLDOWN_MS = 10_000;
let _registroSyncInFlight = false;
let _registroLastSyncAt   = 0;

async function _registroRefreshData() {
    if (typeof supabaseClient === 'undefined') return;
    if (_registroSyncInFlight) return;
    if (Date.now() - _registroLastSyncAt < REGISTRO_SYNC_COOLDOWN_MS) return;

    _registroSyncInFlight = true;
    try {
        // Registro = vista di audit dei movimenti: deve avere dati COMPLETI, non la cache
        // delta ottimizzata per l'egress (una riga saltata dal watermark sparirebbe fino a
        // un full/reload). forceFull bypassa watermark/_shouldFullSync (throttlato a 10s).
        const [, auditRes] = await Promise.all([
            BookingStorage.syncFromSupabase({ forceFull: true }),
            _rpcWithTimeout(
                supabaseClient.from('admin_audit_log')
                    .select('id,actor_user_id,action,target_type,target_id,metadata,created_at,event_key')
                    .order('created_at', { ascending:false })
                    .limit(5000),
                20000
            )
        ]);
        if (auditRes?.error) throw auditRes.error;
        _registroAuditRows = (auditRes?.data || []).map(_registroNormalizeAuditRow);
        _registroLastSyncAt = Date.now();
        // Re-render solo se siamo ancora sul tab Registro: evita lavoro inutile
        // se l'utente ha già cambiato tab mentre il fetch era in volo.
        const active = document.querySelector('.admin-tab.active');
        if (active && active.dataset.tab === 'registro') {
            applyRegistroFilters();
        }
    } catch (e) {
        console.warn('[Registro] refresh error:', e);
    } finally {
        _registroSyncInFlight = false;
    }
}

function _ensureRegistroRealtime() {
    const orgId = window._orgId;
    if (!orgId || typeof supabaseClient === 'undefined') return;
    if (_registroRealtimeChannel && _registroRealtimeOrg === orgId) return;
    if (_registroRealtimeChannel) {
        try { supabaseClient.removeChannel(_registroRealtimeChannel); } catch (_) {}
    }
    _registroRealtimeOrg = orgId;
    _registroRealtimeChannel = supabaseClient
        .channel('registro-billing-' + orgId)
        .on('postgres_changes', {
            event: 'INSERT', schema: 'public', table: 'admin_audit_log',
            filter: 'org_id=eq.' + orgId,
        }, payload => {
            const row = _registroNormalizeAuditRow(payload?.new);
            if (!row || !_REGISTRO_BILLING_CONFIG[row.action]) return;
            if (!_registroAuditRows.some(x => x.id === row.id)) _registroAuditRows.unshift(row);
            const active = document.querySelector('.admin-tab.active');
            if (active && active.dataset.tab === 'registro') applyRegistroFilters();
        })
        .subscribe();
}

// ── Entry point chiamato da switchTab ──────────────────────────────────────
function renderRegistroTab() {
    _ensureRegistroRealtime();
    applyRegistroFilters();      // render immediato da cache (no flicker)
    _registroRefreshData();      // fetch in background, guardato
}

// ── Export Excel della vista filtrata ─────────────────────────────────────
function exportRegistro() {
    const data = _registroFiltered;
    if (data.length === 0) {
        showAlert('Nessun dato da esportare con i filtri correnti.', { type:'warn' });
        return;
    }

    const EVENT_LABEL = {
        booking_created:          'Prenotazione',
        booking_paid:             'Pagamento',
        booking_cancelled:        'Annullamento',
        booking_cancellation_req: 'Rich. Annullamento',
    };
    const METHOD_LABEL = {
        contanti: 'Contanti', 'contanti-report': 'Contanti con Report', carta: 'Carta', iban: 'Bonifico',
    };
    const statusLabel = e => {
        if (e.bookingStatus === 'cancelled')              return 'Annullato';
        if (e.bookingStatus === 'cancellation_requested') return 'Rich. Annullamento';
        if (e.bookingPaid === true)                       return 'Pagato';
        if (e.bookingPaid === false)                      return 'Non pagato';
        return '';
    };
    const fmtTs   = d  => d ? d.toLocaleString('it-IT') : '';
    const fmtDate = str => {
        if (!str) return '';
        const [y, m, d] = str.split('-');
        return `${d}/${m}/${y}`;
    };

    const sheetData = [
        ['Data/Ora Evento', 'Tipo Evento', 'Cliente', 'Telefono', 'Email',
         'Data Lezione', 'Ora Lezione', 'Tipo Lezione',
         'Importo (€)', 'Metodo Pagamento', 'Stato', 'Attore', 'Note', 'Booking ID'],
        ...data.map(e => [
            fmtTs(e.timestamp),
            EVENT_LABEL[e.eventType] || e.eventType,
            e.clientName,
            e.clientPhone,
            e.clientEmail,
            fmtDate(e.lessonDate),
            e.lessonTime || '',
            e.slotLabel  || '',
            e.amount != null ? e.amount : '',
            METHOD_LABEL[e.paymentMethod] || e.paymentMethod || '',
            statusLabel(e),
            e.actorType === 'admin' ? 'Admin' : e.actorType === 'system' ? 'Sistema' : 'Utente',
            e.notes     || '',
            e.bookingId || '',
        ]),
    ];

    const wb = XLSX.utils.book_new();
    const ws = XLSX.utils.aoa_to_sheet(sheetData);
    const colWidths = sheetData[0].map((_, ci) =>
        Math.min(50, Math.max(10, ...sheetData.map(r => String(r[ci] ?? '').length)))
    );
    ws['!cols'] = colWidths.map(w => ({ wch: w }));
    XLSX.utils.book_append_sheet(wb, ws, 'Registro');

    const date = _localDateStr();
    // Prefisso file per-org (multi-tenant): slug dello studio, niente brand hardcoded
    const orgPrefix = (window._orgSlug ? String(window._orgSlug).replace(/[^\w-]/g, '') + '_' : '');
    XLSX.writeFile(wb, `${orgPrefix}Registro_${date}.xlsx`);

    const btn = document.getElementById('registroExportBtn');
    if (btn) {
        const orig = btn.innerHTML;
        btn.innerHTML = '✅ Scaricato!';
        setTimeout(() => { btn.innerHTML = orig; }, 2500);
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// STORICO MESSAGGI / NOTIFICHE ADMIN
// ══════════════════════════════════════════════════════════════════════════════

let _messaggiCache = [];
let _messaggiFiltered = [];
let _messaggiPage = 0;
const MESSAGGI_PAGE_SIZE = 50;

const _MSG_TYPE_LABELS = {
    booking:               '✔️ Prenotazione',
    cancellation:          '❌ Annullamento',
    proximity:             '📍 Arrivo',
    proximity_no_booking:  '📍 Senza prenot.',
    new_client:            '🆕 Nuovo iscritto',
    broadcast:             '📢 Broadcast',
    topup:                 '💰 Ricarica',
};

async function loadMessaggi() {
    if (typeof supabaseClient === 'undefined') return;
    try {
        // typeFilter applicato server-side: con volumi alti di booking/cancellation,
        // i 500 più recenti mascheravano i tipi rari (new_client, topup, broadcast)
        const typeFilter = document.getElementById('msgFilterType')?.value || '';
        let q = supabaseClient
            .from('admin_messages')
            .select('created_at,type,date,title,body,client_name,sent_count')
            .order('created_at', { ascending: false })
            .limit(500);
        if (typeFilter) q = q.eq('type', typeFilter);
        const { data, error } = await _queryWithTimeout(q);
        if (error) {
            console.warn('[Messaggi] load error:', error.message);
            const tbody = document.getElementById('messaggiTableBody');
            if (tbody) tbody.innerHTML = '<tr><td colspan="6" class="registro-empty">❌ Errore caricamento messaggi. <a href="#" onclick="loadMessaggi();return false">Riprova</a></td></tr>';
            return;
        }
        _messaggiCache = data || [];
        renderMessaggiTable();
    } catch (e) {
        console.warn('[Messaggi] load exception:', e);
        const tbody = document.getElementById('messaggiTableBody');
        if (tbody) tbody.innerHTML = '<tr><td colspan="6" class="registro-empty">❌ Errore caricamento messaggi. <a href="#" onclick="loadMessaggi();return false">Riprova</a></td></tr>';
    }
}

function renderMessaggiTable() {
    const typeFilter = document.getElementById('msgFilterType')?.value || '';
    const statusFilter = document.getElementById('msgFilterStatus')?.value || '';
    const dateFilter = document.getElementById('msgFilterDate')?.value || '';

    _messaggiFiltered = _messaggiCache.filter(m => {
        if (typeFilter && m.type !== typeFilter) return false;
        if (dateFilter) {
            // Usa la data di created_at (locale) — m.date è NULL per new_client/topup/broadcast
            const d = new Date(m.created_at);
            const createdDate = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
            if (createdDate !== dateFilter) return false;
        }
        if (statusFilter) {
            const isSent = (m.sent_count || 0) > 0;
            if (statusFilter === 'sent' && !isSent) return false;
            if (statusFilter === 'failed' && isSent) return false;
        }
        return true;
    });

    _messaggiPage = 0;
    _renderMessaggiPage();
}

function _renderMessaggiPage() {
    const tbody = document.getElementById('messaggiTableBody');
    if (!tbody) return;

    const start = _messaggiPage * MESSAGGI_PAGE_SIZE;
    const page = _messaggiFiltered.slice(start, start + MESSAGGI_PAGE_SIZE);

    if (page.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="registro-empty">Nessun messaggio trovato</td></tr>';
        const ml = document.getElementById('messaggiMobileList');
        if (ml) ml.innerHTML = `<div class="registro-mobile-empty">Nessun messaggio trovato</div>`;
    } else {
        tbody.innerHTML = page.map(m => {
            const dt = new Date(m.created_at);
            const dateStr = `${String(dt.getDate()).padStart(2,'0')}/${String(dt.getMonth()+1).padStart(2,'0')}/${dt.getFullYear()}`;
            const timeStr = `${String(dt.getHours()).padStart(2,'0')}:${String(dt.getMinutes()).padStart(2,'0')}`;
            const typeLabel = _MSG_TYPE_LABELS[m.type] || m.type;
            const sent = m.sent_count || 0;
            const isSent = sent > 0;
            const statusLabel = isSent ? `✅ Inviata (${sent})` : '❌ Non inviata';
            const statusStyle = isSent ? 'color:#22c55e' : 'color:#ef4444';
            return `<tr>
                <td>${dateStr} ${timeStr}</td>
                <td>${typeLabel}</td>
                <td>${_escHtml(m.title)}</td>
                <td>${_escHtml(m.body)}</td>
                <td>${_escHtml(m.client_name || '')}</td>
                <td style="${statusStyle};font-weight:600">${statusLabel}</td>
            </tr>`;
        }).join('');
        renderMessaggiMobile(page);
    }

    // Pagination
    const total = _messaggiFiltered.length;
    const totalPages = Math.ceil(total / MESSAGGI_PAGE_SIZE) || 1;
    const infoEl = document.getElementById('messaggiPaginationInfo');
    if (infoEl) infoEl.textContent = `${_messaggiPage + 1} / ${totalPages} (${total})`;
    const prevBtn = document.getElementById('messaggiPrevBtn');
    const nextBtn = document.getElementById('messaggiNextBtn');
    if (prevBtn) prevBtn.disabled = _messaggiPage === 0;
    if (nextBtn) nextBtn.disabled = start + MESSAGGI_PAGE_SIZE >= total;
}

function messaggiPrevPage() {
    if (_messaggiPage > 0) { _messaggiPage--; _renderMessaggiPage(); }
}
function messaggiNextPage() {
    if ((_messaggiPage + 1) * MESSAGGI_PAGE_SIZE < _messaggiFiltered.length) { _messaggiPage++; _renderMessaggiPage(); }
}

// ══════════════════════════════════════════════════════════════════════════════
// NOTIFICHE AI CLIENTI
// ══════════════════════════════════════════════════════════════════════════════

let _cnCache = [];
let _cnFiltered = [];
let _cnPage = 0;
const CN_PAGE_SIZE = 50;

var _debouncedCnFilter = _debounce(() => renderClientNotifTable(), 250);

const _CN_TYPE_LABELS = {
    reminder_24h:    '⏰ Promemoria 24h',
    reminder_1h:     '⏰ Promemoria 1h',
    slot_available:  '🟢 Slot disponibile',
    broadcast:       '📢 Broadcast',
};

const _CN_STATUS_LABELS = {
    sent:            '✅ Inviata',
    failed:          '❌ Fallita',
    no_subscription: '⚠️ No sub',
};

async function loadClientNotifications() {
    if (typeof supabaseClient === 'undefined') return;
    try {
        const { data, error } = await _queryWithTimeout(supabaseClient
            .from('client_notifications')
            .select('created_at,type,status,user_name,user_email,title,body,error,booking_date')
            .order('created_at', { ascending: false })
            .limit(1000));
        if (error) {
            console.warn('[ClientNotif] load error:', error.message);
            const tbody = document.getElementById('clientNotifTableBody');
            if (tbody) tbody.innerHTML = '<tr><td colspan="7" class="registro-empty">❌ Errore caricamento notifiche. <a href="#" onclick="loadClientNotifications();return false">Riprova</a></td></tr>';
            return;
        }
        _cnCache = data || [];
        renderClientNotifTable();
    } catch (e) {
        console.warn('[ClientNotif] load exception:', e);
        const tbody = document.getElementById('clientNotifTableBody');
        if (tbody) tbody.innerHTML = '<tr><td colspan="7" class="registro-empty">❌ Errore caricamento notifiche. <a href="#" onclick="loadClientNotifications();return false">Riprova</a></td></tr>';
    }
}

function renderClientNotifTable() {
    const typeFilter = document.getElementById('cnFilterType')?.value || '';
    const statusFilter = document.getElementById('cnFilterStatus')?.value || '';
    const clientFilter = (document.getElementById('cnFilterClient')?.value || '').toLowerCase().trim();
    const dateFilter = document.getElementById('cnFilterDate')?.value || '';

    _cnFiltered = _cnCache.filter(n => {
        if (typeFilter && n.type !== typeFilter) return false;
        if (statusFilter && n.status !== statusFilter) return false;
        if (dateFilter && n.booking_date !== dateFilter) return false;
        if (clientFilter) {
            const name = (n.user_name || '').toLowerCase();
            const email = (n.user_email || '').toLowerCase();
            if (!name.includes(clientFilter) && !email.includes(clientFilter)) return false;
        }
        return true;
    });

    _cnPage = 0;
    _renderCnPage();
}

function _renderCnPage() {
    const tbody = document.getElementById('clientNotifTableBody');
    if (!tbody) return;

    const start = _cnPage * CN_PAGE_SIZE;
    const page = _cnFiltered.slice(start, start + CN_PAGE_SIZE);

    if (page.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="registro-empty">Nessuna notifica trovata</td></tr>';
        const ml = document.getElementById('cnMobileList');
        if (ml) ml.innerHTML = `<div class="registro-mobile-empty">Nessuna notifica trovata</div>`;
    } else {
        tbody.innerHTML = page.map(n => {
            const dt = new Date(n.created_at);
            const dateStr = `${String(dt.getDate()).padStart(2,'0')}/${String(dt.getMonth()+1).padStart(2,'0')}/${dt.getFullYear()}`;
            const timeStr = `${String(dt.getHours()).padStart(2,'0')}:${String(dt.getMinutes()).padStart(2,'0')}`;
            const typeLabel = _CN_TYPE_LABELS[n.type] || n.type;
            const statusLabel = _CN_STATUS_LABELS[n.status] || n.status;
            const statusStyle = n.status === 'sent' ? 'color:#22c55e' : n.status === 'failed' ? 'color:#ef4444' : 'color:#eab308';
            return `<tr>
                <td>${dateStr} ${timeStr}</td>
                <td>${typeLabel}</td>
                <td>${_escHtml(n.user_name || '')}</td>
                <td>${_escHtml(n.title)}</td>
                <td>${_escHtml(n.body)}${n.error ? `<br><small style="color:#ef4444">${_escHtml(n.error)}</small>` : ''}</td>
                <td style="${statusStyle};font-weight:600">${statusLabel}</td>
            </tr>`;
        }).join('');
        renderCnMobile(page);
    }

    const total = _cnFiltered.length;
    const totalPages = Math.ceil(total / CN_PAGE_SIZE) || 1;
    const infoEl = document.getElementById('cnPaginationInfo');
    if (infoEl) infoEl.textContent = `${_cnPage + 1} / ${totalPages} (${total})`;
    const prevBtn = document.getElementById('cnPrevBtn');
    const nextBtn = document.getElementById('cnNextBtn');
    if (prevBtn) prevBtn.disabled = _cnPage === 0;
    if (nextBtn) nextBtn.disabled = start + CN_PAGE_SIZE >= total;
}

function cnPrevPage() {
    if (_cnPage > 0) { _cnPage--; _renderCnPage(); }
}
function cnNextPage() {
    if ((_cnPage + 1) * CN_PAGE_SIZE < _cnFiltered.length) { _cnPage++; _renderCnPage(); }
}

// ── Render mobile per Notifiche admin (Variante A) ─────────────────────────
function renderMessaggiMobile(page) {
    const list = document.getElementById('messaggiMobileList');
    if (!list) return;

    const SVG = _regSVG();
    const TAG = {
        booking:                       { cls:'book',    svg: SVG.book },
        cancellation:                  { cls:'cancel',  svg: SVG.x },
        proximity:                     { cls:'neutral', svg: SVG.bell },
        proximity_no_booking:          { cls:'warn',    svg: SVG.bell },
        new_client:                    { cls:'credit',  svg: SVG.userPlus },
        broadcast:                     { cls:'warn',    svg: SVG.megaphone },
        topup:                         { cls:'credit',  svg: SVG.wallet },
        access_request_new:            { cls:'book',    svg: SVG.bell },
        access_request_user_accepted:  { cls:'pay',     svg: SVG.check },
        access_request_user_declined:  { cls:'cancel',  svg: SVG.x },
    };

    const todayKey = _regDayKey(new Date());
    const yKey     = (() => { const d = new Date(); d.setDate(d.getDate() - 1); return _regDayKey(d); })();
    const dayLabel = (key, d) => {
        if (key === todayKey) return `Oggi · ${_regShortDate(d)}`;
        if (key === yKey)     return `Ieri · ${_regShortDate(d)}`;
        return _regFullDate(d);
    };
    const groups = [];
    let cur = null;
    for (const m of page) {
        const ts = new Date(m.created_at);
        const k  = _regDayKey(ts);
        if (!cur || cur.key !== k) { cur = { key: k, date: ts, items: [] }; groups.push(cur); }
        cur.items.push(m);
    }

    list.innerHTML = groups.map(g => {
        const rows = g.items.map(m => {
            const ts = new Date(m.created_at);
            const hh = `${String(ts.getHours()).padStart(2,'0')}:${String(ts.getMinutes()).padStart(2,'0')}`;
            const tsKey = _regDayKey(ts);
            const subDay = tsKey === todayKey ? 'oggi' : (tsKey === yKey ? 'ieri' : _regShortDate(ts));
            const t = TAG[m.type] || { cls: 'neutral', svg: SVG.bell };
            const typeLabel = _MSG_TYPE_LABELS[m.type] || m.type;
            const sent = m.sent_count || 0;
            const isSent = sent > 0;
            const statusBadge = isSent
                ? `<span class="reg-mob-badge paid">Inviata · ${sent}</span>`
                : `<span class="reg-mob-badge cancel">Non inviata</span>`;
            const rightPill = isSent
                ? `<span class="reg-mob-amt plus">✓</span>`
                : `<span class="reg-mob-amt minus">✗</span>`;
            const displayName = m.client_name || m.title || '—';
            const clientArg = _regBtnArg(m.client_name || '');
            const clientBtn = m.client_name
                ? `<button class="reg-mob-btn primary" onclick="event.stopPropagation();regMobOpenClient('${clientArg}')">Vedi cliente</button>`
                : '';
            return `
                <div class="reg-mob-row" data-reg-row>
                    <div class="reg-mob-time"><b>${hh}</b>${_escHtml(subDay)}</div>
                    <div class="reg-mob-tag ${t.cls}">${t.svg}</div>
                    <div class="reg-mob-name">${_escHtml(displayName)}</div>
                    ${rightPill}
                    <span class="reg-mob-chev"></span>
                </div>
                <div class="reg-mob-detail">
                    <dl class="reg-mob-grid">
                        <dt>Tipo</dt><dd>${_escHtml(typeLabel)}</dd>
                        ${m.title ? `<dt>Titolo</dt><dd>${_escHtml(m.title)}</dd>` : ''}
                        ${m.body  ? `<dt>Dettaglio</dt><dd>${_escHtml(m.body)}</dd>` : ''}
                        ${m.client_name ? `<dt>Cliente</dt><dd>${_escHtml(m.client_name)}</dd>` : ''}
                        <dt>Stato</dt><dd>${statusBadge}</dd>
                    </dl>
                    ${clientBtn ? `<div class="reg-mob-actions">${clientBtn}</div>` : ''}
                </div>`;
        }).join('');
        return `
            <div class="reg-mob-sep">${dayLabel(g.key, g.date)}</div>
            <div class="reg-mob-group">${rows}</div>`;
    }).join('');

    list.querySelectorAll('[data-reg-row]').forEach(r => {
        r.addEventListener('click', () => {
            const wasOpen = r.classList.contains('open');
            list.querySelectorAll('.reg-mob-row.open').forEach(x => x.classList.remove('open'));
            if (!wasOpen) r.classList.add('open');
        });
    });
}

// ── Render mobile per Notifiche clienti (Variante A) ───────────────────────
function renderCnMobile(page) {
    const list = document.getElementById('cnMobileList');
    if (!list) return;

    const SVG = _regSVG();
    const TAG = {
        reminder_24h:                     { cls:'warn',    svg: SVG.clock },
        reminder_1h:                      { cls:'warn',    svg: SVG.clock },
        slot_available:                   { cls:'pay',     svg: SVG.signal },
        broadcast:                        { cls:'warn',    svg: SVG.megaphone },
        access_request_offered:           { cls:'book',    svg: SVG.bell },
        access_request_admin_offered:     { cls:'pay',     svg: SVG.check },
        access_request_approved:          { cls:'pay',     svg: SVG.check },
        access_request_cancelled_by_admin:{ cls:'cancel',  svg: SVG.x },
    };

    const todayKey = _regDayKey(new Date());
    const yKey     = (() => { const d = new Date(); d.setDate(d.getDate() - 1); return _regDayKey(d); })();
    const dayLabel = (key, d) => {
        if (key === todayKey) return `Oggi · ${_regShortDate(d)}`;
        if (key === yKey)     return `Ieri · ${_regShortDate(d)}`;
        return _regFullDate(d);
    };
    const groups = [];
    let cur = null;
    for (const n of page) {
        const ts = new Date(n.created_at);
        const k  = _regDayKey(ts);
        if (!cur || cur.key !== k) { cur = { key: k, date: ts, items: [] }; groups.push(cur); }
        cur.items.push(n);
    }

    list.innerHTML = groups.map(g => {
        const rows = g.items.map(n => {
            const ts = new Date(n.created_at);
            const hh = `${String(ts.getHours()).padStart(2,'0')}:${String(ts.getMinutes()).padStart(2,'0')}`;
            const tsKey = _regDayKey(ts);
            const subDay = tsKey === todayKey ? 'oggi' : (tsKey === yKey ? 'ieri' : _regShortDate(ts));
            const t = TAG[n.type] || { cls: 'neutral', svg: SVG.bell };
            const typeLabel = _CN_TYPE_LABELS[n.type] || n.type;

            let statusBadge, rightPill;
            if (n.status === 'sent') {
                statusBadge = `<span class="reg-mob-badge paid">Inviata</span>`;
                rightPill   = `<span class="reg-mob-amt plus">✓</span>`;
            } else if (n.status === 'failed') {
                statusBadge = `<span class="reg-mob-badge cancel">Fallita</span>`;
                rightPill   = `<span class="reg-mob-amt minus">✗</span>`;
            } else if (n.status === 'no_subscription') {
                statusBadge = `<span class="reg-mob-badge pending">No sub</span>`;
                rightPill   = `<span class="reg-mob-amt"><span style="color:#b45309">!</span></span>`;
            } else {
                statusBadge = `<span class="reg-mob-badge auto">${_escHtml(n.status || '—')}</span>`;
                rightPill   = `<span class="reg-mob-amt">—</span>`;
            }

            const displayName = n.user_name || n.user_email || '—';
            const clientArg = _regBtnArg(n.user_name || '');
            const clientBtn = n.user_name
                ? `<button class="reg-mob-btn primary" onclick="event.stopPropagation();regMobOpenClient('${clientArg}')">Vedi cliente</button>`
                : '';

            return `
                <div class="reg-mob-row" data-reg-row>
                    <div class="reg-mob-time"><b>${hh}</b>${_escHtml(subDay)}</div>
                    <div class="reg-mob-tag ${t.cls}">${t.svg}</div>
                    <div class="reg-mob-name">${_escHtml(displayName)}</div>
                    ${rightPill}
                    <span class="reg-mob-chev"></span>
                </div>
                <div class="reg-mob-detail">
                    <dl class="reg-mob-grid">
                        <dt>Tipo</dt><dd>${_escHtml(typeLabel)}</dd>
                        ${n.title ? `<dt>Titolo</dt><dd>${_escHtml(n.title)}</dd>` : ''}
                        ${n.body  ? `<dt>Dettaglio</dt><dd>${_escHtml(n.body)}</dd>` : ''}
                        ${n.user_name  ? `<dt>Cliente</dt><dd>${_escHtml(n.user_name)}</dd>` : ''}
                        ${n.user_email ? `<dt>Email</dt><dd>${_escHtml(n.user_email)}</dd>` : ''}
                        ${n.booking_date ? `<dt>Lezione</dt><dd>${_escHtml(n.booking_date)}</dd>` : ''}
                        <dt>Stato</dt><dd>${statusBadge}</dd>
                        ${n.error ? `<dt>Errore</dt><dd style="color:#991b1b">${_escHtml(n.error)}</dd>` : ''}
                    </dl>
                    ${clientBtn ? `<div class="reg-mob-actions">${clientBtn}</div>` : ''}
                </div>`;
        }).join('');
        return `
            <div class="reg-mob-sep">${dayLabel(g.key, g.date)}</div>
            <div class="reg-mob-group">${rows}</div>`;
    }).join('');

    list.querySelectorAll('[data-reg-row]').forEach(r => {
        r.addEventListener('click', () => {
            const wasOpen = r.classList.contains('open');
            list.querySelectorAll('.reg-mob-row.open').forEach(x => x.classList.remove('open'));
            if (!wasOpen) r.classList.add('open');
        });
    });
}

