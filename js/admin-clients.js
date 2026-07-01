/**
 * admin-clients.js — Tab "Clienti" del pannello admin: anagrafica e gestione clienti del tenant.
 *
 * COSA FA
 * Mostra l'elenco dei clienti della org (derivato dalle prenotazioni), con ricerca, filtri
 * per problemi (certificato medico, assicurazione, anagrafica incompleta, privacy, push) e
 * dettaglio espandibile per cliente.
 *
 * COME FUNZIONA
 * - Stato tab: openClientIndex (card aperta), clientsSearchQuery e i flag filtro
 *   clientCertFilter/clientAssicFilter/clientAnagFilter/clientPrivacyFilter/clientPushFilter.
 * - Filtri: toggle*Filter() attivano un filtro per volta (_clearOtherFilters), aggiornano i
 *   pulsanti UI (_syncFilterButtons → #certFilterBtn/#assicFilterBtn/#anagFilterBtn/
 *   #privacyFilterBtn/#pushFilterBtn e #clientsFilterToggle) e ri-renderizzano (renderClientsTab).
 *   toggleClientsFiltersMenu() apre/chiude il menu chip (#clientsFilterChips).
 * - Predicati problema: clientHasCertIssue/clientHasAssicIssue confrontano le scadenze con
 *   _localDateStr(); clientHasAnagIssue verifica codiceFiscale/indirizzo; clientHasPrivacy /
 *   clientHasPushDisabled leggono privacyPrenotazioni / pushEnabled.
 * - Aggregazione: getAllClients() costruisce la lista dai booking usando indici O(1)
 *   (phoneIndex per telefono normalizzato, emailIndex per email) per fondere i duplicati.
 *
 * CONNESSIONI
 * - Legge le prenotazioni da BookingStorage.getAllBookings() (js/data.js).
 * - I dati anagrafici per cliente arrivano da _getUserRecord(email, whatsapp) (definito in
 *   admin-analytics.js, mappato sulla tabella profiles), org-scoped da RLS.
 */
// Clients Tab State
let openClientIndex = null;
// Paginazione lista clienti: costruire tutte le ~N card in un forEach è lento
// (ogni createClientCard è pesante). Renderizziamo a blocchi con "Mostra altri".
const CLIENTS_PAGE_SIZE = 20;
let clientsShown = 0;
let _clientsFiltered = null;
let clientsSearchQuery = '';
let clientCertFilter  = false;
let clientAssicFilter = false;
let clientAnagFilter  = false;
let clientPrivacyFilter = false;
let clientPushFilter    = false;

function clientHasCertIssue(client) {
    const userRecord = _getUserRecord(client.email, client.whatsapp);
    const certScad = userRecord?.certificatoMedicoScadenza || '';
    if (!certScad) return true;
    return certScad < _localDateStr();
}

function clientHasAssicIssue(client) {
    const userRecord = _getUserRecord(client.email, client.whatsapp);
    const assicScad = userRecord?.assicurazioneScadenza || '';
    if (!assicScad) return true;
    return assicScad < _localDateStr();
}

function _syncFilterButtons() {
    document.getElementById('certFilterBtn')?.classList.toggle('active', clientCertFilter);
    document.getElementById('assicFilterBtn')?.classList.toggle('active', clientAssicFilter);
    document.getElementById('anagFilterBtn')?.classList.toggle('active', clientAnagFilter);
    document.getElementById('privacyFilterBtn')?.classList.toggle('active', clientPrivacyFilter);
    document.getElementById('pushFilterBtn')?.classList.toggle('active', clientPushFilter);
    // Evidenzia toggle se un filtro è attivo
    const toggle = document.getElementById('clientsFilterToggle');
    if (toggle) toggle.classList.toggle('active', clientCertFilter || clientAssicFilter || clientAnagFilter || clientPrivacyFilter || clientPushFilter);
}

function toggleClientsFiltersMenu() {
    const chips = document.getElementById('clientsFilterChips');
    const arrow = document.getElementById('clientsFilterToggleArrow');
    const open  = chips.classList.toggle('open');
    if (arrow) arrow.textContent = open ? '▲' : '▼';
}

function _clearOtherFilters(keep) {
    if (keep !== 'cert')    clientCertFilter = false;
    if (keep !== 'assic')   clientAssicFilter = false;
    if (keep !== 'anag')    clientAnagFilter = false;
    if (keep !== 'privacy') clientPrivacyFilter = false;
    if (keep !== 'push')    clientPushFilter = false;
}

function toggleCertFilter() {
    clientCertFilter = !clientCertFilter;
    if (clientCertFilter) _clearOtherFilters('cert');
    _syncFilterButtons();
    renderClientsTab();
}

function toggleAssicFilter() {
    clientAssicFilter = !clientAssicFilter;
    if (clientAssicFilter) _clearOtherFilters('assic');
    _syncFilterButtons();
    renderClientsTab();
}

function clientHasAnagIssue(client) {
    const userRecord = _getUserRecord(client.email, client.whatsapp);
    if (!userRecord) return true;
    const cf   = userRecord.codiceFiscale || '';
    const via  = userRecord.indirizzoVia || '';
    const paese = userRecord.indirizzoPaese || '';
    const cap  = userRecord.indirizzoCap || '';
    return !cf || !via || !paese || !cap;
}

function toggleAnagFilter() {
    clientAnagFilter = !clientAnagFilter;
    if (clientAnagFilter) _clearOtherFilters('anag');
    _syncFilterButtons();
    renderClientsTab();
}

function clientHasPrivacy(client) {
    const userRecord = _getUserRecord(client.email, client.whatsapp);
    return userRecord?.privacyPrenotazioni === true;
}

function togglePrivacyFilter() {
    clientPrivacyFilter = !clientPrivacyFilter;
    if (clientPrivacyFilter) _clearOtherFilters('privacy');
    _syncFilterButtons();
    renderClientsTab();
}

function clientHasPushDisabled(client) {
    const userRecord = _getUserRecord(client.email, client.whatsapp);
    return !userRecord?.pushEnabled;
}

function togglePushFilter() {
    clientPushFilter = !clientPushFilter;
    if (clientPushFilter) _clearOtherFilters('push');
    _syncFilterButtons();
    renderClientsTab();
}


// ===== Clients Tab =====

function getAllClients() {
    const allBookings = BookingStorage.getAllBookings();
    const clientsMap = {};
    // Indici O(1) per evitare il loop annidato su ogni booking
    const phoneIndex = {};   // normPhone → key in clientsMap
    const emailIndex = {};   // email.lower → key in clientsMap

    function _findKey(normPhone, email) {
        if (normPhone && phoneIndex[normPhone]) return phoneIndex[normPhone];
        const emailLow = email ? email.toLowerCase() : '';
        if (emailLow && emailIndex[emailLow]) return emailIndex[emailLow];
        return null;
    }
    function _registerKey(key, normPhone, email) {
        if (normPhone) phoneIndex[normPhone] = key;
        const emailLow = email ? email.toLowerCase() : '';
        if (emailLow) emailIndex[emailLow] = key;
    }

    allBookings.forEach(booking => {
        const normPhone = normalizePhone(booking.whatsapp);
        let matchedKey = _findKey(normPhone, booking.email);
        if (!matchedKey) {
            matchedKey = normPhone || booking.email;
            clientsMap[matchedKey] = { userId: booking.userId || null, name: booking.name, whatsapp: booking.whatsapp, email: booking.email, bookings: [] };
            _registerKey(matchedKey, normPhone, booking.email);
        } else if (!clientsMap[matchedKey].userId && booking.userId) {
            // Arricchisci con userId se il record esistente non lo aveva
            clientsMap[matchedKey].userId = booking.userId;
        }
        clientsMap[matchedKey].bookings.push(booking);
    });

    // Include registered users even without bookings + arricchisci userId per match esistenti
    UserStorage.getAll().forEach(user => {
        const normPhone = normalizePhone(user.whatsapp);
        const existingKey = _findKey(normPhone, user.email);
        if (existingKey) {
            // Cliente già presente (tramite booking): propaga userId dal profilo se mancante
            if (!clientsMap[existingKey].userId && user.userId) {
                clientsMap[existingKey].userId = user.userId;
            }
        } else {
            const key = normPhone || user.email;
            if (key) {
                clientsMap[key] = { userId: user.userId || null, name: user.name, whatsapp: user.whatsapp || '', email: user.email || '', bookings: [] };
                _registerKey(key, normPhone, user.email);
            }
        }
    });

    Object.values(clientsMap).forEach(c => {
        c.bookings.sort((a, b) => b.date.localeCompare(a.date) || b.time.localeCompare(a.time));
    });

    return Object.values(clientsMap).sort((a, b) => a.name.localeCompare(b.name));
}

var liveSearchClients = _debounce(function() {
    const query = document.getElementById('clientSearchInput').value.trim();
    const dropdown = document.getElementById('clientsSearchDropdown');
    if (!query) {
        dropdown.style.display = 'none';
        return;
    }
    const q = query.toLowerCase();
    const allClients = getAllClients();
    const matches = allClients.filter(c =>
        c.name.toLowerCase().includes(q) ||
        c.whatsapp.toLowerCase().includes(q) ||
        (c.email && c.email.toLowerCase().includes(q))
    );
    if (matches.length === 0) {
        dropdown.innerHTML = '<div class="dropdown-no-results">Nessun risultato</div>';
    } else {
        dropdown.innerHTML = matches.slice(0, 15).map((c, i) => {
            return `<div class="dropdown-item" onclick="selectClientFromDropdown(${i})">
                <span class="dropdown-item-name">${_escHtml(c.name)}</span>
            </div>`;
        }).join('');
        dropdown._matches = matches;
    }
    dropdown.style.display = 'block';
}, 200);

function closeClientsSearchDropdown() {
    const dropdown = document.getElementById('clientsSearchDropdown');
    if (dropdown) dropdown.style.display = 'none';
}

function clearClientsSearch() {
    const searchInput = document.getElementById('clientSearchInput');
    if (searchInput) searchInput.value = '';
    closeClientsSearchDropdown();
    // Ripristina stat cards e filtri
    const statsGrid = document.getElementById('clientsStatsGrid');
    const filterToggle = document.getElementById('clientsFilterToggle');
    if (statsGrid) statsGrid.style.display = '';
    if (filterToggle) filterToggle.style.display = '';
    // Nascondi lista (torna allo stato iniziale)
    const listEl = document.getElementById('clientsList');
    if (listEl) { listEl.innerHTML = ''; listEl.style.display = 'none'; }
    clientsListMode = null;
    _updateClientsHints();
}

function selectClientFromDropdown(index) {
    const dropdown = document.getElementById('clientsSearchDropdown');
    const matches = dropdown._matches;
    if (!matches || !matches[index]) return;
    showSingleClientCard(matches[index]);
}

// Mostra la card di un singolo cliente (vista "Risultato ricerca").
// opts.expand: apre subito la card (dettagli visibili senza altro click).
function showSingleClientCard(client, opts) {
    opts = opts || {};
    const container = document.getElementById('clientsList');
    if (!container) return;
    container.innerHTML = '';
    const header = document.createElement('div');
    header.className = 'search-results-header';
    header.innerHTML = '<h4>Risultato ricerca</h4><button class="btn-clear-search" onclick="clearClientsSearch()">✕ Chiudi</button>';
    container.appendChild(header);
    const card = createClientCard(client, 0);
    if (opts.expand) { card.classList.add('open'); openClientIndex = 0; }
    container.appendChild(card);
    container.style.display = '';

    closeClientsSearchDropdown();
    const searchInput = document.getElementById('clientSearchInput');
    if (searchInput) searchInput.value = client.name;
    // Nascondi stat cards e filtri durante la ricerca
    const statsGrid = document.getElementById('clientsStatsGrid');
    const filterToggle = document.getElementById('clientsFilterToggle');
    const filterChips = document.getElementById('clientsFilterChips');
    if (statsGrid) statsGrid.style.display = 'none';
    if (filterToggle) filterToggle.style.display = 'none';
    if (filterChips) filterChips.style.display = 'none';
    card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

// Apre direttamente la card di un cliente dato il nome (usato da "Vedi cliente"
// nel Registro). Ritorna false se il cliente non è trovato (il chiamante fa fallback).
function openClientCardByName(name) {
    const target = (name || '').trim().toLowerCase();
    if (!target) return false;
    const client = getAllClients().find(c => (c.name || '').trim().toLowerCase() === target);
    if (!client) return false;
    showSingleClientCard(client, { expand: true });
    return true;
}


let clientsListMode = null; // null = hidden, 'total' | 'active'

function getActiveClients(allClientsParam) {
    const allClients = allClientsParam || getAllClients();
    const bookings = BookingStorage.getAllBookings();
    const now = new Date();
    const twoMonthsAgo = new Date(now.getFullYear(), now.getMonth() - 2, now.getDate());
    const oneMonthAhead = new Date(now.getFullYear(), now.getMonth() + 1, now.getDate());
    const pad = n => String(n).padStart(2, '0');
    const localDate = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    const cutoffFrom = localDate(twoMonthsAgo);
    const cutoffTo   = localDate(oneMonthAhead);

    const activeEmails = new Set();
    const activePhones = new Set();
    bookings.forEach(b => {
        if (b.status === 'cancelled') return;
        const d = b.date;
        if (d >= cutoffFrom && d <= cutoffTo) {
            if (b.email) activeEmails.add(b.email.toLowerCase());
            if (b.whatsapp) activePhones.add(normalizePhone(b.whatsapp));
        }
    });

    return allClients.filter(c => {
        if (c.email && activeEmails.has(c.email.toLowerCase())) return true;
        if (c.whatsapp && activePhones.has(normalizePhone(c.whatsapp))) return true;
        return false;
    });
}

function renderClientsSummary(allClients, activeClients) {
    if (!allClients) allClients = getAllClients();
    if (!activeClients) activeClients = getActiveClients(allClients);
    document.getElementById('clientsTotalCount').textContent = allClients.length;
    document.getElementById('clientsActiveCount').textContent = activeClients.length;
    const sub = document.getElementById('clientsPageSub');
    if (sub) sub.textContent = `${allClients.length} totali · ${activeClients.length} attivi`;
}

function toggleClientsTotalList() {
    clientsListMode = clientsListMode === 'total' ? null : 'total';
    _updateClientsHints();
    renderClientsTab();
}

function toggleClientsActiveList() {
    clientsListMode = clientsListMode === 'active' ? null : 'active';
    _updateClientsHints();
    renderClientsTab();
}

function _updateClientsHints() {
    const totalHint = document.getElementById('clientsTotalHint');
    const activeHint = document.getElementById('clientsActiveHint');
    if (totalHint) totalHint.textContent = clientsListMode === 'total' ? 'Nascondi ▲' : 'Dettagli ▼';
    if (activeHint) activeHint.textContent = clientsListMode === 'active' ? 'Nascondi ▲' : 'Dettagli ▼';
    document.getElementById('statcard-clienti-totali')?.classList.toggle('active', clientsListMode === 'total');
    document.getElementById('statcard-clienti-attivi')?.classList.toggle('active', clientsListMode === 'active');
}

async function refreshClients() {
    const btn = document.getElementById('refreshClientsBtn');
    if (btn) { btn.textContent = '↻ Caricamento...'; btn.disabled = true; }
    try {
        await UserStorage.syncUsersFromSupabase();
        renderClientsTab();
    } catch (e) {
        console.error('[refreshClients] error:', e);
        if (typeof showToast === 'function') showToast('⚠️ Errore ricarica clienti. Riprova.', 'error', 4000);
    } finally {
        if (btn) { btn.textContent = '↻ Ricarica'; btn.disabled = false; }
    }
}

/**
 * Refreshes only the currently open client card in-place (no full re-render).
 * Works both in "list" mode and "single card from search" mode.
 * Falls back to full renderClientsTab() if the card cannot be found.
 */
function _refreshOpenClientCard(whatsapp, email) {
    renderClientsSummary();

    const normPhone = normalizePhone(whatsapp);
    const emailLow  = (email || '').toLowerCase();

    // Find the open card element in the DOM
    const container = document.getElementById('clientsList');
    if (!container) { renderClientsTab(); return; }
    const openCard = container.querySelector('.client-card.open');
    if (!openCard) { renderClientsTab(); return; }

    // Determine what index the card currently has
    const oldId = openCard.id; // e.g. "client-card-0"

    // Get fresh client data
    const allClients = getAllClients();
    const client = allClients.find(c =>
        (normPhone && normalizePhone(c.whatsapp) === normPhone) ||
        (emailLow && (c.email || '').toLowerCase() === emailLow)
    );
    if (!client) {
        // Client no longer exists (e.g. all bookings deleted) — full re-render
        openClientIndex = null;
        renderClientsTab();
        return;
    }

    // Build a new card with the same index (keeps DOM position)
    const idxMatch = oldId.match(/client-card-(\d+)/);
    const cardIndex = idxMatch ? parseInt(idxMatch[1], 10) : 0;
    const newCard = createClientCard(client, cardIndex);
    newCard.classList.add('open');

    openCard.replaceWith(newCard);
    openClientIndex = cardIndex;
}

function _activeFilterLabel() {
    if (clientCertFilter)    return '🏥 Senza certificato';
    if (clientAssicFilter)   return '📋 Senza assicurazione';
    if (clientAnagFilter)    return '📝 Senza anagrafica';
    if (clientPrivacyFilter) return '🔒 Anonimi';
    if (clientPushFilter)    return '🔕 Notifiche Disattivate';
    return '';
}

function renderClientsTab() {
    // Calcola lista clienti UNA volta sola per render (era chiamato 2-3 volte)
    const _allClients = getAllClients();
    const _activeClients = getActiveClients(_allClients);
    renderClientsSummary(_allClients, _activeClients);
    // Ripristina stat cards e filtri (nascosti durante ricerca)
    const statsGrid = document.getElementById('clientsStatsGrid');
    const filterToggle = document.getElementById('clientsFilterToggle');
    const filterResult = document.getElementById('clientsFilterResult');
    if (filterToggle) filterToggle.style.display = '';
    // Pulisci campo ricerca
    const searchInput = document.getElementById('clientSearchInput');
    if (searchInput) searchInput.value = '';
    closeClientsSearchDropdown();
    const listEl = document.getElementById('clientsList');
    const hasFilter = clientCertFilter || clientAssicFilter || clientAnagFilter || clientPrivacyFilter || clientPushFilter;

    // Nasconde stat cards e mostra conteggio filtrato quando un filtro è attivo
    if (statsGrid) statsGrid.style.display = hasFilter ? 'none' : '';
    if (filterResult) filterResult.style.display = hasFilter ? '' : 'none';

    if (!clientsListMode && !hasFilter) {
        if (listEl) listEl.style.display = 'none';
        return;
    }
    if (listEl) listEl.style.display = '';
    // Se un filtro è attivo senza lista, usa tutti i clienti come base
    const baseClients = clientsListMode === 'active' ? _activeClients : _allClients;
    let filtered = baseClients;
    if (clientCertFilter)  filtered = filtered.filter(clientHasCertIssue);
    if (clientAssicFilter) filtered = filtered.filter(clientHasAssicIssue);
    if (clientAnagFilter)  filtered = filtered.filter(clientHasAnagIssue);
    if (clientPrivacyFilter) filtered = filtered.filter(clientHasPrivacy);
    if (clientPushFilter)    filtered = filtered.filter(clientHasPushDisabled);

    // Aggiorna conteggio filtrato
    if (hasFilter && filterResult) {
        filterResult.innerHTML = `<span class="filter-result-label">${_activeFilterLabel()}</span><span class="filter-result-count">${filtered.length}</span>`;
    }

    const container = document.getElementById('clientsList');
    container.innerHTML = '';

    if (filtered.length === 0) {
        container.innerHTML = '<div class="empty-slot">Nessun cliente trovato</div>';
        return;
    }

    // Paginazione: costruire tutte le card in una volta è lento con molti clienti.
    // Renderizziamo a blocchi (CLIENTS_PAGE_SIZE) con un bottone "Mostra altri clienti".
    _clientsFiltered = filtered;
    clientsShown = 0;
    // Se una card era aperta oltre il primo blocco, estendi il primo batch per includerla.
    let firstBatch = CLIENTS_PAGE_SIZE;
    if (openClientIndex !== null && openClientIndex + 1 > firstBatch) {
        firstBatch = Math.ceil((openClientIndex + 1) / CLIENTS_PAGE_SIZE) * CLIENTS_PAGE_SIZE;
    }
    _appendClientBatch(firstBatch);
}

// Renderizza il prossimo blocco di card cliente e aggiorna il bottone "Mostra altri clienti".
function _appendClientBatch(n) {
    const container = document.getElementById('clientsList');
    if (!container) return;
    document.getElementById('clientsLoadMoreBtn')?.remove();
    const filtered = _clientsFiltered || [];
    const end = Math.min(clientsShown + n, filtered.length);
    for (let i = clientsShown; i < end; i++) {
        try {
            container.appendChild(createClientCard(filtered[i], i));
        } catch (e) {
            console.error(`[_appendClientBatch] errore card cliente "${filtered[i]?.name || '?'}":`, e);
        }
    }
    clientsShown = end;
    // Ripristina la card aperta se ora è nel DOM
    if (openClientIndex !== null) {
        const card = document.getElementById(`client-card-${openClientIndex}`);
        if (card) card.classList.add('open');
    }
    // Bottone "Mostra altri clienti" se ne restano da renderizzare
    const remaining = filtered.length - clientsShown;
    if (remaining > 0) {
        const btn = document.createElement('button');
        btn.id = 'clientsLoadMoreBtn';
        btn.className = 'show-more-btn clients-load-more';
        btn.textContent = `▼ Mostra altri ${Math.min(CLIENTS_PAGE_SIZE, remaining)} clienti (${remaining} rimanenti)`;
        btn.onclick = () => _appendClientBatch(CLIENTS_PAGE_SIZE);
        container.appendChild(btn);
    }
}

function toggleClientCard(id, idx) {
    const card = document.getElementById(id);
    if (!card) return;
    const isOpen = card.classList.toggle('open');
    openClientIndex = isOpen ? idx : null;
}

// Switch segmentato Prenotazioni ⇄ Storico dentro la card cliente: mostra un pannello per volta.
function switchClientSeg(index, seg) {
    const card = document.getElementById(`client-card-${index}`);
    if (!card) return;
    card.querySelectorAll('.cv2-seg-btn').forEach(b => {
        const on = b.dataset.seg === seg;
        b.classList.toggle('active', on);
        b.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    card.querySelectorAll('.cv2-seg-panel').forEach(p => { p.hidden = (p.dataset.seg !== seg); });
}

// "▼ Mostra altri N": rivela in blocchi le righe .pag-item nascoste di una lista paginata
// (prenotazioni della card cliente). A fine paginazione rivela un eventuale elemento collegato
// via data-reveal-on-done (es. "Carica storico completo") e si rimuove.
function _showMoreItems(btn, stepCount) {
    const containerId = btn.dataset.container;
    const container = containerId ? document.getElementById(containerId) : btn.parentElement;
    if (!container) return;
    const shown = parseInt(btn.dataset.shown, 10);
    const total = parseInt(btn.dataset.total, 10);
    const items = container.querySelectorAll('.pag-item');
    const newShown = Math.min(shown + stepCount, total);
    for (let i = shown; i < newShown; i++) {
        if (items[i]) items[i].style.display = '';
    }
    btn.dataset.shown = newShown;
    if (newShown >= total) {
        const revealId = btn.dataset.revealOnDone;
        if (revealId) { const el = document.getElementById(revealId); if (el) el.style.display = ''; }
        btn.remove();
    } else {
        btn.textContent = `▼ Mostra altri ${Math.min(stepCount, total - newShown)}`;
    }
}

// Icone SVG (stroke currentColor → il colore lo dà la classe del contenitore/bottone).
const CV2_PHONE_SVG = '<svg class="cv2-contact-ic" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.9.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92z"/></svg>';
const CV2_MAIL_SVG = '<svg class="cv2-contact-ic" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 7-10 6L2 7"/></svg>';
const CV2_EDIT_SVG = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4Z"/></svg>';
const CV2_TRASH_SVG = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/></svg>';

function createClientCard(client, index) {
    const card = document.createElement('div');
    card.className = 'client-card';
    card.id = `client-card-${index}`;

    const activeBookings = client.bookings.filter(b => b.status !== 'cancelled');
    // Totale dovuto = lezioni passate non pagate (nessun credito/sconto: modello pay-per-session)
    const totalUnpaid = activeBookings.filter(b => !b.paid && bookingHasPassed(b) && b.status !== 'cancellation_requested').reduce((s, b) => s + getBookingPrice(b), 0);

    // Certificato medico e Assicurazione dal profilo utente
    const userRecord  = _getUserRecord(client.email, client.whatsapp);
    const certScad    = userRecord?.certificatoMedicoScadenza || '';
    const assicScad2  = userRecord?.assicurazioneScadenza || '';
    const _wEscBadge  = _escAttr(client.whatsapp || '');
    const _emEscBadge = _escAttr(client.email || '');
    const _nEscBadge  = _escAttr(client.name);
    const _mkBadge = (scad, missingLabel, expiredPrefix, expiringPrefix, okPrefix, onClickAttr) => {
        const oc = onClickAttr ? ` onclick="event.stopPropagation(); ${onClickAttr}"` : '';
        const tag = onClickAttr ? 'button' : 'span';
        const tagAttr = onClickAttr ? ' type="button"' : '';
        const clickCls = onClickAttr ? ' cedit-cert-badge--clickable' : '';
        if (!scad) return `<${tag}${tagAttr} class="cedit-cert-badge cedit-cert-expired${clickCls}"${oc}>${missingLabel}</${tag}>`;
        const today = _localDateStr();
        const [y, m, d] = scad.split('-');
        const label = `${d}/${m}/${y}`;
        if (scad < today) return `<${tag}${tagAttr} class="cedit-cert-badge cedit-cert-expired${clickCls}"${oc}>${expiredPrefix} ${label}</${tag}>`;
        const daysLeft = Math.ceil((new Date(scad + 'T00:00:00') - new Date()) / 86400000);
        if (daysLeft <= 30) return `<${tag}${tagAttr} class="cedit-cert-badge cedit-cert-expiring${clickCls}"${oc}>${expiringPrefix} ${label}</${tag}>`;
        return `<${tag}${tagAttr} class="cedit-cert-badge cedit-cert-ok${clickCls}"${oc}>${okPrefix} ${label}</${tag}>`;
    };
    const certDisplay  = BookingBadgesStorage.getShowCert()
        ? _mkBadge(certScad, '🏥 Imposta scadenza certificato medico', '🏥 Cert. scaduto il', '⏳ Cert. scade il', '✅ Cert. valido fino al',
            `openCertModal(this,'${_emEscBadge}','${_wEscBadge}','${_nEscBadge}')`)
        : '';
    const assicDisplay = BookingBadgesStorage.getShowAssic()
        ? _mkBadge(assicScad2, '📋 Imposta scadenza assicurazione', '📋 Assic. scaduta il', '⏳ Assic. scade il', '📋 Assic. valida fino al',
            `openAssicModal(this,'${_emEscBadge}','${_wEscBadge}','${_nEscBadge}')`)
        : '';
    const docFirmato2  = userRecord?.documentoFirmato || false;
    const docDisplay   = BookingBadgesStorage.getShowDoc()
        ? `<button type="button" class="cedit-cert-badge cedit-cert-badge--clickable ${docFirmato2 ? 'cedit-cert-ok' : 'cedit-cert-expired'}" onclick="event.stopPropagation(); openEditClientPopup(${index},'${_wEscBadge}','${_emEscBadge}','${_nEscBadge}')">${docFirmato2 ? '✅ Documento firmato' : '📝 Documento non firmato'}</button>`
        : '';
    // Anagrafica incompleta (CF, indirizzo)
    const hasAnagComplete = userRecord?.codiceFiscale && userRecord?.indirizzoVia && userRecord?.indirizzoPaese && userRecord?.indirizzoCap;
    const anagDisplay = (BookingBadgesStorage.getShowAnag() && !hasAnagComplete)
        ? `<button type="button" class="cedit-cert-badge cedit-cert-badge--clickable cedit-cert-expiring" onclick="event.stopPropagation(); openEditClientPopup(${index},'${_wEscBadge}','${_emEscBadge}','${_nEscBadge}')">📋 Completa anagrafica</button>`
        : '';

    const _methodShort = m => ({ contanti: 'Contanti', 'contanti-report': 'Contanti (report)', carta: 'Carta', iban: 'Bonifico', stripe: 'Stripe', gratuito: 'Gratuita', 'lezione-gratuita': 'Gratuita' }[m] || '');

    // ── Righe-card PRENOTAZIONI (barra colore per tipo slot, org-aware via getSlotColor) ──
    const bookingRows = client.bookings.map((b, bIdx) => {
        const dateShort = b.date.split('-').reverse().slice(0, 2).join('/');
        const dateFull  = b.date.split('-').reverse().join('/');
        const isCancelPending = b.status === 'cancellation_requested';
        const isCancelled     = b.status === 'cancelled';
        const isFree = b.paid && (b.paymentMethod === 'gratuito' || b.paymentMethod === 'lezione-gratuita');
        const rowClass = ['book-row', 'pag-item',
            bookingHasPassed(b) ? '' : 'future-booking',
            isCancelPending ? 'row-cancel-pending' : '',
            isCancelled ? 'row-cancelled' : ''].filter(Boolean).join(' ');
        const nEsc = _escAttr(b.name);
        const barColor = isCancelled ? '#e5e7eb' : ((typeof getSlotColor === 'function') ? getSlotColor(b.slotType) : '#cbd5e1');
        const statusPill = isCancelled
            ? `<span class="payment-status" style="background:#f3f4f6;color:#6b7280">✕ Annullata</span>`
            : isCancelPending
                ? `<span class="payment-status" style="background:#fef3c7;color:#92400e">⏳ Annullamento</span>`
                : isFree
                    ? `<span class="payment-status" style="background:#f3f4f6;color:#6b7280">🎁 Gratuita</span>`
                    : b.paid
                        ? `<span class="payment-status paid">✓ Pagato${_methodShort(b.paymentMethod) ? ' con ' + _methodShort(b.paymentMethod) : ''}</span>`
                        : `<span class="payment-status unpaid">Non pagato</span>`;
        const actions = (!isCancelled ? `<button class="btn-row-edit" onclick="openBookingEditPopup('${b.id}', ${index})" title="Modifica">${CV2_EDIT_SVG}</button>` : '')
            + `<button class="btn-row-delete" onclick="deleteBookingFromClients('${b.id}', '${nEsc}')" title="Elimina">${CV2_TRASH_SVG}</button>`;
        return `<div id="brow-${b.id}" class="${rowClass}"${bIdx >= 5 ? ' style="display:none"' : ''} title="${_escAttr(SLOT_NAMES[b.slotType] || '')} · ${dateFull} · ${b.time}">
            <span class="book-row-bar" style="background:${barColor}"></span>
            <div class="book-row-main">
                <div class="book-row-type">${SLOT_NAMES[b.slotType] || ''}</div>
                <div class="book-row-when">${dateShort} · ${b.time}</div>
            </div>
            <div class="book-row-side">
                ${statusPill}
                <div class="book-row-actions">${actions}</div>
            </div>
        </div>`;
    });
    const bTotal = bookingRows.length;
    const bookingsHTML = bTotal ? bookingRows.join('') : '<div class="cv2-seg-empty">Nessuna prenotazione</div>';
    const listId = `brows-${index}`;

    // ── Storico movimenti (incassi): prenotazioni pagate = entrata (+€), gratuite = €0 ──
    const _movs = client.bookings
        .filter(b => b.status !== 'cancelled' && b.paid)
        .map(b => {
            const free = b.paymentMethod === 'gratuito' || b.paymentMethod === 'lezione-gratuita';
            return {
                sortKey: b.paidAt || (b.date + 'T00:00:00'),
                dateShort: b.date.split('-').reverse().slice(0, 2).join('/'),
                time: b.time,
                label: SLOT_NAMES[b.slotType] || 'Lezione',
                method: _methodShort(b.paymentMethod),
                free,
                price: free ? 0 : getBookingPrice(b)
            };
        })
        .sort((a, b) => new Date(b.sortKey) - new Date(a.sortKey));
    const storicoCount = _movs.length;
    const storicoRows = _movs.map(m => {
        const amt = m.free
            ? `<span class="tx-row-amount free">€0</span>`
            : `<span class="tx-row-amount plus">+€${Math.round(m.price * 100) / 100}</span>`;
        return `<div class="tx-row ${m.free ? 'tx-free' : 'tx-plus'}">
            <span class="tx-row-bar"></span>
            <div class="tx-row-main">
                <div class="tx-row-label"><span class="tx-row-ic">${m.free ? '🎁' : '💰'}</span>${_escHtml(m.label)}${m.method ? ' · ' + _escHtml(m.method) : ''}</div>
                <div class="tx-row-when">${m.dateShort} · ${_escHtml(m.time)}</div>
            </div>
            <div class="tx-row-side">${amt}</div>
        </div>`;
    }).join('');
    const storicoHTML = storicoCount
        ? `<div class="client-credit-history">${storicoRows}</div>`
        : `<div class="cv2-seg-empty">Nessun incasso registrato</div>`;

    const fullHistBtnId = `fullhist-btn-${index}`;
    const showMoreBooksBtn = bTotal > 5
        ? `<button class="show-more-btn" onclick="_showMoreItems(this,10)" data-container="${listId}" data-shown="5" data-total="${bTotal}" data-reveal-on-done="${fullHistBtnId}" style="margin-top:0.5rem;">▼ Mostra altri ${Math.min(10, bTotal - 5)}</button>`
        : '';
    // Storico completo on-demand: la cache è finestrata a 60gg passati, quindi le prenotazioni
    // (anche pagate) più vecchie non compaiono. Il bottone le carica al volo per QUESTO cliente.
    // Con >5 prenotazioni resta nascosto finché non si esaurisce la paginazione (reveal-on-done).
    const fullHistBtnHTML = client._fullHistoryLoaded
        ? '<div class="client-fullhist-note" style="margin-top:0.5rem;font-size:0.8rem;color:#16a34a;">✓ Storico completo caricato</div>'
        : `<button id="${fullHistBtnId}" class="show-more-btn" onclick="loadClientFullHistory(this, ${index})" style="margin-top:0.5rem;${bTotal > 5 ? 'display:none;' : ''}">📜 Carica storico completo</button>`;

    // ── Schede assegnate ──────────────────────────────────────────────────
    const clientUserId = userRecord?.id || client.userId || null;
    const clientPlans = clientUserId ? WorkoutPlanStorage.getPlansByUser(clientUserId) : [];
    let schedeHTML = '';
    if (clientPlans.length > 0) {
        const planRows = clientPlans.map(plan => {
            const badge = plan.active
                ? '<span class="schede-badge-active" style="font-size:0.7rem;padding:1px 6px;margin-left:6px;">Attiva</span>'
                : '<span class="schede-badge-inactive" style="font-size:0.7rem;padding:1px 6px;margin-left:6px;">Inattiva</span>';
            const exCount = (plan.workout_exercises || []).length;
            const days = [...new Set((plan.workout_exercises || []).map(e => e.day_label))];
            return `<div class="client-scheda-row">
                <div class="client-scheda-info">
                    <span class="client-scheda-name">${_escHtml(plan.name)}${badge}</span>
                    <span class="client-scheda-meta">${exCount} esercizi · ${days.length} giorn${days.length === 1 ? 'o' : 'i'}</span>
                </div>
                <div class="client-scheda-actions">
                    <button class="btn-row-edit" onclick="event.stopPropagation(); clientSaveAsTemplate('${plan.id}', '${_escHtml(plan.name).replace(/'/g, "\\'")}')" title="Salva come template">📋</button>
                    <button class="btn-row-edit" onclick="event.stopPropagation(); clientGoToEditScheda('${plan.id}')" title="Modifica scheda">✏️</button>
                    <button class="btn-row-delete" onclick="event.stopPropagation(); clientDeleteScheda('${plan.id}', '${_escHtml(plan.name)}')" title="Rimuovi scheda">🗑️</button>
                </div>
            </div>`;
        }).join('');
        schedeHTML = `<div class="client-schede-section">
            <h4>📋 Schede assegnate</h4>
            ${planRows}
        </div>`;
    }

    const wEsc  = _escAttr(client.whatsapp);
    const emEsc = _escAttr(client.email || '');
    const nEsc  = _escAttr(client.name);

    // Avatar iniziali (max 2 lettere)
    const initials = (client.name || '?').trim().split(/\s+/).map(w => w[0] || '').join('').toUpperCase().slice(0, 2);
    const phoneRaw = (client.whatsapp || '').replace(/^\+39\s*/, '');
    // Link WhatsApp: normalizza a sole cifre, 0039→39, e prefissa 39 ai numeri nazionali (10 cifre da 3).
    let phoneWa = (client.whatsapp || '').replace(/\D/g, '');
    if (phoneWa.startsWith('0039')) phoneWa = phoneWa.slice(2);
    if (phoneWa.length === 10 && phoneWa.startsWith('3')) phoneWa = '39' + phoneWa;

    // 3 celle stat: Prenot. Future / Sessioni residue (pacchetto) / Da saldare
    // I valori economici (sessioni residue) sono caricati async da client_packages.
    const futureBookingsCount = activeBookings.filter(b => !bookingHasPassed(b)).length;
    const dueCls = totalUnpaid > 0 ? 'red' : '';
    const dueVal = `€${Math.round(totalUnpaid * 100) / 100}`;
    const statsGridHTML = `
        <div class="cv2-stat blue"><div class="v">${futureBookingsCount}</div><div class="l">Prenot. Future</div></div>
        <div class="cv2-stat" id="cv2-sessions-${index}"><div class="v">—</div><div class="l">Sessioni residue</div></div>
        <div class="cv2-stat ${dueCls}"><div class="v">${dueVal}</div><div class="l">Da saldare</div></div>
    `;

    // ── Economia cliente (modello nuovo: pacchetto / abbonamento / incassato) ──
    // Sezione popolata async da client_packages / client_memberships / payments.
    // I pagamenti si gestiscono dal tab Pagamenti (admin_pay_bookings / admin_sell_package
    // / admin_record_membership_payment): qui è SOLA LETTURA.
    const economyHTML = `<div class="client-credit-section" id="client-economy-${index}">
            <h4>📊 Situazione economica</h4>
            <div class="client-economy-body">Caricamento…</div>
        </div>`;

    card.innerHTML = `
        <div class="client-card-header" onclick="toggleClientCard('client-card-${index}', ${index})">
            <div class="cv2-avatar" aria-hidden="true">${initials || '?'}</div>
            <div class="client-info-block">
                <div class="client-name">${_escHtml(client.name)} <button class="btn-edit-contact-icon" onclick="event.stopPropagation(); openEditClientPopup(${index}, '${wEsc}', '${emEsc}', '${nEsc}')" title="Modifica contatto">✏️</button></div>
                <div class="client-contacts">
                    ${phoneRaw ? `<a class="cv2-contact-link" href="https://wa.me/${_escHtml(phoneWa)}" target="_blank" rel="noopener" onclick="event.stopPropagation()">${CV2_PHONE_SVG}<span class="cv2-contact-txt">${_escHtml(phoneRaw)}</span></a>` : ''}
                    ${client.email ? `<a class="cv2-contact-link" href="mailto:${_escHtml(client.email)}" onclick="event.stopPropagation()">${CV2_MAIL_SVG}<span class="cv2-contact-txt">${_escHtml(client.email)}</span></a>` : ''}
                </div>
                <div class="cv2-badges-row">
                    ${certDisplay}${assicDisplay}${anagDisplay}${docDisplay}
                </div>
            </div>
            <div class="client-chevron">▼</div>
        </div>
        <div class="client-stats-block cv2-stats-grid" onclick="toggleClientCard('client-card-${index}', ${index})">${statsGridHTML}</div>
        <div class="client-card-body">
            <div class="cv2-segmented" role="tablist">
                <button class="cv2-seg-btn active" role="tab" data-seg="pren" aria-selected="true" onclick="switchClientSeg(${index}, 'pren')">Prenotazioni · ${bTotal}</button>
                <button class="cv2-seg-btn" role="tab" data-seg="storico" aria-selected="false" onclick="switchClientSeg(${index}, 'storico')">Storico · ${storicoCount}</button>
            </div>
            <div class="cv2-seg-panel" data-seg="pren" role="tabpanel">
                <div class="client-bookings-list" id="${listId}">${bookingsHTML}</div>
                ${showMoreBooksBtn}
                ${fullHistBtnHTML}
            </div>
            <div class="cv2-seg-panel" data-seg="storico" role="tabpanel" hidden>
                ${storicoHTML}
            </div>
            ${schedeHTML}
            ${economyHTML}
        </div>
    `;

    // Riferimento al client object per il re-render dopo "Carica storico completo".
    card._client = client;

    // Carica in background la situazione economica (pacchetto/abbonamento/incassato)
    _loadClientEconomy(index, clientUserId, client.email);

    return card;
}

// Carica lo storico COMPLETO del cliente (anche prenotazioni pagate >60gg, fuori dalla cache
// finestrata) via query mirata per-cliente, lo fonde nella card e ri-renderizza preservando lo
// stato aperto. La cache "live" vince sui duplicati (più fresca dopo prenota/annulla/saldo).
async function loadClientFullHistory(btn, index) {
    const card = document.getElementById(`client-card-${index}`);
    const client = card && card._client;
    if (!client) return;
    btn.disabled = true;
    const _orig = btn.textContent;
    btn.textContent = '⏳ Caricamento…';
    try {
        const rows = (typeof BookingStorage !== 'undefined' && typeof BookingStorage.fetchClientHistory === 'function')
            ? await BookingStorage.fetchClientHistory({
                userId:   client.userId || null,
                email:    client.email || null,
                whatsapp: client.whatsapp || null,
              })
            : null;
        if (!rows) {
            btn.disabled = false; btn.textContent = _orig;
            if (typeof showToast === 'function') showToast('Impossibile caricare lo storico completo', 'error');
            return;
        }
        // Merge dedup per _sbId/id: la copia "live" (cache) vince → no flash "Non pagato" su una
        // lezione appena saldata che lo storico ripescato avrebbe ancora come non pagata.
        const byKey = new Map();
        for (const b of rows) byKey.set(b._sbId || b.id, b);
        for (const b of client.bookings) byKey.set(b._sbId || b.id, b);
        client.bookings = [...byKey.values()].sort((a, b) => b.date.localeCompare(a.date) || b.time.localeCompare(a.time));
        client._fullHistoryLoaded = true;
        // Rebuild della card preservando lo stato aperto (toggleClientCard è CSS-only su .open).
        const wasOpen = card.classList.contains('open');
        const fresh = createClientCard(client, index);
        if (wasOpen) fresh.classList.add('open');
        card.replaceWith(fresh);
    } catch (e) {
        console.error('[Clienti] loadClientFullHistory error:', e);
        btn.disabled = false; btn.textContent = _orig;
        if (typeof showToast === 'function') showToast('Errore caricamento storico', 'error');
    }
}

// ── Carica e renderizza la situazione economica del cliente (modello nuovo) ──
// (a) pacchetto attivo + sessioni residue (client_packages)
// (b) abbonamento attivo (client_memberships)
// (c) totale incassato dal cliente (somma payments)
// SOLA LETTURA: nessuna azione economica qui (vedi tab Pagamenti).
async function _loadClientEconomy(index, userId, email) {
    const section = document.getElementById(`client-economy-${index}`);
    const body = section?.querySelector('.client-economy-body');
    const sessionsStat = document.getElementById(`cv2-sessions-${index}`);
    if (typeof supabaseClient === 'undefined') {
        if (body) body.innerHTML = '<div class="client-economy-empty">Dati economici non disponibili offline.</div>';
        return;
    }

    const emailLow = (email || '').toLowerCase();
    const fmtDate = ds => ds ? ds.split('-').reverse().join('/') : '';

    try {
        // Query parallele: pacchetti attivi, abbonamenti attivi, pagamenti del cliente.
        // RLS filtra già org_id; per pacchetti/abbonamenti serve lo user_id (profiles).
        const pkgQ = userId
            ? supabaseClient.from('client_packages')
                .select('label, total_sessions, remaining_sessions, expires_at, status, purchased_at')
                .eq('user_id', userId).eq('status', 'active')
                .order('purchased_at', { ascending: false })
            : Promise.resolve({ data: [] });
        const memQ = userId
            ? supabaseClient.from('client_memberships')
                .select('plan_label, period_start, period_end, lessons_quota, lessons_used, status')
                .eq('user_id', userId).eq('status', 'active')
                .order('period_end', { ascending: false })
            : Promise.resolve({ data: [] });
        let payQ = supabaseClient.from('payments').select('amount, client_email, client_user_id');
        // Filtra per user_id quando disponibile, altrimenti per email
        if (userId)        payQ = payQ.eq('client_user_id', userId);
        else if (emailLow) payQ = payQ.eq('client_email', emailLow);
        else               payQ = null;

        const [pkgRes, memRes, payRes] = await Promise.all([
            _rpcWithTimeout(pkgQ).catch(e => ({ error: e })),
            _rpcWithTimeout(memQ).catch(e => ({ error: e })),
            payQ ? _rpcWithTimeout(payQ).catch(e => ({ error: e })) : Promise.resolve({ data: [] }),
        ]);

        const packages    = (pkgRes && !pkgRes.error && pkgRes.data) || [];
        const memberships = (memRes && !memRes.error && memRes.data) || [];
        const payments    = (payRes && !payRes.error && payRes.data) || [];

        const totalCollected = payments.reduce((s, p) => s + (Number(p.amount) || 0), 0);
        const remainingSessions = packages.reduce((s, p) => s + (Number(p.remaining_sessions) || 0), 0);

        // Aggiorna la stat "Sessioni residue"
        if (sessionsStat) {
            const v = sessionsStat.querySelector('.v');
            if (v) v.textContent = packages.length ? remainingSessions : '—';
        }

        if (!section || !body) return;

        // (a) Pacchetto attivo
        let pkgHTML = '';
        if (packages.length) {
            pkgHTML = packages.map(p => `
                <div class="client-economy-row">
                    <span class="client-economy-icon">🎟️</span>
                    <span class="client-economy-label">${_escHtml(p.label || 'Pacchetto')}
                        <small style="opacity:0.7">${p.expires_at ? `scade ${fmtDate(p.expires_at)}` : 'senza scadenza'}</small>
                    </span>
                    <span class="client-economy-value">${Number(p.remaining_sessions) || 0}/${Number(p.total_sessions) || 0} sessioni</span>
                </div>`).join('');
        } else {
            pkgHTML = '<div class="client-economy-row client-economy-empty"><span class="client-economy-icon">🎟️</span><span class="client-economy-label">Nessun pacchetto attivo</span></div>';
        }

        // (b) Abbonamento attivo
        let memHTML = '';
        if (memberships.length) {
            memHTML = memberships.map(m => {
                const quota = m.lessons_quota != null
                    ? `${Number(m.lessons_used) || 0}/${m.lessons_quota} lezioni`
                    : 'illimitato';
                return `
                <div class="client-economy-row">
                    <span class="client-economy-icon">📅</span>
                    <span class="client-economy-label">${_escHtml(m.plan_label || 'Abbonamento')}
                        <small style="opacity:0.7">fino al ${fmtDate(m.period_end)}</small>
                    </span>
                    <span class="client-economy-value">${quota}</span>
                </div>`;
            }).join('');
        } else {
            memHTML = '<div class="client-economy-row client-economy-empty"><span class="client-economy-icon">📅</span><span class="client-economy-label">Nessun abbonamento attivo</span></div>';
        }

        // (c) Totale incassato
        const collectedHTML = `
            <div class="client-economy-row client-economy-total">
                <span class="client-economy-icon">💰</span>
                <span class="client-economy-label">Totale incassato</span>
                <span class="client-economy-value">€${Math.round(totalCollected * 100) / 100}</span>
            </div>`;

        body.innerHTML = pkgHTML + memHTML + collectedHTML;
    } catch (e) {
        console.error('[_loadClientEconomy] error:', e);
        if (body) body.innerHTML = '<div class="client-economy-empty">Errore nel caricamento dei dati economici.</div>';
    }
}

// ── Schede helpers from Clienti tab ──────────────────────────────────────────
function clientGoToEditScheda(planId) {
    if (typeof _schedeEditPlan === 'function' && typeof switchTab === 'function') {
        switchTab('schede');
        _schedeEditPlan(planId);
    }
}

async function clientSaveAsTemplate(planId, planName) {
    const tplName = await showPrompt('Nome del template', planName);
    if (!tplName) return;
    try {
        await WorkoutPlanStorage.duplicatePlan(planId, null, tplName);
        if (typeof showToast === 'function') showToast('Template creato!', 'success');
    } catch (e) {
        console.error('clientSaveAsTemplate error:', e);
        if (typeof showToast === 'function') showToast('Errore creazione template', 'error');
    }
}

async function clientDeleteScheda(planId, planName) {
    if (!await showConfirm(`Eliminare la scheda "${planName}" e tutti gli esercizi associati?`)) return;
    try {
        await WorkoutPlanStorage.deletePlan(planId);
        if (typeof showToast === 'function') showToast('Scheda eliminata', 'success');
        renderClientsTab();
    } catch (e) {
        console.error('clientDeleteScheda error:', e);
        if (typeof showToast === 'function') showToast('Errore eliminazione scheda', 'error');
    }
}

function openEditClientPopup(index, whatsapp, email, name) {
    // Cerca il client per email/whatsapp (non per indice, che cambia con i filtri attivi)
    const clients = getAllClients();
    const client = clients.find(c =>
        (email && c.email && c.email.toLowerCase() === email.toLowerCase()) ||
        (whatsapp && c.whatsapp && normalizePhone(c.whatsapp) === normalizePhone(whatsapp))
    ) || clients[index];
    if (!client) return;

    const userRecord = _getUserRecord(client.email, client.whatsapp);
    const certScad   = userRecord?.certificatoMedicoScadenza || '';
    const assicScad  = userRecord?.assicurazioneScadenza || '';
    const cf         = userRecord?.codiceFiscale || '';
    const via        = userRecord?.indirizzoVia || '';
    const paese      = userRecord?.indirizzoPaese || '';
    const cap        = userRecord?.indirizzoCap || '';
    const docFirmato = userRecord?.documentoFirmato || false;
    const stripeEn   = userRecord?.stripeEnabled || false;

    // Remove existing popup if any
    document.getElementById('editClientPopupOverlay')?.remove();

    const overlay = document.createElement('div');
    overlay.id = 'editClientPopupOverlay';
    overlay.className = 'edit-client-popup-overlay';
    overlay.innerHTML = `
        <div class="edit-client-popup">
            <div class="edit-client-popup-header">
                <h3>Modifica contatto</h3>
                <button class="edit-client-popup-close" onclick="closeEditClientPopup()">&times;</button>
            </div>
            <div class="edit-client-popup-body">
                <div class="edit-client-popup-section">
                    <h4>Dati personali</h4>
                    <label>Nome<input type="text" id="cedit-name-${index}" value="${_escHtml(client.name)}"></label>
                    <label>WhatsApp<input type="tel" id="cedit-phone-${index}" value="${_escHtml(client.whatsapp)}"></label>
                    <label>Email<input type="email" id="cedit-email-${index}" value="${_escHtml(client.email || '')}"></label>
                </div>
                <div class="edit-client-popup-section">
                    <h4>Dati fiscali</h4>
                    <label>Codice Fiscale<input type="text" id="cedit-cf-${index}" value="${_escHtml(cf)}" maxlength="16" style="text-transform:uppercase"></label>
                </div>
                <div class="edit-client-popup-section">
                    <h4>Indirizzo di residenza</h4>
                    <label>Via/Indirizzo<input type="text" id="cedit-via-${index}" value="${_escHtml(via)}"></label>
                    <div class="edit-client-popup-row">
                        <label class="edit-client-popup-flex2">Comune<input type="text" id="cedit-paese-${index}" value="${_escHtml(paese)}"></label>
                        <label class="edit-client-popup-flex1">CAP<input type="text" id="cedit-cap-${index}" value="${_escHtml(cap)}" maxlength="5"></label>
                    </div>
                </div>
                <div class="edit-client-popup-section">
                    <h4>Documenti</h4>
                    <div class="edit-client-popup-row">
                        <label class="edit-client-popup-flex1">Cert. Medico<input type="date" id="cedit-cert-${index}" value="${certScad}"></label>
                        <label class="edit-client-popup-flex1">Assicurazione<input type="date" id="cedit-assic-${index}" value="${assicScad}"></label>
                    </div>
                    <div class="cedit-toggle-row">
                        <label for="cedit-docfirmato-${index}" class="cedit-toggle-label">Documento firmato</label>
                        <label class="cedit-toggle-switch">
                            <input type="checkbox" id="cedit-docfirmato-${index}" ${docFirmato ? 'checked' : ''}>
                            <span class="cedit-toggle-slider"></span>
                        </label>
                    </div>
                    <div class="cedit-toggle-row">
                        <label for="cedit-stripe-${index}" class="cedit-toggle-label">Abilita Stripe</label>
                        <label class="cedit-toggle-switch">
                            <input type="checkbox" id="cedit-stripe-${index}" ${stripeEn ? 'checked' : ''}>
                            <span class="cedit-toggle-slider"></span>
                        </label>
                    </div>
                </div>
            </div>
            <div class="edit-client-popup-actions">
                <button class="btn-delete-client" onclick="event.stopPropagation(); deleteClientData(${index}, '${_escHtml(whatsapp)}', '${_escHtml(email)}')" title="Elimina tutti i dati del cliente">🗑️ Elimina</button>
                <button class="btn-cancel-edit" onclick="closeEditClientPopup()">Annulla</button>
                <button class="btn-save-edit" onclick="saveClientEdit(${index}, '${_escHtml(whatsapp)}', '${_escHtml(email)}')">Salva</button>
            </div>
        </div>
    `;
    document.body.appendChild(overlay);
    // Prevent clicks on overlay from propagating to elements behind
    overlay.addEventListener('click', e => { e.stopPropagation(); });
    setTimeout(() => overlay.classList.add('open'), 10);
}

function closeEditClientPopup() {
    const overlay = document.getElementById('editClientPopupOverlay');
    if (overlay) {
        overlay.classList.remove('open');
        setTimeout(() => overlay.remove(), 200);
    }
}

// Helper: aggiorna profilo locale (users), cert, assic, CF, indirizzo, sessione dopo rename
async function _saveClientEditLocalProfile(index, oldWhatsapp, oldEmail, newName, newWhatsapp, newEmail, newCert, newAssic, normOld, normNewPhone, extraFields) {
    let _profileSyncFailed = false;
    const users  = _getUsersFull();
    const oldEmailLow = (oldEmail || '').toLowerCase();
    let userIdx = users.findIndex(u => {
        const phoneMatch = normOld && normalizePhone(u.whatsapp) === normOld;
        const emailMatch = oldEmailLow && u.email && u.email.toLowerCase() === oldEmailLow;
        return phoneMatch || emailMatch;
    });

    if (userIdx === -1) {
        users.push({ name: newName, email: newEmail, whatsapp: normNewPhone, createdAt: new Date().toISOString() });
        userIdx = users.length - 1;
    }

    if (userIdx !== -1) {
        users[userIdx].name     = newName;
        users[userIdx].whatsapp = normNewPhone;
        if (newEmail) users[userIdx].email = newEmail;

        const oldCert = users[userIdx].certificatoMedicoScadenza || '';
        if (newCert !== oldCert) {
            users[userIdx].certificatoMedicoScadenza = newCert || null;
            if (!users[userIdx].certificatoMedicoHistory) users[userIdx].certificatoMedicoHistory = [];
            users[userIdx].certificatoMedicoHistory.push({ scadenza: newCert || null, aggiornatoIl: new Date().toISOString() });
        }
        const oldAssic = users[userIdx].assicurazioneScadenza || '';
        if (newAssic !== oldAssic) {
            users[userIdx].assicurazioneScadenza = newAssic || null;
            if (!users[userIdx].assicurazioneHistory) users[userIdx].assicurazioneHistory = [];
            users[userIdx].assicurazioneHistory.push({ scadenza: newAssic || null, aggiornatoIl: new Date().toISOString() });
        }

        // CF e indirizzo
        const ef = extraFields || {};
        if (ef.cf !== undefined)    users[userIdx].codiceFiscale   = ef.cf || null;
        if (ef.via !== undefined)   users[userIdx].indirizzoVia    = ef.via || null;
        if (ef.paese !== undefined) users[userIdx].indirizzoPaese  = ef.paese || null;
        if (ef.cap !== undefined)   users[userIdx].indirizzoCap    = ef.cap || null;
        if (ef.documentoFirmato !== undefined) users[userIdx].documentoFirmato = !!ef.documentoFirmato;
        if (ef.stripeEnabled !== undefined)    users[userIdx].stripeEnabled    = !!ef.stripeEnabled;

        _saveUsers(users);

        const _supaFields = { name: newName };
        if (newEmail) _supaFields.email = newEmail.toLowerCase();
        if (normNewPhone) _supaFields.whatsapp = normNewPhone;
        if (newCert !== oldCert) _supaFields.medical_cert_expiry = newCert || null;
        if (newAssic !== oldAssic) _supaFields.insurance_expiry = newAssic || null;
        if (ef.cf !== undefined)    _supaFields.codice_fiscale   = ef.cf || null;
        if (ef.via !== undefined)   _supaFields.indirizzo_via    = ef.via || null;
        if (ef.paese !== undefined) _supaFields.indirizzo_paese  = ef.paese || null;
        if (ef.cap !== undefined)   _supaFields.indirizzo_cap    = ef.cap || null;
        if (ef.documentoFirmato !== undefined) _supaFields.documento_firmato = !!ef.documentoFirmato;
        // Usa i VECCHI valori per trovare il record nel DB (non i nuovi che non esistono ancora)
        const profileResult = await _updateSupabaseProfile(oldEmail, normOld, _supaFields);
        if (!profileResult.ok) {
            _profileSyncFailed = true;
            showToast('⚠️ Profilo locale aggiornato, ma errore Supabase: ' + profileResult.error, 'error');
        }

        const current = getCurrentUser();
        if (current) {
            const sessionPhone = normalizePhone(current.whatsapp);
            const sessionEmail = (current.email || '').toLowerCase();
            const isLogged = (normOld && sessionPhone === normOld) || (oldEmailLow && sessionEmail === oldEmailLow);
            if (isLogged) loginUser({ ...current, name: newName, email: newEmail || current.email, whatsapp: normNewPhone });
        }
    }

    openClientIndex = null;
    renderClientsTab();
    // Aggiorna anche la vista giornaliera admin (badge cert/doc/assic)
    if (typeof renderAdminDayView === 'function' && window._currentAdminDate) renderAdminDayView(window._currentAdminDate);
    // Se c'era una ricerca attiva, riesegui con il nome aggiornato
    const searchInput = document.getElementById('clientSearchInput');
    if (searchInput && searchInput.value.trim()) {
        searchInput.value = newName;
        liveSearchClients();
        // Auto-seleziona il cliente appena modificato
        const dropdown = document.getElementById('clientsSearchDropdown');
        if (dropdown && dropdown._matches && dropdown._matches.length > 0) {
            selectClientFromDropdown(0);
        }
    }
    if (!_profileSyncFailed) showToast('Contatto aggiornato.', 'success');
}

async function saveClientEdit(index, oldWhatsapp, oldEmail) {
    const newName     = document.getElementById(`cedit-name-${index}`).value.trim().replace(/\S+/g, w => w[0].toUpperCase() + w.slice(1).toLowerCase());
    const newWhatsapp = document.getElementById(`cedit-phone-${index}`).value.trim();
    const newEmail    = document.getElementById(`cedit-email-${index}`).value.trim();
    const newCert     = document.getElementById(`cedit-cert-${index}`).value;
    const newAssic    = document.getElementById(`cedit-assic-${index}`).value;
    const newCf       = (document.getElementById(`cedit-cf-${index}`)?.value || '').trim().toUpperCase();
    const newVia      = (document.getElementById(`cedit-via-${index}`)?.value || '').trim();
    const newPaese    = (document.getElementById(`cedit-paese-${index}`)?.value || '').trim();
    const newCap      = (document.getElementById(`cedit-cap-${index}`)?.value || '').trim();
    const newDocFirmato = document.getElementById(`cedit-docfirmato-${index}`)?.checked || false;
    const newStripeEn   = document.getElementById(`cedit-stripe-${index}`)?.checked || false;
    if (!newName) { showAlert('Il nome è obbligatorio.', { type:'warn' }); return; }

    const normOld      = normalizePhone(oldWhatsapp);
    const normNewPhone = normalizePhone(newWhatsapp) || newWhatsapp;

    // ── Gating piano: blocca la CREAZIONE di un nuovo cliente oltre il limite ──
    // Questo form salva di norma un cliente esistente, ma _saveClientEditLocalProfile
    // crea un nuovo record (profiles) quando il contatto editato non corrisponde a
    // nessun utente già presente. In quel caso (= nuovo cliente) applichiamo il limite
    // del piano. Fail-open: se Entitlements non è definito non blocchiamo nulla.
    const _isExistingClient = !!_getUserRecord(oldEmail, oldWhatsapp);
    if (!_isExistingClient && typeof Entitlements !== 'undefined' && Entitlements.atClientLimit()) {
        const _cur = Entitlements.clientsCount();
        const _max = Entitlements.maxClients();
        const _msg = `Hai raggiunto il limite di clienti del tuo piano (${_cur}/${_max}). Passa a un piano superiore dalle Impostazioni → Billing SaaS.`;
        if (typeof showToast === 'function') showToast('⚠️ ' + _msg, 'error', 6000);
        else showAlert(_msg, { type:'error' });
        return;
    }

    // ── Rinomina profilo + bookings: atomico server-side (niente credito) ──
    if (typeof supabaseClient !== 'undefined') {
        // Mostra stato di caricamento sul bottone Salva
        const saveBtn = document.querySelector('#editClientPopupOverlay .btn-save-edit');
        if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Salvataggio...'; }

        // Fase 1 — RPC di rinomina (atomica server-side). Solo qui un errore = rinomina fallita.
        let renameOk = false;
        try {
            const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('admin_rename_client', {
                p_old_email:    oldEmail || '',
                p_old_whatsapp: normOld || null,
                p_new_name:     newName,
                p_new_email:    newEmail,
                p_new_whatsapp: normNewPhone,
            }));
            if (error) {
                console.error('[Supabase] admin_rename_client error:', error.message);
                // Il server rifiuta la creazione di clienti oltre la soglia del piano
                // (RPC → 'client_limit_reached'): mostra un messaggio chiaro.
                if (error.message && error.message.includes('client_limit_reached')) {
                    const _limMsg = 'Hai raggiunto il limite di clienti del tuo piano. Passa a un piano superiore dalle Impostazioni → Billing SaaS.';
                    if (typeof showToast === 'function') showToast('⚠️ ' + _limMsg, 'error', 6000);
                    else showAlert(_limMsg, { type:'error' });
                } else {
                    showAlert('Errore durante l\'aggiornamento: ' + error.message, { type:'error' });
                }
                return;
            }
            console.log('[admin_rename_client]', data);
            renameOk = true;
        } catch (e) {
            console.error('[saveClientEdit] RPC exception:', e);
            const isTimeout = e && e.message === 'rpc_timeout';
            showAlert(isTimeout
                ? 'Timeout durante l\'aggiornamento. Verifica la connessione e riprova.'
                : 'Errore di rete. Riprova.', { type:'error' });
            return;
        } finally {
            if (!renameOk && saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Salva'; }
        }

        // Fase 2 — sync + profilo locale (best-effort: la rinomina è già persistita lato server)
        try {
            await BookingStorage.syncFromSupabase().catch(e => console.warn('[Clients] booking sync:', e?.message || e));
            await _saveClientEditLocalProfile(index, oldWhatsapp, oldEmail, newName, newWhatsapp, newEmail, newCert, newAssic, normOld, normNewPhone, { cf: newCf, via: newVia, paese: newPaese, cap: newCap, documentoFirmato: newDocFirmato, stripeEnabled: newStripeEn });
        } catch (e) {
            console.error('[saveClientEdit] post-rename sync/UI exception:', e);
            showToast('Nome aggiornato. Aggiornamento vista non riuscito — ricarica la pagina per vederlo dappertutto.', 'error', 6000);
        } finally {
            if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Salva'; }
            closeEditClientPopup();
        }
        return;
    }

    // Fallback client-side (offline)
    const bookings = BookingStorage.getAllBookings();
    bookings.forEach(b => {
        const phoneMatch = normOld && normalizePhone(b.whatsapp) === normOld;
        const emailMatch = oldEmail && b.email && b.email.toLowerCase() === oldEmail.toLowerCase();
        if (phoneMatch || emailMatch) {
            b.name     = newName;
            b.whatsapp = normNewPhone;
            b.email    = newEmail;
        }
    });
    BookingStorage.replaceAllBookings(bookings);

    // Profilo locale + cert/assic + sessione
    await _saveClientEditLocalProfile(index, oldWhatsapp, oldEmail, newName, newWhatsapp, newEmail, newCert, newAssic, normOld, normNewPhone, { cf: newCf, via: newVia, paese: newPaese, cap: newCap, documentoFirmato: newDocFirmato, stripeEnabled: newStripeEn });
    closeEditClientPopup();
}

async function deleteClientData(index, whatsapp, email) {
    const clients = getAllClients();
    const client = clients.find(c =>
        (email && c.email && c.email.toLowerCase() === email.toLowerCase()) ||
        (whatsapp && c.whatsapp && normalizePhone(c.whatsapp) === normalizePhone(whatsapp))
    ) || clients[index];
    if (!client) return;
    const clientEmail = (client.email || email || '').toLowerCase();
    const clientPhone = normalizePhone(client.whatsapp || whatsapp || '');
    const clientName = client.name || '';

    // Conferma esplicita digitata (niente password hardcoded nel bundle).
    // L'utente deve ridigitare il nome del cliente — o ELIMINA — per procedere.
    // Se la conferma non è superata, NESSUNA cancellazione parte (nemmeno quella locale).
    const atteso = (clientName || '').trim();
    const richiesta = atteso
        ? `Per eliminare TUTTI i dati di "${atteso}", digita il nome del cliente (o ELIMINA):`
        : 'Per eliminare TUTTI i dati del cliente, digita ELIMINA:';
    const _confermaRaw = await showPrompt(richiesta, '', { confirmText:'Elimina' });
    if (_confermaRaw === null) return;
    const conferma = (_confermaRaw || '').trim();
    const ok = conferma.toUpperCase() === 'ELIMINA' ||
               (atteso && conferma.toLowerCase() === atteso.toLowerCase());
    if (!ok) {
        if (conferma !== '') showAlert('Conferma non valida. Eliminazione annullata.', { type:'warn' });
        return;
    }

    if (!await showConfirm(`Confermi l'eliminazione di TUTTI i dati di ${clientName}?\n\nPrenotazioni e dati associati verranno eliminati permanentemente.`)) return;

    // 1. Elimina prenotazioni
    const allBookings = BookingStorage.getAllBookings();
    const kept = allBookings.filter(b => {
        if (clientEmail && b.email?.toLowerCase() === clientEmail) return false;
        if (clientPhone && b.whatsapp && normalizePhone(b.whatsapp) === clientPhone) return false;
        return true;
    });
    const removedBookings = allBookings.length - kept.length;
    BookingStorage.replaceAllBookings(kept);

    // 2. Supabase: elimina dati dal DB via RPC admin
    if (typeof supabaseClient !== 'undefined' && clientEmail) {
        try {
            const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('admin_delete_client_data', { p_email: clientEmail }));
            if (error) console.error('[deleteClientData] RPC error:', error.message);
            else console.log('[deleteClientData] Supabase:', data);
        } catch (e) { console.error('[deleteClientData] Supabase error:', e); }
        // Hard-delete: forza un FULL al prossimo sync (il delta non vede i DELETE).
        BookingStorage.invalidateDelta();
    }

    showToast(`Dati di ${clientName} eliminati (${removedBookings} prenotazioni rimosse).`, 'success');
    renderClientsTab();
}

// Modifica prenotazione in POPUP (riusa l'overlay .edit-client-popup-overlay). Gli input hanno
// gli stessi ID (bedit-paid/method/paidat-<id>) dell'edit inline precedente → saveBookingRowEdit
// resta invariato (legge per ID, indipendente da dove vivono gli input).
function openBookingEditPopup(bookingId, clientIndex) {
    const booking = BookingStorage.getAllBookings().find(b => b.id === bookingId);
    if (!booking) return;

    const methods = [
        { v: 'contanti',        l: '💵 Contanti'            },
        { v: 'contanti-report', l: '🧾 Contanti con Report' },
        { v: 'carta',           l: '💳 Carta'               },
        { v: 'iban',            l: '🏦 Bonifico'            },
        { v: 'stripe',          l: '💳 Stripe'              },
        { v: 'gratuito',        l: '🎁 Gratuita'            }
    ];
    const methodOpts = methods.map(m =>
        `<option value="${m.v}" ${booking.paymentMethod === m.v ? 'selected' : ''}>${m.l}</option>`
    ).join('');

    const dateStr = booking.date.split('-').reverse().join('/');
    const paidAtInput = booking.paidAt
        ? new Date(booking.paidAt).toISOString().slice(0, 16)   // "YYYY-MM-DDTHH:MM" per datetime-local
        : '';

    document.getElementById('bookingEditPopupOverlay')?.remove();
    const overlay = document.createElement('div');
    overlay.id = 'bookingEditPopupOverlay';
    overlay.className = 'edit-client-popup-overlay';
    overlay.innerHTML = `
        <div class="edit-client-popup">
            <div class="edit-client-popup-header">
                <h3>Modifica prenotazione</h3>
                <button class="edit-client-popup-close" onclick="closeBookingEditPopup()">&times;</button>
            </div>
            <div class="edit-client-popup-body">
                <div class="bedit-popup-meta">
                    <strong>${_escHtml(SLOT_NAMES[booking.slotType] || 'Lezione')}</strong> · ${dateStr} · ${_escHtml(booking.time)}
                </div>
                <div class="edit-client-popup-section">
                    <label>Stato pagamento
                        <select id="bedit-paid-${bookingId}">
                            <option value="true"  ${booking.paid  ? 'selected' : ''}>✓ Pagato</option>
                            <option value="false" ${!booking.paid ? 'selected' : ''}>✗ Non pagato</option>
                        </select>
                    </label>
                    <label>Metodo
                        <select id="bedit-method-${bookingId}">
                            <option value="">—</option>
                            ${methodOpts}
                        </select>
                    </label>
                    <label>Data/ora pagamento
                        <input type="datetime-local" id="bedit-paidat-${bookingId}" value="${paidAtInput}">
                    </label>
                </div>
            </div>
            <div class="edit-client-popup-actions">
                <button class="btn-cancel-edit" onclick="closeBookingEditPopup()">Annulla</button>
                <button class="btn-save-edit" onclick="saveBookingRowEdit('${bookingId}', ${clientIndex})">Salva</button>
            </div>
        </div>
    `;
    document.body.appendChild(overlay);
    overlay.addEventListener('click', e => { if (e.target === overlay) closeBookingEditPopup(); });
    setTimeout(() => overlay.classList.add('open'), 10);
}

function closeBookingEditPopup() {
    const overlay = document.getElementById('bookingEditPopupOverlay');
    if (overlay) {
        overlay.classList.remove('open');
        setTimeout(() => overlay.remove(), 200);
    }
}

async function saveBookingRowEdit(bookingId, clientIndex) {
    // Previeni doppio click: disabilita il bottone salva
    const _saveBtn = document.querySelector(`[onclick*="saveBookingRowEdit('${bookingId}'"]`);
    if (_saveBtn) _saveBtn.disabled = true;

    const newPaid   = document.getElementById(`bedit-paid-${bookingId}`).value === 'true';
    const newMethod = document.getElementById(`bedit-method-${bookingId}`).value;

    const bookings = BookingStorage.getAllBookings();
    const booking  = bookings.find(b => b.id === bookingId);
    if (!booking) { if (_saveBtn) _saveBtn.disabled = false; return; }

    // Controllo dati per metodi reportabili (carta/iban/stripe/contanti-report)
    if (['carta', 'iban', 'stripe', 'contanti-report'].includes(newMethod) && newPaid) {
        try { await ensureClientDataForCardPayment(booking.email, booking.whatsapp, booking.name, newMethod); }
        catch (e) { console.error('[Clients] ensureClientDataForCardPayment failed:', e); if (_saveBtn) _saveBtn.disabled = false; return; }
    }

    const newPaidAtRaw = document.getElementById(`bedit-paidat-${bookingId}`)?.value;
    const newPaidAtISO = newPaidAtRaw ? new Date(newPaidAtRaw).toISOString() : null;

    if (typeof supabaseClient !== 'undefined' && booking._sbId) {
        // ── Percorso Supabase (modello nuovo: ledger payments, niente credito) ──
        // Pagato  → admin_pay_bookings: marca pagato + registra incasso nel ledger.
        // Non pag.→ admin_update_booking: azzera pagamento (nessun rimborso credito).
        (async () => {
            try {
                if (newPaid) {
                    const method = newMethod || 'contanti';
                    const { error } = await _rpcWithTimeout(supabaseClient.rpc('admin_pay_bookings', {
                        p_booking_ids: [booking._sbId],
                        p_method:      method,
                        p_paid_at:     newPaidAtISO || new Date().toISOString(),
                    }));
                    if (error) {
                        console.error('[Supabase] admin_pay_bookings error:', error.message);
                        showAlert('Errore: ' + error.message, { type:'error' });
                        return;
                    }
                } else {
                    // Marca come non pagato mantenendo lo stato corrente del booking
                    const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('admin_update_booking', {
                        p_booking_id:     booking._sbId,
                        p_status:         booking.status || 'confirmed',
                        p_paid:           false,
                        p_payment_method: null,
                        p_paid_at:        null,
                    }));
                    if (error || (data && data.success === false)) {
                        console.error('[Supabase] admin_update_booking error:', error?.message || data?.error);
                        showAlert('Errore: ' + (error?.message || data?.error || 'aggiornamento non riuscito'), { type:'error' });
                        return;
                    }
                }

                await BookingStorage.syncFromSupabase().catch(e => console.warn('[Clients] booking sync:', e?.message || e));
                invalidateStatsCache();
                closeBookingEditPopup();
                renderClientsTab();
            } catch (ex) {
                console.error('[saveBookingRowEdit] unexpected error:', ex);
                showAlert('Errore imprevisto. Riprova.', { type:'error' });
            } finally {
                if (_saveBtn) _saveBtn.disabled = false;
            }
        })();
        return;
    }

    // ── Fallback client-side (offline): aggiorna solo lo stato pagamento ──
    booking.paid          = newPaid;
    booking.paymentMethod = newMethod || undefined;
    if (newPaid) {
        // Usa la data inserita manualmente, altrimenti mantieni o usa adesso
        booking.paidAt = newPaidAtISO || booking.paidAt || new Date().toISOString();
    } else {
        delete booking.paidAt;
    }

    BookingStorage.replaceAllBookings(bookings);
    if (_saveBtn) _saveBtn.disabled = false;
    closeBookingEditPopup();
    renderClientsTab();
}

async function deleteBookingFromClients(bookingId, bookingName) {
    if (!await showConfirm(`Eliminare la prenotazione di ${bookingName}?\n\nQuesta operazione non può essere annullata.`)) return;

    const bookings = BookingStorage.getAllBookings();
    const idx = bookings.findIndex(b => b.id === bookingId);
    if (idx === -1) { renderClientsTab(); return; }

    const b = bookings[idx];
    const clientWhatsapp = b.whatsapp;
    const clientEmail    = b.email;

    if (typeof supabaseClient !== 'undefined' && b._sbId) {
        try {
            // Eliminazione fisica del booking (niente rimborso credito: modello rimosso)
            const { error } = await _rpcWithTimeout(supabaseClient.rpc('admin_delete_booking', {
                p_booking_id: b._sbId,
            }));
            if (error) {
                console.error('[Supabase] admin_delete_booking error:', error.message);
                showToast('Errore durante l\'eliminazione: ' + error.message, 'error');
                return;
            }

            // Hard-delete: forza un FULL al prossimo sync (il delta non vede i DELETE).
            BookingStorage.invalidateDelta();
            await BookingStorage.syncFromSupabase();
        } catch (ex) {
            console.error('[deleteBookingFromClients] unexpected error:', ex);
            showToast('Errore imprevisto. Riprova.', 'error');
            return;
        }
    } else {
        // Fallback client-side (offline) — elimina solo il booking, nessun rimborso
        bookings.splice(idx, 1);
        BookingStorage.replaceAllBookings(bookings);
    }

    invalidateStatsCache();
    showToast('Prenotazione eliminata.', 'success');
    _refreshOpenClientCard(clientWhatsapp, clientEmail);
}
