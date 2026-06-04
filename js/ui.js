// ─── UI UTILITIES ─────────────────────────────────────────────────────────────
// Loading states, toast notifications, inline errors.
// Usato in tutto il progetto — compatibile con le future chiamate async Supabase.

// ─── LOADING STATE ────────────────────────────────────────────────────────────

/**
 * Imposta lo stato di caricamento su un pulsante.
 * @param {HTMLButtonElement} btn
 * @param {boolean} isLoading
 * @param {string} loadingText  testo da mostrare durante il caricamento
 */
function setLoading(btn, isLoading, loadingText = 'Caricamento...') {
    if (!btn) return;
    if (isLoading) {
        btn.disabled = true;
        btn.dataset.originalText = btn.innerHTML;
        btn.innerHTML = `<span class="btn-spinner"></span>${loadingText}`;
        btn.classList.add('btn-loading');
    } else {
        btn.disabled = false;
        btn.innerHTML = btn.dataset.originalText || btn.innerHTML;
        btn.classList.remove('btn-loading');
        delete btn.dataset.originalText;
    }
}

// ─── TOAST NOTIFICATIONS ──────────────────────────────────────────────────────

let _toastContainer = null;

function _getToastContainer() {
    if (!_toastContainer) {
        _toastContainer = document.createElement('div');
        _toastContainer.className = 'toast-container';
        document.body.appendChild(_toastContainer);
    }
    return _toastContainer;
}

/**
 * Mostra un toast temporaneo in basso allo schermo.
 * @param {string} message
 * @param {'success'|'error'|'info'} type
 * @param {number} duration  millisecondi prima della scomparsa automatica
 */
function showToast(message, type = 'error', duration = 3500) {
    const container = _getToastContainer();

    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;

    const icon = type === 'success' ? '✓' : type === 'info' ? 'ℹ' : '✕';
    toast.innerHTML = `<span class="toast-icon">${icon}</span><span class="toast-message">${_escHtml(message)}</span>`;

    container.appendChild(toast);

    // Forza reflow per triggherare l'animazione di entrata
    toast.getBoundingClientRect();
    toast.classList.add('toast-visible');

    const remove = () => {
        toast.classList.remove('toast-visible');
        toast.addEventListener('transitionend', () => toast.remove(), { once: true });
    };

    const timer = setTimeout(remove, duration);
    toast.addEventListener('click', () => { clearTimeout(timer); remove(); });
}

// ─── INLINE ERRORS ────────────────────────────────────────────────────────────

/**
 * Mostra un messaggio di errore inline in un elemento esistente.
 * @param {string} elementId
 * @param {string} message
 */
function showInlineError(elementId, message) {
    const el = document.getElementById(elementId);
    if (!el) return;
    el.textContent = message;
    el.style.display = 'block';
}

/**
 * Nasconde un messaggio di errore inline.
 * @param {string} elementId
 */
function hideInlineError(elementId) {
    const el = document.getElementById(elementId);
    if (!el) return;
    el.style.display = 'none';
    el.textContent = '';
}

// ─── HTML ESCAPING ─────────────────────────────────────────────────────────────
// Usare sempre su dati utente interpolati in innerHTML per prevenire XSS.
function _escHtml(str) {
    return String(str ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}
