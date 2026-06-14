// Edge Function: create-checkout
// Crea una sessione Stripe Checkout per la ricarica credito.
// Chiamata dal client con Authorization: Bearer <JWT>.

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY");
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL");
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const SITE_URL          = Deno.env.get("SITE_URL") || "https://palestria-demo.app";

// Fail-fast: se manca una secret critica meglio 500 esplicito che un placeholder
// che farebbe fallire Stripe con errori ambigui lato client.
if (!STRIPE_SECRET_KEY) console.error("[create-checkout] FATAL: STRIPE_SECRET_KEY not configured");
if (!SUPABASE_URL)      console.error("[create-checkout] FATAL: SUPABASE_URL not configured");
if (!SUPABASE_KEY)      console.error("[create-checkout] FATAL: SUPABASE_SERVICE_ROLE_KEY not configured");

const stripe = STRIPE_SECRET_KEY
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

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (!stripe || !SUPABASE_URL || !SUPABASE_KEY) {
        return json({ error: "Servizio non configurato", code: "config_missing" }, 500);
    }

    try {
        const authHeader = req.headers.get("Authorization");
        if (!authHeader || !authHeader.startsWith("Bearer ")) {
            console.warn("[create-checkout] auth: missing or malformed Authorization header");
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_missing" }, 401);
        }

        const token = authHeader.slice("Bearer ".length).trim();
        if (!token) {
            console.warn("[create-checkout] auth: empty bearer token");
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_missing" }, 401);
        }

        const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);
        const { data: { user }, error: authError } = await supabase.auth.getUser(token);

        if (authError || !user) {
            console.warn("[create-checkout] auth: getUser failed:", authError?.message || "no user");
            return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_invalid" }, 401);
        }

        const { amount, user_email, user_name } = await req.json();

        const amountCents = Math.round(Number(amount) * 100);
        if (!amount || amountCents < 5000) {
            return json({ error: "Importo minimo: €50", code: "amount_invalid" }, 400);
        }

        // stripe_enabled e' solo un flag UI (mostra il bottone ricarica a prescindere
        // dal saldo). Chiunque sia autenticato puo' ricaricare: niente gate qui.

        let session;
        try {
            session = await stripe.checkout.sessions.create({
                payment_method_types: ["card"],
                mode: "payment",
                line_items: [{
                    price_data: {
                        currency: "eur",
                        unit_amount: amountCents,
                        product_data: {
                            name: "Ricarica credito palestra",
                            description: `Ricarica €${amount} — ${user_name || user_email || ""}`.trim(),
                        },
                    },
                    quantity: 1,
                }],
                customer_email: user_email || user.email,
                metadata: {
                    supabase_user_id: user.id,
                    amount_eur: String(amount),
                },
                success_url: `${SITE_URL}/prenotazioni.html?topup=success`,
                cancel_url:  `${SITE_URL}/prenotazioni.html?topup=cancel`,
            });
        } catch (stripeErr) {
            console.error("[create-checkout] stripe error:", stripeErr);
            return json({ error: "Errore nella creazione del pagamento", code: "stripe_error" }, 502);
        }

        return json({ url: session.url }, 200);
    } catch (e) {
        console.error("[create-checkout] unexpected error:", e);
        return json({ error: "Errore interno", code: "internal_error" }, 500);
    }
});
