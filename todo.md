# TODO — PalestrIA SaaS

Cose ancora da fare per portare il SaaS in produzione. Aggiornato: 2026-06-05.

> Stato: la piattaforma multi-tenant funziona (signup self-serve, orari flessibili, clienti, prenotazioni, billing-cliente, impostazioni 11 sotto-tab, branding). Deployata su Supabase `rwaiekhllujximrqftmp` + GitHub Pages (`renumaa.github.io/PalestrIA`). Mancano soprattutto: incassi reali (Stripe), dominio/landing, e alcune rifiniture + chiusure di sicurezza.

---

## 🔴 Sicurezza / da chiudere PRIMA della produzione
- [ ] **Chiudere la super-admin dashboard** — oggi `platform_settings.open_access = true` → qualsiasi utente loggato vede i dati di TUTTI i tenant (data-leak cross-tenant, accettato solo in dev). Chiudere con `admin_platform_lock('email@scelta')` (bottone "Limita a una sola email") o SQL: insert in `platform_admins` + `update platform_settings set open_access=false`.
- [ ] **Conferma email** su Supabase: riattivarla (ora OFF per i test) + cablare il flusso "conferma email → crea studio" (gancio `pendingOrg` già in `signup-trainer.html`, da completare in `login.html`).
- [ ] **Site URL / Redirect URLs** su Supabase (Authentication → URL Configuration): impostare il dominio reale (ora `localhost`/github.io) — serve a email e redirect Stripe.
- [ ] **Auth hook `custom_access_token`**: abilitare dal Dashboard (Authentication → Hooks → la function `custom-access-token-hook` è già deployata). Ora si usa il fallback `org_members` (funziona ma è 1 query in più per richiesta).
- [ ] **Test RLS cross-tenant**: verificare con 2 studi che org A non veda mai dati di org B.
- [ ] **GDPR**: adattare `privacy.html` / `termini.html` al SaaS (dati + pagamenti).

## 💳 Pagamenti / Stripe
### Abbonamento SaaS (trainer → piattaforma)
- [ ] Creare i **3 prodotti Stripe** mensili (39,99 / 79,99 / 149,99) → `UPDATE plans SET stripe_price_id_monthly='price_...'`.
- [ ] `supabase secrets set STRIPE_SECRET_KEY=... STRIPE_WEBHOOK_SECRET=... SITE_URL=https://renumaa.github.io/PalestrIA`.
- [ ] `supabase functions deploy billing-checkout billing-portal stripe-webhook`.
- [ ] Registrare il **webhook Stripe** → `.../functions/v1/stripe-webhook` (eventi subscription.* + checkout.session.completed + invoice.*).
- [ ] Verificare il cron `enforce_subscription_state` (degrado/sospensione su scaduto/non pagato).

### Pagamenti-cliente (cliente → trainer) via Stripe Connect
- [ ] **Config owner** (senza, il bottone "Collega Stripe" dà `config_missing`): abilitare Connect sull'account piattaforma; `supabase secrets set STRIPE_CONNECT_CLIENT_ID=ca_...`; registrare redirect URI `https://rwaiekhllujximrqftmp.supabase.co/functions/v1/stripe-connect?action=callback`; `SITE_URL` corretto.
- [ ] **⭐ Checkout cliente online (MANCANTE)** — creare i pagamenti `on_behalf_of` / header `Stripe-Account: acct_…` con la chiave piattaforma. Oggi il trainer può COLLEGARSI ma i clienti non pagano ancora online. È il pezzo che chiude il flusso incassi-cliente.

## 🌐 Dominio / Hosting / PWA
- [ ] Comprare **`palestria.it`** + configurare DNS (`palestria.it`/`www` → marketing; `app` → app SaaS).
- [ ] Decidere il **routing tenant**:
  - **A) `?org=<slug>`** — pronto subito su GitHub Pages, zero infra.
  - **B) sottodominio `<slug>.palestria.it`** — più "pro" + PWA installabile per-studio, ma richiede wildcard DNS + **migrazione hosting a Cloudflare Pages / Netlify / Vercel** (GitHub Pages non fa wildcard).
- [ ] **Manifest PWA dinamico per-org** (nome/icona/colore dell'app installata) — oggi statico "PalestrIA" generico. (Naturale coi sottodomini; su dominio condiviso serve manifest dinamico.)
- [ ] (Se si resta su `?org=`) **fallback localStorage** dello slug, così la PWA installata da anonimo non perde il contesto studio al rilancio.

## 🧩 Funzionalità da completare / rifinire
- [ ] **Pagina pubblica per anonimi**: la griglia slot per il cliente NON loggato deve venire dalla RPC pubblica `get_availability_range`/config — oggi gli orari si caricano "pieni" solo da loggato (la RLS non espone slot_types/template agli anonimi). Necessario per i link pubblici `?org=<slug>`.
- [ ] **UI cambio modello billing per-cliente**: oggi il modello si imposta solo *vendendo* un abbonamento/pacchetto (auto-override). Aggiungere un selettore nel dettaglio cliente per impostarlo a mano (incl. tornare a "a entrata").
- [ ] **Calendario**: refresh automatico dopo modifica della settimana tipo (oggi serve ricaricare la pagina).
- [ ] **Notifiche**: `supabase secrets set VAPID_PUBLIC_KEY/VAPID_PRIVATE_KEY` + deploy `notify-admin-*`, `notify-slot-available`, `send-reminders`; verificare che leggano le chiavi `notif.*` per-org.
- [ ] **Report AI mensili**: `supabase secrets set ANTHROPIC_API_KEY` + deploy `generate-monthly-report`.
- [ ] **admin_health_check/fix**: oggi sono stub che ritornano "ok" — implementare controlli reali org-scoped se serve la sezione Sicurezza.
- [ ] **viewer.html** (tool backup offline legacy): ripulire i residui credito/debito (non tocca il nuovo schema, ma è codice morto).
- [ ] **Storage buckets**: creare `tenant-assets` (logo/branding) + `documenti` se si vuole l'upload del logo dalle Impostazioni (oggi è un campo URL).

## 📣 Go-to-market
- [ ] **Landing SaaS** su `palestria.it`: trasformare `PalestrIA WebSite/` in una landing multi-tenant con CTA "Crea il tuo studio gratis" (→ `signup-trainer.html`) + sezione prezzi (39,99/79,99/149,99 + trial 30gg).
- [ ] Testi/asset marketing (vedi `PalestrIA WebSite/instagram-briefs.md`).
- [ ] **Ads Instagram** → solo DOPO che il funnel è monetizzabile (Stripe live) e i flussi core sono solidi.

## ✅ Testing / QA (prima del lancio)
- [ ] Test end-to-end: signup trainer → orari → clienti → prenotazioni → 4 modelli pagamento → billing SaaS → portal.
- [ ] Test multi-tenant: 2 studi, isolamento dati verificato.
- [ ] Test PWA install + push su iOS/Android.
- [ ] Giro `node --check` + bump cache (`sw.js` `CACHE_NAME` + `?v=`) ad ogni deploy.

---

### Riferimenti
- Piano: `C:\Users\andrea\.claude\plans\voglio-che-questo-progetto-immutable-pillow.md`
- Bug noti (anche per i progetti gemelli): `Bug.md`
- Guida progetto: `CLAUDE.md`
- Repo: https://github.com/ReNumaa/PalestrIA.git
