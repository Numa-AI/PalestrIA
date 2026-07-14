/**
 * admin-calendar.js — Vista calendario settimanale del pannello admin (tab "Prenotazioni").
 *
 * COSA FA
 * Renderizza il calendario admin: navigazione per settimana, selettore giorni e vista
 * giornaliera con gli slot e i relativi iscritti. Da qui l'admin gestisce le prenotazioni
 * del giorno selezionato.
 *
 * COME FUNZIONA
 * - Setup: setupAdminCalendar() collega i pulsanti #adminPrevWeek/#adminNextWeek (modificano
 *   adminWeekOffset, condiviso con admin-analytics.js) e registra il resize handler
 *   _adminCalResizeHandler (rimosso prima di ri-aggiungerlo per evitare accumulo di listener).
 * - Sticky offsets: _updateStickyOffsets() calcola navbar/.admin-tabs e imposta le CSS var
 *   --admin-tabs-top / --bookings-bar-top per l'header appiccicato senza gap.
 * - Date: getAdminWeekDates(offset) genera i 7 giorni (lun→dom) della settimana; formatAdminDate()
 *   produce 'YYYY-MM-DD'.
 * - Render: renderAdminCalendar() seleziona oggi di default (selectedAdminDay), aggiorna
 *   #adminCurrentWeek/#adminCurrentMonth e invoca renderAdminDaySelector() (3 settimane di
 *   day-card in #adminDaySelector) e renderAdminDayView() (slot + capienza del giorno via
 *   _adminDayCapacity).
 *
 * CONNESSIONI
 * - Legge le prenotazioni da BookingStorage.getAllBookings() (js/data.js), org-scoped da RLS;
 *   filtra i booking sintetici (_avail_*) e quelli cancellati.
 * - Condivide stato con admin-analytics.js (adminWeekOffset, selectedAdminDay) e con admin.js
 *   (gestione sticky/scroll).
 */
// Admin Calendar Functions
// L10: riferimento al handler resize per poterlo rimuovere prima di ri-aggiungerlo.
let _adminCalResizeHandler = null;

function setupAdminCalendar() {
    renderAdminCalendar();

    document.getElementById('adminPrevWeek').addEventListener('click', () => {
        adminWeekOffset--;
        if (adminWeekOffset === 0) selectedAdminDay = null;
        renderAdminCalendar();
    });

    document.getElementById('adminNextWeek').addEventListener('click', () => {
        adminWeekOffset++;
        if (adminWeekOffset === 0) selectedAdminDay = null;
        renderAdminCalendar();
    });

    // Sticky: navbar → admin-tabs → week-bar, senza gap
    // L10: rimuovi il listener precedente prima di ri-aggiungerlo per evitare
    // accumulo di listener su re-render della dashboard (come fa admin.js).
    _updateStickyOffsets();
    if (_adminCalResizeHandler) window.removeEventListener('resize', _adminCalResizeHandler);
    _adminCalResizeHandler = _updateStickyOffsets;
    window.addEventListener('resize', _adminCalResizeHandler);
}

function _updateStickyOffsets() {
    const navbar = document.querySelector('.navbar');
    const tabs = document.querySelector('.admin-tabs');
    const root = document.documentElement;
    const navH = navbar ? navbar.offsetHeight : 0;
    root.style.setProperty('--admin-tabs-top', navH + 'px');
    if (tabs) {
        root.style.setProperty('--bookings-bar-top', (navH + tabs.offsetHeight) + 'px');
    }
}

function getAdminWeekDates(offset = 0) {
    const today = new Date();
    const currentDay = today.getDay();
    const diff = currentDay === 0 ? -6 : 1 - currentDay;

    const monday = new Date(today);
    monday.setDate(today.getDate() + diff + (offset * 7));

    const dates = [];
    const dayNames = ['Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato', 'Domenica'];

    for (let i = 0; i < 7; i++) {
        const date = new Date(monday);
        date.setDate(monday.getDate() + i);
        dates.push({
            date: date,
            dayName: dayNames[i],
            formatted: formatAdminDate(date),
            displayDate: `${date.getDate()}/${date.getMonth() + 1}`
        });
    }

    return dates;
}

function formatAdminDate(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

function renderAdminCalendar() {
    const weekDates = getAdminWeekDates(adminWeekOffset);

    // Select today by default (first load), or keep current selection
    if (!selectedAdminDay) {
        const todayFormatted = formatAdminDate(new Date());
        selectedAdminDay = weekDates.find(d => d.formatted === todayFormatted) || weekDates[0];
    } else {
        // Update selected day if it's in the new week
        const matchingDay = weekDates.find(d => d.formatted === selectedAdminDay.formatted);
        selectedAdminDay = matchingDay || weekDates[0];
    }

    renderAdminDaySelector(weekDates);
    renderAdminDayView(selectedAdminDay);

    // Update week display: "27 apr — 3 mag" + sotto "MAGGIO 2026"
    const firstDate = weekDates[0].date;
    const lastDate = weekDates[6].date;
    const M_SHORT = ['gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic'];
    const M_FULL  = ['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto','settembre','ottobre','novembre','dicembre'];
    const range = `${firstDate.getDate()} ${M_SHORT[firstDate.getMonth()]} — ${lastDate.getDate()} ${M_SHORT[lastDate.getMonth()]}`;
    document.getElementById('adminCurrentWeek').textContent = range;
    const monthEl = document.getElementById('adminCurrentMonth');
    if (monthEl) {
        const refDate = selectedAdminDay?.date || lastDate;
        monthEl.textContent = `${M_FULL[refDate.getMonth()].toUpperCase()} ${refDate.getFullYear()}`;
    }
}

function renderAdminDaySelector(_weekDates) {
    const selector = document.getElementById('adminDaySelector');
    selector.innerHTML = '';
    const todayFormatted = formatAdminDate(new Date());

    // M19: leggi i booking UNA sola volta fuori dai loop (3 settimane × 7 giorni =
    // 21 day-card). Prima getAllBookings() veniva chiamato per ogni card.
    const allBookings = BookingStorage.getAllBookings();

    [-1, 0, 1].forEach(off => {
        const weekDates = getAdminWeekDates(adminWeekOffset + off);
        const pageEl = document.createElement('div');
        pageEl.className = 'admin-week-page';
        pageEl.dataset.relOffset = String(off);

        weekDates.forEach(dateInfo => {
            const dayBookings = allBookings.filter(b => b.date === dateInfo.formatted && b.status !== 'cancelled' && !b.id?.startsWith('_avail_'));
            const dayBookingsCount = dayBookings.length;
            const dayCapacity = _adminDayCapacity(dateInfo);
            const fillPct = dayCapacity > 0 ? Math.min(100, Math.round(dayBookingsCount * 100 / dayCapacity)) : 0;

            const dayCard = document.createElement('div');
            dayCard.className = 'admin-day-card';
            if (dateInfo.formatted === todayFormatted) dayCard.classList.add('is-today');
            if (selectedAdminDay && selectedAdminDay.formatted === dateInfo.formatted) {
                dayCard.classList.add('active');
            }

            const shortName = dateInfo.dayName.slice(0, 3);
            dayCard.innerHTML = `
                <div class="admin-day-name"><span class="day-full">${dateInfo.dayName}</span><span class="day-short">${shortName}</span></div>
                <div class="admin-day-date">${dateInfo.date.getDate()}</div>
                <div class="admin-day-count">${dayBookingsCount} pr.</div>
                <div class="admin-day-occ" aria-hidden="true"><div class="admin-day-occ-fill" style="width:${fillPct}%"></div></div>
            `;

            dayCard.addEventListener('click', () => {
                selectedAdminDay = dateInfo;
                document.querySelectorAll('.admin-day-card').forEach(card => card.classList.remove('active'));
                dayCard.classList.add('active');
                renderAdminDayView(dateInfo);
            });
            pageEl.appendChild(dayCard);
        });

        selector.appendChild(pageEl);
    });

    // Centra la pagina corrente (middle)
    requestAnimationFrame(() => {
        const w = selector.clientWidth;
        if (w > 0) {
            const prev = selector.style.scrollBehavior;
            selector.style.scrollBehavior = 'auto';
            selector.scrollLeft = w;
            selector.style.scrollBehavior = prev || '';
        }
    });

    if (!selector._swipeHandlerAttached) {
        selector._swipeHandlerAttached = true;
        let scrollTimer = null;
        selector.addEventListener('scroll', () => {
            clearTimeout(scrollTimer);
            scrollTimer = setTimeout(() => {
                const pageWidth = selector.clientWidth;
                if (!pageWidth) return;
                const idx = Math.round(selector.scrollLeft / pageWidth);
                if (idx === 1) return;
                const delta = idx - 1;
                adminWeekOffset += delta;
                if (adminWeekOffset === 0) selectedAdminDay = null;
                renderAdminCalendar();
            }, 180);
        });
    }
}

// ── Extra spot management ──────────────────────────────────────────────────

function toggleExtraPicker(date, time) {
    const id = 'xpick-' + date + '-' + time.replace(/[: -]/g, '');
    const el = document.getElementById(id);
    if (!el) return;
    const opening = el.style.display === 'none' || el.style.display === '';
    // Reset SEMPRE (non solo in apertura): se il picker era in modalita'
    // ricerca cliente e viene chiuso, lasciava nel DOM input/results che
    // confondevano altri picker aperti dopo. Ripristinare l'HTML iniziale
    // sia in apertura che in chiusura li elimina.
    if (el._initialHtml) {
        el.innerHTML = el._initialHtml;
    }
    el.style.display = opening ? 'flex' : 'none';
    document.body.classList.toggle('extra-picker-open', opening);
}

function addExtraSpotToSlot(date, time, extraType) {
    BookingStorage.addExtraSpot(date, time, extraType);
    toggleExtraPicker(date, time); // chiudi picker
    if (window._currentAdminDate) renderAdminDayView(window._currentAdminDate);
}

// ── Admin: prenota per un cliente specifico ────────────────────────────────
// Stato picker (evita JSON inline negli onclick che causa SyntaxError).
// forcedSlotType: se settato (es. 'group-class'), salta la scelta tra tipi
// e conferma direttamente quel tipo (usato da "Slot prenotato").
let _clientPickerState = { date: '', time: '', client: null, forcedSlotType: null, picker: null };

function openClientBookingPicker(date, time, pickerId) {
    const picker = document.getElementById(pickerId);
    if (!picker) return;
    _clientPickerState.date = date;
    _clientPickerState.time = time;
    _clientPickerState.client = null;
    _clientPickerState.forcedSlotType = null;
    _clientPickerState.picker = picker;

    picker.innerHTML = `
        <div class="extra-picker-content" onclick="event.stopPropagation()">
            <div class="extra-picker-title">Aggiungi una prenotazione</div>
            <div style="display:flex;gap:8px;align-items:center">
                <input class="js-client-search-input" type="text" placeholder="Cerca cliente…"
                    autocomplete="off"
                    style="flex:1;padding:9px 12px;border:1px solid #e2e8f0;border-radius:10px;font-size:14px">
                <button onclick="toggleExtraPicker('${date}','${time}')"
                    style="background:#f1f5f9;border:none;color:#475569;cursor:pointer;font-size:18px;padding:6px 10px;border-radius:8px;line-height:1">✕</button>
            </div>
            <div class="js-client-search-results" style="display:flex;flex-direction:column;gap:6px;height:240px;max-height:240px;overflow-y:auto"></div>
            <div class="js-client-booking-confirm" style="display:none"></div>
        </div>
    `;

    const inputEl = picker.querySelector('.js-client-search-input');
    if (inputEl) {
        inputEl.addEventListener('input', function() {
            _filterClientList(this.value);
        });
    }
}

// Apre lo stesso picker cliente forzando il tipo group-class ("Slot prenotato"):
// dopo la selezione cliente mostrerà direttamente "Conferma", senza chiedere
// il tipo lezione. La capienza (e quindi quante persone) è decisa dal server
// (book_slot). I posti sono fatturati al prezzo standard del tipo slot.
function openClientBookingPickerForSlotPrenotato(date, time, pickerId) {
    openClientBookingPicker(date, time, pickerId);
    _clientPickerState.forcedSlotType = SLOT_TYPES.GROUP_CLASS;
}

function _filterClientList(query) {
    const picker = _clientPickerState.picker;
    if (!picker) return;
    const resultsEl = picker.querySelector('.js-client-search-results');
    if (!resultsEl) return;
    const q = (query || '').toString().toLowerCase().trim();
    if (!q) { resultsEl.innerHTML = ''; return; }
    let clients = [];
    try {
        clients = UserStorage.getAll().filter(c =>
            (c.name || '').toLowerCase().includes(q) || (c.email || '').toLowerCase().includes(q)
        );
    } catch (e) {
        console.error('[_filterClientList] errore filtro:', e);
        resultsEl.innerHTML = `<div style="font-size:12px;color:#999;padding:4px 8px">Errore caricamento clienti</div>`;
        return;
    }
    if (!clients.length) {
        resultsEl.innerHTML = `<div style="font-size:12px;color:#999;padding:4px 8px">Nessun cliente trovato</div>`;
        return;
    }
    resultsEl.innerHTML = '';
    clients.slice(0, 10).forEach((c) => {
        const row = document.createElement('div');
        row.style.cssText = 'display:flex;justify-content:space-between;align-items:center;padding:6px 10px;border:1px solid #eee;border-radius:8px;cursor:pointer;background:#fff;font-size:13px;flex-shrink:0';
        row.innerHTML = `
            <div>
                <div style="font-weight:600">${_escHtml(c.name || '(senza nome)')}</div>
            </div>
            <span style="font-size:11px;color:#aaa">›</span>
        `;
        row.addEventListener('click', () => _selectClientForBooking(c));
        resultsEl.appendChild(row);
    });
}

function _selectClientForBooking(client) {
    _clientPickerState.client = client;
    const picker = _clientPickerState.picker;
    if (!picker) return;
    const confirmEl = picker.querySelector('.js-client-booking-confirm');
    const resultsEl = picker.querySelector('.js-client-search-results');
    const inputEl   = picker.querySelector('.js-client-search-input');
    if (!confirmEl || !resultsEl) return;
    resultsEl.style.display = 'none';
    if (inputEl) inputEl.style.display = 'none';
    confirmEl.style.display = 'block';

    const btnBack = document.createElement('button');
    btnBack.textContent = '← Indietro';
    btnBack.style.cssText = 'background:none;border:1px solid #ddd;border-radius:8px;padding:6px 10px;cursor:pointer;font-size:12px;color:#666';
    btnBack.addEventListener('click', () => {
        _clientPickerState.client = null;
        resultsEl.style.display = 'flex';
        if (inputEl) { inputEl.style.display = ''; inputEl.value = ''; }
        confirmEl.style.display = 'none';
        _filterClientList('');
    });

    const btnRow = document.createElement('div');
    btnRow.style.cssText = 'display:flex;gap:8px;flex-wrap:wrap';

    const forced = _clientPickerState.forcedSlotType;
    if (forced === SLOT_TYPES.GROUP_CLASS) {
        // Flusso "Slot prenotato": un solo bottone Conferma (rosso come il badge)
        const btnOK = document.createElement('button');
        btnOK.className = 'extra-picker-btn';
        btnOK.style.cssText = 'background:#ef4444;color:#fff;border-color:#ef4444';
        btnOK.textContent = 'Conferma Slot prenotato';
        btnOK.addEventListener('click', () => bookForClient(SLOT_TYPES.GROUP_CLASS));
        btnRow.appendChild(btnOK);
    } else {
        const btnAut = document.createElement('button');
        btnAut.className = 'extra-picker-btn personal-training';
        btnAut.textContent = 'Autonomia';
        btnAut.addEventListener('click', () => bookForClient('personal-training'));

        const btnGrp = document.createElement('button');
        btnGrp.className = 'extra-picker-btn small-group';
        btnGrp.textContent = 'Lezione di Gruppo';
        btnGrp.addEventListener('click', () => bookForClient('small-group'));

        btnRow.appendChild(btnAut);
        btnRow.appendChild(btnGrp);
    }
    btnRow.appendChild(btnBack);

    confirmEl.innerHTML = `
        <div style="font-size:13px;margin-bottom:8px">
            <strong>${_escHtml(client.name)}</strong>
            <span style="color:#888;font-size:11px"> · ${_escHtml(client.email || client.whatsapp || '')}</span>
        </div>
    `;
    confirmEl.appendChild(btnRow);
}

async function bookForClient(slotType) {
    console.log('[bookForClient] start', { slotType, state: _clientPickerState });
    // Guard: l'utente deve avere accesso UI admin in base al RUOLO verificato
    // server-side (owner/admin/staff), non al flag sessionStorage. Il backend
    // verifica comunque is_org_admin()/RLS sulle RPC.
    if (typeof hasAdminUiAccess === 'function' ? !hasAdminUiAccess() : sessionStorage.getItem('adminAuth') !== 'true') {
        console.warn('[bookForClient] accesso admin non valido per il ruolo corrente');
        showToast('Sessione admin scaduta. Ricarica la pagina e accedi di nuovo.', 'error');
        return;
    }
    const { date, time, client } = _clientPickerState;
    if (!client) {
        console.warn('[bookForClient] no client in picker state');
        showToast('Seleziona prima un cliente dalla lista.', 'error');
        return;
    }

    // Cerca user_id del cliente in Supabase (per reminders push)
    let clientUserId = null;
    if (typeof supabaseClient !== 'undefined' && client.email) {
        try {
            const { data: prof } = await _queryWithTimeout(supabaseClient
                .from('profiles').select('id').eq('email', (client.email || '').toLowerCase()).maybeSingle());
            clientUserId = prof?.id || null;
        } catch {}
    }

    // Calcola dateDisplay
    const [y, m, d] = date.split('-').map(Number);
    const dt = new Date(y, m - 1, d);
    const days = ['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato'];
    const months = ['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto','settembre','ottobre','novembre','dicembre'];
    const dateDisplay = `${days[dt.getDay()]} ${d} ${months[m - 1]}`;

    const booking = {
        name:        client.name,
        email:       client.email || '',
        whatsapp:    client.whatsapp || '',
        notes:       '',
        date,
        time,
        slotType,
        dateDisplay,
    };

    // ── Flusso standard (tutti i tipi, incluse più persone su group-class) ──
    // NON gonfiare automaticamente la capienza override (anti-pattern §12): se lo
    // slot è pieno lasciamo fallire book_slot con 'slot_full' e mostriamo il
    // messaggio. L'aumento posti resta un'azione esplicita dell'admin (pulsante ＋
    // → "Aggiungi posto allo slot").
    const result = await BookingStorage.saveBookingForClient(booking, clientUserId);
    if (!result.ok) {
        if (result.error === 'slot_full') showToast('Slot pieno: usa il pulsante ＋ per aggiungere un posto, poi riprova.', 'error');
        else showToast('⚠️ Errore: prenotazione non riuscita. Riprova.', 'error');
        if (window._currentAdminDate) renderAdminDayView(window._currentAdminDate);
        return;
    }
    BookingStorage.fulfillPendingCancellations(date, time);

    showToast(`Prenotazione aggiunta per ${client.name}`, 'success');
    invalidateStatsCache();
    if (window._currentAdminDate) renderAdminDayView(window._currentAdminDate);
}

function removeExtraSpotFromSlot(date, time, extraType) {
    if (!BookingStorage.removeExtraSpot(date, time, extraType)) {
        showToast('Prima cancella la prenotazione in corso, poi potrai rimuovere lo slot extra.', 'error');
        return;
    }
    if (window._currentAdminDate) renderAdminDayView(window._currentAdminDate);
}


// Helper: icona notifiche push (solo se disattivate)
function _pushIcon(userRecord) {
    if (userRecord?.pushEnabled) return '';
    return '<span title="Notifiche non attive" style="font-size:13px">🔕</span>';
}


// Helper: HTML di una singola card partecipante
function _buildParticipantCard(booking) {
    const isPaid = booking.paid || false;
    const isCancelPending = booking.status === 'cancellation_requested';
    // Importo da pagare: prenotazioni passate non pagate (base bookings/payments).
    // Nessun credito da sottrarre (sistema credito/bonus rimosso).
    const unpaidAmount = Math.round(getUnpaidAmountForContact(booking.whatsapp, booking.email) * 100) / 100;
    const hasDebts = unpaidAmount > 0;
    const cancelPendingBadge = isCancelPending
        ? `<div class="admin-cancel-pending-badge">⏳ Annullamento richiesto</div>` : '';
    const userRecord = _getUserRecord(booking.email, booking.whatsapp);
    const certScad  = userRecord?.certificatoMedicoScadenza;
    const assicScad = userRecord?.assicurazioneScadenza;
    const hasCF     = !!userRecord?.codiceFiscale;
    const emE = _escAttr(booking.email || '');
    const waE = _escAttr(booking.whatsapp || '');
    const nmE2 = _escAttr(booking.name);
    const _todayStr   = _localDateStr();
    const _today30    = new Date(); _today30.setDate(_today30.getDate() + 30);
    const _today30Str = _localDateStr(_today30);

    // Cert medico
    let certBadge = '';
    if (BookingBadgesStorage.getShowCert()) {
        const certMissing = !certScad;
        if (certMissing) {
            certBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" onclick="openCertModal(this,'${emE}','${waE}','${nmE2}')">🏥 Imposta Cert. Med</div>`;
        } else if (certScad < _todayStr) {
            const [cy, cm, cd] = certScad.split('-');
            certBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" onclick="openCertModal(this,'${emE}','${waE}','${nmE2}')">🏥 Cert. scaduto il ${cd}/${cm}/${cy}</div>`;
        } else if (certScad <= _today30Str) {
            const [cy, cm, cd] = certScad.split('-');
            certBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" style="background:#fffbeb;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b" onclick="openCertModal(this,'${emE}','${waE}','${nmE2}')">⏳ Cert. Med scade il ${cd}/${cm}/${cy}</div>`;
        }
    }

    // Anagrafica incompleta (CF, indirizzo)
    let cfBadge = '';
    if (BookingBadgesStorage.getShowAnag()) {
        const anagMissing = !hasCF || !userRecord?.indirizzoVia || !userRecord?.indirizzoPaese || !userRecord?.indirizzoCap;
        if (anagMissing) {
            cfBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" style="background:#fef3c7;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b" onclick="openEditClientPopup(0,'${waE}','${emE}','${nmE2}')">📋 Completa anagrafica</div>`;
        }
    }

    // Documento firmato
    let docBadge = '';
    if (BookingBadgesStorage.getShowDoc() && !userRecord?.documentoFirmato) {
        docBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" onclick="openEditClientPopup(0,'${waE}','${emE}','${nmE2}')">📝 Documento non firmato</div>`;
    }

    let assicBadge = '';
    if (BookingBadgesStorage.getShowAssic()) {
        if (!assicScad) {
            assicBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" style="background:#fef3c7;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b" onclick="openAssicModal(this,'${emE}','${waE}','${nmE2}')">📋 Imposta Assicurazione</div>`;
        } else if (assicScad < _todayStr) {
            const [ay, am, ad] = assicScad.split('-');
            assicBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" onclick="openAssicModal(this,'${emE}','${waE}','${nmE2}')">📋 Assic. scaduta il ${ad}/${am}/${ay}</div>`;
        } else if (assicScad <= _today30Str) {
            const [ay, am, ad] = assicScad.split('-');
            assicBadge = `<div class="cert-expired-badge cert-expired-badge--clickable" style="background:#fffbeb;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b" onclick="openAssicModal(this,'${emE}','${waE}','${nmE2}')">⏳ Assic. scade il ${ad}/${am}/${ay}</div>`;
        }
    }
    const wa  = _escAttr(booking.whatsapp);
    const em  = _escAttr(booking.email);
    const nm  = _escAttr(booking.name);
    const initials = _participantInitials(booking.name);
    const avatarHue = _participantAvatarHue(booking.name);
    // Etichetta di stato sotto il nome: riferita alla SINGOLA lezione di questa card,
    // NON al saldo aggregato del contatto (code review 2 / port Thomas).
    //   • "Pagato"  → questa prenotazione è saldata (booking.paid; niente creditApplied qui);
    //   • "Da pagare" → SOLO se la lezione è già iniziata/passata (bookingHasPassed) e non pagata;
    //   • lezione futura non pagata → nessuna etichetta (il debito pregresso non è dovuto
    //     finché la lezione non è arrivata).
    // Il chip del saldo a destra resta AGGREGATO (saldo complessivo del contatto, tap = incasso).
    const saldoStatus = isCancelPending
        ? ''
        : (isPaid
            ? `<span class="participant-saldo-status paid">Pagato</span>`
            : (bookingHasPassed(booking)
                ? `<span class="participant-saldo-status owes">Da pagare</span>`
                : ''));
    const saldoChip = hasDebts
        ? `<span class="saldo-chip owes" onclick="openDebtPopup('${wa}','${em}','${nm}')">−€${unpaidAmount}</span>`
        : `<span class="saldo-chip zero">€0</span>`;
    return `
        <div class="admin-participant-card${isCancelPending ? ' cancel-pending' : ''}">
            <div class="participant-card-content">
                <div class="participant-row">
                    <div class="participant-avatar" data-hue="${avatarHue}">${initials}</div>
                    <div class="participant-row-main">
                        <div class="participant-name">${_escHtml(booking.name)} ${_pushIcon(userRecord)}</div>
                        ${cancelPendingBadge}
                        <div class="participant-saldo-line">${saldoStatus}${saldoChip}</div>
                    </div>
                    <button class="btn-delete-booking" onclick="deleteBooking('${booking.id}','${nm}')">✕</button>
                </div>
                ${certBadge}${cfBadge}${assicBadge}${docBadge}
                ${booking.notes ? `<div class="participant-notes">${_escHtml(booking.notes)}</div>` : ''}
            </div>
        </div>`;
}

// Helper: iniziali per avatar partecipante (max 2 lettere maiuscole)
function _participantInitials(name) {
    if (!name) return '?';
    const parts = String(name).trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return '?';
    if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
    return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

// Helper: hue stabile dal nome → 6 varianti colore avatar
function _participantAvatarHue(name) {
    const s = String(name || '');
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
    return h % 6;
}

// Helper: markup di un pip colorato col colore reale del tipo slot
// (slot_types.color via getSlotColor). I pip "empty" usano lo stesso colore
// attenuato. Lo stile inline ha la precedenza sulle regole .pip in admin.css.
function _pipMarkup(slotType, empty) {
    const color = (typeof getSlotColor === 'function') ? getSlotColor(slotType) : '#8B5CF6';
    const style = empty ? `background:${color};opacity:.28` : `background:${color}`;
    return `<span class="pip${empty ? ' empty' : ''}" style="${style}"></span>`;
}

// Capacità giornaliera totale (somma capacity di tutti gli slot programmati)
function _adminDayCapacity(dateInfo) {
    try {
        if (typeof getScheduleForDate !== 'function' || typeof BookingStorage?.getEffectiveCapacity !== 'function') return 0;
        const slots = getScheduleForDate(dateInfo.formatted, dateInfo.dayName) || [];
        let total = 0;
        for (const s of slots) {
            const cap = BookingStorage.getEffectiveCapacity(dateInfo.formatted, s.time, s.type) || 0;
            total += cap;
        }
        return total;
    } catch { return 0; }
}

// Helper: griglia partecipanti per una lista di booking
function _buildParticipantsSection(bookings) {
    if (!bookings || bookings.length === 0)
        return '<div class="empty-slot">Nessuna prenotazione</div>';
    return '<div class="admin-participants-grid">' + bookings.map(_buildParticipantCard).join('') + '</div>';
}

// ────────────────────────────────────────────────────────────────────────────

function renderAdminDayView(dateInfo) {
    window._currentAdminDate = dateInfo;
    BookingStorage.processPendingCancellations();
    // Ripulisci eventuali picker orfani (modal montati su <body>) lasciati
    // dal render precedente quando si cambia giorno. Rimuovi anche la classe
    // 'extra-picker-open' dal body: se resta, overflow:hidden blocca lo scroll
    // e nasconde dock/FAB (succedeva dopo bookForClient → re-render).
    document.querySelectorAll('body > .extra-picker').forEach(p => p.remove());
    document.body.classList.remove('extra-picker-open');
    const dayView = document.getElementById('adminDayView');
    dayView.innerHTML = '';

    const scheduledSlots = getScheduleForDate(dateInfo.formatted, dateInfo.dayName);

    if (scheduledSlots.length === 0) {
        dayView.innerHTML = '<div class="empty-slot">Nessuna lezione programmata per questo giorno</div>';
        return;
    }

    // Reconcile crediti: gestito da pg_cron (ogni minuto) + wrapper on-load in admin.html.
    // Nessuna RPC qui per evitare fan-out N-chiamate ad ogni click giorno.

    scheduledSlots.forEach(scheduledSlot => {
        const slotCard = createAdminSlotCard(dateInfo, scheduledSlot);
        dayView.appendChild(slotCard);
    });

}

function _scrollToCurrentAdminSlot(container) {
    const now = new Date();
    const nowMinutes = now.getHours() * 60 + now.getMinutes();
    const cards = container.querySelectorAll('.admin-slot-card');
    for (const card of cards) {
        const timeEl = card.querySelector('.admin-slot-time');
        if (!timeEl) continue;
        const text = timeEl.textContent.replace('🕐', '').trim();
        const parsed = _parseSlotTime(text);
        if (!parsed) continue;
        const slotEnd = parsed.endH * 60 + parsed.endM;
        if (slotEnd > nowMinutes) {
            // Espandi lo slot corrente + persisti lo stato
            card.classList.add('is-expanded');
            const dateInfo = window._currentAdminDate;
            if (dateInfo?.formatted && text && typeof _expandedAdminSlots !== 'undefined') {
                _expandedAdminSlots.add(`${dateInfo.formatted}|${text}`);
            }
            setTimeout(() => {
                // Dual-mode shell iOS: col body-scroller pageYOffset è 0 e lo scroll
                // vero è su document.body → leggi e scrolla entrambi (l'inattivo è no-op).
                const curScroll = window.pageYOffset || document.body.scrollTop || 0;
                const y = card.getBoundingClientRect().top + curScroll - window.innerHeight * 0.35;
                window.scrollTo({ top: y, behavior: 'smooth' });
                document.body.scrollTo({ top: y, behavior: 'smooth' });
            }, 100);
            return;
        }
    }
}

// Stato globale degli slot espansi (chiave: "YYYY-MM-DD|HH:MM - HH:MM").
const _expandedAdminSlots = (window._expandedAdminSlots = window._expandedAdminSlots || new Set());

function createAdminSlotCard(dateInfo, scheduledSlot) {
    const slotCard = document.createElement('div');
    slotCard.className = `admin-slot-card ${scheduledSlot.type}`;

    const date     = dateInfo.formatted;
    const timeSlot = scheduledSlot.time;
    const mainType = scheduledSlot.type;
    const extras   = scheduledSlot.extras || [];

    // Escape per uso in onclick inline
    const dE = _escAttr(date);
    const tE = _escAttr(timeSlot);

    // Tutti i booking per questa data+ora (tutti i tipi)
    const allBookings = BookingStorage.getBookingsForSlot(date, timeSlot);
    // Booking reali (escludi sintetici _avail_ per la visualizzazione partecipanti)
    const realBookings = allBookings.filter(b => !b.id?.startsWith('_avail_'));

    // Info slot principale (usa allBookings per conteggio corretto posti occupati)
    const mainEffCap   = BookingStorage.getEffectiveCapacity(date, timeSlot, mainType);
    const mainConfirmed = allBookings.filter(b => b.status === 'confirmed' && (!b.slotType || b.slotType === mainType)).length;

    // Tipi extra diversi dal principale
    const extraTypes = [...new Set(extras.map(e => e.type).filter(t => t !== mainType))];
    const hasMixedExtras = extraTypes.length > 0;

    const pickerId = 'xpick-' + date + '-' + timeSlot.replace(/[: -]/g, '');

    // Conteggio booking "slot prenotato" attivi → opzione disponibile solo
    // quando lo slot è group-class e c'è già 1 o 0 persone (max 2 totale).
    const groupClassActiveCount = allBookings.filter(b =>
        (b.status === 'confirmed' || b.status === 'cancellation_requested')
        && b.slotType === SLOT_TYPES.GROUP_CLASS
    ).length;
    const canAddSlotPren  = mainType === SLOT_TYPES.GROUP_CLASS && groupClassActiveCount === 1;

    const slotPrenBtnHTML = canAddSlotPren
        ? `<button class="extra-picker-btn" style="background:#ef4444;color:#fff;border-color:#ef4444" onclick="openClientBookingPickerForSlotPrenotato('${dE}','${tE}','${pickerId}')">Slot prenotato</button>`
        : '';

    // ── Capacità + pip per tipo ─────────────────────────────────────────────
    // capStr e pips: tutti i tipi tranne 'cleaning'. Group-class: base capacity=0
    // → mostra almeno 1 posto (capienza decisa dal server).
    const showPips = mainType !== 'cleaning';
    let displayCap;
    if (mainType === 'group-class') {
        displayCap = Math.max(mainEffCap, mainConfirmed, 1);
    } else {
        displayCap = mainEffCap;
    }

    // Capacita' e prenotati TOTALI (main + tutti gli extra di tipo diverso)
    let totalCap = displayCap;
    for (const t of extraTypes) {
        totalCap += BookingStorage.getEffectiveCapacity(date, timeSlot, t) || 0;
    }
    const totalConfirmed = realBookings.filter(b => b.status === 'confirmed').length;

    const slotsLabel = totalCap === 1 ? 'posto' : 'posti';
    const capStr = (mainType !== 'cleaning' && totalCap > 0)
        ? `${totalConfirmed}/${totalCap} ${slotsLabel}`
        : '';

    // Pips: prima quelli del tipo principale (colore del tipo), poi quelli
    // di ogni tipo extra (es. small-group con +1 Autonomia → 5 gialli + 1 verde).
    const pipParts = [];
    if (showPips && displayCap > 0) {
        for (let i = 0; i < displayCap; i++) {
            pipParts.push(_pipMarkup(mainType, i >= mainConfirmed));
        }
    }
    for (const t of extraTypes) {
        const ec = BookingStorage.getEffectiveCapacity(date, timeSlot, t);
        const eConf = realBookings.filter(b => b.slotType === t && b.status === 'confirmed').length;
        for (let i = 0; i < ec; i++) {
            pipParts.push(_pipMarkup(t, i >= eConf));
        }
    }
    const capPipsHTML = pipParts.length > 0 && pipParts.length <= 12
        ? `<div class="admin-slot-pips" aria-hidden="true">${pipParts.join('')}</div>`
        : '';

    // ── Header ──────────────────────────────────────────────────────────────
    // Cleaning: niente capStr/pips → mostra etichetta nello stesso punto.
    const cleaningHeaderHTML = mainType === 'cleaning'
        ? '<div class="admin-slot-cleaning">🧹 Pulizia</div>'
        : '';
    const headerHTML = `
        <div class="admin-slot-header">
            <div class="admin-slot-time">🕐 ${timeSlot}</div>
            ${capStr ? `<div class="admin-slot-capacity">${capStr}</div>` : ''}
            ${capPipsHTML}
            ${cleaningHeaderHTML}
            <button class="btn-add-extra btn-add-extra--inline" onclick="event.stopPropagation(); toggleExtraPicker('${dE}','${tE}')" title="Aggiungi posto extra" aria-label="Aggiungi posto">＋</button>
            <span class="admin-slot-chev" aria-hidden="true"></span>
        </div>`;

    // Picker modal: posizionato fixed → la posizione DOM non conta.
    const pickerHTML = `
        <div id="${pickerId}" class="extra-picker" style="display:none;" onclick="toggleExtraPicker('${dE}','${tE}')">
            <div class="extra-picker-content" onclick="event.stopPropagation()">
                <div class="extra-picker-title">Aggiungi posto allo slot</div>
                <button class="extra-picker-btn personal-training" onclick="addExtraSpotToSlot('${dE}','${tE}','personal-training')">Autonomia</button>
                <button class="extra-picker-btn small-group" onclick="addExtraSpotToSlot('${dE}','${tE}','small-group')">Lezione di Gruppo</button>
                ${slotPrenBtnHTML}
                <button class="extra-picker-btn" style="background:#6c5ce7;color:#fff" onclick="openClientBookingPicker('${dE}','${tE}','${pickerId}')">Persona</button>
                <button class="extra-picker-cancel" onclick="toggleExtraPicker('${dE}','${tE}')">Annulla</button>
            </div>
        </div>`;

    // ── Extras bar ──────────────────────────────────────────────────────────
    let extrasBarHTML = '';
    if (extras.length > 0) {
        const allExtraTypes = [...new Set(extras.map(e => e.type))];
        const badges = allExtraTypes.map(t => {
            const cnt = extras.filter(e => e.type === t).length;
            return `<span class="extra-badge ${t}">${getSlotName(t)} ×${cnt}
                <button class="btn-remove-extra" onclick="removeExtraSpotFromSlot('${dE}','${tE}','${t}')" title="Rimuovi un posto">−</button>
            </span>`;
        }).join('');
        extrasBarHTML = `<div class="admin-extras-bar">Extra: ${badges}</div>`;
    }

    // ── Participants ─────────────────────────────────────────────────────────
    let participantsHTML;
    if (mainType === 'cleaning' && !hasMixedExtras) {
        // Cleaning puro: l'etichetta "🧹 Pulizia" è già nell'header.
        participantsHTML = '';
    } else if (!hasMixedExtras) {
        // Vista unificata (nessun extra o solo extra dello stesso tipo)
        const mainBookings = realBookings.filter(b => !b.slotType || b.slotType === mainType);
        participantsHTML = _buildParticipantsSection(mainBookings);
    } else {
        // Vista divisa in colonne
        const mainBookings = realBookings.filter(b => !b.slotType || b.slotType === mainType);
        const leftColLabel = getSlotName(mainType);
        const leftCol = `
            <div class="split-column">
                <div class="split-col-title ${mainType}">${leftColLabel}</div>
                ${_buildParticipantsSection(mainBookings)}
            </div>`;
        const rightCols = extraTypes.map(t => {
            const eb = realBookings.filter(b => b.slotType === t);
            const ec = BookingStorage.getEffectiveCapacity(date, timeSlot, t);
            const eConf = eb.filter(b => b.status === 'confirmed').length;
            return `
                <div class="split-col-divider-v"></div>
                <div class="split-column">
                    <div class="split-col-title ${t}">${getSlotName(t)} ${eConf}/${ec}</div>
                    ${_buildParticipantsSection(eb)}
                </div>`;
        }).join('');
        participantsHTML = `<div class="admin-slot-split">${leftCol}${rightCols}</div>`;
    }

    // Picker FUORI dal body: il body collassato (mobile) ha display:none,
    // che propaga ai figli → con il picker dentro al body, anche il modal
    // restava invisibile quando la card era chiusa. Ora il picker è
    // sibling del body, sempre disponibile a prescindere dallo stato.
    slotCard.innerHTML = headerHTML
        + pickerHTML
        + `<div class="admin-slot-body">${extrasBarHTML}${participantsHTML}</div>`;

    // Salva HTML iniziale del picker per restore dopo modalità ricerca
    const pickerEl = slotCard.querySelector('.extra-picker');
    if (pickerEl) {
        pickerEl._initialHtml = pickerEl.innerHTML;
        // Rimuovi eventuale vecchio picker per lo stesso slot (re-render):
        // se restasse, getElementById ritornerebbe il primo (sbagliato).
        const stale = document.getElementById(pickerId);
        if (stale && stale !== pickerEl && stale.parentNode === document.body) {
            stale.remove();
        }
        // Sposta il modal direttamente sotto <body>: .admin-day-view ha
        // position:relative + overflow:hidden su desktop → crea uno
        // stacking context che confina il modal sotto la sticky week-bar
        // (z-index:12). Al body root il suo z-index 9999 e' supremo.
        document.body.appendChild(pickerEl);
    }

    // Stato collapse/expand: ripristina dallo stato globale
    const slotKey = `${date}|${timeSlot}`;
    if (_expandedAdminSlots.has(slotKey)) slotCard.classList.add('is-expanded');

    // Toggle on header click — escludi click su bottoni e pickers
    const headerEl = slotCard.querySelector('.admin-slot-header');
    if (headerEl) {
        headerEl.addEventListener('click', (e) => {
            if (e.target.closest('button, .extra-picker, input, select, textarea, a')) return;
            const expanded = slotCard.classList.toggle('is-expanded');
            if (expanded) _expandedAdminSlots.add(slotKey);
            else _expandedAdminSlots.delete(slotKey);
        });
    }

    // Wrap per swipe-to-reveal su mobile
    const wrap = document.createElement('div');
    wrap.className = 'admin-slot-card-wrap';
    wrap.appendChild(slotCard);

    const actions = document.createElement('div');
    actions.className = 'admin-slot-actions';
    actions.innerHTML = `<button class="btn-add-extra btn-add-extra--swipe" onclick="toggleExtraPicker('${dE}','${tE}')" title="Aggiungi posto extra" aria-label="Aggiungi posto">＋</button>`;
    wrap.appendChild(actions);

    return wrap;
}


async function deleteBooking(bookingId, bookingName) {
    const bookings = [...BookingStorage.getAllBookings()];
    const index = bookings.findIndex(b => b.id === bookingId);
    if (index === -1) return;

    const booking = bookings[index];

    // Modello nuovo: nessun rimborso/credito/bonus/mora. La cancellazione è
    // un semplice cambio stato → 'cancelled' (+ conversione group-class → small-group
    // lato server). Eventuali rimborsi/penali si gestiscono come pagamenti dedicati
    // nel ledger 'payments', non più qui.
    if (!await showConfirm(`Confermare l'annullamento della prenotazione di ${bookingName}?`)) return;

    const useSupabase = typeof supabaseClient !== 'undefined' && booking._sbId;

    // Helper: cancellazione via RPC cancel_booking (atomica, group->small lato server).
    async function _cancelViaRpc() {
        const { data, error } = await _rpcWithTimeout(
            supabaseClient.rpc('cancel_booking', { p_booking_id: booking._sbId })
        );
        if (error) throw new Error(error.message);
        if (data && !data.success) throw new Error(data.error || 'Errore sconosciuto');

        // Riallinea la cache locale con Supabase (stato + eventuale override slot)
        await BookingStorage.syncFromSupabase();

        invalidateStatsCache();
        if (selectedAdminDay) renderAdminDayView(selectedAdminDay);
        if (typeof showToast === 'function') showToast('✅ Prenotazione annullata con successo.', 'success', 4000);
    }

    // Helper: fallback locale (offline / senza _sbId). Solo cambio stato +
    // conversione group-class → small-group (stessa logica di cancel_booking).
    async function _cancelLocal() {
        const ok = await BookingStorage.cancelAndConvertSlot(booking.id);
        if (!ok) {
            // Feedback esplicito: un return silenzioso faceva credere all'admin
            // di aver annullato mentre la prenotazione restava confermata.
            if (typeof showToast === 'function') showToast('⚠️ Annullamento non riuscito. Riprova.', 'error', 5000);
            return false;
        }
        invalidateStatsCache();
        if (selectedAdminDay) renderAdminDayView(selectedAdminDay);
        if (typeof showToast === 'function') showToast('✅ Prenotazione annullata con successo.', 'success', 4000);
        return true;
    }

    if (useSupabase) {
        _cancelViaRpc().catch(err => {
            console.error('[deleteBooking] RPC error:', err);
            if (typeof showToast === 'function') showToast('⚠️ Errore: ' + err.message, 'error', 5000);
        });
    } else {
        _cancelLocal().catch(err => {
            console.error('[deleteBooking local] error:', err);
            if (typeof showToast === 'function') showToast('⚠️ Errore: ' + err.message, 'error', 5000);
        });
    }
}
