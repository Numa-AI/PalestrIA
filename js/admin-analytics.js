/**
 * admin-analytics.js — Dashboard analitica del pannello admin (tab "Dashboard"/Stats).
 *
 * COSA FA
 * Costruisce la dashboard con statistiche, grafici e report del tenant: prenotazioni,
 * fatturato reale, clienti, occupazione slot, tempi più richiesti. Gestisce i filtri
 * temporali (this-month/next-month/last-month/this-year/last-year/custom) con confronto
 * sul periodo precedente, e i drill-down per ciascuna stat card.
 *
 * COME FUNZIONA
 * - Filtri: getFilterDateRange()/getPreviousFilterDateRange() calcolano i range; lo stato
 *   vive in currentFilter/customFilterFrom/customFilterTo; setAnalyticsFilter()/applyCustomFilter()
 *   sono i punti d'ingresso UI.
 * - Caricamento: loadDashboardData() (anti-stale via _loadDashboardSeq) orchestra fetch e
 *   render; _renderDashboardUI()/updateNonChartData()/_setStatCardsLoading() aggiornano la UI.
 * - Fatturato: fonte unica = tabella `payments` (org-scoped via RLS). _fetchPayments() fa fetch
 *   paginato (PAGE=1000) con _queryWithTimeout(), escludendo gli ADMIN_EMAILS. Cache in memoria
 *   (_statsBookings/_statsPayments + range _statsCacheRange/_statsPaymentsRange) per bypassare il
 *   limite ~5MB di localStorage; invalidateStatsCache() va chiamata dopo save/cancel booking.
 * - Stat cards e grafici: updateStatsCards(), drawBookingsChart(), drawTypeChart() (via SimpleChart
 *   di chart-mini.js), updateBookingsTable(), updatePopularTimes(), countGroupClassSlots().
 * - Drill-down: toggleStatDetail(type) + render*Detail() (Fatturato/Prenotazioni/Clienti/Occupancy);
 *   switchFatturatoMode() commuta vista fatturato.
 * - Report: checkWeeklyReportBanner()/downloadWeeklyReport()/downloadFiscalReport() (PDF via jsPDF).
 *
 * CONNESSIONI
 * - Legge prenotazioni da BookingStorage (js/data.js) e profili via _getUserRecord()/
 *   _updateSupabaseProfile() (tabella profiles). Tutto org-scoped da RLS.
 * - Variabili condivise con admin-calendar.js (adminWeekOffset, selectedAdminDay).
 * - Disegna su canvas tramite SimpleChart (js/chart-mini.js).
 * - Helper comuni: _queryWithTimeout, ADMIN_EMAILS, _localDateStr, getBookingPrice (definiti altrove).
 */
let adminWeekOffset = 0;
let selectedAdminDay = null;
let _adminInitialScrollDone = false;

// Analytics filter state
let currentFilter = 'this-month';
let customFilterFrom = null;
let customFilterTo = null;
// Cache in memoria per le stats — bypassa il limite di 5MB di localStorage.
// _statsCacheRange traccia il range date già scaricato: se il filtro rientra, skip fetch.
let _statsBookings = null;
let _statsCacheRange = null; // { from: 'YYYY-MM-DD', to: 'YYYY-MM-DD' }
// Ledger pagamenti (fatturato reale): cache in memoria + range scaricato.
// Fonte unica del fatturato reale → tabella `payments` (org-scoped via RLS).
let _statsPayments = null;       // array di righe payments mappate
let _statsPaymentsRange = null;  // { from, to }
const _excludeAdminBookings = arr => arr.filter(b => !ADMIN_EMAILS.has((b.email || '').toLowerCase()));
// Sequenza per scartare risposte stale in caso di click rapidi sui filtri
let _loadDashboardSeq = 0;

// ── Snapshot stats persistito (stale-while-revalidate al cold start) ──────────
// La cache stats è solo in RAM (sopra) per non pesare sul budget ~5MB di localStorage, ma
// un refresh (cold start) la azzera → skeleton finché non torna il fetch (finestra ~2 anni).
// Persistiamo uno snapshot su localStorage: al cold start paint immediato (niente skeleton) e,
// se fresco entro TTL e copre il range, si salta pure il fetch bookings (meno egress). Scoped
// per identità admin; cap righe + quota-guard; scartato se predate un clear globale dei dati.
// NB: lo snapshot copre i SOLI bookings (la parte pesante); il ledger payments resta un fetch
// separato più leggero → il fatturato reale si aggiorna appena arriva (niente skeleton comunque).
const _STATS_PERSIST_KEY = 'gym_stats_cache_v1';
const _STATS_PERSIST_TTL_MS = 90_000;   // entro 90s un refresh salta il fetch (dati economici freschi)
const _STATS_PERSIST_MAX_ROWS = 6000;   // oltre, niente persist (evita quota)

function _statsIdentity() {
    try {
        if (sessionStorage.getItem('adminAuth') === 'true') return 'admin';
        const user = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
        return user?.id || null;
    } catch (_) { return null; }
}
function _statsPersistKey() {
    const id = _statsIdentity();
    return id ? `${_STATS_PERSIST_KEY}:${id}` : null;
}
// Salva lo snapshot dopo un fetch riuscito. setItem diretto + try/catch: su quota fallisce
// in silenzio (niente toast) e resta il fallback stale-while-revalidate.
function _persistStatsCache() {
    const key = _statsPersistKey();
    if (!key || !_statsBookings || !_statsCacheRange) return;
    if (_statsBookings.length > _STATS_PERSIST_MAX_ROWS) return;
    try {
        localStorage.setItem(key, JSON.stringify({
            savedAt: Date.now(),
            clearedAt: localStorage.getItem('dataLastCleared') || '0',
            range: _statsCacheRange,
            rows: _statsBookings,
        }));
    } catch (_) { /* quota/serialize: ignora — resta il fallback SWR */ }
}
// Idrata la cache RAM dallo snapshot persistito (solo cold start). Ritorna:
//  'fresh' → entro TTL e range coperto (setta _statsCacheRange → skip fetch bookings)
//  'stale' → serve solo per il primo paint (_statsCacheRange resta null → rivalida)
//  null    → assente/invalido
function _hydrateStatsCache(extFromStr, extToStr) {
    const key = _statsPersistKey();
    if (!key) return null;
    const snap = _lsGetJSON(key, null);
    if (!snap || !Array.isArray(snap.rows) || snap.rows.length === 0 || !snap.range) return null;
    // Scarta (e rimuovi) se predate un clear globale dei dati.
    if ((localStorage.getItem('dataLastCleared') || '0') !== (snap.clearedAt || '0')) {
        try { localStorage.removeItem(key); } catch (_) { /* ignore */ }
        return null;
    }
    _statsBookings = snap.rows;
    const fresh = (Date.now() - (snap.savedAt || 0)) < _STATS_PERSIST_TTL_MS
        && extFromStr >= snap.range.from
        && extToStr   <= snap.range.to;
    if (fresh) { _statsCacheRange = snap.range; return 'fresh'; }
    return 'stale';
}
// Rimuove gli snapshot stats persistiti (tutte le identità). Chiamato su mutazione
// (invalidateStatsCache) e, cross-pagina, da BookingStorage._clearPersistedCache
// (logout / clear globale) per non lasciare dati economici admin sul dispositivo.
function _clearPersistedStatsCache() {
    try {
        const prefix = _STATS_PERSIST_KEY + ':';
        for (let i = localStorage.length - 1; i >= 0; i--) {
            const k = localStorage.key(i);
            if (k && k.startsWith(prefix)) localStorage.removeItem(k);
        }
    } catch (_) { /* ignore */ }
}

// Invalida la cache stats (chiamare dopo save/cancel booking): azzera i range in RAM
// e butta lo snapshot persistito, così dopo una mutazione un refresh rifà il fetch.
function invalidateStatsCache() { _statsCacheRange = null; _statsPaymentsRange = null; _clearPersistedStatsCache(); }

// Fetch diretto del ledger pagamenti per il range richiesto (RLS filtra org_id).
// Ritorna array di { date, amount, method, kind, email } o null in caso di errore.
async function _fetchPayments(fromStr, toStr) {
    if (typeof supabaseClient === 'undefined') return null;
    try {
        const PAGE = 1000;
        let all = [], pageFrom = 0, done = false;
        while (!done) {
            let q = supabaseClient.from('payments')
                .select('created_at,amount,method,kind,client_email')
                .order('created_at', { ascending: false })
                .range(pageFrom, pageFrom + PAGE - 1);
            if (fromStr) q = q.gte('created_at', fromStr + 'T00:00:00');
            if (toStr)   q = q.lte('created_at', toStr + 'T23:59:59.999');
            const { data, error } = (await _queryWithTimeout(q, 15000)) || {};
            if (error) throw new Error(error.message || error);
            all = all.concat(data || []);
            done = !data || data.length < PAGE;
            pageFrom += PAGE;
        }
        return all
            .filter(p => !ADMIN_EMAILS.has((p.client_email || '').toLowerCase()))
            .map(p => ({
                date:   p.created_at,
                amount: Number(p.amount) || 0,
                method: p.method || '',
                kind:   p.kind || '',
                email:  p.client_email || ''
            }));
    } catch (e) {
        console.error('[Stats] fetch payments error:', e);
        return null;
    }
}

function getFilterDateRange(filter) {
    const now = new Date();
    switch (filter) {
        case 'this-month':
            return {
                from: new Date(now.getFullYear(), now.getMonth(), 1),
                to: new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999)
            };
        case 'next-month':
            return {
                from: new Date(now.getFullYear(), now.getMonth() + 1, 1),
                to: new Date(now.getFullYear(), now.getMonth() + 2, 0, 23, 59, 59, 999)
            };
        case 'last-month': {
            const lm = now.getMonth() === 0 ? 11 : now.getMonth() - 1;
            const ly = now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
            return {
                from: new Date(ly, lm, 1),
                to: new Date(ly, lm + 1, 0, 23, 59, 59, 999)
            };
        }
        case 'this-year':
            return {
                from: new Date(now.getFullYear(), 0, 1),
                to: new Date(now.getFullYear(), 11, 31, 23, 59, 59, 999)
            };
        case 'last-year':
            return {
                from: new Date(now.getFullYear() - 1, 0, 1),
                to: new Date(now.getFullYear() - 1, 11, 31, 23, 59, 59, 999)
            };
        case 'custom':
            return {
                from: customFilterFrom ? new Date(customFilterFrom + 'T00:00:00') : new Date(now.getFullYear(), now.getMonth(), 1),
                to: customFilterTo ? new Date(customFilterTo + 'T23:59:59') : new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59)
            };
        default:
            return {
                from: new Date(now.getFullYear(), now.getMonth(), 1),
                to: new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999)
            };
    }
}

function getPreviousFilterDateRange(filter) {
    const now = new Date();
    switch (filter) {
        case 'this-month': {
            const lm = now.getMonth() === 0 ? 11 : now.getMonth() - 1;
            const ly = now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
            return { from: new Date(ly, lm, 1), to: new Date(ly, lm + 1, 0, 23, 59, 59, 999) };
        }
        case 'next-month':
            // Periodo confronto = mese corrente
            return { from: new Date(now.getFullYear(), now.getMonth(), 1), to: new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999) };
        case 'last-month': {
            const m2 = ((now.getMonth() - 2) % 12 + 12) % 12;
            const y2 = now.getMonth() <= 1 ? now.getFullYear() - 1 : now.getFullYear();
            return { from: new Date(y2, m2, 1), to: new Date(y2, m2 + 1, 0, 23, 59, 59, 999) };
        }
        case 'this-year':
            return { from: new Date(now.getFullYear() - 1, 0, 1), to: new Date(now.getFullYear() - 1, 11, 31, 23, 59, 59, 999) };
        case 'last-year':
            return { from: new Date(now.getFullYear() - 2, 0, 1), to: new Date(now.getFullYear() - 2, 11, 31, 23, 59, 59, 999) };
        default:
            return null;
    }
}

function getFilteredBookings(filter) {
    // Usa _statsBookings (fetch Supabase) se disponibile, altrimenti localStorage
    const allBookings = _statsBookings ?? _excludeAdminBookings(BookingStorage.getAllBookings());
    const { from, to } = getFilterDateRange(filter);
    return allBookings.filter(b => {
        if (b.status === 'cancelled') return false;
        const d = new Date(b.date + 'T00:00:00');
        return d >= from && d <= to;
    });
}

function getFilterLabel(filter) {
    const now = new Date();
    const months = ['Gennaio','Febbraio','Marzo','Aprile','Maggio','Giugno','Luglio','Agosto','Settembre','Ottobre','Novembre','Dicembre'];
    switch (filter) {
        case 'this-month': return `${months[now.getMonth()]} ${now.getFullYear()}`;
        case 'next-month': {
            const nm = (now.getMonth() + 1) % 12;
            const ny = now.getMonth() === 11 ? now.getFullYear() + 1 : now.getFullYear();
            return `${months[nm]} ${ny}`;
        }
        case 'last-month': {
            const lm = now.getMonth() === 0 ? 11 : now.getMonth() - 1;
            const ly = now.getMonth() === 0 ? now.getFullYear() - 1 : now.getFullYear();
            return `${months[lm]} ${ly}`;
        }
        case 'this-year': return `${now.getFullYear()}`;
        case 'last-year': return `${now.getFullYear() - 1}`;
        case 'custom':
            return customFilterFrom && customFilterTo ? `${customFilterFrom} → ${customFilterTo}` : 'Personalizzato';
        default: return '';
    }
}

// Etichetta del periodo di confronto (es. "Aprile" per filtro this-month a Maggio)
function getPreviousFilterLabel(filter) {
    const now = new Date();
    const months = ['Gennaio','Febbraio','Marzo','Aprile','Maggio','Giugno','Luglio','Agosto','Settembre','Ottobre','Novembre','Dicembre'];
    switch (filter) {
        case 'this-month': {
            const lm = now.getMonth() === 0 ? 11 : now.getMonth() - 1;
            return months[lm];
        }
        case 'next-month':
            return months[now.getMonth()];
        case 'last-month': {
            const m2 = ((now.getMonth() - 2) % 12 + 12) % 12;
            return months[m2];
        }
        case 'this-year': return `${now.getFullYear() - 1}`;
        case 'last-year': return `${now.getFullYear() - 2}`;
        default: return 'periodo prec.';
    }
}

let _filterSwitching = false;
async function setAnalyticsFilter(filter, btn) {
    if (_filterSwitching) return;
    currentFilter = filter;
    document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    const customDates = document.getElementById('filterCustomDates');
    if (filter === 'custom') {
        customDates.style.display = 'flex';
        if (!customFilterFrom) {
            const now = new Date();
            customFilterFrom = formatAdminDate(new Date(now.getFullYear(), now.getMonth(), 1));
            customFilterTo = formatAdminDate(now);
            document.getElementById('filterDateFrom').value = customFilterFrom;
            document.getElementById('filterDateTo').value = customFilterTo;
        }
        return; // wait for "Applica"
    } else {
        customDates.style.display = 'none';
    }
    _filterSwitching = true;
    const allBtns = document.querySelectorAll('.filter-btn');
    allBtns.forEach(b => b.disabled = true);
    try {
        await loadDashboardData();
    } catch (e) {
        console.error('[Stats] Errore cambio filtro:', e);
    } finally {
        allBtns.forEach(b => b.disabled = false);
        _filterSwitching = false;
    }
}

async function applyCustomFilter() {
    const from = document.getElementById('filterDateFrom').value;
    const to = document.getElementById('filterDateTo').value;
    if (!from || !to) { showAlert('Seleziona entrambe le date.', { type:'warn' }); return; }
    if (from > to) { showAlert('La data di inizio deve essere precedente alla data di fine.', { type:'warn' }); return; }
    customFilterFrom = from;
    customFilterTo = to;
    const applyBtn = document.querySelector('.btn-apply-filter');
    if (applyBtn) { applyBtn.disabled = true; applyBtn.style.opacity = '0.6'; }
    try {
        await loadDashboardData();
    } finally {
        if (applyBtn) { applyBtn.disabled = false; applyBtn.style.opacity = ''; }
    }
}


function updateNonChartData() {
    const allBookings = _statsBookings ?? _excludeAdminBookings(BookingStorage.getAllBookings());
    const filteredBookings = getFilteredBookings(currentFilter);
    updateStatsCards(filteredBookings, allBookings);
    updateBookingsTable(filteredBookings);
    updatePopularTimes(filteredBookings);
}

function _renderDashboardUI() {
    const filteredBookings = getFilteredBookings(currentFilter);
    const allBookings = _statsBookings ?? _excludeAdminBookings(BookingStorage.getAllBookings());
    updateStatsCards(filteredBookings, allBookings);
    drawBookingsChart(filteredBookings);
    drawTypeChart(filteredBookings);
    updateBookingsTable(filteredBookings);
    updatePopularTimes(filteredBookings);
    if (_currentStatDetail) {
        const panel = document.getElementById('statsDetailPanel');
        if (panel && panel.style.display !== 'none') {
            switch (_currentStatDetail) {
                case 'fatturato':    renderFatturatoDetail(panel);    break;
                case 'prenotazioni': renderPrenotazioniDetail(panel); break;
                case 'clienti':      renderClientiDetail(panel);      break;
                case 'occupancy':    renderOccupancyDetail(panel);    break;
            }
        }
    }
}

function _setStatCardsLoading(on) {
    document.querySelectorAll('.stat-card').forEach(c =>
        c.classList.toggle('stat-card--loading', on));
}

async function loadDashboardData() {
    const seq = ++_loadDashboardSeq;
    BookingStorage.processPendingCancellations();

    // 1) Stale-while-revalidate: se abbiamo dati in cache, render immediato
    let hasCache = !!_statsBookings;
    if (hasCache) _renderDashboardUI();

    if (typeof BookingStorage !== 'undefined' && typeof supabaseClient !== 'undefined') {
        const { from, to } = getFilterDateRange(currentFilter);
        const prevRange = getPreviousFilterDateRange(currentFilter);
        const now = new Date();
        const twelveMonthsAgo = new Date(now.getFullYear() - 1, now.getMonth(), 1);
        const extFromDate = new Date(Math.min(
            prevRange ? prevRange.from.getTime() : from.getTime(),
            from.getTime(),
            twelveMonthsAgo.getTime()
        ));
        const twelveMonthsAhead = new Date(now.getFullYear() + 1, now.getMonth() + 1, 0, 23, 59, 59, 999);
        const extToDate = new Date(Math.max(to.getTime(), twelveMonthsAhead.getTime()));
        const extFromStr = _localDateStr(extFromDate);
        const extToStr   = _localDateStr(extToDate);

        // 1b) Cold start (post-refresh): niente cache RAM → idrata dallo snapshot persistito.
        // 'fresh' (entro TTL e range coperto) setta _statsCacheRange → salta il fetch bookings
        // qui sotto; altrimenti paint immediato e si rivalida. Fallback allo snapshot condiviso
        // di BookingStorage. Serve a togliere il "lampo" di skeleton al refresh.
        if (!hasCache) {
            _hydrateStatsCache(extFromStr, extToStr);
            if (!_statsBookings) {
                const snapshot = _excludeAdminBookings(BookingStorage.getAllBookings());
                if (snapshot.length) _statsBookings = snapshot; // solo paint: _statsCacheRange resta null → fetch
            }
            if (_statsBookings) { hasCache = true; _renderDashboardUI(); }
        }

        // 2) Cache hit: se il range richiesto è già coperto, skip fetch.
        // Bookings e payments hanno copertura tracciata SEPARATAMENTE: il ledger
        // payments può fallire mentre i bookings sono ok (M12). Rifacciamo il fetch
        // se manca la copertura di almeno una delle due fonti.
        const bookingsCovers = _statsCacheRange
            && extFromStr >= _statsCacheRange.from
            && extToStr   <= _statsCacheRange.to;
        const paymentsCovers = _statsPaymentsRange
            && extFromStr >= _statsPaymentsRange.from
            && extToStr   <= _statsPaymentsRange.to;

        if (!bookingsCovers || !paymentsCovers) {
            // Skeleton anti-flicker: mostra solo se il fetch dura >200ms
            let skeletonTimer = null;
            if (!hasCache) {
                skeletonTimer = setTimeout(() => _setStatCardsLoading(true), 200);
            }

            const fetchPromise = bookingsCovers
                ? Promise.resolve(null)
                : BookingStorage.fetchForAdmin(extFromStr, extToStr);
            const timeoutPromise = new Promise(resolve => setTimeout(() => resolve(null), 10000));
            // Fetch in parallelo del ledger pagamenti (fatturato reale)
            const paymentsPromise = paymentsCovers
                ? Promise.resolve(_statsPayments)   // già coperto: riusa la cache valida
                : _fetchPayments(extFromStr, extToStr);
            const [freshData, freshPayments] = await Promise.all([
                Promise.race([fetchPromise, timeoutPromise]),
                paymentsPromise
            ]);

            if (skeletonTimer) clearTimeout(skeletonTimer);
            _setStatCardsLoading(false);

            if (seq !== _loadDashboardSeq) return;

            if (freshData !== null) {
                _statsBookings = _excludeAdminBookings(freshData);
                _statsCacheRange = { from: extFromStr, to: extToStr };
                _persistStatsCache();   // persisti per il prossimo refresh (SWR cold start)
            } else if (!bookingsCovers && !_statsBookings) {
                _statsBookings = _excludeAdminBookings(BookingStorage.getAllBookings());
            }

            if (!paymentsCovers) {
                if (freshPayments !== null) {
                    _statsPayments = freshPayments;
                    _statsPaymentsRange = { from: extFromStr, to: extToStr };
                } else {
                    // Errore/timeout sul ledger: NON servire payments stantii come freschi
                    // contro il nuovo range. Azzeriamo cache+copertura → il render mostra
                    // blank/— per il fatturato reale invece di dati vecchi mal-attribuiti.
                    _statsPayments = null;
                    _statsPaymentsRange = null;
                }
            }
        }
    }

    // 3) Render finale (o primo render se non c'era cache)
    _statsLastLoad = Date.now();
    _renderDashboardUI();
}

// Refresh dati stats quando l'admin torna sulla pagina dopo >2 minuti
let _statsLastLoad = Date.now();
document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    const elapsed = Date.now() - _statsLastLoad;
    if (elapsed < 300_000) return; // meno di 5 min, skip
    const analyticsTab = document.getElementById('tab-analytics');
    if (!analyticsTab || !analyticsTab.classList.contains('active')) return;
    _statsLastLoad = Date.now();
    invalidateStatsCache();
    loadDashboardData();
});

function updateStatsCards(filteredBookings, allBookings) {
    const filterLabel = getFilterLabel(currentFilter);
    const prevRange = getPreviousFilterDateRange(currentFilter);

    function calcChange(current, prev, el) {
        if (prevRange && currentFilter !== 'custom' && prev > 0) {
            const pct = Math.round(((current - prev) / prev) * 100);
            el.textContent = `${pct >= 0 ? '+' : ''}${pct}% vs ${getPreviousFilterLabel(currentFilter)}`;
            el.className = pct >= 0 ? 'stat-change positive' : 'stat-change negative';
        } else {
            el.textContent = filterLabel;
            el.className = 'stat-change';
        }
    }

    // Revenue (modalità "Prenotazioni") — proiezione dal valore dei booking
    // (pagati o meno) escludendo le lezioni gratuite. Il fatturato reale incassato
    // si vede nel dettaglio (modalità "Reale") dal ledger payments.
    const revenue = filteredBookings
        .filter(b => b.paymentMethod !== 'lezione-gratuita')
        .reduce((t, b) => t + getBookingPrice(b), 0);
    sensitiveSet('monthlyRevenue', `€${revenue}`);
    // Confronto col periodo precedente, simmetrico con `revenue` (usa filteredBookings).
    const prevRevBookings = prevRange ? allBookings.filter(b => {
        if (b.status === 'cancelled') return false;
        const d = new Date(b.date + 'T00:00:00');
        return d >= prevRange.from && d <= prevRange.to && b.paymentMethod !== 'lezione-gratuita';
    }) : [];
    const prevAllBookings = prevRange ? allBookings.filter(b => {
        if (b.status === 'cancelled') return false;
        const d = new Date(b.date + 'T00:00:00');
        return d >= prevRange.from && d <= prevRange.to;
    }) : [];
    const prevRev = prevRevBookings.reduce((t, b) => t + getBookingPrice(b), 0);
    calcChange(revenue, prevRev, document.getElementById('revenueChange'));
    sensitiveSet('revenueChange', document.getElementById('revenueChange').textContent);

    // Total bookings
    document.getElementById('totalBookings').textContent = filteredBookings.length;
    calcChange(filteredBookings.length, prevAllBookings.length, document.getElementById('bookingsChange'));

    // Active clients
    const uniqueClients = new Set(filteredBookings.map(b => b.email)).size;
    document.getElementById('activeClients').textContent = uniqueClients;
    const clientsChangeEl = document.getElementById('clientsChange');
    clientsChangeEl.textContent = filterLabel;
    clientsChangeEl.className = 'stat-change';

    // Occupancy rate over the filter period (basato solo su gestione orari)
    const { from, to } = getFilterDateRange(currentFilter);
    const overridesOcc = BookingStorage.getScheduleOverrides();
    let totalSlots = 0;
    const curOcc = new Date(from); curOcc.setHours(0, 0, 0, 0);
    const endOcc = new Date(to); endOcc.setHours(23, 59, 59, 999);
    while (curOcc <= endOcc) {
        const ds = `${curOcc.getFullYear()}-${String(curOcc.getMonth() + 1).padStart(2, '0')}-${String(curOcc.getDate()).padStart(2, '0')}`;
        const daySlots = overridesOcc[ds];
        if (daySlots && daySlots.length > 0) {
            daySlots.forEach(s => {
                if (s.type === 'group-class') totalSlots += 1;
                else totalSlots += SLOT_MAX_CAPACITY[s.type] || 0;
            });
        }
        curOcc.setDate(curOcc.getDate() + 1);
    }
    const occupancyRate = totalSlots > 0 ? Math.round((filteredBookings.length / totalSlots) * 100) : 0;
    document.getElementById('occupancyRate').textContent = `${occupancyRate}%`;
    const occEl = document.getElementById('occupancyChange');
    occEl.textContent = filterLabel;
    occEl.className = occupancyRate > 50 ? 'stat-change positive' : 'stat-change';
}

function drawBookingsChart(filteredBookings) {
    const canvas = document.getElementById('bookingsChart');
    if (!canvas) return;
    const chart = new SimpleChart(canvas);

    const { from, to } = getFilterDateRange(currentFilter);
    const diffDays = Math.round((to - from) / (1000 * 60 * 60 * 24));
    const useMonthly = diffDays > 60;

    let labels = [];
    let values = [];

    if (useMonthly) {
        const monthNames = ['Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu', 'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'];
        const sy = from.getFullYear(), sm = from.getMonth();
        const ey = to.getFullYear(), em = to.getMonth();
        for (let y = sy; y <= ey; y++) {
            const mStart = (y === sy) ? sm : 0;
            const mEnd = (y === ey) ? em : 11;
            for (let m = mStart; m <= mEnd; m++) {
                labels.push(monthNames[m]);
                values.push(filteredBookings.filter(b => {
                    const d = new Date(b.date + 'T00:00:00');
                    return d.getFullYear() === y && d.getMonth() === m;
                }).length);
            }
        }
    } else {
        const cur = new Date(from); cur.setHours(0, 0, 0, 0);
        const end = new Date(to); end.setHours(23, 59, 59);
        while (cur <= end) {
            const dateStr = formatAdminDate(cur);
            labels.push(`${cur.getDate()}`);
            values.push(filteredBookings.filter(b => b.date === dateStr).length);
            cur.setDate(cur.getDate() + 1);
        }
    }

    // Thin out labels if too many to avoid overlap
    const maxLabels = 12;
    if (labels.length > maxLabels) {
        const step = Math.ceil(labels.length / maxLabels);
        labels = labels.map((l, i) => i % step === 0 ? l : '');
    }

    chart.drawLineChart({ labels, values }, { color: '#e63946' });
}

function countGroupClassSlots(from, to) {
    const overrides = BookingStorage.getScheduleOverrides();
    const dayNames = ['Domenica', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato'];
    let count = 0;
    const cur = new Date(from); cur.setHours(0, 0, 0, 0);
    const end = new Date(to);   end.setHours(23, 59, 59, 999);
    while (cur <= end) {
        const dateStr = formatAdminDate(cur);
        // Override puntuale se configurato, altrimenti il template della settimana
        // ATTIVATA per quella data (date-aware: vuoto se la settimana non è attivata).
        const weekly = (typeof getWeeklySchedule === 'function') ? getWeeklySchedule(dateStr) : null;
        const slots = overrides[dateStr] !== undefined
            ? overrides[dateStr]
            : ((weekly && weekly[dayNames[cur.getDay()]]) || []);
        count += slots.filter(s => s.type === SLOT_TYPES.GROUP_CLASS).length;
        cur.setDate(cur.getDate() + 1);
    }
    return count;
}

function drawTypeChart(filteredBookings) {
    const canvas = document.getElementById('typeChart');
    if (!canvas) return;
    const chart = new SimpleChart(canvas);

    const distribution = {};
    filteredBookings.forEach(b => {
        distribution[b.slotType] = (distribution[b.slotType] || 0) + 1;
    });

    const { from, to } = getFilterDateRange(currentFilter);
    const groupClassCount = countGroupClassSlots(from, to);

    chart.drawPieChart({
        labels: ['Autonomia', 'Lezione di Gruppo', 'Slot prenotato'],
        values: [
            distribution[SLOT_TYPES.PERSONAL] || 0,
            distribution[SLOT_TYPES.SMALL_GROUP] || 0,
            groupClassCount
        ]
    }, {
        colors: ['#22c55e', '#fbbf24', '#ef4444']
    });
}

function updateBookingsTable(bookings) {
    const tbody = document.getElementById('bookingsTableBody');
    if (!tbody) return;
    tbody.innerHTML = '';

    // Sort by booking date (most recent first)
    const sortedBookings = [...bookings].sort((a, b) => {
        if (b.date !== a.date) return b.date.localeCompare(a.date);
        return b.time.localeCompare(a.time);
    }).slice(0, 15);

    if (sortedBookings.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" style="text-align: center; color: #999;">Nessuna prenotazione nel periodo selezionato</td></tr>';
        return;
    }

    sortedBookings.forEach(booking => {
        const row = document.createElement('tr');
        const [y, m, d] = booking.date.split('-').map(Number);
        const dateDisplay = `${d}/${m}/${y}`;

        row.innerHTML = `
            <td>${dateDisplay}</td>
            <td>${booking.time}</td>
            <td>${_escHtml(booking.name)}</td>
            <td>${SLOT_NAMES[booking.slotType]}</td>
            <td>${_escHtml(booking.whatsapp)}</td>
            <td><span class="status-badge ${booking.status}">${
                booking.status === 'confirmed'              ? 'Confermata'            :
                booking.status === 'cancellation_requested' ? 'Richiesta annullamento' :
                booking.status === 'cancelled'              ? 'Annullata'              :
                'In attesa'
            }</span></td>
        `;
        tbody.appendChild(row);
    });
}

function updatePopularTimes(bookings) {
    if (!document.getElementById('popularTimes')) return;
    const timeCounts = {};

    bookings.forEach(booking => {
        timeCounts[booking.time] = (timeCounts[booking.time] || 0) + 1;
    });

    const allSorted = Object.entries(timeCounts).sort((a, b) => b[1] - a[1]);
    const popularContainer = document.getElementById('popularTimes');
    const unpopularContainer = document.getElementById('unpopularTimes');
    popularContainer.innerHTML = '';
    unpopularContainer.innerHTML = '';

    if (allSorted.length === 0) {
        popularContainer.innerHTML = '<p style="color: #999;">Nessun dato disponibile</p>';
        unpopularContainer.innerHTML = '<p style="color: #999;">Nessun dato disponibile</p>';
        return;
    }

    const top5 = allSorted.slice(0, 5);
    const bottom5 = [...allSorted].reverse().slice(0, 5);

    // Each card scales to its own local max so bars vary properly within each list
    const maxPopular = top5[0][1];
    const maxUnpopular = bottom5[bottom5.length - 1][1] || 1;

    const popularHtml = top5.map(([time, count]) => {
        const percentage = (count / maxPopular) * 100;
        return `<div class="time-bar">
                <div class="time-label">${time}</div>
                <div class="time-progress">
                    <div class="time-progress-fill" style="width: ${percentage}%">
                        ${count} pren.
                    </div>
                </div>
            </div>`;
    });
    popularContainer.innerHTML = popularHtml.join('');

    const unpopularHtml = bottom5.map(([time, count]) => {
        const percentage = (count / maxUnpopular) * 100;
        return `<div class="time-bar">
                <div class="time-label">${time}</div>
                <div class="time-progress">
                    <div class="time-progress-fill time-progress-fill--low" style="width: ${percentage}%">
                        ${count} pren.
                    </div>
                </div>
            </div>`;
    });
    unpopularContainer.innerHTML = unpopularHtml.join('');
}

// ── Statistics Detail Panel ──────────────────────────────────────────────────

let _currentStatDetail = null;
let _fatturatoMode = 'prenotazioni'; // 'prenotazioni' | 'reale'

function switchFatturatoMode(mode) {
    _fatturatoMode = mode;
    const panel = document.getElementById('statsDetailPanel');
    if (panel) renderFatturatoDetail(panel);
}

function toggleStatDetail(type) {
    const panel = document.getElementById('statsDetailPanel');
    const card  = document.getElementById('statcard-' + type);
    if (!panel || !card) return;

    if (_currentStatDetail === type) {
        panel.style.display = 'none';
        panel.innerHTML = '';
        card.classList.remove('active');
        _currentStatDetail = null;
        return;
    }

    if (_currentStatDetail) {
        const prev = document.getElementById('statcard-' + _currentStatDetail);
        if (prev) prev.classList.remove('active');
    }

    card.classList.add('active');
    _currentStatDetail = type;
    panel.style.display = 'block';

    switch (type) {
        case 'fatturato':     renderFatturatoDetail(panel);     break;
        case 'prenotazioni':  renderPrenotazioniDetail(panel);  break;
        case 'clienti':       renderClientiDetail(panel);       break;
        case 'occupancy':     renderOccupancyDetail(panel);     break;
        default:
            panel.innerHTML = `<div class="stat-detail-header"><h3>Dettaglio ${type}</h3></div><p style="color:#9ca3af;text-align:center;padding:1.5rem 0">Prossimamente</p>`;
    }
    card.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function renderFatturatoDetail(panel) {
    const isReale = _fatturatoMode === 'reale';
    const revFn = (s, b) => s + getBookingPrice(b);
    const { from, to } = getFilterDateRange(currentFilter);
    const now   = new Date();
    const today = new Date(now); today.setHours(0, 0, 0, 0);
    // In Reale i pagamenti di oggi sono già incassati → confine = domani
    const pastCutoff = isReale ? new Date(today.getTime() + 86400000) : today;

    // ── Fonte dati FATTURATO ─────────────────────────────────────────────────
    // Reale       → ledger `payments` (SUM amount per periodo, raggruppabile per
    //               method/kind). I pagamenti hanno SEMPRE data passata (registrati
    //               quando incassati) → niente proiezione futura.
    // Prenotazioni → proiezione dal valore dei booking (pagati o meno) *
    //               getBookingPrice, con stima sui giorni futuri non programmati.
    const payments = _statsPayments || [];
    // M12: in Reale, se il ledger non è disponibile (fetch fallito/azzerato per il range
    // corrente) NON mostriamo €0 fuorviante ma "—". `_statsPayments === null` = nessuna
    // copertura valida; `[]` legittimo (periodo senza incassi) resta €0.
    const paymentsUnavailable = isReale && _statsPayments === null;
    const fmtReale = v => paymentsUnavailable ? '—' : `€${v}`;
    // Helper Reale: somma payments in un range di date (su created_at)
    const payInRange = (dateFrom, dateTo) => payments
        .filter(p => { const d = new Date(p.date); return d >= dateFrom && d <= dateTo; })
        .reduce((s, p) => s + p.amount, 0);

    // Bookings non-cancellati esclusi i gratuiti (modalità Prenotazioni)
    const allBookings = (_statsBookings ?? _excludeAdminBookings(BookingStorage.getAllBookings()))
        .filter(b => b.status !== 'cancelled' && b.paymentMethod !== 'lezione-gratuita');

    // Bookings in current filter period
    const periodBookings = allBookings.filter(b => {
        const d = new Date(b.date + 'T00:00:00');
        return d >= from && d <= to;
    });

    // Passato (prima di pastCutoff) e futuro (da pastCutoff in poi)
    const pastBookings   = periodBookings.filter(b => new Date(b.date + 'T00:00:00') < pastCutoff);
    const futureBookings = periodBookings.filter(b => new Date(b.date + 'T00:00:00') >= pastCutoff);

    // pastRevenue/futureRevenue: in Reale dal ledger, in Prenotazioni dai booking.
    const pastCreditEnd = new Date(Math.min(to.getTime(), pastCutoff.getTime() - 1));
    const pastRevenue   = isReale ? payInRange(from, pastCreditEnd) : pastBookings.reduce(revFn, 0);
    const futureRevenue = isReale ? payInRange(pastCutoff, to)      : futureBookings.reduce(revFn, 0);

    const periodStart = from.getTime();
    const totalDays   = Math.max(1, Math.ceil((to.getTime() - periodStart) / 86400000));
    // Media settimanale basata sui giorni programmati in gestione orari
    const overrides = BookingStorage.getScheduleOverrides();
    let _weekSchedDays = 0;
    for (let dd = 0; dd < totalDays; dd++) {
        const day = new Date(from.getTime() + dd * 86400000);
        const ds = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
        if (overrides[ds] && overrides[ds].length > 0) _weekSchedDays++;
    }
    const weeklyAvg = _weekSchedDays > 0
        ? Math.round((pastRevenue + futureRevenue) / _weekSchedDays * 7)
        : 0;

    // ── Bar chart: ultimi 12 mesi + successivo ───────────────────────────────
    const MONTH_NAMES = ['Gen','Feb','Mar','Apr','Mag','Giu','Lug','Ago','Set','Ott','Nov','Dic'];
    const barLabels = [], barValues = [], barHighlight = [], barProjected = [], barEstimate = [];

    // Mese corrente: in Reale = incassato; in Prenotazioni = valore booking passati,
    // con la proiezione futura nella barra tratteggiata (barProjected).
    const cmFrom    = new Date(now.getFullYear(), now.getMonth(), 1);
    const cmTo      = new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999);
    const cmActual  = isReale
        ? payInRange(cmFrom, new Date(pastCutoff.getTime() - 1))
        : allBookings.filter(b => { const d = new Date(b.date + 'T00:00:00'); return d >= cmFrom && d < pastCutoff; }).reduce(revFn, 0);
    const cmFuture  = isReale
        ? payInRange(pastCutoff, cmTo)
        : allBookings.filter(b => { const d = new Date(b.date + 'T00:00:00'); return d >= pastCutoff && d <= cmTo; }).reduce(revFn, 0);

    // i=-11..0 = ultimi 12 mesi (corrente = i=0, rightmost), i=1 = mese successivo
    for (let i = -11; i <= 1; i++) {
        const d     = new Date(now.getFullYear(), now.getMonth() + i, 1);
        const mFrom = new Date(d.getFullYear(), d.getMonth(), 1);
        const mTo   = new Date(d.getFullYear(), d.getMonth() + 1, 0, 23, 59, 59, 999);
        const isCurrent = i === 0;
        const isFuture  = i > 0;
        const label = MONTH_NAMES[d.getMonth()] + (d.getFullYear() !== now.getFullYear() ? ` '${String(d.getFullYear()).slice(2)}` : '');
        barLabels.push(label);
        if (isCurrent) {
            barValues.push(cmActual);
            barHighlight.push(true);
            // In modalità Reale: niente proiezione rossa (i pagamenti sono registrati a posteriori)
            barProjected.push(isReale ? 0 : cmFuture);
        } else if (isFuture) {
            if (isReale) {
                // Reale: nessun incasso futuro registrabile
                barValues.push(0);
                barHighlight.push(false);
                barProjected.push(0);
            } else {
                // Prenotazioni: barra tratteggiata = valore prenotazioni confermate
                const confirmedRev = allBookings
                    .filter(b => { const bd = new Date(b.date + 'T00:00:00'); return bd >= mFrom && bd <= mTo; })
                    .reduce(revFn, 0);
                barValues.push(0);
                barHighlight.push(false);
                barProjected.push(confirmedRev);
            }
        } else {
            // Mesi passati: barra solida = fatturato definitivo
            const rev = isReale
                ? payInRange(mFrom, mTo)
                : allBookings.filter(b => { const bd = new Date(b.date + 'T00:00:00'); return bd >= mFrom && bd <= mTo; }).reduce(revFn, 0);
            barValues.push(rev);
            barHighlight.push(false);
            barProjected.push(0);
        }

        // ── Stima verde: proiezione su giorni futuri non programmati ──────────
        // Solo per mese corrente e futuro; in Reale niente stima (dati definitivi).
        if (i >= 0 && !isReale) {
            const daysInMonth = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
            let schDays = 0, futUnschDays = 0;
            for (let day = 1; day <= daysInMonth; day++) {
                const dayDate = new Date(d.getFullYear(), d.getMonth(), day);
                const ds = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
                const hasSlots = overrides[ds] && overrides[ds].length > 0;
                if (hasSlots) schDays++;
                else if (dayDate >= pastCutoff) futUnschDays++;
            }
            const knownRev = barValues[barValues.length - 1] + barProjected[barProjected.length - 1];
            barEstimate.push(schDays > 0 && futUnschDays > 0
                ? Math.round(knownRev / schDays * futUnschDays) : 0);
        } else {
            barEstimate.push(0);
        }
    }

    // ── Forecast chart: actual (past) + confirmed future as cumulative ────────
    // Calcolo media ricavo/giorno programmato per la linea verde stima
    let _fcSchedDays = 0;
    for (let dd = 0; dd < totalDays; dd++) {
        const day = new Date(from.getTime() + dd * 86400000);
        const ds = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
        if (overrides[ds] && overrides[ds].length > 0) _fcSchedDays++;
    }
    const avgRevPerSchedDay = (!isReale && _fcSchedDays > 0) ? (pastRevenue + futureRevenue) / _fcSchedDays : 0;

    const useWeekly  = totalDays > 60;
    const groupDays  = useWeekly ? 7 : 1;
    const groups     = Math.ceil(totalDays / groupDays);
    const fActual = [], fForecast = [], fEstimate = [], fLabels = [];

    const todayGroupIdx = (pastCutoff >= from && pastCutoff <= to)
        ? Math.floor((pastCutoff.getTime() - periodStart) / (86400000 * groupDays))
        : null;

    // Mappe ricavo per data: in Reale dal ledger, in Prenotazioni dai booking.
    const revByDate = {};
    const futureRevByDate = {};
    if (isReale) {
        payments.forEach(p => {
            const d = new Date(p.date);
            const ds = _localDateStr(d);
            if (d >= from && d < pastCutoff)                  revByDate[ds]       = (revByDate[ds] || 0)       + p.amount;
            else if (d >= pastCutoff && d >= from && d <= to) futureRevByDate[ds] = (futureRevByDate[ds] || 0) + p.amount;
        });
    } else {
        allBookings.forEach(b => {
            const d = new Date(b.date + 'T00:00:00');
            if (d >= from && d < pastCutoff)             revByDate[b.date]       = (revByDate[b.date] || 0)       + getBookingPrice(b);
            if (d >= pastCutoff && d >= from && d <= to) futureRevByDate[b.date] = (futureRevByDate[b.date] || 0) + getBookingPrice(b);
        });
    }

    let cumRev = 0, cumFuture = 0, cumEstExtra = 0;
    for (let g = 0; g < groups; g++) {
        const gStart = new Date(periodStart + g * groupDays * 86400000);
        const gEnd   = new Date(periodStart + (g + 1) * groupDays * 86400000 - 1);
        fLabels.push(`${gStart.getDate()}/${gStart.getMonth() + 1}`);

        // Conta giorni futuri senza slot in questo gruppo (per stima verde)
        let unschInGroup = 0;
        for (let dd = 0; dd < groupDays; dd++) {
            const day = new Date(periodStart + (g * groupDays + dd) * 86400000);
            if (day < pastCutoff || day > to) continue;
            const ds = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
            if (!overrides[ds] || overrides[ds].length === 0) unschInGroup++;
        }
        cumEstExtra += unschInGroup * avgRevPerSchedDay;

        if (gEnd < pastCutoff) {
            // Fully past — actual only
            let gRev = 0;
            for (let dd = 0; dd < groupDays; dd++) {
                const day = new Date(periodStart + (g * groupDays + dd) * 86400000);
                gRev += revByDate[_localDateStr(day)] || 0;
            }
            cumRev += gRev;
            fActual.push(cumRev);
            fForecast.push(null);
            fEstimate.push(null);
        } else if (gStart >= pastCutoff) {
            // Fully future — confirmed bookings cumulative
            let gFutureRev = 0;
            for (let dd = 0; dd < groupDays; dd++) {
                const day = new Date(periodStart + (g * groupDays + dd) * 86400000);
                gFutureRev += futureRevByDate[_localDateStr(day)] || 0;
            }
            cumFuture += gFutureRev;
            fActual.push(null);
            fForecast.push(pastRevenue + cumFuture);
            fEstimate.push(cumEstExtra > 0 ? pastRevenue + cumFuture + Math.round(cumEstExtra) : null);
        } else {
            // Straddles pastCutoff — partial actual + start of forecast (connect both lines)
            let gRev = 0, gFutureRev = 0;
            for (let dd = 0; dd < groupDays; dd++) {
                const day = new Date(periodStart + (g * groupDays + dd) * 86400000);
                if (day < pastCutoff) gRev       += revByDate[_localDateStr(day)] || 0;
                else                  gFutureRev += futureRevByDate[_localDateStr(day)] || 0;
            }
            cumRev    += gRev;
            cumFuture += gFutureRev;
            fActual.push(cumRev);
            fForecast.push(cumRev + cumFuture);
            fEstimate.push(cumEstExtra > 0 ? cumRev + cumFuture + Math.round(cumEstExtra) : null);
        }
    }

    // Bridge: collega la linea actual alla linea forecast/estimate nel punto di transizione
    // Con groupDays=1 il caso "straddles" non scatta mai, quindi serve un ponte esplicito
    for (let g = 0; g < groups - 1; g++) {
        if (fActual[g] != null && fActual[g + 1] == null) {
            // Ultimo punto actual → primo punto forecast: imposta forecast qui per collegare le linee
            if (fForecast[g] == null) fForecast[g] = fActual[g];
            if (fEstimate[g + 1] != null && fEstimate[g] == null) fEstimate[g] = fActual[g];
            break;
        }
    }

    // ── Pie chart per tipo di lezione (modalità Prenotazioni) ─────────────────
    const typeConfig = [
        { key: 'personal-training', label: 'Autonomia' },
        { key: 'small-group',       label: 'Lez. Gruppo' },
        { key: 'group-class',       label: 'Slot prenotato' },
    ];
    const typeStats = typeConfig.map(({ key, label }) => {
        const pastB   = pastBookings.filter(b => b.slotType === key);
        const futureB = futureBookings.filter(b => b.slotType === key);
        return {
            label,
            pastCount:    pastB.length,
            pastRev:      pastB.reduce((s, b) => s + getBookingPrice(b), 0),
            futureCount:  futureB.length,
            futureRev:    futureB.reduce((s, b) => s + getBookingPrice(b), 0),
        };
    }).filter(t => t.pastCount + t.futureCount > 0);
    const typePieData = {
        labels: typeStats.map(t => t.label),
        values: typeStats.map(t => t.pastRev + t.futureRev),
    };
    // Colori: verde (Autonomia), giallo (Gruppo), rosso (Slot)
    const pieColors = ['#22c55e', '#f59e0b', '#e63946'];

    // ── Stima futura: solo giorni futuri senza slot programmati ────────────
    // Conta i giorni futuri (da oggi in poi) nel periodo che NON hanno slot.
    // Media ricavo/giorno calcolata su TUTTI i giorni programmati (passati+futuri).
    const schedOverrides = BookingStorage.getScheduleOverrides();
    const periodTotalDays = Math.ceil((to - from) / 86400000);
    let periodScheduledDays = 0;
    let futureUnscheduledDays = 0;
    for (let dd = 0; dd < periodTotalDays; dd++) {
        const day = new Date(from.getTime() + dd * 86400000);
        const ds = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
        const hasSlots = schedOverrides[ds] && schedOverrides[ds].length > 0;
        if (hasSlots) {
            periodScheduledDays++;
        } else if (day >= pastCutoff) {
            futureUnscheduledDays++;
        }
    }
    const knownPeriodRev = pastRevenue + futureRevenue;
    const scheduleEstimate = (periodScheduledDays > 0 && futureUnscheduledDays > 0)
        ? knownPeriodRev + Math.round(knownPeriodRev / periodScheduledDays * futureUnscheduledDays)
        : knownPeriodRev;

    // ── Fatturato per tipo di pagamento (solo Reale) ───────────────────────
    // Soldi in cassa raggruppati per `method` del ledger payments.
    let payMethodStats = [], payMethodPieData = {}, payMethodColors = [], freeLessonCount = 0, freeLessonValue = 0;
    if (isReale) {
        const PAY_METHODS = [
            { key: 'contanti',         label: 'Contanti',            color: '#22c55e' },
            { key: 'contanti-report',  label: 'Contanti con Report', color: '#ef4444' },
            { key: 'carta',            label: 'Carta',               color: '#3b82f6' },
            { key: 'iban',             label: 'Bonifico',            color: '#f59e0b' },
            { key: 'stripe',           label: 'Stripe',              color: '#635bff' },
        ];
        // Somma payments nel periodo per metodo
        const periodPayments = payments.filter(p => {
            const d = new Date(p.date);
            return d >= from && d <= to;
        });
        const payByMethod = {};
        periodPayments.forEach(p => {
            if (p.method === 'gratuito') return; // gestito a parte come "Lezione gratuita"
            payByMethod[p.method] = (payByMethod[p.method] || 0) + p.amount;
        });
        payMethodStats = PAY_METHODS
            .map(({ label, key, color }) => ({ label, color, rev: payByMethod[key] || 0 }))
            .filter(m => m.rev > 0);
        // Metodi non in whitelist (es. pacchetto/abbonamento registrati con altro method) → "Altro"
        const knownKeys = new Set(PAY_METHODS.map(m => m.key).concat(['gratuito']));
        const otherRev = periodPayments
            .filter(p => !knownKeys.has(p.method))
            .reduce((s, p) => s + p.amount, 0);
        if (otherRev > 0) payMethodStats.push({ label: 'Altro', color: '#94a3b8', rev: Math.round(otherRev * 100) / 100 });
        payMethodPieData = {
            labels: payMethodStats.map(m => m.label),
            values: payMethodStats.map(m => m.rev),
        };
        payMethodColors = payMethodStats.map(m => m.color);
        // Lezioni gratuite nel periodo (kind/method 'gratuito' nel ledger)
        const freePayments = periodPayments.filter(p => p.method === 'gratuito');
        freeLessonCount = freePayments.length;
        freeLessonValue = freePayments.reduce((s, p) => s + p.amount, 0);
    }

    // ── Render ────────────────────────────────────────────────────────────────
    const pastLabel   = isReale ? 'Incassato' : 'Prenotazioni fatte';
    const futureLabel = isReale ? 'Incassato futuro' : 'Prenotazioni future';

    // KPI cards: in Reale nascondi "Pagato futuro" e "Stima futura"
    const kpiCards = `
            <div class="stat-detail-kpi stat-detail-kpi--actual">
                <div class="stat-detail-kpi-value">${fmtReale(pastRevenue)}</div>
                <div class="stat-detail-kpi-label">${pastLabel}</div>
            </div>
            ${!isReale ? `<div class="stat-detail-kpi stat-detail-kpi--future">
                <div class="stat-detail-kpi-value">€${futureRevenue}</div>
                <div class="stat-detail-kpi-label">${futureLabel}</div>
            </div>
            <div class="stat-detail-kpi stat-detail-kpi--projected">
                <div class="stat-detail-kpi-value">€${scheduleEstimate}</div>
                <div class="stat-detail-kpi-label">Stima futura</div>
            </div>` : `<div class="stat-detail-kpi stat-detail-kpi--actual">
                <div class="stat-detail-kpi-value">${fmtReale(Math.round(payMethodStats.reduce((s, m) => s + m.rev, 0) * 100) / 100)}</div>
                <div class="stat-detail-kpi-label">Fatturato reale</div>
            </div>`}
            <div class="stat-detail-kpi">
                <div class="stat-detail-kpi-value">${fmtReale(weeklyAvg)}</div>
                <div class="stat-detail-kpi-label">Media settimanale</div>
            </div>`;

    panel.innerHTML = `
        <div class="stat-detail-header">
            <h3>💰 Fatturato — Dettaglio</h3>
            <div class="stat-detail-mode-tabs">
                <button class="stat-mode-btn${!isReale ? ' active' : ''}" onclick="switchFatturatoMode('prenotazioni')">Prenotazioni</button>
                <button class="stat-mode-btn${isReale ? ' active' : ''}" onclick="switchFatturatoMode('reale')">Reale</button>
            </div>
            <span class="stat-detail-period">${getFilterLabel(currentFilter)}</span>
        </div>
        <div class="stat-detail-kpis">
            ${kpiCards}
        </div>
        <div class="stat-detail-charts">
            <div class="stat-detail-chart-block">
                <h4>Fatturato mensile (ultimi 12 mesi + successivo)</h4>
                <canvas id="detailBarChart" style="width:100%;display:block;"></canvas>
            </div>
            <div class="stat-detail-chart-block">
                <h4>Andamento e proiezione — ${getFilterLabel(currentFilter)}</h4>
                <canvas id="detailForecastChart" style="width:100%;display:block;"></canvas>
            </div>
        </div>

        ${isReale ? `<div class="stat-detail-chart-block stat-detail-type-section">
            <h4>Fatturato per tipo di pagamento</h4>
            <canvas id="detailPayMethodChart" style="width:100%;display:block;"></canvas>
            ${(payMethodStats.length > 0 || freeLessonCount > 0) ? `<div class="stat-detail-breakdown" style="margin-top:0.5rem">
                <div class="sdb-rows">
                    ${payMethodStats.map(m => `<div class="sdb-row">
                        <span class="sdb-label"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${m.color};margin-right:6px"></span>${m.label}</span>
                        <span class="sdb-value sdb-bold">€${m.rev}</span>
                    </div>`).join('')}
                    ${freeLessonCount > 0 ? `<div class="sdb-row">
                        <span class="sdb-label"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:#a855f7;margin-right:6px"></span>Lezione gratuita</span>
                        <span class="sdb-value sdb-bold">€${freeLessonValue}</span>
                    </div>` : ''}
                </div>
            </div>` : ''}
        </div>` : `<div class="stat-detail-chart-block stat-detail-type-section">
            <h4>Fatturato per tipo di lezione</h4>
            <canvas id="detailTypeChart" style="width:100%;display:block;"></canvas>
        </div>`}
    `;

    requestAnimationFrame(() => {
        const barCanvas = document.getElementById('detailBarChart');
        if (barCanvas) new SimpleChart(barCanvas).drawBarChart({ labels: barLabels, values: barValues, highlight: barHighlight, projected: barProjected, estimated: barEstimate });

        const fcCanvas = document.getElementById('detailForecastChart');
        if (fcCanvas) new SimpleChart(fcCanvas).drawForecastChart({ actual: fActual, forecast: fForecast, estimated: fEstimate, labels: fLabels, todayIndex: todayGroupIdx });

        const isMobilePie = window.innerWidth < 768;
        const pieH = isMobilePie ? 310 : 250;

        if (isReale) {
            const payCanvas = document.getElementById('detailPayMethodChart');
            if (payCanvas && payMethodStats.length > 0) {
                new SimpleChart(payCanvas, { height: pieH }).drawPieChart(payMethodPieData, { colors: payMethodColors, mobile: isMobilePie });
            }
        } else {
            const typeCanvas = document.getElementById('detailTypeChart');
            if (typeCanvas && typeStats.length > 0) {
                new SimpleChart(typeCanvas, { height: pieH }).drawPieChart(typePieData, { colors: pieColors, mobile: isMobilePie });
            }
        }
    });
}

function renderPrenotazioniDetail(panel) {
    const allBookings = _statsBookings ?? _excludeAdminBookings(BookingStorage.getAllBookings());
    const { from, to } = getFilterDateRange(currentFilter);
    const now   = new Date();
    const today = new Date(now); today.setHours(0, 0, 0, 0);
    const yesterday = new Date(today); yesterday.setDate(yesterday.getDate() - 1);
    const overrides = BookingStorage.getScheduleOverrides();

    const periodBookings = allBookings.filter(b => {
        if (b.status === 'cancelled') return false;
        const d = new Date(b.date + 'T00:00:00');
        return d >= from && d <= to;
    });
    const pastBookings   = periodBookings.filter(b => new Date(b.date + 'T00:00:00') < today);
    const futureBookings = periodBookings
        .filter(b => new Date(b.date + 'T00:00:00') >= today)
        .sort((a, b) => a.date.localeCompare(b.date) || a.time.localeCompare(b.time));

    const cancelledInPeriod = allBookings.filter(b => {
        if (b.status !== 'cancelled') return false;
        const d = new Date(b.date + 'T00:00:00');
        return d >= from && d <= to;
    });

    // ── KPIs ─────────────────────────────────────────────────────────────────
    const totalDays  = Math.max(1, Math.ceil((to - from) / 86400000));
    // Media settimanale basata su giorni con slot programmati
    let _pSchedDays = 0;
    for (let dd = 0; dd < totalDays; dd++) {
        const day = new Date(from.getTime() + dd * 86400000);
        const ds = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
        if (overrides[ds] && overrides[ds].length > 0) _pSchedDays++;
    }
    const weeklyAvg = _pSchedDays > 0
        ? (periodBookings.length / _pSchedDays * 7).toFixed(1)
        : (periodBookings.length / totalDays * 7).toFixed(1);
    const cancelRate = cancelledInPeriod.length > 0
        ? Math.round(cancelledInPeriod.length / (periodBookings.length + cancelledInPeriod.length) * 100)
        : 0;

    // Stima futura: basata su giorni futuri senza slot
    let periodScheduledDays = 0, futureUnscheduledDays = 0;
    for (let dd = 0; dd < totalDays; dd++) {
        const day = new Date(from.getTime() + dd * 86400000);
        const ds = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
        const hasSlots = overrides[ds] && overrides[ds].length > 0;
        if (hasSlots) periodScheduledDays++;
        else if (day >= today) futureUnscheduledDays++;
    }
    const knownCount = periodBookings.length;
    const scheduleEstimate = (periodScheduledDays > 0 && futureUnscheduledDays > 0)
        ? knownCount + Math.round(knownCount / periodScheduledDays * futureUnscheduledDays)
        : knownCount;

    // ── Bar chart: ultimi 12 mesi + 1 successivo ────────────────────────────
    const MONTH_NAMES = ['Gen','Feb','Mar','Apr','Mag','Giu','Lug','Ago','Set','Ott','Nov','Dic'];
    const trendLabels = [], trendValues = [], trendHighlight = [], trendProjected = [], trendEstimate = [];

    // Proiezione mese corrente
    const cmFrom = new Date(now.getFullYear(), now.getMonth(), 1);
    const cmTo   = new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59, 999);
    const cmActual = allBookings.filter(b => {
        if (b.status === 'cancelled') return false;
        const bd = new Date(b.date + 'T00:00:00');
        return bd >= cmFrom && bd < today;
    }).length;
    const cmFuture = allBookings.filter(b => {
        if (b.status === 'cancelled') return false;
        const bd = new Date(b.date + 'T00:00:00');
        return bd >= today && bd <= cmTo;
    }).length;
    const cmDaysElapsed = Math.max(today.getDate() - 1, 1);
    const cmDaysTotal = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
    const cmLinear = Math.round(cmActual * cmDaysTotal / cmDaysElapsed);
    const cmEstimate = cmActual + Math.max(cmFuture, cmLinear - cmActual, 0);

    // i=-11..0 = ultimi 12 mesi, i=1 = mese successivo
    for (let i = -11; i <= 1; i++) {
        const d     = new Date(now.getFullYear(), now.getMonth() + i, 1);
        const mFrom = new Date(d.getFullYear(), d.getMonth(), 1);
        const mTo   = new Date(d.getFullYear(), d.getMonth() + 1, 0, 23, 59, 59, 999);
        const isCurrent = i === 0;
        const isFuture  = i > 0;
        const label = MONTH_NAMES[d.getMonth()] + (d.getFullYear() !== now.getFullYear() ? ` '${String(d.getFullYear()).slice(2)}` : '');
        trendLabels.push(label);

        if (isCurrent) {
            trendValues.push(cmActual);
            trendHighlight.push(true);
            trendProjected.push(Math.max(0, cmEstimate - cmActual));
        } else if (isFuture) {
            const confirmed = allBookings.filter(b => {
                if (b.status === 'cancelled') return false;
                const bd = new Date(b.date + 'T00:00:00');
                return bd >= mFrom && bd <= mTo;
            }).length;
            trendValues.push(0);
            trendHighlight.push(false);
            trendProjected.push(confirmed);
        } else {
            const count = allBookings.filter(b => {
                if (b.status === 'cancelled') return false;
                const bd = new Date(b.date + 'T00:00:00');
                return bd >= mFrom && bd <= mTo;
            }).length;
            trendValues.push(count);
            trendHighlight.push(false);
            trendProjected.push(0);
        }

        // Stima verde: giorni futuri senza slot
        if (i >= 0) {
            const daysInMonth = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
            let schDays = 0, futUnschDays = 0;
            for (let day = 1; day <= daysInMonth; day++) {
                const dayDate = new Date(d.getFullYear(), d.getMonth(), day);
                const ds = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
                const hasSlots = overrides[ds] && overrides[ds].length > 0;
                if (hasSlots) schDays++;
                else if (dayDate >= today) futUnschDays++;
            }
            const knownBar = trendValues[trendValues.length - 1] + trendProjected[trendProjected.length - 1];
            if (schDays > 0 && futUnschDays > 0) {
                trendEstimate.push(Math.round(knownBar / schDays * futUnschDays));
            } else {
                trendEstimate.push(0);
            }
        } else {
            trendEstimate.push(0);
        }
    }

    // ── Per tipo ──────────────────────────────────────────────────────────────
    const typeConfig = [
        { key: 'personal-training', label: 'Autonomia' },
        { key: 'small-group',       label: 'Lez. Gruppo' },
        { key: 'group-class',       label: 'Slot prenotato' },
    ];
    const typeLabels = [], typeValues = [];
    typeConfig.forEach(({ key, label }) => {
        const c = periodBookings.filter(b => b.slotType === key).length;
        if (c > 0) { typeLabels.push(label); typeValues.push(c); }
    });

    // ── Per giorno della settimana ────────────────────────────────────────────
    const dayCounts = [0,0,0,0,0,0,0];
    periodBookings.forEach(b => { dayCounts[new Date(b.date + 'T00:00:00').getDay()]++; });
    const DAY_ORDER = [1,2,3,4,5,6,0];
    const DAY_NAMES = ['Dom','Lun','Mar','Mer','Gio','Ven','Sab'];
    const dayLabels = DAY_ORDER.map(d => DAY_NAMES[d]);
    const dayValues = DAY_ORDER.map(d => dayCounts[d]);

    // ── Per fascia oraria ─────────────────────────────────────────────────────
    const timeMap = {};
    periodBookings.forEach(b => {
        const t = b.time ? b.time.split(' - ')[0] : '?';
        timeMap[t] = (timeMap[t] || 0) + 1;
    });
    const timeSorted = Object.entries(timeMap).sort((a, b) => a[0].localeCompare(b[0]));
    const timeLabels = timeSorted.map(([t]) => t);
    const timeValues = timeSorted.map(([, c]) => c);

    // ── Fascia oraria / giorno più popolare ──────────────────────────────────
    const peakTime  = timeSorted.length ? timeSorted.reduce((a, b) => b[1] > a[1] ? b : a)[0] : '—';
    const peakDay   = dayValues.reduce((mi, v, i, a) => v > a[mi] ? i : mi, 0);

    // ── Top 5 slot più comuni (giorno + orario) ──────────────────────────────
    const slotComboMap = {};
    periodBookings.forEach(b => {
        const dow = new Date(b.date + 'T00:00:00').getDay();
        const t = b.time ? b.time.split(' - ')[0] : '?';
        const key = `${DAY_NAMES[dow]} ${t}`;
        slotComboMap[key] = (slotComboMap[key] || 0) + 1;
    });
    const topSlots = Object.entries(slotComboMap)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 5);
    const topSlotLabels = topSlots.map(([k]) => k);
    const topSlotValues = topSlots.map(([, v]) => v);

    // ── Render ────────────────────────────────────────────────────────────────
    panel.innerHTML = `
        <div class="stat-detail-header">
            <h3>📅 Prenotazioni — Dettaglio</h3>
            <span class="stat-detail-period">${getFilterLabel(currentFilter)}</span>
        </div>
        <div class="stat-detail-kpis">
            <div class="stat-detail-kpi stat-detail-kpi--actual">
                <div class="stat-detail-kpi-value">${pastBookings.length}</div>
                <div class="stat-detail-kpi-label">Passate</div>
            </div>
            <div class="stat-detail-kpi stat-detail-kpi--future">
                <div class="stat-detail-kpi-value">${futureBookings.length}</div>
                <div class="stat-detail-kpi-label">Future</div>
            </div>
            <div class="stat-detail-kpi stat-detail-kpi--projected">
                <div class="stat-detail-kpi-value">${scheduleEstimate}</div>
                <div class="stat-detail-kpi-label">Stima futura</div>
            </div>
            <div class="stat-detail-kpi">
                <div class="stat-detail-kpi-value">${weeklyAvg}</div>
                <div class="stat-detail-kpi-label">Media sett.</div>
            </div>
            <div class="stat-detail-kpi ${cancelRate > 5 ? 'stat-detail-kpi--warn' : ''}">
                <div class="stat-detail-kpi-value">${cancelRate}%</div>
                <div class="stat-detail-kpi-label">Cancellazioni</div>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-chart-block">
                <h4>Trend mensile (ultimi 12 mesi + successivo)</h4>
                <canvas id="detailTrendChart" style="width:100%;display:block;"></canvas>
            </div>
            <div class="stat-detail-chart-block">
                <h4>Per tipo di lezione</h4>
                <canvas id="detailTypeBookChart" style="width:100%;display:block;"></canvas>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-chart-block">
                <h4>Per giorno della settimana</h4>
                <canvas id="detailDayChart" style="width:100%;display:block;"></canvas>
            </div>
            <div class="stat-detail-chart-block">
                <h4>Per fascia oraria</h4>
                <canvas id="detailTimeChart" style="width:100%;display:block;"></canvas>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-chart-block">
                <h4>Top 5 slot più comuni</h4>
                <canvas id="detailTopSlotsChart" style="width:100%;display:block;"></canvas>
            </div>
        </div>

        <div class="stat-detail-breakdown" style="margin-bottom:0.25rem">
            <div class="sdb-rows">
                <div class="sdb-row">
                    <span class="sdb-label" style="color:#6b7280">Fascia oraria più popolare</span>
                    <span class="sdb-value sdb-bold">${peakTime}</span>
                </div>
                <div class="sdb-row">
                    <span class="sdb-label" style="color:#6b7280">Giorno più popolare</span>
                    <span class="sdb-value sdb-bold">${dayLabels[peakDay]}</span>
                </div>
                <div class="sdb-row sdb-row--projected">
                    <span class="sdb-label">Stima futura (+${futureUnscheduledDays} gg futuri senza slot)</span>
                    <span class="sdb-value">${scheduleEstimate}</span>
                </div>
            </div>
        </div>
    `;

    requestAnimationFrame(() => {
        const trendCanvas = document.getElementById('detailTrendChart');
        if (trendCanvas) new SimpleChart(trendCanvas).drawBarChart(
            { labels: trendLabels, values: trendValues, highlight: trendHighlight, projected: trendProjected, estimated: trendEstimate },
            { colors: ['#3b82f6'], prefix: '' }
        );
        const typeBookCanvas = document.getElementById('detailTypeBookChart');
        if (typeBookCanvas && typeLabels.length > 0)
            new SimpleChart(typeBookCanvas).drawPieChart(
                { labels: typeLabels, values: typeValues },
                { colors: ['#22c55e', '#f59e0b', '#e63946'], prefix: '' }
            );
        const dayCanvas = document.getElementById('detailDayChart');
        if (dayCanvas) new SimpleChart(dayCanvas).drawBarChart(
            { labels: dayLabels, values: dayValues },
            { colors: ['#06b6d4'], prefix: '' }
        );
        const timeCanvas = document.getElementById('detailTimeChart');
        if (timeCanvas && timeLabels.length > 0)
            new SimpleChart(timeCanvas).drawBarChart(
                { labels: timeLabels, values: timeValues },
                { colors: ['#f97316'], prefix: '' }
            );
        const topSlotsCanvas = document.getElementById('detailTopSlotsChart');
        if (topSlotsCanvas && topSlotLabels.length > 0)
            new SimpleChart(topSlotsCanvas).drawBarChart(
                { labels: topSlotLabels, values: topSlotValues },
                { colors: ['#8b5cf6'], prefix: '' }
            );
    });
}

function renderClientiDetail(panel) {
    const allBookings = _statsBookings ?? _excludeAdminBookings(BookingStorage.getAllBookings());
    const { from, to } = getFilterDateRange(currentFilter);
    const periodFrom = from || new Date(0);
    const periodTo   = to   || new Date(9e15);
    const now  = new Date();
    const today = new Date(now); today.setHours(0, 0, 0, 0);

    // Build client map (all bookings in period, incluse cancellate)
    const clientMap = {};
    allBookings.forEach(b => {
        const bd = new Date(b.date + 'T00:00:00');
        if (bd < periodFrom || bd > periodTo) return;
        const key = b.email || b.whatsapp || b.name;
        if (!clientMap[key]) clientMap[key] = { name: b.name, total: 0, cancelled: 0, future: 0 };
        if (b.status === 'cancelled') {
            clientMap[key].cancelled++;
        } else {
            clientMap[key].total++;
            if (bd >= today) clientMap[key].future++;
        }
    });

    const clients = Object.values(clientMap);
    const activeClients = clients.filter(c => c.total > 0);
    const totalUnique = clients.length;
    const totalBookings = activeClients.reduce((s, c) => s + c.total, 0);
    const avgBookings = activeClients.length ? (totalBookings / activeClients.length).toFixed(1) : '0';
    const withCancellations = clients.filter(c => c.cancelled > 0).length;
    const cancelClientsRate = totalUnique ? Math.round(withCancellations / totalUnique * 100) : 0;

    // Nuovi clienti: prima prenotazione in assoluto cade nel periodo
    const firstBookingByKey = {};
    allBookings.forEach(b => {
        if (b.status === 'cancelled') return;
        const key = b.email || b.whatsapp || b.name;
        const bd  = new Date(b.date + 'T00:00:00');
        if (!firstBookingByKey[key] || bd < firstBookingByKey[key].date)
            firstBookingByKey[key] = { date: bd, name: b.name };
    });
    const newClients = Object.values(firstBookingByKey)
        .filter(c => c.date >= periodFrom && c.date <= periodTo)
        .sort((a, b) => a.date - b.date);

    const topActive    = [...activeClients].sort((a, b) => b.total - a.total).slice(0, 5);
    const leastActive  = [...activeClients].sort((a, b) => a.total - b.total).slice(0, 5);
    const topCancellers = clients.filter(c => c.cancelled > 0).sort((a, b) => b.cancelled - a.cancelled).slice(0, 5);
    const mostLoyal    = [...activeClients].filter(c => c.cancelled === 0).sort((a, b) => b.total - a.total).slice(0, 5);

    // ── Classifica soldi realmente versati per cliente (dal ledger payments) ──
    // Fonte unica: tabella `payments` (org-scoped via RLS). Mappa per email cliente
    // → nome dall'ultimo booking, fallback all'email.
    const _payments = _statsPayments || [];
    const nameByEmail = {};
    allBookings.forEach(b => { if (b.email) nameByEmail[b.email.toLowerCase()] = b.name; });
    const clientCashMap = {};
    const moraUsers = {};
    _payments.forEach(p => {
        const d = new Date(p.date);
        if (d < periodFrom || d > periodTo) return;
        if (p.method === 'gratuito') return; // lezioni gratuite: nessun incasso
        const emailKey = (p.email || '').toLowerCase();
        const key  = emailKey || p.email || '(sconosciuto)';
        const name = nameByEmail[emailKey] || p.email || '(sconosciuto)';
        // Maggior fatturato (tutti i kind tranne i gratuiti)
        if (!clientCashMap[key]) clientCashMap[key] = { name, cash: 0 };
        clientCashMap[key].cash += p.amount;
        // More (penalità cancellazione)
        if (p.kind === 'penalty_mora' && p.amount > 0) {
            if (!moraUsers[key]) moraUsers[key] = { name, count: 0, total: 0 };
            moraUsers[key].count++;
            moraUsers[key].total += p.amount;
        }
    });

    const topCash = Object.values(clientCashMap)
        .filter(c => c.cash > 0)
        .map(c => ({ name: c.name, cash: Math.round(c.cash * 100) / 100 }))
        .sort((a, b) => b.cash - a.cash)
        .slice(0, 5);

    const moraUsersList = Object.values(moraUsers)
        .map(c => ({ name: c.name, count: c.count, total: Math.round(c.total * 100) / 100 }))
        .sort((a, b) => b.total - a.total);
    const moraTotalAmount = Math.round(moraUsersList.reduce((s, c) => s + c.total, 0) * 100) / 100;

    // ── Clienti persi: attivi nel periodo precedente, assenti in quello corrente ─
    const prevRange = getPreviousFilterDateRange(currentFilter);
    let lostClients = [];
    if (prevRange) {
        const prevClientKeys = new Set();
        const currClientKeys = new Set();
        allBookings.forEach(b => {
            if (b.status === 'cancelled') return;
            const key = b.email || b.whatsapp || b.name;
            const bd = new Date(b.date + 'T00:00:00');
            if (bd >= prevRange.from && bd <= prevRange.to) prevClientKeys.add(key);
            if (bd >= periodFrom && bd <= periodTo) currClientKeys.add(key);
        });
        lostClients = [...prevClientKeys]
            .filter(k => !currClientKeys.has(k))
            .map(k => {
                // Trova il nome dall'ultimo booking
                const lastB = allBookings.filter(b => (b.email || b.whatsapp || b.name) === k && b.status !== 'cancelled').pop();
                return { name: lastB ? lastB.name : k };
            })
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    // Privacy: nasconde gli importi (***); i nomi vanno sempre escapati (XSS stored).
    const _maskAmt = txt => _sensitiveHidden ? '***' : txt;
    const _emptyRow = '<div class="sdb-row"><span class="sdb-label" style="color:#9ca3af">Nessun dato</span></div>';
    const _clientRows = (list, valueFn) => list.length === 0 ? _emptyRow :
        list.map((c, i) => `
            <div class="sdb-row">
                <span class="sdb-label">${i + 1}. ${_escHtml(c.name)}</span>
                <span class="sdb-value">${valueFn(c)}</span>
            </div>`).join('');

    panel.innerHTML = `
        <div class="stat-detail-header">
            <h3>👥 Clienti — Dettaglio</h3>
            <span class="stat-detail-period">${getFilterLabel(currentFilter)}</span>
        </div>
        <div class="stat-detail-kpis">
            <div class="stat-detail-kpi">
                <div class="stat-detail-kpi-value">${totalUnique}</div>
                <div class="stat-detail-kpi-label">Clienti unici</div>
            </div>
            <div class="stat-detail-kpi stat-detail-kpi--projected">
                <div class="stat-detail-kpi-value">${newClients.length}</div>
                <div class="stat-detail-kpi-label">Nuovi clienti</div>
            </div>
            <div class="stat-detail-kpi">
                <div class="stat-detail-kpi-value">${avgBookings}</div>
                <div class="stat-detail-kpi-label">Media lezioni/cliente</div>
            </div>
            <div class="stat-detail-kpi ${cancelClientsRate > 20 ? 'stat-detail-kpi--warn' : ''}">
                <div class="stat-detail-kpi-value">${cancelClientsRate}%</div>
                <div class="stat-detail-kpi-label">Con cancellazioni</div>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-breakdown">
                <h4>💰 Maggior fatturato (versato)</h4>
                <div class="sdb-rows">
                    ${_clientRows(topCash, c => _maskAmt(`€${c.cash}`))}
                </div>
            </div>
            <div class="stat-detail-breakdown">
                <h4>🏆 Più attivi nel periodo</h4>
                <div class="sdb-rows">
                    ${_clientRows(topActive, c => `${c.total} lezioni`)}
                </div>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-breakdown">
                <h4>💤 Meno attivi nel periodo</h4>
                <div class="sdb-rows">
                    ${_clientRows(leastActive, c => `${c.total} lezioni`)}
                </div>
            </div>
            <div class="stat-detail-breakdown">
                <h4>❌ Top annullatori</h4>
                <div class="sdb-rows">
                    ${_clientRows(topCancellers, c => `${c.cancelled} cancellaz.`)}
                </div>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-breakdown">
                <h4>⭐ Più fedeli (0 cancellazioni)</h4>
                <div class="sdb-rows">
                    ${_clientRows(mostLoyal, c => `${c.total} lezioni`)}
                </div>
            </div>
            <div class="stat-detail-breakdown">
                <h4>💸 Pagamento more (${moraUsersList.length}) — ${_maskAmt(`€${moraTotalAmount}`)}</h4>
                <div class="sdb-rows">
                    ${moraUsersList.length === 0
                        ? '<div class="sdb-row"><span class="sdb-label" style="color:#9ca3af">Nessuna mora nel periodo</span></div>'
                        : moraUsersList.map((c, i) => `
                            <div class="sdb-row">
                                <span class="sdb-label">${i + 1}. ${_escHtml(c.name)}</span>
                                <span class="sdb-value">${c.count} more — ${_maskAmt(`€${c.total}`)}</span>
                            </div>`).join('')
                    }
                </div>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-breakdown">
                <h4>🆕 Nuovi clienti nel periodo (${newClients.length})</h4>
                <div class="sdb-rows">
                    ${newClients.length === 0
                        ? '<div class="sdb-row"><span class="sdb-label" style="color:#9ca3af">Nessun nuovo cliente nel periodo</span></div>'
                        : newClients.map((c, i) => `
                            <div class="sdb-row">
                                <span class="sdb-label">${i + 1}. ${_escHtml(c.name)}</span>
                                <span class="sdb-value" style="color:#9ca3af;font-size:0.8rem">${c.date.getDate()}/${c.date.getMonth()+1}/${c.date.getFullYear()}</span>
                            </div>`).join('')
                    }
                </div>
            </div>
            <div class="stat-detail-breakdown">
                <h4>📉 Clienti persi (${lostClients.length})</h4>
                <div class="sdb-rows">
                    ${lostClients.length === 0
                        ? '<div class="sdb-row"><span class="sdb-label" style="color:#9ca3af">Nessun cliente perso</span></div>'
                        : lostClients.map((c, i) => `
                            <div class="sdb-row">
                                <span class="sdb-label">${i + 1}. ${_escHtml(c.name)}</span>
                            </div>`).join('')
                    }
                </div>
            </div>
        </div>
    `;
}

let _certModalEmail    = null;
let _certModalWhatsapp = null;
let _certModalName2    = null;
let _certModalBadgeEl  = null;

// ── Raw gym_users helpers (con tutti i campi, inclusi cert) ──────────────────
function _getUsersFull() {
    return UserStorage._cache;
}
function _saveUsers(users) {
    UserStorage._cache = users;
    // Ri-persisti lo snapshot cross-pagina con la cache appena mutata (post-write admin).
    try { if (typeof UserStorage.persistSnapshot === 'function') UserStorage.persistSnapshot(); } catch (_) {}
}
async function _updateSupabaseProfile(email, whatsapp, fields) {
    if (typeof supabaseClient === 'undefined') return { ok: true };
    try {
        let query = supabaseClient.from('profiles').update(fields);
        if (email) {
            query = query.eq('email', email.toLowerCase());
        } else if (whatsapp) {
            query = query.eq('whatsapp', normalizePhone(whatsapp));
        } else {
            return { ok: true };
        }
        const { error } = await _queryWithTimeout(query);
        if (error) {
            console.error('Supabase profile update error:', error.message);
            return { ok: false, error: error.message };
        }
        return { ok: true };
    } catch (e) {
        console.warn('Supabase profile sync failed:', e);
        return { ok: false, error: e.message || 'Errore di rete' };
    }
}
function _getUserRecord(email, whatsapp) {
    const users = _getUsersFull();
    const idx = _findUserIdx(users, email, whatsapp);
    return idx !== -1 ? users[idx] : null;
}

// ── Controllo dati obbligatori per pagamento carta/bonifico ─────────────────
// Restituisce una Promise: resolve() se i dati sono completi (o appena salvati),
// reject() se l'utente annulla il popup.
let _missingDataResolve = null;
let _missingDataReject  = null;
let _missingDataEmail   = '';
let _missingDataWhatsapp = '';

function ensureClientDataForCardPayment(email, whatsapp, name) {
    const method = arguments[3]; // payment method passed as 4th arg
    const REQUIRE_DATA = new Set(['carta', 'iban', 'stripe', 'contanti-report']);
    if (!REQUIRE_DATA.has(method)) return Promise.resolve();

    const user = _getUserRecord(email, whatsapp);
    const hasCF   = !!user?.codiceFiscale;
    const hasVia  = !!user?.indirizzoVia;
    const hasPaese= !!user?.indirizzoPaese;
    const hasCap  = !!user?.indirizzoCap;

    if (hasCF && hasVia && hasPaese && hasCap) return Promise.resolve();

    // Apri popup per completare i dati
    return new Promise((resolve, reject) => {
        _missingDataResolve  = resolve;
        _missingDataReject   = reject;
        _missingDataEmail    = email;
        _missingDataWhatsapp = whatsapp;

        const overlay = document.getElementById('missingDataOverlay');
        document.getElementById('missingDataTitle').textContent = `⚠️ Dati mancanti — ${name || email}`;
        document.getElementById('mdCodiceFiscale').value = user?.codiceFiscale || '';
        document.getElementById('mdVia').value   = user?.indirizzoVia || '';
        document.getElementById('mdPaese').value = user?.indirizzoPaese || '';
        document.getElementById('mdCAP').value   = user?.indirizzoCap || '';
        document.getElementById('mdError').style.display = 'none';

        // Mostra solo i campi mancanti
        document.getElementById('mdCfField').style.display       = hasCF    ? 'none' : '';
        document.getElementById('mdViaField').style.display      = hasVia   ? 'none' : '';
        document.getElementById('mdPaeseCapField').style.display = (hasPaese && hasCap) ? 'none' : '';

        overlay.classList.add('open');
        document.getElementById('missingDataModal').classList.add('open');
    });
}

function closeMissingDataPopup() {
    document.getElementById('missingDataOverlay').classList.remove('open');
    document.getElementById('missingDataModal').classList.remove('open');
    if (_missingDataReject) { _missingDataReject('cancelled'); _missingDataReject = null; }
    _missingDataResolve = null;
}

async function saveMissingData() {
    const cf    = document.getElementById('mdCodiceFiscale').value.trim().toUpperCase();
    const via   = document.getElementById('mdVia').value.trim();
    const paese = normalizeComune(document.getElementById('mdPaese').value);
    const cap   = document.getElementById('mdCAP').value.trim();
    const errEl = document.getElementById('mdError');

    // Valida solo i campi visibili (quelli che mancavano)
    const cfField = document.getElementById('mdCfField');
    if (cfField.style.display !== 'none' && cf) {
        if (!/^[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]$/i.test(cf)) {
            errEl.textContent = 'Codice Fiscale non valido.';
            errEl.style.display = 'block';
            return;
        }
    }
    if (cfField.style.display !== 'none' && !cf) {
        errEl.textContent = 'Il Codice Fiscale è obbligatorio.';
        errEl.style.display = 'block';
        return;
    }

    const viaField = document.getElementById('mdViaField');
    if (viaField.style.display !== 'none' && !via) {
        errEl.textContent = 'La via è obbligatoria.';
        errEl.style.display = 'block';
        return;
    }

    const paeseCapField = document.getElementById('mdPaeseCapField');
    if (paeseCapField.style.display !== 'none') {
        if (!paese) { errEl.textContent = 'Il paese è obbligatorio.'; errEl.style.display = 'block'; return; }
        if (!/^\d{5}$/.test(cap)) { errEl.textContent = 'CAP non valido (5 cifre).'; errEl.style.display = 'block'; return; }
    }

    // Salva nel profilo (cache locale + Supabase)
    const users = _getUsersFull();
    const idx = _findUserIdx(users, _missingDataEmail, _missingDataWhatsapp);
    const fields = {};
    if (cf)    { fields.codice_fiscale = cf;   if (idx !== -1) users[idx].codiceFiscale = cf; }
    if (via)   { fields.indirizzo_via = via;   if (idx !== -1) users[idx].indirizzoVia = via; }
    if (paese) { fields.indirizzo_paese = paese; if (idx !== -1) users[idx].indirizzoPaese = paese; }
    if (cap)   { fields.indirizzo_cap = cap;   if (idx !== -1) users[idx].indirizzoCap = cap; }

    if (Object.keys(fields).length > 0) {
        await _updateSupabaseProfile(_missingDataEmail, _missingDataWhatsapp, fields);
    }

    document.getElementById('missingDataOverlay').classList.remove('open');
    document.getElementById('missingDataModal').classList.remove('open');
    if (_missingDataResolve) { _missingDataResolve(); _missingDataResolve = null; }
    _missingDataReject = null;
}

function _findUserIdx(users, email, whatsapp) {
    // Cerca prima per email, poi per telefono normalizzato
    if (email) {
        const i = users.findIndex(u => u.email?.toLowerCase() === email.toLowerCase());
        if (i !== -1) return i;
    }
    if (whatsapp) {
        const normWa = normalizePhone(whatsapp);
        const i = users.findIndex(u => normalizePhone(u.whatsapp || '') === normWa);
        if (i !== -1) return i;
    }
    return -1;
}

function openCertModal(badgeEl, email, whatsapp, name) {
    _certModalEmail    = email;
    _certModalWhatsapp = whatsapp;
    _certModalName2    = name;
    _certModalBadgeEl  = badgeEl;

    const users = _getUsersFull();
    const idx   = _findUserIdx(users, email, whatsapp);
    const existing = idx !== -1 ? (users[idx].certificatoMedicoScadenza || '') : '';

    document.getElementById('certModalName').textContent = name;
    document.getElementById('certModalDate').value = existing;
    document.getElementById('certModalOverlay').style.display = 'block';
    document.getElementById('certModal').style.display = 'flex';
    setTimeout(() => document.getElementById('certModalDate').focus(), 50);
}

function closeCertModal() {
    document.getElementById('certModalOverlay').style.display = 'none';
    document.getElementById('certModal').style.display = 'none';
    _certModalEmail = _certModalWhatsapp = _certModalName2 = _certModalBadgeEl = null;
}

function saveCertDate() {
    const val = document.getElementById('certModalDate').value;

    const users = _getUsersFull();
    let idx = _findUserIdx(users, _certModalEmail, _certModalWhatsapp);

    if (idx === -1) {
        users.push({
            name: _certModalName2 || '',
            email: _certModalEmail || null,
            whatsapp: _certModalWhatsapp || null,
            createdAt: new Date().toISOString(),
            certificatoMedicoScadenza: val || null,
            certificatoMedicoHistory: [{ scadenza: val || null, aggiornatoIl: new Date().toISOString() }]
        });
    } else {
        const oldCert = users[idx].certificatoMedicoScadenza || '';
        if (val !== oldCert) {
            users[idx].certificatoMedicoScadenza = val || null;
            if (!users[idx].certificatoMedicoHistory) users[idx].certificatoMedicoHistory = [];
            users[idx].certificatoMedicoHistory.push({ scadenza: val || null, aggiornatoIl: new Date().toISOString() });
        }
    }
    _saveUsers(users);
    _updateSupabaseProfile(_certModalEmail, _certModalWhatsapp, { medical_cert_expiry: val || null });

    // Aggiorna sessione se è il cliente loggato
    const session = getCurrentUser();
    if (session && (
        (_certModalEmail    && session.email?.toLowerCase()    === _certModalEmail.toLowerCase()) ||
        (_certModalWhatsapp && normalizePhone(session.whatsapp) === normalizePhone(_certModalWhatsapp))
    )) {
        loginUser({ ...session, certificatoMedicoScadenza: val || null });
    }

    // Aggiorna il badge in-place
    if (_certModalBadgeEl) {
        const today = _localDateStr();
        if (!val) {
            _certModalBadgeEl.textContent = '🏥 Imposta Cert. Med';
            _certModalBadgeEl.removeAttribute('style');
        } else if (val < today) {
            const [y, m, d] = val.split('-');
            _certModalBadgeEl.textContent = `🏥 Cert. scaduto il ${d}/${m}/${y}`;
            _certModalBadgeEl.removeAttribute('style');
        } else {
            const [y, m, d] = val.split('-');
            _certModalBadgeEl.textContent = `🏥 Cert. Med valido fino al ${d}/${m}/${y}`;
            _certModalBadgeEl.style.cssText = 'background:#f0fdf4;border-color:#bbf7d0;color:#166534;border-left:3px solid #16a34a';
        }
    }

    closeCertModal();
    showToast('Certificato medico aggiornato.', 'success');
}

let _assicModalEmail    = null;
let _assicModalWhatsapp = null;
let _assicModalName2    = null;
let _assicModalBadgeEl  = null;

function openAssicModal(badgeEl, email, whatsapp, name) {
    _assicModalEmail    = email;
    _assicModalWhatsapp = whatsapp;
    _assicModalName2    = name;
    _assicModalBadgeEl  = badgeEl;

    const users = _getUsersFull();
    const idx   = _findUserIdx(users, email, whatsapp);
    const existing = idx !== -1 ? (users[idx].assicurazioneScadenza || '') : '';

    document.getElementById('assicModalName').textContent = name;
    document.getElementById('assicModalDate').value = existing;
    document.getElementById('assicModalOverlay').style.display = 'block';
    document.getElementById('assicModal').style.display = 'flex';
    setTimeout(() => document.getElementById('assicModalDate').focus(), 50);
}

function closeAssicModal() {
    document.getElementById('assicModalOverlay').style.display = 'none';
    document.getElementById('assicModal').style.display = 'none';
    _assicModalEmail = _assicModalWhatsapp = _assicModalName2 = _assicModalBadgeEl = null;
}

function saveAssicDate() {
    const val = document.getElementById('assicModalDate').value;
    const users = _getUsersFull();
    let idx = _findUserIdx(users, _assicModalEmail, _assicModalWhatsapp);

    if (idx === -1) {
        users.push({
            name: _assicModalName2 || '',
            email: _assicModalEmail || null,
            whatsapp: _assicModalWhatsapp || null,
            createdAt: new Date().toISOString(),
            assicurazioneScadenza: val || null,
            assicurazioneHistory: [{ scadenza: val || null, aggiornatoIl: new Date().toISOString() }]
        });
    } else {
        const oldAssic = users[idx].assicurazioneScadenza || '';
        if (val !== oldAssic) {
            users[idx].assicurazioneScadenza = val || null;
            if (!users[idx].assicurazioneHistory) users[idx].assicurazioneHistory = [];
            users[idx].assicurazioneHistory.push({ scadenza: val || null, aggiornatoIl: new Date().toISOString() });
        }
    }
    _saveUsers(users);
    _updateSupabaseProfile(_assicModalEmail, _assicModalWhatsapp, { insurance_expiry: val || null });

    // Aggiorna sessione se è il cliente loggato
    const session = getCurrentUser();
    if (session && (
        (_assicModalEmail    && session.email?.toLowerCase()    === _assicModalEmail.toLowerCase()) ||
        (_assicModalWhatsapp && normalizePhone(session.whatsapp) === normalizePhone(_assicModalWhatsapp))
    )) {
        loginUser({ ...session, assicurazioneScadenza: val || null });
    }

    // Aggiorna il badge in-place
    if (_assicModalBadgeEl) {
        const today = _localDateStr();
        const t30 = new Date(); t30.setDate(t30.getDate() + 30);
        const today30 = _localDateStr(t30);
        if (!val) {
            _assicModalBadgeEl.textContent = '📋 Imposta scadenza Assicurazione';
            _assicModalBadgeEl.style.cssText = 'background:#fef3c7;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b';
        } else if (val < today) {
            const [y, m, d] = val.split('-');
            _assicModalBadgeEl.textContent = `📋 Assic. scaduta il ${d}/${m}/${y}`;
            _assicModalBadgeEl.removeAttribute('style');
        } else if (val <= today30) {
            const [y, m, d] = val.split('-');
            _assicModalBadgeEl.textContent = `⏳ Assic. scade il ${d}/${m}/${y}`;
            _assicModalBadgeEl.style.cssText = 'background:#fffbeb;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b';
        } else {
            const [y, m, d] = val.split('-');
            _assicModalBadgeEl.textContent = `📋 Assic. valida fino al ${d}/${m}/${y}`;
            _assicModalBadgeEl.style.cssText = 'background:#f0fdf4;border-color:#bbf7d0;color:#166534;border-left:3px solid #16a34a';
        }
    }

    closeAssicModal();
    showToast('Assicurazione aggiornata.', 'success');
}

function renderOccupancyDetail(panel) {
    const allBookings = (_statsBookings ?? _excludeAdminBookings(BookingStorage.getAllBookings())).filter(b => b.status !== 'cancelled');
    const { from, to } = getFilterDateRange(currentFilter);
    const now   = new Date();
    const today = new Date(now); today.setHours(0, 0, 0, 0);
    const MONTHS = ['Gen','Feb','Mar','Apr','Mag','Giu','Lug','Ago','Set','Ott','Nov','Dic'];
    const DAY_NAMES = ['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato'];
    const overrides = BookingStorage.getScheduleOverrides();

    // Helper: capacità di uno slot in base al tipo
    const slotCap = (type) => type === 'group-class' ? 1 : (SLOT_MAX_CAPACITY[type] || 0);

    // Helper: slots di un giorno (solo da gestione orari, no fallback template)
    const daySlotsFor = (date) => {
        const ds = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
        return overrides[ds] || [];
    };

    // ── Calcola capacità e prenotazioni per tipo per ogni mese (ultimi 12 + successivo) ──
    const trendLabels = [], ptTrend = [], sgTrend = [], gcTrend = [], trendHighlight = [];
    for (let i = 11; i >= -1; i--) {
        const mFrom = new Date(now.getFullYear(), now.getMonth() - i, 1);
        const mTo   = new Date(now.getFullYear(), now.getMonth() - i + 1, 0, 23, 59, 59, 999);
        const label = MONTHS[mFrom.getMonth()] + (mFrom.getFullYear() !== now.getFullYear() ? ` '${String(mFrom.getFullYear()).slice(2)}` : '');
        trendLabels.push(label);
        trendHighlight.push(i === 0);
        let ptCap = 0, sgCap = 0, gcCap = 0;
        const c = new Date(mFrom);
        while (c <= mTo) {
            daySlotsFor(c).forEach(s => {
                if (s.type === 'personal-training') ptCap += slotCap('personal-training');
                else if (s.type === 'small-group')  sgCap += slotCap('small-group');
                else if (s.type === 'group-class')  gcCap += slotCap('group-class');
            });
            c.setDate(c.getDate() + 1);
        }
        const ptB = allBookings.filter(b => { const d = new Date(b.date+'T00:00:00'); return b.slotType==='personal-training' && d>=mFrom && d<=mTo; }).length;
        const sgB = allBookings.filter(b => { const d = new Date(b.date+'T00:00:00'); return b.slotType==='small-group'        && d>=mFrom && d<=mTo; }).length;
        const gcB = allBookings.filter(b => { const d = new Date(b.date+'T00:00:00'); return b.slotType==='group-class'        && d>=mFrom && d<=mTo; }).length;
        ptTrend.push(ptCap > 0 ? Math.min(100, Math.round(ptB / ptCap * 100)) : 0);
        sgTrend.push(sgCap > 0 ? Math.min(100, Math.round(sgB / sgCap * 100)) : 0);
        gcTrend.push(gcCap > 0 ? Math.min(100, Math.round(gcB / gcCap * 100)) : 0);
    }

    // ── Calcola capacità e prenotazioni per tipo nel periodo filtro ──────────
    let ptSlots = 0, sgSlots = 0, gcSlots = 0;
    const c2 = new Date(from); c2.setHours(0,0,0,0);
    const e2 = new Date(to);   e2.setHours(23,59,59,999);
    while (c2 <= e2) {
        daySlotsFor(c2).forEach(s => {
            if (s.type === 'personal-training') ptSlots += slotCap('personal-training');
            else if (s.type === 'small-group')  sgSlots += slotCap('small-group');
            else if (s.type === 'group-class')  gcSlots += slotCap('group-class');
        });
        c2.setDate(c2.getDate() + 1);
    }
    const periodBookings = allBookings.filter(b => { const d = new Date(b.date+'T00:00:00'); return d >= from && d <= to; });
    const ptB = periodBookings.filter(b => b.slotType === 'personal-training').length;
    const sgB = periodBookings.filter(b => b.slotType === 'small-group').length;
    const gcB = periodBookings.filter(b => b.slotType === 'group-class').length;
    const ptRate = ptSlots > 0 ? Math.min(100, Math.round(ptB / ptSlots * 100)) : 0;
    const sgRate = sgSlots > 0 ? Math.min(100, Math.round(sgB / sgSlots * 100)) : 0;
    const gcRate = gcSlots > 0 ? Math.min(100, Math.round(gcB / gcSlots * 100)) : 0;
    const totSlots = ptSlots + sgSlots + gcSlots;
    const totRate  = totSlots > 0 ? Math.min(100, Math.round((ptB + sgB + gcB) / totSlots * 100)) : 0;

    // ── Occupancy per giorno della settimana ─────────────────────────────────
    const DOW_ORDER = [1,2,3,4,5,6,0];
    const DOW_NAMES = ['Dom','Lun','Mar','Mer','Gio','Ven','Sab'];
    const dowLabels = DOW_ORDER.map(d => DOW_NAMES[d]);
    // Calcola capacità e prenotazioni per ogni giorno della settimana nel periodo
    const dowCap = [0,0,0,0,0,0,0];
    const dowBk  = [0,0,0,0,0,0,0];
    const tmp = new Date(from); tmp.setHours(0,0,0,0);
    while (tmp <= e2) {
        const dow = tmp.getDay();
        daySlotsFor(tmp).forEach(s => { dowCap[dow] += slotCap(s.type); });
        tmp.setDate(tmp.getDate() + 1);
    }
    periodBookings.forEach(b => {
        const dow = new Date(b.date + 'T00:00:00').getDay();
        dowBk[dow]++;
    });
    const dowRates = DOW_ORDER.map(dow =>
        dowCap[dow] > 0 ? Math.min(100, Math.round(dowBk[dow] / dowCap[dow] * 100)) : 0
    );

    panel.innerHTML = `
        <div class="stat-detail-header">
            <h3>📊 Occupazione — Dettaglio</h3>
            <span class="stat-detail-period">${getFilterLabel(currentFilter)}</span>
        </div>
        <div class="stat-detail-kpis">
            <div class="stat-detail-kpi">
                <div class="stat-detail-kpi-value">${totRate}%</div>
                <div class="stat-detail-kpi-label">Totale</div>
            </div>
            <div class="stat-detail-kpi stat-detail-kpi--future">
                <div class="stat-detail-kpi-value">${ptRate}%</div>
                <div class="stat-detail-kpi-label">Autonomia</div>
            </div>
            <div class="stat-detail-kpi stat-detail-kpi--projected">
                <div class="stat-detail-kpi-value">${sgRate}%</div>
                <div class="stat-detail-kpi-label">Lez. Gruppo</div>
            </div>
            <div class="stat-detail-kpi">
                <div class="stat-detail-kpi-value">${ptB + sgB + gcB}</div>
                <div class="stat-detail-kpi-label">Prenotazioni</div>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-chart-block">
                <h4>Autonomia — ultimi 12 mesi + successivo</h4>
                <canvas id="occPtChart" style="width:100%;display:block;"></canvas>
            </div>
            <div class="stat-detail-chart-block">
                <h4>Lezioni di Gruppo — ultimi 12 mesi + successivo</h4>
                <canvas id="occSgChart" style="width:100%;display:block;"></canvas>
            </div>
        </div>

        <div class="stat-detail-charts">
            <div class="stat-detail-chart-block">
                <h4>Occupazione per giorno della settimana</h4>
                <canvas id="occDowChart" style="width:100%;display:block;"></canvas>
            </div>
        </div>
    `;

    requestAnimationFrame(() => {
        const ptCanvas = document.getElementById('occPtChart');
        if (ptCanvas) new SimpleChart(ptCanvas).drawBarChart(
            { labels: trendLabels, values: ptTrend, highlight: trendHighlight },
            { colors: ['#22c55e'], prefix: '', suffix: '%' }
        );
        const sgCanvas = document.getElementById('occSgChart');
        if (sgCanvas) new SimpleChart(sgCanvas).drawBarChart(
            { labels: trendLabels, values: sgTrend, highlight: trendHighlight },
            { colors: ['#f59e0b'], prefix: '', suffix: '%' }
        );
        const dowCanvas = document.getElementById('occDowChart');
        if (dowCanvas) new SimpleChart(dowCanvas).drawBarChart(
            { labels: dowLabels, values: dowRates },
            { colors: ['#3b82f6'], prefix: '', suffix: '%' }
        );
    });
}

// ── End Statistics Detail Panel ───────────────────────────────────────────────

// ── Weekly Card-Payment Report ───────────────────────────────────────────────

// Returns {from: Date, to: Date, label: string} for the previous Monday–Sunday week
function _getPreviousWeekRange() {
    const now = new Date();
    // JavaScript: 0=Sun, 1=Mon, …, 6=Sat
    const day = now.getDay();
    // Days since last Monday (if today is Monday day=1 → 7 days back to previous Mon)
    const daysSinceMonday = day === 0 ? 6 : day - 1;
    const thisMonday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysSinceMonday);
    const prevMonday = new Date(thisMonday);
    prevMonday.setDate(prevMonday.getDate() - 7);
    const prevSunday = new Date(prevMonday);
    prevSunday.setDate(prevSunday.getDate() + 6);

    const fmt = d => d.toLocaleDateString('it-IT', { day: '2-digit', month: '2-digit', year: 'numeric' });
    return {
        from: prevMonday,
        to: prevSunday,
        label: `${fmt(prevMonday)} – ${fmt(prevSunday)}`
    };
}

// Key for localStorage to track dismissed banner per week
function _weeklyReportKey() {
    const { from } = _getPreviousWeekRange();
    return `weeklyReportDismissed_${from.toISOString().slice(0, 10)}`;
}

function checkWeeklyReportBanner() {
    const banner = document.getElementById('weeklyReportBanner');
    if (!banner) return;

    const today = new Date().getDay(); // 0=Sun, 1=Mon
    const dismissed = localStorage.getItem(_weeklyReportKey()) === 'true';

    // Show banner on Monday (day=1) if not dismissed for this week
    if (today === 1 && !dismissed) {
        const { label } = _getPreviousWeekRange();
        const periodEl = document.getElementById('weeklyReportPeriod');
        if (periodEl) periodEl.textContent = `Pagamenti report fiscale: ${label}`;
        banner.style.display = 'block';
    } else {
        banner.style.display = 'none';
    }
}

function dismissWeeklyReport() {
    localStorage.setItem(_weeklyReportKey(), 'true');
    const banner = document.getElementById('weeklyReportBanner');
    if (banner) banner.style.display = 'none';
}

async function downloadWeeklyReport() {
    const { from, to, label } = _getPreviousWeekRange();
    const pad = n => String(n).padStart(2, '0');
    const localDate = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    const fromStr = localDate(from);
    const toStr   = localDate(to);

    // Show loading
    const btn = document.querySelector('.weekly-report-banner-btn');
    const origLabel = btn?.innerHTML;
    if (btn) { btn.innerHTML = '⏳ Generazione...'; btn.disabled = true; }

    try {
        // Sync fresh data from Supabase before generating the report
        await UserStorage.syncUsersFromSupabase();

        // Pagamenti report fiscale: dal ledger payments, metodi tracciati fiscalmente.
        const REPORT_METHODS = new Set(['carta', 'iban', 'stripe', 'contanti-report']);
        const METHOD_LABEL_REPORT = { carta: 'Carta', iban: 'Bonifico', stripe: 'Stripe', 'contanti-report': 'Contanti con Report' };
        const KIND_LABEL = {
            session:          'Sessione',
            membership:       'Abbonamento',
            package_purchase: 'Pacchetto',
            penalty_mora:     'Mora',
            adjustment:       'Rettifica'
        };

        // Fetch diretto del ledger nel range (RLS filtra org_id)
        const payments = (await _fetchPayments(fromStr, toStr)) || [];

        // Build user map for codice_fiscale lookup
        const allUsers = UserStorage.getAll();
        const userMap = {};
        allUsers.forEach(u => {
            if (u.email) userMap[u.email.toLowerCase()] = u;
        });

        function splitName(fullName) {
            if (!fullName) return { nome: '', cognome: '' };
            const parts = (fullName || '').trim().split(/\s+/);
            if (parts.length <= 1) return { nome: parts[0] || '', cognome: '' };
            return { nome: parts[0], cognome: parts.slice(1).join(' ') };
        }

        function fmtDateTime(iso) {
            if (!iso) return '';
            const d = new Date(iso);
            return isNaN(d) ? iso : d.toLocaleString('it-IT');
        }

        // Build rows dal ledger
        const rows = [];
        payments
            .filter(p => REPORT_METHODS.has(p.method) && p.amount > 0)
            .forEach(p => {
                const user = userMap[(p.email || '').toLowerCase()];
                const { nome, cognome } = splitName(user?.name || p.email || '');
                const addr = [user?.indirizzoVia, user?.indirizzoPaese, user?.indirizzoCap].filter(Boolean).join(', ');
                rows.push({
                    nome,
                    cognome,
                    cf: user?.codiceFiscale || '',
                    indirizzo: addr,
                    data: fmtDateTime(p.date),
                    sortKey: p.date || '',
                    tipo: KIND_LABEL[p.kind] || p.kind || '',
                    metodo: METHOD_LABEL_REPORT[p.method] || p.method,
                    importo: p.amount
                });
            });

        // Sort by date ascending
        rows.sort((a, b) => (a.sortKey || '').localeCompare(b.sortKey || ''));

        // Build XLSX
        const sheetData = [
            ['Nome', 'Cognome', 'Codice Fiscale', 'Indirizzo', 'Data e Ora Pagamento', 'Tipo di Pagamento', 'Metodo Pagamento', 'Importo (€)'],
            ...rows.map(r => [r.nome, r.cognome, r.cf, r.indirizzo, r.data, r.tipo, r.metodo, r.importo])
        ];

        const wb = XLSX.utils.book_new();
        const ws = XLSX.utils.aoa_to_sheet(sheetData);
        ws['!cols'] = [
            { wch: 18 }, { wch: 20 }, { wch: 20 }, { wch: 35 }, { wch: 22 }, { wch: 22 }, { wch: 18 }, { wch: 12 }
        ];
        XLSX.utils.book_append_sheet(wb, ws, 'Pagamenti Report Fiscale');

        const fromFmt = fromStr.split('-').reverse().join('-');
        const toFmt   = toStr.split('-').reverse().join('-');
        XLSX.writeFile(wb, `TB_Report_Fiscale_${fromFmt}_${toFmt}.xlsx`);

        // Dismiss the banner after successful download
        dismissWeeklyReport();

        if (typeof showToast === 'function') {
            showToast(`Report scaricato: ${rows.length} pagamenti fiscali`, 'success');
        }
    } catch (err) {
        console.error('[WeeklyReport] Error:', err);
        if (typeof showToast === 'function') {
            showToast('Errore durante la generazione del report', 'error');
        }
    } finally {
        if (btn) { btn.disabled = false; btn.innerHTML = origLabel || '📥 Scarica report'; }
    }
}

// ── End Weekly Report ────────────────────────────────────────────────────────

// ── Fiscal Report (all card/bank-transfer payments) ─────────────────────────

async function downloadFiscalReport() {
    // Gate di conferma: scarica TUTTO il ledger pagamenti dello studio (egress pesante).
    // Evita che un tap accidentale faccia partire la generazione.
    if (typeof showConfirm === 'function') {
        const ok = await showConfirm({
            title: 'Scarica report fiscale completo',
            message: "Verrà generato un report con l'intero archivio dei pagamenti tracciati fiscalmente. L'operazione può richiedere tempo e traffico dati. Procedere?",
            confirmText: 'Scarica',
        });
        if (!ok) return;
    }
    const btn = document.getElementById('fiscalReportBtn');
    const origLabel = btn?.innerHTML;
    if (btn) { btn.innerHTML = '⏳ Generazione...'; btn.disabled = true; }

    try {
        await UserStorage.syncUsersFromSupabase();

        const REPORT_METHODS = new Set(['carta', 'iban', 'stripe', 'contanti-report']);
        const METHOD_LABEL_REPORT = { carta: 'Carta', iban: 'Bonifico', stripe: 'Stripe', 'contanti-report': 'Contanti con Report' };
        const KIND_LABEL = {
            session:          'Sessione',
            membership:       'Abbonamento',
            package_purchase: 'Pacchetto',
            penalty_mora:     'Mora',
            adjustment:       'Rettifica'
        };

        // Fetch diretto di TUTTO il ledger (RLS filtra org_id)
        const payments = (await _fetchPayments(null, null)) || [];

        // User map for codice fiscale / address lookup
        const allUsers = UserStorage.getAll();
        const userMap = {};
        allUsers.forEach(u => { if (u.email) userMap[u.email.toLowerCase()] = u; });

        function splitName(fullName) {
            if (!fullName) return { nome: '', cognome: '' };
            const parts = (fullName || '').trim().split(/\s+/);
            if (parts.length <= 1) return { nome: parts[0] || '', cognome: '' };
            return { nome: parts[0], cognome: parts.slice(1).join(' ') };
        }

        function fmtDateTime(iso) {
            if (!iso) return '';
            const d = new Date(iso);
            return isNaN(d) ? iso : d.toLocaleString('it-IT');
        }

        // Build rows dal ledger
        const rows = [];
        payments
            .filter(p => REPORT_METHODS.has(p.method) && p.amount > 0)
            .forEach(p => {
                const user = userMap[(p.email || '').toLowerCase()];
                const { nome, cognome } = splitName(user?.name || p.email || '');
                const addr = [user?.indirizzoVia, user?.indirizzoPaese, user?.indirizzoCap].filter(Boolean).join(', ');
                rows.push({
                    nome, cognome,
                    cf: user?.codiceFiscale || '',
                    indirizzo: addr,
                    data: fmtDateTime(p.date),
                    sortKey: p.date || '',
                    tipo: KIND_LABEL[p.kind] || p.kind || '',
                    metodo: METHOD_LABEL_REPORT[p.method] || p.method,
                    importo: p.amount
                });
            });

        // Sort by date ascending
        rows.sort((a, b) => (a.sortKey || '').localeCompare(b.sortKey || ''));

        // Build XLSX
        const sheetData = [
            ['Nome', 'Cognome', 'Codice Fiscale', 'Indirizzo', 'Data e Ora Pagamento', 'Tipo di Pagamento', 'Metodo Pagamento', 'Importo (€)'],
            ...rows.map(r => [r.nome, r.cognome, r.cf, r.indirizzo, r.data, r.tipo, r.metodo, r.importo])
        ];

        const wb = XLSX.utils.book_new();
        const ws = XLSX.utils.aoa_to_sheet(sheetData);
        ws['!cols'] = [
            { wch: 18 }, { wch: 20 }, { wch: 20 }, { wch: 35 }, { wch: 22 }, { wch: 22 }, { wch: 18 }, { wch: 12 }
        ];
        XLSX.utils.book_append_sheet(wb, ws, 'Pagamenti Report Fiscale');

        const today = new Date();
        const pad = n => String(n).padStart(2, '0');
        const dateFmt = `${pad(today.getDate())}-${pad(today.getMonth() + 1)}-${today.getFullYear()}`;
        XLSX.writeFile(wb, `TB_Report_Fiscale_${dateFmt}.xlsx`);

        if (typeof showToast === 'function') {
            showToast(`Report fiscale scaricato: ${rows.length} pagamenti fiscali`, 'success');
        }
    } catch (err) {
        console.error('[FiscalReport] Error:', err);
        if (typeof showToast === 'function') {
            showToast('Errore durante la generazione del report fiscale', 'error');
        }
    } finally {
        if (btn) { btn.disabled = false; btn.innerHTML = origLabel || '🧾 Scarica report fiscale'; }
    }
}

// ── End Fiscal Report ────────────────────────────────────────────────────────
