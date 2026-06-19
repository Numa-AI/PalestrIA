// ═══════════════════════════════════════════════════════════════════════════════
// TAB SCHEDE — Gestione schede palestra (workout plans)
// ═══════════════════════════════════════════════════════════════════════════════

// ── Exercise catalog from imported_exercises (Supabase) ─────────────────────
let EXERCISES_DB = [];          // populated by _loadExercisesDB()
let EXERCISES_BY_CAT = {};      // { 'Petto': [...], ... }
let EXERCISE_CATEGORIES = [];   // unique sorted categories
let _exercisesDBLoaded = false;
let _loadExercisesDBPromise = null; // singleton: evita query concorrenti

// localStorage cache: imported_exercises cambia raramente (solo da tab Importa).
// TTL 6h — se admin apre/chiude admin.html più volte nella sessione lavorativa,
// non rifacciamo mai la query da 30s. Invalidazione esplicita su import/remove.
const _EXDB_LS_KEY = 'schede_exercises_db_v1';
const _EXDB_LS_TTL_MS = 6 * 60 * 60 * 1000;

function _populateExercisesFromRaw(rawData) {
    EXERCISES_DB = rawData.map(e => ({
        nome_it: e.nome_it,
        nome_original: e.nome_original || '',
        nome_en: e.nome_en || '',
        categoria: e.categoria,
        slug: e.slug,
        immagine_url: e.immagine || '',
        immagine_url_small: e.immagine_thumbnail || e.immagine || '',
        video_url: e.video || '',
        popolarita: e.popolarita || 0
    }));
    EXERCISES_BY_CAT = {};
    for (const ex of EXERCISES_DB) {
        if (!EXERCISES_BY_CAT[ex.categoria]) EXERCISES_BY_CAT[ex.categoria] = [];
        EXERCISES_BY_CAT[ex.categoria].push(ex);
    }
    EXERCISE_CATEGORIES = Object.keys(EXERCISES_BY_CAT).sort();
}

async function _loadExercisesDB() {
    if (_exercisesDBLoaded) return;
    if (_loadExercisesDBPromise) return _loadExercisesDBPromise;
    _loadExercisesDBPromise = (async () => {
        try {
            // 1. Prima cache in-memory dalla tab Importa (se già caricata)
            let rawData = null;
            if (typeof _importaImportedLoaded !== 'undefined' && _importaImportedLoaded) {
                rawData = _importaImported;
            }
            // 2. Poi cache localStorage (evita 30s di query su admin.html quando
            //    la rete è satura dagli altri sync iniziali)
            let fromLocalStorage = false;
            if (!rawData) {
                try {
                    const raw = localStorage.getItem(_EXDB_LS_KEY);
                    if (raw) {
                        const parsed = JSON.parse(raw);
                        if (parsed && parsed.ts && Date.now() - parsed.ts < _EXDB_LS_TTL_MS && Array.isArray(parsed.data)) {
                            rawData = parsed.data;
                            fromLocalStorage = true;
                            console.log(`[Schede] _loadExercisesDB: da localStorage (${rawData.length} esercizi, ${Math.round((Date.now()-parsed.ts)/60000)}min fa)`);
                        }
                    }
                } catch (e) { /* cache corrotta: ignora */ }
            }
            // 3. Infine fetch da Supabase (paginato: con "Importa tutti" la tabella
            //    può superare il limite di ~1000 righe di PostgREST)
            if (!rawData) {
                const { data, error } = await fetchAllPaginated(() => supabaseClient
                    .from('imported_exercises')
                    .select('slug, nome_it, nome_original, nome_en, categoria, immagine, immagine_thumbnail, video, popolarita')
                    .order('categoria')
                    .order('nome_it'), { timeoutMs: 30000 });
                if (error) throw error;
                rawData = data || [];
                try { localStorage.setItem(_EXDB_LS_KEY, JSON.stringify({ ts: Date.now(), data: rawData })); } catch (e) { /* quota: ignora */ }
            }
            // Propaga anche alla cache di Importa se non è ancora popolata: così
            // aprire la tab Importa dopo aver aperto Schede non rifà la query.
            if (typeof _importaImportedLoaded !== 'undefined' && !_importaImportedLoaded) {
                _importaImported = rawData;
                _importaImportedSlugs = new Set(rawData.map(e => e.slug));
                _importaImportedLoaded = true;
            }
            _populateExercisesFromRaw(rawData);
            _exercisesDBLoaded = true;
        } catch (e) { console.error('[Schede] Failed to load exercises DB:', e); }
    })();
    try { await _loadExercisesDBPromise; } finally { _loadExercisesDBPromise = null; }
}

// Refresh after import/remove in Importa tab
async function _refreshSchedeFromImported() {
    _exercisesDBLoaded = false;
    try { localStorage.removeItem(_EXDB_LS_KEY); } catch (e) { /* noop */ }
    await _loadExercisesDB();
}

function _findExercise(name) {
    if (!name) return null;
    return EXERCISES_DB.find(e => e.nome_it === name)
        || EXERCISES_DB.find(e => e.nome_original === name)
        || null;
}

function _findExerciseForCard(ex) {
    if (ex.exercise_slug) {
        const bySlug = EXERCISES_DB.find(e => e.slug === ex.exercise_slug);
        if (bySlug) return bySlug;
    }
    return _findExercise(ex.exercise_name);
}

function _schedeCleanupPickerScroll() {
    // Se è aperto l'overlay edit mobile, NON resettare l'overflow del body
    // (l'overlay full-screen ha già bloccato lo scroll e ci serve così)
    const mobileOverlay = document.getElementById('admMobEditOverlay');
    if (!mobileOverlay) document.body.style.overflow = '';
    const backdrop = document.getElementById('schedePickerBackdrop');
    if (backdrop) backdrop.remove();
}

// Close open pickers on outside click
// Aggiunti contesti per il picker aperto dentro l'overlay edit mobile
// (.adm-mob-edit-picker-wrap) e per le righe del circuito (.adm-mob-cc-row).
// Senza questi, cliccare una categoria/esercizio dentro l'edit mobile chiudeva
// subito il picker.
document.addEventListener('click', (e) => {
    const isInsidePickerCtx =
        e.target.closest('.schede-ex-picker-wrap') ||
        e.target.closest('.schede-picker-backdrop') ||
        e.target.closest('.schede-ex-picker-dropdown') ||
        e.target.closest('.adm-mob-edit-picker-wrap') ||
        e.target.closest('.adm-mob-cc-row');
    if (!isInsidePickerCtx) {
        document.querySelectorAll('.schede-ex-picker-dropdown').forEach(d => d.style.display = 'none');
        _schedeCleanupPickerScroll();
    }
});

// ── Exercise picker (replaces old select dropdowns) ──────────────────────────
// Opens a search-panel inline within the exercise row

function _schedeOpenPicker(exId) {
    // Close any other open picker
    document.querySelectorAll('.schede-ex-picker-dropdown').forEach(d => { if (d.id !== 'picker-' + exId) d.style.display = 'none'; });

    const dropdown = document.getElementById('picker-' + exId);
    if (!dropdown) return;
    if (dropdown.style.display === 'flex') { dropdown.style.display = 'none'; _schedeCleanupPickerScroll(); return; }

    // Category → SVG icon map
    const catSvg = {
        'Petto': 'chest', 'Tricipiti': 'triceps', 'Bicipiti': 'biceps', 'Braccia': 'biceps',
        'Spalle': 'shoulders', 'Schiena': 'back', 'Quadricipiti': 'quadriceps',
        'Glutei e Femorali': 'hips', 'Femorali': 'hamstrings', 'Polpacci': 'calves',
        'Addominali': 'waist_abs', 'Avambracci': 'forearms', 'Cardio': 'cardio'
    };

    // Build picker content
    let html = `<div class="schede-picker-topbar">
        <span class="schede-picker-title">Seleziona esercizio</span>
        <button type="button" class="schede-picker-close-btn" onclick="_schedeClosePicker('${exId}')">&times;</button>
    </div>
    <div class="schede-picker-header">
        <input type="text" class="schede-picker-search" placeholder="Cerca esercizio..."
               oninput="_schedeFilterPicker('${exId}', this.value)" autofocus>
    </div>
    <div class="schede-picker-body" id="pickerBody-${exId}">
        <div class="schede-picker-cats" id="pickerCats-${exId}">
            ${EXERCISE_CATEGORIES.map(c => {
                const svg = catSvg[c] || 'chest';
                return `
                <button type="button" class="schede-picker-cat-chip" onclick="_schedePickCat('${exId}','${_escHtml(c)}')" data-cat="${_escHtml(c)}">
                    <img src="images/icone_muscoli/${svg}.svg" class="schede-picker-cat-icon" alt="">
                    <span class="schede-picker-cat-name">${_escHtml(c)}</span>
                    <span class="schede-picker-cat-count">${(EXERCISES_BY_CAT[c] || []).length}</span>
                </button>`;
            }).join('')}
        </div>
        <div class="schede-picker-list" id="pickerList-${exId}" style="display:none;"></div>
    </div>
    <div class="schede-picker-footer">
        <button type="button" class="schede-picker-custom-btn" onclick="_schedePickCustom('${exId}')">✏️ Personalizzato</button>
    </div>`;
    dropdown.innerHTML = html;
    dropdown.style.display = 'flex';
    document.body.style.overflow = 'hidden';

    // Add backdrop overlay on desktop
    let backdrop = document.getElementById('schedePickerBackdrop');
    if (!backdrop) {
        backdrop = document.createElement('div');
        backdrop.id = 'schedePickerBackdrop';
        backdrop.className = 'schede-picker-backdrop';
        backdrop.onclick = () => _schedeClosePicker(exId);
        document.body.appendChild(backdrop);
    }

    // Focus search
    const searchInput = dropdown.querySelector('.schede-picker-search');
    if (searchInput) setTimeout(() => searchInput.focus(), 50);
}

function _schedeClosePicker(exId) {
    const dropdown = document.getElementById('picker-' + exId);
    if (dropdown) dropdown.style.display = 'none';
    // Picker standalone del mobile editor: anche l'host wrapper va rimosso.
    if (typeof exId === 'string' && exId.startsWith('__new_')) {
        const host = document.getElementById('admMobNewExPickerHost');
        if (host) host.remove();
    }
    _schedeCleanupPickerScroll();
}

// Select a category → show exercises for that category
function _schedePickCat(exId, cat) {
    const dropdown = document.getElementById('picker-' + exId);
    if (!dropdown) return;

    // Highlight active chip
    dropdown.querySelectorAll('.schede-picker-cat-chip').forEach(ch => {
        ch.classList.toggle('active', ch.dataset.cat === cat);
    });

    _schedeRenderExercises(exId, cat, '');
}

function _schedeFilterPicker(exId, searchText) {
    const dropdown = document.getElementById('picker-' + exId);
    if (!dropdown) return;
    const search = (searchText ?? dropdown.querySelector('.schede-picker-search')?.value ?? '').toLowerCase();

    // Find active category chip
    const activeChip = dropdown.querySelector('.schede-picker-cat-chip.active');
    const cat = activeChip ? activeChip.dataset.cat : '';

    if (!search && !cat) {
        // No search, no category → show category grid
        const catsEl = document.getElementById('pickerCats-' + exId);
        const listEl = document.getElementById('pickerList-' + exId);
        if (catsEl) catsEl.style.display = '';
        if (listEl) listEl.style.display = 'none';
        return;
    }

    _schedeRenderExercises(exId, cat, search);
}

function _schedeRenderExercises(exId, cat, search) {
    const catsEl = document.getElementById('pickerCats-' + exId);
    const listEl = document.getElementById('pickerList-' + exId);
    if (!listEl) return;

    // Hide categories, show list
    if (catsEl) catsEl.style.display = 'none';
    listEl.style.display = '';

    let exercises = EXERCISES_DB;
    if (cat) exercises = exercises.filter(e => e.categoria === cat);
    if (search) exercises = exercises.filter(e =>
        e.nome_it.toLowerCase().includes(search) || e.nome_en.toLowerCase().includes(search) || e.categoria.toLowerCase().includes(search)
    );

    if (exercises.length === 0) {
        listEl.innerHTML = '<div class="schede-picker-empty">Nessun esercizio trovato</div>';
        return;
    }

    // Limit to 50 for performance
    const shown = exercises.slice(0, 50);
    listEl.innerHTML = shown.map(ex => `
        <div class="schede-picker-item">
            <img src="${_escHtml(ex.immagine_url_small)}" class="schede-picker-item-img" alt="" loading="lazy">
            <div class="schede-picker-item-info" onclick="_schedePickExercise('${exId}', '${_escHtml(ex.nome_it).replace(/'/g, "\\'")}')">
                <span class="schede-picker-item-name">${_escHtml(ex.nome_it)}</span>
                <span class="schede-picker-item-cat">${_escHtml(ex.categoria)}</span>
            </div>
            ${ex.video_url ? `<button class="schede-picker-item-video" onclick="event.stopPropagation();_schedeShowExDetail('${_escHtml(ex.slug)}')" title="Video">&#9654;</button>` : ''}
        </div>
    `).join('') + (exercises.length > 50 ? `<div class="schede-picker-more">${exercises.length - 50} altri — affina la ricerca</div>` : '');
}

async function _schedePickExercise(exId, exerciseName) {
    // Picker-first flow: il mobile editor apre il picker con un pseudo-id
    // "__new_*" per dirottare la creazione invece dell'update di uno esistente.
    if (typeof exId === 'string' && exId.startsWith('__new_')) {
        return _admMobCreateExFromPicker(exId, exerciseName);
    }
    const ex = _findExercise(exerciseName);
    // Build all updates in one batch
    const updates = { exercise_name: exerciseName };
    if (ex) {
        updates.exercise_slug = ex.slug;
        updates.muscle_group = ex.categoria;
        // Cardio: set time-based defaults
        if ((ex.categoria || '').toLowerCase() === 'cardio') {
            updates.sets = 1;
            updates.reps = '20';
            updates.rest_seconds = 0;
        }
    }
    try {
        await WorkoutPlanStorage.updateExercise(exId, updates);
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore aggiornamento', 'error');
    }

    // Close picker and re-render row
    const dropdown = document.getElementById('picker-' + exId);
    if (dropdown) dropdown.style.display = 'none';
    _schedeCleanupPickerScroll();

    // Full re-render to update params layout (cardio vs strength)
    _schedeRefreshEditor();
}

async function _schedePickCustom(exId) {
    // Mobile picker-first: nome via prompt, poi delega a _admMobCreateExFromPicker
    if (typeof exId === 'string' && exId.startsWith('__new_')) {
        const name = await showPrompt('Nome esercizio personalizzato:', '', { confirmText: 'Aggiungi' });
        const trimmed = (name || '').trim();
        const host = document.getElementById('admMobNewExPickerHost');
        if (host) host.remove();
        _schedeCleanupPickerScroll();
        if (!trimmed) return;
        return _admMobCreateExFromPicker(exId, trimmed);
    }
    const dropdown = document.getElementById('picker-' + exId);
    if (dropdown) dropdown.style.display = 'none';
    _schedeCleanupPickerScroll();

    try {
        await WorkoutPlanStorage.updateExercise(exId, { exercise_name: '', exercise_slug: null });
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore aggiornamento', 'error');
    }

    const row = document.querySelector(`.schede-exercise-row[data-ex-id="${exId}"]`);
    if (row) {
        const pickerWrap = row.querySelector('.schede-ex-picker-wrap');
        if (pickerWrap) {
            // Show custom input
            let html = '<div class="schede-ex-picker-wrap">';
            html += `<div class="schede-ex-selected" data-ex-id="${exId}">`;
            html += `<div class="schede-ex-thumb schede-ex-thumb--empty" onclick="_schedeOpenPicker('${exId}')"></div>`;
            html += `<span class="schede-ex-chosen-name" onclick="_schedeOpenPicker('${exId}')"><em>Personalizzato</em></span>`;
            html += `<button type="button" class="schede-ex-change-btn" onclick="_schedeOpenPicker('${exId}')" title="Cambia esercizio">&#9998;</button>`;
            html += '</div>';
            html += `<input type="text" class="schede-ex-custom-name" value="" placeholder="Nome personalizzato"
                            onchange="_schedeUpdateExField('${exId}','exercise_name',this.value)" autofocus>`;
            html += `<div class="schede-ex-picker-dropdown" id="picker-${exId}" style="display:none;"></div>`;
            html += '</div>';
            const tempDiv = document.createElement('div');
            tempDiv.innerHTML = html;
            pickerWrap.replaceWith(tempDiv.firstElementChild);
            const customInput = row.querySelector('.schede-ex-custom-name');
            if (customInput) setTimeout(() => customInput.focus(), 50);
        }
    }
}

// ── Exercise detail popup (video + image) ────────────────────────────────────
function _schedeShowExDetail(slug) {
    const ex = EXERCISES_DB.find(e => e.slug === slug);
    if (!ex) return;

    // Remove existing popup if any
    const existing = document.getElementById('schedeExDetailOverlay');
    if (existing) existing.remove();

    const overlay = document.createElement('div');
    overlay.id = 'schedeExDetailOverlay';
    overlay.className = 'schede-ex-detail-overlay';
    overlay.onclick = (e) => { if (e.target === overlay) overlay.remove(); };

    // Build header + media container via innerHTML
    overlay.innerHTML = `
    <div class="schede-ex-detail-panel">
        <div class="schede-ex-detail-header">
            <div>
                <h3>${_escHtml(ex.nome_it)}</h3>
                <span class="schede-ex-detail-cat">${_escHtml(ex.categoria)}</span>
                <span class="schede-ex-detail-en">${_escHtml(ex.nome_en)}</span>
            </div>
            <button class="schede-ex-detail-close" onclick="document.getElementById('schedeExDetailOverlay').remove()">&times;</button>
        </div>
        <div class="schede-ex-detail-body">
            <div class="schede-ex-detail-media" id="schedeExDetailMedia"></div>
        </div>
    </div>`;

    document.body.appendChild(overlay);

    // Create video programmatically (more reliable than innerHTML for media)
    const mediaContainer = document.getElementById('schedeExDetailMedia');
    if (ex.video_url && mediaContainer) {
        const video = document.createElement('video');
        video.className = 'schede-ex-detail-video';
        video.controls = true;
        video.autoplay = true;
        video.loop = true;
        video.muted = true;
        video.playsInline = true;
        video.preload = 'auto';
        video.src = ex.video_url;
        mediaContainer.appendChild(video);
        video.load();
        video.play().catch(() => {});
    } else if (mediaContainer) {
        const img = document.createElement('img');
        img.className = 'schede-ex-detail-img';
        img.src = ex.immagine_url_small;
        img.alt = ex.nome_it;
        mediaContainer.appendChild(img);
    }

    requestAnimationFrame(() => overlay.classList.add('visible'));
}

// Only registered users (with Supabase UUID) can be assigned plans
function _schedeGetRegisteredUsers() {
    if (typeof UserStorage === 'undefined') return [];
    return UserStorage.getAll().filter(u => u.userId);
}

let _schedeView = 'list';  // 'list' | 'edit' | 'progress' | 'clients' | 'client-detail' | 'actual'
let _schedeSection = (function() {
    // Persisti l'ultima sub-sezione attiva (subnav della tab Schede) — sopravvive ai reload.
    try { return sessionStorage.getItem('adminSchedeSection') || 'actual'; } catch (e) { return 'actual'; }
})(); // 'actual' | 'schede' | 'clienti' | 'importa'
let _currentPlanId = null;
let _editingPlan = null;
let _editDayLabels = [];
let _editActiveDay = '';
let _schedeClientUserId = null;  // for client-detail view
let _schedeClientDetailTab = 'schede'; // 'progressi' | 'schede' | 'report' (tab attivo nella client-detail)
// Cache workout_logs per userId con TTL + dedup in-flight: una RPC lenta su un
// cliente non deve bloccare aperture successive dello stesso cliente, e tab
// switch rapidi non devono lanciare query parallele duplicate.
const _schedeLogsCacheByUser = new Map();    // userId -> { logs, fetchedAt }
const _schedeLogsInFlightByUser = new Map(); // userId -> Promise<logs|null>
const _SCHEDE_LOGS_CACHE_TTL_MS = 60000;

// ── Entry point ──────────────────────────────────────────────────────────────
let _schedeRendering = false;   // guard against concurrent calls
let _schedeRenderQueued = false; // re-render after current finishes
let _schedeLastSync = 0;        // timestamp of last successful sync
let _schedeSyncInFlight = null; // evita sync workout_plans concorrenti dal tab
const _SCHEDE_SYNC_INTERVAL = 10000; // skip re-sync if < 10s ago
const _SCHEDE_EXDB_TIMEOUT_MS = 35000;   // safety net oltre il timeout interno 30s
const _SCHEDE_SYNC_TIMEOUT_MS = 35000;   // idem per syncFromSupabase

// Safety-timeout wrapper: garantisce che il render non resti appeso anche se
// la query sottostante non onora il proprio timeout (race, fetch sospeso, ecc.).
function _schedeWithTimeout(promise, ms, label) {
    return Promise.race([
        Promise.resolve(promise),
        new Promise((_, reject) =>
            setTimeout(() => reject(new Error(`[Schede] timeout:${label}`)), ms)
        )
    ]);
}

function _schedeRenderShell(container, { loading }) {
    const loaderHtml = loading ? '<div class="schede-loading">Caricamento schede...</div>' : '';
    container.innerHTML = `<div class="schede-subnav">
        <button class="schede-subnav-pill ${_schedeSection === 'actual' ? 'active' : ''}" onclick="_schedeSwitchSection('actual')">Live</button>
        <button class="schede-subnav-pill ${_schedeSection === 'schede' ? 'active' : ''}" onclick="_schedeSwitchSection('schede')">Schede</button>
        <button class="schede-subnav-pill ${_schedeSection === 'clienti' ? 'active' : ''}" onclick="_schedeSwitchSection('clienti')">Clienti</button>
        <button class="schede-subnav-pill ${_schedeSection === 'importa' ? 'active' : ''}" onclick="_schedeSwitchSection('importa')">Importa</button>
    </div><div id="schedeInner">${loaderHtml}</div>`;
}

function _schedeStartWorkoutPlansSync({ rerenderOnDone = false } = {}) {
    if (typeof WorkoutPlanStorage === 'undefined' || typeof WorkoutPlanStorage.syncFromSupabase !== 'function') return null;
    if (_schedeSyncInFlight) return _schedeSyncInFlight;

    const startedAt = (typeof performance !== 'undefined' ? performance.now() : Date.now());
    console.log('[Schede] syncFromSupabase: background start');
    _schedeSyncInFlight = _schedeWithTimeout(
        WorkoutPlanStorage.syncFromSupabase({ adminMode: true }),
        _SCHEDE_SYNC_TIMEOUT_MS,
        'sync_workout_plans'
    ).then(() => {
        _schedeLastSync = Date.now();
        const ms = Math.round(((typeof performance !== 'undefined' ? performance.now() : Date.now())) - startedAt);
        console.log(`[Schede] syncFromSupabase: background done (${ms}ms)`);
        if (rerenderOnDone && _schedeSection !== 'importa') renderSchedeTab();
    }).catch(e => {
        console.warn('[Schede] Background sync failed/timeout:', e);
        _schedeLastSync = 0;
    }).finally(() => {
        _schedeSyncInFlight = null;
    });

    return _schedeSyncInFlight;
}

async function renderSchedeTab() {
    // If already rendering, queue one re-render and bail
    if (_schedeRendering) {
        _schedeRenderQueued = true;
        console.debug('[Schede] renderSchedeTab: queued (render gia in corso)');
        return;
    }
    _schedeRendering = true;
    _schedeRenderQueued = false;
    const _t0 = (typeof performance !== 'undefined' ? performance.now() : Date.now());
    console.log('[Schede] renderSchedeTab: start');

    try {
        const container = document.getElementById('schedeContainer');
        if (!container) return;

        // Idrata da localStorage se cache in-memory vuota (primo render del tab
        // dopo reload). Così renderizziamo subito l'ultima lista nota invece di
        // mostrare il loader per 30s mentre la query va in timeout.
        if (typeof WorkoutPlanStorage !== 'undefined' && typeof WorkoutPlanStorage._loadFromLocalStorage === 'function') {
            WorkoutPlanStorage._loadFromLocalStorage(true);
        }
        const cachedPlans = (typeof WorkoutPlanStorage !== 'undefined')
            ? (WorkoutPlanStorage.getAllPlans() || []) : [];
        const hasData = cachedPlans.length > 0 || _schedeLastSync > 0;

        // Shell UI subito: subnav sempre visibile. Il contenuto viene renderizzato
        // anche con cache vuota, cosi' una RPC lenta non lascia il tab sul loader.
        _schedeRenderShell(container, { loading: false });

        // ── Sub-sezione "Importa" ────────────────────────────────────────────
        // Render isolato dal resto del tab: non serve sync workout_plans, non
        // serve _loadExercisesDB (quel cache lo riempie admin-importa.js stesso).
        // Inietta il container e delega tutto a renderImportaTab().
        if (_schedeSection === 'importa') {
            _schedeActualStopAutoRefresh();
            const inner = document.getElementById('schedeInner');
            if (inner) {
                inner.innerHTML = '<div class="dashboard-card" id="importaContainer"><div class="importa-loading">Caricamento catalogo esercizi...</div></div>';
                if (typeof renderImportaTab === 'function') renderImportaTab();
            }
            return;
        }

        // ── Exercise DB: serve SOLO per editor e picker. Le view list/actual/
        // clienti/progress NON lo usano (renderano solo WorkoutPlanStorage), quindi
        // non blocchiamo il render. In edit mode invece è necessario (picker esercizi).
        // Fire-and-forget per le altre view → la query si scalda in background.
        if (_schedeView === 'edit') {
            const _tEx = (typeof performance !== 'undefined' ? performance.now() : Date.now());
            console.log('[Schede] _loadExercisesDB: start (edit mode — blocking)');
            try {
                await _schedeWithTimeout(_loadExercisesDB(), _SCHEDE_EXDB_TIMEOUT_MS, 'load_exercises_db');
                const ms = Math.round(((typeof performance !== 'undefined' ? performance.now() : Date.now())) - _tEx);
                console.log(`[Schede] _loadExercisesDB: done (${ms}ms, ${EXERCISES_DB.length} esercizi)`);
            } catch (e) {
                console.warn('[Schede] _loadExercisesDB: timeout/failed, proseguo senza catalogo', e);
            }
        } else if (!_exercisesDBLoaded && !_loadExercisesDBPromise) {
            // Background: prealloca cache per quando l'utente aprirà un editor
            console.log('[Schede] _loadExercisesDB: background (non-blocking)');
            _loadExercisesDB().catch(e => console.warn('[Schede] background _loadExercisesDB failed', e));
        }

        // ── Sync workout_plans ───────────────────────────────────────────────
        // Sync sempre in background. Anche al primo load con cache vuota
        // renderizziamo una UI navigabile e aggiorniamo quando arrivano i dati:
        // una RPC in timeout non deve lasciare "Caricamento schede..." a schermo.
        const now = Date.now();
        if (now - _schedeLastSync > _SCHEDE_SYNC_INTERVAL) {
            _schedeLastSync = now; // ottimistico, evita retry a raffica durante il timeout
            _schedeStartWorkoutPlansSync({ rerenderOnDone: !hasData });
        }

        const inner = document.getElementById('schedeInner');
        if (!inner) return;

        // Actual section has its own auto-refresh (60s) for live slot rotation;
        // keep the interval running only while the view is on 'actual/list'.
        _schedeActualStopAutoRefresh();

        if (_schedeView === 'edit') _renderPlanEditor(inner);
        else if (_schedeView === 'progress') await _renderProgressView(inner);
        else if (_schedeSection === 'clienti') {
            if (_schedeView === 'client-detail') await _renderClientDetail(inner);
            else _renderClientsList(inner);
        } else if (_schedeSection === 'actual') {
            _renderActualView(inner);
            _schedeActualStartAutoRefresh();
        } else {
            _renderSchedeList(inner);
        }
    } catch (e) {
        console.error('[Schede] renderSchedeTab error:', e);
        const errTarget = document.getElementById('schedeInner') || document.getElementById('schedeContainer');
        if (errTarget) errTarget.innerHTML = '<div class="empty-slot">Errore caricamento schede. Cambia tab e riprova.</div>';
    } finally {
        const ms = Math.round(((typeof performance !== 'undefined' ? performance.now() : Date.now())) - _t0);
        console.log(`[Schede] renderSchedeTab: end (${ms}ms) — release lock`);
        _schedeRendering = false;
        if (_schedeRenderQueued) {
            console.debug('[Schede] renderSchedeTab: eseguo re-render in coda');
            renderSchedeTab();
        }
    }
}

function _schedeSwitchSection(section) {
    _schedeSection = section;
    _schedeView = section === 'clienti' ? 'clients' : 'list';
    _schedeClientUserId = null;
    // Reset circuit breaker quando l'utente rientra sull'Actual: se ha
    // raggiunto MAX_FAILURES prima, riprova da capo (intent esplicito utente).
    if (section === 'actual') {
        _schedeActualLoggedTodayFailures = 0;
        _schedeActualReportLastMonthFailures = 0;
    }
    try { sessionStorage.setItem('adminSchedeSection', section); } catch (e) { /* noop */ }
    renderSchedeTab();
}

// ═══════════════════════════════════════════════════════════════════════════════
// ACTUAL (slot precedente / attuale / successivo — live view)
// ═══════════════════════════════════════════════════════════════════════════════
let _schedeActualIntervalId = null;

// Set di user_id che hanno almeno un workout_log per la data corrente.
// Popolato in background da _schedeActualFetchLoggedToday e usato per mostrare
// i badge V/X accanto ai nomi nello slot precedente e attuale.
let _schedeActualLoggedTodayDate = null;
let _schedeActualLoggedTodaySet = new Set();
let _schedeActualLoggedTodayInflight = false;
let _schedeActualLoggedTodayFetchedAt = 0;
let _schedeActualLoggedTodayLastAttemptAt = 0;

// Set di user_id che hanno almeno un monthly_report per il mese scorso (year_month
// = mese precedente a quello corrente). Popolato in background da
// _schedeActualFetchReportsLastMonth e usato per mostrare l'emoji 📊 accanto al
// badge V/X nello slot precedente e attuale.
let _schedeActualReportLastMonthYM = null;
let _schedeActualReportLastMonthSet = new Set();
let _schedeActualReportLastMonthInflight = false;
let _schedeActualReportLastMonthFetchedAt = 0;
let _schedeActualReportLastMonthLastAttemptAt = 0;
const _SCHEDE_ACTUAL_STATUS_TTL_MS = 60000;
const _SCHEDE_ACTUAL_STATUS_RETRY_MS = 5000;
// Backoff esponenziale su fallimenti consecutivi: 5s → 10s → 20s → 40s → 80s → cap 5min.
// Dopo MAX_CONSECUTIVE_FAILURES smette di retryare in automatico (riprenderà quando
// l'utente cambia tab/riapre la pagina). Evita di hammerare il server e saturare le
// connessioni Supabase quando le query sono lente per cause server-side.
const _SCHEDE_ACTUAL_STATUS_MAX_RETRY_MS = 300000;  // 5 min
const _SCHEDE_ACTUAL_STATUS_MAX_FAILURES = 5;
let _schedeActualLoggedTodayFailures = 0;
let _schedeActualReportLastMonthFailures = 0;
function _schedeActualBackoffMs(failures) {
    // 5s base * 2^failures, cap 5min
    return Math.min(_SCHEDE_ACTUAL_STATUS_RETRY_MS * Math.pow(2, failures), _SCHEDE_ACTUAL_STATUS_MAX_RETRY_MS);
}

async function _schedeActualFetchLoggedToday(todayFormatted) {
    if (_schedeActualLoggedTodayInflight) return;
    const fresh = _schedeActualLoggedTodayDate === todayFormatted
        && (Date.now() - _schedeActualLoggedTodayFetchedAt) < _SCHEDE_ACTUAL_STATUS_TTL_MS;
    if (fresh) return;
    const now = Date.now();
    if (now - _schedeActualLoggedTodayLastAttemptAt < _SCHEDE_ACTUAL_STATUS_RETRY_MS) return;
    if (typeof supabaseClient === 'undefined') return;
    _schedeActualLoggedTodayLastAttemptAt = now;
    _schedeActualLoggedTodayInflight = true;
    try {
        const { data, error } = await _queryWithTimeout(supabaseClient
            .from('workout_logs')
            .select('user_id')
            .eq('log_date', todayFormatted));
        if (error) {
            // Errore "hard": conta come fallimento → il circuit-breaker nel finally interviene
            // (stesso pattern di _schedeActualFetchReportsLastMonth).
            _schedeActualLoggedTodayFailures++;
            console.warn('[Schede Actual] fetch logged today error:', error.message);
            return;
        }
        const set = new Set();
        for (const r of (data || [])) if (r.user_id) set.add(r.user_id);
        _schedeActualLoggedTodaySet = set;
        _schedeActualLoggedTodayDate = todayFormatted;
        _schedeActualLoggedTodayFetchedAt = Date.now();
        _schedeActualLoggedTodayFailures = 0;  // success → reset backoff
        // Re-render se siamo ancora sull'Actual: la guardia "fresh" sopra evita
        // il loop infinito (il rerender richiama fetch che vede cache fresca).
        if (_schedeSection === 'actual' && _schedeView === 'list') {
            const inner = document.getElementById('schedeInner');
            if (inner) _renderActualView(inner);
        }
    } catch (e) {
        console.warn('[Schede Actual] fetch logged today exception:', e);
        _schedeActualLoggedTodayFailures++;
    } finally {
        _schedeActualLoggedTodayInflight = false;
        const stillStale = _schedeActualLoggedTodayDate !== todayFormatted
            || (Date.now() - _schedeActualLoggedTodayFetchedAt) >= _SCHEDE_ACTUAL_STATUS_TTL_MS;
        // Backoff esponenziale + circuit breaker: stop dopo MAX_FAILURES consecutivi.
        if (stillStale && _schedeSection === 'actual' && _schedeView === 'list'
            && _schedeActualLoggedTodayFailures < _SCHEDE_ACTUAL_STATUS_MAX_FAILURES) {
            setTimeout(() => _schedeActualFetchLoggedToday(todayFormatted),
                _schedeActualBackoffMs(_schedeActualLoggedTodayFailures));
        }
    }
}

// "YYYY-MM" del mese precedente a oggi (TZ locale). Allineato con
// _getAvailableMonthForGeneration di allenamento-report.js.
function _schedeActualLastMonthYM() {
    const now = new Date();
    const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    return `${prev.getFullYear()}-${String(prev.getMonth() + 1).padStart(2, '0')}`;
}

async function _schedeActualFetchReportsLastMonth(yearMonth) {
    if (_schedeActualReportLastMonthInflight) return;
    const fresh = _schedeActualReportLastMonthYM === yearMonth
        && (Date.now() - _schedeActualReportLastMonthFetchedAt) < _SCHEDE_ACTUAL_STATUS_TTL_MS;
    if (fresh) return;
    const now = Date.now();
    if (now - _schedeActualReportLastMonthLastAttemptAt < _SCHEDE_ACTUAL_STATUS_RETRY_MS) return;
    if (typeof supabaseClient === 'undefined') return;
    _schedeActualReportLastMonthLastAttemptAt = now;
    _schedeActualReportLastMonthInflight = true;
    try {
        const { data, error } = await _queryWithTimeout(supabaseClient
            .from('monthly_reports')
            .select('user_id')
            .eq('year_month', yearMonth));
        if (error) {
            // Errore "hard" (es. schema/permessi): conta come fallimento così il circuit-breaker
            // nel finally smette di rischedulare invece di martellare al backoff minimo all'infinito.
            _schedeActualReportLastMonthFailures++;
            console.warn('[Schede Actual] fetch reports last month error:', error.message);
            return;
        }
        const set = new Set();
        for (const r of (data || [])) if (r.user_id) set.add(r.user_id);
        _schedeActualReportLastMonthSet = set;
        _schedeActualReportLastMonthYM = yearMonth;
        _schedeActualReportLastMonthFetchedAt = Date.now();
        _schedeActualReportLastMonthFailures = 0;  // success → reset backoff
        // Re-render se siamo ancora sull'Actual (la guardia "fresh" sopra
        // evita il loop infinito sul rerender che richiama il fetch).
        if (_schedeSection === 'actual' && _schedeView === 'list') {
            const inner = document.getElementById('schedeInner');
            if (inner) _renderActualView(inner);
        }
    } catch (e) {
        console.warn('[Schede Actual] fetch reports last month exception:', e);
        _schedeActualReportLastMonthFailures++;
    } finally {
        _schedeActualReportLastMonthInflight = false;
        const stillStale = _schedeActualReportLastMonthYM !== yearMonth
            || (Date.now() - _schedeActualReportLastMonthFetchedAt) >= _SCHEDE_ACTUAL_STATUS_TTL_MS;
        if (stillStale && _schedeSection === 'actual' && _schedeView === 'list'
            && _schedeActualReportLastMonthFailures < _SCHEDE_ACTUAL_STATUS_MAX_FAILURES) {
            setTimeout(() => _schedeActualFetchReportsLastMonth(yearMonth),
                _schedeActualBackoffMs(_schedeActualReportLastMonthFailures));
        }
    }
}

function _schedeActualStartAutoRefresh() {
    if (_schedeActualIntervalId) return;
    _schedeActualIntervalId = setInterval(() => {
        // Re-render solo se siamo ancora sul tab Actual e non c'e' un popup aperto.
        // Il popup e' fuori da #schedeInner quindi non viene distrutto, ma evitiamo
        // comunque di riallineare la UI sotto l'utente mentre decide.
        if (_schedeSection !== 'actual' || _schedeView !== 'list') {
            _schedeActualStopAutoRefresh();
            return;
        }
        const inner = document.getElementById('schedeInner');
        if (inner) _renderActualView(inner);
    }, 60000);
}

function _schedeActualStopAutoRefresh() {
    if (_schedeActualIntervalId) {
        clearInterval(_schedeActualIntervalId);
        _schedeActualIntervalId = null;
    }
}

function _schedeActualParseSlot(slotStr) {
    // "HH:MM - HH:MM" → { startMin, endMin }
    const m = slotStr.match(/(\d{2}):(\d{2})\s*-\s*(\d{2}):(\d{2})/);
    if (!m) return null;
    return {
        startMin: parseInt(m[1], 10) * 60 + parseInt(m[2], 10),
        endMin:   parseInt(m[3], 10) * 60 + parseInt(m[4], 10)
    };
}

// Fasce orarie attive della org (org-aware via getTimeSlots), fallback alle
// costanti legacy solo se data.js non è caricato. Unica fonte per il picker e
// il render: così la vista live rispetta la gestione orari del tenant corrente.
function _schedeActualTimeSlots() {
    return (typeof getTimeSlots === 'function') ? getTimeSlots() : TIME_SLOTS.slice();
}

function _schedeActualPickSlots(now) {
    // Return { prev, current, next } indices into le fasce org (or null each).
    const slots = _schedeActualTimeSlots();
    const nowMin = now.getHours() * 60 + now.getMinutes();
    let currentIdx = -1;
    for (let i = 0; i < slots.length; i++) {
        const r = _schedeActualParseSlot(slots[i]);
        if (!r) continue;
        if (nowMin >= r.startMin && nowMin < r.endMin) { currentIdx = i; break; }
    }
    let prevIdx = -1, nextIdx = -1;
    if (currentIdx === -1) {
        // Prima del primo slot o dopo l'ultimo
        const first = slots.length ? _schedeActualParseSlot(slots[0]) : null;
        if (first && nowMin < first.startMin) {
            nextIdx = 0;
        } else if (slots.length) {
            prevIdx = slots.length - 1;
        }
    } else {
        if (currentIdx > 0) prevIdx = currentIdx - 1;
        if (currentIdx < slots.length - 1) nextIdx = currentIdx + 1;
    }
    return { prevIdx, currentIdx, nextIdx };
}

function _schedeActualSlotTypeForDate(dateFormatted, slotTime) {
    // Determine slot type from schedule overrides, fallback to default weekly schedule.
    try {
        if (typeof BookingStorage !== 'undefined' && BookingStorage.getScheduleOverrides) {
            const overrides = BookingStorage.getScheduleOverrides();
            const daySlots = overrides[dateFormatted];
            if (daySlots) {
                const hit = daySlots.find(s => s.time === slotTime);
                if (hit) return hit.type;
            }
        }
    } catch (e) { /* ignore, fallback below */ }
    // Fallback: schedule settimanale org-aware (template attivo dal DB), per nome giorno.
    try {
        const d = new Date(dateFormatted + 'T00:00:00');
        const dayNames = ['Domenica', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato'];
        const dayName = dayNames[d.getDay()];
        const week = (typeof getWeeklySchedule === 'function') ? getWeeklySchedule() : null;
        const daySlots = week ? week[dayName] : null;
        if (daySlots) {
            const hit = daySlots.find(s => s.time === slotTime);
            if (hit) return hit.type;
        }
    } catch (e) { /* ignore */ }
    return null;
}

function _schedeActualSlotTypeLabel(type) {
    if (!type) return '';
    // Nome del tipo slot org-aware (slot_types.label del tenant); fallback legacy.
    if (typeof getSlotName === 'function') {
        const lbl = getSlotName(type);
        // getSlotName ritorna la key stessa se sconosciuta: in quel caso non mostriamo
        // una key grezza ("group-class") ma niente tag.
        return (lbl && lbl !== type) ? lbl : (typeof SLOT_NAMES !== 'undefined' && SLOT_NAMES[type] ? SLOT_NAMES[type] : '');
    }
    if (typeof SLOT_NAMES !== 'undefined' && SLOT_NAMES[type]) return SLOT_NAMES[type];
    return '';
}

// Colore (hex) del tipo slot org-aware — fonte di verità per il tag colorato.
// Preferisce slot_types.color del tenant (via getSlotColor); '' se non risolvibile.
function _schedeActualSlotTypeColor(type) {
    if (!type) return '';
    return (typeof getSlotColor === 'function') ? getSlotColor(type) : '';
}

// hex (#rrggbb) → rgba con alpha. Locale: calendar.js (che ha _hexToRgba) non è
// caricato su admin.html. Ritorna il colore grezzo se non è un hex a 6 cifre.
function _schedeActualHexToRgba(hex, alpha) {
    const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || ''));
    if (!m) return hex || '';
    const n = parseInt(m[1], 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
}

// Avatar helpers — colore stabile (hash del nome) + iniziali
function _saAvatarColor(name) {
    const palette = ['blue', 'green', 'amber', 'purple', 'pink'];
    const s = String(name || '');
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return palette[Math.abs(h) % palette.length];
}
function _saInitials(name) {
    const parts = String(name || '').trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return '?';
    const a = parts[0][0] || '';
    const b = parts.length > 1 ? (parts[parts.length - 1][0] || '') : '';
    return (a + b).toUpperCase();
}

function _renderActualView(container) {
    const now = new Date();
    const todayFormatted = (typeof formatAdminDate === 'function')
        ? formatAdminDate(now)
        : `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`;
    const { prevIdx, currentIdx, nextIdx } = _schedeActualPickSlots(now);

    const allUsers = _schedeGetRegisteredUsers();
    const userById = {};
    for (const u of allUsers) userById[u.userId] = u;

    // Precalcolo: user_ids con almeno una scheda attiva. Chi non e' nel set
    // viene marcato "no-plan" (rosso tenue) → l'admin vede subito chi non
    // ha scheda da seguire e deve assegnargliene una.
    const usersWithActivePlan = new Set();
    try {
        if (typeof WorkoutPlanStorage !== 'undefined') {
            for (const p of (WorkoutPlanStorage.getAllPlans() || [])) {
                if (p.user_id && p.active) usersWithActivePlan.add(p.user_id);
            }
        }
    } catch (e) { /* ignore: se fallisce, nessuno viene marcato no-plan */ }

    // Set user_id che hanno loggato oggi: usato per il badge V/X (solo prev/current).
    // Se la cache e' di un'altra data mostriamo uno stato neutro finche' il fetch
    // in background non aggiorna e ri-renderizza: niente false X.
    _schedeActualFetchLoggedToday(todayFormatted);
    const loggedReady = _schedeActualLoggedTodayDate === todayFormatted;
    const loggedSet = loggedReady ? _schedeActualLoggedTodaySet : null;

    // Set user_id con monthly_report del mese scorso: usato per l'emoji 📊
    // accanto al badge V/X (solo prev/current). Stessa logica di cache.
    const lastMonthYM = _schedeActualLastMonthYM();
    _schedeActualFetchReportsLastMonth(lastMonthYM);
    const reportReady = _schedeActualReportLastMonthYM === lastMonthYM;
    const reportSet = reportReady ? _schedeActualReportLastMonthSet : null;

    const ctx = { now, todayFormatted, usersWithActivePlan, loggedSet, loggedReady, reportSet, reportReady };

    let html = '<div class="schede-actual-carousel">';
    html +=   '<div class="schede-actual-track">';
    html +=     _schedeActualRenderSlot('prev',    prevIdx,    ctx);
    html +=     _schedeActualRenderSlot('current', currentIdx, ctx);
    html +=     _schedeActualRenderSlot('next',    nextIdx,    ctx);
    html +=   '</div>';
    html +=   '<div class="sa-dots"><span></span><span class="active"></span><span></span></div>';
    html += '</div>';

    container.innerHTML = html;

    // Carosello mobile: posiziona scroll sullo slot LIVE al primo render e
    // tieni allineati i puntini all'indice piu' centrato. Su desktop il
    // grid non scrolla orizzontalmente quindi i listener restano dormienti.
    requestAnimationFrame(() => {
        const carousel = container.querySelector('.schede-actual-carousel');
        if (!carousel) return;
        const track = carousel.querySelector('.schede-actual-track');
        if (!track) return;
        const slots = track.querySelectorAll('.schede-actual-slot');
        const dots = carousel.querySelectorAll('.sa-dots span');

        if (track.scrollWidth > track.clientWidth + 1) {
            const live = track.querySelector('.schede-actual-slot--current');
            if (live) {
                const offset = live.offsetLeft - (track.clientWidth - live.clientWidth) / 2;
                track.scrollLeft = Math.max(0, offset);
            }
        }

        const syncDots = () => {
            if (!slots.length || !dots.length) return;
            let nearest = 0, best = Infinity;
            const center = track.scrollLeft + track.clientWidth / 2;
            slots.forEach((s, i) => {
                const c = s.offsetLeft + s.clientWidth / 2;
                const d = Math.abs(c - center);
                if (d < best) { best = d; nearest = i; }
            });
            dots.forEach((d, i) => d.classList.toggle('active', i === nearest));
        };
        track.addEventListener('scroll', syncDots, { passive: true });
        syncDots();
    });
}

function _schedeActualRenderSlot(position, slotIdx, ctx) {
    // Pill in alto a sinistra dell'hero scuro: cambia label/colore per posizione.
    const pillLabel = position === 'prev'    ? 'CONCLUSO'
                    : position === 'current' ? 'LIVE'
                    : 'PROSSIMO';
    const pillHtml  = position === 'current'
        ? '<span class="sa-pill sa-pill--live"><span class="sa-pulse"></span>LIVE</span>'
        : `<span class="sa-pill sa-pill--${position}">${pillLabel}</span>`;

    const slots = _schedeActualTimeSlots();
    if (slotIdx < 0 || slotIdx >= slots.length) {
        const emptyMsg = position === 'prev'    ? 'Nessuno slot prima'
                       : position === 'current' ? 'Nessuno slot attivo'
                       : 'Giornata terminata';
        return `<div class="schede-actual-slot schede-actual-slot--${position} schede-actual-slot--empty">
            <div class="sa-hero">
                <div class="sa-hero-top">${pillHtml}</div>
                <div class="sa-empty-msg">${_escHtml(emptyMsg)}</div>
            </div>
        </div>`;
    }

    const slotTime  = slots[slotIdx];
    const slotRange = _schedeActualParseSlot(slotTime);
    const slotType  = _schedeActualSlotTypeForDate(ctx.todayFormatted, slotTime);
    const typeLabel = _schedeActualSlotTypeLabel(slotType);
    const slotColor = _schedeActualSlotTypeColor(slotType);
    // Tag colorato col colore del tipo slot org solo per lo slot LIVE: prev/next
    // restano mutati (grigio/viola) tramite le regole CSS per posizione.
    const typeStyle = (position === 'current' && slotColor)
        ? `style="background:${_schedeActualHexToRgba(slotColor, 0.18)};color:${slotColor};border-color:${_schedeActualHexToRgba(slotColor, 0.4)};"`
        : '';
    const startTime = slotTime.split(' - ')[0] || '';
    const endTime   = slotTime.split(' - ')[1] || '';

    let bookings = [];
    try {
        bookings = (typeof BookingStorage !== 'undefined')
            ? BookingStorage.getBookingsForSlot(ctx.todayFormatted, slotTime).filter(b => b.status !== 'cancelled' && !b.id?.startsWith('_avail_'))
            : [];
    } catch (e) { console.warn('[Schede Actual] getBookingsForSlot failed:', e); }

    // Capienza: capacita' del tipo principale dello slot per "X / Y posti".
    let cap = 0;
    try {
        if (typeof BookingStorage !== 'undefined' && slotType) {
            cap = BookingStorage.getEffectiveCapacity(ctx.todayFormatted, slotTime, slotType) || 0;
        }
    } catch (e) { /* ignore */ }
    const capHtml = cap > 0
        ? `<span class="sa-cap">${bookings.length} / ${cap} posti</span>`
        : '';

    // Progress bar: 100% se concluso, % corrente se LIVE, 0% se futuro.
    const totalMin = (slotRange && slotRange.endMin > slotRange.startMin)
        ? (slotRange.endMin - slotRange.startMin) : 80;
    const nowMin = ctx.now.getHours() * 60 + ctx.now.getMinutes();
    let progressPct = 0, footMid = '';
    if (position === 'prev') {
        progressPct = 100;
        footMid = 'completato';
    } else if (position === 'current') {
        const elapsed = Math.max(0, Math.min(totalMin, nowMin - (slotRange ? slotRange.startMin : 0)));
        progressPct = Math.round((elapsed / totalMin) * 100);
        footMid = `${elapsed} min · ${progressPct}%`;
    } else {
        progressPct = 0;
        const minutesUntil = Math.max(0, (slotRange ? slotRange.startMin : 0) - nowMin);
        footMid = minutesUntil >= 60
            ? `tra ${Math.round(minutesUntil/60)}h`
            : (minutesUntil > 0 ? `tra ${minutesUntil} min` : 'in arrivo');
    }

    // Lista persone (rimane dentro alla card per posizione: cosi' resta visibile
    // anche per slot prev/next, non solo per LIVE come nel mockup statico).
    let peopleHtml = '';
    if (bookings.length === 0) {
        peopleHtml = '<div class="sa-empty-msg sa-empty-msg--inline">Nessuno in questo slot</div>';
    } else {
        // Badge V/X solo per slot precedente e attuale: nello slot successivo
        // la sessione non e' ancora iniziata, quindi non ha senso mostrarlo.
        const showLogBadge = position === 'prev' || position === 'current';
        peopleHtml = '<div class="sa-people">';
        for (const b of bookings) {
            const uid  = b.userId || b.user_id || '';
            const name = b.name || b.clientName || 'Sconosciuto';
            const hasUid = !!uid;
            const noPlan = hasUid && ctx.usersWithActivePlan && !ctx.usersWithActivePlan.has(uid);
            const avColor  = _saAvatarColor(name);
            const initials = _saInitials(name);

            let logBadgeHtml = '';
            let reportBadgeHtml = '';
            if (showLogBadge) {
                if (!ctx.loggedReady) {
                    const title = 'Verifica log in corso';
                    logBadgeHtml = `<span class="sa-status" title="${title}" aria-label="${title}">...</span>`;
                } else {
                    const logged = hasUid && ctx.loggedSet && ctx.loggedSet.has(uid);
                    const cls = logged ? 'sa-status sa-status--ok' : 'sa-status sa-status--ko';
                    const title = logged ? 'Ha registrato log oggi' : 'Nessun log registrato oggi';
                    logBadgeHtml = `<span class="${cls}" title="${title}" aria-label="${title}">${logged ? '✓' : '✗'}</span>`;
                }
                if (hasUid && ctx.reportReady && ctx.reportSet && ctx.reportSet.has(uid)) {
                    const rTitle = 'Ha generato il report del mese scorso';
                    reportBadgeHtml = `<span class="sa-report" title="${rTitle}" aria-label="${rTitle}">📊</span>`;
                }
            }

            const personClasses = ['sa-person'];
            if (!hasUid) personClasses.push('sa-person--guest');
            if (noPlan)  personClasses.push('sa-person--no-plan');
            const titleAttr = !hasUid
                ? 'title="Cliente senza profilo registrato"'
                : (noPlan ? 'title="Nessuna scheda attiva assegnata"' : '');
            const onClickAttr = hasUid
                ? `onclick="_schedeActualOpenClientPopup('${_escAttr(uid)}','${_escAttr(name)}')"`
                : 'disabled';

            peopleHtml += `<button class="${personClasses.join(' ')}" ${onClickAttr} ${titleAttr}>
                <span class="sa-av sa-av--${avColor}">${_escHtml(initials)}</span>
                <span class="sa-person-info">
                    <span class="sa-person-name">${_escHtml(name)}</span>
                    ${noPlan ? '<span class="sa-person-meta sa-person-meta--warn">Nessuna scheda attiva</span>' : ''}
                </span>
                ${reportBadgeHtml}
                ${logBadgeHtml}
                ${hasUid ? '<span class="sa-chev">›</span>' : ''}
            </button>`;
        }
        peopleHtml += '</div>';
    }

    return `<div class="schede-actual-slot schede-actual-slot--${position}">
        <div class="sa-hero">
            <div class="sa-hero-top">
                ${pillHtml}
                ${capHtml}
            </div>
            <div class="sa-time-row">
                <div class="sa-time-now">${_escHtml(startTime)}</div>
                <div class="sa-time-end">→ ${_escHtml(endTime)}</div>
            </div>
            ${typeLabel ? `<div class="sa-tag-row"><span class="sa-type" ${typeStyle}>${_escHtml(typeLabel)}</span></div>` : ''}
            <div class="sa-progress"><div class="sa-progress-fill" style="width:${progressPct}%;"></div></div>
            <div class="sa-progress-foot">
                <span>${_escHtml(startTime)}</span>
                <span>${_escHtml(footMid)}</span>
                <span>${_escHtml(endTime)}</span>
            </div>
        </div>
        <div class="sa-body">${peopleHtml}</div>
    </div>`;
}

function _escJs(s) {
    return String(s || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/"/g, '\\"');
}

// ── Popup: scelta Carichi / Scheda ────────────────────────────────────────────
function _schedeActualOpenClientPopup(userId, name) {
    // Rimuovi eventuale popup precedente
    _schedeActualCloseClientPopup();

    const plans = (typeof WorkoutPlanStorage !== 'undefined')
        ? WorkoutPlanStorage.getAllPlans().filter(p => p.user_id === userId)
        : [];
    const activePlans = plans.filter(p => p.active);

    const overlay = document.createElement('div');
    overlay.id = 'schedeActualPopupOverlay';
    overlay.className = 'schede-actual-popup-overlay';
    overlay.onclick = function(e) { if (e.target === overlay) _schedeActualCloseClientPopup(); };

    const schedaDisabled = activePlans.length === 0;
    const schedaSubtitle = activePlans.length === 0
        ? 'Nessuna scheda attiva'
        : (activePlans.length === 1 ? activePlans[0].name : `${activePlans.length} schede attive`);

    overlay.innerHTML = `<div class="schede-actual-popup" role="dialog" aria-modal="true">
        <div class="schede-actual-popup-head">
            <div>
                <div class="schede-actual-popup-eyebrow">Cliente</div>
                <h3 class="schede-actual-popup-title">${_escHtml(name)}</h3>
            </div>
            <button class="schede-actual-popup-close" onclick="_schedeActualCloseClientPopup()" aria-label="Chiudi">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
            </button>
        </div>
        <div class="schede-actual-popup-actions">
            <button class="schede-actual-popup-btn" onclick="_schedeActualPickCarichi('${_escJs(userId)}')">
                <div class="schede-actual-popup-btn-icon">📊</div>
                <div class="schede-actual-popup-btn-body">
                    <div class="schede-actual-popup-btn-title">Carichi</div>
                    <div class="schede-actual-popup-btn-sub">Grafici e log delle sessioni precedenti</div>
                </div>
                <div class="schede-actual-popup-btn-chev">›</div>
            </button>
            <button class="schede-actual-popup-btn" onclick="_schedeActualPickReport('${_escJs(userId)}')">
                <div class="schede-actual-popup-btn-icon">📅</div>
                <div class="schede-actual-popup-btn-body">
                    <div class="schede-actual-popup-btn-title">Report</div>
                    <div class="schede-actual-popup-btn-sub">Report AI mensili generati dal cliente</div>
                </div>
                <div class="schede-actual-popup-btn-chev">›</div>
            </button>
            <div class="schede-actual-popup-row">
                <button class="schede-actual-popup-btn ${schedaDisabled ? 'schede-actual-popup-btn--disabled' : ''}"
                    ${schedaDisabled ? 'disabled' : `onclick="_schedeActualPickScheda('${_escJs(userId)}')"`}>
                    <div class="schede-actual-popup-btn-icon">📝</div>
                    <div class="schede-actual-popup-btn-body">
                        <div class="schede-actual-popup-btn-title">Scheda</div>
                        <div class="schede-actual-popup-btn-sub">${_escHtml(schedaSubtitle)}</div>
                    </div>
                    ${schedaDisabled ? '' : '<div class="schede-actual-popup-btn-chev">›</div>'}
                </button>
                ${schedaDisabled ? `<button class="schede-actual-popup-add" onclick="_schedeActualAddPlan('${_escAttr(userId)}','${_escAttr(name)}')" title="Crea nuova scheda per ${_escAttr(name)}">
                    <span class="schede-actual-popup-add-plus">+</span>
                    <span class="schede-actual-popup-add-label">Aggiungi</span>
                </button>` : ''}
            </div>
        </div>
    </div>`;

    document.body.appendChild(overlay);
    document.addEventListener('keydown', _schedeActualPopupKeyHandler);
    requestAnimationFrame(() => overlay.classList.add('visible'));
}

function _schedeActualCloseClientPopup() {
    const overlay = document.getElementById('schedeActualPopupOverlay');
    if (overlay) overlay.remove();
    document.removeEventListener('keydown', _schedeActualPopupKeyHandler);
}

function _schedeActualPopupKeyHandler(e) {
    if (e.key === 'Escape') _schedeActualCloseClientPopup();
}

function _schedeActualPickCarichi(userId) {
    _schedeActualCloseClientPopup();
    _schedeClientUserId = userId;
    _schedeClientDetailTab = 'progressi';
    _schedeSection = 'clienti';
    _schedeView = 'client-detail';
    renderSchedeTab();
}

function _schedeActualPickScheda(userId) {
    _schedeActualCloseClientPopup();
    const plans = WorkoutPlanStorage.getAllPlans().filter(p => p.user_id === userId);
    const activePlans = plans.filter(p => p.active);
    if (activePlans.length === 1) {
        // Apri direttamente l'editor della scheda attiva
        _schedeEditPlan(activePlans[0].id);
    } else {
        _schedeClientUserId = userId;
        _schedeClientDetailTab = 'schede';
        _schedeSection = 'clienti';
        _schedeView = 'client-detail';
        renderSchedeTab();
    }
}

// Pending prefill per la creazione di una nuova scheda: applicato da
// _renderPlanEditor subito dopo aver scritto il DOM.
let _schedePendingNewPlanPrefill = null;

async function _schedeActualAddPlan(userId, clientName) {
    const planName = await showPrompt(`Nome della nuova scheda per ${clientName}:`, '', { confirmText: 'Crea' });
    if (planName === null) return; // annullato
    const trimmed = (planName || '').trim();
    if (!trimmed) {
        if (typeof showToast === 'function') showToast('Nome scheda richiesto', 'error');
        return;
    }
    _schedeActualCloseClientPopup();

    // Imposta prefill + apri editor in modalita' "nuova scheda"
    _schedePendingNewPlanPrefill = { userId: userId, clientName: clientName, planName: trimmed };
    _editingPlan = null;
    _currentPlanId = null;
    _editDayLabels = ['Giorno A'];
    _editActiveDay = 'Giorno A';
    _schedeView = 'edit';
    renderSchedeTab();
}

// ═══════════════════════════════════════════════════════════════════════════════
// REPORT AI (lettura admin dei monthly_reports generati dai clienti)
// ═══════════════════════════════════════════════════════════════════════════════
// Obiettivi correnti — devono restare allineati a _GOALS in allenamento-report.js
// e al CHECK del DB (vedi 20260430000000_monthly_reports_goal.sql).
const _SCHEDE_REPORT_GOALS = {
    dimagrimento:  { label: 'Dimagrimento',  icon: '🔥' },
    massa:         { label: 'Aumento Massa', icon: '💪' },
    tonificazione: { label: 'Tonificazione', icon: '✨' },
    forza:         { label: 'Forza',         icon: '🏋️' },
    salute:        { label: 'Salute',        icon: '❤️' },
    recupero:      { label: 'Recupero',      icon: '🧘' },
};

// Toni legacy: i report generati prima del refactor toni->obiettivi (cc6c2b3)
// hanno solo r.tone valorizzato, non r.goal. Tenuti per leggere lo storico.
const _SCHEDE_REPORT_TONES = {
    serious:      { label: 'Serio',         icon: '🎯' },
    motivational: { label: 'Motivazionale', icon: '💪' },
    ironic:       { label: 'Ironico',       icon: '😏' }
};

function _schedeReportLabel(r) {
    if (r.goal && _SCHEDE_REPORT_GOALS[r.goal]) return _SCHEDE_REPORT_GOALS[r.goal];
    if (r.tone && _SCHEDE_REPORT_TONES[r.tone]) return _SCHEDE_REPORT_TONES[r.tone];
    return { label: r.goal || r.tone || '—', icon: '📝' };
}

// Cache: userId → array di report (caricati al primo open)
const _schedeReportsCache = {};
const _schedeReportsCacheFetchedAt = {};
const _SCHEDE_REPORTS_CACHE_TTL_MS = 60000;

function _schedeFormatYearMonth(ym) {
    if (!ym) return '';
    const [y, m] = ym.split('-');
    const months = ['Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
                    'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'];
    const idx = parseInt(m, 10) - 1;
    return `${months[idx] || m} ${y}`;
}

function _schedeReportMarkdownToHtml(md) {
    if (!md) return '';
    let html = _escHtml(md);
    html = html.replace(/^### (.+)$/gm, '<h4>$1</h4>');
    html = html.replace(/^## (.+)$/gm,  '<h3>$1</h3>');
    html = html.replace(/^# (.+)$/gm,   '<h2>$1</h2>');
    html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/(?<!\*)\*([^*\n]+)\*(?!\*)/g, '<em>$1</em>');
    html = html.split(/\n{2,}/).map(block => {
        const trimmed = block.trim();
        if (!trimmed) return '';
        if (/^<h[2-4]>/.test(trimmed)) return trimmed;
        return `<p>${trimmed.replace(/\n/g, '<br>')}</p>`;
    }).filter(Boolean).join('\n');
    return html;
}

async function _schedeFetchClientReports(userId, { force = false } = {}) {
    const hasCached = Object.prototype.hasOwnProperty.call(_schedeReportsCache, userId);
    const fresh = hasCached && (Date.now() - (_schedeReportsCacheFetchedAt[userId] || 0)) < _SCHEDE_REPORTS_CACHE_TTL_MS;
    if (!force && fresh) return _schedeReportsCache[userId];
    if (typeof supabaseClient === 'undefined') return [];
    try {
        const { data, error } = await _queryWithTimeout(supabaseClient
            .from('monthly_reports')
            .select('id, user_id, year_month, goal, tone, narrative, generated_at, status')
            .eq('user_id', userId)
            .eq('status', 'generated')
            .order('year_month', { ascending: false })
            .order('generated_at', { ascending: false }), 15000);
        if (error) throw error;
        _schedeReportsCache[userId] = data || [];
        _schedeReportsCacheFetchedAt[userId] = Date.now();
        return _schedeReportsCache[userId];
    } catch (e) {
        console.error('[Schede] fetch reports error:', e);
        return [];
    }
}

function _schedeActualPickReport(userId) {
    _schedeActualCloseClientPopup();
    _schedeClientUserId = userId;
    _schedeClientDetailTab = 'report';
    _schedeSection = 'clienti';
    _schedeView = 'client-detail';
    renderSchedeTab();
}

function _schedeRenderReportCard(r) {
    const info = _schedeReportLabel(r);
    const monthLabel = _schedeFormatYearMonth(r.year_month);
    const dateStr = r.generated_at ? new Date(r.generated_at).toLocaleDateString('it-IT') : '';
    return `<button class="schede-report-item" onclick="_schedeOpenReportModal('${_escJs(r.id)}','${_escJs(r.user_id)}')">
        <span class="schede-report-item-icon">${info.icon}</span>
        <span class="schede-report-item-body">
            <span class="schede-report-item-title">${_escHtml(monthLabel)}</span>
            <span class="schede-report-item-meta">${_escHtml(info.label)}${dateStr ? ' &middot; generato ' + _escHtml(dateStr) : ''}</span>
        </span>
        <span class="schede-report-item-chev">›</span>
    </button>`;
}

async function _schedeRenderReportsSection(userId) {
    const section = document.getElementById('schedeReportsSection');
    if (!section) return;
    section.innerHTML = '<div class="schede-loading">Caricamento report...</div>';

    const reports = await _schedeFetchClientReports(userId);
    if (!reports || reports.length === 0) {
        section.innerHTML = `<h4 class="schede-section-title" id="schedeReportsAnchor">Report Mensili</h4>
            <div class="empty-slot">Nessun report generato da questo cliente.</div>`;
        return;
    }

    // Raggruppa per mese
    const byMonth = {};
    for (const r of reports) {
        (byMonth[r.year_month] = byMonth[r.year_month] || []).push(r);
    }
    const months = Object.keys(byMonth).sort().reverse();

    let html = `<h4 class="schede-section-title" id="schedeReportsAnchor">Report Mensili
        <span class="schede-section-count">${reports.length}</span>
    </h4>`;
    html += '<div class="schede-report-list">';
    for (const ym of months) {
        html += `<div class="schede-report-month">
            <div class="schede-report-month-label">${_escHtml(_schedeFormatYearMonth(ym))}</div>
            <div class="schede-report-month-items">`;
        for (const r of byMonth[ym]) html += _schedeRenderReportCard(r);
        html += '</div></div>';
    }
    html += '</div>';

    section.innerHTML = html;
}

function _schedeOpenReportModal(reportId, userId) {
    const reports = _schedeReportsCache[userId] || [];
    const report = reports.find(r => r.id === reportId);
    if (!report) return;

    _schedeCloseReportModal();

    const info = _schedeReportLabel(report);
    const bodyHtml = _schedeReportMarkdownToHtml(report.narrative);
    const monthLabel = _schedeFormatYearMonth(report.year_month);
    const dateStr = report.generated_at
        ? new Date(report.generated_at).toLocaleDateString('it-IT', { day: '2-digit', month: 'short', year: 'numeric' })
        : '';

    const overlay = document.createElement('div');
    overlay.id = 'schedeReportModalOverlay';
    overlay.className = 'schede-report-modal-overlay';
    overlay.onclick = function(e) { if (e.target === overlay) _schedeCloseReportModal(); };

    overlay.innerHTML = `<div class="schede-report-modal" role="dialog" aria-modal="true">
        <div class="schede-report-modal-head">
            <div>
                <div class="schede-report-modal-eyebrow">Report ${_escHtml(monthLabel)}</div>
                <div class="schede-report-modal-tone">${info.icon} ${_escHtml(info.label)}${dateStr ? ' &middot; ' + _escHtml(dateStr) : ''}</div>
            </div>
            <button class="schede-report-modal-close" onclick="_schedeCloseReportModal()" aria-label="Chiudi">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
            </button>
        </div>
        <div class="schede-report-modal-body">${bodyHtml || '<p><em>Report vuoto.</em></p>'}</div>
    </div>`;

    document.body.appendChild(overlay);
    document.addEventListener('keydown', _schedeReportModalKeyHandler);
    requestAnimationFrame(() => overlay.classList.add('visible'));
}

function _schedeCloseReportModal() {
    const overlay = document.getElementById('schedeReportModalOverlay');
    if (overlay) overlay.remove();
    document.removeEventListener('keydown', _schedeReportModalKeyHandler);
}

function _schedeReportModalKeyHandler(e) {
    if (e.key === 'Escape') _schedeCloseReportModal();
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLIENTS LIST (admin → see clients with plans)
// ═══════════════════════════════════════════════════════════════════════════════
function _renderClientsList(container) {
    const plans = WorkoutPlanStorage.getAllPlans();
    const allUsers = _schedeGetRegisteredUsers();

    // Group plans by user_id
    const byUser = {};
    for (const p of plans) {
        if (!p.user_id) continue;
        if (!byUser[p.user_id]) byUser[p.user_id] = [];
        byUser[p.user_id].push(p);
    }

    // Mostra TUTTI i clienti registrati (anche senza scheda), ordinati per nome.
    // Chi non ha scheda assegnata appare con pill grigia "Senza scheda".
    const usersSorted = allUsers
        .filter(u => u.userId)
        .slice()
        .sort((a, b) => (a.name || a.email || '').localeCompare(b.name || b.email || ''));

    let html = '';

    html += `<div class="schede-search-bar">
        <input type="text" id="schedeClientFilterInput" placeholder="Filtra clienti..."
               oninput="_schedeFilterClientCards()">
    </div>`;

    if (usersSorted.length === 0) {
        html += '<div class="empty-slot">Nessun cliente registrato.</div>';
    } else {
        html += '<div class="schede-client-list">';
        for (const u of usersSorted) {
            const uid = u.userId;
            const rawName = u.name || u.email || 'Sconosciuto';
            const clientName = _escHtml(rawName);
            const userPlans = byUser[uid] || [];
            const activePlans = userPlans.filter(p => p.active);
            const activeCount = activePlans.length;
            const totalExercises = userPlans.reduce((s, p) => s + (p.workout_exercises || []).length, 0);

            // Distinct training days (day_label) across active plans
            const activeDayLabels = new Set();
            for (const p of activePlans) {
                for (const ex of (p.workout_exercises || [])) {
                    if (ex.day_label) activeDayLabels.add(ex.day_label);
                }
            }
            const activeDaysCount = activeDayLabels.size;

            // Status pill (top-right):
            //   verde "Attiva" / "N attive" se almeno una scheda attiva,
            //   grigia "Nessuna attiva" se ha schede ma nessuna attiva,
            //   grigia "Senza scheda" se non ha proprio schede assegnate.
            let pillHtml;
            if (activeCount === 1) {
                pillHtml = '<span class="schede-cc-pill"><span class="dot"></span>Attiva</span>';
            } else if (activeCount > 1) {
                pillHtml = '<span class="schede-cc-pill"><span class="dot"></span>' + activeCount + ' attive</span>';
            } else if (userPlans.length > 0) {
                pillHtml = '<span class="schede-cc-pill gray"><span class="dot"></span>Nessuna attiva</span>';
            } else {
                pillHtml = '<span class="schede-cc-pill gray"><span class="dot"></span>Senza scheda</span>';
            }

            // Subtitle
            let subHtml;
            if (activeCount === 1) {
                const daysTxt = activeDaysCount
                    ? ' &middot; ' + activeDaysCount + ' ' + (activeDaysCount === 1 ? 'giorno' : 'giorni')
                    : '';
                subHtml = '<div class="schede-cc-sub">' + _escHtml(activePlans[0].name) + daysTxt + '</div>';
            } else if (activeCount > 1) {
                const daysTxt = activeDaysCount
                    ? activeDaysCount + ' ' + (activeDaysCount === 1 ? 'giorno' : 'giorni')
                    : 'più schede attive';
                subHtml = '<div class="schede-cc-sub">' + daysTxt + '</div>';
            } else if (userPlans.length > 0) {
                subHtml = '<div class="schede-cc-sub muted">Nessuna scheda attiva</div>';
            } else {
                subHtml = '<div class="schede-cc-sub muted">Nessuna scheda assegnata</div>';
            }

            const avInitials = _schedeAvatarInitials(rawName);
            const avColor = _schedeAvatarColorClass(rawName);
            const plansLbl = userPlans.length === 1 ? 'scheda' : 'schede';
            const exLbl = totalExercises === 1 ? 'esercizio' : 'esercizi';

            html += `
            <div class="schede-cc-card" data-client="${clientName.toLowerCase()}" onclick="_schedeOpenClientDetail('${uid}')">
                <div class="schede-cc-av ${avColor}">${avInitials}</div>
                <div class="schede-cc-body">
                    <div class="schede-cc-top">
                        <div class="schede-cc-nm">${clientName}</div>
                        ${pillHtml}
                    </div>
                    ${subHtml}
                    <div class="schede-cc-stats">
                        <span class="it"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><polyline points="14 3 14 8 19 8"/></svg><b>${userPlans.length}</b> ${plansLbl}</span>
                        <span class="it"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="6.5" cy="12" r="2.5"/><circle cx="17.5" cy="12" r="2.5"/><line x1="9" y1="12" x2="15" y2="12"/></svg><b>${totalExercises}</b> ${exLbl}</span>
                    </div>
                </div>
            </div>`;
        }
        html += '</div>';
    }

    container.innerHTML = html;
}

// Avatar helpers (Variante B mockup): initials + colored bg per client name.
function _schedeAvatarInitials(name) {
    const parts = (name || '').trim().split(/\s+/).filter(Boolean);
    if (parts.length === 0) return '?';
    if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
}
function _schedeAvatarColorClass(name) {
    let h = 0;
    const s = name || '';
    for (let i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0;
    const idx = Math.abs(h) % 5;
    return 'c' + (idx + 1);
}

function _schedeFilterClientCards() {
    const q = (document.getElementById('schedeClientFilterInput')?.value || '').toLowerCase();
    document.querySelectorAll('.schede-cc-card').forEach(card => {
        card.style.display = card.dataset.client.includes(q) ? '' : 'none';
    });
}

// Quick assign: search any registered client
var _schedeQuickSearchClient = _debounce(function() {
    const input = document.getElementById('schedeQuickClientSearch');
    const dropdown = document.getElementById('schedeQuickClientDropdown');
    const q = (input?.value || '').toLowerCase();
    if (!q || q.length < 1) { dropdown.style.display = 'none'; return; }

    const matches = _schedeGetRegisteredUsers().filter(u =>
        (u.name || '').toLowerCase().includes(q) ||
        (u.email || '').toLowerCase().includes(q)
    );

    if (matches.length === 0) {
        dropdown.innerHTML = '<div class="dropdown-no-results">Nessun cliente trovato</div>';
    } else {
        dropdown.innerHTML = matches.slice(0, 10).map(u =>
            `<div class="dropdown-item" onclick="_schedeQuickSelectClient('${u.userId}', '${_escHtml(u.name || u.email).replace(/'/g, "\\'")}')">
                <span class="dropdown-item-name">${_escHtml(u.name || 'Senza nome')}</span>
            </div>`
        ).join('');
    }
    dropdown.style.display = 'block';
}, 150);

function _schedeQuickSelectClient(userId, name) {
    const input = document.getElementById('schedeQuickClientSearch');
    input.value = name;
    input.dataset.userId = userId;
    document.getElementById('schedeQuickClientDropdown').style.display = 'none';
}

async function _schedeQuickAssign() {
    const templateId = document.getElementById('schedeQuickTemplate')?.value;
    const clientInput = document.getElementById('schedeQuickClientSearch');
    const userId = clientInput?.dataset?.userId;

    if (!templateId) { if (typeof showToast === 'function') showToast('Seleziona un template', 'error'); return; }
    if (!userId || userId === 'undefined') { if (typeof showToast === 'function') showToast('Seleziona un cliente', 'error'); return; }

    try {
        await WorkoutPlanStorage.duplicatePlan(templateId, userId);
        if (typeof showToast === 'function') showToast('Scheda assegnata!', 'success');
        // Reset
        clientInput.value = '';
        delete clientInput.dataset.userId;
        document.getElementById('schedeQuickTemplate').value = '';
        renderSchedeTab();
    } catch (e) {
        console.error('[Schede] quick assign error:', e);
        if (typeof showToast === 'function') showToast('Errore assegnazione', 'error');
    }
}

function _schedeOpenClientDetail(userId) {
    _schedeClientUserId = userId;
    _schedeClientDetailTab = 'schede'; // default da Clienti
    _schedeView = 'client-detail';
    renderSchedeTab();
}

function _schedeClientSwitchTab(tab) {
    if (_schedeClientDetailTab === tab) return;
    _schedeClientDetailTab = tab;
    renderSchedeTab();
}

// ═══════════════════════════════════════════════════════════════════════════════
// CLIENT DETAIL (admin → view a client's plans + charts)
// ═══════════════════════════════════════════════════════════════════════════════
async function _renderClientDetail(container) {
    const userId = _schedeClientUserId;
    const allUsers = _schedeGetRegisteredUsers();
    const clientName = allUsers.find(u => u.userId === userId)?.name || 'Cliente';
    const plans = WorkoutPlanStorage.getAllPlans().filter(p => p.user_id === userId);
    const tab = _schedeClientDetailTab || 'schede';
    const safeName = _escHtml(clientName);

    const activeCount = plans.filter(p => p.active).length;
    const schedeCt = activeCount === 0
        ? (plans.length === 0 ? 'Nessuna' : 'Nessuna attiva')
        : (activeCount === 1 ? '1 attiva' : activeCount + ' attive');

    // Shell: breadcrumb + name + pill cards + tab-content
    const shell = `<div class="schede-cd-bread">
        <button class="schede-cd-back" onclick="_schedeView='clients';renderSchedeTab()">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
            Clienti
        </button>
        <span class="sep">/</span>
        <span class="now">${safeName}</span>
    </div>
    <h2 class="schede-cd-name">${safeName}</h2>
    <div class="schede-cd-pills" role="tablist">
        <button class="schede-cd-pill ${tab === 'progressi' ? 'active' : ''}" role="tab" onclick="_schedeClientSwitchTab('progressi')">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 17 9 11 13 15 21 7"/><polyline points="14 7 21 7 21 14"/></svg>
            <span class="lbl">Progressi</span>
            <span class="ct" id="schedeCdCtProgressi">—</span>
        </button>
        <button class="schede-cd-pill ${tab === 'schede' ? 'active' : ''}" role="tab" onclick="_schedeClientSwitchTab('schede')">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><polyline points="14 3 14 8 19 8"/></svg>
            <span class="lbl">Schede</span>
            <span class="ct">${schedeCt}</span>
        </button>
        <button class="schede-cd-pill ${tab === 'report' ? 'active' : ''}" role="tab" onclick="_schedeClientSwitchTab('report')">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/></svg>
            <span class="lbl">Report</span>
            <span class="ct" id="schedeCdCtReport">—</span>
        </button>
    </div>
    <div id="schedeClientTabContent" class="schede-client-tab-content"></div>`;
    container.innerHTML = shell;

    const tabContainer = document.getElementById('schedeClientTabContent');
    if (!tabContainer) return;

    if (tab === 'report') {
        await _schedeClientRenderReport(tabContainer, userId);
    } else if (tab === 'progressi') {
        await _schedeClientRenderProgressi(tabContainer, userId, plans);
    } else {
        await _schedeClientRenderSchede(tabContainer, userId, plans);
    }

    // Aggiorna i contatori delle pill (Progressi / Report) in background.
    _schedeCdUpdatePillCounts(userId, plans);
}

// Aggiorna i count delle pill Progressi/Report dopo il primo render.
// Schede ha il count immediato (sync), gli altri due richiedono fetch.
async function _schedeCdUpdatePillCounts(userId, plans) {
    // Progressi: numero di sessioni (distinct exercise_id + log_date)
    _schedeClientDetailLoadLogs(userId, plans).then(logs => {
        const el = document.getElementById('schedeCdCtProgressi');
        if (!el || _schedeClientUserId !== userId) return;
        if (logs === null) { el.textContent = '—'; return; }
        const set = new Set(logs.map(l => l.exercise_id + '|' + l.log_date));
        const n = set.size;
        el.textContent = n === 0 ? 'Nessuna' : (n === 1 ? '1 sess.' : n + ' sess.');
    });
    // Report: numero di monthly_reports
    _schedeFetchClientReports(userId).then(reports => {
        const el = document.getElementById('schedeCdCtReport');
        if (!el || _schedeClientUserId !== userId) return;
        const n = (reports || []).length;
        el.textContent = n === 0 ? 'Nessuno' : (n === 1 ? '1 mensile' : n + ' mensili');
    });
}

// ── Fetch workout_logs con cache per userId (condiviso tra tab Progressi e Schede) ──
function _schedeGetCachedLogs(userId) {
    const entry = _schedeLogsCacheByUser.get(userId);
    if (!entry) return null;
    const fresh = (Date.now() - entry.fetchedAt) < _SCHEDE_LOGS_CACHE_TTL_MS;
    return { logs: entry.logs, fresh };
}

async function _schedeClientDetailLoadLogs(userId, plans, { force = false } = {}) {
    if (!force) {
        const cached = _schedeGetCachedLogs(userId);
        if (cached && cached.fresh) return cached.logs;
    }
    if (_schedeLogsInFlightByUser.has(userId)) return _schedeLogsInFlightByUser.get(userId);

    const allExercises = plans.flatMap(p => p.workout_exercises || []);
    const allExIds = allExercises.map(e => e.id);
    if (!allExIds.length) {
        _schedeLogsCacheByUser.set(userId, { logs: [], fetchedAt: Date.now() });
        return [];
    }

    const promise = (async () => {
        try {
            const { data, error } = await _queryWithTimeout(supabaseClient
                .from('workout_logs')
                .select('exercise_id, log_date, weight_done, reps_done')
                .in('exercise_id', allExIds)
                .order('log_date', { ascending: true }));
            if (error) throw error;
            const logs = data || [];
            _schedeLogsCacheByUser.set(userId, { logs, fetchedAt: Date.now() });
            return logs;
        } catch (e) {
            console.error('[Schede] logs fetch error:', e);
            return null; // null = errore, distinto da [] = vuoto
        } finally {
            _schedeLogsInFlightByUser.delete(userId);
        }
    })();
    _schedeLogsInFlightByUser.set(userId, promise);
    return promise;
}

// ── Tab Schede ───────────────────────────────────────────────────────────────
// Render NON-BLOCCANTE: la lista delle schede deve comparire subito anche se
// la query workout_logs è lenta o va in timeout. I log servono solo per arricchire
// date-range e progress, non per decidere se le schede esistono.
function _schedeBuildClientSchedeHtml(plans, logsOrNull) {
    if (plans.length === 0) {
        return '<h4 class="schede-section-title">Schede assegnate</h4>' +
            '<div class="empty-slot">Nessuna scheda assegnata a questo cliente.</div>';
    }
    const _exIdToPlan = {};
    for (const plan of plans) {
        for (const ex of (plan.workout_exercises || [])) _exIdToPlan[ex.id] = plan.id;
    }
    const _planLogDates = {};
    if (Array.isArray(logsOrNull)) {
        for (const l of logsOrNull) {
            const pid = _exIdToPlan[l.exercise_id];
            if (!pid) continue;
            if (!_planLogDates[pid]) _planLogDates[pid] = [];
            _planLogDates[pid].push(l.log_date);
        }
    }

    let html = '<h4 class="schede-section-title">Schede assegnate</h4>';
    for (const plan of plans) {
        const badge = plan.active
            ? '<span class="schede-cd-statepill green"><span class="dot"></span>Attiva</span>'
            : '<span class="schede-cd-statepill gray"><span class="dot"></span>Inattiva</span>';
        const exCount = (plan.workout_exercises || []).length;
        const exLbl = exCount === 1 ? 'esercizio' : 'esercizi';
        const planDates = _planLogDates[plan.id];
        const dateRange = planDates?.length
            ? _fmtDate(planDates[0]) + ' → ' + _fmtDate(planDates[planDates.length - 1])
            : '';
        const sessions = planDates?.length ? new Set(planDates).size : 0;
        // Progress euristico: target 12 sessioni → 100%. Mostrato solo se ci sono log.
        const pct = sessions > 0 ? Math.min(100, Math.round(sessions * 100 / 12)) : 0;
        const sessLbl = sessions === 1 ? 'sessione' : 'sessioni';
        const planNameJs = _escHtml(plan.name).replace(/'/g, "\\'");
        const accentClass = plan.active ? 'is-active' : 'is-inactive';
        html += `<div class="schede-plan-card schede-client-card schede-cd-plancard ${accentClass}">
            <div class="schede-cd-plan-top">
                <div class="schede-cd-plan-info">
                    <div class="schede-cd-plan-name">${_escHtml(plan.name)}</div>
                    <div class="schede-cd-plan-meta">
                        <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="6.5" cy="12" r="2.5"/><circle cx="17.5" cy="12" r="2.5"/><line x1="9" y1="12" x2="15" y2="12"/></svg>${exCount} ${exLbl}</span>
                        ${dateRange ? '<span class="sep">·</span><span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="18" rx="2"/></svg>' + _escHtml(dateRange) + '</span>' : ''}
                    </div>
                </div>
                ${badge}
            </div>
            ${sessions > 0 ? `<div class="schede-cd-progress"><i style="width:${pct}%;"></i></div>
            <div class="schede-cd-progress-row">
                <span>${sessions} ${sessLbl}</span>
                <span class="pct">${pct}%</span>
            </div>` : ''}
            <div class="schede-cd-plan-actions">
                <button class="schede-cd-btn primary" onclick="_schedeEditPlan('${plan.id}')">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
                    Apri
                </button>
                <button class="schede-cd-icbtn" onclick="_schedeSaveAsTemplate('${plan.id}', '${planNameJs}')" title="Salva come template" aria-label="Salva come template">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/></svg>
                </button>
                <button class="schede-cd-icbtn danger" onclick="_schedeDeletePlanFromDetail('${plan.id}')" title="Elimina" aria-label="Elimina">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/></svg>
                </button>
            </div>
        </div>`;
    }
    return html;
}

function _schedeClientRenderSchede(container, userId, plans) {
    // Schede subito visibili. Se i log sono in cache fresca, includi date-range
    // e progress al primo render; altrimenti renderizza senza, lancia il fetch
    // in background e riarricchisci il DOM quando arrivano (o lascia così se
    // la RPC va in errore — niente "Errore caricamento" che nasconde le schede).
    const cached = _schedeGetCachedLogs(userId);
    const initialLogs = (cached && cached.fresh) ? cached.logs : null;
    container.innerHTML = _schedeBuildClientSchedeHtml(plans, initialLogs);

    if (initialLogs !== null || plans.length === 0) return;

    _schedeClientDetailLoadLogs(userId, plans).then(logs => {
        // Skip se l'utente nel frattempo ha cambiato cliente o tab
        if (_schedeClientUserId !== userId || _schedeClientDetailTab !== 'schede') return;
        if (logs === null) return; // mantiene il render senza date-range
        if (!container.isConnected) return;
        container.innerHTML = _schedeBuildClientSchedeHtml(plans, logs);
    });
}

// ── Tab Progressi ────────────────────────────────────────────────────────────
async function _schedeClientRenderProgressi(container, userId, plans) {
    container.innerHTML = '<div class="schede-loading">Caricamento progressi...</div>';
    const logs = await _schedeClientDetailLoadLogs(userId, plans);

    if (logs === null) {
        container.innerHTML = '<div class="empty-slot">Errore caricamento log. Riprova.</div>';
        return;
    }
    if (!logs.length) {
        container.innerHTML = '<div class="empty-slot">Nessun log registrato da questo cliente.</div>';
        return;
    }

    const allExercises = plans.flatMap(p => p.workout_exercises || []);
    const idToName = {};
    const nameToMuscle = {};
    for (const ex of allExercises) {
        idToName[ex.id] = ex.exercise_name;
        if (ex.muscle_group && !nameToMuscle[ex.exercise_name]) nameToMuscle[ex.exercise_name] = ex.muscle_group;
    }

    const logsByName = {};
    for (const l of logs) {
        const name = idToName[l.exercise_id] || 'Sconosciuto';
        if (!logsByName[name]) logsByName[name] = [];
        logsByName[name].push(l);
    }

    const totalSessions = new Set(logs.map(l => l.exercise_id + '|' + l.log_date)).size;
    const totalVolume = logs.reduce((s, l) => s + ((l.weight_done || 0) * (l.reps_done || 0)), 0);
    let html = `<div class="schede-stats-grid">
        <div class="schede-stat-card">
            <div class="schede-stat-icon">📊</div>
            <div class="schede-stat-value">${totalSessions}</div>
            <div class="schede-stat-label">Sessioni</div>
        </div>
        <div class="schede-stat-card">
            <div class="schede-stat-icon">🏋️</div>
            <div class="schede-stat-value">${logs.length}</div>
            <div class="schede-stat-label">Serie totali</div>
        </div>
        <div class="schede-stat-card">
            <div class="schede-stat-icon">📈</div>
            <div class="schede-stat-value">${totalVolume >= 1000 ? (totalVolume/1000).toFixed(1) + 't' : totalVolume + 'kg'}</div>
            <div class="schede-stat-label">Volume</div>
        </div>
    </div>`;

    const exerciseNames = Object.keys(logsByName).sort();
    let chartIdx = 0;
    const pendingCharts = [];
    for (const exName of exerciseNames) {
        const exLogs = logsByName[exName];
        const sessionMap = {};
        for (const l of exLogs) {
            if (l.weight_done == null) continue;
            const key = l.exercise_id + '|' + l.log_date;
            if (!sessionMap[key] || l.weight_done > sessionMap[key].weight) {
                sessionMap[key] = { date: l.log_date, weight: l.weight_done };
            }
        }
        const sessions = Object.values(sessionMap).sort((a, b) => a.date.localeCompare(b.date));
        if (!sessions.length) continue;

        const values = sessions.map(s => s.weight);
        const labels = sessions.map(s => _fmtDate(s.date));
        const maxW = Math.max(...values);
        const lastW = values[values.length - 1];
        const trend = values.length >= 2 ? lastW - values[0] : 0;
        const trendSign = trend > 0 ? '+' : '';
        const muscle = nameToMuscle[exName] || '';

        const canvasId = 'admin-pchart-' + (chartIdx++);
        const dbEx = _findExercise(exName);
        const imgUrl = dbEx ? (dbEx.immagine_url_small || dbEx.immagine_url || '') : '';
        const imgHtml = imgUrl
            ? `<img src="${_escHtml(imgUrl)}" alt="${_escHtml(exName)}" loading="lazy">`
            : '<div class="schede-admin-chart-img-placeholder">🏋️</div>';
        html += `<div class="schede-admin-chart-card">
            <div class="schede-admin-chart-img">${imgHtml}</div>
            <div class="schede-admin-chart-main">
                <div class="schede-chart-header">
                    <strong>${_escHtml(exName)}</strong>
                    ${muscle ? '<span class="schede-badge-active schede-badge-sm">' + _escHtml(muscle) + '</span>' : ''}
                </div>
                <canvas id="${canvasId}" width="400" height="140" style="width:100%;max-height:140px;"></canvas>
                <div class="schede-chart-stats">
                    <span>Max <strong>${maxW}kg</strong></span>
                    <span>Ultimo <strong>${lastW}kg</strong></span>
                    <span class="${trend >= 0 ? 'schede-trend-up' : 'schede-trend-down'}">Trend <strong>${trendSign}${trend.toFixed(1)}kg</strong></span>
                    <span>${sessions.length} sessioni</span>
                </div>
            </div>
        </div>`;
        pendingCharts.push({ canvasId, labels, values });
    }

    container.innerHTML = html;

    // Draw charts dopo aver scritto il DOM
    for (const { canvasId, labels, values } of pendingCharts) {
        setTimeout(() => {
            const canvas = document.getElementById(canvasId);
            if (canvas) _drawAdminChart(canvas, labels, values);
        }, 50);
    }
}

// ── Tab Report ───────────────────────────────────────────────────────────────
async function _schedeClientRenderReport(container, userId) {
    container.innerHTML = '<div id="schedeReportsSection" class="schede-reports-section"></div>';
    await _schedeRenderReportsSection(userId);
}

// Premium line chart for admin dashboard
function _drawAdminChart(canvas, labels, values) {
    const ctx = canvas.getContext('2d');
    const rect = canvas.getBoundingClientRect();
    const w = rect.width > 0 ? rect.width : 400;
    const h = 150;
    canvas.width = Math.round(w * 2);
    canvas.height = Math.round(h * 2);
    ctx.scale(2, 2);

    // Background
    ctx.fillStyle = '#f8fafc';
    const r = 10;
    ctx.beginPath();
    ctx.moveTo(r, 0); ctx.lineTo(w - r, 0); ctx.quadraticCurveTo(w, 0, w, r);
    ctx.lineTo(w, h - r); ctx.quadraticCurveTo(w, h, w - r, h);
    ctx.lineTo(r, h); ctx.quadraticCurveTo(0, h, 0, h - r);
    ctx.lineTo(0, r); ctx.quadraticCurveTo(0, 0, r, 0);
    ctx.closePath();
    ctx.fill();

    const pad = { top: 22, right: 14, bottom: 30, left: 42 };
    const cw = w - pad.left - pad.right;
    const ch = h - pad.top - pad.bottom;
    if (!values.length) return;

    const minV = Math.min(...values);
    const maxV = Math.max(...values);
    const range = maxV - minV || 1;
    const yMin = Math.max(0, minV - range * 0.1);
    const yMax = maxV + range * 0.1;
    const yRange = yMax - yMin || 1;

    // Grid lines — dashed, subtle
    ctx.strokeStyle = '#e2e8f0';
    ctx.lineWidth = 0.8;
    ctx.setLineDash([3, 3]);
    for (let i = 0; i <= 4; i++) {
        const y = pad.top + ch - (ch * i / 4);
        ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(pad.left + cw, y); ctx.stroke();
        ctx.fillStyle = '#94a3b8';
        ctx.font = '500 8.5px system-ui, sans-serif';
        ctx.textAlign = 'right';
        ctx.fillText(Math.round(yMin + yRange * i / 4), pad.left - 6, y + 3);
    }
    ctx.setLineDash([]);

    const pts = values.map((v, i) => ({
        x: pad.left + (values.length === 1 ? cw / 2 : (i / (values.length - 1)) * cw),
        y: pad.top + ch - ((v - yMin) / yRange) * ch,
        v,
    }));

    // Area fill — smooth gradient
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pad.top + ch);
    pts.forEach(p => ctx.lineTo(p.x, p.y));
    ctx.lineTo(pts[pts.length - 1].x, pad.top + ch);
    ctx.closePath();
    const grad = ctx.createLinearGradient(0, pad.top, 0, pad.top + ch);
    grad.addColorStop(0, 'rgba(0,174,239,0.22)');
    grad.addColorStop(0.6, 'rgba(0,174,239,0.08)');
    grad.addColorStop(1, 'rgba(0,174,239,0.01)');
    ctx.fillStyle = grad;
    ctx.fill();

    // Line — thicker, rounded
    ctx.strokeStyle = '#00AEEF';
    ctx.lineWidth = 2.8;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.beginPath();
    pts.forEach((p, i) => i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y));
    ctx.stroke();

    // Dots
    pts.forEach((p, i) => {
        const isLast = i === pts.length - 1;
        ctx.beginPath();
        ctx.arc(p.x, p.y, isLast ? 4.5 : 3, 0, Math.PI * 2);
        ctx.fillStyle = isLast ? '#00AEEF' : '#fff';
        ctx.fill();
        ctx.strokeStyle = isLast ? '#fff' : '#00AEEF';
        ctx.lineWidth = isLast ? 2 : 1.5;
        ctx.stroke();
        if (isLast) {
            ctx.beginPath();
            ctx.arc(p.x, p.y, 7, 0, Math.PI * 2);
            ctx.strokeStyle = 'rgba(0,174,239,0.2)';
            ctx.lineWidth = 2;
            ctx.stroke();
        }
    });

    // X labels
    ctx.fillStyle = '#94a3b8';
    ctx.font = '500 7.5px system-ui, sans-serif';
    ctx.textAlign = 'center';
    const step = Math.max(1, Math.floor(labels.length / 6));
    labels.forEach((lbl, i) => {
        if (i % step === 0 || i === labels.length - 1) ctx.fillText(lbl, pts[i].x, pad.top + ch + 14);
    });

    // Value badge on last point
    if (pts.length > 0) {
        const last = pts[pts.length - 1];
        const label = last.v + 'kg';
        ctx.font = 'bold 9.5px system-ui, sans-serif';
        const tw = ctx.measureText(label).width;
        const bx = Math.min(last.x, w - pad.right - tw / 2 - 6);
        const by = last.y - 14;
        ctx.fillStyle = '#0f172a';
        ctx.beginPath();
        const br = 4;
        ctx.moveTo(bx - tw/2 - 5 + br, by - 8);
        ctx.lineTo(bx + tw/2 + 5 - br, by - 8);
        ctx.quadraticCurveTo(bx + tw/2 + 5, by - 8, bx + tw/2 + 5, by - 8 + br);
        ctx.lineTo(bx + tw/2 + 5, by + 2 - br);
        ctx.quadraticCurveTo(bx + tw/2 + 5, by + 2, bx + tw/2 + 5 - br, by + 2);
        ctx.lineTo(bx - tw/2 - 5 + br, by + 2);
        ctx.quadraticCurveTo(bx - tw/2 - 5, by + 2, bx - tw/2 - 5, by + 2 - br);
        ctx.lineTo(bx - tw/2 - 5, by - 8 + br);
        ctx.quadraticCurveTo(bx - tw/2 - 5, by - 8, bx - tw/2 - 5 + br, by - 8);
        ctx.closePath();
        ctx.fill();
        ctx.fillStyle = '#fff';
        ctx.textAlign = 'center';
        ctx.fillText(label, bx, by - 1);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// LIST VIEW
// ═══════════════════════════════════════════════════════════════════════════════
function _renderSchedeList(container) {
    const plans = WorkoutPlanStorage.getAllPlans();
    const allUsers = _schedeGetRegisteredUsers();
    const nameMap = {};
    for (const u of allUsers) nameMap[u.userId] = u.name || u.email || u.userId;

    // Templates (no user_id)
    const templates = plans.filter(p => !p.user_id);

    let html = '';

    // Assign template to client bar (top)
    if (templates.length > 0) {
        html += `<div class="schede-assign-bar schede-assign-bar--schede">
            <div class="schede-assign-row schede-assign-row--schede">
                <div class="schede-assign-field">
                    <label class="schede-assign-label">Template</label>
                    <select id="schedeQuickTemplate">
                        <option value="">— Seleziona template —</option>
                        ${templates.map(t => {
                            const exC = (t.workout_exercises || []).length;
                            const dayC = [...new Set((t.workout_exercises || []).map(e => e.day_label))].length;
                            return `<option value="${t.id}">${_escHtml(t.name)} (${exC} es. · ${dayC} gg)</option>`;
                        }).join('')}
                    </select>
                </div>
                <div class="schede-assign-field schede-assign-field--client">
                    <label class="schede-assign-label">Cliente</label>
                    <div class="schede-client-selector" style="position:relative;">
                        <input type="text" id="schedeQuickClientSearch" placeholder="Cerca cliente..."
                               oninput="_schedeQuickSearchClient()" autocomplete="off">
                        <div id="schedeQuickClientDropdown" class="debtor-search-dropdown" style="display:none;"></div>
                    </div>
                </div>
                <button class="btn-primary schede-assign-btn" onclick="_schedeQuickAssign()">Assegna</button>
            </div>
        </div>`;
    }

    // Templates section
    html += '<h4 class="schede-section-title">Template standard</h4>';
    if (templates.length === 0) {
        html += '<div class="empty-slot" style="padding:0.8rem;">Nessun template. Crea una scheda senza selezionare un cliente.</div>';
    } else {
        html += '<div class="schede-plan-list" id="schedePlanList">';
        for (const plan of templates) {
            const exCount = (plan.workout_exercises || []).length;
            const days = [...new Set((plan.workout_exercises || []).map(e => e.day_label))];
            html += `
            <div class="schede-plan-card" data-client="template ${_escHtml(plan.name).toLowerCase()}">
                <div class="schede-plan-card-header">
                    <div class="schede-plan-card-info">
                        <div class="schede-plan-client"><span class="schede-badge-template">Template</span></div>
                        <div class="schede-plan-name">${_escHtml(plan.name)}</div>
                        <div class="schede-plan-meta">${exCount} esercizi &middot; ${days.length} giorni</div>
                    </div>
                    <div class="schede-plan-actions">
                        <button class="tpl-act tpl-act--edit" onclick="_schedeEditPlan('${plan.id}')" title="Modifica" aria-label="Modifica"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg></button>
                        <button class="tpl-act tpl-act--del" onclick="_schedeDeletePlan('${plan.id}')" title="Elimina" aria-label="Elimina"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg></button>
                    </div>
                </div>
            </div>`;
        }
        html += '</div>';
    }

    // FAB rotondo "+" in basso a destra: apre _schedeNewPlan(). Posizionato
    // fixed via CSS, sopra al dock/menu mobile (bottom: 84px su <=768px).
    html += `<button class="schede-fab" onclick="_schedeNewPlan()" aria-label="Nuova scheda" title="Nuova scheda">+</button>`;

    container.innerHTML = html;
}

function _fmtDate(iso) {
    if (!iso) return '';
    const d = new Date(iso + 'T00:00:00');
    return d.toLocaleDateString('it-IT', { day: '2-digit', month: 'short' });
}

// ═══════════════════════════════════════════════════════════════════════════════
// PLAN EDITOR
// ═══════════════════════════════════════════════════════════════════════════════
function _schedeNewPlan() {
    _editingPlan = null;
    _currentPlanId = null;
    _editDayLabels = ['Giorno A'];
    _editActiveDay = 'Giorno A';
    _schedeView = 'edit';
    renderSchedeTab();
}

function _schedeEditPlan(planId) {
    const plan = WorkoutPlanStorage.getPlanById(planId);
    if (!plan) return;
    _editingPlan = plan;
    _currentPlanId = planId;
    const days = [...new Set((plan.workout_exercises || []).map(e => e.day_label))];
    _editDayLabels = days.length ? days : ['Giorno A'];
    _editActiveDay = _editDayLabels[0];
    _schedeView = 'edit';
    renderSchedeTab();
}

// Sotto questa soglia usiamo l'editor card-based "mobile" (stile allenamento.html).
function _isAdmMobile() {
    return window.matchMedia('(max-width: 767px)').matches;
}

// Stato attivo dell'edit overlay mobile (riapertura dopo refresh).
let _admMobActiveEdit = null;

function _renderPlanEditor(container) {
    if (_isAdmMobile()) {
        _renderPlanEditorMobile(container);
        return;
    }
    return _renderPlanEditorDesktop(container);
}

function _renderPlanEditorDesktop(container) {
    const plan = _editingPlan;
    const isNew = !plan;

    // Client selector — only registered users
    const allUsers = _schedeGetRegisteredUsers();
    const selectedUserId = plan?.user_id || '';
    const selectedUserName = selectedUserId ? (allUsers.find(u => u.userId === selectedUserId)?.name || '') : '';

    const hasNotes = !!(plan?.notes);
    let html = `
    <div class="schede-editor">
        <div class="schede-editor-topbar">
            <button class="schede-back-btn" onclick="_schedeBackToList()" aria-label="Indietro"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg></button>
            <div class="schede-ed-meta">
                <div class="schede-ed-eyebrow">${isNew ? 'Nuova scheda' : 'Modifica scheda'}</div>
                <div class="schede-ed-name">${_escHtml(plan?.name || 'Senza nome')}</div>
            </div>
            <label class="schede-toggle schede-toggle--topbar" title="${!plan || plan.active ? 'Attiva' : 'Inattiva'}">
                <input type="checkbox" id="schedePlanActive" ${!plan || plan.active ? 'checked' : ''} onchange="_schedeAutoSavePlanNow()">
                <span class="schede-toggle-slider"></span>
            </label>
        </div>
        <div class="schede-editor-form schede-editor-form--compact">
            <div class="schede-form-grid">
                <div class="schede-form-row schede-form-cell--name">
                    <label>Nome</label>
                    <input type="text" id="schedePlanName" value="${_escHtml(plan?.name || '')}" placeholder="es. Scheda Forza"
                           oninput="_schedeAutoSavePlan()" onblur="_schedeAutoSavePlanNow()">
                </div>
                <div class="schede-form-row schede-form-cell--client" ${!isNew && !selectedUserId ? 'style="display:none"' : ''}>
                    <label>Cliente</label>
                    <div class="schede-client-selector">
                        <input type="text" id="schedeClientSearch" placeholder="Template..."
                               value="${_escHtml(selectedUserName)}"
                               oninput="_schedeSearchClient()" autocomplete="off"
                               onfocus="_schedeSearchClient()"
                               ${selectedUserId ? 'data-user-id="' + selectedUserId + '"' : ''}>
                        <div id="schedeClientDropdown" class="debtor-search-dropdown" style="display:none;"></div>
                    </div>
                </div>
            </div>
            <details class="schede-notes-details"${hasNotes ? ' open' : ''}>
                <summary>Note</summary>
                <textarea id="schedePlanNotes" rows="2" placeholder="Note generali..."
                          oninput="_schedeAutoSavePlan()" onblur="_schedeAutoSavePlanNow()">${_escHtml(plan?.notes || '')}</textarea>
            </details>
        </div>

        <div class="schede-day-section">
            <div class="schede-day-tabs" id="schedeDayTabs">
                ${_editDayLabels.map(d => `<button class="schede-day-tab${d === _editActiveDay ? ' active' : ''}" onclick="_schedeSelectDay('${_escHtml(d)}')">${_escHtml(d)}</button>`).join('')}
                <button class="schede-day-tab schede-day-tab--add" onclick="_schedeAddDay()">+</button>
                ${_editDayLabels.length > 1 ? `<button class="schede-day-tab schede-day-tab--remove" onclick="_schedeRemoveDay()" title="Rimuovi giorno corrente">🗑️</button>` : ''}
            </div>
            <div class="schede-day-rename">
                <input type="text" id="schedeDayRename" value="${_escHtml(_editActiveDay)}" onchange="_schedeRenameDay(this.value)" placeholder="Nome giorno">
            </div>
            <div class="schede-exercises-list" id="schedeExercisesList">
                ${_renderExercisesForDay()}
            </div>
            <div class="schede-add-btns">
                <button class="schede-add-exercise-btn" onclick="_schedeAddExerciseRow()">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" width="16" height="16"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
                    Esercizio
                </button>
                <button class="schede-add-ss-btn" onclick="_schedeAddSupersetRow()">
                    <span class="schede-add-ss-icon">SS</span>
                    Super Serie
                </button>
                <button class="schede-add-cc-btn" onclick="_schedeAddCircuitRow()">
                    <span class="schede-add-cc-icon">C</span>
                    Circuito
                </button>
            </div>
        </div>
    </div>`;

    container.innerHTML = html;

    // Hook autosave su nome/cliente/note/attivo (i listener inline sono nel
    // template HTML qui sopra: oninput → debounced, onblur → flush immediato).

    // Applica prefill di una nuova scheda creata da "Actual → Aggiungi"
    if (isNew && _schedePendingNewPlanPrefill) {
        const pref = _schedePendingNewPlanPrefill;
        _schedePendingNewPlanPrefill = null;
        const nameInput = container.querySelector('#schedePlanName');
        if (nameInput) nameInput.value = pref.planName || '';
        const clientInput = container.querySelector('#schedeClientSearch');
        if (clientInput) {
            clientInput.value = pref.clientName || '';
            if (pref.userId) clientInput.dataset.userId = pref.userId;
        }
    }
}

function _renderExercisesForDay() {
    const exercises = _editingPlan?.workout_exercises?.filter(e => e.day_label === _editActiveDay) || [];

    if (exercises.length === 0 && _editingPlan) {
        return '<div class="empty-slot">Nessun esercizio per questo giorno. Clicca "+ Aggiungi esercizio".</div>';
    }
    if (exercises.length === 0) {
        return '<div class="empty-slot">Salva la scheda, poi aggiungi esercizi.</div>';
    }

    // Build superset / circuit group maps
    const ssRendered = new Set();
    const ssMap = {};
    const ccRendered = new Set();
    const ccMap = {};
    for (const ex of exercises) {
        if (ex.superset_group) {
            if (!ssMap[ex.superset_group]) ssMap[ex.superset_group] = [];
            ssMap[ex.superset_group].push(ex);
        }
        if (ex.circuit_group) {
            if (!ccMap[ex.circuit_group]) ccMap[ex.circuit_group] = [];
            ccMap[ex.circuit_group].push(ex);
        }
    }
    for (const k of Object.keys(ccMap)) ccMap[k].sort((a, b) => a.sort_order - b.sort_order);

    // Build logical "blocks" list: each block is either a single exercise or
    // a whole super serie group. Up/Down arrows move exercises at block level
    // (a normal exercise hops OVER a full SS block, not one member at a time).
    const blocks = _schedeBuildDayBlocks(exercises);
    const totalBlocks = blocks.length;

    let html = '';
    exercises.forEach((ex) => {
        // ── Superset block ──────────────────────────────────────
        if (ex.superset_group && !ssRendered.has(ex.superset_group)) {
            ssRendered.add(ex.superset_group);
            const pair = ssMap[ex.superset_group] || [ex];
            const bIdx = blocks.findIndex(b => b.type === 'superset' && b.groupId === ex.superset_group);
            const ssUp = bIdx > 0;
            const ssDown = bIdx >= 0 && bIdx < totalBlocks - 1;
            html += `<div class="schede-ss-block">
                <span class="schede-ss-badge">SUPER SERIE</span>
                <div class="schede-ss-move">
                    ${ssUp ? `<button onclick="_schedeMoveSuperset('${ex.superset_group}', -1)" title="Su">▲</button>` : ''}
                    ${ssDown ? `<button onclick="_schedeMoveSuperset('${ex.superset_group}', 1)" title="Giù">▼</button>` : ''}
                </div>
                <button class="schede-ss-delete" onclick="_schedeDeleteSuperset('${ex.superset_group}')" title="Elimina super serie">✕ SS</button>`;
            pair.forEach(ssEx => {
                const dbEx = _findExerciseForCard(ssEx);
                const catLabel = dbEx ? dbEx.categoria : (ssEx.muscle_group || '');
                const _isCardio = (ssEx.muscle_group || '').toLowerCase() === 'cardio';
                const thumbUrlSs = dbEx && dbEx.immagine_url_small ? dbEx.immagine_url_small : '';
                const specTextSs = _isCardio
                    ? `${_escHtml(String(ssEx.reps ?? '\u2014'))} min`
                    : `${ssEx.sets || 0}\u00d7${_escHtml(String(ssEx.reps ?? '\u2014'))} \u00b7 ${ssEx.weight_kg ?? '\u2014'}kg`;
                html += `
                <details class="schede-exercise-row" data-ex-id="${ssEx.id}">
                    <summary class="schede-ex-summary">
                        <span class="schede-ex-drag-handle" aria-hidden="true">${_DRAG_SVG}</span>
                        ${thumbUrlSs ? `<img class="schede-ex-icon" src="${_escHtml(thumbUrlSs)}" alt="" loading="lazy">` : `<span class="schede-ex-icon schede-ex-icon--ph" aria-hidden="true">${_DUMB_SVG}</span>`}
                        <div class="schede-ex-info">
                            <div class="schede-ex-preview-name">${_escHtml(ssEx.exercise_name || 'Senza nome')}</div>
                            <div class="schede-ex-preview-meta">
                                ${catLabel ? `<span class="schede-ex-muscle-badge">${_escHtml(catLabel)}</span>` : ''}
                                <span class="schede-ex-spec">${specTextSs}</span>
                            </div>
                        </div>
                        <span class="schede-ex-chev" aria-hidden="true">${_CHEV_SVG}</span>
                    </summary>
                    <div class="schede-ex-body">
                        <div class="schede-ex-fields">
                            <div class="schede-ex-top-row schede-ex-top-row--compact">
                                <div class="schede-ex-picker-wrap">
                                    <button type="button" class="schede-ex-change-cta" onclick="event.preventDefault();_schedeOpenPicker('${ssEx.id}')">✎ Cambia esercizio</button>
                                    ${dbEx ? `<button type="button" class="schede-ex-info-btn" onclick="event.preventDefault();_schedeShowExDetail('${_escHtml(dbEx.slug)}')" title="Dettaglio">i</button>` : ''}
                                    <div class="schede-ex-picker-dropdown" id="picker-${ssEx.id}" style="display:none;"></div>
                                </div>
                            </div>
                            <div class="schede-ex-params">
                                ${_isCardio ? `
                                <label>Min<input type="text" value="${_escHtml(ssEx.reps)}" placeholder="20" onchange="_schedeUpdateExField('${ssEx.id}','reps',this.value)"></label>
                                ` : `
                                <label>Serie<input type="number" min="1" max="20" value="${ssEx.sets}" onchange="_schedeUpdateExField('${ssEx.id}','sets',+this.value)"></label>
                                <label>Reps<input type="text" value="${_escHtml(ssEx.reps)}" placeholder="10" onchange="_schedeUpdateExField('${ssEx.id}','reps',this.value)"></label>
                                <label>Kg<input type="number" step="0.5" min="0" value="${ssEx.weight_kg ?? ''}" placeholder="\u2014" onchange="_schedeUpdateExField('${ssEx.id}','weight_kg',this.value?+this.value:null)"></label>
                                <label>Rec.<input type="number" min="0" step="15" value="${ssEx.rest_seconds ?? 0}" onchange="_schedeUpdateExField('${ssEx.id}','rest_seconds',+this.value)"></label>
                                `}
                            </div>
                            <input type="text" class="schede-ex-notes" value="${_escHtml(ssEx.notes || '')}" placeholder="Note esercizio..."
                                   onchange="_schedeUpdateExField('${ssEx.id}','notes',this.value)">
                        </div>
                    </div>
                </details>`;
            });
            html += '</div>';
            return;
        }
        // Skip second exercise in superset
        if (ex.superset_group && ssRendered.has(ex.superset_group)) return;

        // ── Circuit block ───────────────────────────────────────
        if (ex.circuit_group && !ccRendered.has(ex.circuit_group)) {
            ccRendered.add(ex.circuit_group);
            const members = ccMap[ex.circuit_group] || [ex];
            const ccBIdx = blocks.findIndex(b => b.type === 'circuit' && b.groupId === ex.circuit_group);
            const ccUp = ccBIdx > 0;
            const ccDown = ccBIdx >= 0 && ccBIdx < totalBlocks - 1;
            const rounds = members[0].sets || 1;
            const restSec = members[members.length - 1].rest_seconds || 0;
            html += `<div class="schede-cc-block">
                <span class="schede-cc-badge">CIRCUITO</span>
                <div class="schede-ss-move">
                    ${ccUp ? `<button onclick="_schedeMoveCircuit('${ex.circuit_group}', -1)" title="Su">▲</button>` : ''}
                    ${ccDown ? `<button onclick="_schedeMoveCircuit('${ex.circuit_group}', 1)" title="Giù">▼</button>` : ''}
                </div>
                <button class="schede-ss-delete" onclick="_schedeDeleteCircuit('${ex.circuit_group}')" title="Elimina circuito">✕ C</button>
                <div class="schede-cc-params">
                    <label>Giri<input type="number" min="1" max="20" value="${rounds}" onchange="_schedeUpdateCircuitRounds('${ex.circuit_group}', this.value)"></label>
                    <label>Pausa giri<input type="number" min="0" step="15" value="${restSec}" onchange="_schedeUpdateCircuitRest('${ex.circuit_group}', this.value)"></label>
                </div>`;
            members.forEach(ccEx => {
                const dbEx = _findExerciseForCard(ccEx);
                const catLabel = dbEx ? dbEx.categoria : (ccEx.muscle_group || '');
                const _isCardio = (ccEx.muscle_group || '').toLowerCase() === 'cardio';
                const thumbUrlCc = dbEx && dbEx.immagine_url_small ? dbEx.immagine_url_small : '';
                const specTextCc = _isCardio
                    ? `${_escHtml(String(ccEx.reps ?? '—'))} min`
                    : `${rounds} giri × ${_escHtml(String(ccEx.reps ?? '—'))} · ${ccEx.weight_kg ?? '—'}kg`;
                html += `
                <details class="schede-exercise-row schede-cc-member" data-ex-id="${ccEx.id}">
                    <summary class="schede-ex-summary">
                        <span class="schede-ex-drag-handle" aria-hidden="true">${_DRAG_SVG}</span>
                        ${thumbUrlCc ? `<img class="schede-ex-icon" src="${_escHtml(thumbUrlCc)}" alt="" loading="lazy">` : `<span class="schede-ex-icon schede-ex-icon--ph" aria-hidden="true">${_DUMB_SVG}</span>`}
                        <div class="schede-ex-info">
                            <div class="schede-ex-preview-name">${_escHtml(ccEx.exercise_name || 'Senza nome')}</div>
                            <div class="schede-ex-preview-meta">
                                ${catLabel ? `<span class="schede-ex-muscle-badge">${_escHtml(catLabel)}</span>` : ''}
                                <span class="schede-ex-spec">${specTextCc}</span>
                            </div>
                        </div>
                        <button class="schede-cc-member-remove" onclick="event.preventDefault();event.stopPropagation();_schedeRemoveFromCircuit('${ccEx.id}')" title="Rimuovi dal circuito" aria-label="Rimuovi dal circuito">×</button>
                        <span class="schede-ex-chev" aria-hidden="true">${_CHEV_SVG}</span>
                    </summary>
                    <div class="schede-ex-body">
                        <div class="schede-ex-fields">
                            <div class="schede-ex-top-row schede-ex-top-row--compact">
                                <div class="schede-ex-picker-wrap">
                                    <button type="button" class="schede-ex-change-cta" onclick="event.preventDefault();_schedeOpenPicker('${ccEx.id}')">✎ Cambia esercizio</button>
                                    ${dbEx ? `<button type="button" class="schede-ex-info-btn" onclick="event.preventDefault();_schedeShowExDetail('${_escHtml(dbEx.slug)}')" title="Dettaglio">i</button>` : ''}
                                    <div class="schede-ex-picker-dropdown" id="picker-${ccEx.id}" style="display:none;"></div>
                                </div>
                            </div>
                            <div class="schede-ex-params">
                                ${_isCardio ? `
                                <label>Min<input type="text" value="${_escHtml(ccEx.reps)}" placeholder="20" onchange="_schedeUpdateExField('${ccEx.id}','reps',this.value)"></label>
                                ` : `
                                <label>Reps<input type="text" value="${_escHtml(ccEx.reps)}" placeholder="10" onchange="_schedeUpdateExField('${ccEx.id}','reps',this.value)"></label>
                                <label>Kg<input type="number" step="0.5" min="0" value="${ccEx.weight_kg ?? ''}" placeholder="—" onchange="_schedeUpdateExField('${ccEx.id}','weight_kg',this.value?+this.value:null)"></label>
                                `}
                            </div>
                            <input type="text" class="schede-ex-notes" value="${_escHtml(ccEx.notes || '')}" placeholder="Note esercizio..."
                                   onchange="_schedeUpdateExField('${ccEx.id}','notes',this.value)">
                        </div>
                    </div>
                </details>`;
            });
            html += `<button class="schede-cc-add-member" onclick="_schedeAddExerciseToCircuit('${ex.circuit_group}')">+ Aggiungi esercizio al circuito</button>`;
            html += '</div>';
            return;
        }
        if (ex.circuit_group && ccRendered.has(ex.circuit_group)) return;

        // ── Normal exercise row ─────────────────────────────────
        const dbEx = _findExerciseForCard(ex);
        const catLabel = dbEx ? dbEx.categoria : (ex.muscle_group || '');
        const _isCardio = (ex.muscle_group || '').toLowerCase() === 'cardio';
        const bIdxN = blocks.findIndex(b => b.type === 'single' && b.ids[0] === ex.id);
        const nUp = bIdxN > 0;
        const nDown = bIdxN >= 0 && bIdxN < totalBlocks - 1;
        const thumbUrlN = dbEx && dbEx.immagine_url_small ? dbEx.immagine_url_small : '';
        const specTextN = _isCardio
            ? `${_escHtml(String(ex.reps ?? '—'))} min`
            : `${ex.sets || 0}×${_escHtml(String(ex.reps ?? '—'))} · ${ex.weight_kg ?? '—'}kg`;
        html += `
        <details class="schede-exercise-row" data-ex-id="${ex.id}">
            <summary class="schede-ex-summary">
                <span class="schede-ex-drag-handle" aria-hidden="true">${_DRAG_SVG}</span>
                ${thumbUrlN ? `<img class="schede-ex-icon" src="${_escHtml(thumbUrlN)}" alt="" loading="lazy">` : `<span class="schede-ex-icon schede-ex-icon--ph" aria-hidden="true">${_DUMB_SVG}</span>`}
                <div class="schede-ex-info">
                    <div class="schede-ex-preview-name">${_escHtml(ex.exercise_name || 'Senza nome')}</div>
                    <div class="schede-ex-preview-meta">
                        ${catLabel ? `<span class="schede-ex-muscle-badge">${_escHtml(catLabel)}</span>` : ''}
                        <span class="schede-ex-spec">${specTextN}</span>
                    </div>
                </div>
                <span class="schede-ex-reorder" aria-hidden="true">
                    <button class="schede-ex-move" ${nUp ? '' : 'disabled'} onclick="event.preventDefault();event.stopPropagation();_schedeMoveExercise('${ex.id}', -1)" title="Sposta su" aria-label="Sposta su">▲</button>
                    <button class="schede-ex-move" ${nDown ? '' : 'disabled'} onclick="event.preventDefault();event.stopPropagation();_schedeMoveExercise('${ex.id}', 1)" title="Sposta giù" aria-label="Sposta giù">▼</button>
                </span>
                <span class="schede-ex-chev" aria-hidden="true">${_CHEV_SVG}</span>
            </summary>
            <div class="schede-ex-body">
                <div class="schede-ex-fields">
                    <div class="schede-ex-top-row schede-ex-top-row--compact">
                        <div class="schede-ex-picker-wrap">
                            <button type="button" class="schede-ex-change-cta" onclick="event.preventDefault();_schedeOpenPicker('${ex.id}')">✎ Cambia esercizio</button>
                            ${dbEx ? `<button type="button" class="schede-ex-info-btn" onclick="event.preventDefault();_schedeShowExDetail('${_escHtml(dbEx.slug)}')" title="Dettaglio">i</button>` : ''}
                            <div class="schede-ex-picker-dropdown" id="picker-${ex.id}" style="display:none;"></div>
                        </div>
                    </div>
                    <div class="schede-ex-params">
                        ${_isCardio ? `
                        <label>Min<input type="text" value="${_escHtml(ex.reps)}" placeholder="20" onchange="_schedeUpdateExField('${ex.id}','reps',this.value)"></label>
                        ` : `
                        <label>Serie<input type="number" min="1" max="20" value="${ex.sets}" onchange="_schedeUpdateExField('${ex.id}','sets',+this.value)"></label>
                        <label>Reps<input type="text" value="${_escHtml(ex.reps)}" placeholder="10" onchange="_schedeUpdateExField('${ex.id}','reps',this.value)"></label>
                        <label>Kg<input type="number" step="0.5" min="0" value="${ex.weight_kg ?? ''}" placeholder="—" onchange="_schedeUpdateExField('${ex.id}','weight_kg',this.value?+this.value:null)"></label>
                        <label>Rec.<input type="number" min="0" step="15" value="${ex.rest_seconds ?? 90}" onchange="_schedeUpdateExField('${ex.id}','rest_seconds',+this.value)"></label>
                        `}
                    </div>
                    <input type="text" class="schede-ex-notes" value="${_escHtml(ex.notes || '')}" placeholder="Note esercizio..."
                           onchange="_schedeUpdateExField('${ex.id}','notes',this.value)">
                </div>
                <button class="schede-ex-delete-btn" onclick="_schedeDeleteExercise('${ex.id}')">Rimuovi</button>
            </div>
        </details>`;
    });
    return html;
}

// Icone inline per il summary delle exercise card (Lucide-style)
const _DRAG_SVG = '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="9" cy="6" r="1.5"/><circle cx="9" cy="12" r="1.5"/><circle cx="9" cy="18" r="1.5"/><circle cx="15" cy="6" r="1.5"/><circle cx="15" cy="12" r="1.5"/><circle cx="15" cy="18" r="1.5"/></svg>';
const _DUMB_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 6.5h11M6.5 17.5h11M4 9v6M20 9v6M2 11v2M22 11v2"/></svg>';
const _CHEV_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>';

// ── Client search (only registered users with UUID) ──────────────────────────
var _schedeSearchClient = _debounce(function() {
    const input = document.getElementById('schedeClientSearch');
    const dropdown = document.getElementById('schedeClientDropdown');
    const q = (input?.value || '').toLowerCase();
    if (!q || q.length < 1) { dropdown.style.display = 'none'; return; }

    const matches = _schedeGetRegisteredUsers().filter(u =>
        (u.name || '').toLowerCase().includes(q) ||
        (u.email || '').toLowerCase().includes(q)
    );

    if (matches.length === 0) {
        dropdown.innerHTML = '<div class="dropdown-no-results">Nessun cliente registrato trovato</div>';
    } else {
        dropdown.innerHTML = matches.slice(0, 10).map(u =>
            `<div class="dropdown-item" onclick="_schedeSelectClient('${u.userId}', '${_escHtml(u.name || u.email).replace(/'/g, "\\'")}')">
                <span class="dropdown-item-name">${_escHtml(u.name || 'Senza nome')}</span>
            </div>`
        ).join('');
    }
    dropdown.style.display = 'block';
}, 150);

function _schedeSelectClient(userId, name) {
    const input = document.getElementById('schedeClientSearch');
    input.value = name;
    input.dataset.userId = userId;
    document.getElementById('schedeClientDropdown').style.display = 'none';
    // Flush autosave subito, prima che l'utente cambi vista o input.
    _schedeAutoSavePlanNow();
}

// ── Auto-save scheda (sostituisce il bottone Salva esplicito) ───────────────
// La versione "Now" è chiamata su blur/onchange e prima delle navigazioni.
// La versione debounced è chiamata su oninput per non sparare update ad ogni tasto.
// Niente _schedeRefreshEditor dopo autosave: preserva il focus dell'input.
async function _schedeAutoSavePlanNow() {
    const nameInput = document.getElementById('schedePlanName');
    if (!nameInput) return;
    const clientInput = document.getElementById('schedeClientSearch');
    let userId = clientInput?.dataset?.userId || null;
    if (userId === 'undefined' || (userId && userId.length < 10)) userId = null;
    const planName = nameInput.value?.trim();
    const active = document.getElementById('schedePlanActive')?.checked ?? true;
    const notes = document.getElementById('schedePlanNotes')?.value?.trim() || null;
    try {
        if (_editingPlan) {
            const updates = { user_id: userId, active, notes };
            if (planName) updates.name = planName; // non azzerare il nome
            await WorkoutPlanStorage.updatePlan(_editingPlan.id, updates);
            Object.assign(_editingPlan, updates);
        } else if (planName) {
            const newPlan = await WorkoutPlanStorage.createPlan({
                user_id: userId, name: planName, notes,
            });
            _editingPlan = newPlan;
            _currentPlanId = newPlan.id;
        }
    } catch (e) {
        console.error('[Schede] auto-save error:', e);
        if (typeof showToast === 'function') showToast('Errore salvataggio', 'error');
    }
}

const _schedeAutoSavePlan = _debounce(_schedeAutoSavePlanNow, 600);

// ── Editor refresh helper ────────────────────────────────────────────────────
// Riallinea _editingPlan con la cache corrente: syncFromSupabase (background
// o realtime) sostituisce WorkoutPlanStorage._cache con nuovi oggetti, mentre
// i CRUD mutano la cache fresca via getPlanById. Senza rebind, _editingPlan
// resta un riferimento detached e l'editor renderizza (o mutea) dati stantii.
function _schedeSyncEditingPlan() {
    if (_currentPlanId) {
        const fresh = WorkoutPlanStorage.getPlanById(_currentPlanId);
        if (fresh) _editingPlan = fresh;
    }
}

function _schedeRefreshEditor() {
    _schedeSyncEditingPlan();
    const inner = document.getElementById('schedeInner') || document.getElementById('schedeContainer');
    if (inner) _renderPlanEditor(inner);
    // Mobile: se c'era un overlay edit aperto, riaprilo con i dati freschi
    // (se l'entità che editava non esiste più, chiudilo).
    if (typeof _isAdmMobile === 'function' && _isAdmMobile() && _admMobActiveEdit) {
        const { type, id } = _admMobActiveEdit;
        const exists = (_editingPlan?.workout_exercises || []).some(e =>
            (type === 'ex' && e.id === id) ||
            (type === 'ss' && e.superset_group === id) ||
            (type === 'cc' && e.circuit_group === id)
        );
        if (!exists) {
            _admMobActiveEdit = null;
            const ov = document.getElementById('admMobEditOverlay');
            if (ov) ov.remove();
            document.body.style.overflow = '';
        } else {
            _admMobReopenActiveEdit();
        }
    }
}

// ── Day management ───────────────────────────────────────────────────────────
function _schedeSelectDay(day) {
    _editActiveDay = day;
    _schedeRefreshEditor();
}

function _schedeAddDay() {
    const nextLetter = String.fromCharCode(65 + _editDayLabels.length);
    const newLabel = 'Giorno ' + nextLetter;
    _editDayLabels.push(newLabel);
    _editActiveDay = newLabel;
    _schedeRefreshEditor();
}

async function _schedeRemoveDay() {
    if (_editDayLabels.length <= 1) return;
    _schedeSyncEditingPlan();
    if (_editingPlan) {
        const toDelete = (_editingPlan.workout_exercises || []).filter(e => e.day_label === _editActiveDay);
        for (const ex of toDelete) {
            try { await WorkoutPlanStorage.deleteExercise(ex.id); } catch (e) { console.error('[Schede] deleteExercise failed:', ex.id, e); }
        }
    }
    _editDayLabels = _editDayLabels.filter(d => d !== _editActiveDay);
    _editActiveDay = _editDayLabels[0];
    _schedeRefreshEditor();
}

function _schedeRenameDay(newName) {
    if (!newName.trim()) return;
    const oldName = _editActiveDay;
    _schedeSyncEditingPlan();
    if (_editingPlan) {
        (_editingPlan.workout_exercises || []).forEach(ex => {
            if (ex.day_label === oldName) {
                ex.day_label = newName;
                WorkoutPlanStorage.updateExercise(ex.id, { day_label: newName }).catch(e => { console.error('[Schede] renameDay failed:', ex.id, e); });
            }
        });
    }
    const idx = _editDayLabels.indexOf(oldName);
    if (idx >= 0) _editDayLabels[idx] = newName;
    _editActiveDay = newName;
    _schedeRefreshEditor();
}

// ── Exercise CRUD ────────────────────────────────────────────────────────────
async function _schedeAddExerciseRow() {
    if (!_editingPlan) {
        await _schedeSavePlan();
        if (!_editingPlan) return;
    }
    try {
        await WorkoutPlanStorage.addExercise(_editingPlan.id, {
            day_label: _editActiveDay,
            exercise_name: 'Nuovo esercizio',
            sets: 3,
            reps: '10',
        });
        _schedeRefreshEditor();
    } catch (e) {
        console.error('[Schede] addExercise error:', e);
        if (typeof showToast === 'function') showToast('Errore aggiunta esercizio', 'error');
    }
}

async function _schedeUpdateExField(exId, field, value) {
    // M17: per le Serie, un campo vuoto/invalido non deve collassare a 0.
    // (+'' === 0, +'abc' === NaN) → in quel caso ignora l'update e mantieni il valore precedente.
    if (field === 'sets') {
        const n = (typeof value === 'number') ? value : parseInt(value, 10);
        if (Number.isNaN(n) || n < 1) return;
        value = n;
    }
    try {
        await WorkoutPlanStorage.updateExercise(exId, { [field]: value });
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore aggiornamento', 'error');
    }
}

async function _schedeDeleteExercise(exId) {
    try {
        await WorkoutPlanStorage.deleteExercise(exId);
        _schedeRefreshEditor();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore eliminazione', 'error');
    }
}

async function _schedeAddSupersetRow() {
    if (!_editingPlan) {
        await _schedeSavePlan();
        if (!_editingPlan) return;
    }
    try {
        await WorkoutPlanStorage.addSuperset(_editingPlan.id, {
            day_label: _editActiveDay,
            exercise_name: 'Esercizio 1',
            sets: 3, reps: '10',
        }, {
            day_label: _editActiveDay,
            exercise_name: 'Esercizio 2',
            sets: 3, reps: '10',
            rest_seconds: 90,
        });
        _schedeRefreshEditor();
        if (typeof showToast === 'function') showToast('Super Serie aggiunta!', 'success');
    } catch (e) {
        console.error('[Schede] addSuperset error:', e);
        if (typeof showToast === 'function') showToast('Errore aggiunta super serie', 'error');
    }
}

async function _schedeDeleteSuperset(groupId) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const toDelete = (_editingPlan.workout_exercises || []).filter(e => e.superset_group === groupId);
    try {
        for (const ex of toDelete) {
            await WorkoutPlanStorage.deleteExercise(ex.id);
        }
        _schedeRefreshEditor();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore eliminazione super serie', 'error');
    }
}

// Groups a day's exercises into "blocks": a single exercise or an entire
// super serie. Block ordering follows the first occurrence of each group
// in sort_order. Used by the block-level move arrows.
function _schedeBuildDayBlocks(dayExercises) {
    const blocks = [];
    const seenSs = new Set();
    const seenCc = new Set();
    for (const ex of dayExercises) {
        if (ex.superset_group) {
            if (seenSs.has(ex.superset_group)) continue;
            seenSs.add(ex.superset_group);
            const members = dayExercises.filter(e => e.superset_group === ex.superset_group);
            blocks.push({ type: 'superset', groupId: ex.superset_group, ids: members.map(m => m.id) });
        } else if (ex.circuit_group) {
            if (seenCc.has(ex.circuit_group)) continue;
            seenCc.add(ex.circuit_group);
            const members = dayExercises.filter(e => e.circuit_group === ex.circuit_group)
                .sort((a, b) => a.sort_order - b.sort_order);
            blocks.push({ type: 'circuit', groupId: ex.circuit_group, ids: members.map(m => m.id) });
        } else {
            blocks.push({ type: 'single', ids: [ex.id] });
        }
    }
    return blocks;
}

async function _schedeMoveSuperset(groupId, direction) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const dayExercises = (_editingPlan.workout_exercises || []).filter(e => e.day_label === _editActiveDay);
    const blocks = _schedeBuildDayBlocks(dayExercises);
    const idx = blocks.findIndex(b => b.type === 'superset' && b.groupId === groupId);
    if (idx < 0) return;
    const newIdx = idx + direction;
    if (newIdx < 0 || newIdx >= blocks.length) return;
    [blocks[idx], blocks[newIdx]] = [blocks[newIdx], blocks[idx]];
    const orderedIds = blocks.flatMap(b => b.ids);
    try {
        await WorkoutPlanStorage.reorderExercises(_editingPlan.id, orderedIds);
        _schedeRefreshEditor();
    } catch (_) {}
}

async function _schedeMoveExercise(exId, direction) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const dayExercises = (_editingPlan.workout_exercises || []).filter(e => e.day_label === _editActiveDay);
    const blocks = _schedeBuildDayBlocks(dayExercises);
    const idx = blocks.findIndex(b => b.type === 'single' && b.ids[0] === exId);
    if (idx < 0) return;
    const newIdx = idx + direction;
    if (newIdx < 0 || newIdx >= blocks.length) return;
    [blocks[idx], blocks[newIdx]] = [blocks[newIdx], blocks[idx]];
    const orderedIds = blocks.flatMap(b => b.ids);
    try {
        await WorkoutPlanStorage.reorderExercises(_editingPlan.id, orderedIds);
        _schedeRefreshEditor();
    } catch (_) {}
}

// ── CRUD Circuito (admin desktop editor) ───────────────────────────────────
async function _schedeAddCircuitRow() {
    if (!_editingPlan) {
        await _schedeSavePlan();
        if (!_editingPlan) return;
    }
    try {
        // Default: 2 esercizi placeholder, 3 giri, 90s di pausa di fine giro.
        await WorkoutPlanStorage.addCircuit(_editingPlan.id, [
            { day_label: _editActiveDay, exercise_name: 'Esercizio 1', sets: 3, reps: '10', rest_seconds: 0 },
            { day_label: _editActiveDay, exercise_name: 'Esercizio 2', sets: 3, reps: '10', rest_seconds: 90 },
        ]);
        _schedeRefreshEditor();
        if (typeof showToast === 'function') showToast('Circuito aggiunto!', 'success');
    } catch (e) {
        console.error('[Schede] addCircuit error:', e);
        if (typeof showToast === 'function') showToast('Errore aggiunta circuito', 'error');
    }
}

async function _schedeDeleteCircuit(groupId) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    if (!await showConfirm('Eliminare questo circuito?')) return;
    const toDelete = (_editingPlan.workout_exercises || []).filter(e => e.circuit_group === groupId);
    try {
        for (const ex of toDelete) {
            await WorkoutPlanStorage.deleteExercise(ex.id);
        }
        _schedeRefreshEditor();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore eliminazione circuito', 'error');
    }
}

async function _schedeMoveCircuit(groupId, direction) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const dayExercises = (_editingPlan.workout_exercises || []).filter(e => e.day_label === _editActiveDay);
    const blocks = _schedeBuildDayBlocks(dayExercises);
    const idx = blocks.findIndex(b => b.type === 'circuit' && b.groupId === groupId);
    if (idx < 0) return;
    const newIdx = idx + direction;
    if (newIdx < 0 || newIdx >= blocks.length) return;
    [blocks[idx], blocks[newIdx]] = [blocks[newIdx], blocks[idx]];
    const orderedIds = blocks.flatMap(b => b.ids);
    try {
        await WorkoutPlanStorage.reorderExercises(_editingPlan.id, orderedIds);
        _schedeRefreshEditor();
    } catch (_) {}
}

async function _schedeUpdateCircuitRounds(groupId, value) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const sets = parseInt(value);
    if (!sets || sets < 1) return;
    const members = (_editingPlan.workout_exercises || []).filter(e => e.circuit_group === groupId);
    try {
        for (const ex of members) {
            if (ex.sets !== sets) {
                await WorkoutPlanStorage.updateExercise(ex.id, { sets });
                ex.sets = sets;
            }
        }
        _schedeRefreshEditor();
    } catch (_) {}
}

async function _schedeUpdateCircuitRest(groupId, value) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const rest = parseInt(value);
    if (Number.isNaN(rest) || rest < 0) return;
    const members = (_editingPlan.workout_exercises || []).filter(e => e.circuit_group === groupId)
        .sort((a, b) => a.sort_order - b.sort_order);
    const last = members[members.length - 1];
    if (!last) return;
    try {
        await WorkoutPlanStorage.updateExercise(last.id, { rest_seconds: rest });
        last.rest_seconds = rest;
        _schedeRefreshEditor();
    } catch (_) {}
}

async function _schedeAddExerciseToCircuit(groupId) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const members = (_editingPlan.workout_exercises || []).filter(e => e.circuit_group === groupId)
        .sort((a, b) => a.sort_order - b.sort_order);
    if (!members.length) return;
    const sets = members[0].sets || 3;
    const prevLast = members[members.length - 1];
    const prevRest = prevLast.rest_seconds || 0;
    try {
        // Sposta il riposo dal vecchio ultimo al nuovo (che diventa l'ultimo)
        if (prevRest) {
            await WorkoutPlanStorage.updateExercise(prevLast.id, { rest_seconds: 0 });
            prevLast.rest_seconds = 0;
        }
        await WorkoutPlanStorage.addExercise(_editingPlan.id, {
            day_label: members[0].day_label,
            exercise_name: 'Esercizio',
            sets, reps: '10',
            rest_seconds: prevRest,
            circuit_group: groupId,
        });
        _schedeRefreshEditor();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore aggiunta esercizio al circuito', 'error');
    }
}

async function _schedeRemoveFromCircuit(exId) {
    _schedeSyncEditingPlan();
    if (!_editingPlan) return;
    const target = (_editingPlan.workout_exercises || []).find(e => e.id === exId);
    if (!target || !target.circuit_group) return;
    const members = (_editingPlan.workout_exercises || []).filter(e => e.circuit_group === target.circuit_group)
        .sort((a, b) => a.sort_order - b.sort_order);
    if (members.length <= 2) {
        if (typeof showToast === 'function') showToast('Un circuito deve avere almeno 2 esercizi', 'error');
        return;
    }
    if (!await showConfirm('Rimuovere questo esercizio dal circuito?')) return;
    const wasLast = members[members.length - 1].id === exId;
    try {
        await WorkoutPlanStorage.deleteExercise(exId);
        if (wasLast && target.rest_seconds) {
            const remaining = (_editingPlan.workout_exercises || []).filter(e => e.circuit_group === target.circuit_group)
                .sort((a, b) => a.sort_order - b.sort_order);
            const newLast = remaining[remaining.length - 1];
            if (newLast) {
                await WorkoutPlanStorage.updateExercise(newLast.id, { rest_seconds: target.rest_seconds });
                newLast.rest_seconds = target.rest_seconds;
            }
        }
        _schedeRefreshEditor();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore rimozione', 'error');
    }
}

// ── Save plan ────────────────────────────────────────────────────────────────
async function _schedeSavePlan() {
    const nameInput = document.getElementById('schedePlanName');
    const clientInput = document.getElementById('schedeClientSearch');
    let userId = clientInput?.dataset?.userId || null;
    const planName = nameInput?.value?.trim();

    // If userId looks invalid, treat as template (null)
    if (userId === 'undefined' || (userId && userId.length < 10)) userId = null;

    if (!planName) {
        if (typeof showToast === 'function') showToast('Inserisci un nome per la scheda', 'error');
        return;
    }

    const active = document.getElementById('schedePlanActive')?.checked ?? true;
    const notes = document.getElementById('schedePlanNotes')?.value?.trim() || null;

    try {
        if (_editingPlan) {
            await WorkoutPlanStorage.updatePlan(_editingPlan.id, {
                user_id: userId, name: planName,
                active, notes,
            });
            if (typeof showToast === 'function') showToast('Scheda aggiornata', 'success');
        } else {
            const newPlan = await WorkoutPlanStorage.createPlan({
                user_id: userId, name: planName, notes,
            });
            _editingPlan = newPlan;
            _currentPlanId = newPlan.id;
            if (typeof showToast === 'function') showToast('Scheda creata! Aggiungi esercizi.', 'success');
        }
        _schedeRefreshEditor();
    } catch (e) {
        console.error('[Schede] save error:', e);
        if (typeof showToast === 'function') showToast('Errore salvataggio scheda: ' + (e.message || ''), 'error');
    }
}

async function _schedeBackToList() {
    // Flush autosave prima di lasciare l'editor (input on-blur potrebbe non
    // essere ancora scattato se l'utente clicca direttamente "Indietro").
    try { await _schedeAutoSavePlanNow(); } catch (_) {}
    if (_schedeSection === 'clienti' && _schedeClientUserId) {
        _schedeView = 'client-detail';
    } else {
        _schedeView = _schedeSection === 'clienti' ? 'clients' : 'list';
    }
    _editingPlan = null;
    _currentPlanId = null;
    renderSchedeTab();
}

// ═══════════════════════════════════════════════════════════════════════════════
// PLAN ACTIONS (list view)
// ═══════════════════════════════════════════════════════════════════════════════
async function _schedeAssignTemplate(userId) {
    const sel = document.getElementById('schedeAssignTemplate');
    const templateId = sel?.value;
    if (!templateId) { if (typeof showToast === 'function') showToast('Seleziona un template', 'error'); return; }
    try {
        await WorkoutPlanStorage.duplicatePlan(templateId, userId);
        if (typeof showToast === 'function') showToast('Scheda assegnata!', 'success');
        renderSchedeTab();
    } catch (e) {
        console.error('[Schede] assign error:', e);
        if (typeof showToast === 'function') showToast('Errore assegnazione', 'error');
    }
}

async function _schedeDeletePlan(planId) {
    if (!await showConfirm('Eliminare questa scheda e tutti gli esercizi associati?')) return;
    try {
        await WorkoutPlanStorage.deletePlan(planId);
        if (typeof showToast === 'function') showToast('Scheda eliminata', 'success');
        renderSchedeTab();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore eliminazione', 'error');
    }
}

async function _schedeSaveAsTemplate(planId, planName) {
    const tplName = await showPrompt('Nome del template:', planName, { confirmText: 'Salva template' });
    if (!tplName) return;
    try {
        await WorkoutPlanStorage.duplicatePlan(planId, null, tplName);
        if (typeof showToast === 'function') showToast('Template creato!', 'success');
    } catch (e) {
        console.error('_schedeSaveAsTemplate error:', e);
        if (typeof showToast === 'function') showToast('Errore creazione template', 'error');
    }
}

async function _schedeDeletePlanFromDetail(planId) {
    if (!await showConfirm('Eliminare questa scheda e tutti gli esercizi associati?')) return;
    try {
        await WorkoutPlanStorage.deletePlan(planId);
        if (typeof showToast === 'function') showToast('Scheda eliminata', 'success');
        // Stay on client detail view
        _schedeView = 'client-detail';
        renderSchedeTab();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore eliminazione', 'error');
    }
}

async function _schedeDuplicatePlan(planId) {
    const plan = WorkoutPlanStorage.getPlanById(planId);
    if (!plan) return;

    const allUsers = _schedeGetRegisteredUsers();
    const nameMap = {};
    for (const u of allUsers) nameMap[u.userId] = u.name || u.email;

    const targetName = await showPrompt('Duplicare per quale cliente? (nome)', nameMap[plan.user_id] || '', { confirmText: 'Duplica' });
    if (!targetName) return;

    const targetUser = allUsers.find(u =>
        (u.name || '').toLowerCase() === targetName.toLowerCase() ||
        (u.email || '').toLowerCase() === targetName.toLowerCase()
    );
    if (!targetUser || !targetUser.userId) {
        if (typeof showToast === 'function') showToast('Cliente registrato non trovato', 'error');
        return;
    }

    try {
        await WorkoutPlanStorage.duplicatePlan(planId, targetUser.userId);
        if (typeof showToast === 'function') showToast('Scheda duplicata', 'success');
        renderSchedeTab();
    } catch (e) {
        if (typeof showToast === 'function') showToast('Errore duplicazione', 'error');
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROGRESS VIEW
// ═══════════════════════════════════════════════════════════════════════════════
function _schedeViewProgress(planId) {
    _currentPlanId = planId;
    _schedeView = 'progress';
    renderSchedeTab();
}

async function _renderProgressView(container) {
    const plan = WorkoutPlanStorage.getPlanById(_currentPlanId);
    if (!plan) { _schedeBackToList(); return; }

    await WorkoutLogStorage.syncForPlan(plan.id);
    const logs = WorkoutLogStorage.getAll();

    const allUsers = _schedeGetRegisteredUsers();
    const clientName = allUsers.find(u => u.userId === plan.user_id)?.name || 'Cliente';

    const days = [...new Set((plan.workout_exercises || []).map(e => e.day_label))];

    let html = `
    <div class="schede-progress">
        <div class="schede-editor-topbar">
            <button class="schede-back-btn" onclick="_schedeBackToList()">← Lista</button>
            <h3>Progressi: ${_escHtml(clientName)} — ${_escHtml(plan.name)}</h3>
        </div>`;

    if (logs.length === 0) {
        html += '<div class="empty-slot">Nessun log registrato per questa scheda.</div>';
    } else {
        for (const day of days) {
            const dayExercises = (plan.workout_exercises || []).filter(e => e.day_label === day);
            html += `<h4 class="schede-progress-day">${_escHtml(day)}</h4>`;
            for (const ex of dayExercises) {
                const exLogs = logs.filter(l => l.exercise_id === ex.id);
                if (exLogs.length === 0) continue;

                const byDate = {};
                for (const l of exLogs) {
                    if (!byDate[l.log_date]) byDate[l.log_date] = [];
                    byDate[l.log_date].push(l);
                }
                const dates = Object.keys(byDate).sort().reverse();

                const _dbExProg = _findExerciseForCard(ex);
                html += `
                <div class="schede-progress-exercise">
                    <div class="schede-progress-ex-header">
                        <strong>${_escHtml(_dbExProg ? _dbExProg.nome_it : ex.exercise_name)}</strong>
                        <span class="schede-progress-target">Target: ${(ex.muscle_group || '').toLowerCase() === 'cardio' ? ex.reps + ' min' : ex.sets + '×' + ex.reps + ' @ ' + (ex.weight_kg != null ? ex.weight_kg + 'kg' : '—')}</span>
                    </div>
                    <table class="schede-progress-table">
                        <thead><tr><th>Data</th>${(ex.muscle_group || '').toLowerCase() === 'cardio' ? '<th>Min</th>' : '<th>Serie</th><th>Reps</th><th>Peso</th>'}<th>RPE</th></tr></thead>
                        <tbody>`;
                const _exIsCardio = (ex.muscle_group || '').toLowerCase() === 'cardio';
                for (const date of dates.slice(0, 10)) {
                    const setsForDate = byDate[date].sort((a, b) => a.set_number - b.set_number);
                    for (const s of setsForDate) {
                        const repsClass = _progressClass(s.reps_done, _parseRepsTarget(ex.reps));
                        const weightClass = _progressClass(s.weight_done, ex.weight_kg);
                        if (_exIsCardio) {
                            html += `<tr>
                                <td>${_fmtDate(date)}</td>
                                <td class="${repsClass}">${s.reps_done != null ? s.reps_done + ' min' : '—'}</td>
                                <td>${s.rpe ?? '—'}</td>
                            </tr>`;
                        } else {
                            html += `<tr>
                                <td>${_fmtDate(date)}</td>
                                <td>${s.set_number}</td>
                                <td class="${repsClass}">${s.reps_done ?? '—'}</td>
                                <td class="${weightClass}">${s.weight_done != null ? s.weight_done + 'kg' : '—'}</td>
                                <td>${s.rpe ?? '—'}</td>
                            </tr>`;
                        }
                    }
                }
                html += '</tbody></table></div>';
            }
        }
    }

    html += '</div>';
    container.innerHTML = html;
}

function _parseRepsTarget(reps) {
    if (!reps) return null;
    const num = parseInt(reps);
    return isNaN(num) ? null : num;
}

function _progressClass(actual, target) {
    if (actual == null || target == null) return '';
    if (actual >= target) return 'schede-progress-ok';
    if (actual >= target * 0.8) return 'schede-progress-close';
    return 'schede-progress-miss';
}

// ═══════════════════════════════════════════════════════════════════════════════
// MOBILE EDITOR (card-based, stile allenamento.html)
// Sotto i 768px _renderPlanEditor dispatcha qui. Riusa le classi .all-ex-card /
// .all-ss-card / .all-cc-card del client e apre overlay edit full-screen
// (.all-detail-overlay) con autosave su ogni change.
// ═══════════════════════════════════════════════════════════════════════════════

function _renderPlanEditorMobile(container) {
    const plan = _editingPlan;
    const isNew = !plan;
    const allUsers = _schedeGetRegisteredUsers();
    const selectedUserId = plan?.user_id || '';
    const selectedUserName = selectedUserId ? (allUsers.find(u => u.userId === selectedUserId)?.name || '') : '';
    const hasNotes = !!(plan?.notes);

    const html = `
    <div class="schede-editor schede-editor--mobile">
        <div class="schede-editor-topbar">
            <button class="schede-back-btn" onclick="_schedeBackToList()" aria-label="Indietro">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
            </button>
            <div class="schede-ed-meta">
                <div class="schede-ed-eyebrow">${isNew ? 'Nuova scheda' : 'Modifica scheda'}</div>
            </div>
            <label class="schede-toggle schede-toggle--topbar" title="${!plan || plan.active ? 'Attiva' : 'Inattiva'}">
                <input type="checkbox" id="schedePlanActive" ${!plan || plan.active ? 'checked' : ''} onchange="_schedeAutoSavePlanNow()">
                <span class="schede-toggle-slider"></span>
            </label>
            <div class="adm-mob-hero-fields">
                <div class="adm-mob-hero-field">
                    <label for="schedePlanName">Nome scheda</label>
                    <input type="text" id="schedePlanName" value="${_escHtml(plan?.name || '')}" placeholder="es. Scheda Forza"
                           oninput="_schedeAutoSavePlan()" onblur="_schedeAutoSavePlanNow()">
                </div>
                <div class="adm-mob-hero-field" ${!isNew && !selectedUserId ? 'style="display:none"' : ''}>
                    <label for="schedeClientSearch">Cliente</label>
                    <div class="schede-client-selector">
                        <input type="text" id="schedeClientSearch" placeholder="Template (lascia vuoto)"
                               value="${_escHtml(selectedUserName)}"
                               oninput="_schedeSearchClient()" autocomplete="off"
                               onfocus="_schedeSearchClient()"
                               ${selectedUserId ? 'data-user-id="' + selectedUserId + '"' : ''}>
                        <div id="schedeClientDropdown" class="debtor-search-dropdown" style="display:none;"></div>
                    </div>
                </div>
                <details class="adm-mob-hero-notes"${hasNotes ? ' open' : ''}>
                    <summary>Note generali</summary>
                    <textarea id="schedePlanNotes" rows="2" placeholder="Note sulla scheda..."
                              oninput="_schedeAutoSavePlan()" onblur="_schedeAutoSavePlanNow()">${_escHtml(plan?.notes || '')}</textarea>
                </details>
            </div>
        </div>

        <div class="adm-mob-day-bar">
            <div class="all-day-tabs">
                ${_editDayLabels.map(d => `
                    <button class="all-day-tab${d === _editActiveDay ? ' active' : ''}" role="tab"
                            aria-selected="${d === _editActiveDay}"
                            data-day="${_escHtml(d)}"
                            onclick="_schedeSelectDay('${_escHtml(d)}')">
                        <span class="all-day-tab-name">${_escHtml(d)}</span>
                    </button>
                `).join('')}
                <button class="all-day-tab all-day-tab-add" onclick="_schedeAddDay()" aria-label="Aggiungi giorno">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" width="20" height="20"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
                </button>
            </div>
            ${_editDayLabels.length > 1 ? `
            <div class="adm-mob-day-rename">
                <input type="text" id="schedeDayRename" value="${_escHtml(_editActiveDay)}"
                       onchange="_schedeRenameDay(this.value)" placeholder="Nome giorno">
                <button class="adm-mob-day-remove-btn" onclick="_schedeRemoveDay()" title="Rimuovi giorno">🗑️</button>
            </div>` : ''}
        </div>

        <div class="all-day adm-mob-card-list">
            ${_renderMobileCardsForDay()}
        </div>

        <button class="adm-mob-fab" onclick="_admMobShowFabSheet()" aria-label="Aggiungi al giorno">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" width="26" height="26">
                <line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>
            </svg>
        </button>
    </div>`;

    container.innerHTML = html;
    requestAnimationFrame(() => _admMobInitDrag());
}

function _renderMobileCardsForDay() {
    const exercises = (_editingPlan?.workout_exercises || []).filter(e => e.day_label === _editActiveDay)
        .sort((a, b) => a.sort_order - b.sort_order);
    if (exercises.length === 0) {
        if (_editingPlan) return '<div class="adm-mob-empty">Nessun esercizio in questo giorno.<br>Premi <strong>+</strong> in basso a destra per aggiungere.</div>';
        return '<div class="adm-mob-empty">Salva la scheda, poi aggiungi esercizi.</div>';
    }

    const ssMap = {}, ccMap = {};
    for (const ex of exercises) {
        if (ex.superset_group) (ssMap[ex.superset_group] = ssMap[ex.superset_group] || []).push(ex);
        if (ex.circuit_group) (ccMap[ex.circuit_group] = ccMap[ex.circuit_group] || []).push(ex);
    }
    for (const k of Object.keys(ccMap)) ccMap[k].sort((a, b) => a.sort_order - b.sort_order);

    const ssRendered = new Set();
    const ccRendered = new Set();
    let html = '';

    for (const ex of exercises) {
        if (ex.superset_group && !ssRendered.has(ex.superset_group)) {
            ssRendered.add(ex.superset_group);
            const pair = ssMap[ex.superset_group] || [ex];
            const ex1 = pair[0], ex2 = pair[1];
            const db1 = _findExerciseForCard(ex1), db2 = ex2 ? _findExerciseForCard(ex2) : null;
            const thumb1 = db1 && db1.immagine_url_small ? db1.immagine_url_small : '';
            const thumb2 = db2 && db2.immagine_url_small ? db2.immagine_url_small : '';
            const ssId = ex.superset_group;
            html += `<div class="all-ss-card" id="adm-ss-${ssId}" data-ss-id="${ssId}">
                <div class="all-ex-swipe-content">
                    <div class="all-ss-header" onclick="_admMobOpenSsEdit('${ssId}')">
                        <div class="all-ss-thumbs">
                            <span class="all-ss-badge">SS</span>
                            ${thumb1 ? `<img src="${_escHtml(thumb1)}" class="all-ss-thumb" alt="" loading="lazy">` : ''}
                            ${thumb2 ? `<img src="${_escHtml(thumb2)}" class="all-ss-thumb" alt="" loading="lazy">` : ''}
                        </div>
                        <div class="all-ss-info">
                            <ul class="all-ss-names">
                                <li class="all-ss-ex-name">${_escHtml(db1 ? db1.nome_it : (ex1.exercise_name || 'Senza nome'))}</li>
                                ${ex2 ? `<li class="all-ss-ex-name">${_escHtml(db2 ? db2.nome_it : (ex2.exercise_name || 'Senza nome'))}</li>` : ''}
                            </ul>
                        </div>
                        <div class="all-ss-status"><span class="all-ss-chevron">&#8250;</span></div>
                    </div>
                </div>
            </div>`;
            continue;
        }
        if (ex.superset_group && ssRendered.has(ex.superset_group)) continue;

        if (ex.circuit_group && !ccRendered.has(ex.circuit_group)) {
            ccRendered.add(ex.circuit_group);
            const items = ccMap[ex.circuit_group] || [ex];
            const ccId = ex.circuit_group;
            const rounds = items[0].sets || 1;
            const last = items[items.length - 1];
            const restSec = last.rest_seconds || 0;
            const thumbsHtml = items.slice(0, 4).map(it => {
                const db = _findExerciseForCard(it);
                return db && db.immagine_url_small ? `<img src="${_escHtml(db.immagine_url_small)}" class="all-cc-thumb" alt="" loading="lazy">` : '';
            }).join('');
            const extra = items.length > 4 ? `<span class="all-cc-thumb-more">+${items.length - 4}</span>` : '';
            const namesHtml = items.map(it => {
                const db = _findExerciseForCard(it);
                return `<li class="all-cc-ex-name">${_escHtml(db ? db.nome_it : (it.exercise_name || 'Senza nome'))}</li>`;
            }).join('');
            const metaTxt = `${rounds} giri${restSec ? ' · ' + restSec + 's pausa' : ''}`;
            html += `<div class="all-cc-card" id="adm-cc-${ccId}" data-cc-id="${ccId}">
                <div class="all-ex-swipe-content">
                    <div class="all-cc-header" onclick="_admMobOpenCcEdit('${ccId}')">
                        <div class="all-cc-thumbs">
                            <span class="all-cc-badge">C</span>
                            ${thumbsHtml}${extra}
                        </div>
                        <div class="all-cc-info">
                            <div class="all-cc-meta">${metaTxt}</div>
                            <ul class="all-cc-names">${namesHtml}</ul>
                        </div>
                        <div class="all-cc-status"><span class="all-cc-chevron">&#8250;</span></div>
                    </div>
                </div>
            </div>`;
            continue;
        }
        if (ex.circuit_group && ccRendered.has(ex.circuit_group)) continue;

        const dbEx = _findExerciseForCard(ex);
        const thumbSrc = dbEx && dbEx.immagine_url_small ? dbEx.immagine_url_small : '';
        const _cardio = (ex.muscle_group || '').toLowerCase() === 'cardio';
        const target = _cardio
            ? `${ex.reps} min`
            : `${ex.sets || 0} × ${ex.reps ?? '—'}${ex.weight_kg != null ? ' · ' + ex.weight_kg + ' kg' : ''}${ex.rest_seconds ? ' · ' + ex.rest_seconds + 's pausa' : ''}`;
        html += `<div class="all-ex-card" id="adm-ex-${ex.id}" data-ex-id="${ex.id}">
            <div class="all-ex-swipe-content">
                <div class="all-ex-header" onclick="_admMobOpenExEdit('${ex.id}')">
                    ${thumbSrc ? `<img src="${_escHtml(thumbSrc)}" class="all-ex-thumb" alt="" loading="lazy">` : ''}
                    <div class="all-ex-info">
                        <div class="all-ex-name">${_escHtml(dbEx ? dbEx.nome_it : (ex.exercise_name || 'Senza nome'))}</div>
                        <div class="all-ex-target">${target}</div>
                    </div>
                    <div class="all-ex-status"><span class="all-ex-chevron">&#8250;</span></div>
                </div>
            </div>
        </div>`;
    }
    return html;
}

// ── FAB sheet (Esercizio / Super Serie / Circuito) ──────────────────────────
function _admMobShowFabSheet() {
    const old = document.getElementById('admMobFabSheetOverlay');
    if (old) old.remove();
    const overlay = document.createElement('div');
    overlay.id = 'admMobFabSheetOverlay';
    overlay.className = 'all-fab-sheet-overlay';
    overlay.innerHTML = `
        <div class="all-fab-sheet">
            <div class="all-fab-sheet-handle"></div>
            <div class="all-fab-sheet-title">Aggiungi a ${_escHtml(_editActiveDay)}</div>
            <div class="all-fab-sheet-options">
                <button class="all-fab-sheet-btn" onclick="_admMobCloseFabSheet();_admMobAddSingle()">
                    <div class="all-fab-sheet-btn-icon all-fab-sheet-btn-icon--single">+</div>
                    <div class="all-fab-sheet-btn-text">
                        <span class="all-fab-sheet-btn-title">Esercizio singolo</span>
                        <span class="all-fab-sheet-btn-desc">Un esercizio con riposo</span>
                    </div>
                </button>
                <button class="all-fab-sheet-btn all-fab-sheet-btn--ss" onclick="_admMobCloseFabSheet();_admMobAddSuperset()">
                    <div class="all-fab-sheet-btn-icon all-fab-sheet-btn-icon--ss">SS</div>
                    <div class="all-fab-sheet-btn-text">
                        <span class="all-fab-sheet-btn-title">Super Serie</span>
                        <span class="all-fab-sheet-btn-desc">Due esercizi senza pausa</span>
                    </div>
                </button>
                <button class="all-fab-sheet-btn all-fab-sheet-btn--cc" onclick="_admMobCloseFabSheet();_admMobAddCircuit()">
                    <div class="all-fab-sheet-btn-icon all-fab-sheet-btn-icon--cc">C</div>
                    <div class="all-fab-sheet-btn-text">
                        <span class="all-fab-sheet-btn-title">Circuito</span>
                        <span class="all-fab-sheet-btn-desc">Più esercizi, ripetuti a giri</span>
                    </div>
                </button>
            </div>
        </div>`;
    overlay.addEventListener('click', (e) => { if (e.target === overlay) _admMobCloseFabSheet(); });
    document.body.appendChild(overlay);
    requestAnimationFrame(() => overlay.classList.add('visible'));
}

function _admMobCloseFabSheet() {
    const overlay = document.getElementById('admMobFabSheetOverlay');
    if (!overlay) return;
    overlay.classList.remove('visible');
    setTimeout(() => overlay.remove(), 300);
}

// Picker-first per esercizio singolo: scegli prima l'esercizio, poi apri edit.
async function _admMobAddSingle() {
    await _schedeAutoSavePlanNow();
    if (!_editingPlan) {
        if (typeof showToast === 'function') showToast('Inserisci prima un nome per la scheda', 'error');
        return;
    }
    _admMobOpenStandalonePicker('__new_single__');
}

function _admMobOpenStandalonePicker(exIdToken) {
    let host = document.getElementById('admMobNewExPickerHost');
    if (host) host.remove();
    host = document.createElement('div');
    host.id = 'admMobNewExPickerHost';
    // .adm-mob-edit-picker-wrap evita che il listener globale outside-click chiuda il picker
    host.className = 'adm-mob-edit-picker-wrap';
    host.innerHTML = `<div class="schede-ex-picker-dropdown" id="picker-${exIdToken}" style="display:none;"></div>`;
    document.body.appendChild(host);
    _schedeOpenPicker(exIdToken);
}

async function _admMobCreateExFromPicker(token, exerciseName) {
    const host = document.getElementById('admMobNewExPickerHost');
    if (host) host.remove();
    _schedeCleanupPickerScroll();
    if (!_editingPlan) {
        if (typeof showToast === 'function') showToast('Salva prima la scheda', 'error');
        return;
    }
    const ex = _findExercise(exerciseName);
    const isCardio = ex && (ex.categoria || '').toLowerCase() === 'cardio';
    try {
        const newEx = await WorkoutPlanStorage.addExercise(_editingPlan.id, {
            day_label: _editActiveDay,
            exercise_name: exerciseName,
            exercise_slug: ex ? ex.slug : null,
            muscle_group: ex ? ex.categoria : null,
            sets: isCardio ? 1 : 3,
            reps: isCardio ? '20' : '10',
            rest_seconds: isCardio ? 0 : 90,
        });
        _schedeRefreshEditor();
        if (newEx && newEx.id) _admMobOpenExEdit(newEx.id);
    } catch (e) {
        console.error('[Schede] mobile create from picker error:', e);
        if (typeof showToast === 'function') showToast('Errore aggiunta esercizio', 'error');
    }
}

async function _admMobAddSuperset() {
    await _schedeAddSupersetRow();
    const dayEx = (_editingPlan?.workout_exercises || []).filter(e => e.day_label === _editActiveDay);
    const last = dayEx[dayEx.length - 1];
    if (last && last.superset_group) _admMobOpenSsEdit(last.superset_group);
}

async function _admMobAddCircuit() {
    await _schedeAddCircuitRow();
    const dayEx = (_editingPlan?.workout_exercises || []).filter(e => e.day_label === _editActiveDay);
    const last = dayEx[dayEx.length - 1];
    if (last && last.circuit_group) _admMobOpenCcEdit(last.circuit_group);
}

// ── Edit overlays (single / SS / CC) ────────────────────────────────────────
function _admMobCloseEdit() {
    _admMobActiveEdit = null;
    const ov = document.getElementById('admMobEditOverlay');
    if (ov) ov.remove();
    document.body.style.overflow = '';
    _schedeRefreshEditor();
}

function _admMobReopenActiveEdit() {
    if (!_admMobActiveEdit) return;
    const { type, id } = _admMobActiveEdit;
    if (type === 'ex') _admMobOpenExEdit(id, true);
    else if (type === 'ss') _admMobOpenSsEdit(id, true);
    else if (type === 'cc') _admMobOpenCcEdit(id, true);
}

function _admMobBuildExFields(ex) {
    const exId = ex.id;
    const dbEx = _findExerciseForCard(ex);
    const isCardio = (ex.muscle_group || '').toLowerCase() === 'cardio';
    return `
        <div class="adm-mob-edit-picker-wrap">
            <button type="button" class="schede-ex-change-cta" onclick="event.preventDefault();_schedeOpenPicker('${exId}')">✎ Cambia esercizio</button>
            ${dbEx ? `<button type="button" class="schede-ex-info-btn" onclick="event.preventDefault();_schedeShowExDetail('${_escHtml(dbEx.slug)}')" title="Dettaglio">i</button>` : ''}
            <div class="schede-ex-picker-dropdown" id="picker-${exId}" style="display:none;"></div>
        </div>
        <div class="adm-mob-edit-fields">
            ${isCardio ? `
                <label class="adm-mob-edit-field">
                    <span>Durata (min)</span>
                    <input type="text" value="${_escHtml(String(ex.reps ?? ''))}" placeholder="20"
                           onchange="_schedeUpdateExField('${exId}','reps',this.value)">
                </label>
            ` : `
                <label class="adm-mob-edit-field">
                    <span>Serie</span>
                    <input type="number" min="1" max="30" value="${ex.sets || 3}"
                           onchange="_schedeUpdateExField('${exId}','sets',+this.value)">
                </label>
                <label class="adm-mob-edit-field">
                    <span>Ripetizioni</span>
                    <input type="text" value="${_escHtml(String(ex.reps ?? ''))}" placeholder="10"
                           onchange="_schedeUpdateExField('${exId}','reps',this.value)">
                </label>
                <label class="adm-mob-edit-field">
                    <span>Peso (kg)</span>
                    <input type="number" step="0.5" min="0" value="${ex.weight_kg ?? ''}" placeholder="—"
                           onchange="_schedeUpdateExField('${exId}','weight_kg',this.value?+this.value:null)">
                </label>
                <label class="adm-mob-edit-field">
                    <span>Recupero (s)</span>
                    <input type="number" min="0" step="15" value="${ex.rest_seconds ?? 90}"
                           onchange="_schedeUpdateExField('${exId}','rest_seconds',+this.value)">
                </label>
            `}
            <label class="adm-mob-edit-field adm-mob-edit-field--full">
                <span>Note</span>
                <textarea rows="2" placeholder="Note esercizio..."
                          onchange="_schedeUpdateExField('${exId}','notes',this.value)">${_escHtml(ex.notes || '')}</textarea>
            </label>
        </div>
    `;
}

function _admMobOpenExEdit(exId, isReopen) {
    const ex = (_editingPlan?.workout_exercises || []).find(e => e.id === exId);
    if (!ex) return;
    _admMobActiveEdit = { type: 'ex', id: exId };
    const dbEx = _findExerciseForCard(ex);
    const title = dbEx ? dbEx.nome_it : (ex.exercise_name || 'Senza nome');

    const old = document.getElementById('admMobEditOverlay');
    if (old) old.remove();

    const overlay = document.createElement('div');
    overlay.id = 'admMobEditOverlay';
    overlay.className = 'all-detail-overlay';
    overlay.innerHTML = `
        <div class="all-detail-panel">
            <div class="all-detail-header">
                <button class="all-detail-back" onclick="_admMobCloseEdit()" aria-label="Indietro">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><polyline points="15 18 9 12 15 6"/></svg>
                </button>
                <div class="all-detail-title">${_escHtml(title)}</div>
            </div>
            <div class="all-detail-scroll">
                ${_admMobBuildExFields(ex)}
                <div class="adm-mob-edit-actions">
                    <button class="adm-mob-edit-delete" onclick="_admMobDeleteSingle('${exId}')">Elimina esercizio</button>
                </div>
            </div>
        </div>`;
    document.body.appendChild(overlay);
    document.body.style.overflow = 'hidden';
    if (!isReopen) requestAnimationFrame(() => overlay.classList.add('visible'));
    else overlay.classList.add('visible');
}

async function _admMobDeleteSingle(exId) {
    if (!await showConfirm('Eliminare questo esercizio?')) return;
    _admMobActiveEdit = null;
    await _schedeDeleteExercise(exId);
    const ov = document.getElementById('admMobEditOverlay');
    if (ov) ov.remove();
    document.body.style.overflow = '';
}

function _admMobOpenSsEdit(groupId, isReopen) {
    const members = (_editingPlan?.workout_exercises || []).filter(e => e.superset_group === groupId)
        .sort((a, b) => a.sort_order - b.sort_order);
    if (!members.length) return;
    _admMobActiveEdit = { type: 'ss', id: groupId };

    const old = document.getElementById('admMobEditOverlay');
    if (old) old.remove();

    const blocks = members.map((m, idx) => `
        <div class="adm-mob-edit-section">
            <div class="adm-mob-edit-section-title">Esercizio ${idx + 1} di ${members.length}</div>
            ${_admMobBuildExFields(m)}
        </div>
    `).join('');

    const overlay = document.createElement('div');
    overlay.id = 'admMobEditOverlay';
    overlay.className = 'all-detail-overlay';
    overlay.innerHTML = `
        <div class="all-detail-panel">
            <div class="all-detail-header">
                <button class="all-detail-back" onclick="_admMobCloseEdit()" aria-label="Indietro">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><polyline points="15 18 9 12 15 6"/></svg>
                </button>
                <div class="all-detail-title">Super Serie</div>
            </div>
            <div class="all-detail-scroll">
                ${blocks}
                <div class="adm-mob-edit-actions">
                    <button class="adm-mob-edit-delete" onclick="_admMobDeleteSs('${groupId}')">Elimina super serie</button>
                </div>
            </div>
        </div>`;
    document.body.appendChild(overlay);
    document.body.style.overflow = 'hidden';
    if (!isReopen) requestAnimationFrame(() => overlay.classList.add('visible'));
    else overlay.classList.add('visible');
}

async function _admMobDeleteSs(groupId) {
    if (!await showConfirm('Eliminare questa super serie?')) return;
    _admMobActiveEdit = null;
    await _schedeDeleteSuperset(groupId);
    const ov = document.getElementById('admMobEditOverlay');
    if (ov) ov.remove();
    document.body.style.overflow = '';
}

function _admMobOpenCcEdit(groupId, isReopen) {
    const items = (_editingPlan?.workout_exercises || []).filter(e => e.circuit_group === groupId)
        .sort((a, b) => a.sort_order - b.sort_order);
    if (!items.length) return;
    _admMobActiveEdit = { type: 'cc', id: groupId };
    const rounds = items[0].sets || 1;
    const restSec = items[items.length - 1].rest_seconds || 0;

    const old = document.getElementById('admMobEditOverlay');
    if (old) old.remove();

    const rowsHtml = items.map((it) => {
        const db = _findExerciseForCard(it);
        const name = db ? db.nome_it : (it.exercise_name || 'Senza nome');
        return `<div class="adm-mob-cc-row" data-ex-id="${it.id}">
            <div class="adm-mob-cc-row-head">
                <span class="adm-mob-cc-row-name">${_escHtml(name)}</span>
                <button type="button" class="adm-mob-cc-row-pick" onclick="event.preventDefault();_schedeOpenPicker('${it.id}')" title="Cambia esercizio">✎</button>
                <button type="button" class="adm-mob-cc-row-remove" onclick="_admMobRemoveFromCircuit('${it.id}')" title="Rimuovi">&times;</button>
            </div>
            <div class="schede-ex-picker-dropdown" id="picker-${it.id}" style="display:none;"></div>
            <div class="adm-mob-cc-row-fields">
                <label class="adm-mob-edit-field">
                    <span>Ripetizioni</span>
                    <input type="text" value="${_escHtml(String(it.reps ?? ''))}" placeholder="10"
                           onchange="_schedeUpdateExField('${it.id}','reps',this.value)">
                </label>
                <label class="adm-mob-edit-field">
                    <span>Peso (kg)</span>
                    <input type="number" step="0.5" min="0" value="${it.weight_kg ?? ''}" placeholder="—"
                           onchange="_schedeUpdateExField('${it.id}','weight_kg',this.value?+this.value:null)">
                </label>
            </div>
        </div>`;
    }).join('');

    const overlay = document.createElement('div');
    overlay.id = 'admMobEditOverlay';
    overlay.className = 'all-detail-overlay';
    overlay.innerHTML = `
        <div class="all-detail-panel">
            <div class="all-detail-header">
                <button class="all-detail-back" onclick="_admMobCloseEdit()" aria-label="Indietro">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><polyline points="15 18 9 12 15 6"/></svg>
                </button>
                <div class="all-detail-title">Circuito</div>
            </div>
            <div class="all-detail-scroll">
                <div class="all-cc-edit-section">
                    <div class="all-cc-edit-field">
                        <label class="all-cc-edit-label">Numero di giri</label>
                        <input type="number" min="1" inputmode="numeric" class="all-cc-edit-input" value="${rounds}"
                               onchange="_schedeUpdateCircuitRounds('${groupId}', this.value)">
                    </div>
                    <div class="all-cc-edit-field">
                        <label class="all-cc-edit-label">Pausa fra giri (sec)</label>
                        <input type="number" min="0" inputmode="numeric" class="all-cc-edit-input" value="${restSec}"
                               onchange="_schedeUpdateCircuitRest('${groupId}', this.value)">
                    </div>
                </div>
                <div class="all-cc-edit-section-title">Esercizi del circuito</div>
                <div class="adm-mob-cc-list">${rowsHtml}</div>
                <div class="all-cc-edit-add-wrap">
                    <button type="button" class="all-detail-cc-add-btn" onclick="_admMobAddExToCircuit('${groupId}')">
                        <span class="all-detail-cc-add-btn-icon">+</span> Aggiungi esercizio
                    </button>
                </div>
                <div class="adm-mob-edit-actions">
                    <button class="adm-mob-edit-delete" onclick="_admMobDeleteCc('${groupId}')">Elimina circuito</button>
                </div>
            </div>
        </div>`;
    document.body.appendChild(overlay);
    document.body.style.overflow = 'hidden';
    if (!isReopen) requestAnimationFrame(() => overlay.classList.add('visible'));
    else overlay.classList.add('visible');
}

async function _admMobAddExToCircuit(groupId) {
    await _schedeAddExerciseToCircuit(groupId);
}

async function _admMobRemoveFromCircuit(exId) {
    await _schedeRemoveFromCircuit(exId);
}

async function _admMobDeleteCc(groupId) {
    _admMobActiveEdit = null;
    await _schedeDeleteCircuit(groupId);
    const ov = document.getElementById('admMobEditOverlay');
    if (ov) ov.remove();
    document.body.style.overflow = '';
}

// ── Drag-to-reorder long-press a livello di blocco ──────────────────────────
let _admMobDragState = null;
let _admMobSuppressNextTap = false;

function _admMobInitDrag() {
    const list = document.querySelector('.adm-mob-card-list');
    if (!list) return;
    const cards = list.querySelectorAll(':scope > [data-ex-id], :scope > [data-ss-id], :scope > [data-cc-id]');
    cards.forEach(card => {
        card.addEventListener('touchstart', _admMobDragTouchStart, { passive: true });
        card.addEventListener('touchmove', _admMobDragTouchMove, { passive: false });
        card.addEventListener('touchend', _admMobDragTouchEnd, { passive: false });
        card.addEventListener('touchcancel', _admMobDragTouchEnd, { passive: false });
        card.addEventListener('click', _admMobMaybeBlockTap, true);
    });
}

function _admMobMaybeBlockTap(e) {
    if (_admMobSuppressNextTap) {
        e.preventDefault();
        e.stopPropagation();
        _admMobSuppressNextTap = false;
    }
}

function _admMobDragTouchStart(e) {
    if (_admMobDragState) return;
    const card = e.currentTarget;
    const touch = e.touches[0];
    _admMobDragState = {
        card,
        startX: touch.clientX,
        startY: touch.clientY,
        moved: false,
        dragging: false,
        currentIdx: -1,
        startIdx: -1,
        cardHeight: 0,
        longPressTimer: setTimeout(() => {
            if (_admMobDragState && _admMobDragState.card === card && !_admMobDragState.moved) {
                _admMobStartDrag(card);
            }
        }, 500),
    };
}

function _admMobStartDrag(card) {
    if (!_admMobDragState) return;
    if (navigator.vibrate) navigator.vibrate(30);
    _admMobDragState.dragging = true;
    const cs = getComputedStyle(card);
    const marginB = parseInt(cs.marginBottom) || 0;
    _admMobDragState.cardHeight = card.offsetHeight + marginB;
    const list = card.parentElement;
    const allCards = [...list.querySelectorAll(':scope > [data-ex-id], :scope > [data-ss-id], :scope > [data-cc-id]')];
    _admMobDragState.startIdx = allCards.indexOf(card);
    _admMobDragState.currentIdx = _admMobDragState.startIdx;
    _admMobDragState.allCards = allCards;
    card.classList.add('adm-mob-dragging');
    document.body.style.overflow = 'hidden';
}

function _admMobDragTouchMove(e) {
    if (!_admMobDragState) return;
    const touch = e.touches[0];
    const dy = touch.clientY - _admMobDragState.startY;
    const dx = touch.clientX - _admMobDragState.startX;
    if (!_admMobDragState.dragging) {
        if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
            _admMobDragState.moved = true;
            clearTimeout(_admMobDragState.longPressTimer);
            _admMobDragState = null;
        }
        return;
    }
    e.preventDefault();
    _admMobDragState.card.style.transform = `translateY(${dy}px) scale(1.03)`;
    const stepCount = Math.round(dy / _admMobDragState.cardHeight);
    const newIdx = Math.max(0, Math.min(_admMobDragState.allCards.length - 1, _admMobDragState.startIdx + stepCount));
    if (newIdx !== _admMobDragState.currentIdx) {
        _admMobDragState.allCards.forEach((c, i) => {
            if (c === _admMobDragState.card) return;
            if (_admMobDragState.startIdx < newIdx) {
                c.style.transform = (i > _admMobDragState.startIdx && i <= newIdx) ? `translateY(-${_admMobDragState.cardHeight}px)` : '';
            } else {
                c.style.transform = (i >= newIdx && i < _admMobDragState.startIdx) ? `translateY(${_admMobDragState.cardHeight}px)` : '';
            }
            c.style.transition = 'transform 0.2s ease';
        });
        _admMobDragState.currentIdx = newIdx;
    }
}

async function _admMobDragTouchEnd(e) {
    if (!_admMobDragState) return;
    clearTimeout(_admMobDragState.longPressTimer);
    const wasDragging = _admMobDragState.dragging;
    const card = _admMobDragState.card;
    const fromIdx = _admMobDragState.startIdx;
    const toIdx = _admMobDragState.currentIdx;
    const allCards = _admMobDragState.allCards || [];
    _admMobDragState = null;
    if (!wasDragging) return;
    card.classList.remove('adm-mob-dragging');
    card.style.transform = '';
    allCards.forEach(c => { c.style.transform = ''; c.style.transition = ''; });
    document.body.style.overflow = '';
    _admMobSuppressNextTap = true;
    setTimeout(() => { _admMobSuppressNextTap = false; }, 350);
    if (toIdx < 0 || toIdx === fromIdx) return;
    await _admMobReorderBlocks(fromIdx, toIdx);
}

async function _admMobReorderBlocks(fromIdx, toIdx) {
    if (!_editingPlan) return;
    const dayExercises = (_editingPlan.workout_exercises || []).filter(e => e.day_label === _editActiveDay)
        .sort((a, b) => a.sort_order - b.sort_order);
    const blocks = _schedeBuildDayBlocks(dayExercises);
    if (fromIdx < 0 || toIdx < 0 || fromIdx >= blocks.length || toIdx >= blocks.length) return;
    const [moved] = blocks.splice(fromIdx, 1);
    blocks.splice(toIdx, 0, moved);
    const orderedIds = blocks.flatMap(b => b.ids);

    // Optimistic update: aggiorna sort_order in locale e ridisegna SUBITO,
    // senza aspettare le N UPDATE sequenziali su Supabase (vedi data.js
    // WorkoutPlanStorage.reorderExercises). Persiste poi in background.
    // _editingPlan e WorkoutPlanStorage._cache condividono il riferimento al
    // plan, quindi mutare e.sort_order aggiorna anche la cache.
    const orderMap = new Map(orderedIds.map((id, i) => [id, i]));
    for (const e of _editingPlan.workout_exercises) {
        if (e.day_label === _editActiveDay && orderMap.has(e.id)) {
            e.sort_order = orderMap.get(e.id);
        }
    }
    _schedeRefreshEditor();

    try {
        await WorkoutPlanStorage.reorderExercises(_editingPlan.id, orderedIds);
    } catch (e) {
        console.error('[Schede] mobile reorder error:', e);
        if (typeof showToast === 'function') showToast('Errore riordino', 'error');
    }
}

// Resize listener: re-render solo se attraversiamo la soglia mobile/desktop
// (no su keyboard open/close che cambia solo l'altezza viewport).
let _admResizeTimer = null;
let _admLastIsMobile = (typeof window !== 'undefined' && typeof window.matchMedia === 'function')
    ? window.matchMedia('(max-width: 767px)').matches
    : false;
window.addEventListener('resize', () => {
    clearTimeout(_admResizeTimer);
    _admResizeTimer = setTimeout(() => {
        const nowMobile = _isAdmMobile();
        if (nowMobile === _admLastIsMobile) return;
        _admLastIsMobile = nowMobile;
        if (typeof _editingPlan === 'undefined' || _editingPlan === null) return;
        if (document.getElementById('admMobEditOverlay')) return; // overlay aperto → skip
        const inner = document.getElementById('schedeInner') || document.getElementById('schedeContainer');
        if (inner) _renderPlanEditor(inner);
    }, 200);
});
