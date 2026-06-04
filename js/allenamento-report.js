// Modulo "Report AI" per allenamento.html — lato cliente.
// Gestisce: lista report storici, generazione self-service, opt-in GDPR, modal lettura.
// Dipende da supabaseClient (definito in supabase-client.js).

// ═════════════════════════════════════════════════════════════════════
// STATO E CACHE
// ═════════════════════════════════════════════════════════════════════

let _reportCache = null;        // array di report caricati dal DB
let _reportLoading = false;

const REPORT_FN_URL = 'https://qlbdblkkuxqqrodqojjf.supabase.co/functions/v1/generate-monthly-report';

// ═════════════════════════════════════════════════════════════════════
// HELPER: scroll lock del body quando un modal è aperto
// Evita che la pagina sotto al modal scrolli quando l'utente fa swipe.
// ═════════════════════════════════════════════════════════════════════

// ID dei modal creati da QUESTO modulo. Usati per capire se il body deve
// restare lockato (altri modal statici di allenamento.html hanno class
// .all-modal-overlay ma display:none, quindi querySelector generico è
// inaffidabile per contarli).
const _REPORT_MODAL_IDS = [
    'reportModalOverlay',
    'consentModalOverlay',
    'toneModalOverlay',
    'generatingOverlay',
];

function _lockBodyScroll() {
    document.body.classList.add('all-modal-open');
}

function _unlockBodyScrollIfNoModals() {
    const stillOpen = _REPORT_MODAL_IDS.some(id => document.getElementById(id));
    if (!stillOpen) {
        document.body.classList.remove('all-modal-open');
    }
}

// ═════════════════════════════════════════════════════════════════════
// HELPER: calcolo mese, formattazione
// ═════════════════════════════════════════════════════════════════════

function _getAvailableMonthForGeneration() {
    // ⚠️ TEMPORANEAMENTE: restituisce il mese CORRENTE per permettere test su Aprile.
    // RIATTIVARE comportamento "mese precedente" prima del rilascio in produzione,
    // e riattivare anche il controllo corrispondente nell'Edge Function.
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

// Limite massimo di rigenerazioni per (utente, mese). Deve coincidere con il
// valore nell'Edge Function.
const MAX_GENERATIONS_PER_MONTH = 3;

function _formatYearMonth(ym) {
    if (!ym) return '';
    const [y, m] = ym.split('-');
    const months = ['Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
                    'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'];
    const idx = parseInt(m, 10) - 1;
    return `${months[idx] || m} ${y}`;
}

function _formatTone(tone) {
    return { serious: 'Serio', motivational: 'Motivazionale', ironic: 'Ironico' }[tone] || tone;
}

function _escapeHtml(s) {
    if (s == null) return '';
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

// ═════════════════════════════════════════════════════════════════════
// MARKDOWN → HTML (minimale e safe)
// Supporta: # ## ### headers, **bold**, *italic*, paragrafi
// ═════════════════════════════════════════════════════════════════════

function _markdownToHtml(md) {
    if (!md) return '';
    // Prima scappo HTML potenzialmente pericoloso
    let html = _escapeHtml(md);

    // Headers
    html = html.replace(/^### (.+)$/gm, '<h4>$1</h4>');
    html = html.replace(/^## (.+)$/gm, '<h3>$1</h3>');
    html = html.replace(/^# (.+)$/gm, '<h2>$1</h2>');

    // Bold (**testo**)
    html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    // Italic (*testo*) — escluso **
    html = html.replace(/(?<!\*)\*([^*\n]+)\*(?!\*)/g, '<em>$1</em>');

    // Paragrafi: separo su doppio newline, wrappo in <p> (tranne headers)
    html = html.split(/\n{2,}/).map(block => {
        const trimmed = block.trim();
        if (!trimmed) return '';
        if (/^<h[2-4]>/.test(trimmed)) return trimmed;
        return `<p>${trimmed.replace(/\n/g, '<br>')}</p>`;
    }).filter(Boolean).join('\n');

    return html;
}

// ═════════════════════════════════════════════════════════════════════
// FETCH REPORT STORICI (RLS filtra per user_id=auth.uid())
// ═════════════════════════════════════════════════════════════════════

async function _fetchReports() {
    if (_reportLoading) return _reportCache || [];
    _reportLoading = true;
    try {
        if (typeof supabaseClient === 'undefined') return [];
        // Filtro ESPLICITO per user_id: questa vista è per il cliente ("i MIEI report").
        // Non ci affidiamo solo alla RLS perché se l'utente è admin la policy
        // monthly_reports_admin_all gli mostrerebbe TUTTI i report di tutti gli utenti.
        const { data: authRes } = await supabaseClient.auth.getUser();
        const userId = authRes?.user?.id;
        if (!userId) { _reportCache = []; return _reportCache; }

        const { data, error } = await supabaseClient
            .from('monthly_reports')
            .select('id, user_id, year_month, tone, narrative, scorecard, cost_usd, generated_at, model_used, status')
            .eq('user_id', userId)
            .eq('status', 'generated')
            .order('year_month', { ascending: false });
        if (error) {
            console.error('[Report] fetch error:', error.message);
            return [];
        }
        _reportCache = data || [];
        return _reportCache;
    } finally {
        _reportLoading = false;
    }
}

// ═════════════════════════════════════════════════════════════════════
// RENDER VISTA PRINCIPALE (tab "Report")
// ═════════════════════════════════════════════════════════════════════

// Definizione canonica dei 3 toni supportati (usata in tutte le UI)
const _TONES = [
    { value: 'serious',      label: 'Serio',        icon: '🎯', desc: 'Analitico e professionale' },
    { value: 'motivational', label: 'Motivazionale', icon: '💪', desc: 'Caloroso ed energico' },
    { value: 'ironic',       label: 'Ironico',      icon: '😏', desc: 'Umorismo dry' },
];

async function renderReport() {
    const container = document.getElementById('allContent');
    if (!container) return;

    container.innerHTML = '<div class="all-loading" role="status">Caricamento report...</div>';

    // Auth check
    const { data: authRes } = await supabaseClient.auth.getUser();
    const user = authRes?.user;
    if (!user) {
        container.innerHTML = '<div class="all-empty-state"><p>Devi essere loggato per vedere i report.</p></div>';
        return;
    }

    // ⚠️ TEMPORANEO: la feature Report è disponibile solo agli admin durante
    // la fase di test/refinement. Ai clienti non-admin mostriamo un placeholder
    // "Work in progress". Rimuovere questo blocco quando la feature è pronta.
    const isAdmin = (user.app_metadata)?.role === 'admin';
    if (!isAdmin) {
        container.innerHTML = `
            <div class="all-report-section">
                <div class="all-report-header">
                    <h2 class="all-report-title">📊 Report Mensili</h2>
                </div>
                <div class="all-report-wip">
                    <div class="all-report-wip-icon">🚧</div>
                    <div class="all-report-wip-title">Work in progress</div>
                    <div class="all-report-wip-desc">
                        Stiamo ultimando la feature Report AI. Sarà disponibile prossimamente
                        per tutti gli utenti.
                    </div>
                </div>
            </div>
        `;
        return;
    }

    const reports = await _fetchReports();
    const availableMonth = _getAvailableMonthForGeneration();
    const availableMonthLabel = _formatYearMonth(availableMonth);
    const availableMonthReports = reports.filter(r => r.year_month === availableMonth);

    // Quali toni sono già stati generati per il mese disponibile
    const tonesGenerated = new Set(availableMonthReports.map(r => r.tone));
    const allToneGenerated = _TONES.every(t => tonesGenerated.has(t.value));

    // Raggruppa tutti i report per mese (per la lista archivio)
    const reportsByMonth = reports.reduce((acc, r) => {
        (acc[r.year_month] = acc[r.year_month] || []).push(r);
        return acc;
    }, {});
    const sortedMonths = Object.keys(reportsByMonth).sort().reverse();

    let html = '<div class="all-report-section">';

    // ── Hero card: eyebrow / mese / sub / quota generazioni ──
    const used = availableMonthReports.length;
    const total = MAX_GENERATIONS_PER_MONTH;
    const remaining = Math.max(0, total - used);
    const fillPct = total > 0 ? Math.round((remaining / total) * 100) : 0;
    html += `
        <div class="all-report-hero">
            <div class="all-report-hero-eyebrow">Report mensile</div>
            <div class="all-report-hero-month">${availableMonthLabel}</div>
            <div class="all-report-hero-sub">Scegli un tono e genera il report del mese. Ogni tono può essere usato una sola volta.</div>
            <div class="all-report-hero-quota">
                <span>Generazioni</span>
                <div class="all-report-hero-quota-bar"><div class="all-report-hero-quota-fill" style="width:${fillPct}%"></div></div>
                <b>${remaining} / ${total}</b>
            </div>
        </div>
    `;

    // ── Section header: "Tono del mese" ──
    html += `<div class="all-report-section-h"><span class="t">Tono del mese</span></div>`;

    // ── Tone grid 3 colonne ──
    html += `<div class="all-report-tone-grid">`;
    for (const t of _TONES) {
        const alreadyGenerated = tonesGenerated.has(t.value);
        const disabled = alreadyGenerated;
        let onclick = '';
        if (alreadyGenerated) {
            const existingId = availableMonthReports.find(r => r.tone === t.value)?.id;
            onclick = existingId ? `openReportDetail('${existingId}')` : '';
        } else {
            onclick = `_generateTone('${availableMonth}', '${t.value}')`;
        }
        const stateClass = alreadyGenerated ? 'all-report-tone-card--done' : '';
        const descText = alreadyGenerated ? '✓ Generato — apri' : t.desc;
        html += `
            <button class="all-report-tone-card ${stateClass}"
                    onclick="${onclick}">
                <div class="all-report-tone-card-icon">${t.icon}</div>
                <div class="all-report-tone-card-label">${t.label}</div>
                <div class="all-report-tone-card-desc">${descText}</div>
            </button>
        `;
    }
    html += `</div>`;

    if (allToneGenerated) {
        html += `<div class="all-report-generate-limit">Hai usato tutti e ${MAX_GENERATIONS_PER_MONTH} i toni per ${availableMonthLabel}.</div>`;
    }

    // ── Archivio ──
    html += `<div class="all-report-archive-h"><h2>Archivio</h2></div>`;
    html += '<div class="all-report-list">';
    if (reports.length === 0) {
        html += `<div class="all-empty-state"><p>Non hai ancora report generati. Scegli un tono qui sopra per generare il primo.</p></div>`;
    } else {
        for (const ym of sortedMonths) {
            const monthReports = reportsByMonth[ym];
            const monthLabel = _formatYearMonth(ym);
            html += `<div class="all-report-month-group">
                <div class="all-report-month-group-title">${monthLabel}</div>
                <div class="all-report-month-group-list">`;
            monthReports.sort((a, b) =>
                (new Date(b.generated_at).getTime() || 0) - (new Date(a.generated_at).getTime() || 0)
            );
            for (const r of monthReports) {
                const toneInfo = _TONES.find(t => t.value === r.tone);
                const dateStr = r.generated_at ? new Date(r.generated_at).toLocaleDateString('it-IT') : '';
                const icon = toneInfo?.icon ?? '📝';
                const label = toneInfo?.label ?? (r.tone || '—');
                html += `
                    <button class="all-report-variant" onclick="openReportDetail('${r.id}')">
                        <span class="all-report-variant-icon">${icon}</span>
                        <span class="all-report-variant-label">${label}</span>
                        <span class="all-report-variant-date">${dateStr}</span>
                        <span class="all-report-variant-arrow"></span>
                    </button>
                `;
            }
            html += '</div></div>';
        }
    }
    html += '</div>'; // .all-report-list

    html += '</div>'; // .all-report-section

    container.innerHTML = html;
}

// ═════════════════════════════════════════════════════════════════════
// MODAL: DETTAGLIO REPORT
// ═════════════════════════════════════════════════════════════════════

function openReportDetail(reportId) {
    const report = (_reportCache || []).find(r => r.id === reportId);
    if (!report) return;

    const bodyHtml = _markdownToHtml(report.narrative);
    const toneInfo = _TONES.find(t => t.value === report.tone);
    const toneLabel = toneInfo ? `${toneInfo.icon} ${toneInfo.label}` : _formatTone(report.tone);

    const modalHtml = `
        <div class="all-modal-overlay all-report-modal" id="reportModalOverlay" onclick="if(event.target===this) closeReportModal()">
            <div class="all-modal-box all-report-modal-box">
                <button class="all-modal-close" onclick="closeReportModal()" aria-label="Chiudi">&times;</button>
                <div class="all-report-modal-meta">
                    <span class="all-report-modal-month">${_formatYearMonth(report.year_month)}</span>
                    <span class="all-report-modal-tone">${toneLabel}</span>
                </div>
                <div class="all-report-modal-body">${bodyHtml}</div>
            </div>
        </div>
    `;

    document.getElementById('reportModalOverlay')?.remove();
    document.body.insertAdjacentHTML('beforeend', modalHtml);
    _lockBodyScroll();
    requestAnimationFrame(() => {
        document.getElementById('reportModalOverlay')?.classList.add('visible');
    });
}

function closeReportModal() {
    document.getElementById('reportModalOverlay')?.remove();
    _unlockBodyScrollIfNoModals();
}

// ═════════════════════════════════════════════════════════════════════
// FLUSSO: GENERAZIONE NUOVO REPORT
// Entry point chiamato da uno dei 3 bottoni tono della CTA principale.
// 1. Check consenso GDPR → se manca, mostra modal di consenso (dopo accept ricomincia da qui)
// 2. Chiama Edge Function direttamente (niente modal selezione tono: il tono è già nel click)
// ═════════════════════════════════════════════════════════════════════

async function _generateTone(yearMonth, tone) {
    const { data: authRes } = await supabaseClient.auth.getUser();
    const user = authRes?.user;
    if (!user) { alert('Non sei loggato'); return; }

    const { data: profile } = await supabaseClient.from('profiles')
        .select('report_ai_consent')
        .eq('id', user.id)
        .maybeSingle();

    if (!profile) { alert('Profilo non trovato'); return; }

    if (!profile.report_ai_consent) {
        _showConsentModal(yearMonth, tone);
        return;
    }

    // Tono già scelto cliccando il bottone → genera direttamente.
    // force_regenerate=true perché nell'UI nuova ogni click è una richiesta esplicita
    // (il rate limit lato server impedisce abusi: max 3 con status='generated').
    _startGenerationInternal(yearMonth, tone, /* force */ true);
}

// ── Modal consenso GDPR ──
function _showConsentModal(yearMonth, currentTone) {
    const monthLabel = _formatYearMonth(yearMonth);
    const modalHtml = `
        <div class="all-modal-overlay" id="consentModalOverlay" onclick="if(event.target===this) closeConsentModal()">
            <div class="all-modal-box all-report-consent-box">
                <button class="all-modal-close" onclick="closeConsentModal()" aria-label="Chiudi">&times;</button>
                <h3 class="all-modal-title">Consenso al trattamento AI</h3>
                <p class="all-report-consent-intro">
                    Per generare il report di <strong>${monthLabel}</strong>, l'app analizza i tuoi dati tramite intelligenza artificiale.
                </p>
                <div class="all-report-consent-details">
                    <p><strong>Dati analizzati:</strong></p>
                    <ul>
                        <li>Prenotazioni (sessioni completate, cancellate, aderenza)</li>
                        <li>Log di allenamento (esercizi, carichi, ripetizioni)</li>
                    </ul>
                    <p><strong>Provider AI:</strong> Anthropic (Claude). Nessun altro terzo riceve i tuoi dati.</p>
                    <p><strong>Conservazione:</strong> il report resta nel tuo profilo. Puoi cancellarlo o revocare il consenso in qualsiasi momento.</p>
                </div>
                <label class="all-report-consent-checkbox">
                    <input type="checkbox" id="consentCheckbox">
                    <span>Acconsento al trattamento AI dei miei dati per generare i report mensili.</span>
                </label>
                <div class="all-modal-actions">
                    <button class="all-modal-btn all-modal-btn--secondary" onclick="closeConsentModal()">Annulla</button>
                    <button class="all-modal-btn" onclick="_acceptConsentAndContinue('${yearMonth}', '${currentTone}')">Accetta e continua</button>
                </div>
            </div>
        </div>
    `;

    document.getElementById('consentModalOverlay')?.remove();
    document.body.insertAdjacentHTML('beforeend', modalHtml);
    _lockBodyScroll();
    requestAnimationFrame(() => {
        document.getElementById('consentModalOverlay')?.classList.add('visible');
    });
}

function closeConsentModal() {
    document.getElementById('consentModalOverlay')?.remove();
    _unlockBodyScrollIfNoModals();
}

async function _acceptConsentAndContinue(yearMonth, tone) {
    const checkbox = document.getElementById('consentCheckbox');
    if (!checkbox?.checked) {
        alert('Devi spuntare la casella per procedere.');
        return;
    }

    const { error } = await supabaseClient.rpc('set_report_ai_consent', { p_consent: true });
    if (error) {
        alert('Errore nel salvare il consenso: ' + error.message);
        return;
    }

    closeConsentModal();
    // Consenso appena dato: genera subito il tono già scelto dal bottone
    _startGenerationInternal(yearMonth, tone, /* force */ true);
}

// ── Chiamata Edge Function interna ──
async function _startGenerationInternal(yearMonth, tone, force) {
    // Loading overlay
    const loadingHtml = `
        <div class="all-modal-overlay" id="generatingOverlay">
            <div class="all-modal-box all-report-loading-box">
                <div class="all-report-loading-spinner"></div>
                <h3 class="all-report-loading-title">${force ? 'Rigenerazione' : 'Generazione'} in corso...</h3>
                <p class="all-report-loading-desc">Sto analizzando i tuoi dati e scrivendo il report.</p>
            </div>
        </div>
    `;
    document.body.insertAdjacentHTML('beforeend', loadingHtml);
    _lockBodyScroll();
    requestAnimationFrame(() => {
        document.getElementById('generatingOverlay')?.classList.add('visible');
    });

    try {
        const { data: { session } } = await supabaseClient.auth.getSession();
        if (!session) throw new Error('Sessione scaduta, ricarica la pagina');

        const res = await fetch(REPORT_FN_URL, {
            method: 'POST',
            headers: {
                'Authorization': 'Bearer ' + session.access_token,
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                user_id: session.user.id,
                year_month: yearMonth,
                tone: tone,
                force_regenerate: !!force,
            }),
        });

        const data = await res.json();
        document.getElementById('generatingOverlay')?.remove();
        _unlockBodyScrollIfNoModals();

        if (!res.ok || !data.success) {
            if (data.code === 'REGEN_LIMIT_REACHED') {
                alert(`Hai raggiunto il limite di ${data.limit} generazioni per questo mese. Non puoi rigenerare ulteriormente.`);
            } else {
                const msg = data.error || `Errore HTTP ${res.status}`;
                alert('Errore nella generazione:\n' + msg);
            }
            return;
        }

        // Ricarica lista e apri dettaglio
        _reportCache = null;
        await renderReport();
        if (data.report_id) {
            setTimeout(() => openReportDetail(data.report_id), 150);
        }
    } catch (e) {
        document.getElementById('generatingOverlay')?.remove();
        _unlockBodyScrollIfNoModals();
        alert('Errore: ' + (e.message || 'richiesta fallita'));
    }
}
