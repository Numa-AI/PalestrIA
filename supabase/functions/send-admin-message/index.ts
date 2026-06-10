// Edge Function: send-admin-message
// Invio notifiche push dall'admin a tutti, per giorno o per giorno+ora.
//
// SICUREZZA (multi-tenant): il chiamante DEVE essere owner/admin di una org
// (verificato dal Bearer JWT → org_members). TUTTE le query sono scoping per
// org_id del chiamante: una org non può mai colpire le subscription/prenotazioni
// di un altro tenant. (Vedi invariante "data-leak #1" in CLAUDE.md §3.)

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY  = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:palestra@palestria-demo.app", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

// Service role: bypassa RLS. Proprio per questo OGNI query qui sotto filtra org_id.
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(payload: unknown, status = 200) {
    return new Response(JSON.stringify(payload), {
        status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }
    try {
        // 1) Autenticazione: ricava l'utente dal Bearer JWT.
        const authHeader = req.headers.get("Authorization") ?? "";
        const token = authHeader.replace(/^Bearer\s+/i, "").trim();
        if (!token) return jsonResponse({ ok: false, error: "Non autenticato" }, 401);

        const { data: userData, error: userErr } = await supabase.auth.getUser(token);
        if (userErr || !userData?.user) return jsonResponse({ ok: false, error: "Token non valido" }, 401);
        const callerId = userData.user.id;

        // 2) Autorizzazione: il chiamante deve essere owner/admin di una org.
        //    org_id deriva dalla membership, MAI dal body della richiesta.
        const { data: membership, error: memberErr } = await supabase
            .from("org_members")
            .select("org_id, role")
            .eq("user_id", callerId)
            .in("role", ["owner", "admin"])
            .eq("status", "active")
            .maybeSingle();
        if (memberErr) throw memberErr;
        if (!membership?.org_id) return jsonResponse({ ok: false, error: "Permessi insufficienti" }, 403);
        const orgId = membership.org_id;

        const { title, body, mode, date, time } = await req.json();

        if (!title || !body) {
            return jsonResponse({ ok: false, error: "title e body sono obbligatori" }, 400);
        }

        if ((mode === "giorno" || mode === "ora") && !date) {
            return jsonResponse({ ok: false, error: "date obbligatoria per modalità giorno/ora" }, 400);
        }

        let subs: any[] = [];

        if (mode === "tutti") {
            const { data, error } = await supabase
                .from("push_subscriptions")
                .select("endpoint, p256dh, auth, user_id")
                .eq("org_id", orgId);
            if (error) throw error;
            subs = data ?? [];
        } else {
            let query = supabase
                .from("bookings")
                .select("user_id")
                .eq("org_id", orgId)
                .eq("date", date)
                .in("status", ["confirmed", "cancellation_requested"])
                .not("user_id", "is", null);

            if (mode === "ora" && time) {
                query = query.eq("time", time);
            }

            const { data: bookings, error: bErr } = await query;
            if (bErr) throw bErr;

            const userIds = [...new Set((bookings ?? []).map((b: any) => b.user_id).filter(Boolean))];

            if (userIds.length === 0) {
                return jsonResponse({ ok: true, sent: 0, recipients: [] });
            }

            const { data, error } = await supabase
                .from("push_subscriptions")
                .select("endpoint, p256dh, auth, user_id")
                .eq("org_id", orgId)
                .in("user_id", userIds);
            if (error) throw error;
            subs = data ?? [];
        }

        // Recupera nomi dai profili (sempre scoping per org).
        const userIds = [...new Set(subs.map((s: any) => s.user_id).filter(Boolean))];
        let nameMap: Record<string, string> = {};
        if (userIds.length > 0) {
            const { data: profiles } = await supabase
                .from("profiles")
                .select("id, name")
                .eq("org_id", orgId)
                .in("id", userIds);
            for (const p of profiles ?? []) {
                nameMap[p.id] = p.name || "Senza nome";
            }
        }

        const payload = JSON.stringify({
            title,
            body,
            tag: `admin-msg-${Date.now()}`,
            url: "/index.html",
        });

        let sent = 0;
        const sentUserIds = new Set<string>();
        const failedUserIds = new Set<string>();
        for (const sub of subs) {
            try {
                await webpush.sendNotification(
                    { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
                    payload,
                );
                sent++;
                if (sub.user_id) sentUserIds.add(sub.user_id);
            } catch (e: any) {
                console.error(`[Push] Errore ${sub.endpoint.slice(-30)}:`, e.message);
                if (e.statusCode === 410 || e.statusCode === 404) {
                    await supabase.from("push_subscriptions").delete()
                        .eq("endpoint", sub.endpoint).eq("org_id", orgId);
                }
                if (sub.user_id) failedUserIds.add(sub.user_id);
            }
        }

        // Nomi di chi ha ricevuto con successo
        const recipients = [...sentUserIds].map(id => nameMap[id] || "Sconosciuto");
        // Nomi di chi ha fallito (e non ha ricevuto su nessun device)
        const failed = [...failedUserIds].filter(id => !sentUserIds.has(id)).map(id => nameMap[id] || "Sconosciuto");

        // Log notifiche client (schema reale: org_id, user_id, title, body).
        const notifRows = [...sentUserIds].map(uid => ({
            org_id: orgId, user_id: uid, title, body,
        }));
        if (notifRows.length > 0) {
            const { error: notifErr } = await supabase.from("client_notifications").insert(notifRows);
            if (notifErr) console.error("[send-admin-message] log notifiche fallito:", notifErr.message);
        }

        console.log(`[send-admin-message] org=${orgId} ${sent}/${subs.length} notifiche inviate (mode=${mode})`);
        return jsonResponse({ ok: true, sent, recipients, failed });
    } catch (e: any) {
        console.error("[send-admin-message] Errore:", e);
        return jsonResponse({ ok: false, error: e.message }, 500);
    }
});
