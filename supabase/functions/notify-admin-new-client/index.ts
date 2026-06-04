// Edge Function: notify-admin-new-client
// Chiamata dal client dopo una registrazione confermata.
// Manda una push notification AGLI ADMIN DELLA ORG del nuovo iscritto.
//
// Multi-tenant: niente più ADMIN_IDS hardcoded. La org si ricava dal record
// del nuovo cliente (profiles.org_id) tramite SERVICE ROLE KEY; i destinatari
// sono gli owner/admin attivi di QUELLA org (org_members) con una push_subscription.

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
        // Firma payload invariata (name). Accettiamo opzionalmente org_id / client_id
        // per risolvere la org senza ambiguità; altrimenti la ricaviamo dal profilo.
        const { name, org_id: orgIdInput, client_id } = await req.json();

        if (!name) {
            return new Response(JSON.stringify({ ok: false, error: "name è obbligatorio" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // ── 1) Risoluzione della org del nuovo cliente ─────────────────────────
        // Priorità: org_id esplicito → profiles per client_id → profiles per name.
        let orgId: string | null = orgIdInput ?? null;

        if (!orgId && client_id) {
            const { data: prof, error: profErr } = await supabase
                .from("profiles")
                .select("org_id")
                .eq("id", client_id)
                .maybeSingle();
            if (profErr) throw profErr;
            orgId = prof?.org_id ?? null;
        }

        if (!orgId) {
            // Fallback: cerca il profilo per nome (il più recente, se più di uno).
            const { data: prof, error: profErr } = await supabase
                .from("profiles")
                .select("org_id")
                .eq("name", name)
                .order("created_at", { ascending: false })
                .limit(1)
                .maybeSingle();
            if (profErr) throw profErr;
            orgId = prof?.org_id ?? null;
        }

        if (!orgId) {
            // Senza org non sappiamo a quali admin notificare: usciamo senza errore.
            console.warn(`[notify-admin-new-client] org non risolta per "${name}" — notifica saltata`);
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
            body:  `${name} iscritto`,
            tag:   `admin-new-client-${name}`.replace(/\s/g, "-"),
            url:   `/admin.html`,
        });

        // ── 3) Push subscriptions di QUEGLI admin, nella stessa org ────────────
        const { data: subs, error: subsErr } = await supabase
            .from("push_subscriptions")
            .select("endpoint, p256dh, auth, user_id")
            .eq("org_id", orgId)
            .in("user_id", adminIds);

        if (subsErr) throw subsErr;

        let sent = 0;
        for (const sub of subs ?? []) {
            try {
                await webpush.sendNotification(
                    { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
                    payload,
                );
                sent++;
            } catch (e: any) {
                console.error(`[Push] Errore ${sub.endpoint.slice(-30)}:`, e.message);
                if (e.statusCode === 410 || e.statusCode === 404) {
                    await supabase.from("push_subscriptions").delete().eq("endpoint", sub.endpoint);
                }
            }
        }

        // ── 4) Registro messaggi admin (scoping per org) ───────────────────────
        await supabase.from("admin_messages").insert({
            org_id: orgId,
            kind:  "new_client",
            title: "🆕 New entry!",
            body:  `${name} iscritto`,
        });

        console.log(`[notify-admin-new-client] org ${orgId} — ${sent} notifiche inviate per ${name}`);
        return new Response(JSON.stringify({ ok: true, sent }), {
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
