/* ============================================================= */
/* Admin – Mobile filters (< 768px)                                */
/* Sostituisce le righe scrollabili di tab/filtri con:             */
/*   1. Page switcher (left)  → bottom sheet "Vai a"               */
/*   2. Bottone filtri (right) → bottom sheet contestuale          */
/* I filtri originali restano in DOM (display:none via CSS)        */
/* e vengono pilotati programmaticamente (proxy click/value+event) */
/* ============================================================= */
(function () {
    'use strict';

    const MQ = window.matchMedia('(max-width: 768px)');

    // Icona estratta dal primo emoji presente nel testo del tab
    function splitEmojiLabel(raw) {
        const t = (raw || '').trim();
        // Cattura il primo "cluster" emoji + eventuali modificatori
        const m = t.match(/^(\p{Extended_Pictographic}(?:‍\p{Extended_Pictographic})*(?:[️\u{1F3FB}-\u{1F3FF}])*)\s*(.*)$/u);
        if (m) return { icon: m[1], label: m[2] || t };
        return { icon: '', label: t };
    }

    // ---- Bottom sheet primitives -------------------------------
    function openSheet(sheetId, backdropId) {
        const sheet = document.getElementById(sheetId);
        const backdrop = document.getElementById(backdropId);
        if (!sheet || !backdrop) return;
        backdrop.hidden = false;
        sheet.setAttribute('aria-hidden', 'false');
        // Forza un reflow per far partire la transizione
        requestAnimationFrame(() => {
            backdrop.classList.add('is-open');
            sheet.classList.add('is-open');
        });
        document.body.classList.add('adm-sheet-open');
    }

    function closeSheet(sheetId, backdropId) {
        const sheet = document.getElementById(sheetId);
        const backdrop = document.getElementById(backdropId);
        if (!sheet || !backdrop) return;
        sheet.classList.remove('is-open');
        backdrop.classList.remove('is-open');
        sheet.setAttribute('aria-hidden', 'true');
        // Nasconde dopo la transizione
        setTimeout(() => {
            backdrop.hidden = true;
            // Solo se nessun altro sheet è aperto
            if (!document.querySelector('.adm-sheet.is-open')) {
                document.body.classList.remove('adm-sheet-open');
            }
        }, 300);
    }

    function closeAllSheets() {
        closeSheet('admPagesSheet', 'admPagesBackdrop');
        closeSheet('admFiltersSheet', 'admFiltersBackdrop');
    }

    // ---- Page switcher -----------------------------------------
    function getActiveTab() {
        const tab = document.querySelector('.admin-tab.active');
        return tab ? tab.dataset.tab : 'bookings';
    }

    function renderPagesSheet() {
        const list = document.getElementById('admPagesList');
        if (!list) return;
        const active = getActiveTab();
        const tabs = Array.from(document.querySelectorAll('.admin-tab[data-tab]'))
            // Esclude il toggle privacy (non è una sezione)
            .filter(t => !t.classList.contains('admin-tab--privacy'));

        list.innerHTML = tabs.map(t => {
            const { icon, label } = splitEmojiLabel(t.textContent);
            const isActive = t.dataset.tab === active;
            return `
                <li>
                    <button type="button" class="adm-sheet-item${isActive ? ' is-active' : ''}"
                            data-page="${t.dataset.tab}"
                            role="option" aria-selected="${isActive ? 'true' : 'false'}">
                        <span class="adm-sheet-item-ico">${icon || '▫️'}</span>
                        <span class="adm-sheet-item-text">
                            <span class="adm-sheet-item-title">${label}</span>
                        </span>
                        <span class="adm-sheet-item-radio" aria-hidden="true"></span>
                    </button>
                </li>`;
        }).join('');

        // Aggiungi voce separata per il toggle privacy (dati sensibili)
        const privacyBtn = document.getElementById('btnToggleSensitive');
        if (privacyBtn) {
            const isHidden = privacyBtn.classList.contains('active');
            const li = document.createElement('li');
            li.innerHTML = `
                <button type="button" class="adm-sheet-item adm-sheet-item--action" data-action="privacy"${isHidden ? ' aria-pressed="true"' : ''}>
                    <span class="adm-sheet-item-ico">👁</span>
                    <span class="adm-sheet-item-text">
                        <span class="adm-sheet-item-title">Dati sensibili</span>
                        <span class="adm-sheet-item-meta">${isHidden ? 'Nascosti' : 'Visibili'} — tocca per ${isHidden ? 'mostrare' : 'nascondere'}</span>
                    </span>
                </button>`;
            list.appendChild(li);
        }

        list.querySelectorAll('.adm-sheet-item').forEach(btn => {
            btn.addEventListener('click', () => {
                if (btn.dataset.action === 'privacy') {
                    if (privacyBtn) privacyBtn.click();
                    setTimeout(() => closeSheet('admPagesSheet', 'admPagesBackdrop'), 150);
                    return;
                }
                const page = btn.dataset.page;
                const target = document.querySelector(`.admin-tab[data-tab="${page}"]`);
                if (target) target.click();
                // Feedback visivo check + chiudi
                list.querySelectorAll('.adm-sheet-item').forEach(b => b.classList.remove('is-active'));
                btn.classList.add('is-active');
                setTimeout(() => closeSheet('admPagesSheet', 'admPagesBackdrop'), 150);
            });
        });
    }

    function updatePageSwitcherLabel() {
        const label = document.getElementById('admMbarPageLabel');
        const ico = document.getElementById('admMbarPageIco');
        const tab = document.querySelector('.admin-tab.active');
        if (!label || !ico || !tab) return;
        const { icon, label: name } = splitEmojiLabel(tab.textContent);
        label.textContent = name;
        ico.textContent = icon || '▫️';
    }

    // ---- Filter button visibility + contextual label -----------
    // Mappa tab → ha filtri? label default, icona
    const FILTER_CONFIG = {
        bookings:  { show: false },
        payments:  { show: false },
        clients:   { show: true, icon: '🔍', label: 'Filtri' },
        schedule:  { show: false },
        analytics: { show: true, icon: '📅', label: 'Periodo' },
        settings:  { show: false },
        registro:  { show: true, icon: '🔍', label: 'Filtri' },
        messaggi:  { show: false },
        schede:    { show: false },
    };

    function updateFilterButton() {
        const btn = document.getElementById('admMbarFilter');
        const ico = document.getElementById('admMbarFilterIco');
        const labelEl = document.getElementById('admMbarFilterLabel');
        if (!btn || !ico || !labelEl) return;

        const tab = getActiveTab();
        const cfg = FILTER_CONFIG[tab] || { show: false };

        if (!cfg.show) {
            btn.hidden = true;
            return;
        }
        btn.hidden = false;
        ico.textContent = cfg.icon || '🔍';

        // Label contestuale
        let label = cfg.label;
        let hasActive = false;

        if (tab === 'analytics') {
            const activeBtn = document.querySelector('.analytics-filter-bar .filter-btn.active');
            if (activeBtn) label = activeBtn.textContent.trim().replace(/^📅\s*/, '');
            hasActive = !!activeBtn && activeBtn.dataset && activeBtn.dataset.default !== 'true';
        } else if (tab === 'clients') {
            hasActive = countActiveClientFilters() > 0;
        } else if (tab === 'registro') {
            hasActive = countActiveRegistroFilters() > 0;
        }

        labelEl.textContent = label;
        btn.classList.toggle('has-active', hasActive);
    }

    // ---- Count helpers -----------------------------------------
    function countActiveClientFilters() {
        return document.querySelectorAll('.clients-filter-chip.active').length;
    }
    function countActiveRegistroFilters() {
        let n = 0;
        // tipo evento (multi)
        n += document.querySelectorAll('.rfilter-type-pills .rfilter-btn.active').length;
        const slot = document.getElementById('registroFilterSlot');
        const method = document.getElementById('registroFilterMethod');
        const status = document.getElementById('registroFilterStatus');
        if (slot && slot.value && slot.value !== 'all') n++;
        if (method && method.value && method.value !== 'all') n++;
        if (status && status.value && status.value !== 'all') n++;
        const search = document.getElementById('registroSearch');
        if (search && search.value.trim()) n++;
        // periodo diverso dal default "Tutto"
        const range = document.querySelector('.registro-date-btns .rfilter-btn.active');
        if (range && range.dataset.range && range.dataset.range !== 'all') n++;
        return n;
    }

    // ---- Filters sheet – rendering contestuale ------------------
    function renderFiltersSheet() {
        const body = document.getElementById('admFiltersBody');
        const title = document.getElementById('admFiltersTitle');
        if (!body || !title) return;
        const tab = getActiveTab();

        body.innerHTML = '';
        title.textContent = 'Filtri';

        if (tab === 'analytics') {
            title.textContent = 'Periodo';
            body.appendChild(buildAnalyticsFilters());
        } else if (tab === 'clients') {
            title.textContent = 'Filtri clienti';
            body.appendChild(buildClientsFilters());
        } else if (tab === 'registro') {
            title.textContent = 'Filtri registro';
            body.appendChild(buildRegistroFilters());
        } else {
            body.innerHTML = '<p class="adm-filt-empty">Nessun filtro disponibile.</p>';
        }
    }

    // ---- Analytics filters (periodo) ----------------------------
    function buildAnalyticsFilters() {
        const wrap = document.createElement('div');

        // Pills periodo — proxy delle filter-btn originali
        const group = document.createElement('div');
        group.className = 'adm-filt-group';
        group.innerHTML = '<span class="adm-filt-label">Periodo</span><div class="adm-filt-pills" id="admAnalyticsPills"></div>';
        wrap.appendChild(group);

        const pillsWrap = group.querySelector('#admAnalyticsPills');
        const origBtns = document.querySelectorAll('.analytics-filter-bar .filter-btn');
        origBtns.forEach(ob => {
            const pill = document.createElement('button');
            pill.type = 'button';
            pill.className = 'adm-filt-pill';
            if (ob.classList.contains('active')) pill.classList.add('is-active');
            pill.textContent = ob.textContent.trim();
            pill.addEventListener('click', () => {
                // Proxy click sull'originale (mantiene tutta la logica)
                ob.click();
                pillsWrap.querySelectorAll('.adm-filt-pill').forEach(p => p.classList.remove('is-active'));
                pill.classList.add('is-active');
                // Se non è "custom", chiudi la sheet dopo un attimo
                if (ob.textContent.trim().toLowerCase().indexOf('personal') === -1) {
                    setTimeout(() => {
                        closeSheet('admFiltersSheet', 'admFiltersBackdrop');
                        updateFilterButton();
                    }, 150);
                } else {
                    // Mostra i custom date
                    customRow.style.display = '';
                }
            });
            pillsWrap.appendChild(pill);
        });

        // Custom dates
        const customGroup = document.createElement('div');
        customGroup.className = 'adm-filt-group';
        customGroup.id = 'admAnalyticsCustom';
        const origCustom = document.getElementById('filterCustomDates');
        const customVisible = origCustom && origCustom.style.display !== 'none';
        customGroup.innerHTML = `
            <span class="adm-filt-label">Range personalizzato</span>
            <div class="adm-filt-row">
                <input type="date" class="adm-filt-date" id="admAnalyticsFrom">
                <span class="adm-filt-row-sep">→</span>
                <input type="date" class="adm-filt-date" id="admAnalyticsTo">
            </div>
        `;
        const customRow = customGroup;
        customRow.style.display = customVisible ? '' : 'none';
        wrap.appendChild(customRow);

        // Sync valori iniziali dai campi originali
        const fromOrig = document.getElementById('filterDateFrom');
        const toOrig   = document.getElementById('filterDateTo');
        const fromNew  = customRow.querySelector('#admAnalyticsFrom');
        const toNew    = customRow.querySelector('#admAnalyticsTo');
        if (fromOrig && fromNew) fromNew.value = fromOrig.value;
        if (toOrig && toNew) toNew.value = toOrig.value;

        // Bottone "Applica" usa gli handler esistenti
        document.getElementById('admFiltersApply').onclick = () => {
            if (customRow.style.display !== 'none') {
                if (fromOrig) fromOrig.value = fromNew.value;
                if (toOrig)   toOrig.value   = toNew.value;
                if (typeof window.applyCustomFilter === 'function') window.applyCustomFilter();
            }
            closeSheet('admFiltersSheet', 'admFiltersBackdrop');
            updateFilterButton();
        };
        document.getElementById('admFiltersReset').onclick = () => {
            const def = document.querySelector('.analytics-filter-bar .filter-btn'); // "Questo mese"
            if (def) def.click();
            closeSheet('admFiltersSheet', 'admFiltersBackdrop');
            updateFilterButton();
        };

        return wrap;
    }

    // ---- Clients filters (chip) ---------------------------------
    function buildClientsFilters() {
        const wrap = document.createElement('div');
        const group = document.createElement('div');
        group.className = 'adm-filt-group';
        group.innerHTML = '<span class="adm-filt-label">Mostra solo clienti</span><div class="adm-filt-pills" id="admClientsPills"></div>';
        wrap.appendChild(group);

        const pillsWrap = group.querySelector('#admClientsPills');
        const origChips = document.querySelectorAll('.clients-filter-chips .clients-filter-chip');
        origChips.forEach(ochip => {
            const pill = document.createElement('button');
            pill.type = 'button';
            pill.className = 'adm-filt-pill';
            if (ochip.classList.contains('active')) pill.classList.add('is-active');
            pill.textContent = ochip.textContent.trim();
            pill.addEventListener('click', () => {
                ochip.click(); // riusa la logica originale
                // Aggiorna stato visivo pills (cert è esclusivo — dopo il click altre chip potrebbero essere state spente)
                requestAnimationFrame(() => {
                    syncClientsPills(pillsWrap);
                });
            });
            pillsWrap.appendChild(pill);
        });

        document.getElementById('admFiltersApply').onclick = () => {
            closeSheet('admFiltersSheet', 'admFiltersBackdrop');
            updateFilterButton();
        };
        document.getElementById('admFiltersReset').onclick = () => {
            // Clicca ogni chip attiva per spegnerla
            document.querySelectorAll('.clients-filter-chips .clients-filter-chip.active').forEach(c => c.click());
            syncClientsPills(pillsWrap);
            updateFilterButton();
        };

        return wrap;
    }

    function syncClientsPills(pillsWrap) {
        const origChips = document.querySelectorAll('.clients-filter-chips .clients-filter-chip');
        const newPills = pillsWrap.querySelectorAll('.adm-filt-pill');
        origChips.forEach((oc, i) => {
            if (newPills[i]) newPills[i].classList.toggle('is-active', oc.classList.contains('active'));
        });
    }

    // ---- Registro filters ---------------------------------------
    function buildRegistroFilters() {
        const wrap = document.createElement('div');

        // Sub-tab attivo: i filtri visualizzati dipendono dal sub-tab
        const subtab = document.querySelector('.registro-subtab.active');
        const subtabName = subtab ? subtab.dataset.subtab : 'registro';

        if (subtabName === 'registro') {
            // Periodo
            wrap.appendChild(buildPillsGroup({
                label: 'Periodo',
                origSelector: '.registro-date-btns .rfilter-btn',
                onPillClick: (pill, orig) => {
                    orig.click();
                    wrap.querySelectorAll('[data-group="periodo"] .adm-filt-pill').forEach(p => p.classList.remove('is-active'));
                    pill.classList.add('is-active');
                    const isCustom = orig.dataset.range === 'custom';
                    const custom = wrap.querySelector('#admRegistroCustom');
                    if (custom) custom.style.display = isCustom ? '' : 'none';
                },
                dataGroup: 'periodo',
            }));

            // Custom dates periodo
            const custom = document.createElement('div');
            custom.className = 'adm-filt-group';
            custom.id = 'admRegistroCustom';
            const origCustom = document.getElementById('registroCustomDates');
            custom.style.display = (origCustom && origCustom.style.display !== 'none') ? '' : 'none';
            custom.innerHTML = `
                <span class="adm-filt-label">Date personalizzate</span>
                <div class="adm-filt-row">
                    <input type="date" class="adm-filt-date" id="admRegistroFrom">
                    <span class="adm-filt-row-sep">→</span>
                    <input type="date" class="adm-filt-date" id="admRegistroTo">
                </div>`;
            const origFrom = document.getElementById('registroDateFrom');
            const origTo = document.getElementById('registroDateTo');
            const newFrom = custom.querySelector('#admRegistroFrom');
            const newTo = custom.querySelector('#admRegistroTo');
            if (origFrom && newFrom) newFrom.value = origFrom.value;
            if (origTo && newTo) newTo.value = origTo.value;
            wrap.appendChild(custom);

            // Tipo evento (multi)
            wrap.appendChild(buildPillsGroup({
                label: 'Tipo evento',
                origSelector: '.rfilter-type-pills .rfilter-btn',
                onPillClick: (pill, orig) => {
                    orig.click();
                    pill.classList.toggle('is-active', orig.classList.contains('active'));
                },
                dataGroup: 'tipoevento',
                multi: true,
            }));

            // Tipo lezione (select → pills)
            wrap.appendChild(buildSelectAsPills({
                label: 'Tipo lezione',
                selectId: 'registroFilterSlot',
                dataGroup: 'slot',
            }));

            // Metodo pagamento (select → pills)
            wrap.appendChild(buildSelectAsPills({
                label: 'Metodo pagamento',
                selectId: 'registroFilterMethod',
                dataGroup: 'method',
            }));

            // Stato (select → pills)
            wrap.appendChild(buildSelectAsPills({
                label: 'Stato',
                selectId: 'registroFilterStatus',
                dataGroup: 'stato',
            }));

            // Ricerca cliente
            const searchGroup = document.createElement('div');
            searchGroup.className = 'adm-filt-group';
            searchGroup.innerHTML = `
                <span class="adm-filt-label">Cerca cliente</span>
                <input type="text" class="adm-filt-input" id="admRegistroSearch" placeholder="Nome, telefono…">`;
            const origSearch = document.getElementById('registroSearch');
            const newSearch = searchGroup.querySelector('#admRegistroSearch');
            if (origSearch && newSearch) newSearch.value = origSearch.value;
            wrap.appendChild(searchGroup);

            document.getElementById('admFiltersApply').onclick = () => {
                // Applica custom date
                if (custom.style.display !== 'none') {
                    if (origFrom) origFrom.value = newFrom.value;
                    if (origTo)   origTo.value   = newTo.value;
                    if (typeof window.applyRegistroCustomRange === 'function') window.applyRegistroCustomRange();
                }
                // Applica ricerca
                if (origSearch && newSearch && newSearch.value !== origSearch.value) {
                    origSearch.value = newSearch.value;
                    origSearch.dispatchEvent(new Event('input', { bubbles: true }));
                }
                closeSheet('admFiltersSheet', 'admFiltersBackdrop');
                updateFilterButton();
            };
            document.getElementById('admFiltersReset').onclick = () => {
                if (typeof window.resetRegistroFilters === 'function') {
                    window.resetRegistroFilters();
                }
                closeSheet('admFiltersSheet', 'admFiltersBackdrop');
                updateFilterButton();
            };
        } else if (subtabName === 'notifiche-admin') {
            wrap.appendChild(buildSelectAsPills({
                label: 'Tipo notifica',
                selectId: 'msgFilterType',
                dataGroup: 'msg-type',
            }));
            wrap.appendChild(buildSelectAsPills({
                label: 'Stato',
                selectId: 'msgFilterStatus',
                dataGroup: 'msg-status',
            }));
            const dateGroup = document.createElement('div');
            dateGroup.className = 'adm-filt-group';
            dateGroup.innerHTML = `
                <span class="adm-filt-label">Data</span>
                <input type="date" class="adm-filt-date" id="admMsgDate">`;
            const origDate = document.getElementById('msgFilterDate');
            const newDate = dateGroup.querySelector('#admMsgDate');
            if (origDate && newDate) newDate.value = origDate.value;
            wrap.appendChild(dateGroup);

            document.getElementById('admFiltersApply').onclick = () => {
                if (origDate && newDate && newDate.value !== origDate.value) {
                    origDate.value = newDate.value;
                    origDate.dispatchEvent(new Event('change', { bubbles: true }));
                }
                closeSheet('admFiltersSheet', 'admFiltersBackdrop');
                updateFilterButton();
            };
            document.getElementById('admFiltersReset').onclick = () => {
                ['msgFilterType', 'msgFilterStatus', 'msgFilterDate'].forEach(id => {
                    const el = document.getElementById(id);
                    if (el) { el.value = ''; el.dispatchEvent(new Event('change', { bubbles: true })); }
                });
                if (typeof window.loadMessaggi === 'function') window.loadMessaggi();
                closeSheet('admFiltersSheet', 'admFiltersBackdrop');
                updateFilterButton();
            };
        } else if (subtabName === 'notifiche-clienti') {
            wrap.appendChild(buildSelectAsPills({
                label: 'Tipo notifica',
                selectId: 'cnFilterType',
                dataGroup: 'cn-type',
            }));
            wrap.appendChild(buildSelectAsPills({
                label: 'Stato',
                selectId: 'cnFilterStatus',
                dataGroup: 'cn-status',
            }));
            const clientGroup = document.createElement('div');
            clientGroup.className = 'adm-filt-group';
            clientGroup.innerHTML = `
                <span class="adm-filt-label">Cerca cliente</span>
                <input type="text" class="adm-filt-input" id="admCnClient" placeholder="Nome cliente…">`;
            const origClient = document.getElementById('cnFilterClient');
            const newClient = clientGroup.querySelector('#admCnClient');
            if (origClient && newClient) newClient.value = origClient.value;
            wrap.appendChild(clientGroup);

            const dateGroup = document.createElement('div');
            dateGroup.className = 'adm-filt-group';
            dateGroup.innerHTML = `
                <span class="adm-filt-label">Data</span>
                <input type="date" class="adm-filt-date" id="admCnDate">`;
            const origDate = document.getElementById('cnFilterDate');
            const newDate = dateGroup.querySelector('#admCnDate');
            if (origDate && newDate) newDate.value = origDate.value;
            wrap.appendChild(dateGroup);

            document.getElementById('admFiltersApply').onclick = () => {
                if (origClient && newClient && newClient.value !== origClient.value) {
                    origClient.value = newClient.value;
                    origClient.dispatchEvent(new Event('input', { bubbles: true }));
                }
                if (origDate && newDate && newDate.value !== origDate.value) {
                    origDate.value = newDate.value;
                    origDate.dispatchEvent(new Event('change', { bubbles: true }));
                }
                closeSheet('admFiltersSheet', 'admFiltersBackdrop');
                updateFilterButton();
            };
            document.getElementById('admFiltersReset').onclick = () => {
                ['cnFilterType', 'cnFilterStatus', 'cnFilterClient', 'cnFilterDate'].forEach(id => {
                    const el = document.getElementById(id);
                    if (el) {
                        el.value = '';
                        el.dispatchEvent(new Event(el.tagName === 'SELECT' ? 'change' : 'input', { bubbles: true }));
                    }
                });
                if (typeof window.renderClientNotifTable === 'function') window.renderClientNotifTable();
                closeSheet('admFiltersSheet', 'admFiltersBackdrop');
                updateFilterButton();
            };
        }

        return wrap;
    }

    // ---- Helpers builders ---------------------------------------
    function buildPillsGroup({ label, origSelector, onPillClick, dataGroup, multi }) {
        const group = document.createElement('div');
        group.className = 'adm-filt-group';
        group.dataset.group = dataGroup;
        group.innerHTML = `<span class="adm-filt-label">${label}</span><div class="adm-filt-pills"></div>`;
        const pillsWrap = group.querySelector('.adm-filt-pills');
        document.querySelectorAll(origSelector).forEach(orig => {
            const pill = document.createElement('button');
            pill.type = 'button';
            pill.className = 'adm-filt-pill';
            if (orig.classList.contains('active')) pill.classList.add('is-active');
            pill.textContent = orig.textContent.trim();
            pill.addEventListener('click', () => onPillClick(pill, orig));
            pillsWrap.appendChild(pill);
        });
        return group;
    }

    function buildSelectAsPills({ label, selectId, dataGroup }) {
        const group = document.createElement('div');
        group.className = 'adm-filt-group';
        group.dataset.group = dataGroup;
        group.innerHTML = `<span class="adm-filt-label">${label}</span><div class="adm-filt-pills"></div>`;
        const pillsWrap = group.querySelector('.adm-filt-pills');
        const select = document.getElementById(selectId);
        if (!select) return group;
        Array.from(select.options).forEach(opt => {
            const pill = document.createElement('button');
            pill.type = 'button';
            pill.className = 'adm-filt-pill';
            if (select.value === opt.value) pill.classList.add('is-active');
            pill.textContent = opt.textContent;
            pill.addEventListener('click', () => {
                select.value = opt.value;
                select.dispatchEvent(new Event('change', { bubbles: true }));
                pillsWrap.querySelectorAll('.adm-filt-pill').forEach(p => p.classList.remove('is-active'));
                pill.classList.add('is-active');
            });
            pillsWrap.appendChild(pill);
        });
        return group;
    }

    // ---- Wiring ------------------------------------------------
    function wireButtons() {
        const pageBtn = document.getElementById('admMbarPage');
        const filterBtn = document.getElementById('admMbarFilter');
        const pagesBackdrop = document.getElementById('admPagesBackdrop');
        const filtersBackdrop = document.getElementById('admFiltersBackdrop');

        if (pageBtn) {
            pageBtn.addEventListener('click', () => {
                renderPagesSheet();
                openSheet('admPagesSheet', 'admPagesBackdrop');
                pageBtn.setAttribute('aria-expanded', 'true');
            });
        }
        if (filterBtn) {
            filterBtn.addEventListener('click', () => {
                renderFiltersSheet();
                openSheet('admFiltersSheet', 'admFiltersBackdrop');
                filterBtn.setAttribute('aria-expanded', 'true');
            });
        }

        // Chiudi tap su backdrop
        if (pagesBackdrop) pagesBackdrop.addEventListener('click', () => {
            closeSheet('admPagesSheet', 'admPagesBackdrop');
            if (pageBtn) pageBtn.setAttribute('aria-expanded', 'false');
        });
        if (filtersBackdrop) filtersBackdrop.addEventListener('click', () => {
            closeSheet('admFiltersSheet', 'admFiltersBackdrop');
            if (filterBtn) filterBtn.setAttribute('aria-expanded', 'false');
        });

        // Chiudi con Esc
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') closeAllSheets();
        });

        // Grabber: tap per chiudere
        document.querySelectorAll('.adm-sheet-grabber').forEach(g => {
            g.addEventListener('click', () => {
                const sheet = g.closest('.adm-sheet');
                if (!sheet) return;
                if (sheet.id === 'admPagesSheet') closeSheet('admPagesSheet', 'admPagesBackdrop');
                if (sheet.id === 'admFiltersSheet') closeSheet('admFiltersSheet', 'admFiltersBackdrop');
            });
        });

        // Swipe-down su ciascun sheet
        document.querySelectorAll('.adm-sheet').forEach(attachSwipeDown);
    }

    function attachSwipeDown(sheet) {
        let startY = null;
        let dy = 0;
        sheet.addEventListener('touchstart', (e) => {
            if (!sheet.classList.contains('is-open')) return;
            // Chiude solo se il drag parte dall'intestazione (grabber/title)
            const t = e.target;
            if (!(t.classList.contains('adm-sheet-grabber') || t.classList.contains('adm-sheet-title'))) return;
            startY = e.touches[0].clientY;
            dy = 0;
        }, { passive: true });
        sheet.addEventListener('touchmove', (e) => {
            if (startY === null) return;
            dy = e.touches[0].clientY - startY;
            if (dy > 0) {
                sheet.style.transform = `translateY(${dy}px)`;
                sheet.style.transition = 'none';
            }
        }, { passive: true });
        sheet.addEventListener('touchend', () => {
            if (startY === null) return;
            sheet.style.transition = '';
            if (dy > 80) {
                if (sheet.id === 'admPagesSheet') closeSheet('admPagesSheet', 'admPagesBackdrop');
                if (sheet.id === 'admFiltersSheet') closeSheet('admFiltersSheet', 'admFiltersBackdrop');
            }
            sheet.style.transform = '';
            startY = null;
            dy = 0;
        });
    }

    // ---- Re-run on tab switch ----------------------------------
    // Intercettiamo i click sugli admin-tab (e sui registro-subtab) per
    // aggiornare label/filter button.
    function observeTabChanges() {
        // Osserva cambi di classe 'active' sui tab (via click OR programmatico)
        const tabs = document.querySelectorAll('.admin-tab');
        tabs.forEach(t => {
            t.addEventListener('click', () => {
                setTimeout(() => {
                    updatePageSwitcherLabel();
                    updateFilterButton();
                }, 0);
            });
        });
        // MutationObserver: copre i cambi programmatici di switchTab()
        const dataTabs = document.querySelectorAll('.admin-tab[data-tab]');
        if (dataTabs.length && 'MutationObserver' in window) {
            const mo = new MutationObserver(() => {
                updatePageSwitcherLabel();
                updateFilterButton();
            });
            dataTabs.forEach(t => mo.observe(t, { attributes: true, attributeFilter: ['class'] }));
        }

        // Anche i sub-tab del registro
        const sub = document.querySelectorAll('.registro-subtab');
        sub.forEach(s => {
            s.addEventListener('click', () => {
                setTimeout(updateFilterButton, 0);
            });
        });

        // Sync quando cambiano filtri lato originale (es. da search live)
        const origSearch = document.getElementById('registroSearch');
        if (origSearch) origSearch.addEventListener('input', () => requestAnimationFrame(updateFilterButton));
        document.querySelectorAll('#registroFilterSlot, #registroFilterMethod, #registroFilterStatus').forEach(el => {
            el.addEventListener('change', () => updateFilterButton());
        });
        document.querySelectorAll('.clients-filter-chip').forEach(c => {
            c.addEventListener('click', () => requestAnimationFrame(updateFilterButton));
        });
        document.querySelectorAll('.analytics-filter-bar .filter-btn').forEach(b => {
            b.addEventListener('click', () => requestAnimationFrame(updateFilterButton));
        });
        document.querySelectorAll('.registro-date-btns .rfilter-btn, .rfilter-type-pills .rfilter-btn').forEach(b => {
            b.addEventListener('click', () => requestAnimationFrame(updateFilterButton));
        });
    }

    // ---- Init --------------------------------------------------
    function init() {
        // Controlla che i nodi della UI mobile siano in DOM
        if (!document.getElementById('admMbar')) return;
        wireButtons();
        updatePageSwitcherLabel();
        updateFilterButton();
        observeTabChanges();

        // Se cambia il viewport chiudi tutto (evita stati strani)
        MQ.addEventListener?.('change', () => {
            closeAllSheets();
            updatePageSwitcherLabel();
            updateFilterButton();
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
