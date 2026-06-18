# Updates — Sostituzione popup nativi con modal grafici

> Guida per replicare la modifica su un progetto **quasi identico**.
> Commit di riferimento: `688698f` — *"Popup nativi → modal grafici (showConfirm/showPrompt/showAlert)"*.
> Obiettivo: eliminare ovunque i popup nativi del browser (`alert` / `confirm` / `prompt`,
> quelli con l'intestazione **"…dice"** e lo sfondo nero di sistema) sostituendoli con
> dialog grafici coerenti con lo stile dell'app.

---

## 1. Cosa è stato fatto, in sintesi

1. Creato **un nuovo file `js/modals.js`** che espone 3 funzioni globali Promise-based:
   - `showConfirm()` → `Promise<boolean>` (sostituisce `confirm`)
   - `showPrompt()`  → `Promise<string|null>` (sostituisce `prompt`; `null` = annullato)
   - `showAlert()`   → `Promise<void>` (sostituisce `alert`)
2. Incluso `modals.js` in **tutte le pagine** che usano popup nativi o caricano script che li usano.
3. Sostituite **tutte** le chiamate native in pagine e file JS (utente + admin).
4. Aggiornato il **service worker** (cache) e i **`?v=`** dei file toccati.
5. Verificato in browser (Playwright): conferma/annulla/prompt/alert + ordine di esecuzione.

**Totale popup sostituiti: ~152** (74 lato utente + 78 lato admin/home).

---

## 2. Nuovo file: `js/modals.js`

Copialo **identico** nel progetto gemello (è autosufficiente: nessuna dipendenza, CSS
iniettato una sola volta, testo inserito via `textContent` quindi XSS-safe).
Estetica allineata al popup "Approvazione trainer" (`slot-offer-popup`): card bianca
arrotondata, icona a cerchio, overlay scuro sfocato. Accento brand `#00AEEF`; rosso
`#dc3545` per le azioni distruttive.

> ⚠️ Se il progetto gemello usa un **colore brand diverso**, cambia `#00AEEF`/`#0098d1`
> nelle classi `.tbm-btn--primary`, `.tbm-icon--info`, `.tbm-input:focus`.

### API

```js
// CONFIRM  → Promise<boolean>
await showConfirm('Eliminare questo set?')            // forma breve
await showConfirm({                                    // forma completa
  title: 'Annulla prenotazione',
  message: 'Confermare l’annullamento?',
  confirmText: 'Conferma',
  cancelText: 'Indietro',
  danger: true,        // bottone rosso (auto se il messaggio contiene "elimin"/"rimuov")
})

// PROMPT  → Promise<string|null>   (null = annullato; "" se svuotato, come il nativo)
await showPrompt('Nuovo nome scheda:', valoreDefault, {
  confirmText: 'Rinomina',
  placeholder: 'Nome scheda',
  numeric: true,       // inputmode=numeric → tastierino numerico su mobile
  type: 'password',    // campo password
  subtitle: 'testo secondario sotto il titolo',
})

// ALERT  → Promise<void>
await showAlert('Operazione completata!', { type: 'success' }) // type: info|success|warn|error
```

### Sorgente completo (`js/modals.js`)

```javascript
// ─── MODAL DIALOGS (confirm / prompt / alert) ──────────────────────────────────
// Sostituiscono i popup nativi del browser (window.confirm / prompt / alert) con
// dialog grafici coerenti. API basate su Promise. Nessuna dipendenza esterna.

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
        if (document.getElementById('tbm-styles')) return;
        const css = `
.tbm-overlay {
    position: fixed; inset: 0; z-index: 2147483000;
    background: rgba(0,0,0,0.55); backdrop-filter: blur(2px); -webkit-backdrop-filter: blur(2px);
    display: flex; align-items: center; justify-content: center; padding: 16px;
    animation: tbmFade .2s ease;
}
@keyframes tbmFade { from { opacity: 0 } to { opacity: 1 } }
.tbm-box {
    position: relative; width: 100%; max-width: 400px;
    max-height: 88vh; overflow-y: auto;
    background: #fff; border-radius: 18px;
    box-shadow: 0 20px 60px rgba(0,0,0,0.3);
    padding: 26px 22px 20px;
    animation: tbmPop .25s cubic-bezier(.18,.89,.32,1.28);
}
@keyframes tbmPop { from { transform: translateY(12px) scale(.96); opacity: 0 } to { transform: none; opacity: 1 } }
.tbm-icon {
    width: 54px; height: 54px; margin: 0 auto 14px;
    display: flex; align-items: center; justify-content: center; border-radius: 50%;
}
.tbm-icon svg { width: 28px; height: 28px; }
.tbm-icon--info    { background: rgba(0,174,239,0.12); color: #00AEEF; }
.tbm-icon--warn    { background: rgba(234,123,10,0.12); color: #ea7b0a; }
.tbm-icon--danger  { background: rgba(220,53,69,0.10);  color: #dc3545; }
.tbm-icon--success { background: rgba(34,160,90,0.12);  color: #22a05a; }
.tbm-title { font-size: 1.12rem; font-weight: 800; color: #1a1a1a; text-align: center; line-height: 1.3; }
.tbm-msg   { font-size: .92rem; color: #5a6672; text-align: center; margin-top: 8px; line-height: 1.45; white-space: pre-line; }
.tbm-input {
    width: 100%; margin-top: 18px; padding: 12px 14px; box-sizing: border-box;
    border: 1.5px solid #d8dee3; border-radius: 12px;
    font-size: 1rem; font-family: inherit; color: #1a1a1a; outline: none;
    transition: border-color .15s;
}
.tbm-input:focus { border-color: #00AEEF; }
.tbm-actions { display: flex; gap: 10px; margin-top: 22px; }
.tbm-btn {
    flex: 1; padding: 12px 14px; border: none; border-radius: 12px;
    font-size: .95rem; font-weight: 700; cursor: pointer; font-family: inherit;
    transition: transform .1s, background-color .2s, opacity .2s;
}
.tbm-btn:active { transform: scale(.97); }
.tbm-btn--primary { background: #00AEEF; color: #fff; }
.tbm-btn--primary:hover { background: #0098d1; }
.tbm-btn--danger  { background: #dc3545; color: #fff; }
.tbm-btn--danger:hover { background: #c42d3c; }
.tbm-btn--ghost   { background: #f1f3f5; color: #444; }
.tbm-btn--ghost:hover { background: #e2e6ea; }
body.tbm-open { overflow: hidden; }`;
        const style = document.createElement('style');
        style.id = 'tbm-styles';
        style.textContent = css;
        document.head.appendChild(style);
    }

    function open({ title, message, iconKey, iconClass, input, actions, escapeValue }) {
        return new Promise(resolve => {
            injectStyles();
            const overlay = document.createElement('div');
            overlay.className = 'tbm-overlay';
            const box = document.createElement('div');
            box.className = 'tbm-box';
            box.setAttribute('role', 'dialog');
            box.setAttribute('aria-modal', 'true');
            overlay.appendChild(box);
            if (iconKey) {
                const ic = document.createElement('div');
                ic.className = 'tbm-icon ' + (iconClass || 'tbm-icon--info');
                ic.setAttribute('aria-hidden', 'true');
                ic.innerHTML = ICONS[iconKey] || '';
                box.appendChild(ic);
            }
            if (title) {
                const t = document.createElement('div');
                t.className = 'tbm-title';
                t.textContent = title;
                box.appendChild(t);
            }
            if (message) {
                const m = document.createElement('div');
                m.className = 'tbm-msg';
                m.textContent = message;
                box.appendChild(m);
            }
            let inputEl = null;
            if (input) {
                inputEl = document.createElement('input');
                inputEl.className = 'tbm-input';
                inputEl.type = input.type || 'text';
                if (input.inputmode) inputEl.inputMode = input.inputmode;
                if (input.placeholder) inputEl.placeholder = input.placeholder;
                inputEl.value = input.value != null ? input.value : '';
                box.appendChild(inputEl);
            }
            const act = document.createElement('div');
            act.className = 'tbm-actions';
            box.appendChild(act);
            let settled = false;
            function close(result) {
                if (settled) return;
                settled = true;
                document.removeEventListener('keydown', onKey, true);
                overlay.remove();
                document.body.classList.remove('tbm-open');
                resolve(result);
            }
            actions.forEach(a => {
                const b = document.createElement('button');
                b.type = 'button';
                b.className = 'tbm-btn ' + a.cls;
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
            document.body.classList.add('tbm-open');
            setTimeout(() => {
                if (inputEl) { inputEl.focus(); if (input.selectAll !== false) inputEl.select(); }
                else { const p = act.querySelector('.tbm-btn--primary, .tbm-btn--danger'); if (p) p.focus(); }
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
            iconClass: isDanger ? 'tbm-icon--danger' : 'tbm-icon--info',
            escapeValue: false,
            actions: [
                { text: cancelText,  cls: 'tbm-btn--ghost', value: false },
                { text: confirmText, cls: isDanger ? 'tbm-btn--danger' : 'tbm-btn--primary', value: true },
            ],
        });
    }

    function showPrompt(message, defaultValue, opts) {
        if (message && typeof message === 'object') { opts = message; message = opts.message; defaultValue = opts.value; }
        opts = opts || {};
        return open({
            title: opts.title || message || '',
            message: opts.subtitle || '',
            iconKey: 'edit', iconClass: 'tbm-icon--info',
            escapeValue: null,
            input: {
                type: opts.type || 'text',
                inputmode: opts.numeric ? 'numeric' : opts.inputmode,
                value: defaultValue != null ? defaultValue : '',
                placeholder: opts.placeholder,
                selectAll: opts.selectAll,
            },
            actions: [
                { text: opts.cancelText || 'Annulla', cls: 'tbm-btn--ghost', value: null },
                { text: opts.confirmText || 'OK', cls: 'tbm-btn--primary', returnInput: true },
            ],
        });
    }

    function showAlert(message, opts) {
        if (message && typeof message === 'object') { opts = message; message = opts.message; }
        opts = opts || {};
        const type = opts.type || 'info';
        const iconClass = type === 'error' ? 'tbm-icon--danger'
            : type === 'success' ? 'tbm-icon--success'
            : type === 'warn' ? 'tbm-icon--warn' : 'tbm-icon--info';
        const iconKey = type === 'error' ? 'warn' : type === 'success' ? 'success' : type === 'warn' ? 'warn' : 'info';
        return open({
            title: opts.title || (type === 'error' ? 'Errore' : type === 'success' ? 'Fatto' : 'Avviso'),
            message, iconKey, iconClass,
            escapeValue: undefined,
            actions: [{ text: opts.confirmText || 'OK', cls: 'tbm-btn--primary', value: undefined }],
        });
    }

    window.showConfirm = showConfirm;
    window.showPrompt  = showPrompt;
    window.showAlert   = showAlert;
})();
```

---

## 3. Wiring negli HTML

Aggiungi `<script src="js/modals.js?v=1"></script>` **prima** degli script che lo usano.
Regola pratica: subito **dopo `ui.js`** (se presente) oppure **prima** di
`slot-offer-popup.js` / `calendar.js` / i moduli `admin-*.js`.

| Pagina | Dove inserirlo |
|---|---|
| prenotazioni / allenamento | dopo `ui.js` |
| chi-sono, dove-sono, index, nutrizione, regolamento, privacy, termini | subito **prima** di `slot-offer-popup.js` |
| login | dopo `ui.js` |
| admin | dopo `ui.js`, **prima** di tutti gli `admin-*.js` |
| tablet | dopo `supabase-client.js` (non c'è `ui.js`) |
| viewer | **prima** del `<script>` inline (non carica file JS esterni) |

> Le pagine che non avevano popup nativi **né** caricavano `slot-offer-popup.js`
> (es. eventuali pagine statiche) non necessitano di `modals.js`.

---

## 4. Regole di sostituzione (find → replace)

| Nativo | Sostituzione |
|---|---|
| `if (!confirm('X?')) return;` | `if (!await showConfirm('X?')) return;` |
| `confirm(msgVar)` | `await showConfirm({ title:'…', message: msgVar, confirmText:'…' })` |
| `alert('Errore: '+e)` (errore) | `showAlert('Errore: '+e, { type:'error' })` |
| `alert('Seleziona…')` (validazione) | `showAlert('Seleziona…', { type:'warn' })` |
| `alert('✅ Fatto')` (successo) | `showAlert('Fatto', { type:'success' })` |
| `prompt('Label:', def)` | `await showPrompt('Label:', def, { confirmText:'…' })` |
| `prompt('Serie:', '3')` (numerico) | `await showPrompt('Serie:', '3', { numeric:true })` |
| `prompt('Password:')` | `await showPrompt('Password', '', { type:'password' })` |

### Convenzioni adottate
- **Emoji rimosse** dai messaggi (`⚠️`, `✅`) perché l'icona del modal le sostituisce.
- **Eliminazioni** → `danger:true` (bottone rosso). È **automatico** se il messaggio
  contiene `elimin`/`rimuov`; altrimenti passarlo a mano.
- Sui confirm di **annullamento** ho usato `cancelText:'Indietro'` per non confondere
  con la parola "Annulla".
- **Password** → `type:'password'`; **valori numerici** (serie/ripetizioni/secondi) → `numeric:true`.

### ⚠️ Punti critici (NON sbagliare)

1. **`await` richiede funzione `async`.** Ogni `confirm`/`prompt` sostituito con `await`
   deve stare in una funzione `async`. Se la funzione era **sincrona**, va resa `async`
   e i suoi **chiamanti aggiornati** (vedi §5). Gli handler `onclick`/`onchange` possono
   chiamare funzioni async senza problemi (la Promise viene ignorata).

2. **`alert` di sola validazione** seguiti da `return;` **NON** richiedono `async`:
   `showAlert(...)` è "fire-and-forget" (mostra il modal e prosegue). Es:
   `if (!nome) { showAlert('Nome obbligatorio', {type:'warn'}); return; }`

3. **`alert` di successo seguito da `location.reload()`** → usare **`await showAlert(...)`**
   prima del reload, altrimenti la pagina ricarica prima che l'utente veda il messaggio
   (il nativo bloccava, il modal no). Es:
   `await showAlert('Dati salvati', {type:'success'}); location.reload();`

4. **Niente race condition.** `await showConfirm()` chiude **solo** il dialog di conferma;
   il codice dopo l'`await` (es. la chiamata a Supabase) gira **dopo** e completa
   regolarmente; la richiesta/popup reale si chiude solo a risposta ricevuta. Verificato.

5. **`prompt` annullato** → `showPrompt` ritorna `null` (come il nativo). I controlli
   `if (x === null) return;` e `if (!x) return;` continuano a funzionare.

---

## 5. Funzioni rese `async` (+ chiamanti aggiornati)

Nel progetto originale queste funzioni erano sincrone e sono diventate `async` perché ora
usano `await showConfirm/showPrompt`. Verifica gli equivalenti nel gemello:

| File | Funzione | Chiamanti aggiornati |
|---|---|---|
| allenamento.html | `addDayToScheda`, `_supersetPickExercise`, `_circuitPickExercise` | `pickExerciseFromPicker`, `pickCustomExercise` → `await` |
| tablet.html | `_tabSsPickExercise` | `tabPickExercise` → `await` |
| admin-backup.js | `importBackup`, `resetDemoData` | onchange/onclick (ok) |
| admin-payments.js | `deleteManualDebtEntry`, `deleteCreditEntryFromCard` | onclick (ok) |
| admin-schede.js | `_schedeActualAddPlan` | onclick (ok) |
| admin-schedule.js | `clearWeekSchedule` | onclick (ok) |
| admin-calendar.js | `deleteBooking` | onclick (ok) |

> Tutte le altre funzioni interessate erano **già** `async`.

---

## 6. File modificati (elenco completo)

### Lato utente / shared
| File | N° popup | Note |
|---|---|---|
| `js/modals.js` | — | **NUOVO** |
| `prenotazioni.html` | 16 | 6 confirm + 10 alert→toast (qui usato `showToast` già esistente) |
| `allenamento.html` | 26 | confirm + prompt numerici |
| `tablet.html` | 12 | editor schede (no `ui.js`, alert→`_toast` interno) |
| `viewer.html` | 10 | tutti alert di validazione |
| `login.html` | 1 | alert errore login |
| `js/slot-offer-popup.js` | 1 | confirm "Rifiuta posto" |
| `js/allenamento-report.js` | 8 | alert flusso report (caricato da allenamento.html) |
| `js/calendar.js` | 1 | confirm lista d'attesa (home/index.html) |

### Lato admin (caricati da `admin.html`)
| File | N° popup |
|---|---|
| `js/admin-clients.js` | 17 |
| `js/admin-payments.js` | 14 |
| `js/admin-backup.js` | 13 |
| `js/admin-schede.js` | 9 |
| `js/admin-analytics.js` | 6 |
| `js/admin-schedule.js` | 5 |
| `js/admin-importa.js` | 5 |
| `js/admin-registro.js` | 3 |
| `js/admin-settings.js` | 2 |
| `js/admin-messaggi.js` | 1 |
| `js/admin-calendar.js` | 1 |
| `js/admin-richieste.js` | 1 |

> Sono presenti **prompt password** in: `admin-backup.js` (import backup),
> `admin-clients.js` (elimina dati cliente), `admin-settings.js` (blocco admin).

---

## 7. Cache / deploy (service worker)

Regola del progetto: ad ogni deploy bumpare `CACHE_NAME`, i `?v=` degli script
modificati e `APP_SHELL` per i nuovi file. In questo update:

1. `sw.js` → `CACHE_NAME` bumpato (es. `palestra-v781` → `palestra-v782`).
2. `sw.js` → aggiunto **`/js/modals.js`** a `APP_SHELL`.
3. `?v=` bumpati in HTML per **ogni** file JS modificato:
   - `slot-offer-popup.js` su tutte le pagine che lo caricano
   - `calendar.js` (index.html), `allenamento-report.js` (allenamento.html)
   - tutti i 12 `admin-*.js` in `admin.html`
4. `modals.js` referenziato come `?v=1` (nuovo file).

> Il SW serve JS/CSS **cache-first con match esatto del `?v=`**: senza bump del `?v=`
> l'utente continuerebbe a ricevere il file vecchio dalla cache.

---

## 8. Verifica (fatta con Playwright)

- `showConfirm` → click "Conferma": ordine `confirm=true → chiamata async → risposta → chiusura`; operazione completata (nessuna race). Click "Annulla" → `false`, nessuna azione.
- `showPrompt` → input prefillato, `inputmode=numeric`, ritorna la stringa; Escape → `null`.
- `showAlert` → si chiude su OK; overlay sempre rimosso dal DOM.

Per i file JS standalone è utile un controllo sintassi rapido (intercetta `await` fuori
da funzioni `async`):
```bash
for f in js/admin-*.js js/modals.js js/calendar.js; do node --check "$f" && echo "$f OK"; done
```

### Sweep finale (deve dare 0 risultati, esclusi commenti)
```bash
# ripgrep: chiamate native residue (esclude show* e chiamate-metodo)
rg "(^|[^.A-Za-z_])(alert|confirm|prompt)\s*\(" --glob '*.html' --glob 'js/*.js'
```
