// Calendar functionality
let currentWeekOffset = 0;
let selectedSlot = null;
let selectedMobileDay = null;

function spotsColorClass(n) {
    if (n === 1) return 'spots-red';
    if (n === 2) return 'spots-orange';
    return 'spots-dark';
}

function _isLoggedIn() {
    return typeof getCurrentUser === 'function' && getCurrentUser() != null;
}

function _isUserEnrolled(date, time, slotType) {
    const user = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
    if (!user) return false;
    const bookings = BookingStorage.getBookingsForSlot(date, time);
    return bookings.some(b => b.userId === user.id && b.status === 'confirmed' && (!b.slotType || b.slotType === slotType));
}

function _isUserEnrolledOnDate(date) {
    const user = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
    if (!user) return false;
    const all = BookingStorage.getAllBookings();
    return all.some(b => b.date === date && b.userId === user.id && b.status === 'confirmed');
}

function _autoAdvanceWeek() {
    if (currentWeekOffset !== 0) return;
    const weekDates = getWeekDatesDesktop(0);
    const hasAvailable = weekDates.some(d => dateHasAvailableSlots(d));
    if (!hasAvailable && weekHasSlotsDesktop(1)) {
        currentWeekOffset = 1;
    }
}

function initCalendar() {
    _autoAdvanceWeek();
    renderCalendar();
    renderMobileCalendar();
    setupCalendarControls();
    setupMobileStickyOffsets();
}

let _mobileStickyResizeHandler = null;
function setupMobileStickyOffsets() {
    const navbar = document.querySelector('.navbar');
    const weekNav = document.querySelector('.mobile-week-nav');
    const daySelector = document.querySelector('.mobile-day-selector');
    if (!navbar || !weekNav || !daySelector) return;

    const navH = navbar.offsetHeight - 3;
    weekNav.style.top = navH + 'px';
    if (_mobileStickyResizeHandler) window.removeEventListener('resize', _mobileStickyResizeHandler);
    _mobileStickyResizeHandler = () => { daySelector.style.top = (navH + weekNav.offsetHeight) + 'px'; };
    _mobileStickyResizeHandler();
    window.addEventListener('resize', _mobileStickyResizeHandler);
}

function setupCalendarControls() {
    // Desktop controls
    document.getElementById('prevWeek').addEventListener('click', () => {
        if (currentWeekOffset > 0) {
            currentWeekOffset--;
            renderCalendar();
            renderMobileCalendar();
        }
    });

    document.getElementById('nextWeek').addEventListener('click', () => {
        currentWeekOffset++;
        renderCalendar();
        renderMobileCalendar();
    });

    // Mobile controls
    const mobilePrev = document.getElementById('mobilePrevWeek');
    const mobileNext = document.getElementById('mobileNextWeek');

    if (mobilePrev) {
        mobilePrev.addEventListener('click', () => {
            if (currentWeekOffset > 0) {
                currentWeekOffset--;
                renderCalendar();
                renderMobileCalendar();
            }
        });
    }

    if (mobileNext) {
        mobileNext.addEventListener('click', () => {
            currentWeekOffset++;
            renderCalendar();
            renderMobileCalendar();
        });
    }

    // Swipe orizzontale sul selettore giorni per cambiare settimana
    const daySelector = document.getElementById('mobileDaySelector');
    if (daySelector) {
        let touchStartX = 0;
        daySelector.addEventListener('touchstart', e => {
            touchStartX = e.touches[0].clientX;
        }, { passive: true });
        daySelector.addEventListener('touchend', e => {
            const dx = e.changedTouches[0].clientX - touchStartX;
            if (Math.abs(dx) < 50) return;
            if (dx < 0) {
                // Swipe sinistra → settimana successiva
                if (weekHasSlotsDesktop(currentWeekOffset + 1)) {
                    currentWeekOffset++;
                    renderCalendar();
                    renderMobileCalendar();
                }
            } else if (currentWeekOffset > 0) {
                // Swipe destra → settimana precedente
                currentWeekOffset--;
                renderCalendar();
                renderMobileCalendar();
            }
        }, { passive: true });
    }
}

function getWeekDates(offset = 0) {
    const now = new Date();
    const today = new Date(now);
    today.setHours(0, 0, 0, 0);

    // Dopo le 20:30 non ci sono più lezioni disponibili oggi: parti da domani
    const minutesNow = now.getHours() * 60 + now.getMinutes();
    if (offset === 0 && minutesNow >= 20 * 60 + 30) {
        today.setDate(today.getDate() + 1);
    }

    // Start from today (offset 0 = today, offset 1 = today + 7 days, etc.)
    const startDate = new Date(today);
    startDate.setDate(today.getDate() + offset * 7);

    const allDayNames = ['Domenica', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato'];
    const dates = [];

    for (let i = 0; i < 7; i++) {
        const date = new Date(startDate);
        date.setDate(startDate.getDate() + i);
        dates.push({
            date: date,
            dayName: allDayNames[date.getDay()],
            formatted: formatDate(date),
            displayDate: `${date.getDate()}/${date.getMonth() + 1}`
        });
    }

    return dates;
}

// Desktop: mostra Lunedì-Domenica della settimana corrente
function getWeekDatesDesktop(offset = 0) {
    const now = new Date();
    const today = new Date(now);
    today.setHours(0, 0, 0, 0);

    // Trova il lunedì della settimana corrente
    const dayOfWeek = today.getDay(); // 0=Dom, 1=Lun, ..., 6=Sab
    const diffToMonday = dayOfWeek === 0 ? -6 : 1 - dayOfWeek;
    const monday = new Date(today);
    monday.setDate(today.getDate() + diffToMonday + offset * 7);

    const allDayNames = ['Domenica', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato'];
    const dates = [];

    for (let i = 0; i < 7; i++) { // Lun-Dom = 7 giorni
        const date = new Date(monday);
        date.setDate(monday.getDate() + i);
        dates.push({
            date: date,
            dayName: allDayNames[date.getDay()],
            formatted: formatDate(date),
            displayDate: `${date.getDate()}/${date.getMonth() + 1}`
        });
    }

    return dates;
}

function formatDate(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

function weekHasSlots(offset) {
    const overrides = BookingStorage.getScheduleOverrides();
    return getWeekDates(offset).some(d => overrides[d.formatted] && overrides[d.formatted].length > 0);
}

function weekHasSlotsDesktop(offset) {
    const overrides = BookingStorage.getScheduleOverrides();
    return getWeekDatesDesktop(offset).some(d => overrides[d.formatted] && overrides[d.formatted].length > 0);
}

function renderCalendar() {
    const weekDates = getWeekDatesDesktop(currentWeekOffset);
    const calendarGrid = document.getElementById('calendar');
    calendarGrid.innerHTML = '';

    // Disable "previous" button when already showing from today
    const prevBtn = document.getElementById('prevWeek');
    prevBtn.disabled = currentWeekOffset === 0;
    prevBtn.style.opacity = currentWeekOffset === 0 ? '0.3' : '1';
    prevBtn.style.cursor = currentWeekOffset === 0 ? 'not-allowed' : 'pointer';

    // Disable "next" button when the next week has no configured slots
    const nextBtn = document.getElementById('nextWeek');
    const nextHasSlots = weekHasSlotsDesktop(currentWeekOffset + 1);
    nextBtn.disabled = !nextHasSlots;
    nextBtn.style.opacity = nextHasSlots ? '1' : '0.3';
    nextBtn.style.cursor = nextHasSlots ? 'pointer' : 'not-allowed';

    // Update week display
    const firstDate = weekDates[0].date;
    const lastDate = weekDates[weekDates.length - 1].date;
    document.getElementById('currentWeek').textContent =
        `${firstDate.getDate()}/${firstDate.getMonth() + 1} - ${lastDate.getDate()}/${lastDate.getMonth() + 1}/${lastDate.getFullYear()}`;

    // Create header row
    const timeHeader = createDiv('calendar-header', '');
    calendarGrid.appendChild(timeHeader);

    weekDates.forEach(dateInfo => {
        const header = createDiv('calendar-header', `
            <div>${dateInfo.dayName}</div>
            <div style="font-size: 0.85rem; opacity: 0.8;">${dateInfo.displayDate}</div>
        `);
        calendarGrid.appendChild(header);
    });

    // Create time slots rows
    TIME_SLOTS.forEach(timeSlot => {
        // Time label
        const timeLabel = createDiv('calendar-time', timeSlot);
        calendarGrid.appendChild(timeLabel);

        // Day slots
        weekDates.forEach(dateInfo => {
            const slot = createSlot(dateInfo, timeSlot);
            calendarGrid.appendChild(slot);
        });
    });
}

// Slot types that are not bookable by users (no spots shown, no click)
function _isNonBookable(type) {
    return type === SLOT_TYPES.GROUP_CLASS || type === SLOT_TYPES.CLEANING;
}

function createSlot(dateInfo, timeSlot) {
    const slot = document.createElement('div');
    slot.className = 'calendar-slot';

    const overrides = BookingStorage.getScheduleOverrides();
    const scheduledSlots = overrides[dateInfo.formatted] || [];
    const scheduledSlot = scheduledSlots.find(s => s.time === timeSlot);

    if (!scheduledSlot) {
        slot.innerHTML = '<div style="color: #ccc; font-size: 0.85rem;">-</div>';
        slot.style.cursor = 'default';
        return slot;
    }

    const mainType = scheduledSlot.type;
    const extras   = scheduledSlot.extras || [];
    const extraTypes = [...new Set(extras.map(e => e.type).filter(t => t !== mainType))];
    const hasMixedExtras = extraTypes.length > 0;

    const _tp1 = _parseSlotTime(timeSlot);
    let timeOk = false;
    if (_tp1) {
        const lessonStart = new Date(dateInfo.date);
        lessonStart.setHours(_tp1.startH, _tp1.startM, 0, 0);
        timeOk = (new Date() - lessonStart) <= 30 * 60 * 1000;
    }
    if (!timeOk && _isLoggedIn()) { slot.style.opacity = '0.35'; slot.style.filter = 'grayscale(0.8)'; }

    if (!hasMixedExtras) {
        // Vista unificata (stesso tipo o nessun extra)
        const loggedIn = _isLoggedIn();
        const remainingSpots = BookingStorage.getRemainingSpots(dateInfo.formatted, timeSlot, mainType);
        const isFull = remainingSpots <= 0;
        const enrolled = loggedIn && _isUserEnrolled(dateInfo.formatted, timeSlot, mainType);
        slot.classList.add('has-booking', mainType);
        if (loggedIn && isFull) slot.classList.add('slot-full');
        if (enrolled) slot.classList.add('user-enrolled');
        slot.innerHTML = `
            <div class="slot-type">${SLOT_NAMES[mainType]}</div>
            ${enrolled ? '<div class="slot-enrolled-badge">Qui ti alleni 💪🏼</div>' : (loggedIn && !_isNonBookable(mainType) ? `<div class="slot-spots ${spotsColorClass(remainingSpots)}">${isFull ? 'Completo' : remainingSpots + (remainingSpots === 1 ? ' disponibile' : ' disponibili')}</div>` : '')}
        `;
        if (loggedIn) {
            const bookable = !isFull && timeOk && !_isNonBookable(mainType);
            // Slot pieni o con iscrizione restano cliccabili per mostrare "Persone iscritte"
            const clickable = bookable || isFull || enrolled;
            slot.style.cursor = clickable ? 'pointer' : 'not-allowed';
            if (clickable) slot.addEventListener('click', () => selectSlot(dateInfo, timeSlot, mainType, remainingSpots));
        } else if (!_isNonBookable(mainType) && timeOk) {
            slot.style.cursor = 'pointer';
            slot.addEventListener('click', () => selectSlot(dateInfo, timeSlot, mainType, remainingSpots));
        } else {
            slot.style.cursor = 'default';
        }
    } else {
        // Vista divisa: metà sinistra = tipo principale, metà destra = extra diversi
        slot.classList.add('has-booking', 'split-slot');

        const loggedInSplit = _isLoggedIn();
        const buildHalf = (type) => {
            const rem = BookingStorage.getRemainingSpots(dateInfo.formatted, timeSlot, type);
            const full = rem <= 0;
            const enrolledHalf = loggedInSplit && _isUserEnrolled(dateInfo.formatted, timeSlot, type);
            const half = document.createElement('div');
            half.className = `split-slot-half ${type}${loggedInSplit && full ? ' slot-full' : ''}${enrolledHalf ? ' user-enrolled' : ''}`;
            half.innerHTML = `
                <div class="slot-type">${SLOT_NAMES[type]}</div>
                ${enrolledHalf ? '<div class="slot-enrolled-badge">Qui ti alleni 💪🏼</div>' : (loggedInSplit && !_isNonBookable(type) ? `<div class="slot-spots ${spotsColorClass(rem)}">${full ? 'Completo' : rem + ' disp.'}</div>` : '')}
            `;
            if (loggedInSplit) {
                const bookable = !full && timeOk && !_isNonBookable(type);
                const clickableHalf = bookable || full || enrolledHalf;
                half.style.cursor = clickableHalf ? 'pointer' : 'not-allowed';
                if (clickableHalf) half.addEventListener('click', e => { e.stopPropagation(); selectSlot(dateInfo, timeSlot, type, rem); });
            } else if (!_isNonBookable(type) && timeOk) {
                half.style.cursor = 'pointer';
                half.addEventListener('click', e => { e.stopPropagation(); selectSlot(dateInfo, timeSlot, type, rem); });
            } else {
                half.style.cursor = 'default';
            }
            return half;
        };

        slot.appendChild(buildHalf(mainType));
        extraTypes.forEach(t => slot.appendChild(buildHalf(t)));
    }

    return slot;
}

function selectSlot(dateInfo, timeSlot, slotType, remainingSpots) {
    selectedSlot = {
        date: dateInfo.formatted,
        dateDisplay: `${dateInfo.dayName} ${dateInfo.displayDate}`,
        time: timeSlot,
        slotType: slotType,
        remainingSpots: remainingSpots
    };
    openBookingModal(dateInfo, timeSlot, slotType, remainingSpots);
}

function createDiv(className, innerHTML) {
    const div = document.createElement('div');
    div.className = className;
    div.innerHTML = innerHTML;
    return div;
}

// Check if a date still has available (future) slots considering the 30-min rule
function dateHasAvailableSlots(dateInfo) {
    const overrides = BookingStorage.getScheduleOverrides();
    const scheduledSlots = overrides[dateInfo.formatted] || [];
    if (scheduledSlots.length === 0) return false;
    const now = new Date();
    const thirtyMinMs = 30 * 60 * 1000;
    return scheduledSlots.some(slot => {
        const tp = _parseSlotTime(slot.time);
        if (!tp) return false;
        const lessonStart = new Date(dateInfo.date);
        lessonStart.setHours(tp.startH, tp.startM, 0, 0);
        return (now - lessonStart) <= thirtyMinMs;
    });
}

// Mobile Calendar Functions
function renderMobileCalendar() {
    const weekDates = getWeekDatesDesktop(currentWeekOffset);

    // Update mobile week label
    const mobileWeekLabel = document.getElementById('mobileWeekLabel');
    if (mobileWeekLabel) {
        const first = weekDates[0].date;
        const last = weekDates[6].date;
        mobileWeekLabel.textContent = `${first.getDate()}/${first.getMonth() + 1} – ${last.getDate()}/${last.getMonth() + 1}`;
    }

    // Update mobile prev/next button states
    const mobilePrev = document.getElementById('mobilePrevWeek');
    if (mobilePrev) {
        mobilePrev.disabled = currentWeekOffset === 0;
        mobilePrev.style.opacity = currentWeekOffset === 0 ? '0.3' : '1';
        mobilePrev.style.cursor  = currentWeekOffset === 0 ? 'not-allowed' : 'pointer';
    }

    const mobileNext = document.getElementById('mobileNextWeek');
    if (mobileNext) {
        const nextHasSlots = weekHasSlotsDesktop(currentWeekOffset + 1);
        mobileNext.disabled = !nextHasSlots;
        mobileNext.style.opacity = nextHasSlots ? '1' : '0.3';
        mobileNext.style.cursor  = nextHasSlots ? 'pointer' : 'not-allowed';
    }

    // Preserve current selection if it's still in this week, otherwise auto-select
    const currentInWeek = selectedMobileDay
        ? weekDates.find(d => d.formatted === selectedMobileDay.formatted)
        : null;
    if (currentInWeek && dateHasAvailableSlots(currentInWeek)) {
        selectedMobileDay = currentInWeek;
    } else {
        const todayStr = formatDate(new Date());
        const now = new Date(); now.setHours(0, 0, 0, 0);
        // Pick today if it has available slots, otherwise the next day with slots
        const todayInWeek = weekDates.find(d => d.formatted === todayStr);
        if (todayInWeek && dateHasAvailableSlots(todayInWeek)) {
            selectedMobileDay = todayInWeek;
        } else {
            // Pick first future day that has available slots
            const firstFutureWithSlots = weekDates.find(d => d.date >= now && d.formatted !== todayStr && dateHasAvailableSlots(d));
            if (firstFutureWithSlots) {
                selectedMobileDay = firstFutureWithSlots;
            } else {
                // Fallback: first future day (even without slots)
                const firstFuture = weekDates.find(d => d.date >= now);
                selectedMobileDay = firstFuture || weekDates[0];
            }
        }
    }

    renderMobileDaySelector(weekDates);
    renderMobileSlots(selectedMobileDay);
}

function renderMobileDaySelector(weekDates) {
    const selector = document.getElementById('mobileDaySelector');
    selector.innerHTML = '';

    const monthNames = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'];
    // Index by actual JS day (0=Sun,1=Mon,...) so it works regardless of start day
    const dayNamesShort = ['Dom', 'Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab'];

    const today = new Date();
    today.setHours(0, 0, 0, 0);

    weekDates.forEach((dateInfo) => {
        const dayCard = document.createElement('div');
        dayCard.className = 'mobile-day-card';

        const isPast = dateInfo.date < today || !dateHasAvailableSlots(dateInfo);

        if (isPast) {
            dayCard.classList.add('disabled');
        }

        if (selectedMobileDay && selectedMobileDay.formatted === dateInfo.formatted) {
            dayCard.classList.add('active');
        }

        if (_isLoggedIn() && _isUserEnrolledOnDate(dateInfo.formatted)) {
            dayCard.classList.add('has-enrollment');
        }

        dayCard.innerHTML = `
            <div class="mobile-day-name">${dayNamesShort[dateInfo.date.getDay()]}</div>
            <div class="mobile-day-date">${dateInfo.date.getDate()}</div>
            <div class="mobile-day-month">${monthNames[dateInfo.date.getMonth()]}</div>
        `;

        if (!isPast) {
            dayCard.addEventListener('click', () => {
                selectedMobileDay = dateInfo;
                document.querySelectorAll('.mobile-day-card').forEach(card => card.classList.remove('active'));
                dayCard.classList.add('active');
                renderMobileSlots(dateInfo);
            });
        }

        selector.appendChild(dayCard);
    });
}

function renderMobileSlots(dateInfo) {
    const slotsList = document.getElementById('mobileSlotsList');
    slotsList.innerHTML = '';

    const overrides = BookingStorage.getScheduleOverrides();
    const scheduledSlots = overrides[dateInfo.formatted] || [];

    if (scheduledSlots.length === 0) {
        slotsList.innerHTML = '<div style="text-align: center; color: #999; padding: 2rem;">Nessuna lezione programmata per questo giorno</div>';
        return;
    }

    const now = new Date();
    const thirtyMinMs = 30 * 60 * 1000;

    scheduledSlots.forEach(scheduledSlot => {
        const _tp2 = _parseSlotTime(scheduledSlot.time);
        if (!_tp2) return;
        const lessonStart = new Date(dateInfo.date);
        lessonStart.setHours(_tp2.startH, _tp2.startM, 0, 0);
        if ((now - lessonStart) > thirtyMinMs) return;

        // Card tipo principale — mostra sempre (anche se completo)
        slotsList.appendChild(createMobileSlotCard(dateInfo, scheduledSlot));

        // Card tipi extra diversi dal principale
        const extras = scheduledSlot.extras || [];
        const extraTypes = [...new Set(extras.map(e => e.type).filter(t => t !== scheduledSlot.type))];
        extraTypes.forEach(extraType => {
            slotsList.appendChild(createMobileSlotCard(dateInfo, { ...scheduledSlot, type: extraType }));
        });
    });

    if (!slotsList.hasChildNodes()) {
        slotsList.innerHTML = '<div style="text-align: center; color: #999; padding: 2rem;">Nessuna lezione disponibile per questo giorno</div>';
    }
}

function createMobileSlotCard(dateInfo, scheduledSlot) {
    const slotCard = document.createElement('div');
    slotCard.className = `mobile-slot-card ${scheduledSlot.type}`;

    const timeSlot = scheduledSlot.time;
    const slotType = scheduledSlot.type;
    const loggedIn = _isLoggedIn();
    const remainingSpots = BookingStorage.getRemainingSpots(dateInfo.formatted, timeSlot, slotType);
    const isFull = remainingSpots <= 0;
    const enrolled = loggedIn && _isUserEnrolled(dateInfo.formatted, timeSlot, slotType);

    if (loggedIn && isFull) {
        slotCard.classList.add('slot-full');
    }
    if (enrolled) slotCard.classList.add('user-enrolled');

    if (slotType === SLOT_TYPES.CLEANING) {
        slotCard.innerHTML = `
            <div class="mobile-slot-header">
                <span class="mobile-slot-time">🕐 ${timeSlot}</span>
            </div>
            <div class="mobile-slot-type">🧹 Pulizia</div>`;
        slotCard.style.cursor = 'default';
        return slotCard;
    }

    slotCard.innerHTML = `
        <div class="mobile-slot-header">
            <span class="mobile-slot-time">🕐 ${timeSlot}</span>
            ${enrolled ? '<span class="mobile-slot-enrolled">Qui ti alleni 💪🏼</span>' : (loggedIn && !_isNonBookable(slotType) ? `<span class="mobile-slot-available ${spotsColorClass(remainingSpots)}">${isFull ? 'Completo' : remainingSpots + (remainingSpots === 1 ? ' disponibile' : ' disponibili')}</span>` : '')}
        </div>
        <div class="mobile-slot-type">${SLOT_NAMES[slotType]}</div>
    `;

    // Allow booking if not full and less than 30 min have passed since lesson start
    const _tp3 = _parseSlotTime(timeSlot);
    let timeOk = false;
    if (_tp3) {
        const lessonStart = new Date(dateInfo.date);
        lessonStart.setHours(_tp3.startH, _tp3.startM, 0, 0);
        timeOk = (new Date() - lessonStart) <= 30 * 60 * 1000;
    }

    if (loggedIn) {
        const bookable = !isFull && timeOk;
        const clickable = bookable || isFull || enrolled;
        if (clickable) {
            slotCard.addEventListener('click', () => {
                selectMobileSlot(dateInfo, timeSlot, slotType, remainingSpots, slotCard);
            });
        } else {
            slotCard.style.cursor = 'not-allowed';
        }
    } else if (!_isNonBookable(slotType) && timeOk) {
        slotCard.addEventListener('click', () => {
            selectMobileSlot(dateInfo, timeSlot, slotType, remainingSpots, slotCard);
        });
    } else {
        slotCard.style.cursor = 'default';
    }

    return slotCard;
}

function selectMobileSlot(dateInfo, timeSlot, slotType, remainingSpots, slotCard) {
    selectedSlot = {
        date: dateInfo.formatted,
        dateDisplay: `${dateInfo.dayName} ${dateInfo.displayDate}`,
        time: timeSlot,
        slotType: slotType,
        remainingSpots: remainingSpots
    };
    openBookingModal(dateInfo, timeSlot, slotType, remainingSpots);
}

// Initialize calendar when DOM is loaded
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initCalendar);
} else {
    initCalendar();
}

// Aggiorna i dati quando la pagina viene ripristinata dal bfcache (back/forward)
window.addEventListener('pageshow', (event) => {
    if (event.persisted) {
        renderCalendar();
        renderMobileCalendar();
    }
});
