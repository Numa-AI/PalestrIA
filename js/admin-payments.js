// ══════════════════════════════════════════════════════════════════════════════
// admin-payments.js — Tab "Pagamenti" (versione LEDGER, multi-tenant)
//
// Ricostruito dopo la rimozione del sistema crediti/debiti/bonus. Ora si basa
// esclusivamente sul ledger unificato `payments` e sulle prenotazioni non pagate:
//   (1) elenco "Non in regola": prenotazioni pay-per-session passate e non pagate,
//       raggruppate per cliente → si saldano via RPC admin_pay_bookings.
//   (2) elenco "Pagamenti recenti": righe della tabella payments (org-scoped da RLS).
//   (3) azione "Vendi pacchetto"   → RPC admin_sell_package.
//   (4) azione "Registra abbonamento" → RPC admin_record_membership_payment.
//
// Niente più credito/debito/bonus: i prezzi sono server-authoritative
// (slot_types.default_price), le RPC filtrano org_id (current_org_id()).
//
// Dipendenze globali: supabaseClient, _rpcWithTimeout, showToast, _escHtml,
//   sensitiveSet, _sensitiveHidden, normalizePhone (auth.js), bookingHasPassed
//   (definita qui), getBookingPrice/SLOT_NAMES (data.js), BookingStorage,
//   UserStorage (data.js).
// ══════════════════════════════════════════════════════════════════════════════

// Metodi di pagamento ammessi dal ledger (allineati al CHECK di payments.method)
const PAYMENT_METHOD_LABELS = {
    'contanti':        '💵 Contanti',
    'contanti-report': '🧾 Contanti con Report',
    'carta':           '💳 Carta',
    'iban':            '🏦 Bonifico',
    'stripe':          '🌐 Stripe',
    'gratuito':        '🎁 Gratuito',
};
const PAYMENT_KIND_LABELS = {
    'session':          'Lezione',
    'membership':       'Abbonamento',
    'package_purchase': 'Pacchetto',
    'penalty_mora':     'Mora',
    'adjustment':       'Rettifica',
};

let debtorsListVisible  = false;
let recentListVisible   = false;

// Guard render: scarta risposte RPC non più correnti (tab switch rapidi).
let _paymentsReqCounter = 0;
let _recentPayments     = [];   // cache ultima fetch payments

// ─────────────────────────────────────────────────────────────────────────────
// Helper booking (riusati anche da admin-calendar.js / admin-clients.js)
// ─────────────────────────────────────────────────────────────────────────────

// True se l'orario di inizio della prenotazione è già passato.
function bookingHasPassed(booking) {
    const startTimePart = (booking.time || '').split(' - ')[0];
    if (!startTimePart || !booking.date) return false;
    const [startHour, startMin] = startTimePart.trim().split(':').map(Number);
    const [year, month, day]    = booking.date.split('-').map(Number);
    const startDateTime = new Date(year, month - 1, day, startHour, startMin, 0);
    return new Date() >= startDateTime;
}

// Importo non pagato (lordo) per un contatto: somma delle prenotazioni passate
// non pagate e non annullate. Niente più credito/debito manuale da sottrarre.
// Mantiene la firma usata da admin-calendar.js.
function getUnpaidAmountForContact(whatsapp, email) {
    const normWhatsapp = normalizePhone(whatsapp);
    const emailLow = (email || '').toLowerCase();
    let totalUnpaid = 0;
    BookingStorage.getAllBookings().forEach(booking => {
        const phoneMatch = normWhatsapp && normalizePhone(booking.whatsapp) === normWhatsapp;
        const emailMatch = emailLow && booking.email && booking.email.toLowerCase() === emailLow;
        if ((phoneMatch || emailMatch) && !booking.paid && bookingHasPassed(booking)
            && booking.status !== 'cancelled' && booking.status !== 'cancellation_requested') {
            totalUnpaid += getBookingPrice(booking);
        }
    });
    return Math.round(totalUnpaid * 100) / 100;
}

// Raggruppa le prenotazioni passate non pagate per contatto (telefono OR email).
// Ritorna [{ name, whatsapp, email, unpaidBookings:[{...b, price}], totalAmount }]
function _getUnpaidContacts() {
    const allBookings = BookingStorage.getAllBookings();
    const map = {};
    const phoneIdx = {};
    const emailIdx = {};

    function _findKey(normPhone, email) {
        if (normPhone && phoneIdx[normPhone]) return phoneIdx[normPhone];
        const el = email ? email.toLowerCase() : '';
        if (el && emailIdx[el]) return emailIdx[el];
        return null;
    }
    function _registerKey(key, normPhone, email) {
        if (normPhone) phoneIdx[normPhone] = key;
        const el = email ? email.toLowerCase() : '';
        if (el) emailIdx[el] = key;
    }

    allBookings.forEach(booking => {
        if (!booking.paid && bookingHasPassed(booking)
            && booking.status !== 'cancelled' && booking.status !== 'cancellation_requested') {
            const normPhone = normalizePhone(booking.whatsapp);
            let key = _findKey(normPhone, booking.email);
            if (!key) {
                key = normPhone || (booking.email || '').toLowerCase() || booking.id;
                map[key] = {
                    name: booking.name, whatsapp: booking.whatsapp, email: booking.email,
                    unpaidBookings: [], totalAmount: 0,
                };
                _registerKey(key, normPhone, booking.email);
            }
            const price = getBookingPrice(booking);
            map[key].unpaidBookings.push({ ...booking, price });
            map[key].totalAmount = Math.round((map[key].totalAmount + price) * 100) / 100;
        }
    });

    return Object.values(map)
        .filter(c => c.totalAmount > 0)
        .sort((a, b) => b.totalAmount - a.totalAmount);
}

// ─────────────────────────────────────────────────────────────────────────────
// Render del tab
// ─────────────────────────────────────────────────────────────────────────────

async function renderPaymentsTab(_diagSource = 'unknown') {
    const reqId = ++_paymentsReqCounter;

    // 1) Render sincrono dai dati locali: tab utilizzabile subito.
    _paintPaymentsTab({ preserveUiState: false });

    // 2) In background scarico i pagamenti recenti dal ledger e riallineo.
    if (typeof supabaseClient !== 'undefined') {
        try {
            const { data, error } = await _rpcWithTimeout(
                supabaseClient.from('payments')
                    .select('id, created_at, client_email, amount, currency, method, kind, note, period_start, period_end')
                    .order('created_at', { ascending: false })
                    .limit(50),
                15000
            );
            if (reqId !== _paymentsReqCounter) return; // render più recente → scarto
            if (error) { console.warn('[Payments] fetch payments error:', error.message); return; }
            _recentPayments = data || [];
            _paintPaymentsTab({ preserveUiState: true });
        } catch (e) {
            console.warn('[Payments] fetch payments fallita:', e?.message || e);
        }
    }
}

function _paintPaymentsTab({ preserveUiState }) {
    const contacts = _getUnpaidContacts();
    const totalUnpaid = contacts.reduce((s, c) => s + c.totalAmount, 0);

    // Incasso del mese corrente dal ledger
    const now = new Date();
    const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
    const monthRevenue = _recentPayments.reduce((s, p) => {
        const d = new Date(p.created_at);
        return d >= monthStart ? s + Number(p.amount || 0) : s;
    }, 0);

    // Stat cards (gli ID esistono già in admin.html)
    sensitiveSet('totalUnpaid', `€${Math.round(totalUnpaid * 100) / 100}`);
    sensitiveSet('totalDebtors', contacts.length);
    sensitiveSet('totalCreditAmount', `€${Math.round(monthRevenue * 100) / 100}`);
    sensitiveSet('totalCreditors', _recentPayments.length);

    const debtorsList = document.getElementById('debtorsList');
    const recentList  = document.getElementById('creditsList');
    if (!debtorsList) return;

    if (!preserveUiState) {
        clearSearch();
        debtorsListVisible = false;
        recentListVisible  = false;
        debtorsList.style.display = 'none';
        const debtorsHint = document.getElementById('debtorsToggleHint');
        if (debtorsHint) debtorsHint.textContent = 'Dettagli ▼';
        document.getElementById('statcard-debtors')?.classList.remove('active');
        if (recentList) {
            recentList.style.display = 'none';
            const recentHint = document.getElementById('creditorsToggleHint');
            if (recentHint) recentHint.textContent = 'Dettagli ▼';
            document.getElementById('statcard-creditors')?.classList.remove('active');
        }
    }

    // Lista "Non in regola"
    if (contacts.length === 0) {
        debtorsList.innerHTML = '<div class="empty-slot">Nessun cliente con pagamenti in sospeso! 🎉</div>';
    } else {
        debtorsList.innerHTML = '';
        contacts.forEach((c, i) => debtorsList.appendChild(createDebtorCard(c, `main-${i}`)));
    }

    // Lista "Pagamenti recenti" (ledger)
    if (recentList) {
        if (_recentPayments.length === 0) {
            recentList.innerHTML = '<div class="empty-slot">Nessun pagamento registrato</div>';
        } else {
            recentList.innerHTML = '';
            _recentPayments.forEach(p => recentList.appendChild(_createPaymentRow(p)));
        }
    }
}

function _createPaymentRow(p) {
    const row = document.createElement('div');
    row.className = 'debtor-card payment-ledger-row';
    const d = new Date(p.created_at);
    const dateStr = `${d.getDate()}/${d.getMonth() + 1}/${d.getFullYear()}`;
    const method  = PAYMENT_METHOD_LABELS[p.method] || p.method || '';
    const kind    = PAYMENT_KIND_LABELS[p.kind] || p.kind || '';
    const who     = p.client_email || '—';
    let period = '';
    if (p.period_start && p.period_end) {
        const ps = new Date(p.period_start), pe = new Date(p.period_end);
        period = ` · ${ps.getDate()}/${ps.getMonth() + 1} → ${pe.getDate()}/${pe.getMonth() + 1}`;
    }
    row.innerHTML = `
        <div class="debtor-card-header" style="cursor:default">
            <div class="debtor-info">
                <div class="debtor-name">${_escHtml(who)}</div>
                <div class="debtor-contact">
                    <span>📅 ${dateStr} · ${_escHtml(kind)} · ${_escHtml(method)}${_escHtml(period)}</span>
                    ${p.note ? `<span>📝 ${_escHtml(p.note)}</span>` : ''}
                </div>
            </div>
            <div class="debtor-amount credit-amount">€${Number(p.amount || 0)}</div>
        </div>`;
    return row;
}

// Card cliente "non in regola" — apre il popup di saldo al click.
function createDebtorCard(contact, cardId) {
    const card = document.createElement('div');
    card.className = 'debtor-card';
    card.id = `debtor-card-${cardId}`;

    const safeW = (contact.whatsapp || '').replace(/'/g, "\\'");
    const safeE = (contact.email || '').replace(/'/g, "\\'");
    const safeN = (contact.name || '').replace(/'/g, "\\'");

    const items = contact.unpaidBookings.map(b => `
        <div class="debtor-booking-item">
            <div class="debtor-booking-details">
                📅 ${b.date} &nbsp;·&nbsp; 🕐 ${b.time} &nbsp;·&nbsp; ${SLOT_NAMES[b.slotType] || b.slotType}
            </div>
            <div class="debtor-booking-price">€${b.price}</div>
        </div>`).join('');

    card.innerHTML = `
        <div class="debtor-card-header" onclick="toggleDebtorCard('debtor-card-${cardId}')">
            <div class="debtor-info">
                <div class="debtor-name">${_escHtml(contact.name)}</div>
                <div class="debtor-contact"><span>📱 ${_escHtml(contact.whatsapp || '—')}</span></div>
            </div>
            <div class="debtor-amount">Da incassare: €${contact.totalAmount}</div>
            <div class="debtor-toggle">▼</div>
        </div>
        <div class="debtor-card-body">
            <div class="debtor-bookings">${items}</div>
            <button class="debt-popup-pay-btn" style="margin:0.75rem;"
                onclick="event.stopPropagation();openDebtPopup('${safeW}','${safeE}','${safeN}')">
                ✓ Segna come pagato
            </button>
        </div>`;
    return card;
}

function toggleDebtorCard(cardId) {
    document.getElementById(cardId)?.classList.toggle('open');
}

function toggleDebtorsList() {
    if (_sensitiveHidden) return;
    debtorsListVisible = !debtorsListVisible;
    const list = document.getElementById('debtorsList');
    const hint = document.getElementById('debtorsToggleHint');
    const card = document.getElementById('statcard-debtors');
    if (list) list.style.display = debtorsListVisible ? 'flex' : 'none';
    if (hint) hint.textContent = debtorsListVisible ? 'Nascondi ▲' : 'Dettagli ▼';
    if (card) card.classList.toggle('active', debtorsListVisible);
    if (debtorsListVisible && recentListVisible) _collapseRecentList();
}

function toggleCreditsList() {
    if (_sensitiveHidden) return;
    recentListVisible = !recentListVisible;
    const list = document.getElementById('creditsList');
    const hint = document.getElementById('creditorsToggleHint');
    const card = document.getElementById('statcard-creditors');
    if (list) list.style.display = recentListVisible ? 'flex' : 'none';
    if (hint) hint.textContent = recentListVisible ? 'Nascondi ▲' : 'Dettagli ▼';
    if (card) card.classList.toggle('active', recentListVisible);
    if (recentListVisible && debtorsListVisible) _collapseDebtorsList();
}

function _collapseRecentList() {
    recentListVisible = false;
    const cl = document.getElementById('creditsList');
    const ch = document.getElementById('creditorsToggleHint');
    document.getElementById('statcard-creditors')?.classList.remove('active');
    if (cl) cl.style.display = 'none';
    if (ch) ch.textContent = 'Dettagli ▼';
}
function _collapseDebtorsList() {
    debtorsListVisible = false;
    const dl = document.getElementById('debtorsList');
    const dh = document.getElementById('debtorsToggleHint');
    document.getElementById('statcard-debtors')?.classList.remove('active');
    if (dl) dl.style.display = 'none';
    if (dh) dh.textContent = 'Dettagli ▼';
}

function clearSearch() {
    const resultsContainer = document.getElementById('debtorSearchResults');
    if (resultsContainer) resultsContainer.style.display = 'none';
    const stats = document.querySelector('.payments-stats');
    if (stats) stats.style.display = '';
}

// ═══════════════════════════════════════════════════════════════════════════════
// Popup "Segna come pagato" — salda le prenotazioni non pagate di un contatto
// via RPC admin_pay_bookings(ids, method, now). Riusa il markup #debtPopup* di
// admin.html (campo importo nascosto: il prezzo lo decide il server).
// ═══════════════════════════════════════════════════════════════════════════════
let currentDebtContact = null;

function openDebtPopup(whatsapp, email, name) {
    const normWhatsapp = normalizePhone(whatsapp);
    const emailLow = (email || '').toLowerCase();
    const unpaid = BookingStorage.getAllBookings()
        .filter(b => {
            const phoneMatch = normWhatsapp && normalizePhone(b.whatsapp) === normWhatsapp;
            const emailMatch = emailLow && b.email && b.email.toLowerCase() === emailLow;
            return (phoneMatch || emailMatch) && !b.paid
                && b.status !== 'cancelled' && b.status !== 'cancellation_requested';
        })
        .sort((a, b) => a.date.localeCompare(b.date) || a.time.localeCompare(b.time));

    if (unpaid.length === 0) { showToast('Nessuna prenotazione da saldare', 'info'); return; }

    currentDebtContact = { whatsapp, email, name, unpaid };

    document.getElementById('debtPopupName').textContent = name;
    const pastCount   = unpaid.filter(b => bookingHasPassed(b)).length;
    const futureCount = unpaid.length - pastCount;
    const parts = [];
    if (pastCount   > 0) parts.push(`${pastCount} passata${pastCount   > 1 ? 'e' : ''}`);
    if (futureCount > 0) parts.push(`${futureCount} futura${futureCount > 1 ? 'e' : ''}`);
    document.getElementById('debtPopupSubtitle').textContent =
        `${unpaid.length} lezione${unpaid.length > 1 ? 'i' : ''} non pagata${unpaid.length > 1 ? 'e' : ''} (${parts.join(', ')})`;

    const debtSelect = document.getElementById('debtMethodSelect');
    if (debtSelect) debtSelect.value = '';

    // Campo "importo incassato" non più rilevante: il prezzo è server-side.
    const amountRow = document.querySelector('#debtPopupModal .debt-payment-amount-row');
    if (amountRow) amountRow.style.display = 'none';
    const existingCreditRow = document.getElementById('debtExistingCreditRow');
    if (existingCreditRow) existingCreditRow.style.display = 'none';
    const creditRow = document.getElementById('debtCreditRow');
    if (creditRow) creditRow.style.display = 'none';

    _renderDebtPopupList(unpaid);
    _updateDebtTotal();

    document.getElementById('debtPopupOverlay').classList.add('open');
    document.getElementById('debtPopupModal').classList.add('open');
    document.body.style.overflow = 'hidden';
}

function _renderDebtPopupList(unpaid) {
    const list = document.getElementById('debtPopupList');
    list.innerHTML = '';
    unpaid
        .slice()
        .sort((a, b) => {
            const ta = new Date(`${a.date}T${(a.time || '').split(' - ')[0] || '00:00'}`);
            const tb = new Date(`${b.date}T${(b.time || '').split(' - ')[0] || '00:00'}`);
            return ta - tb;
        })
        .forEach(booking => {
            const [y, m, d] = booking.date.split('-').map(Number);
            const dateDisplay = `${d}/${m}/${y}`;
            const price = getBookingPrice(booking);
            const el = document.createElement('div');
            el.className = 'debt-popup-item';
            if (bookingHasPassed(booking)) el.classList.add('debt-popup-item--past');
            el.innerHTML = `
                <label class="debt-item-label">
                    <input type="checkbox" class="debt-item-check" data-id="${booking.id}"
                           data-sbid="${booking._sbId || ''}" data-price="${price}" onchange="updateDebtTotal()">
                    <div class="debt-item-info">
                        <span class="debt-item-date">📅 ${dateDisplay} &nbsp;·&nbsp; 🕐 ${booking.time}</span>
                        <span class="debt-item-type">${SLOT_NAMES[booking.slotType] || booking.slotType}</span>
                    </div>
                    <span class="debt-item-price">€${Number(price).toFixed(2).replace('.', ',')}</span>
                </label>`;
            list.appendChild(el);
        });
}

function _updateDebtTotal() {
    const checked = document.querySelectorAll('.debt-item-check:checked');
    const all     = document.querySelectorAll('.debt-item-check');
    const dueTotal = Array.from(checked).reduce((sum, cb) => sum + Number(cb.dataset.price), 0);
    document.getElementById('debtSelectedTotal').textContent = `€${Math.round(dueTotal * 100) / 100}`;

    const selectAll = document.getElementById('debtSelectAll');
    if (selectAll) {
        selectAll.indeterminate = checked.length > 0 && checked.length < all.length;
        selectAll.checked = all.length > 0 && checked.length === all.length;
    }
    const methodSelect = document.getElementById('debtMethodSelect');
    const payBtn = document.getElementById('debtPayBtn');
    if (payBtn) payBtn.disabled = checked.length === 0 || !(methodSelect && methodSelect.value);
}
// alias retro-compat per gli oninline in admin.html
function updateDebtTotal() { _updateDebtTotal(); }

function toggleAllDebts(checked) {
    document.querySelectorAll('.debt-item-check').forEach(cb => { cb.checked = checked; });
    _updateDebtTotal();
}

// Cambio metodo: aggiorna solo lo stato del pulsante (niente più logica credito).
function onPaymentMethodChange() { _updateDebtTotal(); }
// L'input importo non è più usato; manteniamo lo stub per gli oninput residui.
function onAmountInput() { _updateDebtTotal(); }

async function paySelectedDebts() {
    const checked = document.querySelectorAll('.debt-item-check:checked');
    const methodSelect = document.getElementById('debtMethodSelect');
    const method = methodSelect ? methodSelect.value : '';
    if (!method) { showToast('Seleziona un metodo di pagamento', 'error'); return; }
    if (checked.length === 0) { showToast('Seleziona almeno una lezione', 'error'); return; }

    // ledger.method ammette solo: contanti|contanti-report|carta|iban|stripe|gratuito
    const ledgerMethod = method === 'lezione-gratuita' ? 'gratuito' : method;

    // Solo prenotazioni effettivamente su Supabase (servono gli UUID server-side).
    const sbIds = Array.from(checked).map(cb => cb.dataset.sbid).filter(Boolean);
    if (sbIds.length === 0) {
        showToast('Nessuna prenotazione sincronizzata da saldare', 'error');
        return;
    }

    const payBtn = document.getElementById('debtPayBtn');
    if (payBtn) { payBtn.disabled = true; payBtn.textContent = 'Salvataggio...'; }

    try {
        // #8: garantisci la sessione PRIMA della RPC NON idempotente. Dopo idle il lock auth
        // può essere bloccato → la RPC perderebbe il token e l'operazione andrebbe persa
        // (niente retry). ensureValidSession è veloce (lettura diretta da storage, #5) e
        // "sveglia" il lock → la RPC parte con token valido.
        // B1: garantisci la sessione E BLOCCA se persa → mai una RPC finanziaria senza token
        // valido (sarebbe un 401 silenzioso = pagamento perso). Il finally riabilita il bottone.
        if (typeof ensureValidSession === 'function') {
            let _sess = null;
            try { _sess = await ensureValidSession({ force: false, timeoutMs: 12000 }); } catch (_) {}
            if (!_sess) {
                showToast('Sessione scaduta. Riaccedi prima di registrare il pagamento.', 'error', 5000);
                return;
            }
        }
        const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('admin_pay_bookings', {
            p_booking_ids: sbIds,
            p_method:      ledgerMethod,
            p_paid_at:     new Date().toISOString(),
        }), 30000);
        if (error) {
            console.error('[admin_pay_bookings] error:', error.message);
            showToast('Errore: ' + error.message, 'error');
            return;
        }
        console.log('[admin_pay_bookings] saldate:', data);
        closeDebtPopup();
        showToast(`${data || sbIds.length} pagament${(data || sbIds.length) === 1 ? 'o' : 'i'} registrat${(data || sbIds.length) === 1 ? 'o' : 'i'}`, 'success');

        await BookingStorage.syncFromSupabase();
        if (typeof selectedAdminDay !== 'undefined' && selectedAdminDay) renderAdminDayView(selectedAdminDay);
        const activeTab = document.querySelector('.admin-tab.active');
        if (activeTab && activeTab.dataset.tab === 'payments') renderPaymentsTab('saveDebtPayment');
    } catch (e) {
        console.error('[paySelectedDebts] unexpected:', e);
        showToast('Errore di rete o timeout. Riprova.', 'error');
    } finally {
        if (payBtn) { payBtn.textContent = '✓ Conferma'; payBtn.disabled = false; }
    }
}

function closeDebtPopup() {
    document.getElementById('debtPopupOverlay').classList.remove('open');
    document.getElementById('debtPopupModal').classList.remove('open');
    document.body.style.overflow = '';
    currentDebtContact = null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Action sheet FAB: "Vendi pacchetto" / "Registra abbonamento"
// ═══════════════════════════════════════════════════════════════════════════════
function openPaymentsActionSheet() {
    const old = document.getElementById('paymentsSheetOverlay');
    if (old) old.remove();
    const overlay = document.createElement('div');
    overlay.id = 'paymentsSheetOverlay';
    overlay.className = 'payments-sheet-overlay';
    overlay.innerHTML = `
        <div class="payments-sheet" role="dialog" aria-label="Registra incasso">
            <div class="payments-sheet-handle"></div>
            <div class="payments-sheet-title">Registra incasso</div>
            <div class="payments-sheet-options">
                <button class="payments-sheet-btn payments-sheet-btn--credit" onclick="closePaymentsActionSheet();openSellPackagePopup()">
                    <div class="payments-sheet-btn-icon payments-sheet-btn-icon--credit">🎟️</div>
                    <div class="payments-sheet-btn-text">
                        <span class="payments-sheet-btn-title">Vendi pacchetto</span>
                        <span class="payments-sheet-btn-desc">Carnet di lezioni prepagate</span>
                    </div>
                </button>
                <button class="payments-sheet-btn payments-sheet-btn--debt" onclick="closePaymentsActionSheet();openMembershipPopup()">
                    <div class="payments-sheet-btn-icon payments-sheet-btn-icon--debt">📅</div>
                    <div class="payments-sheet-btn-text">
                        <span class="payments-sheet-btn-title">Registra abbonamento</span>
                        <span class="payments-sheet-btn-desc">Quota mensile / periodo</span>
                    </div>
                </button>
            </div>
        </div>`;
    overlay.addEventListener('click', (e) => { if (e.target === overlay) closePaymentsActionSheet(); });
    document.body.appendChild(overlay);
    requestAnimationFrame(() => overlay.classList.add('visible'));
}

function closePaymentsActionSheet() {
    const overlay = document.getElementById('paymentsSheetOverlay');
    if (!overlay) return;
    overlay.classList.remove('visible');
    setTimeout(() => overlay.remove(), 300);
}

// ─────────────────────────────────────────────────────────────────────────────
// Popup generico per Pacchetto / Abbonamento (costruito a runtime).
// Selezione cliente via UserStorage (org-scoped: profiles della propria org).
// ─────────────────────────────────────────────────────────────────────────────
let _saleType = null;            // 'package' | 'membership'
let _saleContact = null;         // { name, whatsapp, email, userId }

function openSellPackagePopup()  { _openSalePopup('package'); }
function openMembershipPopup()   { _openSalePopup('membership'); }

function _openSalePopup(type) {
    _saleType = type;
    _saleContact = null;
    const old = document.getElementById('saleOverlay');
    if (old) old.remove();

    const isPkg = type === 'package';
    const today = new Date();
    const periodStart = _isoDate(today);
    const periodEnd   = _isoDate(new Date(today.getFullYear(), today.getMonth() + 1, today.getDate()));

    const overlay = document.createElement('div');
    overlay.id = 'saleOverlay';
    overlay.className = 'debt-popup-overlay open';
    overlay.onclick = (e) => { if (e.target === overlay) closeSalePopup(); };

    overlay.innerHTML = `
        <div class="debt-popup-modal manual-entry-modal open" onclick="event.stopPropagation()" style="max-width:460px;">
            <div class="debt-popup-header">
                <div>
                    <h3>${isPkg ? '🎟️ Vendi pacchetto' : '📅 Registra abbonamento'}</h3>
                    <p>${isPkg ? 'Carnet di lezioni prepagate' : 'Quota mensile / periodo'}</p>
                </div>
                <button class="debt-popup-close" onclick="closeSalePopup()">✕</button>
            </div>
            <div class="manual-entry-form">
                <div class="manual-entry-field">
                    <span class="debt-field-label">Cliente</span>
                    <div class="manual-client-search-wrap">
                        <div class="manual-search-input-wrap">
                            <input type="text" id="saleClientInput" placeholder="Nome o telefono..."
                                   oninput="liveSearchSaleClient()" autocomplete="off">
                        </div>
                        <div id="saleClientDropdown" class="debtor-search-dropdown manual-dropdown" style="display:none;"></div>
                    </div>
                    <div id="saleClientSelected" class="manual-client-selected" style="display:none;"></div>
                </div>
                <div class="manual-entry-field">
                    <span class="debt-field-label">Etichetta</span>
                    <input type="text" id="saleLabel" class="manual-note-input"
                           placeholder="${isPkg ? 'Es. Carnet 10 lezioni' : 'Es. Abbonamento mensile'}">
                </div>
                ${isPkg ? `
                <div class="manual-entry-field">
                    <span class="debt-field-label">Numero di lezioni</span>
                    <input type="number" id="saleSessions" class="manual-note-input" min="1" step="1" placeholder="10">
                </div>
                <div class="manual-entry-field">
                    <span class="debt-field-label">Scadenza (opzionale)</span>
                    <input type="date" id="saleExpires" class="manual-note-input">
                </div>` : `
                <div class="manual-entry-field">
                    <span class="debt-field-label">Periodo</span>
                    <div style="display:flex;gap:0.5rem;">
                        <input type="date" id="salePeriodStart" class="manual-note-input" value="${periodStart}">
                        <input type="date" id="salePeriodEnd" class="manual-note-input" value="${periodEnd}">
                    </div>
                </div>
                <div class="manual-entry-field">
                    <span class="debt-field-label">Lezioni incluse (vuoto = illimitato)</span>
                    <input type="number" id="saleQuota" class="manual-note-input" min="1" step="1" placeholder="∞">
                </div>`}
                <div class="manual-entry-field manual-amount-field">
                    <span class="debt-field-label">Prezzo</span>
                    <div class="manual-amount-display">
                        <span class="manual-amount-currency">€</span>
                        <input type="number" id="salePrice" class="manual-amount-input" min="0" step="0.01" placeholder="0">
                    </div>
                </div>
                <div class="manual-entry-field">
                    <span class="debt-field-label">Metodo di pagamento</span>
                    <select class="debt-method-select" id="saleMethod">
                        <option value="contanti">💵 Contanti</option>
                        <option value="contanti-report">🧾 Contanti con Report</option>
                        <option value="carta">💳 Carta</option>
                        <option value="iban">🏦 Bonifico</option>
                        <option value="stripe">🌐 Stripe</option>
                    </select>
                </div>
            </div>
            <div class="debt-popup-footer" style="justify-content:flex-end; gap:0.75rem;">
                <button class="btn-clear-search" onclick="closeSalePopup()">Annulla</button>
                <button id="saleSaveBtn" class="debt-popup-pay-btn" onclick="saveSale()">✓ Registra</button>
            </div>
        </div>`;
    document.body.appendChild(overlay);
    setTimeout(() => document.getElementById('saleClientInput')?.focus(), 100);
}

function closeSalePopup() {
    document.getElementById('saleOverlay')?.remove();
    _saleType = null;
    _saleContact = null;
}

function liveSearchSaleClient() {
    const input = document.getElementById('saleClientInput');
    const dropdown = document.getElementById('saleClientDropdown');
    if (!input || !dropdown) return;
    const q = input.value.trim();
    if (q.length < 2) { dropdown.style.display = 'none'; return; }
    const results = UserStorage.search(q).slice(0, 6);
    if (results.length === 0) { dropdown.style.display = 'none'; return; }
    dropdown.innerHTML = results.map(u => {
        const safeN = (u.name || '').replace(/'/g, "\\'");
        const safeW = (u.whatsapp || '').replace(/'/g, "\\'");
        const safeE = (u.email || '').replace(/'/g, "\\'");
        const safeId = (u.userId || '').toString().replace(/'/g, "\\'");
        return `<div class="debtor-search-option" onclick="selectSaleClient('${safeN}','${safeW}','${safeE}','${safeId}')">
            <strong>${_escHtml(u.name)}</strong>
        </div>`;
    }).join('');
    dropdown.style.display = 'block';
}

function selectSaleClient(name, whatsapp, email, userId) {
    _saleContact = { name, whatsapp, email, userId: userId || null };
    const input = document.getElementById('saleClientInput');
    const dropdown = document.getElementById('saleClientDropdown');
    const sel = document.getElementById('saleClientSelected');
    if (input) input.value = '';
    if (dropdown) dropdown.style.display = 'none';
    if (!sel) return;
    sel.style.display = 'flex';
    const initials = name.trim().split(/\s+/).map(w => w[0]).join('').toUpperCase().slice(0, 2);
    const sub = [whatsapp, email].filter(Boolean).join(' · ');
    sel.innerHTML = `
        <div class="manual-client-avatar">${initials}</div>
        <div class="manual-client-info">
            <strong>${_escHtml(name)}</strong>
            ${sub ? `<small>${_escHtml(sub)}</small>` : ''}
        </div>
        <button class="manual-client-clear" onclick="_saleContact=null;
            document.getElementById('saleClientSelected').style.display='none';">✕</button>`;
}

let _savingSale = false;
async function saveSale() {
    if (_savingSale) return;
    if (!_saleContact || !_saleContact.userId) {
        showToast('Seleziona un cliente registrato dalla lista', 'error');
        return;
    }
    const label  = document.getElementById('saleLabel').value.trim();
    const price  = parseFloat(document.getElementById('salePrice').value);
    const method = document.getElementById('saleMethod').value;
    if (isNaN(price) || price < 0) { showToast('Inserisci un prezzo valido', 'error'); return; }

    const saveBtn = document.getElementById('saleSaveBtn');
    _savingSale = true;
    if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Salvataggio...'; }

    try {
        // #8 + B1: sessione garantita E BLOCCA se persa → niente vendita (RPC non idempotente)
        // senza token valido. Il finally riabilita il bottone.
        if (typeof ensureValidSession === 'function') {
            let _sess = null;
            try { _sess = await ensureValidSession({ force: false, timeoutMs: 12000 }); } catch (_) {}
            if (!_sess) {
                showToast('Sessione scaduta. Riaccedi prima di registrare la vendita.', 'error', 5000);
                return;
            }
        }
        let error;
        if (_saleType === 'package') {
            const sessions = parseInt(document.getElementById('saleSessions').value, 10);
            if (!sessions || sessions < 1) { showToast('Numero di lezioni non valido', 'error'); return; }
            const expires = document.getElementById('saleExpires').value || null;
            ({ error } = await _rpcWithTimeout(supabaseClient.rpc('admin_sell_package', {
                p_user_id:  _saleContact.userId,
                p_label:    label || 'Pacchetto',
                p_sessions: sessions,
                p_price:    price,
                p_method:   method,
                p_expires:  expires,
            }), 30000));
        } else {
            const periodStart = document.getElementById('salePeriodStart').value;
            const periodEnd   = document.getElementById('salePeriodEnd').value;
            if (!periodStart || !periodEnd) { showToast('Imposta il periodo dell\'abbonamento', 'error'); return; }
            const quotaRaw = document.getElementById('saleQuota').value;
            const quota = quotaRaw ? parseInt(quotaRaw, 10) : null;
            ({ error } = await _rpcWithTimeout(supabaseClient.rpc('admin_record_membership_payment', {
                p_user_id:       _saleContact.userId,
                p_label:         label || 'Abbonamento',
                p_price:         price,
                p_period_start:  periodStart,
                p_period_end:    periodEnd,
                p_lessons_quota: quota,
                p_method:        method,
            }), 30000));
        }

        if (error) {
            console.error('[saveSale] error:', error.message);
            showToast('Errore: ' + error.message, 'error');
            return;
        }

        // Imposta automaticamente il modello di fatturazione del cliente in base alla
        // vendita: così book_slot applica la logica giusta (mensile/pacchetto) a QUESTO
        // cliente, a prescindere dal default dello studio. (override per-cliente)
        try {
            await supabaseClient.from('client_billing_profiles').upsert({
                org_id:         window._orgId,
                user_id:        _saleContact.userId,
                model_override: _saleType === 'package' ? 'package' : 'monthly',
            }, { onConflict: 'org_id,user_id' });
        } catch (e) { console.warn('[saveSale] model_override non impostato:', e && e.message); }

        closeSalePopup();
        showToast(_saleType === 'package' ? 'Pacchetto registrato' : 'Abbonamento registrato', 'success');
        const activeTab = document.querySelector('.admin-tab.active');
        if (activeTab && activeTab.dataset.tab === 'payments') renderPaymentsTab('saveSale');
    } catch (e) {
        console.error('[saveSale] unexpected:', e);
        showToast('Errore di rete o timeout. Riprova.', 'error');
    } finally {
        _savingSale = false;
        if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = '✓ Registra'; }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Util
// ─────────────────────────────────────────────────────────────────────────────
function _isoDate(d) {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
}
