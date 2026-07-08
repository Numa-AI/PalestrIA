# PalestrIA — Specifica completa AREA CLIENTE (per riscrittura Flutter)

> Fonte: web app vanilla JS (repo PalestrIA, branch `saas-main`). Questa specifica è
> **autosufficiente**: descrive layout, stili (valori CSS esatti), testi UI esatti, stati,
> flussi e logica dati (RPC Supabase, cache) delle pagine cliente:
> `index.html`, `login.html`, `prenotazioni.html`, `allenamento.html`, `signup-trainer.html`
> più i moduli JS collegati (`booking.js`, `calendar.js`, `ui.js`, `modals.js`,
> `allenamento-report.js`, `branding-boot.js`, `org-settings.js`, `auth.js`, `data.js`,
> `chart-mini.js`, `push.js`, `new-client-popup.js`).
>
> Lingua UI: **italiano**. Tutti i testi riportati tra virgolette sono da replicare 1:1.

---

## 0. Indice

1. [Architettura e concetti trasversali](#1-architettura-e-concetti-trasversali)
2. [Design system globale](#2-design-system-globale)
3. [Shell comune (navbar, sidebar, footer, FAB WhatsApp)](#3-shell-comune)
4. [Pagina: Home / Calendario pubblico (index.html)](#4-pagina-home--calendario-pubblico-indexhtml)
5. [Flusso prenotazione completo (modal + book_slot)](#5-flusso-prenotazione-completo)
6. [Pagina: Login / Registrazione (login.html)](#6-pagina-login--registrazione-loginhtml)
7. [Pagina: Le mie prenotazioni (prenotazioni.html)](#7-pagina-le-mie-prenotazioni-prenotazionihtml)
8. [Pagina: Allenamento (allenamento.html)](#8-pagina-allenamento-allenamentohtml)
9. [Report AI mensile (allenamento-report.js)](#9-report-ai-mensile)
10. [Pagina: Crea il tuo studio (signup-trainer.html)](#10-pagina-crea-il-tuo-studio-signup-trainerhtml)
11. [Branding per-org e OrgSettings](#11-branding-per-org-e-orgsettings)
12. [Autenticazione, ruoli e navigazione dinamica (auth.js)](#12-autenticazione-ruoli-e-navigazione-dinamica)
13. [Data layer: RPC, tabelle, cache locali (data.js)](#13-data-layer-rpc-tabelle-cache-locali)
14. [Notifiche push (push.js)](#14-notifiche-push)
15. [Popup "Nuovo cliente iscritto" (new-client-popup.js)](#15-popup-nuovo-cliente-iscritto)
16. [Componenti condivisi: toast, loading, dialoghi (ui.js, modals.js)](#16-componenti-condivisi)
17. [Chiavi localStorage / sessionStorage](#17-chiavi-localstorage--sessionstorage)
18. [Riepilogo RPC ed Edge Functions](#18-riepilogo-rpc-ed-edge-functions)

---

## 1. Architettura e concetti trasversali

### 1.1 Multi-tenant (org) e risoluzione dello slug

- Ogni studio/trainer è un **tenant** (`organizations`). I dati sono isolati per `org_id` + RLS.
- **Client anonimo** (nessun login): la org si risolve dallo **slug** con `_resolveOrgSlug()`
  (definita in `data.js`, replicata in `org-settings.js`), nell'ordine:
  1. `window._orgSlug` (se già settato);
  2. **sottodominio**: `location.hostname.split('.')` — se ci sono >2 segmenti e il primo
     non è `www`/`app`, il primo segmento è lo slug (es. `studio-rossi.palestria.app`);
  3. query string `?org=<slug>`.
  Se non risolvibile → `null` (le RPC pubbliche falliranno / fallback).
- **Client autenticato**: `org_id` arriva dal claim JWT `app_metadata.org_id`
  (iniettato dal Custom Access Token Hook); fallback: query su `org_members`
  (`select org_id, role where user_id = auth.uid() and status='active'`).
  Viene salvato in `window._orgId`; il ruolo in `window._orgRole`
  (`owner`/`admin`/`staff` per lo staff, `null` per i clienti).
- Se `org_role ∈ {owner, admin}` → `sessionStorage.adminAuth = 'true'` (gating client-side
  dell'area admin; il server resta l'autorità).
- In Flutter: mantenere un "OrgContext" globale con `orgId`, `orgRole`, `orgSlug`.

### 1.2 Pattern dati "dual-layer"

Tutte le letture UI avvengono da **cache in memoria** (classi statiche `*Storage` in
`data.js`), sincronizzata da Supabase. Le **scritture critiche** (prenotare, annullare)
passano SEMPRE da **RPC `SECURITY DEFINER` server-authoritative** — mai insert diretti.
La capienza è decisa dal server (advisory lock in `book_slot`), il client mostra solo
i residui.

### 1.3 Stack pagine

Ogni pagina HTML carica: Supabase JS v2 (CDN), `supabase-client.js` (init client;
2 istanze: `supabaseClient` dati + `supabaseAuth` auth), `org-settings.js`, `ui.js`,
`modals.js`, `data.js`, `auth.js`, più moduli PWA (`sw-update.js`, `pull-to-refresh.js`,
`pwa-install.js`, `silent-refresh.js`, `app-watchdog.js`, `maintenance.js`, `push.js`).
In `<head>`, PRIMA del body: `ls-namespace.js` (namespacing localStorage per-org) e
`branding-boot.js` (applica il branding cache prima del primo paint → niente flash).

### 1.4 Realtime

Canali Supabase Realtime (postgres_changes) con **debounce 600 ms**:
- `bookings-rt-calendar` su tabella `bookings` (index) → invalidate availability cache +
  `syncFromSupabase()` + re-render calendario;
- `appsettings-rt-calendar` su `app_settings` e `settings` (index) → sync settings + re-render;
- `preno-rt` su `bookings` (prenotazioni.html) → `syncFromSupabase({ownOnly:true})` +
  re-render lista + billing;
- `org_settings_<orgId>` su `org_settings` filtrato `org_id=eq.<id>` (org-settings.js) →
  aggiorna cache; se la chiave inizia con `branding.` riapplica il branding.

Cross-tab (stesso browser): listener su evento `storage` per chiavi `gym_bookings` /
`scheduleOverrides` → re-render.

---

## 2. Design system globale

### 2.1 Palette (CSS custom properties in `:root`, `css/style.css`)

| Variabile | Valore | Uso |
|---|---|---|
| `--primary-purple` | `#8B5CF6` | Colore brand primario (SOVRASCRIVIBILE per-org a runtime) |
| `--primary-purple-dark` | `#7C3AED` | Variante scura (derivata: brand −10% luminosità) |
| `--dark-bg` | `#1a1a1a` | Navbar, footer, hero scuro |
| `--dark-gray` | `#2d2d2d` | Celle orario calendario |
| `--light-gray` | `#f8f9fa` | Background pagina |
| `--text-white` | `#ffffff` | Testo su scuro |
| `--text-dark` | `#333333` | Testo body |
| `--personal-training` | `#22c55e` | Tipo slot "Autonomia" (verde) |
| `--small-group` | `#fbbf24` | Tipo slot "Lezione di Gruppo" (giallo) |
| `--group-class` | `#ef4444` | Tipo slot "Slot prenotato" (rosso) |
| `--cleaning` | `#8b5cf6` | Tipo slot "Pulizie" (viola) |
| `--success` | `#06d6a0` | Toast/conferme |
| `--warning` | `#f77f00` | Avvisi |

Colori tipi-slot in JS (`getSlotColor()` fallback legacy, usati per pallini/gradients quando
la config org non definisce `slot_types.color`):
`personal-training #16a34a`, `small-group #f59e0b`, `group-class #ef4444`,
`cleaning #64748b`, default `#8B5CF6`.
**Org-aware**: se `slot_types.color` è definito per il tenant, quel valore VINCE.

### 2.2 Tipografia e layout

- Font: `'Segoe UI', Tahoma, Geneva, Verdana, sans-serif` (nessun webfont).
- `line-height: 1.6` sul body.
- Desktop (`min-width:769px`): `html { font-size: 12px }` (**scale-down globale**, tutti
  i rem si riducono), `.container { max-width: 900px }`. Mobile: rem base 16px,
  `.container { max-width:1200px; padding: 0 20px }` (12px su mobile).
- Breakpoint principale: **768px** (mobile ≤768, desktop ≥769). Extra-small: 380px, 480px, 600px.

### 2.3 Nomi e costanti dei tipi slot (legacy fallback, `data.js`)

```
SLOT_TYPES = { PERSONAL:'personal-training', SMALL_GROUP:'small-group',
               GROUP_CLASS:'group-class', CLEANING:'cleaning' }
SLOT_NAMES = { 'personal-training':'Autonomia', 'small-group':'Lezione di Gruppo',
               'group-class':'Slot prenotato', 'cleaning':'Pulizie' }
SLOT_MAX_CAPACITY = { 'personal-training':5, 'small-group':5, 'group-class':0, 'cleaning':0 }
TIME_SLOTS (12 fasce da 80 min): '05:20 - 06:40' … '20:00 - 21:20'
```
**IMPORTANTE**: sono solo fallback single-tenant. La fonte reale per-org è il DB
(`slot_types`, `time_slots_config`, `weekly_schedule_templates` + `activated_weeks`),
caricata da `loadOrgScheduleConfig()`. `getSlotName(key)` / `getSlotColor(key)` /
`getTimeSlots()` preferiscono SEMPRE la config org.

Formato orario slot: stringa `"HH:MM - HH:MM"` (es. `"08:00 - 09:20"`), parsata da
`_parseSlotTime()`. Formato data: `"YYYY-MM-DD"` in **fuso locale** (`_localDateStr()`).

### 2.4 Colore "posti residui" (`spotsColorClass(n)`)

| Residui | Classe | Colore testo |
|---|---|---|
| 1 | `spots-red` | `#dc2626` |
| 2 | `spots-orange` | `#ea7b0a` |
| ≥3 | `spots-dark` | `#111` |
| (verde, usato altrove) | `spots-green` | `#16a34a` |

---

## 3. Shell comune

Presente identica in index/login/prenotazioni/allenamento (NON in signup-trainer).

### 3.1 Navbar (`.navbar`)

- Sticky top, `background:#1a1a1a`, `padding:1rem 0`, `z-index:1000`,
  `box-shadow:0 2px 10px rgba(0,0,0,0.3)`.
- Sinistra: logo `<img class="nav-logo" data-org-logo>` (default
  `images/logo-palestria-light.png`), h 48px (52px mobile, 44px ≤380px e desktop),
  `border-radius:6px`, link a `index.html`.
- Centro/destra (solo desktop, `.nav-desktop-links`, nascosti ≤768px): link testuali
  "Calendario", "Regolamento", "Nutrizione", "Chi sono", "Dove sono" — colore
  `rgba(255,255,255,0.82)`, `font-size:0.95rem`, peso 500, padding `0.45rem 0.9rem`,
  radius 6; hover/active: colore `var(--primary-purple)` + bg `rgba(139,92,246,0.1)`.
- Auth (destra):
  - Non loggato → `#navLoginLink`: bottone-pill **"Accedi"** (`.nav-login-btn`):
    bg `var(--primary-purple)`, testo bianco, `padding:0.25rem 0.65rem`,
    `border-radius:20px`, `font-size:0.8rem`, bold 600.
  - Loggato → `#navUserMenu`: `#navUserName` (primo nome, bianco, 0.9rem, 600,
    sottolineato, click → naviga a `prenotazioni.html`) + bottone **"Esci"**
    (`.nav-logout-btn`: ghost, bordo `1.5px solid rgba(255,255,255,0.5)`, radius 20px,
    0.8rem; su mobile ≤768px NASCOSTO — il logout vive nella sidebar).
  - Anti-flash: fino a `body.auth-loaded` (settato da `updateNavAuth()`) entrambi i blocchi
    hanno `visibility:hidden`.
- Hamburger (`.nav-hamburger`, solo mobile): icona 3 linee SVG 26px bianca; apre la sidebar.

### 3.2 Sidebar mobile (`.nav-sidebar` + `.nav-sidebar-overlay`)

- Pannello fisso a destra, `width:270px`, `height:100dvh`, bg `#1a1a1a`,
  slide-in da destra (`right:-300px → 0`, transizione `0.3s cubic-bezier(0.4,0,0.2,1)`),
  `box-shadow:-8px 0 40px rgba(0,0,0,0.5)`, overlay `rgba(0,0,0,0.55)`.
- Header: logo (h 42px) + bottone chiudi X circolare 34px bg `rgba(255,255,255,0.08)`.
- Voci (li a): `padding:0.95rem 1.5rem`, colore `rgba(255,255,255,0.82)`, 1rem/500,
  `border-left:3px solid transparent`; hover → viola + bg viola 10% + bordo sinistro viola.
  Separatori: `border-top:1px solid rgba(255,255,255,0.05)` tra le voci.
- Voci statiche: "Calendario", **"Allenamento"** (`#navAllenamento`, nascosta di default —
  vedi §12.4), "Nutrizione", "Regolamento", "Chi sono", "Dove sono".
- Voci dinamiche (iniettate da `updateNavAuth()`): "Le mie prenotazioni" (prima voce, se
  cliente loggato), "Amministrazione" (ultima, se admin), bottone **"Esci"**
  (`.nav-sidebar-logout`: testo `#ff7070`, hover `#ff4444` + bg rosso 10%).
- Footer sidebar: "powered by **Andrea Pompili**" (link `https://andreapompili.com/`),
  `font-size:0.65rem`, colore `rgba(255,255,255,0.35)`, link sottolineato `rgba(255,255,255,0.5)`.
- Toggle: `toggleNavMenu()` — classi `.open` su sidebar/overlay + `body.nav-open`
  (`overflow:hidden`).
- Su desktop (≥769px) sidebar e hamburger `display:none`.

### 3.3 Footer (`.footer`)

Bg `#1a1a1a`, testo bianco centrato, `padding:2rem 0` (0.75rem mobile):
riga 1 "© 2026 PalestrIA"; riga 2 link "Privacy" · "Termini"
(bianchi, opacity 0.7, `font-size:0.85rem`). Su allenamento.html mobile il footer è
**nascosto** (il dock fisso fa da fondo pagina).

### 3.4 FAB WhatsApp (`.whatsapp-fab`)

Presente su index e prenotazioni: cerchio fisso bottom/right `1.5rem`, 58×58px,
bg `#25D366`, icona WhatsApp bianca 30px, shadow `0 4px 16px rgba(37,211,102,0.45)`;
hover: bg `#1ebe5a`, `scale(1.1)`. Link `https://wa.me/<numero>` (statico nell'HTML,
`aria-label="Contattami su WhatsApp"`).

---

## 4. Pagina: Home / Calendario pubblico (index.html)

Home del tenant. Accessibile ANCHE senza login (prenotazione anonima possibile).
`<title>` di default "PalestrIA" (sovrascritto dal branding). Theme color `#8B5CF6`.

### 4.1 Hero (`.hero`)

- Bg: `linear-gradient(135deg, #1a1a1a 0%, #111 50%, #1a2a2a 100%)`, testo bianco,
  centrato, `padding:4rem 0 3.5rem` (mobile `1.2rem 0 1rem`). Decorazione: cerchio
  radiale viola 12% in alto a destra (300px, `::before`).
- `h1.hero-name` `[data-org-name]`: placeholder statico **"IL TUO NOME"**, sostituito dal
  branding con il nome dello studio. `font-size:3rem` (1.7rem mobile), peso 800,
  `letter-spacing:2px`.
  - Override legacy via query `?pt=<nome>`: forza il testo (uppercase) e `document.title
    = "<nome> – PalestrIA"`, e marca `data-brand-locked="1"` (il branding org NON lo tocca).
- `p.hero-role`: **"Personal Trainer"** — viola brand, `letter-spacing:5px`, uppercase,
  0.78–1rem, peso 600.
- `.hero-info`: due chip pill (bg `rgba(255,255,255,0.08)`, bordo `1px solid
  rgba(255,255,255,0.12)`, radius 50px, `font-size:0.8rem`, icona SVG 16px viola):
  1. icona orologio + `[data-org-duration]` default **"80 minuti"**;
  2. link Google Maps (icona pin) + `[data-org-address]` default **"Via Demo 1 — Milano"**,
     `href` default `https://maps.app.goo.gl/…`, `[data-org-maps]` (sostituiti dal branding).

### 4.2 Sezione calendario

#### Controlli desktop (`.calendar-controls`, nascosti ≤768px)
- Bottone sinistro **"← Settimana Precedente"**, titolo centrale `#currentWeek` (testo
  `"D/M - D/M/YYYY"` della settimana), bottone destro **"Settimana Successiva →"**.
- Bottoni `.btn-control`: bg viola, testo bianco, `padding:0.75rem 1.5rem`, radius 5px;
  hover: viola scuro + translateY(-2px) + shadow.
- Prev disabilitato (opacity 0.3, cursor not-allowed) quando `currentWeekOffset === 0`
  (non si può andare nel passato). Next disabilitato se la settimana successiva non ha
  slot configurati (`weekHasSlotsDesktop(offset+1)`).

#### Griglia desktop (`.calendar-grid`)
- CSS grid `80px repeat(7, 1fr)` (desktop scale: `58px repeat(7,1fr)`), gap 2px, bg bianco,
  bordo `1px solid #ddd`, radius 8px.
- Riga header: cella vuota + 7 celle `.calendar-header` (bg `#1a1a1a`, bianco, bold) con
  nome giorno ("Lunedì"…) e sotto data `D/M` (0.85rem, opacity 0.8).
- Righe: etichetta orario `.calendar-time` (bg `#2d2d2d`, bianco, 0.9rem) + 7 celle slot.
- Settimana desktop: **Lunedì→Domenica** della settimana corrente + offset
  (`getWeekDatesDesktop(offset)`; lunedì calcolato da `getDay()`).

#### Cella slot (`createSlot`)
- `.calendar-slot`: bg bianco, `min-height:80px` (58px desktop scale), padding 0.75rem,
  flex column centrata; hover: `scale(1.02)` + shadow.
- Slot NON configurato per (giorno, ora): contenuto `"-"` grigio `#ccc`, non cliccabile.
- Slot configurato: classe `has-booking <tipo>` → gradiente 135deg per tipo:
  - `personal-training`: `#22c55e → #16a34a`
  - `small-group`: `#fbbf24 → #d97706`
  - `group-class`: `#ef4444 → #dc2626`
  - `cleaning`: `#8b5cf6 → #7c3aed`
- Contenuto: `.slot-type` = `getSlotName(tipo)` (0.85rem); sotto, SOLO se loggato e tipo
  prenotabile: `.slot-spots` con **"Completo"** oppure **"N disponibile/disponibili"**
  (0.75rem, bold, colore per `spotsColorClass`).
- Se l'utente è iscritto allo slot: badge `.slot-enrolled-badge` **"Qui ti alleni 💪🏼"**
  (0.68rem, bold, pill bg `rgba(255,255,255,0.35)` con blur, testo `#111`) al posto dei posti.
- Slot pieno (loggato): classe `.slot-full` → `opacity:0.45; filter:grayscale(0.6)`;
  resta CLICCABILE per vedere gli iscritti. Se enrolled+full: `opacity:0.85`, nessun filtro.
- Cutoff 30 minuti: se sono passati >30 min dall'inizio lezione lo slot non è prenotabile;
  se loggato viene mostrato attenuato (`opacity:0.35; grayscale(0.8)`).
- **Slot "misto"** (override con `extras` di tipo diverso): cella divisa in verticale
  (`.split-slot` → 2+ metà `.split-slot-half`, ciascuna con gradiente del proprio tipo,
  nome tipo 0.72rem e posti 0.65rem, click indipendente).
- Click (se consentito) → `selectSlot(dateInfo, timeSlot, slotType, remainingSpots)` che
  salva `selectedSlot = { date, dateDisplay:"<GiornoNome> <D/M>", time, slotType,
  remainingSpots }` e apre il modal di prenotazione.
- Regole clickabilità: loggato → cliccabile se (prenotabile) OR (pieno) OR (iscritto);
  anonimo → cliccabile solo se tipo prenotabile e orario ok (il modal mostrerà il login
  prompt). Tipi non prenotabili: `bookable===false` in config org (fallback legacy:
  `group-class` e `cleaning`).

#### Calendario mobile (`.mobile-calendar`, ≤768px)
- `.mobile-week-nav` (sticky sotto navbar, bg `#f8f9fa`): bottone "**← Prec.**",
  label centrale `"D/M – D/M"`, bottone "**Succ. →**". Bottoni `.mobile-week-btn`:
  viola pieni, radius 8px, 0.85rem/700; disabilitato = opacity 0.3.
- `.mobile-day-selector` (sticky sotto la week-nav): 7 card giorno `.mobile-day-card`
  flex 1, bg bianco, bordo `2px solid #ddd`, radius 10px, padding `0.6rem 0.2rem`,
  centrate. Contenuto: nome breve giorno ("Lun".."Dom", 0.7rem bold), numero (1rem bold),
  mese breve ("Gen".."Dic", 0.65rem opacity 0.8).
  - `.disabled` (passato o senza slot disponibili): opacity 0.35, non cliccabile.
  - `.active`: gradiente viola `var(--primary-purple)→dark`, testo bianco,
    `scale(1.05)`.
  - `.has-enrollment` (utente iscritto in quel giorno): bg `rgba(239,68,68,0.12)`,
    bordo `rgba(239,68,68,0.35)`; se anche attivo: gradiente rosso `#ef4444→#dc2626`.
  - Swipe orizzontale sul selettore (>50px) cambia settimana (sinistra→successiva se ha
    slot, destra→precedente se offset>0).
- Selezione automatica giorno: mantiene il giorno selezionato se ancora valido; altrimenti
  oggi (se ha slot disponibili) o il primo giorno futuro con slot; fallback il primo futuro.
- `.mobile-slots-list`: card slot verticali `.mobile-slot-card` — bg bianco, radius 10px,
  `padding:0.75rem 1rem`, shadow `0 2px 8px rgba(0,0,0,0.1)`,
  `border-left:5px solid <colore tipo>` + gradiente orizzontale
  `linear-gradient(to right, rgba(colore,0.22), rgba(colore,0.05))` — il colore viene da
  `getSlotColor(tipo)` (inline, org-aware).
  - Header: `🕐 HH:MM - HH:MM` (1.1rem bold) + a destra pill posti
    (`.mobile-slot-available`, 0.85rem/600, radius 20px, bg tinta del colore) oppure
    badge verde **"Qui ti alleni 💪🏼"** (`.mobile-slot-enrolled`: bg `rgba(34,197,94,0.15)`,
    testo `#16a34a`).
  - Sotto: nome tipo (0.95rem/600).
  - Slot `cleaning`: header orario + riga **"🧹 Pulizia"**, non cliccabile.
  - Slot pieno: `.slot-full` opacity 0.5 (ma cliccabile per vedere iscritti se loggato).
  - Slot con orario passato >30min: NON viene renderizzato nella lista.
  - Empty state: **"Nessuna lezione programmata per questo giorno"** oppure (se tutti
    filtrati dal cutoff) **"Nessuna lezione disponibile per questo giorno"** (testo grigio
    `#999` centrato, padding 2rem).

#### Logica slot del giorno (`_daySlots(date)`)
1. Se esiste un override puntuale in `scheduleOverrides[date]` → usa quello;
2. altrimenti template della **settimana attivata** che contiene la data
   (`getWeeklySchedule(date)`, date-aware: se la settimana non è attivata → nessuno slot).
3. In contesto org senza config → griglia vuota (mai il default legacy).

#### Auto-advance (`_autoAdvanceWeek`)
Al primo render, se la settimana corrente non ha più slot disponibili (tutti passati) e
quella successiva ne ha → parte da `currentWeekOffset=1`.

#### Boot pagina (script inline)
1. render immediato da cache localStorage;
2. `window._orgSlug = _resolveOrgSlug()`; `await initAuth()`;
3. `OrgSettings.load()` + `OrgSettings.applyBranding()`;
4. `BookingStorage.syncFromSupabase()` + `BookingStorage.syncAppSettingsFromSupabase()`;
5. deep-link `?date=YYYY-MM-DD` (da push): calcola `currentWeekOffset` per portare alla
   settimana giusta;
6. re-render; se loggato dopo 1.5s `promptPushPermission()`;
7. subscribe canali Realtime (§1.4).

---

## 5. Flusso prenotazione completo

### 5.1 Modal di prenotazione (`#bookingModal`, `booking.js`)

**Contenitore**: `.modal-overlay` (fixed, `rgba(0,0,0,0.55)`, z 2000, fadeIn 0.2s) +
`.modal-box` (bg bianco, radius 16px, padding 2rem, `max-width:680px`, `max-height:90vh`,
scroll, shadow `0 20px 60px rgba(0,0,0,0.3)`, slideUp 0.25s). Chiusura: X (32px cerchio
`#f0f0f0`, in alto a dx), tap sull'overlay, tasto Escape.
**Mobile ≤600px**: diventa **bottom sheet** — overlay allineato in basso, box
`border-radius:16px 16px 0 0`, `max-height:80dvh`, animazione slideUpSheet dal basso,
drag-handle grigia 36×4px in alto (`::before`), X nascosta, **swipe-down per chiudere**
(attivo solo se il touch parte nei primi 40px del box; se trascinato >80px → chiude).

**Header slot** (`#modalSlotInfo`, centrato, border-bottom `#eee`):
- Badge tipo (`#modalSlotTypeBadge .modal-slot-badge <tipo>`): pill uppercase bianca,
  0.8rem/700, radius 20px, bg = colore tipo (`.personal-training #22c55e`,
  `.small-group #fbbf24`, `.group-class #ef4444`, `.cleaning` viola).
- Posti (`#modalSlotSpots .modal-spots`): **"Completo"** se ≤0, altrimenti
  **"N disponibile/disponibili"**, colorato con `spots-*`.
- Giorno (`#modalSlotDay`, h3 1.5rem): `"<GiornoNome> <D/M>"`; orario (`#modalSlotTime`,
  1.3rem): `"🕐 HH:MM - HH:MM"`.

**Sezione "Persone iscritte"** (`#slotAttendees`, solo utenti loggati):
- `<details>` collassabile con summary **"Persone iscritte"** (bg `#f9fafb`, 0.9rem/600,
  freccia ▸ che ruota 90° se aperto). Se lo slot è pieno il details si apre in automatico.
- Se `user.privacy_prenotazioni !== false` (default true = privacy ATTIVA):
  **"Disattiva la privacy per vedere chi è iscritto."** (corsivo grigio `#9ca3af`).
- Altrimenti carica via RPC **`get_slot_attendees`**`({ p_org_slug, p_date, p_time })` →
  ritorna righe `{ name, slot_type }` (solo utenti con privacy disattivata, ordinate per
  slot_type). Stati:
  - loading: "Caricamento..." (corsivo grigio);
  - vuoto: **"Nessuna persona visibile per questo slot."**;
  - 1 solo tipo → lista piatta `👤 Nome`;
  - 2+ tipi → **gruppi per tipo di lezione**: intestazione con pallino colorato 8px
    (`getSlotColor(tipo)`, org-aware) + `"<NomeTipo> · <conteggio>"` (uppercase 0.72rem
    grigio `#6b7280`), poi i nomi indentati (`padding-left:0.9rem`);
  - errore: retry automatico 1 volta dopo `ensureValidSession()`; al secondo fallimento
    **"Impossibile caricare gli iscritti. Riprova"** con link Riprova.
  - Timeout RPC 8s (AbortController); anti-race con sequence counter (scarta risposte di
    slot precedenti).

**Stati del corpo modal**:
1. **Anonimo**: form nascosto; `#loginPrompt` visibile: testo **"Per prenotare devi accedere
   al tuo account."** + bottone pieno **"Accedi / Registrati"** → `login.html`.
2. **Loggato, bloccato**: form nascosto, messaggio `#bookingBlockMessage`
   (`padding:24px`, centrato, testo `#c0392b` bold, prefisso "⚠️ "). Cause, in ordine:
   - anagrafica incompleta → "Completa l'anagrafica prima di prenotare. Vai in \"Le mie
     prenotazioni\" e apri il profilo."
   - cert. non impostato e `CertBookingStorage.getBlockIfNotSet()` → "Non hai inserito la
     data di scadenza del certificato medico. Contatta il tuo PT."
   - cert. scaduto e `getBlockIfExpired()` → "Il tuo certificato medico è scaduto.
     Contatta il tuo PT per aggiornarlo."
   - assicurazione non impostata / scaduta (`AssicBookingStorage`) → analoghi con
     "assicurazione".
3. **Loggato, slot pieno**: form nascosto, si vede solo l'header + iscritti (aperti).
4. **Loggato ok**: form visibile; i campi Nome/Email/WhatsApp sono precompilati dal profilo
   e il blocco `#bookingUserFields` è **nascosto** (restano solo Note); l'anonimo (caso 1)
   non arriva mai al form.

**Form** (`#bookingForm`): campi label→input:
"Nome Completo *", "Email *", "Numero WhatsApp *" (tel), "Note (opzionale)" (textarea 2
righe). Submit: bottone pieno **"Conferma Prenotazione"** (`.btn-primary`).

### 5.2 Submit (`handleBookingSubmit`)

1. Doppio-click guard (disabilita bottone). Timer: dopo 15s toast warning
   **"Connessione lenta, attendi..."**; dopo 50s sblocco forzato + toast error
   **"La richiesta sta impiegando troppo. Riprova."**
2. Validazioni client (toast error):
   - nessuno slot selezionato → "Seleziona uno slot dal calendario prima di prenotare."
   - cutoff: se passati >30 min dall'inizio → "Non è possibile prenotare: sono passati più
     di 30 minuti dall'inizio della lezione." (e chiude il modal)
   - campi vuoti → "Compila tutti i campi obbligatori."
   - email regex `^[^\s@]+@[^\s@]+\.[^\s@]+$` → "Inserisci un indirizzo email valido."
   - telefono regex `[\d\s+()-]{10,}` → "Inserisci un numero WhatsApp valido."
   - nome: title-case automatico; email lowercase; whatsapp `normalizePhone()` (E.164, §12.1).
3. **Check duplicato**: query diretta `bookings` (`user_id = me AND date AND time AND
   status NOT IN (cancelled, cancellation_requested)`, timeout 10s; fallback su cache
   locale per anonimi/offline, match per email o telefono normalizzato) →
   "Hai già una prenotazione per questo orario."
4. Re-check blocchi cert/assicurazione (stessi testi con prefisso "Prenotazione bloccata: …").
5. `setLoading(btn, true, 'Prenotazione in corso...')` → **`BookingStorage.saveBooking()`**:
   - genera `id` locale `"<timestamp>-<rand36>"`, `createdAt` ISO, `status:'confirmed'`;
   - `ensureValidSession()` best-effort;
   - RPC **`book_slot`** con timeout/abort 45s, parametri:
     ```
     p_org_slug, p_local_id, p_date, p_time, p_name, p_email, p_whatsapp,
     p_notes, p_date_display
     ```
     (server risolve org, tipo, capienza, prezzo, user_id da auth.uid(), advisory lock
     anti-overbooking, gating billing: decremento pacchetto/quota abbonamento, `paid`
     iniziale per modelli monthly/package/free).
   - Risposta `{ success, booking_id, paid }` → aggiorna cache, invalida availability.
   - Errori (`result.error`):
     - `slot_full` → toast "Slot non più disponibile. Qualcun altro ha prenotato prima di te."
       + re-render calendario;
     - `too_late` → toast "Non è possibile prenotare: sono passati più di 30 minuti
       dall'inizio della lezione." + chiudi modal;
     - `server_error` e offline → "Sei offline. Connettiti a internet per prenotare.";
     - altro → "Errore durante la prenotazione. Riprova tra qualche secondo."
6. Successo → `showConfirmation(booking)`, `notificaPrenotazione(booking)` (notifica
   locale di sistema), `notifyAdminBooking(booking)` (push all'admin, §14), reset form,
   re-render calendario.

### 5.3 Schermata di conferma (`showConfirmation`)

Sostituisce il form dentro il modal (`#confirmationMessage`, gradiente viola brand →
dark, radius 12px, testo bianco, centrato):
- Titolo: **"✓ <NomeTipo> Confermata!"** (1.3rem)
- `<strong>Nome</strong>`; riga "📅 <GiornoNome D/M> · 🕐 <HH:MM - HH:MM>"
- Riga bottoni calendario (`.cal-buttons`): **"Google Calendar"** (`.cal-btn-google`,
  bg bianco/testo `#444`, apre `googleCalendarUrl()` — URL `calendar.google.com/render`
  con `text="Allenamento – <NomeTipo>"`, `dates`, `details="Prenotato da <nome>"`,
  `ctz=<timezone org>`) e **"Apple Calendar"** (`.cal-btn-apple`, bg `rgba(255,255,255,0.15)`,
  scarica file `.ics` "allenamento.ics" via `downloadIcs()` — VCALENDAR con VTIMEZONE
  CET/CEST del fuso org, UID `<id>@palestria.app`, `SUMMARY:Allenamento – <NomeTipo>`).
- Blocco regole (`.confirm-rules`, allineato a sinistra, 3 item icona+testo):
  1. 👟 **"Abbigliamento adeguato"** — "Indossa scarpe di ricambio pulite (da usare solo in
     palestra). In alternativa, puoi allenarti con calze antiscivolo. Porta sempre una
     **salvietta** personale da usare sugli attrezzi."
  2. 🚫 **"Alimentazione e digestione"** — "Non mangiare nelle 2–3 ore prima
     dell'allenamento per evitare fastidi durante l'attività fisica."
  3. 💧 **"Idratazione"** — "Porta sempre con te una borraccia d'acqua per mantenerti
     idratato durante la sessione."
- Bottone finale **"← Torna al calendario"** (bianco con bordo viola 2px) → chiude modal.
- Notifica locale (se permesso concesso): titolo "Prenotazione confermata", body
  `"<NomeTipo> · <dateDisplay> · <time>"`.

### 5.4 Gating pagamenti (informativo)

Il client NON pre-verifica il credito: `book_slot` applica il modello billing del cliente
(`client_billing_profiles.model_override` ?? `billing_settings.default_model`):
- `pay_per_session`: booking creato `paid=false` (si paga dopo, badge "Da pagare");
- `monthly`: se abbonamento attivo con quota → `paid=true` (`payment_method='abbonamento'`)
  e `lessons_used++`;
- `package`: se pacchetto attivo con ingressi → `paid=true` (`'pacchetto'`) e
  `remaining_sessions--`;
- `free`: `paid=true` (`'gratuito'`).
Lo stato riepilogativo è mostrato in prenotazioni.html (§7.3).

---

## 6. Pagina: Login / Registrazione (login.html)

`<title>` "Accedi – PalestrIA". Layout: navbar comune (senza blocco auth), poi
`.login-page` (flex centrato, min-height calc(100vh − 70px), bg `#f8f9fa`) con una card.

### 6.1 Card (`.login-card`)

Bg bianco, radius 16px, `padding:2.5rem 2rem` (1.75/1.25 mobile), `max-width:400px`,
shadow `0 8px 32px rgba(0,0,0,0.12)`, contenuto centrato.
- Logo circolare 80×80 (`object-fit:cover`, `border-radius:50%`, `[data-org-logo]`).
- **Tabs** (`.login-tabs`): pill container bg `#f8f9fa` radius 10, due bottoni flex 1
  **"Accedi"** / **"Registrati"** (0.9rem/600, grigio `#888`; attivo: bg bianco, testo
  scuro, shadow leggera). Nascoste nei pannelli forgot/reset.

### 6.2 Pannello ACCEDI

- Sottotitolo: **"Accedi per vedere le tue prenotazioni"** (0.9rem, `#777`).
- Box demo (stile inline, bg `#eef7ff`, bordo viola, radius 10px): titolo "🎬 Demo mode",
  credenziali Admin (`admin@palestria.app` / `Demo2026Admin!`) e Cliente
  (`luca.bianchi@demo.it` / `Demo2026!`) in `<code>`. (Solo demo — opzionale in Flutter.)
- Bottone social **"Continua con Google"** (`.social-btn-google`: bianco, bordo `1.5px #ddd`,
  radius 10px, logo Google 4 colori) → `supabaseAuth.auth.signInWithOAuth({provider:'google',
  redirectTo: origin + '/login.html'})`.
- Divider **"oppure"** (linee `#e0e0e0` ai lati, testo `#aaa` 0.85rem).
- Form manuale: "Email" (placeholder `mario@email.com`), "Password" (placeholder
  `••••••••`) con bottone **"Mostra"/"Nascondi"** dentro il campo
  (`.password-toggle`, 0.78rem grigio, a destra). Input: radius 8px, bordo `1.5px #ddd`,
  focus bordo viola + ring `rgba(139,92,246,0.12)`. Errori inline `.login-error`
  (rosso `#dc2626`, 0.85rem): "Compila tutti i campi." o il messaggio mappato (§12.2).
- Submit **"Accedi"** full-width; loading "Accesso in corso...".
- Link sotto: **"Hai dimenticato la password?"** (0.85rem grigio, hover viola sottolineato)
  → pannello Forgot.
- Successo login: se il profilo è completo → redirect `index.html`; se ruolo
  owner/admin/staff → redirect `admin.html`; se anagrafica incompleta → modal
  "completa profilo" (§6.5).

### 6.3 Pannello REGISTRATI

Sottotitolo: **"Crea il tuo account per prenotare le lezioni"**. Campi (tutti obbligatori):
- riga doppia "Nome *" (placeholder Mario) / "Cognome *" (Rossi), maxlength 40;
- "Email *"; "Numero WhatsApp *" (placeholder `+39 348 1234567`);
- "Codice Fiscale *" (placeholder `RSSMRA85M01H501Z`, maxlength 16, uppercase);
- "Via / Indirizzo *" (Via Roma 1);
- riga "Paese / Città *" (flex 2, Milano) / "CAP *" (flex 1, 20100, maxlength 5, numeric);
- "Password *" (Min. 6 caratteri) e "Conferma Password *" con toggle Mostra.
Validazioni (messaggi esatti):
- vuoti → "Compila tutti i campi obbligatori."
- nome/cognome regex `^[\p{L}][\p{L}\s'-]{1,}$` → "Nome non valido. Usa solo lettere,
  apostrofi e trattini (min. 2 caratteri)." (idem "Cognome non valido. …")
- email → "Inserisci un indirizzo email valido."
- whatsapp normalizzato deve matchare `^\+\d{10,15}$` → "Numero WhatsApp non valido.
  Usa formato: +39 348 1234567"
- CF regex `^[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]$` (case-insens.) → "Codice Fiscale non
  valido. Deve essere di 16 caratteri alfanumerici."
- CAP `^\d{5}$` → "CAP non valido. Deve essere di 5 cifre."
- password <6 → "La password deve essere di almeno 6 caratteri."; diverse → "Le password
  non coincidono."
Submit **"Registrati"** (loading "Registrazione in corso..."), chiama `registerUser(name,
email, whatsapp, password, codiceFiscale, {via, paese, cap})` (§12.3). Successo → nasconde
il form e mostra: 📧 (2.5rem) + **"Controlla la tua email!"** + "Ti abbiamo inviato un link
di conferma. Clicca il link per attivare il tuo account e accedere."
Errore server: mostrato inline (es. "Questo numero WhatsApp è già associato a un altro
account.", "Email già registrata.", "Studio non identificato. Apri il link di
registrazione del tuo studio (es. ?org=nome-studio) e riprova.").

### 6.4 Pannelli password

**Forgot**: sottotitolo "Inserisci la tua email e ti invieremo un link per reimpostare la
password." Campo Email, submit **"Invia link di reset"** (loading "Invio in corso...") →
`supabaseAuth.auth.resetPasswordForEmail(email, { redirectTo: origin + '/login.html' })`.
Successo: 📧 + **"Email inviata!"** + "Controlla la tua casella di posta e clicca il link
per reimpostare la password." + link "← Torna al login". Errori: "Inserisci la tua
email." / "Inserisci un indirizzo email valido." / "Errore durante l'invio. Riprova."

**Reset** (attivato dall'evento Supabase `PASSWORD_RECOVERY` al click del link email):
sottotitolo "Scegli la tua nuova password." Campi "Nuova Password" (Min. 6 caratteri) e
"Conferma Password" con toggle. Submit **"Salva nuova password"** (loading
"Salvataggio...") → `supabaseAuth.auth.updateUser({ password })`. Successo: ✅ +
**"Password aggiornata!"** + "Ora puoi accedere con la nuova password." + bottone
"Vai al login". Errori: "Compila entrambi i campi." / min 6 / non coincidono /
"Errore durante il salvataggio: <msg>".

### 6.5 Modal "Completa profilo" post-OAuth (`#completeProfileModal`)

Overlay `.social-modal-overlay` (rgba(0,0,0,0.5), allineato in ALTO) con box che scende
dall'alto (`.social-modal-box`, radius solo in basso `0 0 16px 16px`, max-width 480px,
animazione socialSlideDown 0.3s).
Titolo **"Un'ultima cosa!"**, sotto "Completa il tuo profilo per continuare."
Campi: "Numero WhatsApp *", "Codice Fiscale *", "Via / Indirizzo *",
"Paese / Città *" + "CAP *". Bottone **"Continua"**.
Validazioni: telefono → "Numero non valido. Usa formato: +39 348 1234567"; CF →
"Codice Fiscale non valido (16 caratteri alfanumerici)."; via/paese vuoti → "Compila via e
paese di residenza."; CAP → "CAP non valido. Deve essere di 5 cifre."
Logica: RPC `is_whatsapp_taken({phone, exclude_user_id})` → se preso: "Questo numero
WhatsApp è già associato a un altro account."; se l'utente non ha org → RPC
`join_organization({p_org_slug})` (se slug assente: "Studio non identificato. Apri il link
del tuo studio (es. ?org=nome-studio) e riprova."); poi `upsert` su `profiles`
(`{id, org_id, name, email, whatsapp, codice_fiscale, indirizzo_via, indirizzo_paese,
indirizzo_cap}`) e redirect `index.html`.
Il modal si mostra quando: ritorno OAuth con anagrafica incompleta, conferma email con
anagrafica incompleta, o login con profilo incompleto. Owner/admin/staff NON passano di
qui (vanno diretti ad `admin.html`).

### 6.6 Notifica admin "nuovo iscritto"

`maybeNotifyNewClient(session)`: se l'account è stato creato da <120 s e non già
notificato (`localStorage.new_client_notified = user.id` come dedup) → chiama
`notifyAdminNewClient(nome)` (edge `notify-admin-new-client`). Ancorata in 2 punti:
submit registrazione (conferma email OFF) e `initAuth` al ritorno dal link di conferma.

---

## 7. Pagina: Le mie prenotazioni (prenotazioni.html)

Home post-login del cliente. `<title>` "Le mie prenotazioni – PalestrIA".
Layout: navbar comune → `main.preno-page` (bg `#f8f9fa`, `padding:2rem 0 3rem`) → footer.
CSS: `css/prenotazioni.css`.

### 7.1 Hero profilo (`.preno-hero`)

Card gradiente scuro→viola `linear-gradient(135deg, #1a1a1a 0%, #2a1f3d 50%, #6D28D9
100%)`, radius 18px (16 mobile), `padding:1.1rem 1.25rem`, shadow
`0 4px 20px rgba(109,40,217,0.25)` + inset ring bianco 6%. Glow radiale viola 45% in
basso a destra (`.preno-hero-glow`).
Contenuto in riga:
- **Avatar** (`#prenoAvatar`): cerchio 54px (48 mobile), gradiente
  `#A78BFA → #8B5CF6 → #6D28D9`, iniziale del nome (1.45rem/700, bianco).
- Nome (`#prenoUserName`): **primo nome** dell'utente, 1.45rem (1.25 mobile), 800, bianco.
- Bottone modifica (`.preno-hero-edit`): 28px quadrato radius 8, bg `rgba(255,255,255,0.12)`,
  icona matita 14px → apre il modal Modifica profilo.
- Sotto il nome (`#prenoAccessCode`): "Codice accesso: **4729 + ▲**" (0.78rem,
  `rgba(255,255,255,0.72)`; il codice è statico nell'app attuale).
- A destra: bottone grafico (`.preno-hero-chart`): 38px radius 10, bg
  `rgba(255,255,255,0.14)`, icona bar-chart → apre il modal "Allenamenti settimanali".

### 7.2 Warning anagrafica/certificato (`#prenoCertWarning`, `renderCertWarning`)

Banner pill (`.preno-cert-warning`: radius 12px, `padding:0.7rem 1rem`, 0.88rem/600):
- Stile "expired" (`.preno-cert-expired`): bg `#fef2f2`, testo `#dc2626`,
  `border-left:4px solid #dc2626`.
- Stile "expiring" (`.preno-cert-expiring`): bg `#fffbeb`, testo `#92400e`, bordo `#f59e0b`.
Casi (in ordine, possono cumularsi):
1. anagrafica incompleta (manca whatsapp/CF/via/paese/CAP) → **"📋 Completa anagrafica"**
   (cliccabile → apre modal profilo);
2. `CertEditableStorage.get()` true e `medical_cert_expiry` assente →
   **"📋 Imposta Cert. Medico"** (cliccabile);
3. certificato scaduto → **"⚠️ Certificato medico scaduto"**;
4. scade entro 30 giorni → **"⏳ Cert. medico scade fra N giorno/i"**.

### 7.3 Card stato pagamenti (`#prenoBilling`, `renderClientBilling`)

Card orizzontale (inline style): `padding:13px 16px`, `border:1.5px solid`, radius 14px,
icona emoji 1.55rem + titolo bold `#1a1a1a` + dettaglio 0.84rem `#64748b`.
Toni: `ok` → bordo `#22c55e` bg `#f0fdf4`; `warn` → bordo `#f59e0b` bg `#fffbeb`;
neutro → bordo `#e2e8f0` bg bianco.
Dati letti in parallelo: `billing_settings.default_model` (per org),
`client_billing_profiles.model_override` (per me), `client_memberships` (attiva più
recente: `plan_label, period_end, lessons_quota, lessons_used, status`),
`client_packages` (attivi: `label, remaining_sessions`).
Modello effettivo = `model_override ?? default_model ?? 'pay_per_session'`. Render:

| Modello | Icona | Titolo | Dettaglio |
|---|---|---|---|
| `free` | 🎁 (ok) | "Accesso gratuito" | "Nessun pagamento richiesto per le tue lezioni." |
| `monthly` attivo | 📅 (ok) | "Abbonamento attivo[ · <plan_label>]" | "Valido fino al <gg/mm/aaaa> · <used>/<quota> lezioni usate" oppure "… · lezioni illimitate" |
| `monthly` non attivo | 📅 (warn) | "Abbonamento non attivo" | "Contatta il trainer per attivare o rinnovare l'abbonamento mensile." |
| `package` con residuo | 🎫 (ok) | "Pacchetto: N ingresso/i rimasto/i" | "Gli ingressi si scalano automaticamente a ogni prenotazione." |
| `package` esaurito | 🎫 (warn) | "Pacchetto esaurito" | "Contatta il trainer per acquistare un nuovo pacchetto." |
| `pay_per_session` con debito | 💳 (warn) | "Da saldare: €<tot>" | "N lezione/i non ancora pagata/e." |
| `pay_per_session` ok | ✅ (ok) | "Pagamenti in regola" | "Paghi ogni lezione singolarmente." |

Il debito = somma di `getBookingPrice(b)` sulle prenotazioni PASSATE non pagate e non
annullate. Valuta: `OrgSettings.getString('locale.currency','EUR')` → simbolo `€` se EUR.

### 7.4 Tabs + lista prenotazioni

- Tabs (`.preno-tabs`): container bianco radius 14px padding 0.3rem, due bottoni flex 1
  **"Prossime"** / **"Passate"** (0.88rem/600 grigio; attivo: bianco su viola brand,
  radius 11px, shadow viola). Divider orizzontale sotto (`#e5e7eb`).
- Sorgente: `getUserBookings()` (§12.5) → `{upcoming, past}` ordinati (prossime asc,
  passate desc).
- **Paginazione**: mostra le prime **5**; bottone **"Mostra altro (N)"**
  (`.preno-show-more`: full width, bordo `1.5px #e5e7eb`, radius 14px, testo viola
  0.88rem/600) carica **+20** alla volta.
- Empty state (`.preno-empty`, card bianca radius 14): **"Nessuna prenotazione futura."** /
  **"Nessuna prenotazione passata."**

#### Card prenotazione (`.preno-card`)
Card bianca radius 14px, `border-left:5px solid <colore tipo>` (var CSS per i 4 tipi
legacy), `padding:1rem 1.15rem`, flex spazio-tra, shadow leggera, hover translateY(-2px).
- Sinistra: riga data (icona calendario 15px + **"Sabato 4 Luglio 2026"** — formato
  `<GiornoSettimana> <g> <Mese> <anno>` in italiano, 0.92rem/700), riga orario (icona
  orologio + `HH:MM - HH:MM`, 0.85rem `#666`), riga tipo (`getSlotName`, 0.78rem `#999`).
- Destra (colonna, allineata a destra): **badge pagamento** + eventuale azione annullo.

Badge (`.preno-badge`: pill 0.73rem/600 radius 20px):
| Stato | Classe | Colori | Testo |
|---|---|---|---|
| annullata | `preno-badge-cancelled` | bg `#f3f4f6`, testo `#6b7280` | "✕ Annullata" |
| pagata | `preno-badge-paid` | bg `#dcfce7`, testo `#166534` | vedi mappa metodi |
| da pagare | `preno-badge-unpaid` | bg `#fef9c3`, testo `#854d0e` | "Da pagare" |

Mappa metodi (`paymentMethod`):
`contanti` → "💵 Pagata con Contanti"; `contanti-report` → "🧾 Pagata con Contanti
(Report)"; `carta` → "💳 Pagata con Carta"; `iban` → "🏦 Pagata con Bonifico";
`stripe` → "💳 Pagata con Stripe"; `pacchetto` → "🎫 Pagata con Pacchetto";
`abbonamento` → "📅 Pagata con Abbonamento"; `gratuito` → "🎁 Lezione Gratuita";
altro → "✓ Pagata".

#### Regole annullamento (tab Prossime, stato ≠ cancelled, lezione non iniziata)
Costanti: `TEN_MIN=10min` (grace dal `createdAt`), `ONE_DAY=24h`, `TWO_HOURS=2h`,
`THREE_DAYS=72h`. `msToLesson` = inizio lezione − ora.
- **Grace period**: entro 10 min dalla creazione → sempre annullo diretto.
- Annullo **diretto** se: grace, oppure `group-class` con >3 giorni, oppure altri tipi
  con >24h → bottone **"Annulla prenotazione"** (`.preno-cancel-btn`: ghost bordo
  `#e5e7eb`, testo rosso `#dc2626` 0.78rem/600, radius 20px, hover bg `#fee2e2`).
- **Richiesta** di annullamento se: NON group-class e 2h < msToLesson ≤ 24h → bottone
  **"Richiedi annullamento"** (stesso stile).
- Stato `cancellation_requested` → chip **"⏳ Annullamento in attesa"**
  (`.preno-cancel-pending`: bg `#fef3c7`, testo `#92400e`).
- Altrimenti (lezione futura ma non annullabile) → chip **"🔒 Non annullabile (<motivo>)"**
  (`.preno-cancel-locked`: bg `#f3f4f6` testo `#6b7280`); motivo: "meno di 2 ore" se
  ≤2h, altrimenti "slot prenotato entro 3 giorni".

**Annullo diretto** (`cancelDirect`): dialog conferma (§16.2). Messaggi:
- group-class: "Confermare l'annullamento?\n\nLa prenotazione sarà annullata e lo slot
  diventerà una Lezione di Gruppo aperta al pubblico." (conferma "Annulla prenotazione",
  cancel "Indietro");
- altri: "Confermare l'annullamento della prenotazione?".
Poi RPC **`cancel_booking({ p_booking_id })`** (server: status→cancelled + conversione
group-class→small-group; NESSUN rimborso). Errori: showAlert "Errore: <msg>" /
`data.error` / "Errore di rete. Riprova." Successo → sync `ownOnly` + re-render +
`notifyAdminCancellation(booking)`.

**Richiesta annullamento** (`requestCancellation`): conferma con messaggio:
"Richiedere l'annullamento?\n\n• Se qualcuno prenota al tuo posto, la prenotazione sarà
annullata.\n• Se entro 2 ore dalla lezione nessuno ha preso il tuo posto, l'annullamento
viene negato e dovrai presentarti." (conferma "Richiedi annullamento"). Poi RPC
**`user_request_cancellation({ p_booking_id })`** → stato `cancellation_requested`
(il posto torna disponibile; un cron server-side ogni 15 min riconferma se entro 2h nessuno
ha preso il posto; se qualcuno prenota, la richiesta più vecchia viene soddisfatta FIFO).

### 7.5 CTA finale

`.preno-cta-btn`: bottone-link centrato **"Prenota una lezione"** con icona calendario,
gradiente `#8B5CF6 → #0088cc`, bianco 0.95rem/700, `padding:0.8rem 1.75rem`, radius 14px,
shadow viola → `index.html`.

### 7.6 Modal "Allenamenti settimanali" (`#weeklyChartModal`)

Modal box max-width 520px. Header: titolo `#chartViewTitle` ("Allenamenti settimanali" /
"Allenamenti mensili") + bottone toggle pill ghost (`#chartToggleBtn`, 0.72rem, bordo
`1.5px #e0e0e0`, radius 20px): "Vista mensile" ↔ "Vista settimanale".
Canvas `#weeklyChartCanvas` (100% × 250px), grafico a barre con `SimpleChart`
(`chart-mini.js`) + overlay custom:
- **Settimanale**: 8 settimane (4 passate, corrente evidenziata, 3 future), etichette
  `dd/mm` del lunedì. Barre = conteggio prenotazioni non annullate per settimana;
  porzione passata blu `#3b82f6`, porzione futura sovrapposta in rosso `#e63946`.
- **Mensile**: 10 mesi (−5…+4), etichette "Gen".."Dic".
- Legenda sotto: quadratini 10px "Passati" (`#3b82f6`) e "Futuri" (`#e63946`).
- Dati: cache utente (finestra 60gg) FUSA con lo storico completo caricato on-demand via
  `BookingStorage.fetchClientHistory({userId, email, whatsapp})` (fail-silent).

### 7.7 Modal "Modifica profilo" (`#editProfileModal`)

`.modal-box.edit-profile-modal` (max-width 480px, `max-height:90vh` scroll; mobile:
bottom-sheet-like con X visibile). Header: avatar 48px (gradiente `#8B5CF6 → #0077b6`,
iniziale) + titolo **"Modifica profilo"** + sottotitolo = email.
Sezioni con titolo uppercase 0.78rem grigio `#888` + icona 15px:
1. **"Dati personali"**: "Nome completo" (input DISABILITATO — non modificabile),
   "Email", "Numero WhatsApp", "Codice Fiscale".
2. **"Indirizzo"**: "Via / Indirizzo", riga "Paese / Città" (flex 2) + "CAP" (flex 1).
3. **"Documenti"**: "Scadenza certificato medico" (date; DISABILITATA se
   `CertEditableStorage.get()===false`), "Scadenza assicurazione (gestita dal trainer)"
   (date, SEMPRE disabilitata).
4. **"Sicurezza"** (nascosta per account OAuth): "Nuova password (lascia vuoto per non
   cambiare)", "Conferma nuova password".
5. Checkbox **"Privacy prenotazioni"** (accent viola 18px) + nota: "Se attivo, il tuo nome
   non sarà visibile agli altri nelle prenotazioni." (default: attivo).
Errore inline (`.edit-profile-error`: bg `#fef2f2`, testo `#dc2626`, bordo `#fecaca`,
radius 10px). Bottone **"Salva modifiche"** sticky in basso.
Validazioni: nome/email obbligatori ("Il nome è obbligatorio." / "L'email è
obbligatoria."), password min 6 e coincidenza, CAP 5 cifre.
Submit → `updateUserProfile(currentEmail, updates, newPassword)` (§12.6). Successo:
chiude modal, aggiorna hero, toast success **"Profilo aggiornato."** oppure (se cambiata
email) **"Profilo aggiornato. Controlla la tua email per confermare il cambio di
indirizzo."** (6s).

### 7.8 Lifecycle pagina

- Boot: `initAuth()`; se sessione non pronta ritenta dopo 2s (getSession → refreshSession);
  `OrgSettings.load()+applyBranding()`; `syncFromSupabase({ownOnly:true})` +
  `syncAppSettingsFromSupabase()`; init UI; `promptPushPermission()` dopo 1.5s.
- Polling 120s: re-render se esistono prenotazioni proprie in `cancellation_requested`
  (si ferma quando non ce ne sono più); stop quando la pagina è nascosta.
- Realtime `preno-rt` (§1.4); bfcache `pageshow` → re-init.

---

## 8. Pagina: Allenamento (allenamento.html)

Scheda workout del cliente. Accesso: **solo loggati**; i NON admin devono avere almeno una
scheda attiva (`workout_plans where user_id=me and active=true`, count>0) altrimenti
redirect a `index.html`. `<body class="allenamento-body">`, `<html class="all-shell-page">`
(su iOS standalone ≤768px lo scroller è il body, non il root — fix dock).
`<title>` "Allenamento – PalestrIA". CSS: `css/allenamento.css`.

### 8.1 Design tokens locali (prefisso `--all-*`)

```
--all-purple:#8B5CF6  --all-purple-dark:#7C3AED  --all-purple-glow:rgba(139,92,246,.12)
--all-navy:#0f172a  --all-slate:#1e293b  --all-muted:#64748b  --all-subtle:#94a3b8
--all-border:#e2e8f0  --all-border-hover:#cbd5e1  --all-surface:#fff  --all-bg:#f1f5f9
--all-success:#10b981  --all-success-dark:#059669  --all-amber:#f59e0b
--all-cyan:#06b6d4  --all-cyan-dark:#0891b2
--all-radius:16px  --all-radius-sm:12px  --all-radius-xs:8px
--all-shadow: 0 1px 3px rgba(15,23,42,.06), 0 1px 2px rgba(15,23,42,.04)
--all-shadow-md: 0 4px 16px rgba(15,23,42,.08), 0 2px 4px rgba(15,23,42,.04)
--all-transition: 0.2s cubic-bezier(0.4,0,0.2,1)
```

### 8.2 Navigazione tra sezioni

**Desktop** (`.all-nav`, ≥769px): barra pill (container bianco radius 14, padding 0.3rem,
come le tabs di prenotazioni) con 5 tab: **"Scheda"**, **"Progressi"**, **"Report"**,
**"Tablet"**, + pill-icona download (PDF). Attiva: bianco su viola con shadow.
Sopra la barra: **plan selector** (`#allPlanSelector`): se più schede → `<select>` con
`"<nome> (attiva)"` per la scheda attiva + bottone matita ✎ "Rinomina scheda"; se una sola
→ nome piatto + matita.

**Mobile** (≤768px): `.all-nav` nascosta. In basso **dock fisso** (`.all-bottom-stack` →
`.all-dock-btn`): bottone full-width min-height 60px, gradiente
`linear-gradient(135deg, var(--all-purple-dark), var(--all-purple))`, radius 12px,
shadow multipla viola; contenuto: icona emoji in box 38px `rgba(255,255,255,0.20)`,
eyebrow **"Sezione"** (0.62rem uppercase bianco 78%), nome sezione corrente (0.98rem/800),
chevron su. Tap → **bottom sheet** (`.all-sheet`: bianco, radius top 18px, slide-up 0.28s,
backdrop `rgba(15,23,42,0.45)`, grabber 40×4 `#cbd5e1`, titolo **"Vai a"** uppercase
0.78rem `#64748b`) con la lista sezioni:
`📋 Scheda · 📈 Progressi · 📊 Report · 📱 Tablet · ⬇️ Scarica PDF` — item con icona in
box 36px `#f1f5f9`, titolo 0.95rem/700, radio a destra (22px; selezionato: pieno viola con
pallino bianco, item bg viola 10%). Swipe-down o backdrop per chiudere. Mentre il sheet è
aperto il dock è nascosto. Il footer di pagina è nascosto su mobile.
Il contenuto ha `padding-bottom: calc(100px + safe-area)`; il FAB sta a
`bottom: calc(84px + safe-area)`.

La vista attiva è persistita in `sessionStorage.allView`
(valori: `scheda|progressi|storico|report|tablet|pdf`; `storico` è sotto-vista di
Progressi e tiene attiva la pill Progressi).

### 8.3 Vista SCHEDA (`renderScheda`)

**Hero mobile** (`.scheda-hero`, solo ≤768px — sostituisce plan selector e day tabs):
card gradiente `linear-gradient(135deg, #0f172a 0%, #1e1b4b 60%, #7C3AED 130%)`, radius
18px, margini negativi −16px laterali, glow radiale viola in basso a destra. Contenuto:
- eyebrow **"Scheda"** (9.5px/800 uppercase, `rgba(196,181,253,0.85)`);
- nome scheda (22px/800 bianco, ellipsis) + bottone matita 32px
  (`rgba(255,255,255,0.12)`) → `renamePlan()` (prompt "Nuovo nome scheda:", conferma
  "Rinomina"; toast "Scheda rinominata");
- rail orizzontale scrollabile dei **giorni**: chip `.day` (radius 11px, bg
  `rgba(255,255,255,0.08)`, bordo bianco 10%, blur): nome giorno (13px/800) + meta
  `"ultimo · oggi|<d MMM>|mai"` (10px, bianco 65%). Attivo: bg bianco, testo `#0f172a`.
  Ordine: il giorno "da fare" (suggerito) è primo. Chip finale `+` tratteggiato →
  `addDayToScheda()`.

**Day tabs desktop** (`.all-day-tabs`, nascoste su mobile): card 4-visibili scrollabili,
bordo `1.5px var(--all-border)`, radius 16, top-bar 2.5px (viola se attiva, verde
`#10b981` se completata oggi). Contenuto per tab: nome giorno (0.82rem/700; "✓" se fatto
oggi), "ultimo: <oggi|d MMM|mai>" (0.62rem), "prossimo: <oggi|domani|d MMM|niente>"
(0.68rem viola scuro — mappa le prossime prenotazioni confermate ai giorni in rotazione
least-recent). Tab `+` (44px, tratteggiato) per aggiungere giorno.
Interazioni: tap = seleziona; **doppio tap / dblclick** = menu giorno (overlay centrato,
card bianca radius 16: titolo = nome giorno, bottoni "✏️ Rinomina" e "🗑️ Elimina"
(danger)); **long-press 500ms** = drag per riordinare i giorni (riassegna i sort_order di
tutti gli esercizi; vibrazione 30ms).
- Rinomina giorno: prompt "Rinomina giorno:"; duplicato → toast "Questo nome esiste già";
  successo → "Giorno rinominato".
- Elimina giorno: conferma `Eliminare "<giorno>" e i suoi N esercizi?` → toast
  `"<giorno>" eliminato`.
- Nuovo giorno (`addDayToScheda`): prompt "Nome del nuovo giorno:" con default
  "Giorno A/B/C…" (prima lettera libera); duplicato → "Questo giorno esiste già"; poi apre
  il **picker esercizi** (il giorno viene creato col primo esercizio).

**Header giorno** (`.all-day-header`): nome giorno + contatore
**"N/M completati"** (esercizi con log di oggi).

**Card esercizio singolo** (`.all-ex-card`): card bianca bordo `1.5px #e2e8f0` radius
16px, margine 0.65rem, barra sinistra 3px (trasparente; verde se fatto oggi); se fatto
oggi (`.all-ex-done`): bordo verde `#10b981`, bg gradiente `#f0fdf4 → #fff`.
Header (`.all-ex-header`, padding `0.9rem 1.1rem`): thumbnail 44px radius 10 (immagine
esercizio dal catalogo), nome (0.93rem/700 navy), target (0.76rem `#64748b`):
- normale: `"<sets> × <reps>[ · <peso> kg][ · <rest>s pausa]"` (se `rest ≤ 3` mostra
  `"<rest> min"`);
- cardio (muscle_group "Cardio"): `"<reps> min"`.
A destra: chevron `›` oppure check verde in cerchio 30px (gradiente
`#10b981→#059669`).
- Tap header → **overlay dettaglio** (sotto).
- **Swipe left** (solo touch, direction-lock 8px, max 100px): rivela azione
  **"Elimina"** (colonna 85px a destra con icona cestino); snap aperto a −85px se
  trascinato >60px. Tap Elimina → conferma "Eliminare questo esercizio dalla scheda?" →
  toast "Esercizio eliminato".
- **Long-press 500ms** → drag verticale per riordinare (scale 1.02, le altre card si
  spostano; al rilascio riassegna `sort_order` e salva).

**Card Super Serie** (`.all-ss-card`): stessa struttura; badge **"SS"** + 2 thumbnail,
lista dei 2 nomi; check se entrambi fatti oggi. Tap → dettaglio superset. Swipe-delete:
"Eliminare questa super serie dalla scheda?" → "Super Serie eliminata".

**Card Circuito** (`.all-cc-card`): badge **"C"** + fino a 4 thumbnail (`+N` se di più),
meta `"<giri> giri[ · <rest>s pausa]"`, lista nomi. Tap → dettaglio circuito.
Swipe-delete: "Eliminare questo circuito dalla scheda?" → "Circuito eliminato".

**Empty state** (nessuna scheda): "Nessuna scheda ancora.\nPremi il **+** in basso per
crearne una!". Errore: "Errore caricamento scheda.".
Loading globale (`.all-loading`): spinner 36px (bordo 3px `#e2e8f0`, top viola, rotate
0.7s) + "Caricamento...".

### 8.4 Overlay dettaglio esercizio / superset / circuito

Overlay fullscreen (`.all-detail-overlay` → `.all-detail-panel`) con header: freccia
indietro, titolo (= nome esercizio | "Super Serie" | "Circuito"), matita modifica.
Il tasto **Indietro hardware/browser chiude l'overlay** (history.pushState + popstate,
con flag di soppressione).
Contenuto scrollabile:
- media: video autoplay-loop-muted (`apilyfta.com`) o immagine dell'esercizio;
- riga target: **"DA FARE:"** · `<target>`;
- eventuale nota esercizio (corsivo grigio);
- **"Sessione precedente — <d MMM>"**: `<details>` giallino (bg gradiente
  `#fefce8→#fffbeb`, bordo sinistro 3px `#f59e0b`) con chip per set:
  `"1. 10×20kg"` (o `"20 min"` cardio);
- **sezione log** (`.all-log-section`): header **"Registra per oggi — <d MMM>"**
  (0.72rem uppercase); griglia con intestazioni `Serie | Ripetizioni | Kg | Riposo`
  (cardio: solo `Min`); una riga per set: numero set + 3 input numerici
  (`.all-log-input`: bg `#f1f5f9`, bordo-bottom `#e2e8f0`, radius 12, centrato, 0.95rem/600;
  focus: bordo viola + ring + `scale(1.04)`), precompilati con log di oggi ?? log sessione
  precedente ?? target;
  - bottone **"+ Serie"** (tratteggiato) aggiunge una riga extra;
  - bottone **"Salva"** (`.all-log-save`: full width, gradiente viola, uppercase
    0.88rem/800, radius 12; loading "Salvataggio..."; successo "Salvato!" verde per 2s,
    toast "Log salvato");
  - se esistono log di oggi: bottone **"Elimina log di oggi"** → conferma "Eliminare il
    log di oggi per questo esercizio?" → toast "Log eliminato".
- Superset: blocchi "Esercizio 1/2" con divider; Circuito: sommario
  `"<giri> giri · <n> esercizi · <rest>s pausa"` + blocchi "Esercizio i di N", header con
  matita → **popup Modifica circuito** (campi "Numero di giri", "Pausa fra giri (sec)",
  lista esercizi con input reps inline + ✕ rimuovi [min 2 esercizi: "Un circuito deve
  avere almeno 2 esercizi"], bottone "+ Aggiungi esercizio").

**Modal modifica esercizio** (`showEditExercise`, `.all-edit-overlay`): titolo "Modifica
esercizio", nome esercizio; campi: "Serie" (stepper −/+), "Ripetizioni" (testo, placeholder
"es. 10 o 8-12"), "Peso (kg)" (step 0.5, "Opzionale"), "Recupero (secondi)" ("es. 90");
cardio: solo "Durata (minuti)". "Note" textarea ("Aggiungi note..."). Bottoni
**"Salva modifiche"** / **"Annulla"**. Errore: alert "Errore nel salvataggio".

**Salvataggi resilienti**: ogni `saveLog`/`saveEditExercise` viene accodato in
`localStorage.pt_pending_workout_ops` PRIMA dell'invio (op idempotenti: upsert per
`exercise_id,user_id,log_date,set_number`; update per id). `flushPendingWorkoutOps()`
al boot / online / resume. Se l'app va in background durante il save (traccia
`_bgGeneration`), nessun errore mostrato: al ritorno la pagina fa `location.reload()` e
il flush completa. Watchdog 20s sblocca bottoni rimasti su "Salvataggio...".

### 8.5 FAB e aggiunta esercizi

FAB (`.all-fab`): cerchio 56px viola fisso bottom-right (visibile solo in vista Scheda),
icona +. Comportamento (`fabAction`):
- nessuna scheda → **modal "Nuova scheda"** (`#createPlanModal`, box radius 18 max-width
  400): campi "Nome scheda" (placeholder "Es. Scheda Forza, Upper/Lower...", max 100) e
  "Note (opzionale)" ("Obiettivi, indicazioni..."); bottone **"Crea scheda"** (loading
  "Creazione..."); errori: toast "Inserisci un nome per la scheda" / "Errore creazione:
  <msg>"; successo: toast "Scheda creata!".
- scheda esistente → **FAB sheet** (bottom sheet, titolo "Aggiungi al <giorno>"):
  3 opzioni con icona 40px gradiente:
  1. `+` viola — **"Esercizio singolo"** / "Aggiungi un esercizio con riposo";
  2. `SS` ambra (`#f59e0b→#f97316`) — **"Super Serie"** / "Due esercizi senza pausa tra loro";
  3. `C` cyan (`#06b6d4→#0891b2`) — **"Circuito"** / "Più esercizi in serie, ripetuti a giri".

**Picker esercizi** (`openExercisePicker`, fullscreen): topbar "Aggiungi esercizio —
<giorno>" + X; ricerca "Cerca esercizio..."; griglia categorie (chip con icona SVG muscolo
`images/icone_muscoli/<slug>.svg`, nome e conteggio; categorie del catalogo:
Petto, Tricipiti, Bicipiti, Spalle, Schiena, Quadricipiti, Glutei e Femorali, Femorali,
Polpacci, Addominali, Avambracci, Cardio, ecc.); lista risultati (max 50 mostrati, poi
"N altri — affina la ricerca") con thumbnail, nome it, categoria e ▶ (apre scheda
dettaglio con video). Footer: bottone **"✏️ Personalizzato"** → prompt "Nome esercizio
personalizzato:".
Catalogo: tabella `imported_exercises` (`nome_it, nome_original, nome_en, categoria, slug,
immagine, immagine_thumbnail, video, popolarita`), caricata una volta per sessione.
Il tasto Indietro chiude il picker (history.pushState).

**Flusso esercizio singolo**: prompt sequenziali (dialoghi §16.2, numeric):
"Numero di serie:" (default 3, conferma "Avanti") → "Numero di ripetizioni:" (10,
"Avanti") → "Riposo tra le serie (secondi):" (90, "Aggiungi"). Cardio: nessun prompt
(sets=1, reps='20', rest=0). Insert con `sort_order` in coda → toast "Esercizio aggiunto!".

**Flusso Super Serie**: titolo picker "Super Serie — Esercizio 1 di 2" → per ogni
esercizio prompt "Numero di ripetizioni:"; dopo il secondo: "Numero di serie (per
entrambi):" e "Riposo dopo la super serie (secondi):". Il primo esercizio ha
`rest_seconds=0`, il secondo il riposo; condividono `superset_group` (UUID) →
toast "Super Serie aggiunta!".

**Flusso Circuito**: titolo "Circuito — Esercizio N"; per ogni esercizio prompt reps
("Ripetizioni per \"<nome>\":" / cardio "Durata esercizio cardio (minuti):"); toolbar con
chip `"1. <nome> × <reps>"` e bottone **"Concludi circuito"** (visibile da 2 esercizi;
sotto: "Aggiungi almeno 2 esercizi al circuito"); alla fine: "Numero di giri del
circuito:" e "Riposo tra un giro e l'altro (secondi):". Tutti condividono
`circuit_group`; stesso `sets` (giri); solo l'ultimo ha `rest_seconds` →
toast "Circuito aggiunto!".

### 8.6 Vista STORICO (`renderStorico`, raggiungibile solo da Progressi)

Header: bottone **"← Torna ai Progressi"**; ricerca "Cerca esercizio...".
Lista card per **nome esercizio** (raggruppamento per `exercise_slug`, fallback nome
normalizzato — i log restano uniti dopo un rename): thumbnail 44px, nome, meta
`"N log · M sessione/i"`, chevron ›/▾ espandibile.
Espansa: sessioni per data (desc) — header data + bottone cestino "Elimina giornata"
(conferma "Eliminare tutti i set del <d MMM>?" → toast "Giornata eliminata"); griglia
`Set | Reps | Kg | Riposo` (cardio: `Set | Min`) con input EDITABILI per riga + bottone
check (salva riga: update `workout_logs` per id → toast "Modifica salvata") + bottone ✕
(elimina set: conferma "Eliminare questo set?" → toast "Set eliminato").
Empty: "Nessun esercizio nelle tue schede." / "Nessun log registrato ancora." /
"Nessun risultato." Errore: "Errore caricamento storico."

### 8.7 Vista PROGRESSI (`renderProgressi`)

Dati: tutti i log dell'utente su tutti i piani (paginati), raggruppati per slug/nome.
Valore sessione = max `weight_done` del giorno (cardio: max `reps_done`, unità "min").

**Desktop**: bottone **"📂 Vedi Storico allenamenti →"**; barra filtri con 2 select:
periodo ("Tutto", "Ultimi 7 giorni", "Ultimi 30 giorni", "Ultimi 90 giorni") e muscolo
("Tutti i muscoli" + gruppi dal catalogo). Riga 3 stat card (`.all-stat-card`):
**Sessioni** / **Serie totali** / **Volume totale** (kg; ≥1000 → "X.Xt").
Poi una card per esercizio: nome + "Target: <sets>×<reps>[ · <kg>kg]", grafico linea
canvas 320×140 (`drawDarkLineChart`: bg `#f8fafc` radius 10, griglia tratteggiata
`#e2e8f0`, area gradiente, linea 2.5px `#8B5CF6`, punti bianchi bordati, ultimo punto
pieno con badge navy `#0f172a` "NNkg"), footer:
`Max <v><unit> · Ultimo <v><unit> · Trend <±v.v><unit> · N sessioni`
(trend verde `.all-trend-up` / rosso `.all-trend-down`).
In fondo: card "Volume Totale per Sessione" (linea verde `#22c55e`).
Empty filtri: "Nessun risultato per i filtri selezionati."

**Mobile v2** (`_renderProgressiMobileV2`, ≤768px): hero scura con:
- bottone eyebrow **"PROGRESSI[ · ULTIMI 7 GG|ULTIMI 30 GG|ULTIMI 3 MESI|TUTTO]"** +
  chevron → bottom sheet "Periodo" (Tutto / Ultimi 7 giorni / Ultimi 30 giorni /
  Ultimi 3 mesi); default periodo = 30d;
- icona storia → Storico;
- 4 KPI: **Allenamenti** (giorni distinti con prenotazioni passate confermate),
  **Sessioni**, **Serie**, **Volume**.
Sezione **"Esercizi"** con conteggio; card per esercizio (`.prog2-ex`): titolo + target
("Target 3×10 · 20kg"), badge "N sess", corpo con immagine (bottone zoom ⤢) + mini
grafico SVG sparkline (area gradiente viola, dot primi/ultimi) + badge ultimo valore;
footer Max/Ultimo/Trend. FAB filtro muscolo in basso (pill "🔽 <Tutto|muscolo>") → bottom
sheet "Filtra per muscolo". Zoom → modal con video/immagine + grafico grande + footer stat.
Empty: "Nessun esercizio registrati|negli ultimi 7 giorni|…" (+ variante per muscolo:
`Nessun esercizio per "<muscolo>" <periodo>.`).

### 8.8 Vista TABLET (`renderTabletQR`)

Card centrata: titolo **"Il tuo QR per il Tablet"**, canvas QR 220×220 (lib
`qrcode-generator@1.4.4` CDN, error level M, moduli navy `#0f172a` su bianco; fallback
testo "QR non disponibile / Copia il link qui sotto"), nome utente, bottoni
**"Scarica"** (download PNG `qr-allenamento.png`) e **"Copia link"** (clipboard → toast
"Link copiato!"; fallback prompt "Copia questo link:"). Hint: "Scansiona dal tablet in
palestra. Resta valido anche se cambi scheda."
URL codificato: `<origin>/tablet.html?uid=<user.id>`.

### 8.9 Vista PDF (`renderPdfDownload`)

Body bloccato (no scroll). Header **"Anteprima Scheda"** + hint "scorri →" (autohide 6s).
Scroller orizzontale di pagine renderizzate con **PDF.js 3.11.174** (CDN) + dots
indicatori. Tap su pagina → lightbox zoom (pinch 1–5×, doppio tap 2.5×/reset, wheel,
hint "Pizzica per ingrandire · doppio tap per reset", chiudi ✕/Escape).
FAB in basso **"Scarica PDF"** (icona download; loading "Generazione…").
**Generazione** (`_buildSchedaPDF`, jsPDF 2.5.2 + autotable 3.8.4, A4 portrait, margini
14mm, cache per firma scheda):
- palette PDF: accent `[139,92,246]`, navy `[15,23,42]`, gray `[100,116,139]`,
  light-gray `[226,232,240]`;
- header: nome scheda (20pt bold navy), nome utente, "Data: ____/____/________",
  linea viola 1mm, note scheda in corsivo;
- per giorno: barra viola arrotondata con NOME GIORNO uppercase bianco 13pt;
- per esercizio: badge numerato circolare viola, thumbnail 16mm (via edge
  `image-proxy?url=` per CORS), nome bold 11pt, target 9pt, gruppo muscolare 8pt, note
  corsive, tabella `Serie|Reps|Kg|Riposo|Fatto ✓` con N righe + 1 vuota (cardio:
  `Minuti|Fatto ✓`), header tabella navy, righe alternate `#f8fafc`;
- superset: barra accent + "SUPER SERIE" + nomi + target combinati, esercizi A./B. con
  separatori tratteggiati; circuito: "CIRCUITO" + `"<giri> giri[ · <rest>s pausa finale]"`;
  page-break intelligente (il blocco resta sulla stessa pagina);
- footer ogni pagina: "PalestrIA" + "i / N";
- filename: `scheda-<nome-slugificato>.pdf`.
Salvataggio: iOS/PWA standalone → Web Share API con File (toast "PDF pronto per la
condivisione") o apertura blob (toast "PDF aperto"); desktop → `doc.save()` (toast
"PDF scaricato!"). Annullo share → toast info "Operazione annullata".

### 8.10 Lifecycle allenamento

- Boot `_initAllenamento`: `initAuth` → guard → `_syncAllViewUI` → `_refreshAllenamentoData`
  (carica in parallelo: `workout_plans` con `workout_exercises(*)` per l'utente ordinati
  per active/updated_at, prossime 20 prenotazioni confermate `date,time,slot_type`,
  date prenotazioni passate confermate max 2000). Scheda corrente = precedente ?? attiva ??
  prima. Poi `_loadLogsForPlan` (tutti i `workout_logs` degli esercizi del piano, paginati).
- Resume da background: se c'era un salvataggio in corso o background ≥2s →
  `location.reload()` (la coda pending sopravvive).
- Heartbeat 90s: verifica sessione (refresh o reload) e refresh dati se fermi >5 min.
- `online` → flush coda + refresh. bfcache `pageshow persisted` → re-init completo
  (se nessun overlay aperto/input focus).

---

## 9. Report AI mensile

Vista "Report" di allenamento.html (`allenamento-report.js`). Feature self-service per il
**mese precedente** (l'unico generabile). Max **3 generazioni/mese** (una per tono).

### 9.1 UI (`renderReport` → container `#allContent`)

- Loading "Caricamento report...". Non loggato: "Devi essere loggato per vedere i report."
- **Hero card** (`.all-report-hero`): eyebrow "Report mensile", mese grande (es.
  "Giugno 2026"), sub "Scegli un tono e genera il report del mese. Ogni tono può essere
  usato una sola volta.", riga quota: "Generazioni" + barra riempimento + **"R / 3"**
  (R = rimanenti).
- Sezione **"Tono del mese"**: griglia 3 card tono:
  - 🎯 **"Serio"** — "Analitico e professionale"
  - 💪 **"Motivazionale"** — "Caloroso ed energico"
  - 😏 **"Ironico"** — "Umorismo dry"
  Se già generato: card in stato "done" con desc "✓ Generato — apri" (tap apre il
  dettaglio); altrimenti tap → genera.
  Se tutti generati: "Hai usato tutti e 3 i toni per <Mese Anno>."
- **"Archivio"**: gruppi per mese (label "Giugno 2026"), righe-bottone per report:
  icona tono + label + data generazione (it-IT) + freccia → dettaglio.
  Empty: "Non hai ancora report generati. Scegli un tono qui sopra per generare il primo."

### 9.2 Flusso generazione

1. `_generateTone(yearMonth, tone)`: legge `profiles.report_ai_consent`; se manca →
   **modal consenso GDPR**: titolo "Consenso al trattamento AI"; intro "Per generare il
   report di <Mese>, l'app analizza i tuoi dati tramite intelligenza artificiale.";
   dettagli: "Dati analizzati:" lista (Prenotazioni…, Log di allenamento…),
   "Provider AI: Anthropic (Claude). Nessun altro terzo riceve i tuoi dati.",
   "Conservazione: il report resta nel tuo profilo. Puoi cancellarlo o revocare il
   consenso in qualsiasi momento."; checkbox "Acconsento al trattamento AI dei miei dati
   per generare i report mensili."; bottoni "Annulla" / "Accetta e continua"
   (senza spunta → alert "Devi spuntare la casella per procedere."). Consenso → RPC
   **`set_report_ai_consent({ p_consent: true })`**.
2. Overlay loading: spinner + "Generazione in corso..." (o "Rigenerazione in corso...") +
   "Sto analizzando i tuoi dati e scrivendo il report."
3. POST all'edge function **`generate-monthly-report`**
   (`https://<project>.supabase.co/functions/v1/generate-monthly-report`), headers
   `Authorization: Bearer <access_token>`, body
   `{ user_id, year_month:"YYYY-MM", tone, force_regenerate:true }`.
4. Errori: `code==='REGEN_LIMIT_REACHED'` → alert "Hai raggiunto il limite di <limit>
   generazioni per questo mese. Non puoi rigenerare ulteriormente."; altrimenti
   "Errore nella generazione:\n<msg>".
5. Successo: ricarica lista e apre il dettaglio (`report_id`).

### 9.3 Dettaglio report

Modal (`.all-report-modal-box`): meta (mese + chip tono con icona), corpo = `narrative`
markdown convertito in HTML **safe** (supporta `#`/`##`/`###` → h2/h3/h4, `**bold**`,
`*italic*`, paragrafi; tutto pre-escaped).
Dati letti da `monthly_reports` (`id, user_id, year_month, tone, narrative, scorecard,
cost_usd, generated_at, model_used, status`) filtrati `user_id = me AND
status='generated'`, ordine year_month desc.

---

## 10. Pagina: Crea il tuo studio (signup-trainer.html)

Pagina standalone (NO navbar/footer/style.css — stile inline). Onboarding SaaS trainer.
Body: gradiente `linear-gradient(135deg, #0f172a 0%, #1e1b4b 60%, #7C3AED 130%)`, flex
centrato.
**Card** bianca: radius 20px, padding 32px, max-width 460px, shadow
`0 24px 60px rgba(0,0,0,.35)`. Contenuto:
- eyebrow **"PalestrIA SaaS"** (uppercase 12px viola 700, letter-spacing .12em);
- h1 **"Crea il tuo studio"** (24px);
- sub "Inizia con **30 giorni di prova gratuita**. Nessuna carta richiesta ora."
  (`#64748b` 14px);
- box trial (bg `#f5f3ff`, bordo `#ddd6fe`, radius 12, testo `#7C3AED` 13px):
  "✨ Prova gratuita 30 giorni · poi da €39,99/mese · disdici quando vuoi";
- form: "Nome dello studio / palestra" (placeholder "Es. Studio Fitness Rossi") con
  **slug preview live** sotto (12px viola 600): "Il tuo indirizzo: <slug>.palestria.app"
  — slugify: lowercase, senza accenti, `[^a-z0-9]+`→`-`, max 40 char;
  "Il tuo nome" ("Mario Rossi"); "Email" ("tu@esempio.it"); "Password"
  (minlength 8, "Almeno 8 caratteri"). Input: bordo `1.5px #e2e8f0` radius 12, focus viola.
- bottone full **"Crea studio e inizia la prova"** (gradiente viola, radius 12, 16px/700;
  loading "Creazione in corso…");
- messaggi `#msg`: err (bg `#fef2f2`, testo `#b91c1c`) / ok (bg `#f0fdf4`, `#15803d`);
- footer: "Hai già un account? **Accedi**" → login.html.

Flusso submit:
1. slug < 3 char → "Il nome dello studio è troppo corto."
2. `signUp` con `data:{ full_name, signup_type:'trainer' }` (il trigger NON crea profilo
   cliente); se "already registered" prosegue col login.
3. Se niente sessione → `signInWithPassword`; se credenziali errate → "Esiste già un
   account con questa email (password diversa). Accedi da login.html."; se conferma email
   richiesta → messaggio ok "Ti abbiamo inviato una email di conferma. Conferma
   l'indirizzo, poi accedi per completare la creazione dello studio." +
   `sessionStorage.pendingOrg = {name, slug}`.
4. RPC **`create_organization({ p_name, p_slug })`** (crea org + owner + seed settings +
   trial 30gg). Errori: `slug_taken` → "Questo nome studio è già in uso. Provane un
   altro."; `invalid_slug` → "Nome studio non valido (usa lettere e numeri)."; altro →
   "Errore nella creazione dello studio: <msg>".
5. `refreshSession()` (per il claim org_id) → msg "Studio creato! Ti stiamo portando alla
   dashboard…" → redirect `admin.html` dopo 800ms.

---

## 11. Branding per-org e OrgSettings

### 11.1 OrgSettings (`org-settings.js`)

Layer chiave-valore org-scoped su tabella `org_settings(org_id, key, value jsonb)`:
- **Load**: autenticato → `select key,value from org_settings where org_id=<me>`;
  anonimo → RPC **`get_public_org_settings({ p_org_slug })`** (whitelist pubblica,
  ritorna oggetto `{key: value}`).
- Cache: Map in memoria + localStorage namespaced `org_<orgId|slug|anon>_<key>`.
- API: `get/getBool/getNumber/getString(key, default)`, `set(key,value)` (RPC
  `upsert_org_setting`, admin-only), `onChange(cb)`, `timezone()` (default
  `Europe/Rome`), `currency()` (default `EUR`), `reset()` al logout (pulisce chiavi
  org_* e canale realtime).
- Realtime: canale `org_settings_<orgId>` (§1.4).

### 11.2 Chiavi branding e applicazione (`applyBranding`)

| Chiave | Effetto |
|---|---|
| `branding.studio_name` | testo di tutti gli `[data-org-name]` (hero home) — skip se `data-brand-locked="1"` |
| `branding.logo_url` | `src` di tutte le `img[data-org-logo]` (navbar, sidebar, login) |
| `branding.primary_color` | `--primary-purple` su `:root` + `--primary-purple-dark` = colore scurito del 10% + `<meta theme-color>` |
| `branding.favicon_url` | href del `<link rel=icon>` |
| `branding.pwa_name` | `document.title` + `apple-mobile-web-app-title` (fallback studio_name) |
| `branding.home_duration` | testo `[data-org-duration]` (es. "80 minuti") |
| `company.maps_url` | href `a[data-org-maps]` (validato: solo http/https) |
| `company.address` (jsonb `{via, citta, paese}`) | testo `[data-org-address]` = `"<via> — <citta|paese>"` |

Dopo l'applicazione salva uno **snapshot stabile** `localStorage._brandingSnapshot`
(`{name,color,colorDark,favicon,logo,title,maps,address,duration}`).

### 11.3 branding-boot.js (anti-flash)

Eseguito sincrono in `<head>`: legge `_brandingSnapshot` e applica SUBITO colori/favicon/
titolo su `:root`; per nome/indirizzo/durata inietta CSS `visibility:hidden` sugli
elementi finché non applica i valori a DOM pronto, poi `html[data-branded]` li rivela.
In Flutter: equivalente = cache locale del branding letta prima del primo frame.

---

## 12. Autenticazione, ruoli e navigazione dinamica

### 12.1 `normalizePhone(raw)` → E.164
1. rimuove spazi/`-()/.`; 2. `+…` → invariato; `00…` → `+…`;
3. `0…` (fisso IT) → `+39` + resto senza 0; 4. 9-10 cifre → `+39` + numero;
5. altrimenti invariato.

`normalizeComune(input)`: title-case italiano dei comuni (connettivi minuscoli:
di/del/della/…; prefissi apostrofo: dell'/nell'/… — es. "reggio nell'emilia" →
"Reggio nell'Emilia"). Applicato a `indirizzo_paese` in registrazione e update profilo.

`isAnagraficaComplete(user)`: true se whatsapp, codice_fiscale, indirizzo_via,
indirizzo_paese, indirizzo_cap sono tutti valorizzati.

### 12.2 Mappa errori auth (`_authError`)
"already registered" → "Email già registrata."; "Invalid login credentials" → "Email o
password errata."; "Email not confirmed" → "Controlla la tua email per confermare la
registrazione."; "Password should be at least" → "La password deve essere di almeno 6
caratteri."; "User not found" → "Email non trovata."; default: messaggio raw o
"Errore sconosciuto. Riprova."

### 12.3 `registerUser(name, email, whatsapp, password, codiceFiscale, indirizzo)`
1. RPC `is_whatsapp_taken({phone})` → errore se preso.
2. Slug org OBBLIGATORIO (altrimenti errore "Studio non identificato…").
3. `supabaseAuth.auth.signUp` con `options.data = { signup_type:'client',
   org_slug, full_name (title-case), whatsapp, codice_fiscale (upper),
   indirizzo_via, indirizzo_paese (normalizeComune), indirizzo_cap }` e
   `emailRedirectTo: <origin>/login.html`. Il trigger `handle_new_user` crea la riga
   `profiles` nella org giusta e collega le prenotazioni anonime pregresse.
4. Safety-net: se sessione già attiva → RPC `join_organization({p_org_slug})` idempotente.
5. `_trackLoginEvent(userId,'signup')` → insert fail-silent su `login_events`
   (device hash SHA-256 di ua|screen|timezone|language, platform, browser, is_pwa…).

### 12.4 `initAuth()` e `updateNavAuth()`
- `initAuth`: attende `INITIAL_SESSION` (timeout 6s → `ensureValidSession()`); con sessione
  esegue in parallelo `_loadProfile(userId)` (select su `profiles`: id, name, email,
  whatsapp, medical_cert_expiry, medical_cert_history, insurance_expiry,
  insurance_history, codice_fiscale, indirizzo_via/paese/cap, documento_firmato,
  privacy_prenotazioni, created_at → `window._currentUser`; auto-capitalizza il nome) e
  `_applyOrgContext` (§1.1). Registra listener persistente su `onAuthStateChange`
  (SIGNED_IN/TOKEN_REFRESHED → ricarica profilo; SIGNED_OUT spurio → tenta recovery della
  sessione prima di sloggare). Su `visibilitychange` (foreground) rivalida sessione e se
  in background ≥120s risincronizza i bookings.
- `ensureValidSession()`: gestione robusta refresh token (lettura diretta da
  localStorage `sb-<ref>-auth-token`, refresh manuale con timeout 12s, fail-closed con
  evento `auth:session-lost` → toast **"Sessione scaduta. Effettua di nuovo l'accesso."**
  + redirect a login dopo 1.5s).
- `updateNavAuth()`: se loggato nasconde "Accedi", mostra nome+Esci; inietta link
  **"Le mie prenotazioni"** (prima voce nav/sidebar, per i clienti) e
  **"Amministrazione"** (ultima, per admin); mostra la voce **"Allenamento"**
  (`#navAllenamento`) se admin, oppure per i clienti SOLO se hanno almeno una scheda
  attiva (count su `workout_plans` active=true); aggiunge "Esci" in sidebar.
- `logoutUser()`: pulizia completa per-tenant (cache bookings/users/workout, availability,
  stats, push, OrgSettings.reset, `_brandingSnapshot`) + `signOut({scope:'local'})` con
  timeout 3s → redirect `index.html`.

### 12.5 `getUserBookings()`
Filtra `BookingStorage.getAllBookings()`: match primario `b.userId === user.id`; fallback
email (case-insens.) con telefono coerente se presente. Esclude id `demo-*`.
"Passata" = data < oggi, oppure oggi con orario di fine ≤ adesso.
Ritorna `{upcoming (asc), past (desc)}`.

### 12.6 `updateUserProfile(currentEmail, updates, newPassword)`
- Campi mappati su `profiles`: name (title-case), whatsapp (check `is_whatsapp_taken` con
  exclude_user_id), email (solo se INVARIATA — il cambio email passa da
  `auth.updateUser({email})` con conferma → flag `emailPendingConfirmation`),
  codice_fiscale (upper), indirizzo_*, `medical_cert_expiry` (+ append a
  `medical_cert_history` `{scadenza, aggiornatoIl}`), `insurance_expiry` (+history),
  `privacy_prenotazioni`.
- Upsert su `profiles` con `id`, `name`, `email`, `org_id` sempre presenti.
- Password → `auth.updateUser({password})`. Poi `_loadProfile` per riallineare.

---

## 13. Data layer: RPC, tabelle, cache locali

### 13.1 `BookingStorage.syncFromSupabase({ownOnly, forceFull})`
- **Anonimo**: RPC **`get_availability_range({p_org_slug, p_from:oggi, p_to:+90gg})`**
  (cache dedup 60s) → righe `{date, time, slot_type, capacity, remaining,
  confirmed_count}`; indicizzate in `_availabilityByKey["date|time|type"]` e trasformate
  in "booking sintetici" (id `_avail_*`) per il rendering dei posti. Nessun dato personale.
- **Utente**: select `bookings` filtrata `user_id=me` (ownOnly) su finestra −60/+90 giorni
  + tutte le passate non pagate; PIÙ la stessa RPC availability per gli slot altrui.
- **Admin**: full list org con delta-sync (fingerprint count|max updated_at, snapshot
  persistito `gym_bookings_cache_v2:<key>:<identity>`, TTL 15 min).
- Mapping riga→oggetto: `id`(local_id), `_sbId`(uuid), `userId`, `date`, `time`,
  `slotType`, `dateDisplay`, `name`, `email`, `whatsapp`, `notes`, `status`
  (`confirmed|cancelled|cancellation_requested`), `paid`, `paymentMethod`, `paidAt`,
  `customPrice`, `createdAt`, `cancellationRequestedAt`, `cancelledAt`, ecc.

### 13.2 Capienza e posti residui (client, display-only)
- `getEffectiveCapacity(date,time,type)`: 0) valore server da availability cache;
  1) override puntuale (`schedule_overrides.capacity`, tipo coincidente, altrimenti 0);
  2) template settimana attivata; 3) `default_capacity` dello slot_type (fallback
  `SLOT_MAX_CAPACITY`).
- `getRemainingSpots`: capienza − confermati in cache (conta anche
  `cancellation_requested`); se non ci sono booking reali in cache usa `remaining` del
  server.

### 13.3 `getBookingPrice(booking)`
`customPrice` se valorizzato → `OrgSettings.get('billing_client.prices')[slotType]` →
`OrgSettings.getNumber('price.<slotType>')` → fallback legacy
`SLOT_PRICES = {personal-training:5, small-group:10, group-class:30, cleaning:0}`.

### 13.4 Config orari per-org (`loadOrgScheduleConfig`)
Carica `slot_types` (id, key, label, color, default_capacity, default_price, bookable,
is_active, sort_order), `time_slots_config` (start/end → etichette "HH:MM - HH:MM"),
`activated_weeks` (week_start → template_id), `weekly_template_slots` (template_id,
weekday 0-6, capacity, slot_type, fascia) → popola `_ORG_SLOT_TYPES`, `_ORG_TIME_SLOTS`,
`_ORG_TPL_WEEKLY`, `_ORG_ACTIVE_WEEKS`. Snapshot in
`localStorage._orgSchedSnap_<orgId>` + `_lastOrgId` (idratazione sincrona anti-flash).
Gli anonimi non leggono queste tabelle (RLS): per loro la verità è la RPC availability.

### 13.5 Storage impostazioni-cliente rilevanti
- `CertEditableStorage` (`gym_cert_scadenza_editable`, default **true**): il cliente può
  modificare la scadenza del certificato.
- `CertBookingStorage` (`gym_cert_block_expired` / `gym_cert_block_not_set`): blocchi
  prenotazione per certificato scaduto/non impostato (default false).
- `AssicBookingStorage`: analogo per l'assicurazione.
Questi flag sono sincronizzati dalle impostazioni org (arrivano via
`syncAppSettingsFromSupabase` → `org_settings`).

### 13.6 Workout
- `WorkoutPlanStorage`: `syncFromSupabase({adminMode:false})` → `workout_plans` +
  `workout_exercises(*)` propri e attivi (TTL rete 5 min, cache LS
  `workout_plans_cache_client_v1` TTL 30 min). CRUD: `createPlan`, `updatePlan`,
  `deletePlan`, `addExercise`, `addSuperset`, `addCircuit`, `updateExercise`,
  `deleteExercise`, `reorderExercises`. Campi esercizio: `plan_id, day_label,
  exercise_name, exercise_slug, muscle_group, sort_order, sets, reps (testo),
  weight_kg, rest_seconds, notes, superset_group, circuit_group`.
- `WorkoutLogStorage`: `logSet({exercise_id, user_id, log_date, set_number, reps_done,
  weight_done, rest_done, rpe, notes})` = **upsert** su unique
  `(exercise_id,user_id,log_date,set_number)`; `deleteLog(id)`; sync paginati.

---

## 14. Notifiche push

- `promptPushPermission()`: banner scuro custom (fixed bottom, bg `#1a1a1a`, radius 18px,
  max-width 400px) mostrato solo a utenti con ≥1 prenotazione, in PWA installata;
  gestisce iOS/standalone; se permesso già dato ri-registra la subscription in silenzio;
  se negato mostra banner esplicativo una sola volta (chiave
  `denied_banner_shown_push`).
- `registerPushSubscription()`: `pushManager.subscribe` con VAPID public key → salva su
  `push_subscriptions`.
- `notifyAdminBooking(booking)` / `notifyAdminCancellation(booking)` /
  `notifyAdminNewClient(name)`: POST alle edge functions `notify-admin-booking`,
  `notify-admin-cancellation`, `notify-admin-new-client` con Bearer token → push a tutti
  gli admin della org. Chiamate rispettivamente dopo prenotazione riuscita, annullo,
  nuova registrazione. Fail-silent.
- Notifica locale post-prenotazione: §5.3.

---

## 15. Popup "Nuovo cliente iscritto"

(`new-client-popup.js` — vive in **admin.html**, NON nelle pagine cliente; incluso qui per
completezza.) Solo mobile/PWA (standalone o viewport ≤768px) e solo admin
(`sessionStorage.adminAuth==='true'`). Quando un nuovo cliente completa TUTTA l'anagrafica,
all'admin appare un popup (overlay `rgba(0,0,0,0.55)`, card bianca radius 18, max-width
420px): icona "aggiungi contatto" in cerchio viola 12%, titolo **"Nuovo cliente
iscritto"** (o "N nuovi clienti iscritti"), sub "Aggiungilo alla rubrica" (o "Hai **N**
nuovi clienti da aggiungere"); per cliente: nome (1.05rem/800), telefono, bottone info ⓘ
(espande pannello: 👤 sesso e 🎂 età derivati dal codice fiscale, 📍 comune; fallback
"Dati non disponibili"), bottoni **"WhatsApp"** (verde `#25d366`, `wa.me/<cifre>`) e
**"Telefono"** (viola, `tel:`). Dedup per device+org via localStorage
(`palestria_newClientSeen_<orgId>`, baseline `palestria_newClientBaseline_<orgId>`).

---

## 16. Componenti condivisi

### 16.1 Toast (`showToast(message, type='error', duration=3500)`)
Container fixed bottom 24px centrato (max-width 420px). Toast: radius 12px, padding
`12px 18px`, testo bianco 0.9rem/500, icona (✓ success, ℹ info, ✕ error), fade+slide
0.25s, auto-dismiss, dismiss al tap. Colori: success `#06d6a0`, error `#ef4444`,
info `var(--primary-purple)`.

### 16.2 Dialoghi (`modals.js` — sostituiscono confirm/prompt/alert nativi)
Overlay `rgba(0,0,0,0.55)` + blur 2px, z-index 2147483000; box bianca radius 18px,
max-width 400px, padding `26px 22px 20px`, animazione pop
(`translateY(12px) scale(.96) → none`, cubic-bezier(.18,.89,.32,1.28)).
Icona circolare 54px in testa (info: viola 12%; warn: `#ea7b0a` 12%; danger: `#dc3545`
10%; success: `#22a05a` 12%). Titolo 1.12rem/800 centrato; messaggio 0.92rem `#5a6672`
(`white-space:pre-line`). Bottoni flex: ghost (bg `#f1f3f5` testo `#444`), primary
(viola `#8B5CF6`, hover `#7C3AED`), danger (`#dc3545`).
- `showConfirm({message, title?, confirmText?, cancelText?, danger?})` → Promise<bool>.
  Default: title "Conferma" (o "Conferma eliminazione" se il msg contiene
  elimin/rimuov → danger auto), conferma "Conferma"/"Elimina"/"Rimuovi", cancel "Annulla".
- `showPrompt(message, defaultValue, {numeric?, placeholder?, confirmText?})` →
  Promise<string|null>. Input radius 12, focus viola; Enter conferma, Escape annulla.
- `showAlert(message, {type: 'info'|'error'|'success'|'warn', title?})`.
  Titoli default: "Avviso" / "Errore" / "Fatto".

### 16.3 Loading bottoni (`setLoading(btn, isLoading, text='Caricamento...')`)
Disabilita il bottone, salva il contenuto originale, mostra spinner circolare 14px
(bordo bianco 40%, top bianco, spin 0.7s) + testo.

### 16.4 Grafici (`chart-mini.js` — `SimpleChart`)
Canvas 2x device ratio; `drawBarChart({labels, values, highlight}, {colors})`: barre
arrotondate (radius top 3px), asse Y a 5 step, colonna evidenziata per il periodo
corrente. Usato dal modal Allenamenti (§7.6).

---

## 17. Chiavi localStorage / sessionStorage

| Chiave | Contenuto |
|---|---|
| `_brandingSnapshot` | snapshot branding per boot anti-flash |
| `org_<orgId|slug>_<key>` | cache OrgSettings per-tenant |
| `_orgSchedSnap_<orgId>` / `_lastOrgId` | snapshot config orari org |
| `scheduleOverrides_<orgId|anon>` | override calendario per data |
| `gym_bookings_cache_v2:<own|all>:<identity>` | snapshot bookings (TTL 15 min) |
| `gym_stats` | contatori locali prenotazioni |
| `weeklyScheduleTemplate`, `scheduleVersion`, `gym_week_templates`, `gym_active_week_template` | template legacy (fallback anonimo) |
| `gym_cert_block_expired`, `gym_cert_block_not_set`, `gym_assic_block_*`, `gym_cert_scadenza_editable` | flag blocchi prenotazione |
| `pt_pending_workout_ops` | coda offline salvataggi workout |
| `workout_plans_cache_client_v1` | cache schede (TTL 30 min) |
| `new_client_notified` | dedup notifica nuovo iscritto |
| `dataLastCleared`, `dataClearedByUser` | marker clear remoto |
| `denied_banner_shown_push` | banner push negato già mostrato |
| sessionStorage `adminAuth` | 'true' se owner/admin |
| sessionStorage `allView` | vista attiva allenamento |
| sessionStorage `pendingOrg` | org in attesa post-conferma email trainer |

---

## 18. Riepilogo RPC ed Edge Functions

### RPC Supabase (schema public) usate dall'area cliente

| RPC | Parametri | Uso |
|---|---|---|
| `book_slot` | `p_org_slug, p_local_id, p_date, p_time, p_name, p_email, p_whatsapp, p_notes, p_date_display` (+`p_for_user_id` admin) | prenota (server-authoritative, advisory lock, billing gating). Ritorna `{success, booking_id, paid}` o `{success:false, error:'slot_full'|'too_late'|…}` |
| `cancel_booking` | `p_booking_id` | annullo diretto (+ conversione group→small) |
| `user_request_cancellation` | `p_booking_id` | richiesta annullamento (ultime 24h) |
| `get_slot_attendees` | `p_org_slug, p_date, p_time` | iscritti visibili → `table(name, slot_type)` |
| `get_availability_range` | `p_org_slug, p_from, p_to` | disponibilità aggregata per anonimi/utenti |
| `get_public_org_settings` | `p_org_slug` | settings pubblici (branding ecc.) |
| `upsert_org_setting` | `p_key, p_value` | scrittura settings (admin) |
| `join_organization` | `p_org_slug` | crea profilo cliente nella org (idempotente) |
| `create_organization` | `p_name, p_slug` | onboarding trainer |
| `is_whatsapp_taken` | `phone[, exclude_user_id]` | unicità numero |
| `set_report_ai_consent` | `p_consent` | consenso GDPR report AI |
| `admin_duplicate_plan` | `p_plan_id, p_new_user_id, p_new_name` | (admin) duplica scheda |

### Tabelle lette/scritte direttamente (via RLS)
`bookings` (read own / dup-check), `profiles` (read/upsert own),
`billing_settings`, `client_billing_profiles`, `client_memberships`, `client_packages`
(read own), `workout_plans`, `workout_exercises`, `workout_logs` (CRUD own),
`imported_exercises` (read catalogo), `monthly_reports` (read own),
`org_settings` (read org), `slot_types`, `time_slots_config`, `activated_weeks`,
`weekly_template_slots`, `schedule_overrides` (read org), `login_events` (insert),
`push_subscriptions` (upsert own), `org_members` (fallback ruolo).

### Edge Functions
`generate-monthly-report` (report AI), `notify-admin-booking`,
`notify-admin-cancellation`, `notify-admin-new-client` (push admin org),
`image-proxy?url=` (CORS per immagini esercizi nel PDF).

---

## Appendice — Note di migrazione Flutter

1. Le "pagine info" (regolamento, nutrizione, chi-sono, dove-sono, privacy, termini) sono
   statiche e fuori da questa spec ma linkate dalla navigazione: prevederle come schermate
   contenuto o webview.
2. Il web usa MPA + cache localStorage per la persistenza cross-pagina: in Flutter basta
   uno stato in-memory con persistenza (Hive/SharedPreferences) per branding, config
   orari, coda offline workout e snapshot bookings.
3. Tutti i testi sono hardcoded in italiano: centralizzarli in ARB/l10n mantenendo le
   stringhe esatte di questa spec.
4. La PWA gestisce manualmente refresh token/lock (ensureValidSession, heartbeat,
   watchdog): con supabase-flutter la gestione sessione è nativa, ma vanno mantenuti i
   punti funzionali: fail-closed → schermata login con messaggio "Sessione scaduta…",
   re-sync al foreground ≥2 min, flush coda offline.
