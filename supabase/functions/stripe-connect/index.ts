// Edge Function: stripe-connect
// Stripe Connect (Standard): il trainer collega il PROPRIO account Stripe così che
// i pagamenti dei clienti arrivino direttamente a lui (commissione piattaforma = 0).
// La piattaforma NON riceve i soldi: fa solo da "ponte" OAuth. Salviamo SOLO l'id
// dell'account connesso (acct_…), MAI chiavi segrete del trainer.
//
// Azioni:
//   POST { action: 'start' }       → (auth Bearer del trainer) ritorna { url } verso Stripe OAuth.
//   GET  ?action=callback&code&state → (redirect del browser da Stripe) scambia il code,
//                                      salva acct_… sulla org, poi redirect all'app.
//   POST { action: 'disconnect' }  → (auth Bearer) de-autorizza e azzera i campi Connect.
//
// verify_jwt = false: il callback è un redirect del browser SENZA Bearer. Le azioni
// start/disconnect validano comunque il Bearer internamente (getUser).
//
// Secret richiesti (edge): STRIPE_SECRET_KEY, STRIPE_CONNECT_CLIENT_ID,
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SITE_URL.

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY");
const CONNECT_CLIENT_ID = Deno.env.get("STRIPE_CONNECT_CLIENT_ID");
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL");
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const SITE_URL          = Deno.env.get("SITE_URL") || "https://renumaa.github.io/PalestrIA";

if (!STRIPE_SECRET_KEY) console.error("[stripe-connect] FATAL: STRIPE_SECRET_KEY not configured");
if (!CONNECT_CLIENT_ID) console.error("[stripe-connect] FATAL: STRIPE_CONNECT_CLIENT_ID not configured");
if (!SUPABASE_URL)      console.error("[stripe-connect] FATAL: SUPABASE_URL not configured");
if (!SUPABASE_KEY)      console.error("[stripe-connect] FATAL: SUPABASE_SERVICE_ROLE_KEY not configured");

const stripe = STRIPE_SECRET_KEY
    ? new Stripe(STRIPE_SECRET_KEY, { apiVersion: "2024-12-18.acacia" })
    : null;

// redirect_uri del callback: DEVE essere registrato in Stripe → Connect → Settings → Redirects.
const REDIRECT_URI = `${SUPABASE_URL}/functions/v1/stripe-connect?action=callback`;

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
        status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

// Redirect del browser verso l'app (usato nel callback).
const redirectTo = (path: string) =>
    new Response(null, { status: 302, headers: { Location: `${SITE_URL}/${path}` } });

// Risolve la org (owner/admin) del chiamante a partire dal Bearer.
async function resolveAdminOrg(supabase: any, token: string) {
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return { error: "auth_invalid" as const };
    const { data: membership } = await supabase
        .from("org_members")
        .select("org_id, role")
        .eq("user_id", user.id)
        .eq("status", "active")
        .in("role", ["owner", "admin"])
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();
    if (!membership) return { error: "forbidden" as const };
    return { user, orgId: membership.org_id as string };
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }
    if (!stripe || !SUPABASE_URL || !SUPABASE_KEY || !CONNECT_CLIENT_ID) {
        return json({ error: "Servizio non configurato", code: "config_missing" }, 500);
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);
    const url = new URL(req.url);

    // ── CALLBACK (GET, redirect del browser da Stripe) ────────────────────────
    if (req.method === "GET" && url.searchParams.get("action") === "callback") {
        try {
            // L'utente ha annullato l'autorizzazione su Stripe.
            if (url.searchParams.get("error")) {
                return redirectTo("admin.html?stripe=cancelled");
            }
            const code  = url.searchParams.get("code");
            const state = url.searchParams.get("state");
            if (!code || !state) return redirectTo("admin.html?stripe=error");

            // Valida e consuma lo state (anti-CSRF) → otteniamo la org.
            const { data: stateRow } = await supabase
                .from("stripe_oauth_states").select("org_id").eq("state", state).maybeSingle();
            if (!stateRow) return redirectTo("admin.html?stripe=error");
            await supabase.from("stripe_oauth_states").delete().eq("state", state);

            // Scambia il code con l'id dell'account connesso (acct_…).
            const oauthRes = await stripe.oauth.token({ grant_type: "authorization_code", code });
            const acct = oauthRes.stripe_user_id;
            if (!acct) return redirectTo("admin.html?stripe=error");

            // Stato dell'account (incassi attivi? email?).
            let chargesEnabled = false, email: string | null = null;
            try {
                const account = await stripe.accounts.retrieve(acct);
                chargesEnabled = !!account.charges_enabled;
                email = account.email ?? null;
            } catch (_e) { /* non bloccante: salviamo comunque l'acct */ }

            // Salva sull'org (service_role: la guardia trigger consente solo questo ruolo).
            const { error: updErr } = await supabase.from("organizations").update({
                stripe_account_id: acct,
                stripe_charges_enabled: chargesEnabled,
                stripe_account_email: email,
                stripe_connected_at: new Date().toISOString(),
            }).eq("id", stateRow.org_id);
            if (updErr) {
                console.error("[stripe-connect] org update error:", updErr.message);
                return redirectTo("admin.html?stripe=error");
            }
            return redirectTo("admin.html?stripe=connected");
        } catch (e) {
            console.error("[stripe-connect] callback error:", e);
            return redirectTo("admin.html?stripe=error");
        }
    }

    // ── Azioni POST (start / disconnect) — richiedono Bearer del trainer ──────
    if (req.method !== "POST") return json({ error: "Method not allowed", code: "method" }, 405);

    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
        return json({ error: "Sessione scaduta, effettua di nuovo l'accesso.", code: "auth_missing" }, 401);
    }
    const token = authHeader.slice("Bearer ".length).trim();

    let payload: any = {};
    try { payload = await req.json(); } catch (_e) { payload = {}; }
    const action = String(payload.action || "").trim();

    const who = await resolveAdminOrg(supabase, token);
    if ("error" in who) {
        const status = who.error === "forbidden" ? 403 : 401;
        const msg = who.error === "forbidden"
            ? "Operazione riservata al titolare dello studio."
            : "Sessione scaduta, effettua di nuovo l'accesso.";
        return json({ error: msg, code: who.error }, status);
    }
    const orgId = who.orgId;

    try {
        if (action === "start") {
            // Genera uno state random e legalo alla org (anti-CSRF).
            const state = crypto.randomUUID() + crypto.randomUUID().replace(/-/g, "");
            const { error: insErr } = await supabase.from("stripe_oauth_states")
                .insert({ state, org_id: orgId, user_id: who.user.id });
            if (insErr) {
                console.error("[stripe-connect] state insert error:", insErr.message);
                return json({ error: "Errore interno", code: "internal_error" }, 500);
            }
            const authorizeUrl = "https://connect.stripe.com/oauth/authorize?" + new URLSearchParams({
                response_type: "code",
                client_id: CONNECT_CLIENT_ID,
                scope: "read_write",
                redirect_uri: REDIRECT_URI,
                state,
                "stripe_user[email]": who.user.email || "",
            }).toString();
            return json({ url: authorizeUrl }, 200);
        }

        if (action === "disconnect") {
            const { data: org } = await supabase.from("organizations")
                .select("stripe_account_id").eq("id", orgId).maybeSingle();
            const acct = org?.stripe_account_id;
            if (acct) {
                try {
                    await stripe.oauth.deauthorize({ client_id: CONNECT_CLIENT_ID, stripe_user_id: acct });
                } catch (e) {
                    console.warn("[stripe-connect] deauthorize warning:", (e as Error).message);
                }
            }
            const { error: updErr } = await supabase.from("organizations").update({
                stripe_account_id: null,
                stripe_charges_enabled: false,
                stripe_account_email: null,
                stripe_connected_at: null,
            }).eq("id", orgId);
            if (updErr) {
                console.error("[stripe-connect] disconnect update error:", updErr.message);
                return json({ error: "Errore interno", code: "internal_error" }, 500);
            }
            return json({ ok: true }, 200);
        }

        return json({ error: "Azione non valida", code: "bad_action" }, 400);
    } catch (e) {
        console.error("[stripe-connect] unexpected error:", e);
        return json({ error: "Errore interno", code: "internal_error" }, 500);
    }
});
