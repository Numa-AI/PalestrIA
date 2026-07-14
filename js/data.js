/**
 * data.js — Storage/data layer dell'app (pattern dual-layer: cache localStorage + sync Supabase).
 *
 * COSA FA: è il cuore dei dati lato client. Espone classi *Storage* statiche che leggono dalla
 * cache in memoria/localStorage e sincronizzano con Supabase (Postgres + RLS + RPC):
 *   - BookingStorage   — prenotazioni: cache + delta-sync con fingerprint, persistenza cross-pagina
 *                        (gym_bookings_cache_v2), prenotazione server-authoritative via RPC book_slot,
 *                        disponibilità via RPC get_availability_range (cache dedup 60s), capienza
 *                        effettiva (override → template settimana attivata → default slot_type).
 *   - UserStorage      — profili clienti dell'org (RPC get_all_profiles / get_all_profiles_basic).
 *   - WorkoutPlanStorage / WorkoutLogStorage — schede ed esercizi/log allenamento (join + TTL cache).
 *   - Storage di impostazioni (modalità pagamento, blocchi prenotazione, visibilità doc, template
 *     orari) org-scoped, più gli helper schedule (weekly templates + activated_weeks).
 *
 * COME FUNZIONA: tutte le scritture critiche passano da RPC SECURITY DEFINER (org-scoped) — la
 * capienza/anti-overbooking è decisa dal server, mai dal client. Le cache sono DISPLAY-ONLY e
 * identity-scoped; i marker dataLastCleared / data_cleared_at coordinano i clear cross-device.
 * Helper interni: _lsSet/_lsGetJSON (localStorage), _queryWithTimeout/_rpcWithTimeout (timeout),
 * _localDateStr (date locali), _resolveOrgSlug (org dal contesto multi-tenant).
 *
 * CONNESSIONI: usa il client di supabase-client.js; legge sessione/ruolo da auth.js; è consumato
 * da booking.js/calendar.js (cliente), prenotazioni.html, index.html e dai moduli admin-*.js
 * (admin-calendar, admin-clients, admin-payments, admin-analytics, admin-schede, ...). egress-debug.js
 * misura il peso delle query qui generate. Caricato in APP_SHELL (sw.js) con cache-busting ?v=.
 */
// Utility debounce: ritarda l'esecuzione finché non passa `delay` ms senza nuove chiamate.
function _debounce(fn, delay) {
    let timer;
    return function (...args) {
        clearTimeout(timer);
        timer = setTimeout(() => fn.apply(this, args), delay);
    };
}

// Restituisce la data locale corrente (o di un oggetto Date) come "YYYY-MM-DD".
// Usa il fuso locale del browser, non UTC — evita l'off-by-one dopo le 23:00 CET.
function _localDateStr(d = new Date()) {
    return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

// Parsa "HH:MM - HH:MM" in { startH, startM, endH, endM }.
// Restituisce null e logga un errore se il formato non è riconosciuto.
function _parseSlotTime(str) {
    if (!str || typeof str !== 'string') {
        console.error('[_parseSlotTime] Formato orario non valido:', str);
        return null;
    }
    const parts = str.split(' - ');
    if (parts.length !== 2) {
        console.error('[_parseSlotTime] Formato atteso "HH:MM - HH:MM":', str);
        return null;
    }
    const [sh, sm] = parts[0].trim().split(':').map(Number);
    const [eh, em] = parts[1].trim().split(':').map(Number);
    if ([sh, sm, eh, em].some(isNaN)) {
        console.error('[_parseSlotTime] Ore/minuti non numerici in:', str);
        return null;
    }
    return { startH: sh, startM: sm, endH: eh, endM: em };
}

// Salva in localStorage con gestione QuotaExceededError.
// Logga l'errore senza lanciare eccezioni — evita crash silenziosi su storage pieno.
function _lsSet(key, value) {
    try {
        localStorage.setItem(key, value);
        return true;
    } catch (e) {
        if (e instanceof DOMException && (e.name === 'QuotaExceededError' || e.code === 22)) {
            // Auto-guarigione: evicta gli snapshot rigenerabili e riprova UNA volta.
            // Il toast (chiave critica > cache) appare solo se anche il retry fallisce.
            _lsEvictSnapshots((value?.length || 0) || 1, key);
            try {
                localStorage.setItem(key, value);
                return true;
            } catch (e2) {
                console.error('[localStorage] QuotaExceededError anche dopo eviction:', key,
                    '—', Math.round((value?.length || 0) / 1024), 'KB');
                if (typeof showToast === 'function') showToast('⚠️ Memoria locale piena. Alcuni dati potrebbero non essere salvati.', 'error', 8000);
                return false;
            }
        }
        console.error('[localStorage] Errore setItem per chiave', key, ':', e);
        return false;
    }
}

// Legge e parsa JSON da localStorage con protezione errori.
function _lsGetJSON(key, fallback) {
    try {
        const raw = localStorage.getItem(key);
        return raw ? JSON.parse(raw) : fallback;
    } catch (e) {
        console.error('[localStorage] JSON.parse error per chiave', key, ':', e);
        return fallback;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Governo quota localStorage (~5MB/origine). Gli snapshot-cache (bookings, stats,
// profili, DB esercizi, schede, override) possono saturare la quota. Difesa a 3
// livelli, TUTTA e SOLO su cache rigenerabili da Supabase (mai settings, code
// pending, push, auth token): (1) budget globale con eviction largest-first;
// (2) auto-guarigione in _lsSet su QuotaExceededError; (3) housekeeping al boot.
// NB: il divoratore storico del gemello (credit_history) qui NON esiste (crediti
// rimossi §11) → questa è una difesa preventiva.
// ─────────────────────────────────────────────────────────────────────────────
const _LS_SNAPSHOT_PREFIXES = [
    'gym_bookings_cache_v2:',
    'gym_stats_cache_v1:',
    'gym_stats',                 // chiave legacy non più scritta — resta per l'eviction dei residui
    'gym_users_cache_v1',
    'workout_plans_cache_',
    'schede_exercises_db_v1',
    'scheduleOverrides_',
    '_orgSchedSnap_',
];
const _LS_OBSOLETE_PREFIXES = ['gym_bookings_cache_v1'];   // versioni superate → purga
const _LS_SNAPSHOT_BUDGET  = 2_000_000;   // char totali per gli snapshot (~4MB)
const _LS_SNAPSHOT_KEY_MAX = 900_000;     // char per singola chiave snapshot

function _lsSnapshotEntries() {
    const out = [];
    for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (!k) continue;
        if (_LS_SNAPSHOT_PREFIXES.some(p => k.startsWith(p))) {
            const v = localStorage.getItem(k);
            out.push({ key: k, size: v ? v.length : 0 });
        }
    }
    return out;
}

// Evicta gli snapshot più grossi (whitelist), saltando keepKey, finché non ha
// liberato needChars caratteri. Tocca SOLO le cache rigenerabili.
function _lsEvictSnapshots(needChars, keepKey) {
    if (!(needChars > 0)) return 0;
    const entries = _lsSnapshotEntries()
        .filter(e => e.key !== keepKey)
        .sort((a, b) => b.size - a.size);
    let freed = 0;
    for (const e of entries) {
        if (freed >= needChars) break;
        try { localStorage.removeItem(e.key); freed += e.size; console.log('[localStorage] evict snapshot', e.key, Math.round(e.size / 1024) + 'KB'); }
        catch (err) { /* noop */ }
    }
    return freed;
}

// Persiste uno snapshot cache: cap per-chiave + budget totale + retry post-eviction.
// NON mostra MAI il toast (è cache rigenerabile: se salta, il prossimo load rifà un fetch).
function _lsSetSnapshot(key, json) {
    if (typeof json !== 'string') { try { json = JSON.stringify(json); } catch (e) { return false; } }
    if (json.length > _LS_SNAPSHOT_KEY_MAX) {
        console.warn('[localStorage] snapshot troppo grande, salto persist:', key, Math.round(json.length / 1024) + 'KB');
        try { localStorage.removeItem(key); } catch (e) { /* noop */ }
        return false;
    }
    // Rientra nel budget globale prima di scrivere.
    const total = _lsSnapshotEntries().reduce((s, e) => s + (e.key !== key ? e.size : 0), 0);
    if (total + json.length > _LS_SNAPSHOT_BUDGET) {
        _lsEvictSnapshots((total + json.length) - _LS_SNAPSHOT_BUDGET, key);
    }
    try {
        localStorage.setItem(key, json);
        return true;
    } catch (e) {
        if (e instanceof DOMException && (e.name === 'QuotaExceededError' || e.code === 22)) {
            _lsEvictSnapshots(json.length, key);
            try { localStorage.setItem(key, json); return true; }
            catch (e2) { console.warn('[localStorage] snapshot non salvato dopo eviction:', key); return false; }
        }
        console.error('[localStorage] errore snapshot', key, e);
        return false;
    }
}

// Housekeeping al boot: purga chiavi obsolete + rientra nel budget → un device
// già "pieno" si auto-ripara al primo avvio della nuova versione.
(function _lsSnapshotHousekeeping() {
    try {
        const obsolete = [];
        for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i);
            if (k && _LS_OBSOLETE_PREFIXES.some(p => k.startsWith(p))) obsolete.push(k);
        }
        obsolete.forEach(k => { try { localStorage.removeItem(k); } catch (e) { /* noop */ } });
        const total = _lsSnapshotEntries().reduce((s, e) => s + e.size, 0);
        if (total > _LS_SNAPSHOT_BUDGET) _lsEvictSnapshots(total - _LS_SNAPSHOT_BUDGET, null);
    } catch (e) { /* noop */ }
})();

// Wrappa una promise RPC con un timeout esplicito.
// Se supera ms millisecondi, rifiuta con Error('rpc_timeout').
function _rpcWithTimeout(promise, ms = 12000) {
    let ac = null;
    let racedPromise = promise;
    try {
        if (promise && typeof promise.abortSignal === 'function') {
            ac = new AbortController();
            racedPromise = promise.abortSignal(ac.signal);
        }
    } catch (_) {}

    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            if (ac) {
                try { ac.abort(); } catch (_) {}
            }
            reject(new Error('rpc_timeout'));
        }, ms);
        Promise.resolve(racedPromise).then(
            (v) => { clearTimeout(timer); resolve(v); },
            (e) => { clearTimeout(timer); reject(e); }
        );
    });
}
function _queryWithTimeout(promise, ms = 12000) {
    return _rpcWithTimeout(promise, ms);
}

// Fetch paginato: supera il limite default PostgREST (~1000 righe per query)
// scaricando a batch di 1000 finché la tabella non esaurisce.
// Ritorna { data, error } identico a una query supabase-js → drop-in replacement.
//
// Usage:
//   const { data, error } = await fetchAllPaginated(() =>
//       supabaseClient.from('tabella').select('col1, col2').order('created_at'));
//
// Il queryBuilder è una CALLBACK che crea una query fresca ad ogni iterazione
// (il .range() muta la query, quindi serve una query nuova per ogni pagina).
async function fetchAllPaginated(queryBuilder, options = {}) {
    const { timeoutMs = 30000, maxRows = 500000 } = options;
    if (typeof queryBuilder !== 'function') {
        return { data: null, error: { message: 'fetchAllPaginated: queryBuilder must be a function' } };
    }
    const all = [];
    const BATCH = 1000;
    const MAX_PAGES = Math.max(1, Math.ceil(maxRows / BATCH));
    for (let page = 0; page < MAX_PAGES; page++) {
        const from = page * BATCH;
        const q = queryBuilder().range(from, from + BATCH - 1);
        const { data, error } = await _queryWithTimeout(q, timeoutMs);
        if (error) return { data: null, error };
        if (!data || data.length === 0) break;
        all.push(...data);
        if (data.length < BATCH) break; // ultima pagina
    }
    return { data: all, error: null };
}

// Mock data storage - In production, this would be a database
const SLOT_TYPES = {
    PERSONAL: 'personal-training',
    SMALL_GROUP: 'small-group',
    GROUP_CLASS: 'group-class',
    CLEANING: 'cleaning'
};

const SLOT_MAX_CAPACITY = {
    'personal-training': 5,
    'small-group': 5,
    'group-class': 0,
    'cleaning': 0
};

// @deprecated — listino hardcoded single-tenant. NON usare per nuovi prezzi:
// i prezzi reali arrivano da slot_types.default_price / get_org_price (server)
// e da OrgSettings lato client. Tenuto solo come fallback finché tutte le pagine
// non leggono i prezzi org-scoped.
const SLOT_PRICES = {
    'personal-training': 5,
    'small-group': 10,
    'group-class': 30,
    'cleaning': 0
};

// Prezzo effettivo di un booking: rispetta custom_price (override prezzo per booking),
// poi il prezzo org-scoped (OrgSettings: price.<slotType> o slot_types.default_price
// sincronizzati lato client), infine il fallback deprecato SLOT_PRICES.
// Usare SEMPRE questo helper al posto di SLOT_PRICES[b.slotType] quando si
// calcola il prezzo di uno specifico booking.
function getBookingPrice(booking) {
    if (!booking) return 0;
    // Un cambio del modello predefinito annulla le sole posizioni operative
    // ancora aperte. La prenotazione resta nello storico, ma non genera piu
    // saldo, incasso o previsione economica.
    if (booking.billingVoidedAt) return 0;
    if (booking.customPrice != null && !Number.isNaN(Number(booking.customPrice))) {
        return Number(booking.customPrice);
    }
    // Prezzo per-org (slot config / OrgSettings) con fallback al listino deprecato.
    // Ordine: 1) billing_client.prices (jsonb {slotTypeKey: prezzo}, listino cliente
    // autoritativo lato display), 2) price.<slotType> (legacy OrgSettings), 3) SLOT_PRICES.
    if (typeof OrgSettings !== 'undefined' && booking.slotType) {
        const prices = OrgSettings.get('billing_client.prices');
        if (prices && typeof prices === 'object') {
            const p = Number(prices[booking.slotType]);
            if (Number.isFinite(p)) return p;
        }
        const orgPrice = OrgSettings.getNumber(`price.${booking.slotType}`, NaN);
        if (Number.isFinite(orgPrice)) return orgPrice;
    }
    return SLOT_PRICES[booking.slotType] || 0;
}

// Email degli admin — esclusi dalle statistiche
const ADMIN_EMAILS = new Set([
    'demo@palestria.app',
    'andrea.pompili1997@gmail.com'
]);

const SLOT_NAMES = {
    'personal-training': 'Autonomia',
    'small-group': 'Lezione di Gruppo',
    'group-class': 'Slot prenotato',
    'cleaning': 'Pulizie'
};

// Time slots configuration — 80 min each, 05:20 → 21:20
const TIME_SLOTS = [
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

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG ORARI PER-ORG (runtime, dal DB). Quando popolate, queste strutture
// hanno la precedenza sulle costanti hardcoded SLOT_TYPES/SLOT_MAX_CAPACITY/
// SLOT_PRICES/SLOT_NAMES/TIME_SLOTS/DEFAULT_WEEKLY_SCHEDULE (tenute come fallback
// deprecato single-tenant). Caricate da loadOrgScheduleConfig() su pageload.
//   _ORG_SLOT_TYPES : { [key]: { id, key, label, color, defaultCapacity, defaultPrice, bookable, isActive, sortOrder } }
//   _ORG_TIME_SLOTS : [ 'HH:MM - HH:MM', ... ]  (ordinati per sort_order)
//   _ORG_TPL_WEEKLY : { [templateId]: { [weekday 0..6]: { [time]: { slotTypeId, slotTypeKey, capacity } } } }
//                     weekday: 0=Domenica .. 6=Sabato (come extract(dow))
//   _ORG_ACTIVE_WEEKS : { [mondayYMD 'YYYY-MM-DD']: templateId }  ← attivazione per-settimana
// Attivazione PER-SETTIMANA: ogni settimana concreta del calendario va attivata
// manualmente e punta a un template (vedi tabella activated_weeks + resolve_slot_config).
// La risoluzione "weekly" è quindi DATE-AWARE: dipende dalla settimana che contiene
// la data. Le settimane non attivate non hanno slot. (Prima: un solo template
// is_active replicato su tutte le settimane — _ORG_WEEKLY senza dimensione data.)
let _ORG_SLOT_TYPES = null;
let _ORG_TIME_SLOTS = null;
let _ORG_TPL_WEEKLY = null;
let _ORG_ACTIVE_WEEKS = null;

// Lunedì (YMD) della settimana che contiene la data 'YYYY-MM-DD' (fuso locale).
// Allineato a date_trunc('week') di Postgres (settimana ISO: lunedì→domenica).
function _mondayYMD(dateStr) {
    if (!dateStr || typeof dateStr !== 'string') return null;
    const [y, m, d] = dateStr.split('-').map(Number);
    if ([y, m, d].some(Number.isNaN)) return null;
    const dt = new Date(y, m - 1, d);
    const day = dt.getDay();                 // 0=Dom .. 6=Sab
    const diff = day === 0 ? -6 : 1 - day;   // → lunedì
    dt.setDate(dt.getDate() + diff);
    return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
}

// Mappa weekly { [weekday]: { [time]: {...} } } del template attivato per la
// settimana che contiene dateStr; null se la settimana non è attivata.
function _orgWeeklyForDate(dateStr) {
    _hydrateOrgScheduleFromCache();
    if (!_ORG_ACTIVE_WEEKS || !_ORG_TPL_WEEKLY) return null;
    const mon = _mondayYMD(dateStr);
    if (!mon) return null;
    const tid = _ORG_ACTIVE_WEEKS[mon];
    if (!tid) return null;
    return _ORG_TPL_WEEKLY[tid] || null;
}

// true se la config orari org è stata caricata dal DB (almeno gli slot_types).
function _hasOrgScheduleConfig() {
    return _ORG_SLOT_TYPES && Object.keys(_ORG_SLOT_TYPES).length > 0;
}

// orgId per cui abbiamo già tentato l'idratazione da cache (evita letture ripetute).
let _orgSchedHydratedFor = null;

// Idrata _ORG_* dallo snapshot localStorage della org CORRENTE (keyed per orgId →
// no bleed cross-tenant) se non già caricati dal DB. Sincrono, una sola volta per
// orgId. Elimina il flash degli slot legacy (05:20) al refresh: i veri orari per-org
// sono disponibili SUBITO mentre loadOrgScheduleConfig() fa il round-trip al DB, che
// poi li aggiorna. Se orgId non è ancora noto (auth async) esce senza marcare il flag.
function _hydrateOrgScheduleFromCache() {
    // orgId: dal claim auth se già noto, altrimenti dal puntatore stabile `_lastOrgId`
    // (scritto al precedente caricamento). Senza questo fallback, al primo paint dopo un
    // refresh l'auth è ancora async → orgId null → niente idratazione → si vedeva il
    // DEFAULT legacy (lo schema del gestionale originario) per un istante, ad ogni refresh.
    let orgId = (typeof window !== 'undefined' && window._orgId) ? window._orgId : null;
    if (!orgId) { try { orgId = localStorage.getItem('_lastOrgId') || null; } catch (_) {} }
    if (!orgId || _orgSchedHydratedFor === orgId) return;
    _orgSchedHydratedFor = orgId;
    try {
        const raw = localStorage.getItem('_orgSchedSnap_' + orgId);
        if (!raw) return;
        const snap = JSON.parse(raw);
        if (!snap || typeof snap !== 'object') return;
        if (!_ORG_SLOT_TYPES && snap.slotTypes && Object.keys(snap.slotTypes).length) _ORG_SLOT_TYPES = snap.slotTypes;
        if (!_ORG_TIME_SLOTS && Array.isArray(snap.timeSlots) && snap.timeSlots.length) _ORG_TIME_SLOTS = snap.timeSlots;
        if (!_ORG_TPL_WEEKLY && snap.tplWeekly && Object.keys(snap.tplWeekly).length) _ORG_TPL_WEEKLY = snap.tplWeekly;
        if (!_ORG_ACTIVE_WEEKS && snap.activeWeeks && Object.keys(snap.activeWeeks).length) _ORG_ACTIVE_WEEKS = snap.activeWeeks;
    } catch (_) {}
}

// Salva lo snapshot della config orari per-org (chiamato dopo loadOrgScheduleConfig).
function _persistOrgScheduleSnapshot(orgId) {
    if (!orgId) return;
    if (!_ORG_SLOT_TYPES && !_ORG_TIME_SLOTS && !_ORG_TPL_WEEKLY && !_ORG_ACTIVE_WEEKS) return;
    try {
        _lsSetSnapshot('_orgSchedSnap_' + orgId, JSON.stringify({
            slotTypes: _ORG_SLOT_TYPES, timeSlots: _ORG_TIME_SLOTS,
            tplWeekly: _ORG_TPL_WEEKLY, activeWeeks: _ORG_ACTIVE_WEEKS,
        }));
        localStorage.setItem('_lastOrgId', orgId); // puntatore stabile per l'idratazione sincrona al refresh
    } catch (_) {}
}

// True se questo device ha un contesto org (trainer loggato, org già nota in precedenza,
// o sessione Supabase in cache): in tal caso lo schema orario reale arriva da
// loadOrgScheduleConfig() e il DEFAULT legacy NON va mostrato, o si vedrebbe per un
// istante il calendario di un altro studio. Per gli anonimi puri (nessun contesto org)
// resta il fallback storico. Letture localStorage sincrone, difensive.
function _hasOrgContext() {
    try {
        if (typeof window !== 'undefined' && window._orgId) return true;
        if (localStorage.getItem('_lastOrgId')) return true;
        for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i);
            if (k && /^sb-.*-auth-token$/.test(k)) return true; // sessione in cache → utente loggato
        }
    } catch (_) {}
    return false;
}

// Indice JS getDay() → nome giorno italiano usato dalle costanti legacy.
const _WEEKDAY_NAMES_IT = ['Domenica', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato'];

// Risolve l'id slot_type (uuid) dalla key per la org corrente. null se sconosciuto.
function _orgSlotTypeId(key) {
    if (!_ORG_SLOT_TYPES) return null;
    const st = _ORG_SLOT_TYPES[key];
    return st ? st.id : null;
}

// Carica la config orari della org corrente dal DB e popola le strutture runtime.
// Fonti: slot_types, time_slots_config (ordinati per sort_order) e il
// weekly_schedule_template attivo + i suoi slot. RLS limita alla propria org;
// per i client anonimi (nessun JWT) le tabelle non sono leggibili → si resta sui
// fallback hardcoded e la disponibilità arriva comunque dalle RPC pubbliche.
async function loadOrgScheduleConfig() {
    if (typeof supabaseClient === 'undefined') return;
    const orgId = (typeof window !== 'undefined') ? window._orgId : null;
    _hydrateOrgScheduleFromCache(); // idrata SUBITO dalla cache (no flash slot legacy), poi il DB aggiorna
    try {
        const [stRes, tsRes, tplRes] = await Promise.allSettled([
            _queryWithTimeout(
                (orgId
                    ? supabaseClient.from('slot_types').select('id, key, label, color, default_capacity, default_price, bookable, is_active, sort_order').eq('org_id', orgId)
                    : supabaseClient.from('slot_types').select('id, key, label, color, default_capacity, default_price, bookable, is_active, sort_order')
                ).order('sort_order')
            ),
            _queryWithTimeout(
                (orgId
                    ? supabaseClient.from('time_slots_config').select('start_time, end_time, label, sort_order, is_active').eq('org_id', orgId)
                    : supabaseClient.from('time_slots_config').select('start_time, end_time, label, sort_order, is_active')
                ).order('sort_order')
            ),
            _queryWithTimeout(
                // Settimane ATTIVATE della org (mappa mondayYMD → templateId). Solo
                // per gli autenticati: gli anonimi non hanno policy di lettura e
                // ricevono la disponibilità dalle RPC pubbliche.
                orgId
                    ? supabaseClient.from('activated_weeks').select('week_start, template_id').eq('org_id', orgId)
                    : supabaseClient.from('activated_weeks').select('week_start, template_id').limit(0)
            ),
        ]);

        // 1) slot_types → mappa per key (solo attivi)
        if (stRes.status === 'fulfilled' && !stRes.value.error && Array.isArray(stRes.value.data)) {
            const map = {};
            for (const r of stRes.value.data) {
                if (r.is_active === false) continue;
                map[r.key] = {
                    id:              r.id,
                    key:             r.key,
                    label:           r.label,
                    color:           r.color || '#8B5CF6',
                    defaultCapacity: r.default_capacity ?? 0,
                    defaultPrice:    r.default_price != null ? Number(r.default_price) : 0,
                    bookable:        r.bookable !== false,
                    isActive:        r.is_active !== false,
                    sortOrder:       r.sort_order ?? 0,
                };
            }
            if (Object.keys(map).length > 0) _ORG_SLOT_TYPES = map;
        }

        // 2) time_slots_config → array di etichette 'HH:MM - HH:MM' (formato come bookings.time)
        if (tsRes.status === 'fulfilled' && !tsRes.value.error && Array.isArray(tsRes.value.data)) {
            const labels = [];
            for (const r of tsRes.value.data) {
                if (r.is_active === false) continue;
                const lbl = _formatTimeSlotLabel(r.start_time, r.end_time);
                if (lbl) labels.push(lbl);
            }
            if (labels.length > 0) _ORG_TIME_SLOTS = labels;
        }

        // 3) attivazione per-settimana → _ORG_ACTIVE_WEEKS[mondayYMD] = templateId
        if (tplRes.status === 'fulfilled' && !tplRes.value.error && Array.isArray(tplRes.value.data)) {
            const aw = {};
            for (const r of tplRes.value.data) {
                if (!r.week_start || !r.template_id) continue;
                // week_start arriva come 'YYYY-MM-DD' (tipo date) → usalo come chiave.
                aw[String(r.week_start).slice(0, 10)] = r.template_id;
            }
            _ORG_ACTIVE_WEEKS = aw;
        }

        // 4) slot di TUTTI i template della org → _ORG_TPL_WEEKLY[templateId][weekday][time]
        //    (servono i template referenziati dalle settimane attivate; carichiamo
        //     tutto in una query org-scoped, è poca roba per studio).
        if (orgId) {
            const { data: slotsData, error: slotsErr } = await _queryWithTimeout(
                supabaseClient.from('weekly_template_slots')
                    .select('template_id, weekday, capacity, slot_type_id, time_slots_config(start_time, end_time), slot_types(key, default_capacity)')
                    .eq('org_id', orgId)
            );
            if (!slotsErr && Array.isArray(slotsData)) {
                const tplWeekly = {};
                for (const r of slotsData) {
                    const tsc = r.time_slots_config;
                    const stp = r.slot_types;
                    if (!tsc || !stp) continue;
                    const time = _formatTimeSlotLabel(tsc.start_time, tsc.end_time);
                    if (!time) continue;
                    const tid = r.template_id;
                    const wd = Number(r.weekday);
                    if (!tplWeekly[tid]) tplWeekly[tid] = {};
                    if (!tplWeekly[tid][wd]) tplWeekly[tid][wd] = {};
                    tplWeekly[tid][wd][time] = {
                        slotTypeId:  r.slot_type_id,
                        slotTypeKey: stp.key,
                        capacity:    r.capacity != null ? r.capacity : (stp.default_capacity ?? 0),
                    };
                }
                _ORG_TPL_WEEKLY = tplWeekly;
            }
        }

        console.log(`[Supabase] loadOrgScheduleConfig: ${_ORG_SLOT_TYPES ? Object.keys(_ORG_SLOT_TYPES).length : 0} slot_types, ${_ORG_TIME_SLOTS ? _ORG_TIME_SLOTS.length : 0} fasce, settimane attivate=${_ORG_ACTIVE_WEEKS ? Object.keys(_ORG_ACTIVE_WEEKS).length : 0}`);
        _persistOrgScheduleSnapshot(orgId); // aggiorna la cache per il prossimo refresh (no flash)
    } catch (e) {
        console.warn('[Supabase] loadOrgScheduleConfig exception (uso fallback hardcoded):', e);
    }
}

// Converte due valori time Postgres ('HH:MM[:SS]') nell'etichetta 'HH:MM - HH:MM'
// (stesso formato di bookings.time e delle costanti TIME_SLOTS).
function _formatTimeSlotLabel(startTime, endTime) {
    const _hhmm = (t) => {
        if (!t || typeof t !== 'string') return null;
        const parts = t.split(':');
        if (parts.length < 2) return null;
        return `${parts[0].padStart(2, '0')}:${parts[1].padStart(2, '0')}`;
    };
    const s = _hhmm(startTime);
    const e = _hhmm(endTime);
    if (!s || !e) return null;
    return `${s} - ${e}`;
}

// Etichetta (nome) di un tipo slot: preferisce la config org, fallback al
// listino deprecato SLOT_NAMES.
function getSlotName(slotType) {
    if (_ORG_SLOT_TYPES && _ORG_SLOT_TYPES[slotType]) return _ORG_SLOT_TYPES[slotType].label;
    return SLOT_NAMES[slotType] || slotType;
}

// Colore (hex) di un tipo slot — fonte di verità per pip/badge nel calendario.
// Preferisce slot_types.color per-org (_ORG_SLOT_TYPES); fallback ai colori
// storici delle chiavi single-tenant e infine al viola di default del brand.
const _LEGACY_SLOT_COLORS = {
    'personal-training': '#16a34a',
    'small-group':       '#f59e0b',
    'group-class':       '#ef4444',
    'cleaning':          '#64748b',
};
function getSlotColor(slotType) {
    _hydrateOrgScheduleFromCache();
    if (_ORG_SLOT_TYPES && _ORG_SLOT_TYPES[slotType] && _ORG_SLOT_TYPES[slotType].color) {
        return _ORG_SLOT_TYPES[slotType].color;
    }
    return _LEGACY_SLOT_COLORS[slotType] || '#8B5CF6';
}

// Elenco fasce orarie attive per la org (etichette 'HH:MM - HH:MM').
// Preferisce _ORG_TIME_SLOTS (dal DB), fallback alle costanti TIME_SLOTS.
function getTimeSlots() {
    _hydrateOrgScheduleFromCache();
    return (_ORG_TIME_SLOTS && _ORG_TIME_SLOTS.length) ? _ORG_TIME_SLOTS.slice() : TIME_SLOTS.slice();
}

// Bump this whenever DEFAULT_WEEKLY_SCHEDULE changes — forces a reset for all clients
const SCHEDULE_VERSION = 'v9';

// Default weekly schedule — all 12 slots assigned every day
// 🟢 GREEN = personal-training | 🟡 YELLOW = small-group | 🔴 RED = group-class
const DEFAULT_WEEKLY_SCHEDULE = {
    'Lunedì': [
        { time: '05:20 - 06:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '06:40 - 08:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '08:00 - 09:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '09:20 - 10:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '10:40 - 12:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '12:00 - 13:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '13:20 - 14:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '14:40 - 16:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '16:00 - 17:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '17:20 - 18:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '18:40 - 20:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '20:00 - 21:20', type: SLOT_TYPES.PERSONAL }    // 🟢
    ],
    'Martedì': [
        { time: '05:20 - 06:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '06:40 - 08:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '08:00 - 09:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '09:20 - 10:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '10:40 - 12:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '12:00 - 13:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '13:20 - 14:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '14:40 - 16:00', type: SLOT_TYPES.GROUP_CLASS },// 🔴
        { time: '16:00 - 17:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '17:20 - 18:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '18:40 - 20:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '20:00 - 21:20', type: SLOT_TYPES.PERSONAL }    // 🟢
    ],
    'Mercoledì': [
        { time: '05:20 - 06:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '06:40 - 08:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '08:00 - 09:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '09:20 - 10:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '10:40 - 12:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '12:00 - 13:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '13:20 - 14:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '14:40 - 16:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '16:00 - 17:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '17:20 - 18:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '18:40 - 20:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '20:00 - 21:20', type: SLOT_TYPES.PERSONAL }    // 🟢
    ],
    'Giovedì': [
        { time: '05:20 - 06:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '06:40 - 08:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '08:00 - 09:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '09:20 - 10:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '10:40 - 12:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '12:00 - 13:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '13:20 - 14:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '14:40 - 16:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '16:00 - 17:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '17:20 - 18:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '18:40 - 20:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '20:00 - 21:20', type: SLOT_TYPES.PERSONAL }    // 🟢
    ],
    'Venerdì': [
        { time: '05:20 - 06:40', type: SLOT_TYPES.GROUP_CLASS },// 🔴
        { time: '06:40 - 08:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '08:00 - 09:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '09:20 - 10:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '10:40 - 12:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '12:00 - 13:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '13:20 - 14:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '14:40 - 16:00', type: SLOT_TYPES.GROUP_CLASS },// 🔴
        { time: '16:00 - 17:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '17:20 - 18:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '18:40 - 20:00', type: SLOT_TYPES.SMALL_GROUP },  // 🟡
        { time: '20:00 - 21:20', type: SLOT_TYPES.PERSONAL }    // 🟢
    ],
    'Sabato': [
        { time: '05:20 - 06:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '06:40 - 08:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '08:00 - 09:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '09:20 - 10:40', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '10:40 - 12:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '12:00 - 13:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '13:20 - 14:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '14:40 - 16:00', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '16:00 - 17:20', type: SLOT_TYPES.SMALL_GROUP },// 🟡
        { time: '17:20 - 18:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '18:40 - 20:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '20:00 - 21:20', type: SLOT_TYPES.PERSONAL }    // 🟢
    ],
    'Domenica': [
        { time: '05:20 - 06:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '06:40 - 08:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '08:00 - 09:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '09:20 - 10:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '10:40 - 12:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '12:00 - 13:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '13:20 - 14:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '14:40 - 16:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '16:00 - 17:20', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '17:20 - 18:40', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '18:40 - 20:00', type: SLOT_TYPES.PERSONAL },   // 🟢
        { time: '20:00 - 21:20', type: SLOT_TYPES.PERSONAL }    // 🟢
    ]
};

// Costruisce DEFAULT_WEEKLY_SCHEDULE-like ({ 'Lunedì': [{time,type}], ... })
// dal template ATTIVATO per la settimana che contiene dateStr. DATE-AWARE: senza
// data (o se la settimana non è attivata) ritorna null.
function _weeklyScheduleFromOrg(dateStr) {
    if (!dateStr) return null;            // l'attivazione è per-settimana: serve la data
    const weekly = _orgWeeklyForDate(dateStr);
    if (!weekly || Object.keys(weekly).length === 0) return null;
    const result = {};
    for (let wd = 0; wd < 7; wd++) {
        const dayName = _WEEKDAY_NAMES_IT[wd];
        const slotsByTime = weekly[wd] || {};
        const slots = Object.keys(slotsByTime).map(time => ({
            time,
            type: slotsByTime[time].slotTypeKey,
        }));
        // Ordina per orario di inizio (gli oggetti non garantiscono l'ordine)
        slots.sort((a, b) => a.time.localeCompare(b.time));
        result[dayName] = slots;
    }
    return result;
}

// Schedule settimanale ({ 'Lunedì': [{time,type}], ... }) per la settimana che
// contiene `dateStr`. DATE-AWARE per via dell'attivazione per-settimana: passa
// SEMPRE la data (es. getWeeklySchedule('2026-06-23')). Senza data si ricade sui
// template localStorage/default (solo legacy/anonimo): in contesto org una data
// è obbligatoria per sapere quale settimana (e se è attivata) sto guardando.
function getWeeklySchedule(dateStr) {
    // Config org dal DB (settimana attivata): ha la precedenza sui template localStorage.
    const orgWeekly = _weeklyScheduleFromOrg(dateStr);
    if (orgWeekly) return orgWeekly;
    // Contesto org ma settimana non attivata (o config non pronta) → griglia vuota:
    // niente fallback al DEFAULT legacy né ai template localStorage, che mostrerebbero
    // slot di "un altro studio". Tutto il codice sotto gira SOLO senza contesto org.
    if (_hasOrgContext()) return {};

    // Try to load from WeekTemplateStorage (active template)
    const templatesRaw = localStorage.getItem('gym_week_templates');
    if (templatesRaw) {
        try {
            const templates = JSON.parse(templatesRaw);
            const activeId = parseInt(localStorage.getItem('gym_active_week_template') || '1', 10);
            const active = templates.find(t => t.id === activeId);
            if (active && active.schedule) {
                _lsSet('weeklyScheduleTemplate', JSON.stringify(active.schedule));
                return active.schedule;
            }
        } catch { /* corrupted — fall through */ }
    }

    // Fallback: legacy localStorage or default
    const saved = localStorage.getItem('weeklyScheduleTemplate');
    const savedVersion = localStorage.getItem('scheduleVersion');
    if (saved && savedVersion === SCHEDULE_VERSION) {
        try {
            const parsed = JSON.parse(saved);
            const storedTimes = Object.values(parsed).flat().map(s => s.time);
            const isCurrentFormat = storedTimes.length === 0 || storedTimes.every(t => TIME_SLOTS.includes(t));
            if (isCurrentFormat) return parsed;
        } catch { /* corrupted — will reset below */ }
    }
    // Legacy / single-tenant senza contesto org: fallback storico (reset versione/formato).
    localStorage.removeItem(_schedOverridesLsKey());
    _lsSet('weeklyScheduleTemplate', JSON.stringify(DEFAULT_WEEKLY_SCHEDULE));
    _lsSet('scheduleVersion', SCHEDULE_VERSION);
    return DEFAULT_WEEKLY_SCHEDULE;
}

// Risolve lo slug org per le RPC pubbliche (book_slot, availability, attendees).
// Fonti in ordine: window._orgSlug (settato da auth.js), ?org=<slug> (link
// d'invito, PRIORITÀ), sottodominio <slug>.dominio SOLO su domini tenant reali.
// ⚠️ Su host di piattaforma (github.io / localhost / IP) il primo label del
// dominio NON è uno studio (es. numa-ai.github.io → "numa-ai"): va escluso,
// altrimenti l'org anonima si risolverebbe sempre sbagliata e il ?org= verrebbe
// ignorato. Ritorna null se non risolvibile (RPC fa fallback su current_org_id()).
function _resolveOrgSlug() {
    if (typeof window !== 'undefined' && window._orgSlug) return window._orgSlug;
    try {
        const qs = new URLSearchParams(location.search).get('org');
        if (qs) return qs.trim().toLowerCase();
        const host = location.hostname;
        const isPlatformHost = host.endsWith('github.io')
            || host === 'localhost' || host === '127.0.0.1'
            || /^\d+\.\d+\.\d+\.\d+$/.test(host);
        if (!isPlatformHost) {
            const parts = host.split('.');
            if (parts.length > 2 && !['www', 'app'].includes(parts[0])) return parts[0];
        }
    } catch (_) {}
    return null;
}

// Chiave localStorage degli scheduleOverrides, namespaced per org. Senza namespace,
// gli override (che includono PII dei clienti) di un tenant resterebbero visibili e
// RISCRIVIBILI da un altro tenant sullo stesso device (logout A → login B): leak
// cross-tenant + write-back di dati di A nel DB di B. 'anon' per i client pubblici.
function _schedOverridesLsKey() {
    const oid = (typeof window !== 'undefined' && window._orgId) ? window._orgId : 'anon';
    return `scheduleOverrides_${oid}`;
}

// Normalizzazione legacy al boot: senza contesto org ripristina/normalizza il
// template in localStorage (side-effect). Il valore di ritorno non serve: i
// consumatori chiamano direttamente getWeeklySchedule(dateStr).
getWeeklySchedule();

// Storage functions
class BookingStorage {
    static _cache = [];
    static _syncInFlightByKey = {};
    static _adminFetchInFlightByKey = {};
    static _adminFetchCacheByKey = {};
    static _ADMIN_FETCH_CACHE_TTL_MS = 60000;

    static getAllBookings() {
        return this._cache;
    }

    // Fetches bookings from Supabase and updates the localStorage cache.
    // - Admin: SELECT * (sees all via is_admin() RLS)
    // - Authenticated user: SELECT own + RPC availability for others' slots (synthetic)
    // - Anon: RPC availability only (no personal data)
    static _syncRetryTimer = null;

    // Sync incrementale (admin full-list): fingerprint "<count>|<max updated_at>" della
    // finestra prenotazioni → salta il full-fetch quando nulla è cambiato (wake veloce).
    // Reconcile periodico come safety net per delete e per il raro insert+delete che non
    // muove né count né max. NON tocca il path utente/anon (lì domina la disponibilità).
    static _bkFingerprint = null;
    static _bkLastFullFetch = 0;
    static _BK_RECONCILE_MS = 5 * 60 * 1000;
    static _syncFailCount = 0; // #10: toast "errore connessione" solo dopo 3 fallimenti consecutivi

    // ── Delta-sync (admin full-list): quando il fingerprint cambia, invece di riscaricare
    //    l'intera finestra (60+90 gg) scarica SOLO le righe con updated_at >= cursore.
    //    Il count del fingerprint regala la rilevazione degli hard-delete: se scende → FULL.
    static _DELTA_OVERLAP_MS = 5000; // overlap finestra anti clock-skew (merge idempotente per _sbId)

    // ── Persistenza cache su localStorage (cross-pagina) ───────────────────────────
    // L'app è multi-pagina (MPA): ad OGNI navigazione la _cache in memoria riparte vuota, quindi
    // syncFromSupabase farebbe un FULL re-fetch (admin: ~150 giorni di booking) ad ogni pagina
    // caricata → grossa voce di egress. Persistendo la cache + i watermark del fingerprint, la
    // navigazione successiva fa uno SKIP (fingerprint invariato) o un DELTA (solo le righe con
    // updated_at >= cursore) invece di un full. Sicuro: la cache è DISPLAY-ONLY — capienza e
    // prenotazioni restano server-authoritative (book_slot con advisory lock); i pagamenti
    // vengono dal ledger `payments`. Identity-scoped per non mischiare dati di utenti diversi.
    // Snapshot oltre il TTL → non idratato (ricade nel full da cache vuota, come oggi).
    // v2: la FULL ora carica anche i debiti vecchi (lezioni passate non pagate fuori finestra) →
    // gli snapshot v1 (solo finestra 60gg) sono incompleti; bumpare la chiave li invalida così il
    // primo load post-deploy fa un FULL che ripesca subito i debiti vecchi (no attesa del reconcile).
    static _PERSIST_KEY = 'gym_bookings_cache_v2';
    static _PERSIST_MAX_ROWS = 8000;          // oltre, salta il persist (evita quota localStorage)
    static _PERSIST_TTL_MS = 15 * 60 * 1000;  // età max snapshot idratabile (oltre → full da vuoto)

    // ── Dedup get_availability_range (utenti/anon) ─────────────────────────────────
    // L'aggregato di disponibilità viene ri-chiesto ad ogni syncFromSupabase (load, resume,
    // visibility, wake-from-idle): su un burst ravvicinato è lo stesso identico payload.
    // Cache in-memory 60s → un solo fetch per finestra+org. Invalidata su ogni cambio capienza
    // (prenotazione/annullo/conversione) così la disponibilità torna fresca subito dopo un'azione.
    static _availCache = { ts: 0, key: '', data: null };
    static _AVAIL_TTL_MS = 60000; // 60s

    // Spezza il fingerprint "<count>|<max updated_at>" nei suoi componenti.
    static _parseFingerprint(fp) {
        if (!fp || typeof fp !== 'string') return null;
        const i = fp.indexOf('|');
        if (i < 0) return null;
        const countRaw = fp.slice(0, i);
        const count = countRaw === '?' ? null : parseInt(countRaw, 10);
        return { count: Number.isNaN(count) ? null : count, maxUpd: fp.slice(i + 1) };
    }

    // Forza un FULL-fetch al prossimo sync (azzera cursore + reconcile). Chiamato dopo gli
    // hard-delete (admin_delete_booking/client_data/clear_all_data) per reattività sul client.
    static invalidateDelta() {
        this._bkFingerprint = null;
        this._bkLastFullFetch = 0;
        this._clearPersistedCache(); // lo snapshot conteneva il count pre-delete → scartalo
    }

    // ── Dedup get_availability_range: una sola fetch per finestra+org entro _AVAIL_TTL_MS ──
    // Multi-tenant: la chiave include lo slug org (firma get_availability_range(p_org_slug,...)).
    static async _fetchAvailabilityCached(fromStr, toStr) {
        const slug = (typeof _resolveOrgSlug === 'function') ? _resolveOrgSlug() : '';
        const key = `${slug}|${fromStr}|${toStr}`;
        if (this._availCache.data && this._availCache.key === key
            && Date.now() - this._availCache.ts < this._AVAIL_TTL_MS) {
            return { data: this._availCache.data, error: null };
        }
        const res = await _rpcWithTimeout(
            supabaseClient.rpc('get_availability_range', { p_org_slug: slug, p_from: fromStr, p_to: toStr })
        ).catch(e => ({ data: null, error: e }));
        if (res && !res.error && res.data) {
            this._availCache = { ts: Date.now(), key, data: res.data };
        }
        return res || { data: null, error: new Error('rpc annullata') };
    }

    static _invalidateAvailabilityCache() { this._availCache = { ts: 0, key: '', data: null }; }

    // ── Persistenza cache bookings su localStorage (cross-pagina) ──────────────────
    static _persistKeyFor(syncKey, identity) {
        return `${this._PERSIST_KEY}:${syncKey}:${identity}`;
    }

    // Salva le sole righe REALI (con _sbId, non sintetiche/pending) + i watermark del fingerprint.
    static _persistCache(syncKey, identity) {
        if (!identity) return; // anon: nessun dato personale da persistere
        try {
            const rows = this._cache.filter(b => b._sbId && !b.id?.startsWith('_avail_'));
            if (rows.length > this._PERSIST_MAX_ROWS) return;
            // _lsSetSnapshot: cap per-chiave + budget + eviction, mai toast (su quota
            // fallisce in silenzio → full al prossimo load).
            _lsSetSnapshot(this._persistKeyFor(syncKey, identity), JSON.stringify({
                savedAt:     Date.now(),
                clearedAt:   localStorage.getItem('dataLastCleared') || '0',
                fingerprint: this._bkFingerprint || null,
                lastFull:    this._bkLastFullFetch || 0,
                rows,
            }));
        } catch (e) { /* quota/serialize: ignora — al peggio il prossimo sync sarà full */ }
    }

    // Idrata la cache in memoria dallo snapshot localStorage, SOLO al primo sync di pagina.
    // Ripristina anche i watermark del fingerprint: snapshot fresco → il sync sotto diventa
    // skip/delta (cross-pagina); snapshot vecchio (>TTL) → ignorato (full da cache vuota).
    static _hydrateCache(syncKey, identity) {
        if (!identity) return false;
        if (this._cache.some(b => b._sbId)) return false; // cache già popolata di righe reali
        try {
            const snap = _lsGetJSON(this._persistKeyFor(syncKey, identity), null);
            if (!snap || !Array.isArray(snap.rows) || snap.rows.length === 0) return false;
            // Scartato se predate un clear globale (dati pre-cancellazione) o se troppo vecchio.
            if ((localStorage.getItem('dataLastCleared') || '0') !== (snap.clearedAt || '0')) return false;
            if (!snap.savedAt || (Date.now() - snap.savedAt) > this._PERSIST_TTL_MS) return false;
            const others = this._cache.filter(b => b.id?.startsWith('_avail_') || !b._sbId);
            this._cache = [...snap.rows, ...others];
            this._bkFingerprint   = snap.fingerprint || null;
            this._bkLastFullFetch = snap.lastFull || 0;
            console.log(`[Supabase] bookings cache idratata da localStorage: ${snap.rows.length} righe (${Math.round((Date.now() - (snap.savedAt || 0)) / 1000)}s fa)`);
            return true;
        } catch (e) { return false; }
    }

    static _clearPersistedCache() {
        try {
            // Purga sia la cache bookings persistita sia lo snapshot stats admin
            // (gym_stats_cache_v1:*, admin-analytics.js) → i dati economici non
            // sopravvivono a logout / clear globale sul dispositivo.
            const prefixes = [this._PERSIST_KEY + ':', 'gym_stats_cache_v1:', 'gym_users_cache_v1'];
            for (let i = localStorage.length - 1; i >= 0; i--) {
                const k = localStorage.key(i);
                if (k && prefixes.some(p => k.startsWith(p))) localStorage.removeItem(k);
            }
        } catch (e) { /* ignore */ }
    }

    // Fingerprint cheap: una query (count exact + riga col max updated_at). null su errore.
    // Il filtro DEVE coincidere con quello della FULL (finestra [past,future] OPPURE qualsiasi
    // lezione passata non pagata e non annullata), altrimenti count/maxUpd non rispecchiano ciò
    // che la cache contiene: un debito vecchio appena SALDATO esce dall'insieme → count scende →
    // FULL reconcile (lo rimuove); un debito vecchio EDITATO bumpa maxUpd → DELTA lo ripesca.
    static async _bookingsFingerprint(pastStr, futureStr) {
        try {
            const { data, count, error } = await _queryWithTimeout(
                supabaseClient.from('bookings')
                    .select('updated_at', { count: 'exact' })
                    .lte('date', futureStr)
                    .or(`date.gte.${pastStr},and(paid.is.false,status.neq.cancelled)`)
                    .order('updated_at', { ascending: false, nullsFirst: false })
                    .limit(1),
                10000
            );
            if (error) return null;
            const maxUpd = (data && data[0] && data[0].updated_at) || '';
            return `${count == null ? '?' : count}|${maxUpd}`;
        } catch (_) { return null; }
    }

    // forceFull: bypassa il delta/skip e forza un FULL sync (finestra operativa completa +
    // debiti vecchi). Usato dal Registro (vista di audit) che deve avere dati completi, non la
    // cache delta ottimizzata per l'egress. Se c'è già un sync in volo per questa chiave riusa
    // quello (anche se delta) — accettabile: il forceFull serve all'apertura del tab (throttlata)
    // e si ripete al prossimo ingresso.
    static async syncFromSupabase({ ownOnly = false, forceFull = false } = {}) {
        if (typeof supabaseClient === 'undefined') return;
        const syncKey = ownOnly ? 'own' : 'all';
        if (this._syncInFlightByKey[syncKey]) return this._syncInFlightByKey[syncKey];
        this._syncInFlightByKey[syncKey] = this._syncFromSupabaseImpl({ ownOnly, forceFull });
        try { return await this._syncInFlightByKey[syncKey]; }
        finally { delete this._syncInFlightByKey[syncKey]; }
    }

    static async _syncFromSupabaseImpl({ ownOnly = false, forceFull = false } = {}) {
        try {
            const user    = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
            const isAdmin = sessionStorage.getItem('adminAuth') === 'true';
            const syncKey = ownOnly ? 'own' : 'all';
            // Identity per lo scoping della cache persistita cross-pagina (anon → null = no persist)
            const _identity = isAdmin ? 'admin' : (user?.id || null);
            // Snapshot anti-race: se la cache viene svuotata (logout/clear) DURANTE la sync,
            // non ricommittare dati vecchi sopra una cache appena pulita (controllo prima del commit).
            const clearedAtStart = localStorage.getItem('dataLastCleared') || '0';

            // Date range for availability RPC (~3 months forward)
            const todayStr = _localDateStr();
            const endDate  = new Date(); endDate.setDate(endDate.getDate() + 90);
            const endStr   = _localDateStr(endDate);

            if (!user && !isAdmin) {
                // ── ANON: solo disponibilità aggregata, nessun dato personale ──────────
                // get_availability_range(p_org_slug, p_from, p_to) via cache dedup 60s
                const { data: availData, error } = await this._fetchAvailabilityCached(todayStr, endStr);
                if (error) {
                    // #10: l'errore qui è quasi sempre transitorio (es. blip auth dopo il logout
                    // → navigazione a index.html, lock navigator.locks ancora in assestamento).
                    // NON mostrare il toast subito: rilancia e lascia gestire al catch esterno
                    // (contatore + retry silenzioso a 5s, toast solo al 3° fallimento consecutivo),
                    // identico al path admin/utente. Evita il falso allarme dopo un logout normale.
                    throw new Error('get_availability_range error: ' + (error.message || error));
                }
                // Capienza/posti residui server-authoritative per il rendering
                this._indexAvailability(availData);
                const synth = this._buildSyntheticBookings(availData, {});
                // Mantieni booking in cache non-sintetici (pending insert non ancora su Supabase)
                const local = this._cache.filter(b => !b.id?.startsWith('_avail_'));
                this._cache = [...synth, ...local];
                this._syncFailCount = 0; // #10: successo (anon)
                console.log(`[Supabase] syncFromSupabase (anon): ${synth.length} slot sintetici`);
                return;
            }

            // ── ADMIN o UTENTE: SELECT bookings reali ─────────────────────────────────
            // Finestra operativa: 60 giorni passati + 90 futuri (contiene localStorage/egress),
            // PIÙ qualsiasi lezione passata NON pagata e non annullata (senza floor di data) → i
            // debiti vecchi (>60gg) restano visibili in Pagamenti/debitori e non si rischia di non
            // incassarli. Lo storico completo per-cliente (anche pagato) è on-demand via
            // fetchClientHistory(); le query stats/export complete via fetchForAdmin().
            const bookingSelect = 'id,local_id,user_id,date,time,slot_type,date_display,name,email,whatsapp,notes,status,paid,payment_method,paid_at,custom_price,billing_voided_at,billing_void_reason,created_at,cancellation_requested_at,cancelled_at,updated_at,cancelled_payment_method,cancelled_paid_at,cancelled_refund_pct,created_by,cancelled_by,arrived_at';
            // ownOnly: filtra per user_id server-side (es. prenotazioni.html — anche admin vedono solo i propri)
            const pastD   = new Date(); pastD.setDate(pastD.getDate() - 60);
            const futureD = new Date(); futureD.setDate(futureD.getDate() + 90);
            const pastStr   = _localDateStr(pastD);
            const futureStr = _localDateStr(futureD);

            // H4: su admin (autoRefreshToken OFF, #9) garantisci un token fresco PRIMA delle
            // query (fingerprint + fetch): al rientro da background con token scaduto supabase-js
            // NON auto-rinnova → 401. ensureValidSession è veloce (lettura diretta da storage, #5).
            if (isAdmin && typeof ensureValidSession === 'function') {
                await ensureValidSession({ force: false, timeoutMs: 3000 }).catch(() => null);
            }

            // Idrata la cache dallo snapshot localStorage PRIMA della decisione fingerprint:
            // su una pagina nuova ripristina cache + watermark → il blocco sotto fa skip/delta
            // invece di un full (admin). Per l'utente pre-popola la cache (render immediato);
            // il full utente la sostituisce comunque subito dopo.
            this._hydrateCache(syncKey, _identity);

            // ── Sync incrementale (solo admin full-list), basato sul fingerprint (count + max
            //    updated_at): 1) invariato → SKIP (wake istantaneo). 2) cambiato senza delete
            //    (count non sceso) → DELTA, scarica solo le righe con updated_at >= cursore.
            //    3) altrimenti (primo load, count sceso = hard-delete, reconcile dovuto) → FULL.
            //    Reconcile periodico (5 min) come safety net per delete/edge a count invariato.
            let isDelta = false, deltaFrom = null, deltaNewFp = null;
            // forceFull salta l'intero blocco (niente skip-su-fingerprint-invariato né delta) → FULL.
            if (isAdmin && !ownOnly && !forceFull) {
                const reconcileDue = !this._bkLastFullFetch || (Date.now() - this._bkLastFullFetch > this._BK_RECONCILE_MS);
                const prev = this._parseFingerprint(this._bkFingerprint);
                if (prev && this._cache.length > 0) {
                    const fp = await this._bookingsFingerprint(pastStr, futureStr);
                    if (fp !== null && fp === this._bkFingerprint) {
                        console.log('[Supabase] syncFromSupabase (admin): fingerprint invariato → skip full-fetch');
                        this._syncFailCount = 0; // #10: skip = successo
                        return;
                    }
                    const cur = this._parseFingerprint(fp);
                    if (!reconcileDue && fp !== null && cur && cur.count != null && prev.count != null
                        && cur.count >= prev.count && prev.maxUpd && !isNaN(Date.parse(prev.maxUpd))) {
                        isDelta = true;
                        deltaFrom = new Date(Date.parse(prev.maxUpd) - this._DELTA_OVERLAP_MS).toISOString();
                        deltaNewFp = fp; // il fingerprint server appena calcolato dopo il merge
                    }
                }
            }

            // Paginazione: Supabase limita a 1000 righe per request (max-rows server)
            const PAGE = 1000;
            let data = [], pageFrom = 0, done = false;
            while (!done) {
                let q = supabaseClient.from('bookings').select(bookingSelect)
                    .order(isDelta ? 'updated_at' : 'created_at', { ascending: false })
                    .order('id')  // tiebreaker: created_at/updated_at non unici → pagine stabili oltre le 1000 righe
                    .range(pageFrom, pageFrom + PAGE - 1)
                    .lte('date', futureStr);
                if (isDelta) {
                    // DELTA: solo le righe modificate dal cursore (overlap anti clock-skew). NIENTE
                    // floor di data → ripesca anche un debito vecchio appena saldato/editato (la sua
                    // updated_at è recente) che resterebbe altrimenti "appeso" come non pagato.
                    q = q.gte('updated_at', deltaFrom);
                } else {
                    // FULL: finestra [pastStr, futureStr] OPPURE qualsiasi lezione passata non pagata
                    // e non annullata → i debiti vecchi restano in cache (debitori/registro/card).
                    // Coincide col filtro del fingerprint → count/maxUpd coerenti col contenuto cache.
                    q = q.or(`date.gte.${pastStr},and(paid.is.false,status.neq.cancelled)`);
                }
                if (ownOnly && user) q = q.eq('user_id', user.id);
                // Timeout 12s: senza, su rete lenta/wake-from-idle questa query raw
                // appende l'intero sync e refreshInFlight non si resetta mai (→ freeze).
                const { data: page, error: pageErr } = await _queryWithTimeout(q, 12000);
                if (pageErr) throw new Error('Page fetch error: ' + (pageErr.message || pageErr));
                data = data.concat(page || []);
                done = !page || page.length < PAGE;
                pageFrom += PAGE;
            }
            // Utente non-admin: richiede anche la disponibilità aggregata in parallelo
            // get_availability_range(p_org_slug, p_from, p_to) via cache dedup 60s
            const fetchAvail = !isAdmin
                ? this._fetchAvailabilityCached(todayStr, endStr)
                : Promise.resolve({ data: null, error: null });

            const { data: availData, error: e2 } = await fetchAvail;
            if (e2) { console.error('[Supabase] get_availability_range error:', e2.message); }
            // Capienza/posti residui server-authoritative per il rendering (utente non-admin)
            if (!isAdmin) this._indexAvailability(availData);

            const mapped = data.map(row => this._mapRow(row));

            // Booking sintetici per slot occupati da altri (solo utente non-admin)
            let synth = [];
            if (!isAdmin && availData) {
                const ownCounts = {};
                for (const b of mapped) {
                    if (b.status === 'confirmed') {
                        const k = `${b.date}|${b.time}`;
                        ownCounts[k] = (ownCounts[k] || 0) + 1;
                    }
                }
                synth = this._buildSyntheticBookings(availData, ownCounts);
            }

            // Pending: booking in cache recenti (< 30 min) non ancora confermati su Supabase
            const supabaseIds = new Set(mapped.map(m => m.id));
            const local = this._cache.filter(b => !b.id?.startsWith('_avail_'));
            const now = Date.now();
            const dataLastCleared = localStorage.getItem('dataLastCleared') || '0';
            const pending = local.filter(b => {
                if (supabaseIds.has(b.id) || b.status === 'cancelled') return false;
                // Se ha _sbId era già su Supabase: se non è più nella risposta, è stato eliminato
                if (b._sbId) return false;
                const age = now - new Date(b.createdAt).getTime();
                if (age >= 30 * 60 * 1000) return false;
                if (b.createdAt <= dataLastCleared) return false;
                return true;
            });

            // Guardia anti-race: se la cache è stata svuotata durante la sync, non ricommittare.
            if ((localStorage.getItem('dataLastCleared') || '0') !== clearedAtStart) {
                console.log('[Supabase] syncFromSupabase: dataLastCleared cambiato durante la sync → skip commit');
                return;
            }

            if (isDelta) {
                // Merge incrementale (admin): upsert per _sbId nelle righe reali esistenti,
                // preservando sintetici e pending (righe senza _sbId). Le righe cancelled
                // arrivano nel delta e sovrascrivono → restano in cache come cancelled (no fantasmi).
                // Idempotente (Map per id) → l'overlap di 5s non crea doppioni.
                const byId = new Map();
                const others = [];
                for (const b of this._cache) {
                    if (b._sbId) byId.set(b._sbId, b);
                    else others.push(b);
                }
                for (const m of mapped) { if (m._sbId) byId.set(m._sbId, m); }
                this._cache = [...byId.values(), ...others];
                // Riusa il fingerprint server già calcolato (count+max corretti). NON tocca
                // _bkLastFullFetch → il reconcile periodico (5 min) resta garantito come safety net.
                if (deltaNewFp) this._bkFingerprint = deltaNewFp;
                console.log(`[Supabase] syncFromSupabase (admin DELTA): ${mapped.length} righe cambiate, ${this._cache.length} totali in cache`);
            } else {
                this._cache = [...mapped, ...synth, ...pending];
                if (isAdmin && !ownOnly) {
                    // Aggiorna il fingerprint dai dati appena scaricati (count = righe in finestra,
                    // + max updated_at) — gratis, niente query extra — e segna il full-fetch.
                    let _maxUpd = '';
                    for (const r of data) { if (r.updated_at && r.updated_at > _maxUpd) _maxUpd = r.updated_at; }
                    this._bkFingerprint = `${data.length}|${_maxUpd}`;
                    this._bkLastFullFetch = Date.now();
                }
                console.log(`[Supabase] syncFromSupabase (${isAdmin ? 'admin FULL' : 'user'}): ${mapped.length} da Supabase, ${synth.length} sintetici, ${pending.length} pending`);
            }

            // Persisti la cache aggiornata per la navigazione cross-pagina (full sempre; delta
            // solo se sono arrivate righe nuove, per non riscrivere localStorage a vuoto).
            if (!isDelta || mapped.length > 0) this._persistCache(syncKey, _identity);

            this._retryPending(pending, user);
            // Sync riuscita — cancella eventuale retry pendente
            clearTimeout(BookingStorage._syncRetryTimer);
            BookingStorage._syncFailCount = 0; // #10: reset su successo
        } catch (e) {
            console.error('[Supabase] syncFromSupabase exception:', e);
            // #10: i primi 2 fallimenti sono spesso transitori (lock bloccato al rientro che
            // si auto-recupera al retry 5s) → retry in SILENZIO. Toast solo al 3° consecutivo.
            BookingStorage._syncFailCount = (BookingStorage._syncFailCount || 0) + 1;
            if (BookingStorage._syncFailCount >= 3 && typeof showToast === 'function') {
                showToast('Errore di connessione al server. Verifica la tua connessione.', 'error', 5000);
            }
            // Retry automatico dopo 5 secondi
            clearTimeout(BookingStorage._syncRetryTimer);
            BookingStorage._syncRetryTimer = setTimeout(() => {
                console.log('[Supabase] syncFromSupabase — retry automatico');
                BookingStorage.syncFromSupabase();
            }, 5000);
        }
    }

    // Mappa una riga Supabase al formato booking localStorage
    static _mapRow(row) {
        return {
            id:                       row.local_id || row.id,
            _sbId:                    row.id,
            userId:                   row.user_id,
            date:                     row.date,
            time:                     row.time,
            slotType:                 row.slot_type,
            dateDisplay:              row.date_display || '',
            name:                     row.name,
            email:                    row.email,
            whatsapp:                 row.whatsapp,
            notes:                    row.notes || '',
            status:                   row.status,
            paid:                     row.paid || false,
            paymentMethod:            row.payment_method || null,
            paidAt:                   row.paid_at || null,
            customPrice:              row.custom_price != null ? Number(row.custom_price) : null,
            billingVoidedAt:          row.billing_voided_at || null,
            billingVoidReason:        row.billing_void_reason || null,
            createdAt:                row.created_at,
            cancellationRequestedAt:  row.cancellation_requested_at || null,
            cancelledAt:              row.cancelled_at || null,
            cancelledPaymentMethod:   row.cancelled_payment_method || null,
            cancelledPaidAt:          row.cancelled_paid_at || null,
            cancelledRefundPct:       row.cancelled_refund_pct ?? null,
            updatedAt:                row.updated_at || null,
            createdBy:                row.created_by || null,
            cancelledBy:              row.cancelled_by || null,
            arrivedAt:                row.arrived_at || null,
        };
    }

    // Crea booking sintetici (senza dati personali) per slot occupati da altri utenti.
    // availData: array di {date, time, slot_type, capacity, confirmed_count, remaining}
    //            dalla RPC multi-tenant get_availability_range/get_slot_availability.
    //            (compat: accetta anche i vecchi nomi slot_date/slot_time single-tenant)
    // ownCounts: {date|time -> n} dei propri booking già confermati (da sottrarre)
    static _buildSyntheticBookings(availData, ownCounts) {
        const result = [];
        for (const row of availData || []) {
            const d     = row.date ?? row.slot_date;
            const t     = row.time ?? row.slot_time;
            const own   = ownCounts[`${d}|${t}`] || 0;
            const count = Math.max(0, Number(row.confirmed_count) - own);
            for (let i = 0; i < count; i++) {
                result.push({
                    id:        `_avail_${d}_${t.replace(/[: ]/g, '')}_${row.slot_type}_${i}`,
                    date:      d,
                    time:      t,
                    slotType:  row.slot_type,
                    status:    'confirmed',
                    name:      '',
                    email:     '',
                    whatsapp:  '',
                    notes:     '',
                    paid:      false,
                    createdAt: d + 'T00:00:00.000Z',
                });
            }
        }
        return result;
    }

    // Fetch diretto da Supabase senza toccare localStorage — usato da stats admin ed export.
    // startStr / endStr: 'YYYY-MM-DD' oppure null per nessun limite.
    static async fetchForAdmin(startStr, endStr) {
        if (typeof supabaseClient === 'undefined') return null;
        const cacheKey = `${startStr || ''}|${endStr || ''}`;
        const cached = this._adminFetchCacheByKey[cacheKey];
        if (cached && Date.now() - cached.ts < this._ADMIN_FETCH_CACHE_TTL_MS) return cached.data;
        if (this._adminFetchInFlightByKey[cacheKey]) return this._adminFetchInFlightByKey[cacheKey];

        this._adminFetchInFlightByKey[cacheKey] = (async () => {
            const adminCols = 'id,date,time,slot_type,name,email,whatsapp,notes,status,paid,payment_method,paid_at,custom_price,billing_voided_at,billing_void_reason,created_at,cancelled_at,cancelled_paid_at,cancelled_payment_method,cancelled_refund_pct';
            // Paginazione: il server limita a 1000 righe per request
            const PAGE = 1000;
            let all = [], pageFrom = 0, done = false;
            while (!done) {
                let q = supabaseClient.from('bookings').select(adminCols)
                    .order('date', { ascending: false })
                    .range(pageFrom, pageFrom + PAGE - 1);
                if (startStr) q = q.gte('date', startStr);
                if (endStr)   q = q.lte('date', endStr);
                const response = await _queryWithTimeout(q, 15000);
                const { data, error } = response || {};
                if (!response) throw new Error('fetchForAdmin empty response');
                if (error) throw new Error('Page fetch error: ' + (error.message || error));
                all = all.concat(data || []);
                done = !data || data.length < PAGE;
                pageFrom += PAGE;
            }
            const mapped = all.map(row => this._mapRow(row));
            this._adminFetchCacheByKey[cacheKey] = { ts: Date.now(), data: mapped };
            return mapped;
        })();

        try { return await this._adminFetchInFlightByKey[cacheKey]; }
        catch (e) {
            console.error('[Supabase] fetchForAdmin exception:', e);
            if (cached) return cached.data;
            return null;
        } finally {
            delete this._adminFetchInFlightByKey[cacheKey];
        }
    }

    // Storico COMPLETO di un singolo cliente (anche lezioni pagate fuori finestra 60gg), senza
    // limiti di data — query mirata per cliente, NON tocca la cache globale/localStorage. Usato da:
    //  • admin: bottone "Carica storico completo" nella card cliente (vede tutte le righe via is_admin);
    //  • utente: grafico mensile in prenotazioni.html (RLS → ritorna solo le PROPRIE righe).
    // Paginato (cap 1000 righe PostgREST); tiebreaker .order('id') per pagine stabili. Ritorna
    // righe mappate con _mapRow, oppure null se mancano identificatori o su errore.
    static async fetchClientHistory({ userId = null, email = null, whatsapp = null } = {}) {
        if (typeof supabaseClient === 'undefined') return null;
        // Email/whatsapp racchiusi tra doppi apici con escape: una virgola/parentesi nel valore
        // romperebbe il logic-tree di PostgREST .or() → PGRST100.
        const quote = (v) => `"${String(v).replace(/(["\\])/g, '\\$1')}"`;
        const ors = [];
        if (userId)   ors.push(`user_id.eq.${userId}`);
        if (email)    ors.push(`email.eq.${quote(email)}`);
        if (whatsapp) ors.push(`whatsapp.eq.${quote(whatsapp)}`);
        if (!ors.length) return null;
        const cols = 'id,local_id,user_id,date,time,slot_type,date_display,name,email,whatsapp,notes,status,paid,payment_method,paid_at,custom_price,billing_voided_at,billing_void_reason,created_at,cancellation_requested_at,cancelled_at,cancelled_payment_method,cancelled_paid_at,cancelled_refund_pct,updated_at,created_by,cancelled_by,arrived_at';
        try {
            const { data, error } = await fetchAllPaginated(() => supabaseClient
                .from('bookings')
                .select(cols)
                .or(ors.join(','))
                .order('date', { ascending: false })
                .order('id'), { timeoutMs: 15000 });
            if (error) { console.error('[Supabase] fetchClientHistory error:', error.message || error); return null; }
            return (data || []).map(row => this._mapRow(row));
        } catch (e) {
            console.error('[Supabase] fetchClientHistory exception:', e);
            return null;
        }
    }

    // Ritenta l'insert su Supabase per booking in stato pending (falliti in precedenza).
    // Ogni insert è protetto da timeout 12s: senza, le promise fire-and-forget su rete
    // lenta restano appese e saturano la microtask queue, ritardando il booking successivo.
    static async _retryPending(pending, user) {
        // Server-authoritative: ritenta via la RPC atomica `book_slot`, NON con un insert
        // diretto su `bookings`. L'insert diretto bypassava org_id/capienza/advisory-lock e,
        // con la RLS SaaS (bookings scrivibili solo da admin o via RPC), fallisce comunque
        // per l'utente normale. book_slot risolve org/tipo/prezzo/user server-side (auth.uid()).
        const orgSlug = _resolveOrgSlug();
        for (const b of pending) {
            console.warn('[Supabase] retry book_slot per booking pending:', b.id);
            try {
                const { data, error } = await _rpcWithTimeout(supabaseClient.rpc('book_slot', {
                    p_org_slug:     orgSlug,
                    p_local_id:     b.id,
                    p_date:         b.date,
                    p_time:         b.time,
                    p_name:         b.name,
                    p_email:        b.email,
                    p_whatsapp:     b.whatsapp,
                    p_notes:        b.notes || '',
                    p_date_display: b.dateDisplay || '',
                }), 12000);
                if (error) {
                    console.error('[Supabase] retry book_slot error:', error.message);
                } else if (data && data.success) {
                    b._sbId = data.booking_id || b._sbId || null;
                    if (typeof data.paid === 'boolean') b.paid = data.paid;
                    console.log('[Supabase] retry book_slot OK:', b.id);
                } else {
                    // rifiutato (già presente / slot pieno / cutoff): logga, non ri-ciclare all'infinito
                    console.warn('[Supabase] retry book_slot rifiutato:', data?.error || 'unknown', b.id);
                }
            } catch (e) {
                console.error('[Supabase] retry book_slot timeout/exception:', b.id, e && e.message);
            }
            // Piccola pausa tra i retry per non saturare la microtask queue su molti pending
            await new Promise(r => setTimeout(r, 100));
        }
    }

    static async saveBooking(booking) {
        booking.id = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        booking.createdAt = new Date().toISOString();
        booking.status = 'confirmed';

        if (typeof supabaseClient === 'undefined') {
            return { ok: false, error: 'offline', booking };
        }

        // Guard di sessione: garantisce un access_token fresco PRIMA della RPC (stesso pattern
        // già usato in admin-payments.js prima delle RPC non-idempotenti). Senza, su tab tornata
        // da background book_slot restava appesa fino al safety-timeout del bottone (50s) senza
        // prenotare. Best-effort: se fallisce, la RPC parte comunque (RLS/401 decideranno l'esito).
        if (typeof ensureValidSession === 'function') {
            try { await ensureValidSession(); } catch (_) { /* best-effort */ }
        }

        // book_slot risolve org/capienza/tipo/prezzo server-side: il client passa
        // solo lo slug org + i dati del booking (niente p_slot_type/p_max_capacity).
        // user_id e modello di billing sono risolti dal server via auth.uid().
        const orgSlug = _resolveOrgSlug();
        // Timeout 45s per evitare che il bottone resti bloccato su rete lenta
        const _abortCtrl = new AbortController();
        const _abortTimer = setTimeout(() => _abortCtrl.abort(), 45000);
        let data, error;
        try {
            ({ data, error } = await supabaseClient.rpc('book_slot', {
                p_org_slug:     orgSlug,
                p_local_id:     booking.id,
                p_date:         booking.date,
                p_time:         booking.time,
                p_name:         booking.name,
                p_email:        booking.email,
                p_whatsapp:     booking.whatsapp,
                p_notes:        booking.notes || '',
                p_date_display: booking.dateDisplay || ''
            }).abortSignal(_abortCtrl.signal));
        } catch (e) {
            clearTimeout(_abortTimer);
            console.error('[Supabase] book_slot timeout/abort:', e.message);
            return { ok: false, error: 'server_error', booking };
        }
        clearTimeout(_abortTimer);
        if (error) {
            console.error('[Supabase] book_slot error:', error.message);
            return { ok: false, error: 'server_error', booking };
        }
        if (!data || !data.success) {
            const reason = data?.error || 'unknown';
            console.warn('[Supabase] book_slot rifiutato:', reason);
            return { ok: false, error: reason, booking };
        }
        // RPC confermata — aggiorna cache in memoria
        booking._sbId = data.booking_id || null;
        booking.paid = !!data.paid;
        this._cache.push(booking);
        this._invalidateAvailabilityCache(); // disponibilità cambiata → niente cache stantia
        console.log('[Supabase] book_slot OK — id:', booking.id, 'paid:', booking.paid);
        return { ok: true, booking };
    }

    // Versione admin di saveBooking: prenota a nome di un cliente.
    // NOTA contratto book_slot: il server risolve user_id da auth.uid() — non
    // accetta più un p_user_id esplicito. clientUserId resta nella firma per
    // retro-compatibilità dei chiamanti ma non viene inoltrato. Se serve davvero
    // attribuire il booking al cliente (es. per il push promemoria), la RPC
    // book_slot va estesa lato server con un parametro admin-only.
    static async saveBookingForClient(booking, clientUserId) {
        if (typeof sessionStorage !== 'undefined' && sessionStorage.getItem('adminAuth') !== 'true') {
            console.warn('[saveBookingForClient] Chiamata senza sessione admin attiva — operazione bloccata lato frontend');
            return { ok: false, error: 'not_admin', booking };
        }
        booking.id = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
        booking.createdAt = new Date().toISOString();
        booking.status = 'confirmed';

        if (typeof supabaseClient === 'undefined') {
            return { ok: false, error: 'offline', booking };
        }

        const orgSlug = _resolveOrgSlug();
        // Timeout 45s come saveBooking: senza, su rete lenta/webview sospesa la RPC
        // resta appesa e il bottone admin si blocca a tempo indefinito (freeze "alla 2a").
        const _abortCtrl = new AbortController();
        const _abortTimer = setTimeout(() => _abortCtrl.abort(), 45000);
        let data, error;
        try {
            ({ data, error } = await supabaseClient.rpc('book_slot', {
                p_org_slug:     orgSlug,
                p_local_id:     booking.id,
                p_date:         booking.date,
                p_time:         booking.time,
                p_name:         booking.name,
                p_email:        booking.email,
                p_whatsapp:     booking.whatsapp,
                p_notes:        booking.notes || '',
                p_date_display: booking.dateDisplay || '',
                p_for_user_id:  clientUserId || null   // admin-only: attribuisce il booking al cliente
            }).abortSignal(_abortCtrl.signal));
        } catch (e) {
            clearTimeout(_abortTimer);
            console.error('[Supabase] adminBook timeout/abort:', e.message);
            return { ok: false, error: 'server_error', booking };
        }
        clearTimeout(_abortTimer);
        if (error) {
            console.error('[Supabase] adminBook error:', error.message);
            return { ok: false, error: 'server_error', booking };
        }
        if (!data || !data.success) {
            console.warn('[Supabase] adminBook rifiutato:', data?.error);
            return { ok: false, error: data?.error || 'unknown', booking };
        }
        booking._sbId = data.booking_id || null;
        booking.paid = !!data.paid;
        this._cache.push(booking);
        this._invalidateAvailabilityCache(); // disponibilità cambiata → niente cache stantia
        return { ok: true, booking };
    }

    static getBookingsForSlot(date, time) {
        const bookings = this.getAllBookings();
        return bookings.filter(b => b.date === date && b.time === time && b.status !== 'cancelled');
    }

    // Capacità ASSOLUTA effettiva per (data, ora, tipo).
    // Modello nuovo (per-org): non più "base + extras", ma un numero assoluto
    // risolto con precedenza override → template attivo → default dello slot_type.
    //   1) schedule_overrides.capacity per quella data/ora (se il tipo coincide
    //      col tipo dell'override; altrimenti 0 per quel tipo);
    //   2) template della settimana attivata per quella data quando il tipo coincide;
    //   3) default_capacity dello slot_type (_ORG_SLOT_TYPES, fallback SLOT_MAX_CAPACITY).
    // Per i tipi diversi dal tipo principale dello slot (slot "misto"/diviso) la
    // capienza resta 0 finché non viene impostata esplicitamente via override.
    static getEffectiveCapacity(date, time, slotType) {
        // 0) Capienza server-authoritative dalla RPC availability (get_availability_range),
        //    quando disponibile per (data, ora, tipo): è la fonte di verità del server
        //    (override → template → default risolti server-side da resolve_slot_config).
        const srv = this._availabilityByKey[`${date}|${time}|${slotType}`];
        if (srv && srv.capacity != null) return Math.max(0, Number(srv.capacity));

        const overrides = this.getScheduleOverrides();
        const slots = overrides[date] || [];
        const slot = slots.find(s => s.time === time);

        // 1) Override puntuale per data/ora
        if (slot) {
            if (slot.type === slotType) {
                // capacity assoluta salvata sull'override; se assente, ricadi sul default
                if (slot.capacity != null && !Number.isNaN(Number(slot.capacity))) {
                    return Math.max(0, Number(slot.capacity));
                }
                return this._defaultCapacityFor(slotType);
            }
            // tipo richiesto != tipo principale dell'override → nessun posto per quel tipo
            // (a meno che un futuro override per-tipo lo definisca esplicitamente)
            return 0;
        }

        // 2) Template della settimana ATTIVATA che contiene `date` (org, per-settimana)
        const orgWeekly = _orgWeeklyForDate(date);
        if (orgWeekly) {
            const wd = this._weekdayFromDateStr(date);
            const tplSlot = wd != null ? (orgWeekly[wd] || {})[time] : null;
            if (tplSlot && tplSlot.slotTypeKey === slotType) {
                if (tplSlot.capacity != null) return Math.max(0, Number(tplSlot.capacity));
                return this._defaultCapacityFor(slotType);
            }
            // Se il template definisce un tipo diverso per quello slot, l'altro tipo è 0
            if (tplSlot && tplSlot.slotTypeKey !== slotType) return 0;
        }

        // 3) Default del tipo slot
        return this._defaultCapacityFor(slotType);
    }

    // Capienza di default del tipo slot (config org → fallback costante legacy).
    static _defaultCapacityFor(slotType) {
        if (_ORG_SLOT_TYPES && _ORG_SLOT_TYPES[slotType]) {
            return Math.max(0, Number(_ORG_SLOT_TYPES[slotType].defaultCapacity) || 0);
        }
        return SLOT_MAX_CAPACITY[slotType] || 0;
    }

    // weekday (0=Domenica..6=Sabato, come extract(dow)) da 'YYYY-MM-DD' in fuso locale.
    static _weekdayFromDateStr(dateStr) {
        if (!dateStr || typeof dateStr !== 'string') return null;
        const [y, m, d] = dateStr.split('-').map(Number);
        if ([y, m, d].some(Number.isNaN)) return null;
        return new Date(y, m - 1, d).getDay();
    }

    // Posti residui per (data, ora, tipo). Modello nuovo: capienza assoluta.
    // Per gli slot futuri privi di prenotazioni reali in cache usa il dato
    // server-authoritative 'remaining' della RPC availability (così anche i
    // client anonimi, che non possono leggere slot_types via RLS, vedono numeri
    // coerenti). Negli altri casi calcola capacity - confermati dalla cache.
    static getRemainingSpots(date, time, slotType) {
        const bookings = this.getBookingsForSlot(date, time);
        // Filtra per tipo: ogni "categoria" ha la propria capacità indipendente.
        // Conta anche 'cancellation_requested' (posti ancora occupati fino all'annullamento):
        // allineato a book_slot / get_availability_range, altrimenti si mostra un "posto
        // fantasma" che il server poi rifiuta con slot_full (code review 2, #1).
        const confirmedCount = bookings.filter(b => (b.status === 'confirmed' || b.status === 'cancellation_requested') && (!b.slotType || b.slotType === slotType)).length;
        const maxCapacity = this.getEffectiveCapacity(date, time, slotType);
        const local = Math.max(0, maxCapacity - confirmedCount);

        // Se non ci sono booking reali in cache per questo slot ma il server ha un
        // 'remaining', fidati del server (evita di mostrare "pieno/disponibile"
        // sbagliato quando la cache locale è parziale, tipico dei client anonimi).
        const srv = this._availabilityByKey[`${date}|${time}|${slotType}`];
        if (srv && srv.remaining != null) {
            const hasRealLocal = bookings.some(b => !b.id?.startsWith('_avail_'));
            if (!hasRealLocal) return Math.max(0, Number(srv.remaining));
        }
        return local;
    }

    // Cache availability server-authoritative: { 'date|time|slot_type': {capacity, remaining, confirmedCount} }
    // Popolata da _indexAvailability() a partire dalle righe di get_availability_range/get_slot_availability.
    static _availabilityByKey = {};

    // Indicizza le righe availability della RPC nella cache _availabilityByKey.
    // Accetta i nomi nuovi (date/time/capacity/remaining) con compat sui vecchi.
    static _indexAvailability(availData) {
        if (!Array.isArray(availData)) return;
        for (const row of availData) {
            const d = row.date ?? row.slot_date;
            const t = row.time ?? row.slot_time;
            const st = row.slot_type;
            if (!d || !t || !st) continue;
            this._availabilityByKey[`${d}|${t}|${st}`] = {
                capacity:       row.capacity != null ? Number(row.capacity) : null,
                remaining:      row.remaining != null ? Number(row.remaining) : null,
                confirmedCount: row.confirmed_count != null ? Number(row.confirmed_count) : null,
            };
        }
    }

    // Aggiunge un posto allo slot di quella data/ora.
    // Modello nuovo: la capienza è ASSOLUTA → "aggiungere un posto" = incrementare
    // di 1 la capacity dell'override per quel tipo. Se non esiste un override per
    // quella data/ora, ne crea uno con la capienza di default+1 del tipo richiesto.
    // (Il nome storico addExtraSpot resta per i call-site admin; non c'è più array extras.)
    static addExtraSpot(date, time, extraType) {
        const overrides = this.getScheduleOverrides();
        if (!overrides[date]) overrides[date] = [];
        let slot = overrides[date].find(s => s.time === time);
        if (!slot) {
            // Nessuno slot configurato per quella data/ora: crea l'override dal tipo richiesto
            slot = { time, type: extraType, capacity: this._defaultCapacityFor(extraType) + 1 };
            overrides[date].push(slot);
            this.saveScheduleOverrides(overrides, [date]);
            return true;
        }
        const current = this.getEffectiveCapacity(date, time, slot.type === extraType ? extraType : slot.type);
        if (slot.type === extraType) {
            slot.capacity = current + 1;
        } else {
            // Tipo diverso dal principale: oggi il modello assoluto non supporta
            // capienze multiple per-tipo sullo stesso slot. Convertiamo il tipo
            // principale e impostiamo la capienza assoluta a current+1.
            slot.type = extraType;
            slot.capacity = this._defaultCapacityFor(extraType) + 1;
        }
        this.saveScheduleOverrides(overrides, [date]);
        return true;
    }

    // Rimuove un posto dallo slot (decrementa la capacity assoluta), se libero.
    static removeExtraSpot(date, time, extraType) {
        const overrides = this.getScheduleOverrides();
        const slots = overrides[date] || [];
        const slot = slots.find(s => s.time === time);
        if (!slot || slot.type !== extraType) return false;
        const effectiveCap = this.getEffectiveCapacity(date, time, extraType);
        const bookings = this.getBookingsForSlot(date, time);
        const bookedCount = bookings.filter(b => b.status === 'confirmed' && (!b.slotType || b.slotType === extraType)).length;
        if (effectiveCap - bookedCount <= 0) return false; // nessun posto libero da rimuovere
        slot.capacity = Math.max(0, effectiveCap - 1);
        this.saveScheduleOverrides(overrides, [date]);
        return true;
    }

    // Restituisce un NUOVO array in cui la prenotazione `id` è un nuovo oggetto con il
    // patch applicato (le altre restano per riferimento). Necessario perché
    // replaceAllBookings fa il diff contro la cache precedente: mutare gli oggetti in
    // place renderebbe il diff sempre vuoto → nessuna sync sul server (cancellazioni
    // mai propagate, posti fantasma, prenotazioni che "resuscitano" al sync).
    static _withBookingPatch(all, id, patch) {
        return all.map(b => (b.id === id ? { ...b, ...patch } : b));
    }

    // Patch standard di cancellazione (preserva i dati di pagamento nello storico).
    static _cancelPatch(booking) {
        return {
            cancelledPaymentMethod: booking.paymentMethod,
            cancelledPaidAt: booking.paidAt,
            status: 'cancelled',
            cancelledAt: new Date().toISOString(),
            paid: false,
            paymentMethod: null,
            paidAt: null,
        };
    }

    // Cancella direttamente una prenotazione (small-group, autonomia) senza conversione slot
    // Usato quando il cliente annulla con più di 24h di anticipo.
    // NOTA: nessun rimborso credito (sistema crediti rimosso) — solo cambio stato.
    static async cancelDirectly(id) {
        const all = this.getAllBookings();
        const booking = all.find(b => b.id === id);
        if (!booking || booking.status !== 'confirmed') return false;
        this.replaceAllBookings(this._withBookingPatch(all, id, this._cancelPatch(booking)));
        return true;
    }

    // Cancella immediatamente uno "Slot prenotato" e converte lo slot in "Lezione di Gruppo"
    // Usato quando il cliente annulla con più di 24h di anticipo.
    // NOTA: nessun rimborso credito (sistema crediti rimosso) — solo cambio stato + conversione slot.
    // Supabase migration: sostituire le due operazioni con cancel_booking (RPC atomica, group->small lato server)
    static async cancelAndConvertSlot(id) {
        const all = this.getAllBookings();
        const booking = all.find(b => b.id === id);
        if (!booking || booking.status !== 'confirmed') return false;

        // Cancella subito la prenotazione (nuovo oggetto per il diff)
        this.replaceAllBookings(this._withBookingPatch(all, id, this._cancelPatch(booking)));

        // Converte lo slot in Gestione Orari da group-class a small-group
        const overrides = this.getScheduleOverrides();
        const dateSlots = overrides[booking.date];
        if (dateSlots) {
            const slot = dateSlots.find(s => s.time === booking.time && s.type === SLOT_TYPES.GROUP_CLASS);
            if (slot) {
                slot.type = SLOT_TYPES.SMALL_GROUP;
                delete slot.client;
                delete slot.bookingId;
                this.saveScheduleOverrides(overrides, [booking.date]);
            }
        }
        return true;
    }

    // Marca una prenotazione come "annullamento richiesto" (il posto torna disponibile)
    static requestCancellation(id) {
        const all = this.getAllBookings();
        const booking = all.find(b => b.id === id);
        if (!booking || booking.status !== 'confirmed') return false;
        this.replaceAllBookings(this._withBookingPatch(all, id, {
            status: 'cancellation_requested',
            cancellationRequestedAt: new Date().toISOString(),
        }));
        return true;
    }

    // Quando arriva una nuova prenotazione, cancella la prima richiesta pendente per quello slot (FIFO)
    static async fulfillPendingCancellations(date, time) {
        const all = this.getAllBookings();
        const pending = all
            .filter(b => b.date === date && b.time === time &&
                (b.status === 'cancellation_requested' ||
                 (b.status === 'confirmed' && b.cancellationRequestedAt)))
            .sort((a, b) => (a.cancellationRequestedAt || '').localeCompare(b.cancellationRequestedAt || ''));
        if (pending.length === 0) return false;
        const toCancel = pending[0];
        // Nuovo oggetto per la prenotazione cancellata (il diff in replaceAllBookings
        // confronta con la cache precedente: mutare in place lo renderebbe sempre vuoto).
        this.replaceAllBookings(this._withBookingPatch(all, toCancel.id, this._cancelPatch(toCancel)));
        // NOTA: nessun rimborso credito (sistema crediti rimosso) — solo cambio stato.
        return true;
    }

    // Controlla le richieste pendenti: se la lezione è entro 2h, nega l'annullamento (torna confirmed)
    static processPendingCancellations() {
        const all = this.getAllBookings();
        const now = new Date();
        const twoHoursMs = 2 * 60 * 60 * 1000;
        let changed = false;
        // Costruisce un nuovo array (nuovo oggetto per ogni booking riportato a
        // 'confirmed') così il diff in replaceAllBookings rileva il cambio e sincronizza.
        const updated = all.map(b => {
            if (b.status !== 'cancellation_requested') return b;
            const _tp = _parseSlotTime(b.time);
            if (!_tp) return b;
            const [_yr, _mo, _dy] = b.date.split('-').map(Number);
            const lessonStart = new Date(_yr, _mo - 1, _dy, _tp.startH, _tp.startM, 0, 0);
            if (lessonStart - now <= twoHoursMs) {
                changed = true;
                // Keep cancellationRequestedAt so fulfillPendingCancellations can still
                // honour the request if another user books this slot.
                return { ...b, status: 'confirmed' };
            }
            return b;
        });
        if (changed) this.replaceAllBookings(updated);
        return changed;
    }

    // Teardown logout (H2): rimuove 'gym_stats' da localStorage. La chiave non viene
    // più scritta (mini-ledger stats rimosso: nessuna UI lo leggeva) — la pulizia
    // resta per i device con residui legacy.
    static clearStats() {
        try { localStorage.removeItem('gym_stats'); } catch (_) {}
    }

    // Teardown logout (H2): azzera la cache availability server-authoritative
    // (capienze/posti residui) per evitare valori stantii cross-org.
    static clearAvailability() {
        this._availabilityByKey = {};
    }

    // ── Helpers per scheduleOverrides ────────────────────────────────────────
    // Accesso centralizzato: quando si passa a Supabase si cambiano solo questi

    static _scheduleOverridesCache = null;
    static _scheduleOverridesCacheOrg = null;   // org cui appartiene la cache in memoria

    // Cutoff data per il fetch di schedule_overrides (egress: la tabella cresce per sempre,
    // una riga per slot/data personalizzata, ed era scaricata INTERA ad ogni boot di OGNI
    // utente — anche anonimo). Finestra bounded:
    //  - admin: dal 1° gennaio dell'anno precedente (copre il filtro stats "Anno precedente"
    //    e i 12 mesi di occupazione; ≤24 mesi, niente aritmetica sui mesi → nessun overflow);
    //  - altri (cliente/anon): oggi − 30gg (il calendario cliente non naviga nel passato:
    //    prevWeek disabilitato a offset 0; le conversioni di slot toccano solo date future).
    // Lo STESSO cutoff scopa il confronto del ramo full-sync di saveScheduleOverrides
    // (delete-compare) → le righe più vecchie del cutoff, assenti in locale, non possono
    // essere cancellate dal server.
    static _overridesCutoff() {
        const isAdmin = (typeof window !== 'undefined') &&
            (window._orgRole === 'owner' || window._orgRole === 'admin' ||
             (typeof sessionStorage !== 'undefined' && sessionStorage.getItem('adminAuth') === 'true'));
        const now = new Date();
        if (isAdmin) return `${now.getFullYear() - 1}-01-01`;
        const d = new Date(now);
        d.setDate(d.getDate() - 30);
        return _localDateStr(d);
    }

    static getScheduleOverrides() {
        const oid = (typeof window !== 'undefined' && window._orgId) ? window._orgId : 'anon';
        // Invalida la cache in memoria se l'org è cambiata (logout A → login B sullo
        // stesso device): senza, serviremmo gli override del tenant precedente.
        if (this._scheduleOverridesCache && this._scheduleOverridesCacheOrg === oid) {
            return this._scheduleOverridesCache;
        }
        try {
            this._scheduleOverridesCache = JSON.parse(localStorage.getItem(_schedOverridesLsKey()) || '{}');
        } catch {
            this._scheduleOverridesCache = {};
        }
        this._scheduleOverridesCacheOrg = oid;
        return this._scheduleOverridesCache;
    }

    // Salva solo le date specificate (default: tutte).
    // changedDates: array di date YYYY-MM-DD che sono cambiate, oppure null per sync completo.
    static saveScheduleOverrides(overrides, changedDates) {
        this._scheduleOverridesCache = overrides;
        this._scheduleOverridesCacheOrg = (typeof window !== 'undefined' && window._orgId) ? window._orgId : 'anon';
        _lsSet(_schedOverridesLsKey(), JSON.stringify(overrides));
        if (typeof supabaseClient === 'undefined') return;

        // Se changedDates è specificato, sincronizza solo quelle date (molto più veloce)
        const datesToSync = changedDates || Object.keys(overrides);

        // org_id obbligatorio in ogni insert (RLS *_admin via is_org_admin):
        // senza non si scrive su schedule_overrides.
        const orgId = (typeof window !== 'undefined') ? window._orgId : null;

        const rows = [];
        for (const dateStr of datesToSync) {
            const slots = overrides[dateStr];
            if (slots && slots.length > 0) {
                for (const slot of slots) {
                    // capacity ASSOLUTA per slot/data (modello nuovo, non più base+extras)
                    const capAbs = (slot.capacity != null && !Number.isNaN(Number(slot.capacity)))
                        ? Math.max(0, Number(slot.capacity))
                        : null;
                    rows.push({
                        org_id:          orgId,
                        date:            dateStr,
                        time:            slot.time,
                        slot_type:       slot.type,
                        slot_type_id:    _orgSlotTypeId(slot.type),   // lookup key → uuid in _ORG_SLOT_TYPES
                        capacity:        capAbs,
                        client_name:     slot.client?.name || null,
                        client_email:    slot.client?.email || null,
                        client_whatsapp: slot.client?.whatsapp || null,
                        booking_id:      slot.bookingId || null,
                    });
                }
            }
        }

        (async () => {
            try {
                if (rows.length > 0) {
                    const { error } = await _queryWithTimeout(supabaseClient.from('schedule_overrides')
                        .upsert(rows, { onConflict: 'org_id,date,time' }), 15000);
                    if (error) { console.error('[Supabase] saveScheduleOverrides upsert error:', error.message); return; }
                }
                // Elimina le date svuotate e gli slot rimossi dalle date cambiate
                if (changedDates) {
                    for (const dateStr of datesToSync) {
                        const activeTimesForDate = (overrides[dateStr] || []).map(s => s.time);
                        const { data: existing } = await _queryWithTimeout(supabaseClient.from('schedule_overrides')
                            .select('id, time').eq('date', dateStr), 15000);
                        if (existing) {
                            const toDelete = existing
                                .filter(r => !activeTimesForDate.includes(r.time))
                                .map(r => r.id);
                            if (toDelete.length > 0) {
                                await _queryWithTimeout(supabaseClient.from('schedule_overrides')
                                    .delete().in('id', toDelete), 15000);
                            }
                        }
                    }
                } else {
                    // Sync completo (importa settimana, clear, ecc.). Nessun caller attuale
                    // passa null (tutti usano changedDates), ma per sicurezza col fetch
                    // finestrato limitiamo il confronto allo STESSO cutoff: le righe più
                    // vecchie del cutoff, assenti in locale, non devono essere cancellate.
                    const activeKeys = new Set(rows.map(r => `${r.date}|${r.time}`));
                    const { data: existing } = await _queryWithTimeout(supabaseClient.from('schedule_overrides')
                        .select('id, date, time').gte('date', BookingStorage._overridesCutoff()), 15000);
                    if (existing) {
                        const toDelete = existing
                            .filter(r => !activeKeys.has(`${r.date}|${r.time}`))
                            .map(r => r.id);
                        if (toDelete.length > 0) {
                            await _queryWithTimeout(supabaseClient.from('schedule_overrides')
                                .delete().in('id', toDelete), 15000);
                        }
                    }
                }
            } catch (e) { console.error('[Supabase] saveScheduleOverrides exception:', e); }
        })();
    }

    // Imposta/aggiorna un singolo override (data, ora) con capienza ASSOLUTA e
    // tipo risolto. Wrapper attorno a saveScheduleOverrides (che gestisce upsert
    // org-scoped con slot_type_id risolto + org_id=window._orgId).
    //   slotType: key del tipo (es. 'small-group'); capacity: numero assoluto (null=default)
    //   extra: { client:{name,email,whatsapp}, bookingId } opzionale
    static saveScheduleOverride(date, time, slotType, capacity, extra = {}) {
        const overrides = this.getScheduleOverrides();
        if (!overrides[date]) overrides[date] = [];
        let slot = overrides[date].find(s => s.time === time);
        if (!slot) {
            slot = { time, type: slotType };
            overrides[date].push(slot);
        } else {
            slot.type = slotType;
        }
        if (capacity != null && !Number.isNaN(Number(capacity))) {
            slot.capacity = Math.max(0, Number(capacity));
        } else {
            delete slot.capacity;
        }
        if (extra.client) slot.client = extra.client; else if ('client' in extra) delete slot.client;
        if (extra.bookingId) slot.bookingId = extra.bookingId; else if ('bookingId' in extra) delete slot.bookingId;
        this.saveScheduleOverrides(overrides, [date]);
        return true;
    }

    // Carica tutti i dati da Supabase in parallelo e aggiorna il localStorage.
    // Fonti: tabelle dedicate (schedule_overrides, org_settings org-scoped)
    //        + app_settings solo per il segnale data_cleared_at.
    static async syncAppSettingsFromSupabase() {
        if (typeof supabaseClient === 'undefined') return;
        // Carica la config orari per-org (slot_types/time_slots_config/settimane attivate)
        // PRIMA di processare gli override: getEffectiveCapacity/getWeeklySchedule e i
        // booking sintetici dipendono da _ORG_SLOT_TYPES/_ORG_TPL_WEEKLY/_ORG_ACTIVE_WEEKS.
        await loadOrgScheduleConfig();
        try {
            // Promise.allSettled: ogni query è indipendente — se una fallisce le altre vanno avanti
            // Ogni query è wrappata in _queryWithTimeout per evitare hang infiniti
            // Settings: lettura org-scoped da org_settings (value è jsonb).
            //  - autenticato (window._orgId): select key,value filtrato per org (RLS limita comunque alla propria org)
            //  - anonimo/pubblico: RPC get_public_org_settings(slug) — ritorna un singolo oggetto jsonb {key: value}
            const _orgId = (typeof window !== 'undefined') ? window._orgId : null;
            const _settingsQuery = _orgId
                ? supabaseClient.from('org_settings').select('key, value').eq('org_id', _orgId)
                : (() => {
                    const slug = _resolveOrgSlug();
                    return slug
                        ? supabaseClient.rpc('get_public_org_settings', { p_org_slug: slug })
                        : Promise.resolve({ data: null, error: null });
                })();
            // Egress: finestra schedule_overrides al cutoff (admin=1° gen anno prec., altri=oggi−30gg).
            const _ovCutoff = BookingStorage._overridesCutoff();
            const _results = await Promise.allSettled([
                fetchAllPaginated(() => supabaseClient.from('schedule_overrides').select('date, time, slot_type, slot_type_id, capacity, client_name, client_email, client_whatsapp, booking_id').gte('date', _ovCutoff).order('date').order('time')),
                _queryWithTimeout(_settingsQuery),
            ]);
            const _syncLabels = ['schedule_overrides', 'org_settings'];
            _results.forEach((r, i) => { if (r.status === 'rejected') console.warn(`[Supabase] syncAppSettings: ${_syncLabels[i]} skipped (timeout/error)`); });
            const _v = (i) => _results[i].status === 'fulfilled' ? _results[i].value : { data: null, error: 'rejected' };
            const { data: overridesData, error: e5 }  = _v(0);
            const { data: settingsData, error: e6 }   = _v(1);

            // org_settings.value è jsonb: select → array [{key,value}], RPC pubblica → oggetto {key:value}.
            const sMap = Array.isArray(settingsData)
                ? Object.fromEntries(settingsData.map(r => [r.key, r.value]))
                : (settingsData && typeof settingsData === 'object' ? settingsData : null);

            // 1. Propaga il clear dati: il marker data_cleared_at vive su org_settings (ex tabella
            //    app_settings), scritto da clearAllOrgData (admin-settings.js) via upsert_org_setting.
            const remoteClearedAt = sMap?.data_cleared_at?.ts || null;
            if (remoteClearedAt) {
                const localClearedAt = localStorage.getItem('dataLastCleared') || '0';
                if (remoteClearedAt > localClearedAt) {
                    BookingStorage._cache = [];
                    BookingStorage._clearPersistedCache(); // snapshot pre-clear: via dalla localStorage
                    BookingStorage._invalidateAvailabilityCache();
                    localStorage.removeItem(_schedOverridesLsKey());
                    BookingStorage._scheduleOverridesCache = null;
                    BookingStorage._scheduleOverridesCacheOrg = null;
                    _lsSet('dataLastCleared', remoteClearedAt);
                    _lsSet('dataClearedByUser', 'true');
                    console.log('[Supabase] clearAllData ricevuto da remoto — tutte le cache svuotate');
                    // Return immediato: i dati gia' fetchati in _results sono pre-clear,
                    // applicarli ripopolerebbe la cache appena svuotata.
                    return;
                }
            }

            // 2. Schedule overrides
            if (!e5) {
                const overrides = {};
                for (const r of (overridesData || [])) {
                    if (!overrides[r.date]) overrides[r.date] = [];
                    const slot = { time: r.time, type: r.slot_type };
                    // capacity ASSOLUTA (modello nuovo): la conserviamo se valorizzata
                    if (r.capacity != null) slot.capacity = Number(r.capacity);
                    if (r.slot_type_id) slot.slotTypeId = r.slot_type_id;
                    if (r.client_name) slot.client = { name: r.client_name, email: r.client_email || '', whatsapp: r.client_whatsapp || '' };
                    if (r.booking_id) slot.bookingId = r.booking_id;
                    overrides[r.date].push(slot);
                }
                BookingStorage._scheduleOverridesCache = overrides;
                BookingStorage._scheduleOverridesCacheOrg = (typeof window !== 'undefined' && window._orgId) ? window._orgId : 'anon';
                _lsSet(_schedOverridesLsKey(), JSON.stringify(overrides));
            }

            // 3. Settings — chiavi nel DB senza prefisso gym_, in localStorage con prefisso (sMap già calcolata sopra).
            if (!e6 && sMap && Object.keys(sMap).length) {
                // jsonb: primitivi → String(); oggetti/array → JSON.stringify (le getter fanno JSON.parse)
                const _s = (lsKey, dbKey) => {
                    const v = sMap[dbKey];
                    if (v == null) return;
                    _lsSet(lsKey, (typeof v === 'object') ? JSON.stringify(v) : String(v));
                };
                _s(CancellationModeStorage.KEY,    'cancellation_mode');
                _s(CertEditableStorage.KEY,        'cert_scadenza_editable');
                _s(CertBookingStorage.KEY_EXPIRED, 'cert_block_expired');
                _s(CertBookingStorage.KEY_NOT_SET, 'cert_block_not_set');
                _s(AssicBookingStorage.KEY_EXPIRED,'assic_block_expired');
                _s(AssicBookingStorage.KEY_NOT_SET,'assic_block_not_set');
                _s(BookingBadgesStorage.KEY_CERT,  'show_cert_badge');
                _s(BookingBadgesStorage.KEY_ASSIC, 'show_assic_badge');
                _s(BookingBadgesStorage.KEY_DOC,   'show_doc_badge');
                _s(BookingBadgesStorage.KEY_ANAG,  'show_anag_badge');
                _s(WeekTemplateStorage.KEY,        'week_templates');
                _s(WeekTemplateStorage.ACTIVE_KEY, 'active_week_template');
                // Ri-normalizza il template localStorage dopo il sync (side-effect;
                // i consumatori chiamano direttamente getWeeklySchedule(dateStr)).
                getWeeklySchedule();
            }

            const count = (overridesData?.length || 0) + (sMap ? Object.keys(sMap).length : 0);
            console.log(`[Supabase] syncAppSettings: ${count} record caricati`);
        } catch (e) { console.error('[Supabase] syncAppSettings exception:', e); }
    }

    // Sostituisce l'intero array di prenotazioni (usato dopo modifiche bulk).
    // Sincronizza su Supabase solo i booking effettivamente cambiati (diff intelligente).
    static replaceAllBookings(bookings) {
        const prev = [...this._cache];
        this._cache = bookings;

        if (typeof supabaseClient === 'undefined') return;
        const prevMap = Object.fromEntries(prev.map(b => [b.id, b]));
        const changed = bookings.filter(b => {
            const p = prevMap[b.id];
            if (!p) return false; // nuovi booking gestiti da saveBooking
            return p.status !== b.status
                || p.paid !== b.paid
                || p.paymentMethod !== b.paymentMethod
                || p.paidAt !== b.paidAt
                || p.cancellationRequestedAt !== b.cancellationRequestedAt
                || p.cancelledAt !== b.cancelledAt;
        });
        // Un cambio di stato (annullo/conversione) libera/occupa un posto → invalida la
        // cache disponibilità così il prossimo sync la rilegge fresca dal server.
        if (changed.some(b => prevMap[b.id]?.status !== b.status)) this._invalidateAvailabilityCache();
        for (const b of changed) {
            if (!b._sbId) { console.warn('[Supabase] booking update skip — nessun _sbId per:', b.id); continue; }
            // Usa RPC SECURITY DEFINER per bypassare RLS (admin può modificare booking altrui)
            // Passa updatedAt per optimistic locking: se il booking è stato modificato
            // da un altro admin nel frattempo, la RPC rifiuta con 'stale_data'
            supabaseClient.rpc('admin_update_booking', {
                p_booking_id:                b._sbId,
                p_status:                    b.status,
                p_paid:                      b.paid || false,
                p_payment_method:            b.paymentMethod || null,
                p_paid_at:                   b.paidAt || null,
                p_cancellation_requested_at: b.cancellationRequestedAt || null,
                p_cancelled_at:              b.cancelledAt || null,
                p_cancelled_payment_method:  b.cancelledPaymentMethod || null,
                p_cancelled_paid_at:         b.cancelledPaidAt || null,
                p_cancelled_refund_pct:      b.cancelledRefundPct ?? null,
                p_expected_updated_at:       b.updatedAt || null,
            }).then(({ data, error }) => {
                if (error) {
                    console.error('[Supabase] admin_update_booking error:', error.message);
                    if (typeof showToast === 'function') showToast('⚠️ Errore aggiornamento prenotazione sul server.', 'error', 5000);
                    // Rollback: riscarica i dati dal server per riallineare
                    BookingStorage.syncFromSupabase().then(() => {
                        if (typeof renderAdminDayView === 'function' && typeof selectedAdminDay !== 'undefined' && selectedAdminDay) renderAdminDayView(selectedAdminDay);
                    });
                } else if (data && !data.success && data.error === 'stale_data') {
                    console.warn('[Supabase] admin_update_booking: dati obsoleti per', b._sbId, '— rollback');
                    if (typeof showToast === 'function') showToast('Prenotazione modificata da un altro dispositivo. Dati ricaricati.', 'error', 5000);
                    // Rollback: riscarica i dati dal server per riallineare
                    BookingStorage.syncFromSupabase().then(() => {
                        if (typeof renderAdminDayView === 'function' && typeof selectedAdminDay !== 'undefined' && selectedAdminDay) renderAdminDayView(selectedAdminDay);
                    });
                } else {
                    console.log('[Supabase] admin_update_booking OK — id:', b._sbId, 'status:', b.status);
                }
            });
        }
    }

    // Marca come cancellata una prenotazione per ID (preserva lo storico)
    static removeBookingById(id) {
        if (!id) return;
        const all = this._cache;
        const idx = all.findIndex(b => b.id === id);
        if (idx !== -1 && all[idx].status !== 'cancelled') {
            // Build a new array with the modified booking so replaceAllBookings
            // can diff against the old cache (which still has the original refs)
            const updated = all.map((b, i) => {
                if (i !== idx) return b;
                return {
                    ...b,
                    status: 'cancelled',
                    cancelledAt: new Date().toISOString(),
                    paid: false,
                    paymentMethod: null,
                    paidAt: null,
                };
            });
            this.replaceAllBookings(updated);
        }
    }
}

// Helper: scrive un'impostazione su org_settings via RPC upsert_org_setting (fire-and-forget).
// La RPC è org-scoped (current_org_id) e richiede admin; p_value è jsonb.
// Mappa la chiave localStorage (con prefisso gym_) alla chiave DB (senza prefisso) e
// converte il valore-stringa in un valore jsonb nativo (bool / oggetto / stringa).
function _upsertSetting(key, value) {
    if (typeof supabaseClient === 'undefined') return;
    const dbKey = key.replace(/^gym_/, ''); // 'gym_cancellation_mode' → 'cancellation_mode'
    // Coercion verso jsonb: 'true'/'false' → bool; JSON valido (oggetti/array) → parsato; altrimenti stringa
    let jsonValue;
    if (value === 'true') jsonValue = true;
    else if (value === 'false') jsonValue = false;
    else if (typeof value === 'string' && /^[\[{]/.test(value.trim())) {
        try { jsonValue = JSON.parse(value); } catch (_) { jsonValue = value; }
    } else {
        jsonValue = value;
    }
    supabaseClient.rpc('upsert_org_setting', { p_key: dbKey, p_value: jsonValue })
        .then(({ error }) => {
            if (error) console.error(`[Supabase] org_setting '${dbKey}' save error:`, error.message);
        });
}

// Cancellation mode — global setting: how the restricted cancellation window is handled
class CancellationModeStorage {
    static KEY = 'gym_cancellation_mode';
    static get() { return localStorage.getItem(this.KEY) || 'penalty-50'; }
    static set(mode) { _lsSet(this.KEY, mode); _upsertSetting(this.KEY, mode); }
}

// Cert editable — whether clients can modify their own medical certificate expiry date
class CertEditableStorage {
    static KEY = 'gym_cert_scadenza_editable';
    static get() { const v = localStorage.getItem(this.KEY); return v === null ? true : v === 'true'; }
    static set(val) { _lsSet(this.KEY, val ? 'true' : 'false'); _upsertSetting(this.KEY, val ? 'true' : 'false'); }
}

// Cert booking restrictions — block bookings when cert is expired or not set
class CertBookingStorage {
    static KEY_EXPIRED  = 'gym_cert_block_expired';
    static KEY_NOT_SET  = 'gym_cert_block_not_set';
    static getBlockIfExpired() { return localStorage.getItem(this.KEY_EXPIRED) === 'true'; }
    static getBlockIfNotSet()  { return localStorage.getItem(this.KEY_NOT_SET)  === 'true'; }
    static setBlockIfExpired(val) { _lsSet(this.KEY_EXPIRED, val ? 'true' : 'false'); _upsertSetting(this.KEY_EXPIRED, val ? 'true' : 'false'); }
    static setBlockIfNotSet(val)  { _lsSet(this.KEY_NOT_SET,  val ? 'true' : 'false'); _upsertSetting(this.KEY_NOT_SET,  val ? 'true' : 'false'); }
}

// Assicurazione booking restrictions — block bookings when assicurazione is expired or not set
class AssicBookingStorage {
    static KEY_EXPIRED  = 'gym_assic_block_expired';
    static KEY_NOT_SET  = 'gym_assic_block_not_set';
    static getBlockIfExpired() { return localStorage.getItem(this.KEY_EXPIRED) === 'true'; }
    static getBlockIfNotSet()  { return localStorage.getItem(this.KEY_NOT_SET)  === 'true'; }
    static setBlockIfExpired(val) { _lsSet(this.KEY_EXPIRED, val ? 'true' : 'false'); _upsertSetting(this.KEY_EXPIRED, val ? 'true' : 'false'); }
    static setBlockIfNotSet(val)  { _lsSet(this.KEY_NOT_SET,  val ? 'true' : 'false'); _upsertSetting(this.KEY_NOT_SET,  val ? 'true' : 'false'); }
}

// Visibility toggles for participant-card badges in admin Prenotazioni tab.
// Default true preserves prior behavior on first load.
class BookingBadgesStorage {
    static KEY_CERT  = 'gym_show_cert_badge';
    static KEY_ASSIC = 'gym_show_assic_badge';
    static KEY_DOC   = 'gym_show_doc_badge';
    static KEY_ANAG  = 'gym_show_anag_badge';
    static _get(key) { const v = localStorage.getItem(key); return v === null ? true : v === 'true'; }
    static getShowCert()  { return this._get(this.KEY_CERT); }
    static getShowAssic() { return this._get(this.KEY_ASSIC); }
    static getShowDoc()   { return this._get(this.KEY_DOC); }
    static getShowAnag()  { return this._get(this.KEY_ANAG); }
    static setShowCert(val)  { _lsSet(this.KEY_CERT,  val ? 'true' : 'false'); _upsertSetting(this.KEY_CERT,  val ? 'true' : 'false'); }
    static setShowAssic(val) { _lsSet(this.KEY_ASSIC, val ? 'true' : 'false'); _upsertSetting(this.KEY_ASSIC, val ? 'true' : 'false'); }
    static setShowDoc(val)   { _lsSet(this.KEY_DOC,   val ? 'true' : 'false'); _upsertSetting(this.KEY_DOC,   val ? 'true' : 'false'); }
    static setShowAnag(val)  { _lsSet(this.KEY_ANAG,  val ? 'true' : 'false'); _upsertSetting(this.KEY_ANAG,  val ? 'true' : 'false'); }
}

// Week template storage — 3 named standard week templates, one active
class WeekTemplateStorage {
    static KEY = 'gym_week_templates';
    static ACTIVE_KEY = 'gym_active_week_template';

    static _defaultTemplates() {
        return [
            { id: 1, name: 'Settimana Standard 1', schedule: JSON.parse(JSON.stringify(DEFAULT_WEEKLY_SCHEDULE)) },
            { id: 2, name: 'Settimana Standard 2', schedule: JSON.parse(JSON.stringify(DEFAULT_WEEKLY_SCHEDULE)) },
            { id: 3, name: 'Settimana Standard 3', schedule: JSON.parse(JSON.stringify(DEFAULT_WEEKLY_SCHEDULE)) },
        ];
    }

    static getAll() {
        const raw = localStorage.getItem(this.KEY);
        if (raw) {
            try { return JSON.parse(raw); } catch { /* corrupted */ }
        }
        const defaults = this._defaultTemplates();
        _lsSet(this.KEY, JSON.stringify(defaults));
        return defaults;
    }

    static save(templates) {
        _lsSet(this.KEY, JSON.stringify(templates));
        _upsertSetting(this.KEY, JSON.stringify(templates));
    }

    static getActiveId() {
        return parseInt(localStorage.getItem(this.ACTIVE_KEY) || '1', 10);
    }

    static setActiveId(id) {
        _lsSet(this.ACTIVE_KEY, String(id));
        _upsertSetting(this.ACTIVE_KEY, String(id));
        // Persisti il template attivo per il fallback legacy di getWeeklySchedule()
        const templates = this.getAll();
        const active = templates.find(t => t.id === id);
        if (active) {
            _lsSet('weeklyScheduleTemplate', JSON.stringify(active.schedule));
        }
    }

    static getActiveSchedule() {
        const templates = this.getAll();
        const activeId = this.getActiveId();
        const active = templates.find(t => t.id === activeId);
        return active ? active.schedule : DEFAULT_WEEKLY_SCHEDULE;
    }

    static updateTemplate(id, data) {
        const templates = this.getAll();
        const tpl = templates.find(t => t.id === id);
        if (!tpl) return;
        if (data.name !== undefined) tpl.name = data.name;
        if (data.schedule !== undefined) tpl.schedule = data.schedule;
        this.save(templates);
        // Se è il template attivo, aggiorna il fallback legacy in localStorage
        if (id === this.getActiveId()) {
            _lsSet('weeklyScheduleTemplate', JSON.stringify(tpl.schedule));
        }
    }
}

// User storage — client lookup for schedule management (Slot prenotato picker)
// Sources: registered accounts (gym_users) + unique clients from booking history (gym_bookings)
// Supabase migration: replace localStorage reads in getAll() with:
//   - supabaseClient.from('profiles').select('name, email, whatsapp')
//   - supabaseClient.from('bookings').select('name, email, whatsapp')
//   then apply the same dedup logic below
class UserStorage {
    static USERS_KEY = 'gym_users'; // managed by auth.js
    static _cache = []; // registered users cache (synced from Supabase profiles)

    // Sync incrementale (admin): fingerprint "<count>|<max updated_at>" dei profili → salta
    // il re-fetch (get_all_profiles) al wake quando nulla è cambiato. RLS limita il count
    // alla propria org. Reconcile periodico come safety net. Stesso schema di BookingStorage.
    static _profilesFingerprint = null;
    static _profilesLastFullFetch = 0;
    static _PROFILES_RECONCILE_MS = 5 * 60 * 1000;

    // ── Snapshot profili cross-pagina (egress: il TTL 5min vive solo in RAM, azzerato dalla
    //    navigazione MPA → ~260 profili rifetchati ad ogni pagina admin). Persistiamo la cache
    //    (org-scoped, admin-only) su localStorage così l'hydrate ad inizio pagina fa valere il
    //    TTL cross-pagina: dentro i 5min basta il fingerprint (1 query) invece del full. ─────
    static _USERS_SNAP_KEY = 'gym_users_cache_v1';
    static _usersSnapHydrated = false;

    static _persistUsersSnapshot() {
        try {
            if (typeof sessionStorage === 'undefined' || sessionStorage.getItem('adminAuth') !== 'true') return;
            // Non persistere una cache mai sincronizzata in pagina (un write dal modal cert su
            // cache vuota scriverebbe uno snapshot da 1 solo profilo, idratato dopo).
            if (!this._profilesLastFullFetch || !Array.isArray(this._cache) || !this._cache.length) return;
            const payload = {
                cache: this._cache,
                fp: this._profilesFingerprint,
                savedAt: this._profilesLastFullFetch,
                clearedAt: (typeof localStorage !== 'undefined' && localStorage.getItem('dataLastCleared')) || '0',
                org: (typeof window !== 'undefined' && window._orgId) ? window._orgId : 'anon',
            };
            _lsSetSnapshot(this._USERS_SNAP_KEY, JSON.stringify(payload));
        } catch (_) {}
    }
    static persistSnapshot() { this._persistUsersSnapshot(); }   // API pubblica per i write admin

    static _hydrateUsersSnapshot() {
        if (this._usersSnapHydrated) return;
        this._usersSnapHydrated = true;
        try {
            if (typeof sessionStorage === 'undefined' || sessionStorage.getItem('adminAuth') !== 'true') return;
            if (Array.isArray(this._cache) && this._cache.length) return;   // già popolata in pagina
            const raw = localStorage.getItem(this._USERS_SNAP_KEY);
            if (!raw) return;
            const snap = JSON.parse(raw);
            if (!snap || !Array.isArray(snap.cache) || !snap.cache.length) return;
            const org = (typeof window !== 'undefined' && window._orgId) ? window._orgId : 'anon';
            if (snap.org && snap.org !== org) return;                       // altro tenant
            const clearedAt = (typeof localStorage !== 'undefined' && localStorage.getItem('dataLastCleared')) || '0';
            if ((snap.clearedAt || '0') !== clearedAt) return;             // dati azzerati dopo lo snapshot
            if (!snap.savedAt || (Date.now() - snap.savedAt) > 24 * 60 * 60 * 1000) return;  // >24h
            this._cache = snap.cache;
            this._profilesFingerprint = snap.fp || null;
            this._profilesLastFullFetch = snap.savedAt;                    // TTL 5min valido cross-pagina
        } catch (_) {}
    }

    static async _profilesFingerprintFetch() {
        try {
            const { data, count, error } = await _queryWithTimeout(
                supabaseClient.from('profiles')
                    .select('updated_at', { count: 'exact' })
                    .order('updated_at', { ascending: false, nullsFirst: false })
                    .limit(1),
                10000
            );
            if (error) return null;
            const maxUpd = (data && data[0] && data[0].updated_at) || '';
            return `${count == null ? '?' : count}|${maxUpd}`;
        } catch (_) { return null; }
    }

    // Returns all known contacts: registered accounts first, then unique clients from booking history.
    // Deduplicates by email (case-insensitive) and phone (last 10 digits).
    static getAll() {
        this._hydrateUsersSnapshot();   // picker istantanei: cache pronta cross-pagina
        const seenEmails = new Set();
        const seenPhones = new Set();
        const result = [];

        // Last 10 digits of a phone — used for dedup comparison only
        const _normPhone = p => (p || '').replace(/\D/g, '').slice(-10);

        const _isDup = (email, whatsapp) => {
            const e = (email || '').toLowerCase().trim();
            const p = _normPhone(whatsapp);
            return (e && seenEmails.has(e)) || (p.length >= 9 && seenPhones.has(p));
        };

        const _mark = (email, whatsapp) => {
            const e = (email || '').toLowerCase().trim();
            const p = _normPhone(whatsapp);
            if (e) seenEmails.add(e);
            if (p.length >= 9) seenPhones.add(p);
        };

        const _add = (user) => {
            const { name, email, whatsapp } = user;
            if (!name || (!email && !whatsapp)) return;
            if (_isDup(email, whatsapp)) return;
            _mark(email, whatsapp);
            result.push({ ...user, email: email || '', whatsapp: whatsapp || '' });
        };

        // 1. Registered accounts (from cache) — highest priority
        this._cache.forEach(_add);

        // 2. Unique clients from booking history (from BookingStorage cache)
        BookingStorage._cache
            .filter(b => b.name && (b.email || b.whatsapp))
            .forEach(_add);

        return result.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
    }

    // Sincronizza gym_users localStorage dai profili Supabase.
    // Chiama get_all_profiles() (SECURITY DEFINER) — accessibile anche senza sessione auth.
    // Strategia di merge:
    //   - Dati anagrafici (name/email/whatsapp) da Supabase sono autoritativi
    //   - Dati cert/assicurazione locali hanno priorità (admin li aggiorna solo localmente)
    //   - Utenti solo locali (non registrati) vengono preservati
    static async syncUsersFromSupabase() {
        if (typeof supabaseClient === 'undefined') return;
        try {
            // Idrata lo snapshot cross-pagina PRIMA di decidere: così il fingerprint-skip
            // sotto vede una cache già popolata e un _profilesLastFullFetch recente.
            this._hydrateUsersSnapshot();
            // Fingerprint-skip: salta il re-fetch dei profili se nulla è cambiato (wake
            // veloce). Reconcile periodico (5 min) come safety net per il caso limite.
            const _reconcileDue = !this._profilesLastFullFetch || (Date.now() - this._profilesLastFullFetch > this._PROFILES_RECONCILE_MS);
            const _fp = await this._profilesFingerprintFetch();
            if (!_reconcileDue && _fp !== null && _fp === this._profilesFingerprint && this._cache.length > 0) {
                console.log('[Supabase] syncUsersFromSupabase: fingerprint invariato → skip');
                return;
            }
            // Prova la variante leggera get_all_profiles_basic (senza le history JSONB, mai
            // mostrate/scritte lato admin); se assente o in errore (migration non ancora
            // applicata) ricade sulla full → deploy sicuro in qualsiasi ordine. Le history
            // mancanti nel merge cadono su `existing` (cache locale preservata).
            let response = await _rpcWithTimeout(supabaseClient.rpc('get_all_profiles_basic')).catch(() => null);
            if (!response || response.error) {
                response = await _rpcWithTimeout(supabaseClient.rpc('get_all_profiles'));
            }
            const { data, error } = response || {};
            if (!response) {
                console.warn('[Supabase] syncUsersFromSupabase: risposta vuota, tengo cache corrente');
                return;
            }
            if (error) {
                console.error('[Supabase] syncUsersFromSupabase error:', error.message);
                return;
            }
            if (!data?.length) return;

            const local = this._cache;

            const normEmail = e => (e || '').toLowerCase().trim();
            const normPhone = p => (p || '').replace(/\D/g, '').slice(-10);

            // Indicizza utenti locali per email e telefono
            const localByEmail = new Map(
                local.filter(u => u.email).map(u => [normEmail(u.email), u])
            );
            const localByPhone = new Map(
                local.filter(u => normPhone(u.whatsapp).length >= 9)
                     .map(u => [normPhone(u.whatsapp), u])
            );

            const supabaseEmails = new Set();
            const supabasePhones = new Set();

            const merged = data.map(row => {
                const e = normEmail(row.email);
                const p = normPhone(row.whatsapp);
                const existing = (e && localByEmail.get(e)) || (p.length >= 9 && localByPhone.get(p)) || {};
                if (e) supabaseEmails.add(e);
                if (p.length >= 9) supabasePhones.add(p);
                return {
                    ...existing,
                    _fromSupabase: true,
                    userId:   row.id || existing.userId || null,
                    name:     row.name     || existing.name     || '',
                    email:    row.email    || existing.email    || '',
                    whatsapp: row.whatsapp || existing.whatsapp || '',
                    certificatoMedicoScadenza: row.medical_cert_expiry ?? existing.certificatoMedicoScadenza ?? null,
                    certificatoMedicoHistory: row.medical_cert_history || existing.certificatoMedicoHistory || [],
                    assicurazioneScadenza: row.insurance_expiry ?? existing.assicurazioneScadenza ?? null,
                    assicurazioneHistory: row.insurance_history || existing.assicurazioneHistory || [],
                    codiceFiscale: row.codice_fiscale ?? existing.codiceFiscale ?? null,
                    indirizzoVia: row.indirizzo_via ?? existing.indirizzoVia ?? null,
                    indirizzoPaese: row.indirizzo_paese ?? existing.indirizzoPaese ?? null,
                    indirizzoCap: row.indirizzo_cap ?? existing.indirizzoCap ?? null,
                    documentoFirmato: row.documento_firmato ?? existing.documentoFirmato ?? false,
                    privacyPrenotazioni: row.privacy_prenotazioni ?? existing.privacyPrenotazioni ?? false,
                    geoEnabled: row.geo_enabled ?? existing.geoEnabled ?? false,
                    pushEnabled: row.push_enabled ?? existing.pushEnabled ?? false,
                    archivedAt: row.archived_at ?? existing.archivedAt ?? null,
                };
            });

            // Mantieni solo utenti mai syncati da Supabase (clienti offline senza account)
            const localOnly = local.filter(u => {
                if (u._fromSupabase) return false;
                const e = normEmail(u.email);
                const p = normPhone(u.whatsapp);
                return !(e && supabaseEmails.has(e)) && !(p.length >= 9 && supabasePhones.has(p));
            });

            this._cache = [...merged, ...localOnly];
            this._profilesFingerprint = _fp;
            this._profilesLastFullFetch = Date.now();
            this._persistUsersSnapshot();   // aggiorna lo snapshot cross-pagina
            console.log(`[Supabase] syncUsersFromSupabase: ${data.length} da Supabase, ${localOnly.length} solo locali`);
        } catch (e) {
            console.error('[Supabase] syncUsersFromSupabase exception:', e);
        }
    }

    // Search by name, email, or whatsapp (min 2 chars)
    static search(query) {
        if (!query || query.trim().length < 2) return [];
        const q = query.trim().toLowerCase();
        return this.getAll().filter(u =>
            u.name?.toLowerCase().includes(q) ||
            u.email?.toLowerCase().includes(q) ||
            (u.whatsapp && u.whatsapp.replace(/\s/g, '').includes(q.replace(/\s/g, '')))
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// WorkoutPlanStorage — Schede palestra
// ═══════════════════════════════════════════════════════════════════════════════
class WorkoutPlanStorage {
    static _cache = [];           // array of plan objects with nested exercises
    static _syncInFlightByMode = {};

    static _LS_TTL_MS = 30 * 60 * 1000;
    // TTL di RETE: la query (join workout_exercises su tutti i piani) è pesante e
    // partirebbe ad ogni renderSchedeTab. La ri-eseguiamo al massimo ogni _NET_TTL_MS;
    // i CRUD aggiornano _cache localmente, quindi le modifiche admin si vedono subito.
    static _NET_TTL_MS = 300000; // 5 min
    static _lastSyncAtByMode = { admin: 0, client: 0 };
    static _lsKey(adminMode) { return `workout_plans_cache_${adminMode ? 'admin' : 'client'}_v1`; }
    static _loadFromLocalStorage(adminMode) {
        if (this._cache.length > 0) return false;
        try {
            const raw = localStorage.getItem(this._lsKey(adminMode));
            if (!raw) return false;
            const parsed = JSON.parse(raw);
            if (!parsed || !parsed.ts || Date.now() - parsed.ts > this._LS_TTL_MS) return false;
            if (!Array.isArray(parsed.data)) return false;
            this._cache = parsed.data;
            console.log(`[Supabase] WorkoutPlanStorage: cache localStorage (${this._cache.length} piani, ${Math.round((Date.now()-parsed.ts)/60000)}min fa)`);
            return true;
        } catch { return false; }
    }
    static _saveToLocalStorage(adminMode) {
        _lsSetSnapshot(this._lsKey(adminMode), JSON.stringify({ ts: Date.now(), data: this._cache }));
    }

    // Teardown logout (H2): svuota la cache in memoria + le chiavi localStorage TTL
    // (admin e client) → piani/log dei clienti dell'org A non più visibili all'org B.
    static clearCache() {
        this._cache = [];
        this._syncInFlightByMode = {};
        this._lastSyncAtByMode = { admin: 0, client: 0 };
        try { localStorage.removeItem(this._lsKey(true)); } catch (_) {}
        try { localStorage.removeItem(this._lsKey(false)); } catch (_) {}
    }

    static getAllPlans() { return this._cache; }

    static getPlansByUser(userId) {
        return this._cache.filter(p => p.user_id === userId);
    }

    static getActivePlan(userId) {
        return this._cache.find(p => p.user_id === userId && p.active);
    }

    static getPlanById(planId) {
        return this._cache.find(p => p.id === planId);
    }

    // Admin: fetch all plans with nested exercises
    // Client: fetch only own active plan(s)
    static async syncFromSupabase({ adminMode = false, force = false } = {}) {
        if (typeof supabaseClient === 'undefined') return;
        this._loadFromLocalStorage(adminMode);
        const syncKey = adminMode ? 'admin' : 'client';
        if (this._syncInFlightByMode[syncKey]) return this._syncInFlightByMode[syncKey];
        // TTL di rete: salta il re-fetch (join pesante) se la cache è popolata e l'ultimo
        // fetch è recente. force lo bypassa (refresh espliciti).
        if (!force && this._cache.length && (Date.now() - (this._lastSyncAtByMode[syncKey] || 0) < this._NET_TTL_MS)) return;
        this._syncInFlightByMode[syncKey] = (async () => {
            let query = supabaseClient
                .from('workout_plans')
                .select('*, workout_exercises(*)');

            if (!adminMode) {
                // Client: only own active plans
                const user = typeof getCurrentUser === 'function' ? getCurrentUser() : null;
                if (!user) return;
                query = query.eq('user_id', user.id).eq('active', true);
            }
            query = query.order('updated_at', { ascending: false });

            // Timeout 30s: query pesante (join workout_exercises su tutti i piani).
            // In admin mode carica 30+ piani e puo' superare i 12s di default.
            const response = await _queryWithTimeout(query, 30000);
            const { data, error } = response || {};
            if (!response) {
                console.warn('[Supabase] WorkoutPlanStorage.sync: risposta vuota, tengo cache corrente');
                return;
            }
            if (error) { console.error('[Supabase] WorkoutPlanStorage.sync error:', error.message); return; }

            // Sort exercises within each plan by sort_order
            for (const plan of (data || [])) {
                if (plan.workout_exercises) {
                    plan.workout_exercises.sort((a, b) => a.sort_order - b.sort_order);
                }
            }
            this._cache = data || [];
            this._saveToLocalStorage(adminMode);
            this._lastSyncAtByMode[syncKey] = Date.now(); // marker TTL di rete
            console.log(`[Supabase] WorkoutPlanStorage.sync: ${this._cache.length} piani caricati`);
        })();
        try { return await this._syncInFlightByMode[syncKey]; }
        catch (e) { console.error('[Supabase] WorkoutPlanStorage.sync exception:', e); }
        finally { delete this._syncInFlightByMode[syncKey]; }
    }

    // ── CRUD Plans ───────────────────────────────────────────────────────────
    // Tutte le CRUD usano _queryWithTimeout(15000): senza timeout, in caso di
    // auth lock contention o rete lenta le insert/update/delete restavano
    // appese indefinitamente, lasciando l'utente senza feedback (es. click
    // "Aggiungi Esercizio" che non aggiungeva nulla, niente toast, niente errore).
    static async createPlan({ user_id, name, start_date, end_date, notes }) {
        const { data, error } = await _queryWithTimeout(supabaseClient
            .from('workout_plans')
            .insert({ user_id, name, start_date: start_date || null, end_date: end_date || null, notes: notes || null, active: true })
            .select()
            .single(), 15000);
        if (error) throw error;
        data.workout_exercises = [];
        this._cache.unshift(data);
        return data;
    }

    static async updatePlan(planId, updates) {
        const { error } = await _queryWithTimeout(supabaseClient
            .from('workout_plans')
            .update(updates)
            .eq('id', planId), 15000);
        if (error) throw error;
        const idx = this._cache.findIndex(p => p.id === planId);
        if (idx >= 0) Object.assign(this._cache[idx], updates);
    }

    static async deletePlan(planId) {
        const { error } = await _queryWithTimeout(supabaseClient
            .from('workout_plans')
            .delete()
            .eq('id', planId), 15000);
        if (error) throw error;
        this._cache = this._cache.filter(p => p.id !== planId);
    }

    static async duplicatePlan(planId, newUserId, newName) {
        const { data, error } = await _rpcWithTimeout(
            supabaseClient.rpc('admin_duplicate_plan', {
                p_plan_id: planId,
                p_new_user_id: newUserId,
                p_new_name: newName || null,
            })
        );
        if (error) throw error;
        await this.syncFromSupabase({ adminMode: true });
        return data; // new plan id
    }

    // ── CRUD Exercises ───────────────────────────────────────────────────────
    static async addExercise(planId, exerciseData) {
        const plan = this.getPlanById(planId);
        // Se sort_order non è passato esplicitamente, leggi il max reale dal DB
        let maxOrder = -1;
        if (exerciseData.sort_order == null) {
            try {
                const { data: lastEx } = await _queryWithTimeout(
                    supabaseClient
                        .from('workout_exercises')
                        .select('sort_order')
                        .eq('plan_id', planId)
                        .order('sort_order', { ascending: false })
                        .limit(1)
                        .maybeSingle(),
                    15000
                );
                maxOrder = lastEx?.sort_order ?? -1;
            } catch (_) {
                // Fallback: cache locale se la query fallisce
                maxOrder = plan?.workout_exercises?.reduce((m, e) => Math.max(m, e.sort_order ?? -1), -1) ?? -1;
            }
        }
        const row = {
            plan_id: planId,
            day_label: exerciseData.day_label || 'Giorno A',
            exercise_name: exerciseData.exercise_name,
            exercise_slug: exerciseData.exercise_slug || null,
            muscle_group: exerciseData.muscle_group || null,
            sort_order: exerciseData.sort_order ?? (maxOrder + 1),
            sets: exerciseData.sets || 3,
            reps: exerciseData.reps || '10',
            weight_kg: exerciseData.weight_kg ?? null,
            rest_seconds: exerciseData.rest_seconds ?? 90,
            notes: exerciseData.notes || null,
            superset_group: exerciseData.superset_group || null,
            circuit_group: exerciseData.circuit_group || null,
        };
        const { data, error } = await _queryWithTimeout(supabaseClient
            .from('workout_exercises')
            .insert(row)
            .select()
            .single(), 15000);
        if (error) throw error;
        if (plan) {
            plan.workout_exercises = plan.workout_exercises || [];
            plan.workout_exercises.push(data);
        }
        return data;
    }

    // Add a superset pair (two exercises linked by the same superset_group UUID)
    // Caller can pass sort_order in ex1Data/ex2Data to force placement;
    // otherwise maxOrder is computed from cache, or (fallback) fetched from Supabase.
    static async addSuperset(planId, ex1Data, ex2Data) {
        let maxOrder = -1;
        if (ex1Data.sort_order == null || ex2Data.sort_order == null) {
            // Sempre dal DB per evitare sort_order stale da cache locale
            try {
                const { data: lastEx } = await _queryWithTimeout(
                    supabaseClient
                        .from('workout_exercises')
                        .select('sort_order')
                        .eq('plan_id', planId)
                        .order('sort_order', { ascending: false })
                        .limit(1)
                        .maybeSingle(),
                    15000
                );
                maxOrder = lastEx?.sort_order ?? -1;
            } catch (_) {
                // Fallback: cache locale
                const plan = this.getPlanById(planId);
                if (plan && Array.isArray(plan.workout_exercises) && plan.workout_exercises.length > 0) {
                    maxOrder = plan.workout_exercises.reduce((m, e) => Math.max(m, e.sort_order ?? -1), -1);
                }
            }
        }
        const groupId = crypto.randomUUID();
        const so1 = ex1Data.sort_order != null ? ex1Data.sort_order : (maxOrder + 1);
        const so2 = ex2Data.sort_order != null ? ex2Data.sort_order : (maxOrder + 2);
        // First exercise: no rest (done back-to-back)
        const first = await this.addExercise(planId, {
            ...ex1Data,
            sort_order: so1,
            rest_seconds: 0,
            superset_group: groupId,
        });
        // Second exercise: has the actual rest
        const second = await this.addExercise(planId, {
            ...ex2Data,
            sort_order: so2,
            superset_group: groupId,
        });
        return { first, second, superset_group: groupId };
    }

    // Add a circuit (N>=2 exercises sharing the same circuit_group UUID).
    // Tutti gli esercizi hanno lo stesso `sets` (= numero di giri).
    // Solo l'ultimo per sort_order ha `rest_seconds > 0` (pausa fine giro).
    // I sort_order vengono assegnati incrementalmente partendo dal max attuale.
    static async addCircuit(planId, items) {
        if (!Array.isArray(items) || items.length < 2) {
            throw new Error('addCircuit: servono almeno 2 esercizi');
        }
        // maxOrder calcolato UNA volta (stesso pattern di addSuperset): senza sort_order
        // esplicito ogni addExercise farebbe la propria SELECT max → 2N round-trip.
        let maxOrder = -1;
        if (items.some(it => it.sort_order == null)) {
            try {
                const { data: lastEx } = await _queryWithTimeout(
                    supabaseClient
                        .from('workout_exercises')
                        .select('sort_order')
                        .eq('plan_id', planId)
                        .order('sort_order', { ascending: false })
                        .limit(1)
                        .maybeSingle(),
                    15000
                );
                maxOrder = lastEx?.sort_order ?? -1;
            } catch (_) {
                const plan = this.getPlanById(planId);
                maxOrder = plan?.workout_exercises?.reduce((m, e) => Math.max(m, e.sort_order ?? -1), -1) ?? -1;
            }
        }
        const groupId = crypto.randomUUID();
        const inserted = [];
        for (let i = 0; i < items.length; i++) {
            const row = await this.addExercise(planId, {
                ...items[i],
                sort_order: items[i].sort_order != null ? items[i].sort_order : (maxOrder + 1 + i),
                circuit_group: groupId,
            });
            inserted.push(row);
        }
        return { items: inserted, circuit_group: groupId };
    }

    static async updateExercise(exerciseId, updates) {
        const { error } = await _queryWithTimeout(supabaseClient
            .from('workout_exercises')
            .update(updates)
            .eq('id', exerciseId), 15000);
        if (error) throw error;
        // Update cache
        for (const plan of this._cache) {
            const ex = (plan.workout_exercises || []).find(e => e.id === exerciseId);
            if (ex) { Object.assign(ex, updates); break; }
        }
    }

    static async deleteExercise(exerciseId) {
        const { error } = await _queryWithTimeout(supabaseClient
            .from('workout_exercises')
            .delete()
            .eq('id', exerciseId), 15000);
        if (error) throw error;
        for (const plan of this._cache) {
            plan.workout_exercises = (plan.workout_exercises || []).filter(e => e.id !== exerciseId);
        }
    }

    // Cancellazione batch: una sola DELETE .in('id',...) invece di N round-trip
    // seriali (usata per rimozione giorno/super serie/circuito in admin-schede.js).
    static async deleteExercises(exerciseIds) {
        const ids = (exerciseIds || []).filter(Boolean);
        if (!ids.length) return;
        const { error } = await _queryWithTimeout(supabaseClient
            .from('workout_exercises')
            .delete()
            .in('id', ids), 15000);
        if (error) throw error;
        const idSet = new Set(ids);
        for (const plan of this._cache) {
            plan.workout_exercises = (plan.workout_exercises || []).filter(e => !idSet.has(e.id));
        }
    }

    static async reorderExercises(planId, orderedIds) {
        // Riordina SOLO gli esercizi passati (di norma quelli di un singolo giorno del
        // piano multi-giorno). La vecchia versione riscriveva sort_order da 0..N-1 sui
        // soli id del giorno attivo → collideva con gli altri giorni. Ora la nuova
        // numerazione parte dal MINIMO sort_order tra gli esercizi riordinati, così
        // resta nel loro intervallo e non tocca gli altri giorni.
        const plan = this.getPlanById(planId);
        const planExs = plan?.workout_exercises || [];
        const reordered = orderedIds.map(id => planExs.find(e => e.id === id)).filter(Boolean);
        const base = reordered.length
            ? Math.min(...reordered.map(e => (typeof e.sort_order === 'number' ? e.sort_order : 0)))
            : 0;
        const updates = orderedIds.map((id, i) => ({ id, sort_order: base + i }));
        for (const u of updates) {
            await _queryWithTimeout(supabaseClient.from('workout_exercises').update({ sort_order: u.sort_order }).eq('id', u.id), 15000);
            const ex = planExs.find(e => e.id === u.id);
            if (ex) ex.sort_order = u.sort_order;
        }
        // Riordina l'INTERO piano per sort_order (tutti i giorni), non solo il giorno mosso.
        if (plan && plan.workout_exercises) {
            plan.workout_exercises.sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
        }
    }

}

// ═══════════════════════════════════════════════════════════════════════════════
// WorkoutLogStorage — Log allenamenti clienti
// ═══════════════════════════════════════════════════════════════════════════════
class WorkoutLogStorage {
    static _cache = [];

    // Teardown logout (H2): svuota la cache log in memoria (nessuna persistenza LS).
    static clearCache() { this._cache = []; }

    static getAll() { return this._cache; }

    static getByExercise(exerciseId) {
        return this._cache.filter(l => l.exercise_id === exerciseId);
    }

    static getByDate(logDate) {
        return this._cache.filter(l => l.log_date === logDate);
    }

    // Fetch logs for a specific plan (all exercises)
    static async syncForPlan(planId) {
        if (typeof supabaseClient === 'undefined') return;
        try {
            const plan = WorkoutPlanStorage.getPlanById(planId);
            if (!plan || !plan.workout_exercises?.length) { this._cache = []; return; }
            const exIds = plan.workout_exercises.map(e => e.id);
            // Paginato: c'è UNA riga per ogni serie loggata → un cliente assiduo supera il cap di
            // ~1000 righe di PostgREST in pochi mesi e i log più vecchi sparivano dallo storico.
            // Tiebreaker .order('id') = pagine stabili (log_date/set_number non sono univoci).
            const { data, error } = await fetchAllPaginated(() => supabaseClient
                .from('workout_logs')
                .select('id,exercise_id,user_id,log_date,set_number,reps_done,weight_done,rest_done,rpe,notes')
                .in('exercise_id', exIds)
                .order('log_date', { ascending: false })
                .order('set_number', { ascending: true })
                .order('id'));
            if (error) { console.error('[Supabase] WorkoutLogStorage.sync error:', error.message); return; }
            this._cache = data || [];
            console.log(`[Supabase] WorkoutLogStorage.sync: ${this._cache.length} log caricati`);
        } catch (e) { console.error('[Supabase] WorkoutLogStorage.sync exception:', e); }
    }

    // Fetch ALL logs for a user (for charts across plans)
    static async syncForUser(userId) {
        if (typeof supabaseClient === 'undefined') return;
        try {
            // Paginato (cap ~1000 righe PostgREST): una riga per serie → lo storico vecchio veniva
            // troncato. Tiebreaker .order('id') = pagine stabili.
            const { data, error } = await fetchAllPaginated(() => supabaseClient
                .from('workout_logs')
                .select('id,exercise_id,user_id,log_date,set_number,reps_done,weight_done,rest_done,rpe,notes')
                .eq('user_id', userId)
                .order('log_date', { ascending: false })
                .order('set_number', { ascending: true })
                .order('id'));
            if (error) { console.error('[Supabase] WorkoutLogStorage.syncUser error:', error.message); return; }
            this._cache = data || [];
        } catch (e) { console.error('[Supabase] WorkoutLogStorage.syncUser exception:', e); }
    }

    // Insert or update (upsert on unique constraint)
    static async logSet({ exercise_id, user_id, log_date, set_number, reps_done, weight_done, rpe, rest_done, notes }) {
        const row = {
            exercise_id, user_id,
            log_date: log_date || _localDateStr(),
            set_number,
            reps_done: reps_done ?? null,
            weight_done: weight_done ?? null,
            rpe: rpe ?? null,
            rest_done: rest_done ?? null,
            notes: notes || null,
        };
        const { data, error } = await _queryWithTimeout(supabaseClient
            .from('workout_logs')
            .upsert(row, { onConflict: 'exercise_id,user_id,log_date,set_number' })
            .select()
            .single(), 15000);
        if (error) throw error;
        // Update cache
        const idx = this._cache.findIndex(l =>
            l.exercise_id === exercise_id && l.log_date === row.log_date && l.set_number === set_number
        );
        if (idx >= 0) this._cache[idx] = data;
        else this._cache.push(data);
        return data;
    }

    // Delete a single log entry
    static async deleteLog(logId) {
        const { error } = await _queryWithTimeout(supabaseClient
            .from('workout_logs')
            .delete()
            .eq('id', logId), 15000);
        if (error) throw error;
        this._cache = this._cache.filter(l => l.id !== logId);
    }
}

// processPendingCancellations() è chiamata solo da pagine admin (admin.js).
// Il pg_cron server-side (job "process-pending-cancellations", ogni 15 min) è la fonte autorevole.
// NON chiamare da pagine utente: replaceAllBookings usa admin_update_booking RPC che richiede is_admin().
