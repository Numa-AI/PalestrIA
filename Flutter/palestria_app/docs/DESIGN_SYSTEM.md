# PalestrIA — Design System (app Flutter)

> **Questo è il file di riferimento unico dello stile dell'app.** Serve a tenere una
> "linea sola" come farebbe un art director: font, spaziature, colori, raggi, ombre e
> componenti stanno qui e nel codice dei token — non si reinventano schermata per schermata.
>
> - **Codice sorgente dei token**: [`lib/core/theme/tokens.dart`](../lib/core/theme/tokens.dart)
> - **Tema (ThemeData org-aware)**: [`lib/core/theme/org_theme.dart`](../lib/core/theme/org_theme.dart)
> - **Componenti condivisi (UI kit)**: [`lib/core/theme/ui_kit.dart`](../lib/core/theme/ui_kit.dart)
> - **Estrazione grafica dal web (fonte storica)**: [`design-tokens.md`](design-tokens.md)
>
> Regola d'oro: **se un valore (colore/padding/raggio/testo) non è in un token o in un
> componente del kit, prima di scriverlo a mano chiediti se dovrebbe diventarlo.**

---

## 1. Identità

PalestrIA è un gestionale fitness **professionale, pulito, denso di dati** (KPI, prezzi, orari,
calendari). L'estetica è "SaaS moderno + Athletic performance": superfici bianche ariose, un
**viola brand** (personalizzabile per-org), heading **extra-bold** con tracking negativo, e
**hero scure** per le sezioni "sportive" (allenamento/profilo).

Tre tratti identitari da non perdere mai:
1. **Peso 800** su titoli e valori numerici (è la firma tipografica n.1).
2. **Cifre tabulari** su tutti i numeri (importi, orari, conteggi).
3. **Coppia "superficie bianca + accento viola"**: selezione/azione = viola pieno con ombra viola.

---

## 2. Tipografia

**Font unico: `Inter`** — bundled in [`assets/fonts/`](../assets/fonts) (offline, nessuna chiamata
runtime). Costante `kFontFamily` in `tokens.dart` + sezione `fonts:` nel `pubspec.yaml`: cambiare
font si fa in **un punto solo**. Inter è scelto perché è disegnato per UI, altamente leggibile a
misure piccole e con eccellenti **cifre tabulari** — ideale per un'app piena di numeri.

Pesi bundlati: **400** (Regular), **500** (Medium), **600** (SemiBold), **700** (Bold),
**800** (ExtraBold). Usare solo questi.

### Scala tipografica (usare gli stili di `AppText`, non `TextStyle` a mano)

| Stile `AppText` | Size | Peso | Uso |
|---|---|---|---|
| `pageTitle` | 26.4 | 800 | titolo di pagina/tab |
| `sectionTitle` | 22.4 | 800 | titolo di sezione |
| `statValue` | 32 | 800 | valore KPI (tabular) |
| `cardTitle` | 16 | 700 | titolo card |
| `body` | 15 | 500 | testo corrente (line-height 1.55) |
| `label` | 13.5 | 600 | label di form/campo |
| `meta` | 13 | 500 | sottotitoli, meta, timestamp |
| `badge` | 12 | 700 | testo di pill/badge |
| `eyebrow` | 11 | 800 | overline UPPERCASE (letter-spacing 1.1) |

Regole:
- **Numeri sempre tabulari**: `AppText.statValue` lo è già; per numeri inline aggiungi
  `fontFeatures: AppText.tabularNums`.
- Titoli grandi → letter-spacing **negativo** (già nei token). UPPERCASE → **positivo** (eyebrow).
- Non introdurre nuove misure a caso: se ne serve una, aggiungila ad `AppText`.

---

## 3. Colore

Il brand è **org-aware**: il colore primario arriva dal branding della org
(`org_settings.branding.primary_color`) tramite `buildAppTheme`. **In UI usa sempre il tema**,
non il token statico, per gli elementi branded:

- **Elementi branded** (bottoni, tab attive, dock, FAB, focus, selezione) →
  `Theme.of(context).colorScheme.primary` / `.secondary` (= primaryDark) / `brandGradient(context)`.
  ⚠️ **Mai** `AppColors.primary`/`Color(0xFF8B5CF6)` per questi: su una org con brand diverso
  resterebbero viola.
- **Colori semantici e superfici** (successo, errore, warning, bordi, testo, sfondi) → i token
  `AppColors.*` (fissi).

### Token semantici principali (`AppColors`)

| Ruolo | Token |
|---|---|
| Testo heading / body / secondario / terziario | `navy` · `textDark` · `muted` · `subtle` |
| Bordi | `border` (slate-200) · `borderHover` · `borderGray` |
| Sfondi pagina | `lightGray` (pubblico) · `slateBg` (app) · `surface` (card) |
| Successo / errore / warning | `success` (teal) · `danger`/`dangerDark` · `warning`/`amber` |
| Superfici soft (box tenui) | `successSurface` · `dangerSurface` · `warnSurface` · `infoSurface` · `slate50` |
| Verdi "attivo/incassato" | `green500` · `green600` · `green700` |
| Chip pagamento (bg/testo) | `paidBg/paidText` · `unpaidBg/unpaidText` · `partialBg/partialText` · `cancelledBg/cancelledText` · `cancelReqBg/cancelReqText` |
| Stati documento (cert/assic/anagrafica) | `docOkBg/docOkText` · `docWarnBg/docWarnText` · `docDangerBg/docDangerText` |
| Posti residui | `danger` (1) · `spotsOrange` (2) · `navy` (≥3) |
| Avatar (6 tinte hash) | `avatarTints` |
| Colori tipo-slot | **runtime** da `slot_types.color` (mai hardcoded); default in `AppColors.slot*` |

Do/Don't:
- ✅ `AppColors.dangerDark` — ❌ `Color(0xFFDC2626)` sparso.
- ✅ colore tipo-slot da `slotColor(type)` org-aware — ❌ palette fissa PT/SG/GC.

---

## 4. Spaziatura e geometria

### Scala spaziature (`AppSpacing`, 4-based)
`xs 4 · sm 8 · md 12 · lg 16 · xl 20 · xxl 24 · xxxl 32`. Non usare valori fuori scala (niente 6, 13, 18…).

Regole di layout:
- **Padding di pagina**: `AppSpacing.lg` (16) orizzontale.
- **Gap tra sezioni**: `AppSpacing.xxl` (24).
- **Gap tra card in lista**: `AppSpacing.sm`–`md` (8–12).
- **Padding interno card**: `AppSpacing.lg` (16); stat card 16.
- `SafeArea` in fondo per dock/sheet.

### Raggi (`AppRadius`)
| Componente | Token |
|---|---|
| Bottone | `button` 8 · `buttonAdmin` 10 |
| Input | `input` 10 |
| Card | `card` 14 · `cardLg` 16 (stat card) |
| Modal/dialog | `modal` 16 · `modalLg` 18 |
| Bottom sheet (solo top) | `sheet` 20 |
| Chip/pill | `chip` 999 |
| Toast | `toast` 12 |

Niente `BorderRadius.circular(16)` a mano: usa `AppRadius.cardLg`.

### Ombre (`AppShadows`)
`card` (riposo) · `cardMd` (in evidenza/hover) · `cardLg` (overlay/modali) · `glow` (focus viola).
Sono **doppie e leggerissime**: non usare mai l'`elevation` Material di default sulle card.

### Bordi
Default `1px AppColors.border`. Barra colore a sinistra **4–5px** per codificare tipo/severità
(usa `AppCard(leftBarColor: …)`).

---

## 5. Componenti condivisi (UI kit)

Da [`ui_kit.dart`](../lib/core/theme/ui_kit.dart). **Preferisci sempre questi** a `Container`+`BoxDecoration` fatti a mano.

| Widget | Quando usarlo |
|---|---|
| `AppCard` | qualsiasi contenitore-card bianco (bordo, radius 14, ombra `card`); opz. `leftBarColor`, `onTap`, `elevated`. |
| `SectionHeader` | intestazione di sezione: `eyebrow` UPPERCASE opz. + titolo, con `trailing` (es. bottone). |
| `AppStatCard` | KPI: barra gradiente in alto, tile icona tinta, label eyebrow, valore 800. |
| `StatusPill` | badge/pill di stato con coppia bg/fg (usa i token chip/doc). |
| `GradientButton` | azione primaria a gradiente brand (org-aware) con press-scale + ombra viola. |
| `DarkHero` | hero scura→viola con **glow radiale** (replica `.preno-hero`/hero admin del web); il viola profondo e l'alone seguono il brand org (`colorScheme`). Usato in Profilo cliente, header sezione Prenotazioni cliente e week-bar admin Prenotazioni. Le sezioni Allenamento usano invece il gradiente fisso `AppGradients.workoutHero` (slate, come il web allenamento). |
| `AppEmptyState` | stato vuoto coerente: icona tenue + titolo + sottotitolo (+ azione opz.). |
| `AppLoading` | spinner brandizzato centrato (bordo grigio + testa viola). |
| `AppErrorRetry` | stato di errore con "Riprova" — **distinto** dal vuoto. |

### Bottoni (gerarchia)
1. **Primario** → `FilledButton` (tema) o `GradientButton` per le CTA forti.
2. **Secondario** → `OutlinedButton`.
3. **Testo/ghost** → `TextButton`.
4. **Distruttivo** (Elimina, Esci) → sempre **rosso** (`AppColors.danger`), mai il brand.

---

## 6. Pattern trasversali (regole di comportamento)

- **Tre stati sempre distinti** per ogni vista async: **loading** (`AppLoading`), **empty**
  (`AppEmptyState`), **error** (`AppErrorRetry`). ❌ Mai mostrare "nessun dato" quando in realtà è
  un errore di rete: usa il ramo `error` dell'`AsyncValue`.
- **Feedback esito** (SnackBar): **verde** su successo, **rosso** su errore, viola su info. Non usare
  lo stesso navy per tutto (helper `AppSnack.success/error` — vedi `ui_kit`/estensioni).
- **Bottom sheet**: `showModalBottomSheet(isScrollControlled: true)` con `showDragHandle: true`,
  radius top `AppRadius.sheet`, `SafeArea`. La maniglia comunica che si chiude con swipe.
- **Press feedback** su tap: `AnimatedScale` a `0.97` (~110ms) — già in `GradientButton`.
- **Org branding**: dock/tab/FAB/selezioni devono seguire `colorScheme.primary`. Il logo della org
  (`branding.logo_url`) va mostrato dove il web lo mostra (login, header admin).
- **Numeri e valute**: formattatore € unico, virgola decimale IT, cifre tabulari.

---

## 7. Checklist per una nuova schermata / un fix

- [ ] Testi via `AppText.*` (font Inter automatico), niente `TextStyle` a mano non necessari.
- [ ] Colori branded via `Theme.of(context).colorScheme`; semantici via `AppColors.*`. Zero hex sparsi.
- [ ] Spaziature dalla scala `AppSpacing`; raggi da `AppRadius`; ombre da `AppShadows`.
- [ ] Card = `AppCard`; stato vuoto = `AppEmptyState`; loading = `AppLoading`; errore = `AppErrorRetry`.
- [ ] Azioni distruttive in rosso; CTA primaria `GradientButton`/`FilledButton`.
- [ ] Tre stati async gestiti; SnackBar colorato per esito.
- [ ] `flutter analyze` pulito.

---

## 8. Manutenzione del sistema

Quando aggiungi un valore ricorrente (un nuovo colore semantico, un nuovo tipo di card, un pattern):
1. Aggiungilo a `tokens.dart` (colore/spacing/radius) o a `ui_kit.dart` (componente).
2. Documentalo qui.
3. Sostituisci le occorrenze hardcoded esistenti.

Così il design system **cresce senza divergere**. Storico delle scelte grafiche → in fondo a questo
file e nel diario di `MIGRATION_PLAN.md`.

---

### Changelog design
- **2026-07-08** — Introdotto il font unico **Inter** (bundled), la UI kit condivisa
  (`AppCard`/`SectionHeader`/`StatusPill`/`AppEmptyState`/`GradientButton`/`AppStatCard`/`DarkHero`/
  `AppLoading`/`AppErrorRetry`), token aggiuntivi (superfici soft, verdi, stati documento, posti,
  `AppGradients.workoutHero`) e questo reference. Obiettivo: chiudere le divergenze grafiche emerse
  nel port PWA→Flutter e tenere una linea unica.
