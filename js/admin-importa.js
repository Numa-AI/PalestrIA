// ═══════════════════════════════════════════════════════════════════════════════
// TAB IMPORTA — Catalogo esercizi completo con import selettivo
// ═══════════════════════════════════════════════════════════════════════════════

let _importaCatalog = [];           // full 7200+ exercises from JSON
let _importaCatalogByCat = {};      // { 'Petto': [...], ... }
let _importaCatalogLoaded = false;
let _importaImported = [];          // rows from imported_exercises table
let _importaImportedSlugs = new Set();
let _importaImportedLoaded = false; // cache flag — solo questo tab modifica la tabella
let _importaView = 'catalogo';     // 'catalogo' | 'importati'
let _importaActiveCat = '';         // active category filter
let _importaSearch = '';
let _importaPage = 0;
const _IMPORTA_PAGE_SIZE = 60;

// Category → SVG icon map (includes new categories from full catalog)
const _importaCatSvg = {
    'Petto': 'chest', 'Tricipiti': 'triceps', 'Bicipiti': 'biceps', 'Braccia': 'biceps',
    'Spalle': 'shoulders', 'Schiena': 'back', 'Quadricipiti': 'quadriceps',
    'Anche/Glutei': 'hips', 'Glutei e Femorali': 'hips', 'Femorali': 'hamstrings',
    'Polpacci': 'calves', 'Addominali': 'waist_abs', 'Avambracci': 'forearms',
    'Cardio': 'cardio', 'Collo': 'neck', 'Altro': 'chest'
};

// ── Load full catalog from JSON ─────────────────────────────────────────────
// Timeout 30s: il file e' ~3MB, su reti lente o con SW pasticciato puo' restare
// appeso senza mai risolvere lasciando il tab bloccato su "Caricamento...".
async function _loadImportaCatalog() {
    if (_importaCatalogLoaded) return;
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 30000);
    try {
        const resp = await fetch('data/esercizi_completo.json', { signal: ac.signal });
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        _importaCatalog = await resp.json();
        _importaCatalogByCat = {};
        for (const ex of _importaCatalog) {
            if (!_importaCatalogByCat[ex.categoria]) _importaCatalogByCat[ex.categoria] = [];
            _importaCatalogByCat[ex.categoria].push(ex);
        }
        _importaCatalogLoaded = true;
    } finally {
        clearTimeout(timer);
    }
}

// ── Load imported exercises from Supabase ───────────────────────────────────
// Cache in-memory: la tabella imported_exercises e' modificata SOLO da questo
// tab (admin-schede.js la legge ma non scrive). Quindi dopo il primo load
// possiamo riusare la cache su tutti i tab-switch successivi e re-fetchare
// solo dopo add/remove/rename (che invalidano esplicitamente).
// Questo evita il bug per cui il re-query mid-sessione restava appeso e il
// tab Importa non usciva mai dallo stato "Caricamento catalogo...".
// Timeout 30s come safety net per il primo load.
async function _loadImportaImported() {
    if (_importaImportedLoaded) return;
    const LS_KEY = 'schede_exercises_db_v1';
    const LS_TTL_MS = 6 * 60 * 60 * 1000;
    try {
        const raw = localStorage.getItem(LS_KEY);
        if (raw) {
            const parsed = JSON.parse(raw);
            if (parsed && parsed.ts && Date.now() - parsed.ts < LS_TTL_MS && Array.isArray(parsed.data)) {
                _importaImported = parsed.data;
                _importaImportedSlugs = new Set(_importaImported.map(e => e.slug));
                _importaImportedLoaded = true;
                console.log(`[Importa] _loadImportaImported: da localStorage (${_importaImported.length} esercizi, ${Math.round((Date.now()-parsed.ts)/60000)}min fa)`);
                return;
            }
        }
    } catch (e) { /* cache corrotta: ignora e rifetcha */ }

    // Paginato: con "Importa tutti" la tabella può superare il limite di ~1000
    // righe di PostgREST, quindi va scaricata a batch (altrimenti il picker e i
    // contatori mostrerebbero solo i primi 1000).
    const { data, error } = await fetchAllPaginated(() => supabaseClient
        .from('imported_exercises')
        .select('slug, nome_it, nome_original, nome_en, categoria, immagine, immagine_thumbnail, video, popolarita')
        .order('categoria', { ascending: true })
        .order('nome_it', { ascending: true }), { timeoutMs: 30000 });
    if (error) throw error;
    _importaImported = data || [];
    _importaImportedSlugs = new Set(_importaImported.map(e => e.slug));
    _importaImportedLoaded = true;
    try { localStorage.setItem(LS_KEY, JSON.stringify({ ts: Date.now(), data: _importaImported })); } catch (e) { /* quota: ignora */ }
}

// ── Main render ─────────────────────────────────────────────────────────────
async function renderImportaTab() {
    const container = document.getElementById('importaContainer');
    if (!container) return;

    container.innerHTML = '<div class="importa-loading">Caricamento catalogo esercizi...</div>';

    try {
        await Promise.all([_loadImportaCatalog(), _loadImportaImported()]);
    } catch (e) {
        console.error('[Importa] Failed to load:', e);
        container.innerHTML = `
            <div class="importa-empty">
                Errore caricamento catalogo (${_escHtml(e.message || e)}).<br>
                <button class="importa-btn importa-btn--add" style="margin-top:12px" onclick="renderImportaTab()">Riprova</button>
            </div>`;
        return;
    }

    _importaPage = 0;
    _renderImportaUI(container);
}

function _renderImportaUI(container) {
    const totalCount = _importaCatalog.length;
    const importedCount = _importaImported.length;

    // Build category stats
    const catStats = {};
    const allCats = Object.keys(_importaCatalogByCat).sort();
    for (const c of allCats) {
        catStats[c] = {
            total: (_importaCatalogByCat[c] || []).length,
            imported: _importaImported.filter(e => e.categoria === c).length
        };
    }

    // Copertura (% del catalogo importato)
    const coverage = totalCount > 0 ? (importedCount / totalCount * 100) : 0;
    const coverageStr = coverage.toLocaleString('it', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
    const coverageWidth = Math.max(0, Math.min(100, coverage));

    let html = '';

    // ── Hero (Catalogo esercizi) ────────────────────────────────────────────
    html += `
    <section class="importa-hero">
        <div class="importa-hero-eyebrow">Catalogo esercizi</div>
        <div class="importa-hero-title">${totalCount.toLocaleString('it')} disponibili</div>
        <div class="importa-hero-stats">
            <div class="importa-hero-stat">
                <div class="v">${importedCount.toLocaleString('it')}<small>/ ${totalCount.toLocaleString('it')}</small></div>
                <div class="l">Importati</div>
            </div>
            <div class="importa-hero-spacer"></div>
            <div class="importa-hero-stat importa-hero-stat--right">
                <div class="v">${coverageStr}<small>%</small></div>
                <div class="l">Copertura</div>
            </div>
        </div>
        <div class="importa-hero-bar"><span style="width:${coverageWidth.toFixed(2)}%"></span></div>
    </section>`;

    // ── Seg (Catalogo completo / Importati) ─────────────────────────────────
    html += `
    <div class="importa-view-toggle">
        <button class="importa-view-btn${_importaView === 'catalogo' ? ' active' : ''}" onclick="_importaSwitchView('catalogo')">
            Catalogo completo <span class="importa-view-count">${totalCount.toLocaleString('it')}</span>
        </button>
        <button class="importa-view-btn${_importaView === 'importati' ? ' active' : ''}" onclick="_importaSwitchView('importati')">
            Importati <span class="importa-view-count">${importedCount.toLocaleString('it')}</span>
        </button>
    </div>`;

    // ── Filters (search + categoria) ────────────────────────────────────────
    const catOptions = ['<option value="">Tutte le categorie</option>'];
    for (const c of allCats) {
        const s = catStats[c];
        if (_importaView === 'importati' && s.imported === 0) continue;
        const selected = _importaActiveCat === c ? ' selected' : '';
        catOptions.push(`<option value="${_escHtml(c)}"${selected}>${_escHtml(c)}</option>`);
    }
    html += `
    <div class="importa-filters">
        <div class="importa-search-bar">
            <svg class="importa-search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
            <input type="text" class="importa-search-input" id="importaSearchInput"
                   placeholder="Cerca esercizio…" value="${_escHtml(_importaSearch)}"
                   oninput="_importaOnSearch(this.value)">
            ${_importaSearch ? '<button class="importa-search-clear" onclick="_importaClearSearch()" aria-label="Pulisci">&times;</button>' : ''}
        </div>
        <select class="importa-cat-select" onchange="_importaPickCat(this.value)">${catOptions.join('')}</select>
    </div>`;

    // ── Bulk import bar (solo vista catalogo, quando c'è qualcosa da importare) ─
    if (_importaView === 'catalogo') {
        const pending = _importaPendingCatalog().length;
        if (pending > 0) {
            const scope = _importaActiveCat || _importaSearch ? 'filtrati' : '';
            html += `
    <div class="importa-bulk-bar">
        <button class="importa-bulk-btn" onclick="_importaAddAll()">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg>
            Importa tutti ${scope} <span class="importa-bulk-count">${pending.toLocaleString('it')}</span>
        </button>
    </div>`;
        }
    }

    // ── Exercise grid ───────────────────────────────────────────────────────
    html += '<div class="importa-grid" id="importaGrid"></div>';
    html += '<div class="importa-load-more" id="importaLoadMore"></div>';

    container.innerHTML = html;

    // Render exercises
    _importaRenderGrid();
}

// ── Render exercise grid ────────────────────────────────────────────────────
function _importaRenderGrid() {
    const grid = document.getElementById('importaGrid');
    const loadMoreEl = document.getElementById('importaLoadMore');
    if (!grid) return;

    let exercises;
    if (_importaView === 'catalogo') {
        exercises = _importaCatalog;
    } else {
        exercises = _importaImported.map(imp => {
            // Merge imported data with catalog data for display
            const cat = _importaCatalog.find(e => e.slug === imp.slug);
            return {
                nome: imp.nome_it,
                nome_en: imp.nome_en || (cat ? cat.nome_en : ''),
                categoria: imp.categoria,
                slug: imp.slug,
                immagine: imp.immagine || (cat ? cat.immagine : ''),
                immagine_thumbnail: imp.immagine_thumbnail || (cat ? cat.immagine_thumbnail : ''),
                video: imp.video || (cat ? cat.video : ''),
                popolarita: imp.popolarita || 0,
                _imported: imp
            };
        });
    }

    // Filter by category
    if (_importaActiveCat) {
        exercises = exercises.filter(e => e.categoria === _importaActiveCat);
    }

    // Filter by search
    if (_importaSearch) {
        const s = _importaSearch.toLowerCase();
        exercises = exercises.filter(e =>
            (e.nome || '').toLowerCase().includes(s) ||
            (e.nome_en || '').toLowerCase().includes(s) ||
            (e.nome_it || '').toLowerCase().includes(s)
        );
    }

    const total = exercises.length;
    const end = (_importaPage + 1) * _IMPORTA_PAGE_SIZE;
    const shown = exercises.slice(0, end);

    if (shown.length === 0) {
        grid.innerHTML = '<div class="importa-empty">Nessun esercizio trovato</div>';
        if (loadMoreEl) loadMoreEl.innerHTML = '';
        return;
    }

    grid.innerHTML = shown.map(ex => {
        const slug = ex.slug;
        const isImported = _importaImportedSlugs.has(slug);
        const nome = _importaView === 'importati' && ex._imported
            ? ex._imported.nome_it
            : (ex.nome || ex.nome_it);
        const nomeEn = ex.nome_en || '';
        const thumb = ex.immagine_thumbnail || ex.immagine || '';
        const cat = ex.categoria;
        const svgFile = _importaCatSvg[cat] || 'chest';

        return `
        <div class="importa-card${isImported ? ' importa-card--imported' : ''}" data-slug="${_escHtml(slug)}">
            <div class="importa-card-media" onclick="_importaShowDetail('${_escHtml(slug)}')">
                ${thumb
                    ? `<img src="${_escHtml(thumb)}" class="importa-card-img" alt="${_escHtml(nome)}" loading="lazy">`
                    : `<div class="importa-card-img importa-card-img--placeholder"><img src="images/icone_muscoli/${svgFile}.svg" alt="" class="importa-card-placeholder-icon"></div>`
                }
                ${isImported ? '<span class="importa-card-check">✓</span>' : ''}
            </div>
            <div class="importa-card-body">
                <div class="importa-card-name" title="${_escHtml(nome)}">${_escHtml(nome)}</div>
                <div class="importa-card-meta">
                    <img src="images/icone_muscoli/${svgFile}.svg" class="importa-card-cat-icon" alt="">
                    <span>${_escHtml(cat)}</span>
                </div>
                ${_importaView === 'importati' && ex._imported && ex._imported.nome_it !== ex._imported.nome_original
                    ? `<div class="importa-card-original" title="Nome originale: ${_escHtml(ex._imported.nome_original)}">📝 ${_escHtml(ex._imported.nome_original)}</div>`
                    : ''
                }
                <div class="importa-card-actions">
                    ${isImported
                        ? `<button class="importa-btn importa-btn--remove" onclick="_importaRemove('${_escHtml(slug)}')" title="Rimuovi">✕ Rimuovi</button>
                           <button class="importa-btn importa-btn--rename" onclick="_importaRename('${_escHtml(slug)}')" title="Rinomina">✏️</button>`
                        : `<button class="importa-btn importa-btn--add" onclick="_importaAdd('${_escHtml(slug)}')">+ Importa</button>`
                    }
                </div>
            </div>
        </div>`;
    }).join('');

    // Load more button
    if (loadMoreEl) {
        if (end < total) {
            loadMoreEl.innerHTML = `
                <button class="importa-load-more-btn" onclick="_importaLoadMore()">
                    Mostra altri (${Math.min(_IMPORTA_PAGE_SIZE, total - end)} di ${total - end} rimanenti)
                </button>`;
        } else {
            loadMoreEl.innerHTML = total > 0
                ? `<div class="importa-load-more-done">${total} esercizi visualizzati</div>`
                : '';
        }
    }
}

function _importaLoadMore() {
    _importaPage++;
    _importaRenderGrid();
}

// ── View switching ──────────────────────────────────────────────────────────
function _importaSwitchView(view) {
    _importaView = view;
    _importaActiveCat = '';
    _importaSearch = '';
    _importaPage = 0;
    const container = document.getElementById('importaContainer');
    if (container) _renderImportaUI(container);
}

// ── Category filter ─────────────────────────────────────────────────────────
function _importaPickCat(cat) {
    _importaActiveCat = (_importaActiveCat === cat) ? '' : cat;
    _importaPage = 0;
    const container = document.getElementById('importaContainer');
    if (container) _renderImportaUI(container);
}

// ── Search ──────────────────────────────────────────────────────────────────
let _importaSearchTimer = null;
function _importaOnSearch(val) {
    clearTimeout(_importaSearchTimer);
    _importaSearchTimer = setTimeout(() => {
        _importaSearch = val.trim();
        _importaPage = 0;
        _importaRenderGrid();
    }, 250);
}

function _importaClearSearch() {
    _importaSearch = '';
    _importaPage = 0;
    const input = document.getElementById('importaSearchInput');
    if (input) input.value = '';
    const container = document.getElementById('importaContainer');
    if (container) _renderImportaUI(container);
}

// ── Import exercise ─────────────────────────────────────────────────────────
async function _importaAdd(slug) {
    const ex = _importaCatalog.find(e => e.slug === slug);
    if (!ex) return;
    if (_importaImportedSlugs.has(slug)) return;

    // Disable the button visually
    const card = document.querySelector(`.importa-card[data-slug="${slug}"]`);
    const btn = card?.querySelector('.importa-btn--add');
    if (btn) { btn.disabled = true; btn.textContent = '...'; }

    try {
        const { error } = await _queryWithTimeout(
            supabaseClient.from('imported_exercises').insert({
                slug: ex.slug,
                nome_it: ex.nome,
                nome_original: ex.nome,
                nome_en: ex.nome_en || null,
                categoria: ex.categoria,
                immagine: ex.immagine || null,
                immagine_thumbnail: ex.immagine_thumbnail || null,
                video: ex.video || null,
                popolarita: ex.popolarita || 0
            })
        );
        if (error) throw error;

        // Invalida cache e ricarica
        _importaImportedLoaded = false;
        try { localStorage.removeItem('schede_exercises_db_v1'); } catch (e) { /* noop */ }
        await _loadImportaImported();
        // Also refresh schede DB if loaded
        if (typeof _refreshSchedeFromImported === 'function') await _refreshSchedeFromImported();

        const container = document.getElementById('importaContainer');
        if (container) _renderImportaUI(container);
    } catch (e) {
        console.error('[Importa] Insert error:', e);
        showAlert('Errore durante l\'importazione: ' + (e.message || e), { type:'error' });
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = '+ Importa'; }
    }
}

// ── Filtered catalog helpers (rispecchiano la logica della griglia) ──────────
function _importaFilteredCatalog() {
    let exercises = _importaCatalog;
    if (_importaActiveCat) {
        exercises = exercises.filter(e => e.categoria === _importaActiveCat);
    }
    if (_importaSearch) {
        const s = _importaSearch.toLowerCase();
        exercises = exercises.filter(e =>
            (e.nome || '').toLowerCase().includes(s) ||
            (e.nome_en || '').toLowerCase().includes(s)
        );
    }
    return exercises;
}

// Esercizi del catalogo (filtrato) non ancora importati.
function _importaPendingCatalog() {
    return _importaFilteredCatalog().filter(e => !_importaImportedSlugs.has(e.slug));
}

// ── Import massivo (Importa tutti) ──────────────────────────────────────────
let _importaBulkRunning = false;
async function _importaAddAll() {
    if (_importaBulkRunning) return;

    const pending = _importaPendingCatalog();
    if (pending.length === 0) return;

    const scoped = !!(_importaActiveCat || _importaSearch);
    const msg = scoped
        ? `Importare i ${pending.length} esercizi filtrati nel tuo catalogo?`
        : `Importare TUTTI i ${pending.length.toLocaleString('it')} esercizi del catalogo?\n\nSaranno tutti disponibili nel picker delle schede. Potrai rimuovere quelli che non ti servono in seguito.`;
    if (!await showConfirm(msg)) return;

    _importaBulkRunning = true;

    // Overlay di progresso (bloccante).
    const overlay = document.createElement('div');
    overlay.className = 'importa-detail-overlay importa-bulk-overlay';
    overlay.innerHTML = `
        <div class="importa-bulk-modal">
            <div class="importa-bulk-modal-title">Importazione in corso…</div>
            <div class="importa-bulk-modal-sub" id="importaBulkStatus">0 / ${pending.length.toLocaleString('it')}</div>
            <div class="importa-bulk-progress"><span id="importaBulkProgressBar" style="width:0%"></span></div>
        </div>`;
    document.body.appendChild(overlay);
    const statusEl = overlay.querySelector('#importaBulkStatus');
    const barEl = overlay.querySelector('#importaBulkProgressBar');

    const rows = pending.map(ex => ({
        slug: ex.slug,
        nome_it: ex.nome,
        nome_original: ex.nome,
        nome_en: ex.nome_en || null,
        categoria: ex.categoria,
        immagine: ex.immagine || null,
        immagine_thumbnail: ex.immagine_thumbnail || null,
        video: ex.video || null,
        popolarita: ex.popolarita || 0
    }));

    const BATCH = 500;
    let done = 0;
    let failed = 0;
    try {
        for (let i = 0; i < rows.length; i += BATCH) {
            const batch = rows.slice(i, i + BATCH);
            const { error } = await _queryWithTimeout(
                supabaseClient.from('imported_exercises').insert(batch), 60000
            );
            if (error) {
                console.error('[Importa] Bulk insert batch error:', error);
                failed += batch.length;
            } else {
                done += batch.length;
            }
            const pct = Math.round(((i + batch.length) / rows.length) * 100);
            if (statusEl) statusEl.textContent = `${(done + failed).toLocaleString('it')} / ${rows.length.toLocaleString('it')}`;
            if (barEl) barEl.style.width = pct + '%';
        }

        // Invalida cache e ricarica.
        _importaImportedLoaded = false;
        try { localStorage.removeItem('schede_exercises_db_v1'); } catch (e) { /* noop */ }
        await _loadImportaImported();
        if (typeof _refreshSchedeFromImported === 'function') await _refreshSchedeFromImported();

        overlay.remove();

        if (failed > 0) {
            showAlert(`Importati ${done.toLocaleString('it')} esercizi. ${failed.toLocaleString('it')} non importati (errore). Riprova per i restanti.`, { type:'error' });
        } else {
            showAlert(`Importati ${done.toLocaleString('it')} esercizi.`, { type:'success' });
        }

        const container = document.getElementById('importaContainer');
        if (container) _renderImportaUI(container);
    } catch (e) {
        console.error('[Importa] Bulk import error:', e);
        overlay.remove();
        // Ricarica comunque per riflettere ciò che è andato a buon fine.
        try {
            _importaImportedLoaded = false;
            try { localStorage.removeItem('schede_exercises_db_v1'); } catch (e2) { /* noop */ }
            await _loadImportaImported();
            if (typeof _refreshSchedeFromImported === 'function') await _refreshSchedeFromImported();
            const container = document.getElementById('importaContainer');
            if (container) _renderImportaUI(container);
        } catch (e2) { /* noop */ }
        showAlert('Errore durante l\'importazione massiva: ' + (e.message || e), { type:'error' });
    } finally {
        _importaBulkRunning = false;
    }
}

// ── Remove imported exercise ────────────────────────────────────────────────
async function _importaRemove(slug) {
    if (!await showConfirm('Rimuovere questo esercizio dagli importati?\nNon sarà più disponibile nel picker delle schede.')) return;

    const card = document.querySelector(`.importa-card[data-slug="${slug}"]`);
    const btn = card?.querySelector('.importa-btn--remove');
    if (btn) { btn.disabled = true; btn.textContent = '...'; }

    try {
        const { error } = await _queryWithTimeout(
            supabaseClient.from('imported_exercises').delete().eq('slug', slug)
        );
        if (error) throw error;

        _importaImportedLoaded = false;
        try { localStorage.removeItem('schede_exercises_db_v1'); } catch (e) { /* noop */ }
        await _loadImportaImported();
        if (typeof _refreshSchedeFromImported === 'function') await _refreshSchedeFromImported();

        const container = document.getElementById('importaContainer');
        if (container) _renderImportaUI(container);
    } catch (e) {
        console.error('[Importa] Delete error:', e);
        showAlert('Errore: ' + (e.message || e), { type:'error' });
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = '✕ Rimuovi'; }
    }
}

// ── Rename exercise ─────────────────────────────────────────────────────────
async function _importaRename(slug) {
    const imp = _importaImported.find(e => e.slug === slug);
    if (!imp) return;

    const newName = await showPrompt('Nuovo nome italiano:', imp.nome_it);
    if (!newName || newName.trim() === imp.nome_it) return;

    const trimmedNew = newName.trim();
    const oldName = imp.nome_it;
    const nomeOriginal = imp.nome_original || null;

    try {
        const { error } = await _queryWithTimeout(
            supabaseClient
                .from('imported_exercises')
                .update({ nome_it: trimmedNew })
                .eq('slug', slug)
        );
        if (error) throw error;

        // Propaga la rinomina alle schede dei clienti già esistenti.
        // 1) Sync nome sulle righe linkate via slug.
        try {
            const { error: e1 } = await _queryWithTimeout(
                supabaseClient
                    .from('workout_exercises')
                    .update({ exercise_name: trimmedNew })
                    .eq('exercise_slug', slug)
            );
            if (e1) console.warn('[Importa] Rename: sync workout_exercises by slug failed:', e1);
        } catch (e) { console.warn('[Importa] Rename: sync workout_exercises by slug error:', e); }

        // 2) Backfill orfane (slug NULL) che combaciano col nome vecchio o l'originale.
        try {
            const orphanNames = [oldName];
            if (nomeOriginal && nomeOriginal !== oldName) orphanNames.push(nomeOriginal);
            const { error: e2 } = await _queryWithTimeout(
                supabaseClient
                    .from('workout_exercises')
                    .update({ exercise_slug: slug, exercise_name: trimmedNew })
                    .is('exercise_slug', null)
                    .in('exercise_name', orphanNames)
            );
            if (e2) console.warn('[Importa] Rename: backfill orphan workout_exercises failed:', e2);
        } catch (e) { console.warn('[Importa] Rename: backfill orphan workout_exercises error:', e); }

        _importaImportedLoaded = false;
        try { localStorage.removeItem('schede_exercises_db_v1'); } catch (e) { /* noop */ }
        await _loadImportaImported();
        if (typeof _refreshSchedeFromImported === 'function') await _refreshSchedeFromImported();

        const container = document.getElementById('importaContainer');
        if (container) _renderImportaUI(container);
    } catch (e) {
        console.error('[Importa] Rename error:', e);
        showAlert('Errore: ' + (e.message || e), { type:'error' });
    }
}

// ── Exercise detail modal ───────────────────────────────────────────────────
function _importaShowDetail(slug) {
    const ex = _importaCatalog.find(e => e.slug === slug);
    if (!ex) return;
    const imp = _importaImported.find(e => e.slug === slug);
    const isImported = !!imp;
    const displayName = imp ? imp.nome_it : ex.nome;

    // Create overlay
    const overlay = document.createElement('div');
    overlay.className = 'importa-detail-overlay';
    overlay.onclick = (e) => { if (e.target === overlay) overlay.remove(); };

    const svgFile = _importaCatSvg[ex.categoria] || 'chest';

    overlay.innerHTML = `
    <div class="importa-detail-modal">
        <button class="importa-detail-close" onclick="this.closest('.importa-detail-overlay').remove()">&times;</button>
        <div class="importa-detail-media">
            ${ex.video
                ? `<video src="${_escHtml(ex.video)}" autoplay loop muted playsinline class="importa-detail-video"></video>`
                : (ex.immagine
                    ? `<img src="${_escHtml(ex.immagine)}" class="importa-detail-img" alt="">`
                    : `<div class="importa-detail-placeholder"><img src="images/icone_muscoli/${svgFile}.svg" alt=""></div>`)
            }
        </div>
        <div class="importa-detail-info">
            <h3 class="importa-detail-name">${_escHtml(displayName)}</h3>
            ${imp && imp.nome_it !== imp.nome_original
                ? `<div class="importa-detail-original">Originale: ${_escHtml(imp.nome_original)}</div>`
                : ''
            }
            <div class="importa-detail-en">${_escHtml(ex.nome_en || '')}</div>
            <div class="importa-detail-cat">
                <img src="images/icone_muscoli/${svgFile}.svg" class="importa-detail-cat-icon" alt="">
                ${_escHtml(ex.categoria)}
            </div>
            <div class="importa-detail-actions">
                ${isImported
                    ? `<button class="importa-btn importa-btn--remove" onclick="_importaRemove('${_escHtml(slug)}');this.closest('.importa-detail-overlay').remove()">✕ Rimuovi</button>
                       <button class="importa-btn importa-btn--rename" onclick="_importaRename('${_escHtml(slug)}');this.closest('.importa-detail-overlay').remove()">✏️ Rinomina</button>`
                    : `<button class="importa-btn importa-btn--add importa-btn--lg" onclick="_importaAdd('${_escHtml(slug)}');this.closest('.importa-detail-overlay').remove()">+ Importa esercizio</button>`
                }
            </div>
        </div>
    </div>`;

    document.body.appendChild(overlay);
}
