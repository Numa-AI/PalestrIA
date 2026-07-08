# Piano di migrazione PalestrIA → Flutter

> **Stato vivo del progetto Flutter.** Questo file è la fonte di verità della migrazione:
> ogni iterazione del loop lo legge per capire dove siamo e lo aggiorna a fine lavoro.
> Repo web di riferimento: la root di questo repository (l'app web resta attiva e NON va modificata).

## Obiettivo

App Flutter **Android (Play Store)** che replica 1:1 — grafica e comportamento — l'area **cliente**
(prenotazioni, profilo, allenamenti) e l'area **admin** (tutte le tab) della web app PalestrIA,
parlando con lo **stesso backend Supabase** (org_id + RLS, nessuna modifica server richiesta in fase 1).

## Decisioni prese (confermate dall'utente, 2026-07-06)

| Tema | Decisione |
| --- | --- |
| Perimetro | Area cliente **+ admin** (super-admin resta web) |
| Distribuzione | **Unica app** sul Play Store; l'org arriva dal login (claim JWT `org_id`); al signup il cliente inserisce lo slug/codice palestra |
| Push native | **Fase 2** (FCM); per ora niente push nell'app |
| Pagamenti Stripe | Restano su **pagina web** (aperta via browser esterno / Custom Tab con `url_launcher`) → niente vincolo IAP Google |
| Prenotazione anonima | Resta **solo web** (nell'app si è sempre loggati) |
| Toolchain | Installato in locale: Flutter stable in `C:\Users\andrea\flutter`, JDK 17 portable in `C:\Users\andrea\jdk-17`, Android SDK in `C:\Users\andrea\Android\Sdk` |

## Aggiornamento strategico (2026-07-08)

Go-to-market confermato dall'utente: **lancio entro fine 2026 su ENTRAMBI gli store** (Google Play + Apple App Store) con un **sito web marketing "fatto bene"** + campagna marketing. Sequenza e regole:

- **Android prima** (già in **test interno** sul Play Store dal 2026-07-08; account pagato/verificato, package `com.palestria.app` bloccato). Si porta a **produzione**, POI si affronta iOS.
- **iOS (App Store) = IN SCOPE ma DIFFERITO** finché Android non è stabile in produzione. Con Flutter è ~1.3× (stesso codice Dart), non una riscrittura. Prerequisiti: **macOS** per build/firma/upload (l'utente se lo può procurare), **Apple Developer** 99$/anno, **bundle id iOS** da bloccare insieme all'`applicationId` Android. Accorgimento: al primo Mac, fare subito un **build iOS "usa e getta"** per far emergere i quirk plugin, prima di rifinire la UI.
- **PWA/web → MODALITÀ MANUTENZIONE**: resta viva per **prenotazione pubblica anonima** (link, nessuna install), **super-admin** e fallback web/admin da desktop; **congelato lo sviluppo di nuove feature** lì. Le feature nuove nascono in Flutter; dei port dal gemello Thomas si portano in Dart **solo i rilevanti** (niente doppio lavoro sistematico).
- **IAP**: l'abbonamento SaaS del trainer resta gestito su **web** (evita la regola IAP Apple/Google); i pagamenti-cliente sono servizi del mondo reale (lezioni) → esenti, restano su Stripe esterno.
- **Account Play = Organizzazione (Numa AI) ⇒ ESENTE** dal closed testing 12-tester/14gg (quel vincolo vale solo per account **personali** aperti dopo il 13/11/2023). Si va **dritti alla produzione** dopo config scheda + review Google — **nessun muro a tempo Android**. Il long-pole del calendario diventa quindi **iOS** (Mac + Apple Developer + primo build).

## Architettura scelta

- **Progetto**: `Flutter/palestria_app/` (dentro questo repo). `applicationId`: `com.palestria.app`
  ⚠️ da confermare con l'utente PRIMA della pubblicazione (dopo non si cambia più).
- **Stack Dart**: `supabase_flutter` (auth+db+realtime), `flutter_riverpod` (state),
  `go_router` (navigazione), `shared_preferences` (cache dual-layer come localStorage web),
  `url_launcher` (Stripe web), `intl` (it_IT), `printing`/`pdf` (report PDF).
- **Tema**: Material 3 con design tokens estratti dal CSS web (`docs/design-tokens.md`) +
  **tema dinamico per-org** (colori/logo da `org_settings`, equivalente di branding-boot.js).
- **Data layer**: repository Dart che replicano le classi Storage di `js/data.js`
  (stesso pattern cache-first + sync Supabase, stesse RPC, chiavi cache namespaced `org_<id>_`).
  I workaround web NON vanno portati: niente lock PWA, niente service worker, niente cache-busting.
- **Lingua**: UI e commenti in italiano, come il web.

## Fasi

### Fase 0 — Fondamenta ✅ FATTA (2026-07-06)

- [x] Decisioni di scope con l'utente
- [x] Toolchain: Flutter 3.44.4 stable + JDK 17 (`C:\Users\andrea\jdk-17`) + Android SDK 35/36
      (`C:\Users\andrea\Android\Sdk`), licenze accettate, PATH/JAVA_HOME/ANDROID_HOME user-scope.
      `flutter doctor`: ok (il warning Visual Studio riguarda solo il target Windows desktop, irrilevante).
- [x] Specifiche estratte dal web in `docs/`:
  - [x] `docs/spec-client.md` (91 KB) — UI/flussi area cliente
  - [x] `docs/spec-admin.md` (379 KB) — UI/flussi area admin (9 tab, 3 layout responsive, card cliente viola)
  - [x] `docs/design-tokens.md` (38 KB) — brand `#8B5CF6`, light-only, branding per-org via `org_settings`
  - [x] `docs/spec-data.md` (74 KB) — schema, RPC, storage layer, auth (URL/anon key in §1)
- [x] `flutter create palestria_app` (Android-only, org com.palestria) + dipendenze
      (supabase_flutter 2.15, riverpod 3.3, go_router 17, shared_preferences, url_launcher,
      intl 0.20.2 (pinnato da flutter_localizations), cached_network_image, pdf, printing)
- [x] Config Android: applicationId `com.palestria.app` (⚠️ da confermare pre-release),
      label "PalestrIA", permesso INTERNET nel manifest main

### Fase 1 — Core condiviso ⏳ IN CORSO

- [x] Init Supabase (stesso URL/publishable key del web) — `lib/core/config.dart`, `main.dart`
- [x] Auth: `auth_repository.dart` (login, signup cliente con slug org + is_whatsapp_taken +
      join_organization safety-net, recovery, logout con teardown per-tenant) +
      `auth_providers.dart` (session stream, OrgContext dai claim JWT con fallback query)
- [x] Normalizzazioni 1:1: `normalize.dart` (normalizePhone, normalizeComune, capitalizeName,
      isAnagraficaComplete)
- [x] OrgSettings service (`org_settings_service.dart`): cache memoria→prefs `org_<id>_<key>`,
      RPC upsert_org_setting, canale Realtime `org_settings_<orgId>`, reset al logout
- [x] Tema: `tokens.dart` (palette/ombre/radius/testi dal CSS) + `org_theme.dart`
      (OrgBranding con dark −10%, snapshot pre-paint, buildAppTheme M3)
- [x] Shell navigazione: go_router con redirect per ruolo (claim org_role → /admin, altrimenti
      /client/*), StatefulShellRoute con dock a 3 tab; login/signup funzionanti (grafica da rifinire)
- [x] Modelli: SlotType, Booking (mapping _mapRow), SlotAvailability, SlotAttendee, UserProfile
- [x] ScheduleConfigRepository (4 query parallele slot_types/time_slots_config/activated_weeks/
      weekly_template_slots + snapshot `_orgSchedSnap_<orgId>` anti-flash + daySchedule date-aware)
- [x] BookingRepository cliente (fetchOwnBookings finestrato, get_availability_range con TTL 60s,
      book_slot 45s con mappatura errori IT, cancel_booking/user_request_cancellation,
      get_slot_attendees; orgSlugProvider da organizations)
- [x] Prima build APK debug OK (~23 min Gradle first-run, poi incrementale)
- [ ] Modelli/repository restanti (WorkoutPlan/Log, Payment, memberships/packages) — con le feature
- [ ] Deep link per conferma email/recovery (per ora i link email puntano al web: funziona comunque)

### Fase 2 — Area cliente ⏳ IN CORSO

- [ ] Login/benvenuto (funzionante; fedeltà grafica 1:1 a login.html da rifinire)
- [x] **Prenotazioni — tab Calendario** (`calendar_view.dart`): week-nav ←/→ con disabilitazioni,
      selettore 7 giorni (stati active/disabled/has-enrollment, swipe settimana), card slot mobile
      (bordo sx 5px + gradiente colore-tipo org-aware, pill posti con colori 1=rosso/2=arancio/≥3=scuro,
      badge "Qui ti alleni 💪🏼", cutoff 30 min, pulizia non cliccabile, empty states esatti, auto-advance)
- [x] **Prenotazioni — bottom sheet** (`booking_sheet.dart`): header badge tipo + posti + giorno/ora,
      sezione "Persone iscritte" collassabile (gate privacy, gruppi per tipo con pallino colorato,
      retry), note + Conferma, check duplicato pre-submit, conferma con gradiente viola + regole
      (abbigliamento/alimentazione/idratazione) + bottone Google Calendar (url_launcher)
- [x] **Prenotazioni — Le mie** (`my_bookings_view.dart`): tab Prossime/Passate, paginazione 5→+20,
      card con badge pagamento (mappa metodi completa), regole annullo (grace 10min, diretto >24h /
      group-class >3gg, richiesta 2-24h, chip attesa/bloccato) con dialog di conferma testi esatti
- [x] Provider dati: overrides finestrati −30gg, disponibilità 90gg indicizzata, computeDaySlots
      (override → template settimana attivata → vuoto)
- [x] **Profilo cliente** (`profile_screen.dart`): hero gradiente scuro→viola §7.1 (avatar iniziale,
      primo nome, bottone modifica), warning cumulabili §7.2 (completa anagrafica / imposta cert /
      scaduto / scade fra N gg), card stato pagamenti §7.3 (`billing_status.dart`: 7 varianti
      free/monthly/package/pay_per_session con debito da prezzi org), card dati, logout
- [x] **Modifica profilo** (`edit_profile_sheet.dart` §7.7): nome disabilitato, email (cambio via
      auth con conferma), whatsapp (is_whatsapp_taken con exclude), CF upper, indirizzo con
      normalizeComune, CAP 5 cifre, cert con append history, assicurazione sempre disabilitata,
      password min 6 + conferma, checkbox privacy, errori inline, toast esatti
- [ ] Modal grafico allenamenti settimanali/mensili (§7.6) — rimandato con l'area workout
- [x] **Allenamento — vista Scheda** (§8.3, `workout_screen.dart`): hero gradiente
      #0f172a→#1e1b4b→#7C3AED con eyebrow SCHEDA, nome + rinomina, selettore multi-scheda,
      rail giorni con meta "ultimo · oggi/data/mai"; header giorno "N/M completati"; card
      esercizio/superset (badge SS ambra)/circuito (badge C cyan) con thumbnail dal catalogo,
      stato fatto-oggi (bordo verde + check), swipe-delete con conferme e toast esatti;
      empty state; FAB con modal "Nuova scheda"
- [x] **Allenamento — dettaglio + log** (§8.4, `exercise_detail_sheet.dart`): pagina fullscreen
      con media, "DA FARE:", note, "Sessione precedente" (chip giallini), griglia
      "Registra per oggi" (prefill oggi ?? precedente ?? target, cardio solo Min), "+ Serie",
      Salva (→"Salvato!" verde 2s), "Elimina log di oggi"; upsert onConflict identico al web
- [x] Data layer workout: modelli + repository (fetch embed, log paginati, logSet upsert,
      CRUD piani/esercizi, reorder)
- [x] **Allenamento — aggiunta esercizi** (§8.5, `exercise_picker.dart` + `add_exercise_flows.dart`):
      picker fullscreen (ricerca, griglia categorie con conteggi, max 50 risultati + "N altri",
      bottone Personalizzato), FAB sheet "Aggiungi al giorno" (3 opzioni con badge colorati),
      flusso singolo (prompt serie/reps/riposo, cardio senza prompt), super serie (2 esercizi,
      rest 0 sul primo, superset_group condiviso), circuito (N≥2, toolbar riepilogo, giri comuni,
      rest solo sull'ultimo, circuit_group), nuovo giorno con default "Giorno A/B/C…"
- [x] **Allenamento — Progressi** (§8.7 mobile v2, `progress_view.dart`): hero scura con selettore
      periodo (Tutto/7gg/30gg/3 mesi, default 30), 4 KPI (Allenamenti da prenotazioni passate,
      Sessioni, Serie, Volume con "X.Xt"), card per esercizio (target, badge N sess, sparkline
      area viola, Max/Ultimo/Trend colorato), FAB pill filtro muscolo, empty states con periodo
- [x] **Allenamento — Storico** (§8.6, `history_view.dart`): back ai Progressi, ricerca, card per
      esercizio raggruppate per slug con "N log · M sessioni", sessioni espandibili per data,
      righe editabili con salva/elimina set, elimina giornata — conferme e toast esatti
- [x] **Allenamento — navigazione sezioni** (§8.2): dock gradiente viola in basso (eyebrow
      "Sezione" + nome + chevron) → sheet "Vai a" con radio (Scheda/Progressi); FAB rialzato
- [x] Allenamento — **COMPLETO (2026-07-07)** vs web (nav web Scheda/Progressi/**Report/Tablet/PDF**;
      Flutter ora ha tutte le sezioni + grafico profilo §7.6):
  - [x] **PDF scheda** (§8.9, 2026-07-07): `workout_pdf.dart` — A4 con header+note, barra viola per
        giorno, esercizi con badge numerato + target/gruppo/note + tabella Serie|Reps|Kg|Riposo|Fatto
        (cardio: Minuti|Fatto) pre-compilata + 1 riga vuota, superset/circuito con intestazione;
        bottone PDF nella hero Scheda → `Printing.sharePdf`. Miniature (image-proxy) omesse.
  - [x] **Report AI mensile** (§9, 2026-07-07): `report_view.dart` — nuova `WorkoutSection.report`
        nel dock/sheet; hero mese+quota (rimanenti/3), griglia 3 toni (serio/motivazionale/ironico,
        stato "generato→apri"), archivio per mese, **consenso GDPR** (dialog+`set_report_ai_consent`),
        invoke edge `generate-monthly-report` (force_regenerate, gestione REGEN_LIMIT_REACHED),
        dettaglio in bottom-sheet con narrative markdown minimale (h2/3/4, bold, italic).
  - [x] **QR Tablet** (§8.8, 2026-07-07): `tablet_qr_view.dart` — QR (CustomPainter su
        `package:barcode`, aggiunto come dep diretta in pubspec: era transitiva di `pdf`) verso
        `${AppConfig.webBaseUrl}/tablet.html?uid=<id>`, nome utente, "Copia link" (Clipboard),
        hint; nuova `WorkoutSection.tablet` nel dock/sheet. PNG download del web omesso (poco utile
        su app: il QR si scansiona a schermo).
  - [x] **Grafico allenamenti settimanali/mensili** nel profilo (§7.6, 2026-07-07):
        `weekly_chart_sheet.dart` — bottone "I miei allenamenti" nel profilo → bottom-sheet con
        toggle settimanale(8 sett.)/mensile(10 mesi), barre conteggio prenotazioni non annullate
        (passato blu #3b82f6 + futuro rosso #e63946), legenda. Riusa `MonthlyBarChart` esteso con
        `projectedColor`. Usa `ownBookingsProvider` (finestra recente; fusione storico completo
        on-demand del web omessa — i mesi lontani mostrano ciò che è in finestra).
- [x] Pagamenti Stripe SaaS su browser esterno (url_launcher) — vedi Impostazioni admin sopra.
      Resta da valutare l'analogo per i pagamenti-cliente online se/quando serviranno lato app.

### Fase 3 — Area admin ⏳ IN CORSO

- [x] **Shell admin** (`admin_shell.dart`): 9 tab enum (emoji+label esatte), dock viola in basso
      + sheet "Vai a" con radio (§1.4), routing per ruolo, logout; placeholder per le tab non ancora
      portate (`tabs_placeholder.dart`)
- [x] **Data layer admin** (`admin_repository.dart`): fetch bookings org finestrati (60gg+90gg+debiti,
      paginati), get_all_profiles_basic con fallback, aggregazione clienti O(1) per email/telefono
      (getAllClients), attivi (2 mesi fa → 1 mese avanti), admin_pay_bookings, admin_delete_booking
- [x] **Tab Clienti** (§6, `clients_tab.dart` + `client_card.dart`): titolo "N totali · M attivi",
      ricerca live, 5 chip filtro (uno alla volta), 2 stat card cliccabili (Totali/Attivi), lista
      nascosta finché non si clicca/filtra, paginazione 20 + "Mostra altri N", card viola v2 (bordo
      sx 4px, avatar iniziali, nome+✏️, contatti WhatsApp/email tappabili, badge cert/anagrafica/doc,
      3 stat cell Prenot.Future/Sessioni/Da saldare, switch Prenotazioni⇄Storico, righe .book-row
      org-aware con pill saldo tutti gli stati, storico=incassi con +€)
- [x] **Tab Prenotazioni admin** (§3, `admin_bookings_tab.dart` + `add_participant_sheet.dart`):
      week-bar con nav ±settimana e mese/anno, selettore 7 giorni (stati oggi/attivo + conteggio
      "N pr."), slot card con capienza "N/M posti" e pulizia, card partecipante (avatar 6 tinte hash,
      nome, stato pagamento Pagato/Da pagare/annullamento, elimina→cancel_booking), aggiunta
      prenotazione (ricerca cliente → book_slot con p_for_user_id)
- [x] **Tab Impostazioni** (§12, `settings_tab.dart` + `billing_saas.dart`): sezioni Branding
      (nome studio + colore primario, applica il tema live), Localizzazione (timezone/valuta),
      nota Pagamenti cliente, e **Abbonamento SaaS**: entitlements (get_tenant_entitlements: piano,
      stato trial/active/past_due, clienti), 3 piani (Starter/Pro/Business) → **Stripe Checkout via
      billing-checkout aperto nel browser esterno** (niente IAP), "Gestisci abbonamento" → billing-portal
- [x] **Tab Pagamenti** (§7, `payments_tab.dart` + `pay_debt_sheet.dart`): stat card "Da Incassare"
      (debitori raggruppati per contatto, espandibili) + "Incassato questo mese" (ledger payments),
      popup "Segna come pagato" (selezione lezioni + metodo → admin_pay_bookings)
- [x] **Tab Statistiche & Fatturato** (§8, `analytics_tab.dart` + `stats_charts.dart` + 4 pannelli +
      `fiscal_report.dart`) — **PORTATA COMPLETA (Stage A+B+C, 2026-07-07)**. Dashboard (Stage A): filtri completi (questo mese / mese prossimo / mese scorso /
      quest'anno / anno scorso) con **confronto % sul periodo precedente**; 4 stat card (Fatturato
      previsto via `bookingPrice()` org-aware, Prenotazioni, Clienti attivi, **Occupazione** =
      prenotazioni/capienza programmata da `daySchedule`); grafico **andamento prenotazioni**
      (line CustomPainter, giornaliero ≤60gg / mensile oltre); **ripartizione per tipo** (donut
      org-aware `slotName`/`slotColor`); **orari più richiesti**; **ultime prenotazioni** (15).
      Nuovo provider `statsBookingsProvider` (finestra 24 mesi indietro→12 avanti) + helper
      `booking_pricing.dart` (`bookingPrice`, `isAdminStatsEmail`). `flutter analyze` pulito.
      **Stage B.1 fatto (2026-07-07)**: stat card tappabili + pannello drill-down **Fatturato**
      (`fatturato_detail.dart`): modalità Prenotazioni/Reale, KPI (fatte/future/stima/media sett.
      o incassato/reale/media), **barre 12 mesi+successivo** (`MonthlyBarChart`, corrente
      evidenziato + overlay proiezione), ripartizione pie per tipo (Prenotazioni) / per metodo di
      pagamento + lezioni gratuite (Reale). `flutter analyze` pulito.
      **Stage B.2 fatto (2026-07-07)**: pannello drill-down **Prenotazioni** (`prenotazioni_detail.dart`):
      KPI (passate/future/stima/media sett./% cancellazioni), trend mensile 12+1, ripartizione per
      tipo (donut org-aware), per giorno della settimana e per fascia oraria (barre), top-5 slot più
      comuni, breakdown fascia/giorno popolare. `MonthlyBarChart` generalizzato con `barColor`.
      **Stage B.3 fatto (2026-07-07)**: pannello drill-down **Clienti** (`clienti_detail.dart`):
      KPI (unici/nuovi/media lez./% con cancellazioni) + 8 classifiche (maggior fatturato dal
      ledger, più/meno attivi, top annullatori, più fedeli, more `penalty_mora`, nuovi clienti,
      clienti persi vs periodo prec.). NB: i modali certificato/assicurazione sono nelle card della
      tab Clienti → ✅ FATTO 2026-07-07 (`client_edit_sheet.dart`, vedi sezione "verifica" in fondo).
      **Stage B.4 fatto (2026-07-07)**: pannello drill-down **Occupancy** (`occupancy_detail.dart`),
      org-aware (no pt/sg/gc hardcoded): occupazione = prenotazioni/capienza `daySchedule`; KPI
      (totale + primi 2 tipi + prenotazioni), trend occupazione % per tipo (12+1 mesi, fino a 3
      tipi), occupazione per giorno settimana. Empty-state se nessuno slot programmato.
      **Stage C fatto (2026-07-07)**: **export report fiscale** (`fiscal_report.dart`): filtra i
      pagamenti tracciabili (carta/bonifico/stripe/contanti-report, importo>0), incrocia CF+indirizzo
      dai profili, ordina per data, genera **PDF** (pacchetti `pdf`/`printing`) condiviso via
      `Printing.sharePdf` (share sheet); bottone nella dashboard con dialog di conferma (egress
      pesante). File `PalestrIA_Report_Fiscale_<data>.pdf` (rinominato dal `TB_` del gemello).
      **✅ TAB COMPLETA.** Unico residuo minore rimandato: forecast cumulativo del pannello Fatturato.
- [x] **Tab Registro** (§5, `registro_tab.dart`): 3 sub-tab — eventi prenotazioni (created/paid/
      cancelled/cancel_req con badge e importi, filtro periodo+ricerca), notifiche admin
      (admin_messages), notifiche clienti (client_notifications)
- [x] **Tab Gestione Orari** (§4, `schedule_tab.dart`): consultazione config reale (tipi lezione con
      colore/capienza/prezzo, fasce orarie, settimane attivate); editing template resta sul web
- [x] **Tab Schede** (§9, `schede_tab.dart`): elenco schede org con giorni/esercizi espandibili;
      editor esercizi resta sul web
- [x] **Tab Messaggi** (`messaggi_tab.dart`): composizione notifica push via edge send-admin-message
      (mode tutti/giorno/ora), lista ultimi messaggi
- [x] **Interruttore Admin ⇄ Utente** (`area_switch.dart`): da admin "Vista utente", dall'area cliente
      (se admin) "Area admin"; routing con gate che risolve il ruolo via org_members (ripiego se il
      JWT hook non è registrato)
- [x] Impostazioni — **COMPLETE (2026-07-07)**: portate tutte le sotto-tab web (11). Residui minori:
      toggle legacy cert/assic/badge nella Policy (chiavi org_settings `cert_*`/`assic_*`/`show_*_badge`)
      e backup/restore completo + verifica integrità (restano sul web). Dettaglio sotto-tab:
  - [x] **Dati azienda & fiscali** (§3, 2026-07-07): `settings_company.dart` `CompanySection` — ragione
        sociale/P.IVA/CF/PEC/SDI/prefisso fattura + indirizzo (oggetto `company.address`) + maps;
        chiavi `company.*` su org_settings. Aggiunta al `settings_tab`.
  - [x] **Pagamenti cliente** (§4, 2026-07-07): `settings_payments.dart` `PaymentsSection` — Stripe
        Connect (edge `stripe-connect` start/disconnect, `url_launcher`), modello predefinito
        (billing_settings.upsert), soglie/flag blocco (threshold/grace/block_memb/block_pkg/auto_dec),
        listino `slot_types.default_price` + `org_settings billing_client.prices`.
  - [x] **Policy prenotazione/cancellazione** (§5, 2026-07-07): `settings_prefs.dart` `PolicySection` —
        form `booking.policy.*` (ore cancellazione gratuita, penale %, anticipo max, richiedi account,
        modalità cancellazione). Toggle legacy cert/assic/badge (classi Storage separate) RIMANDATE.
  - [x] **Notifiche** (§6, 2026-07-07): `settings_prefs.dart` `NotifSection` — `notif.*`
        (conferma, promemoria+ore, avvisa admin) + canali `notif.channels` (push/email/whatsapp).
  - [x] **GDPR** (§8, 2026-07-07): `settings_prefs.dart` `GdprSection` — `gdpr.privacy_url`,
        `gdpr.terms_url`, `gdpr.data_retention_days`.
  - [x] **Feature flags** (§9, 2026-07-07): `settings_prefs.dart` `FeaturesSection` — 5 toggle
        `features.<key>` (workout_plans/nutrition/messaging/ai_reports/client_online_payments),
        salvati al cambio.
  - [x] **Staff** (§7, adminOnly, 2026-07-07): `settings_staff.dart` `StaffSection` — invita
        (`invite_org_member`), lista `org_members` + nome/email dai profili, cambia ruolo
        (staff/admin, update con `.neq('role','owner')`), revoca (status=revoked, con conferma).
        Owner non modificabile.
  - [x] **Sicurezza/Manutenzione** (§11, adminOnly, 2026-07-07): `settings_security.dart`
        `SecuritySection` — modalità manutenzione (`maintenance.mode`/`maintenance.message`),
        **cancella tutti i dati** (`admin_clear_all_data`, doppia conferma con "ELIMINA" digitato).
        Backup/restore completo + verifica integrità + report XLSX restano sul web (infra file-share
        non presente nell'app; report fiscale PDF già nella tab Statistiche).
- [~] **Gestione Orari editor** (§4) — era sola lettura; editing in corso:
  - [x] **Editor Tipi slot** (slot_types CRUD, 2026-07-07): `core/data/schedule_admin.dart`
        (`ScheduleAdminRepository` + `allSlotTypesProvider`/`scheduleAdminRepoProvider`) +
        `slot_type_editor.dart` (bottom sheet: etichetta, colore da palette preset, capienza,
        prezzo, ordine, prenotabile, attivo; key auto-generata `_uniqueKey` alla creazione) +
        `schedule_tab.dart` reso editabile (lista tipi con modifica/elimina + "Nuovo tipo",
        elimina con conferma; invalida allSlotTypes+scheduleConfig).
  - [x] Editor **Fasce orarie** (time_slots_config CRUD, 2026-07-07): `time_slot_editor.dart`
        (bottom sheet: time picker inizio/fine con validazione end>start, etichetta opz., ordine;
        insert con is_active=true) + repo `fetchTimeSlots`/`saveTimeSlot`/`deleteTimeSlot` +
        `allTimeSlotsProvider`; sezione Fasce editabile in `schedule_tab` (chip HH:MM-HH:MM +
        modifica/elimina + "Nuova fascia").
  - [x] Editor **Settimana tipo** (templates + template_slots, 2026-07-07): `template_editor.dart`
        `TemplateEditorSection` — selettore template + nuova/rinomina/elimina, **tab-giorno**
        (Lun–Dom, adattato a mobile invece della tabella 7col) + righe per fascia con dropdown
        tipo e campo capienza (set/cambia tipo resetta capienza, vuoto=default); repo
        setCell/setCellCapacity/create/rename/delete + `allTemplatesProvider`/`templateSlotsProvider`.
  - [x] **Attiva settimane** (activated_weeks, 2026-07-07): `activation_editor.dart`
        `ActivationEditorSection` — finestra settimana corrente + 8 successive + settimane attivate
        fuori finestra; dropdown template + Attiva/Aggiorna/Disattiva con **guard prenotazioni**
        (`weekHasBookings`: no cambio template/disattivazione se ci sono iscritti attivi);
        upsert/delete activated_weeks. Sostituisce la vecchia sezione read-only.
  - [ ] **Override** per data (schedule_overrides): secondario, label-keyed con gestione orfani →
        resta sul web per ora (nota in-app).
  **Gestione Orari: editor core COMPLETO** (tipi/fasce/template/attiva-settimane); manca solo l'Override.
- [~] **Schede admin editor** (§9, admin-schede.js 3647 righe) — era sola lettura:
  - [x] **Editor esercizi** (2026-07-07): `schede_providers.dart` (`orgPlansProvider` spostato) +
        `schede_edit.dart` (bottom sheet crea/modifica esercizio: nome, serie, reps, peso, riposo,
        note) + `schede_tab.dart` editabile (rinomina scheda via `updatePlan`, "+ Esercizio" per
        giorno, modifica/elimina esercizio). Riusa `WorkoutRepository` (CRUD per-id, RLS org-admin).
  - [ ] **Picker dal catalogo** esercizi (7200+), super serie/circuiti visuali, vista **"allenamento
        dal vivo"** (chi si allena ora + log) e **tab Importa** (`admin-importa.js`,
        `imported_exercises`) → restano sul web (heavy/mobile-poco-adatti; nota in-app).

### Fase 4 — Play Store

- [ ] Icona/splash, nome app, `applicationId` definitivo
- [ ] Firma release (keystore) + `flutter build appbundle`
- [ ] Versioning, proguard/shrink, test su device
- [ ] Checklist Play Console (privacy policy URL, data safety)

### Fase 5 — dopo il lancio Android

- [ ] **iOS (App Store)** — **IN SCOPE, differito a dopo il lancio Android in produzione** (vedi "Aggiornamento strategico 2026-07-08"). Riusa lo stesso codice Dart (~1.3×); serve **macOS** per build/firma/upload + **Apple Developer** + **bundle id** definitivo. Primo passo: build iOS "usa e getta" per far emergere i quirk plugin.
- [ ] Push FCM + adeguamento edge functions (vale sia Android sia iOS)
- [ ] Deep link / App Links per inviti org

## Gap admin noti (da chiudere) — rilevati 2026-07-07

Confronto codice web (js/admin-*.js) vs Flutter: diverse tab admin erano gusci ridotti o
sola-consultazione. Ordine di lavoro concordato con l'utente (2026-07-07): **1) Statistiche &
Fatturato** (in corso, Stage A fatto), poi Impostazioni (7 sotto-tab), Gestione Orari editor,
Schede+Importa editor. Buchi principali ancora aperti:

- **Statistiche**: drill-down + report fiscale (vedi tab sopra, Stage B/C).
- **Impostazioni** (1693→350 righe): mancano Dati fiscali, Pagamenti cliente (config reale),
  Policy prenotazione/cancellazione, Notifiche, Staff (invita/revoca/ruolo), GDPR, Feature flags,
  Sicurezza/Manutenzione (incl. **Backup/export/restore**, `admin-backup.js`).
- **Gestione Orari** (1063→138): editor tipi/fasce/template/override/capienze (oggi sola lettura).
- **Schede** (3647→112): editor esercizi (super serie/circuiti/riordino) + **tab Importa**
  catalogo 7200+ esercizi (`admin-importa.js`) — oggi sola lettura.
- **Registro/Clienti/Prenotazioni**: ridotte; da verificare modali di dettaglio e azioni per-cliente.

## Diario di bordo

- **2026-07-08** — **Decisione strategica go-to-market** (dettaglio in "Aggiornamento strategico 2026-07-08" in cima). Lancio **fine 2026 su Play + App Store** + sito marketing "fatto bene" + campagna. **Android prima** (test interno già pubblicato l'8/07), **iOS differito ma in scope** (dopo Android stabile; serve Mac + Apple Developer + bundle id). **PWA→manutenzione** (resta per booking pubblico anonimo, super-admin e fallback web; feature nuove solo in Flutter, port da Thomas selettivi). Nessuna modifica di codice in questa sessione: solo indirizzo strategico registrato qui + in memoria `stato-progetto`. Prossimi blocchi verso la produzione Android (account **Organizzazione Numa AI → ESENTE** dal 12-tester/14gg): "Configurare l'app" su Play Console, asset scheda, commit/push del ramo Flutter, deploy mig.0028 + parità web, poi promozione a produzione + review Google.
- **2026-07-07 (loop autonomo /loop)** — **Chiusura gap admin+cliente vs PWA.** Completate in
  sequenza, una sezione per iterazione, con `flutter analyze` pulito ad ogni step (mai committato/
  buildato — lo fa l'utente):
  1. **Statistiche & Fatturato** A+B+C (dashboard + 4 pannelli drill-down + report fiscale PDF).
  2. **Allenamento cliente** (PDF scheda, Report AI, QR Tablet, grafico settimanale profilo).
  3. **Impostazioni** — tutte le sotto-tab web (Azienda, Pagamenti+Stripe Connect, Policy, Notifiche,
     GDPR, Feature flags, Staff, Sicurezza/Manutenzione).
  4. **Gestione Orari editor** core (tipi, fasce, settimana-tipo, attiva-settimane).
  5. **Schede admin** editor esercizi (rinomina scheda, aggiungi/modifica/elimina esercizio).
  6. **Clienti**: editor documenti (modali cert/assicurazione + documento firmato).
  Nuova dep diretta: `barcode` (QR). **Residui deferiti al web** (documentati sopra): override orari
  per-data, picker dal catalogo 7200 esercizi + vista "allenamento dal vivo" + tab Importa, backup/
  restore completo + verifica integrità, export CSV/sort del Registro, barra filtri mobile Prenotazioni,
  toggle legacy cert/assic/badge nella Policy, forecast cumulativo del pannello Fatturato.
  ⚠️ Prossima build APK: `flutter pub get` già fatto; scaricherà `barcode`.
- **2026-07-07 (post-install fix)** — Build+install APK sul telefono (adb, USB). Bug segnalato
  dall'utente: **i video degli esercizi non si vedevano** (il web usa `<video autoplay loop muted
  playsinline>`, i media del catalogo `imported_exercises.video` sono video mp4/webm, ma il dettaglio
  Flutter mostrava solo `immagine`/`immagine_thumbnail` via `cached_network_image`). Fix: nuova dep
  **`video_player`** + `exercise_media.dart` (`ExerciseMediaView`: riproduce il video autoplay/loop/
  muto con fallback immagine) agganciato in `exercise_detail_sheet.dart`. `flutter analyze` pulito,
  APK ricostruito+reinstallato. (Da valutare se estendere il video anche al modal Progressi §8.7 e al
  bottone ▶ del picker; se i video non partono → verificare cleartext http nel manifest.)
- **2026-07-07** — Ripresa lavori sull'area admin (gap vs PWA). Analisi divario tab-per-tab.
  **Statistiche & Fatturato Stage A**: riscritta `analytics_tab.dart` da 4 KPI a dashboard
  completa (filtri+confronto periodo, 4 stat card con Occupazione, line/donut CustomPainter,
  orari popolari, ultime prenotazioni); nuovi `stats_charts.dart`, `booking_pricing.dart`,
  `statsBookingsProvider`/`fetchBookingsRange`. `flutter analyze` pulito. Prossimo: Stage B
  (drill-down + modali cert/assic) e Stage C (report fiscale).
- **2026-07-06** — Kickoff. Decisioni prese con l'utente; toolchain in installazione (background);
  4 agenti spawnati per estrarre le specifiche in `docs/`; creato questo piano.
