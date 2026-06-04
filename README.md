# PalestrIA — il gestionale SaaS per personal trainer e studi fitness

PalestrIA è una piattaforma **multi-tenant self-serve** che dà a ogni personal
trainer (o studio, con staff) il proprio gestionale completo: prenotazioni con
calendario, schede di allenamento, gestione clienti, pagamenti e report — tutto
in una **PWA installabile** che funziona anche offline.

Chiunque può registrarsi, creare il proprio studio in pochi secondi e iniziare
con un **trial di 30 giorni**. Niente da installare per i clienti finali: aprono
un link, prenotano, consultano la scheda.

---

## Architettura (zero-build + Supabase + PWA)

- **Frontend**: HTML + CSS + JavaScript **vanilla, zero-build**. Niente bundler,
  niente framework. Le dipendenze esterne (Supabase JS, jsPDF, PDF.js) arrivano
  via CDN. Una pagina = un file `.html` con i suoi `<script src="js/*.js">`.
- **Backend**: **Supabase** — Postgres con Row Level Security, Auth, Edge
  Functions (Deno/TypeScript), Storage, Realtime.
- **PWA**: Service Worker offline-first (`sw.js`), manifest installabile, supporto
  iOS/Android.
- **Hosting**: statico (oggi GitHub Pages; per il SaaS in produzione si valuta
  hosting con sottodomini per-tenant).

Lo schema DB consolidato vive in `supabase/migrations/00000000000000_baseline.sql`
(progetto Supabase greenfield, già multi-tenant).

---

## Modello multi-tenant (`org_id` + RLS)

Ogni studio/trainer è un **tenant isolato** rappresentato da una riga in
`organizations` (slug, branding, timezone, valuta, stato). L'isolamento dei dati
è garantito a livello database:

- **Tabelle di tenancy**: `organizations`, `org_members` (staff con `role` ∈
  `owner`/`admin`/`staff`) e `profiles.org_id` (i clienti finali appartengono a
  una org).
- **Ogni tabella business porta `org_id NOT NULL`** + RLS org-scoped. Nessuna
  policy `USING(true)`.
- **Helper SQL**: `current_org_id()`, `is_org_admin([p_org_id])`,
  `org_id_for_slug(slug)`, `get_tenant_entitlements()`.
- I claim di tenancy (`app_metadata.org_id` / `org_role`) vengono iniettati nel
  JWT dall'**auth hook** `custom-access-token-hook`, così le policy RLS sanno a
  quale org appartiene ogni richiesta.

---

## Piani e prezzi

Abbonamento mensile alla piattaforma, con **trial di 30 giorni** su tutti i piani.
Il tier si sceglie in base al numero di clienti iscritti allo studio.

| Piano      | Prezzo/mese | Clienti     | Highlight                                  |
|------------|-------------|-------------|--------------------------------------------|
| Starter    | € 39,99     | fino a 50   | Prenotazioni, schede, messaggi             |
| Pro        | € 79,99     | fino a 200  | + report AI, pagamenti online dei clienti  |
| Business   | € 149,99    | illimitati  | Tutto Pro, senza limiti di clienti         |

I piani sono già nel baseline (tabella `plans`). Gli `stripe_price_id_monthly`
si impostano dopo aver creato i prodotti su Stripe.

---

## Due flussi Stripe (da non confondere)

PalestrIA gestisce **due flussi di denaro distinti**, su livelli diversi:

1. **Abbonamento SaaS** — il *trainer paga la piattaforma*. Ricorrente mensile,
   usa l'account Stripe **della piattaforma**. Flusso gestito dalle Edge
   Functions `billing-checkout` (avvio del Checkout Stripe) e `billing-portal`
   (Customer Portal per gestire/cancellare l'abbonamento). Lo stato vive in
   `subscriptions` / `subscription_events`.

2. **Pagamenti-cliente** — il *cliente paga il trainer* per le lezioni
   (a entrata / mensile / pacchetto / gratuito). Modello **configurabile** dallo
   studio (`billing_settings`). I pagamenti online passano da Stripe; quelli
   manuali (contanti/carta/bonifico) vengono registrati a mano e funzionano
   senza Stripe. Ledger unico in `payments`, con `client_packages` e
   `client_memberships`.

Entrambi i flussi convergono sulla **stessa Edge Function** `stripe-webhook`,
autenticata dalla **firma Stripe** (`STRIPE_WEBHOOK_SECRET`) e idempotente
(`subscription_events.stripe_event_id` UNIQUE / `payments.stripe_payment_intent`
UNIQUE).

---

## Onboarding self-serve

1. L'utente si registra (Supabase Auth).
2. Chiama la RPC `create_organization(name, slug)`: crea la org, la membership
   `owner`, i `billing_settings`, gli slot types di default e avvia una
   `subscription` in **trial 30 giorni** sul piano `starter`.
3. L'auth hook inietta `org_id`/`org_role` nel JWT al login successivo.
4. Lo studio configura orari, prezzi e branding e condivide il proprio link
   pubblico di prenotazione (`org_id_for_slug` risolve la org per i clienti
   anonimi).

---

## Sviluppo

Serve la [Supabase CLI](https://supabase.com/docs/guides/local-development).

```bash
# Avvia lo stack locale (Postgres, Auth, Storage, Studio, Edge Runtime)
supabase start

# Reset del DB locale: applica le migration + esegue supabase/seed.sql
supabase db reset

# Allinea il DB remoto con le migration locali
supabase db push

# Deploy delle Edge Functions
supabase functions deploy <nome-function>
supabase functions deploy            # tutte
```

I secret di piattaforma per le Edge Functions (`STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SITE_URL`,
…) si impostano via `supabase secrets set` e **non** vanno mai committati.
Il file `supabase/config.toml` tiene `verify_jwt = true` di default; è `false`
solo per `stripe-webhook` (firma Stripe), `custom-access-token-hook` (chiamata da
GoTrue) e `image-proxy` (proxy pubblico).

---

## Documentazione per gli sviluppatori

Convenzioni di codice, regole multi-tenant non negoziabili, mappa dei file ed
elenco delle Edge Functions sono in **[CLAUDE.md](./CLAUDE.md)**. Leggilo prima
di modificare il codice.
