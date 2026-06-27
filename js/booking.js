/**
 * booking.js — Form/modal di prenotazione del cliente (lato pubblico, pagina prenotazioni).
 *
 * COSA FA
 * Gestisce il modal con cui il cliente prenota uno slot: mostra info slot e iscritti visibili,
 * applica i gating (certificato medico / assicurazione), invia la prenotazione, mostra la
 * conferma e genera gli inviti calendario (ICS / Google Calendar).
 *
 * COME FUNZIONA
 * - Setup: initBookingForm() collega il submit (#bookingForm → handleBookingSubmit), la chiusura
 *   con Escape/overlay/swipe-down (.modal-box) del #bookingModal.
 * - Iscritti slot: _loadSlotAttendees() chiama la RPC pubblica supabaseClient.rpc('get_slot_attendees',
 *   { p_org_slug, p_date, p_time }) con anti-race (_attendeesLoadSeq), timeout 8s (AbortController),
 *   retry singolo con ensureValidSession() e link "Riprova".
 * - Apertura: openBookingModal(dateInfo, timeSlot, slotType, remainingSpots) popola badge/info
 *   (#modalSlotTypeBadge, #modalSlotDay, #modalSlotTime, #modalSlotSpots) e resetta il form.
 * - Submit: handleBookingSubmit() applica i gating cert/assicurazione (CertBookingStorage/
 *   AssicBookingStorage) e invia con BookingStorage.saveBooking({..., orgSlug: window._orgSlug}).
 *   NESSUN pre-check capienza lato client: l'autorità è la RPC server-side `book_slot` (data.js).
 * - Conferma e calendario: showConfirmation() (usa _confirmedBooking), downloadIcs()/
 *   downloadCancelIcs() (ICS con VTIMEZONE), googleCalendarUrl(); il fuso è per-org via
 *   _orgTimezone() (OrgSettings 'locale.timezone'). notificaPrenotazione() invia la notifica.
 *
 * CONNESSIONI
 * - Persistenza/RPC via BookingStorage (js/data.js → RPC `book_slot`, tabella bookings, org-scoped).
 * - Org pubblica risolta dallo slug in window._orgSlug (client anonimo, niente JWT).
 * - Impostazioni per-org via OrgSettings; helper condivisi _escHtml, getSlotName, spotsColorClass.
 */
// Booking form / modal functionality
let _confirmedBooking = null; // used by downloadIcs button in showConfirmation

// Timezone IANA per-org (es. 'Europe/Rome'), letto da OrgSettings con guard.
// Usato per ICS/Google Calendar (TZID/ctz) — ogni tenant può avere un fuso diverso.
function _orgTimezone() {
    if (typeof OrgSettings !== 'undefined') {
        return OrgSettings.getString('locale.timezone', 'Europe/Rome');
    }
    return 'Europe/Rome';
}

function initBookingForm() {
    const form = document.getElementById('bookingForm');
    form.addEventListener('submit', handleBookingSubmit);

    // Close modal on Escape key
    document.addEventListener('keydown', e => {
        if (e.key === 'Escape') closeBookingModal();
    });

    // Swipe-down to close on mobile (works on form and confirmation screens)
    const box = document.getElementById('bookingModal').querySelector('.modal-box');
    let startY = 0;
    let swipeActive = false;
    box.addEventListener('touchstart', e => {
        // Only activate swipe when starting in the top 40px (drag handle area)
        const boxTop = box.getBoundingClientRect().top;
        swipeActive = (e.touches[0].clientY - boxTop) < 40;
        if (swipeActive) {
            startY = e.touches[0].clientY;
            box.style.transition = 'none';
        }
    }, { passive: true });
    box.addEventListener('touchmove', e => {
        if (!swipeActive) return;
        const dy = e.touches[0].clientY - startY;
        if (dy > 0) box.style.transform = `translateY(${dy}px)`;
    }, { passive: true });
    box.addEventListener('touchend', e => {
        if (!swipeActive) return;
        const dy = e.changedTouches[0].clientY - startY;
        box.style.transition = '';
        if (dy > 80) {
            box.style.transform = `translateY(100%)`;
            setTimeout(closeBookingModal, 200);
        } else {
            box.style.transform = '';
        }
        swipeActive = false;
    });
}

// Caricamento iscritti di uno slot. Estratto da openBookingModal per gestire:
//  - anti-race: un contatore modulo-level scarta le risposte di slot precedenti se nel
//    frattempo si riapre il modal su un altro slot;
//  - retry automatico: al primo fallimento rinfresca la sessione e ritenta una volta (la
//    tab può tornare da background con token scaduto); al secondo mostra "Riprova";
//  - timeout RPC 8s: col token già letto da storage, una RPC appesa è inutile.
let _attendeesLoadSeq = 0;
function _loadSlotAttendees(attendeesList, slotDate, slotTime, isRetry) {
    if (!attendeesList) return;
    const mySeq = ++_attendeesLoadSeq;
    attendeesList.innerHTML = '<li style="color:#9ca3af;font-style:italic">Caricamento...</li>';

    const _ac = new AbortController();
    const _t = setTimeout(() => _ac.abort(), 8000);

    supabaseClient.rpc('get_slot_attendees', {
        p_org_slug: window._orgSlug,
        p_date: slotDate,
        p_time: slotTime
    }).abortSignal(_ac.signal).then(({ data, error }) => {
        clearTimeout(_t);
        if (mySeq !== _attendeesLoadSeq) return; // slot cambiato nel frattempo → scarta
        if (error) throw error;                  // niente più "errore == lista vuota": il catch gestisce
        if (!data || data.length === 0) {
            attendeesList.innerHTML = '<li class="slot-attendees-empty">Nessuna persona visibile per questo slot.</li>';
        } else {
            attendeesList.innerHTML = data.map(a => `<li>👤 ${_escHtml(a.name)}</li>`).join('');
        }
    }).catch(async (err) => {
        clearTimeout(_t);
        if (mySeq !== _attendeesLoadSeq) return; // slot cambiato → non sovrascrivere l'UI corrente
        console.warn('[Booking] get_slot_attendees fallita:', err && err.message);
        if (!isRetry) {
            // Primo fallimento: la sessione potrebbe essere scaduta (tab tornata da background).
            // Rinfrescala e ritenta una volta sola.
            if (typeof ensureValidSession === 'function') {
                try { await ensureValidSession(); } catch (_) {}
            }
            if (mySeq !== _attendeesLoadSeq) return; // slot cambiato durante il refresh
            _loadSlotAttendees(attendeesList, slotDate, slotTime, true);
            return;
        }
        // Secondo fallimento: messaggio + link "Riprova" che rilancia il load da capo.
        attendeesList.innerHTML = '<li class="slot-attendees-empty">Impossibile caricare gli iscritti. <a href="#" class="slot-attendees-retry">Riprova</a></li>';
        const _retry = attendeesList.querySelector('.slot-attendees-retry');
        if (_retry) _retry.addEventListener('click', (e) => {
            e.preventDefault();
            _loadSlotAttendees(attendeesList, slotDate, slotTime);
        });
    });
}

function openBookingModal(dateInfo, timeSlot, slotType, remainingSpots) {
    // Populate slot info
    const badge = document.getElementById('modalSlotTypeBadge');
    badge.textContent = getSlotName(slotType);
    badge.className = `modal-slot-badge ${slotType}`;

    document.getElementById('modalSlotDay').textContent = `${dateInfo.dayName} ${dateInfo.displayDate}`;
    document.getElementById('modalSlotTime').textContent = `🕐 ${timeSlot}`;

    const spotsEl = document.getElementById('modalSlotSpots');
    spotsEl.textContent = remainingSpots <= 0 ? 'Completo' : `${remainingSpots} ${remainingSpots === 1 ? 'disponibile' : 'disponibili'}`;
    spotsEl.className = `modal-spots ${remainingSpots <= 0 ? 'spots-full' : spotsColorClass(remainingSpots)}`;

    // Reset form and hide confirmation, restore slot info
    document.getElementById('bookingForm').reset();
    document.getElementById('confirmationMessage').style.display = 'none';
    document.getElementById('modalSlotInfo').style.display = '';

    // Check login
    const user = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
    const loginPrompt = document.getElementById('loginPrompt');

    // Rimuovi eventuale blocco precedente
    const oldBlock = document.getElementById('bookingBlockMessage');
    if (oldBlock) oldBlock.remove();

    if (!user) {
        // Not logged in: show login prompt, hide form
        loginPrompt.style.display = 'block';
        document.getElementById('bookingForm').style.display = 'none';
    } else {
        loginPrompt.style.display = 'none';

        // Check blocchi certificato/assicurazione PRIMA di mostrare il form
        const _certScad  = user.medical_cert_expiry || '';
        const _assicScad = user.insurance_expiry || '';
        const _today     = _localDateStr();
        let blockMsg = null;
        if (typeof isAnagraficaComplete === 'function' && !isAnagraficaComplete(user))
            blockMsg = "Completa l'anagrafica prima di prenotare. Vai in \"Le mie prenotazioni\" e apri il profilo.";
        else if (!_certScad && typeof CertBookingStorage !== 'undefined' && CertBookingStorage.getBlockIfNotSet())
            blockMsg = 'Non hai inserito la data di scadenza del certificato medico. Contatta il tuo PT.';
        else if (_certScad && _certScad < _today && typeof CertBookingStorage !== 'undefined' && CertBookingStorage.getBlockIfExpired())
            blockMsg = 'Il tuo certificato medico è scaduto. Contatta il tuo PT per aggiornarlo.';
        else if (!_assicScad && typeof AssicBookingStorage !== 'undefined' && AssicBookingStorage.getBlockIfNotSet())
            blockMsg = 'Non hai inserito la data di scadenza dell\'assicurazione. Contatta il tuo PT.';
        else if (_assicScad && _assicScad < _today && typeof AssicBookingStorage !== 'undefined' && AssicBookingStorage.getBlockIfExpired())
            blockMsg = 'La tua assicurazione è scaduta. Contatta il tuo PT per aggiornarla.';

        if (blockMsg) {
            document.getElementById('bookingForm').style.display = 'none';
            const blockEl = document.createElement('div');
            blockEl.id = 'bookingBlockMessage';
            blockEl.style.cssText = 'padding:24px;text-align:center;color:#c0392b;font-weight:600;line-height:1.5';
            blockEl.textContent = '⚠️ ' + blockMsg;
            document.getElementById('bookingForm').parentNode.insertBefore(blockEl, document.getElementById('bookingForm'));
        } else {
            // Logged in, nessun blocco statico: show form, pre-fill fields, hide user fields
            document.getElementById('bookingForm').style.display = 'flex';
            document.getElementById('name').value     = user.name     || '';
            document.getElementById('email').value    = user.email    || '';
            document.getElementById('whatsapp').value = user.whatsapp || '';
            const userFields = document.getElementById('bookingUserFields');
            if (userFields) userFields.style.display = 'none';
        }
    }

    // Reset submit button (potrebbe essere rimasto disabilitato da un submit precedente)
    const _submitBtn = document.querySelector('#bookingForm button[type="submit"]');
    if (_submitBtn) { _submitBtn.disabled = false; setLoading(_submitBtn, false); }

    // Slot pieno: nascondi form, mostra solo persone iscritte
    const _slotFull = remainingSpots <= 0;
    if (_slotFull && user) {
        document.getElementById('bookingForm').style.display = 'none';
        // Rimuovi eventuali messaggi di blocco (non servono per slot pieni)
        const _oldBl = document.getElementById('bookingBlockMessage');
        if (_oldBl) _oldBl.remove();
    }

    // Persone iscritte (solo per utenti loggati)
    const attendeesContainer = document.getElementById('slotAttendees');
    const attendeesList = document.getElementById('slotAttendeesList');
    if (attendeesContainer && user) {
        attendeesContainer.style.display = '';
        const details = attendeesContainer.querySelector('details');
        // Slot pieno: apri automaticamente la tendina
        if (details) { if (_slotFull) details.setAttribute('open', ''); else details.removeAttribute('open'); }
        // Se l'utente ha la privacy attiva, non può vedere chi è iscritto
        if (user.privacy_prenotazioni !== false) {
            attendeesList.innerHTML = '<li class="slot-attendees-empty">Disattiva la privacy per vedere chi è iscritto.</li>';
        } else {
            _loadSlotAttendees(attendeesList, selectedSlot ? selectedSlot.date : dateInfo.formatted, timeSlot);
        }
    } else if (attendeesContainer) {
        attendeesContainer.style.display = 'none';
    }

    // Show modal
    document.getElementById('bookingModal').style.display = 'flex';
    document.body.style.overflow = 'hidden';
}

function closeBookingModal() {
    const box = document.getElementById('bookingModal').querySelector('.modal-box');
    box.style.transform = '';
    box.style.transition = '';
    document.getElementById('bookingModal').style.display = 'none';
    document.getElementById('modalSlotInfo').style.display = '';
    document.body.style.overflow = '';
    const _attCont = document.getElementById('slotAttendees');
    if (_attCont) _attCont.style.display = 'none';
    selectedSlot = null;
    // Reset iOS Safari auto-zoom that may have triggered on input focus
    const vp = document.querySelector('meta[name="viewport"]');
    if (vp) {
        vp.setAttribute('content', 'width=device-width, initial-scale=1.0, maximum-scale=1.0');
        setTimeout(() => vp.setAttribute('content', 'width=device-width, initial-scale=1.0'), 100);
    }
}

function handleModalOverlayClick(e) {
    if (e.target === document.getElementById('bookingModal')) {
        closeBookingModal();
    }
}

async function handleBookingSubmit(e) {
    e.preventDefault();

    const submitBtn = e.target.querySelector('button[type="submit"]');

    // Previeni doppio click: disabilita subito il bottone
    if (submitBtn.disabled) return;
    submitBtn.disabled = true;

    // Avviso connessione lenta dopo 15s, sblocco forzato dopo 50s
    const _slowTimer = setTimeout(() => {
        showToast('Connessione lenta, attendi...', 'warning', 8000);
    }, 15000);
    const _safetyTimer = setTimeout(() => {
        console.warn('[Booking] safety timeout — sblocco bottone dopo 50s');
        setLoading(submitBtn, false);
        submitBtn.disabled = false;
        showToast('La richiesta sta impiegando troppo. Riprova.', 'error');
    }, 50000);

    try {

    if (!selectedSlot) {
        showToast('Seleziona uno slot dal calendario prima di prenotare.', 'error');
        return;
    }

    // Reject if more than 30 minutes have passed since lesson start.
    // La data va costruita in orario LOCALE: new Date("YYYY-MM-DD") la
    // interpreterebbe come mezzanotte UTC, sfasando il cutoff di 1-2h
    // (rotto vicino a mezzanotte/DST). Parse esplicito y/mo/dy + ora locale.
    const _slotTp = _parseSlotTime(selectedSlot.time);
    const [_sh, _sm] = _slotTp ? [_slotTp.startH, _slotTp.startM] : [0, 0];
    const [_yr, _mo, _dy] = String(selectedSlot.date).split('-').map(Number);
    const _lessonStart = new Date(_yr, _mo - 1, _dy, _sh, _sm, 0, 0);
    if ((new Date() - _lessonStart) > 30 * 60 * 1000) {
        showToast('Non è possibile prenotare: sono passati più di 30 minuti dall\'inizio della lezione.', 'error');
        closeBookingModal();
        return;
    }

    // Validate form
    const formData = {
        name: document.getElementById('name').value.trim().replace(/\S+/g, w => w[0].toUpperCase() + w.slice(1).toLowerCase()),
        email: document.getElementById('email').value.trim().toLowerCase(),
        whatsapp: normalizePhone(document.getElementById('whatsapp').value.trim()),
        notes: document.getElementById('notes').value.trim()
    };

    // Basic validation
    if (!formData.name || !formData.email || !formData.whatsapp) {
        showToast('Compila tutti i campi obbligatori.', 'error');
        return;
    }

    // Validate email
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(formData.email)) {
        showToast('Inserisci un indirizzo email valido.', 'error');
        return;
    }

    // Validate phone (basic check)
    const phoneRegex = /[\d\s+()-]{10,}/;
    if (!phoneRegex.test(formData.whatsapp)) {
        showToast('Inserisci un numero WhatsApp valido.', 'error');
        return;
    }

    // NB: nessun pre-check capienza lato client. L'autorità è `book_slot`
    // (server, advisory lock anti-overbooking): la cache localStorage può essere
    // stantia e negare a torto uno slot che il server concederebbe. Il caso
    // "slot pieno" è gestito più sotto via result.error === 'slot_full'.

    // Check duplicate booking (same user, same date+time, not cancelled)
    // Query Supabase direttamente per evitare dati stale in localStorage
    let duplicate = false;
    const _dupUser = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
    if (_dupUser?.id && typeof supabaseClient !== 'undefined') {
        try {
            // Timeout 10s sul check duplicati per non bloccare il flusso
            const _dupAbort = new AbortController();
            const _dupTimer = setTimeout(() => _dupAbort.abort(), 10000);
            const { data: _dupRows, error: _dupErr } = await supabaseClient
                .from('bookings')
                .select('id')
                .eq('user_id', _dupUser.id)
                .eq('date', selectedSlot.date)
                .eq('time', selectedSlot.time)
                .not('status', 'in', '("cancelled","cancellation_requested")')
                .limit(1)
                .abortSignal(_dupAbort.signal);
            clearTimeout(_dupTimer);
            if (!_dupErr && _dupRows && _dupRows.length > 0) duplicate = true;
        } catch (_) {
            // Fallback: controlla localStorage se Supabase non raggiungibile
            const allBookings = BookingStorage.getAllBookings();
            const normPhone = normalizePhone(formData.whatsapp);
            duplicate = allBookings.some(b =>
                b.date === selectedSlot.date &&
                b.time === selectedSlot.time &&
                b.status !== 'cancelled' &&
                b.status !== 'cancellation_requested' &&
                (
                    (b.email && b.email.toLowerCase() === formData.email.toLowerCase()) ||
                    (normPhone && normalizePhone(b.whatsapp) === normPhone)
                )
            );
        }
    } else {
        // Utente non loggato o Supabase non disponibile: fallback localStorage
        const allBookings = BookingStorage.getAllBookings();
        const normPhone = normalizePhone(formData.whatsapp);
        duplicate = allBookings.some(b =>
            b.date === selectedSlot.date &&
            b.time === selectedSlot.time &&
            b.status !== 'cancelled' &&
            b.status !== 'cancellation_requested' &&
            (
                (b.email && b.email.toLowerCase() === formData.email.toLowerCase()) ||
                (normPhone && normalizePhone(b.whatsapp) === normPhone)
            )
        );
    }
    if (duplicate) {
        showToast('Hai già una prenotazione per questo orario.', 'error');
        return;
    }

    // Check medical certificate restrictions — usa il profilo Supabase (getCurrentUser è sync)
    const _certUser = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
    if (typeof isAnagraficaComplete === 'function' && _certUser && !isAnagraficaComplete(_certUser)) {
        showToast("Prenotazione bloccata: completa l'anagrafica prima di prenotare.", 'error');
        return;
    }
    const _certScad = _certUser?.medical_cert_expiry || '';
    const _today    = _localDateStr();
    if (!_certScad && CertBookingStorage.getBlockIfNotSet()) {
        showToast('Prenotazione bloccata: non hai inserito la data di scadenza del certificato medico. Contatta il tuo PT.', 'error');
        return;
    }
    if (_certScad && _certScad < _today && CertBookingStorage.getBlockIfExpired()) {
        showToast('Prenotazione bloccata: il tuo certificato medico è scaduto. Contatta il tuo PT per aggiornarlo.', 'error');
        return;
    }

    // Check assicurazione restrictions
    const _assicScad = _certUser?.insurance_expiry || '';
    if (!_assicScad && AssicBookingStorage.getBlockIfNotSet()) {
        showToast('Prenotazione bloccata: non hai inserito la data di scadenza dell\'assicurazione. Contatta il tuo PT.', 'error');
        return;
    }
    if (_assicScad && _assicScad < _today && AssicBookingStorage.getBlockIfExpired()) {
        showToast('Prenotazione bloccata: la tua assicurazione è scaduta. Contatta il tuo PT per aggiornarla.', 'error');
        return;
    }

    setLoading(submitBtn, true, 'Prenotazione in corso...');

    // Create booking
    const booking = {
        ...formData,
        date: selectedSlot.date,
        time: selectedSlot.time,
        slotType: selectedSlot.slotType,
        dateDisplay: selectedSlot.dateDisplay,
        orgSlug: window._orgSlug   // org pubblica risolta lato client, passata a book_slot
    };

    // Save booking — attende la conferma server prima di mostrare il risultato
    const result = await BookingStorage.saveBooking(booking);
    if (!result.ok) {
        if (result.error === 'slot_full') {
            showToast('Slot non più disponibile. Qualcun altro ha prenotato prima di te.', 'error');
            renderCalendar();
            if (typeof renderMobileSlots === 'function' && selectedMobileDay) renderMobileSlots(selectedMobileDay);
        } else if (result.error === 'too_late') {
            showToast('Non è possibile prenotare: sono passati più di 30 minuti dall\'inizio della lezione.', 'error');
            closeBookingModal();
        } else if (result.error === 'server_error' && !navigator.onLine) {
            showToast('Sei offline. Connettiti a internet per prenotare.', 'error');
        } else {
            showToast('Errore durante la prenotazione. Riprova tra qualche secondo.', 'error');
        }
        return;
    }
    const savedBooking = result.booking;
    if (result.offline) {
        showToast('Prenotazione salvata localmente. Verrà sincronizzata quando torni online.', 'warning', 5000);
    }

    // Show confirmation
    showConfirmation(savedBooking);
    notificaPrenotazione(savedBooking);
    console.log('[Booking] notifyAdminBooking exists?', typeof notifyAdminBooking);
    if (typeof notifyAdminBooking === 'function') notifyAdminBooking(savedBooking);

    // Reset form
    document.getElementById('bookingForm').reset();

    // Refresh calendar to show updated availability
    renderCalendar();
    if (typeof renderMobileSlots === 'function' && selectedMobileDay) {
        renderMobileSlots(selectedMobileDay);
    }

    // Clear selection
    selectedSlot = null;

    } catch (err) {
        console.error('[Booking] errore imprevisto durante la prenotazione:', err);
        showToast('Errore durante la prenotazione. Riprova.', 'error');
    } finally {
        clearTimeout(_slowTimer);
        clearTimeout(_safetyTimer);
        setLoading(submitBtn, false);
        submitBtn.disabled = false;
    }
}

function buildCalendarDates(dateStr, timeStr) {
    const _btp = _parseSlotTime(timeStr);
    if (!_btp) return { start: '', end: '' };
    const [sH, sM] = [String(_btp.startH).padStart(2,'0'), String(_btp.startM).padStart(2,'0')];
    const [eH, eM] = [String(_btp.endH).padStart(2,'0'), String(_btp.endM).padStart(2,'0')];
    const d = dateStr.replace(/-/g, '');
    return { start: `${d}T${sH}${sM}00`, end: `${d}T${eH}${eM}00` };
}

function googleCalendarUrl(booking) {
    const { start, end } = buildCalendarDates(booking.date, booking.time);
    const title = encodeURIComponent(`Allenamento – ${getSlotName(booking.slotType)}`);
    const details = encodeURIComponent(`Prenotato da ${booking.name}`);
    const location = encodeURIComponent('Via Demo 1, Milano BS');
    const ctz = encodeURIComponent(_orgTimezone());
    return `https://calendar.google.com/calendar/render?action=TEMPLATE&text=${title}&dates=${start}/${end}&details=${details}&location=${location}&ctz=${ctz}`;
}

function _bookingUid(booking) {
    return `${booking.id}@palestria.app`;
}

// Blocco VTIMEZONE per l'ICS. Il TZID riflette il fuso configurato per la org
// (locale.timezone). NOTA: le regole DST embeddate (CET/CEST, ultima domenica di
// marzo/ottobre) sono valide per i fusi europei tipo Europe/Rome (il default).
// Per fusi non-europei servirebbe un DB timezone client-side: vedi limitazione
// documentata. Le righe DTSTART;TZID=/DTEND;TZID= devono usare lo stesso TZID.
function _vtimezoneLines(tzid) {
    return [
        'BEGIN:VTIMEZONE',
        `TZID:${tzid}`,
        'BEGIN:STANDARD',
        'DTSTART:19701025T030000',
        'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10',
        'TZOFFSETFROM:+0200',
        'TZOFFSETTO:+0100',
        'TZNAME:CET',
        'END:STANDARD',
        'BEGIN:DAYLIGHT',
        'DTSTART:19700329T020000',
        'RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3',
        'TZOFFSETFROM:+0100',
        'TZOFFSETTO:+0200',
        'TZNAME:CEST',
        'END:DAYLIGHT',
        'END:VTIMEZONE',
    ];
}

function downloadIcs(booking) {
    const { start, end } = buildCalendarDates(booking.date, booking.time);
    const title = `Allenamento – ${getSlotName(booking.slotType)}`;
    const uid = _bookingUid(booking);
    const tz = _orgTimezone();
    const ics = [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//PalestrIA//IT',
        ..._vtimezoneLines(tz),
        'BEGIN:VEVENT',
        `UID:${uid}`,
        `DTSTART;TZID=${tz}:${start}`,
        `DTEND;TZID=${tz}:${end}`,
        `SUMMARY:${title}`,
        'LOCATION:Via Demo\\, 1\\, Milano BS',
        `DESCRIPTION:Prenotato da ${booking.name}`,
        'END:VEVENT',
        'END:VCALENDAR'
    ].join('\r\n');

    const blob = new Blob([ics], { type: 'text/calendar' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'allenamento.ics';
    a.click();
    URL.revokeObjectURL(url);
}

function downloadCancelIcs(booking) {
    const { start, end } = buildCalendarDates(booking.date, booking.time);
    const title = `Allenamento – ${getSlotName(booking.slotType)}`;
    const uid = _bookingUid(booking);
    const tz = _orgTimezone();
    const ics = [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID:-//PalestrIA//IT',
        'METHOD:CANCEL',
        ..._vtimezoneLines(tz),
        'BEGIN:VEVENT',
        `UID:${uid}`,
        `DTSTART;TZID=${tz}:${start}`,
        `DTEND;TZID=${tz}:${end}`,
        `SUMMARY:${title}`,
        'STATUS:CANCELLED',
        'SEQUENCE:1',
        'END:VEVENT',
        'END:VCALENDAR'
    ].join('\r\n');

    const blob = new Blob([ics], { type: 'text/calendar' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'annulla-allenamento.ics';
    a.click();
    URL.revokeObjectURL(url);
}

function showConfirmation(booking) {
    _confirmedBooking = booking;
    // Hide form, show confirmation inside the modal
    document.getElementById('bookingForm').style.display = 'none';
    document.getElementById('modalSlotInfo').style.display = 'none';

    const confirmationDiv = document.getElementById('confirmationMessage');
    const creditNotice = '';
    confirmationDiv.innerHTML = `
        <h3>✓ ${getSlotName(booking.slotType)} Confermata!</h3>
        <p><strong>${_escHtml(booking.name)}</strong></p>
        <p>📅 ${booking.dateDisplay} &nbsp;·&nbsp; 🕐 ${booking.time}</p>
        ${creditNotice}
        <div class="cal-buttons">
            <a href="${googleCalendarUrl(booking)}" target="_blank" rel="noopener" class="cal-btn cal-btn-google">
                <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path fill="#4285F4" d="M19 4h-1V2h-2v2H8V2H6v2H5C3.9 4 3 4.9 3 6v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 16H5V10h14v10zm0-12H5V6h14v2z"/><rect fill="#EA4335" x="7" y="12" width="2" height="2"/><rect fill="#34A853" x="11" y="12" width="2" height="2"/><rect fill="#FBBC04" x="15" y="12" width="2" height="2"/><rect fill="#34A853" x="7" y="16" width="2" height="2"/><rect fill="#4285F4" x="11" y="16" width="2" height="2"/><rect fill="#EA4335" x="15" y="16" width="2" height="2"/></svg>
                Google Calendar
            </a>
            <button onclick="downloadIcs(_confirmedBooking)" class="cal-btn cal-btn-apple">
                <svg viewBox="0 0 24 24" fill="currentColor"><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>
                Apple Calendar
            </button>
        </div>
        <div class="confirm-rules">
            <div class="confirm-rule-item">
                <span class="confirm-rule-icon">👟</span>
                <div>
                    <strong>Abbigliamento adeguato</strong>
                    <p>Indossa scarpe di ricambio pulite (da usare solo in palestra). In alternativa, puoi allenarti con calze antiscivolo. Porta sempre una <strong>salvietta</strong> personale da usare sugli attrezzi.</p>
                </div>
            </div>
            <div class="confirm-rule-item">
                <span class="confirm-rule-icon">🚫</span>
                <div>
                    <strong>Alimentazione e digestione</strong>
                    <p>Non mangiare nelle 2–3 ore prima dell'allenamento per evitare fastidi durante l'attività fisica.</p>
                </div>
            </div>
            <div class="confirm-rule-item">
                <span class="confirm-rule-icon">💧</span>
                <div>
                    <strong>Idratazione</strong>
                    <p>Porta sempre con te una borraccia d'acqua per mantenerti idratato durante la sessione.</p>
                </div>
            </div>
        </div>
        <button onclick="closeBookingModal();document.getElementById('bookingForm').style.display='';document.getElementById('confirmationMessage').style.display='none';" class="btn btn-primary" style="margin-top:1.2rem;width:100%;background-color:#fff;color:var(--primary-purple);border:2px solid var(--primary-purple);">← Torna al calendario</button>
    `;
    confirmationDiv.style.display = 'block';
}

// Notifica di sistema dopo una prenotazione confermata
async function notificaPrenotazione(booking) {
    if (!('Notification' in window) || !navigator.serviceWorker) return;
    let permission = Notification.permission;
    if (permission === 'denied') return;
    if (permission === 'default') {
        permission = await Notification.requestPermission();
    }
    if (permission !== 'granted') return;
    // Registra push subscription per notifiche future (es. reminder 24h prima)
    if (typeof registerPushSubscription === 'function') registerPushSubscription();
    const reg = await navigator.serviceWorker.ready;
    reg.showNotification('Prenotazione confermata', {
        body: `${getSlotName(booking.slotType)} · ${booking.dateDisplay} · ${booking.time}`,
        icon: '/images/logo-palestria.png',
        badge: '/images/badge-mono-96.png',
        tag: 'prenotazione-' + booking.id,
        renotify: false
    });
}

// Initialize booking form when DOM is loaded
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initBookingForm);
} else {
    initBookingForm();
}
