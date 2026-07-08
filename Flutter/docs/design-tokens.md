# PalestrIA — Design System / Design Tokens (estratto dalla web app per il port Flutter)

> Fonte: `css/style.css`, `css/admin.css` (12.7k righe), `css/allenamento.css`, `css/prenotazioni.css`,
> `css/login.css`, `css/tablet.css`, `css/super-admin.css`, `css/nutrizione.css` + `js/branding-boot.js`,
> `js/org-settings.js` e meta inline degli HTML. Data estrazione: 2026-07-06.
> Obiettivo: fedeltà grafica 1:1 in Flutter (`ThemeData` + design tokens + tema dinamico per-org).

---

## 1. PALETTE COMPLETA

### 1.1 Token globali (`:root` in `style.css`) — la base di TUTTE le pagine

| CSS var | Hex | Ruolo semantico | Override per-org? |
|---|---|---|---|
| `--primary-purple` | `#8B5CF6` | **Brand primary** (bottoni, tab attive, link attivi, FAB, accenti) | ✅ `org_settings` chiave **`branding.primary_color`** |
| `--primary-purple-dark` | `#7C3AED` | Primary "dark" (hover, gradienti, pressed) | ✅ derivato a runtime: primary scurito del 10% (RGB × 0.9) |
| `--dark-bg` | `#1a1a1a` | Superficie scura: navbar, footer, hero home, header tabelle | ❌ fisso |
| `--dark-gray` | `#2d2d2d` | Celle orario calendario desktop | ❌ |
| `--light-gray` | `#f8f9fa` | **Sfondo pagina** (home, login, prenotazioni) | ❌ |
| `--text-white` | `#ffffff` | Testo su superfici scure | ❌ |
| `--text-dark` | `#333333` | Testo body di default | ❌ |
| `--personal-training` | `#22c55e` | Colore tipo-slot "Personal training" (verde) | ⚠️ vedi §1.4 |
| `--small-group` | `#fbbf24` | Colore tipo-slot "Small group" (ambra) | ⚠️ |
| `--group-class` | `#ef4444` | Colore tipo-slot "Group class" (rosso) | ⚠️ |
| `--cleaning` | `#8b5cf6` | Colore tipo-slot "Pulizia" (viola) | ⚠️ |
| `--success` | `#06d6a0` | Verde-teal successo (toast success, badge confirmed, btn salva) | ❌ |
| `--warning` | `#f77f00` | Arancio warning (badge pending, banner super-admin) | ❌ |

`<meta name="theme-color" content="#8B5CF6">` su tutte le pagine (riscritto a runtime col colore org).

### 1.2 Token sezione Allenamento (`--all-*`, definiti su `body`) — design "Athletic Performance"

È la palette **slate** usata da allenamento, editor schede admin e (rinominata senza prefisso) da `tablet.css`.

| CSS var | Valore | Ruolo |
|---|---|---|
| `--all-purple` | `#8B5CF6` | primary locale (alias del brand) |
| `--all-purple-dark` | `#7C3AED` | primary dark |
| `--all-purple-glow` | `rgba(139,92,246,0.12)` | focus ring / tint viola |
| `--all-purple-glow-strong` | `rgba(139,92,246,0.22)` | tint viola forte |
| `--all-navy` | `#0f172a` | testo heading (slate-900) |
| `--all-navy-light` / `--all-slate` | `#1e293b` | testo body scuro (slate-800) |
| `--all-muted` | `#64748b` | testo secondario (slate-500) |
| `--all-subtle` | `#94a3b8` | testo terziario/placeholder (slate-400) |
| `--all-border` | `#e2e8f0` | bordo default (slate-200) |
| `--all-border-hover` | `#cbd5e1` | bordo hover (slate-300) |
| `--all-surface` | `#ffffff` | superficie card |
| `--all-bg` | `#f1f5f9` | sfondo pagina (slate-100) |
| `--all-success` | `#10b981` | verde successo (emerald-500) |
| `--all-success-dark` | `#059669` | emerald-600 |
| `--all-success-glow` | `rgba(16,185,129,0.12)` | tint verde |
| `--all-amber` | `#f59e0b` | ambra (superset, warning) |
| `--all-amber-glow` | `rgba(245,158,11,0.12)` | tint ambra |
| `--all-cyan` | `#06b6d4` | ciano (circuiti) |
| `--all-cyan-dark` | `#0891b2` | ciano scuro |
| `--all-cyan-glow` | `rgba(6,182,212,0.12)` | tint ciano |
| `--all-red` | `#ef4444` | rosso danger |
| `--all-red-glow` | `rgba(239,68,68,0.12)` | tint rosso |

Token report AI (`--rep-*`): `--rep-brand #8B5CF6`, `--rep-brand-strong #7C3AED`, `--rep-header-ink #0f172a`, `--rep-green #16a34a`, `--rep-green-bg #dcfce7`, `--rep-green-ink #166534`.

### 1.3 Token Super-Admin (`--sa-*`) — UNICA pagina interamente dark

| CSS var | Valore | Ruolo |
|---|---|---|
| `--sa-bg` | `#0f0f14` | sfondo (con radial-gradient viola `rgba(139,92,246,0.10)` in alto a dx) |
| `--sa-card` | `rgba(255,255,255,0.035)` | card glass |
| `--sa-card-2` | `rgba(255,255,255,0.05)` | card glass 2 / input |
| `--sa-border` | `rgba(139,92,246,0.18)` | bordo viola |
| `--sa-border-2` | `rgba(255,255,255,0.08)` | bordo neutro |
| `--sa-text` | `#f4f4f7` | testo |
| `--sa-muted` | `#9aa0ad` | testo secondario |
| `--sa-radius` | `16px` | radius card |

### 1.4 Colori tipi-slot (calendario / prenotazioni) — ⚠️ per-org a runtime

**Importante per Flutter**: in PalestrIA SaaS i tipi di lezione sono definiti per-org nella tabella
`slot_types` (colonna `color`). Il JS applica i colori **inline** via `getSlotColor()`; le classi CSS
qui sotto sono i **default** (org demo). Il tema Flutter deve prevedere colori slot dinamici.

| Tipo | Base | Gradiente cella calendario (135deg) | Card mobile (gradiente to-right) | Pip capacità |
|---|---|---|---|---|
| personal-training | `#22c55e` | `#22c55e → #16a34a` | `rgba(34,197,94,0.25) → rgba(34,197,94,0.05)`, bordo sx 5px `#22c55e` | `#16a34a` |
| small-group | `#fbbf24` | `#fbbf24 → #d97706` | `rgba(251,191,36,0.3) → rgba(251,191,36,0.08)` | `#f59e0b` |
| group-class | `#ef4444` | `#ef4444 → #dc2626` | `rgba(239,68,68,0.2) → rgba(239,68,68,0.05)` | `#ef4444` |
| cleaning | `#8b5cf6` | `#8b5cf6 → #7c3aed` | `rgba(139,92,246,0.2) → rgba(139,92,246,0.05)` | `#06b6d4` |

- Pip "vuoto": stesso colore con alpha `0.28` (neutro vuoto `#e2e8f0`, neutro pieno `#cbd5e1`).
- Pill titolo split-slot: PT `#dcfce7`/`#16a34a` · SG `#fef9c3`/`#b45309` · GC `#fee2e2`/`#dc2626` · CL `#ede9fe`/`#7c3aed`.
- Testo sopra i gradienti slot: `#111` (peso 500).
- Indicatore posti (`spots-*`): dark `#111` · green `#16a34a` · orange `#ea7b0a` · red `#dc2626`
  (versione chip mobile: stesso testo su bg `rgba(0,0,0,0.06)` / `rgba(22,163,74,0.1)` / `rgba(234,123,10,0.1)` / `rgba(220,38,38,0.1)`).

### 1.5 Scale semantiche ricorrenti (Tailwind-like, usate ovunque a mano)

- **Viola brand**: `#faf5ff` `#f5f3ff` `#ede9fe` `#f3e8ff` (bg) · `#d8b4fe` `#c4b5fd` `#a78bfa` (chiari) · `#8B5CF6` (500) · `#7C3AED` (600) · `#6D28D9` (700) · `#5b21b6` `#6b21a8` `#7e22ce` (testi scuri).
- **Verde**: bg `#f0fdf4` `#dcfce7` `#d1fae5` `#bbf7d0` · `#4ade80` `#22c55e` `#16a34a` `#15803d` `#166534` `#065f46` · emerald `#10b981` `#059669` `#047857`.
- **Rosso**: bg `#fef2f2` `#fee2e2` `#fecaca` `#fca5a5` · `#f87171` `#ef4444` `#dc2626` `#b91c1c` `#991b1b`.
- **Ambra**: bg `#fffbeb` `#fef3c7` `#fef9c3` `#fde68a` `#fcd34d` · `#fbbf24` `#f59e0b` `#d97706` `#b45309` `#92400e` `#854d0e`.
- **Blu**: bg `#eff6ff` `#dbeafe` `#e0f2fe` `#bae6fd` · `#60a5fa` `#3b82f6` `#2563eb` `#1d4ed8` `#1e40af` `#0369a1` `#075985`.
- **Ciano**: bg `#ecfeff` `#cffafe` · `#06b6d4` `#0891b2` `#0e7490`.
- **Grigi (slate)**: `#f8fafc` `#f1f5f9` `#e2e8f0` `#cbd5e1` `#94a3b8` `#64748b` `#475569` `#334155` `#1e293b` `#0f172a`.
- **Grigi (gray)**: `#f9fafb` `#f3f4f6` `#e5e7eb` `#d1d5db` `#9ca3af` `#6b7280` `#374151` + legacy `#eee #ddd #ccc #bbb #aaa #999 #888 #777 #666 #555 #444 #333 #111`.

### 1.6 Chip stati pagamento / badge (valori esatti)

| Stato | Sfondo | Testo |
|---|---|---|
| Pagato (`.preno-badge-paid`) | `#dcfce7` | `#166534` |
| Da pagare (`.preno-badge-unpaid`) | `#fef9c3` | `#854d0e` |
| Parziale (`.preno-badge-partial`) | `#ede9fe` | `#5b21b6` |
| Annullata (`.preno-badge-cancelled`) | `#f3f4f6` | `#6b7280` |
| Cancellazione richiesta | `#fef3c7` | `#92400e` |
| Pagato (pill admin `.payment-status.paid`) | `rgba(34,197,94,0.12)` | `#06d6a0` (var --success) |
| Da pagare (pill admin `.debt-warning`) | `rgba(245,158,11,0.16)` | `#b45309` |
| Saldo chip "deve" (`.saldo-chip.owes`) | `rgba(239,68,68,0.12)` | `#dc2626` |
| Saldo chip zero | `#f3f4f6` | `#6b7280` |
| Confirmed (`.status-badge.confirmed`) | `rgba(6,214,160,0.2)` | `#06d6a0` |
| Pending | `rgba(255,193,7,0.2)` | `#f77f00` |

Badge Registro eventi (`.rtype-*`): booking `#dbeafe/#1d4ed8` · paid `#dcfce7/#15803d` · cancelled `#fee2e2/#b91c1c` · pending `#fef3c7/#92400e` · credit `#f3e8ff/#7e22ce` · creditused `#e0f2fe/#0369a1` · refund `#cffafe/#0e7490` · debt `#fef9c3/#854d0e` · debtpaid `#d1fae5/#065f46` · mora `#fde68a/#92400e`.
Badge stato (`.rstatus-*`): paid `rgba(6,214,160,0.15)/#059669` · unpaid `#fee2e2/#b91c1c` · cancelled `#f3f4f6/#6b7280` · pending `#fef3c7/#92400e` · credit `#f3e8ff/#7e22ce` · debt `#fef9c3/#854d0e`.
Badge Super-admin (`.sa-badge`): trialing `rgba(139,92,246,0.18)/#c4b5fd` · active `rgba(6,214,160,0.16)/#6ee7b7` · past_due `rgba(247,127,0,0.18)/#fbbf24` · suspended `rgba(239,68,68,0.16)/#fca5a5` · cancelled `rgba(148,163,184,0.15)/#cbd5e1`.

### 1.7 Avatar partecipanti (6 tinte stabili per iniziali, hash sul nome)

| hue | Sfondo | Testo |
|---|---|---|
| 0 | `#cdecf9` | `#0b7fb0` |
| 1 | `#fef3c7` | `#b45309` |
| 2 | `#f3e8ff` | `#7e22ce` |
| 3 | `#dcfce7` | `#166534` |
| 4 | `#fee2e2` | `#b91c1c` |
| 5 | `#e0f2fe` | `#075985` |

Cancellazione pendente: `#fef3c7` / `#92400e`.

### 1.8 Gradienti chiave (esatti)

| Uso | Gradiente |
|---|---|
| Bottone/tab primario attivo | `linear-gradient(135deg, #8B5CF6, #7C3AED)` |
| Dock mobile admin | `linear-gradient(180deg, #8B5CF6 0%, #7C3AED 100%)` |
| Hero home (dark) | `linear-gradient(135deg, #1a1a1a 0%, #111 50%, #1a2a2a 100%)` + glow radiale `rgba(139,92,246,0.12)` |
| Hero prenotazioni | `linear-gradient(135deg, #1a1a1a 0%, #2a1f3d 50%, #6D28D9 100%)` + glow `radial rgba(139,92,246,0.45)` |
| Avatar hero / promo banner | `linear-gradient(135deg, #A78BFA 0%, #8B5CF6 50%, #6D28D9 100%)` |
| Login admin (sfondo) | `linear-gradient(135deg, #080808 0%, #111 55%, #091616 100%)` + 2 blob blur(90px) viola alpha 0.05–0.07 |
| Contenitore tab admin desktop | `linear-gradient(135deg, #f1f5f9, #e8ecf1)` |
| Tab "Privacy" attiva | `linear-gradient(135deg, #f59e0b, #d97706)` |
| CTA prenota | `linear-gradient(135deg, #8B5CF6 0%, #0088cc 100%)` |
| Barre accent stat card (top 3px) | fatturato `#f59e0b→#fbbf24` · prenotazioni `#3b82f6→#60a5fa` · clienti `#10b981→#34d399` · occupancy `#8b5cf6→#a78bfa` · debiti `#ef4444→#f87171` · crediti `#22c55e→#4ade80` |
| Bottoni azione Impostazioni | blue `#2563eb→#1d4ed8` · purple `#7c3aed→#6d28d9` · green `#059669→#047857` · red `#ef4444→#dc2626` |
| Save allenamento | `linear-gradient(135deg, #8B5CF6, #7C3AED)` + inset highlight `rgba(255,255,255,0.15)`; variante done `#10b981→#059669` |
| Progress bar orari popolari | `linear-gradient(90deg, #8B5CF6, #7C3AED)`; bassa `#94a3b8→#64748b` |

### 1.9 Colori terze parti / social

WhatsApp FAB `#25D366` (hover `#1ebe5a`, shadow `rgba(37,211,102,0.45)`) · Facebook `#1877F2` · Apple `#000` · Google: bianco con bordo `#ddd`, testo `#444`.

---

## 2. TIPOGRAFIA

### 2.1 Famiglie

| Contesto | font-family |
|---|---|
| **App principale** (tutte le pagine) | `'Segoe UI', Tahoma, Geneva, Verdana, sans-serif` |
| Tablet mode (`tablet.css`) | `system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif` |
| Super-admin | `-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif` |
| Nutrizione (display) | `'Barlow Condensed', 'Segoe UI', sans-serif` (titoli); `Georgia, serif` (citazioni, note corsive report) |
| Hint tecnici login admin | `monospace` |

**Flutter**: 'Segoe UI' non esiste su Android/iOS → il match visivo migliore è il **font di sistema**
(Roboto/SF Pro) oppure includere *Segoe UI-like* (es. `Inter` o `Open Sans`) come custom font. La web
app di fatto rende con Segoe UI su Windows e col system font su mobile: usare il default di piattaforma è fedele.

### 2.2 Dimensione base e scala

- `html`: 16px su mobile. **⚠️ Su desktop (≥769px) `html { font-size: 12px }`** — tutta la UI in rem
  si riscala al 75% (design "compatto" desktop). In Flutter (mobile-first) usare la scala mobile 16px.
- `body`: `line-height: 1.6`, colore `#333333` (o `#1e293b` nelle pagine slate).

Scala tipografica effettiva (mobile, 1rem = 16px):

| Ruolo | Size | Weight | Note |
|---|---|---|---|
| Hero name (home) | 3rem (48) → mobile 1.7rem (27) | 800 | letter-spacing 2px→1px, line-height 1.1 |
| Hero role (overline) | 1rem → 0.78rem | 600 | UPPERCASE, letter-spacing 5px→2px, colore primary |
| H2 sezione | 2rem (32) → 1.2rem mobile | 700 (default bold) | colore `#1a1a1a` |
| Titolo pagina tab admin | 1.65rem (26.4) | 800 | letter-spacing −0.02em, `#0f172a` |
| Titolo header Impostazioni | 1.4rem | 800 | −0.02em |
| Nome hero prenotazioni | 1.45rem → 1.25rem | 800 | −0.02em, bianco |
| Titolo modal / login | 1.5rem / 1.3rem | 700 | |
| Stat value (KPI) | 2rem (32) | 800 | −0.02em, `tabular-nums`, line-height 1.15 |
| KPI super-admin | 1.7rem | 800 | |
| Titolo card | 0.95–1.1rem | 700–800 | −0.01em |
| Body / testo card | 0.88–0.95rem | 500–600 | |
| Label form | 0.82–0.85rem | 600 | `#555`/`#444` |
| Meta / sottotitoli | 0.78–0.82rem | 500 | `#888`/`#64748b` |
| Badge / chip | 0.72–0.78rem | 600–800 | letter-spacing 0.01–0.02em |
| Eyebrow / group label | 0.62–0.72rem | 700–800 | UPPERCASE, letter-spacing 0.04–0.10em |
| Micro (credit sidebar, dot) | 0.65–0.68rem | 500–700 | |

### 2.3 Pesi e dettagli

- Pesi usati: **500** (testo), **600** (semibold, label/menu), **700** (bold, titoli/badge), **800** (extra-bold, heading e valori numerici — cifra distintiva del design).
- **`font-variant-numeric: tabular-nums`** su TUTTI i numeri/importi/orari (in Flutter: `FontFeature.tabularFigures()`).
- Letter-spacing: negativo sui titoli grandi (−0.02em / −0.01em), positivo sulle UPPERCASE (0.04–0.10em, fino a 5px sull'overline hero).
- Input mobile: **`font-size: 16px` fisso** (anti-zoom iOS) — in Flutter non serve.
- `-webkit-font-smoothing: antialiased` sulle pagine slate.

---

## 3. SPAZIATURE E GEOMETRIA

### 3.1 Scala spaziature ricorrente (rem)

`0.25 / 0.3 / 0.4 / 0.5 / 0.6 / 0.75 / 0.85 / 1 / 1.1 / 1.25 / 1.5 / 1.75 / 2 / 2.5 / 3` rem
→ in px (mobile): 4 / 5 / 6.5 / 8 / 10 / 12 / 13.5 / 16 / 17.5 / 20 / 24 / 28 / 32 / 40 / 48.
Suggerimento Flutter: scala 4-based `4, 8, 12, 16, 20, 24, 32, 40, 48`.

- Padding card: `1rem 1.15rem` (mobile) · `1.4rem 1.35rem 1.2rem` (stat card) · `2rem` (dashboard card desktop).
- Gap liste card: `0.5–0.75rem`. Gap grids: `1rem` (stats) / `2rem` (dashboard).
- Container: max-width **1200px** (`padding 0 20px`; mobile `0 12px`); desktop app ridotta a **900px**;
  admin: 620px (tab strette) / 1280px (`--wide`) / 1400px (dashboard).
- Safe-area iOS: `env(safe-area-inset-bottom)` su dock, sheet e sidebar (Flutter: `SafeArea`).

### 3.2 Border-radius per componente

| Componente | Radius |
|---|---|
| Bottone base (`.btn-primary`, `.btn-control`) | 5px (desktop web) → **8px** mobile/modali; admin 10px |
| Bottone piccolo/riga (`.btn-save-edit` ecc.) | 6px |
| Input | 8px (base) · 10px (admin/profile) · 11px (allenamento) |
| Chip / badge / pill | **20px o 999px** (full pill) |
| Card | **14px** (preno-card, tabs container) · **16px** (`--all-radius`, stat card, saldo card) |
| Card piccola / tile icona | 10–12px (`--all-radius-sm` = 12) |
| Modal / dialog | **16px** (`.modal-box`) · **18px** (`.all-modal-box`, login admin, stats panel) |
| Bottom sheet | **16–20px solo in alto** (`border-radius: 20px 20px 0 0` admin, 16px pubblico) |
| Dock mobile admin | 16px |
| Toast | 12px |
| Toggle switch | pill (24px / 13px track) |
| FAB / avatar / spinner / radio | 50% (cerchio) |
| Drag handle sheet | 2px (36×4px) / 999px (40×4px admin) |
| Tab attiva dentro pill-bar | 10–11px |

### 3.3 Ombre (box-shadow esatte)

| Token/uso | Valore |
|---|---|
| `--all-shadow` (card riposo) | `0 1px 3px rgba(15,23,42,0.06), 0 1px 2px rgba(15,23,42,0.04)` |
| `--all-shadow-md` (hover) | `0 4px 16px rgba(15,23,42,0.08), 0 2px 4px rgba(15,23,42,0.04)` |
| `--all-shadow-lg` (overlay) | `0 12px 32px rgba(15,23,42,0.12), 0 4px 8px rgba(15,23,42,0.06)` |
| `--all-shadow-glow` (focus/selected) | `0 0 0 3px rgba(139,92,246,0.12), 0 4px 16px rgba(139,92,246,0.10)` |
| Card standard (preno/tabs) | `0 1px 3px rgba(0,0,0,0.04), 0 2px 8px rgba(0,0,0,0.05)` |
| Card hover | `0 4px 12px rgba(0,0,0,0.08), 0 8px 24px rgba(0,0,0,0.06)` |
| Stat card | `0 1px 3px rgba(0,0,0,0.03), 0 4px 14px rgba(0,0,0,0.04)` + bordo `1px rgba(0,0,0,0.06)` |
| Stat card hover (glow tinto) | `0 8px 28px rgba(<colore>,0.14), 0 2px 6px rgba(0,0,0,0.03)` |
| Modal | `0 20px 60px rgba(0,0,0,0.3)` · all-modal `0 12px 40px rgba(0,0,0,0.15)` |
| Bottom sheet | `0 -10px 30px rgba(0,0,0,0.18)` |
| Login card | `0 8px 32px rgba(0,0,0,0.12)` |
| Login admin (dark) | `0 28px 80px rgba(0,0,0,0.65), 0 0 60px rgba(139,92,246,0.06)` |
| Navbar | `0 2px 10px rgba(0,0,0,0.3)` |
| Toast | `0 4px 20px rgba(0,0,0,0.18)` |
| Elemento attivo viola (tab/bottone) | `0 2px 8px rgba(139,92,246,0.3)` |
| FAB | `0 4px 16px rgba(139,92,246,0.35), 0 2px 4px rgba(0,0,0,0.1)`; hover `0 6px 24px rgba(139,92,246,0.45), 0 3px 6px rgba(0,0,0,0.12)` |
| Dock admin | `0 12px 24px -8px rgba(124,58,237,0.45), 0 4px 10px -4px rgba(15,23,42,0.20), inset 0 1px 0 rgba(255,255,255,0.25)` |
| Pill filtro mobile | `0 4px 12px -4px rgba(15,23,42,0.12), 0 1px 2px rgba(15,23,42,0.06)` |
| Focus ring input | `0 0 0 3px rgba(139,92,246,0.10–0.15)` + bordo primary |

### 3.4 Bordi

- Default: `1px solid #e2e8f0` (slate) o `#e5e7eb` (gray); card "invisibile" `1px rgba(0,0,0,0.06)`.
- Input: `1.5px` (login/admin) o `2px` (form pubblici) solid `#ddd`/`#e0e0e0`/`#e5e7eb`/`#e2e8f0` → focus `--primary-purple`.
- Bordo sinistro colore-tipo: **4–5px** sulle card prenotazione/warning (info box 4px, slot card 5px).
- Bordo tratteggiato (`dashed`) sui bottoni "aggiungi" (1.5px, `#e2e8f0`→viola hover).
- Barra accent top card: 3px (gradient, vedi §1.8); barra attiva day-tab 2.5px.
- Divider: `1px #f0f0f0` / `#f1f5f9` / `#e2e8f0`; su dark `rgba(255,255,255,0.05–0.15)`.

---

## 4. COMPONENTI RICORRENTI

### 4.1 Bottoni

| Variante | Stile |
|---|---|
| **Primario** (`.btn-primary`) | bg `--primary-purple`, testo bianco bold, radius 5→8px, padding `1rem 2rem` (modal `0.75rem`); hover: bg `--primary-purple-dark` + `translateY(-2px)` + shadow `0 4px 12px rgba(139,92,246,0.3)`; disabled bg `#ccc` |
| **Primario gradient** (admin) | `linear-gradient(135deg,#8B5CF6,#7C3AED)`, radius 8–10, weight 600–700, shadow `0 4px 20px rgba(139,92,246,0.28)` |
| **Secondario/outline** | bg `#fff`, bordo `1.5px #e5e7eb`, testo colorato (es. viola `.preno-show-more`, rosso `.preno-cancel-btn`), pill o radius 14; hover: bordo colore pieno + bg tint (`#fee2e2` per danger) |
| **Danger soft** | bg `#fff`, bordo `#fecaca`, testo `#ef4444`; hover bg `#fef2f2` |
| **Success** | bg `#06d6a0` (var --success), testo bianco, radius 6 |
| **Ghost/testo** | bg `none`, testo `#888`; hover testo viola; su dark `rgba(255,255,255,0.06)` + bordo `rgba(255,255,255,0.14)` |
| **Azione settings** (`.sett-action-btn`) | gradient per colore (§1.8), radius 10, `0.55rem 1.1rem`, 0.82rem/700, shadow tinta `0 2px 8px rgba(c,0.3)` |
| **Dashed add** | `1.5px dashed #e2e8f0`, testo `#64748b` 0.78rem/700 → hover viola su tint `rgba(139,92,246,0.12)` |
| **Save workout** (`.all-log-save`) | full-width, gradient viola, UPPERCASE 0.88rem/800 ls 0.04em, radius 12, inset highlight; done → gradient verde |
| **Pill filtro** (`.adm-filt-pill`) | pill 999, bordo `#e2e8f0`, bg `#fff`, testo `#475569` 0.82rem/600; attiva → gradient viola, testo bianco |

**Stati press (mobile)**: `:active { transform: scale(0.94–0.98) }` ovunque; hover desktop `translateY(-1/-2px)`.
Min-height touch: 34–44px (sheet btn 44, filtro 40, dock 60).

### 4.2 Card

- **Card lista** (prenotazione): bianco, radius 14, bordo-sx 5px colore tipo, padding `1rem 1.15rem`, shadow standard, hover lift −2px.
- **Stat card**: bianco, radius 16, bordo `rgba(0,0,0,0.06)`, barra top 3px gradient, icona in tile 2.85rem radius 12 con bg tinta `rgba(c,0.10)`, label UPPERCASE 0.7rem `#9ca3af`, valore 2rem/800.
- **Card esercizio** (`.all-ex-card`): bianco, bordo `1.5px #e2e8f0`, radius 16, barra sx 3px (trasparente → viola se aperta, verde se done), header 0.9×1.1rem, accordion body; aperta = bordo viola + shadow-glow; done = bg `linear-gradient(145deg,#f0fdf4,#fff 60%)`.
- **Hero card scura** (prenotazioni/assegna scheda): gradient scuro→viola, radius 18, glow radiale interno, testo bianco, shadow `0 4px 20px rgba(109,40,217,0.25) + inset ring rgba(255,255,255,0.06)`.
- **Card KPI super-admin**: glass `rgba(255,255,255,0.035)` + bordo viola alpha su dark.

### 4.3 Chip / Badge

Pill radius 20/999, padding `0.2–0.25rem 0.6–0.75rem`, 0.72–0.78rem/600–800, combinazioni colore §1.6.
Badge tipo-slot nel modal: pill piena colore tipo, testo bianco UPPERCASE 0.8rem/700 ls 0.04em.

### 4.4 Input / Select / Toggle

- **Testo**: bg `#fff` (o `#f8fafc` in allenamento), bordo 1.5–2px grigio, radius 8–11, padding `0.55–0.75rem 0.75rem`; focus: bordo viola + ring `0 0 0 3px rgba(139,92,246,0.10)`; disabled bg `#f9fafb` testo `#999`; placeholder `#94a3b8`.
- **Login admin (dark)**: bg `rgba(255,255,255,0.05)`, bordo `rgba(255,255,255,0.1)`, testo bianco; focus bg `rgba(139,92,246,0.07)`.
- **Select allenamento**: pill bianca radius 11 senza bordo, freccia SVG custom; focus = bg viola pieno testo bianco.
- **Checkbox**: `accent-color: var(--primary-purple)`, 18px.
- **Toggle iOS-style**: track 44×24 (settings 44×26) radius pill, bg `#d1d5db`/`#cbd5e1` → checked viola (o gradient viola + shadow); thumb bianco 18–20px, shadow `0 1px 2px rgba(0,0,0,0.2)`, translate 20px/18px, transizione 0.2–0.25s.
- **Radio sheet**: cerchio 22px bordo 2px `#cbd5e1` → attivo riempito `#8B5CF6` con pallino interno bianco 8px.
- **Search**: input full-width con dropdown suggerimenti card bianca sotto (radius 10, shadow md).

### 4.5 Modali / Popup / Bottom sheet

- **Overlay**: `rgba(0,0,0,0.55)` (pubblico) / `rgba(0,0,0,0.4)` (allenamento) / `rgba(15,23,42,0.45)` (admin sheet); fadeIn 0.2–0.25s.
- **Desktop/tablet**: dialog centrato, bianco, radius 16–18, padding 1.5–2rem, max-width 400–680px, max-height 90vh, shadow `0 20px 60px rgba(0,0,0,0.3)`, animazione **slideUp 0.25s ease** (`translateY(30px)→0` + fade). Bottone X: cerchio 32px bg `#f0f0f0`, hover `#ddd`.
- **Mobile (≤600px)**: diventa **bottom sheet**: allineato in basso, `border-radius: 16px 16px 0 0`, max-height `80dvh`, animazione **slideUpSheet 0.3s ease** (`translateY(100%)→0`), **drag handle** 36×4px `#ccc` radius 2, X nascosta (tap fuori per chiudere).
- **Admin sheet** (filtri/nav): radius top 20, grabber 40×4 `#cbd5e1`, titolo 1.05rem/700, lista item 48px con tile icona 36px radius 10 bg `#f1f5f9` (attiva → gradient viola), footer 2 bottoni (ghost `#f1f5f9`/`#475569` + primary gradient), transizione `transform 0.3s cubic-bezier(0.4,0,0.2,1)`.
- **Modal conferma prenotazione**: bg gradient viola (135deg primary→dark), testo bianco, radius 12.
- **Drawer super-admin**: da destra, `translateX(100%)→0` 0.25s, width min(460px,100%), bg `#14141b`.
- **Social login modal**: scende dall'alto (`socialSlideDown 0.3s`, translateY −100%→0), radius `0 0 16px 16px`.

### 4.6 Toast / Notifiche

- Container: fixed bottom 24px, centrato, max-width 420px, stack column gap 10.
- Toast: radius 12, padding `12px 18px`, testo bianco 0.9rem/500, icona + messaggio, shadow `0 4px 20px rgba(0,0,0,0.18)`.
- Colori: success `#06d6a0` · error `#ef4444` · info `--primary-purple`.
- Animazione: entra con `opacity 0→1` + `translateY(12px)→0` in 0.25s ease (classe `.toast-visible`); tap per chiudere.
- Variante super-admin: bg `#1d1d27` bordo viola, slide dal basso `translateY(120%)→0`.

### 4.7 Navigazione

- **Navbar (pubblica)**: bg `#1a1a1a` sticky, shadow, logo 48–52px radius 6; link `rgba(255,255,255,0.82)` 0.95rem/500 radius 6, hover/active testo viola + bg `rgba(139,92,246,0.1)`; bottone login pill viola.
- **Sidebar mobile (hamburger)**: panel destro 270px bg `#1a1a1a`, slide `right: -300px→0` 0.3s `cubic-bezier(0.4,0,0.2,1)`, overlay `rgba(0,0,0,0.55)`; voci con bordo-sx 3px trasparente → viola hover; logout rosso `#ff7070`.
- **Tab pill-bar** (prenotazioni/allenamento — pattern principale mobile): container bianco radius 14 padding 0.3rem shadow leggera; tab flex-1 0.88rem/600 `#888` radius 11; **attiva = bg viola testo bianco + shadow viola**; divider verticali 1px `#ddd` tra tab inattive.
- **Tab admin desktop**: barra sticky gradient `#f1f5f9→#e8ecf1`, bordo `#e2e8f0`, radius 14; tab 0.95rem/700 `#64748b` radius 10; attiva gradient viola.
- **Dock mobile admin** (bottom, page-switcher): bottone full-width min-h 60 gradient viola radius 16, tile icona 38px `rgba(255,255,255,0.20)` radius 10, eyebrow UPPERCASE 0.62rem/700 `rgba(255,255,255,0.78)`, nome 0.98rem/800 bianco, chevron; sta in uno stack fixed col gradiente di dissolvenza `rgba(248,250,252,0→1)` + pill "Filtri" sopra (bianca, pill, bordo `#e2e8f0`).
- **Day-selector** (calendario mobile): card giorno bianche bordo 2px `#ddd` radius 10, attiva gradient viola scale(1.05); giorno con iscrizione bg `rgba(239,68,68,0.12)`; day-tab allenamento: bordo 1.5px, top-bar 2.5px colore stato, attiva ring `0 0 0 3px glow`.

### 4.8 Tabelle / Liste

- Tabella: th bg `#1a1a1a` testo bianco 600 padding 1rem; td padding 1rem, bordo-bottom `1px #eee`; row hover `#f8f9fa`; wrapper `overflow-x: auto`.
- Su mobile (≤768px) le tabelle diventano **liste di card** (pattern super-admin: `td` flex con `::before` etichetta UPPERCASE).
- Liste: card separate con gap 0.5–0.75rem (mai divider-only).

### 4.9 Empty state / Loading

- **Empty**: testo centrato `#999`/`#94a3b8` 0.9rem, line-height 1.4–1.8, in card bianca radius 14 (`.preno-empty`) o nudo con padding 3–4rem (`.all-empty`, `.sa-empty`).
- **Spinner**: cerchio `border: 3px solid #e2e8f0` (o rgba viola 0.25) con `border-top-color: #8B5CF6`, 34–36px, `spin 0.7–0.8s linear infinite`; inline nei bottoni 14px bordo 2px `rgba(255,255,255,0.4)` top bianco.
- **Skeleton**: blocchi `#e5e7eb` radius 6 con `skeleton-pulse 1.2s ease-in-out infinite` (opacity 1→0.4→1).
- **Bottone loading**: `.btn-loading` = opacity 0.8 + spinner + pointer-events none.

### 4.10 FAB

56px cerchio viola pieno, icona bianca, `bottom/right 1.5rem`, shadow viola; hover `scale(1.08)`, active `scale(0.95)`; su mobile admin risale sopra il dock (`bottom: 84px + safe-area`). WhatsApp FAB 58px `#25D366`.

---

## 5. ANIMAZIONI E TRANSIZIONI

### 5.1 Durate

| Durata | Uso |
|---|---|
| 0.1–0.15s | micro-interazioni (press, hover icone) |
| **0.2s** | standard (`--all-transition`), colori/bordi/bg |
| 0.25s | toast, modal slideUp, drawer, fade contenuti |
| **0.3s** | bottom sheet, sidebar, accordion, tab fade |
| 0.35s | spring (`--all-transition-spring`), banner PWA |
| 0.5s | progress bar width |
| 0.7–0.8s | spinner (linear infinite) |
| 1.2s | skeleton pulse |
| 3s | sparkle decorativo (infinite) |

### 5.2 Easing

| Curva | Uso | Flutter |
|---|---|---|
| `ease` | default legacy | `Curves.ease` |
| `cubic-bezier(0.4, 0, 0.2, 1)` | **standard** (Material) — sheet, sidebar, tab | `Curves.fastOutSlowIn` |
| `cubic-bezier(0.34, 1.56, 0.64, 1)` | spring con overshoot (check pop, giorno attivo) | `Curves.easeOutBack` (≈) |
| `cubic-bezier(0.22, 1, 0.36, 1)` | easeOutQuint (stat card, panel) | `Curves.easeOutQuint` |
| `ease-out` / `ease-in-out` | accordion / pulse | `Curves.easeOut` / `easeInOut` |

### 5.3 Keyframes principali

- `fadeIn`: opacity 0→1 (versione admin: + translateY 10px→0), 0.2–0.3s.
- `slideUp` (modal): translateY 30px→0 + fade, 0.25s.
- `slideUpSheet`: translateY 100%→0, 0.3s.
- `socialSlideDown`: translateY −100%→0 + fade, 0.3s.
- `allPop` (check verde): scale 0→1.15 (60%)→1, 0.35s spring.
- `allSlideDown` (accordion): opacity 0 + translateY −8px → 0, 0.3s ease-out.
- `allFadeUp` / `tabFadeUp`: fade + rise per card in ingresso.
- `btn-spin`/`allSpin`/`sa-spin`: rotate 360°, 0.7–0.8s linear infinite.
- `skeleton-pulse`: opacity 1→0.4→1, 1.2s infinite.
- `promoSparkle`: opacity 0.3→0.9 + scale 1→1.6, 3s infinite (decorativo banner).
- Chevron accordion: `rotate(180deg)` 0.3s; freccia details `rotate(90deg)` 0.2s.

### 5.4 Pattern hover→press (per il port mobile)

Su web: hover = lift (`translateY(-1/-2px)` + shadow più ampia) o tint bg; press = `scale(0.94–0.98)`.
In Flutter: mappare il press su `InkWell`/`GestureDetector` con `AnimatedScale` (0.97, 100–150ms) e
ignorare gli stati hover (o tenerli per tablet/desktop). `prefers-reduced-motion` è rispettato
(animazioni → 0.01ms): in Flutter usare `MediaQuery.disableAnimations`.

---

## 6. RESPONSIVE

### 6.1 Breakpoint usati

| Breakpoint | Uso |
|---|---|
| `max-width: 380px` | telefoni piccolissimi (riduzioni font) |
| `max-width: 480px` | telefono compatto (padding/font ridotti) |
| `max-width: 600px` | **modal → bottom sheet**, riduzioni card |
| `max-width: 640/768px` | **mobile ↔ desktop principale**: calendario griglia→lista verticale, tab admin→dock, tabelle→card, hamburger |
| `min-width: 769px` | desktop: **html 12px**, container 900px, nasconde sidebar/hamburger |
| `min-width: 1024px` | admin desktop: sidebar verticale + topbar (sostituisce le tab) |
| `min-width: 1600px` | super-admin padding extra |
| `display-mode: standalone` | aggiustamenti PWA (dock iOS) |
| `orientation: landscape + max-height 600px` | tablet QR |

### 6.2 Differenze mobile/desktop rilevanti per Flutter (mobile-first)

- **Mobile è il layout di riferimento**: calendario = day-selector orizzontale + lista slot verticale; admin = dock viola in basso + bottom sheet per nav/filtri; modali = bottom sheet con grabber; FAB sopra il dock.
- Desktop aggiunge: griglia calendario 8 colonne, sidebar admin, hover states, scala font 75%.
- Layout a card fluide (`grid auto-fit minmax(220px,1fr)`) per le stat → in Flutter `GridView`/`Wrap` con 2 colonne su phone.

---

## 7. DARK MODE

**Non esiste una dark mode utente.** L'app è light-only e lo dichiara: `color-scheme: light` sui
loghi/pagine (evita inversioni UA). Le uniche superfici scure sono **di design, fisse**:

1. Navbar / footer / hero (bg `#1a1a1a`).
2. Schermata login admin (gradient near-black + glass card).
3. Hero card viola-scure (prenotazioni, assegna-scheda, report).
4. **Super-admin** (`super-admin.html`): pagina interamente dark (`color-scheme: dark`, palette `--sa-*`) — è uno strumento interno della piattaforma, non del tenant.

Per Flutter: `themeMode: ThemeMode.light`; le superfici scure si modellano come componenti con colori
fissi (non con un dark `ColorScheme`).

---

## 8. MAPPATURA FLUTTER CONSIGLIATA

### 8.1 ColorScheme (light)

| Token CSS | Flutter `ColorScheme` | Valore default |
|---|---|---|
| `--primary-purple` | `primary` | `Color(0xFF8B5CF6)` |
| `--primary-purple-dark` | `primaryContainer`* / tinta pressed | `Color(0xFF7C3AED)` |
| bianco su viola | `onPrimary` | `Colors.white` |
| `rgba(139,92,246,0.1)` | `primary.withOpacity(.10)` (tint attivo) | — |
| `--light-gray` / `--all-bg` | `surfaceContainerLowest` / scaffold | `0xFFF8F9FA` (pubblico) / `0xFFF1F5F9` (allenamento/admin) |
| `#ffffff` | `surface` | `0xFFFFFFFF` |
| `--text-dark` / `--all-navy` | `onSurface` | `0xFF333333` (pubblico) / `0xFF0F172A` (slate) |
| `--all-muted` `#64748b` | `onSurfaceVariant` | `0xFF64748B` |
| `--all-border` `#e2e8f0` | `outlineVariant` | `0xFFE2E8F0` |
| `#cbd5e1` | `outline` | `0xFFCBD5E1` |
| `--group-class`/`--all-red` `#ef4444` | `error` | `0xFFEF4444` |
| `#fef2f2` | `errorContainer` | `0xFFFEF2F2` |
| `--success` `#06d6a0` (+ scala verde `#22c55e/#16a34a`) | extension `success` | `0xFF06D6A0` |
| `--warning` `#f77f00` (+ ambra `#f59e0b`) | extension `warning` | `0xFFF77F00` |
| `--dark-bg` `#1a1a1a` | `inverseSurface` (navbar/footer) | `0xFF1A1A1A` |

\* meglio un **`ThemeExtension` custom** (`PalestriaColors`) con: `primaryDark`, `success`, `successBg`,
`warning`, `warningBg`, `danger`, `dangerBg`, `info`, `infoBg`, `slotColors` (mappa per tipo, runtime),
`avatarHues` (6 coppie §1.7), `chipPaid/chipUnpaid/chipPartial/chipCancelled` (coppie bg/fg §1.6).

### 8.2 TextTheme (base 16, system font, tabular nums sui numeri)

| Ruolo web | TextTheme | Size/Weight/Spacing |
|---|---|---|
| Hero name | `displaySmall` | 27–48 / w800 / ls 1–2 |
| Titolo pagina (1.65rem/800/−0.02em) | `headlineMedium` | 26 / w800 / ls −0.5 |
| Titolo sezione/modal (1.3–1.5rem) | `headlineSmall`/`titleLarge` | 21–24 / w700 |
| Stat value | `displaySmall` + `FontFeature.tabularFigures()` | 32 / w800 / ls −0.6 |
| Titolo card (0.95–1.1rem/700-800) | `titleMedium` | 15–17.5 / w700 |
| Body (0.88–0.95rem) | `bodyMedium` | 14–15 / w500 |
| Label form (0.82–0.85rem/600) | `labelLarge` | 13 / w600 |
| Meta (0.78rem) | `bodySmall` | 12.5 / w500 |
| Badge (0.72–0.78rem/700) | `labelMedium` | 11.5–12.5 / w700 |
| Eyebrow UPPERCASE (0.62–0.72rem/800, ls 0.04–0.1em) | `labelSmall` | 10–11.5 / w800 / ls 0.6–1.6 |

### 8.3 Component themes

| Componente web | Flutter |
|---|---|
| `.btn-primary` | `FilledButton` — bg primary, radius 8–10, `minimumSize height 48`, textStyle w700; pressed: `AnimatedScale 0.97` |
| Bottoni gradient | custom `GradientButton` (Ink + `BoxDecoration.gradient` 135°, shadow tinta `0 2px 8px color(0.3)`) |
| Outline/danger soft | `OutlinedButton` — side `1.5px #e5e7eb`, fg colore semantico, shape `StadiumBorder` per le pill |
| Card | `CardTheme`: white, `RoundedRectangleBorder(14–16)`, elevation 0 + `BoxShadow` custom (§3.3), bordo `#e2e8f0`; barra colore tipo = `Container` 5px in `Row` o `Border(left:)` |
| Chip/badge | `Chip`/custom pill: `StadiumBorder`, padding `2×10`, label 12/w700, coppie colore §1.6 |
| Input | `InputDecorationTheme`: filled white (`#f8fafc` in allenamento), `OutlineInputBorder(10, #e2e8f0 1.5px)`, focused viola 1.5–2px (il ring `0 0 0 3px` si simula con `focusedBorder` più spesso o wrapper con shadow), contentPadding `12×14` |
| Toggle | `SwitchTheme`: track 44×24 pill (`#d1d5db`→primary), thumb bianco 18–20 (Material 3 Switch è già ~fedele; impostare `trackOutlineColor: transparent`) |
| Modal desktop / mobile | `showDialog` (radius 18) su ≥600dp; **`showModalBottomSheet`** su phone: `shape: RoundedRectangleBorder(vertical top 16–20)`, `showDragHandle: true` (handle `#cbd5e1` 40×4), barrier `rgba(15,23,42,0.45)`, `animationDuration 300ms` + `Curves.fastOutSlowIn` |
| Toast | `SnackBarTheme`: `behavior: floating`, radius 12, `width ≤420`, bg per severità (§4.6), text white w500; oppure package toast custom bottom-centered |
| Tab pill-bar | custom `SegmentedPillBar`: container bianco radius 14 padding 5, item selezionato `AnimatedContainer` viola radius 11 + shadow; NON usare `TabBar` Material di default |
| Dock admin | custom bottom bar: `Container` gradient viola radius 16 dentro `Padding` con fade — non `NavigationBar` standard |
| FAB | `FloatingActionButtonTheme`: bg primary, fg white, `shape: CircleBorder()`, elevation ~6 |
| Tabelle | su phone: liste di card (come fa già la web app mobile); `DataTable` solo per tablet/desktop |
| Spinner | `CircularProgressIndicator(strokeWidth: 3, color: primary, backgroundColor: #e2e8f0)` |
| Skeleton | shimmer/pulse su blocchi `#e5e7eb` radius 6, periodo 1.2s |
| Empty state | testo centrato `#94a3b8` 14–15, dentro card bianca radius 14 quando in lista |

### 8.4 Tema dinamico runtime (branding per-org) — OBBLIGATORIO

Il colore primario **non è una costante**: ogni tenant può cambiarlo. Flusso web (da replicare):

1. `OrgSettings.load()` legge `org_settings` (autenticato: select filtrata per `org_id`; anonimo: RPC
   `get_public_org_settings(p_org_slug)`), con cache localStorage namespaced `org_<id>_<key>`.
2. Chiavi rilevanti per il tema:
   - **`branding.primary_color`** → `--primary-purple` (= `ColorScheme.primary`) + `theme-color` (= status bar / `SystemChrome`).
   - dark derivato: **`_darkenHex(color, 10)`** = ogni canale RGB × 0.9 → `--primary-purple-dark`.
   - **`branding.logo_url`** → logo navbar/login; **`branding.favicon_url`** → icona; **`branding.studio_name`** → nome mostrato; **`branding.pwa_name`** → titolo app; `branding.home_duration`, `company.maps_url`, `company.address {via, citta, paese}` → testi home.
3. Anti-flash: snapshot `_brandingSnapshot` in localStorage applicato PRIMA del primo paint
   (`branding-boot.js`). **Equivalente Flutter**: salvare il branding in `SharedPreferences` e
   costruire il `ThemeData` iniziale da lì in `main()` (prima di `runApp`), poi aggiornare quando arriva il dato fresco.
4. Aggiornamenti live: canale Realtime su `org_settings` (filtro `org_id`); ogni chiave `branding.*`
   riapplica il tema → in Flutter: stream Supabase Realtime → `ChangeNotifier`/`Riverpod` provider che
   ricostruisce `MaterialApp` con il nuovo `ColorScheme.fromSeed`/palette.
5. **Colori tipi-slot**: da `slot_types.color` per-org (runtime, non hardcoded) — esporli nel
   `ThemeExtension` come `Map<String, Color>` popolata dai dati.
6. Reset su logout (`OrgSettings.reset()`): pulire cache tema per evitare bleed cross-tenant.

```dart
// Sketch
ThemeData buildTheme(OrgBranding b) {
  final primary = b.primaryColor ?? const Color(0xFF8B5CF6);
  final primaryDark = darken10(primary); // c * 0.9 per canale RGB
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.light(
      primary: primary,
      onPrimary: Colors.white,
      surface: Colors.white,
      error: const Color(0xFFEF4444),
      onSurface: const Color(0xFF0F172A),
      outlineVariant: const Color(0xFFE2E8F0),
    ),
    scaffoldBackgroundColor: const Color(0xFFF8F9FA), // 0xFFF1F5F9 sezione allenamento
    extensions: [PalestriaColors(primaryDark: primaryDark, /* §8.1 */)],
  );
}
```

### 8.5 Note di fedeltà

- Non replicare lo scale-down desktop (html 12px): l'app Flutter usa la scala mobile.
- Numeri sempre `tabular-nums` (`FontFeature.tabularFigures()`), specie importi e orari.
- Peso 800 sui titoli/valori è il tratto identitario n.1; il n.2 è la coppia "pill bianca + selezione viola piena con ombra viola `rgba(139,92,246,0.3)`".
- Ombre sempre **doppie e leggerissime** (mai elevation Material di default: usare `BoxShadow` espliciti).
- Bordi sinistri colorati 4–5px sulle card come codifica del tipo/severità.
- Status bar: colore = `branding.primary_color` (come `theme-color` web), icone chiare.
