// Edge Function: stripe-webhook
// ─────────────────────────────────────────────────────────────────────────────
// Punto unico di ricezione dei webhook Stripe per la piattaforma PalestrIA.
//
// Gestisce due famiglie di eventi:
//
//  1) ABBONAMENTO SaaS (mode='subscription') — il trainer paga la piattaforma.
//     Sincronizza la tabella `subscriptions` (per org) e allinea
//     `organizations.status` allo stato Stripe della sottoscrizione.
//
//  2) PAGAMENTO-CLIENTE (mode='payment') — il cliente paga il trainer.
//     Registra una riga nel ledger `payments` e, se richiesto dal `kind`,
//     crea il relativo `client_packages` / `client_memberships`.
//
// Sicurezza: NON usa l'Authorization header (verify_jwt=false). La fiducia
// deriva esclusivamente dalla verifica della firma Stripe (STRIPE_WEBHOOK_SECRET)
// tramite constructEventAsync. Le scritture usano la SERVICE_ROLE_KEY.
//
// Idempotenza: ogni evento viene registrato in `subscription_events`
// (stripe_event_id UNIQUE). Se l'evento è già stato visto si esce con 200
// senza riprocessarlo, così Stripe non ritenta inutilmente.
// ─────────────────────────────────────────────────────────────────────────────

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY     = Deno.env.get("STRIPE_SECRET_KEY")     || "";
const STRIPE_WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") || "";
const SUPABASE_URL          = Deno.env.get("SUPABASE_URL")          || "";
const SUPABASE_KEY          = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// Fail-fast: meglio un log chiaro all'avvio che errori opachi a runtime.
if (!STRIPE_SECRET_KEY)     console.error("[stripe-webhook] FATAL: STRIPE_SECRET_KEY mancante");
if (!STRIPE_WEBHOOK_SECRET) console.error("[stripe-webhook] FATAL: STRIPE_WEBHOOK_SECRET mancante");
if (!SUPABASE_URL)          console.error("[stripe-webhook] FATAL: SUPABASE_URL mancante");
if (!SUPABASE_KEY)          console.error("[stripe-webhook] FATAL: SUPABASE_SERVICE_ROLE_KEY mancante");

const stripe   = new Stripe(STRIPE_SECRET_KEY, { apiVersion: "2024-12-18.acacia" as any });
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// ─────────────────────────────────────────────────────────────────────────────
// Utility
// ─────────────────────────────────────────────────────────────────────────────

/** Converte un timestamp Stripe (secondi epoch) in ISO string, o null. */
function tsToIso(sec: number | null | undefined): string | null {
    return typeof sec === "number" && sec > 0 ? new Date(sec * 1000).toISOString() : null;
}

/**
 * Mappa lo stato della subscription Stripe sullo stato della org.
 * organizations.status ammette: trialing | active | past_due | suspended | cancelled
 * subscriptions.status ammette:  trialing | active | past_due | canceled | unpaid | incomplete
 */
function orgStatusFromSub(subStatus: string): string {
    switch (subStatus) {
        case "trialing":   return "trialing";
        case "active":     return "active";
        case "past_due":   return "past_due";
        case "unpaid":     return "suspended";   // morosità prolungata → org sospesa
        case "incomplete": return "suspended";   // pagamento iniziale non completato
        case "canceled":   return "cancelled";
        default:           return "suspended";   // stato inatteso → prudente
    }
}

/** Normalizza lo stato Stripe sul check constraint di subscriptions.status. */
function normalizeSubStatus(s: string | null | undefined): string {
    const allowed = ["trialing", "active", "past_due", "canceled", "unpaid", "incomplete"];
    if (s && allowed.includes(s)) return s;
    // 'incomplete_expired' e simili → li trattiamo come canceled
    if (s === "incomplete_expired") return "canceled";
    return "incomplete";
}

/** Risolve il plan_id locale a partire dallo Stripe price id (mensile). */
async function planIdFromPriceId(priceId: string | null | undefined): Promise<string | null> {
    if (!priceId) return null;
    const { data, error } = await supabase
        .from("plans")
        .select("id")
        .eq("stripe_price_id_monthly", priceId)
        .maybeSingle();
    if (error) {
        console.error("[stripe-webhook] planIdFromPriceId errore:", error.message);
        return null;
    }
    return data?.id ?? null;
}

/** Estrae il price id principale da un oggetto subscription Stripe. */
function priceIdFromSubscription(sub: Stripe.Subscription): string | null {
    return sub.items?.data?.[0]?.price?.id ?? null;
}

/** Estrae lo stripe_customer_id (stringa) da un oggetto subscription Stripe. */
function customerIdFromSubscription(sub: Stripe.Subscription): string | null {
    return typeof sub.customer === "string" ? sub.customer : sub.customer?.id ?? null;
}

/**
 * Risolve la org a partire dallo stripe_customer_id (fonte di verità lato server):
 * lo customer è legato alla org in `subscriptions.stripe_customer_id`. Questo evita
 * di fidarsi di metadata.org_id influenzabile dal mittente (cfr. M1).
 */
async function orgIdFromCustomer(customerId: string | null): Promise<string | null> {
    if (!customerId) return null;
    const { data: sub, error: subErr } = await supabase
        .from("subscriptions")
        .select("org_id")
        .eq("stripe_customer_id", customerId)
        .maybeSingle();
    if (subErr) console.error("[stripe-webhook] lookup org da customer errore:", subErr.message);
    return sub?.org_id ?? null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Sincronizzazione SUBSCRIPTION (SaaS)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * UPSERT su `subscriptions` a partire da un oggetto Stripe.Subscription e allinea
 * `organizations.status`. La org viene risolta:
 *   - dall'org_id passato (es. da checkout.session.completed via client_reference_id), oppure
 *   - dalla riga subscriptions esistente con lo stesso stripe_subscription_id.
 */
async function syncSubscription(sub: Stripe.Subscription, orgIdHint: string | null): Promise<void> {
    const priceId  = priceIdFromSubscription(sub);
    const planId   = await planIdFromPriceId(priceId);
    const subStatus = normalizeSubStatus(sub.status);
    const customerId = customerIdFromSubscription(sub);

    // ── Determina la org di destinazione (fonte di verità = lato server) ──────
    // 1) preferiamo l'org legata allo stripe_customer_id (in subscriptions);
    // 2) poi l'org della riga subscriptions con lo stesso stripe_subscription_id;
    // 3) infine il "hint" (client_reference_id del checkout o metadata.org_id):
    //    serve SOLO alla PRIMA sincronizzazione, quando non esiste ancora una riga
    //    da cui derivare l'org dal customer.
    // Se sia il customer/sub esistente CHE il hint risolvono una org, devono
    // combaciare: in caso contrario l'evento è mal-attribuito → log e usiamo
    // la fonte server (customer), MAI il hint influenzabile (cfr. M1).
    let orgId = await orgIdFromCustomer(customerId);

    if (!orgId) {
        const { data: existing, error } = await supabase
            .from("subscriptions")
            .select("org_id")
            .eq("stripe_subscription_id", sub.id)
            .maybeSingle();
        if (error) console.error("[stripe-webhook] lookup subscription org_id errore:", error.message);
        orgId = existing?.org_id ?? null;
    }

    if (orgId && orgIdHint && orgId !== orgIdHint) {
        console.warn(`[stripe-webhook] subscription ${sub.id}: mismatch org server=${orgId} hint=${orgIdHint} → uso la fonte server`);
    }

    if (!orgId) {
        // Nessuna org server-side: prima sincronizzazione → usiamo il hint.
        orgId = orgIdHint;
    }

    if (!orgId) {
        // Senza org non possiamo collegare la subscription: logghiamo e usciamo
        // (l'evento resta registrato in subscription_events per audit).
        console.warn(`[stripe-webhook] subscription ${sub.id}: org_id non risolvibile, skip`);
        return;
    }

    const row: Record<string, unknown> = {
        org_id:                 orgId,
        plan_id:                planId,
        stripe_customer_id:     customerId,
        stripe_subscription_id: sub.id,
        status:                 subStatus,
        current_period_end:     tsToIso(sub.current_period_end),
        cancel_at_period_end:   Boolean(sub.cancel_at_period_end),
        trial_end:              tsToIso(sub.trial_end),
        updated_at:             new Date().toISOString(),
    };

    // org_id è UNIQUE su subscriptions → upsert per org garantisce 1 riga per org.
    const { error: upErr } = await supabase
        .from("subscriptions")
        .upsert(row, { onConflict: "org_id" });
    if (upErr) {
        console.error("[stripe-webhook] upsert subscriptions errore:", upErr.message);
        throw upErr;
    }

    // Allinea lo stato della org.
    const newOrgStatus = orgStatusFromSub(subStatus);
    const { error: orgErr } = await supabase
        .from("organizations")
        .update({ status: newOrgStatus, updated_at: new Date().toISOString() })
        .eq("id", orgId);
    if (orgErr) console.error("[stripe-webhook] update organizations.status errore:", orgErr.message);

    console.log(`[stripe-webhook] subscription ${sub.id} → org ${orgId} status=${subStatus}/${newOrgStatus} plan=${planId ?? "?"}`);
}

/**
 * Recupera la subscription completa da Stripe (per id) e la sincronizza.
 * Usato dagli eventi invoice.* che portano solo l'id della subscription.
 */
async function syncSubscriptionById(subscriptionId: string | null, orgIdHint: string | null): Promise<void> {
    if (!subscriptionId) return;
    try {
        const sub = await stripe.subscriptions.retrieve(subscriptionId);
        await syncSubscription(sub, orgIdHint);
    } catch (e) {
        console.error(`[stripe-webhook] retrieve subscription ${subscriptionId} errore:`, e);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PAGAMENTO-CLIENTE (mode='payment')
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Registra un pagamento-cliente nel ledger `payments` (idempotente su
 * stripe_payment_intent) e, se il `kind` lo richiede, crea il pacchetto o
 * l'abbonamento del cliente. I dati arrivano dai metadata della sessione di
 * checkout creata lato piattaforma.
 *
 * metadata attesi:
 *   org_id          (uuid)  — org di destinazione
 *   kind            (text)  — 'session' | 'package_purchase' | 'membership'
 *   client_user_id  (uuid?) — profilo cliente (opzionale)
 *   booking_id      (uuid?) — per kind='session'
 *   total_sessions  (int?)  — per kind='package_purchase'
 *   package_label   (text?) — per kind='package_purchase'
 *   plan_label      (text?) — per kind='membership'
 *   period_start    (date?) — per kind='membership'
 *   period_end      (date?) — per kind='membership'
 *   lessons_quota   (int?)  — per kind='membership' (null = illimitato)
 */
async function handleClientPayment(session: Stripe.Checkout.Session): Promise<void> {
    const md = session.metadata || {};
    const orgId = md.org_id || null;
    const kind  = md.kind   || null;

    if (!orgId) {
        console.error("[stripe-webhook] client payment: metadata.org_id mancante, skip");
        return;
    }
    const allowedKinds = ["session", "package_purchase", "membership"];
    if (!kind || !allowedKinds.includes(kind)) {
        console.error(`[stripe-webhook] client payment: kind non valido (${kind}), skip`);
        return;
    }

    // Riferimento Stripe univoco per l'idempotenza: il PaymentIntent della sessione.
    const paymentIntentId =
        typeof session.payment_intent === "string"
            ? session.payment_intent
            : session.payment_intent?.id ?? session.id; // fallback: id sessione

    const amount = (session.amount_total ?? 0) / 100; // centesimi → euro
    const currency = (session.currency || "eur").toUpperCase();
    const clientUserId = md.client_user_id || null;
    const clientEmail  = session.customer_details?.email || session.customer_email || md.client_email || null;
    const bookingId    = md.booking_id || null;

    // 1) Idempotenza: se esiste già un payment con questo intent, non rifacciamo nulla.
    const { data: existingPay, error: existErr } = await supabase
        .from("payments")
        .select("id")
        .eq("stripe_payment_intent", paymentIntentId)
        .maybeSingle();
    if (existErr) console.error("[stripe-webhook] lookup payment esistente errore:", existErr.message);
    if (existingPay) {
        console.log(`[stripe-webhook] client payment già registrato (intent ${paymentIntentId}), skip`);
        return;
    }

    // 2) Crea l'eventuale pacchetto / abbonamento prima del payment, così possiamo
    //    collegarne l'id nel ledger (FK opzionali su payments).
    let packageId: string | null = null;
    let membershipId: string | null = null;

    if (kind === "package_purchase") {
        const totalSessions = parseInt(md.total_sessions || "0", 10);
        if (clientUserId && totalSessions > 0) {
            const { data: pkg, error: pkgErr } = await supabase
                .from("client_packages")
                .insert({
                    org_id:             orgId,
                    user_id:            clientUserId,
                    label:              md.package_label || "Pacchetto",
                    total_sessions:     totalSessions,
                    remaining_sessions: totalSessions,
                    expires_at:         md.expires_at || null,
                    price:              amount,
                    status:             "active",
                })
                .select("id")
                .single();
            if (pkgErr) console.error("[stripe-webhook] insert client_packages errore:", pkgErr.message);
            else packageId = pkg?.id ?? null;
        } else {
            console.warn("[stripe-webhook] package_purchase: client_user_id o total_sessions mancanti, salto creazione pacchetto");
        }
    }

    if (kind === "membership") {
        const periodStart = md.period_start || null;
        const periodEnd   = md.period_end   || null;
        if (clientUserId && periodStart && periodEnd) {
            const lessonsQuota = md.lessons_quota ? parseInt(md.lessons_quota, 10) : null;
            const { data: mem, error: memErr } = await supabase
                .from("client_memberships")
                .insert({
                    org_id:        orgId,
                    user_id:       clientUserId,
                    plan_label:    md.plan_label || "Abbonamento",
                    period_start:  periodStart,
                    period_end:    periodEnd,
                    lessons_quota: lessonsQuota,
                    price:         amount,
                    status:        "active",
                })
                .select("id")
                .single();
            if (memErr) console.error("[stripe-webhook] insert client_memberships errore:", memErr.message);
            else membershipId = mem?.id ?? null;
        } else {
            console.warn("[stripe-webhook] membership: client_user_id/period_start/period_end mancanti, salto creazione abbonamento");
        }
    }

    // 3) Riga ledger nel payments. method='stripe' (pagamento online cliente).
    const { error: payErr } = await supabase
        .from("payments")
        .insert({
            org_id:               orgId,
            client_user_id:       clientUserId,
            client_email:         clientEmail,
            amount,
            currency,
            method:               "stripe",
            kind,
            booking_id:           bookingId,
            membership_id:        membershipId,
            package_id:           packageId,
            note:                 md.note || null,
            stripe_payment_intent: paymentIntentId,
        });

    if (payErr) {
        // 23505 = unique_violation: race con un altro tentativo → trattiamo come idempotente.
        if ((payErr as { code?: string }).code === "23505") {
            console.log(`[stripe-webhook] client payment race su intent ${paymentIntentId}, già presente`);
            return;
        }
        console.error("[stripe-webhook] insert payments errore:", payErr.message);
        throw payErr;
    }

    console.log(`[stripe-webhook] client payment registrato org=${orgId} kind=${kind} amount=${amount}${currency} intent=${paymentIntentId}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// Dispatcher eventi
// ─────────────────────────────────────────────────────────────────────────────

async function processEvent(event: Stripe.Event): Promise<void> {
    switch (event.type) {
        // ── Checkout completato ────────────────────────────────────────────────
        case "checkout.session.completed": {
            const session = event.data.object as Stripe.Checkout.Session;

            if (session.mode === "subscription") {
                // Abbonamento SaaS: la org viene da client_reference_id (preferito)
                // o da metadata.org_id come fallback.
                const orgId = session.client_reference_id || session.metadata?.org_id || null;
                const subscriptionId =
                    typeof session.subscription === "string"
                        ? session.subscription
                        : session.subscription?.id ?? null;
                await syncSubscriptionById(subscriptionId, orgId);
            } else if (session.mode === "payment") {
                // Pagamento-cliente: registriamo solo se realmente pagato.
                if (session.payment_status !== "paid") {
                    console.warn(`[stripe-webhook] checkout payment non pagato (${session.payment_status}), skip ${session.id}`);
                    break;
                }
                await handleClientPayment(session);
            } else {
                console.log(`[stripe-webhook] checkout.session.completed mode non gestito: ${session.mode}`);
            }
            break;
        }

        // ── Ciclo di vita della subscription ────────────────────────────────────
        case "customer.subscription.created":
        case "customer.subscription.updated":
        case "customer.subscription.deleted": {
            const sub = event.data.object as Stripe.Subscription;
            const orgIdHint = sub.metadata?.org_id || null;
            await syncSubscription(sub, orgIdHint);
            break;
        }

        // ── Fatturazione ricorrente ─────────────────────────────────────────────
        case "invoice.payment_succeeded":
        case "invoice.payment_failed": {
            const invoice = event.data.object as Stripe.Invoice;
            const subscriptionId =
                typeof invoice.subscription === "string"
                    ? invoice.subscription
                    : invoice.subscription?.id ?? null;
            const orgIdHint = invoice.subscription_details?.metadata?.org_id || invoice.metadata?.org_id || null;
            // Ri-sincronizziamo dalla fonte di verità (la subscription) così lo
            // stato/period_end riflettono l'esito reale del pagamento.
            await syncSubscriptionById(subscriptionId, orgIdHint);
            break;
        }

        default:
            console.log(`[stripe-webhook] evento ignorato: ${event.type}`);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP handler
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204 });
    }
    if (req.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
    }

    // 1) Verifica firma Stripe (unica fonte di autenticazione).
    let event: Stripe.Event;
    try {
        const body = await req.text();
        const sig  = req.headers.get("stripe-signature");
        if (!sig) {
            console.warn("[stripe-webhook] firma mancante");
            return new Response("Missing signature", { status: 400 });
        }
        event = await stripe.webhooks.constructEventAsync(body, sig, STRIPE_WEBHOOK_SECRET);
    } catch (err) {
        console.error("[stripe-webhook] verifica firma fallita:", err);
        return new Response("Invalid signature", { status: 400 });
    }

    // 2) Idempotenza: registriamo l'evento. Se è un duplicato (ON CONFLICT DO
    //    NOTHING → nessuna riga inserita), usciamo subito senza riprocessare.
    try {
        // Tentiamo di estrarre l'org_id dall'oggetto per arricchire l'audit;
        // non è bloccante se assente.
        const obj = event.data?.object as Record<string, any> | undefined;
        const auditOrgId =
            obj?.client_reference_id ||
            obj?.metadata?.org_id ||
            obj?.subscription_details?.metadata?.org_id ||
            null;

        const { data: inserted, error: insErr } = await supabase
            .from("subscription_events")
            .upsert(
                {
                    stripe_event_id: event.id,
                    type:            event.type,
                    payload:         event as unknown as Record<string, unknown>,
                    org_id:          auditOrgId,
                },
                { onConflict: "stripe_event_id", ignoreDuplicates: true },
            )
            .select("id");

        if (insErr) {
            // Errore di registrazione: meglio NON processare per non perdere
            // l'idempotenza. Rispondiamo 500 così Stripe ritenta.
            console.error("[stripe-webhook] registrazione evento errore:", insErr.message);
            return new Response("Event log failed", { status: 500 });
        }

        // ignoreDuplicates: upsert su conflitto restituisce 0 righe → già visto.
        if (!inserted || inserted.length === 0) {
            console.log(`[stripe-webhook] evento duplicato ${event.id} (${event.type}), skip`);
            return new Response(JSON.stringify({ received: true, duplicate: true }), {
                status: 200,
                headers: { "Content-Type": "application/json" },
            });
        }
    } catch (e) {
        console.error("[stripe-webhook] errore idempotenza:", e);
        return new Response("Idempotency error", { status: 500 });
    }

    // 3) Processiamo l'evento. Eventuali errori → 500 per far ritentare Stripe;
    //    al retry l'evento risulterà già registrato ma, se il processing era
    //    fallito, lo stato a valle è comunque idempotente (upsert/lookup).
    try {
        await processEvent(event);
    } catch (e) {
        console.error(`[stripe-webhook] processing ${event.type} fallito:`, e);
        return new Response(JSON.stringify({ received: true, error: "processing_failed" }), {
            status: 500,
            headers: { "Content-Type": "application/json" },
        });
    }

    return new Response(JSON.stringify({ received: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
    });
});
