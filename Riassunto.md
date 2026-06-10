# Riassunto Progetto — PalestrIA SaaS

## Task: Audit codice multi-agente + fix bug gravi
**Data:** 2026-06-09
**Durata stimata:** ~1h lavoro Claude + ~5 min prompt utente

### Modifiche effettuate
Diagnosi con workflow dynamic (8 aree di analisi + verifica avversariale a 2 lenti): 11 bug gravi confermati (1 critical, 8 high, 2 medium), 0 confutati. Tutti fixati:

1. **`send-admin-message` (CRITICAL)** — broadcast push cross-tenant: aggiunta validazione Bearer, derivazione org da `org_members` (owner/admin attivo), scoping `org_id` su tutte le query, insert `client_notifications` con schema reale.
2. **Signup cliente senza org (HIGH)** — `registerUser` passa `org_slug`+`signup_type` (+ safety-net `join_organization`); modal "Completa profilo" in `login.html` salta gli admin e include `org_id`.
3. **Lezione gratuita → incasso fittizio (HIGH)** — `admin_pay_bookings` gestisce `'gratuito'` (amount 0).
4. **Cancellazione senza refund (HIGH)** — `book_slot` traccia pacchetto/membership consumati; `cancel_booking`/`admin_delete_booking` li rimborsano.
5. **`cancel_booking` aggirabile dal cliente (HIGH)** — cutoff temporale server-side per i non-admin (grace/24h/3gg nel timezone org).
6. **Stored XSS pannelli admin (HIGH)** — nuovo `_escAttr` per attributi onclick; applicato a clients/calendar/payments/registro.
7. **`replaceAllBookings` diff vuoto (HIGH)** — mutatori riscritti con oggetti immutabili (`_withBookingPatch`/`_cancelPatch`).
8. **Cache `scheduleOverrides` cross-tenant (HIGH)** — namespacing localStorage per org + cache org-aware + reset al logout.
9. **`notify-slot-available` (MEDIUM)** — auth + scoping org + fix filter-injection + insert corretto.
10. **`generate-monthly-report` (MEDIUM)** — ruolo/org da `org_members`, scoping `org_id` sul target.

### Decisioni prese
- **Refund deterministico**: aggiunte colonne `bookings.consumed_package_id`/`consumed_membership_id` (uuid soft, no FK per ordine di creazione tabelle) popolate in `book_slot`, invece di indovinare quale pacchetto rimborsare.
- **XSS**: un solo helper `_escAttr` (JS-escape poi HTML-escape) invece di toccare ogni call-site con logiche ad-hoc.
- **`cancel_booking`**: NON ristretta ad admin-only (i clienti la usano legittimamente per disdette >24h), ma aggiunto il cutoff server-side che replica la policy UI.
- **Encoding HTML**: i `?v=` bumpati con `[System.IO.File]::ReadAllText/WriteAllText` UTF-8 (il primo tentativo con `Get-Content -Raw` aveva corrotto i file — vedi `tasks/lessons.md`).

### File toccati
- `supabase/functions/send-admin-message/index.ts` — riscritta authz + org scoping
- `supabase/functions/notify-slot-available/index.ts` — riscritta authz + org scoping
- `supabase/functions/generate-monthly-report/index.ts` — claim/org scoping
- `supabase/migrations/00000000000000_baseline.sql` — colonne `consumed_*`, `book_slot`, `admin_pay_bookings`
- `supabase/migrations/00000000000001_operational_rpcs.sql` — `cancel_booking` (refund+cutoff), `admin_delete_booking` (refund)
- `js/ui.js` — nuovo `_escAttr`
- `js/auth.js` — `registerUser` org_slug + reset cache scheduleOverrides al logout
- `js/data.js` — `_withBookingPatch`/`_cancelPatch`, mutatori, namespacing `scheduleOverrides`
- `js/admin-clients.js`, `js/admin-calendar.js`, `js/admin-payments.js`, `js/admin-registro.js` — escaping `_escAttr`
- `login.html` — modal profilo (skip admin + org_id)
- `sw.js` (CACHE v542→v543) + tutti gli `*.html` (`?v=` bump: ui v3, data v83, auth v29, admin-calendar v17, admin-payments v16, admin-clients v8, admin-registro v7)
- `todo.md` — sezione audit con fix e residui

### Da fare dopo (deploy)
- `supabase db push` (schema + RPC) e `supabase functions deploy send-admin-message notify-slot-available generate-monthly-report`.
- Se il progetto remoto ha già la baseline applicata: creare migration ALTER TABLE per le colonne `consumed_*` invece di ri-applicare la baseline.
