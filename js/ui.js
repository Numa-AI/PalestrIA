// ─── UI UTILITIES ─────────────────────────────────────────────────────────────
// Loading states, toast notifications, inline errors.
// Usato in tutto il progetto — compatibile con le future chiamate async Supabase.
//
// COSA FA
// Raccolta di utility UI condivise, senza dipendenze, riusate da tutte le pagine:
// stato di caricamento sui pulsanti, toast temporanei, errori inline e helper di
// escaping HTML anti-XSS.
//
// COME FUNZIONA
//  - Loading: setLoading(btn, isLoading, loadingText) disabilita il pulsante, salva il
//    testo originale in dataset.originalText e mostra uno spinner (.btn-spinner/.btn-loading).
//  - Toast: showToast(message, type, duration) crea un toast (.toast/.toast-<type>) nel
//    contenitore lazy _getToastContainer() (.toast-container), con animazione di entrata,
//    auto-dismiss e chiusura al click. type ∈ 'success'|'error'|'info'.
//  - Errori inline: showInlineError(elementId, message)/hideInlineError(elementId) mostrano o
//    nascondono un messaggio in un elemento esistente.
//  - Escaping: _escHtml(str) (entità HTML per innerHTML) e _escAttr(str) (per stringhe passate
//    come argomento dentro handler inline tipo onclick="fn('${_escAttr(v)}')", che neutralizza
//    prima il contesto JS poi quello HTML). Da usare SEMPRE su dati utente non sanitizzati
//    all'origine (es. name/email) per prevenire lo stored XSS nella sessione admin.
//
// CONNESSIONI
//  - Nessuna dipendenza esterna né accesso a Supabase. _escHtml/_escAttr sono usati
//    pervasivamente dai moduli admin-*/booking/calendar quando interpolano dati utente in
//    innerHTML; showToast/setLoading sono i feedback standard per le operazioni async.

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

// ─── HTML ESCAPING ─────────────────────────────────────────────────────────────
// Usare sempre su dati utente interpolati in innerHTML per prevenire XSS.
function _escHtml(str) {
    return String(str ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

// Escaping per dati utente passati come ARGOMENTO STRINGA dentro un handler inline,
// es. onclick="fn('${_escAttr(value)}')". Il valore vive in DUE contesti annidati:
//  1) stringa JS a singoli apici  →  va neutralizzato \ e '
//  2) attributo HTML a doppi apici →  va neutralizzato & " < >
// Si applica prima l'escape JS, poi quello HTML: il browser de-codifica le entità
// PRIMA che il JS interpreti la stringa, restituendo i caratteri già \-escapati.
// Senza, un nome cliente come  a"><img src=x onerror=...>  esegue codice nella
// sessione admin (stored XSS, dato che name/email non sono sanitizzati all'origine).
function _escAttr(str) {
    return _escHtml(
        String(str ?? '')
            .replace(/\\/g, '\\\\')
            .replace(/'/g, "\\'")
    );
}
