// ─── MODAL DIALOGS (confirm / prompt / alert) ──────────────────────────────────
// Sostituiscono i popup nativi del browser (window.confirm / prompt / alert) con
// dialog grafici coerenti con lo stile PalestrIA. API basate su Promise. Nessuna
// dipendenza esterna. CSS iniettato una sola volta. Testo via textContent → XSS-safe.
// Accento brand viola #8B5CF6 (--primary-purple); rosso #dc3545 per azioni distruttive.

(function () {
    'use strict';

    const ICONS = {
        question: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.5"/><path d="M9.2 9.3a2.8 2.8 0 0 1 5.4 1c0 1.8-2.6 2.2-2.6 3.7"/><circle cx="12" cy="17.4" r="0.6" fill="currentColor" stroke="none"/></svg>',
        danger:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/></svg>',
        edit:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5z"/></svg>',
        warn:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><line x1="12" y1="9.5" x2="12" y2="13.5"/><circle cx="12" cy="17" r="0.6" fill="currentColor" stroke="none"/></svg>',
        info:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.5"/><line x1="12" y1="11" x2="12" y2="16.5"/><circle cx="12" cy="8" r="0.6" fill="currentColor" stroke="none"/></svg>',
        success:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9.5"/><polyline points="8 12.5 11 15.5 16 9.5"/></svg>',
    };

    function injectStyles() {
        if (document.getElementById('pim-styles')) return;
        const css = `
.pim-overlay {
    position: fixed; inset: 0; z-index: 2147483000;
    background: rgba(0,0,0,0.55); backdrop-filter: blur(2px); -webkit-backdrop-filter: blur(2px);
    display: flex; align-items: center; justify-content: center; padding: 16px;
    animation: pimFade .2s ease;
}
@keyframes pimFade { from { opacity: 0 } to { opacity: 1 } }
.pim-box {
    position: relative; width: 100%; max-width: 400px;
    max-height: 88vh; overflow-y: auto;
    background: #fff; border-radius: 18px;
    box-shadow: 0 20px 60px rgba(0,0,0,0.3);
    padding: 26px 22px 20px;
    animation: pimPop .25s cubic-bezier(.18,.89,.32,1.28);
}
@keyframes pimPop { from { transform: translateY(12px) scale(.96); opacity: 0 } to { transform: none; opacity: 1 } }
.pim-icon {
    width: 54px; height: 54px; margin: 0 auto 14px;
    display: flex; align-items: center; justify-content: center; border-radius: 50%;
}
.pim-icon svg { width: 28px; height: 28px; }
.pim-icon--info    { background: rgba(139,92,246,0.12); color: #8B5CF6; }
.pim-icon--warn    { background: rgba(234,123,10,0.12); color: #ea7b0a; }
.pim-icon--danger  { background: rgba(220,53,69,0.10);  color: #dc3545; }
.pim-icon--success { background: rgba(34,160,90,0.12);  color: #22a05a; }
.pim-title { font-size: 1.12rem; font-weight: 800; color: #1a1a1a; text-align: center; line-height: 1.3; }
.pim-msg   { font-size: .92rem; color: #5a6672; text-align: center; margin-top: 8px; line-height: 1.45; white-space: pre-line; }
.pim-input {
    width: 100%; margin-top: 18px; padding: 12px 14px; box-sizing: border-box;
    border: 1.5px solid #d8dee3; border-radius: 12px;
    font-size: 1rem; font-family: inherit; color: #1a1a1a; outline: none;
    transition: border-color .15s;
}
.pim-input:focus { border-color: #8B5CF6; }
.pim-actions { display: flex; gap: 10px; margin-top: 22px; }
.pim-btn {
    flex: 1; padding: 12px 14px; border: none; border-radius: 12px;
    font-size: .95rem; font-weight: 700; cursor: pointer; font-family: inherit;
    transition: transform .1s, background-color .2s, opacity .2s;
}
.pim-btn:active { transform: scale(.97); }
.pim-btn--primary { background: #8B5CF6; color: #fff; }
.pim-btn--primary:hover { background: #7C3AED; }
.pim-btn--danger  { background: #dc3545; color: #fff; }
.pim-btn--danger:hover { background: #c42d3c; }
.pim-btn--ghost   { background: #f1f3f5; color: #444; }
.pim-btn--ghost:hover { background: #e2e6ea; }
body.pim-open { overflow: hidden; }`;
        const style = document.createElement('style');
        style.id = 'pim-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }

    function open({ title, message, iconKey, iconClass, input, actions, escapeValue }) {
        return new Promise(resolve => {
            injectStyles();
            const overlay = document.createElement('div');
            overlay.className = 'pim-overlay';
            const box = document.createElement('div');
            box.className = 'pim-box';
            box.setAttribute('role', 'dialog');
            box.setAttribute('aria-modal', 'true');
            overlay.appendChild(box);
            if (iconKey) {
                const ic = document.createElement('div');
                ic.className = 'pim-icon ' + (iconClass || 'pim-icon--info');
                ic.setAttribute('aria-hidden', 'true');
                ic.innerHTML = ICONS[iconKey] || '';
                box.appendChild(ic);
            }
            if (title) {
                const t = document.createElement('div');
                t.className = 'pim-title';
                t.textContent = title;
                box.appendChild(t);
            }
            if (message) {
                const m = document.createElement('div');
                m.className = 'pim-msg';
                m.textContent = message;
                box.appendChild(m);
            }
            let inputEl = null;
            if (input) {
                inputEl = document.createElement('input');
                inputEl.className = 'pim-input';
                inputEl.type = input.type || 'text';
                if (input.inputmode) inputEl.inputMode = input.inputmode;
                if (input.placeholder) inputEl.placeholder = input.placeholder;
                inputEl.value = input.value != null ? input.value : '';
                box.appendChild(inputEl);
            }
            const act = document.createElement('div');
            act.className = 'pim-actions';
            box.appendChild(act);
            let settled = false;
            function close(result) {
                if (settled) return;
                settled = true;
                document.removeEventListener('keydown', onKey, true);
                overlay.remove();
                document.body.classList.remove('pim-open');
                resolve(result);
            }
            actions.forEach(a => {
                const b = document.createElement('button');
                b.type = 'button';
                b.className = 'pim-btn ' + a.cls;
                b.textContent = a.text;
                b.addEventListener('click', () =>
                    close(a.returnInput ? (inputEl ? inputEl.value : null) : a.value));
                act.appendChild(b);
            });
            function onKey(e) {
                if (e.key === 'Escape') { e.preventDefault(); close(escapeValue); }
                else if (e.key === 'Enter' && inputEl) { e.preventDefault(); close(inputEl.value); }
            }
            document.addEventListener('keydown', onKey, true);
            overlay.addEventListener('click', e => { if (e.target === overlay) close(escapeValue); });
            document.body.appendChild(overlay);
            document.body.classList.add('pim-open');
            setTimeout(() => {
                if (inputEl) { inputEl.focus(); if (input.selectAll !== false) inputEl.select(); }
                else { const p = act.querySelector('.pim-btn--primary, .pim-btn--danger'); if (p) p.focus(); }
            }, 60);
        });
    }

    function showConfirm(opts) {
        if (typeof opts === 'string') opts = { message: opts };
        opts = opts || {};
        const msg = opts.message != null ? opts.message : '';
        const isDanger = opts.danger != null ? opts.danger : /elimin|rimuov/i.test(msg);
        const confirmText = opts.confirmText || (isDanger ? (/rimuov/i.test(msg) ? 'Rimuovi' : 'Elimina') : 'Conferma');
        const cancelText  = opts.cancelText || 'Annulla';
        const title = opts.title || (isDanger ? 'Conferma eliminazione' : 'Conferma');
        return open({
            title, message: msg,
            iconKey:   opts.icon || (isDanger ? 'danger' : 'question'),
            iconClass: isDanger ? 'pim-icon--danger' : 'pim-icon--info',
            escapeValue: false,
            actions: [
                { text: cancelText,  cls: 'pim-btn--ghost', value: false },
                { text: confirmText, cls: isDanger ? 'pim-btn--danger' : 'pim-btn--primary', value: true },
            ],
        });
    }

    function showPrompt(message, defaultValue, opts) {
        if (message && typeof message === 'object') { opts = message; message = opts.message; defaultValue = opts.value; }
        opts = opts || {};
        return open({
            title: opts.title || message || '',
            message: opts.subtitle || '',
            iconKey: 'edit', iconClass: 'pim-icon--info',
            escapeValue: null,
            input: {
                type: opts.type || 'text',
                inputmode: opts.numeric ? 'numeric' : opts.inputmode,
                value: defaultValue != null ? defaultValue : '',
                placeholder: opts.placeholder,
                selectAll: opts.selectAll,
            },
            actions: [
                { text: opts.cancelText || 'Annulla', cls: 'pim-btn--ghost', value: null },
                { text: opts.confirmText || 'OK', cls: 'pim-btn--primary', returnInput: true },
            ],
        });
    }

    function showAlert(message, opts) {
        if (message && typeof message === 'object') { opts = message; message = opts.message; }
        opts = opts || {};
        const type = opts.type || 'info';
        const iconClass = type === 'error' ? 'pim-icon--danger'
            : type === 'success' ? 'pim-icon--success'
            : type === 'warn' ? 'pim-icon--warn' : 'pim-icon--info';
        const iconKey = type === 'error' ? 'warn' : type === 'success' ? 'success' : type === 'warn' ? 'warn' : 'info';
        return open({
            title: opts.title || (type === 'error' ? 'Errore' : type === 'success' ? 'Fatto' : 'Avviso'),
            message, iconKey, iconClass,
            escapeValue: undefined,
            actions: [{ text: opts.confirmText || 'OK', cls: 'pim-btn--primary', value: undefined }],
        });
    }

    window.showConfirm = showConfirm;
    window.showPrompt  = showPrompt;
    window.showAlert   = showAlert;
})();
