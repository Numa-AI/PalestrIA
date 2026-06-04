/* ============================================================= */
/* Admin – Desktop sidebar + topbar + date popover (≥ 1024px)      */
/* Sostituisce la riga orizzontale di tab admin con una sidebar    */
/* verticale + topbar con titolo della sezione e date picker       */
/* contestuale (visibile solo su Statistiche & Fatturato).         */
/* Tutte le azioni passano in proxy dai click sugli elementi       */
/* esistenti (.admin-tab, .filter-btn, #filterDateFrom/To) così    */
/* la logica di business resta invariata.                          */
/* ============================================================= */
(function () {
    'use strict';

    const MQ = window.matchMedia('(min-width: 1024px)');

    // ---- Config sezioni (ordine scelto dall'utente) ------------
    const SECTIONS = [
        { id: 'bookings',  label: 'Prenotazioni',            icon: iconCalendar,   group: 1 },
        { id: 'payments',  label: 'Pagamenti',               icon: iconCard,       group: 1 },
        { id: 'analytics', label: 'Statistiche & Fatturato', icon: iconChart,      group: 1 },
        { id: 'schede',    label: 'Schede',                  icon: iconDumbbell,   group: 1 },
        { id: 'registro',  label: 'Registro',                icon: iconBook,       group: 1 },
        { id: 'clients',   label: 'Clienti',                 icon: iconUsers,      group: 1 },
        { id: 'schedule',  label: 'Gestione Orari',          icon: iconClock,      group: 1 },
        { id: 'messaggi',  label: 'Messaggi',                icon: iconMessage,    group: 2 },
        { id: 'settings',  label: 'Impostazioni',            icon: iconSettings,   group: 2 },
    ];

    // ---- Icone Lucide (SVG inline, stroke 2, size 16) ----------
    function svg(paths) {
        return '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths + '</svg>';
    }
    function iconCalendar()  { return svg('<rect x="3" y="4" width="18" height="18" rx="2" ry="2"/><line x1="16" x2="16" y1="2" y2="6"/><line x1="8" x2="8" y1="2" y2="6"/><line x1="3" x2="21" y1="10" y2="10"/>'); }
    function iconCard()      { return svg('<rect width="20" height="14" x="2" y="5" rx="2"/><line x1="2" x2="22" y1="10" y2="10"/>'); }
    function iconChart()     { return svg('<path d="M3 3v18h18"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>'); }
    function iconDumbbell()  { return svg('<path d="M6.5 6.5 17.5 17.5"/><path d="m21 21-1-1"/><path d="m3 3 1 1"/><path d="m18 22 4-4"/><path d="m2 6 4-4"/><path d="m6.5 6.5-2.5 2.5"/><path d="m17.5 17.5-2.5 2.5"/><path d="m14 21 7-7"/>'); }
    function iconBook()      { return svg('<path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>'); }
    function iconUsers()     { return svg('<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>'); }
    function iconClock()     { return svg('<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>'); }
    function iconUpload()    { return svg('<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/>'); }
    function iconMessage()   { return svg('<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>'); }
    function iconSettings()  { return svg('<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>'); }
    function iconEye()       { return svg('<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>'); }

    // ---- Tab helpers --------------------------------------------
    function getActiveTab() {
        const tab = document.querySelector('.admin-tab.active');
        return tab ? tab.dataset.tab : 'bookings';
    }

    function sectionById(id) { return SECTIONS.find(s => s.id === id); }

    // ---- Sidebar ------------------------------------------------
    function buildSidebar() {
        const list = document.getElementById('admSideList');
        if (!list) return;
        list.innerHTML = '';
        let lastGroup = SECTIONS.length ? SECTIONS[0].group : 1;
        SECTIONS.forEach((s) => {
            if (s.group !== lastGroup) {
                const liDiv = document.createElement('li');
                liDiv.setAttribute('role', 'presentation');
                liDiv.innerHTML = '<div class="adm-side-divider" aria-hidden="true"></div>';
                list.appendChild(liDiv);
                lastGroup = s.group;
            }
            const li = document.createElement('li');
            li.innerHTML = `
                <button type="button" class="adm-side-item" data-page="${s.id}" aria-current="${getActiveTab() === s.id ? 'page' : 'false'}">
                    ${s.icon()}
                    <span class="adm-side-item-label">${s.label}</span>
                </button>`;
            list.appendChild(li);
        });

        // Voce azione: Dati sensibili (👁)
        const privacyBtn = document.getElementById('btnToggleSensitive');
        if (privacyBtn) {
            const liDivider = document.createElement('li');
            liDivider.setAttribute('role', 'presentation');
            liDivider.innerHTML = '<div class="adm-side-divider" aria-hidden="true"></div>';
            list.appendChild(liDivider);

            const li = document.createElement('li');
            li.innerHTML = `
                <button type="button" class="adm-side-item adm-side-item--action" data-action="privacy" aria-pressed="${privacyBtn.classList.contains('active') ? 'true' : 'false'}">
                    ${iconEye()}
                    <span class="adm-side-item-label">Dati sensibili</span>
                </button>`;
            list.appendChild(li);
        }

        // Wiring click
        list.querySelectorAll('.adm-side-item').forEach(btn => {
            btn.addEventListener('click', () => {
                if (btn.dataset.action === 'privacy') {
                    if (privacyBtn) privacyBtn.click();
                    btn.classList.toggle('is-pressed', privacyBtn && privacyBtn.classList.contains('active'));
                    btn.setAttribute('aria-pressed', btn.classList.contains('is-pressed') ? 'true' : 'false');
                    return;
                }
                const page = btn.dataset.page;
                const target = document.querySelector(`.admin-tab[data-tab="${page}"]`);
                if (target) target.click();
            });
        });
    }

    function updateSidebarActive() {
        const list = document.getElementById('admSideList');
        if (!list) return;
        const active = getActiveTab();
        list.querySelectorAll('.adm-side-item').forEach(btn => {
            if (btn.dataset.action === 'privacy') {
                const privacyBtn = document.getElementById('btnToggleSensitive');
                const pressed = !!(privacyBtn && privacyBtn.classList.contains('active'));
                btn.classList.toggle('is-pressed', pressed);
                btn.setAttribute('aria-pressed', pressed ? 'true' : 'false');
                return;
            }
            const isActive = btn.dataset.page === active;
            btn.classList.toggle('is-active', isActive);
            btn.setAttribute('aria-current', isActive ? 'page' : 'false');
        });
    }

    // ---- Topbar -------------------------------------------------
    function updateTopbar() {
        const titleEl = document.getElementById('admTopbarTitle');
        const exportBtn = document.getElementById('admTopbarExport');
        const dateBtn = document.getElementById('admTopbarDateBtn');
        if (!titleEl) return;
        const active = getActiveTab();
        const section = sectionById(active);
        titleEl.textContent = section ? section.label : 'Amministrazione';

        // Date picker e Export visibili solo su Statistiche
        if (active === 'analytics') {
            if (dateBtn) dateBtn.hidden = false;
            if (exportBtn) exportBtn.hidden = false;
            updateDateButtonLabel();
        } else {
            if (dateBtn) dateBtn.hidden = true;
            if (exportBtn) exportBtn.hidden = true;
        }
    }

    function updateDateButtonLabel() {
        const labelEl = document.getElementById('admTopbarDateLabel');
        if (!labelEl) return;
        const activeBtn = document.querySelector('.analytics-filter-bar .filter-btn.active');
        if (activeBtn) {
            labelEl.textContent = activeBtn.textContent.trim().replace(/^📅\s*/, '');
        } else {
            labelEl.textContent = 'Questo mese';
        }
    }

    // ---- Date popover -------------------------------------------
    let _popoverOpen = false;

    function openDatepop() {
        const btn = document.getElementById('admTopbarDateBtn');
        const pop = document.getElementById('admDatepop');
        const backdrop = document.getElementById('admDatepopBackdrop');
        if (!btn || !pop || !backdrop) return;
        renderPresets();
        syncPopoverInputs();
        positionPopover();
        backdrop.hidden = false;
        requestAnimationFrame(() => {
            backdrop.classList.add('is-open');
            pop.classList.add('is-open');
        });
        pop.setAttribute('aria-hidden', 'false');
        btn.setAttribute('aria-expanded', 'true');
        _popoverOpen = true;
    }

    function closeDatepop() {
        const btn = document.getElementById('admTopbarDateBtn');
        const pop = document.getElementById('admDatepop');
        const backdrop = document.getElementById('admDatepopBackdrop');
        if (!btn || !pop || !backdrop) return;
        backdrop.classList.remove('is-open');
        pop.classList.remove('is-open');
        pop.setAttribute('aria-hidden', 'true');
        btn.setAttribute('aria-expanded', 'false');
        setTimeout(() => { backdrop.hidden = true; }, 200);
        _popoverOpen = false;
    }

    function positionPopover() {
        const btn = document.getElementById('admTopbarDateBtn');
        const pop = document.getElementById('admDatepop');
        if (!btn || !pop) return;
        const rect = btn.getBoundingClientRect();
        const popW = 340;
        const gap = 8;
        // Preferisce allineamento a destra del bottone
        let left = rect.right - popW;
        if (left < 16) left = 16;
        if (left + popW > window.innerWidth - 16) left = window.innerWidth - popW - 16;
        const top = rect.bottom + gap;
        pop.style.left = left + 'px';
        pop.style.top = top + 'px';
    }

    function renderPresets() {
        const wrap = document.getElementById('admDatepopPresets');
        if (!wrap) return;
        wrap.innerHTML = '';
        const origBtns = document.querySelectorAll('.analytics-filter-bar .filter-btn');
        origBtns.forEach(ob => {
            const pill = document.createElement('button');
            pill.type = 'button';
            pill.className = 'adm-datepop-preset';
            if (ob.classList.contains('active')) pill.classList.add('is-active');
            pill.textContent = ob.textContent.trim();
            pill.addEventListener('click', () => {
                ob.click();
                wrap.querySelectorAll('.adm-datepop-preset').forEach(p => p.classList.remove('is-active'));
                pill.classList.add('is-active');
                // Se non è "Personalizzato" chiudi il popover
                if (ob.textContent.trim().toLowerCase().indexOf('personal') === -1) {
                    setTimeout(() => {
                        closeDatepop();
                        updateDateButtonLabel();
                    }, 120);
                }
            });
            wrap.appendChild(pill);
        });
    }

    function syncPopoverInputs() {
        const origFrom = document.getElementById('filterDateFrom');
        const origTo = document.getElementById('filterDateTo');
        const newFrom = document.getElementById('admDatepopFrom');
        const newTo = document.getElementById('admDatepopTo');
        if (origFrom && newFrom) newFrom.value = origFrom.value;
        if (origTo && newTo) newTo.value = origTo.value;
    }

    function wireDatePopover() {
        const btn = document.getElementById('admTopbarDateBtn');
        const backdrop = document.getElementById('admDatepopBackdrop');
        const applyBtn = document.getElementById('admDatepopApply');
        if (!btn || !backdrop || !applyBtn) return;

        btn.addEventListener('click', () => {
            if (_popoverOpen) closeDatepop();
            else openDatepop();
        });
        backdrop.addEventListener('click', () => closeDatepop());
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && _popoverOpen) closeDatepop();
        });
        window.addEventListener('resize', () => {
            if (_popoverOpen) positionPopover();
        });
        window.addEventListener('scroll', () => {
            if (_popoverOpen) positionPopover();
        }, { passive: true });

        applyBtn.addEventListener('click', () => {
            const origFrom = document.getElementById('filterDateFrom');
            const origTo = document.getElementById('filterDateTo');
            const newFrom = document.getElementById('admDatepopFrom');
            const newTo = document.getElementById('admDatepopTo');
            if (origFrom && newFrom) origFrom.value = newFrom.value;
            if (origTo && newTo) origTo.value = newTo.value;
            if (typeof window.applyCustomFilter === 'function') {
                window.applyCustomFilter();
            }
            closeDatepop();
            updateDateButtonLabel();
        });
    }

    // ---- Export button -----------------------------------------
    function wireExport() {
        const btn = document.getElementById('admTopbarExport');
        if (!btn) return;
        btn.addEventListener('click', () => {
            if (typeof window.downloadFiscalReport === 'function') {
                window.downloadFiscalReport();
            }
        });
    }

    // ---- Observer: click su tab + MutationObserver sulla classe ---
    // Il click copre le interazioni utente; il MutationObserver copre i
    // cambi programmatici (es. showDashboard -> switchTab da sessionStorage).
    function observeTabChanges() {
        document.querySelectorAll('.admin-tab').forEach(t => {
            t.addEventListener('click', () => {
                setTimeout(() => {
                    updateSidebarActive();
                    updateTopbar();
                }, 0);
            });
        });

        const tabs = document.querySelectorAll('.admin-tab[data-tab]');
        if (tabs.length && 'MutationObserver' in window) {
            const mo = new MutationObserver(() => {
                updateSidebarActive();
                updateTopbar();
            });
            tabs.forEach(t => mo.observe(t, { attributes: true, attributeFilter: ['class'] }));
        }

        // Quando cambia il filtro analytics, aggiorna label topbar
        document.querySelectorAll('.analytics-filter-bar .filter-btn').forEach(b => {
            b.addEventListener('click', () => requestAnimationFrame(updateDateButtonLabel));
        });
    }

    // ---- Init --------------------------------------------------
    function init() {
        if (!document.getElementById('admSidebar')) return;
        buildSidebar();
        updateSidebarActive();
        updateTopbar();
        wireDatePopover();
        wireExport();
        observeTabChanges();

        MQ.addEventListener?.('change', () => {
            if (!MQ.matches) closeDatepop();
            updateSidebarActive();
            updateTopbar();
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
