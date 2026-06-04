// ══════════════════════════════════════════════════════════════════════════
// ██  TAB MESSAGGI — Invio notifiche push dall'admin
// ══════════════════════════════════════════════════════════════════════════

function showMsgResultPopup(recipients, failed) {
    // Rimuovi popup precedente se esiste
    const old = document.getElementById('msgResultPopup');
    if (old) old.remove();
    const oldOverlay = document.getElementById('msgResultOverlay');
    if (oldOverlay) oldOverlay.remove();

    const getInitials = (name) => {
        const parts = name.trim().split(/\s+/);
        return (parts[0]?.[0] || '') + (parts[1]?.[0] || '');
    };

    let html = '';
    if (recipients.length > 0) {
        html += '<div class="msg-popup-section">';
        html += `<div class="msg-popup-section-title msg-popup-section-title--ok">✅ Inviate con successo (${recipients.length})</div>`;
        html += '<ul class="msg-popup-list msg-popup-list--ok">';
        recipients.forEach(name => {
            html += `<li><span class="msg-popup-avatar">${getInitials(name)}</span> ${name}</li>`;
        });
        html += '</ul></div>';
    }
    if (failed.length > 0) {
        html += '<div class="msg-popup-section">';
        html += `<div class="msg-popup-section-title msg-popup-section-title--fail">❌ Non recapitate (${failed.length})</div>`;
        html += '<ul class="msg-popup-list msg-popup-list--fail">';
        failed.forEach(name => {
            html += `<li><span class="msg-popup-avatar">${getInitials(name)}</span> ${name}</li>`;
        });
        html += '</ul></div>';
    }
    if (recipients.length === 0 && failed.length === 0) {
        html = '<div class="msg-popup-empty">Nessun destinatario trovato.</div>';
    }

    const overlay = document.createElement('div');
    overlay.id = 'msgResultOverlay';
    overlay.className = 'msg-popup-overlay';
    overlay.onclick = (e) => { e.stopPropagation(); };

    const popup = document.createElement('div');
    popup.id = 'msgResultPopup';
    popup.className = 'msg-popup';
    popup.innerHTML = `
        <div class="msg-popup-header">
            <h3>📩 Risultato invio</h3>
            <button class="msg-popup-close" onclick="document.getElementById('msgResultOverlay').remove();document.getElementById('msgResultPopup').remove();">✕</button>
        </div>
        <div class="msg-popup-body">${html}</div>
    `;

    document.body.appendChild(overlay);
    document.body.appendChild(popup);
}

function renderMessaggiTab() {
    const dateInput = document.getElementById('msgDate');
    if (dateInput && !dateInput.value) {
        const today = new Date();
        dateInput.value = today.toISOString().split('T')[0];
    }
}

function onMsgRecipientModeChange(mode) {
    const datePicker = document.getElementById('msgDatePicker');
    const timePicker = document.getElementById('msgTimePicker');
    datePicker.style.display = (mode === 'giorno' || mode === 'ora') ? 'block' : 'none';
    timePicker.style.display = mode === 'ora' ? 'block' : 'none';
    if (mode === 'giorno' || mode === 'ora') {
        const dateInput = document.getElementById('msgDate');
        if (!dateInput.value) {
            dateInput.value = new Date().toISOString().split('T')[0];
        }
        if (mode === 'ora') onMsgDateChange(dateInput.value);
    }
}

function onMsgDateChange(dateStr) {
    const select = document.getElementById('msgTimeSlot');
    select.innerHTML = '';
    if (!dateStr) {
        select.innerHTML = '<option value="">Seleziona una data</option>';
        return;
    }
    const d = new Date(dateStr + 'T00:00:00');
    const dayNames = ['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato'];
    const dayName = dayNames[d.getDay()];
    const formatted = dateStr; // already YYYY-MM-DD
    const slots = getScheduleForDate(formatted, dayName);
    if (!slots || slots.length === 0) {
        select.innerHTML = '<option value="">Nessuno slot in questo giorno</option>';
        return;
    }
    slots.forEach(slot => {
        const opt = document.createElement('option');
        opt.value = slot.time;
        opt.textContent = slot.time + ' — ' + (slot.type === 'personal-training' ? 'Autonomia' : slot.type === 'small-group' ? 'Lezione di Gruppo' : 'Slot prenotato');
        select.appendChild(opt);
    });
}

async function sendAdminMessage() {
    const title = document.getElementById('msgTitle').value.trim();
    const body = document.getElementById('msgBody').value.trim();
    const mode = document.querySelector('input[name="msgRecipientMode"]:checked')?.value || 'tutti';
    const date = document.getElementById('msgDate')?.value || '';
    const time = document.getElementById('msgTimeSlot')?.value || '';
    const status = document.getElementById('msgStatus');

    if (!title || !body) {
        status.textContent = '⚠️ Inserisci titolo e messaggio.';
        status.style.color = '#dc2626';
        return;
    }
    if ((mode === 'giorno' || mode === 'ora') && !date) {
        status.textContent = '⚠️ Seleziona una data.';
        status.style.color = '#dc2626';
        return;
    }
    if (mode === 'ora' && !time) {
        status.textContent = '⚠️ Seleziona un orario.';
        status.style.color = '#dc2626';
        return;
    }

    const modeLabel = mode === 'tutti' ? 'tutti gli utenti' : mode === 'giorno' ? `iscritti del ${date}` : `iscritti ${date} alle ${time}`;
    if (!confirm(`Inviare la notifica a ${modeLabel}?`)) return;

    status.textContent = '⏳ Invio in corso...';
    status.style.color = '#6b7280';

    const _abortCtrl = new AbortController();
    const _abortTimer = setTimeout(() => _abortCtrl.abort(), 20000);
    try {
        const { data: { session: _msgSession } } = await supabaseClient.auth.getSession();
        const res = await fetch(`${SUPABASE_URL}/functions/v1/send-admin-message`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + (_msgSession?.access_token || '') },
            body: JSON.stringify({ title, body, mode, date, time }),
            signal: _abortCtrl.signal
        });
        clearTimeout(_abortTimer);
        const data = await res.json();
        if (data.ok) {
            status.textContent = `✅ Inviate ${data.sent} notifiche.`;
            status.style.color = '#16a34a';
            document.getElementById('msgTitle').value = '';
            document.getElementById('msgBody').value = '';
            showMsgResultPopup(data.recipients || [], data.failed || []);
        } else {
            status.textContent = `❌ Errore: ${data.error}`;
            status.style.color = '#dc2626';
        }
    } catch (e) {
        clearTimeout(_abortTimer);
        const msg = e.name === 'AbortError' ? 'Timeout — invio non confermato. Riprova.' : `Errore di rete: ${e.message}`;
        status.textContent = `❌ ${msg}`;
        status.style.color = '#dc2626';
    }
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────
// Questo è l'ultimo modulo admin-*.js a caricarsi: tutte le funzioni sono disponibili.
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initAdmin);
} else {
    initAdmin();
}

// Aggiorna i dati quando la pagina viene ripristinata dal bfcache (back/forward)
window.addEventListener('pageshow', (event) => {
    if (!event.persisted) return;
    const activeTab = document.querySelector('.admin-tab.active');
    if (activeTab) switchTab(activeTab.dataset.tab);
    _applyPrivacyMask();
});
