# Specifica completa — Area ADMIN di PalestrIA (web app → Flutter)

> **Scopo**: questo documento è la specifica **completa e autosufficiente** dell'area amministrativa della web app PalestrIA (`admin.html` + pannelli JS + CSS), scritta per permettere a uno sviluppatore Flutter di replicarla **1:1 graficamente e funzionalmente senza leggere il codice originale**.
>
> **Fonti** (lette integralmente alla data 2026-07-06, branch `saas-main`): `admin.html`; `js/admin.js`, `js/admin-clients.js`, `js/admin-schedule.js`, `js/admin-calendar.js`, `js/admin-registro.js`, `js/admin-payments.js`, `js/admin-analytics.js`, `js/admin-schede.js`, `js/admin-settings.js`, `js/admin-importa.js`, `js/admin-messaggi.js`, `js/admin-backup.js`, `js/admin-health.js`, `js/admin-desktop-sidebar.js`, `js/admin-mobile-filters.js`, `js/chart-mini.js`, `js/new-client-popup.js`, `js/entitlements.js`, `js/org-settings.js`; `css/admin.css` (+ parti rilevanti di `css/style.css`, `css/login.css`, `css/allenamento.css`); consultazione mirata di `js/data.js` e `js/auth.js` per RPC/storage layer.
>
> **Contesto architetturale**: PalestrIA è un SaaS multi-tenant (una `organization` per studio/trainer, isolamento via `org_id` + RLS su Postgres/Supabase). Il frontend è vanilla JS zero-build; tutti i dati passano da Supabase (Postgres + RPC + Realtime + Edge Functions) con un layer dual-cache in localStorage. La UI è **in italiano**. Nella migrazione Flutter: i testi UI vanno mantenuti identici, i colori sono specificati in hex esatti, i nomi di RPC/tabelle Supabase restano invariati (il backend non cambia).

## Indice

1. Struttura generale e navigazione (header, tab bar, sidebar desktop, filtri mobile, boot, gating ruoli)
2. Design system (palette, tipografia, componenti CSS riusabili)
3. Tab Prenotazioni (calendario admin)
4. Tab Gestione Orari
5. Tab Registro
6. Tab Clienti (card cliente — redesign viola)
7. Tab Pagamenti e billing-cliente
8. Tab Statistiche & Fatturato (Analytics)
9. Tab Schede (allenamento)
10. Importa (esercizi/dati)
11. Tab Messaggi
12. Tab Impostazioni (11 sotto-tab)
13. Backup

---

---

## 1. Struttura generale e navigazione

Questa sezione descrive la shell dell'area admin (`admin.html` + `js/admin.js` e moduli di navigazione), che il porting Flutter deve replicare: header, tab bar responsive a 3 layout (mobile ≤768px, tablet 769–1023px, desktop ≥1024px), boot sequence, gating ruoli/piano e tutti i modali globali.

**Breakpoint chiave** (identici in tutti i moduli):
- `max-width: 768px` → layout mobile (bottom dock + bottom sheets; tab bar orizzontale nascosta).
- `769px – 1023px` → layout tablet (tab bar orizzontale scrollabile).
- `min-width: 1024px` → layout desktop (sidebar verticale sinistra 240px + topbar; tab bar nascosta).

**Palette shell**: viola brand `#8B5CF6` (var `--primary-purple`), viola scuro `#7C3AED` (var `--primary-purple-dark`), sfondo scuro navbar `#1a1a1a` (var `--dark-bg`), grigi slate `#0f172a / #334155 / #475569 / #64748b / #94a3b8 / #cbd5e1 / #e2e8f0 / #f1f5f9 / #f8fafc`. I due viola sono **sovrascrivibili per-org a runtime** dal branding (vedi 1.1.2).

---

### 1.1 Header pagina (navbar)

#### 1.1.1 Markup e stile

`<nav class="navbar">` sticky (`position: sticky; top: 0; z-index: 1000`), sfondo `#1a1a1a` (`--dark-bg`), `padding: 1rem 0`, `box-shadow: 0 2px 10px rgba(0,0,0,0.3)`. Il `.container` interno è flex `justify-content: space-between; align-items: center`. Su admin (≥769px) il container della navbar è portato a **tutta larghezza** (`max-width: none; width: 100%; padding: 0 2rem` — override in `admin.css`), mentre sulle altre pagine resta centrato.

Contenuto sinistro `.nav-brand` (flex, gap `0.75rem`):
- `<a href="index.html">` con `<img src="images/logo-palestria-light.png" class="nav-logo" data-org-logo>` — logo altezza **48px**, `border-radius: 6px`.
- `<span class="adm-brand-org" data-org-name>` — **nome studio del tenant**, inline style: `color:#8B5CF6; font-size:0.85rem; font-weight:700; letter-spacing:1px; text-transform:uppercase`. CSS extra (`admin.css`): `word-spacing: 100vw` (ogni parola va a capo → una parola per riga), `line-height: 1.1`, e `:empty { display:none }` (collassa se il branding non è ancora arrivato).

Contenuto destro `.nav-right` (flex, gap `1rem`):
- `ul.nav-desktop-links` (visibile solo desktop): link testuali "Calendario" (index.html), "Regolamento", "Nutrizione", "Chi sono", "Dove sono", "Amministrazione" (admin.html, classe `nav-admin-link`). Stile link: `color: rgba(255,255,255,0.82)`, `font-size: 0.95rem`, `font-weight: 500`, `padding: 0.45rem 0.9rem`, `border-radius: 6px`; hover/active: `color: var(--primary-purple); background: rgba(139,92,246,0.1)`.
- `li#superAdminNavItem` (default `display:none`): link "👑 Super Admin" → `super-admin.html`, `color:#fbbf24`. Mostrato solo se la RPC Supabase **`is_platform_admin`** (senza parametri) ritorna `true` (chiamata nel boot inline, non blocca).
- `div#navLoginLink` con `<a href="login.html" class="nav-login-btn">Accedi</a>` — pillola viola: `background: var(--primary-purple)`, testo bianco, `padding: 0.25rem 0.65rem`, `border-radius: 20px`, `font-weight: 600`, `font-size: 0.8rem`. Visibile solo da sloggati.
- `div#navUserMenu` (default `display:none`, mostrato da loggati): `span#navUserName` (bianco, `0.9rem`, weight 600, sottolineato, `cursor:pointer`; click → naviga a `prenotazioni.html`) + `button#navLogoutBtn` con testo **"Esci"** — bordo `1.5px solid rgba(255,255,255,0.5)`, sfondo trasparente, bianco, `border-radius: 20px`, `font-size: 0.8rem`; hover `background: rgba(255,255,255,0.15)`. **Nascosto su ≤768px** (`display:none`; su mobile il logout sta nel drawer hamburger). Click → `logoutUser()` poi redirect a `index.html`.
- `button.nav-hamburger#navHamburger` (aria-label "Menu", SVG 3 righe 26×26 bianco): visibile solo <769px; click → `toggleNavMenu()` apre il drawer.

**Drawer hamburger mobile**: `.nav-sidebar-overlay#navSidebarOverlay` (fixed, `rgba(0,0,0,0.55)`, z-index 1500, click → chiude) + `nav.nav-sidebar#navSidebar` (drawer da destra, sfondo `--dark-bg`, z-index 1600, transizione `right 0.3s cubic-bezier(0.4,0,0.2,1)`, classe `.open`). Header con logo (`data-org-logo`) + bottone ✕. Link: "Calendario", "Allenamento" (`li#navAllenamento`, default nascosto — mostrato per gli admin, o per clienti con almeno una scheda attiva su `workout_plans`), "Nutrizione", "Regolamento", "Chi sono", "Dove sono", "Amministrazione", "👑 Super Admin" (`#superAdminNavItemMobile`, nascosto come sopra). Footer: `powered by <a href="https://andreapompili.com/">Andrea Pompili</a>`. Un bottone "Esci" (`.nav-sidebar-logout`) è iniettato in fondo da `_injectSidebarLogout()` (auth.js) per gli utenti loggati.

#### 1.1.2 Popolamento dinamico (auth + branding)

- **`updateNavAuth()`** (auth.js): se c'è utente o `sessionStorage.adminAuth==='true'` → nasconde `#navLoginLink`, mostra `#navUserMenu`; `#navUserName` = primo token di `name`/`email` dell'utente, oppure letterale **"PT"** se c'è solo il flag admin. Inietta dinamicamente (`data-nav-dynamic`) il link "Le mie prenotazioni" (prima voce, per utenti) e "Amministrazione" (ultima voce, per admin) in `.nav-desktop-links` e `.nav-sidebar-links`; mostra `#navAllenamento` per gli admin.
- **Branding per-org**: due layer.
  1. `js/branding-boot.js` (sincrono in `<head>`): legge lo snapshot `localStorage._brandingSnapshot` (chiave NON namespaced) e prima del paint applica: `--primary-purple`/`--primary-purple-dark` su `:root` (inline style), `meta theme-color`, favicon, `document.title` + `apple-mobile-web-app-title`; a DOM pronto scrive nome su `[data-org-name]`, logo su `img[data-org-logo]` (salvando `dataset.brandDefault`), indirizzo/durata/link maps; nasconde gli elementi via `visibility:hidden` finché non setta `html[data-branded]` (anti-flash).
  2. `OrgSettings.applyBranding()` (org-settings.js, async dopo `OrgSettings.load()`): legge le chiavi org `branding.studio_name`, `branding.logo_url`, `branding.primary_color`, `branding.favicon_url`, `branding.pwa_name` e riapplica i valori reali (derivando il colore dark con un darken −%); riscrive lo snapshot. Realtime sul canale `org_settings_<orgId>` (postgres_changes su tabella `org_settings` filtrata `org_id=eq.<orgId>`): se cambia una chiave `branding.*` riapplica al volo.

#### 1.1.3 Gate di accesso (overlay)

`div#adminGateOverlay`: `position:fixed; inset:0; z-index:2147483647; display:flex; align-items:center; justify-content:center; background:#ffffff; color:#8B5CF6; font-family:system-ui,-apple-system,sans-serif; font-size:0.95rem; font-weight:600; letter-spacing:0.5px`. Testo esatto: **"Verifica accesso…"**. Copre TUTTA la pagina finché il boot non conferma il ruolo admin; per i non-admin resta visibile durante il redirect così non trapela mai un lampo della dashboard (vedi 1.8).

---

### 1.2 Tab bar e `switchTab`

#### 1.2.1 Le 9 tab

Markup in `admin.html` (`div.admin-tabs`), etichette ESATTE (emoji inclusa) e `data-tab`:

| # | `data-tab` | Label esatta | Note |
|---|---|---|---|
| 1 | `bookings` | `📅 Prenotazioni` | tab di default, `class="admin-tab active"` |
| 2 | `payments` | `💳 Pagamenti` | |
| 3 | `analytics` | `📊 Statistiche & Fatturato` | |
| 4 | `schede` | `🏋🏻 Schede` | `id="adminTabSchede"`, **`data-feature="workout_plans"`** |
| 5 | `registro` | `📋 Registro` | |
| 6 | `clients` | `👤 Clienti` | |
| 7 | `schedule` | `⚙️ Gestione Orari` | |
| 8 | `messaggi` | `📩 Messaggi` | **`data-feature="messaging"`** |
| 9 | `settings` | `🔧 Impostazioni` | |

Decimo bottone (non è una sezione): `button.admin-tab.admin-tab--privacy#btnToggleSensitive`, testo `👁`, `title="Nascondi/mostra dati sensibili"`, `onclick="toggleSensitiveData()"` — toggle privacy (vedi sotto).

Ogni tab corrisponde a un pannello `div#tab-<nome>.tab-content` (`display:none`; `.active { display:block }`, animazione `fadeIn 0.3s ease` da `opacity:0`).

#### 1.2.2 Stile

`.admin-tabs`: `display:flex; gap:4px; padding:5px; flex-wrap:wrap; justify-content:center; position:sticky; top: var(--admin-tabs-top, 72px); z-index:13; background: linear-gradient(135deg, #f1f5f9, #e8ecf1); border:1px solid #e2e8f0; border-radius:14px; box-shadow: 0 1px 4px rgba(0,0,0,0.04), 0 4px 8px rgba(0,0,0,0.06); margin-bottom:1.5rem`.

`.admin-tab` (inattiva): `background:transparent; border:none; padding:0.6rem 1.1rem; font-size:0.95rem; font-weight:700; color:#64748b; border-radius:10px; white-space:nowrap; letter-spacing:0.01em; transition: all 0.25s cubic-bezier(0.4,0,0.2,1)`.
Hover: `color:#334155; background:rgba(255,255,255,0.7)`.
**Attiva**: `color:#fff; background:linear-gradient(135deg, #8B5CF6, #7C3AED); box-shadow: 0 2px 8px rgba(139,92,246,0.3)`.

`.admin-tab--privacy`: `margin-left:auto; font-size:0.75rem; opacity:0.55; color:#94a3b8`; hover opacità 1; **attiva** (dati nascosti): `background:linear-gradient(135deg, #f59e0b, #d97706); color:#fff; box-shadow:0 2px 8px rgba(245,158,11,0.3)`.

Responsive: su ≤768px la barra è scrollabile orizzontale (`flex-wrap:nowrap; overflow-x:auto; gap:3px; padding:4px; border-radius:12px`, scrollbar nascosta; tab `padding:0.5rem 0.75rem; font-size:0.75rem; border-radius:8px`) **ma è comunque `display:none !important`** perché sostituita dal dock mobile (1.4); di fatto la barra orizzontale è visibile **solo tra 769px e 1023px**. Su ≥1024px: `display:none !important` (sostituita dalla sidebar, 1.3).

#### 1.2.3 `switchTab(tabName)` — comportamento esatto (js/admin.js)

Firma: `function switchTab(tabName)` (globale). Passi:
1. **Remap retro-compatibile**: se `tabName === 'importa'` → `tabName = 'schede'` e flag interno `_schedeJumpToImporta = true` ("Importa" è oggi un sub-tab di Schede).
2. **Persistenza**: `sessionStorage.setItem('adminActiveTab', tabName)` (in try/catch).
3. Toglie `.active` da tutti i `.admin-tab` e la mette su quello con `dataset.tab === tabName`.
4. Aggiunge la classe `container--wide` al `.dashboard-section .container` (cap **1280px**; il default è `max-width:620px`) — così tutte le tab hanno la stessa larghezza della barra.
5. Toglie `.active` da tutti i `.tab-content` e la mette su `#tab-<tabName>`.
6. FAB: `#paymentsFab` → `display:'flex'` solo se `tabName === 'payments'`; `#scrollToSlotFab` → `display:'flex'` solo se `tabName === 'bookings'`; altrimenti `none`.
7. Scroll top: `window.scrollTo({top:0})` **e** `document.body.scrollTo({top:0})` (dual-mode shell iOS: su iOS standalone il body è lo scroller).
8. **Lazy-load asincrono del pannello** via `setTimeout(loader, 0)` (il browser renderizza prima il cambio tab, poi esegue il lavoro pesante). Mappa loader:
   - `analytics` → `requestAnimationFrame(() => requestAnimationFrame(() => loadDashboardData()))` (doppio rAF)
   - `bookings` → `renderAdminCalendar()`
   - `payments` → `renderPaymentsTab('switchTab')`
   - `clients` → `renderClientsTab()`
   - `schedule` → `renderScheduleManager()`
   - `settings` → `renderSettingsTab()`
   - `registro` → `renderRegistroTab()`
   - `messaggi` → `renderMessaggiTab()`
   - `schede` → `renderSchedeTab()`, oppure `_schedeSwitchSection('importa')` se veniva da 'importa'.

`setupTabs()` aggancia un click-listener a ogni `.admin-tab` che chiama `switchTab(tab.dataset.tab)`. NON usa hash URL: la persistenza è solo `sessionStorage`.

#### 1.2.4 Anti-flash del tab al refresh

Script inline nel `<head>` (prima del CSS del body): legge `sessionStorage.adminActiveTab`; se vale `'importa'` lo migra a `'schede'` e setta `sessionStorage.adminSchedeSection='importa'`; se esiste ed è ≠ `'bookings'` setta l'attributo **`data-initial-tab`** su `<html>`. Regole CSS dedicate (admin.css) fintanto che l'attributo esiste: nascondono `#tab-bookings.active`, mostrano (`display:block`) il pannello salvato (`html[data-initial-tab="payments"] #tab-payments`, ecc. per payments/analytics/schede/importa→schede/registro/clients/schedule/messaggi/settings), spengono lo stile attivo del bottone bookings (`color:#64748b; background:transparent; box-shadow:none`) e accendono quello del bottone salvato (stesso gradient viola dell'attiva). `showDashboard()` poi chiama `switchTab(savedTab)` e **rimuove `data-initial-tab`** da `<html>`.

#### 1.2.5 Sticky offsets e privacy mask (js/admin.js)

- `setupAdminStickyOffsets()`: calcola `navbar.offsetHeight - 1` e lo assegna a `tabs.style.top`; su >768px imposta anche `top` di `.admin-calendar-controls` (= navbar+tabs) e `.admin-day-selector` (= navbar+tabs+controls). Ricalcola su `resize`. Su scroll (agganciato sia a `window` che a `document.body`, `sy = window.scrollY || document.body.scrollTop`): oltre 120px aggiunge `.scroll-hidden` a `.admin-calendar-controls` (nasconde la week-nav) e rialza il day-selector; sotto 10px la rimostra.
- **Privacy toggle**: `SENSITIVE_IDS = ['totalUnpaid','totalDebtors','totalCreditors','totalCreditAmount','monthlyRevenue','revenueChange']`. Stato in `localStorage.adminSensitiveHidden` (`'true'`/`'false'`). `toggleSensitiveData()` inverte lo stato e chiama `_applyPrivacyMask()`: ogni id mascherato mostra `'***'` (valore reale salvato in `dataset.realValue`); le liste `#debtorsList` e `#creditsList` vengono nascoste del tutto; il bottone `#btnToggleSensitive` mostra `🙈` quando nascosto, `👁` quando visibile. `sensitiveSet(id, value)` è l'helper usato dai moduli per scrivere valori rispettando la maschera.

---

### 1.3 Sidebar desktop + topbar + date popover (js/admin-desktop-sidebar.js, ≥1024px)

Attivo con `matchMedia('(min-width: 1024px)')`. Su desktop `.dashboard-section` diventa `display:flex; align-items:flex-start; min-height:calc(100vh - 80px)`; il `.container` principale: `flex:1 1 auto; max-width:1400px; padding:1.5rem 2rem 2rem`. `.admin-tabs` e `.analytics-filter-bar` sono `display:none !important`.

**Sidebar** — markup statico in admin.html: `aside.adm-sidebar#admSidebar` (aria-label "Amministrazione") con `.adm-side-head` testo **"Amministrazione"** e `ul#admSideList` popolata da JS. `buildSidebar()` genera le voci dall'array costante `SECTIONS` (ordine e label esatte):
`bookings "Prenotazioni"`, `payments "Pagamenti"`, `analytics "Statistiche & Fatturato"`, `schede "Schede"`, `registro "Registro"`, `clients "Clienti"`, `schedule "Gestione Orari"` (group 1), poi **divider**, `messaggi "Messaggi"`, `settings "Impostazioni"` (group 2). Le icone sono SVG inline stile Lucide (16×16, `stroke-width:2`): calendario, carta di credito, bar-chart, manubrio, libro, utenti, orologio, message-bubble, ingranaggio. Ogni voce: `<button class="adm-side-item" data-page="<id>" aria-current="page|false">` con `<span class="adm-side-item-label">`. Dopo un ulteriore divider c'è la voce azione **"Dati sensibili"** (icona occhio, `data-action="privacy"`, `aria-pressed`) che fa da proxy: `click()` sul bottone `#btnToggleSensitive`.

Click su una voce = `document.querySelector('.admin-tab[data-tab="<page>"]').click()` → passa SEMPRE da `switchTab` (unica fonte di verità). `updateSidebarActive()` sincronizza `.is-active`/`aria-current` leggendo il tab `.active`; è invocata sia dai click sia da un **MutationObserver** sugli attributi `class` dei tab (copre gli switch programmatici).

Stili sidebar: `flex: 0 0 240px; position:sticky; top:72px; max-height:calc(100vh - 72px); overflow-y:auto; background:#fff; border-right:1px solid #e2e8f0; padding:1rem 0.5rem 1.25rem; z-index:10`. Head: `font-size:0.7rem; font-weight:700; letter-spacing:0.08em; uppercase; color:#94a3b8`. Item: `min-height:36px; padding:0.55rem 0.65rem; border-radius:8px; font-size:0.82rem; font-weight:600; color:#334155; gap:0.6rem` (icona `#64748b`); hover `background:#f8fafc; color:#0f172a`; **attivo** `background:rgba(139,92,246,0.08); color:#7C3AED` (icona inclusa). Divider `1px #e2e8f0`. Voce privacy premuta (`.is-pressed`): `background:rgba(245,158,11,0.1); color:#b45309`. **Non esiste collapse/espansione**: la sidebar è fissa a 240px.

**Topbar** — `header.adm-topbar#admTopbar` (in admin.html) contiene solo `.adm-topbar-right` con due bottoni entrambi `hidden` di default: `#admTopbarExport` (icona download + testo **"Esporta"**, ghost) e `#admTopbarDateBtn` (icona calendario + `span#admTopbarDateLabel` default **"Questo mese"** + chevron; `aria-haspopup="dialog"`). Stile bottoni: `padding:0.5rem 0.75rem; border:1px solid #e2e8f0; border-radius:10px; background:#fff; color:#0f172a; font-size:0.82rem; font-weight:700`; hover `border-color:#8B5CF6; color:#7C3AED`. La topbar si auto-nasconde quando nessun bottone è visibile: `.adm-topbar:not(:has(.adm-topbar-btn:not([hidden]))) { display:none }`. `updateTopbar()` dovrebbe mostrare Export+Date **solo sul tab `analytics`** e settare il titolo di sezione; ⚠️ **nota fedele al codice attuale**: la funzione fa `getElementById('admTopbarTitle')` come guard e **quell'elemento non esiste in admin.html** → la funzione ritorna subito, quindi allo stato attuale i due bottoni topbar restano `hidden` e la topbar non compare (dead code di fatto; in Flutter si può decidere se ripristinare l'intento — titolo sezione + Esporta/Periodo su Statistiche — o ometterla).
- Export: click → `window.downloadFiscalReport()` (admin-analytics.js).
- Date button: apre il **date popover** `#admDatepop` (backdrop trasparente `#admDatepopBackdrop`, z-index 1098/1099): dialog fixed largo **340px** (max `calc(100vw - 2rem)`), posizionato sotto il bottone allineato a destra (gap 8px, clamp ai bordi 16px), `border-radius:12px; border:1px solid #e2e8f0; box-shadow:0 10px 30px -8px rgba(15,23,42,0.2)`, fade+translateY 0.18s. Titolo "Periodo" (uppercase 0.72rem `#64748b`). `renderPresets()` clona come pillole i bottoni originali `.analytics-filter-bar .filter-btn` (proxy `click()`; se il preset non contiene "personal" chiude dopo 120ms). Label "Range personalizzato", due `input date` `#admDatepopFrom/#admDatepopTo` sincronizzati con `#filterDateFrom/#filterDateTo`, bottone **"Applica"** full-width viola → copia i valori negli input originali e chiama `window.applyCustomFilter()`. Pillola preset attiva: gradient viola + `border-color:#7C3AED`. Chiusura: click backdrop, `Escape`, cambio breakpoint; riposizionamento su resize/scroll.

---

### 1.4 Mobile: bottom dock + filtri contestuali (js/admin-mobile-filters.js, ≤768px)

Attivo con `matchMedia('(max-width: 768px)')`. Su mobile spariscono (`display:none !important`): `.admin-tabs`, `.analytics-filter-bar`, `.clients-filter-toggle`, `.clients-filter-chips`, le righe filtri del Registro e le righe filtri di Notifiche admin/clienti. **I controlli originali restano nel DOM** (nascosti) e vengono pilotati via proxy (`click()` / set `value` + `dispatchEvent`), così la logica di business non è duplicata.

**Bottom stack** `#admBottomStack`: contenitore `position:fixed; left/right/bottom:0; z-index:1090; padding:18px 12px calc(12px + env(safe-area-inset-bottom))`, colonna con gap 10px, gradient di fade verso il basso (`rgba(248,250,252,0) → 0.92 al 35% → 1`), `pointer-events:none` (riattivati sui figli). Contiene, dall'alto:

1. **Pill filtri** `#admMbar` → `button#admMbarFilter` (allineato a destra): `span#admMbarFilterIco` (emoji), `span#admMbarFilterLabel` (testo), chevron CSS. Stile: pillola `border-radius:999px; background:#fff; border:1px solid #e2e8f0; min-height:40px; font-size:0.84rem; font-weight:700; box-shadow: 0 4px 12px -4px rgba(15,23,42,0.12), 0 1px 2px rgba(15,23,42,0.06)`; con filtri attivi (classe `.has-active`): `border-color:#8B5CF6; color:#7C3AED; background:rgba(139,92,246,0.08)`. La riga si nasconde se il bottone è `hidden`.
2. **Dock viola** `#admDock` → `button#admMbarPage`: `min-height:60px; border-radius:16px; background:linear-gradient(180deg, #8B5CF6 0%, #7C3AED 100%); color:#fff`, box-shadow viola multiplo + inset highlight; dentro: box icona 38×38 (`rgba(255,255,255,0.20)`, radius 10) con `span#admMbarPageIco` (emoji, default `📅`), eyebrow **"Sezione"** (`0.62rem`, uppercase, `rgba(255,255,255,0.78)`) e `span#admMbarPageLabel` (nome sezione, default **"Prenotazioni"**, `0.98rem` weight 800), chevron ▲.

Spaziatura contenuto: `#dashboardSection { padding-bottom: calc(100px + safe-area) }`, che sale a **150px** quando la pill filtri è visibile (`body:has(#admMbarFilter:not([hidden]))`). I FAB (`.scroll-slot-fab`, `.payments-fab`, `.schede-fab`) stanno a `bottom: 84px` (134px con pill) + safe-area. Quando un bottom sheet è aperto (`body.adm-sheet-open`) l'intero stack è nascosto e il body ha `overflow:hidden`.

**Bottom sheet "Vai a"** (`#admPagesSheet` + backdrop `#admPagesBackdrop`) — page switcher. `renderPagesSheet()`: titolo **"Vai a"**, una voce per ogni `.admin-tab[data-tab]` (escluso `.admin-tab--privacy`). L'emoji è estratta dal testo del tab con `splitEmojiLabel()` (regex Unicode `\p{Extended_Pictographic}` + modificatori; fallback icona `▫️`) e la label è il resto (es. `📅` + "Prenotazioni"). Ogni voce: box icona 36×36 (`#f1f5f9`, radius 10), titolo `0.95rem` weight 700, indicatore radio 22px a destra (bordo `#cbd5e1`; attivo: riempito `#8B5CF6` con puntino bianco 8px). Voce attiva: `background:rgba(139,92,246,0.08); border-color:rgba(139,92,246,0.25)`, icona su gradient viola. In fondo, separata da bordo, voce azione **"Dati sensibili"** con icona `👁` e meta dinamica: `"Nascosti — tocca per mostrare"` oppure `"Visibili — tocca per nascondere"` (proxy click su `#btnToggleSensitive`). Click su una voce: proxy `click()` sul tab → `switchTab`, feedback `.is-active`, chiusura dopo 150ms.

**Bottom sheet "Filtri"** (`#admFiltersSheet` + `#admFiltersBackdrop`) — contestuale al tab. Config `FILTER_CONFIG`: solo **clients** (icona `🔍`, label "Filtri"), **analytics** (icona `📅`, label "Periodo"), **registro** (icona `🔍`, label "Filtri") hanno filtri; per bookings/payments/schedule/settings/messaggi/schede la pill è `hidden`. `updateFilterButton()` aggiorna icona/label (per analytics la label diventa il periodo attivo, es. "Questo mese", con l'eventuale `📅 ` iniziale rimosso) e la classe `.has-active` (analytics: preset ≠ default; clients: `countActiveClientFilters()` = numero di `.clients-filter-chip.active`; registro: `countActiveRegistroFilters()` = pills tipo-evento attive + select slot/metodo/stato ≠ `all` + search non vuota + range ≠ `all`).

`renderFiltersSheet()` imposta il titolo (**"Periodo"** per analytics, **"Filtri clienti"**, **"Filtri registro"**, default "Filtri"; se il tab non ha filtri: `<p class="adm-filt-empty">Nessun filtro disponibile.</p>`) e costruisce il corpo:
- **Analytics**: gruppo "Periodo" con pillole proxy dei `.filter-btn` originali (chiusura auto se non "Personalizzato"); gruppo "Range personalizzato" con `#admAnalyticsFrom/To` sincronizzati con `#filterDateFrom/To`. Applica → copia date + `applyCustomFilter()`; Reset → click sul primo preset ("Questo mese").
- **Clients**: gruppo "Mostra solo clienti" con pillole proxy delle chip originali (testi: `🏥 Senza certificato`, `📋 Senza assicurazione`, `📝 Senza anagrafica`, `🔒 Anonimi`, `🔕 Notifiche Disattivate`); `syncClientsPills()` risincronizza dopo ogni click (alcune chip sono mutuamente esclusive). Reset → spegne tutte le chip attive.
- **Registro** (dipende dal sub-tab attivo `.registro-subtab.active`):
  - sub-tab `registro`: "Periodo" (pillole proxy di `.registro-date-btns .rfilter-btn`; se `data-range="custom"` mostra il gruppo "Date personalizzate" con `#admRegistroFrom/To` ↔ `#registroDateFrom/To`), "Tipo evento" (multi-toggle proxy di `.rfilter-type-pills .rfilter-btn`), "Tipo lezione"/"Metodo pagamento"/"Stato" (select originali `#registroFilterSlot/#registroFilterMethod/#registroFilterStatus` resi come pillole: set `value` + `dispatchEvent('change')`), "Cerca cliente" (input testo `placeholder="Nome, telefono…"` ↔ `#registroSearch`, applicato con evento `input`). Applica → `applyRegistroCustomRange()` + propagazione search; Reset → `resetRegistroFilters()`.
  - sub-tab `notifiche-admin`: "Tipo notifica" (`#msgFilterType`), "Stato" (`#msgFilterStatus`), "Data" (`#admMsgDate` ↔ `#msgFilterDate`). Reset azzera i 3 campi e chiama `loadMessaggi()`.
  - sub-tab `notifiche-clienti`: "Tipo notifica" (`#cnFilterType`), "Stato" (`#cnFilterStatus`), "Cerca cliente" (`placeholder="Nome cliente…"` ↔ `#cnFilterClient`), "Data" (↔ `#cnFilterDate`). Reset azzera e chiama `renderClientNotifTable()`.

Footer sheet filtri: bottoni **"Reset"** (`.adm-sheet-btn--ghost`: `#f1f5f9`/`#475569`) e **"Applica"** (`.adm-sheet-btn--primary`: gradient viola, testo bianco), `min-height:44px; border-radius:10px`.

Stile sheet comune: fixed bottom full-width, `max-height:82vh; background:#fff; border-radius: 20px 20px 0 0; box-shadow: 0 -10px 30px rgba(0,0,0,0.18)`, animazione `transform: translateY(100%) → 0` in `0.3s cubic-bezier(0.4,0,0.2,1)`; backdrop `rgba(15,23,42,0.45)` z-index 1100 (sheet 1101). Grabber 40×4px `#cbd5e1` (tap = chiudi). Pillole filtro: `border-radius:999px; min-height:36px; font-size:0.82rem` bianche con bordo `#e2e8f0`; attive = gradient viola. Chiusure: tap backdrop, `Escape`, **swipe-down > 80px** (drag che parte da grabber o titolo, con translateY live durante il drag), cambio breakpoint. Sincronizzazione stato: click-listener + MutationObserver su `class` dei tab (come la sidebar) + listener su tutti i controlli originali (search input, select, chip, filter-btn) per aggiornare badge/label della pill.

---

### 1.5 admin-health.js — utility diagnostiche console

**Non monitora nulla in automatico e non mostra banner o toast**: registra solo 4 funzioni globali da usare in console (in Flutter sono replicabili come debug utilities o omesse):
- `window.adminCheckBodyLocks()` — elenca gli overlay attualmente visibili (selettore `[id$="Modal"], [id$="modal"], .modal-overlay, .popup-overlay` con check su display/visibility/opacity/rect) e gli `overflow` inline di body/html; output con `console.table`.
- `window.adminHealth()` — snapshot: `path`, `online` (navigator.onLine), `visibility`, `activeTab` (dal tab `.active`), `adminAuth` (flag sessionStorage), `hasSession` (via `supabaseAuth.auth.getSession()`), `bookings` (`BookingStorage.getAllBookings().length`), `users` (`UserStorage.getAll().length`), `localBookingsBytes` (lunghezza di `localStorage.gym_bookings`).
- `window.adminDebugLog()` — setta `localStorage.admin_debug = '1'` e logga `"[Admin] debug log abilitato"`.
- `window.adminMeasure(label, fn)` — esegue `fn` e logga `"[AdminMeasure] <label> <N>ms"`.

---

### 1.6 Popup "Nuovo cliente iscritto" (js/new-client-popup.js)

**Scopo**: quando un nuovo cliente completa TUTTA l'anagrafica, mostra all'admin un popup con nome+telefono e bottoni rapidi WhatsApp/Telefono per salvarlo in rubrica. 100% client-side, nessuna chiamata di rete propria.

**Gate**: gira solo se `sessionStorage.adminAuth === 'true'` (verificato in `decide()`, non al boot) **e** solo su mobile/PWA: `navigator.standalone === true` o `matchMedia('(display-mode: standalone)')` o `window.innerWidth <= 768`. Su desktop non compare mai.

**Fonte dati**: `UserStorage._cache` (roster già sincronizzato dal boot con RPC **`get_all_profiles_basic`**, fallback `get_all_profiles` — org-scoped via RLS/`is_org_admin`). "Completo" = `userId` + `whatsapp` + `codiceFiscale` + `indirizzoVia` + `indirizzoPaese` + `indirizzoCap` tutti valorizzati, e `_fromSupabase === true`.

**Logica "nuovo"** (chiavi localStorage **namespaced per org**, suffisso `_<window._orgId>` o `_default`):
- `palestria_newClientSeen_<orgId>` — array JSON di userId già mostrati/acquisiti.
- `palestria_newClientBaseline_<orgId>` — `'1'` dopo la prima semina.
Al primo avvio assoluto per l'org: semina il set con tutti i clienti completi correnti (baseline, nessun popup). Poi: cliente completo con userId non presente nel set → popup. Alla **chiusura volontaria** (✕ o tap sul backdrop) gli id mostrati vengono marcati visti → non ricompaiono più su quel dispositivo.

**Trigger**: (1) al boot, `_waitForRoster()` polla `UserStorage._cache` (max 15s, step 300ms) poi `decide()`; (2) a ogni ritorno in primo piano (`visibilitychange` dopo un hidden) → `syncAndDecide()` = `UserStorage.syncUsersFromSupabase()` (economico: TTL/fingerprint) + `decide()`. **Nessun canale realtime dedicato.** API debug: `window.NewClientPopup.refresh` / `._decide`.

**UI** (stili self-contained iniettati, prefisso `.ncp-*`): overlay fixed `rgba(0,0,0,0.55)` + `backdrop-filter: blur(2px)`, z-index 3000; card centrata `max-width:420px; border-radius:18px; background:#fff`, animazione pop `0.25s cubic-bezier(.18,.89,.32,1.28)`; icona header "aggiungi contatto" in cerchio `rgba(139,92,246,0.12)`/`#8B5CF6` 56px. Testi esatti:
- Titolo: **"Nuovo cliente iscritto"** (1 cliente) oppure **"N nuovi clienti iscritti"**.
- Sottotitolo: **"Aggiungilo alla rubrica"** oppure **"Hai N nuovi clienti da aggiungere"** (N in grassetto).
- Per ogni cliente (card `#fafbfc`, bordo `#eceff1`, radius 14px): nome (weight 800), telefono, bottone info ⓘ (28px, viola soft; attivo pieno `#8B5CF6`) che espande un pannello con righe: `👤 Uomo/Donna` e `🎂 N anni` (derivati dal **codice fiscale** con `parseCF()`: giorno >40 = donna; secolo euristico 2000/1900), `📍 <comune>` (da `indirizzoPaese`); fallback **"Dati non disponibili"**.
- Azioni: **"WhatsApp"** (bottone verde `#25d366`, hover `#1fb757`, href `https://wa.me/<solo cifre>`) e **"Telefono"** (viola `#8B5CF6`, hover `#7C3AED`, href `tel:<+ e cifre>`).
- Chiudi: ✕ tondo 32px in alto a destra (`#f1f3f5`). `body.ncp-open { overflow:hidden }`.

---

### 1.7 Modali/overlay globali di admin.html e script inline

#### 1.7.1 Banner report settimanale

`div#weeklyReportBanner.weekly-report-banner` (default `display:none`): gradient blu `linear-gradient(135deg, #1e40af 0%, #2563eb 100%)`, radius 12px, animazione slide-in 0.4s. Contenuto: icona `📊`, `<strong>Report settimanale disponibile</strong>`, `span#weeklyReportPeriod` (testo `"Pagamenti report fiscale: <label settimana precedente>"`), bottone **"📥 Scarica report"** (`onclick="downloadWeeklyReport()"` — bianco, testo `#1e40af`, radius 8px) e close **"✕"** (`onclick="dismissWeeklyReport()"`, `title="Chiudi"`). Logica (`admin-analytics.js`): `checkWeeklyReportBanner()` lo mostra **solo il lunedì** (`new Date().getDay() === 1`) se non dismesso; dismissal in `localStorage` con chiave `weeklyReportDismissed_<YYYY-MM-DD>` (lunedì della settimana precedente). `downloadWeeklyReport()` risincronizza i profili e genera un PDF dal ledger `payments` (metodi fiscali: `carta`, `iban`, `stripe`, `contanti-report`).

#### 1.7.2 Modali (id, titoli, campi, bottoni — testi esatti)

1. **Certificato medico** — `#certModalOverlay` (overlay `.debt-popup-overlay`) + `#certModal.cert-modal`. Header: `🏥 Certificato Medico` + sottotitolo `#certModalName` (nome cliente, `0.9rem #6b7280`), close ✕ SVG (`closeCertModal()`). Corpo: label **"Data di scadenza"**, `input type=date #certModalDate`. Azioni: **"Annulla"** (`closeCertModal()`) / **"Salva"** (`saveCertDate()`).
2. **Assicurazione** — `#assicModalOverlay` + `#assicModal` (stessa struttura): titolo `📋 Assicurazione`, `#assicModalName`, label "Data di scadenza", `#assicModalDate`, "Annulla" (`closeAssicModal()`) / "Salva" (`saveAssicDate()`).
3. **Incasso debiti** — `#debtPopupOverlay` + `#debtPopupModal.debt-popup-modal`. Header: `h3#debtPopupName` + `p#debtPopupSubtitle` (popolati da admin-payments.js), close ✕ (`closeDebtPopup()`). Corpo: lista prenotazioni selezionabili `#debtPopupList` (generata). Riga pagamento: label **"Metodo di pagamento"** + `select#debtMethodSelect` (`onchange="onPaymentMethodChange(this)"`) con placeholder disabilitato **"Seleziona…"** e opzioni: `💵 Contanti` (`contanti`), `🧾 Contanti con Report` (`contanti-report`), `💳 Carta` (`carta`), `🏦 Bonifico` (`iban`), `🎁 Gratuita` (`lezione-gratuita`). Footer: checkbox **"Seleziona tutto"** (`toggleAllDebts(checked)`), checkbox **"Seleziona passate"** (`#debtSelectPast`, wrapper `#debtSelectPastWrap`, `togglePastDebts(checked)`), totale **"Dovuto: €0"** (`strong#debtSelectedTotal`), bottone **"✓ Conferma"** (`#debtPayBtn`, `paySelectedDebts()`, `disabled` di default).
4. **Dati mancanti per pagamento** — `#missingDataOverlay` + `#missingDataModal` (max-width 420px). Titolo: **"⚠️ Dati mancanti per pagamento"** (`#missingDataTitle`), close ✕ (`closeMissingDataPopup()`). Testo: *"Per i pagamenti riportati fiscalmente (carta, bonifico, stripe, contanti con report) servono Codice Fiscale e indirizzo di residenza."* Campi: **"Codice Fiscale"** (`#mdCodiceFiscale`, placeholder `RSSMRA85M01H501Z`, maxlength 16, uppercase), **"Via / Indirizzo"** (`#mdVia`, placeholder `Via Roma 1`), **"Paese / Città"** (`#mdPaese`, placeholder `Milano`) + **"CAP"** (`#mdCAP`, placeholder `20100`, maxlength 5, numeric). Area errore `#mdError` (rosso `#dc2626`). Azioni: **"Annulla"** (`closeMissingDataPopup()`) / **"✓ Salva e continua"** (`#mdSaveBtn`, `saveMissingData()`).
5. **Date popover desktop** — `#admDatepopBackdrop` + `#admDatepop` (vedi 1.3): titolo "Periodo", presets, label "Range personalizzato", `#admDatepopFrom/To`, bottone "Applica".
6. **Bottom sheet "Vai a"** — `#admPagesBackdrop` + `#admPagesSheet` (titolo `#admPagesTitle` "Vai a", `ul#admPagesList` role=listbox). Vedi 1.4.
7. **Bottom sheet "Filtri"** — `#admFiltersBackdrop` + `#admFiltersSheet.adm-sheet--filters` (titolo `#admFiltersTitle` "Filtri", corpo `#admFiltersBody`, footer `#admFiltersReset` "Reset" / `#admFiltersApply` "Applica"). Vedi 1.4.
8. **Drawer hamburger** — `#navSidebarOverlay` + `#navSidebar` (vedi 1.1.1).

#### 1.7.3 FAB globali

- `button#scrollToSlotFab.scroll-slot-fab` — emoji `🕐`, `title="Vai allo slot corrente"`, `onclick="_scrollToCurrentAdminSlot(document.getElementById('adminDayView'))"`. Visibile SOLO sul tab `bookings` (gestito da `switchTab`).
- `button#paymentsFab.payments-fab` — icona SVG "+" 28×28, `aria-label="Aggiungi pagamento"`, `title="Aggiungi"`, `onclick="openPaymentsActionSheet()"`. Visibile SOLO sul tab `payments`.
Su mobile stanno a `bottom: 84px/134px + safe-area` per non coprire il dock (1.4).

#### 1.7.4 Markup statico per-tab (sintesi — dettagli nelle sezioni dedicate della specifica)

- `#tab-bookings`: barra settimana (`#adminCurrentWeek` testo iniziale "Settimana Corrente", `#adminCurrentMonth`, frecce `#adminPrevWeek`/`#adminNextWeek` con title/aria "Settimana precedente/successiva"), `#adminDaySelector` (giorni generati da JS), `#adminDayView`.
- `#tab-payments`: titolo pagina "Pagamenti" / sub "Da incassare"; 2 stat-card cliccabili con hint **"Dettagli ▼"**: "Da Incassare" (`💰`, `#totalUnpaid` "€0", `onclick toggleDebtorsList()`) e "Incassato questo mese" (`💳`, `#totalCreditAmount`, `toggleCreditsList()`); contenitori `#debtorsList` e `#creditsList` (quest'ultimo `display:none`).
- `#tab-clients`: titolo "Clienti"; search `#clientSearchInput` placeholder **"Cerca cliente.."** (`oninput liveSearchClients()`, Escape → `closeClientsSearchDropdown()`); bottone `#clientsFilterToggle` "🔍 Filtri ▼" (`toggleClientsFiltersMenu()`); dropdown `#clientsSearchDropdown`; 5 chip filtro (testi in 1.4); `#clientsFilterResult`; 2 stat-card "Clienti Totali" (`👥`, `#clientsTotalCount`, `toggleClientsTotalList()`) e "Clienti Attivi" (`💪`, `#clientsActiveCount`, `toggleClientsActiveList()`); lista `#clientsList`.
- `#tab-schedule`: solo `#scheduleManager` (tutto generato da admin-schedule.js).
- `#tab-analytics`: titolo "Statistiche" / "& Fatturato"; filter bar con bottoni **"Questo mese"** (attivo default), **"Mese prossimo"**, **"Mese scorso"**, **"Quest'anno"**, **"Anno scorso"**, **"📅 Personalizzato"** (`onclick setAnalyticsFilter('<id>', this)`) + `#filterCustomDates` (from/to + "Applica" → `applyCustomFilter()`); 4 stat-card cliccabili (`toggleStatDetail('fatturato'|'prenotazioni'|'clienti'|'occupancy')`): "Fatturato previsto" (`💰 #monthlyRevenue` "€0", `#revenueChange` "+0%"), "Prenotazioni Totali" (`📅 #totalBookings`), "Clienti Attivi" (`👥 #activeClients`), "Tasso Occupazione" (`📊 #occupancyRate` "0%"); pannello `#statsDetailPanel`.
- `#tab-settings`: hub con header "Impostazioni" + badge **"🔧 Configurazione"**, nav `#settNav` e corpo `#settBody` con placeholder **"⏳ Caricamento impostazioni…"** (11 sotto-tab generate da `renderSettingsTab()`).
- `#tab-registro`: 3 sub-tab (`switchRegistroSubtab('<nome>', this)`): **"Registro"**, **"Notifiche admin"**, **"Notifiche clienti"**. Sezione Registro: header collassabile "📋 Registro Operazioni" (`toggleRegFilters(this)`), filtri periodo ("Tutto" attivo default, "Questo mese", "Mese scorso", "Quest'anno", "📅 Personalizzato" → `setRegistroRange`), pillole tipo evento (`📅 Prenotazione`=booking_created, `✅ Pagamento`=booking_paid, `❌ Annullamento`=booking_cancelled, `⬆️ Credito Manuale`=credit_added, `📋 Debito Manuale`=manual_debt, `💰 Debito Saldato`=manual_debt_paid, `💸 Mora`=cancellation_mora → `toggleRegistroType(this)`), select "Tipo lezione" (Tutte/Autonomia/Lezione di Gruppo/Slot prenotato), "Metodo pagamento" (Tutti, 💵 Contanti, 🧾 Contanti con Report, 💳 Carta, 💳 Stripe con `data-feature="client_online_payments"`, 🏦 Bonifico, 🔄 Credito, 🎁 Gratuita), "Stato" (Tutti/Pagato/Non pagato/Annullato), search "Nome, telefono..." (`_debouncedRegistroFilter()`), "↺ Reset" (`resetRegistroFilters()`); tabella sortabile (colonne Data/Ora ↕, Tipo, Cliente, Data Lezione ↕, Ora, Tipo Lezione, Importo, Metodo, Stato, Nota; empty-state "Seleziona il tab per caricare il registro."), lista mobile `#registroMobileList`, paginazione "← Prec" / "Succ →" (`registroPrevPage()`/`registroNextPage()`). Notifiche admin: header "📩 Storico notifiche", filtri tipo (✔️ Prenotazioni/❌ Annullamenti/🆕 Nuovi iscritti/💰 Ricariche → `loadMessaggi()`), stato (✅ Inviata/❌ Non inviata), data, reset; tabella + `#messaggiMobileList` + paginazione (`messaggiPrevPage/NextPage`). Notifiche clienti: header "📬 Notifiche ai clienti", filtri tipo (⏰ Promemoria 24h `reminder_24h`, ⏰ Promemoria 1h `reminder_1h`, 🟢 Slot disponibile `slot_available`, 📢 Broadcast `broadcast` → `renderClientNotifTable()`), stato (✅ Inviata/❌ Fallita/⚠️ No subscription), search cliente (`_debouncedCnFilter()`), data; tabella + `#cnMobileList` + paginazione (`cnPrevPage/NextPage`).
- `#tab-messaggi` (**`data-feature="messaging"`** anche sul pannello): hub "Notifiche Push" + badge **"📡 Broadcast"**; card "✏️ Componi messaggio" con "Titolo" (`#msgTitle`, maxlength 60, placeholder "Titolo notifica") e "Messaggio" (`#msgBody`, textarea 3 righe, maxlength 200, placeholder "Testo del messaggio"); card "👥 Destinatari" con 3 radio `msgRecipientMode` (`onchange onMsgRecipientModeChange(value)`): **"Tutti gli utenti"** (`tutti`, checked; sub "Invia a tutti gli utenti iscritti alle notifiche push."), **"Iscritti di un giorno"** (`giorno`; "Invia solo a chi ha una prenotazione in un giorno specifico."), **"Iscritti di un'ora specifica"** (`ora`; "Invia solo a chi ha una prenotazione in un giorno e orario specifico."); campi condizionali "Data" (`#msgDate`, `onchange onMsgDateChange(value)`) e "Orario" (`select#msgTimeSlot`, placeholder "Seleziona prima una data"); barra invio: **"📤 Invia notifica"** (`sendAdminMessage()`) + `span#msgStatus`.
- `#tab-schede` (**`data-feature="workout_plans"`**): solo `#schedeContainer` con placeholder **"Caricamento schede..."** (tutto generato da admin-schede.js).

#### 1.7.5 Script inline in fondo ad admin.html

1. **Anti-zoom iOS**: su `touchstart` su INPUT/SELECT/TEXTAREA riscrive il meta viewport con `maximum-scale=1`; su `focusout` lo ripristina dopo 300ms.
2. **Boot IIFE async** (dopo il caricamento di tutti i moduli) — vedi 1.8 per la sequenza; in sintesi definisce `window._adminAccessGate`, il check `is_platform_admin`, il toast di ritorno Stripe Connect (query `?stripe=`: `connected` → "✅ Account Stripe collegato!", `cancelled` → "Collegamento Stripe annullato.", altro → "⚠️ Collegamento Stripe non riuscito. Riprova."; mostrato con `showToast` dopo 900ms, poi `history.replaceState` pulisce l'URL), i 3 sync iniziali, il primo render, `window._adminRefreshAfterResume`, il sync realtime debounced e la sottoscrizione del canale.
3. **Realtime**: canale `'admin-rt'` con `postgres_changes` (event `*`, schema `public`) sulle tabelle **`bookings`**, **`app_settings`**, **`profiles`**, **`settings`** → handler unico `_adminDebouncedSync` (debounce **1500ms**): `ensureValidSession({timeoutMs:12000})`, poi in PARALLELO `UserStorage.syncUsersFromSupabase()` + `BookingStorage.syncFromSupabase()` + `BookingStorage.syncAppSettingsFromSupabase()`, poi re-render: `loadDashboardData()`, `renderAdminCalendar()`, `renderAdminDayView(selectedAdminDay)` se definito, `renderScheduleManager()`, e re-render del tab attivo (payments → `renderPaymentsTab('realtime')`, clients → `renderClientsTab()`, settings → `renderSettingsTab()`, schede → `renderSchedeTab()`). Il canale è registrato via `window._registerRealtimeChannel('admin-rt', factory)` (registry di silent-refresh.js che lo rianima dopo sleep/wake).
4. `window._adminRefreshAfterResume(reason)`: al resume/riconnessione — `ensureValidSession({ force: /online/.test(reason), timeoutMs: 12000 })`, 3 sync in parallelo, `loadDashboardData()` + `renderAdminCalendar()` + `switchTab(tabAttivo)`; incrementa/decrementa `window._userRecoveryDepth` per sopprimere il reload d'emergenza del watchdog.

---

### 1.8 Boot sequence

Ordine di caricamento script (rilevante per le dipendenze): `<head>`: inline anti-flash tab → `ls-namespace.js` (namespacing trasparente con prefisso `palestria:` delle 6 chiavi localStorage legacy: `gym_bookings`, `gym_stats`, `weeklyScheduleTemplate`, `scheduleVersion`, `gym_week_templates`, `gym_active_week_template` — patch di `Storage.prototype`) → `branding-boot.js`. `<body>` in fondo: supabase-js CDN → `egress-debug.js` → `supabase-client.js` → `org-settings.js` → `entitlements.js` → xlsx CDN → `ui.js` → `modals.js` → `data.js` → `auth.js` → `silent-refresh.js` → `app-watchdog.js` → `push.js` → `chart-mini.js` → `admin.js` → `admin-analytics.js` → `admin-backup.js` → `admin-calendar.js` → `admin-schedule.js` → `admin-settings.js` → `admin-payments.js` → `admin-clients.js` → `admin-registro.js` → `admin-messaggi.js` → `admin-schede.js` → `admin-health.js` → `admin-importa.js` → `admin-mobile-filters.js` → `admin-desktop-sidebar.js` → `maintenance.js` → `new-client-popup.js` → **boot IIFE inline** → `sw-update.js` → `pull-to-refresh.js` → `pwa-install.js`.

Sequenza runtime:

1. **Gate accesso** — il boot inline crea `window._adminAccessGate` (promise condivisa): `await initAuth()` (auth.js: in parallelo `_loadProfile(userId)` → select su `profiles`, e `_applyOrgContext(user)` → legge `app_metadata.org_id`/`org_role` dal JWT con fallback query `org_members` (`select org_id, role` `eq user_id` `eq status='active'` `order created_at asc limit 1`); setta `window._orgId`/`window._orgRole`; **`sessionStorage.adminAuth='true'` SOLO se role ∈ {owner, admin}**, altrimenti lo rimuove). Poi: se `adminAuth === 'true'` → rimuove `#adminGateOverlay`, resolve `true`; altrimenti `location.replace('index.html')` se loggato, `location.replace('login.html?redirect=admin.html')` se anonimo, resolve `false` (stop totale: niente sync/render).
2. **`initAdmin()`** (js/admin.js — lanciato su DOMContentLoaded da admin-messaggi.js, l'ultimo modulo admin): guard `window._adminInitialized`; `await window._adminAccessGate` (se `false` return); `await _ensureAdminOrgContext()` (garantisce `window._orgId/_orgRole` rileggendo `org_members` se i claim mancano; propaga `adminAuth='true'` anche per `staff`); gate `hasAdminUiAccess()` su `ADMIN_UI_ROLES = ['owner','admin','staff']` (basato su `window._orgRole` verificato, NON sul flag sessionStorage); `await loadOrgScheduleConfig()` (config orari per-org: slot_types/fasce/template); `await OrgSettings.load()` + `OrgSettings.applyBranding()`; `await Entitlements.load()` + `Entitlements.applyFeatureGating()` (fail-open con warn); `showDashboard()`; `setupAdminStickyOffsets()`; listener globale click → `closeSearchDropdown()` fuori da `.payment-search`.
3. **`showDashboard()`**: rimuove (difesa in profondità) `#adminGateOverlay`; azzera l'inline display di `#dashboardSection`; `setupTabs()`; `setupAdminCalendar()`; `setupScheduleManager()`; `updateNonChartData()` (admin-analytics: stat cards + tabella + orari popolari da cache locale); `checkWeeklyReportBanner()`; ripristina il tab salvato da `sessionStorage.adminActiveTab` con `switchTab(savedTab)`; rimuove `data-initial-tab` da `<html>`.
4. **Boot inline (continua, dopo la gate)**: check `is_platform_admin` (mostra i 2 link Super Admin); toast Stripe Connect; **sync IN SERIE** (per non saturare il pool Supabase): `await UserStorage.syncUsersFromSupabase()` (RPC `get_all_profiles_basic`, fallback `get_all_profiles`) → `await BookingStorage.syncFromSupabase()` (tabella `bookings`) → `await BookingStorage.syncAppSettingsFromSupabase()` (che chiama prima `loadOrgScheduleConfig()`; tabelle settings/overrides org); `window._adminLastFullSyncAt = Date.now()`; **primo render**: `loadDashboardData()`, `renderAdminCalendar()`, `renderScheduleManager()`, `switchTab(tabAttivo)`; dopo 1500ms `promptPushPermission()`; in background `syncPushEnabledUsers()`; installa resume-handler e realtime (1.7.5).

**Loading/skeleton**: non esistono skeleton veri. Gli stati di caricamento sono: overlay bianco "Verifica accesso…" (finché la gate non risolve), placeholder testuali per-pannello ("⏳ Caricamento impostazioni…", "Caricamento schede...", "Caricamento..." nelle tabelle registro/notifiche, "Seleziona il tab per caricare il registro."), e il pattern dual-layer di data.js (prima render da cache localStorage, poi re-render al sync). I loader dei tab sono deferiti (`setTimeout 0` / doppio `requestAnimationFrame`) per non congelare la UI.

**Chiavi storage usate dalla shell** (riepilogo esatto):
- `sessionStorage`: `adminAuth` (`'true'`), `adminActiveTab` (nome tab), `adminSchedeSection` (`'importa'`).
- `localStorage`: `adminSensitiveHidden` (`'true'|'false'`), `admin_debug` (`'1'`), `weeklyReportDismissed_<YYYY-MM-DD>`, `palestria_newClientSeen_<orgId>` (JSON array), `palestria_newClientBaseline_<orgId>` (`'1'`), `_brandingSnapshot` (JSON), chiavi org-namespaced `org_<orgId>_<key>` (cache OrgSettings), e le 6 chiavi rimappate `palestria:gym_bookings` ecc. (via ls-namespace.js); `adminAuthenticated` è legacy e viene solo rimossa.

---

### 1.9 Gating ruoli e feature flags

#### 1.9.1 Ruoli (owner / admin / staff)

- I ruoli vivono in `org_members.role` e (se l'auth hook è registrato) nel claim JWT `app_metadata.org_role`; il client li espone come `window._orgRole` (+ `window._orgId` da `app_metadata.org_id`).
- **`_applyOrgContext()`** (auth.js) setta `sessionStorage.adminAuth='true'` **solo per owner/admin** (staff e clienti: flag rimosso). La **gate del boot** di admin.html ammette solo `adminAuth==='true'` → di fatto al primo accesso **solo owner/admin superano la gate**; lo staff verrebbe rediretto a `index.html`. 
- **`admin.js`** però è progettato per 3 ruoli: `ADMIN_UI_ROLES = ['owner','admin','staff']`; `hasAdminUiAccess()` = ruolo ∈ lista (autorità = `window._orgRole` verificato server-side, mai il flag sessionStorage, manipolabile da console); `isOrgAdminRole()` = solo `owner`/`admin` ("per azioni/UI che lo staff non deve vedere"); `_ensureAdminOrgContext()` propaga `adminAuth='true'` anche per `staff` (per i moduli legacy che leggono il flag). ⚠️ Nella spec Flutter va deciso e uniformato: il codice attuale contiene questa **incoerenza** (gate d'ingresso = owner/admin; scope interno = owner/admin/staff). In ogni caso l'autorità sulle scritture resta il server (RLS + RPC): lo staff può al più vedere, non fare ciò che il DB gli nega.
- **Owner vs admin**: nella shell admin NON c'è alcuna differenza UI tra owner e admin (stesse tab, stessi bottoni). L'unico elemento "sopra-tenant" è il link **"👑 Super Admin"** (navbar + drawer), mostrato solo se la RPC **`is_platform_admin()`** ritorna `true` (admin di PIATTAFORMA, non ruolo org).
- Clienti/anonimi: redirect immediato dalla gate (index.html o login.html?redirect=admin.html) senza che nulla della dashboard venga renderizzato (overlay opaco fino al redirect).

#### 1.9.2 Feature flags per piano SaaS (entitlements.js)

- Fonte di verità: RPC **`get_tenant_entitlements()`** (nessun parametro, authenticated) → jsonb `{ plan, status, max_clients, features, trial_end, current_period_end, clients_count }`, o `null` se la org non ha subscription. Cache in memoria + `window._entitlements`; `load({force})` idempotente.
- `Entitlements.has(flag)`: **fail-closed** — ritorna `false` finché il load non è completato con esito noto (`_loaded`), `false` se `_ent` è `null` (nessuna subscription), altrimenti `features[flag] !== false` (flag assente = incluso). Stati "attivi": `['trialing','active']` (`isActive()`). Altre API: `plan()`, `status()`, `maxClients()` (null = illimitato), `clientsCount()`, `atClientLimit()`, `remainingClients()`.
- **`Entitlements.applyFeatureGating(root?)`**: per ogni elemento `[data-feature]` con flag non incluso:
  - Se è un **tab della dashboard** (`.admin-tab[data-tab]`): resta VISIBILE ma `disabled` + `aria-disabled="true"` + classe `ent-locked` (`opacity:.55; cursor:not-allowed`) + badge figlio `span.ent-upgrade-badge` con testo **"🔒 Piano superiore"** e `title="Disponibile nel piano superiore"` (stile: `font-size:10px; font-weight:600; color:#92400e; background:#fef3c7; border:1px solid #fde68a; border-radius:999px; padding:1px 6px; margin-left:6px`). Razionale: l'utente vede cosa sblocca con l'upgrade.
  - Qualsiasi altro elemento: nascosto con `display:none` (salvando il display precedente in `dataset.entPrevDisplay` per il ripristino se il piano cambia).
  - Se il flag torna incluso: ripristino completo (rimozione badge/disabled/classe, restore display).
- **Attributi `data-feature` presenti in admin.html**: `workout_plans` (tab `🏋🏻 Schede` **e** pannello `#tab-schede`), `messaging` (tab `📩 Messaggi` **e** pannello `#tab-messaggi`), `client_online_payments` (option "💳 Stripe" nel select `#registroFilterMethod` del Registro). Il gating è puramente UX: l'enforcement reale è server-side.
- Boot: `initAdmin()` chiama `Entitlements.load()` + `applyFeatureGating()` prima di `showDashboard()`; in caso di errore RPC logga `"[admin] feature gating non applicato:"` e prosegue (le feature premium restano bloccate lato UI per il fail-closed di `has()`).

---

# PalestrIA — Migrazione Flutter area admin

## 2. Design system (CSS)

Fonti analizzate integralmente: `css/admin.css` (13.703 righe, v83), `css/style.css` (1.974 righe, globale, v11), `css/login.css` (393 righe, v6), `css/allenamento.css` (tokens `--all-*` e componenti riusati dall'editor schede admin, v58). Tutte linkate da `admin.html`.

> ⚠️ **Nota rem/desktop**: `style.css` imposta `html { font-size: 12px }` a `min-width: 769px` (desktop "scale-down"), mentre su mobile resta il default 16px. **Tutti i valori in `rem` di questo documento valgono 16px su mobile e 12px su desktop.** In Flutter conviene definire due scale (mobile/desktop) o un fattore 0.75 per ≥769px logici.

> ⚠️ **Branding per-org (multi-tenant)**: le variabili `--primary-purple` / `--primary-purple-dark` possono essere **sovrascritte a runtime** dal branding del tenant (`OrgSettings.applyBranding` / `branding-boot.js`). Anche i colori dei tipi-slot sono per-org (`slot_types.color`, applicati inline dal JS, es. pallini `.sa-dot` e barre `.book-row-bar`). In Flutter il `ThemeData` va costruito dinamicamente dai settings dell'organizzazione, con i valori sotto come **default**.

---

### 2.1 Design tokens (variabili CSS)

#### `:root` di `style.css` (globale, tutte le pagine)

| Variabile | Valore | Uso |
|---|---|---|
| `--primary-purple` | `#8B5CF6` | Colore brand primario (viola). Bottoni, tab attive, link, focus ring, FAB. Sovrascrivibile per-org |
| `--primary-purple-dark` | `#7C3AED` | Viola scuro: hover, seconda stop dei gradient brand |
| `--dark-bg` | `#1a1a1a` | Sfondo scuro: navbar, footer, th tabelle, titoli scuri |
| `--dark-gray` | `#2d2d2d` | Grigio scuro (celle orario calendario pubblico) |
| `--light-gray` | `#f8f9fa` | **Sfondo pagina** (body) e superfici neutre chiare |
| `--text-white` | `#ffffff` | Testo su fondi scuri |
| `--text-dark` | `#333333` | Testo body di default |
| `--personal-training` | `#22c55e` | Tipo slot "Allenamento in autonomia / PT" (verde) |
| `--small-group` | `#fbbf24` | Tipo slot "Lezione di gruppo / small group" (giallo/ambra) |
| `--group-class` | `#ef4444` | Tipo slot "Slot prenotato / group class" (rosso) |
| `--cleaning` | `#8b5cf6` | Tipo slot "Pulizia" (viola) |
| `--success` | `#06d6a0` | Verde-acqua successo (badge pagato, toast success, btn-pay-all) |
| `--warning` | `#f77f00` | Arancio warning (badge pending) |

#### `:root` di `allenamento.css` (tokens `--all-*`, usati anche dall'editor schede admin mobile)

| Variabile | Valore |
|---|---|
| `--all-purple` / `--all-purple-dark` | `#8B5CF6` / `#7C3AED` |
| `--all-purple-glow` / `--all-purple-glow-strong` | `rgba(139,92,246,0.12)` / `rgba(139,92,246,0.22)` |
| `--all-navy` / `--all-navy-light` / `--all-slate` | `#0f172a` / `#1e293b` / `#1e293b` |
| `--all-muted` / `--all-subtle` | `#64748b` / `#94a3b8` |
| `--all-border` / `--all-border-hover` | `#e2e8f0` / `#cbd5e1` |
| `--all-surface` / `--all-bg` | `#ffffff` / `#f1f5f9` |
| `--all-success` / `--all-success-dark` / `--all-success-glow` | `#10b981` / `#059669` / `rgba(16,185,129,0.12)` |
| `--all-amber` / `--all-amber-glow` | `#f59e0b` / `rgba(245,158,11,0.12)` |
| `--all-cyan` / `--all-cyan-dark` / `--all-cyan-glow` | `#06b6d4` / `#0891b2` / `rgba(6,182,212,0.12)` |
| `--all-red` / `--all-red-glow` | `#ef4444` / `rgba(239,68,68,0.12)` |
| `--all-radius` / `--all-radius-sm` / `--all-radius-xs` | `16px` / `12px` / `8px` |
| `--all-shadow` | `0 1px 3px rgba(15,23,42,0.06), 0 1px 2px rgba(15,23,42,0.04)` |
| `--all-shadow-md` | `0 4px 16px rgba(15,23,42,0.08), 0 2px 4px rgba(15,23,42,0.04)` |
| `--all-shadow-lg` | `0 12px 32px rgba(15,23,42,0.12), 0 4px 8px rgba(15,23,42,0.06)` |
| `--all-shadow-glow` | `0 0 0 3px var(--all-purple-glow), 0 4px 16px rgba(139,92,246,0.10)` |
| `--all-transition` | `0.2s cubic-bezier(0.4,0,0.2,1)` |
| `--all-transition-spring` | `0.35s cubic-bezier(0.34,1.56,0.64,1)` |

Tokens report (`--rep-*`, sempre in allenamento.css): `--rep-brand #8B5CF6`, `--rep-brand-strong #7C3AED`, `--rep-header-ink #0f172a`, `--rep-green #16a34a`, `--rep-green-bg #dcfce7`, `--rep-green-ink #166534`.

#### Variabili impostate a runtime dal JS (layout)

| Variabile | Default | Uso |
|---|---|---|
| `--admin-tabs-top` | `72px` | offset sticky della barra tab admin (sotto navbar) |
| `--bookings-bar-top` | `122px` (mobile `72px`) | offset sticky delle week-bar Prenotazioni/Orari |
| `--adm-fixed-correction-y` | `0px` | correzione iOS PWA per dock/FAB fixed (legacy, ora shell anti-detach) |

**Tema scuro**: non esiste un dark-mode globale (nessun `prefers-color-scheme` in questi CSS; `color-scheme: light` forzato sui loghi). L'app è light-only, ma usa "hero scuri" fissi in componenti specifici (login admin, week-bar mobile, topbar editor schede, hero Importa) — vedi §2.13.

---

### 2.2 Palette completa (hex esatti e significato d'uso)

#### Viola brand (primario)
| Hex | Uso |
|---|---|
| `#8B5CF6` | primario: bottoni, tab attive, focus, FAB, accenti |
| `#7C3AED` | primario scuro: hover, gradient stop, testo tab-underline attiva |
| `#6D28D9` | stop finale gradient hero scuri e avatar viola |
| `#5b21b6` / `#1e1b4b` / `#312e81` | stop gradient hero card "Live" schede |
| `#A78BFA` | viola chiaro (hover border esercizi, eyebrow hero Importa) |
| `#C4B5FD` | lavanda (eyebrow/count su hero scuri mobile, barra occupazione) |
| `#ddd6fe` / `#ede9fe` / `#f5f3ff` / `#faf5ff` | tinte viola chiarissime: avatar bg, badge, bg selezione/hover, form Gestione Orari |
| `#f3e8ff` / `#7e22ce` / `#6d28d9` | badge "credito" (bg/testo) e avatar viola |

#### Grigi/slate (scala Tailwind slate — testo e bordi)
| Hex | Uso |
|---|---|
| `#0f172a` | testo titoli forte (slate-900) |
| `#1e293b` | testo titoli secondari |
| `#334155` | testo medio-forte |
| `#475569` | testo secondario forte, label |
| `#64748b` | testo secondario / tab idle |
| `#94a3b8` | testo muted, placeholder, icone spente |
| `#cbd5e1` | bordi hover, chevron, dot spenti |
| `#e2e8f0` | **bordo standard** card/input |
| `#e8ecf1` | seconda stop dei gradient "pill-bar" grigi |
| `#f1f5f9` | sfondo pill-bar / divisori / hover chiaro |
| `#f8fafc` | sfondo hover righe / pannelli chiari |
| grigi legacy `#eee #ddd #ccc #aaa #999 #888 #777 #666 #555 #444 #333 #111`, `#e5e7eb #d1d5db #9ca3af #6b7280 #374151 #f3f4f6 #f9fafb #fafbfc` | bordi/testi nei componenti più vecchi (popup, tabelle clienti) |

#### Verdi (successo / pagato / PT)
| Hex | Uso |
|---|---|
| `#22c55e` | tipo slot PT, bottoni credito |
| `#16a34a` | verde scuro: importi credito, badge attivo |
| `#15803d` / `#166534` / `#14532d` / `#065f46` | testi verdi su bg chiari |
| `#dcfce7` / `#f0fdf4` / `#d1fae5` / `#bbf7d0` / `#86efac` / `#a7f3d0` / `#6ee7b7` / `#4ade80` / `#ecfdf5` | bg verdi chiari (badge, chip cliente selezionato, card importata) |
| `#06d6a0` / `#05b886` | verde-acqua `--success`: toast, badge confermato, btn-add-slot |
| `#10b981` / `#059669` / `#047857` / `#34d399` | verde smeraldo: stat clienti, bottoni azione verdi |

#### Rossi (errore / debiti / oggi)
| Hex | Uso |
|---|---|
| `#ef4444` | rosso base: delete, debiti, tipo group-class |
| `#dc2626` | rosso scuro: hover, testo errore, "oggi" attivo |
| `#b91c1c` / `#991b1b` / `#7f1d1d` | testi rossi scuri |
| `#fee2e2` / `#fef2f2` / `#fecaca` / `#fca5a5` / `#f87171` / `#fff1f2` | bg rossi chiari (righe future, badge annullato, filtri reset) |
| `#e63946` | prezzo debito nel popup incasso |
| `#ff6b6b` / `#fff3cd` / `#856404` / `#ffe8a0` | debt-warning legacy (banner giallo bordo rosso) |
| `#ff7070` / `#ff4444` | logout sidebar navbar |

#### Ambra/gialli (warning / small-group / in attesa)
| Hex | Uso |
|---|---|
| `#f59e0b` | ambra base: edit icon, superset, statcard fatturato |
| `#fbbf24` / `#d97706` / `#b45309` / `#92400e` / `#854d0e` / `#a16207` / `#ca8a04` / `#c07000` | scala testi/bordi ambra |
| `#fef3c7` / `#fffbeb` / `#fef9c3` / `#fde68a` / `#fcd34d` / `#eab308` | bg gialli chiari (badge pending, tema superset) |
| `#f97316` | stop arancio del gradient superset |
| `#f77f00` | `--warning` (badge pending legacy, stato Stripe pending) |

#### Blu (prenotazioni / info)
| Hex | Uso |
|---|---|
| `#3b82f6` / `#60a5fa` | statcard prenotazioni (accent + gradient) |
| `#2563eb` / `#1d4ed8` / `#1e40af` | bottoni blu (backup), banner report settimanale |
| `#dbeafe` / `#eff6ff` / `#e0e7ff` / `#93c5fd` / `#dbeafe` | bg blu chiari (badge booking, avatar, KPI) |
| `#0369a1` / `#0284c7` / `#075985` / `#0b7fb0` / `#0c4a6e` / `#0084b4` / `#0070a8` / `#0077b6` | ciano-blu scuri (titoli sezioni card cliente, badge template) |
| `#f0f9ff` / `#e0f2fe` / `#bae6fd` / `#7dd3fc` / `#cdecf9` | bg azzurri chiari (riga editing, azioni schede cliente, hover) |

#### Ciano (circuiti / cleaning pip)
| Hex | Uso |
|---|---|
| `#06b6d4` / `#0891b2` / `#0e7490` | tema "circuito" (CC) e bottoni cyan |
| `#ecfeff` / `#cffafe` / `#67e8f9` | bg ciano chiari |

#### Rosa/pink
| Hex | Uso |
|---|---|
| `#be185d` / `#fce7f3` | stat "pink" card cliente, avatar rosa |

#### Scuri hero/navy
| Hex | Uso |
|---|---|
| `#0b1220` / `#0e1f33` | start/mid dei gradient hero scuri (editor schede, assign bar, Importa) |
| `#1f2937` / `#374151` | hero slot "precedente" (Live) |
| `#2a1f3d` | mid del gradient week-bar mobile |
| `#080808` / `#111` / `#091616` / `#1a2a2a` | gradient sfondo login admin / hero pubblico |

#### Altri
| Hex | Uso |
|---|---|
| `#25D366` / `#1ebe5a` | FAB WhatsApp |
| `#1877F2` | bottone Facebook login |
| `#d1d5db` / `#b8c0cc` / `#d5dae2` / `#b0b6bf` / `#eef0f3` / `#eef2f7` / `#e8eaed` / `#f0f1f3` / `#f8f9fb` / `#fbfcfe` / `#fafcfd` / `#f6f8fa` / `#fffbf0` / `#f4f4f4` / `#f8f8f8` / `#e0e0e0` / `#e8e8e8` / `#f0f0f0` | micro-varianti di grigi per bordi/divisori/bg specifici |
| `#1c1917` / `#1917` | testo quasi-nero warm nelle Impostazioni legacy |

---

### 2.3 Tipografia

| Proprietà | Valore |
|---|---|
| Font family (unica) | `'Segoe UI', Tahoma, Geneva, Verdana, sans-serif` — in Flutter: `Segoe UI` su Windows, fallback sistema (es. SF/Roboto). Monospace solo su `.hint` (login) |
| Base | body: `line-height 1.6`, colore `#333333` |
| Root size | 16px mobile, **12px desktop (≥769px)** |
| Numeri | `font-variant-numeric: tabular-nums` su tutti i valori numerici (stat, orari, importi, paginazione) → in Flutter usare `FontFeature.tabularFigures()` |

Scala effettiva usata (peso → esempi):

| Ruolo | Size | Weight | Extra |
|---|---|---|---|
| Stat value | `2rem` (mobile 1.15–1.4rem) | 800 | `letter-spacing -0.02em` |
| Payment total | `1.85rem` | 800 | `-0.02em` |
| Titolo pagina tab (`.tab-page-title h2`) | `1.65rem` | 800 | `-0.02em`; sottotitolo `0.8rem` 500 `#94a3b8` |
| Titoli hub (`.msg-header h3`, `.sett-header h3`) | `1.4rem` | 800 | `-0.02em` |
| Titolo Registro / schede-header | `1.3–1.5rem` | 800 | |
| Orario slot live (`.sa-time-now`) | `1.85rem` (mobile 1.6) | 800 | tabular |
| Titoli card/modali h3 | `1.05–1.25rem` | 700–800 | |
| Testo card principale | `0.9–0.95rem` | 600–700 | |
| Testo secondario/meta | `0.78–0.85rem` | 500–600 | `#64748b`/`#94a3b8` |
| Label uppercase (kicker) | `0.62–0.78rem` | 700–800 | `text-transform: uppercase`, `letter-spacing 0.04–0.12em` |
| Micro-testi (count, hint) | `0.55–0.72rem` | 600–800 | |
| Pesi presenti | 400 (raro), 500, 600, 700, 800, 900 (`.schede-stat-value`, `.importa-hero-stat .v`) | | |

---

### 2.4 Spaziature, radius, ombre, transizioni, animazioni

**Spaziatura**: nessuna scala formale; ricorrono `0.3/0.4/0.5/0.6/0.75/0.85/1/1.2/1.5/2rem`. Gap standard liste card: `0.5–0.75rem` (mobile `0.4–0.6rem`, liste v2 `4–8px`). Padding card: `1.1–1.4rem × 1.3rem` desktop, `0.75–1rem` mobile.

**Border-radius** (px): `4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20` + `999px/50px` (pill) + `50%` (cerchi). Convenzioni: input/bottoni `8–10`, card `12–16`, hero/modali grandi `16–20`, chip sempre pill (`20px` o `999px`).

**Box-shadow principali** (esatte):

| Nome/uso | Valore |
|---|---|
| Card leggera | `0 1px 3px rgba(15,23,42,0.06), 0 1px 2px rgba(15,23,42,0.04)` (o `0 1px 3px rgba(15,23,42,0.04/0.05)`) |
| Card standard (hub) | `0 2px 8px rgba(0,0,0,0.04), 0 0 0 1px rgba(0,0,0,0.02)` |
| Stat card | `0 1px 3px rgba(0,0,0,0.03), 0 4px 14px rgba(0,0,0,0.04)` |
| Contenitore lista slot | `0 1px 4px rgba(0,0,0,0.04), 0 4px 16px rgba(0,0,0,0.03)` |
| Hover card cliente | `0 8px 22px rgba(15,23,42,0.09)` (open: `0 10px 28px rgba(15,23,42,0.11)`) |
| Bottone brand | `0 2px 8px rgba(139,92,246,0.25–0.3)` → hover `0 4px 12–14px rgba(139,92,246,0.35–0.4)` |
| FAB | `0 4px 14px rgba(139,92,246,0.35)` → hover `0 6px 20px rgba(139,92,246,0.45)` |
| Focus ring input | `0 0 0 3px rgba(139,92,246,0.1)` (o 4px: `0 0 0 4px rgba(139,92,246,0.1), 0 4px 12px rgba(139,92,246,0.06)`) |
| Tab/pill attiva | `0 2px 8px rgba(139,92,246,0.3)` |
| Modale media | `0 12px 40px rgba(0,0,0,0.18)` |
| Modale grande | `0 20px 60px rgba(0,0,0,0.2–0.3)` / `0 24px 64px rgba(0,0,0,0.22–0.25)` / `0 25px 70px rgba(0,0,0,0.2)` |
| Bottom sheet | `0 -10px 30/40px rgba(0,0,0,0.15–0.18)` |
| Dock viola mobile | `0 12px 24px -8px rgba(124,58,237,0.45), 0 4px 10px -4px rgba(15,23,42,0.20), inset 0 1px 0 rgba(255,255,255,0.25)` |
| Login box (dark) | `0 28px 80px rgba(0,0,0,0.65), 0 0 60px rgba(139,92,246,0.06)` |
| Week-bar hero mobile | `0 6px 16px -6px rgba(15,23,42,0.35), 0 2px 4px -2px rgba(15,23,42,0.18)` |

**Transizioni**: standard `all 0.25s cubic-bezier(0.4,0,0.2,1)` (varianti 0.15/0.18/0.2s); stat-card `transform 0.28s cubic-bezier(0.22,1,0.36,1)`; sheet `transform 0.3s cubic-bezier(0.4,0,0.2,1)`; spring (allenamento) `0.35s cubic-bezier(0.34,1.56,0.64,1)`; micro-interazioni hover `translateY(-1/-2/-3px)`, active `scale(0.97–0.985)` o `translateY(0/1px)`.

**@keyframes** (nome → effetto):

| Keyframe | Effetto |
|---|---|
| `fadeIn` | opacity 0→1 + translateY(10px)→0, 0.3s — switch tab content |
| `slideUp` | translateY(30px)+fade→0, 0.25s — modal-box |
| `slideUpSheet` | translateY(100%)→0, 0.3s — bottom sheet modale mobile |
| `socialSlideDown` | translateY(-100%)→0 — modale conferma social |
| `btn-spin` / `allSpin` | rotate 360°, 0.7s linear infinite — spinner bottoni/loading |
| `skeleton-pulse` | opacity 1→0.4→1, 1.2s infinite — skeleton stat |
| `statDetailFadeIn` | fade + translateY(-8px)→0, 0.25s — pannello dettaglio statistiche |
| `bannerSlideIn` | fade + translateY(-12px)→0, 0.4s — banner report settimanale |
| `schede-pulse` | opacity 1→0.6→1, 1.5s infinite — loading schede |
| `schede-slide-up` | fade + translateY(12px)→0 |
| `schede-glow` | box-shadow glow viola 8→18px, pulsante |
| `sa-pulse` | opacity 1→0.35→1, 1.6s — pallino LIVE |
| `msg-fade-in` | fade + translateY(10px)→0, 0.4s — hub Messaggi/Impostazioni/Prenotazioni |
| `msg-pulse-send` | pulsazione shadow viola su bottone invio |
| `importaFadeIn` / `importaSlideUp` | fade overlay / translateY(20px)+fade modale Importa |
| `extraPickerSlideUp` / `extraPickerFadeIn` | sheet da sotto (mobile) / fade+scale 0.96 (desktop) |
| `allSlideDown` | fade + translateY(-8px)→0, 0.3s — apertura body card esercizio |

---

### 2.5 Bottoni (tutte le varianti)

| Variante | Stile esatto |
|---|---|
| **Primario globale** `.btn-primary` | bg `#8B5CF6`, testo bianco bold, padding `1rem 2rem`, font `1.1rem`, radius `5px`, width 100%; hover: bg `#7C3AED`, `translateY(-2px)`, shadow `0 4px 12px rgba(139,92,246,0.3)`; disabled: bg `#ccc` |
| **Primario admin (gradient)** — `.msg-send-btn`, `.sett-save-btn`, `.btn-import-week`, `.sched-btn-primary`, `.adm-datepop-btn`, `.adm-sheet-btn--primary`, `.btn-apply-filter`, `.importa-bulk-btn`, `.schede-save-btn` | bg `linear-gradient(135deg,#8B5CF6,#7C3AED)`, testo `#fff` 700, radius `10px` (save schede 12px), padding tipico `0.5rem 1rem`–`0.7rem 1.6rem`, shadow `0 2px 8px rgba(139,92,246,0.25)`; hover shadow `0 4px 14px rgba(139,92,246,0.4)` + `translateY(-1px)`; alcune varianti uppercase + `letter-spacing 0.04em` |
| **Danger** `.btn-delete` | bg `linear-gradient(135deg,#ef4444,#dc2626)`, bianco 600, padding `0.45rem 0.9rem`, radius 10, shadow `0 2px 6px rgba(239,68,68,0.2)`; hover shadow `0 4px 12px rgba(239,68,68,0.35)` |
| **Success** `.btn-add-slot` | bg `linear-gradient(135deg,#06d6a0,#05b886)`, bianco 700, padding `0.65rem 1.4rem`, radius 10, shadow `0 2px 8px rgba(6,214,160,0.3)`; `.btn-pay-all`: bg `#06d6a0`, hover `#059669` + `scale(1.03)`; `.btn-save-edit`: bg `#06d6a0` radius 6 |
| **Ghost/outline** `.btn-clear-week`, `.sched-btn-ghost`, `.registro-pag-btn`, `.btn-template-cancel`, `.adm-topbar-btn` | bg `#fff`, border `1.5px #e2e8f0` (o 1px), testo `#64748b`/`#475569` 600–700, radius 10; hover: border+testo `#8B5CF6` (o rosso per azioni distruttive: `.btn-clear-week` hover border `#ef4444` bg `#fef2f2`) |
| **Ghost grigio** `.cancel-popup-btn--cancel`, `.cert-modal-btn--cancel`, `.adm-sheet-btn--ghost`, `.btn-cancel-edit` | bg `#f3f4f6`/`#f1f5f9`, testo `#374151`/`#475569`, radius 8–10 |
| **Conferma distruttiva** `.cancel-popup-btn--confirm`, `.cert-modal-btn--save` | bg `#ef4444`, bianco 600, radius 8; disabled opacity 0.4 |
| **Icon button 30×30** `.btn-row-edit/.btn-row-delete/.btn-row-save/.btn-row-cancel`, `.tpl-act` | 30×30px (varianti 28×28 radius 7), border `1px #e5e7eb`, radius 5–8, bg none; edit color `#f59e0b` hover border `#f59e0b` bg `rgba(245,158,11,0.06)`; delete color `#94a3b8` hover `#ef4444` bg `rgba(239,68,68,0.06)`; save border `#22c55e` hover bg pieno |
| **FAB** `.scroll-slot-fab` (52px), `.payments-fab`/`.schede-fab`/`.adm-mob-fab` (56px) | cerchio, bg `#8B5CF6` (adm-mob-fab gradient), bianco, `bottom/right 1.5rem`, shadow `0 4px 14px rgba(139,92,246,0.35)`, hover `translateY(-2px)` + `0 6px 20px rgba(...,0.45)`; z-index 1000; mobile: `bottom calc(84px + safe-area)` (134px con pill filtri) |
| **Azioni Impostazioni** `.sett-action-btn--{blue,purple,green,red,cyan}` | gradient 135deg: blue `#2563eb→#1d4ed8`, purple `#7c3aed→#6d28d9`, green `#059669→#047857`, red `#ef4444→#dc2626`, cyan `#0891b2→#0e7490`; shadow `0 2px 8px rgba(colore,0.3)`; `--ghost`: bg `rgba(255,255,255,0.06)` testo `#cbd5e1` border `rgba(255,255,255,0.14)`; `--muted`: bg `#e2e8f0` testo `#64748b` |
| **CTA dashed "aggiungi"** `.schede-add-exercise-btn` (viola), `.schede-add-ss-btn` (ambra), `.schede-add-cc-btn` (ciano) | bg `rgba(colore,0.06)`, border `1.5–2px dashed rgba(colore,0.35–0.40)`, testo colore pieno 700–800 uppercase, radius 10–12; hover bg `rgba(colore,0.10)` border solida |
| **Paginazione** `.show-more-btn` | border `1px #d1d5db`, radius 6, testo `#6b7280` `0.8rem`; hover bg `#f3f4f6`; `.clients-load-more`: full-width; `.importa-load-more-btn`: border `2px #e2e8f0` radius 10, hover border `#8B5CF6` bg `#e0f2fe` |
| **Frecce settimana** `.schedule-week-btn` | 36×36 (mobile 30×30), radius 10 (9), bg `linear-gradient(135deg,#f1f5f9,#e8ecf1)` border `#e2e8f0`; hover diventa gradient viola pieno; su hero scuro mobile: bg `rgba(255,255,255,0.08–0.12)` border `rgba(255,255,255,0.16)` bianco |
| **+ circolari** `.btn-add-extra` (2rem, border 2px viola, hover inverso), `.btn-add-extra--inline` (1.85rem, bg `rgba(139,92,246,0.12)`), `.btn-add-extra--swipe` (2.5rem bg viola pieno) | |
| **Loading state** `.btn-loading` + `.btn-spinner` | spinner 14px, border `2px rgba(255,255,255,0.4)` top `#fff`, `btn-spin 0.7s linear infinite`; bottone `opacity 0.8` non cliccabile |

---

### 2.6 Input, select, textarea, toggle, checkbox

| Componente | Valori |
|---|---|
| **Input standard admin** (`.msg-input`, `.form-group-schedule input/select`, `.schede-search-bar input`) | padding `0.6rem 0.85rem`, border `2px solid #e2e8f0`, radius `10px` (search 12px), font `0.95rem`, colore `#0f172a`, bg `#fff`, shadow `0 1px 3px rgba(0,0,0,0.03)`; **focus**: border `#8B5CF6`, ring `0 0 0 4px rgba(139,92,246,0.1), 0 4px 12px rgba(139,92,246,0.06)`; placeholder `#94a3b8` |
| **Input sottile** (popup, filtri: `.manual-note-input`, `.reg-panel-select/date/search`, `.sett-text-input`) | border `1.5px #e5e7eb`/`#e2e8f0`, radius 10, bg `#f8f9fa`/`#f8fafc`, font `0.82–0.88rem`; focus border `#8B5CF6` + ring 3px, bg `#fff`; height filtri `36px` |
| **Search con icona** `.search-input-group` | icona `🔍` assoluta a sinistra (opacity 0.45), input padding-left `2.5rem`, border `1.5px #e5e7eb`, radius 12, bg `#fafafa` |
| **iOS anti-zoom** | tutti gli input mobile hanno `font-size: 16px` esplicito |
| **Importo grande** `.manual-amount-input` | `2.8rem` 700 centrato, senza bordo, sotto riga `border-bottom 2px #e8e8e8` (focus viola), simbolo € `1.6rem` `#ccc`→viola su focus, caret viola |
| **Toggle iOS** `.cedit-toggle-switch` | 44×24px, track `#d1d5db` radius 24, thumb 18px bianco (shadow `0 1px 2px rgba(0,0,0,0.2)`), checked: track `#8B5CF6`, thumb `translateX(20px)`; focus-visible outline 2px viola |
| **Toggle Impostazioni** `.settings-toggle-track` | 42×24 (dentro `.sett-card`: 44×26, inset shadow `inset 0 1px 3px rgba(0,0,0,0.1)`, checked gradient viola + shadow) |
| **Toggle schede** `.schede-toggle` | 46×26, track `#94a3b8` radius 13, thumb 20px; checked gradient viola + glow `0 0 10px rgba(139,92,246,0.3)` |
| **Checkbox/radio** | native con `accent-color: #8B5CF6` (17–18px); radio custom sheet mobile: cerchio 22px border `2px #cbd5e1`, attivo bg viola + pallino bianco 8px |
| **Radio-card** `.settings-option`, `.msg-recipient-opt`, `.sett-model-opt` | border `1.5px #e5e7eb/#e2e8f0` radius `0.6rem–12px`, checked (`:has(input:checked)`) border `#8B5CF6` + bg `#f0fbff`/gradient azzurro + shadow `0 2px 10px rgba(139,92,246,0.1)` |
| **Select con chevron custom** | `appearance:none` + `background-image` SVG data-URI (freccia `#8B5CF6` o colore contestuale), `background-position right 8–10px center` — usato in assign-bar dark, Importa, select tipo-slot mobile |
| **Color picker** `.sett-color-input` | 46×38, border `1.5px #e2e8f0` radius 10 + campo hex `.sett-text-input--hex` largo 110px uppercase |
| **Textarea** | come input; `resize: vertical`; note schede `font-style: italic` |

---

### 2.7 Chip e badge (tutte le varianti di stato)

| Gruppo | Variante → bg / testo |
|---|---|
| **Stato prenotazione** `.status-badge` (pill radius 20, `0.85rem` 600) | `confirmed` `rgba(6,214,160,0.2)` / `#06d6a0` · `pending` `rgba(255,193,7,0.2)` / `#f77f00` · `cancellation_requested` `#fef3c7` / `#92400e` · `cancelled` `#f3f4f6` / `#6b7280` |
| **Pagamento** `.payment-status` (pill `0.75rem` 700; v2: inline-flex radius 999) | `paid` `rgba(34,197,94,0.1–0.12)` / `#06d6a0` · `unpaid` `rgba(245,158,11,0.1)` / `#d97706` (cliccabile, hover 0.2) |
| **"Da pagare"** `.debt-warning` (v2 pill) | `rgba(245,158,11,0.16)` / `#b45309`, hover `0.26` |
| **Chip saldo** `.saldo-chip` (pill 999, `0.78rem` 800, tabular) | `owes` `rgba(239,68,68,0.12)` / `#dc2626` (cliccabile) · `zero` `#f3f4f6` / `#6b7280`; etichetta `.participant-saldo-status`: owes `#b45309`, paid `#15803d` |
| **Stat cliente** `.cstat` (pill 20, `0.82rem` 600) | default `rgba(59,130,246,0.10)` / `#1d4ed8` · `paid` `rgba(34,197,94,0.1)` / `#166534` · `free` `rgba(22,163,74,0.08)` / `#15803d` · `unpaid` `rgba(239,68,68,0.1)` / `#991b1b` · `credit` `rgba(139,92,246,0.12)` / `#0369a1` |
| **Certificato medico** `.cedit-cert-*` (pill 20, `0.78rem` 600) | `expired` `#fef2f2` / `#dc2626` · `expiring` `#fffbeb` / `#92400e` · `ok` `#f0fdf4` / `#166534`; banner `.cert-expired-badge`: bg `#fef2f2`, `border-left 3px #dc2626` |
| **Tipo evento Registro** `.rtype-*` (pill 20, `0.74rem` 700) | `booking` `#dbeafe`/`#1d4ed8` · `paid` `#dcfce7`/`#15803d` · `cancelled` `#fee2e2`/`#b91c1c` · `pending` `#fef3c7`/`#92400e` · `credit` `#f3e8ff`/`#7e22ce` · `creditused` `#e0f2fe`/`#0369a1` · `refund` `#cffafe`/`#0e7490` · `debt` `#fef9c3`/`#854d0e` · `debtpaid` `#d1fae5`/`#065f46` · `mora` `#fde68a`/`#92400e` |
| **Stato Registro** `.rstatus-*` (pill 20, `0.74rem` 600) | `paid` `rgba(6,214,160,0.15)`/`#059669` · `unpaid` `#fee2e2`/`#b91c1c` · `cancelled` `#f3f4f6`/`#6b7280` · `pending` `#fef3c7`/`#92400e` · `credit` `#f3e8ff`/`#7e22ce` · `debt` `#fef9c3`/`#854d0e` |
| **Badge mobile Registro** `.reg-mob-badge` (pill 999, `10.5px` 800) | `gift` `#ede9fe`/`#6d28d9` · `paid` `#dcfce7`/`#166534` · `due` `#fef3c7`/`#b45309` · `cancel` `#fee2e2`/`#991b1b` · `pending` `#fef3c7`/`#92400e` · `auto` `#f1f5f9`/`#475569` · `admin` `#fde68a`/`#92400e` · `system` `#d1fae5`/`#065f46` |
| **Tipo slot (badge pieno)** `.schedule-slot-type-badge` / `.current-type-badge` (pill 20, `0.8rem` 700) | `personal-training` bg `#22c55e` bianco · `small-group` bg `#fbbf24` bianco · `group-class` bg `#ef4444` testo `#333` · `cleaning` bg `#8b5cf6` bianco |
| **Tipo slot (tinta)** `.split-col-title` / `.tpl-slot-badge` / `.extra-badge` | PT `#dcfce7`/`#16a34a` (tpl: `rgba(34,197,94,0.12)`/`#15803d`) · SG `#fef9c3`/`#b45309` (tpl `rgba(234,179,8,0.12)`/`#a16207`) · GC `#fee2e2`/`#dc2626` · CL `#ede9fe`/`#7c3aed` |
| **Schede** | `.schede-badge-active` gradient `#dcfce7→#bbf7d0` / `#14532d`, border `rgba(34,197,94,0.2)` · `.schede-badge-inactive` gradient `#fee2e2→#fecaca` / `#7f1d1d` · `.schede-badge-template` gradient `#0c4a6e→#0369a1` / `#e0f2fe` uppercase · `.schede-cc-pill`/`.schede-cd-statepill` green `#dcfce7`/`#166534` + dot `#16a34a`, gray `#f1f5f9`/`#64748b`+dot `#94a3b8` · muscolo `.schede-ex-muscle-badge` gradient `#e0f2fe→#bae6fd`/`#0369a1` (editor: `rgba(139,92,246,0.10)`/`#7C3AED` pill) · badge blocco SS gradient `#f59e0b→#f97316`, CC `#06b6d4→#0891b2` (bianco, uppercase, top -9px) |
| **Ruoli staff** `.sett-role-badge` (radius 6, `0.68rem` 800 uppercase) | `owner` `#fef3c7`/`#b45309` · `admin` `#ede9fe`/`#6d28d9` · `staff` `#e0f2fe`/`#0369a1` |
| **Gestione orari** `.sched-badge` | `--muted` `#f1f5f9`/`#64748b` · `--off` `#fef2f2`/`#dc2626`; `.sched-time-chip` `#f1f5f9`/`#334155` radius 8 |
| **Header hub** `.msg-header-badge`/`.sett-header-badge` | pill 20, `0.7rem` 800 uppercase ls 0.1em, testo `#8B5CF6`, bg gradient `rgba(139,92,246,0.08→0.15)`, border `rgba(139,92,246,0.2)` |
| **Importo debito** `.debtor-amount` | pill 20, bg `rgba(239,68,68,0.08)` testo `#ef4444` border `rgba(239,68,68,0.15)`; variante `--paid`/credito: verdi `rgba(34,197,94,0.08)`/`#166534` (credito `#16a34a`) |
| **Pill hero Live** `.sa-pill` | `--live` bg `#dc2626` bianco + dot pulsante · `--prev` `rgba(255,255,255,0.12)`/`#cbd5e1` · `--next` `rgba(124,58,237,0.3)`/`#ddd6fe`; tipo slot su scuro `.sa-type`: bg `rgba(colore,0.18)` testo tinta chiara border `rgba(tinta,0.3)` |
| **Avatar con iniziali** | `.cv2-avatar` 44px `#ede9fe`/`#7c3aed` (open `#ddd6fe`) · `.participant-avatar` 38px (mobile 34) hue 0–5: `#cdecf9`/`#0b7fb0`, `#fef3c7`/`#b45309`, `#f3e8ff`/`#7e22ce`, `#dcfce7`/`#166534`, `#fee2e2`/`#b91c1c`, `#e0f2fe`/`#075985` · `.sa-av` 36px blue `#dbeafe`/`#1d4ed8`, green `#dcfce7`/`#166534`, amber `#fef3c7`/`#b45309`, purple `#ede9fe`/`#6d28d9`, pink `#fce7f3`/`#be185d` · `.schede-cc-av` 42px c1–c5 analoghi · `.manual-client-avatar` 2rem gradient viola bianco |

---

### 2.8 Card generiche

| Card | Valori chiave |
|---|---|
| `.dashboard-card` | bg bianco, padding `2rem` (mobile 0.75–1rem), radius 12, shadow `0 4px 12px rgba(0,0,0,0.1)` |
| `.stat-card` | bg `#fff`, padding `1.4rem 1.35rem 1.2rem`, radius 16, border `1px rgba(0,0,0,0.06)`, shadow stat (v. §2.4), `::after` barra top 3px colorata (default `#d1d5db`), hover `translateY(-3px)` + glow colorato per card; h3 label `0.7rem` uppercase `#9ca3af`; `.stat-icon` 2.85rem quadrato radius 12 bg `#f3f4f6` (tinte per card `rgba(colore,0.10)`); `.stat-change.positive` `#059669`/`rgba(16,185,129,0.1)`, `.negative` `#dc2626`/`rgba(239,68,68,0.08)` |
| `.payment-stat-card` | bianco, border `1px #e5e7eb`, radius 16, padding `1.2rem 1.1rem 1rem`, centrata, `::before` barra sinistra 4px (debitori gradient `#ef4444→#dc2626`, creditori `#22c55e→#16a34a`, clients viola→`#0284c7`); `--clickable` hover `translateY(-2px)` + `0 6px 20px rgba(0,0,0,0.09)` |
| `.msg-card` / `.sett-card` | bianco, border `1px #e2e8f0`, radius 14, padding `1.1–1.2rem 1.3rem`; `::before` 3px top gradient `90deg #8B5CF6,#7C3AED,#8B5CF6` visibile su hover/focus-within; `.sett-card--danger`: border `#fecaca`, barra `#ef4444→#dc2626`; icone `.sett-card-icon` 36px radius 10 con bg tinta (cyan/amber/red/blue/green/purple = gradient `rgba(colore,0.08–0.1)→rgba(colore,0.16–0.2)`) |
| `.reg-panel` | bianco, border `#e2e8f0`, radius 14, shadow standard; filtri interni bg `#f8fafc` |
| `.stats-detail-panel` | bianco, radius 18, padding 1.5rem, shadow `0 1px 3px rgba(0,0,0,0.03), 0 8px 24px rgba(0,0,0,0.06)`, `::before` 3px top gradient multicolore `#f59e0b,#3b82f6,#10b981,#8b5cf6` opacity 0.65, anim `statDetailFadeIn` |
| KPI mini `.stat-detail-kpi` | bg `#f9fafb` border `#e5e7eb` radius 12, barra sinistra 3px; varianti: `--actual` `#eff6ff`/`#dbeafe`, gradient blu, valore `#2563eb` · `--future` `#fef2f2`/`#fecaca`, rosso, `#dc2626` · `--projected` `#f0fdf4`/`#bbf7d0`, verde, `#059669` · `--warn` `#fff7ed`/`#fed7aa`, ambra, `#d97706` |

---

### 2.9 Tabelle

| Tabella | Valori |
|---|---|
| `.bookings-table` | th: bg `#1a1a1a`, bianco, padding 1rem, 600; td padding 1rem, border-bottom `1px #eee`; hover riga bg `#f8f9fa`. Mobile: padding `0.45rem 0.4rem`, font `0.76rem`, colonna 5 (WhatsApp) nascosta |
| `.registro-table` | `min-width 860px` in wrapper `overflow-x:auto` (border `#e2e8f0`, radius 14); thead gradient `#f1f5f9→#e8ecf1`; th `0.78rem` 700 uppercase `#475569` ls 0.06em; td `0.55rem 0.5rem`, border-bottom `#f1f5f9`, testo `#1e293b`; hover `#f8fafc`; righe **admin** bg `#fef2f2` (hover `#fee2e2`), righe **system** `#f0fdf4` (hover `#dcfce7`); colonne: timestamp `#888 0.78rem` tabular, importo `#059669` 700, note ellipsis max 150px; th ordinabili hover `#8B5CF6` |
| `.client-bookings-table` | font `0.93rem`; th `#999 0.82rem` border-bottom `2px #f3f4f6`; righe future bg `#fef2f2` (hover `#fee2e2`); annullate testo `#bbb` line-through; editing bg `#f0f9ff`; mobile nasconde colonne 5–6 |
| `.schede-progress-table` | th gradient `#f8fafc→#f1f5f9`, `0.76rem` uppercase `#475569`, border-bottom `2px #e2e8f0`; esiti: `ok` `#15803d` 700 · `close` `#ca8a04` · `miss` `#dc2626` |
| `.sched-grid` (settimana tipo) | min-width 640, celle border `#eef2f7`, thead `#f8fafc` sticky, colonna orari `#f8fafc` testo `0.74rem` 700; cella con tipo bg `#faf5ff`, dot colore 8px in alto a destra, select/cap interni `0.72rem` radius 7 |

---

### 2.10 Modali, overlay, bottom sheet

| Modale | Dimensioni | Radius | Backdrop | Animazione |
|---|---|---|---|---|
| `.modal-box` (globale) | max-w 680, max-h 90vh, padding 2rem | 16 | `rgba(0,0,0,0.55)` | `slideUp` 0.25s; ≤600px: bottom-sheet `80dvh`, radius `16 16 0 0`, drag-handle 36×4 `#ccc`, X nascosta |
| `.edit-client-popup` | max-w 480, max-h 90vh | 14 | `rgba(0,0,0,0.45)` z 9999 | fade 0.2s + translateY(20→0) |
| `.edit-entry-popup` | `min(92vw,380px)` | 14 | `rgba(0,0,0,0.4)` z 10000 | fade |
| `.cancel-popup` | `min(380px,92vw)` | 16 | `rgba(0,0,0,0.55)` z 2000 | fade + scale 0.95→1 |
| `.cert-modal` | `min(360px,92vw)` | 16 | (riusa debt overlay) z 1001 | — |
| `.debt-popup-modal` (incasso) | `min(500px, 100vw−32px)`, max-h 82vh (mobile `100vw−16px`, 88vh) | 16 (mobile 12) | `rgba(0,0,0,0.55)` z 2000/2100 | fade + translate(-50%,-46%→-50%) 0.22s; header/footer border `#f0f0f0`; temi: `--debt` bg `#fef2f2` titolo `#dc2626` btn `#ef4444`; `--credit` bg `#f0fdf4` titolo `#16a34a` btn `#22c55e` |
| `.template-editor-popup` | max-w 560, max-h 90vh | 14 | `rgba(0,0,0,0.45)` z 9999 | — (header/footer bg `#f9fafb`) |
| `.msg-popup` (esito invio) | max-w 420, 92%, max-h 75vh | 18 | `rgba(15,23,42,0.5)` + blur 4px, z 9998/9999 | `msg-fade-in` |
| `.schede-actual-popup` | max-w 440 | 18 (mobile 16) | `rgba(15,23,42,0.55)` + blur 4, z 10000 | fade + translateY(12)+scale(0.97→1) 0.25s |
| `.schede-ex-picker-dropdown` | fullscreen mobile; desktop 600px, top/bottom 5vh | 0 / 16 + border `2px #8B5CF6` | `rgba(0,0,0,0.4)` z 10001/10002 | —; topbar gradient viola, bianco |
| `.schede-ex-detail-overlay` | panel 600, max-h 90vh | 16 | `rgba(0,0,0,0.6)` + blur 4, z 10003 | translateY(20→0) 0.3s |
| `.importa-detail-modal` | max-w 560 | 20 | `rgba(0,0,0,0.6)` + blur 4, z 9999 | `importaSlideUp` |
| `.schede-report-modal` | max-w 720, max-h 85vh (mobile 92vh) | 18 (16) | `rgba(15,23,42,0.6)` + blur 5, z 10001 | translateY(12)+scale(0.97→1) |
| `.payments-sheet` (bottom sheet) | full-width; desktop ≥768: 420px centrato, bottom 5vh | `20 20 0 0` (desktop 20) | `rgba(0,0,0,0.4)` + blur 4, z 9998/9999 | translateY(100%→0) 0.3s; handle 36×4 `#e2e8f0`; opzioni con icona 40px gradient (credit verde, debt rosso, checkfisico viola) |
| `.adm-sheet` (sheet filtri/menu mobile) | full-width, max-h 82vh | `20 20 0 0` | `rgba(15,23,42,0.45)` z 1100/1101 | translateY(100%→0) 0.3s; grabber 40×4 `#cbd5e1`; item attivo bg `rgba(139,92,246,0.08)` border `rgba(139,92,246,0.25)` |
| `.extra-picker` (scelta tipo posto extra) | sheet mobile max-w 500; desktop centrato 420 | `16 16 0 0` / 16 | `rgba(15,23,42,0.55)` + blur 2, z 9999 | `extraPickerSlideUp` / FadeIn |
| `.all-detail-overlay` (edit esercizio mobile, da allenamento.css) | panel max-w 560, full-height, bg `#f1f5f9` | — | `rgba(15,23,42,0.55)` + blur 6, z 10000 | fade + translateY(24→0); `pointer-events:none` quando nascosto |

Pattern chiusura: bottone X circolare 32–36px, bg `rgba(0,0,0,0.06)` o `#f1f5f9`, hover più scuro (dettaglio esercizio: hover bg `#ef4444` bianco).

---

### 2.11 Toast, spinner, skeleton, empty state, paginazione

- **Toast** (`style.css`): container `fixed bottom 24px` centrato, max-w 420, z 9999; toast: padding `12px 18px`, radius 12, bianco 500 `0.9rem`, shadow `0 4px 20px rgba(0,0,0,0.18)`, fade+translateY(12→0) 0.25s; **success `#06d6a0` · error `#ef4444` · info `#8B5CF6`**; cliccabile per chiudere.
- **Spinner**: `.btn-spinner` (14px, v. §2.5); `.all-loading::before` 36px, border `3px #e2e8f0` top `#8B5CF6`, `allSpin 0.7s`.
- **Skeleton**: `.stat-card--loading .stat-value/.stat-change` e `.payment-stat-card--loading .payment-total` → testo trasparente, bg `#e5e7eb`, radius 6, `skeleton-pulse 1.2s infinite`; larghezze 55–80%, min-height 0.9–2rem.
- **Empty state**: `.empty-slot` corsivo `#94a3b8` `0.88rem` · `.registro-empty`/`.importa-empty` padding 3rem `#94a3b8` · `.cv2-seg-empty` `#94a3b8` 600 · `.sched-empty`/`.adm-mob-empty` bg `#f8fafc`/bianco con `border 1px/1.5px dashed #e2e8f0/#cbd5e1` radius 12 · `.msg-popup-empty`, `.dropdown-no-results`, `.slot-client-no-results` `#999–#94a3b8` centrati.
- **Paginazione**: Registro `.registro-pagination` (bottoni ghost + info `0.82rem` tabular, min-width 130, disabled opacity 0.3); liste "mostra altri" `.show-more-btn`/`.clients-load-more`; Importa `.importa-load-more-btn` + `.importa-load-more-done` (`0.78rem #94a3b8`).

---

### 2.12 Navigazione: tab, pill, sidebar, dock

- **Barra tab principale** `.admin-tabs` (visibile solo 769–1023px; nascosta su mobile e desktop ≥1024): sticky `top var(--admin-tabs-top,72px)` z 13, bg gradient `135deg #f1f5f9→#e8ecf1`, border `#e2e8f0`, radius 14, padding 5px, gap 4, max-w 1280 centrata, shadow `0 1px 4px rgba(0,0,0,0.04), 0 4px 8px rgba(0,0,0,0.06)`. Tab `.admin-tab`: padding `0.6rem 1.1rem`, `0.95rem` 700, colore `#64748b`, radius 10; hover bg `rgba(255,255,255,0.7)` testo `#334155`; **attiva**: bianco su gradient `135deg #8B5CF6→#7C3AED` + shadow `0 2px 8px rgba(139,92,246,0.3)`. Variante `.admin-tab--privacy`: `0.75rem`, opacity 0.55, attiva gradient ambra `#f59e0b→#d97706`. Anti-flash: `html[data-initial-tab]` mostra subito il tab salvato.
- **Tab underline** (`.analytics-filter-bar .filter-btn`, `.registro-subtab`, `.schede-subnav-pill`): barra con solo `border-bottom 1px #e2e8f0`; bottone trasparente `0.88rem` 600 `#64748b`, `border-bottom 3px transparent` (schede 2px); attivo: testo `#7C3AED` 700 + underline `#8B5CF6`.
- **Segmented control** (`.cv2-segmented`, `.sched-nav`, `.sett-nav`, `.importa-view-toggle`): track bg `#eef2f6`/`#f1f5f9` radius 11–12 padding 3–4px; bottone attivo bg `#fff` testo `#7C3AED` shadow `0 1px 4px rgba(15,23,42,0.08–0.10)` (Importa: attivo gradient viola pieno + count pill `rgba(255,255,255,0.22)`).
- **Pill filter** (`.rfilter-btn`, `.adm-filt-pill`, `.adm-datepop-preset`, `.clients-filter-chip`): pill radius 20/999, bg `#f8fafc`/`#fff`, border `1.5px #e2e8f0`, `0.8rem` 600 `#475569`; hover border/testo viola; attiva gradient viola bianco + shadow; chip clienti "filtri" attiva tema **rosso** (`#fef2f2`/`#ef4444`/`#dc2626`); `.rfilter-btn--reset` rosso.
- **Sidebar desktop ≥1024** `.adm-sidebar`: 240px fissi, sticky `top 72px`, bg `#fff`, `border-right 1px #e2e8f0`, scrollbar 6px `#e2e8f0`; heading `0.7rem` uppercase `#94a3b8`; item: radius 8, `0.82rem` 600 `#334155`, icona SVG 16px `#64748b`, min-height 36; hover bg `#f8fafc`; **attivo** bg `rgba(139,92,246,0.08)` testo+icona `#7C3AED`; divider `#e2e8f0`; azione "premuta" ambra `rgba(245,158,11,0.1)`/`#b45309`. Topbar `.adm-topbar`: bottoni ghost (Esporta/Data) allineati a destra, border-bottom `#e2e8f0`; popover data `.adm-datepop`: 340px, radius 12, shadow `0 10px 30px -8px rgba(15,23,42,0.2)`, z 1099, preset pill + range date + bottone gradient.
- **Dock mobile ≤768** `.adm-bottom-stack`: fixed bottom z 1090, padding `18px 12px calc(12px + safe-area)`, sfumatura bg da trasparente a `#f8fafc`; `.adm-dock-btn`: full-width min-h 60, radius 16, gradient `180deg #8B5CF6→#7C3AED`, icona 38px in box `rgba(255,255,255,0.20)` radius 10, eyebrow `0.62rem` uppercase `rgba(255,255,255,0.78)`, nome `0.98rem` 800; shadow dock (v. §2.4); pill filtro `.adm-mbar-filter`: pill bianca min-h 40 border `#e2e8f0`, shadow `0 4px 12px -4px rgba(15,23,42,0.12)`, con filtro attivo border/testo viola bg `rgba(139,92,246,0.08)`.

---

### 2.13 Componenti specifici per tab

#### Prenotazioni (calendario admin)
- **Week bar** `.bookings-week-bar`: card bianca sticky (`top var(--bookings-bar-top,122px)`, z 12) con `::before` 3px gradient viola; **mobile**: hero scuro `radial-gradient(circle 110px…rgba(139,92,246,0.45))` + `linear-gradient(155deg,#1a1a1a 0%,#2a1f3d 60%,#6D28D9 130%)`, radius 18, eyebrow mese `#C4B5FD` ls 0.18em, date bianche `1.05rem` 800, frecce glass `rgba(255,255,255,0.12)`.
- **Day selector** `.admin-day-selector`: scroll-snap x a pagine-settimana (`.admin-week-page` flex 100%); card giorno `.admin-day-card`: nome `0.78rem` 700 uppercase, data `1.2rem` 800, count `0.68rem`; attiva gradient viola + shadow; **oggi**: tenue `rgba(239,68,68,0.22)`/`#991b1b`, attivo gradient `#ef4444→#dc2626` (mobile: sempre `linear-gradient(180deg,#dc2626,#b91c1c)` border `#fca5a5`); su hero mobile le card sono glass `rgba(255,255,255,0.06)` border `rgba(255,255,255,0.1)` blur 4; barra occupazione `.admin-day-occ` 3px (mobile pill 24×2px, fill `#C4B5FD`, bianco se attiva, `#dc2626` se oggi).
- **Lista slot** `.admin-day-view`: desktop contenitore bianco radius 16 con righe `border-left 4px` colore tipo + bg tinta (`PT rgba(34,197,94,0.06)`, `SG rgba(251,191,36,0.07)`, `GC rgba(239,68,68,0.05)`, `CL rgba(139,92,246,0.05)`), divisori `#d5dae2`; **mobile**: card separate bianche radius 12 gap 8, collassabili (chevron CSS 9px, `.is-expanded` border `#e0d4ff` + shadow viola), swipe-to-reveal wrapper scroll-snap con azione `+` (56px, bg `rgba(139,92,246,0.14)`).
- **Header slot**: orario `1.05rem` 800 `#0f172a`; capienza `0.82rem` `#64748b`; **pips** 6×14px radius 2 (mobile 5×12): pieni `pip-pt #16a34a`, `pip-sg #f59e0b`, `pip-gc #ef4444`, `pip-cl #06b6d4`; vuoti `rgba(colore,0.28)`.
- **Card partecipante** `.admin-participant-card`: bianco, border `#eef0f3`, radius 14 (mobile 10), shadow `0 1px 3px rgba(15,23,42,0.05)`; hover border `rgba(139,92,246,0.3)`; `cancel-pending`: border `#fcd34d`, bg gradient `#fffbeb→#fef3c7`, badge `#fef3c7`/`#92400e`; layout riga: avatar hue + nome ellipsis 700 `0.95rem` + riga saldo (etichetta + `.saldo-chip` a destra).
- **Split view** tipi misti: colonne con `.split-col-title` pill tinta, divider verticale `#ddd` (mobile: impilate).
- FAB orologio `.scroll-slot-fab` (52px) per scroll allo slot corrente.

#### Clienti
- **Card cliente** `.client-card`: border `1px #eef0f3` + **`border-left 4px #8B5CF6`**, radius 16, shadow `0 1px 3px rgba(15,23,42,0.04)`; hover/open left-border `#7C3AED` + shadow più profonda; header cliccabile bg `#fff` (open: `#f5f3ff` + border-bottom `#e5e7eb`); avatar `.cv2-avatar` 44px `#ede9fe`/`#7c3aed`; nome `1.05rem` 700; contatti `.cv2-contact-link` `0.85rem` 600 `#475569` con icona `#94a3b8`, hover viola; meta età/residenza `0.82rem` `#64748b` (desktop colonna destra, mobile inline).
- **Stats grid 3 celle** `.cv2-stats-grid`: valori `1rem` 800, label `0.62rem` 700 uppercase `#94a3b8`; tinte: `green #16a34a`, `pink #be185d`, `blue #8B5CF6`, `red #dc2626`.
- **Switch Prenotazioni⇄Storico** `.cv2-segmented` (v. §2.12).
- **Righe-card prenotazioni** `.book-row`: padding `0.5rem 0.6rem`, radius 9, hover `#f6f8fa`; **barra sinistra** `.book-row-bar` 3×radius3 default `#cbd5e1`, **colore org-aware inline dal JS** (colore tipo slot del tenant); future non annullate bg `#fef2f2` (hover `#fee2e2`); tipo `0.85rem` 800, data `0.72rem` 600 `#94a3b8`; annullata line-through `#b0b6bf`; azioni 28×28 radius 7 (matita ambra / cestino grigio→rosso).
- **Righe storico incassi** `.tx-row`: barra per segno (`tx-plus #22c55e`, `tx-minus #ef4444`, `tx-free #cbd5e1`), importo 800 tabular (`plus #15803d`, `minus #dc2626`, `free #9ca3af`).
- **Ricerca+filtri**: input search con icona; toggle filtri pill; chips filtro tema rosso; risultato conteggio `2.2rem` 700 rosso.
- **Popup modifica cliente** (v. §2.10) con sezioni h4 uppercase `#999`, toggle iOS, azioni 2×2 (salva verde, annulla ghost, reset-bonus ambra outline `#fde68a`, elimina rosso outline `#fecaca`).

#### Gestione orari (tab Orari + editor flessibile)
- **Week bar orari** `.schedule-week-bar`: come bookings; stato settimana pill `.schedule-week-status`: `has-slots` `#8B5CF6`/`rgba(139,92,246,0.08)`, `is-blank` `#94a3b8`/`#f1f5f9` (mobile su hero: testo plain `#22c55e`/`#f87171` uppercase); azioni: `.btn-import-week` gradient viola, `.btn-clear-week` ghost→rosso (mobile: entrambi glass su scuro).
- **Righe slot** `.schedule-slot-item-selector`: desktop righe bianche divisorio `#d5dae2` con accent hover sinistro 3px viola; **mobile**: card radius 12 `border-left 3px` per tipo (`empty #e2e8f0`, `PT #16a34a`, `SG #eab308`, `CL #f59e0b`, `GC #dc2626` + bg gradient `rgba(254,226,226,0.55)→#fff`); select tipo a pill colorata con chevron data-URI (PT `#dcfce7`/`#166534`, SG `#fef9c3`/`#854d0e`, GC `#dc2626`/bianco, CL `#fef3c7`/`#b45309`).
- **Client picker** (slot prenotato): pannello gradient `#f8fafc→#f1f5f9` (mobile: dashed-top inline); chip selezionato verde `#dcfce7` border `#86efac` con avatar 22px `#16a34a`; warning `#fef3c7` border `#fcd34d` testo `#b45309`; autocomplete dropdown bianco shadow `0 8px 24px rgba(0,0,0,0.1)`.
- **Editor flessibile** (`.sched-*`): nav segmented; sezioni card bianche radius 14; righe `.sched-row` bg `#fbfcfe` border `#eef2f7` radius 11, hover border `#ddd6fe`; dot colore 16px con doppio ring; form inline bg `#faf5ff` border `1.5px #ede9fe`, titolo `#5b21b6`; griglia settimana-tipo (v. §2.9); override: riga attiva bg `#faf5ff` border `#ddd6fe`.

#### Registro
- Sub-tab underline (Registro / Notifiche admin / Notifiche clienti); header collassabile con chevron rotante; filtri: pill data, select/search 36px; tabella (v. §2.9); badge `rtype-*`/`rstatus-*` (v. §2.7); paginazione.
- **Vista mobile ≤640** `.registro-mobile-list`: gruppi card bianche radius 14; righe 10×12px con orario 46px tabular, tag icona 24px radius 7 colorato (`book #dbeafe/#1d4ed8`, `pay #dcfce7/#166534`, `credit #ede9fe/#6d28d9`, `refund #cffafe/#0e7490`, `cancel #fee2e2/#991b1b`, `warn #fef3c7/#b45309`, `neutral #f1f5f9/#475569`), importo 800 (`plus #166534`, `minus #991b1b`, `free` pill `#ede9fe/#6d28d9`); righe admin bg `#fef2f2`, system `#f0fdf4`; dettaglio espandibile a griglia dt/dd + bottoni azione (primary `#8B5CF6`).

#### Pagamenti
- Stat card debitori/creditori (v. §2.8) + skeleton; valori rossi `#ef4444` / verdi `#16a34a`.
- **Card debitore** `.debtor-card`: bianco radius 14, `border-left 4px #e5e7eb`, hover left `#ef4444` (creditore hover `#22c55e`); importo pill (v. §2.7); righe prenotazione `#f8f9fb` radius 8; pagate opacity 0.55 line-through; footer paga-tutto con `.btn-pay-all`; conferma `.debtor-pay-success` verde.
- **FAB +** e **action sheet** (v. §2.10); popup incasso `.debt-popup-modal` con checkbox lista, metodo pagamento a bottoni (`.debt-method-btn` attivo viola tenue; "lezione gratis" tema verde `#dcfce7`/`#15803d`), importo con wrapper €, righe anteprima credito verdi/ambra.
- **Manual entry** crediti/debiti con temi credit/debt (v. §2.10) e importo gigante `2.8rem`.

#### Analytics / Statistiche
- Filtro periodi underline; stat card cliccabili con bordo attivo colorato per metrica (fatturato `#f59e0b`, prenotazioni `#3b82f6`, clienti `#10b981`, occupancy `#8b5cf6`, debitori `#ef4444`, creditori `#22c55e`) + hint "clicca" `0.62rem` `#d1d5db`; pannello dettaglio con KPI (v. §2.8), blocchi grafici `#fafbfc` border `#e8eaed` radius 14, tabelle breakdown `.sdb-row` zebra `rgba(0,0,0,0.02)`; mode-switch `.stat-mode-btn` attivo **nero `#111`**; canvas Chart.js `height 250px !important`; barre orari popolari: track `#f8f9fa` radius 15 h30, fill gradient viola (variante low `#94a3b8→#64748b`).

#### Schede allenamento
- Sub-nav 3 tab underline (Live/Schede/Clienti); container trasparente (no card bianca).
- **Live** `.schede-actual-*`: griglia 3 col (mobile carosello scroll-snap + dots — attivo 18×6 pill viola); card radius 18 con **hero scuro**: prev `linear-gradient(160deg,#1f2937,#374151)` (opacity 0.88), current `linear-gradient(160deg,#0b1220 0%,#1e1b4b 65%,#5b21b6 130%)`, next `linear-gradient(160deg,#0e1f33,#312e81)`, glow radiale viola in basso a destra; pill LIVE rossa pulsante; orario `1.85rem` 800; progress bar 6px gradient `#8B5CF6→#86efac`; body bianco con righe persona `.sa-person` (border `#e2e8f0` radius 12, hover viola `#f5f3ff` + translateX(2px); `--no-plan` tema rosso `#fef2f2`/`#fecaca`/`#991b1b`); stato ✓/✗ cerchio 1.35rem (`ok #dcfce7/#15803d/#86efac`, `ko #fef2f2/#b91c1c/#fca5a5`).
- **Lista schede**: assign-bar **dark hero** (`radial …rgba(139,92,246,0.40)` + `linear-gradient(160deg,#0b1220 0%,#0e1f33 65%,#6D28D9 130%)`, radius 18, label `9.5px` 800 `#8B5CF6`, input glass `rgba(255,255,255,0.06)` border `rgba(255,255,255,0.14)`, bottone gradient viola full-width); card piano `.schede-plan-card`: `border-left 5px #8B5CF6` radius 14, hover `translateY(-2px)`; azioni icona 30×30.
- **Editor** `.schede-editor`: topbar **dark hero** identica all'assign-bar, back-btn glass 34px; form card bianca; day-pill grandi (attive gradient viola, `+` dashed, cestino a destra); card esercizio `<details>` con barra sinistra 3px viola, `[open]` ring viola; corpo bg `#fafcfd` con griglia parametri 4 col; blocchi **superset** border `2px #f59e0b` bg gradient `#fffbeb→#fff` e **circuito** border `2px #06b6d4` bg `#ecfeff→#fff`, badge flottanti top -9px; CTA dashed (v. §2.5); save full-width uppercase.
- **Picker esercizi**: fullscreen (v. §2.10), chips categoria (attiva gradient viola, icona invertita), item 44px thumb, bottone video circolare 34px viola-outline.
- **Importa** (catalogo): hero scuro con stats 900 e progress `#8B5CF6→#10b981`; toggle viste; griglia card `minmax(200–220px,1fr)` radius 14 border `1.5px #e8ecf1`, hover `translateY(-3px)`; importata: border `#86efac` bg gradient `#f0fdf4→#fff` + check 28px `#22c55e`; bottoni: add gradient viola, remove `#fee2e2`/`#dc2626`, rename `#fef3c7`/`#92400e`.
- **Cliente detail**: breadcrumb viola, pills conteggio (attiva gradient `180deg #8B5CF6→#7C3AED` shadow `0 4px 10px -3px rgba(124,58,237,0.45)`), plan-card con progress verde `#16a34a→#86efac` 5px, bottoni `.schede-cd-btn` (primary gradient viola) e icon-btn 36px (`danger rgba(220,38,38,0.08)`); report mensili: item lista radius 12 hover viola + modal markdown (v. §2.10); grafici progressi card gradient `#fff→#f8fafc` con thumb 100px (mobile 72) bg `#f5f3ff→#ede9fe`.

#### Messaggi (push hub)
- Header card con barra top viola e badge pill; card form con `::before` viola su focus-within; opzioni destinatario radio-card (checked gradient azzurro `#f0fbff→#e8f7ff` + icona gradient viola); campi condizionali con `border-top dashed`; send-bar bg gradient `#f8fafc→#f1f5f9` + `.msg-send-btn` uppercase; popup esiti con liste ok/fail (`border-left 3px #16a34a/#dc2626`, avatar 24px gradient).

#### Impostazioni
- Header hub + badge; nav 11 sotto-tab segmented (mobile: solo icone); gruppi label uppercase con icona 22px (danger rosso); `.sett-card` (v. §2.8) con toggle grandi, controlli soglia (€ wrap `#f8fafc` border focus viola), input manutenzione, bottoni azione colorati (Backup=blue/green, ecc.); radio-card modello pagamento (attivo `#faf5ff` ring viola); listino prezzi righe `#f8fafc` con input € right-aligned; staff rows con role badge; **Billing SaaS**: stats 3 col, plan-grid 3 col — card corrente border `#8B5CF6` + ring, prezzo `1.4rem` 800 `#7c3aed`, feature list con ✓ `#059669`; stato Stripe `.sett-stripe-status`: ok `rgba(6,214,160,0.10)` border `rgba(6,214,160,0.35)`, pending `rgba(247,127,0,0.10)`.

#### Backup / azioni rapide
- Vive nelle Impostazioni (bottoni `.sett-action-btn--blue/--green`); mobile legacy: `.actions-card` griglia 2 col di `.btn-action` (bg viola pieno, testo sinistra, hover `translateX(5px)`); sezioni collassabili mobile `.m-section` (bianco radius 10, shadow `0 1px 5px rgba(0,0,0,0.07)`, chevron ruotante) — su desktop diventano wrapper trasparenti.

---

### 2.14 Layout responsive (breakpoint esatti)

| Breakpoint | Effetto |
|---|---|
| `@media (min-width: 769px)` | **`html { font-size: 12px }`** (scala desktop); navbar full-width padding `0 2rem`; `.m-section` trasparenti; `.extra-picker` centrato; pips allineati a destra nell'header slot |
| `@media (min-width: 768px)` | payments-sheet centrato 420px; picker esercizi 600px; griglia Importa più larga |
| `@media (min-width: 1024px)` | **layout desktop**: `.dashboard-section` diventa flex con **sidebar 240px sticky** + main (container max-w 1400, padding `1.5rem 2rem 2rem`); `.admin-tabs` e `.analytics-filter-bar` nascoste (`display:none !important`); compaiono `.adm-topbar` e `.adm-datepop` |
| `@media (max-width: 780px)` | carosello Live: card 100% scroll-snap + dots |
| `@media (max-width: 768px)` | **mobile**: `.admin-tabs` nascosta → **dock viola** `.adm-bottom-stack` (page-switcher) + pill Filtri + bottom-sheet; padding-bottom contenuto `calc(100px + safe-area)` (150px con pill); FAB rialzati a `calc(84px/134px + safe-area)`; week-bar diventano **hero scuri**; slot list → card collassabili con swipe; stats grid 2×2 compatta; tab orizzontali a scroll (`scrollbar-width:none`); tabella prenotazioni nasconde col. WhatsApp; participant grid 1 colonna; login padding ridotto |
| `@media (max-width: 640px)` | Registro: filtri a colonna, tabella → lista mobile `.reg-mob-*`; reg-panel filtri full-width; Impostazioni: griglie 1 colonna, nav solo icone |
| `@media (max-width: 600px)` | modali → bottom-sheet (`80dvh`, radius top 16, drag handle); schede mobile (card compatte, save sticky bottom con sfumatura bianca, day-tabs scroll); template editor 95vh; sched editor compatto |
| `@media (max-width: 500px)` | popup Live: bottone "Aggiungi" compatto |
| `@media (max-width: 480px)` | card cliente compatta (avatar 38px); griglia Importa 2 colonne; stat detail panel padding ridotto |
| `@media (max-width: 380px)` | extra-small: logo 44px, day-card e testi minimi |

Contenitori: `.dashboard-section .container` max-w 1400 (95%); default sezione 620px, `--wide` 1280px; `.admin-tabs` cap 1280; `.schede-editor`/`.schede-progress` max-w 900; `#importaContainer` max-w 1100 (1200 desktop).

---

### 2.15 Safe-area, sticky/fixed e quirks PWA

- **`env(safe-area-inset-bottom)`** usato in: `.payments-sheet` (padding bottom `calc(1.5rem + safe-area)`), `.adm-bottom-stack` (`calc(12px + safe-area)`), `#dashboardSection` padding-bottom (`calc(100/150px + safe-area)`), FAB (`calc(84/134px + safe-area)`), `.adm-sheet` (`max(18px, safe-area)`), credit sidebar navbar.
- **Sticky**: navbar `top 0` z 1000; `.admin-tabs` `top var(--admin-tabs-top,72px)` z 13; week-bar Prenotazioni/Orari `top var(--bookings-bar-top,122px)` z 12 (mobile `+0.35rem` con `::after` che riempie il gap col bg pagina `#f8f9fa`); sidebar desktop `top 72px`; save schede mobile sticky bottom; thead `.sched-grid` sticky.
- **Fixed**: FAB (z 1000), dock/stack (z 1090), sheets (1100/1101), overlay modali (2000–10003), toast (9999), PWA banner (10000).
- **Scala z-index**: 1 (day-view) · 10–13 (sticky bars) · 100–200 (dropdown) · 990–1000 (FAB/navbar) · 1090–1101 (dock+sheet) · 1500/1600 (sidebar nav) · 2000–2300 (popup pagamento) · 3000 (social modal) · 9998–9999 (overlay app) · 10000–10003 (overlay schede, ordine: detail-overlay < picker-backdrop < picker < video-detail).
- **iOS anti-detach shell** (fine admin.css): solo iOS standalone ≤768 (`@supports (-webkit-touch-callout:none)` + `@media (display-mode: standalone)`) e solo `html.adm-shell-page`: `html { height:100%; overflow:hidden }`, `body { height:100%; min-height:0; overflow-y:auto }`, `#dashboardSection { flex:1 0 auto }` — il body diventa lo scroller per evitare che i `position:fixed; bottom:0` si stacchino durante il momentum scroll. In Flutter non serve (Scaffold nativo), ma spiega perché il dock è un componente separato dal flusso.
- Altri quirk: `overscroll-behavior-x: none` su html/body; `-webkit-overflow-scrolling: touch` e `scrollbar-width: none` su tutte le strip orizzontali; `scroll-snap-type: x mandatory` (settimane, carosello Live, swipe slot); `font-size: 16px` sugli input (anti-zoom iOS); `body.nav-open` / `body.adm-sheet-open` / `body.extra-picker-open` → `overflow: hidden` (con sheet aperto dock+FAB nascosti); `-webkit-touch-callout: none` + `pointer-events: none` sulle immagini nelle liste drag (long-press iOS); `touch-action: none` sugli overlay, `pan-y` sulle liste scrollabili nei popup; `backdrop-filter: blur(2–6px)` sugli overlay (richiede equivalente `BackdropFilter` in Flutter); `color-scheme: light` sui loghi.

---

# Spec migrazione Flutter — Sezioni 3/4/5: Prenotazioni, Gestione Orari, Registro

Fonti: `js/admin-calendar.js` (824 r.), `js/admin-schedule.js` (1063 r.), `js/admin-registro.js` (1199 r.), `admin.html`, `css/admin.css`, `js/data.js`, `js/admin.js`, `js/booking.js`. Tutti i testi UI sono riportati ESATTI (in italiano).

**Contesto comune.** I tre pannelli vivono in `admin.html` dentro `#dashboardSection`; la tab-bar (`.admin-tabs`) ha i bottoni `📅 Prenotazioni` (`data-tab="bookings"`, attivo di default), `📋 Registro` (`data-tab="registro"`), `⚙️ Gestione Orari` (`data-tab="schedule"`). `switchTab(tabName)` (admin.js) mostra `#tab-<nome>` e invoca il render: `bookings → renderAdminCalendar()`, `schedule → renderScheduleManager()`, `registro → renderRegistroTab()`. Tab attivo persistito in `sessionStorage['adminActiveTab']` (ripristinato al refresh, default `bookings`). **Gating ruoli**: `ADMIN_UI_ROLES = ['owner','admin','staff']`; `hasAdminUiAccess()` → `ADMIN_UI_ROLES.includes(window._orgRole)`. La UI è visibile a tutti e tre i ruoli; l'autorità resta il server (RLS + RPC con `is_org_admin()`). Colori brand: `--primary-purple: #8B5CF6`, `--primary-purple-dark: #7C3AED`; colori tipo-slot legacy: `--personal-training: #22c55e`, `--small-group: #fbbf24`, `--group-class: #ef4444`, `--cleaning: #8b5cf6`.

**Colori/nome tipo slot org-aware (data.js)** — fonte di verità per pip/badge/dot:
- `getSlotColor(slotType)`: se `_ORG_SLOT_TYPES[slotType].color` esiste → quello (hex da tabella `slot_types.color`); altrimenti fallback `_LEGACY_SLOT_COLORS = { 'personal-training':'#16a34a', 'small-group':'#f59e0b', 'group-class':'#ef4444', 'cleaning':'#64748b' }`; ultimo fallback `#8B5CF6`.
- `getSlotName(slotType)`: `_ORG_SLOT_TYPES[slotType].label`, fallback `SLOT_NAMES = { 'personal-training':'Autonomia', 'small-group':'Lezione di Gruppo', 'group-class':'Slot prenotato', 'cleaning':'Pulizie' }`.
- `SLOT_TYPES = { PERSONAL:'personal-training', SMALL_GROUP:'small-group', GROUP_CLASS:'group-class', CLEANING:'cleaning' }`.
- `_ORG_SLOT_TYPES` è caricata da `loadOrgScheduleConfig()` (SELECT su `slot_types`: `id, key, label, color, default_capacity, default_price, bookable, is_active, sort_order` filtrata `org_id`); snapshot sincrono in `localStorage['_orgSchedSnap_<orgId>']` + puntatore `localStorage['_lastOrgId']` (idratazione immediata al refresh, niente flash dello schema legacy).

---

## 3. Tab Prenotazioni (calendario admin)

File: `js/admin-calendar.js`. Markup statico in `admin.html` (`#tab-bookings`).

### 3.1 Layout e componenti

Struttura HTML (testi esatti):

```
#tab-bookings > .bookings-hub
  .bookings-week-bar                 (sticky, top: var(--bookings-bar-top, 122px), z-index 12,
                                      bianco #fff, bordo #e2e8f0, radius 14px; barra superiore 3px
                                      gradient 90° #8B5CF6→#7C3AED→#8B5CF6)
    .bookings-week-nav
      .bookings-week-info
        span#adminCurrentWeek.schedule-week-dates   → testo iniziale "Settimana Corrente"
        span#adminCurrentMonth.schedule-week-month  → es. "LUGLIO 2026" (uppercase, 0.62rem, #94a3b8)
      .bookings-week-arrows
        button#adminPrevWeek.schedule-week-btn  (SVG chevron sinistra, title/aria "Settimana precedente")
        button#adminNextWeek.schedule-week-btn  (SVG chevron destra, title/aria "Settimana successiva")
    .admin-day-selector#adminDaySelector       (strip 3 settimane con scroll-snap orizzontale)
  #adminDayView.admin-day-view                  (lista slot del giorno selezionato)
```

- **Header settimana**: `renderAdminCalendar()` scrive in `#adminCurrentWeek` il range `"{d1} {mesecorto} — {d2} {mesecorto}"` (es. `27 apr — 3 mag`) con `M_SHORT = ['gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic']`; in `#adminCurrentMonth` scrive `"{MESE_FULL_MAIUSCOLO} {anno}"` (es. `MAGGIO 2026`) usando il mese del giorno selezionato (`M_FULL = ['gennaio',…,'dicembre']`).
- **Navigazione**: frecce ±1 settimana su `adminWeekOffset` (variabile globale condivisa con admin-analytics.js); tornando a offset 0 si riseleziona oggi (`selectedAdminDay = null`). Swipe orizzontale sulla strip: 3 pagine (`.admin-week-page`, offset relativi −1/0/+1), scroll-snap `x mandatory`; al termine dello scroll (debounce 180ms) l'indice pagina ≠ 1 aggiorna `adminWeekOffset += delta` e ri-renderizza; la pagina corrente viene ricentrata (`scrollLeft = clientWidth`).
- **Sticky offsets**: `_updateStickyOffsets()` imposta le CSS var `--admin-tabs-top` (= altezza `.navbar`) e `--bookings-bar-top` (= navbar + `.admin-tabs`); handler registrato su `resize` (rimosso prima di ri-aggiungerlo, ref `_adminCalResizeHandler`).
- **Date**: `getAdminWeekDates(offset)` genera 7 giorni Lun→Dom (`dayNames = ['Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato','Domenica']`), ognuno con `{date, dayName, formatted:'YYYY-MM-DD', displayDate:'d/m'}`; `formatAdminDate(date)` → `YYYY-MM-DD` zero-padded.

### 3.2 Selettore giorni (day card)

`renderAdminDaySelector()` crea 3 × 7 card. Ogni `.admin-day-card` contiene:
- `.admin-day-name` → `<span class="day-full">Lunedì</span><span class="day-short">Lun</span>` (short = primi 3 caratteri; su mobile ≤768px si mostra solo short, 0.6rem);
- `.admin-day-date` → numero giorno (1.2rem, weight 800);
- `.admin-day-count` → `"{N} pr."` (numero prenotazioni non cancellate, esclusi id sintetici `_avail_*`);
- `.admin-day-occ` → barra occupazione alta 3px (sfondo `rgba(15,23,42,0.08)`) con `.admin-day-occ-fill` larghezza `min(100, round(prenotati*100/capienzaGiorno))%`.

Capienza giornaliera: `_adminDayCapacity(dateInfo)` = somma di `BookingStorage.getEffectiveCapacity(date, slot.time, slot.type)` per tutti gli slot di `getScheduleForDate(date, dayName)`.

Stati/colori day card (light):
- default: sfondo trasparente su strip `linear-gradient(135deg,#f1f5f9,#e8ecf1)` radius 12px; testo `#64748b`; divider verticale 1px `#b8c0cc` tra card (nascosto attorno all'attiva);
- hover (non attiva): `rgba(255,255,255,0.7)`, testo `#334155`;
- `.active` (selezionata): `linear-gradient(135deg,#8B5CF6,#7C3AED)`, testo bianco, shadow `0 2px 8px rgba(139,92,246,0.3)`; barra occ: track `rgba(255,255,255,0.25)`, fill `#ffffff`;
- `.is-today` non attiva: sfondo `rgba(239,68,68,0.22)`, testo `#991b1b` (hover `rgba(239,68,68,0.32)` / `#7f1d1d`); fill barra `#dc2626`;
- `.is-today.active`: `linear-gradient(135deg,#ef4444,#dc2626)`, bianco, shadow `0 2px 8px rgba(239,68,68,0.4)`.

Click su card → `selectedAdminDay = dateInfo`, toggle classe `active`, `renderAdminDayView(dateInfo)`.

Selezione default: al primo render seleziona oggi se presente nella settimana, altrimenti il primo giorno; cambiando settimana mantiene il giorno se ancora visibile.

### 3.3 Vista giornaliera: slot card

`renderAdminDayView(dateInfo)`:
1. salva `window._currentAdminDate = dateInfo`;
2. `BookingStorage.processPendingCancellations()` (le richieste di annullamento entro 2h dall'inizio lezione tornano `confirmed`, client-side);
3. rimuove eventuali picker orfani (`body > .extra-picker`);
4. `getScheduleForDate(date, dayName)` → array `[{time,type,capacity?,…}]`; se vuoto → `#adminDayView` = `<div class="empty-slot">Nessuna lezione programmata per questo giorno</div>`;
5. per ogni slot → `createAdminSlotCard(dateInfo, scheduledSlot)`.

**Slot card** (`.admin-slot-card <tipo>` dentro wrapper `.admin-slot-card-wrap`):
- Desktop: righe piene in un contenitore `.admin-day-view` bianco radius 16px; card `padding 1.2rem 1.3rem`, `border-left: 4px solid` colore tipo, `border-bottom: 1px solid #d5dae2`. Tinte per tipo (light): `personal-training` bg `rgba(34,197,94,0.06)` bordo `var(--personal-training)` (#22c55e); `small-group` bg `rgba(251,191,36,0.07)` bordo #fbbf24; `group-class` bg `rgba(239,68,68,0.05)` bordo #ef4444; `cleaning` bg `rgba(139,92,246,0.05)` bordo #8b5cf6. Hover: rispettivamente `rgba(34,197,94,0.09)`, `rgba(251,191,36,0.10)`, `rgba(239,68,68,0.08)`, `rgba(139,92,246,0.08)`.
- Mobile (≤768px): card bianche separate radius 12px, collassabili. Header cliccabile (toggle `is-expanded`, escluso click su bottoni/input); body (`.admin-slot-body`) `display:none` di default, visibile solo se `is-expanded` (bordo card espansa `#e0d4ff` + shadow viola). Chevron `.admin-slot-chev` (9px, bordi 2px `#94a3b8`, ruota di 180° quando espansa) visibile solo mobile. Stato espansi persistito nel `Set` globale `_expandedAdminSlots` con chiave `"YYYY-MM-DD|HH:MM - HH:MM"`.
- **Swipe-to-reveal (mobile)**: il wrap è flex scrollabile `scroll-snap-type:x mandatory`; a destra `.admin-slot-actions` (56px, bg `rgba(139,92,246,0.14)`) col bottone `＋` `.btn-add-extra--swipe` (cerchio 2.5rem viola #8B5CF6, testo bianco) → apre l'extra picker.

**Header slot** (`.admin-slot-header`):
- `.admin-slot-time` → `🕐 {time}` (es. `🕐 08:00 - 09:20`; 1.05rem, weight 800, #0f172a);
- `.admin-slot-capacity` → `"{confermatiTotali}/{capienzaTotale} posti"` (singolare `posto` se capienza 1; 0.82rem #64748b). Nascosto per `cleaning` o capienza 0;
- `.admin-slot-pips` → pip capienza (max 12, altrimenti niente): rettangolini 6×14px radius 2px, `_pipMarkup(slotType, empty)` con stile inline `background:{getSlotColor(tipo)}` pieno, `background:{colore};opacity:.28` vuoto. Prima i pip del tipo principale, poi quelli di ogni tipo extra (es. small-group +1 autonomia → 5 gialli + 1 verde). Classi CSS di fallback: `.pip-pt #16a34a`, `.pip-sg #f59e0b`, `.pip-gc #ef4444`, `.pip-cl #06b6d4`, `.pip.empty #e2e8f0` (lo stile inline vince);
- per `cleaning`: al posto di capienza/pips → `<div class="admin-slot-cleaning">🧹 Pulizia</div>` (colore `var(--cleaning,#8b5cf6)`);
- bottone `＋` `.btn-add-extra--inline` (cerchio 1.85rem, bg `rgba(139,92,246,0.12)`, colore viola; hover pieno viola/bianco; title "Aggiungi posto extra", aria-label "Aggiungi posto") — solo desktop; su mobile è nascosto (si usa lo swipe).

Capienza mostrata (`displayCap`): per `group-class` = `max(capienzaEffettiva, confermati, 1)` (capienza base 0, decisa dal server); per gli altri = `getEffectiveCapacity(date,time,mainType)`. `totalCap` somma anche `getEffectiveCapacity` di ogni tipo extra diverso dal principale; `totalConfirmed` = booking reali confermati.

**Barra extra** (`.admin-extras-bar`, presente se `scheduledSlot.extras` non vuoto): testo `Extra: ` seguito da badge `.extra-badge {tipo}` col testo `"{getSlotName(tipo)} ×{conteggio}"` e bottone `−` `.btn-remove-extra` (title "Rimuovi un posto") → `removeExtraSpotFromSlot`. Colori badge: `personal-training` bg #dcfce7 testo #16a34a; `small-group` bg #fef9c3 testo #b45309.

**Sezione partecipanti**:
- nessun extra di tipo diverso → `_buildParticipantsSection(mainBookings)`: griglia `.admin-participants-grid` (`grid-template-columns: repeat(auto-fill, minmax(200px,1fr))`, gap 1rem; mobile 1 colonna); se vuota → `<div class="empty-slot">Nessuna prenotazione</div>`;
- tipi misti (extra con tipo ≠ principale) → vista divisa `.admin-slot-split`: colonna sinistra con pill titolo `.split-col-title {mainType}` = `getSlotName(mainType)`, divisore verticale `.split-col-divider-v` (1px #ddd), colonne destre per ogni tipo extra con titolo `"{getSlotName(t)} {confermati}/{capienza}"`. Colori pill titolo: `personal-training` #dcfce7/#16a34a, `small-group` #fef9c3/#b45309, `group-class` #fee2e2/#dc2626, `cleaning` #ede9fe/#7c3aed. Su mobile le colonne si impilano verticalmente;
- `cleaning` puro senza extra: nessun body partecipanti.

### 3.4 Card partecipante (`_buildParticipantCard(booking)`)

`.admin-participant-card` (bianca, radius 14px, bordo #eef0f3; hover bordo `rgba(139,92,246,0.3)`; se `status === 'cancellation_requested'` classe `cancel-pending` → bordo #fcd34d, bg gradient #fffbeb→#fef3c7). Contenuto:

- **Riga principale** `.participant-row`: avatar + nome + chip saldo + bottone elimina.
  - `.participant-avatar` cerchio 38px (34px mobile) con iniziali (`_participantInitials`: 1 parola → prime 2 lettere; più parole → prima lettera di prima e ultima, uppercase; fallback `?`). Colore da `_participantAvatarHue(name)` (hash del nome % 6) via `data-hue`: 0 bg #cdecf9/testo #0b7fb0; 1 #fef3c7/#b45309; 2 #f3e8ff/#7e22ce; 3 #dcfce7/#166534; 4 #fee2e2/#b91c1c; 5 #e0f2fe/#075985. Se cancel-pending: bg #fef3c7 testo #92400e.
  - `.participant-name`: nome (weight 700, #0f172a, nowrap+ellipsis) + eventuale icona `🔕` (`_pushIcon`: mostrata solo se `userRecord.pushEnabled` falsy, title "Notifiche non attive").
  - Badge annullamento: `<div class="admin-cancel-pending-badge">⏳ Annullamento richiesto</div>` (bg #fef3c7, testo #92400e).
  - **Riga saldo** `.participant-saldo-line`: etichetta stato della SINGOLA lezione — `Pagato` (`.participant-saldo-status.paid`, #15803d) se `booking.paid`; `Da pagare` (`.owes`, #b45309) SOLO se lezione già iniziata/passata (`bookingHasPassed(booking)`, admin-payments.js) e non pagata; lezione futura non pagata → nessuna etichetta; nessuna etichetta anche se cancel-pending. Chip saldo AGGREGATO del contatto: se `getUnpaidAmountForContact(whatsapp,email) > 0` → `<span class="saldo-chip owes">−€{importo}</span>` (testo #dc2626, bg `rgba(239,68,68,0.12)`, cliccabile → `openDebtPopup(wa,em,nome)` popup incasso in admin-payments.js); altrimenti `<span class="saldo-chip zero">€0</span>` (#6b7280 su #f3f4f6).
  - Bottone `✕` `.btn-delete-booking` (28px, gradient viola `#8B5CF6→#7C3AED`, bianco) → `deleteBooking(id, nome)`.
- **Badge documenti** (`.cert-expired-badge cert-expired-badge--clickable`; visibilità pilotata da `BookingBadgesStorage`, localStorage: `gym_show_cert_badge`, `gym_show_assic_badge`, `gym_show_doc_badge`, `gym_show_anag_badge`, default true, sync via `_upsertSetting`):
  - Certificato (se `getShowCert()`): mancante → `🏥 Imposta Cert. Med`; scaduto → `🏥 Cert. scaduto il {dd}/{mm}/{yyyy}`; in scadenza ≤30gg → `⏳ Cert. Med scade il {dd}/{mm}/{yyyy}` con stile inline warn `background:#fffbeb;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b`. Click → `openCertModal(this,email,wa,nome)`. Stile default badge: bg #fef2f2, testo #dc2626, border-left 3px #dc2626, radius 5px.
  - Anagrafica (se `getShowAnag()` e manca CF/via/paese/CAP): `📋 Completa anagrafica` (stile inline `background:#fef3c7;border-color:#fde68a;color:#92400e;border-left:3px solid #f59e0b`) → `openEditClientPopup(0,wa,email,nome)`.
  - Documento (se `getShowDoc()` e `!documentoFirmato`): `📝 Documento non firmato` → `openEditClientPopup`.
  - Assicurazione (se `getShowAssic()`): mancante → `📋 Imposta Assicurazione` (stile warn #fef3c7); scaduta → `📋 Assic. scaduta il {dd}/{mm}/{yyyy}`; in scadenza → `⏳ Assic. scade il {dd}/{mm}/{yyyy}` (stile warn #fffbeb). Click → `openAssicModal`.
- **Note**: `<div class="participant-notes">{booking.notes}</div>` (0.78rem corsivo #64748b, bg gradient #f8fafc→#f1f5f9).

Dati cliente: `_getUserRecord(email, whatsapp)` (admin-analytics.js, cerca nella cache `UserStorage`).

### 3.5 Modali/popup

**A) Extra picker "Aggiungi posto allo slot"** — trigger: bottone `＋` (inline desktop o swipe mobile) → `toggleExtraPicker(date,time)`. Elemento `#xpick-{date}-{timeSenzaSeparatori}` `.extra-picker`, montato come figlio diretto di `<body>` (per evitare stacking context) e mostrato/nascosto con `display:flex/none`; classe `body.extra-picker-open` blocca lo scroll e nasconde dock/FAB mobile. Stile: overlay fixed inset 0, bg `rgba(15,23,42,0.55)` + `backdrop-filter: blur(2px)`, z-index 9999; contenuto `.extra-picker-content` bianco, bottom-sheet mobile (radius 16px 16px 0 0, slide-up 0.22s) / dialog centrato desktop (max-width 420px, fade-in). Click sull'overlay chiude; il contenuto fa `stopPropagation`. Alla chiusura l'HTML iniziale viene ripristinato (`el._initialHtml`) per resettare l'eventuale modalità ricerca.
Contenuto:
- titolo `.extra-picker-title`: `Aggiungi posto allo slot` (0.7rem uppercase #64748b);
- `<button class="extra-picker-btn personal-training">Autonomia</button>` (bg `var(--personal-training)` #22c55e, bianco) → `addExtraSpotToSlot(date,time,'personal-training')`;
- `<button class="extra-picker-btn small-group">Lezione di Gruppo</button>` (bg #fbbf24, testo #333) → `addExtraSpotToSlot(date,time,'small-group')`;
- `Slot prenotato` (stile inline `background:#ef4444;color:#fff;border-color:#ef4444`) → `openClientBookingPickerForSlotPrenotato(...)` — presente SOLO se il tipo principale è `group-class` E i booking group-class attivi (confirmed o cancellation_requested) sono esattamente 1;
- `Persona` (stile inline `background:#6c5ce7;color:#fff`) → `openClientBookingPicker(date,time,pickerId)`;
- `<button class="extra-picker-cancel">Annulla</button>` (bg #f1f5f9, testo #475569) → chiude.

**B) Picker cliente "Aggiungi una prenotazione"** — trigger: bottone `Persona` (o `Slot prenotato`). `openClientBookingPicker` sostituisce il contenuto del picker con:
- titolo `Aggiungi una prenotazione`;
- input testo placeholder `Cerca cliente…` (classe `js-client-search-input`) + bottone `✕` di chiusura;
- lista risultati `.js-client-search-results` (altezza fissa 240px, scroll): `_filterClientList(query)` filtra `UserStorage.getAll()` per nome/email (case-insensitive), max 10 righe; ogni riga mostra il nome in grassetto + freccia `›`; query vuota → lista vuota; nessun match → `Nessun cliente trovato` (grigio #999); eccezione → `Errore caricamento clienti`;
- selezione cliente (`_selectClientForBooking`): nasconde input+lista, mostra conferma con `**{nome}** · {email o whatsapp}` e bottoni:
  - flusso normale: `Autonomia` (`.extra-picker-btn.personal-training`) → `bookForClient('personal-training')`; `Lezione di Gruppo` (`.extra-picker-btn.small-group`) → `bookForClient('small-group')`;
  - flusso "Slot prenotato" (`_clientPickerState.forcedSlotType === 'group-class'`): unico bottone `Conferma Slot prenotato` (rosso `#ef4444`) → `bookForClient('group-class')`;
  - `← Indietro` riporta alla ricerca.

Stato del picker in `_clientPickerState = { date, time, client, forcedSlotType, picker }` (niente JSON negli onclick).

**C) Conferme** (dialog custom `showConfirm`, ui.js): vedi flussi sotto.

### 3.6 Flussi d'interazione

**Prenotazione manuale admin (`bookForClient(slotType)`)**:
1. guard ruolo: `hasAdminUiAccess()` (fallback `sessionStorage['adminAuth']==='true'`); se no → toast errore `Sessione admin scaduta. Ricarica la pagina e accedi di nuovo.`;
2. cliente selezionato obbligatorio, altrimenti toast `Seleziona prima un cliente dalla lista.`;
3. lookup `user_id` del cliente: `supabaseClient.from('profiles').select('id').eq('email', emailLower).maybeSingle()` (per push promemoria);
4. calcola `dateDisplay` = `"{GiornoSettimana} {d} {mese}"` (es. `Lunedì 6 luglio`);
5. `BookingStorage.saveBookingForClient(booking, clientUserId)` → RPC **`book_slot`** con parametri esatti: `p_org_slug` (da `_resolveOrgSlug()`: `window._orgSlug` → sottodominio → `?org=`), `p_local_id` (id client-side `"{Date.now()}-{rand36}"`), `p_date`, `p_time`, `p_name`, `p_email`, `p_whatsapp`, `p_notes`, `p_date_display`, `p_for_user_id` (admin-only: attribuisce il booking al cliente; null se non trovato). Timeout 45s con AbortController. La capienza è decisa dal SERVER (advisory lock anti-overbooking): niente gonfiaggio automatico dell'override;
6. errori: `slot_full` → toast `Slot pieno: usa il pulsante ＋ per aggiungere un posto, poi riprova.`; altro → `⚠️ Errore: prenotazione non riuscita. Riprova.`;
7. successo: `BookingStorage.fulfillPendingCancellations(date,time)` (cancella FIFO la prima richiesta di annullamento pendente su quello slot), toast success `Prenotazione aggiunta per {nome}`, `invalidateStatsCache()`, re-render del giorno.

**Aggiungi/rimuovi posto extra**:
- `addExtraSpotToSlot(date,time,tipo)` → `BookingStorage.addExtraSpot`: incrementa di 1 la capienza ASSOLUTA dell'override localStorage per quella data/ora (se non esiste crea `{time, type, capacity: default+1}`; se il tipo differisce dal principale converte il tipo e imposta `default(nuovoTipo)+1`), poi `saveScheduleOverrides(overrides,[date])` (upsert su `schedule_overrides`, vedi §4.7); chiude il picker e re-renderizza.
- `removeExtraSpotFromSlot` → `BookingStorage.removeExtraSpot`: decrementa la capacity se c'è almeno un posto libero; se lo slot è occupato ritorna false → toast errore `Prima cancella la prenotazione in corso, poi potrai rimuovere lo slot extra.`.

**Cancellazione prenotazione admin (`deleteBooking(bookingId, bookingName)`)**:
1. conferma: `Confermare l'annullamento della prenotazione di {nome}?`;
2. se online e il booking ha `_sbId` → RPC **`cancel_booking`** `{ p_booking_id: booking._sbId }` (atomica: cambio stato → `cancelled` + conversione `group-class → small-group` lato server). Poi `BookingStorage.syncFromSupabase()` per riallineare cache, `invalidateStatsCache()`, re-render, toast success `✅ Prenotazione annullata con successo.` (4s);
3. fallback offline/senza `_sbId` → `BookingStorage.cancelAndConvertSlot(id)` (stessa logica client-side: patch `status:'cancelled'`, `cancelledAt`, azzera paid/paymentMethod/paidAt preservando `cancelledPaymentMethod`/`cancelledPaidAt`; converte l'override group-class→small-group);
4. errore → toast `⚠️ Errore: {msg}` (5s). NB: nessun rimborso/credito/mora (sistema crediti rimosso); nessuna push inviata da questo flusso (le edge `notify-admin-cancellation` riguardano annullamenti fatti dal cliente).

**Auto-scroll allo slot corrente**: `_scrollToCurrentAdminSlot(container)` trova la prima card con orario di fine > adesso, la espande (aggiunge la chiave a `_expandedAdminSlots`) e scrolla (`window.scrollTo` + `document.body.scrollTo`, target al 35% viewport).

**Popup iscritti raggruppati per tipo (pagina prenotazione, port Thomas 2026-07-04)** — vive in `js/booking.js` (modal cliente `#bookingModal`), citato qui perché usa la stessa infrastruttura org-aware: `_loadSlotAttendees()` chiama la RPC **`get_slot_attendees`** `{ p_org_slug: window._orgSlug, p_date, p_time }` (ritorna `TABLE(name, slot_type)`, timeout 8s + retry singolo con `ensureValidSession()`); `_renderSlotAttendees(list, data, currentType)` raggruppa per `slot_type` in ordine di comparsa: se 1 solo gruppo → lista piatta `👤 {nome}`; altrimenti per ogni gruppo intestazione `<li class="slot-attendees-group"><span class="sa-dot" style="background:{getSlotColor(tipo)}"></span>{getSlotName(tipo)} · {n}</li>` seguita dai nomi `👤 {nome}`. Stati: caricamento `Caricamento...` (corsivo #9ca3af); vuoto `Nessuna persona visibile per questo slot.`; errore `Impossibile caricare gli iscritti. Riprova` (link che rilancia il load).

### 3.7 Logica dati

Funzioni principali (nomi esatti): `setupAdminCalendar`, `_updateStickyOffsets`, `getAdminWeekDates`, `formatAdminDate`, `renderAdminCalendar`, `renderAdminDaySelector`, `renderAdminDayView`, `createAdminSlotCard`, `_buildParticipantCard`, `_buildParticipantsSection`, `_participantInitials`, `_participantAvatarHue`, `_pipMarkup`, `_adminDayCapacity`, `_scrollToCurrentAdminSlot`, `toggleExtraPicker`, `addExtraSpotToSlot`, `removeExtraSpotFromSlot`, `openClientBookingPicker`, `openClientBookingPickerForSlotPrenotato`, `_filterClientList`, `_selectClientForBooking`, `bookForClient`, `deleteBooking`, `_pushIcon`.

**BookingStorage (data.js)** — dual-layer cache in memoria + localStorage + Supabase:
- `getAllBookings()` → ritorna `this._cache` (array in memoria). Ogni riga: `{ id (local_id), _sbId, userId, date, time, slotType, dateDisplay, name, email, whatsapp, notes, status ('confirmed'|'cancellation_requested'|'cancelled'), paid, paymentMethod, paidAt, customPrice, createdAt, cancellationRequestedAt, cancelledAt, cancelledPaymentMethod, cancelledPaidAt, cancelledRefundPct, updatedAt, createdBy, cancelledBy, arrivedAt }` (mapping `_mapRow`).
- `getBookingsForSlot(date, time)` → filtra cache per data+ora, esclusi `cancelled`.
- `getEffectiveCapacity(date, time, slotType)` → precedenza: (0) capienza server-authoritative da `_availabilityByKey["{date}|{time}|{tipo}"]` (indice della RPC `get_availability_range`); (1) override localStorage per data/ora (capacity assoluta; tipo diverso → 0); (2) template della settimana ATTIVATA (`_orgWeeklyForDate(date)` da `_ORG_ACTIVE_WEEKS`+`_ORG_TPL_WEEKLY`); (3) `_ORG_SLOT_TYPES[tipo].defaultCapacity` (fallback `SLOT_MAX_CAPACITY = { 'personal-training':5, 'small-group':5, 'group-class':0, 'cleaning':0 }`).
- `syncFromSupabase({ ownOnly, forceFull })` — **ottimizzazioni egress**:
  - finestra operativa: **60 giorni passati + 90 futuri** (`.lte('date', futureStr)` + `.or('date.gte.{pastStr},and(paid.is.false,status.neq.cancelled)')` — include SEMPRE le lezioni passate non pagate e non annullate senza floor di data, per i debiti vecchi); select colonne esplicite (`id,local_id,user_id,date,time,slot_type,date_display,name,email,whatsapp,notes,status,paid,payment_method,paid_at,custom_price,created_at,cancellation_requested_at,cancelled_at,updated_at,cancelled_payment_method,cancelled_paid_at,cancelled_refund_pct,created_by,cancelled_by,arrived_at`); paginazione 1000 righe con tiebreaker `.order('id')`;
  - **fingerprint** `"{count}|{max updated_at}"` (query cheap `count:'exact'` + 1 riga): invariato → SKIP; cambiato senza delete (count non sceso) e reconcile non dovuto → **DELTA** (`.gte('updated_at', cursore−5000ms)`, merge idempotente per `_sbId`); altrimenti FULL. Reconcile periodico ogni 5 min (`_BK_RECONCILE_MS`);
  - **snapshot persistito** in `localStorage["gym_bookings_cache_v2:{syncKey}:{identity}"]` (`syncKey` = 'all'|'own'; `identity` = 'admin'|userId; anon non persiste) con `{savedAt, clearedAt, fingerprint, lastFull, rows}`; TTL 15 min, max 8000 righe; idratato al primo sync di pagina → skip/delta cross-pagina;
  - utenti non-admin: in più RPC **`get_availability_range`** `{ p_org_slug, p_from: oggi, p_to: oggi+90 }` (cache dedup 60s `_availCache`) → booking sintetici `_avail_*` senza dati personali; l'admin NON la usa (vede tutto via RLS `is_admin()`);
  - retry automatico 5s su errore; toast `Errore di connessione al server. Verifica la tua connessione.` solo al 3° fallimento consecutivo;
  - pending: booking locali < 30 min senza `_sbId` vengono ritentati via `book_slot` (`_retryPending`).
- `saveBookingForClient` / `saveBooking` → RPC `book_slot` (parametri in §3.6).
- `fulfillPendingCancellations(date,time)`, `processPendingCancellations()`, `cancelAndConvertSlot(id)`, `requestCancellation(id)` → patch locali + `replaceAllBookings()` che diffa e sincronizza i cambi via RPC **`admin_update_booking`** `{ p_booking_id, p_status, p_paid, p_payment_method, p_paid_at, p_cancellation_requested_at, p_cancelled_at, p_cancelled_payment_method, p_cancelled_paid_at, p_cancelled_refund_pct, p_expected_updated_at }` (optimistic locking: `stale_data` → toast `Prenotazione modificata da un altro dispositivo. Dati ricaricati.` + resync).
- `addExtraSpot` / `removeExtraSpot` / `getScheduleOverrides` / `saveScheduleOverrides` → vedi §4.7.

**Prezzi**: `getBookingPrice(booking)` = `customPrice` se presente → `OrgSettings.get('billing_client.prices')[slotType]` → `OrgSettings.getNumber('price.{slotType}')` → fallback deprecato `SLOT_PRICES = { 'personal-training':5, 'small-group':10, 'group-class':30, 'cleaning':0 }`.

**Realtime**: nessuna subscription dedicata a `bookings` in questo tab; refresh via sync su switchTab/visibility (silent-refresh.js). Realtime esiste solo su `org_settings` (org-settings.js, canale con filtro `org_id=eq.{orgId}`).

`_showMoreItems` NON è usato in questo tab (è della tab Clienti).

### 3.8 Stati vuoti/errore/loading

- Giorno senza lezioni: `Nessuna lezione programmata per questo giorno` (`.empty-slot`: centrato, #94a3b8, corsivo).
- Slot senza iscritti: `Nessuna prenotazione`.
- Ricerca cliente: `Nessun cliente trovato` / `Errore caricamento clienti`.
- Toast (già elencati in §3.6). Nessuno spinner dedicato: il calendario renderizza subito dalla cache.

---

## 4. Tab Gestione Orari

File: `js/admin-schedule.js`. Markup: `#tab-schedule > #scheduleManager` (tutto generato da JS). Entry point: `setupScheduleManager()` → `renderScheduleManager()`.

### 4.1 Layout e navigazione

`renderScheduleManager()` monta lo skeleton:

```
#scheduleManager
  .sched-head > .sched-nav#schedNav        (5 bottoni sezione)
  #schedBody                                → "⏳ Caricamento configurazione orari…" (.sched-loading)
```

poi `await _schedLoadAll()` e `_schedRenderActiveSection()`.

Nav (`_schedNavHtml()`), bottoni `.sched-nav-btn` con icona+label (label nascosta su mobile ≤768px, resta l'icona 1.15rem):
- `🏷️ Tipi slot` (id sezione `types`, default)
- `🕐 Fasce orarie` (`slots`)
- `🗓️ Settimana tipo` (`template`)
- `✅ Attiva settimane` (`activation`)
- `📌 Override per data` (`overrides`)

Stili nav: contenitore bg #f1f5f9 radius 12px; bottone attivo bg #fff testo #7C3AED shadow; hover `rgba(139,92,246,0.08)` testo #7C3AED. Sezioni `.sched-section`: card bianca bordo #e2e8f0 radius 14px padding 1.1rem 1.3rem. Titoli `.sched-section-title` 1rem/800 #0f172a; descrizioni `.sched-section-desc` 0.8rem #64748b. Bottoni: `.sched-btn-primary` gradient `#8B5CF6→#7C3AED` bianco radius 10px; `.sched-btn-ghost` bianco bordo #e2e8f0; `.sched-btn-icon` 32px quadrato bordo #e2e8f0 (variante `--danger` hover bordo #fecaca bg #fef2f2); `.sched-btn-sm` compatto. Righe `.sched-row`: bg #fbfcfe bordo #eef2f7 radius 11px (hover bordo #ddd6fe); `.is-inactive` opacity 0.6. Badge `.sched-badge` uppercase 0.66rem: `--muted` #f1f5f9/#64748b, `--off` #fef2f2/#dc2626. Chip orario `.sched-time-chip` bg #f1f5f9 testo #334155. Stato vuoto/caricamento `.sched-empty`/`.sched-loading`: centrato #64748b, bg #f8fafc, bordo tratteggiato #e2e8f0.

Stato modulo: `_schedActiveSection` ('types'|'slots'|'template'|'activation'|'overrides'), `_schedData = { slotTypes, timeSlots, templates, tplSlots, activated, overrides }`, `_schedSelectedTemplateId`, `_schedOverrideDate`, costante `_SCHED_ACTIVATION_WEEKS = 12`. Ordinamento giorni: `_WEEKDAY_SHORT = ['Dom','Lun','Mar','Mer','Gio','Ven','Sab']` indicizzato per weekday DB (0=Domenica), ordine visuale `_WEEKDAY_ORDER = [1,2,3,4,5,6,0]` (Lun→Dom).

**Caricamento (`_schedLoadAll`)** — 4 SELECT parallele org-scoped (tutte `.eq('org_id', org)`):
- `slot_types` `select('*')` order `sort_order` asc;
- `time_slots_config` `select('*')` order `sort_order` asc, poi `start_time` asc;
- `weekly_schedule_templates` `select('*')` order `created_at` asc;
- `activated_weeks` `select('*')` order `week_start` asc.
Poi `_schedLoadTemplateSlots()`: `weekly_template_slots` `select('*')` `.eq('org_id',org).eq('template_id',_schedSelectedTemplateId)`. Template selezionato di default: quello con `is_active`, altrimenti il primo. `_schedLoadOverrides(date)`: `schedule_overrides` `select('*')` `.eq('org_id',org).eq('date',date)` order `time` asc.
Errore load → toast `⚠️ Errore nel caricamento orari.`.

Guard comune scritture `_schedRequireOrg()`: senza `window._orgId` → toast `⚠️ Organizzazione non disponibile. Riprova dopo il login.`; senza `supabaseClient` → `⚠️ Connessione non disponibile.`. Le scritture sono INSERT/UPDATE/DELETE dirette via `supabaseClient.from(...)` (RLS `is_org_admin()` autorizza solo owner/admin — lo staff vede la UI ma il server rifiuta); OGNI insert include `org_id = window._orgId`.

### 4.2 Editor 1 — Tipi slot (`slot_types`)

Sezione (`_schedRenderTypes`): titolo `Tipi di slot`, descrizione `Le categorie di lezione (es. Personal, Small Group). Capienza e prezzo qui sono i valori di default.`, bottone `+ Nuovo tipo`.
Lista: per ogni tipo una `.sched-row` con: pallino colore `.sched-color-dot` 16px (background = `slot_types.color`, fallback #8B5CF6); titolo = label + badge `non prenotabile` (`--muted`) se `!bookable` + badge `disattivo` (`--off`) se `!is_active`; sottotitolo `capienza {default_capacity} · €{default_price con 2 decimali}`; azioni `✏️` (title "Modifica") e `🗑️` (title "Elimina").
Vuoto: `Nessun tipo di slot configurato. Creane uno per iniziare.`

**Form inline** (`schedEditType(id?)`, host `#schedTypeForm`, card `.sched-form` bg #faf5ff bordo #ede9fe): titolo `Nuovo tipo di slot` / `Modifica tipo`. Campi (grid auto-fit minmax 160px):
- `Etichetta` (text, placeholder `Personal Training`)
- `Colore` (input type=color, default `#8B5CF6`)
- `Capienza default` (number min 0 step 1)
- `Prezzo default (€)` (number min 0 step 0.01)
- `Ordine` (number step 1)
Checkbox: `Prenotabile dai clienti`, `Attivo`. Azioni: `Annulla` (ghost) e `Crea tipo`/`Salva modifiche` (primary).

`schedSaveType(id)`: etichetta obbligatoria (toast `⚠️ Inserisci un'etichetta.`); per i nuovi tipi la `key` è generata da `_schedUniqueKey(label)` (slugify + suffisso `-2`, `-3`… anti-collisione; NON esposta in UI e mai modificata in update). Update: `from('slot_types').update(payload).eq('id',id).eq('org_id',org)`; insert: `.insert({...payload, key, org_id})`. Payload: `{ label, color, default_capacity, default_price, bookable, is_active, sort_order }`. Toast `✅ Tipo aggiornato.` / `✅ Tipo creato.`; duplicato (code 23505) → `⚠️ Esiste già un tipo con questa chiave.`; altro → `⚠️ Errore nel salvataggio.`.
`schedDeleteType(id)`: confirm `Eliminare il tipo "{label}"? Verrà rimosso anche dalle settimane tipo.` → DELETE; toast `🗑️ Tipo eliminato.`; errore → `⚠️ Impossibile eliminare (potrebbe essere usato in prenotazioni).`.

Parsing interi: `_schedParseInt(raw, fallback)` — stringa vuota/invalida → fallback, `'0'` → 0 legittimo.

### 4.3 Editor 2 — Fasce orarie (`time_slots_config`)

Sezione (`_schedRenderSlots`): titolo `Fasce orarie`, descrizione `Gli intervalli prenotabili della giornata. L'etichetta usata nelle prenotazioni è "HH:MM - HH:MM".`, bottone `+ Nuova fascia`.
Riga fascia: chip `🕐 {HH:MM - HH:MM}` (`_schedSlotLabel(ts)` = `start_time`/`end_time` troncati a 5 char, uniti da ` - `); titolo = `label` oppure l'etichetta oraria + badge `disattiva` se `!is_active`; sottotitolo `ordine {sort_order}`; azioni ✏️/🗑️.
Vuoto: `Nessuna fascia oraria configurata. Aggiungine una.`

**Form** (`schedEditSlot`, host `#schedSlotForm`): titolo `Nuova fascia oraria`/`Modifica fascia`; campi `Inizio` (time, default 09:00), `Fine` (time, default 10:00), `Etichetta (opzionale)` (placeholder `Mattina`), `Ordine`; azioni `Annulla` / `Crea fascia` / `Salva`.
`schedSaveSlot(id)`: validazioni `⚠️ Inserisci inizio e fine.` e `⚠️ La fine deve essere dopo l'inizio.` (confronto stringhe). Payload `{ start_time, end_time, label|null, sort_order }`; insert aggiunge `is_active: true, org_id`. Toast `✅ Fascia aggiornata.`/`✅ Fascia creata.`; dup → `⚠️ Esiste già una fascia con questi orari.`; altro → `⚠️ Errore nel salvataggio.`.
`schedDeleteSlot(id)`: confirm `Eliminare la fascia "{HH:MM - HH:MM}"? Verrà rimossa dalle settimane tipo.` → DELETE; `🗑️ Fascia eliminata.` / `⚠️ Errore eliminazione.`.

### 4.4 Editor 3 — Settimana tipo (`weekly_schedule_templates` + `weekly_template_slots`)

Sezione (`_schedRenderTemplate`): titolo `Settimana tipo`, descrizione: `Configura per ogni giorno e fascia il tipo di lezione e la capienza. I template sono **modelli riutilizzabili**: per metterli in calendario attiva le singole settimane in **"Attiva settimane"**.` Bottone `+ Nuova settimana`.
Nessun template: `Nessuna settimana tipo. Creane una per impostare la griglia ricorrente.`
Barra template `.sched-tpl-bar`: select `Settimana` (`#schedTplSelect`, onchange `schedSelectTemplate`) + icone `✏️` (title "Rinomina") e `🗑️` (title "Elimina settimana").
Prerequisiti mancanti (nessuna fascia o tipo attivo): `Per comporre la griglia servono almeno una **fascia oraria** e un **tipo di slot** attivi.`

**Griglia** (`.sched-grid-wrap` scrollabile > `<table class="sched-grid">`, min-width 640px): header `Fascia` (angolo `.sched-grid-corner` bg #f1f5f9) + colonne `Lun Mar Mer Gio Ven Sab Dom`; righe = fasce attive con `<th class="sched-grid-time">{HH:MM - HH:MM}</th>`. Ogni cella `.sched-cell` (min-width 78px; `has-type` → bg #faf5ff) contiene `.sched-cell-inner`:
- pallino `.sched-cell-dot` 8px in alto a destra col colore del tipo selezionato;
- `<select class="sched-cell-type">` con opzione vuota `—` + tutti i tipi attivi (onchange `schedSetCell(weekday, timeSlotId, value, null)`);
- `<input class="sched-cell-cap" type="number" min="0" step="1" placeholder="cap" title="Capienza (vuoto = default del tipo)">` (onchange `schedSetCellCapacity`; disabled se nessun tipo).
Hint sotto la barra: `Seleziona il tipo per ogni cella. Il campo numerico imposta la capienza solo per quella cella (vuoto = capienza di default del tipo).`

Azioni:
- `schedNewTemplate()`: prompt `Nome della nuova settimana tipo:` (default `Settimana {N+1}`, bottone conferma `Crea`) → INSERT `{ org_id, name, is_active: <true se primo> }` con `.select('id').single()`; toast `✅ Settimana creata.` / `⚠️ Errore creazione settimana.`.
- `schedRenameTemplate(id)`: prompt `Nuovo nome:` (conferma `Rinomina`) → UPDATE `{name}`; errore `⚠️ Errore rinomina.`.
- `schedDeleteTemplate(id)`: confirm `Eliminare la settimana "{nome}" e tutte le sue celle?` → DELETE (le `weekly_template_slots` cascano per FK); toast `🗑️ Settimana eliminata.` / `⚠️ Errore eliminazione.`.
- `schedSetCell(weekday, timeSlotId, stId, capacity)`: mappa celle per chiave `"{weekday}|{time_slot_id}"`; stId vuoto → DELETE della riga; esistente → UPDATE `{ slot_type_id, capacity }` (capacity SEMPRE resettata a null al cambio tipo, per ereditare la default del nuovo tipo); nuova → INSERT `{ org_id, template_id, weekday, time_slot_id, slot_type_id, capacity }`. Errore → `⚠️ Errore aggiornamento cella.`.
- `schedSetCellCapacity(weekday, timeSlotId, rawValue)`: solo su cella esistente; vuoto → `null` (default tipo), `'0'` → 0; UPDATE `{capacity}` senza re-render completo (evita flicker input). Errore → `⚠️ Errore capienza cella.`.

### 4.5 Editor 3.5 — Attiva settimane (`activated_weeks`)

Il calendario si attiva UNA settimana concreta alla volta; ogni settimana punta a un template. Sezione (`_schedRenderActivation`): titolo `Attiva settimane`, descrizione `Attiva il calendario **una settimana alla volta**, scegliendo quale template applicare. Le settimane non attivate non mostrano slot; quelle già attivate restano invariate.`
Nessun template: `Crea prima almeno una **settimana tipo** (tab "Settimana tipo") da applicare alle settimane.`

Righe: finestra = settimana corrente + 12 successive (`_SCHED_ACTIVATION_WEEKS`). Ogni riga (`_schedActivationRow`), classe `.sched-row.sched-ovr-row` (+`has-ovr` se attiva → bordo #ddd6fe bg #faf5ff):
- chip `🗓️ {dd/mm} – {dd/mm}/{yyyy}` (lunedì–domenica; `_schedDM` = `dd/mm`); per la prima riga suffisso ` · **questa settimana**`;
- `<select id="awTpl-{ymd}">` coi template (preselezionato: template già attivato, altrimenti quello selezionato nell'editor o il primo);
- bottone primary `Attiva` (se non attiva) / `Aggiorna` (se attiva);
- se attiva: icona `🗑️` title "Disattiva settimana";
- badge: `✅ attiva · {nomeTemplate}` oppure `non attiva` (`--off`).

Blocco extra: settimane attivate FUORI finestra, introdotte da `Altre settimane attivate (fuori dalle prossime 12 settimane).`

Azioni:
- `schedActivateWeek(weekStart)`: template obbligatorio (`⚠️ Seleziona un template per la settimana.`). **Guard prenotazioni**: se la settimana è già attiva e si cambia template, `_schedWeekHasBookings(org, weekStart)` conta `bookings` con `select('id',{count:'exact',head:true}).eq('org_id',org).neq('status','cancelled').gte('date',weekStart).lte('date',weekEnd)` (fail-safe: errore rete → blocca); se >0 → toast `⚠️ Settimana con prenotazioni attive: non puoi cambiarne il template. Disdici/sposta prima le prenotazioni.`. Altrimenti UPSERT `from('activated_weeks').upsert({ org_id, week_start, template_id }, { onConflict: 'org_id,week_start' })`; toast `✅ Settimana attivata.` / `⚠️ Errore attivazione settimana.`.
- `schedDeactivateWeek(weekStart)`: stesso guard (toast `⚠️ Settimana con prenotazioni attive: non puoi disattivarla. Disdici/sposta prima le prenotazioni.`); confirm `Disattivare questa settimana? Gli slot non saranno più disponibili (le prenotazioni esistenti restano nel registro).` → DELETE `.eq('org_id',org).eq('week_start',weekStart)`; toast `🗑️ Settimana disattivata.` / `⚠️ Errore disattivazione.`.

Helper date: `_schedMondayOf(d)` (lunedì ISO, allineato a `date_trunc('week')` Postgres), `_schedYMD`, `_schedWeekEnd`.

### 4.6 Editor 4 — Override per data (`schedule_overrides`)

Capienza ASSOLUTA per specifico slot/data; ha la precedenza sulla settimana tipo. Sezione (`_schedRenderOverrides`): titolo `Override per data`, descrizione `Per una data specifica forza tipo e **capienza assoluta** di uno slot. Ha la precedenza sulla settimana tipo.`; a destra campo `Data` (`<input type="date" id="schedOvrDate">`, default oggi, onchange `schedChangeOverrideDate` → `_schedLoadOverrides(date)` + re-render).

Nessuna fascia: `Configura prima le fasce orarie per impostare gli override.`
Riga per ogni fascia attiva (`.sched-ovr-row`, `has-ovr` se override presente):
- chip `🕐 {HH:MM - HH:MM}`;
- `<select id="ovrType-{tsId}" class="sched-ovr-type">` con `— Nessun override —` + tutti i tipi;
- `<input id="ovrCap-{tsId}" class="sched-ovr-cap" type="number" min="0" step="1" placeholder="capienza" title="Capienza assoluta per questa data">`;
- bottone `Salva` (primary sm);
- se override esistente: icona `🗑️` title "Rimuovi override" + badge `.sched-ovr-badge` con stile inline `background:{color}1a;color:{color}` e testo `{labelTipo}` + ` · cap {n}` se capacity valorizzata.

**Override orfani** (etichetta `time` non più tra le fasce attive — la riga è indicizzata per label, non per id: cambiare orario di una fascia rende orfano l'override): blocco introdotto da `⚠️ Override per orari non più tra le fasce attive (non vengono più applicati). Rimuovili per fare pulizia.`; riga con chip `⚠️ {time}`, testo `Override orfano: fascia non più attiva` + ` · {labelTipo}` + ` · cap {n}`, icona `🗑️` title "Rimuovi override orfano".

Azioni:
- `schedSaveOverride(timeLabel, tsId)`: tipo obbligatorio (`⚠️ Seleziona un tipo di slot per l'override.`); capacity vuota → null (default tipo). UPSERT `from('schedule_overrides').upsert({ org_id, date: _schedOverrideDate, time: timeLabel, slot_type: st.key, slot_type_id: stId, capacity }, { onConflict: 'org_id,date,time' })`; toast `✅ Override salvato.` / `⚠️ Errore nel salvataggio override.`; ricarica overrides.
- `schedDeleteOverride(timeLabel)`: confirm `Rimuovere l'override delle {time} del {YYYY-MM-DD}?` → DELETE `.eq('org_id').eq('date').eq('time')`; toast `🗑️ Override rimosso.` / `⚠️ Errore rimozione override.`.

### 4.7 Bridge legacy + persistenza override (consumati dal calendario §3)

Funzioni ponte in fondo a admin-schedule.js (contratto sulla cache localStorage, consumate da admin-calendar.js/admin-messaggi.js):
- `getScheduleForDate(dateFormatted, dayName)`: 1) se `BookingStorage.getScheduleOverrides()[date]` non vuoto → quello (l'override per-data ha la precedenza); 2) altrimenti `getWeeklySchedule(dateFormatted)` (data.js, DATE-AWARE: risolve il template della settimana ATTIVATA che contiene la data via `_ORG_ACTIVE_WEEKS[mondayYMD]` → `_ORG_TPL_WEEKLY[tid]`; settimana non attivata → `{}` vuoto in contesto org — NIENTE fallback al default legacy) e ritorna `weekly[nomeGiornoItaliano]`; 3) fallback `[]`.
- `saveScheduleForDate(dateFormatted, dayName, slots)`: scrive nella cache override e sincronizza.
- `getScheduleWeekDates(offset)`: date Lun→Dom come `getAdminWeekDates`.

**BookingStorage.getScheduleOverrides()** (data.js): cache in memoria + `localStorage['scheduleOverrides_{orgId}']` (namespaced per org, `'anon'` senza org — anti leak cross-tenant); formato `{ 'YYYY-MM-DD': [{ time, type, capacity?, slotTypeId?, client?{name,email,whatsapp}, bookingId? }] }`. Cache invalidata se cambia l'org.
**BookingStorage.saveScheduleOverrides(overrides, changedDates)**: salva localStorage e in async: UPSERT su `schedule_overrides` con righe `{ org_id, date, time, slot_type, slot_type_id (lookup uuid da _ORG_SLOT_TYPES), capacity (assoluta o null), client_name, client_email, client_whatsapp, booking_id }` `onConflict:'org_id,date,time'`; poi per ogni data cambiata DELETE degli slot rimossi (select `id,time` per data e delete `.in('id', toDelete)`).
**Egress override (finestrato)**: la lettura in `syncAppSettingsFromSupabase()` scarica `schedule_overrides` con `select('date, time, slot_type, slot_type_id, capacity, client_name, client_email, client_whatsapp, booking_id').gte('date', cutoff)` paginato (`fetchAllPaginated`, batch 1000); cutoff da `_overridesCutoff()`: **admin → 1° gennaio dell'anno precedente**; non-admin → **oggi − 30 giorni**. Nella stessa sync vengono lette `org_settings` (autenticato: `select('key,value').eq('org_id',orgId)`; anonimo: RPC `get_public_org_settings { p_org_slug }`) e propagato l'eventuale `data_cleared_at` (svuota tutte le cache).
La config orari (tipi/fasce/settimane/template) usata dal calendario è caricata da `loadOrgScheduleConfig()` (§ contesto comune) che legge anche `weekly_template_slots` con select annidata `template_id, weekday, capacity, slot_type_id, time_slots_config(start_time, end_time), slot_types(key, default_capacity)`.
NB server-side: la fonte di verità per il tipo/capienza di uno slot è la RPC **`resolve_slot_config(org, date, time)`** (usata da `book_slot`/`get_availability_range`): precedenza override → template settimana attivata → default tipo; la UI replica la stessa precedenza client-side in `getEffectiveCapacity`.

### 4.8 Stati e gating

- Loading: `⏳ Caricamento configurazione orari…`.
- Stati vuoti/errore: tutti i testi esatti riportati nelle sottosezioni.
- Le RLS `*_admin` (is_org_admin) consentono le scritture solo a owner/admin; lo staff può navigare ma le scritture falliscono server-side. Nessuna subscription realtime; i dati si ricaricano a ogni azione (`_schedLoadAll` dopo ogni save/delete).

---

## 5. Tab Registro

File: `js/admin-registro.js`. Markup statico completo in `admin.html` (`#tab-registro`). Entry point: `renderRegistroTab()` = `applyRegistroFilters()` (render immediato da cache, no flicker) + `_registroRefreshData()` (fetch in background).

### 5.1 Struttura e sub-tab

```
#tab-registro
  .registro-subtabs      (3 bottoni, underline style)
    "Registro"           (data-subtab="registro", attivo)
    "Notifiche admin"    (data-subtab="notifiche-admin")
    "Notifiche clienti"  (data-subtab="notifiche-clienti")
  #registroSubtab-registro / -notifiche-admin / -notifiche-clienti (.registro-subtab-content)
```

`switchRegistroSubtab(name, btn)` commuta le classi `active`; lazy-load alla prima apertura: `notifiche-admin → loadMessaggi()`, `notifiche-clienti → loadClientNotifications()`. Stile sub-tab: testo #64748b, attivo #7C3AED con `border-bottom: 3px solid #8B5CF6` weight 700.

Ogni sub-tab è una `.reg-panel` con: header-toggle filtri (`.reg-header-toggle` con `<h3>` + chevron `.reg-filters-toggle-icon` "▼"; `toggleRegFilters(btn)` apre/chiude `.reg-filters-collapsible` con classe `open`), tabella desktop (`.registro-table-wrap` — nascosta su mobile), lista mobile (`.registro-mobile-list` — visibile solo mobile), paginazione (`.registro-pagination` con bottoni `← Prec` / `Succ →` e info centrale). Su mobile (≤768px) le righe filtri del sub-tab Registro e le filter-bar delle notifiche sono nascoste (i filtri vanno nel bottom-sheet della dock mobile).

### 5.2 Sub-tab Registro — filtri (testi esatti da admin.html)

Header: `📋 Registro Operazioni`.

- **Periodo (data evento)** — pill `.rfilter-btn` con `data-range`: `Tutto` (attivo default), `Questo mese`, `Mese scorso`, `Quest'anno`, `📅 Personalizzato`. `setRegistroRange(range, btn)`; `custom` mostra `#registroCustomDates` (due `input date` separati da `→` + bottone `Applica` → `applyRegistroCustomRange()`; validazioni con `showAlert`: `Seleziona entrambe le date.` e `La data di inizio deve essere precedente alla data di fine.`).
- **Tipo evento** — pill multi-selezione (`toggleRegistroType(btn)`, nessuna attiva = tutte), `data-etype`: `📅 Prenotazione` (booking_created), `✅ Pagamento` (booking_paid), `❌ Annullamento` (booking_cancelled), `⬆️ Credito Manuale` (credit_added), `📋 Debito Manuale` (manual_debt), `💰 Debito Saldato` (manual_debt_paid), `💸 Mora` (cancellation_mora). NB: gli ultimi 4 sono pill legacy presenti nell'HTML ma `buildRegistroEntries()` genera SOLO eventi booking_* (sistema crediti rimosso): selezionarli filtra a vuoto.
- **Tipo lezione** — select `#registroFilterSlot`: `Tutte` (all), `Autonomia` (personal-training), `Lezione di Gruppo` (small-group), `Slot prenotato` (group-class).
- **Metodo pagamento** — select `#registroFilterMethod`: `Tutti`, `💵 Contanti` (contanti), `🧾 Contanti con Report` (contanti-report), `💳 Carta` (carta), `💳 Stripe` (stripe, con `data-feature="client_online_payments"`), `🏦 Bonifico` (iban), `🔄 Credito` (credito, legacy), `🎁 Gratuita` (lezione-gratuita).
- **Stato** — select `#registroFilterStatus`: `Tutti`, `Pagato` (paid), `Non pagato` (unpaid), `Annullato` (cancelled).
- **Cerca cliente** — input `#registroSearch` placeholder `Nome, telefono...`, oninput `_debouncedRegistroFilter()` (debounce 250ms su nome+telefono+email).
- **Reset** — `↺ Reset` (`.rfilter-btn--reset`, rosso: bordo #fca5a5, testo #dc2626, bg #fef2f2) → `resetRegistroFilters()` (riporta range 'all', svuota pill/select/search, sort timestamp desc, pagina 0).

Colori pill: default bg #f8fafc bordo #e2e8f0 testo #475569; hover bordo/testo #8B5CF6; attiva gradient `#8B5CF6→#7C3AED` testo bianco.

### 5.3 Aggregazione eventi e tabella desktop

**`buildRegistroEntries()`**: da `BookingStorage.getAllBookings()` (esclusi `_avail_*`) genera fino a 4 eventi per booking:
1. `booking_created` — timestamp `createdAt` (fallback `{date}T08:00:00`), amount `getBookingPrice(b)`, actor `admin` se `_isAdminAction(createdBy, userId)` (attore ≠ proprietario), altrimenti `user`;
2. `booking_paid` — se `paidAt` (o `cancelledPaidAt` per annullate-dopo-pagamento); method `paymentMethod`/`cancelledPaymentMethod`;
3. `booking_cancellation_req` — se `cancellationRequestedAt`; actor da `cancelledBy`;
4. `booking_cancelled` — se `status==='cancelled' && cancelledAt`; actor `system` se `!cancelledBy && cancellationRequestedAt` (completato da `fulfill_pending_cancellation`), altrimenti admin/user.
Campi base evento: `bookingId, clientName, clientPhone, clientEmail, lessonDate, lessonTime, slotType, slotLabel` (mappa locale `SLOT_LABEL = { 'personal-training':'Autonomia', 'small-group':'Lezione di Gruppo', 'group-class':'Slot prenotato', 'cleaning':'Pulizie' }`), `notes, eventType, timestamp, amount, paymentMethod, bookingStatus, bookingPaid, actorType`.

**`applyRegistroFilters()`**: filtra su periodo (`_registroGetDateRange()`: this-month/last-month/this-year/custom), tipi attivi, slot, metodo, stato (`unpaid` = solo booking_created non pagati e non annullati), ricerca; ordina per `_registroState.sortField` ('timestamp' default | 'lessonDate') × `sortDir` ('desc' default); salva `_registroFiltered`, azzera pagina, `_updateRegistroSummary()` + `renderRegistroTable()`.

**Summary** (`_updateRegistroSummary`): scrive su `#registroTotalEvents`, `#registroTotalPaid` (con tooltip: `Valore teorico delle prenotazioni (prezzi correnti). Per l'incassato reale vedi Statistiche → Fatturato (ledger pagamenti).`), `#registroTotalBookings` — **questi elementi NON esistono nell'HTML attuale** (guard `if (el)`), quindi no-op: in Flutter si può ometterli o reintrodurli.

**Ordinamento colonne**: `toggleRegistroSort(field)` su header `Data/Ora` (`#registroSortTs`) e `Data Lezione` (`#registroSortLesson`); icona `↓`/`↑` sul campo attivo.

**Tabella** `.registro-table` (min-width 860px, thead gradient #f1f5f9→#e8ecf1, th uppercase 0.78rem #475569). Colonne: `Data/Ora` (sortable) | `Tipo` | `Cliente` | `Data Lezione` (sortable) | `Ora` | `Tipo Lezione` | `Importo` | `Metodo` | `Stato` | `Nota`.
Riga (`renderRegistroTable`, pagina di 50 = `REGISTRO_PAGE_SIZE`):
- `registro-ts`: `toLocaleString('it-IT', {day:'2-digit',month:'2-digit',year:'2-digit',hour:'2-digit',minute:'2-digit'})` (#888, 0.78rem);
- badge tipo `.rtype-badge` da `EVENT_CONFIG`: booking_created `📅 Prenotazione` (`.rtype-booking` bg #dbeafe testo #1d4ed8); booking_paid `✅ Pagamento` (`.rtype-paid` #dcfce7/#15803d); booking_cancelled `❌ Annullamento` (`.rtype-cancelled` #fee2e2/#b91c1c); booking_cancellation_req `⏳ Rich. Annullamento` (`.rtype-pending` #fef3c7/#92400e);
- cliente: `.registro-client-name` weight 600;
- data lezione `dd/mm/yyyy`; ora = `lessonTime` (es. `08:00 - 09:20`);
- importo `€{n.toFixed(2)}` o `—` (`.registro-amount` verde #059669 weight 700);
- metodo: icona+label da `METHOD_ICON = { contanti:'💵', 'contanti-report':'🧾', carta:'💳', iban:'🏦' }`, `METHOD_LABEL = { contanti:'Contanti', 'contanti-report':'Contanti con Report', carta:'Carta', iban:'Bonifico' }`, `—` se assente;
- stato (`statusHTML`): `cancelled` → `<span class="rstatus-badge rstatus-cancelled">Annullato</span>` (bg #f3f4f6 testo #6b7280); `cancellation_requested` → `In attesa` (`.rstatus-pending` #fef3c7/#92400e); paid true → `Pagato` (`.rstatus-paid` bg rgba(6,214,160,0.15) testo #059669); paid false → `Non pagato` (`.rstatus-unpaid` #fee2e2/#b91c1c); altrimenti `—`;
- nota: ellipsis max-width 150px, title = testo completo.
**Evidenziazione attore riga**: `actorType==='admin'` → classe `registro-admin` (celle bg **#fef2f2**, hover #fee2e2); `system` → `registro-system` (bg **#f0fdf4**, hover #dcfce7); user → nessuna (hover #f8fafc).

**Paginazione**: `#registroPaginationInfo` = `"{start+1}–{end} di {total}"` oppure `Nessun risultato`; bottoni `#registroPrevBtn`/`#registroNextBtn` (`← Prec` / `Succ →`, disabled ai bordi; `registroPrevPage()`/`registroNextPage()`). Placeholder iniziale tbody: `Seleziona il tab per caricare il registro.`; nessun match: `Nessun evento trovato con i filtri selezionati.` (colspan 10, `.registro-empty` #94a3b8).

**Export** (`exportRegistro()`): genera XLSX (libreria `XLSX`) `TB_Registro_{YYYY-MM-DD}.xlsx`, foglio `Registro`, intestazioni: `Data/Ora Evento, Tipo Evento, Cliente, Telefono, Email, Data Lezione, Ora Lezione, Tipo Lezione, Importo (€), Metodo Pagamento, Stato, Attore, Note, Booking ID`; attore = `Admin`/`Sistema`/`Utente`; vuoto → alert `Nessun dato da esportare con i filtri correnti.`; feedback bottone `#registroExportBtn` → `✅ Scaricato!` per 2.5s (NB: il bottone non è presente nell'HTML attuale).

### 5.4 Lista mobile (Variante A, `renderRegistroMobile`)

Visibile ≤768px al posto della tabella. Eventi raggruppati per giorno con separatore `.reg-mob-sep` (uppercase 10px #64748b): `Oggi · {d} {mese}` / `Ieri · {d} {mese}` / `{Dom|Lun|...} · {d} {mese} {yyyy}` (`_regDayKey`, `_regShortDate` con mesi `gen…dic`, `_regFullDate`). Gruppo `.reg-mob-group` = card bianca radius 14px.
Riga `.reg-mob-row` (tap = espande il dettaglio; una sola aperta per lista): 
- `.reg-mob-time`: ora `HH:MM` in grassetto + sotto `oggi`/`ieri`/`{d} {mese}`;
- tag icona `.reg-mob-tag` 24px (SVG inline `_regSVG()`): booking_created `.book` (bg #dbeafe testo #1d4ed8, icona calendario); booking_paid `.pay` (#dcfce7/#166534, check); booking_cancelled `.cancel` (#fee2e2/#991b1b, ban); booking_cancellation_req `.warn` (#fef3c7/#b45309, clock);
- `.reg-mob-name`: nome cliente (ellipsis);
- `.reg-mob-amt` a destra: per created/cancellation_req mostra ora inizio lezione + data stack (`<b>{HH:MM}</b><i>{dd/mm}</i>`); per paid `+€{n}` verde #166534 (`.plus`); altrimenti `—`;
- chevron `.reg-mob-chev`.
Righe attore: `admin` → `.reg-mob-row--admin` bg #fef2f2 (open #fee2e2), `system` → `.reg-mob-row--system` bg #f0fdf4 (open #dcfce7); dettaglio con stesse tinte.
Dettaglio `.reg-mob-detail` (grid dt/dd): `Tipo` (icona+label + badge `Admin` `.reg-mob-badge.admin` #fde68a/#92400e o `Sistema` `.system` #d1fae5/#065f46), `Slot`/`Prenotaz.` (data `dd/mm/yyyy · HH:MM - HH:MM`), `Modalità` (badge `.reg-mob-badge.auto` con slotLabel), `Importo` (`€ {n}` o `—`), `Metodo` (se presente), `Stato` (statusHTML), `Nota` (se presente). Azione: bottone `Vedi cliente` (`.reg-mob-btn.primary` bg #8B5CF6) → `regMobOpenClient(nome)`: `switchTab('clients')` e dopo 60ms `openClientCardByName(nome)` (fallback: riempie la barra di ricerca clienti).
Vuoto: `Nessun evento trovato con i filtri selezionati.` (`.registro-mobile-empty`).

### 5.5 Sub-tab "Notifiche admin" (tabella `admin_messages`)

Header: `📩 Storico notifiche`. Filtri (`.reg-panel-filters-row`):
- select `#msgFilterType` (onchange `loadMessaggi()` — filtro applicato SERVER-SIDE): `Tutti i tipi`, `✔️ Prenotazioni` (booking), `❌ Annullamenti` (cancellation), `🆕 Nuovi iscritti` (new_client), `💰 Ricariche` (topup);
- select `#msgFilterStatus` (onchange `renderMessaggiTable()`): `Tutti gli stati`, `✅ Inviata` (sent), `❌ Non inviata` (failed);
- `input date #msgFilterDate` (client-side, confronta la data locale di `created_at`);
- `↺ Reset` (svuota i 3 filtri e rilancia `loadMessaggi()`).

**`loadMessaggi()`**: `supabaseClient.from('admin_messages').select('created_at,type,date,title,body,client_name,sent_count').order('created_at',{ascending:false}).limit(500)` + `.eq('type', typeFilter)` se selezionato (i 500 più recenti mascheravano i tipi rari). Errore → riga `❌ Errore caricamento messaggi. Riprova` (link rilancia).
Tabella (colonne): `Data/Ora | Tipo | Titolo | Dettaglio | Cliente | Stato`. Tipo da `_MSG_TYPE_LABELS = { booking:'✔️ Prenotazione', cancellation:'❌ Annullamento', proximity:'📍 Arrivo', proximity_no_booking:'📍 Senza prenot.', new_client:'🆕 Nuovo iscritto', broadcast:'📢 Broadcast', topup:'💰 Ricarica' }`. Stato: `✅ Inviata ({sent_count})` verde #22c55e / `❌ Non inviata` rosso #ef4444 (weight 600).
Paginazione client-side 50/pagina (`MESSAGGI_PAGE_SIZE`), info `"{pagina}/{totPagine} ({tot})"`, bottoni `← Prec`/`Succ →` (`messaggiPrevPage`/`messaggiNextPage`). Vuoto: `Nessun messaggio trovato`. Placeholder iniziale: `Caricamento...`.
Mobile (`renderMessaggiMobile`): stesso pattern Variante A; tag per tipo (booking `.book`, cancellation `.cancel` con icona ✗, proximity `.neutral` campanella, proximity_no_booking `.warn`, new_client `.credit` user-plus #ede9fe/#6d28d9, broadcast `.warn` megafono, topup `.credit` wallet, più tipi access_request_*); pill destra `✓` verde / `✗` rossa; badge stato `Inviata · {n}` (`.paid`) / `Non inviata` (`.cancel`); dettaglio con `Tipo/Titolo/Dettaglio/Cliente/Stato`; bottone `Vedi cliente` se `client_name` presente.

### 5.6 Sub-tab "Notifiche clienti" (tabella `client_notifications`)

Header: `📬 Notifiche ai clienti`. Filtri:
- select `#cnFilterType`: `Tutti i tipi`, `⏰ Promemoria 24h` (reminder_24h), `⏰ Promemoria 1h` (reminder_1h), `🟢 Slot disponibile` (slot_available), `📢 Broadcast` (broadcast);
- select `#cnFilterStatus`: `Tutti gli stati`, `✅ Inviata` (sent), `❌ Fallita` (failed), `⚠️ No subscription` (no_subscription);
- `input text #cnFilterClient` placeholder `Cerca cliente...` (debounce 250ms `_debouncedCnFilter`, matcha `user_name`/`user_email`);
- `input date #cnFilterDate` (confronta `booking_date`);
- `↺ Reset`.

**`loadClientNotifications()`**: `from('client_notifications').select('created_at,type,status,user_name,user_email,title,body,error,booking_date').order('created_at',{ascending:false}).limit(1000)`. Tutti i filtri client-side (`renderClientNotifTable`). Errore → `❌ Errore caricamento notifiche. Riprova`.
Tabella: `Data/Ora | Tipo | Cliente | Titolo | Dettaglio | Stato`. Tipo da `_CN_TYPE_LABELS = { reminder_24h:'⏰ Promemoria 24h', reminder_1h:'⏰ Promemoria 1h', slot_available:'🟢 Slot disponibile', broadcast:'📢 Broadcast' }`; stato da `_CN_STATUS_LABELS = { sent:'✅ Inviata', failed:'❌ Fallita', no_subscription:'⚠️ No sub' }` (colore: sent #22c55e, failed #ef4444, altro #eab308); l'eventuale `error` è appeso al Dettaglio in `<small>` rosso #ef4444.
Paginazione 50/pagina (`CN_PAGE_SIZE`, `cnPrevPage`/`cnNextPage`, `#cnPaginationInfo`). Vuoto: `Nessuna notifica trovata`. Placeholder: `Caricamento...`.
Mobile (`renderCnMobile`): tag (reminder `.warn` clock, slot_available `.pay` segnale, broadcast `.warn` megafono, access_request_* vari); pill: sent `✓` verde, failed `✗` rossa, no_subscription `!` ambra #b45309; badge stato `Inviata` (`.paid`) / `Fallita` (`.cancel`) / `No sub` (`.pending` #fef3c7/#92400e); dettaglio `Tipo/Titolo/Dettaglio/Cliente/Email/Lezione (booking_date)/Stato/Errore` (errore in #991b1b); bottone `Vedi cliente` se `user_name`.

### 5.7 Logica dati / egress

- **Refresh registro** (`_registroRefreshData`): invocato SOLO da `renderRegistroTab()` (ingresso nel tab); guard doppia — flag `_registroSyncInFlight` + cooldown `REGISTRO_SYNC_COOLDOWN_MS = 10_000` ms. Chiama `BookingStorage.syncFromSupabase({ forceFull: true })` (**il Registro è vista di audit: bypassa fingerprint/delta per avere dati completi**). Al termine ri-applica i filtri SOLO se il tab attivo è ancora `registro`. Errore: `console.warn` silenzioso (i dati cache restano visibili).
- Filtri/ordinamento interni passano da `applyRegistroFilters()` senza rete.
- Paginazioni: registro 50 (`REGISTRO_PAGE_SIZE`), messaggi 50 (limit fetch 500), notifiche clienti 50 (limit fetch 1000). `_showMoreItems` NON usato qui.
- Nessuna subscription realtime nei 3 sub-tab.
- Stato modulo: `_registroState = { range:'all', customFrom:null, customTo:null, sortField:'timestamp', sortDir:'desc', page:0 }`, `_registroFiltered`; `_messaggiCache/_messaggiFiltered/_messaggiPage`; `_cnCache/_cnFiltered/_cnPage`.
- Helper condivisi: `_debounce`, `_localDateStr`, `_escHtml`/`_escAttr` (ui.js), `_regBtnArg` (escape per onclick), `_queryWithTimeout` (timeout 12s default).

### 5.8 Note per il porting

- L'evidenziazione rows admin (rosso) / system (verde) e il chip `Admin`/`Sistema` sono il segnale visivo chiave dell'attore: replicarli 1:1.
- La colonna `Importo` del registro è il VALORE TEORICO (prezzi correnti da `getBookingPrice`), NON l'incassato del ledger `payments` (che vive in Statistiche): non presentarli come riconciliabili.
- Le pill evento legacy (Credito/Debito/Mora) e il metodo `credito`/`lezione-gratuita` esistono solo nei filtri HTML: in Flutter si possono omettere o mantenere per parità visiva (filtrano a vuoto).

---

# (Sezione per la spec di migrazione Flutter — area admin PalestrIA)

## 6. Tab Clienti

Fonte: `js/admin-clients.js` (1607 righe), markup in `admin.html` (`#tab-clients`, righe 219–267 + modali cert/assic 730–772), stili in `css/admin.css`, dati in `js/data.js`, helper anagrafici in `js/admin-analytics.js`, popup nuovo cliente in `js/new-client-popup.js`. Variabili CSS globali (`css/style.css` `:root`): `--primary-purple: #8B5CF6`, `--primary-purple-dark: #7C3AED`, `--success: #06d6a0`, `--dark-bg: #1a1a1a`.

---

### 6.1 Layout della tab

Struttura verticale del pannello `#tab-clients` (dall'alto in basso):

1. **Titolo pagina** `.tab-page-title`: `<h2>Clienti</h2>` (1.65rem, weight 800, `#0f172a`, letter-spacing −0.02em) + sottotitolo `<span id="clientsPageSub">` (0.8rem, `#94a3b8`, weight 500) con testo **`{N} totali · {M} attivi`** (aggiornato da `renderClientsSummary`). Prima del primo render contiene `&nbsp;`.

2. **Barra ricerca** `.clients-search-bar` (colonna, gap 0.6rem, margin-bottom 1.5rem; `position:relative` inline):
   - Riga `.clients-search-row` (flex, gap 0.5rem, align stretch):
     - Input `#clientSearchInput`, placeholder esatto **`Cerca cliente..`** (due punti, non tre), `oninput="liveSearchClients()"`, `onkeydown` Escape → `closeClientsSearchDropdown()`. Focus: border `var(--primary-purple)`, box-shadow `0 0 0 3px rgba(139,92,246,0.10)`, bg `#fff`.
     - Bottone `#clientsFilterToggle` `.clients-filter-toggle`: contenuto **`🔍 Filtri ▼`** (emoji in `.filter-toggle-emoji`, testo " Filtri" in `.filter-toggle-text`, freccia in `#clientsFilterToggleArrow` che diventa `▲` a menu aperto). Stile: bg `#fff`, border `1.5px solid #e5e7eb`, color `#6b7280`, 0.85rem/600, padding 0.4rem 0.9rem, radius **12px**. Hover: bg `#f9fafb`, border `#d1d5db`, color `#374151`. `.active` (≥1 filtro attivo): bg `#f0f9ff`, border `var(--primary-purple)`, color `var(--primary-purple-dark)`.
   - Dropdown risultati `#clientsSearchDropdown` `.debtor-search-dropdown` (assoluto, `right:0; top:42px` per questa barra): bg white, border `1.5px solid var(--primary-purple)` senza top, radius `0 0 10px 10px`, shadow `0 6px 20px rgba(0,0,0,0.10)`, max-height 260px scroll, z-index 100.
   - Menu chips `#clientsFilterChips` `.clients-filter-chips` (display none → flex con classe `.open`; wrap, gap 0.45rem, margin-top 0.5rem). **5 chip** `.clients-filter-chip` con testi ESATTI:
     - `#certFilterBtn` → **`🏥 Senza certificato`** (`toggleCertFilter()`)
     - `#assicFilterBtn` → **`📋 Senza assicurazione`** (`toggleAssicFilter()`)
     - `#anagFilterBtn` → **`📝 Senza anagrafica`** (`toggleAnagFilter()`)
     - `#privacyFilterBtn` → **`🔒 Anonimi`** (`togglePrivacyFilter()`)
     - `#pushFilterBtn` → **`🔕 Notifiche Disattivate`** (`togglePushFilter()`)
     Stile chip: bg `#fff`, border `1.5px solid #e5e7eb`, color `#6b7280`, 0.8rem/600, padding 0.3rem 0.8rem, radius **20px**. Hover: bg `#fef2f2`, border `#fca5a5`, color `#dc2626`. `.active`: bg `#fef2f2`, border `#ef4444`, color `#dc2626`, shadow `0 1px 4px rgba(239,68,68,0.15)`.

3. **Risultato filtro** `#clientsFilterResult` `.clients-filter-result` (visibile solo con filtro attivo; colonna centrata, padding 1.2rem 0.5rem): `<span class="filter-result-label">{etichetta filtro}</span><span class="filter-result-count">{n}</span>`. Label 1rem `var(--text-secondary,#666)`; count **2.2rem/700 `var(--primary,#ef4444)`** (la var `--primary` non è definita → fallback rosso `#ef4444`).

4. **Stat cards** `#clientsStatsGrid` (`.stats-grid.stats-grid--payments`, grid `repeat(auto-fit,minmax(220px,1fr))`, gap 1rem, margin-bottom 2.5rem) con **2 card cliccabili** `.stat-card.stat-card--clickable`:
   - `#statcard-clienti-totali`: hint `#clientsTotalHint` (**`Dettagli ▼`** / **`Nascondi ▲`**), icona `👥`, `<h3>Clienti Totali</h3>`, valore `#clientsTotalCount`. `onclick="toggleClientsTotalList()"`, `title="Clicca per vedere la lista"`.
   - `#statcard-clienti-attivi`: hint `#clientsActiveHint`, icona `💪`, `<h3>Clienti Attivi</h3>`, valore `#clientsActiveCount`. `onclick="toggleClientsActiveList()"`.
   Stile `.stat-card`: bg `#fff`, padding `1.4rem 1.35rem 1.2rem`, radius **16px**, border `1px solid rgba(0,0,0,0.06)`, shadow `0 1px 3px rgba(0,0,0,0.03), 0 4px 14px rgba(0,0,0,0.04)`, barra accent top 3px (`::after`, default `#d1d5db`), hover `translateY(-3px)`. `h3` 0.7rem uppercase `#9ca3af` ls 0.08em; `.stat-value` 2rem/800 `#111`; `.stat-icon` 1.5rem in box 2.85rem radius 12px bg `#f3f4f6`. `.stat-card--clickable.active` (lista aperta): border `1.5px solid #8B5CF6`, shadow `0 0 0 3px rgba(139,92,246,0.10), 0 4px 16px rgba(0,0,0,0.06)`, `transform:none`. Hint `.stat-card-click-hint`: assoluto top 0.5rem right 0.7rem, 0.62rem `#d1d5db`, → `#8B5CF6` quando `.active`.

5. **Lista clienti** `#clientsList` `.clients-list` (colonna, gap 0.6rem), `style="display:none"` di default: **la lista è nascosta finché l'utente non clicca una stat card o attiva un filtro** (`clientsListMode` = `null | 'total' | 'active'`).

**Paginazione lista** (`CLIENTS_PAGE_SIZE = 20`): `renderClientsTab()` → `_appendClientBatch(n)` renderizza le card a blocchi di **20**. In coda, se restano clienti, bottone `#clientsLoadMoreBtn` classe `.show-more-btn.clients-load-more` con testo esatto:
**`▼ Mostra altri {min(20, rimanenti)} clienti ({rimanenti} rimanenti)`** — click → `_appendClientBatch(20)`.
Stile `.show-more-btn`: self-center, bg none, border `1px solid #d1d5db`, radius 6px, color `#6b7280`, 0.8rem, padding 0.3rem 0.9rem; hover bg `#f3f4f6` color `#374151`. Variante `.clients-load-more`: `display:block; width:100%; margin-top:0.75rem; padding:0.55rem 0.9rem`. Se una card era aperta oltre il primo blocco, il primo batch viene esteso a multipli di 20 per includerla e la card viene riaperta (`openClientIndex`).

**Mobile (≤768px)**: `.clients-filter-toggle` e `.clients-filter-chips` sono `display:none !important` — i filtri vanno nel **bottom-sheet mobile** (`js/admin-mobile-filters.js`): pill `🔍 Filtri` nella barra `adm-mbar`, sheet con titolo **`Filtri clienti`**, chip proxy che cliccano le chip originali nascoste, badge contatore = numero di `.clients-filter-chip.active`. Altre regole mobile: `.clients-search-bar` gap 0.4rem margin-bottom 0.75rem; input font-size 16px (anti-zoom iOS).

**Bottone ricarica**: `refreshClients()` cerca `#refreshClientsBtn` e mostra `↻ Caricamento...` / ripristina `↻ Ricarica`, con `await UserStorage.syncUsersFromSupabase()` + `renderClientsTab()`; errore → toast **`⚠️ Errore ricarica clienti. Riprova.`** (error, 4000ms). ⚠️ Nota: nel markup attuale di `admin.html` il bottone `#refreshClientsBtn` NON esiste (residuo — la funzione degrada in no-op sul bottone ma esegue comunque sync+render se chiamata).

---

### 6.2 Filtri: stato e predicati

Stato modulo: `openClientIndex` (card aperta), `clientsShown`, `_clientsFiltered`, `clientsSearchQuery`, flag `clientCertFilter/clientAssicFilter/clientAnagFilter/clientPrivacyFilter/clientPushFilter`, `clientsListMode`.

- **Un solo filtro attivo per volta**: ogni `toggle*Filter()` chiama `_clearOtherFilters(keep)` che azzera gli altri, poi `_syncFilterButtons()` (toggla `.active` sui 5 bottoni e su `#clientsFilterToggle`) e `renderClientsTab()`.
- `toggleClientsFiltersMenu()`: toggla `.open` su `#clientsFilterChips` e la freccia `▲`/`▼`.
- **Predicati** (tutti via `_getUserRecord(email, whatsapp)` → profilo in `UserStorage._cache`):
  - `clientHasCertIssue`: `certificatoMedicoScadenza` assente **oppure** `< oggi` (`_localDateStr()`).
  - `clientHasAssicIssue`: idem su `assicurazioneScadenza`.
  - `clientHasAnagIssue`: profilo assente oppure manca uno tra `codiceFiscale`, `indirizzoVia`, `indirizzoPaese`, `indirizzoCap`.
  - `clientHasPrivacy`: `privacyPrenotazioni === true` (clienti "anonimi" nel calendario pubblico).
  - `clientHasPushDisabled`: `!pushEnabled`.
- `_activeFilterLabel()` — etichette ESATTE mostrate in `.filter-result-label`: `🏥 Senza certificato`, `📋 Senza assicurazione`, `📝 Senza anagrafica`, `🔒 Anonimi`, `🔕 Notifiche Disattivate`.
- Con filtro attivo: `#clientsStatsGrid` nascosto, `#clientsFilterResult` visibile; base = lista attivi se `clientsListMode==='active'`, altrimenti tutti.

---

### 6.3 Aggregazione clienti e contatori

- **`getAllClients()`**: costruisce la mappa clienti dalle prenotazioni `BookingStorage.getAllBookings()` con **indici O(1)** (`phoneIndex` per `normalizePhone(whatsapp)`, `emailIndex` per email lowercase) per fondere i duplicati; oggetto cliente: `{ userId, name, whatsapp, email, bookings[] }`. Poi integra `UserStorage.getAll()` (utenti registrati anche senza prenotazioni; arricchisce `userId` sui match). Ogni `bookings` ordinato per data+ora **discendenti**; lista finale ordinata per `name` (localeCompare).
- **`getActiveClients(allClients)`**: attivo = ha ≥1 prenotazione non `cancelled` con data tra **2 mesi fa e 1 mese avanti** (match per email lowercase o telefono normalizzato).
- **`renderClientsSummary(all, active)`**: scrive `#clientsTotalCount`, `#clientsActiveCount` e `#clientsPageSub` = `` `${all.length} totali · ${active.length} attivi` ``.
- `toggleClientsTotalList()` / `toggleClientsActiveList()`: togglano `clientsListMode` ('total'/'active' ⇄ null), `_updateClientsHints()` (hint `Nascondi ▲`/`Dettagli ▼` + classe `.active` sulle stat card), `renderClientsTab()`.
- Stato vuoto lista filtrata: `<div class="empty-slot">Nessun cliente trovato</div>` (centrato, padding 1.5rem, `#94a3b8`, italic, 0.88rem; mobile 0.4rem 0.75rem / 0.82rem).

---

### 6.4 Ricerca live e vista "Risultato ricerca"

- **`liveSearchClients`** = `_debounce(fn, 200)` (debounce 200ms, `data.js`). Match `includes` case-insensitive su **name, whatsapp, email**. Dropdown: max **15** risultati, item `<div class="dropdown-item" onclick="selectClientFromDropdown(i)"><span class="dropdown-item-name">{nome}</span></div>`; nessun match → `<div class="dropdown-no-results">Nessun risultato</div>` (padding 0.75rem 1rem, `#999`, 0.9rem, centrato). `.dropdown-item`: padding 0.65rem 1rem, 0.95rem, border-bottom `1px solid #f0f0f0`, hover bg `#f0f9ff`; `.dropdown-item-name` 600 `var(--dark-bg)`.
- **`selectClientFromDropdown(index)`** → **`showSingleClientCard(client, opts)`**: svuota `#clientsList`, inserisce header `.search-results-header` = `<h4>Risultato ricerca</h4><button class="btn-clear-search" onclick="clearClientsSearch()">✕ Chiudi</button>` (header flex space-between margin-bottom 1rem; bottone border `1px solid #ccc`, padding 0.25rem 0.6rem, radius 6px, 0.85rem `#666`, hover bg `#f0f0f0`), poi UNA card cliente (index 0). Con `opts.expand` la card nasce già aperta. Durante la ricerca stat cards, toggle filtri e chips sono nascosti; l'input mostra il nome del cliente; scroll `scrollIntoView smooth/nearest`.
- **`clearClientsSearch()`**: svuota input, chiude dropdown, ripristina stat cards/filtri, svuota e nasconde la lista, `clientsListMode = null`.
- **"Vedi cliente" dal Registro** (`js/admin-registro.js` → `regMobOpenClient(name)`): `switchTab('clients')` + `setTimeout(60ms)` → **`openClientCardByName(name)`** (match esatto sul nome trim/lowercase; se trovato → `showSingleClientCard(client, { expand: true })` cioè card singola GIÀ ESPANSA e ritorna true). Fallback se non trovato: riempie il primo input di ricerca del tab (placeholder contenente "cerca"/"cliente"/"nome"), dispatcha `input` e scrolla.

---

### 6.5 CARD CLIENTE — design esatto (redesign viola "v2")

Creata da **`createClientCard(client, index)`**, `div.client-card` con `id="client-card-{index}"`. Apertura: click su header o stats-grid → `toggleClientCard(id, idx)` toggla la classe `.open` (CSS-only) e aggiorna `openClientIndex`.

**Contenitore `.client-card`**: border `1px solid #eef0f3`, **border-left `4px solid #8B5CF6`** (viola brand), radius **16px**, `overflow:hidden`, shadow `0 1px 3px rgba(15,23,42,0.04)`, transition `box-shadow .2s, border-left-color .2s`. Hover: shadow `0 8px 22px rgba(15,23,42,0.09)`, border-left `#7C3AED`. `.open`: shadow `0 10px 28px rgba(15,23,42,0.11)`, border-left `#7C3AED`.

**Header `.client-card-header`** (flex, align center, gap 1rem, padding `1rem 1.15rem`, bg `#fff`, cursor pointer, `user-select:none`; hover bg `#fafbfc`; `.open`: bg **`#f5f3ff`** + border-bottom `1px solid #e5e7eb`). Contenuto in ordine:

1. **Avatar `.cv2-avatar`**: iniziali (prime lettere delle parole del nome, max 2, uppercase; fallback `?`), cerchio **44×44px**, bg `#ede9fe`, color `#7c3aed`, 0.92rem/800, ls 0.02em; `.open` → bg `#ddd6fe`. Mobile ≤480px: 38×38px, 0.82rem.
2. **Blocco info `.client-info-block`** (flex:1, min-width 0):
   - `.client-name`: **`{nome} ✏️`** — weight 700, 1.05rem, `#1a1a1a` (0.95rem su mobile). Il CSS NON imposta nowrap sul nome (il nowrap/ellipsis è sui testi contatto/residenza). La matita è `<button class="btn-edit-contact-icon" title="Modifica contatto">✏️</button>` (bg none, 0.85rem, opacity 0.5 → 1 hover) → `openEditClientPopup(index, whatsapp, email, name)` con `stopPropagation`.
   - **Età inline** `.cv2-age.cv2-age--inline` (solo mobile): icona calendario SVG 13×13 `.cv2-meta-ic` (`#94a3b8`) + `{età} anni`. Nascosta su desktop (`display:none`, → `display:flex; font-size:0.8rem` sotto 768px).
   - `.client-contacts` (in card: colonna, gap 0.18rem):
     - Telefono: `<a class="cv2-contact-link" href="https://wa.me/{phoneWa}" target="_blank" rel="noopener">` icona cornetta SVG 14×14 + `<span class="cv2-contact-txt">{numero senza prefisso +39}</span>`. **Formato link WhatsApp esatto**: dal campo `whatsapp` si tolgono i non-numerici; `0039…` → `39…`; se restano 10 cifre che iniziano per `3` → prefisso `39`. Il testo mostrato è il numero grezzo con l'eventuale `+39 ` iniziale rimosso (`replace(/^\+39\s*/, '')`).
     - Email: `<a class="cv2-contact-link" href="mailto:{email}">` icona busta SVG + testo email.
     - Stile link: inline-flex gap 0.35rem, `#475569`, 0.85rem/600, no underline; hover `#7C3AED` + underline sul testo; icone `#94a3b8`; testo ellipsis nowrap. Mobile ≤480: 0.8rem.
   - **Residenza inline** `.cv2-residence.cv2-residence--inline` (solo mobile): icona pin SVG 13×13 + `<span class="cv2-res-txt">{indirizzoPaese}</span>` (ellipsis).
   - **Riga badge `.cv2-badges-row`** (wrap, gap 0.35rem, margin-top 0.5rem; `:empty → display:none`): badge certificato + assicurazione + anagrafica + documento (v. sotto).
3. **Meta desktop `.cv2-meta`** (colonna allineata a destra, gap 0.2rem, `text-align:right`; nascosta ≤768px): età (`{n} anni` con icona calendario) e residenza (icona pin + comune, `max-width:170px` ellipsis). Font `.cv2-age/.cv2-residence`: 0.82rem `#64748b`, gap 0.3rem. Renderizzate SOLO se il dato esiste (età da CF valido, residenza non vuota).
4. **Chevron `.client-chevron`**: `▼`, 0.8rem `#aaa`, ruota 180° con `.open`. Mobile: header `position:relative`, chevron assoluto `right:0.75rem; top:0.85rem`; header diventa colonna (align flex-start, gap 0.5rem, padding 0.75rem 0.9rem).

**Età dal CF**: helper locale `_ageFromCF(cf)` — caratteri 7-8 = anno, 9 = mese-lettera (A=1…T=12), 10-11 = giorno (−40 per le donne); secolo: prova 2000+YY, se nel futuro 1900+YY; scarta età fuori 0–120. Ritorna null se non ricavabile → riga età non renderizzata.

**Badge documenti** (`.cedit-cert-badge`, generati da `_mkBadge`): pill inline 0.78rem/600, padding `0.12rem 0.5rem`, radius **20px** (nella badges-row `margin-left:0`). Stati colore: `.cedit-cert-expired` bg `#fef2f2` color `#dc2626`; `.cedit-cert-expiring` bg `#fffbeb` color `#92400e`; `.cedit-cert-ok` bg `#f0fdf4` color `#166534`. Se cliccabile è un `<button>` (border 0, cursor pointer, `.cedit-cert-badge--clickable`: hover `filter:brightness(0.96)` + shadow `0 1px 4px rgba(15,23,42,0.08)`, active brightness 0.92). Testi ESATTI (data `DD/MM/YYYY`):
- **Certificato** (visibile se `BookingBadgesStorage.getShowCert()`; click → `openCertModal`):
  - mancante → `🏥 Imposta scadenza certificato medico` (expired/rosso)
  - scaduto → `🏥 Cert. scaduto il {data}` (rosso)
  - scade entro 30 gg → `⏳ Cert. scade il {data}` (expiring/ambra)
  - valido → `✅ Cert. valido fino al {data}` (ok/verde)
- **Assicurazione** (`getShowAssic()`; click → `openAssicModal`): `📋 Imposta scadenza assicurazione` / `📋 Assic. scaduta il {data}` / `⏳ Assic. scade il {data}` / `📋 Assic. valida fino al {data}`.
- **Anagrafica** (`getShowAnag()` E anagrafica incompleta): `📋 Completa anagrafica` (stile expiring; click → `openEditClientPopup`).
- **Documento** (`getShowDoc()`; click → `openEditClientPopup`): `✅ Documento firmato` (ok) oppure `📝 Documento non firmato` (expired).
Le 4 visibilità arrivano da `BookingBadgesStorage` (chiavi localStorage `gym_show_cert_badge`, `gym_show_assic_badge`, `gym_show_doc_badge`, `gym_show_anag_badge`; default **true**; sincronizzate org-wide via `_upsertSetting`).

**Riga stats `.client-stats-block.cv2-stats-grid`** (cliccabile, toggla la card): grid 3 colonne, gap 0.5rem, padding `0.6rem 1.15rem 0.85rem`, bg `#fff`, border-top `1px solid #f1f5f9`; `.open` → bg `#f5f3ff`, border-top `#ede9fe`. Cella `.cv2-stat` centrata: valore `.v` 1rem/800 `#0f172a` line-height 1.15; label `.l` 0.62rem/700 `#94a3b8` uppercase ls 0.04em margin-top 2px. Colori modificatori: `.blue .v` `#8B5CF6`, `.red .v/.l` `#dc2626` (`.green` `#16a34a` e `.pink` `#be185d` definiti ma non usati qui). Mobile ≤480: padding 0.5rem 0.85rem 0.7rem, gap 0.35rem, v 0.92rem, l 0.58rem. Le 3 celle:
1. `.cv2-stat.blue` → valore = n. prenotazioni attive future (`!bookingHasPassed`), label **`Prenot. Future`**.
2. `.cv2-stat` `id="cv2-sessions-{index}"` → valore iniziale **`—`**, label **`Sessioni residue`** (popolato async da `_loadClientEconomy` = somma `remaining_sessions` dei pacchetti attivi; resta `—` se nessun pacchetto).
3. `.cv2-stat` (+`.red` se >0) → valore **`€{totalUnpaid}`** (arrotondato 2 decimali), label **`Da saldare`**. `totalUnpaid` = somma `getBookingPrice(b)` delle prenotazioni non cancellate, **passate** (`bookingHasPassed`), non pagate e non in `cancellation_requested`.

**Corpo `.client-card-body`**: `display:none` → `flex` (colonna, gap 1rem, padding `1.1rem 1.25rem`) con `.open`. Mobile: padding 0.75rem 0.9rem, gap 0.75rem. Contiene in ordine: switch segmentato, pannello Prenotazioni, pannello Storico, sezione Schede, sezione Situazione economica.

---

### 6.6 Switch segmentato Prenotazioni ⇄ Storico

`.cv2-segmented` (`role="tablist"`): flex, gap 4px, bg `#eef2f6`, radius **11px**, padding 4px. Due bottoni `.cv2-seg-btn` (`role="tab"`, `data-seg`, `aria-selected`): flex 1, padding `0.55rem 0.4rem`, radius 8px, 0.8rem/800, `#64748b`, bg transparent, nowrap; `.active`: bg `#fff`, color **`#7C3AED`**, shadow `0 1px 4px rgba(15,23,42,0.10)`. Testi ESATTI:
- **`Prenotazioni · {bTotal}`** (`data-seg="pren"`, attivo di default)
- **`Storico · {storicoCount}`** (`data-seg="storico"`)

`switchClientSeg(index, seg)` aggiorna `.active`/`aria-selected` e mostra un solo `.cv2-seg-panel` (`[hidden] { display:none }`). **La vista Storico = incassi**: mostra i movimenti di pagamento (v. 6.8), NON le prenotazioni. Stati vuoti `.cv2-seg-empty` (centrato, `#94a3b8`, 0.85rem/600, padding 1.25rem 0.5rem): **`Nessuna prenotazione`** / **`Nessun incasso registrato`**.

---

### 6.7 Pannello Prenotazioni — righe `.book-row`

Lista `.client-bookings-list` `id="brows-{index}"` (colonna, gap 4px). Ogni prenotazione del cliente (tutte, incluse cancellate) → riga `div#brow-{bookingId}` con classi `book-row pag-item` + opzionali `future-booking` (se NON passata), `row-cancel-pending` (status `cancellation_requested`), `row-cancelled` (status `cancelled`). `title="{Nome tipo} · {DD/MM/YYYY} · {HH:MM - HH:MM}"`.

**Layout riga**: flex, `align-items:stretch`, gap 10px, padding `0.5rem 0.6rem`, radius 9px, hover bg `#f6f8fa`.
- **Righe future ROSSE**: `.book-row.future-booking:not(.row-cancelled)` → bg **`#fef2f2`**, hover **`#fee2e2`** (le passate restano bianche).
- **Barra colorata org-aware** `.book-row-bar`: `<span>` largo **3px**, radius 3px, `background` inline = `getSlotColor(b.slotType)` (`data.js`): preferisce **`slot_types.color` per-org** (`_ORG_SLOT_TYPES`, idratato da `loadOrgScheduleConfig`/cache localStorage), fallback legacy `personal-training #16a34a`, `small-group #f59e0b`, `group-class #ef4444`, `cleaning #64748b`, default `#8B5CF6`; prenotazione **cancellata → `#e5e7eb`**; se `getSlotColor` non definita → `#cbd5e1` (che è anche il bg di default CSS della barra).
- **Main** `.book-row-main` (flex 1, colonna, gap 2px):
  - `.book-row-type`: nome tipo lezione `SLOT_NAMES[b.slotType]` — 0.85rem/800 `#0f172a`, `overflow-wrap:anywhere`. Cancellata → line-through `#b0b6bf`; pending annullamento → `#92400e`.
  - `.book-row-when`: **`{DD/MM} · {HH:MM - HH:MM}`** — 0.72rem/600 `#94a3b8`.
- **Side** `.book-row-side` (colonna allineata a destra, gap 6px, max-width 46%): pill stato pagamento + azioni.

**Chip/pill saldo `.payment-status`** (inline-block, 0.75rem/700, padding `0.2rem 0.6rem`, radius 20px, ls 0.02em; nella riga: `margin-top:0`, `white-space:normal`, `text-align:right`). **Tutti gli stati, testi e colori esatti**:
1. Annullata → `<span class="payment-status" style="background:#f3f4f6;color:#6b7280">✕ Annullata</span>`
2. Annullamento richiesto → `style="background:#fef3c7;color:#92400e"` → **`⏳ Annullamento`**
3. Gratuita (pagata con metodo `gratuito`/`lezione-gratuita`) → `style="background:#f3f4f6;color:#6b7280"` → **`🎁 Gratuita`**
4. Pagata → classe `.paid` (color `var(--success)` = `#06d6a0`, bg `rgba(34,197,94,0.1)`) → **`✓ Pagato`** oppure **`✓ Pagato con {metodo}`** dove metodo (mappa `_methodShort`): `contanti→Contanti`, `contanti-report→Contanti (report)`, `carta→Carta`, `iban→Bonifico`, `stripe→Stripe`, `gratuito|lezione-gratuita→Gratuita`.
5. Non pagata → classe `.unpaid` (color `#d97706`, bg `rgba(245,158,11,0.1)`, cursor pointer, hover bg `rgba(245,158,11,0.2)`) → **`Non pagato`**.
Gli stati 3 e 1 sono i **2 stati "no-credito"** grigi (bg `#f3f4f6` / color `#6b7280`) introdotti col redesign: nessun riferimento a crediti/bonus (modello rimosso, §11 CLAUDE.md).

**Azioni riga** `.book-row-actions` (flex, gap 5px; nel contesto book-row i bottoni sono 28×28px radius 7px, base `.btn-row-edit/.btn-row-delete`: bg none, border `1px solid #e5e7eb`, inline-flex centrato):
- **Matita** (SVG stroke 15×15, `currentColor`; solo se NON cancellata; color `#f59e0b`, hover border `#f59e0b` bg `rgba(245,158,11,0.06)`) → `openBookingEditPopup(bookingId, index)` (popup modifica/incasso, v. 6.10).
- **Cestino** (SVG trash 15×15; color `#94a3b8`, hover border+color `#ef4444` bg `rgba(239,68,68,0.06)`, sempre presente) → `deleteBookingFromClients(bookingId, nome)`: `showConfirm` **`Eliminare la prenotazione di {nome}?\n\nQuesta operazione non può essere annullata.`** → RPC **`admin_delete_booking(p_booking_id: b._sbId)`** → `BookingStorage.invalidateDelta()` (hard-delete: forza FULL al prossimo sync) + `syncFromSupabase()` + `invalidateStatsCache()` + toast **`Prenotazione eliminata.`** + `_refreshOpenClientCard(whatsapp, email)` (ricostruisce SOLO la card aperta in-place, stessa posizione DOM; fallback `renderClientsTab()`). Errori: toast `Errore durante l'eliminazione: {msg}` / `Errore imprevisto. Riprova.`. Le **note** della prenotazione non sono mostrate nella riga (niente emoji-note: la riga espone solo tipo, data/ora, stato, azioni).

**Paginazione interna righe** (`_showMoreItems`): le righe oltre la **5ª** nascono con `style="display:none"`; se `bTotal > 5` compare `<button class="show-more-btn" onclick="_showMoreItems(this,10)" data-container="brows-{i}" data-shown="5" data-total="{bTotal}" data-reveal-on-done="fullhist-btn-{i}" style="margin-top:0.5rem;">` con testo **`▼ Mostra altri {min(10, bTotal-5)}`**; ogni click rivela 10 `.pag-item` e aggiorna il testo `▼ Mostra altri {min(10, restanti)}`; a esaurimento il bottone si rimuove e rivela l'elemento `data-reveal-on-done`.

**Storico completo on-demand**: bottone `#fullhist-btn-{i}` `.show-more-btn` testo **`📜 Carica storico completo`** (nascosto finché la paginazione non è esaurita quando `bTotal > 5`; la cache bookings è finestrata a 60gg passati → le prenotazioni pagate più vecchie mancano). Click → `loadClientFullHistory(btn, index)`: bottone `disabled` + testo **`⏳ Caricamento…`**; chiama **`BookingStorage.fetchClientHistory({ userId, email, whatsapp })`** (query mirata su `bookings` con `.or('user_id.eq.X,email.eq."…",whatsapp.eq."…"')` — valori quotati/escapati per PostgREST —, paginata via `fetchAllPaginated`, order date desc + id, timeout 15s, ritorna righe `_mapRow` o null; NON tocca la cache globale); merge dedup per `_sbId||id` con la **cache live che vince** (evita flash "Non pagato" su lezione appena saldata); sort desc; `client._fullHistoryLoaded = true`; ricostruisce la card preservando `.open`. Dopo il load, al posto del bottone: `<div class="client-fullhist-note" style="margin-top:0.5rem;font-size:0.8rem;color:#16a34a;">✓ Storico completo caricato</div>`. Errori: toast **`Impossibile caricare lo storico completo`** / **`Errore caricamento storico`** (ripristina il bottone).

---

### 6.8 Pannello Storico (= incassi)

Movimenti `_movs` = prenotazioni del cliente `status !== 'cancelled' && paid`, mappate a `{ sortKey: paidAt || date+'T00:00:00', dateShort DD/MM, time, label: SLOT_NAMES[slotType] || 'Lezione', method: _methodShort, free, price: free?0:getBookingPrice(b) }`, ordinate per `sortKey` discendente. Contenitore `.client-credit-history` (colonna, gap 4px).

Riga `.tx-row` (+`.tx-plus` o `.tx-free`): stesso layout di book-row (flex stretch, gap 10px, padding 0.5rem 0.6rem, radius 9px, hover `#f6f8fa`).
- Barra `.tx-row-bar` 3px radius 3px: default `#e5e7eb`; `.tx-plus` → **`#22c55e`**; `.tx-free` → `#cbd5e1` (`.tx-minus` → `#ef4444` definito ma non generato qui).
- `.tx-row-label` (0.83rem/800 `#0f172a`, nowrap ellipsis, flex gap 0.35rem): icona `.tx-row-ic` **`💰`** (incasso) o **`🎁`** (gratuita) + `{label}` + eventuale ` · {metodo}`.
- `.tx-row-when`: `{DD/MM} · {orario}` — 0.72rem/600 `#94a3b8` nowrap.
- `.tx-row-side` → importo `.tx-row-amount` (0.9rem/800, tabular-nums): `.plus` color **`#15803d`** testo **`+€{prezzo}`**; `.free` color `#9ca3af` testo **`€0`**.

Sezione titolo assente (il pannello è diretto). Vuoto: `Nessun incasso registrato`.

---

### 6.9 Sezione "Schede assegnate"

Visibile solo se `WorkoutPlanStorage.getPlansByUser(clientUserId)` non è vuoto (`clientUserId = userRecord?.id || client.userId`). `.client-schede-section` (border-top `1px solid #f3f4f6`, padding-top 0.75rem, margin-bottom 0.5rem), `<h4>📋 Schede assegnate</h4>` (0.97rem/700 `#0369a1`).

Riga piano `.client-scheda-row` (flex space-between, padding 0.5rem 0.6rem, radius 8px, **bg `#f0f9ff`**, margin-bottom 0.35rem, gap 0.5rem):
- `.client-scheda-name` (0.9rem/600 `#1e293b`): nome piano + badge inline `<span class="schede-badge-active|schede-badge-inactive" style="font-size:0.7rem;padding:1px 6px;margin-left:6px;">` con testo **`Attiva`** / **`Inattiva`**.
- `.client-scheda-meta` (0.78rem `#94a3b8`): **`{n} esercizi · {m} giorno/i`** (singolare `giorno` se m=1; giorni = `day_label` distinti di `workout_exercises`).
- Azioni `.client-scheda-actions` (bottoni bg `#e0f2fe`, border `1px solid #bae6fd`, radius 6px, 0.95rem, padding 5px 10px, hover bg `#bae6fd`):
  - `📋` title "Salva come template" → `clientSaveAsTemplate(planId, planName)`: `showPrompt('Nome del template', planName)` → `WorkoutPlanStorage.duplicatePlan(planId, null, tplName)`; toast **`Template creato!`** / **`Errore creazione template`**.
  - `✏️` title "Modifica scheda" → `clientGoToEditScheda(planId)`: `switchTab('schede')` + `_schedeEditPlan(planId)`.
  - `🗑️` title "Rimuovi scheda" → `clientDeleteScheda`: `showConfirm(`Eliminare la scheda "{nome}" e tutti gli esercizi associati?`)` → `WorkoutPlanStorage.deletePlan(planId)`; toast **`Scheda eliminata`** / **`Errore eliminazione scheda`**; poi `renderClientsTab()`.

---

### 6.10 Sezione "Situazione economica" (billing-cliente, SOLA LETTURA)

`.client-credit-section` `id="client-economy-{index}"` (border-top `1px solid #f3f4f6`, padding-top 0.75rem), `<h4>📊 Situazione economica</h4>` (0.97rem/700 `#0369a1`) + `<div class="client-economy-body">` con placeholder **`Caricamento…`**. ⚠️ Le classi `.client-economy-*` NON hanno CSS dedicato in `admin.css` (stile ereditato + inline `<small style="opacity:0.7">`): in Flutter va ricreato un layout riga icona+label+valore.

**`_loadClientEconomy(index, userId, email)`** (async, lanciata da `createClientCard`): 3 query parallele con `_rpcWithTimeout` (timeout default 12s), RLS org-scoped:
1. `supabaseClient.from('client_packages').select('label, total_sessions, remaining_sessions, expires_at, status, purchased_at').eq('user_id', userId).eq('status', 'active').order('purchased_at', { ascending: false })` — solo se `userId` presente.
2. `supabaseClient.from('client_memberships').select('plan_label, period_start, period_end, lessons_quota, lessons_used, status').eq('user_id', userId).eq('status', 'active').order('period_end', { ascending: false })` — solo se `userId`.
3. `supabaseClient.from('payments').select('amount, client_email, client_user_id')` filtrata `.eq('client_user_id', userId)` se c'è userId, altrimenti `.eq('client_email', emailLowercase)`; se mancano entrambi la query non parte.

Rendering (`fmtDate` = `DD/MM/YYYY`):
- **Pacchetti**: per ognuno riga `🎟️ {label|'Pacchetto'}` + small **`scade {data}`** o **`senza scadenza`** + valore **`{remaining}/{total} sessioni`**. Nessuno → riga empty `🎟️ Nessun pacchetto attivo`.
- **Abbonamenti**: riga `📅 {plan_label|'Abbonamento'}` + small **`fino al {period_end}`** + valore **`{lessons_used}/{lessons_quota} lezioni`** oppure **`illimitato`** (quota null). Nessuno → `📅 Nessun abbonamento attivo`.
- **Totale**: riga `client-economy-total` `💰 Totale incassato` → **`€{somma amount}`** (arrotondata a 2 decimali).
- Aggiorna la stat header **Sessioni residue** = somma `remaining_sessions` (o `—` senza pacchetti).

Stati: offline (`supabaseClient` undefined) → **`Dati economici non disponibili offline.`**; eccezione → **`Errore nel caricamento dei dati economici.`**. I modelli billing (`pay_per_session`/`monthly`/`package`/`free` di `billing_settings`/`client_billing_profiles`) NON si modificano da qui: le azioni economiche (vendita pacchetto `admin_sell_package`, incasso mensile `admin_record_membership_payment`, saldo lezioni `admin_pay_bookings`) vivono nel tab Pagamenti; questa sezione è solo display.

---

### 6.11 Popup "Modifica contatto" (`openEditClientPopup`)

Ricerca del cliente per email/whatsapp normalizzati (non per indice, che cambia coi filtri). Overlay dinamico `#editClientPopupOverlay` `.edit-client-popup-overlay`: fixed inset 0, bg `rgba(0,0,0,0.45)`, **z-index 9999**, flex centrato, padding 1rem, fade opacity .2s (classe `.open` dopo 10ms). Box `.edit-client-popup`: bg `#fff`, radius **14px**, width 100% max-width **480px**, max-height 90vh scroll, shadow `0 12px 40px rgba(0,0,0,0.18)`, translateY(20px)→0.

- **Header** (padding 1rem 1.2rem, border-bottom `#e5e7eb`): `<h3>Modifica contatto</h3>` (1.1rem) + close `&times;` (1.5rem `#999`→`#333`).
- **Body** (padding 1rem 1.2rem, colonna gap 1rem), sezioni `.edit-client-popup-section` con `<h4>` uppercase 0.8rem `#999` ls 0.05em; label colonna 0.83rem/600 `#666`; input padding 0.5rem 0.75rem, border `1px solid #d1d5db`, radius 8px, **font-size 16px** (anti-zoom iOS), focus border `var(--primary-purple)`:
  1. **`Dati personali`**: `Nome` (text), `WhatsApp` (tel), `Email` (email) — precompilati.
  2. **`Dati fiscali`**: `Codice Fiscale` (text, `maxlength="16"`, `text-transform:uppercase`).
  3. **`Indirizzo di residenza`**: `Via/Indirizzo`; riga flex (`.edit-client-popup-row`, gap 0.65rem): `Comune` (flex 2) + `CAP` (flex 1, `maxlength="5"`).
  4. **`Documenti`**: riga `Cert. Medico` (date) + `Assicurazione` (date); due **toggle iOS** `.cedit-toggle-row` con label **`Documento firmato`** e **`Abilita Stripe`** — switch `.cedit-toggle-switch` 44×24px, slider `#d1d5db` → `var(--primary-purple)` checked, knob bianco 18px (left/bottom 3px) traslato 20px, focus-visible outline viola.
- **Azioni** (`.edit-client-popup-actions`, wrap gap 0.5rem, padding 0.8rem 1.2rem, border-top; ogni bottone `flex:1 1 calc(50% - 0.25rem)`):
  - **`🗑️ Elimina`** `.btn-delete-client` (bg `#fff`, color `#ef4444`, border `#fecaca`, radius 6px; hover bg `#fef2f2` border `#ef4444`) → `deleteClientData` (v. 6.13).
  - **`Annulla`** `.btn-cancel-edit` (bg `#f3f4f6`, `#555`, border `#e5e7eb`).
  - **`Salva`** `.btn-save-edit` (bg `var(--success)` `#06d6a0`, bianco, 0.9rem/600).
Click sull'overlay NON chiude (solo `stopPropagation`); chiusura via `closeEditClientPopup()` (rimuove `.open`, remove dopo 200ms).

**Flusso `saveClientEdit(index, oldWhatsapp, oldEmail)`**:
1. Nome → **Title Case automatico** (ogni parola: iniziale maiuscola, resto minuscolo). Vuoto → `showAlert('Il nome è obbligatorio.', {type:'warn'})`.
2. Comune → `normalizeComune()` (auth.js: apostrofi curvi→dritti, title-case con connettivi `di/da/del/...` minuscoli se non a inizio).
3. **Gating piano SaaS** (solo se il contatto NON matcha un profilo esistente = creazione): `Entitlements.atClientLimit()` → toast **`⚠️ Hai raggiunto il limite di clienti del tuo piano ({cur}/{max}). Passa a un piano superiore dalle Impostazioni → Billing SaaS.`** (error, 6000ms) e stop. Fail-open se `Entitlements` non definito; il server rifà comunque il check.
4. Bottone Salva → disabled + testo **`Salvataggio...`**.
5. **Fase 1 — RPC atomica** `admin_rename_client({ p_old_email, p_old_whatsapp, p_new_name, p_new_email, p_new_whatsapp })` (rinomina profilo + bookings server-side, org-scoped, SECURITY DEFINER). Errori: messaggio contiene `client_limit_reached` → toast **`⚠️ Hai raggiunto il limite di clienti del tuo piano. Passa a un piano superiore dalle Impostazioni → Billing SaaS.`**; altro errore → `showAlert("Errore durante l'aggiornamento: {msg}")`; `data.success === false` → **`Aggiornamento rifiutato dal server. Riprova.`**; timeout (`rpc_timeout`) → **`Timeout durante l'aggiornamento. Verifica la connessione e riprova.`**; eccezione → **`Errore di rete. Riprova.`**.
6. **Fase 2 — best effort**: `BookingStorage.syncFromSupabase()` + `_saveClientEditLocalProfile(...)`: aggiorna/crea il record in `UserStorage._cache` (nome, whatsapp normalizzato, email; se cert/assic cambiati appende a `certificatoMedicoHistory`/`assicurazioneHistory` `{scadenza, aggiornatoIl}`; CF/via/paese/cap/documentoFirmato/stripeEnabled), `_saveUsers` (ri-persiste lo snapshot), poi **`_updateSupabaseProfile(oldEmail, normOld, fields)`** = `UPDATE profiles SET …` matchando sui VECCHI identificatori, con mapping campi: `name`, `email`, `whatsapp`, `medical_cert_expiry`, `insurance_expiry`, `codice_fiscale`, `indirizzo_via`, `indirizzo_paese`, `indirizzo_cap`, `documento_firmato` (⚠️ `stripeEnabled` resta SOLO locale, non è inviato). Errore profilo → toast **`⚠️ Profilo locale aggiornato, ma errore Supabase: {msg}`**. Aggiorna la sessione se il cliente editato è l'utente loggato. Poi `renderClientsTab()` + `renderAdminDayView(dataCorrente)` + (se ricerca attiva) ri-esegue la ricerca col nuovo nome e auto-seleziona. Successo → toast **`Contatto aggiornato.`**. Eccezione fase 2 → toast **`Nome aggiornato. Aggiornamento vista non riuscito — ricarica la pagina per vederlo dappertutto.`** (6000ms).
7. **Fallback offline** (no `supabaseClient`): rinomina in-place tutte le prenotazioni matchate in cache + `replaceAllBookings` + profilo locale.

---

### 6.12 Popup "Modifica prenotazione" / incasso (`openBookingEditPopup`)

Riusa overlay/box `.edit-client-popup-overlay`/`.edit-client-popup` (id `#bookingEditPopupOverlay`; qui il click sull'overlay CHIUDE). Header `<h3>Modifica prenotazione</h3>`. **Riga meta su una riga** `.bedit-popup-meta` (0.9rem `#475569`, padding `0.2rem 0 0.6rem`; strong `#0f172a`): **`{Nome tipo} · {DD/MM/YYYY} · {orario}`**. Campi (una sezione):
- `Stato pagamento` — select `#bedit-paid-{id}`: opzioni **`✓ Pagato`** (value `true`) / **`✗ Non pagato`** (value `false`).
- `Metodo` — select `#bedit-method-{id}`: opzione vuota **`—`** + **`💵 Contanti`** (`contanti`), **`🧾 Contanti con Report`** (`contanti-report`), **`💳 Carta`** (`carta`), **`🏦 Bonifico`** (`iban`), **`💳 Stripe`** (`stripe`), **`🎁 Gratuita`** (`gratuito`).
- `Data/ora pagamento` — `datetime-local` `#bedit-paidat-{id}` precompilato da `paidAt` (ISO → `YYYY-MM-DDTHH:MM`).
Azioni: **`Annulla`** / **`Salva`** (`saveBookingRowEdit(bookingId, clientIndex)`).

**Flusso `saveBookingRowEdit`** (anti doppio-click: disabilita Salva):
1. Se metodo ∈ {`carta`,`iban`,`stripe`,`contanti-report`} e pagato → `ensureClientDataForCardPayment(email, whatsapp, name, method)`: se mancano CF/via/comune/CAP apre il popup "**⚠️ Dati mancanti — {nome}**" (`#missingDataOverlay/#missingDataModal`, mostra solo i campi mancanti) con validazioni ESATTE: `Codice Fiscale non valido.` (regex `^[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]$`), `Il Codice Fiscale è obbligatorio.`, `La via è obbligatoria.`, `Il paese è obbligatorio.`, `CAP non valido (5 cifre).`; annulla → reject e il salvataggio si interrompe.
2. **Pagato** → RPC **`admin_pay_bookings({ p_booking_ids: [booking._sbId], p_method: metodo || 'contanti', p_paid_at: ISO scelto || now })`**.
3. **Non pagato** → RPC **`admin_update_booking({ p_booking_id, p_status: booking.status || 'confirmed', p_paid: false, p_payment_method: null, p_paid_at: null })`**.
4. Poi `BookingStorage.syncFromSupabase()`, `invalidateStatsCache()`, chiudi popup, `renderClientsTab()`. Errori: `showAlert('Errore: {msg}')` / **`Errore imprevisto. Riprova.`**. Fallback offline: muta `paid/paymentMethod/paidAt` in cache e `replaceAllBookings`.

**Cosa scrive `admin_pay_bookings` nel ledger `payments`** (baseline SQL, `returns integer` = n. prenotazioni saldate; `security definer`, richiede `is_org_admin`): per ogni booking della org non ancora pagato (lock `FOR UPDATE`): `UPDATE bookings SET paid=true, payment_method=p_method, paid_at=p_paid_at`; poi `INSERT INTO payments (org_id, client_user_id, client_email, amount, currency, method, kind, booking_id, created_by)` con `amount` = **0 se metodo `gratuito`**, altrimenti `coalesce(bookings.custom_price, get_org_price(org, slot_type))`; `currency` della org; `method` whitelisted (`contanti|contanti-report|carta|iban|stripe|gratuito`, altrimenti `contanti`); **`kind = 'session'`**; `created_by = auth.uid()`; **`ON CONFLICT (booking_id) WHERE kind='session' DO NOTHING`** (idempotente: un solo incasso per prenotazione).

---

### 6.13 Eliminazione cliente (`deleteClientData`)

Dal popup Modifica contatto, bottone `🗑️ Elimina`:
1. **Conferma digitata** (niente password hardcoded): `showPrompt` con messaggio **`Per eliminare TUTTI i dati di "{nome}", digita il nome del cliente (o ELIMINA):`** (senza nome: `Per eliminare TUTTI i dati del cliente, digita ELIMINA:`), bottone conferma **`Elimina`**. Valida: testo = `ELIMINA` (case-insensitive) oppure = nome cliente (case-insensitive). Non valida e non vuota → `showAlert('Conferma non valida. Eliminazione annullata.', {type:'warn'})`.
2. Secondo check: `showConfirm` **`Confermi l'eliminazione di TUTTI i dati di {nome}?\n\nPrenotazioni e dati associati verranno eliminati permanentemente.`**
3. Senza email né whatsapp → `showAlert('Cliente senza email né WhatsApp: impossibile eliminare i dati server-side.', {type:'error'})` e stop.
4. **Server-first**: RPC **`admin_delete_client_data({ p_email, p_whatsapp })`** (org-scoped; elimina le prenotazioni del cliente; `payments.booking_id` è `ON DELETE SET NULL` → il fatturato nel ledger resta). Errore RPC → `Errore lato server: {msg}\nNessun dato è stato rimosso.`; `success:false` → `Eliminazione rifiutata dal server ({motivo}). Nessun dato rimosso.`; timeout → `Timeout durante l'eliminazione. Nessun dato è stato rimosso — riprova.`; rete → `Errore di rete durante l'eliminazione. Nessun dato è stato rimosso — riprova.`
5. Successo → `BookingStorage.invalidateDelta()` + rimozione dalla cache locale delle prenotazioni matchate (email o telefono) via `replaceAllBookings` → toast **`Dati di {nome} eliminati ({N} prenotazioni rimosse).`** → `renderClientsTab()`.

---

### 6.14 Modali Certificato / Assicurazione (markup statico in admin.html)

Aperti dai badge della card (`openCertModal(badgeEl, email, whatsapp, name)` / `openAssicModal(...)` — definiti in `admin-analytics.js`; il badge cliccato viene aggiornato in-place al salvataggio). Overlay `.debt-popup-overlay` + box `.cert-modal`: fixed centrato (translate −50%), z-index 1001, bg `#fff`, radius **16px**, shadow `0 8px 40px rgba(0,0,0,0.18)`, width `min(360px, 92vw)`.
- Header `.debt-popup-header`: `<h3>🏥 Certificato Medico</h3>` / `<h3>📋 Assicurazione</h3>` + nome cliente (`#certModalName`/`#assicModalName`, 0.9rem `#6b7280`) + close SVG ✕.
- Body (padding `1.25rem 1.5rem 1.5rem`): label **`Data di scadenza`** + `<input type="date">` `.cert-modal-date-input` (border `1.5px #e5e7eb`, radius 8px, padding 0.6rem 0.75rem, 0.95rem, bg `#f9fafb`; focus border **`#ef4444`** bg `#fff`) + azioni `.cert-modal-actions` (flex gap 0.6rem): **`Annulla`** (`.cert-modal-btn--cancel` bg `#f3f4f6` `#374151`) e **`Salva`** (`.cert-modal-btn--save` bg **`#ef4444`** bianco), radius 8px, 0.9rem/600.
- `saveCertDate()` / `saveAssicDate()`: aggiorna cache utenti (+history), `_updateSupabaseProfile(email, whatsapp, { medical_cert_expiry: val||null })` / `{ insurance_expiry: val||null }`, aggiorna sessione se cliente loggato, aggiorna il badge sorgente in-place, toast **`Certificato medico aggiornato.`** / **`Assicurazione aggiornata.`**.

---

### 6.15 Logica dati: Storage, RPC, cache, realtime, egress

**Funzioni JS principali del tab** (nomi esatti): `getAllClients`, `getActiveClients`, `renderClientsSummary`, `renderClientsTab`, `_appendClientBatch`, `createClientCard`, `toggleClientCard`, `switchClientSeg`, `_showMoreItems`, `loadClientFullHistory`, `_loadClientEconomy`, `liveSearchClients`, `selectClientFromDropdown`, `showSingleClientCard`, `openClientCardByName`, `clearClientsSearch`, `closeClientsSearchDropdown`, `toggleClientsTotalList/ActiveList`, `_updateClientsHints`, `refreshClients`, `_refreshOpenClientCard`, `toggleCert/Assic/Anag/Privacy/PushFilter`, `_clearOtherFilters`, `_syncFilterButtons`, `toggleClientsFiltersMenu`, `_activeFilterLabel`, `clientHas*`, `_ageFromCF`, `openEditClientPopup/closeEditClientPopup/saveClientEdit/_saveClientEditLocalProfile`, `deleteClientData`, `openBookingEditPopup/closeBookingEditPopup/saveBookingRowEdit`, `deleteBookingFromClients`, `clientGoToEditScheda/clientSaveAsTemplate/clientDeleteScheda`.

**RPC/tabelle Supabase usate** (parametri esatti):
- `admin_rename_client(p_old_email text, p_old_whatsapp text, p_new_name text, p_new_email text, p_new_whatsapp text) → jsonb`
- `admin_delete_client_data(p_email text, p_whatsapp text) → jsonb`
- `admin_delete_booking(p_booking_id uuid) → void`
- `admin_pay_bookings(p_booking_ids uuid[], p_method text, p_paid_at timestamptz default now()) → integer` (ledger: v. 6.12)
- `admin_update_booking(p_booking_id uuid, p_status text, p_paid boolean, p_payment_method text, p_paid_at timestamptz, …altri default)`
- SELECT diretti (RLS org): `client_packages`, `client_memberships`, `payments` (v. 6.10); `bookings` via `BookingStorage.fetchClientHistory`.
- Profili: `get_all_profiles_basic()` con fallback `get_all_profiles()` (via `UserStorage.syncUsersFromSupabase`); `UPDATE profiles` diretto via `_updateSupabaseProfile`.
- Tutte le RPC wrappate in **`_rpcWithTimeout(promise, ms=12000)`** → rigetta `Error('rpc_timeout')`.

**Cache & snapshot localStorage (chiavi esatte, TTL, invalidazione)**:
- **BookingStorage** (`data.js`): cache in-RAM `_cache` (fonte di `getAllBookings()`); persistita cross-pagina in **`gym_bookings_cache_v2:{all|own}:{admin|userId}`** — payload `{savedAt, clearedAt, fingerprint, lastFull, rows}` (solo righe reali con `_sbId`, max **8000**, TTL idratazione **15 min**). Sync admin: finestra **−60/+90 giorni** + TUTTE le lezioni passate non pagate non annullate (debiti vecchi); fingerprint `"{count}|{maxUpdatedAt}"` → **skip** se invariato, **DELTA** (`updated_at >= cursore−5s`) se count non sceso, **FULL** altrimenti; reconcile ogni **5 min**; paginazione 1000 righe. `invalidateDelta()` (dopo hard-delete) azzera fingerprint e purga gli snapshot (`gym_bookings_cache_v2:*`, `gym_stats_cache_v1:*`, `gym_users_cache_v1`). `forceFull:true` salta skip/delta. Chiave di clear globale: `dataLastCleared`.
- **UserStorage**: cache `_cache` dei profili org; snapshot cross-pagina **`gym_users_cache_v1`** `{cache, fp, savedAt, clearedAt, org}` — org-scoped (scartato se `window._orgId` diverso), max **24h**, fingerprint-skip con reconcile **5 min** (`get_all_profiles_basic`); merge: anagrafica Supabase autoritativa, cert/assic locali prioritari, utenti solo-locali preservati. Mapping campi row→cache: `medical_cert_expiry→certificatoMedicoScadenza`, `insurance_expiry→assicurazioneScadenza`, `codice_fiscale→codiceFiscale`, `indirizzo_via/paese/cap`, `documento_firmato`, `privacy_prenotazioni`, `push_enabled`, `stripe_enabled`, `id→userId`.
- **WorkoutPlanStorage**: chiavi `workout_plans_cache_admin_v1`/`_client_v1`, TTL localStorage 30 min, TTL rete 5 min.
- **BookingBadgesStorage**: `gym_show_cert_badge`, `gym_show_assic_badge`, `gym_show_doc_badge`, `gym_show_anag_badge` (default true, sync org via `_upsertSetting`).
- Helper anagrafici (`admin-analytics.js`): `_getUsersFull()` = `UserStorage._cache`; `_saveUsers()` ri-persiste lo snapshot; `_getUserRecord(email, whatsapp)` via `_findUserIdx` (prima email lowercase, poi telefono `normalizePhone`).

**Boot & realtime** (`admin.html` inline): al boot sync **in serie** `UserStorage.syncUsersFromSupabase()` → `BookingStorage.syncFromSupabase()` → `syncAppSettingsFromSupabase()`, poi `switchTab(tabAttiva)`; `switchTab('clients')` → `renderClientsTab()` via `setTimeout 0` (`admin.js` loader map). Realtime Supabase: handler unico **debounced 1500ms** che risincronizza Users+Bookings+Settings in parallelo e, se la tab attiva è `clients`, richiama `renderClientsTab()`; stesso giro su resume/visibilitychange (`_adminRefreshAfterResume`). Ottimizzazioni egress chiave da replicare: fingerprint-skip, delta-sync, snapshot cross-pagina, storico per-cliente on-demand (`fetchClientHistory`), dedup ricerca debounced.

---

### 6.16 Popup "Nuovo cliente iscritto" (`js/new-client-popup.js`)

Collegato alla gestione clienti (solo **admin** + solo **mobile/PWA**: standalone `display-mode: standalone`/`navigator.standalone` oppure viewport ≤768px; su desktop non compare). 100% client-side:
- **Fonte**: `UserStorage._cache` (profili `_fromSupabase`) con anagrafica **completa** (`userId` + whatsapp + codiceFiscale + indirizzoVia + indirizzoPaese + indirizzoCap).
- **Chiavi localStorage namespaced per org**: `palestria_newClientSeen_{orgId}` (array userId già visti) e `palestria_newClientBaseline_{orgId}` (`'1'` dopo la semina). Primo avvio: semina tutti i completi come visti (nessun popup per la base esistente). Ricontrollo a ogni ritorno in primo piano (`visibilitychange` → `syncUsersFromSupabase()` cheap + `decide()`).
- **UI** (overlay `.ncp-overlay` z-index 3000, bg `rgba(0,0,0,0.55)` blur 2px; box `.ncp-box` max-width 420px radius 18px): icona persona+ in cerchio viola (`rgba(139,92,246,0.12)`/`#8B5CF6`), titolo **`Nuovo cliente iscritto`** (1 cliente) o **`{n} nuovi clienti iscritti`**, sottotitolo **`Aggiungilo alla rubrica`** / **`Hai <b>{n}</b> nuovi clienti da aggiungere`**. Per cliente `.ncp-item` (bg `#fafbfc`, border `#eceff1`, radius 14px): nome (1.05rem/800), telefono, bottone info `ⓘ` che espande pannello `.ncp-info` con righe **`👤 {Uomo|Donna}`**, **`🎂 {età} anni`** (da `parseCF`), **`📍 {comune}`** — oppure **`Dati non disponibili`**; due bottoni: **`WhatsApp`** (`.ncp-btn--wa` bg `#25d366`, href `https://wa.me/{cifre}`) e **`Telefono`** (`.ncp-btn--tel` bg `#8B5CF6` hover `#7C3AED`, href `tel:{+ e cifre}`). Chiusura (✕ o backdrop) marca i mostrati come visti. API debug: `window.NewClientPopup.refresh()`.

---

### 6.17 Stati vuoti/errore/loading e gating ruoli — riepilogo testi esatti

| Contesto | Testo esatto |
|---|---|
| Lista filtrata vuota | `Nessun cliente trovato` |
| Dropdown ricerca senza match | `Nessun risultato` |
| Pannello Prenotazioni vuoto | `Nessuna prenotazione` |
| Pannello Storico vuoto | `Nessun incasso registrato` |
| Economia in caricamento | `Caricamento…` |
| Economia offline | `Dati economici non disponibili offline.` |
| Economia in errore | `Errore nel caricamento dei dati economici.` |
| Nessun pacchetto / abbonamento | `Nessun pacchetto attivo` / `Nessun abbonamento attivo` |
| Storico completo: loading / ok / errori | `⏳ Caricamento…` / `✓ Storico completo caricato` / `Impossibile caricare lo storico completo`, `Errore caricamento storico` |
| Ricarica clienti in corso / errore | `↻ Caricamento...` / `⚠️ Errore ricarica clienti. Riprova.` |
| Sync fallita 3 volte consecutive | `Errore di connessione al server. Verifica la tua connessione.` |
| Salvataggio contatto in corso | `Salvataggio...` |

**Gating ruoli**: l'intera tab vive in `admin.html`, accessibile solo con `sessionStorage.adminAuth === 'true'` (impostato da `auth.js` se `app_metadata.org_role` ∈ {owner, admin}); l'autorità resta server-side (RLS org-scoped su `bookings`/`profiles`/`payments`/`client_packages`/`client_memberships` + `is_org_admin()` dentro ogni RPC `admin_*`). Limite clienti per piano: client-side `Entitlements.atClientLimit()` (`maxClients` null = illimitato; fail-closed su feature, fail-open sul limite se modulo assente) + enforcement server `org_at_client_limit` → eccezione `client_limit_reached`. Nessuna distinzione owner/admin/staff dentro la tab: chi passa il gate admin vede tutto.

---

# Specifica migrazione Flutter — PalestrIA area admin
# Sezioni: Pagamenti (billing-cliente) e Statistiche & Fatturato (Analytics)

Fonti analizzate (repo `C:\Users\andrea\VM-Nextcloud\Vibe Coding\PalestrIA`):
`js/admin-payments.js` (856 righe), `js/admin-analytics.js` (2465 righe), `js/chart-mini.js` (445 righe),
`admin.html` (pannelli `tab-payments`/`tab-analytics` + modali), `css/admin.css`, `js/data.js`,
`supabase/migrations/00000000000000_baseline.sql` (schema + RPC), `js/admin.js` (switchTab, privacy mask).

---

## 7. Tab Pagamenti e billing-cliente

### 7.1 Ingresso nel tab e ciclo di render

- Bottone tab: `<button class="admin-tab" data-tab="payments">💳 Pagamenti</button>`.
- Allo switch (`switchTab` in `js/admin.js`): mostra `#tab-payments`, mostra il **FAB** `#paymentsFab` (solo in questo tab: `fab.style.display = tabName === 'payments' ? 'flex' : 'none'`) e chiama `renderPaymentsTab('switchTab')`.
- `renderPaymentsTab(_diagSource)` (in `admin-payments.js`) è a **due fasi**:
  1. **Render sincrono** immediato dai dati locali (`_paintPaymentsTab({ preserveUiState: false })`) — il tab è usabile subito;
  2. **Fetch in background** dal ledger `payments` (se `supabaseClient` definito), poi ri-paint con `{ preserveUiState: true }` (non richiude le liste aperte). Tre query in `Promise.all` (tutte con `_rpcWithTimeout(..., 15000)`):
     - (a) lista UI: `from('payments').select('id, created_at, client_email, amount, currency, method, kind, note, period_start, period_end').order('created_at', {ascending:false}).limit(50)` → cache `_recentPayments`;
     - (b) KPI conteggio mese: `from('payments').select('id', { count:'exact', head:true }).gte('created_at', monthStartIso)` → `_monthCount`;
     - (c) KPI somma mese: `from('payments').select('amount').gte('created_at', monthStartIso)` → `_monthRevenue = Σ Number(p.amount)`.
     `monthStartIso = new Date(anno, meseCorrente, 1).toISOString()`. I KPI del mese sono **aggregati server-side sull'intero mese**, mai derivati dalla lista cappata a 50 (sottostimerebbe).
- **Anti-stale**: contatore `_paymentsReqCounter`; se al ritorno del fetch `reqId !== _paymentsReqCounter` la risposta viene scartata (tab switch rapidi).
- Finché `_monthRevenue`/`_monthCount` sono `null` le card mostrano **"—"** (mai 0 fuorviante). Se il fetch fallisce restano i valori precedenti/`—` (warn in console, nessun toast).
- **Niente realtime** su questo tab: il refresh avviene a ogni ingresso nel tab, dopo ogni mutazione (saldo/vendita) e tramite `BookingStorage.syncFromSupabase()`.

### 7.2 Layout del pannello (`#tab-payments` in admin.html)

Struttura esatta:

```html
<div class="tab-page-title">
    <h2>Pagamenti</h2>
    <span>Da incassare</span>
</div>
<div class="stats-grid stats-grid--payments">
    <div class="stat-card stat-card--clickable" id="statcard-debtors" onclick="toggleDebtorsList()" title="Clicca per vedere la lista">
        <div class="stat-card-click-hint" id="debtorsToggleHint">Dettagli ▼</div>
        <div class="stat-icon">💰</div>
        <h3>Da Incassare</h3>
        <p class="stat-value" id="totalUnpaid">€0</p>
    </div>
    <div class="stat-card stat-card--clickable" id="statcard-creditors" onclick="toggleCreditsList()" title="Clicca per i pagamenti recenti">
        <div class="stat-card-click-hint" id="creditorsToggleHint">Dettagli ▼</div>
        <div class="stat-icon">💳</div>
        <h3>Incassato questo mese</h3>
        <p class="stat-value" id="totalCreditAmount">€0</p>
    </div>
</div>
<div id="debtorsList" class="debtors-list"></div>
<div id="creditsList" class="debtors-list credits-list" style="display:none;"></div>
```

- Titolo pagina (`.tab-page-title`): `h2` 1.65rem/800/`#0f172a` letter-spacing -0.02em; `span` sotto 0.8rem/`#94a3b8`/500.
- Grid: `.stats-grid` = `grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap:1rem; margin-bottom:2.5rem`.
- Valori impostati dal paint (via `sensitiveSet`, §7.13):
  - `totalUnpaid` = `€` + somma arrotondata 2 decimali del "da incassare" (§7.3);
  - `totalCreditAmount` = `€{_monthRevenue}` (o `—`);
  - `sensitiveSet('totalDebtors', …)` e `sensitiveSet('totalCreditors', …)` vengono chiamate ma **gli ID non esistono più in admin.html** → no-op (retaggio; in Flutter si possono ignorare o esporre come conteggio debitori / n. pagamenti mese).
- **Stat card CSS** (esatti): `.stat-card` = sfondo `#fff`, padding `1.4rem 1.35rem 1.2rem`, radius 16px, bordo `1px solid rgba(0,0,0,0.06)`, ombra `0 1px 3px rgba(0,0,0,0.03), 0 4px 14px rgba(0,0,0,0.04)`; barra accento top 3px via `::after`:
  - `#statcard-debtors::after`: `linear-gradient(90deg, #ef4444, #f87171)` (rosso);
  - `#statcard-creditors::after`: `linear-gradient(90deg, #22c55e, #4ade80)` (verde).
  - Icona `.stat-icon`: 2.85rem × 2.85rem, radius 12px, font 1.5rem; tinta: debtors `rgba(239,68,68,0.10)`, creditors `rgba(34,197,94,0.10)`.
  - `h3` card: 0.7rem uppercase `#9ca3af` letter-spacing 0.08em, weight 600.
  - `.stat-value`: 2rem/800/`#111`, tabular-nums; colore per card: debtors `#ef4444`, creditors `#16a34a`.
  - `.stat-card-click-hint`: assoluto top 0.5rem right 0.7rem, 0.62rem, `#d1d5db`.
  - Stato attivo `.stat-card--clickable.active`: `#statcard-debtors` bordo `#ef4444` + glow `0 0 0 3px rgba(239,68,68,0.12), 0 4px 16px rgba(239,68,68,0.10)`; `#statcard-creditors` bordo `#22c55e` + glow analogo verde; hint attivo `#ef4444`/`#16a34a`.
  - Hover: `translateY(-3px)` + glow colorato per card.

### 7.3 Card 1 — "Da Incassare" (insolventi) e lista `#debtorsList`

**Definizione di "da incassare"** (funzione `_getUnpaidContacts()`): tutte le prenotazioni con
`!booking.paid && bookingHasPassed(booking) && status !== 'cancelled' && status !== 'cancellation_requested'`,
raggruppate per **contatto** (match telefono normalizzato con `normalizePhone` OPPURE email lowercase, con doppio indice `phoneIdx`/`emailIdx` per unificare chi ha prenotato ora col telefono ora con l'email). Ogni gruppo: `{ name, whatsapp, email, unpaidBookings:[{...b, price}], totalAmount }`, `price = getBookingPrice(b)` (§7.14), `totalAmount` arrotondato a 2 decimali. Filtrati `totalAmount > 0` e **ordinati per importo decrescente**.

- `bookingHasPassed(b)`: prende la parte iniziale di `b.time` (formato `"HH:MM - HH:MM"`), costruisce `Date(anno, mese-1, giorno, HH, MM)` da `b.date` (`YYYY-MM-DD`) e ritorna `new Date() >= startDateTime` (la lezione è "passata" appena inizia).
- `getUnpaidAmountForContact(whatsapp, email)`: stessa logica per singolo contatto (riusata da admin-calendar.js) — somma i prezzi delle passate non pagate, round 2 decimali.
- Toggle lista: `toggleDebtorsList()` — se privacy attiva (`_sensitiveHidden`) non fa nulla; mostra/nasconde `#debtorsList` (`display:flex`/`none`), cambia hint `Dettagli ▼` ⇄ `Nascondi ▲`, toggla `.active` sulla card; **mutuamente esclusivo** con la lista pagamenti recenti (aprire l'una collassa l'altra via `_collapseRecentList()`/`_collapseDebtorsList()`).
- **Stato vuoto** (testo esatto): `<div class="empty-slot">Nessun cliente con pagamenti in sospeso! 🎉</div>` (`.empty-slot`: centrato, padding 1.5rem, `#94a3b8`, italic, 0.88rem; mobile ≤768px padding 0.4rem 0.75rem font 0.82rem).
- **Card debitore** (`createDebtorCard(contact, cardId)`, id `debtor-card-main-{i}`), markup:
  - header (click → `toggleDebtorCard(id)` che toggla la classe `open`):
    - `.debtor-name` = nome (1.2rem bold);
    - `.debtor-contact` = `📱 {whatsapp || '—'}` (0.9rem `#666`);
    - `.debtor-amount` = **`Da incassare: €{totalAmount}`** — pill rossa: bg `rgba(239,68,68,0.08)`, testo `#ef4444`, bordo `rgba(239,68,68,0.15)`, radius 20px, padding 0.3rem 0.85rem, 0.9rem/700;
    - `.debtor-toggle` = `▼` (`#bbb`; ruota 180° con `.open`).
  - body (visibile solo con `.open`): righe `.debtor-booking-item` (bg `#f8f9fb`, radius 8px, bordo `#f0f1f3`) con `.debtor-booking-details` = `📅 {date} · 🕐 {time} · {SLOT_NAMES[slotType]}` e `.debtor-booking-price` = `€{price}` (700, `#ef4444`); in fondo bottone **`✓ Segna come pagato`** (classe `.debt-popup-pay-btn`, margin 0.75rem) → `openDebtPopup(whatsapp, email, name)`.
  - Card container `.debtor-card`: bianco, radius 14px, bordo `#e5e7eb` con **border-left 4px** che diventa `#ef4444` in hover; `.debtors-list` è colonna flex `gap:1rem`.

### 7.4 Card 2 — "Incassato questo mese" e lista `#creditsList` (pagamenti recenti)

- Toggle: `toggleCreditsList()` (stessa meccanica di 7.3, hint `#creditorsToggleHint`).
- `.credits-list`: `margin-top:1.25rem; padding-top:1rem; border-top:1.5px solid rgba(34,197,94,0.15)`.
- **Stato vuoto** (testo esatto): `<div class="empty-slot">Nessun pagamento registrato</div>`.
- Riga pagamento (`_createPaymentRow(p)`, classe `debtor-card payment-ledger-row`, header con `cursor:default`):
  - riga 1: `client_email` o `—` (`.debtor-name`);
  - riga 2: `📅 {gg/m/aaaa} · {kind label} · {method label}` + se `period_start`&&`period_end`: ` · {gg/m} → {gg/m}`; se `note`: seconda span `📝 {note}`;
  - a destra: `.debtor-amount.credit-amount` = `€{amount}` — variante **verde**: testo `#16a34a`, bg `rgba(34,197,94,0.08)`, bordo `rgba(34,197,94,0.15)`.
- **Etichette metodo** (`PAYMENT_METHOD_LABELS`, testi esatti):
  `contanti` → `💵 Contanti`; `contanti-report` → `🧾 Contanti con Report`; `carta` → `💳 Carta`; `iban` → `🏦 Bonifico`; `stripe` → `🌐 Stripe`; `gratuito` → `🎁 Gratuito`.
- **Etichette kind** (`PAYMENT_KIND_LABELS`): `session` → `Lezione`; `membership` → `Abbonamento`; `package_purchase` → `Pacchetto`; `penalty_mora` → `Mora`; `adjustment` → `Rettifica`.

### 7.5 Modal "Segna come pagato" (`#debtPopupModal`, markup statico in admin.html)

Aperto da `openDebtPopup(whatsapp, email, name)`. Ricalcola le prenotazioni **non pagate** del contatto (stesso match phone/email; qui SENZA il filtro "passata": include anche le future), ordinate per data+ora. Se zero → toast `Nessuna prenotazione da saldare` (tipo info) e non apre.

- Header: `#debtPopupName` = nome cliente; `#debtPopupSubtitle` (testo generato, plurali esatti):
  `"{N} lezioni non pagate ({X} passate, {Y} future)"` — singolari: `lezione`/`pagata`/`passata`/`futura`. Esempio: `3 lezioni non pagate (2 passate, 1 futura)`.
- Lista `#debtPopupList` (`_renderDebtPopupList`): per ogni booking una riga `.debt-popup-item` con checkbox `.debt-item-check` (attrs: `data-id`, `data-sbid` = UUID Supabase `_sbId`, `data-price`, `onchange=updateDebtTotal()`), `.debt-item-date` = `{g/m} {HH:MM–HH:MM}` (title = data completa + orario), `.debt-item-type` = `SLOT_NAMES[slotType]` (prefisso CSS `· `), `.debt-item-price` = `€{prezzo}` con virgola decimale (`toFixed(2).replace('.', ',')`, colore `#e63946`). Le righe **passate** hanno classe `.debt-popup-item--past` → sfondo rosato `#fff1f2`.
- Selettore metodo (markup esatto):
  ```html
  <span class="debt-field-label">Metodo di pagamento</span>
  <select class="debt-method-select" id="debtMethodSelect" onchange="onPaymentMethodChange(this)">
      <option value="" disabled selected>Seleziona…</option>
      <option value="contanti">💵 Contanti</option>
      <option value="contanti-report">🧾 Contanti con Report</option>
      <option value="carta">💳 Carta</option>
      <option value="iban">🏦 Bonifico</option>
      <option value="lezione-gratuita">🎁 Gratuita</option>
  </select>
  ```
  Nota: `lezione-gratuita` viene mappato a `gratuito` prima della RPC (`ledgerMethod = method === 'lezione-gratuita' ? 'gratuito' : method`). Qui NON c'è l'opzione `stripe` (i pagamenti Stripe cliente arrivano da webhook, non manuali).
- Footer: checkbox **`Seleziona tutto`** (`#debtSelectAll` → `toggleAllDebts(checked)`) e **`Seleziona passate`** (`#debtSelectPast` → `togglePastDebts(checked)`, visibile solo se esistono righe `--past`, spunta SOLO le passate lasciando intatte le future); totale **`Dovuto: €{somma selezionate}`** (`#debtSelectedTotal`); bottone **`✓ Conferma`** (`#debtPayBtn`, disabilitato finché `0 selezionate || metodo vuoto`).
- `_syncDebtToggleStates()`: gestisce `checked`/`indeterminate` di entrambi i toggle in base allo stato reale delle checkbox.
- Il campo "importo incassato" legacy (`.debt-payment-amount-row`) viene **nascosto**: il prezzo è deciso dal server.
- **Conferma** (`paySelectedDebts()`):
  1. valida metodo (`Seleziona un metodo di pagamento`) e selezione (`Seleziona almeno una lezione`) — toast error;
  2. prende solo gli id sincronizzati (`data-sbid` non vuoto); se zero → toast `Nessuna prenotazione sincronizzata da saldare`;
  3. bottone → `Salvataggio...` disabilitato;
  4. **sessione garantita** prima della RPC (non idempotente): `ensureValidSession({ force:false, timeoutMs:12000 })`; se persa → toast `Sessione scaduta. Riaccedi prima di registrare il pagamento.` (error, 5000ms) e abort;
  5. RPC: `supabaseClient.rpc('admin_pay_bookings', { p_booking_ids: sbIds, p_method: ledgerMethod, p_paid_at: new Date().toISOString() })` con timeout 30000;
  6. errore → toast `Errore: {msg}`; successo → chiude popup, toast `"{N} pagamenti registrati"` (singolare `pagamento registrato`), poi `BookingStorage.syncFromSupabase()`, re-render del giorno calendario se aperto e `renderPaymentsTab('saveDebtPayment')` se il tab attivo è payments;
  7. `finally`: bottone torna `✓ Conferma` abilitato. Catch rete: toast `Errore di rete o timeout. Riprova.`.
- CSS modal (`.debt-popup-modal`): fixed centrato, `width:min(500px, calc(100vw - 32px))`, max-height 82vh, radius 16px, ombra `0 24px 64px rgba(0,0,0,0.22)`, transizione opacity/transform 0.22s (entra da translate -46% → -50%); overlay `rgba(0,0,0,0.55)` z-index 2000.

### 7.6 RPC `admin_pay_bookings` (baseline.sql — firma esatta)

```sql
admin_pay_bookings(p_booking_ids uuid[], p_method text, p_paid_at timestamptz default now()) returns integer
```
SECURITY DEFINER; richiede `is_org_admin(current_org_id())` altrimenti `exception 'unauthorized'`. Per ogni booking della **propria org** (lock `for update`) non ancora pagato:
- `update bookings set paid=true, payment_method=p_method, paid_at=p_paid_at`;
- calcola prezzo server-side: `0` se `p_method='gratuito'`, altrimenti `coalesce(bookings.custom_price, get_org_price(org, slot_type))`;
- inserisce riga in `payments` con `kind='session'`, `method` whitelistato (`contanti|contanti-report|carta|iban|stripe|gratuito`, fallback `contanti`), `booking_id`, `client_user_id`, `client_email`, `currency` della org, `created_by=auth.uid()`;
- **idempotenza**: `on conflict (booking_id) where kind='session' do nothing` (indice unico parziale `payments_booking_session_uidx`).
Ritorna il numero di booking saldati.

### 7.7 FAB e action sheet "Registra incasso"

- FAB: `<button id="paymentsFab" class="payments-fab" onclick="openPaymentsActionSheet()" aria-label="Aggiungi pagamento" title="Aggiungi">` con icona SVG "+" 28×28. CSS: fixed bottom/right 1.5rem, 56×56, cerchio, bg `#8B5CF6`, ombra `0 4px 14px rgba(139,92,246,0.35)`, z-index 1000.
- `openPaymentsActionSheet()` costruisce a runtime un bottom-sheet (`.payments-sheet-overlay` blur 4px + `.payments-sheet` che sale da sotto, radius 20px top; desktop ≥768px: centrato, width 420px):
  - handle grigio 36×4, titolo **`Registra incasso`** (0.95rem/800);
  - opzione 1 (verde, icona 🎟️ su gradiente `#22c55e→#16a34a`): titolo **`Vendi pacchetto`**, descrizione **`Carnet di lezioni prepagate`** → `openSellPackagePopup()`;
  - opzione 2 (rossa, icona 📅 su gradiente `#ef4444→#dc2626`): titolo **`Registra abbonamento`**, descrizione **`Quota mensile / periodo`** → `openMembershipPopup()`.
  - Click su overlay o selezione → `closePaymentsActionSheet()` (fade 300ms poi remove).

### 7.8 Popup vendita Pacchetto / Abbonamento (`_openSalePopup(type)`, costruito a runtime)

Stato: `_saleType` (`'package' | 'membership'`), `_saleContact` (`{name, whatsapp, email, userId}`).
Overlay `#saleOverlay` con modal `debt-popup-modal manual-entry-modal` max-width 460px.

- Header: `🎟️ Vendi pacchetto` / sottotitolo `Carnet di lezioni prepagate`, oppure `📅 Registra abbonamento` / `Quota mensile / periodo`; bottone chiudi `✕`.
- Campi comuni:
  - **Cliente**: input `#saleClientInput` placeholder `Nome o telefono...` con ricerca live (`liveSearchSaleClient()`: min 2 caratteri, `UserStorage.search(q).slice(0, 6)`, dropdown `#saleClientDropdown`); selezione → chip `#saleClientSelected` con avatar iniziali (2 lettere), nome, sottotitolo `whatsapp · email`, bottone ✕ per deselezionare. Solo clienti **registrati** (serve `userId`).
  - **Etichetta**: input `#saleLabel`, placeholder `Es. Carnet 10 lezioni` (package) / `Es. Abbonamento mensile` (membership).
  - **Prezzo**: `€` + input number `#salePrice` min 0 step 0.01 placeholder `0`.
  - **Metodo di pagamento**: select `#saleMethod` con `💵 Contanti / 🧾 Contanti con Report / 💳 Carta / 🏦 Bonifico / 🌐 Stripe` (valori `contanti|contanti-report|carta|iban|stripe`; qui NON c'è "gratuita").
- Solo **package**: `Numero di lezioni` (`#saleSessions`, number min 1 step 1, placeholder `10`) e `Scadenza (opzionale)` (`#saleExpires`, date).
- Solo **membership**: `Periodo` = due date affiancate `#salePeriodStart`/`#salePeriodEnd` (default: oggi → stesso giorno del mese successivo) e `Lezioni incluse (vuoto = illimitato)` (`#saleQuota`, number, placeholder `∞`).
- Footer: `Annulla` (`.btn-clear-search`) + **`✓ Registra`** (`#saleSaveBtn`).
- **Salvataggio** (`saveSale()`, guard `_savingSale` anti doppio-tap):
  - validazioni/toast: `Seleziona un cliente registrato dalla lista`; `Inserisci un prezzo valido`; `Numero di lezioni non valido`; `Imposta il periodo dell'abbonamento`;
  - `ensureValidSession` come in 7.5, toast `Sessione scaduta. Riaccedi prima di registrare la vendita.`;
  - RPC package: `admin_sell_package({ p_user_id, p_label: label || 'Pacchetto', p_sessions, p_price, p_method, p_expires })` (timeout 30000);
  - RPC membership: `admin_record_membership_payment({ p_user_id, p_label: label || 'Abbonamento', p_price, p_period_start, p_period_end, p_lessons_quota: quota|null, p_method })`;
  - post-successo: **upsert dell'override modello** — `supabaseClient.from('client_billing_profiles').upsert({ org_id: window._orgId, user_id, model_override: 'package'|'monthly' }, { onConflict: 'org_id,user_id' })` (best-effort, warn se fallisce) → così `book_slot` applica da subito la logica giusta a QUEL cliente;
  - toast `Pacchetto registrato` / `Abbonamento registrato`, chiusura, re-render del tab.

### 7.9 RPC di vendita (firme esatte, baseline.sql)

```sql
admin_sell_package(p_user_id uuid, p_label text, p_sessions integer, p_price numeric,
                   p_method text default 'contanti', p_expires date default null) returns uuid
```
Admin-only. Inserisce `client_packages(org_id, user_id, label, total_sessions=p_sessions, remaining_sessions=p_sessions, expires_at, price)` e riga ledger `payments(kind='package_purchase', method=p_method, amount=p_price, package_id, client_user_id, client_email, created_by)`. Ritorna l'id pacchetto.

```sql
admin_record_membership_payment(p_user_id uuid, p_label text, p_price numeric,
    p_period_start date, p_period_end date,
    p_lessons_quota integer default null, p_method text default 'contanti') returns uuid
```
Admin-only. Inserisce `client_memberships(plan_label, period_start, period_end, lessons_quota, price, status='active')` e riga ledger `payments(kind='membership', membership_id, period_start, period_end, …)`. Ritorna l'id membership. **Il "rinnovo" = registrare un nuovo pagamento con nuovo periodo** (crea una nuova riga membership; `book_slot` usa quella con `period_end` più lontano).

### 7.10 I 4 modelli di billing-cliente e la risoluzione default/override

- Tabella **`billing_settings`** (1 riga per org, PK `org_id`) = **default dello studio**:
  - `default_model` ∈ `pay_per_session | monthly | package | free` (default `pay_per_session`);
  - `block_unpaid_threshold numeric(10,2)` default 0 (0 = nessun blocco);
  - `block_if_membership_expired boolean` default true;
  - `block_if_no_package boolean` default true;
  - `grace_days integer` default 0;
  - `package_auto_decrement boolean` default true;
  - `updated_at`.
  Creata con i default da `create_organization` all'onboarding. La configurazione UI avviene nel tab Impostazioni (modulo `OrgSettings`/admin-settings, fuori scope di questa sezione).
- Tabella **`client_billing_profiles`** = **override per-cliente**: `id, org_id, user_id (unique org_id+user_id), client_email, model_override (stesso CHECK dei 4 modelli, nullable), custom_price numeric(10,2), notes, created_at`. L'admin non ha una UI dedicata: l'override viene scritto **automaticamente** dalla vendita (§7.8) o via DB.
- **Risoluzione** (dentro `book_slot`): `coalesce(cbp.model_override, bs.default_model, 'pay_per_session')`.
- Comportamento per modello (gating/decremento in `book_slot`, SOLO se il cliente è identificato, `v_book_user is not null`):
  - **`free`** → booking creato subito `paid=true, payment_method='gratuito'`.
  - **`package`** → seleziona (FOR UPDATE) il pacchetto `status='active' AND remaining_sessions>0 AND (expires_at is null OR expires_at >= current_date)` **più vecchio per `purchased_at`** (FIFO). Se non c'è: blocca con errore **`no_package`** se `billing_settings.block_if_no_package`, altrimenti lascia prenotare non pagato. Se c'è: `remaining_sessions - 1` (e `status='exhausted'` se arriva a 0), booking `paid=true, payment_method='pacchetto'`, salva `consumed_package_id` per il refund in caso di cancellazione.
  - **`monthly`** → seleziona la membership `status='active'` con `period_end` **più recente** (FOR UPDATE). Se assente o `period_end < current_date - grace_days`: errore **`membership_expired`** se `block_if_membership_expired`. Se `lessons_quota` non null e `lessons_used >= lessons_quota`: errore **`quota_exceeded`**. Altrimenti `lessons_used + 1`, booking `paid=true, payment_method='abbonamento'`, salva `consumed_membership_id`.
  - **`pay_per_session`** (default) → booking creato **non pagato** (`paid=false`); il saldo avviene poi con `admin_pay_bookings` (§7.5-7.6). È l'unico modello che alimenta la lista "Da Incassare".
- Nota UI: i `payment_method` interni `pacchetto`/`abbonamento` sui bookings NON sono metodi del ledger; nel dettaglio Analytics "Fatturato per tipo di pagamento" eventuali method fuori whitelist vengono raggruppati come **"Altro"** (§8.4).

### 7.11 Schema `client_memberships` (mensile)

`id uuid PK, org_id, user_id NOT NULL → profiles, plan_label text, period_start date NOT NULL, period_end date NOT NULL, lessons_quota integer (null = illimitato), lessons_used integer default 0, status text default 'active' CHECK in ('active','expired','cancelled'), auto_renew boolean default false, price numeric(10,2), created_at`. Indici `(org_id,user_id)` e `(org_id,user_id,status,period_end)`. La scadenza effettiva è valutata da `book_slot` confrontando `period_end` + `grace_days` (lo status non viene auto-flippato a `expired` da un cron nel codice attuale).

### 7.12 Schema `client_packages` (carnet)

`id uuid PK, org_id, user_id NOT NULL, label text, total_sessions integer NOT NULL, remaining_sessions integer NOT NULL, purchased_at timestamptz default now(), expires_at date (null = non scade), status text default 'active' CHECK in ('active','exhausted','expired','cancelled'), price numeric(10,2), created_at`. Decremento **esclusivamente server-side** in `book_slot` (§7.10); refund su cancellazione via `consumed_package_id`.

### 7.13 Ledger `payments` (unica fonte del fatturato reale)

Campi (baseline.sql): `id uuid PK, org_id NOT NULL, created_at timestamptz default now(), client_user_id uuid → profiles (set null), client_email text, amount numeric(10,2) NOT NULL, currency text default 'EUR', method CHECK in ('contanti','contanti-report','carta','iban','stripe','gratuito'), kind CHECK in ('session','membership','package_purchase','penalty_mora','adjustment'), booking_id uuid → bookings (set null), membership_id, package_id, period_start date, period_end date, note text, created_by uuid, stripe_payment_intent text unique`.
Indici: `(org_id, created_at)`, `(org_id, client_email)`, unico parziale `(booking_id) where kind='session'`.
**Scrittura**: solo da RPC (`admin_pay_bookings`, `admin_sell_package`, `admin_record_membership_payment`) e dal webhook Stripe; il client non fa mai INSERT diretti. **Lettura**: select org-scoped via RLS (il client non passa mai org_id).

### 7.14 Prezzi client-side: `getBookingPrice(booking)` (data.js)

Ordine: 1) `booking.customPrice` se numerico; 2) `OrgSettings.get('billing_client.prices')[slotType]` (listino per-org jsonb); 3) `OrgSettings.getNumber('price.<slotType>')` (legacy); 4) fallback deprecato `SLOT_PRICES` (`personal-training:5, small-group:10, group-class:30, cleaning:0`). `SLOT_NAMES` = `personal-training:'Autonomia', small-group:'Lezione di Gruppo', group-class:'Slot prenotato', cleaning:'Pulizie'`. Server-side l'autorità è `get_org_price(org, slot_type)` / `bookings.custom_price`.

### 7.15 Modal "Dati mancanti" (`#missingDataModal`, logica in admin-analytics.js)

`ensureClientDataForCardPayment(email, whatsapp, name, method)` — richiesto per i metodi **fiscali** `REQUIRE_DATA = {'carta','iban','stripe','contanti-report'}` (chiamato dai flussi di incasso in calendar/clients). Se il profilo ha già `codiceFiscale`, `indirizzoVia`, `indirizzoPaese`, `indirizzoCap` → resolve immediato. Altrimenti apre il popup (Promise: resolve al salvataggio, reject `'cancelled'` alla chiusura):
- titolo: `⚠️ Dati mancanti — {nome|email}` (default statico: `⚠️ Dati mancanti per pagamento`);
- testo: `Per i pagamenti riportati fiscalmente (carta, bonifico, stripe, contanti con report) servono Codice Fiscale e indirizzo di residenza.`;
- campi (mostrati SOLO quelli mancanti): `Codice Fiscale` (`#mdCodiceFiscale`, placeholder `RSSMRA85M01H501Z`, maxlength 16, uppercase), `Via / Indirizzo` (placeholder `Via Roma 1`), `Paese / Città` (placeholder `Milano`) + `CAP` (placeholder `20100`, 5 cifre numeric);
- validazioni (testi esatti in `#mdError`): `Codice Fiscale non valido.` (regex `^[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]$` case-insensitive), `Il Codice Fiscale è obbligatorio.`, `La via è obbligatoria.`, `Il paese è obbligatorio.`, `CAP non valido (5 cifre).`;
- bottoni: `Annulla` / **`✓ Salva e continua`** (`saveMissingData()`: aggiorna cache `UserStorage._cache` + `profiles` su Supabase con `codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap`; il paese passa da `normalizeComune`). Z-index sopra gli altri popup (`#missingDataOverlay` 2200, `#missingDataModal` 2300).

### 7.16 Privacy mask, chiavi localStorage, funzioni

- **Privacy** (admin.js): `SENSITIVE_IDS = ['totalUnpaid','totalDebtors','totalCreditors','totalCreditAmount','monthlyRevenue','revenueChange']`; `sensitiveSet(id, value)` salva `dataset.realValue` e mostra `***` se `_sensitiveHidden`; toggle occhio 👁 nella tab-bar (`toggleSensitiveData()`), persistito in localStorage **`adminSensitiveHidden`** (`'true'/'false'`). Con privacy attiva `toggleDebtorsList/toggleCreditsList` sono bloccati.
- **localStorage**: nessuna chiave propria del tab Pagamenti oltre alla privacy; i bookings vengono dal dual-layer `BookingStorage` (cache localStorage + sync Supabase, org-namespaced in data.js).
- **Funzioni JS esatte** (admin-payments.js): `bookingHasPassed`, `getUnpaidAmountForContact`, `_getUnpaidContacts`, `renderPaymentsTab`, `_paintPaymentsTab`, `_createPaymentRow`, `createDebtorCard`, `toggleDebtorCard`, `toggleDebtorsList`, `toggleCreditsList`, `_collapseRecentList`, `_collapseDebtorsList`, `clearSearch`, `openDebtPopup`, `_renderDebtPopupList`, `_updateDebtTotal`, `updateDebtTotal` (alias), `_syncDebtToggleStates`, `toggleAllDebts`, `togglePastDebts`, `onPaymentMethodChange`, `paySelectedDebts`, `closeDebtPopup`, `openPaymentsActionSheet`, `closePaymentsActionSheet`, `openSellPackagePopup`, `openMembershipPopup`, `_openSalePopup`, `closeSalePopup`, `liveSearchSaleClient`, `selectSaleClient`, `saveSale`, `_isoDate`.

---

## 8. Tab Statistiche & Fatturato (Analytics)

### 8.1 Ingresso, layout e filtri periodo

- Bottone tab: `<button class="admin-tab" data-tab="analytics">📊 Statistiche & Fatturato</button>`. Allo switch: `requestAnimationFrame(() => requestAnimationFrame(() => loadDashboardData()))` (doppio rAF: prima il paint del tab, poi il lavoro pesante).
- Titolo: `h2` **`Statistiche`**, span **`& Fatturato`**.
- **Filter bar** (`.analytics-filter-bar`, stile "underline tabs": border-bottom `#e2e8f0`; bottone attivo testo `#7C3AED` + underline 3px `#8B5CF6`, weight 700; inattivo `#64748b` 0.88rem/600) — testi esatti dei 6 bottoni:
  `Questo mese` (attivo di default) · `Mese prossimo` · `Mese scorso` · `Quest'anno` · `Anno scorso` · `📅 Personalizzato`.
  Con `Personalizzato` appare `#filterCustomDates`: `input date` → `→` → `input date` → bottone **`Applica`** (`.btn-apply-filter`: gradiente `#8B5CF6→#7C3AED`, bianco, radius 10px, 0.85rem/700). Default range custom: 1° del mese corrente → oggi.
- Stato filtro: `currentFilter` ∈ `this-month | next-month | last-month | this-year | last-year | custom`, più `customFilterFrom/customFilterTo` (`YYYY-MM-DD`).
- `getFilterDateRange(filter)` → `{from: Date, to: Date}` esatti (to sempre a 23:59:59.999): mese corrente/prossimo/scorso da calendario; anni interi; custom da input.
- `getPreviousFilterDateRange(filter)` = periodo di confronto: this-month→mese scorso; next-month→mese corrente; last-month→due mesi fa; this-year→anno scorso; last-year→2 anni fa; custom→`null` (nessun confronto).
- `getFilterLabel(filter)` (etichette mostrate, italiano): `"{MeseEsteso} {anno}"` (mesi `Gennaio…Dicembre`), `"{anno}"`, custom `"{from} → {to}"` o `Personalizzato`. `getPreviousFilterLabel` → nome del mese/anno di confronto (fallback `periodo prec.`).
- `setAnalyticsFilter(filter, btn)`: guard `_filterSwitching`, toggle `.active`, disabilita tutti i `.filter-btn` durante il load; `custom` mostra i date-picker e ASPETTA "Applica". `applyCustomFilter()`: valida con `showAlert` warn — testi esatti `Seleziona entrambe le date.` e `La data di inizio deve essere precedente alla data di fine.`.

### 8.2 Stat card principali (4, tutte cliccabili → drill-down)

Markup: `.stats-grid` con 4 `.stat-card--clickable` (hint `Dettagli ▼`), click → `toggleStatDetail(tipo)`. Accenti top (`::after`): fatturato `linear-gradient(90deg,#f59e0b,#fbbf24)`, prenotazioni `#3b82f6→#60a5fa`, clienti `#10b981→#34d399`, occupancy `#8b5cf6→#a78bfa`; icona con tinta 10% del colore; attive con bordo/glow del proprio colore.

| Card (id) | Icona / h3 esatto | Valore (id) | Formula esatta |
|---|---|---|---|
| `statcard-fatturato` | 💰 `Fatturato previsto` | `#monthlyRevenue` = `€{revenue}` | `revenue = Σ getBookingPrice(b)` sui booking del periodo con `status!=='cancelled'` e `paymentMethod!=='lezione-gratuita'` (pagati o no: è una **proiezione** dal valore delle prenotazioni; il fatturato incassato è nel drill-down "Reale") |
| — badge | `#revenueChange` | `+N% vs {mesePrec}` | `pct = round((cur-prev)/prev*100)` se `prevRange` esiste, filtro ≠ custom e `prev>0`; classe `.stat-change.positive` (verde `#059669` su `rgba(16,185,129,0.1)`) se ≥0, `.negative` (`#dc2626` su `rgba(239,68,68,0.08)`) se <0; altrimenti mostra l'etichetta periodo |
| `statcard-prenotazioni` | 📅 `Prenotazioni Totali` | `#totalBookings` | `filteredBookings.length` (esclusi `cancelled`, esclusi ADMIN_EMAILS) + badge `#bookingsChange` stesso `calcChange` |
| `statcard-clienti` | 👥 `Clienti Attivi` | `#activeClients` | `new Set(filteredBookings.map(b => b.email)).size`; badge `#clientsChange` = etichetta periodo (nessun confronto %) |
| `statcard-occupancy` | 📊 `Tasso Occupazione` | `#occupancyRate` = `{N}%` | `totalSlots` = per ogni giorno del periodo con override orari (`BookingStorage.getScheduleOverrides()[ds]` non vuoto): +1 per slot `group-class`, `+SLOT_MAX_CAPACITY[type]` per gli altri; `rate = round(filteredBookings.length / totalSlots * 100)` (0 se totalSlots=0). Badge = etichetta periodo, classe `positive` se >50 |

- `monthlyRevenue` e `revenueChange` passano da `sensitiveSet` (mascherabili `***`).
- Skeleton: `_setStatCardsLoading(on)` toggla `.stat-card--loading` (valore/badge diventano blocchi grigi `#e5e7eb` pulsanti, `skeleton-pulse` 1.2s); mostrato solo se il fetch dura >200ms e non c'è cache.
- Fonte dati: `getFilteredBookings(filter)` usa `_statsBookings` (fetch Supabase) se presente, altrimenti `BookingStorage.getAllBookings()` filtrato con `_excludeAdminBookings` (esclude email in `ADMIN_EMAILS`, in data.js: `demo@palestria.app`, `andrea.pompili1997@gmail.com`).

### 8.3 Pipeline dati, cache e ottimizzazioni egress

- **`loadDashboardData()`** (anti-stale con `_loadDashboardSeq`):
  1. SWR: se `_statsBookings` in RAM → `_renderDashboardUI()` immediato;
  2. calcola la **finestra estesa** di fetch: `extFrom = min(prevRange.from, from, 12 mesi fa)`, `extTo = max(to, fine del mese +12 mesi)` (≈ 2 anni: serve ai grafici "ultimi 12 mesi + successivo");
  3. **cold start**: `_hydrateStatsCache(extFromStr, extToStr)` dallo snapshot persistito (sotto); fallback allo snapshot condiviso di `BookingStorage` (solo paint, si rivalida comunque);
  4. **cache hit**: copertura tracciata SEPARATAMENTE per bookings (`_statsCacheRange`) e payments (`_statsPaymentsRange`); se entrambe coprono `[extFrom, extTo]` → skip fetch;
  5. altrimenti fetch in parallelo: `BookingStorage.fetchForAdmin(extFromStr, extToStr)` (race con timeout 10s) + `_fetchPayments(extFromStr, extToStr)`; a successo aggiorna cache/range e chiama `_persistStatsCache()`; se il fetch payments fallisce → `_statsPayments=null` (il render mostra `—` invece di dati stantii mal-attribuiti);
  6. `_statsLastLoad = Date.now()`; render finale.
- **Snapshot persistito** (stale-while-revalidate al refresh): chiave localStorage **`gym_stats_cache_v1:{identity}`** dove identity = `'admin'` (se `sessionStorage.adminAuth==='true'`) o `getCurrentUser().id`. Payload: `{ savedAt, clearedAt (copia di localStorage 'dataLastCleared'), range:{from,to}, rows:[bookings] }`. TTL freschezza **90_000 ms** (`_STATS_PERSIST_TTL_MS`); cap **6000 righe** (`_STATS_PERSIST_MAX_ROWS`, oltre non persiste); scartato se `dataLastCleared` è cambiato. `'fresh'` = entro TTL e range coperto → salta anche il fetch bookings. Lo snapshot copre SOLO i bookings; il ledger payments è sempre un fetch separato (più leggero).
- **`invalidateStatsCache()`**: azzera `_statsCacheRange` + `_statsPaymentsRange` e rimuove tutti gli snapshot `gym_stats_cache_v1:*` (`_clearPersistedStatsCache`); da chiamare dopo ogni save/cancel booking. Chiamata anche cross-pagina da `BookingStorage._clearPersistedCache` (logout/clear).
- **`_fetchPayments(fromStr, toStr)`**: fetch **paginato** del ledger (PAGE=1000, `range(pageFrom, pageFrom+999)`) su `payments.select('created_at,amount,method,kind,client_email').order('created_at', desc)` con `gte(created_at, from+'T00:00:00')` / `lte(created_at, to+'T23:59:59.999')`; esclude ADMIN_EMAILS; mappa in `{ date, amount:Number, method, kind, email }`; `null` su errore. Con `(null, null)` scarica TUTTO il ledger (usato dal report fiscale completo).
- **Auto-refresh su visibilità**: listener `visibilitychange` — se la pagina torna visibile dopo **>5 min** (`300_000` ms; nel commento "2 minuti" ma il codice usa 5) e il tab analytics è attivo → `invalidateStatsCache()` + `loadDashboardData()`.
- `_renderDashboardUI()` chiama: `updateStatsCards`, `drawBookingsChart`, `drawTypeChart`, `updateBookingsTable`, `updatePopularTimes` e, se un drill-down è aperto, il suo `render*Detail`. **NOTA**: i canvas `#bookingsChart`/`#typeChart`, la tabella `#bookingsTableBody` e i contenitori `#popularTimes`/`#unpopularTimes` **non esistono più in admin.html** → quelle 4 funzioni ritornano subito (guard `if (!el) return`). In Flutter NON vanno replicate come UI del tab (il codice resta come riferimento: line chart rosso `#e63946` prenotazioni/giorno o /mese se >60 giorni con max 12 label; donut Autonomia/Lezione di Gruppo/Slot prenotato colori `#22c55e/#fbbf24/#ef4444`; tabella ultime 15 con badge stato `Confermata/Richiesta annullamento/Annullata/In attesa` e stato vuoto `Nessuna prenotazione nel periodo selezionato`; barre orari popolari con `{count} pren.` e vuoto `Nessun dato disponibile`).

### 8.4 Drill-down "Fatturato" (`toggleStatDetail('fatturato')` → `renderFatturatoDetail(panel)`)

Il pannello `#statsDetailPanel` (`.stats-detail-panel`: bianco, radius 18px, padding 1.5rem, accento top gradiente `#f59e0b,#3b82f6,#10b981,#8b5cf6` opacity 0.65, animazione fade-in 0.25s) si apre sotto le card; click sulla stessa card lo chiude; una sola card attiva alla volta; `card.scrollIntoView({behavior:'smooth'})`.

- Header: `<h3>💰 Fatturato — Dettaglio</h3>` + **switch modalità** (`.stat-detail-mode-tabs`, 2 bottoni `stat-mode-btn`: attivo bg `#111` testo bianco): **`Prenotazioni`** | **`Reale`** (`switchFatturatoMode('prenotazioni'|'reale')`, stato `_fatturatoMode`, default `prenotazioni`) + badge periodo `.stat-detail-period` = `getFilterLabel(currentFilter)`.
- **Fonti**: modalità *Reale* = ledger `payments` (Σ `amount` per periodo su `created_at`); *Prenotazioni* = proiezione `Σ getBookingPrice(b)` sui booking non cancellati con `paymentMethod!=='lezione-gratuita'`.
- `pastCutoff` = oggi 00:00 (*Prenotazioni*) o **domani** 00:00 (*Reale*: gli incassi di oggi contano come passati).
- Se in Reale `_statsPayments === null` (ledger non disponibile) → tutti i valori Reale mostrano **`—`** (`fmtReale`); `[]` legittimo resta €0.
- **KPI cards** (`.stat-detail-kpis`, grid auto-fit minmax(100px,1fr); varianti colore: `--actual` blu `#eff6ff`/valore `#2563eb`, `--future` rosso `#fef2f2`/`#dc2626`, `--projected` verde `#f0fdf4`/`#059669`, `--warn` ambra `#fff7ed`/`#d97706`; label 0.65rem uppercase `#9ca3af`):
  - *Prenotazioni*: `€{pastRevenue}` label **`Prenotazioni fatte`** (actual) · `€{futureRevenue}` **`Prenotazioni future`** (future) · `€{scheduleEstimate}` **`Stima futura`** (projected) · `€{weeklyAvg}` **`Media settimanale`**;
  - *Reale*: `€{pastRevenue}` label **`Incassato`** · `€{Σ payMethodStats.rev}` **`Fatturato reale`** · `€{weeklyAvg}` **`Media settimanale`** (niente future/stima: gli incassi sono sempre a posteriori).
  - Formule: `pastRevenue` = Reale: `payInRange(from, min(to, pastCutoff-1ms))`; Pren.: Σ prezzi booking con data < pastCutoff. `futureRevenue` analogo da pastCutoff a `to`. `weeklyAvg = round((past+future) / giorniProgrammati * 7)` dove giorniProgrammati = giorni del periodo con `overrides[ds].length>0`. `scheduleEstimate = knownRev + round(knownRev / periodScheduledDays * futureUnscheduledDays)` (giorni futuri del periodo SENZA slot programmati; se non ce ne sono = knownRev).
- **Grafico 1 — `Fatturato mensile (ultimi 12 mesi + successivo)`** (canvas `#detailBarChart`, `drawBarChart`): 13 barre (i = -11…+1). Mesi passati: barra solida = fatturato del mese (Reale: `payInRange`; Pren.: Σ booking). Mese corrente (`highlight=true`, label X rossa bold): solido = maturato, `projected[i]` = valore prenotazioni future del mese (SOLO Prenotazioni; estensione tratteggiata rossa `#e63946` alpha 0.28); `estimated[i]` = stima verde (`#22c55e` alpha 0.22, tratteggiata) = `round(knownRev/schDays*futUnschDays)` sui giorni del mese senza slot (solo i≥0 e solo in Prenotazioni). Mese futuro: solido 0, projected = valore prenotazioni confermate. Label: `Gen…Dic` + `' 'YY` se anno diverso.
- **Grafico 2 — `Andamento e proiezione — {periodo}`** (canvas `#detailForecastChart`, `drawForecastChart`): linee **cumulative** sul periodo filtrato, raggruppate per giorno (o settimana se `totalDays > 60`): `actual` (blu `#3b82f6`, piena) fino a pastCutoff; `forecast` (grigia `#94a3b8`, tratteggiata) = `pastRevenue + cumulato futuro confermato`; `estimated` (verde `#22c55e`, tratteggiata) = forecast + `unschInGroup * avgRevPerSchedDay` cumulato (solo Prenotazioni). Bridge esplicito che collega l'ultimo punto actual al primo forecast. Linea verticale rossa `Oggi` a `todayGroupIdx`. Label X = `g/m` di inizio gruppo, sfoltite a max ~8.
- **Sezione 3, dipende dalla modalità**:
  - *Prenotazioni*: `<h4>Fatturato per tipo di lezione</h4>` + donut `#detailTypeChart` — labels `Autonomia` / `Lez. Gruppo` / `Slot prenotato` (solo tipi con count>0), values = `pastRev+futureRev` per tipo, colori `['#22c55e','#f59e0b','#e63946']`;
  - *Reale*: `<h4>Fatturato per tipo di pagamento</h4>` + donut `#detailPayMethodChart` con Σ `amount` del periodo per `method` (escluso `gratuito`), palette esatta: `Contanti #22c55e`, `Contanti con Report #ef4444`, `Carta #3b82f6`, `Bonifico #f59e0b` (key `iban`), `Stripe #635bff`; metodi fuori whitelist → voce **`Altro`** `#94a3b8`. Sotto, righe `.sdb-row` con pallino colore + label + `€{rev}`; se ci sono pagamenti `method='gratuito'`: riga **`Lezione gratuita`** con pallino viola `#a855f7` e `€{freeLessonValue}`.
  - I donut usano `height` 310 se `window.innerWidth < 768` (legenda sotto), altrimenti 250 (legenda a destra).

### 8.5 Drill-down "Prenotazioni" (`renderPrenotazioniDetail`)

Header `📅 Prenotazioni — Dettaglio` + periodo. Dati: booking del periodo esclusi cancelled (`periodBookings`), split passate/future su oggi 00:00; `cancelledInPeriod` = cancellate con data nel periodo.

- **5 KPI** (testi esatti): `Passate` (actual) = pastBookings.length; `Future` (future); `Stima futura` (projected) = `knownCount + round(knownCount/periodScheduledDays*futureUnscheduledDays)`; `Media sett.` = `(periodBookings.length / schedDays * 7).toFixed(1)` (fallback su totalDays); `Cancellazioni` = `round(cancelled/(period+cancelled)*100)` + `%`, variante `--warn` se >5.
- **Grafici** (2 righe da 2 + 1):
  1. `Trend mensile (ultimi 12 mesi + successivo)` — `#detailTrendChart`, drawBarChart, colori `['#3b82f6']`, `prefix:''` (niente €). Mese corrente: solido = passate del mese, projected = `max(0, cmEstimate - cmActual)` con `cmEstimate = cmActual + max(cmFuture, cmLinear - cmActual, 0)` e `cmLinear = round(cmActual * giorniMese / max(giornoOdierno-1,1))`; estimated verde sui giorni senza slot come in 8.4. Futuro: projected = confermate.
  2. `Per tipo di lezione` — `#detailTypeBookChart`, donut count per tipo (`Autonomia`/`Lez. Gruppo`/`Slot prenotato`), colori `['#22c55e','#f59e0b','#e63946']`, `prefix:''`.
  3. `Per giorno della settimana` — `#detailDayChart`, barre `['#06b6d4']`, ordine `Lun Mar Mer Gio Ven Sab Dom` (labels `Lun…Dom`).
  4. `Per fascia oraria` — `#detailTimeChart`, barre `['#f97316']`, label = ora inizio (`b.time.split(' - ')[0]`), ordinate per orario.
  5. `Top 5 slot più comuni` — `#detailTopSlotsChart`, barre `['#8b5cf6']`, label = `"{Dow} {HH:MM}"` (es. `Lun 18:40`), top 5 per frequenza.
- **Breakdown finale** (righe `.sdb-row`): `Fascia oraria più popolare` → orario; `Giorno più popolare` → nome giorno; riga `--projected` (verde italic): `Stima futura (+{N} gg futuri senza slot)` → valore stima.

### 8.6 Drill-down "Clienti" (`renderClientiDetail`)

Header `👥 Clienti — Dettaglio` + periodo. Mappa clienti per chiave `email || whatsapp || name` sui booking del periodo (incluse cancellate per il conteggio cancellazioni).

- **4 KPI**: `Clienti unici` = chiavi totali; `Nuovi clienti` (projected) = clienti la cui **prima prenotazione in assoluto** cade nel periodo; `Media lezioni/cliente` = `(Σ total / attivi).toFixed(1)`; `Con cancellazioni` = `%` clienti con ≥1 cancellata (variante `--warn` se >20).
- **Otto liste** `.stat-detail-breakdown` (titoli esatti, righe numerate `"{i}. {nome}"` + valore; stato vuoto `Nessun dato`):
  1. `💰 Maggior fatturato (versato)` — **dal ledger payments**: Σ `amount` per email nel periodo escludendo `method='gratuito'`; nome risolto dall'ultimo booking con quella email (fallback email, `(sconosciuto)`); top 5, valore `€{cash}` (mascherato `***` se privacy);
  2. `🏆 Più attivi nel periodo` — top 5 per `total`, valore `{N} lezioni`;
  3. `💤 Meno attivi nel periodo` — bottom 5, `{N} lezioni`;
  4. `❌ Top annullatori` — top 5 per cancellate, `{N} cancellaz.`;
  5. `⭐ Più fedeli (0 cancellazioni)` — top 5 per lezioni tra chi ha 0 cancellate;
  6. `💸 Pagamento more ({count}) — €{totale}` — dal ledger, `kind='penalty_mora'` e `amount>0`; righe `{N} more — €{tot}`; vuoto: `Nessuna mora nel periodo`;
  7. `🆕 Nuovi clienti nel periodo ({N})` — nome + data prima prenotazione `g/m/aaaa` (grigia 0.8rem); vuoto: `Nessun nuovo cliente nel periodo`;
  8. `📉 Clienti persi ({N})` — chiavi attive nel periodo precedente ma assenti in quello corrente (solo se `prevRange` esiste), in ordine alfabetico; vuoto: `Nessun cliente perso`.
- Importi mascherabili con `_maskAmt` (privacy `***`); nomi sempre escapati (`_escHtml`, XSS stored).

### 8.7 Drill-down "Occupazione" (`renderOccupancyDetail`)

Header `📊 Occupazione — Dettaglio`. Capacità per slot: `group-class` = 1, altri = `SLOT_MAX_CAPACITY[type]` (5/5/0/0); i giorni contano solo se hanno override in gestione orari (`overrides[ds]`, nessun fallback template).

- **4 KPI**: `Totale` = `min(100, round(prenTot/capTot*100))%`; `Autonomia` (future/blu) = % personal-training; `Lez. Gruppo` (projected/verde) = % small-group; `Prenotazioni` = conteggio totale nel periodo.
- **3 grafici** drawBarChart con `prefix:''`, `suffix:'%'`:
  1. `Autonomia — ultimi 12 mesi + successivo` — `#occPtChart`, `['#22c55e']`, 13 mesi, mese corrente evidenziato (`highlight`);
  2. `Lezioni di Gruppo — ultimi 12 mesi + successivo` — `#occSgChart`, `['#f59e0b']`;
  3. `Occupazione per giorno della settimana` — `#occDowChart`, `['#3b82f6']`, ordine Lun→Dom, `rate = min(100, round(bookingsDow/capDow*100))`.

### 8.8 chart-mini.js — replica esatta dei grafici (classe `SimpleChart`)

**Setup**: `new SimpleChart(canvas, {height})` — larghezza = `getBoundingClientRect().width` (fallback `offsetWidth`, poi 400); altezza logica = `options.height || 250`; buffer canvas ×2 (`scale(2,2)`, HiDPI). CSS globale: `canvas { width:100% !important; height:250px !important; }` (i canvas dei dettagli hanno style inline `width:100%;display:block`). In Flutter: `CustomPainter` con le stesse geometrie logiche.

**`drawLineChart({labels, values}, {color})`** *(non più montato nel tab, riferimento)*: padding 40 su tutti i lati; vuoto → testo `Nessun dato` 13px `#9ca3af` centrato; `maxValue = max(values, 1)`; `stepX = chartW / max(1, n-1)`; griglia 6 linee orizzontali `#e0e0e0` 1px; linea 3px colore `options.color || '#e63946'`; punti r=4 pieni; label X 11px `#666` centrate a `height-10`; scala Y: 6 valori `round(max/5*(5-i))` 11px allineati a sinistra x=5.

**`drawBarChart(data, options)`** — `data = { labels, values (numeri o array multi-serie), valueLabels?, highlight?, projected?, estimated? }`, `options = { colors=['#3b82f6','#94a3b8'], prefix='€', suffix='', legend? }`:
- pad `{top:24, right:16, bottom:44, left:52}`; vuoto → `Nessun dato` 13px `#9ca3af`;
- `maxVal` include base+projected+estimated per barra (min 1); asse Y "nice": `step = ceil(maxVal/5)`, `axisMax = step*5`; 6 gridline `#e5e7eb` 1px con label `{prefix}{round(axisMax*i/5)}{suffix}` 10px `#9ca3af` right-aligned a `left-5`;
- `slotW = chartW/n`; `barW = min(slotW*0.7/serie, 40)`; gap tra serie 3px; barre con angoli arrotondati top `[3,3,0,0]` (roundRect);
- value label sopra ogni barra >0: bold 9px `#333`, testo = `valueLabels[i][0]` se fornito altrimenti `{prefix}{v}{suffix}`;
- **projected** (solo mono-serie): estensione sopra la barra, fill `#e63946` alpha 0.28 + stroke tratteggiato `#e63946` 1.5px dash `[3,2]`;
- **estimated**: ulteriore estensione sopra projected, fill `#22c55e` alpha 0.22 + stroke tratteggiato `#22c55e` 1.5px dash `[3,2]`;
- label X: 10px `#6b7280`, ma `bold` e `#e63946` se `highlight[i]` (mese corrente); y = `ch - bottom/3 + 4`;
- legenda opzionale: quadratini 10×10 dei colori + testo 10px `#6b7280`, in alto a sinistra (y = top-16), avanzamento `misuraTesto + 30`.
- Nessun tooltip interattivo (canvas statico): i valori sono stampati sopra le barre.

**`drawForecastChart({actual, forecast, estimated, labels, todayIndex})`**:
- pad `{top:24, right:16, bottom:40, left:52}`; scala Y come sopra con prefisso fisso `€`;
- 3 serie di linee (spesse 2.5px, punti r=3.5): `actual` `#3b82f6` piena; `forecast` `#94a3b8` dash `[6,4]`; `estimated` `#22c55e` dash `[6,4]`; i `null` interrompono/spostano il tratto;
- linea verticale `Oggi`: `#e63946` 1.5px dash `[4,3]` a `x = left + todayIndex*stepX`, etichetta `Oggi` bold 9px rossa a destra della linea (y = top+12);
- label X `g/m` 10px `#6b7280`, sfoltite con `skip = ceil(n/8)` (ultima sempre mostrata);
- legenda in alto: trattini 16px (dash se serie tratteggiata) + testi esatti `Effettivo` (blu), `Confermato` (grigio), `Stima` (verde, solo se presente); passo orizzontale 70px.

**`drawPieChart({labels, values}, {colors, prefix='€', mobile})`** — è un **donut**:
- vuoto (`total===0`) → `Nessun dato` 14px `#ccc`;
- layout: desktop = grafico a sinistra (55% larghezza) + legenda a destra centrata verticalmente; mobile (`options.mobile`) = grafico sopra + legenda sotto (righe alte 22px, x=12);
- `radius = min(centerX, areaH/2) - 24`; `innerRadius = radius * 0.52`; fette da -90° in senso orario, bordo bianco 2px;
- % sulla fetta se `pct >= 8`: bianco bold 11px al raggio medio;
- centro: `{prefix}{total}` bold 16px `#333` (y-6) + `Totale` 10px `#888` (y+10);
- legenda: quadratino 10×10 + testo 11px `#333`: **`{label} — {prefix}{value} ({pct}%)`**;
- colori default `['#ff6b6b','#4ecdc4','#ffd93d']` (sempre sovrascritti dai chiamanti).

CSS dei blocchi grafici: `.stat-detail-charts` = grid 2 colonne gap 0.85rem (1 colonna su mobile); `.stat-detail-chart-block` = bg `#fafbfc`, bordo `#e8eaed`, radius 14px, `h4` 0.68rem uppercase `#6b7280`.

### 8.9 Report settimanale e report fiscale (export XLSX — SheetJS `xlsx@0.18.5` da CDN)

**Banner settimanale** (`#weeklyReportBanner`, sopra le tab in admin.html): mostrato **solo il lunedì** se non dismesso per quella settimana (`checkWeeklyReportBanner`). Chiave localStorage: **`weeklyReportDismissed_{YYYY-MM-DD del lunedì precedente}`** = `'true'`. Testi: **`Report settimanale disponibile`** + `#weeklyReportPeriod` = `Pagamenti report fiscale: {gg/mm/aaaa} – {gg/mm/aaaa}` (lunedì→domenica della settimana precedente, `_getPreviousWeekRange()`); bottoni **`📥 Scarica report`** (`downloadWeeklyReport()`) e `✕` (`dismissWeeklyReport()`). CSS: gradiente blu `#1e40af→#2563eb`, radius 12px, testo bianco, bottone bianco testo `#1e40af`.

**`downloadWeeklyReport()`**: bottone → `⏳ Generazione...`; `UserStorage.syncUsersFromSupabase()`; `_fetchPayments(fromStr, toStr)` della settimana precedente; filtra `REPORT_METHODS = {'carta','iban','stripe','contanti-report'}` e `amount > 0`; per ogni riga risolve il profilo per email (CF + indirizzo). Colonne XLSX (esatte): `Nome, Cognome, Codice Fiscale, Indirizzo, Data e Ora Pagamento, Tipo di Pagamento, Metodo Pagamento, Importo (€)`; label tipo: `Sessione/Abbonamento/Pacchetto/Mora/Rettifica`; label metodo: `Carta/Bonifico/Stripe/Contanti con Report`; larghezze colonne `[18,20,20,35,22,22,18,12]`; sheet `Pagamenti Report Fiscale`; filename **`TB_Report_Fiscale_{gg-mm-aaaa}_{gg-mm-aaaa}.xlsx`**; ordinamento per data crescente. Successo: dismisse il banner + toast `Report scaricato: {N} pagamenti fiscali`; errore: `Errore durante la generazione del report`.

**`downloadFiscalReport()`** (bottone `#fiscalReportBtn` = `🧾 Report fiscale completo`, nel tab Impostazioni, `admin-settings.js`): prima un `showConfirm` — titolo `Scarica report fiscale completo`, messaggio `Verrà generato un report con l'intero archivio dei pagamenti tracciati fiscalmente. L'operazione può richiedere tempo e traffico dati. Procedere?`, conferma `Scarica` (gate anti-tap per l'egress). Poi identico al settimanale ma con `_fetchPayments(null, null)` (TUTTO il ledger); filename `TB_Report_Fiscale_{gg-mm-aaaa}.xlsx` (data odierna); toast `Report fiscale scaricato: {N} pagamenti fiscali` / `Errore durante la generazione del report fiscale`.

**Report mensile AI**: la edge function `generate-monthly-report` (Anthropic) NON fa parte del tab Analytics admin — è usata dall'area cliente allenamento (`js/allenamento-report.js`, URL `.../functions/v1/generate-monthly-report`) per il report PDF dei progressi. Nel tab Statistiche non esiste alcun trigger/UI AI: non replicarlo qui.

### 8.10 Modali secondarie definite in admin-analytics.js (usate dal tab Clienti)

Per completezza (il codice vive in questo file ma la UI è nelle card cliente): `openCertModal/saveCertDate/closeCertModal` (modal `🏥 Certificato Medico`, input date, bottoni `Annulla`/`Salva`, toast `Certificato medico aggiornato.`, aggiorna `profiles.medical_cert_expiry` + history locale) e `openAssicModal/saveAssicDate` (modal `📋 Assicurazione`, `profiles.insurance_expiry`, toast `Assicurazione aggiornata.`, badge con soglia 30 giorni `⏳ Assic. scade il …`). Non fanno parte del tab Analytics in senso stretto.

### 8.11 Riepilogo funzioni, stato e chiavi cache

- **Stato modulo**: `currentFilter`, `customFilterFrom/To`, `_statsBookings`, `_statsCacheRange`, `_statsPayments`, `_statsPaymentsRange`, `_loadDashboardSeq`, `_statsLastLoad`, `_currentStatDetail` (null | 'fatturato' | 'prenotazioni' | 'clienti' | 'occupancy'), `_fatturatoMode` ('prenotazioni' | 'reale'), `_filterSwitching`.
- **Funzioni JS esatte**: `getFilterDateRange`, `getPreviousFilterDateRange`, `getFilteredBookings`, `getFilterLabel`, `getPreviousFilterLabel`, `setAnalyticsFilter`, `applyCustomFilter`, `updateNonChartData`, `_renderDashboardUI`, `_setStatCardsLoading`, `loadDashboardData`, `updateStatsCards`, `drawBookingsChart`, `countGroupClassSlots`, `drawTypeChart`, `updateBookingsTable`, `updatePopularTimes`, `switchFatturatoMode`, `toggleStatDetail`, `renderFatturatoDetail`, `renderPrenotazioniDetail`, `renderClientiDetail`, `renderOccupancyDetail`, `_statsIdentity`, `_statsPersistKey`, `_persistStatsCache`, `_hydrateStatsCache`, `_clearPersistedStatsCache`, `invalidateStatsCache`, `_fetchPayments`, `_getPreviousWeekRange`, `_weeklyReportKey`, `checkWeeklyReportBanner`, `dismissWeeklyReport`, `downloadWeeklyReport`, `downloadFiscalReport`, `ensureClientDataForCardPayment`, `saveMissingData`, `closeMissingDataPopup`.
- **Chiavi localStorage/sessionStorage**: `gym_stats_cache_v1:{admin|userId}` (snapshot bookings, TTL 90s, cap 6000 righe), `dataLastCleared` (marker invalidazione), `weeklyReportDismissed_{YYYY-MM-DD}`, `adminSensitiveHidden`, `sessionStorage.adminAuth`; prezzi org via `OrgSettings` (namespace `org_<id>_<key>`, chiavi `billing_client.prices`, `price.<slotType>`).
- **Realtime**: nessuna subscription nel tab; refresh = cambio filtro, switch tab, `visibilitychange` >5 min, invalidazione post-mutazione.

---

# Specifica migrazione Flutter — Sezioni 9-10: Schede allenamento e Importa

> Fonte: `js/admin-schede.js` (3647 righe), `js/admin-importa.js` (586 righe), `admin.html`, `js/data.js` (WorkoutPlanStorage, WorkoutLogStorage, fetchAllPaginated), `js/entitlements.js`, `css/admin.css`, `css/allenamento.css`, baseline SQL + migration `00000000000001_operational_rpcs.sql`, `00000000000015_monthly_reports_schema.sql`.

## 9. Tab Schede (allenamento)

### 9.1 Ingresso, gating feature-flag e shell

- **Bottone tab** (navbar admin): `<button class="admin-tab" data-tab="schede" id="adminTabSchede" data-feature="workout_plans">🏋🏻 Schede</button>`.
- **Pannello**: `<div id="tab-schede" class="tab-content" data-feature="workout_plans"><div class="dashboard-card" id="schedeContainer"><div class="schede-loading">Caricamento schede...</div></div></div>`.
- **Feature gating** (`js/entitlements.js`, `applyFeatureGating`): il flag `workout_plans` viene da `plans.features` (jsonb) del piano SaaS. Tutti e 3 i piani seed (`starter`, `pro`, `business`) hanno `"workout_plans": true`. Se il flag manca: il bottone tab resta visibile ma `disabled` + classe `ent-locked` (opacity .55, cursor not-allowed) + badge figlio `.ent-upgrade-badge` con testo esatto **"🔒 Piano superiore"** (title "Disponibile nel piano superiore"; stile: font 10px/600, colore `#92400e`, bg `#fef3c7`, border `1px solid #fde68a`, radius 999px, padding 1px 6px, margin-left 6px); i contenuti `[data-feature]` non-tab vengono nascosti con `display:none`.
- **Trigger render**: `switchTab('schede')` in `admin.js` chiama `renderSchedeTab()` (via `setTimeout(loader, 0)`). Retro-compatibilità: `switchTab('importa')` viene rimappato a `schede` + `_schedeSwitchSection('importa')`. Anche `admin.html` migra `sessionStorage.adminActiveTab === 'importa'` → `'schede'` + `adminSchedeSection='importa'`. Al `visibilitychange` (wake) se il tab attivo è schede viene richiamato `renderSchedeTab()`.
- **Shell** (`_schedeRenderShell`): subnav a 4 pill con testi esatti **"Live"**, **"Schede"**, **"Clienti"**, **"Importa"** (`.schede-subnav-pill`, attiva = colore `#7C3AED` + border-bottom 2px `#8B5CF6`; inattive `#64748b`, font 0.82rem/700) + `<div id="schedeInner">`. Il wrapper `#schedeContainer.dashboard-card` è reso trasparente (bg transparent, no padding/shadow).
- **Stato/routing interno**:
  - `_schedeSection` ∈ `'actual' | 'schede' | 'clienti' | 'importa'` — persistito in `sessionStorage['adminSchedeSection']` (default `'actual'`).
  - `_schedeView` ∈ `'list' | 'edit' | 'progress' | 'clients' | 'client-detail'`.
  - `_schedeSwitchSection(section)` resetta `_schedeView` (`'clients'` per clienti, `'list'` altrove), azzera `_schedeClientUserId` e i circuit-breaker dell'Actual, salva sessionStorage e re-renderizza.

### 9.2 `renderSchedeTab()` — orchestrazione, cache e timeout

Funzione entry-point con lock anti-concorrenza (`_schedeRendering` + `_schedeRenderQueued`: se già in render, accoda un solo re-render). Flusso:

1. Idrata `WorkoutPlanStorage._loadFromLocalStorage(true)` se cache RAM vuota (chiave LS `workout_plans_cache_admin_v1`, TTL 30 min) → render immediato dell'ultima lista nota.
2. Render shell subito (mai loader bloccante).
3. Se sezione `importa`: stop auto-refresh Actual, inietta `<div class="dashboard-card" id="importaContainer"><div class="importa-loading">Caricamento catalogo esercizi...</div></div>` e delega a `renderImportaTab()` (vedi §10). Return.
4. **Catalogo esercizi** (`_loadExercisesDB`): bloccante SOLO in vista `edit` (timeout di sicurezza `_SCHEDE_EXDB_TIMEOUT_MS = 35000` ms via `_schedeWithTimeout`); nelle altre viste fire-and-forget in background.
5. **Sync piani**: `_schedeStartWorkoutPlansSync()` in background se `Date.now() - _schedeLastSync > _SCHEDE_SYNC_INTERVAL (10000 ms)`; wrappato con timeout `_SCHEDE_SYNC_TIMEOUT_MS = 35000`; con cache vuota fa re-render a fine sync (`rerenderOnDone`).
6. Dispatch: `edit` → `_renderPlanEditor`; `progress` → `_renderProgressView`; sezione `clienti` → `_renderClientDetail` o `_renderClientsList`; sezione `actual` → `_renderActualView` + `_schedeActualStartAutoRefresh()` (interval 60 s); default → `_renderSchedeList`.
7. Errore: `'Errore caricamento schede. Cambia tab e riprova.'` in `.empty-slot`.

**Catalogo esercizi in RAM** (`EXERCISES_DB`, `EXERCISES_BY_CAT`, `EXERCISE_CATEGORIES`): caricato da `_loadExercisesDB()` con priorità: (1) cache in-memory del tab Importa (`_importaImported`), (2) localStorage `schede_exercises_db_v1` `{ts, data}` TTL **6 ore**, (3) fetch paginato Supabase:

```js
fetchAllPaginated(() => supabaseClient
    .from('imported_exercises')
    .select('slug, nome_it, nome_original, nome_en, categoria, immagine, immagine_thumbnail, video, popolarita')
    .order('categoria').order('nome_it'), { timeoutMs: 30000 })
```

`fetchAllPaginated` (data.js:130) scarica a batch da 1000 con `.range(from, from+999)` finché esaurisce (max 500k righe). Ogni riga viene mappata in `{nome_it, nome_original, nome_en, categoria, slug, immagine_url, immagine_url_small (= immagine_thumbnail||immagine), video_url, popolarita}`. `_refreshSchedeFromImported()` invalida flag + rimuove la chiave LS e ricarica (chiamata dal tab Importa dopo add/remove/rename). Le **immagini/video sono URL diretti esterni** (`https://apilyfta.com/static/GymvisualPNG/...png|_small.png`, `.../GymvisualMP4/...mp4`) — **NON passano dall'edge `image-proxy`**.

**WorkoutPlanStorage** (data.js:2757): cache array di piani con `workout_exercises` annidati.
- `syncFromSupabase({adminMode:true})`: `from('workout_plans').select('*, workout_exercises(*)').order('updated_at', {ascending:false})`, timeout 30 s, TTL di rete 5 min (`_NET_TTL_MS`), dedup in-flight per modo; ordina gli esercizi per `sort_order`; persiste su LS (`workout_plans_cache_admin_v1`, TTL 30 min).
- CRUD (tutte con `_queryWithTimeout(…, 15000)`): `createPlan({user_id,name,start_date,end_date,notes})` (insert + `active:true`), `updatePlan(planId, updates)`, `deletePlan(planId)`, `addExercise(planId, data)` (se `sort_order` mancante legge il max reale dal DB con select `sort_order` desc limit 1), `updateExercise(exerciseId, updates)`, `deleteExercise(exerciseId)`, `reorderExercises(planId, orderedIds)` (riscrive `sort_order` partendo dal minimo del gruppo, un UPDATE per id, sequenziale), `addSuperset(planId, ex1, ex2)` (stesso `superset_group = crypto.randomUUID()`; il 1° con `rest_seconds:0`), `addCircuit(planId, items[])` (≥2 elementi, stesso `circuit_group` UUID), `duplicatePlan(planId, newUserId, newName)` → **RPC `admin_duplicate_plan(p_plan_id uuid, p_new_user_id uuid, p_new_name text default null)`** (SECURITY DEFINER, verifica `is_org_admin`, copia piano+esercizi inclusi `circuit_group/superset_group/exercise_slug`, ritorna uuid nuovo piano) seguita da re-sync.
- `clearCache()` al logout (svuota RAM + entrambe le chiavi LS).

**Schema DB** (baseline): `workout_plans(id, org_id default current_org_id(), user_id, name, start_date, end_date, notes, active bool default true, created_at, updated_at)`; `workout_exercises(id, org_id, plan_id, day_label default 'Giorno A', exercise_name, exercise_slug, muscle_group, sort_order int default 0, sets int default 3, reps text default '10', weight_kg numeric(6,1), rest_seconds int default 90, superset_group uuid, circuit_group uuid, notes)`; `workout_logs(id, org_id, exercise_id, user_id, log_date date, set_number, reps_done, weight_done numeric(6,1), rest_done, rpe 1-10, notes, created_at, UNIQUE(exercise_id,user_id,log_date,set_number))`. RLS org-scoped ovunque.

**Clienti assegnabili**: `_schedeGetRegisteredUsers()` = `UserStorage.getAll().filter(u => u.userId)` (solo profili registrati con UUID; campi usati: `userId`, `name`, `email`).

**Realtime**: nessuna subscription in questo tab; l'aggiornamento è TTL-based + auto-refresh 60 s della vista Live.

**Shell iOS allenamento (port 2026-07-04)**: tocca solo il client (`allenamento.html`); nell'admin l'unico riflesso è in `admin.js` `switchTab` (`window.scrollTo` + `document.body.scrollTo` per il dual-scroller). Nessun impatto sul tab Schede.

### 9.3 Sub-sezione "Live" (Actual) — carosello slot precedente/attuale/successivo

`_renderActualView(container)` renderizza un carosello di 3 card (`.schede-actual-carousel > .schede-actual-track > .schede-actual-slot--prev|--current|--next` + `.sa-dots` a 3 puntini, visibili solo mobile).

- **Selezione slot** (`_schedeActualPickSlots`): fasce orarie org-aware da `getTimeSlots()` (formato `"HH:MM - HH:MM"`, parse con `_schedeActualParseSlot`). currentIdx = slot che contiene l'ora attuale; prev/next adiacenti; prima del primo slot → solo next=0; dopo l'ultimo → solo prev=ultimo.
- **Card slot** (`_schedeActualRenderSlot(position, slotIdx, ctx)`), hero scuro + body bianco:
  - Pill posizione: `CONCLUSO` (prev, bg `rgba(255,255,255,0.12)` testo `#cbd5e1`), **`LIVE`** (current, bg `#dc2626` bianco + pallino `.sa-pulse` animato 1.6s), `PROSSIMO` (next, bg `rgba(124,58,237,0.3)` testo `#ddd6fe`). Font 0.66rem/800.
  - Slot vuoto: messaggi esatti `'Nessuno slot prima'` / `'Nessuno slot attivo'` / `'Giornata terminata'`.
  - Capienza `.sa-cap`: `"{n} / {cap} posti"` — `cap = BookingStorage.getEffectiveCapacity(oggi, slotTime, slotType)`; prenotazioni da `BookingStorage.getBookingsForSlot(oggi, slotTime)` filtrate `status !== 'cancelled'` e id non `_avail_*`.
  - Orari: `.sa-time-now` (inizio, 1.85rem/800) + `.sa-time-end` `"→ {fine}"` (0.85rem, `#94a3b8`).
  - Tag tipo slot `.sa-type`: label da `getSlotName(type)` (fallback `SLOT_NAMES`), tipo risolto da `_schedeActualSlotTypeForDate` (prima `BookingStorage.getScheduleOverrides()[data]`, poi `getWeeklySchedule(data)[nomeGiorno]`). Solo per lo slot LIVE il tag è colorato inline col colore org `getSlotColor(type)`: `background: hexToRgba(color, 0.18); color: {color}; border-color: hexToRgba(color, 0.4)`. Prev/next restano muti (grigio/viola da CSS).
  - Progress bar `.sa-progress` (6px, bg `rgba(255,255,255,0.1)`; fill gradient `#8B5CF6→#86efac`, prev `#94a3b8`, next `rgba(221,214,254,0.6)`): 100% se concluso, % tempo trascorso se LIVE, 0% se futuro. Footer 3 voci: inizio · testo centrale · fine; testo centrale: `'completato'` | `"{elapsed} min · {pct}%"` | `"tra {N}h"` / `"tra {N} min"` / `'in arrivo'`.
  - **Hero gradients**: current `linear-gradient(160deg, #0b1220 0%, #1e1b4b 65%, #5b21b6 130%)` + cerchio radiale viola `rgba(139,92,246,0.4)`; prev `linear-gradient(160deg,#1f2937,#374151)` (card opacity 0.88); next `linear-gradient(160deg,#0e1f33,#312e81)`. Border-radius card 18px.
- **Lista persone** `.sa-people` (in tutte e 3 le card): per ogni booking un bottone `.sa-person` con:
  - Avatar iniziali `.sa-av` (36px, colore stabile hash del nome, palette: blue `#dbeafe/#1d4ed8`, green `#dcfce7/#166534`, amber `#fef3c7/#b45309`, purple `#ede9fe/#6d28d9`, pink `#fce7f3/#be185d`; `_saInitials` = prima lettera primo+ultimo nome).
  - Nome (0.92rem/700, ellipsis). Guest senza `userId`: `disabled`, corsivo, title `"Cliente senza profilo registrato"`.
  - **Marcatore no-plan**: se lo user non ha nessun piano `active` → classe `.sa-person--no-plan` (bg `#fef2f2`, border `#fecaca`, testo `#991b1b`), sotto il nome meta rossa `"Nessuna scheda attiva"`, title `"Nessuna scheda attiva assegnata"`.
  - **Badge log V/X** (solo prev/current): `...` (title `'Verifica log in corso'`) finché il fetch non è pronto; poi `✓` verde (`.sa-status--ok`, `#dcfce7/#15803d`, title `'Ha registrato log oggi'`) o `✗` rosso (`.sa-status--ko`, `#fef2f2/#b91c1c`, title `'Nessun log registrato oggi'`). Dati: `supabaseClient.from('workout_logs').select('user_id').eq('log_date', oggi)` → Set di user_id (`_schedeActualFetchLoggedToday`).
  - **Badge report 📊** (solo prev/current, se presente): title `'Ha generato il report del mese scorso'`. Dati: `from('monthly_reports').select('user_id').eq('year_month', YYYY-MM del mese precedente)` (`_schedeActualFetchReportsLastMonth`).
  - Chevron `›` a destra (solo registrati). Click → `_schedeActualOpenClientPopup(uid, name)`.
- **Caching/backoff dei 2 fetch di stato**: TTL 60 s (`_SCHEDE_ACTUAL_STATUS_TTL_MS`), min-retry 5 s, backoff esponenziale `5s·2^failures` cap 5 min, **circuit breaker a 5 fallimenti consecutivi** (`_SCHEDE_ACTUAL_STATUS_MAX_FAILURES`); reset del breaker quando l'utente rientra sulla sezione. A fetch riuscito re-render se ancora su Actual.
- **Auto-refresh**: `setInterval` 60 s (`_schedeActualStartAutoRefresh`), fermato uscendo dalla sezione.
- **Carosello mobile** (≤780px): track flex `overflow-x:auto` con `scroll-snap-type: x mandatory`, card `flex: 0 0 100%`; al primo render scrollLeft centrato sullo slot LIVE; listener scroll sincronizza i `.sa-dots` (attivo = 18px pill viola `#8B5CF6`). Desktop: grid 3 colonne gap 0.85rem.

#### 9.3.1 Popup cliente (Live) — testi ESATTI

`_schedeActualOpenClientPopup(userId, name)` → overlay `#schedeActualPopupOverlay` (`.schede-actual-popup-overlay`, bg `rgba(15,23,42,0.55)` + blur 4px; chiusura: click fuori, X, tasto Escape via `_schedeActualPopupKeyHandler`). Card 440px max, radius 18px:

- Header: eyebrow **"Cliente"** (0.7rem uppercase `#94a3b8`), titolo = nome cliente (1.2rem/800), bottone chiusura X (SVG).
- 3 azioni `.schede-actual-popup-btn` (icona 44px in gradiente `#f5f3ff→#ede9fe` + titolo + sottotitolo + chevron `›`):
  1. **📊 "Carichi"** — sub: **"Grafici e log delle sessioni precedenti"** → `_schedeActualPickCarichi`: apre client-detail tab `progressi`.
  2. **📅 "Report"** — sub: **"Report AI mensili generati dal cliente"** → `_schedeActualPickReport`: client-detail tab `report`.
  3. **📝 "Scheda"** — sub dinamico: `'Nessuna scheda attiva'` (bottone disabilitato) | nome dell'unica scheda attiva | `"{N} schede attive"` → `_schedeActualPickScheda`: se 1 sola attiva apre direttamente l'editor (`_schedeEditPlan`), altrimenti client-detail tab `schede`.
- Se nessuna scheda attiva, accanto compare il bottone verde **"+ Aggiungi"** (`.schede-actual-popup-add`, gradient `#22c55e→#16a34a`, title `"Crea nuova scheda per {name}"`) → `_schedeActualAddPlan`: `showPrompt("Nome della nuova scheda per {clientName}:", '', {confirmText:'Crea'})`; vuoto → toast `'Nome scheda richiesto'`; altrimenti imposta `_schedePendingNewPlanPrefill = {userId, clientName, planName}` e apre l'editor in modalità nuova scheda (giorno iniziale `'Giorno A'`).

### 9.4 Sub-sezione "Schede" (lista template) — `_renderSchedeList`

Mostra SOLO i **template** (piani con `user_id == null`):

- **Barra assegnazione** (solo se esistono template; `.schede-assign-bar--schede`, gradient verde `#ecfdf5→#d1fae5`, border `#a7f3d0`): label uppercase **"Template"** con `<select id="schedeQuickTemplate">` — prima option **"— Seleziona template —"**, poi `"{nome} ({N} es. · {M} gg)"`; label **"Cliente"** con input `#schedeQuickClientSearch` placeholder **"Cerca cliente..."** + dropdown `#schedeQuickClientDropdown` (ricerca debounced 150 ms su nome/email, max 10 risultati, vuoto → `'Nessun cliente trovato'`); bottone **"Assegna"** → `_schedeQuickAssign()`: valida (toast `'Seleziona un template'` / `'Seleziona un cliente'`), `WorkoutPlanStorage.duplicatePlan(templateId, userId)`, toast `'Scheda assegnata!'` o `'Errore assegnazione'`.
- Titolo sezione **"Template standard"** (`.schede-section-title`, con riga sfumata a destra). Vuoto: `'Nessun template. Crea una scheda senza selezionare un cliente.'`
- Card template `.schede-plan-card` (bg bianco, border-left 5px `#8B5CF6`, radius 14px): badge **"Template"** (`.schede-badge-template`, gradient `#0c4a6e→#0369a1`, testo `#e0f2fe`, uppercase), nome, meta `"{N} esercizi · {M} giorni"`; azioni: matita (title/aria **"Modifica"**, colore `#f59e0b`) → `_schedeEditPlan(id)`; cestino (title **"Elimina"**, `#64748b`) → `_schedeDeletePlan(id)` con `showConfirm('Eliminare questa scheda e tutti gli esercizi associati?')`, toast `'Scheda eliminata'`/`'Errore eliminazione'`.
- **FAB** `.schede-fab` "+" fisso in basso a destra (56px, cerchio `#8B5CF6`, shadow `0 4px 14px rgba(139,92,246,0.35)`, aria/title **"Nuova scheda"**) → `_schedeNewPlan()` (editor vuoto, giorno `'Giorno A'`).

Esistono anche `_schedeAssignTemplate(userId)` (variante legacy con select `#schedeAssignTemplate`) e `_schedeDuplicatePlan(planId)` (prompt `'Duplicare per quale cliente? (nome)'`, confirm `'Duplica'`, match per nome/email, errore `'Cliente registrato non trovato'`, toast `'Scheda duplicata'`/`'Errore duplicazione'`).

### 9.5 Sub-sezione "Clienti" — `_renderClientsList`

- Barra ricerca `#schedeClientFilterInput` placeholder **"Filtra clienti..."** — filtro client-side su `data-client` (`_schedeFilterClientCards`, mostra/nasconde le card).
- Mostra **tutti** i clienti registrati ordinati per nome (anche senza schede). Vuoto: `'Nessun cliente registrato.'`
- Card cliente `.schede-cc-card` (bianca, radius 14px, padding 12px, click → `_schedeOpenClientDetail(uid)`):
  - Avatar 42px `.schede-cc-av` con iniziali, 5 classi colore `c1..c5` per hash nome (`c1 #ede9fe/#6d28d9`, `c2 #fef3c7/#b45309`, `c3 #e0e7ff/#4338ca`, `c4 #fce7f3/#be185d`, `c5 #dcfce7/#166534`).
  - Nome (14.5px/800) + **pill stato** in alto a destra (`.schede-cc-pill`, 10.5px/800 con dot): verde `#dcfce7/#166534` con **"Attiva"** (1 attiva) o **"{N} attive"**; grigia (`.gray`, `#f1f5f9/#64748b`) con **"Nessuna attiva"** (ha schede ma nessuna attiva) o **"Senza scheda"** (nessuna scheda).
  - Sottotitolo: `"{nome scheda attiva} · {N} giorno/giorni"` (1 attiva; giorni = `day_label` distinti delle attive) | `"{N} giorni"` o `'più schede attive'` (multi) | `'Nessuna scheda attiva'` | `'Nessuna scheda assegnata'` (muted).
  - Stats inline con icone SVG: `"{N} scheda/schede"` e `"{N} esercizio/esercizi"` (totale su tutte le schede).

### 9.6 Client detail — `_renderClientDetail` (tab Progressi / Schede / Report)

Shell: breadcrumb `.schede-cd-bread` (bottone back **"Clienti"** con chevron ← → `_schedeView='clients'`; separatore "/"; nome corrente), titolo H2 col nome, 3 **pill-tab** `.schede-cd-pill` (colonna icona SVG + label + counter; attiva = gradiente `#8B5CF6→#7C3AED` testo bianco):

- **"Progressi"** — counter `#schedeCdCtProgressi`: `'—'` → poi `'Nessuna'` | `'1 sess.'` | `"{N} sess."` (sessioni = Set di `exercise_id+'|'+log_date`).
- **"Schede"** — counter immediato: `'Nessuna'` | `'Nessuna attiva'` | `'1 attiva'` | `"{N} attive"`.
- **"Report"** — counter `#schedeCdCtReport`: `'—'` → `'Nessuno'` | `'1 mensile'` | `"{N} mensili"`.

Switch tab: `_schedeClientSwitchTab(tab)`; stato `_schedeClientDetailTab` ∈ `'progressi'|'schede'|'report'` (default `'schede'` dalla lista Clienti; il popup Live imposta il tab pertinente).

**Fetch log condiviso** `_schedeClientDetailLoadLogs(userId, plans)`: cache per-utente `_schedeLogsCacheByUser` (TTL 60 s) + dedup in-flight; query paginata:

```js
fetchAllPaginated(() => supabaseClient
    .from('workout_logs')
    .select('exercise_id, log_date, weight_done, reps_done')
    .in('exercise_id', allExIds)         // tutti gli esercizi di tutte le schede del cliente
    .order('log_date', { ascending: true })
    .order('id'))                        // tiebreaker per pagine stabili
```

Ritorna `null` in caso di errore (distinto da `[]` = vuoto). La paginazione esiste perché c'è **una riga per serie** e il cap PostgREST è ~1000 righe.

#### 9.6.1 Tab "Schede" (`_schedeClientRenderSchede` / `_schedeBuildClientSchedeHtml`)

Render NON bloccante: prima le card senza date-range, poi arricchimento quando arrivano i log. Titolo **"Schede assegnate"**; vuoto: `'Nessuna scheda assegnata a questo cliente.'` Card `.schede-cd-plancard` (border-left 3px: verde `#16a34a` se attiva, grigio `#94a3b8` se no):

- Nome piano + meta: `"{N} esercizio/esercizi"` e (se log) date-range `"{gg mmm} → {gg mmm}"` (`_fmtDate` = `toLocaleDateString('it-IT', {day:'2-digit', month:'short'})`).
- Badge stato `.schede-cd-statepill`: **"Attiva"** (green `#dcfce7/#166534`) / **"Inattiva"** (gray `#f1f5f9/#475569`).
- Se sessioni > 0: progress bar (5px, fill gradiente `#16a34a→#86efac`) con **euristica `pct = min(100, round(sessioni·100/12))`** e riga `"{N} sessione/sessioni"` + `"{pct}%"`.
- Azioni: bottone primario **"Apri"** (gradiente viola) → `_schedeEditPlan(id)`; icona salva (title **"Salva come template"**) → `_schedeSaveAsTemplate(id, nome)`: `showPrompt('Nome del template:', nome, {confirmText:'Salva template'})` → `duplicatePlan(planId, null, tplName)`, toast `'Template creato!'`/`'Errore creazione template'`; icona cestino rossa (title **"Elimina"**) → `_schedeDeletePlanFromDetail(id)`: confirm `'Eliminare questa scheda e tutti gli esercizi associati?'`, resta sul detail.

#### 9.6.2 Tab "Progressi" (`_schedeClientRenderProgressi`)

Loader `'Caricamento progressi...'`; errore → `'Errore caricamento log. Riprova.'`; vuoto → `'Nessun log registrato da questo cliente.'`

- **3 stat card** `.schede-stats-grid`: 📊 valore=N sessioni label **"Sessioni"**; 🏋️ valore=N righe log label **"Serie totali"**; 📈 volume=Σ(weight_done·reps_done) label **"Volume"** (formato `"{x.x}t"` se ≥1000 altrimenti `"{N}kg"`).
- **Una chart-card per esercizio** (`.schede-admin-chart-card`, ordinati per nome): immagine 100×100 (thumbnail dal catalogo via `_findExercise(nome)`; placeholder 🏋️) + header (nome + badge gruppo muscolare `.schede-badge-active.schede-badge-sm`) + `<canvas>` 400×140 + stats `"Max {N}kg"`, `"Ultimo {N}kg"`, `"Trend {±N.N}kg"` (classe `.schede-trend-up` verde / `.schede-trend-down`), `"{N} sessioni"`.
- Serie del grafico: per ogni sessione (`exercise_id|log_date`) il **peso massimo**; ordinamento per data; trend = ultimo − primo.
- **`_drawAdminChart(canvas, labels, values)`** (canvas 2D, scala 2×, h=150): bg `#f8fafc` con angoli 10px; padding `{top:22, right:14, bottom:30, left:42}`; 4 gridline tratteggiate `#e2e8f0` (dash 3,3) con etichette Y `#94a3b8` 8.5px; area riempita con gradiente verticale `rgba(0,174,239,0.22) → 0.08 → 0.01`; linea `#00AEEF` spessore 2.8 round; punti bianchi bordati `#00AEEF` r=3 (ultimo: pieno `#00AEEF` r=4.5 + alone `rgba(0,174,239,0.2)` r=7); etichette X ogni `max(1, floor(n/6))` a 7.5px; badge valore sull'ultimo punto: rettangolo arrotondato `#0f172a` con testo bianco bold 9.5px `"{val}kg"`.

#### 9.6.3 Tab "Report" (`_schedeClientRenderReport` → `_schedeRenderReportsSection`)

Sola lettura dei report AI mensili generati dal cliente. Fetch (`_schedeFetchClientReports`, cache 60 s per userId, timeout 15 s):

```js
supabaseClient.from('monthly_reports')
    .select('id, user_id, year_month, goal, tone, narrative, generated_at, status')
    .eq('user_id', userId).eq('status', 'generated')
    .order('year_month', { ascending: false })
    .order('generated_at', { ascending: false })
```

- Vuoto: titolo **"Report Mensili"** + `'Nessun report generato da questo cliente.'`
- Con dati: titolo "Report Mensili" + counter pill `.schede-section-count` (bg `#ede9fe`, testo `#6D28D9`); raggruppati per mese (label uppercase `"Luglio 2026"` via `_schedeFormatYearMonth` con mesi italiani); item `.schede-report-item` = icona obiettivo + titolo mese + meta `"{label obiettivo} · generato {gg/mm/aaaa}"` + chevron.
- **Mappa obiettivi** `_SCHEDE_REPORT_GOALS`: `dimagrimento` 🔥 "Dimagrimento", `massa` 💪 "Aumento Massa", `tonificazione` ✨ "Tonificazione", `forza` 🏋️ "Forza", `salute` ❤️ "Salute", `recupero` 🧘 "Recupero". **Toni legacy** `_SCHEDE_REPORT_TONES` (report vecchi con solo `tone`): `serious` 🎯 "Serio", `motivational` 💪 "Motivazionale", `ironic` 😏 "Ironico". Fallback: `{label: goal||tone||'—', icon:'📝'}`.
- **Modal report** (`_schedeOpenReportModal`, overlay `#schedeReportModalOverlay`, z 10001, max-width 720px, max-height 85vh, Escape/click-fuori per chiudere): head con eyebrow **"Report {Mese Anno}"** e riga `"{icon} {label} · {gg mmm aaaa}"`; body = markdown convertito in HTML da `_schedeReportMarkdownToHtml` (regex per `#`/`##`/`###` → h2/h3/h4, `**bold**`, `*italic*`, paragrafi su doppio newline); vuoto: `<p><em>Report vuoto.</em></p>`.
- Nota schema: la baseline aveva `month/content`; la migration `00000000000015_monthly_reports_schema.sql` rinomina `month → year_month` e aggiunge `narrative, goal, status, generated_at, scorecard, model_used, tokens, cost_usd`.

#### 9.6.4 Report PDF — NON presente

Nel tab Schede admin **non c'è generazione PDF**: i "report" sono gli AI mensili sopra (testo). jsPDF è usato solo in `admin-analytics.js` (fuori scope di questa sezione). Il dev Flutter non deve implementare alcun PDF qui.

### 9.7 Editor scheda — desktop (`_renderPlanEditorDesktop`)

Dispatch: `_renderPlanEditor` → mobile se `matchMedia('(max-width: 767px)')` (`_isAdmMobile`), altrimenti desktop. Un listener `resize` (debounce 200 ms) re-renderizza solo se si attraversa la soglia e nessun overlay mobile è aperto.

**Topbar dark hero** (`.schede-editor-topbar`: gradiente `linear-gradient(160deg,#0b1220 0%,#0e1f33 65%,#6D28D9 130%)` + radiale viola, radius 18px):
- Bottone back (chevron ←, 34px, `rgba(255,255,255,0.10)`) → `_schedeBackToList()`: **flush autosave** poi torna a client-detail (se si veniva da lì) o lista/clients.
- Eyebrow **"Nuova scheda"** / **"Modifica scheda"** (9.5px uppercase `#8B5CF6`) + nome scheda (16px/800 bianco; default `'Senza nome'`).
- **Toggle attiva/inattiva** `#schedePlanActive` (`.schede-toggle`, 46×26px, checked = gradiente viola; title "Attiva"/"Inattiva") — `onchange` → `_schedeAutoSavePlanNow()`.

**Form** (card bianca `.schede-editor-form--compact`):
- Campo **"Nome"** `#schedePlanName` placeholder **"es. Scheda Forza"** — `oninput` autosave debounced 600 ms (`_schedeAutoSavePlan`), `onblur` flush.
- Campo **"Cliente"** `#schedeClientSearch` placeholder **"Template..."** (mobile: **"Template (lascia vuoto)"**) con dropdown `#schedeClientDropdown`: ricerca `_schedeSearchClient` debounced 150 ms su nome/email, max 10; vuoto → `'Nessun cliente registrato trovato'`; selezione (`_schedeSelectClient`) scrive `dataset.userId` e flusha l'autosave. Cliente vuoto/invalid (`length < 10` o `'undefined'`) ⇒ **template** (`user_id = null`). Nascosto se scheda esistente senza cliente.
- `<details>` **"Note"** `#schedePlanNotes` (aperto se già presenti) placeholder **"Note generali..."** — autosave.

**Autosave** (`_schedeAutoSavePlanNow`): se `_editingPlan` → `updatePlan(id, {user_id, active, notes, name?})` (non azzera mai il nome); se nuova e nome non vuoto → `createPlan(...)` e aggancia `_editingPlan/_currentPlanId`. Errore → toast `'Errore salvataggio'`. Esiste anche `_schedeSavePlan()` (path esplicito usato dai bottoni "aggiungi" quando il piano non esiste ancora): valida nome (toast `'Inserisci un nome per la scheda'`), toast `'Scheda aggiornata'` / `'Scheda creata! Aggiungi esercizi.'` / `'Errore salvataggio scheda: {msg}'`.

**Giorni** (`_editDayLabels` derivate dai `day_label` distinti; default `['Giorno A']`):
- Tab pill per giorno (`.schede-day-tab`, attiva = gradiente viola) + bottone **"+"** (`_schedeAddDay`: nome auto `"Giorno {B,C,...}"` da `String.fromCharCode(65+len)`) + **🗑️** (solo se >1 giorno, title **"Rimuovi giorno corrente"**, `_schedeRemoveDay`: elimina su DB tutti gli esercizi del giorno).
- Input rename `#schedeDayRename` placeholder **"Nome giorno"** (`_schedeRenameDay`: aggiorna `day_label` di ogni esercizio via `updateExercise`).

**Lista esercizi del giorno** (`_renderExercisesForDay`): vuoto → `'Nessun esercizio per questo giorno. Clicca "+ Aggiungi esercizio".'` (o `'Salva la scheda, poi aggiungi esercizi.'` se piano non ancora creato). Tre tipi di blocco:

1. **Riga esercizio singolo** = `<details class="schede-exercise-row" data-ex-id>` collassabile:
   - Summary: drag-handle (6 pallini, decorativo su desktop), thumbnail 44px (o placeholder manubrio), nome (14px/800), badge gruppo muscolare `.schede-ex-muscle-badge` (pill viola `rgba(139,92,246,0.10)`/`#7C3AED`, 10px uppercase), spec `"{sets}×{reps} · {kg}kg"` (cardio: `"{reps} min"`; peso mancante `—`), **frecce riordino ▲/▼** (`.schede-ex-move`, 24×18px; title "Sposta su"/"Sposta giù"; disabilitate ai bordi), chevron (ruota 180° da aperto).
   - Body (bg `#fafcfd`): bottone **"✎ Cambia esercizio"** (`.schede-ex-change-cta`, dashed viola, uppercase 11.5px) → apre il picker; bottone **"i"** (title **"Dettaglio"**, solo se esercizio da catalogo) → `_schedeShowExDetail(slug)`; griglia 4 param con label uppercase: **"Serie"** (number 1–20), **"Reps"** (text, placeholder "10"), **"Kg"** (number step 0.5, placeholder "—", vuoto→null), **"Rec."** (number step 15, default 90); cardio → solo **"Min"** (text, placeholder "20"); input note placeholder **"Note esercizio..."**; bottone **"Rimuovi"** (`.schede-ex-delete-btn`, outline rosso) → `_schedeDeleteExercise`.
   - Ogni change → `_schedeUpdateExField(exId, field, value)` → `updateExercise` (guardia M17: `sets` NaN o <1 viene ignorato); errore → toast `'Errore aggiornamento'`.
2. **Blocco Super Serie** `.schede-ss-block` (border 2px `#f59e0b`, bg gradiente `#fffbeb→#fff`): badge flottante **"SUPER SERIE"** (gradiente `#f59e0b→#f97316`), frecce ▲/▼ a sinistra (`_schedeMoveSuperset`), bottone **"✕ SS"** in alto a destra (title **"Elimina super serie"**, `_schedeDeleteSuperset` = delete dei membri); dentro, le stesse `<details>` per i 2 esercizi (il 1° ha `rest_seconds: 0` — spec regola SS).
3. **Blocco Circuito** `.schede-cc-block` (border 2px `#06b6d4`, bg `#ecfeff→#fff`): badge **"CIRCUITO"** (gradiente `#06b6d4→#0891b2`), frecce (`_schedeMoveCircuit`), **"✕ C"** (title **"Elimina circuito"**, `_schedeDeleteCircuit` con confirm `'Eliminare questo circuito?'`); parametri di gruppo: **"Giri"** (= `sets` sincronizzato su tutti i membri, `_schedeUpdateCircuitRounds`) e **"Pausa giri"** (= `rest_seconds` solo sull'ULTIMO membro per sort_order, `_schedeUpdateCircuitRest`); membri come `<details>` con solo **"Reps"** e **"Kg"** + "×" rosso per membro (title **"Rimuovi dal circuito"**, `_schedeRemoveFromCircuit`: min 2 membri → toast `'Un circuito deve avere almeno 2 esercizi'`; confirm `'Rimuovere questo esercizio dal circuito?'`; se era l'ultimo trasferisce il rest al nuovo ultimo); in fondo **"+ Aggiungi esercizio al circuito"** (`_schedeAddExerciseToCircuit`: sposta il rest dal vecchio ultimo al nuovo, `exercise_name:'Esercizio'`).

**Bottoni aggiunta** (in fondo, 3 CTA dashed): **"Esercizio"** (icona +, viola) → `_schedeAddExerciseRow` (default `'Nuovo esercizio'`, 3×'10'; errore toast `'Errore aggiunta esercizio'`); **"Super Serie"** (icona quadrata "SS" ambra) → `_schedeAddSupersetRow` (`'Esercizio 1'`/`'Esercizio 2'`, 3×'10', rest 90 sul 2°; toast `'Super Serie aggiunta!'`/`'Errore aggiunta super serie'`); **"Circuito"** (icona "C" ciano) → `_schedeAddCircuitRow` (2 placeholder, 3 giri, rest 90 sull'ultimo; toast `'Circuito aggiunto!'`/`'Errore aggiunta circuito'`).

**Riordino a blocchi** (`_schedeBuildDayBlocks`): la lista del giorno è normalizzata in blocchi `single | superset | circuit`; le frecce spostano il blocco intero (un singolo "salta" un'intera SS). Il nuovo ordine → `reorderExercises(planId, blocks.flatMap(b => b.ids))`.

**Refresh editor** (`_schedeRefreshEditor` / `_schedeSyncEditingPlan`): ad ogni mutazione ri-binda `_editingPlan = getPlanById(_currentPlanId)` (la cache può essere stata sostituita da un sync) e re-renderizza; su mobile riapre l'overlay edit attivo (`_admMobReopenActiveEdit`) o lo chiude se l'entità non esiste più.

### 9.8 Picker esercizio (desktop + mobile) — testi ESATTI

`_schedeOpenPicker(exId)` popola `#picker-{exId}` (`.schede-ex-picker-dropdown`): **fullscreen su mobile**, su ≥768px finestra centrata 600×(90vh−10vh) radius 16px border 2px `#8B5CF6` con backdrop `.schede-picker-backdrop` (`rgba(0,0,0,0.4)`, z 10001; dropdown z 10002). Blocca lo scroll body.

- Topbar gradiente viola: titolo **"Seleziona esercizio"** + bottone × (chiude, `_schedeClosePicker`).
- Search: placeholder **"Cerca esercizio..."** (`_schedeFilterPicker`, live su nome_it/nome_en/categoria, lowercase contains).
- **Griglia categorie** (`.schede-picker-cats`, auto-fill minmax 130px): chip per categoria con icona SVG `images/icone_muscoli/{file}.svg`, nome, count esercizi. Mappa categoria→icona: Petto=chest, Tricipiti=triceps, Bicipiti/Braccia=biceps, Spalle=shoulders, Schiena=back, Quadricipiti=quadriceps, "Glutei e Femorali"=hips, Femorali=hamstrings, Polpacci=calves, Addominali=waist_abs, Avambracci=forearms, Cardio=cardio (fallback chest). Click chip (`_schedePickCat`) → lista esercizi della categoria.
- **Lista risultati** (`_schedeRenderExercises`, **max 50 mostrati**): riga = thumbnail 44px + nome + categoria (uppercase) + bottone play ▶ (title **"Video"**, se `video_url`) che apre il dettaglio. Vuota: `'Nessun esercizio trovato'`. Oltre 50: `"{N} altri — affina la ricerca"`.
- Footer: bottone **"✏️ Personalizzato"** (`_schedePickCustom`): svuota nome/slug e mostra input inline placeholder **"Nome personalizzato"** (label corsivo *Personalizzato*); su mobile: `showPrompt('Nome esercizio personalizzato:', '', {confirmText:'Aggiungi'})`.
- **Selezione** (`_schedePickExercise`): update batch `{exercise_name, exercise_slug, muscle_group}`; se categoria Cardio applica default `sets:1, reps:'20', rest_seconds:0`. Chiude e re-renderizza (layout cardio/forza). Id pseudo `'__new_*'` (flusso picker-first mobile) devia su `_admMobCreateExFromPicker`.
- Chiusura per click esterno gestita da listener document-level (contesti validi: `.schede-ex-picker-wrap`, `.schede-picker-backdrop`, `.schede-ex-picker-dropdown`, `.adm-mob-edit-picker-wrap`, `.adm-mob-cc-row`).

**Dettaglio esercizio** (`_schedeShowExDetail(slug)` → overlay `#schedeExDetailOverlay`, z 10003, bg `rgba(0,0,0,0.6)`+blur): header con nome, pill categoria (azzurra `#e0f2fe→#bae6fd`/`#0369a1`), nome inglese in corsivo, ×; media: `<video controls autoplay loop muted playsinline>` (max-height 300px, creato via DOM per affidabilità) oppure immagine.

### 9.9 Editor scheda — mobile (`_renderPlanEditorMobile`, <768px)

Riusa le card del client (`allenamento.css`: variabili `--all-*` esposte anche su `.schede-editor--mobile`; viola `#8B5CF6`, radius 16/12/8px).

- **Topbar hero scura** come desktop + campi dentro l'hero (`.adm-mob-hero-fields`, input glass `rgba(255,255,255,0.08)` bordo `rgba(255,255,255,0.18)`): label **"Nome scheda"**, label **"Cliente"** (placeholder **"Template (lascia vuoto)"**), details **"Note generali"** con textarea placeholder **"Note sulla scheda..."**.
- Day bar: riusa `.all-day-tabs` (+ bottone "+" `.all-day-tab-add`, aria **"Aggiungi giorno"**); se >1 giorno riga rename + bottone 🗑️ (title **"Rimuovi giorno"**).
- **Card list** (`_renderMobileCardsForDay`, ordinata per `sort_order`): vuoto → `'Nessun esercizio in questo giorno.'` + `'Premi + in basso a destra per aggiungere.'` (o `'Salva la scheda, poi aggiungi esercizi.'`).
  - Esercizio singolo `.all-ex-card` (id `adm-ex-{id}`): thumb + nome + target `"{sets} × {reps} · {kg} kg · {rest}s pausa"` (cardio `"{reps} min"`) + chevron `›` → `_admMobOpenExEdit`.
  - Super serie `.all-ss-card` (id `adm-ss-{group}`): badge **"SS"** + 2 thumb sovrapposte + lista dei 2 nomi → `_admMobOpenSsEdit`.
  - Circuito `.all-cc-card` (id `adm-cc-{group}`): badge **"C"** + fino a 4 thumb (+`"+{N}"` extra) + meta `"{giri} giri · {rest}s pausa"` + nomi → `_admMobOpenCcEdit`.
- **FAB** `.adm-mob-fab` (56px, `bottom:80px; right:1rem`, gradiente viola, z 990) → **bottom-sheet** `_admMobShowFabSheet` (`.all-fab-sheet-overlay`): titolo **"Aggiungi a {giorno}"** e 3 opzioni con testi esatti: **"Esercizio singolo"**/"Un esercizio con riposo" (icona +); **"Super Serie"**/"Due esercizi senza pausa" (icona SS); **"Circuito"**/"Più esercizi, ripetuti a giri" (icona C).
  - `_admMobAddSingle`: flush autosave; se piano inesistente toast `'Inserisci prima un nome per la scheda'`; altrimenti **picker-first**: `_admMobOpenStandalonePicker('__new_single__')` → alla scelta `_admMobCreateExFromPicker` crea l'esercizio (cardio: 1×'20' rest 0; altrimenti 3×'10' rest 90; toast errore `'Errore aggiunta esercizio'`, guard `'Salva prima la scheda'`) e apre subito il suo edit-overlay.
  - `_admMobAddSuperset` / `_admMobAddCircuit`: riusano le funzioni desktop e aprono l'overlay del gruppo appena creato.
- **Overlay edit full-screen** (`#admMobEditOverlay`, classe `.all-detail-overlay`; stato `_admMobActiveEdit = {type:'ex'|'ss'|'cc', id}`; chiusura back → `_admMobCloseEdit` + refresh):
  - Singolo: titolo = nome esercizio; CTA **"✎ Cambia esercizio"** + "i" (title "Dettaglio"); campi (grid 2 col): **"Serie"** (1–30), **"Ripetizioni"**, **"Peso (kg)"**, **"Recupero (s)"** — cardio: solo **"Durata (min)"** — più **"Note"** full-width (textarea, placeholder "Note esercizio..."); bottone **"Elimina esercizio"** (`_admMobDeleteSingle`, confirm `'Eliminare questo esercizio?'`).
  - Super serie: titolo **"Super Serie"**; sezioni **"Esercizio {i} di {n}"** (header ambra `#b45309` su `#fffbeb`) coi campi come sopra; **"Elimina super serie"** (confirm `'Eliminare questa super serie?'`).
  - Circuito: titolo **"Circuito"**; campi **"Numero di giri"** e **"Pausa fra giri (sec)"**; sezione **"Esercizi del circuito"**: righe `.adm-mob-cc-row` con nome + ✎ (cerchio ciano, title "Cambia esercizio") + × (title "Rimuovi") e campi **"Ripetizioni"**/**"Peso (kg)"**; bottone **"+ Aggiungi esercizio"**; **"Elimina circuito"**.
- **Drag-to-reorder long-press** (`_admMobInitDrag` su `[data-ex-id]/[data-ss-id]/[data-cc-id]`): long-press **500 ms** (annullato se il dito si muove >10px prima), vibrazione 30 ms (`navigator.vibrate`), classe `.adm-mob-dragging`, translate delle altre card di ±cardHeight con transition 0.2s; al rilascio `_admMobReorderBlocks(fromIdx, toIdx)` con **optimistic update** (muta `sort_order` in locale, re-render immediato, poi `reorderExercises` in background; errore → toast `'Errore riordino'`); soppressione del tap successivo per 350 ms. Le card hanno `-webkit-touch-callout:none; user-select:none` e le img `pointer-events:none` (fix iOS long-press).

### 9.10 Vista "progress" per singola scheda (legacy) — `_renderProgressView`

Vista raggiungibile via `_schedeViewProgress(planId)` (nessun bottone attivo la richiama nel layout corrente — mantenerla per completezza o scartarla consapevolmente). Usa `WorkoutLogStorage.syncForPlan(planId)`:

```js
fetchAllPaginated(() => supabaseClient.from('workout_logs')
    .select('id,exercise_id,user_id,log_date,set_number,reps_done,weight_done,rest_done,rpe,notes')
    .in('exercise_id', exIds)
    .order('log_date', {ascending:false}).order('set_number', {ascending:true}).order('id'))
```

Header: back **"← Lista"** + `"Progressi: {cliente} — {scheda}"`. Vuoto: `'Nessun log registrato per questa scheda.'` Per giorno/esercizio: header col nome + `"Target: {sets}×{reps} @ {kg}kg"` (cardio `"{reps} min"`); tabella (ultime **10 date**, serie ordinate per `set_number`) con colonne **Data | Serie | Reps | Peso | RPE** (cardio: **Data | Min | RPE**); color-coding celle vs target: `≥target` → `.schede-progress-ok` (`#15803d`), `≥80%` → `.schede-progress-close` (`#ca8a04`), altrimenti `.schede-progress-miss` (`#dc2626`); valori nulli `—`.

### 9.11 Riepilogo chiavi cache / costanti

| Chiave/Costante | Valore | Uso |
|---|---|---|
| LS `schede_exercises_db_v1` | `{ts, data[]}`, TTL 6h | catalogo `imported_exercises` (condiviso Schede+Importa) |
| LS `workout_plans_cache_admin_v1` / `_client_v1` | `{ts, data[]}`, TTL 30 min | piani + esercizi |
| SS `adminSchedeSection` | actual/schede/clienti/importa | sub-tab persistita |
| SS `adminActiveTab` | 'schede' (migrazione da 'importa') | tab admin |
| `_SCHEDE_SYNC_INTERVAL` | 10 s | min-gap re-sync piani |
| `WorkoutPlanStorage._NET_TTL_MS` | 5 min | TTL di rete join pesante |
| `_SCHEDE_EXDB_TIMEOUT_MS` / `_SCHEDE_SYNC_TIMEOUT_MS` | 35 s | safety-timeout render |
| `_SCHEDE_LOGS_CACHE_TTL_MS` | 60 s | log per client-detail |
| `_SCHEDE_REPORTS_CACHE_TTL_MS` | 60 s | monthly_reports per cliente |
| `_SCHEDE_ACTUAL_STATUS_TTL_MS` / retry / cap / max-fail | 60 s / 5 s / 5 min / 5 | badge V-X e 📊 |
| Auto-refresh Actual | 60 s | rotazione slot live |
| `_queryWithTimeout` default | 12 s (CRUD 15 s, sync 30 s) | ogni query |

Helper condivisi citati: `_escHtml`, `_escAttr`, `_escJs`, `_debounce`, `showToast(msg, 'success'|'error')`, `showConfirm(msg)`, `showPrompt(msg, default, {confirmText})`, `showAlert(msg, {type})`, `formatAdminDate(date)` → `YYYY-MM-DD`, `getTimeSlots()`, `getWeeklySchedule(date)`, `getSlotName(type)`, `getSlotColor(type)` (tutti org-aware da data.js).

---

## 10. Importa (esercizi/dati)

### 10.1 Cosa importa e dove vive la UI

- Importa **esclusivamente esercizi** nel catalogo del tenant: dal file statico **`data/esercizi_completo.json`** (~7.200 esercizi, ~3 MB) alla tabella Supabase **`imported_exercises`** (org-scoped: `org_id default current_org_id()`; colonne scritte: `slug, nome_it, nome_original, nome_en, categoria, immagine, immagine_thumbnail, video, popolarita`). **Niente CSV, niente XLSX/SheetJS, niente import clienti, niente mapping colonne**: è una selezione da catalogo predefinito.
- Formato voce JSON: `{ "nome", "nome_en", "categoria", "slug", "immagine", "immagine_thumbnail", "video", "popolarita" }` con URL media assoluti `https://apilyfta.com/static/GymvisualPNG|GymvisualMP4/…`.
- **Dove si trova**: NON è un tab admin autonomo — è la **sub-sezione "Importa" del tab Schede** (4ª pill della subnav §9.1). `renderSchedeTab` inietta `#importaContainer` e chiama `renderImportaTab()`. Retro-compat: `switchTab('importa')` e `sessionStorage.adminActiveTab==='importa'` reindirizzano qui.
- Gli esercizi importati alimentano il **picker delle schede** (§9.8) e le thumbnail in tutto il tab Schede.

### 10.2 Caricamento dati — `renderImportaTab()`

- Loader: **"Caricamento catalogo esercizi..."** (`.importa-loading`).
- `Promise.all([_loadImportaCatalog(), _loadImportaImported()])`:
  - `_loadImportaCatalog()`: `fetch('data/esercizi_completo.json')` con **AbortController + timeout 30 s**; costruisce `_importaCatalog[]` e `_importaCatalogByCat{}`.
  - `_loadImportaImported()`: prima prova LS `schede_exercises_db_v1` (TTL 6h — stessa chiave di admin-schede); poi `fetchAllPaginated` su `imported_exercises` (stessa select/order di §9.2, timeout 30 s); popola `_importaImported[]` + `_importaImportedSlugs:Set` e riscrive la cache LS. Flag `_importaImportedLoaded` = cache valida finché non invalidata da add/remove/rename (solo questo tab scrive la tabella).
- Errore: `'Errore caricamento catalogo ({message}).'` + bottone **"Riprova"** (richiama `renderImportaTab()`).
- Stato UI: `_importaView` ∈ `'catalogo'|'importati'`, `_importaActiveCat`, `_importaSearch`, `_importaPage` (page size **`_IMPORTA_PAGE_SIZE = 60`**).

### 10.3 Layout — `_renderImportaUI(container)` (testi ESATTI)

1. **Hero** `.importa-hero` (gradiente navy/viola identico allo slot LIVE: `linear-gradient(160deg,#0b1220 0%,#1e1b4b 65%,#5b21b6 130%)` + radiale `rgba(139,92,246,0.40)`, radius 18px): eyebrow **"Catalogo esercizi"** (10px uppercase `#a78bfa`); titolo **"{totale} disponibili"** (18px/800 bianco, numero `toLocaleString('it')`); due stat: valore **"{importati}/ {totale}"** label **"Importati"**, e valore **"{x,x}%"** label **"Copertura"** (1 decimale, locale it); barra copertura 4px (fill gradiente `#8B5CF6→#10b981`).
2. **Toggle vista** `.importa-view-toggle` (segmented, bg `#f1f5f9`; attivo = gradiente viola): **"Catalogo completo"** + count pill e **"Importati"** + count pill (`_importaSwitchView(view)` resetta filtri/pagina).
3. **Filtri** `.importa-filters` (grid `1fr 220px`; ≤480px `1fr 130px`): search `#importaSearchInput` con icona lente, placeholder **"Cerca esercizio…"**, bottone clear **×** (aria "Pulisci", `_importaClearSearch`), debounce **250 ms** (`_importaOnSearch`, match su nome/nome_en/nome_it lowercase); `<select class="importa-cat-select">` con prima option **"Tutte le categorie"** + tutte le categorie ordinate (in vista Importati nasconde le categorie a 0 importati) — `_importaPickCat` (ri-cliccare la stessa categoria la toglie).
4. **Barra bulk** (solo vista catalogo, se `_importaPendingCatalog().length > 0`): bottone full-width viola **"Importa tutti {filtrati} {N}"** — la parola `filtrati` compare solo se filtro categoria o ricerca attivi; `{N}` = count pill.
5. **Griglia** `#importaGrid` (`.importa-grid`, auto-fill minmax 200px, gap 0.85rem; ≥768px minmax 210px e container max-width 1200px) + `#importaLoadMore`.

### 10.4 Griglia esercizi — `_importaRenderGrid()`

- Sorgente: catalogo intero oppure importati (merge con dati catalogo per media mancanti; campo `_imported` per il nome rinominato). Filtri categoria+ricerca applicati.
- Paginazione client-side: mostra `(page+1)·60` elementi; bottone **"Mostra altri ({min(60, restanti)} di {restanti} rimanenti)"** (`_importaLoadMore` incrementa `_importaPage`); a fine lista **"{N} esercizi visualizzati"**; vuoto: **"Nessun esercizio trovato"**.
- **Card** `.importa-card` (radius 14px, border 1.5px `#e8ecf1`; hover translateY(-3px); già importata: `.importa-card--imported` border `#86efac`, bg gradiente `#f0fdf4→#fff`):
  - Media `aspect-ratio 4/3` (img `object-fit:contain`, lazy; senza immagine placeholder con icona muscolo SVG opacity .25); click → `_importaShowDetail(slug)`; badge check **"✓"** (cerchio 28px `#22c55e`) se importata.
  - Nome (2 righe max, 0.82rem/700) + meta categoria con icona SVG (mappa `_importaCatSvg`: come §9.8 più `'Anche/Glutei':'hips'`, `'Collo':'neck'`, `'Altro':'chest'`).
  - Se importata e rinominata: riga **"📝 {nome_original}"** (title `"Nome originale: {nome_original}"`).
  - Azioni: non importata → **"+ Importa"** (`.importa-btn--add`, gradiente viola, flex:1); importata → **"✕ Rimuovi"** (`.importa-btn--remove`, `#fee2e2`/`#dc2626`) e **"✏️"** (`.importa-btn--rename`, `#fef3c7`/`#92400e`, title "Rinomina").

### 10.5 Azioni — funzioni, query, validazioni (testi ESATTI)

- **`_importaAdd(slug)`** (import singolo): guardie (slug già importato → no-op); il bottone diventa `...` disabled; `supabaseClient.from('imported_exercises').insert({slug, nome_it: ex.nome, nome_original: ex.nome, nome_en, categoria, immagine, immagine_thumbnail, video, popolarita})` (via `_queryWithTimeout`); poi invalida cache (`_importaImportedLoaded=false` + `localStorage.removeItem('schede_exercises_db_v1')`), ricarica, `_refreshSchedeFromImported()`, re-render. Errore: `showAlert("Errore durante l'importazione: {msg}", {type:'error'})`.
- **`_importaAddAll()`** (bulk, `_importaBulkRunning` anti-doppio-click): pendenti = catalogo filtrato − già importati (`_importaPendingCatalog`). Confirm esatti: con filtri → `"Importare i {N} esercizi filtrati nel tuo catalogo?"`; senza → `"Importare TUTTI i {N} esercizi del catalogo?\n\nSaranno tutti disponibili nel picker delle schede. Potrai rimuovere quelli che non ti servono in seguito."` Overlay bloccante `.importa-bulk-overlay` con modal: titolo **"Importazione in corso…"**, contatore **"{fatti} / {totale}"** (`#importaBulkStatus`) e progress bar (`#importaBulkProgressBar`). Insert a **batch da 500** (`BATCH=500`) con timeout **60 s** per batch; i batch falliti contano come `failed` senza interrompere. Esito: `showAlert("Importati {N} esercizi.", {type:'success'})` oppure `"Importati {N} esercizi. {M} non importati (errore). Riprova per i restanti."` (error). In catch: ricarica comunque e `"Errore durante l'importazione massiva: {msg}"`.
- **`_importaRemove(slug)`**: confirm `"Rimuovere questo esercizio dagli importati?\nNon sarà più disponibile nel picker delle schede."`; bottone `...`; `from('imported_exercises').delete().eq('slug', slug)`; invalidazione + reload + refresh schede. Errore: `"Errore: {msg}"`.
- **`_importaRename(slug)`**: `showPrompt('Nuovo nome italiano:', nomeAttuale)`; no-op se vuoto/uguale; `from('imported_exercises').update({nome_it: nuovo}).eq('slug', slug)`; **propagazione alle schede esistenti** (best-effort, warn su errore):
  1. `from('workout_exercises').update({exercise_name: nuovo}).eq('exercise_slug', slug)` — sync righe linkate.
  2. Backfill orfane: `from('workout_exercises').update({exercise_slug: slug, exercise_name: nuovo}).is('exercise_slug', null).in('exercise_name', [vecchioNome, nome_original?])`.
  Poi invalidazione cache + reload + refresh. Errore: `"Errore: {msg}"`.
- **`_importaShowDetail(slug)`** (modal `.importa-detail-overlay`, z 9999, bg `rgba(0,0,0,0.6)`+blur, chiusura click-fuori o ×; modal 560px radius 20px, animazioni fadeIn 0.2s/slideUp 0.25s): media 16/10 (video autoplay loop muted playsinline > immagine > placeholder icona); nome visualizzato (rinominato se importato); se rinominato riga **"Originale: {nome_original}"**; nome_en; categoria con icona; azioni: importato → **"✕ Rimuovi"** + **"✏️ Rinomina"**; altrimenti **"+ Importa esercizio"** (`.importa-btn--lg`). I bottoni chiudono il modal ed eseguono l'azione.

### 10.6 Sincronizzazione con il tab Schede

- Cache **condivisa bidirezionale**: `_loadExercisesDB` (Schede) riusa `_importaImported` se già caricato e viceversa propaga il proprio fetch a `_importaImported/_importaImportedSlugs/_importaImportedLoaded` se il tab Importa non ha ancora caricato; entrambe leggono/scrivono la stessa chiave LS `schede_exercises_db_v1` (TTL 6h).
- Ogni mutazione in Importa invalida flag + LS e chiama `_refreshSchedeFromImported()` così il picker delle schede vede subito il catalogo aggiornato.
- In Flutter: modellare un unico repository `ImportedExercisesRepository` (cache disco TTL 6h + invalidazione esplicita) consumato da entrambe le sezioni.

### 10.7 Note replicazione Flutter

- La tabella `imported_exercises` NON ha updated_at/unique(slug) a livello schema visibile qui: l'anti-duplicato è client-side (`_importaImportedSlugs.has(slug)`), l'RLS è org-scoped (`imported_exercises_read` per membri org; `imported_exercises_admin` per owner/admin; `org_id null` = catalogo globale piattaforma).
- Contatori e copertura sono calcolati client-side su liste complete in RAM (catalogo 7.2k + importati fino a 7.2k): accettabile, ma in Flutter valutare isolate per il parse JSON da 3 MB.
- Palette Importa: identica al tab Schede — viola primario `#8B5CF6`/`#7C3AED`/hover `#6D28D9`, successo `#22c55e`/`#10b981`, rimozione `#fee2e2`/`#dc2626`, rename `#fef3c7`/`#92400e`, testo `#0f172a`, muted `#64748b`, subtle `#94a3b8`, border `#e2e8f0`, bg chip `#f1f5f9`.

---

# Spec migrazione Flutter — Sezioni 11–13: Messaggi, Impostazioni, Backup

> Fonte: `js/admin-messaggi.js` (181 righe), `js/admin-settings.js` (1824 righe), `js/admin-backup.js` (885 righe), `js/org-settings.js` (327 righe), `admin.html` (tab `messaggi` e `settings`), `css/admin.css`, `js/data.js`, edge functions `send-admin-message`, `billing-checkout`, `billing-portal`, `stripe-connect`.
> Tutti i testi UI riportati sono **esatti** (copiare 1:1, emoji incluse).

---

## 11. Tab Messaggi

### 11.1 Accesso e gating

- Bottone tab: `<button class="admin-tab" data-tab="messaggi" data-feature="messaging">📩 Messaggi</button>` (admin.html:150).
- Pannello: `<div id="tab-messaggi" class="tab-content" data-feature="messaging">` (admin.html:605).
- **Feature gating per piano** (`js/entitlements.js`, `applyFeatureGating`): tutti gli elementi `[data-feature="messaging"]` sono gateati dal flag `messaging` degli entitlements del piano SaaS. Se il flag NON è incluso: il **bottone tab resta visibile ma disabilitato** (`disabled`, classe `ent-locked`) con badge figlio `.ent-upgrade-badge` testo `🔒 Piano superiore` (title `Disponibile nel piano superiore`); i contenuti non-tab vengono nascosti (`display:none` con memo `data-ent-hidden`).
- Lato server la edge function richiede caller **owner/admin attivo** in `org_members` (non basta essere loggati).

### 11.2 Layout (admin.html righe 604–692)

Struttura: contenitore `.msg-hub` (colonna, gap 1rem, animazione `msg-fade-in 0.4s ease-out`) con:

1. **Header** `.msg-header`: `<h3>Notifiche Push</h3>` + badge `.msg-header-badge` = `📡 Broadcast`. Card bianca (`#fff`), bordo `1px solid #e2e8f0`, radius `14px`, padding `1rem 1.3rem`, shadow `0 2px 8px rgba(0,0,0,0.04), 0 0 0 1px rgba(0,0,0,0.02)`, barra superiore `::before` alta `3px` gradient `linear-gradient(90deg, #8B5CF6, #7C3AED, #8B5CF6)`. `h3`: 1.4rem/800/`#0f172a`. Badge: 0.7rem/800 uppercase, colore `#8B5CF6`, sfondo gradient `rgba(139,92,246,0.08)→0.15`, bordo `1px solid rgba(139,92,246,0.2)`, radius 20px.
2. **Riga 2 card affiancate** `.msg-cards-row` (flex, gap 1rem; su mobile ≤768px vanno in colonna):
   - **Card "Componi messaggio"** (`.msg-card`, titolo `.msg-card-title` con icona `✏️` in `.msg-card-title-icon` 26×26px radius 7px sfondo gradient viola tenue; label uppercase 0.78rem/700 `#64748b`, border-bottom `1px solid #f1f5f9`).
   - **Card "Destinatari"** (icona `👥`).
3. **Barra invio** `.msg-send-bar` (flex centrato, gap 1rem, sfondo `linear-gradient(135deg, #f8fafc, #f1f5f9)`, bordo `#e2e8f0`, radius 14px, padding `1rem 1.3rem`).

Card `.msg-card`: bianco, bordo `1px solid #e2e8f0`, radius 14px, padding `1.2rem 1.3rem`; su `:focus-within` appare la barra viola `::before` (3px) e shadow `0 6px 20px rgba(139,92,246,0.08), 0 0 0 1px rgba(139,92,246,0.06)`.

### 11.3 Campi "Componi messaggio"

| Campo | Widget | id | Vincoli | Placeholder |
|---|---|---|---|---|
| `Titolo` (label `.msg-label`, uppercase 0.78rem/700 `#334155`) | `<input type="text">` | `msgTitle` | `maxlength="60"` | `Titolo notifica` |
| `Messaggio` | `<textarea rows="3">` | `msgBody` | `maxlength="200"` | `Testo del messaggio` |

Input/textarea `.msg-input`/`.msg-textarea`: padding `0.6rem 0.85rem`, bordo `2px solid #e2e8f0`, radius 10px, font 0.95rem, colore `#0f172a`; focus: bordo `#8B5CF6`, shadow `0 0 0 4px rgba(139,92,246,0.1), 0 4px 12px rgba(139,92,246,0.06)`; placeholder `#94a3b8`. Textarea `resize: vertical`.

### 11.4 Destinatari — 3 modalità radio (name=`msgRecipientMode`)

Radio card `.msg-recipient-opt` (bordo `1.5px solid #e2e8f0`, radius 12px, padding `0.8rem 1rem`; selezionata via `:has(input:checked)`: bordo `#8B5CF6`, sfondo `linear-gradient(135deg, #f0fbff, #e8f7ff)`; icona 32×32 radius 8px, selezionata gradient pieno `#8B5CF6→#7C3AED`). `onchange="onMsgRecipientModeChange(this.value)"`.

| value | icona | titolo (strong) | sottotitolo (span) | default |
|---|---|---|---|---|
| `tutti` | 🌐 | `Tutti gli utenti` | `Invia a tutti gli utenti iscritti alle notifiche push.` | ✔ checked |
| `giorno` | 📅 | `Iscritti di un giorno` | `Invia solo a chi ha una prenotazione in un giorno specifico.` | |
| `ora` | 🕐 | `Iscritti di un'ora specifica` | `Invia solo a chi ha una prenotazione in un giorno e orario specifico.` | |

> Non esiste modalità "singolo cliente": il target minimo è lo slot orario.

**Campi condizionali** (`.msg-conditional-field`, `margin-top:0.75rem`, `border-top: 1px dashed #e2e8f0`):
- `#msgDatePicker` (label `Data`, `<input type="date" id="msgDate" onchange="onMsgDateChange(this.value)">`, max-width 260px) — visibile per `giorno` e `ora`.
- `#msgTimePicker` (label `Orario`, `<select id="msgTimeSlot">` con option iniziale `Seleziona prima una data`) — visibile solo per `ora`.

**Logica JS** (`admin-messaggi.js`):
- `renderMessaggiTab()`: al primo render precompila `#msgDate` con la data odierna (`toISOString().split('T')[0]`).
- `onMsgRecipientModeChange(mode)`: mostra/nasconde i picker (`display:block/none`); se mode∈{giorno,ora} e data vuota → oggi; se `ora` chiama `onMsgDateChange(date)`.
- `onMsgDateChange(dateStr)`: svuota il select; se data vuota → option `Seleziona una data`. Altrimenti calcola il giorno (nomi: `['Domenica','Lunedì','Martedì','Mercoledì','Giovedì','Venerdì','Sabato']`) e chiama `getScheduleForDate(dateStr, dayName)` (calendario risolto: template settimanale + override). Se nessuno slot → option `Nessuno slot in questo giorno`. Per ogni slot: option `value = slot.time`, testo = `slot.time + ' — ' + label` dove label = `Autonomia` se `slot.type === 'personal-training'`, `Lezione di Gruppo` se `small-group`, altrimenti `Slot prenotato`.

### 11.5 Invio — `sendAdminMessage()`

Bottone: `.msg-send-btn` = `📤 Invia notifica` (gradient `#8B5CF6→#7C3AED`, uppercase, radius 10px, padding `0.7rem 1.6rem`, shadow `0 4px 14px rgba(139,92,246,0.3)`). Accanto `<span id="msgStatus" class="msg-status">` (0.85rem/600, `#64748b`).

Validazioni (messaggi in `#msgStatus`, colore `#dc2626`):
- titolo o messaggio vuoti → `⚠️ Inserisci titolo e messaggio.`
- mode giorno/ora senza data → `⚠️ Seleziona una data.`
- mode ora senza orario → `⚠️ Seleziona un orario.`

Conferma (`showConfirm`): `Inviare la notifica a {modeLabel}?` dove modeLabel = `tutti gli utenti` | `iscritti del {date}` | `iscritti {date} alle {time}`.

Durante l'invio: status `⏳ Invio in corso...` (colore `#6b7280`). Timeout client con `AbortController` a **20000 ms**.

**Chiamata edge function** (fetch diretto, NON `functions.invoke`):
```
POST {SUPABASE_URL}/functions/v1/send-admin-message
Headers: Content-Type: application/json, Authorization: Bearer <access_token sessione Supabase>
Body JSON: { title, body, mode, date, time }
```
(`mode` ∈ `'tutti'|'giorno'|'ora'`; `date` = `YYYY-MM-DD` o `''`; `time` = es. `"09:00 - 10:20"` o `''`).

Esiti:
- `data.ok === true` → status `✅ Inviate {data.sent} notifiche.` (verde `#16a34a`), svuota titolo+messaggio, apre popup risultato con `data.recipients`/`data.failed`.
- `data.ok === false` → `❌ Errore: {data.error}`.
- AbortError → `❌ Timeout — invio non confermato. Riprova.`; altro errore rete → `❌ Errore di rete: {msg}`.

### 11.6 Edge function `send-admin-message` (contratto server)

- Auth: Bearer JWT → `supabase.auth.getUser(token)`; 401 `Non autenticato` / `Token non valido`.
- Autorizzazione: riga in `org_members` con `role IN ('owner','admin')` e `status='active'`; l'**org_id deriva dalla membership, mai dal body**; 403 `Permessi insufficienti`.
- Validazione: 400 `title e body sono obbligatori`; 400 `date obbligatoria per modalità giorno/ora`.
- Selezione destinatari: mode `tutti` → tutte le `push_subscriptions` con `org_id = orgId`; mode `giorno`/`ora` → `bookings` con `org_id`, `date`, `status IN ('confirmed','cancellation_requested')`, `user_id NOT NULL` (+ `time = time` se `ora`) → dedup `user_id` → subscriptions di quegli utenti. Se 0 utenti: `{ ok:true, sent:0, recipients:[] }`.
- Payload push web-push: `{ title, body, tag: "admin-msg-<timestamp>", url: "/index.html" }`. Subscription 410/404 → cancellata da `push_subscriptions`.
- Log in `client_notifications`: una riga `{ org_id, user_id, title, body }` per ogni utente raggiunto (questo è l'unico "storico": non c'è UI di storico messaggi nel tab).
- Risposta: `{ ok: true, sent: <n>, recipients: string[nomi], failed: string[nomi] }` (nomi da `profiles.name` della org, fallback `Sconosciuto`/`Senza nome`).

### 11.7 Popup risultato — `showMsgResultPopup(recipients, failed)`

Overlay `.msg-popup-overlay` (fixed inset 0, `rgba(15,23,42,0.5)` + blur 4px, z-index 9998) + dialog `.msg-popup` (centrato, bianco, radius 18px, max-width 420px, width 92%, max-height 75vh, z-index 9999).
- Header: `<h3>📩 Risultato invio</h3>` + bottone chiusura `✕` (rimuove overlay+popup); barra viola 3px in alto.
- Sezione OK: titolo `✅ Inviate con successo ({n})` (colore `#16a34a`), lista `li` con avatar-iniziali (24×24, gradient `#16a34a→#15803d`, border-left `3px solid #16a34a`) + nome.
- Sezione fail: `❌ Non recapitate ({n})` (`#dc2626`, gradient `#dc2626→#b91c1c`).
- Se entrambe vuote: `.msg-popup-empty` = `Nessun destinatario trovato.`

### 11.8 Storico messaggi

Non esiste una vista storico nel tab. La tabella `admin_messages` esiste (inclusa nel backup §13) e `client_notifications` registra le notifiche inviate (visibili al cliente nella sua app, non all'admin qui).

---

## 12. Tab Impostazioni (11 sotto-tab)

### 12.0 Meccanismo generale

**Shell** (admin.html:340–351, ricreata idempotente da `renderSettingsTab()` in admin-settings.js): `.sett-hub` → `.sett-header` (`<h3>Impostazioni</h3>` + badge `🔧 Configurazione`) → nav `#settNav` → corpo `#settBody` (placeholder iniziale `⏳ Caricamento impostazioni…` in `.sett-loading`).

**Navigazione**: stato modulo `_settActiveSection` (default `'branding'`). `_settSections()` restituisce le 11 sezioni (id, icona, label, render fn, flag `adminOnly`); `settSwitchSection(id)` ri-renderizza nav + corpo. Bottoni `.sett-nav-btn` con `.sett-nav-ico` (emoji) + `.sett-nav-lbl` (testo; **nascosto su mobile ≤640px**, resta solo l'icona). Nav: sfondo `#f1f5f9`, radius 12px, padding 0.3rem; bottone attivo: sfondo `#fff`, colore `#7C3AED`, shadow `0 1px 4px rgba(15,23,42,0.08)`; hover: `rgba(139,92,246,0.08)`.

**Le 11 sezioni** (ordine, icona, label esatta):

| # | id | icona | label nav | render | adminOnly |
|---|---|---|---|---|---|
| 1 | `branding` | 🎨 | `Branding` | `_settRenderBranding` | no |
| 2 | `locale` | 🌍 | `Localizzazione` | `_settRenderLocale` | no |
| 3 | `company` | 🏢 | `Azienda` | `_settRenderCompany` | no |
| 4 | `payments` | 💳 | `Pagamenti` | `_settRenderPayments` (async) | no |
| 5 | `policy` | 🛡️ | `Prenotazioni` | `_settRenderPolicy` | no |
| 6 | `notif` | 🔔 | `Notifiche` | `_settRenderNotif` | no |
| 7 | `staff` | 👥 | `Staff` | `_settRenderStaff` (async) | **sì** |
| 8 | `gdpr` | 📜 | `GDPR` | `_settRenderGdpr` | no |
| 9 | `features` | 🧩 | `Funzionalità` | `_settRenderFeatures` | no |
| 10 | `billing-saas` | 💎 | `Abbonamento` | `_settRenderBillingSaas` (async) | **sì** |
| 11 | `security` | ⚠️ | `Sicurezza` | `_settRenderSecurity` | **sì** |

**Gating ruoli**: `_settIsAdmin()` = `window._orgRole === 'owner' || window._orgRole === 'admin'`. Le sezioni `adminOnly` (Staff, Abbonamento, Sicurezza) sono **filtrate dalla nav** per chi non è owner/admin (ruolo `staff` non le vede). Se la sezione attiva diventa invisibile (cambio ruolo), fallback a `branding`. Inoltre **ogni funzione di salvataggio** ricontrolla `_settIsAdmin()` e in caso negativo mostra toast `Permesso negato` (error) — quindi lo staff vede le altre 8 sezioni ma non può salvare. Non c'è distinzione owner-vs-admin nelle sotto-tab (solo: nella lista Staff un owner non è modificabile da nessuno).

**Bootstrap**: `renderSettingsTab()` → `await OrgSettings.load()` (popola cache) → `_settApplyBrandingExtras()` (applica branding runtime) → render nav + sezione attiva. Il render della sezione è dentro try/catch: su errore `#settBody` mostra card con `Errore nel caricamento della sezione.`

**Salvataggio**: NON autosave per i form — ogni sezione ha un bottone `💾 Salva …` esplicito che scrive in sequenza le chiavi via `OrgSettings.set(key, value)`. Fanno eccezione (salvataggio immediato `onchange`): i toggle legacy della sezione Prenotazioni (cert/assicurazione/badge), i feature flags, il toggle manutenzione. Toast via `showToast(msg, 'success'|'error')`.

**Toast di conferma per sezione (testi esatti)**:
- Branding: `✅ Branding salvato` / `Errore salvataggio branding`
- Localizzazione: `✅ Localizzazione salvata` / `Errore salvataggio localizzazione`
- Azienda: `✅ Dati azienda salvati` / `Errore salvataggio dati azienda`
- Pagamenti: `✅ Pagamenti salvati` / `Salvato, ma {n} prezzo/i non aggiornati` / `Errore salvataggio pagamenti`
- Policy: `✅ Policy salvata` / `Errore salvataggio policy`
- Notifiche: `✅ Notifiche salvate` / `Errore salvataggio notifiche`
- Toggle generico/legacy: `✅ Impostazione salvata` / `Errore salvataggio impostazione`
- Staff: `✅ Invito inviato`, `✅ Ruolo aggiornato`, `✅ Membro revocato` + errori specifici (§12.7)
- GDPR: `✅ GDPR salvato` / `Errore salvataggio GDPR`
- Feature flag: `✅ Funzionalità attivata` / `Funzionalità disattivata` (quest'ultimo come success)
- Manutenzione: `🔧 Manutenzione attivata` (mostrato con stile **error**, intenzionale) / `✅ Manutenzione disattivata` (success)
- Permessi: `Permesso negato` (error)

**Layer OrgSettings** (org-settings.js — da replicare in Flutter):
- Tabella `org_settings(org_id, key, value jsonb)`. Cache in-memory `Map` + **localStorage namespaced `org_<orgId>_<key>`** (per anonimi: `org_<slug>_<key>`, fallback `org_anon_<key>`), valori serializzati JSON.
- `load(force)`: autenticato → `from('org_settings').select('key,value').eq('org_id', orgId)`; anonimo → RPC `get_public_org_settings({ p_org_slug })` (whitelist pubblica). Poi `_subscribeRealtime()` + `applyBranding()`.
- Letture sincrone: `get(key, dflt)` (cache → localStorage → default), `getBool/getNumber/getString` con coercion difensiva (`'true'`→true, parseFloat, String).
- `set(key, value)`: aggiorna cache+localStorage+listener **ottimisticamente**, poi RPC **`upsert_org_setting({ p_key, p_value })`** (SECURITY DEFINER, org-scoped su `current_org_id()`, richiede `is_org_admin()`); su errore rilancia (i chiamanti mostrano toast errore).
- **Realtime**: canale `org_settings_<orgId>` su `postgres_changes` (event `*`, table `org_settings`, filter `org_id=eq.<orgId>`); su evento aggiorna cache+localStorage, notifica i listener `onChange(cb)`, e se la chiave inizia con `branding.` invoca `applyBranding()`. Il canale è registrato in un registry (`window._registerRealtimeChannel`) che lo ricrea dopo wake da sleep.
- `applyBranding()`: applica a runtime nome studio (`[data-org-name]`), logo (`img[data-org-logo]`), link Maps (`a[data-org-maps]`, URL validato http/https), indirizzo (`[data-org-address]` = `via — città`), durata (`[data-org-duration]`), colore primario (CSS var `--primary-purple` + derivata `--primary-purple-dark` = colore scurito del 10% + `<meta theme-color>`), favicon, titolo pagina/PWA (pwa_name || studio_name); salva snapshot NON namespaced `_brandingSnapshot` per l'anti-flash pre-paint.
- `reset()` al logout: rimuove chiavi `org_<id>_*`, chiude canale realtime, svuota cache.
- Helper legacy `_upsertSetting(key, value)` (data.js:2368): usato dalle Storage classes; mappa `gym_xxx` → `xxx` (toglie prefisso), coercion `'true'/'false'`→bool e JSON-string→oggetto, poi stessa RPC `upsert_org_setting` **fire-and-forget** (senza await).

**Stili chiave form** (admin.css): card `.sett-card` (bianca, bordo `#e2e8f0`, radius 14px, padding `1.1rem 1.3rem`, hover barra viola 3px + shadow; variante `.sett-card--danger` bordo `#fecaca`, barra `#ef4444→#dc2626`); icona card `.sett-card-icon` 36×36 radius 10px con gradienti per colore (`--purple` `rgba(124,58,237,0.08)→0.16`, `--blue` `rgba(37,99,235,…)`, `--green` `rgba(5,150,105,…)`, `--red` `rgba(239,68,68,…)`, `--cyan` viola tenue, `--amber`); titolo `.sett-card-title` 0.95rem/800 `#0f172a`; desc `.sett-card-desc` 0.8rem `#64748b`. Grid form `.sett-form-grid` 2 colonne (1 su ≤640px), `.sett-field--wide` = colonna intera. Label `.sett-input-label` 0.78rem/700 uppercase `#64748b`. Input `.sett-text-input` e `.sett-select`: bordo `1.5px solid #e2e8f0`, radius 10px, sfondo `#f8fafc`, focus bordo `#8B5CF6` + ring `rgba(139,92,246,0.1)`. Bottoni `.sett-action-btn` (radius 10px, 0.82rem/700, bianco) varianti: `--blue` `#2563eb→#1d4ed8`, `--purple` `#7c3aed→#6d28d9`, `--green` `#059669→#047857`, `--red` `#ef4444→#dc2626`, `--cyan` `#0891b2→#0e7490`, `--ghost`, `--muted` (`#e2e8f0`/`#64748b`, disabled). Riga bottoni `.sett-btn-row` con border-top `#f1f5f9`. Toggle switch (`.settings-toggle-wrap` base 42×24, dentro `.sett-card` override 44×26, track off `#cbd5e1`, on gradient `#8B5CF6→#7C3AED`, thumb 20×20 che trasla a left 21px).

---

### 12.1 Branding (`_settRenderBranding` / `saveBrandingSettings`)

Card unica — icona 🎨 purple, titolo `Branding studio`, desc `Nome, logo e colore mostrati ai clienti e nell'app installabile.`

| Label esatta | Widget | id | Chiave org_settings | Default | Note/validazione |
|---|---|---|---|---|---|
| `Nome studio` | text | `brandStudioName` | `branding.studio_name` | `''` | placeholder `Es. Studio Fitness Rossi`; trim |
| `Nome PWA (app installata)` | text | `brandPwaName` | `branding.pwa_name` | `''` | placeholder `Es. PalestrIA` |
| `Durata sessione (home)` | text | `brandHomeDuration` | `branding.home_duration` | `''` | placeholder `Es. 80 minuti` |
| `URL logo` | url | `brandLogoUrl` | `branding.logo_url` | `''` | placeholder `https://…/logo.png` — **nessun upload file: solo URL** |
| `URL favicon` | url | `brandFaviconUrl` | `branding.favicon_url` | `''` | placeholder `https://…/favicon.png` |
| `Colore primario` | color + hex sincronizzati | `brandPrimaryColor` / `brandPrimaryColorHex` | `branding.primary_color` | `#8B5CF6` | i due input si aggiornano a vicenda `oninput`; hex maxlength 7, uppercase via CSS; in lettura fallback regex `#RRGGBB` |

Bottone: `💾 Salva branding` (purple). Al salvataggio scrive le 6 chiavi in sequenza poi `_settApplyBrandingExtras()` → applica subito nome/logo/favicon/colore/titolo a runtime (**anteprima live post-save**, non live-preview durante digitazione). Il branding viene ri-applicato anche all'apertura del tab e via realtime su ogni cambio `branding.*`.

### 12.2 Localizzazione (`_settRenderLocale` / `saveLocaleSettings`)

Card unica — icona 🌍 blue, titolo `Localizzazione`, desc `Fuso orario, valuta, lingua e formati usati in tutta la piattaforma.`

| Label | Widget | id | Chiave | Default | Opzioni |
|---|---|---|---|---|---|
| `Fuso orario` | select | `locTimezone` | `locale.timezone` | `Europe/Rome` | 16 IANA: Europe/Rome, London, Paris, Berlin, Madrid, Lisbon, Zurich, Athens, Bucharest, Moscow, America/New_York, Chicago, Denver, Los_Angeles, Sao_Paulo, UTC |
| `Valuta` | select | `locCurrency` | `locale.currency` | `EUR` | EUR, USD, GBP, CHF |
| `Lingua` | select | `locLanguage` | `locale.language` | `it` | it=Italiano, en=English, es=Español, de=Deutsch, fr=Français |
| `Formato data` | select | `locDateFormat` | `locale.date_format` | `DD/MM/YYYY` | DD/MM/YYYY, MM/DD/YYYY, YYYY-MM-DD |
| `Primo giorno settimana` | select | `locFirstDay` | `locale.first_day_of_week` | `1` (number) | 1=Lunedì, 0=Domenica (parseInt al save) |

Bottone: `💾 Salva localizzazione` (blue). Helper globali: `OrgSettings.timezone()` e `OrgSettings.currency()`.

### 12.3 Azienda — Dati azienda/fiscali (`_settRenderCompany` / `saveCompanySettings`)

Card unica — icona 🏢 green, titolo `Dati azienda & fiscali`, desc `Ragione sociale, partita IVA e dati per la fatturazione.`

| Label | Widget | id | Chiave | Note |
|---|---|---|---|---|
| `Ragione sociale` | text | `coLegalName` | `company.legal_name` | trim |
| `Partita IVA` | text | `coVatNumber` | `company.vat_number` | |
| `Codice fiscale` | text | `coTaxCode` | `company.tax_code` | |
| `PEC` | email | `coPec` | `company.pec` | |
| `Codice SDI` | text | `coSdiCode` | `company.sdi_code` | maxlength 7, salvato `.toUpperCase()` |
| `Prefisso fattura` | text | `coInvoicePrefix` | `company.invoice_prefix` | placeholder `Es. 2026/` |

Sottosezione `.sett-subheader` = `Indirizzo` (unica chiave **oggetto** `company.address` = `{ via, cap, citta, provincia, paese }`):

| Label | id | campo oggetto | Note |
|---|---|---|---|
| `Via` (wide) | `coAddrVia` | `via` | |
| `CAP` | `coAddrCap` | `cap` | maxlength 5 |
| `Città` | `coAddrCitta` | `citta` | |
| `Provincia` | `coAddrProvincia` | `provincia` | maxlength 2, uppercase |
| `Paese` | `coAddrPaese` | `paese` | default visuale `Italia` |
| `Link Google Maps (mostrato nella home)` (wide) | `coMapsUrl` | chiave separata `company.maps_url` | placeholder `Es. https://maps.app.goo.gl/...`; in `applyBranding` validato http/https e applicato a `a[data-org-maps]` |

Bottone: `💾 Salva dati azienda` (green).

### 12.4 Pagamenti — Pagamenti cliente (`_settRenderPayments` async / `savePaymentsSettings`)

Placeholder caricamento: `⏳ Caricamento configurazione pagamenti…`. Carica in parallelo (con `_queryWithTimeout`): `billing_settings` (`select('*').eq('org_id', _orgId).maybeSingle()`), `slot_types` (`select('id,key,label,default_price,is_active').eq('org_id',…).order('sort_order')`), `organizations` (`select('stripe_account_id,stripe_charges_enabled,stripe_account_email')`).

**Card 1 — Stripe Connect** (icona 🔗 green): titolo `Incassi online — Stripe`, desc `Collega il TUO account Stripe: i pagamenti dei clienti arrivano direttamente a te, la piattaforma non trattiene nulla.`
- Nessun account: bottone `🔗 Collega il mio account Stripe` (green) → `connectStripeAccount()`.
- Account presente: box `.sett-stripe-status` `ok`/`pending`: `✅ **Account collegato e attivo.**` oppure `⏳ **Account collegato — onboarding da completare** su Stripe per poter ricevere pagamenti.` + email account; bottoni `↗ Completa su Stripe` (solo se pending, green) e `Scollega` (ghost).
- `connectStripeAccount()`: `supabaseClient.functions.invoke('stripe-connect', { body: { action: 'start' } })` → redirect `window.location.href = data.url`. Errore: toast `Errore collegamento Stripe: {msg}`.
- `disconnectStripeAccount()`: confirm `Scollegare il tuo account Stripe? I clienti non potranno più pagarti online finché non lo ricolleghi.` → `invoke('stripe-connect', { body: { action: 'disconnect' } })` → toast `Account Stripe scollegato` + reload dopo 700ms.

**Card 2 — Modello predefinito** (icona 💳 green): titolo `Modello di pagamento predefinito`, desc `Modalità applicata di default ai nuovi clienti (sovrascrivibile per-cliente).` Radio card `.sett-model-opt` (name=`payDefaultModel`), griglia 2×2:

| value | titolo | descrizione |
|---|---|---|
| `pay_per_session` | `🎟️ A entrata` | `Il cliente paga ogni singola lezione.` |
| `monthly` | `📆 Mensile` | `Abbonamento mensile a tariffa fissa.` |
| `package` | `🎫 Pacchetto` | `Carnet di ingressi prepagato (decremento automatico).` |
| `free` | `🎁 Gratuito` | `Nessun pagamento richiesto.` |

Default `pay_per_session`; `onchange` sposta la classe `.active` (bordo `#8B5CF6`, sfondo `#faf5ff`).

**Card 3 — Blocchi** (icona 🚫 red): titolo `Blocco prenotazioni per pagamenti`, desc `Condizioni che impediscono al cliente di prenotare.`
- `Soglia debito massimo (€, 0 = nessun blocco)` — number min 0 step 0.01, id `payThreshold` → `billing_settings.block_unpaid_threshold` (default 0, display `.toFixed(2)`).
- `Giorni di tolleranza (grace)` — number min 0 step 1, id `payGraceDays` → `grace_days` (default 0).
- Toggle `Abbonamento scaduto` / `Blocca se l'abbonamento mensile è scaduto.` id `payBlockMemb` → `block_if_membership_expired` (default true).
- Toggle `Pacchetto esaurito` / `Blocca se il carnet di ingressi è terminato.` id `payBlockPkg` → `block_if_no_package` (default true).
- Toggle `Decremento automatico pacchetto` / `Scala un ingresso dal pacchetto ad ogni prenotazione.` id `payAutoDecrement` → `package_auto_decrement` (default true).

**Card 4 — Listino** (icona 💶 blue): titolo `Listino prezzi per tipo di slot`, desc `Prezzo cliente autoritativo per ciascun tipo di lezione (sincronizzato col display pubblico).` Una riga `.sett-price-row` per ogni `slot_type`: label (+ badge `disattivo` se `is_active=false`) e input `€` number min 0 step 0.01 (class `.sett-price-input`, `data-slot-id`, `data-slot-key`; valore = `slot_types.default_price` con fallback cache `billing_client.prices[key]`). Se vuoto: `Nessun tipo di slot configurato. Aggiungili da Gestione Orari → Tipi slot.`

Bottone finale: `💾 Salva pagamenti` (green). **Persistenza mista** (unica sezione che NON usa solo OrgSettings): (1) upsert su tabella `billing_settings` con `onConflict: 'org_id'` (campi: org_id, default_model, block_unpaid_threshold, block_if_membership_expired, block_if_no_package, grace_days, package_auto_decrement, updated_at); (2) update paralleli `slot_types.default_price` per id+org_id con raccolta errori; (3) `OrgSettings.set('billing_client.prices', {key: prezzo,…})` per il display pubblico.

### 12.5 Prenotazioni — Policy prenotazione/cancellazione (`_settRenderPolicy` / `savePolicySettings` + toggle legacy)

**Card 1 — Policy** (icona 🛡️ purple): titolo `Policy prenotazione & cancellazione`, desc `Regole su anticipo, finestra di cancellazione gratuita e penali.`

| Label | Widget | id | Chiave | Default |
|---|---|---|---|---|
| `Ore di cancellazione gratuita` | number min 0 | `polFreeHours` | `booking.policy.free_cancel_hours` | 24 |
| `Penale cancellazione tardiva (%)` | number 0–100 | `polPenalty` | `booking.policy.penalty_pct` | 50 |
| `Anticipo massimo prenotazione (giorni, 0 = illimitato)` | number min 0 | `polMaxAdvance` | `booking.policy.max_advance_days` | 0 |
| `Modalità cancellazione` | select | `polCancelMode` | `booking.policy.cancel_mode` | `penalty` — opzioni: `penalty`=`Penale percentuale`, `block`=`Blocca cancellazione tardiva`, `free`=`Sempre gratuita` |
| Toggle `Richiedi account per prenotare` / `Se attivo, solo i clienti registrati possono prenotare.` | checkbox | `polRequiresAccount` | `booking.policy.requires_account` | false |

Bottone: `💾 Salva policy` (purple).

**Card 2 — Certificato medico** (icona 🏥 cyan): desc `Se attivo, i clienti possono modificare la scadenza del proprio certificato nel profilo.` Toggle header-inline `certEditableToggle` con testo di stato `certEditableText` = `Modificabile dal cliente` / `Non modificabile`. Salvataggio **immediato onchange** via `saveCertEditable(checked)`.

**Card 3 — Blocco prenotazioni per certificato medico** (icona 🚫 red), desc `Impedisci ai clienti di prenotare in base allo stato del certificato medico.`:
- `Certificato scaduto` / `Blocca la prenotazione se il certificato medico risulta scaduto.` → `certBlockExpiredToggle`, stato `Bloccato`/`Non bloccato`.
- `Certificato non impostato` / `Blocca la prenotazione se il cliente non ha ancora inserito la scadenza.` → `certBlockNotSetToggle`.

**Card 4 — Blocco prenotazioni per assicurazione** (icona 🚫 red), desc `Impedisci ai clienti di prenotare in base allo stato dell'assicurazione.`:
- `Assicurazione scaduta` / `Blocca la prenotazione se l'assicurazione risulta scaduta.` → `assicBlockExpiredToggle`.
- `Assicurazione non impostata` / `Blocca la prenotazione se il cliente non ha ancora inserito la scadenza.` → `assicBlockNotSetToggle`.

**Card 5 — Badge sulla card partecipante** (icona 👁️ cyan), desc `Quali badge mostrare nella vista Prenotazioni admin.` 4 toggle: `🏥 Certificato medico` (`showCertBadgeToggle`), `📋 Assicurazione` (`showAssicBadgeToggle`), `📝 Documento non firmato` (`showDocBadgeToggle`), `📋 Completa anagrafica` (`showAnagBadgeToggle`); stato `Visibile`/`Nascosto`; dopo il save richiamano `_refreshAdminCalendarIfVisible()` (re-render vista giorno admin).

**Card 6 — Settimane standard** (icona 🗓️ cyan): solo rimando, desc `La configurazione delle settimane tipo è stata spostata in Gestione Orari → Settimana tipo.` + bottone `Vai a Gestione Orari` (cyan) → `switchTab('schedule')`.

**Meccanica toggle legacy** (`_settSaveLegacyToggle(toggleId, textId, dbKey, val, labels, legacySetter, after)`): gate admin con **rollback del checkbox** su permesso negato; update ottimistico del testo; `await OrgSettings.set(dbKey, val)` (chiave org_settings **senza** prefisso `gym_`); in parallelo aggiorna la Storage class legacy di data.js (che scrive localStorage `gym_*` + `_upsertSetting` fire-and-forget) per i consumer in-session; toast `✅ Impostazione salvata`; su errore rollback toggle+testo e toast `Errore salvataggio impostazione`.

Chiavi org_settings dei toggle legacy (dbKey ↔ Storage class ↔ localStorage legacy):
- `cert_scadenza_editable` ↔ `CertEditableStorage` ↔ `gym_cert_scadenza_editable` (default get: true)
- `cert_block_expired` / `cert_block_not_set` ↔ `CertBookingStorage` ↔ `gym_cert_block_expired` / `gym_cert_block_not_set` (default false)
- `assic_block_expired` / `assic_block_not_set` ↔ `AssicBookingStorage` ↔ `gym_assic_*` (default false)
- `show_cert_badge` / `show_assic_badge` / `show_doc_badge` / `show_anag_badge` ↔ `BookingBadgesStorage` ↔ `gym_show_*_badge` (default true)

Al boot `BookingStorage.syncAppSettingsFromSupabase()` (data.js:2171) ripopola le chiavi `gym_*` dalle chiavi org_settings.

### 12.6 Notifiche (`_settRenderNotif` / `saveNotifSettings`)

**Card 1** (icona 🔔 blue): titolo `Notifiche`, desc `Conferme, promemoria e avvisi agli admin.`

| Elemento | id | Chiave | Default |
|---|---|---|---|
| Toggle `Conferma prenotazione al cliente` / `Invia una notifica al cliente quando prenota.` | `notifConfirmation` | `notif.booking_confirmation` | true |
| Toggle `Promemoria lezione` / `Invia un promemoria prima della lezione.` | `notifReminderEnabled` | `notif.reminder_enabled` | true |
| `Anticipo promemoria (ore)` — number min 1, input small (90px) | `notifReminderHours` | `notif.reminder_hours` | 24 (fallback 24 se NaN) |
| Toggle `Avvisa admin su nuova prenotazione` / `Notifica push agli admin della org per ogni nuova prenotazione.` | `notifAdminNew` | `notif.admin_new_booking` | true |

**Card 2 — Canali** (icona 📡 purple): titolo `Canali di invio`, desc `Quali canali usare per le notifiche.` Chiave **oggetto** `notif.channels` = `{ push, email, whatsapp }` (default `{push:true, email:false, whatsapp:false}`): toggle `📲 Push` (`notifChanPush`, checked se `!== false`), `✉️ Email` (`notifChanEmail`), `💬 WhatsApp` (`notifChanWhatsapp`).

Bottone: `💾 Salva notifiche` (blue). **Non c'è bottone "test push"** in questa sezione.

### 12.7 Staff / Membri (`_settRenderStaff` — solo owner/admin)

**Card 1 — Invito** (icona 👥 purple): titolo `Invita un membro dello staff`, desc `Inserisci l'email di un utente registrato e assegna un ruolo.`
- `Email` (wide) — `staffInviteEmail`, placeholder `nome@esempio.it`, lowercased.
- `Ruolo` — select `staffInviteRole`: `Staff` (value `staff`, default) / `Admin` (value `admin`). **Owner non assegnabile.**
- Bottone `➕ Invita membro` (purple) → validazione `email.includes('@')` altrimenti toast `Inserisci un'email valida`; RPC **`invite_org_member({ p_email, p_role })`** (l'utente deve già esistere in auth). Successo: toast `✅ Invito inviato`, svuota campo, ricarica lista. Errori mappati: messaggio contiene `unauthorized` → `Permesso negato`; `invalid_role` → `Ruolo non valido`; altro → `Errore: l'utente deve essere registrato per essere invitato`.

**Card 2 — Lista** (icona 📋 blue): titolo `Membri dello staff`, desc `Ruoli e stato dei membri della tua organizzazione.` Placeholder `⏳ Caricamento membri…`. Query: `org_members.select('id,user_id,role,status,invited_email').eq('org_id',…).order('role')` + risoluzione nomi/email da `profiles` (`.in('id', userIds)`). Vuota: `Nessun membro oltre al proprietario.` Errore: `Errore nel caricamento dei membri.`

Riga membro `.sett-staff-row`: nome (fallback: `profiles.name` → `invited_email` → `profiles.email` → `—`) + badge ruolo `.sett-role-badge--owner/admin/staff` con label `Proprietario`/`Admin`/`Staff` (owner: `#fef3c7`/`#b45309`; admin: `#ede9fe`/`#6d28d9`; staff: `#e0f2fe`/`#0369a1`) + badge stato se `status !== 'active'` (`invitato` se `invited`, altrimenti `revocato`); sotto l'email. Azioni (solo se caller owner/admin **e** il membro non è owner): select ruolo `Staff`/`Admin` → `changeStaffRole(memberId, newRole)` (update `org_members.role` con guardie `.eq('org_id')`, `.neq('role','owner')`; toast `✅ Ruolo aggiornato` / `Errore aggiornamento ruolo` con reload lista); bottone rosso `Revoca` → confirm `Revocare l'accesso a questo membro?` → update `status='revoked'` (toast `✅ Membro revocato` / `Errore revoca membro`).

### 12.8 GDPR / Privacy (`_settRenderGdpr` / `saveGdprSettings`)

Card unica (icona 📜 green): titolo `GDPR & Privacy`, desc `Link ai documenti legali e conservazione dei dati.`

| Label | Widget | id | Chiave | Default |
|---|---|---|---|---|
| `URL informativa privacy` (wide) | url | `gdprPrivacyUrl` | `gdpr.privacy_url` | `''` — placeholder `https://…/privacy` |
| `URL termini e condizioni` (wide) | url | `gdprTermsUrl` | `gdpr.terms_url` | `''` — placeholder `https://…/termini` |
| `Conservazione dati (giorni, 0 = illimitato)` | number min 0 | `gdprRetention` | `gdpr.data_retention_days` | 0 |

Bottone: `💾 Salva GDPR` (green). **Non c'è export GDPR per-cliente qui** (l'export completo dati org è nel Backup, §13).

### 12.9 Funzionalità — Feature flags (`_settRenderFeatures` / `saveFeatureFlag`)

Card unica (icona 🧩 purple): titolo `Funzionalità`, desc `Attiva/disattiva i moduli per la tua organizzazione. La disponibilità per piano è gestita a parte.` 5 toggle **con salvataggio immediato onchange** (chiave `features.<key>`, default lettura **false**):

| key | label | descrizione |
|---|---|---|
| `workout_plans` | `💪 Schede di allenamento` | `Modulo schede, esercizi e progressi.` |
| `nutrition` | `🥗 Nutrizione` | `Piani alimentari per i clienti.` |
| `messaging` | `💬 Messaggistica` | `Notifiche push broadcast ai clienti.` |
| `ai_reports` | `🤖 Report AI` | `Report mensili generati con AI.` |
| `client_online_payments` | `💳 Pagamenti online` | `I clienti pagano le lezioni online con Stripe.` |

`saveFeatureFlag(key, val)`: gate admin con rollback checkbox; toast `✅ Funzionalità attivata` / `Funzionalità disattivata`. (Questi flag org-level si combinano col gating per piano di entitlements.js, che è separato.)

### 12.10 Abbonamento — Billing SaaS (`_settRenderBillingSaas` — solo owner/admin)

Placeholder: `⏳ Caricamento abbonamento…`. Dati da RPC **`get_tenant_entitlements()`** → `{ plan, status, max_clients, clients_count, trial_end, current_period_end }`.

**Card 1 — Stato** (icona 💎 purple): titolo `Il tuo abbonamento`, desc `Stato dell'abbonamento PalestrIA della tua organizzazione.` Tre stat `.sett-saas-stat`:
- `Piano` → nome capitalizzato (es. `Starter`) o `—`.
- `Stato` → mappa: `trialing`=`🎁 In prova`, `active`=`✅ Attivo`, `past_due`=`⚠️ Pagamento in ritardo`, `canceled`=`⛔ Annullato`, `unpaid`=`⚠️ Non pagato`, `incomplete`=`⏳ Incompleto` (altrimenti valore raw).
- `Clienti` → `{clients_count} / {max_clients|∞}`.
Sotto, se trialing: `Prova fino al **{data it-IT}**`; altrimenti se c'è period end: `Rinnovo: **{data}**`. Bottone `⚙️ Gestisci abbonamento` (blue) → `openBillingPortal()`.

**Card 2 — Cambia piano** (icona 🚀 green): titolo `Cambia piano`, desc `Scegli il piano più adatto al numero di clienti.` Griglia 3 card `.sett-plan-card` (bordo `1.5px #e2e8f0` radius 14px; corrente: bordo `#8B5CF6` + ring):

| code | nome | prezzo | limite | feats (lista con ✓ verde) |
|---|---|---|---|---|
| `starter` | `Starter` | `€39,99` `/mese` | `≤ 50 clienti` | `Schede`, `Notifiche push` |
| `pro` | `Pro` | `€79,99` `/mese` | `≤ 200 clienti` | `Tutto Starter`, `Report AI`, `Pagamenti online` |
| `business` | `Business` | `€149,99` `/mese` | `Clienti illimitati` | `Tutto Pro`, `Priorità supporto` |

Piano corrente: bottone disabilitato `Piano attuale` (muted); altri: `Scegli` (green) → `changeSaasPlan(code)`.

**Flussi Stripe (piattaforma)**:
- `changeSaasPlan(planCode)`: toast `Reindirizzamento al checkout…` → `supabaseClient.functions.invoke('billing-checkout', { body: { plan_code: planCode } })` → risposta `{ url }` → `window.location = url`. Errore: toast `Errore avvio checkout`. Lato server: Stripe Checkout **mode=subscription**, trial 30gg, `success_url = {SITE_URL}/admin.html?billing=success`, `cancel_url = {SITE_URL}/admin.html?billing=cancel`.
- `openBillingPortal()`: toast `Apertura portale…` → `invoke('billing-portal')` (senza body) → `{ url }` → redirect. Errore: toast `Errore apertura portale`. Lato server: Stripe Customer Portal con `return_url = {SITE_URL}/admin.html?billing=portal`.

### 12.11 Sicurezza / Manutenzione (`_settRenderSecurity` — solo owner/admin)

5 card:

**1. Modalità manutenzione** (`.sett-card--danger`, icona 🔧 red): titolo `Modalità manutenzione`, desc `Quando attiva, i clienti vedono un overlay "sistema non disponibile". L'admin continua ad accedere.` Toggle `maintenanceModeToggle` con testo `Attiva`/`Non attiva`; save immediato `saveMaintenanceMode(checked)` → `OrgSettings.set('maintenance.mode', bool)`; toast `🔧 Manutenzione attivata` (stile error) / `✅ Manutenzione disattivata`; rollback su errore. Campo `Messaggio personalizzato (opzionale)` — input `maintenanceMessageInput` placeholder `Sistema temporaneamente non disponibile…` + bottone `.sett-save-btn` `Salva` → `saveMaintenanceMessage()` → `OrgSettings.set('maintenance.message', msg)`; conferma inline `Salvato` (`#maintenanceMessageSaved`, verde, visibile 2s — niente toast).

**2. Verifica integrità dati** (icona 🔍 purple): desc `Controlla anomalie: utenti senza profilo, prenotazioni orfane, email non corrispondenti.` Bottone `🔍 Verifica` (`runHealthCheck` → RPC `admin_health_check`, timeout 30s; durante: `⏳ Verifica in corso...`). Checks: `👻 Utenti senza profilo` (desc `Account auth.users senza riga in profiles`, fix `Crea profilo da metadata`), `📅 Prenotazioni orfane` (`Prenotazioni con user_id che punta a profilo inesistente` / `Scollega user_id (booking intatta)`), `📧 Email non corrispondenti` (`Prenotazioni con email diversa dal profilo collegato` / `Ricollega user_id al profilo corretto`). Riepilogo: `✅ Nessuna anomalia rilevata` (verde) o `⚠️ {n} anomalie rilevate` (rosso); per check ko: righe dettaglio (max 10 + `... e altri {n}`), prefisso `Correzione: {fix}`. Se anomalie>0 appare `🔧 Correggi anomalie` (red) → confirm `Correggi tutte le anomalie?\n\nNessun dato verrà cancellato.\n• Utenti fantasma → crea profilo\n• Booking orfane → scollega user_id\n• Email mismatch → ricollega user_id al profilo corretto` → RPC `admin_health_fix` → riepilogo `🔧 {n} correzioni applicate` + dettagli (`Profili creati`, `Prenotazioni scollegate`, `Email allineate`; se 0: `Nessuna correzione necessaria.`) → resync `UserStorage.syncUsersFromSupabase()` + `BookingStorage.syncFromSupabase()` → toast `Integrità dati corretta.`

**3. Backup & Ripristino** (icona 💾 blue) — vedi §13.

**4. Report pagamenti** (icona 🧾 green): titolo `Report pagamenti`, desc `Scarica i report XLSX dei pagamenti fiscali (carta, bonifico, Stripe, contanti con report).` Bottoni `📥 Report settimanale` → `downloadWeeklyReport()` e `🧾 Report fiscale completo` → `downloadFiscalReport()` (entrambi definiti in `admin-analytics.js`, generano XLSX via SheetJS — fuori scope di questa sezione).

**5. Cancella tutti i dati** (`.sett-card--danger`, icona 🗑️ red): titolo `Cancella tutti i dati`, desc `Elimina prenotazioni, schede, pagamenti e configurazioni della tua organizzazione. Account e abbonamento restano. Operazione irreversibile.` Bottone `🗑️ Cancella dati org` (red) → `clearAllOrgData()`: confirm `Cancellare TUTTI i dati operativi della tua organizzazione?\n\nVerranno eliminati: prenotazioni, schede, pagamenti, override calendario, notifiche e report.\nAccount, membri e abbonamento NON saranno toccati.\n\nL'operazione è IRREVERSIBILE.` → prompt `Per confermare, scrivi ELIMINA in maiuscolo:` (deve essere esattamente `ELIMINA`, altrimenti toast `Operazione annullata`) → RPC **`admin_clear_all_data`** (timeout 30s) → toast `✅ Dati organizzazione cancellati` / `Errore cancellazione dati`.

---

## 13. Backup

### 13.1 Dove vive

Il backup NON ha un tab proprio: vive nella **card "Backup & Ripristino" della sotto-tab Impostazioni → Sicurezza** (§12.11 card 3, quindi solo owner/admin). Markup: bottoni `📤 Esporta JSON` (blue, `exportBackup('json')`), `📤 Esporta CSV` (purple, `exportBackup('csv')`), `📥 Importa backup` (green, apre `<input type="file" id="importBackupFile" accept=".json" style="display:none" onchange="importBackup(this)">`), più status line `<div id="backupStatus" class="sett-status-text">`. Desc card: `Esporta tutti i dati della tua organizzazione. Il ripristino sovrascrive i dati attuali.` Logica in `js/admin-backup.js`.

### 13.2 Export — `exportBackup(format)` (format `'json'` default | `'csv'`)

1. **Gate di conferma** (`showConfirm`): titolo `Esporta backup completo`, messaggio `Verrà scaricato l'intero archivio in formato {JSON|CSV} (tutte le tabelle dello studio). L'operazione può richiedere tempo e traffico dati. Procedere?`, bottone `Esporta`.
2. Status: `⏳ Esportazione in corso...`
3. **Fetch completo di 14 sorgenti** in `Promise.allSettled`, tutte via `_fetchAllPaginated(table, '*', orderBy, timeoutMs)` — fetch paginato batch **1000 righe**, cap **500 pagine** (500k righe/tabella), ogni pagina con `_queryWithTimeout`; supera il limite PostgREST ~1000 righe. Tabelle (org-scoped da RLS) e ordinamenti:
   - `bookings` (created_at asc, 30s), `payments` (created_at asc, 30s), `client_packages` (created_at, 20s), `client_memberships` (created_at, 20s), `slot_types` (sort_order, 20s), `time_slots_config` (sort_order, 20s), `weekly_schedule_templates` (created_at, 20s), `schedule_overrides` (date, 20s), **`profiles` via RPC `get_all_profiles`** (20s), `org_settings` (20s), `push_subscriptions` (20s), `admin_audit_log` (created_at, 30s), `admin_messages` (created_at, 20s), `client_notifications` (created_at, 30s).
   - Tabelle fallite/timeout → saltate e loggate (`[Backup] Tabelle saltate…`).
4. **Formato JSON** (stesso formato del backup auto-cron Nextcloud): `{ generated_at: ISO, source: 'admin-export', bookings: […], payments: […], … }` → download `gym-backup-{YYYY-MM-DD}.json` (Blob `application/json`, pretty 2 spazi). Status finale: `✅ Backup JSON esportato il {toLocaleString('it-IT')}` oppure `⚠️ Backup esportato (tabelle mancanti: {lista}) — {data}`.
5. **Formato CSV** (`_exportBackupCSV`): un **singolo file CSV multi-sezione** (niente ZIP): header `# Backup PalestrIA — {data}` + `# Generato il {…}`, poi per ogni tabella non vuota `### TABELLA: {NOME} ({n} righe) ###` + CSV (header = chiavi prima riga; escaping RFC: valori con `,`/`"`/newline racchiusi tra doppi apici, `"`→`""`; oggetti serializzati JSON). Download `gym-backup-{data}.csv` con BOM `﻿`, MIME `text/csv;charset=utf-8`. Se nessun dato: status `❌ Nessun dato da esportare`.

### 13.3 Import/Ripristino — `importBackup(input)`

1. **Conferma digitata** (niente password): prompt `L'import sovrascrive i dati attuali.\n\nPer confermare, digita IMPORTA (in maiuscolo)` (placeholder `IMPORTA`, bottone `Importa`). Se ≠ `IMPORTA`: alert `Conferma non valida. Import annullato.` (warn) e reset input.
2. Legge il file con FileReader e riconosce **3 formati**:
   - **Formato admin**: `{ version, exportedAt, data: { gym_bookings: "json-string", … } }`.
   - **Formato Nextcloud/cron A**: `{ generated_at, bookings: […], payments: […], … }` → convertito con `_convertCronToAdminFormat()`.
   - **Formato Nextcloud B**: `{ exportedAt, tables: { bookings: […] } }` → appiattito in A poi convertito.
   - Non riconosciuto → `Errore durante l'importazione: Formato non valido`.
3. `_convertCronToAdminFormat(cron)` produce `{ version: 2, exportedAt, data }` mappando: `bookings` snake→camel (id=`local_id||id`, userId, date, time, slotType, name, email, whatsapp, notes, status, paid, paymentMethod, paidAt, createdAt, dateDisplay, cancellationRequestedAt, cancelledAt, cancelledPaymentMethod, cancelledPaidAt, cancelledRefundPct, arrivedAt) in `gym_bookings`; `schedule_overrides` array → mappa per data `{time, type, slotTypeId?, capacity?}` in `scheduleOverrides`; `settings` → chiavi localStorage legacy (mapping: `cancellation_mode`→`gym_cancellation_mode`, `cert_scadenza_editable`, `cert_block_expired`, `cert_block_not_set`, `assic_block_expired`, `assic_block_not_set`, `week_templates`→`gym_week_templates`, `active_week_template`→`gym_active_week_template`); `profiles` → `gym_users`; tabelle raw prefissate `_` per il restore diretto: `_push_subscriptions`, `_admin_audit_log`, `_profiles`, `_org_settings` (accetta anche `settings` legacy), `_admin_messages`, `_client_notifications`, `_payments`, `_client_packages`, `_client_memberships`, `_slot_types`, `_time_slots_config`, `_weekly_schedule_templates`.
4. **Seconda conferma** (danger): `Ripristinare il backup del {data}?\n\nConterrà {n} sezioni di dati.\n\nATTENZIONE: tutti i dati attuali verranno sovrascritti.`
5. Ripristina in localStorage le `BACKUP_KEYS`: `gym_bookings`, `gym_stats`, `gym_users`, `weeklyScheduleTemplate`, `scheduleOverrides`, `scheduleVersion`, `gym_cancellation_mode`, `gym_cert_scadenza_editable`, `gym_cert_block_expired`, `gym_cert_block_not_set`, `gym_assic_block_expired`, `gym_assic_block_not_set`, `dataClearedByUser`, `dataLastCleared`, `gym_week_templates`, `gym_active_week_template` (le chiavi crediti/debiti/bonus sono state rimosse).
6. **Push su Supabase** (12 step, status progressivo `⏳ Ripristino: {label}...`, timeout 20s/step, errori raccolti):
   1. `bookings`: upsert `onConflict:'local_id'` (scarta id `demo-*`/`_avail_*`; **org_id forzato a `window._orgId`**, PK server-generata).
   2. `payments`: **insert** (id scartato, org_id forzato — sicurezza ledger).
   3. `client_packages`: insert (id scartato, org_id forzato).
   4. `client_memberships`: insert (idem).
   5. `schedule_overrides`: upsert `onConflict:'org_id,date,time'` (con `slot_type_id` e `capacity` assoluta se presenti).
   6. `slot_types` / `time_slots_config` / `weekly_schedule_templates`: upsert `onConflict:'id'` (id preservato per i riferimenti incrociati, org_id forzato; RLS respinge id di altri tenant).
   7. `org_settings`: upsert `onConflict:'org_id,key'` (org_id forzato).
   8. `profiles`: per riga, `update` match su `email` lowercased (name, whatsapp, medical_cert_expiry, medical_cert_history, insurance_expiry, insurance_history, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap, documento_firmato, geo_enabled, push_enabled).
   9. `push_subscriptions`: upsert `onConflict:'endpoint'` (user_id, endpoint, p256dh, auth).
   10. `admin_audit_log`: insert (id scartato, org_id forzato — niente blanket delete).
   11. `admin_messages`: insert (idem).
   12. `client_notifications`: insert (idem).
7. Esito: status `✅ Backup ripristinato. Ricarico...` oppure `⚠️ Ripristinato con errori ({step falliti}). Ricarico...` → `location.reload()` dopo 1200ms. Errore parsing: alert `Errore durante l'importazione: {msg}` + status `❌ Importazione fallita: {msg}`.

> Nota sicurezza da preservare in Flutter: l'import **forza sempre `org_id` alla org corrente** e **non invia mai PK client** per le tabelle sensibili (payments, packages, memberships, audit, messages, notifications) — solo insert. TODO dichiarato nel codice: spostare l'import su RPC server-side.

### 13.4 Funzioni legacy presenti ma NON collegate alla UI attuale

In `admin-backup.js` esistono anche `exportData()` (export XLSX 4 fogli `Clienti`/`Prenotazioni`/`Pagamenti`/`Gestione Orari` via SheetJS, filename `TB_Training_export_{data}.xlsx`), `resetDemoData()` (rigenera dati demo), `clearAllData()` (versione legacy con RPC `admin_clear_all_data` + marker `data_cleared_at` via `upsert_org_setting` + svuota cache PWA) e `pruneOldData()` (RPC `admin_prune_old_data({ p_cutoff })`, elimina demo + prenotazioni < cutoff mesi). **Nessuna di queste è referenziata da admin.html**: la UI corrente usa solo `exportBackup`/`importBackup` e `clearAllOrgData` (§12.11). In Flutter non vanno replicate nella UI (eventualmente solo `pruneOldData` come candidato futuro).

### 13.5 Dipendenze condivise

- `_queryWithTimeout(query, ms)` / `_rpcWithTimeout(rpc, ms)`: wrapper Promise.race con timeout (definiti altrove, usati ovunque qui).
- `_localDateStr(date?)`: data locale `YYYY-MM-DD` per i filename.
- `showConfirm` / `showPrompt` / `showAlert` / `showToast`: dialog e toast custom dell'app (i testi esatti sono riportati sopra).
- `_escHtml`: escaping HTML per ogni dato dinamico (in Flutter equivale a non interpolare HTML).

---
