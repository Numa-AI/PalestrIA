// Edge Function: billing-portal
// Billing-SaaS: apre lo Stripe Customer Portal per il trainer (owner/admin),
// dove può gestire/cancellare l'abbonamento alla piattaforma, aggiornare il
// metodo di pagamento e scaricare le fatture.
//
// Input:   nessun body richiesto.
// Auth:    Authorization: Bearer <JWT> del trainer.
// Flusso:  getUser → verifica owner/admin in org_members → recupera
//          subscriptions.stripe_customer_id della org → billingPortal.sessions.create.
// Output:  { url }
//
// Pattern CORS + auth Bearer ripreso da create-checkout/index.ts.

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY");
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL");
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const SITE_URL          = Deno.env.get("SITE_URL") || "https://palestria-demo.app";

if (!STRIPE_SECRET_KEY) console.error("[billing-portal] FATAL: STRIPE_SECRET_KEY not configured");
if (!SUPABASE_URL)      console.error("[billing-portal] FATAL: SUPABASE_URL not configured");
if (!SUPABASE_KEY)      console.error("[billing-portal] FATAL: SUPABASE_SERVICE_ROLE_KEY not configured");

const stripe = STRIPE_SECRET_KEY
    ? new Stripe(STRIPE_SECRET_KEY, { apiVersion: "2024-12-18.acacia" })
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
            console.warn("[billing-portal] auth: missing or malformed Authorization header");
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_missing" }, 401);
        }
        const token = authHeader.slice("Bearer ".length).trim();
        if (!token) {
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_missing" }, 401);
        }

        const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);
        const { data: { user }, error: authError } = await supabase.auth.getUser(token);
        if (authError || !user) {
            console.warn("[billing-portal] auth: getUser failed:", authError?.message || "no user");
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_invalid" }, 401);
        }

        // ── Autorizzazione: owner/admin di una org ────────────────────────────
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
            console.error("[billing-portal] org_members query error:", memberErr.message);
            return json({ error: "Errore interno", code: "internal_error" }, 500);
        }
        if (!membership) {
            console.warn("[billing-portal] forbidden: user is not owner/admin of any org:", user.id);
            return json({ error: "Operazione riservata al titolare dello studio.", code: "forbidden" }, 403);
        }
        const orgId = membership.org_id;

        // ── Recupera lo Stripe Customer della org ─────────────────────────────
        const { data: sub, error: subErr } = await supabase
            .from("subscriptions")
            .select("stripe_customer_id")
            .eq("org_id", orgId)
            .maybeSingle();

        if (subErr) {
            console.error("[billing-portal] subscriptions query error:", subErr.message);
            return json({ error: "Errore interno", code: "internal_error" }, 500);
        }
        if (!sub?.stripe_customer_id) {
            // Nessun customer Stripe: la org non ha ancora avviato un checkout a pagamento.
            return json({ error: "Nessun abbonamento attivo da gestire.", code: "no_customer" }, 409);
        }

        // ── Crea la sessione del Customer Portal ──────────────────────────────
        let session;
        try {
            session = await stripe.billingPortal.sessions.create({
                customer: sub.stripe_customer_id,
                return_url: `${SITE_URL}/admin.html?billing=portal`,
            });
        } catch (stripeErr) {
            console.error("[billing-portal] stripe error:", stripeErr);
            return json({ error: "Errore nell'apertura del portale di fatturazione", code: "stripe_error" }, 502);
        }

        return json({ url: session.url }, 200);
    } catch (e) {
        console.error("[billing-portal] unexpected error:", e);
        return json({ error: "Errore interno", code: "internal_error" }, 500);
    }
});
