// Edge Function: billing-checkout
// Billing-SaaS: il trainer (owner/admin di una org) sottoscrive un piano mensile
// della piattaforma PalestrIA. Crea una Stripe Checkout Session in mode='subscription'.
//
// Input (JSON):  { plan_code: 'starter' | 'pro' | 'business' }
// Auth:          Authorization: Bearer <JWT> del trainer.
// Flusso:        getUser → verifica owner/admin in org_members → risolve plan +
//                stripe_price_id_monthly → recupera/crea stripe.customers →
//                salva subscriptions.stripe_customer_id → crea Checkout Session.
// Output:        { url }
//
// Pattern CORS + auth Bearer ripreso da create-checkout/index.ts.

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY");
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL");
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const SITE_URL          = Deno.env.get("SITE_URL") || "https://palestria-demo.app";

// Fail-fast: meglio 500 esplicito che placeholder che fa fallire Stripe in modo ambiguo.
if (!STRIPE_SECRET_KEY) console.error("[billing-checkout] FATAL: STRIPE_SECRET_KEY not configured");
if (!SUPABASE_URL)      console.error("[billing-checkout] FATAL: SUPABASE_URL not configured");
if (!SUPABASE_KEY)      console.error("[billing-checkout] FATAL: SUPABASE_SERVICE_ROLE_KEY not configured");

const stripe = STRIPE_SECRET_KEY
    // apiVersion pinnata di proposito: l'SDK npm:stripe@17 vincola il literal alla SUA
    // default (che drifta tra minor) → cast `as any` per mantenere la versione testata.
    ? new Stripe(STRIPE_SECRET_KEY, { apiVersion: "2024-12-18.acacia" as any })
    : null;

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

const TRIAL_PERIOD_DAYS = 30;

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (!stripe || !SUPABASE_URL || !SUPABASE_KEY) {
        return json({ error: "Servizio non configurato", code: "config_missing" }, 500);
    }

    try {
        // ── Auth: Bearer JWT del trainer ──────────────────────────────────────
        const authHeader = req.headers.get("Authorization");
        if (!authHeader || !authHeader.startsWith("Bearer ")) {
            console.warn("[billing-checkout] auth: missing or malformed Authorization header");
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_missing" }, 401);
        }
        const token = authHeader.slice("Bearer ".length).trim();
        if (!token) {
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_missing" }, 401);
        }

        // Service role: ci serve sia per getUser sia per leggere/scrivere subscriptions
        // (le scritture su subscriptions sono riservate al service_role — vedi RLS baseline).
        const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);
        const { data: { user }, error: authError } = await supabase.auth.getUser(token);
        if (authError || !user) {
            console.warn("[billing-checkout] auth: getUser failed:", authError?.message || "no user");
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_invalid" }, 401);
        }

        // ── Input ─────────────────────────────────────────────────────────────
        const { plan_code } = await req.json();
        const planCode = String(plan_code || "").trim().toLowerCase();
        if (!["starter", "pro", "business"].includes(planCode)) {
            return json({ error: "Piano non valido", code: "plan_invalid" }, 400);
        }

        // ── Autorizzazione: il chiamante deve essere owner/admin di una org ────
        const { data: membership, error: memberErr } = await supabase
            .from("org_members")
            .select("org_id, role")
            .eq("user_id", user.id)
            .eq("status", "active")
            .in("role", ["owner", "admin"])
            .order("created_at", { ascending: true })
            .limit(1)
            .maybeSingle();

        if (memberErr) {
            console.error("[billing-checkout] org_members query error:", memberErr.message);
            return json({ error: "Errore interno", code: "internal_error" }, 500);
        }
        if (!membership) {
            console.warn("[billing-checkout] forbidden: user is not owner/admin of any org:", user.id);
            return json({ error: "Operazione riservata al titolare dello studio.", code: "forbidden" }, 403);
        }
        const orgId = membership.org_id;

        // ── Risolvi piano + price Stripe mensile ──────────────────────────────
        const { data: plan, error: planErr } = await supabase
            .from("plans")
            .select("id, code, stripe_price_id_monthly")
            .eq("code", planCode)
            .eq("active", true)
            .maybeSingle();

        if (planErr) {
            console.error("[billing-checkout] plans query error:", planErr.message);
            return json({ error: "Errore interno", code: "internal_error" }, 500);
        }
        if (!plan || !plan.stripe_price_id_monthly) {
            console.error("[billing-checkout] plan price not configured for:", planCode);
            return json({ error: "Piano non disponibile", code: "plan_unavailable" }, 400);
        }

        // ── Org + subscription esistente (la sub trial è creata da create_organization) ──
        const { data: org } = await supabase
            .from("organizations")
            .select("id, name")
            .eq("id", orgId)
            .maybeSingle();

        const { data: existingSub } = await supabase
            .from("subscriptions")
            .select("id, stripe_customer_id")
            .eq("org_id", orgId)
            .maybeSingle();

        // ── Recupera/crea lo Stripe Customer della org ────────────────────────
        let customerId = existingSub?.stripe_customer_id || null;
        if (!customerId) {
            const customer = await stripe.customers.create({
                email: user.email || undefined,
                name: org?.name || undefined,
                metadata: {
                    org_id: orgId,
                    supabase_user_id: user.id,
                },
            });
            customerId = customer.id;

            // Persisti il customer sulla subscription della org (upsert su org_id UNIQUE).
            const { error: upsertErr } = await supabase
                .from("subscriptions")
                .upsert(
                    { org_id: orgId, stripe_customer_id: customerId },
                    { onConflict: "org_id" },
                );
            if (upsertErr) {
                console.error("[billing-checkout] subscriptions upsert error:", upsertErr.message);
                // non fatale: il customer esiste su Stripe; il webhook potrà riconciliare.
            }
        }

        // ── Crea la Checkout Session (subscription mensile, trial 30gg) ───────
        let session;
        try {
            session = await stripe.checkout.sessions.create({
                mode: "subscription",
                customer: customerId,
                client_reference_id: orgId,
                line_items: [{ price: plan.stripe_price_id_monthly, quantity: 1 }],
                subscription_data: {
                    trial_period_days: TRIAL_PERIOD_DAYS,
                    metadata: {
                        org_id: orgId,
                        plan_id: plan.id,
                        plan_code: plan.code,
                    },
                },
                metadata: {
                    org_id: orgId,
                    plan_id: plan.id,
                    plan_code: plan.code,
                },
                success_url: `${SITE_URL}/admin.html?billing=success`,
                cancel_url:  `${SITE_URL}/admin.html?billing=cancel`,
            });
        } catch (stripeErr) {
            console.error("[billing-checkout] stripe error:", stripeErr);
            return json({ error: "Errore nella creazione dell'abbonamento", code: "stripe_error" }, 502);
        }

        return json({ url: session.url }, 200);
    } catch (e) {
        console.error("[billing-checkout] unexpected error:", e);
        return json({ error: "Errore interno", code: "internal_error" }, 500);
    }
});
