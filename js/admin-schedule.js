// Schedule Manager Functions
let scheduleWeekOffset = 0;
let selectedScheduleDate = null;

function setupScheduleManager() {
    renderScheduleManager();
}

function renderScheduleManager() {
    const manager = document.getElementById('scheduleManager');
    if (!manager) return;

    const weekDates = getScheduleWeekDates(scheduleWeekOffset);

    // Resolve selected date BEFORE building HTML so the active tab gets highlighted.
    // Reset to Monday if no date is selected or the selection belongs to a different week.
    if (!selectedScheduleDate || !weekDates.find(d => d.formatted === selectedScheduleDate.formatted)) {
        selectedScheduleDate = weekDates[0];
    }

    // Week navigation
    const firstDate = weekDates[0].date;
    const lastDate = weekDates[6].date;

    const overrides = BookingStorage.getScheduleOverrides();
    const weekHasAnySlot = weekDates.some(d => overrides[d.formatted] && overrides[d.formatted].length > 0);

    const M_SHORT = ['gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic'];
    const range = `${firstDate.getDate()} ${M_SHORT[firstDate.getMonth()]} — ${lastDate.getDate()} ${M_SHORT[lastDate.getMonth()]}`;

    // Day selector tabs with dates — wrapped in 3 .admin-week-page for swipe
    const monthNames = ['Gen','Feb','Mar','Apr','Mag','Giu','Lug','Ago','Set','Ott','Nov','Dic'];
    let dayTabsHtml = '<div class="schedule-day-tabs" id="scheduleDayTabs">';
    [-1, 0, 1].forEach(off => {
        const pageDates = getScheduleWeekDates(scheduleWeekOffset + off);
        dayTabsHtml += `<div class="admin-week-page" data-rel-offset="${off}">`;
        pageDates.forEach(dateInfo => {
            const isActive = (off === 0 && selectedScheduleDate && selectedScheduleDate.formatted === dateInfo.formatted) ? 'active' : '';
            const daySlots = overrides[dateInfo.formatted] || [];
            const hasSlots = daySlots.length > 0;
            const hasMissingClient = daySlots.some(s => s.type === SLOT_TYPES.GROUP_CLASS && !s.client);
            const shortName = dateInfo.dayName.slice(0, 3);
            dayTabsHtml += `<button class="schedule-day-tab ${isActive} ${hasSlots ? 'has-slots' : ''} ${hasMissingClient ? 'missing-client' : ''}" data-date="${dateInfo.formatted}" onclick="selectScheduleDate('${dateInfo.formatted}', '${dateInfo.dayName}')">
                <div class="admin-day-name"><span class="day-full">${dateInfo.dayName}</span><span class="day-short">${shortName}</span></div>
                <div class="admin-day-date">${dateInfo.date.getDate()}</div>
                <div class="admin-day-count">${monthNames[dateInfo.date.getMonth()]}</div>
            </button>`;
        });
        dayTabsHtml += '</div>';
    });
    dayTabsHtml += '</div>';

    let html = `
        <div class="schedule-week-bar">
            <div class="schedule-week-nav">
                <div class="schedule-week-info">
                    <span class="schedule-week-dates">${range}</span>
                    <span class="schedule-week-status ${weekHasAnySlot ? 'has-slots' : 'is-blank'}">${weekHasAnySlot ? 'CONFIGURATA' : 'NON CONFIGURATA'}</span>
                </div>
                <div class="schedule-week-arrows">
                    <button class="schedule-week-btn" onclick="changeScheduleWeek(-1)" aria-label="Settimana precedente" title="Settimana precedente">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
                    </button>
                    <button class="schedule-week-btn" onclick="changeScheduleWeek(1)" aria-label="Settimana successiva" title="Settimana successiva">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>
                    </button>
                </div>
            </div>
            ${dayTabsHtml}
            <div class="schedule-week-actions">
                <button class="btn-import-week" onclick="importWeekTemplate(${scheduleWeekOffset})">📥 Importa: ${_escHtml(_getActiveTemplateName())}</button>
                ${weekHasAnySlot ? `<button class="btn-clear-week" onclick="clearWeekSchedule(${scheduleWeekOffset})">🗑 Svuota</button>` : ''}
            </div>
        </div>
    `;

    html += '<div id="scheduleDaySlots"></div>';

    manager.innerHTML = html;

    setupScheduleWeekSwipe();
    renderAllTimeSlots();
}

function setupScheduleWeekSwipe() {
    const container = document.getElementById('scheduleDayTabs');
    if (!container) return;

    requestAnimationFrame(() => {
        const w = container.clientWidth;
        if (w > 0) {
            const prev = container.style.scrollBehavior;
            container.style.scrollBehavior = 'auto';
            container.scrollLeft = w;
            container.style.scrollBehavior = prev || '';
        }
    });

    let scrollTimer = null;
    container.addEventListener('scroll', () => {
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(() => {
            const pageWidth = container.clientWidth;
            if (!pageWidth) return;
            const idx = Math.round(container.scrollLeft / pageWidth);
            if (idx === 1) return;
            scheduleWeekOffset += (idx - 1);
            selectedScheduleDate = null;
            renderScheduleManager();
        }, 180);
    });
}

function _clientInitials(name) {
    if (!name) return '?';
    const parts = String(name).trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return '?';
    if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
}

function getScheduleWeekDates(offset = 0) {
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
            formatted: formatAdminDate(date)
        });
    }

    return dates;
}

function changeScheduleWeek(direction) {
    scheduleWeekOffset += direction;
    selectedScheduleDate = null;
    renderScheduleManager();
}

function weekHasBookings(weekOffset) {
    const weekDates = getScheduleWeekDates(weekOffset);
    const weekDateSet = new Set(weekDates.map(d => d.formatted));
    const allBookings = BookingStorage.getAllBookings();
    return allBookings.some(b => weekDateSet.has(b.date) && b.status !== 'cancelled');
}

function importWeekTemplate(weekOffset) {
    if (weekHasBookings(weekOffset)) {
        alert('Non è possibile importare la settimana standard: ci sono prenotazioni in questa settimana.');
        return;
    }
    const weekDates = getScheduleWeekDates(weekOffset);
    const overrides = BookingStorage.getScheduleOverrides();
    const dayNames = ['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato'];

    weekDates.forEach(dateInfo => {
        const jsDay = dateInfo.date.getDay(); // 0=Dom, 1=Lun, ...
        const templateSlots = WEEKLY_SCHEDULE_TEMPLATE[dayNames[jsDay]] || [];
        if (templateSlots.length > 0) {
            // Don't overwrite days already customized
            if (!overrides[dateInfo.formatted]) {
                overrides[dateInfo.formatted] = templateSlots;
            }
        }
    });

    BookingStorage.saveScheduleOverrides(overrides, weekDates.map(d => d.formatted));
    renderScheduleManager();
}

function clearWeekSchedule(weekOffset) {
    if (weekHasBookings(weekOffset)) {
        alert('Non è possibile svuotare la settimana: ci sono prenotazioni in questa settimana.');
        return;
    }
    if (!confirm('Svuotare tutti i giorni di questa settimana?')) return;
    const weekDates = getScheduleWeekDates(weekOffset);
    const overrides = BookingStorage.getScheduleOverrides();
    weekDates.forEach(dateInfo => { delete overrides[dateInfo.formatted]; });
    BookingStorage.saveScheduleOverrides(overrides, weekDates.map(d => d.formatted));
    selectedScheduleDate = null;
    renderScheduleManager();
}

function selectScheduleDate(dateFormatted, dayName) {
    const weekDates = getScheduleWeekDates(scheduleWeekOffset);
    selectedScheduleDate = weekDates.find(d => d.formatted === dateFormatted);

    // Aggiorna solo i tab attivi + slot, senza ricostruire l'intera UI della settimana
    document.querySelectorAll('.schedule-day-tab').forEach(tab => {
        tab.classList.toggle('active', tab.dataset.date === dateFormatted);
    });

    renderAllTimeSlots();
}

// All possible time slots — 80 min each, 05:20 → 21:20
const ALL_TIME_SLOTS = [
    '05:20 - 06:40',
    '06:40 - 08:00',
    '08:00 - 09:20',
    '09:20 - 10:40',
    '10:40 - 12:00',
    '12:00 - 13:20',
    '13:20 - 14:40',
    '14:40 - 16:00',
    '16:00 - 17:20',
    '17:20 - 18:40',
    '18:40 - 20:00',
    '20:00 - 21:20'
];

// Get schedule for a specific date (uses overrides if exist, otherwise template)
function getScheduleForDate(dateFormatted, dayName) {
    // Only return slots that have been explicitly configured for this date.
    // Weeks with no override are blank and won't appear in the calendar.
    const overrides = BookingStorage.getScheduleOverrides();
    return overrides[dateFormatted] || [];
}

// Save schedule override for a specific date
function saveScheduleForDate(dateFormatted, dayName, slots) {
    const overrides = BookingStorage.getScheduleOverrides();

    if (slots.length === 0) {
        // If empty, remove override (will fall back to template)
        delete overrides[dateFormatted];
    } else {
        overrides[dateFormatted] = slots;
    }

    BookingStorage.saveScheduleOverrides(overrides, [dateFormatted]);
}

function renderAllTimeSlots() {
    const container = document.getElementById('scheduleDaySlots');
    if (!container || !selectedScheduleDate) return;

    // Get slots for this specific date
    const daySlots = getScheduleForDate(selectedScheduleDate.formatted, selectedScheduleDate.dayName);

    const M_SHORT = ['gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic'];
    const dayShort = selectedScheduleDate.dayName.slice(0, 3);
    const dateShort = `${dayShort} · ${selectedScheduleDate.date.getDate()} ${M_SHORT[selectedScheduleDate.date.getMonth()]}`;
    let html = `<p class="schedule-day-h">
                  <strong>Slot del giorno</strong>
                  <span class="schedule-day-h-d">${dateShort}</span>
                </p>`;

    html += '<div class="schedule-slots-list">';

    ALL_TIME_SLOTS.forEach(timeSlot => {
        // Find if this time slot already has a lesson assigned
        const existingSlot = daySlots.find(slot => slot.time === timeSlot);
        const currentType = existingSlot ? existingSlot.type : '';
        const isGroupClass = currentType === SLOT_TYPES.GROUP_CLASS;
        const safeId = sanitizeSlotId(timeSlot);
        const typeClass = currentType ? `is-${currentType}` : 'is-empty';

        // Client picker HTML — only for "Slot prenotato"
        let clientPickerHtml = '';
        if (isGroupClass) {
            const client = existingSlot?.client;
            const selectedClientHtml = client
                ? `<div class="slot-client-selected">
                       <span class="slot-client-avatar" aria-hidden="true">${_escHtml(_clientInitials(client.name))}</span>
                       <span class="slot-client-name">${_escHtml(client.name)}</span>
                       <button class="btn-clear-client" onclick="clearSlotClient('${timeSlot}')" aria-label="Rimuovi cliente" title="Rimuovi cliente">✕</button>
                   </div>`
                : `<div class="slot-client-warning">⚠️ Cliente obbligatorio — cerca e seleziona un iscritto</div>`;

            clientPickerHtml = `
                <div class="slot-client-picker">
                    ${selectedClientHtml}
                    <div class="slot-client-search">
                        <input type="text"
                            class="slot-client-input"
                            id="client-input-${safeId}"
                            placeholder="Cerca per nome, email o telefono..."
                            oninput="searchClientsForSlot('${timeSlot}', this.value)"
                            autocomplete="off">
                        <div class="slot-client-results" id="client-results-${safeId}"></div>
                    </div>
                </div>`;
        }

        if (isGroupClass) {
            // Group-class: column layout with client picker below the row
            html += `
                <div class="schedule-slot-item-selector ${typeClass} has-client-picker">
                    <div class="schedule-slot-top-row">
                        <div class="schedule-slot-time">🕐 ${timeSlot}</div>
                        <div class="schedule-slot-dropdown">
                            <select onchange="updateSlotType('${timeSlot}', this.value)" class="slot-type-select">
                                <option value="">-- Nessuna lezione --</option>
                                <option value="${SLOT_TYPES.PERSONAL}">Autonomia</option>
                                <option value="${SLOT_TYPES.SMALL_GROUP}">Lezione di Gruppo</option>
                                <option value="${SLOT_TYPES.GROUP_CLASS}" selected>Slot prenotato</option>
                                <option value="${SLOT_TYPES.CLEANING}">Pulizie</option>
                            </select>
                        </div>
                        <div class="current-type-badge ${SLOT_TYPES.GROUP_CLASS}">${SLOT_NAMES[SLOT_TYPES.GROUP_CLASS]}</div>
                    </div>
                    ${clientPickerHtml}
                </div>
            `;
        } else {
            html += `
                <div class="schedule-slot-item-selector ${typeClass}">
                    <div class="schedule-slot-time">🕐 ${timeSlot}</div>
                    <div class="schedule-slot-dropdown">
                        <select onchange="updateSlotType('${timeSlot}', this.value)" class="slot-type-select">
                            <option value="">-- Nessuna lezione --</option>
                            <option value="${SLOT_TYPES.PERSONAL}" ${currentType === SLOT_TYPES.PERSONAL ? 'selected' : ''}>Autonomia</option>
                            <option value="${SLOT_TYPES.SMALL_GROUP}" ${currentType === SLOT_TYPES.SMALL_GROUP ? 'selected' : ''}>Lezione di Gruppo</option>
                            <option value="${SLOT_TYPES.GROUP_CLASS}">Slot prenotato</option>
                            <option value="${SLOT_TYPES.CLEANING}" ${currentType === SLOT_TYPES.CLEANING ? 'selected' : ''}>Pulizie</option>
                        </select>
                    </div>
                    ${currentType ? `<div class="current-type-badge ${currentType}">${SLOT_NAMES[currentType]}</div>` : ''}
                </div>
            `;
        }
    });

    html += '</div>';

    container.innerHTML = html;
}

function updateSlotType(timeSlot, newType) {
    if (!selectedScheduleDate) return;

    const dateFormatted = selectedScheduleDate.formatted;

    // Check if there are existing bookings in this slot
    const existingBookings = BookingStorage.getBookingsForSlot(dateFormatted, timeSlot);
    // Filter to only confirmed / cancellation_requested (getBookingsForSlot already excludes cancelled)
    const activeBookings = existingBookings.filter(b => b.status === 'confirmed' || b.status === 'cancellation_requested');

    if (activeBookings.length > 0) {
        // Show confirmation popup with booked people
        _showSlotChangePopup(timeSlot, newType, activeBookings);
    } else {
        // No bookings — apply change directly
        _applySlotTypeChange(timeSlot, newType);
    }
}

// Actually applies the slot type change (called directly or after popup confirmation)
function _applySlotTypeChange(timeSlot, newType) {
    if (!selectedScheduleDate) return;

    // Get current slots for this date
    let daySlots = getScheduleForDate(selectedScheduleDate.formatted, selectedScheduleDate.dayName);

    // Make a copy to modify
    daySlots = JSON.parse(JSON.stringify(daySlots));

    // Find existing slot
    const existingSlotIndex = daySlots.findIndex(slot => slot.time === timeSlot);

    if (newType === '') {
        // Remove slot if "Nessuna lezione" is selected
        if (existingSlotIndex !== -1) {
            // Remove the associated booking if this was a group-class slot
            if (daySlots[existingSlotIndex].bookingId) {
                BookingStorage.removeBookingById(daySlots[existingSlotIndex].bookingId);
            }
            daySlots.splice(existingSlotIndex, 1);
        }
    } else {
        // Add or update slot
        if (existingSlotIndex !== -1) {
            // When switching away from group-class, remove client and booking
            if (daySlots[existingSlotIndex].type === SLOT_TYPES.GROUP_CLASS && newType !== SLOT_TYPES.GROUP_CLASS) {
                if (daySlots[existingSlotIndex].bookingId) {
                    BookingStorage.removeBookingById(daySlots[existingSlotIndex].bookingId);
                }
                delete daySlots[existingSlotIndex].client;
                delete daySlots[existingSlotIndex].bookingId;
            }
            daySlots[existingSlotIndex].type = newType;
        } else {
            // Add new slot
            daySlots.push({
                time: timeSlot,
                type: newType
            });
        }
    }

    // Sort by time
    daySlots.sort((a, b) => a.time.localeCompare(b.time));

    // Save as override for this specific date
    saveScheduleForDate(selectedScheduleDate.formatted, selectedScheduleDate.dayName, daySlots);

    // Refresh display
    renderAllTimeSlots();

    console.log(`Slot ${timeSlot} per ${selectedScheduleDate.formatted} aggiornato: ${newType || 'rimosso'}`);
}

// ── Slot Change Confirmation Popup ────────────────────────────────────────────
// Shows a popup when admin tries to change/remove a slot that has active bookings.
// Lists the booked people, allows sending a notification, and confirms cancellation.

function _showSlotChangePopup(timeSlot, newType, bookings) {
    // Remove any previous popup
    const old = document.getElementById('slotChangeOverlay');
    if (old) old.remove();
    const oldPopup = document.getElementById('slotChangePopup');
    if (oldPopup) oldPopup.remove();

    const dateDisplay = `${selectedScheduleDate.dayName} ${selectedScheduleDate.date.getDate()}/${selectedScheduleDate.date.getMonth() + 1}/${selectedScheduleDate.date.getFullYear()}`;
    const changeLabel = newType ? SLOT_NAMES[newType] : 'Nessuna lezione';

    // Build people list HTML
    let peopleHtml = '';
    bookings.forEach(b => {
        peopleHtml += `
            <div style="display:flex; align-items:center; gap:0.5rem; padding:0.5rem 0.75rem; background:#fef2f2; border-radius:8px; margin-bottom:0.4rem;">
                <span style="font-size:1.1rem;">👤</span>
                <div style="flex:1; min-width:0;">
                    <div style="font-weight:600; font-size:0.95rem;">${_escHtml(b.name)}</div>
                    <div style="font-size:0.8rem; color:#666;">${_escHtml(b.whatsapp || b.email || '')}</div>
                </div>
                <span style="font-size:0.75rem; color:#dc2626; font-weight:500;">${b.status === 'cancellation_requested' ? 'Annullamento richiesto' : 'Confermata'}</span>
            </div>`;
    });

    const defaultMsg = '';

    const overlay = document.createElement('div');
    overlay.id = 'slotChangeOverlay';
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:9998;';

    const popup = document.createElement('div');
    popup.id = 'slotChangePopup';
    popup.style.cssText = 'position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);background:#fff;border-radius:16px;padding:0;max-width:460px;width:92%;max-height:85vh;overflow:hidden;z-index:9999;box-shadow:0 20px 60px rgba(0,0,0,0.3);display:flex;flex-direction:column;';

    popup.innerHTML = `
        <div style="padding:1.25rem 1.5rem; border-bottom:1px solid #e5e7eb; display:flex; justify-content:space-between; align-items:center;">
            <div>
                <h3 style="margin:0; font-size:1.1rem; color:#dc2626;">⚠️ Prenotazioni attive</h3>
                <p style="margin:0.25rem 0 0; font-size:0.85rem; color:#666;">Slot ${timeSlot} — ${dateDisplay}</p>
            </div>
            <button id="slotChangeClose" style="background:none;border:none;font-size:1.3rem;cursor:pointer;padding:0.25rem;color:#666;">✕</button>
        </div>
        <div style="padding:1rem 1.5rem; overflow-y:auto; flex:1;">
            <p style="margin:0 0 0.75rem; font-size:0.9rem; color:#374151;">
                Ci sono <strong>${bookings.length} persona/e</strong> prenotate in questo slot.
                Cambiando in <strong>"${_escHtml(changeLabel)}"</strong>, le prenotazioni verranno annullate.
            </p>
            <div style="margin-bottom:1rem;">
                ${peopleHtml}
            </div>
            <div style="margin-bottom:0.75rem;">
                <label style="display:flex; align-items:center; gap:0.5rem; font-size:0.9rem; font-weight:500; color:#374151; cursor:pointer;">
                    <input type="checkbox" id="slotChangeSendNotify" checked style="width:18px; height:18px; accent-color:#2563eb;">
                    Invia notifica push ai prenotati
                </label>
            </div>
            <div id="slotChangeMsgContainer">
                <label style="font-size:0.85rem; font-weight:600; color:#374151; display:block; margin-bottom:0.4rem;">Messaggio:</label>
                <textarea id="slotChangeMsgText" rows="3" placeholder="Scrivi il messaggio da inviare ai prenotati..." style="width:100%; box-sizing:border-box; padding:0.6rem 0.75rem; border:1px solid #d1d5db; border-radius:8px; font-size:0.9rem; resize:vertical; font-family:inherit;"></textarea>
            </div>
            <div id="slotChangeResult" style="margin-top:0.75rem;"></div>
        </div>
        <div style="padding:1rem 1.5rem; border-top:1px solid #e5e7eb; display:flex; gap:0.75rem; justify-content:flex-end;">
            <button id="slotChangeCancelBtn" style="padding:0.6rem 1.2rem; border:1px solid #d1d5db; border-radius:8px; background:#fff; font-size:0.9rem; cursor:pointer; color:#374151;">Annulla</button>
            <button id="slotChangeConfirmBtn" style="padding:0.6rem 1.2rem; border:none; border-radius:8px; background:#dc2626; color:#fff; font-size:0.9rem; cursor:pointer; font-weight:600;">Conferma annullamento</button>
        </div>
    `;

    document.body.appendChild(overlay);
    document.body.appendChild(popup);

    // Toggle message field visibility based on checkbox
    const notifyCheckbox = document.getElementById('slotChangeSendNotify');
    const msgContainer = document.getElementById('slotChangeMsgContainer');
    notifyCheckbox.addEventListener('change', () => {
        msgContainer.style.display = notifyCheckbox.checked ? 'block' : 'none';
    });

    // Close handlers
    const closePopup = () => {
        overlay.remove();
        popup.remove();
        // Reset the select dropdown since we're cancelling
        renderAllTimeSlots();
    };

    document.getElementById('slotChangeClose').addEventListener('click', closePopup);
    document.getElementById('slotChangeCancelBtn').addEventListener('click', closePopup);
    overlay.addEventListener('click', e => { e.stopPropagation(); });

    // Confirm handler
    document.getElementById('slotChangeConfirmBtn').addEventListener('click', async () => {
        const confirmBtn = document.getElementById('slotChangeConfirmBtn');
        const resultDiv = document.getElementById('slotChangeResult');
        const sendNotify = document.getElementById('slotChangeSendNotify').checked;
        const msgText = document.getElementById('slotChangeMsgText').value.trim();

        confirmBtn.disabled = true;
        confirmBtn.textContent = '⏳ Elaborazione...';

        try {
            // Step 1: Send notifications if checked
            if (sendNotify && msgText) {
                resultDiv.innerHTML = '<div style="color:#6b7280; font-size:0.85rem;">⏳ Invio notifiche in corso...</div>';

                const { data: { session: _schedSession } } = await supabaseClient.auth.getSession();
                const res = await fetch(`${SUPABASE_URL}/functions/v1/send-admin-message`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + (_schedSession?.access_token || '') },
                    body: JSON.stringify({
                        title: `📢 Lezione annullata di ${dateDisplay} alle ${timeSlot.split(' - ')[0]}`,
                        body: msgText,
                        mode: 'ora',
                        date: selectedScheduleDate.formatted,
                        time: timeSlot
                    })
                });
                const data = await res.json();

                let notifyHtml = '';
                if (data.ok) {
                    if ((data.recipients || []).length > 0) {
                        notifyHtml += `<div style="color:#16a34a; font-size:0.85rem; margin-bottom:0.3rem;">✅ Notifica inviata a (${data.recipients.length}):</div>`;
                        notifyHtml += '<ul style="margin:0 0 0.5rem; padding-left:1.2rem; list-style:none;">';
                        (data.recipients || []).forEach(name => {
                            notifyHtml += `<li style="font-size:0.85rem; padding:0.15rem 0;">👤 ${_escHtml(name)}</li>`;
                        });
                        notifyHtml += '</ul>';
                    }
                    if ((data.failed || []).length > 0) {
                        notifyHtml += `<div style="color:#dc2626; font-size:0.85rem; margin-bottom:0.3rem;">❌ Non recapitate (${data.failed.length}):</div>`;
                        notifyHtml += '<ul style="margin:0 0 0.5rem; padding-left:1.2rem; list-style:none;">';
                        (data.failed || []).forEach(name => {
                            notifyHtml += `<li style="font-size:0.85rem; padding:0.15rem 0;">👤 ${_escHtml(name)}</li>`;
                        });
                        notifyHtml += '</ul>';
                    }
                    if ((data.recipients || []).length === 0 && (data.failed || []).length === 0) {
                        notifyHtml = '<div style="color:#f59e0b; font-size:0.85rem;">⚠️ Nessun destinatario con notifiche push attive.</div>';
                    }
                } else {
                    notifyHtml = `<div style="color:#dc2626; font-size:0.85rem;">❌ Errore invio notifiche: ${_escHtml(data.error || 'sconosciuto')}</div>`;
                }

                resultDiv.innerHTML = notifyHtml;
            }

            // Step 2: Cancel all bookings in this slot (with await on Supabase)
            if (!sendNotify || !msgText) {
                resultDiv.innerHTML = '<div style="color:#6b7280; font-size:0.85rem;">⏳ Annullamento prenotazioni...</div>';
            } else {
                resultDiv.innerHTML += '<div style="color:#6b7280; font-size:0.85rem; margin-top:0.5rem;">⏳ Annullamento prenotazioni...</div>';
            }

            let cancelledCount = 0;
            let cancelErrors = [];
            for (const b of bookings) {
                // Aggiorna cache locale: solo cambio stato (nessun rimborso/mora/bonus)
                const all = BookingStorage.getAllBookings();
                const idx = all.findIndex(bk => bk.id === b.id);
                if (idx === -1) continue;
                const bk = all[idx];
                bk.cancelledPaymentMethod = bk.paymentMethod;
                bk.cancelledPaidAt = bk.paidAt;
                bk.status = 'cancelled';
                bk.cancelledAt = new Date().toISOString();
                bk.paid = false;
                bk.paymentMethod = null;
                bk.paidAt = null;

                // Cancellazione server via RPC atomica cancel_booking
                // (cambio stato + conversione group-class -> small-group lato server)
                if (typeof supabaseClient !== 'undefined' && bk._sbId) {
                    try {
                        const { data: rpcData, error: rpcErr } = await _rpcWithTimeout(
                            supabaseClient.rpc('cancel_booking', { p_booking_id: bk._sbId })
                        );
                        if (rpcErr) {
                            console.error('[SlotChange] cancel_booking error:', rpcErr.message);
                            cancelErrors.push(b.name);
                        } else if (rpcData && !rpcData.success && rpcData.error !== 'already_cancelled') {
                            console.warn('[SlotChange] cancel_booking fallita per', bk._sbId, rpcData.error);
                            cancelErrors.push(b.name);
                        } else {
                            cancelledCount++;
                        }
                    } catch (e) {
                        console.error('[SlotChange] RPC exception:', e);
                        cancelErrors.push(b.name);
                    }
                } else {
                    cancelledCount++;
                }
            }
            // Commit local cache (single write)
            BookingStorage.replaceAllBookings(BookingStorage.getAllBookings());

            // Step 3: Apply the slot type change
            _applySlotTypeChange(timeSlot, newType);

            // Update button to show success
            confirmBtn.textContent = '✅ Fatto';
            confirmBtn.style.background = '#16a34a';

            // Add final message
            let doneHtml = `<div style="color:#16a34a; font-size:0.85rem; font-weight:600; margin-top:0.5rem;">✅ ${cancelledCount} prenotazione/i annullata/e. Slot aggiornato.</div>`;
            if (cancelErrors.length > 0) {
                doneHtml += `<div style="color:#dc2626; font-size:0.85rem; margin-top:0.3rem;">⚠️ Errore annullamento per: ${cancelErrors.map(n => _escHtml(n)).join(', ')}</div>`;
            }
            resultDiv.innerHTML += doneHtml;

            // Auto-close after a short delay
            setTimeout(() => {
                overlay.remove();
                popup.remove();
            }, 2500);

        } catch (e) {
            resultDiv.innerHTML = `<div style="color:#dc2626; font-size:0.85rem;">❌ Errore: ${_escHtml(e.message)}</div>`;
        } finally {
            // Ri-abilita il bottone solo se non siamo già nello stato successo
            // (stato successo: testo cambiato e popup si auto-chiude dopo 2.5s)
            if (confirmBtn && confirmBtn.textContent !== '✅ Fatto') {
                confirmBtn.disabled = false;
                confirmBtn.textContent = 'Conferma annullamento';
            }
        }
    });
}

// ── Client Picker for "Slot prenotato" ────────────────────────────────────────

// Sanitize a time slot string to use as an HTML element ID
function sanitizeSlotId(timeSlot) {
    return timeSlot.replace(/[^a-z0-9]/gi, '_');
}

// Holds last search results per time slot to avoid JSON in onclick attributes
const _clientSearchResults = {};

// Called on input — searches registered users and renders the dropdown list
var searchClientsForSlot = _debounce(function(timeSlot, query) {
    const safeId = sanitizeSlotId(timeSlot);
    const resultsDiv = document.getElementById(`client-results-${safeId}`);
    if (!resultsDiv) return;

    if (!query || query.trim().length < 2) {
        resultsDiv.innerHTML = '';
        _clientSearchResults[timeSlot] = [];
        return;
    }

    const results = UserStorage.search(query);
    _clientSearchResults[timeSlot] = results;

    if (results.length === 0) {
        resultsDiv.innerHTML = '<div class="slot-client-no-results">Nessun iscritto trovato</div>';
        return;
    }

    resultsDiv.innerHTML = results.map((user, i) => `
        <div class="slot-client-result" onclick="selectSlotClient('${timeSlot}', ${i})">
            <span class="slot-client-result-name">${user.name}</span>
        </div>
    `).join('');
}, 250);

// Formats YYYY-MM-DD to display string (e.g. "Lunedì 26 Febbraio 2026")
function formatAdminBookingDate(dateStr) {
    const [year, month, day] = dateStr.split('-').map(Number);
    const d = new Date(year, month - 1, day);
    const days = ['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato'];
    const months = ['Gennaio','Febbraio','Marzo','Aprile','Maggio','Giugno',
                    'Luglio','Agosto','Settembre','Ottobre','Novembre','Dicembre'];
    return `${days[d.getDay()]} ${day} ${months[month - 1]} ${year}`;
}

// Called when a user clicks a result — creates a real booking and links it to the slot
async function selectSlotClient(timeSlot, index) {
    const user = (_clientSearchResults[timeSlot] || [])[index];
    if (!user || !selectedScheduleDate) return;

    if (!confirm(`Confermare la prenotazione di ${user.name} per lo slot ${timeSlot} del ${selectedScheduleDate.formatted}?`)) return;

    const overrides = BookingStorage.getScheduleOverrides();
    const dateSlots = overrides[selectedScheduleDate.formatted];
    if (!dateSlots) return;

    const slot = dateSlots.find(s => s.time === timeSlot);
    if (!slot) return;

    // Remove previous booking for this slot (if admin changed the client)
    if (slot.bookingId) {
        BookingStorage.removeBookingById(slot.bookingId);
    }

    // Create the real booking — visible in Prenotazioni, Clienti, Pagamenti, Le mie prenotazioni
    const booking = {
        name: user.name,
        email: user.email,
        whatsapp: user.whatsapp || '',
        date: selectedScheduleDate.formatted,
        time: timeSlot,
        slotType: slot.type || SLOT_TYPES.GROUP_CLASS,
        notes: '',
        dateDisplay: formatAdminBookingDate(selectedScheduleDate.formatted)
    };
    // Admin assigns client to slot: ensure capacity allows the booking
    const currentCount = BookingStorage.getBookingsForSlot(booking.date, booking.time)
        .filter(b => b.status === 'confirmed' && b.slotType === booking.slotType).length;
    const result = await BookingStorage.saveBooking(booking, currentCount + 1);
    if (!result.ok) {
        showToast('⚠️ Errore: prenotazione non riuscita. Riprova.', 'error');
        renderAllTimeSlots();
        return;
    }

    // Store client and bookingId in the override for display purposes
    slot.client = { name: user.name, email: user.email, whatsapp: user.whatsapp || '' };
    slot.bookingId = result.booking.id;
    BookingStorage.saveScheduleOverrides(overrides, [selectedScheduleDate.formatted]);
    invalidateStatsCache();
    renderAllTimeSlots();
}

// Rimuove cliente e prenotazione da uno "Slot prenotato" (group-class).
// La cancellazione e' solo cambio stato via RPC cancel_booking (la conversione
// group-class -> small-group la fa il server). NESSUN rimborso credito, mora o bonus.
async function clearSlotClient(timeSlot) {
    if (!selectedScheduleDate) return;

    const overrides = BookingStorage.getScheduleOverrides();
    const dateSlots = overrides[selectedScheduleDate.formatted];
    if (!dateSlots) return;

    const slot = dateSlots.find(s => s.time === timeSlot);
    if (!slot || !slot.bookingId) return;

    const allBookings = [...BookingStorage.getAllBookings()];
    const index = allBookings.findIndex(b => b.id === slot.bookingId);
    if (index === -1) {
        // Booking not found in cache — just clear the slot
        delete slot.client;
        delete slot.bookingId;
        BookingStorage.saveScheduleOverrides(overrides, [selectedScheduleDate.formatted]);
        renderAllTimeSlots();
        return;
    }

    const booking = allBookings[index];
    const bookingName = booking.name || slot.client?.name || '';

    if (!confirm(`Confermare l'annullamento della prenotazione di ${bookingName}?`)) return;

    // Helper to finalize: clear slot override + render
    const finalizeSlotClear = () => {
        const ov = BookingStorage.getScheduleOverrides();
        const ds = ov[selectedScheduleDate.formatted];
        if (ds) {
            const s = ds.find(x => x.time === timeSlot);
            if (s) { delete s.client; delete s.bookingId; }
            BookingStorage.saveScheduleOverrides(ov, [selectedScheduleDate.formatted]);
        }
        renderAllTimeSlots();
    };

    // Cancellazione server via RPC atomica (cambio stato + conversione slot lato server)
    if (typeof supabaseClient !== 'undefined' && booking._sbId) {
        try {
            const { data, error } = await _rpcWithTimeout(
                supabaseClient.rpc('cancel_booking', { p_booking_id: booking._sbId })
            );
            if (error) throw new Error(error.message);
            if (data && !data.success && data.error !== 'already_cancelled') {
                throw new Error(data.error || 'Errore sconosciuto');
            }
        } catch (e) {
            console.error('[clearSlotClient] cancel_booking error:', e);
            if (typeof showToast === 'function') showToast('⚠️ Errore annullamento. Riprova.', 'error', 5000);
            return;
        }
    }

    // Aggiorna cache locale: solo cambio stato (nessun rimborso/mora/bonus)
    allBookings[index] = {
        ...booking,
        cancelledPaymentMethod: booking.paymentMethod,
        cancelledPaidAt: booking.paidAt,
        status: 'cancelled',
        cancelledAt: new Date().toISOString(),
        paid: false, paymentMethod: null, paidAt: null,
    };
    BookingStorage.replaceAllBookings(allBookings);
    finalizeSlotClear();
}
