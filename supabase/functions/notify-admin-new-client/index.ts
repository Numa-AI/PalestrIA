// Edge Function: notify-admin-new-client
// Chiamata dal client dopo una registrazione confermata.
// Manda una push notification AGLI ADMIN DELLA ORG del nuovo iscritto.
//
// SICUREZZA (multi-tenant): il chiamante DEVE essere autenticato (Bearer JWT
// validato con getUser). La org si deriva dal PROFILO del chiamante
// (profiles.org_id) — è l'utente appena registrato — MAI dal body. org_id e
// client_id eventualmente presenti nel body sono ignorati (anti-spoofing H1).
// I destinatari sono gli owner/admin attivi di QUELLA org (org_members) con una
// push_subscription.

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY  = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:palestra@palestria-demo.app", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

// Client con SERVICE ROLE: bypassa RLS per leggere membership/subscriptions cross-user.
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }
    try {
        // ── 0) Autenticazione: ricava l'utente dal Bearer JWT ──────────────────
        const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
        if (!token) {
            return new Response(JSON.stringify({ ok: false, error: "Non autenticato" }), {
                status: 401,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }
        const { data: userData, error: userErr } = await supabase.auth.getUser(token);
        if (userErr || !userData?.user) {
            return new Response(JSON.stringify({ ok: false, error: "Token non valido" }), {
                status: 401,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }
        const callerId = userData.user.id;

        // Solo `name` è usato dal body; org_id/client_id eventuali sono IGNORATI.
        const { name } = await req.json();

        if (!name) {
            return new Response(JSON.stringify({ ok: false, error: "name è obbligatorio" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // ── 1) Org del nuovo cliente = org del PROFILO del chiamante ───────────
        // Anti-spoofing: il `name` del body è forgiabile (finisce nelle push e in
        // admin_messages mostrate agli admin). Preferisci SEMPRE il nome server-side
        // dal profilo del chiamante (l'utente appena registrato); il body è solo fallback.
        const { data: prof, error: profErr } = await supabase
            .from("profiles")
            .select("org_id, name")
            .eq("id", callerId)
            .maybeSingle();
        if (profErr) throw profErr;
        const orgId: string | null = prof?.org_id ?? null;
        const displayName = (prof?.name && String(prof.name).trim()) ? prof.name : name;

        if (!orgId) {
            // Senza org non sappiamo a quali admin notificare: usciamo senza errore.
            console.warn(`[notify-admin-new-client] org non risolta per il chiamante ${callerId} — notifica saltata`);
            return new Response(JSON.stringify({ ok: true, sent: 0, skipped: "org_not_resolved" }), {
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // ── 2) Admin/owner attivi della org ────────────────────────────────────
        const { data: members, error: membersErr } = await supabase
            .from("org_members")
            .select("user_id")
            .eq("org_id", orgId)
            .in("role", ["owner", "admin"])
            .eq("status", "active");

        if (membersErr) throw membersErr;

        const adminIds = (members ?? []).map((m) => m.user_id);
        if (adminIds.length === 0) {
            console.warn(`[notify-admin-new-client] nessun admin attivo per org ${orgId}`);
            return new Response(JSON.stringify({ ok: true, sent: 0, skipped: "no_admins" }), {
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        const payload = JSON.stringify({
            title: "🆕 New entry!",
            body:  `${displayName} iscritto`,
            tag:   `admin-new-client-${displayName}`.replace(/\s/g, "-"),
            url:   `/admin.html`,
        });

        // ── 3) Push subscriptions di QUEGLI admin, nella stessa org ────────────
        const { data: subs, error: subsErr } = await supabase
            .from("push_subscriptions")
            .select("endpoint, p256dh, auth, user_id")
            .eq("org_id", orgId)
            .in("user_id", adminIds);

        if (subsErr) throw subsErr;

        let sent = 0, failed = 0;
        for (const sub of subs ?? []) {
            const _tail = sub.endpoint.slice(-30);
            try {
                // web-push NON lancia sempre su endpoint scaduto: può risolvere con uno
                // statusCode non-2xx (es. 410/404). Validiamo l'esito HTTP esplicitamente,
                // così `sent` conta solo le consegne riuscite e gli endpoint morti vengono
                // rimossi sia da eccezione sia da status code.
                const result: any = await webpush.sendNotification(
                    { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
                    payload,
                );
                const statusCode = result?.statusCode ?? 201;
                if (statusCode >= 200 && statusCode < 300) {
                    sent++;
                    console.log(`[Push] OK ${_tail} (${statusCode})`);
                } else {
                    failed++;
                    console.warn(`[Push] Errore HTTP ${statusCode} ${_tail}`);
                    if (statusCode === 410 || statusCode === 404) {
                        await supabase.from("push_subscriptions").delete().eq("endpoint", sub.endpoint);
                        console.log(`[Push] Cancellata subscription morta: ${_tail}`);
                    }
                }
            } catch (e: any) {
                failed++;
                console.error(`[Push] Errore ${_tail}:`, e.message);
                if (e.statusCode === 410 || e.statusCode === 404) {
                    await supabase.from("push_subscriptions").delete().eq("endpoint", sub.endpoint);
                    console.log(`[Push] Cancellata subscription morta: ${_tail}`);
                }
            }
        }

        // ── 4) Registro messaggi admin (scoping per org) ───────────────────────
        await supabase.from("admin_messages").insert({
            org_id: orgId,
            kind:  "new_client",
            title: "🆕 New entry!",
            body:  `${displayName} iscritto`,
        });

        console.log(`[notify-admin-new-client] org ${orgId} — ${sent} inviate, ${failed} fallite per ${displayName}`);
        return new Response(JSON.stringify({ ok: true, sent, failed }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    } catch (e: any) {
        console.error("[notify-admin-new-client] Errore:", e);
        return new Response(JSON.stringify({ ok: false, error: e.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    }
});
