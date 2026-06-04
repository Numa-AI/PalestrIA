// Edge Function: send-admin-message
// Invio notifiche push dall'admin a tutti, per giorno o per giorno+ora.

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY  = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:palestra@palestria-demo.app", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

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
        const { title, body, mode, date, time } = await req.json();

        if (!title || !body) {
            return new Response(JSON.stringify({ ok: false, error: "title e body sono obbligatori" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        if ((mode === "giorno" || mode === "ora") && !date) {
            return new Response(JSON.stringify({ ok: false, error: "date obbligatoria per modalità giorno/ora" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        let subs: any[] = [];

        if (mode === "tutti") {
            const { data, error } = await supabase
                .from("push_subscriptions")
                .select("endpoint, p256dh, auth, user_id");
            if (error) throw error;
            subs = data ?? [];
        } else {
            let query = supabase
                .from("bookings")
                .select("user_id")
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
                return new Response(JSON.stringify({ ok: true, sent: 0, recipients: [] }), {
                    headers: { ...corsHeaders, "Content-Type": "application/json" },
                });
            }

            const { data, error } = await supabase
                .from("push_subscriptions")
                .select("endpoint, p256dh, auth, user_id")
                .in("user_id", userIds);
            if (error) throw error;
            subs = data ?? [];
        }

        // Recupera nomi dai profili
        const userIds = [...new Set(subs.map((s: any) => s.user_id).filter(Boolean))];
        let nameMap: Record<string, string> = {};
        if (userIds.length > 0) {
            const { data: profiles } = await supabase
                .from("profiles")
                .select("id, name")
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
                    await supabase.from("push_subscriptions").delete().eq("endpoint", sub.endpoint);
                }
                if (sub.user_id) failedUserIds.add(sub.user_id);
            }
        }

        // Nomi di chi ha ricevuto con successo
        const recipients = [...sentUserIds].map(id => nameMap[id] || "Sconosciuto");
        // Nomi di chi ha fallito (e non ha ricevuto su nessun device)
        const failed = [...failedUserIds].filter(id => !sentUserIds.has(id)).map(id => nameMap[id] || "Sconosciuto");

        // Log notifiche client
        const notifRows = [
            ...[...sentUserIds].map(uid => ({
                user_id: uid, user_name: nameMap[uid] || "", user_email: "",
                type: "broadcast", title, body,
                status: "sent", booking_date: date || null, booking_time: time || null,
            })),
            ...[...failedUserIds].filter(id => !sentUserIds.has(id)).map(uid => ({
                user_id: uid, user_name: nameMap[uid] || "", user_email: "",
                type: "broadcast", title, body,
                status: "failed", booking_date: date || null, booking_time: time || null,
            })),
        ];
        if (notifRows.length > 0) {
            await supabase.from("client_notifications").insert(notifRows);
        }

        console.log(`[send-admin-message] ${sent}/${subs.length} notifiche inviate (mode=${mode})`);
        return new Response(JSON.stringify({ ok: true, sent, recipients, failed }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    } catch (e: any) {
        console.error("[send-admin-message] Errore:", e);
        return new Response(JSON.stringify({ ok: false, error: e.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    }
});
