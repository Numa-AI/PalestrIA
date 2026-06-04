// Edge Function: notify-admin-booking
// Chiamata dal client dopo una prenotazione confermata.
// Manda una push notification AGLI ADMIN DELLA ORG della prenotazione
// (niente più ADMIN_IDS hardcoded: multi-tenant).
//
// Risoluzione org (in ordine):
//   1) org_id presente nel payload
//   2) bookings.org_id (se arriva booking_id)
//   3) profiles.org_id (se arriva user_id del cliente)
// Dalla org si ricavano gli admin via org_members (role owner/admin, status active)
// e da lì le loro push_subscriptions (scoping per org_id + user_id).

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY  = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:palestra@palestria-demo.app", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

// Service role: bypassa RLS per leggere membership/subscriptions cross-tenant in sicurezza.
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Ricava la org_id partendo dal payload o dai record collegati (service role).
async function resolveOrgId(input: {
    org_id?: string;
    booking_id?: string;
    user_id?: string;
}): Promise<string | null> {
    // 1) org_id esplicito nel payload
    if (input.org_id) return input.org_id;

    // 2) dalla prenotazione (bookings.org_id)
    if (input.booking_id) {
        const { data, error } = await supabase
            .from("bookings")
            .select("org_id")
            .eq("id", input.booking_id)
            .maybeSingle();
        if (error) throw error;
        if (data?.org_id) return data.org_id;
    }

    // 3) dal profilo del cliente (profiles.org_id)
    if (input.user_id) {
        const { data, error } = await supabase
            .from("profiles")
            .select("org_id")
            .eq("id", input.user_id)
            .maybeSingle();
        if (error) throw error;
        if (data?.org_id) return data.org_id;
    }

    return null;
}

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }
    try {
        // Firma/payload in ingresso invariata; aggiunti org_id/booking_id/user_id (opzionali) per la risoluzione org.
        const {
            name, date_display, time, date, slot_type, max_capacity,
            org_id: payloadOrgId, booking_id, user_id,
        } = await req.json();

        if (!name || !date_display || !time) {
            return new Response(JSON.stringify({ ok: false, error: "name, date_display e time sono obbligatori" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // Risolvi la org della prenotazione: i push andranno SOLO agli admin di questa org.
        const orgId = await resolveOrgId({ org_id: payloadOrgId, booking_id, user_id });
        if (!orgId) {
            return new Response(JSON.stringify({ ok: false, error: "Impossibile determinare la org della prenotazione" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // Conta prenotazioni attive per questo slot (scoping per org), dopo l'inserimento.
        const { count, error: countErr } = await supabase
            .from("bookings")
            .select("id", { count: "exact", head: true })
            .eq("org_id", orgId)
            .eq("date", date)
            .eq("time", time)
            .eq("slot_type", slot_type)
            .in("status", ["confirmed", "cancellation_requested"]);

        if (countErr) throw countErr;

        const occupancy = count ?? 0;
        const capacity = max_capacity ?? occupancy;
        const startTime = time.split(" - ")[0]?.trim() ?? time;

        const title = "✔️ " + name;
        const body  = `${date_display} alle ${startTime} (${occupancy}/${capacity})`;

        const payload = JSON.stringify({
            title,
            body,
            tag:   `admin-booking-${date}-${startTime}-${occupancy}`.replace(/\s/g, "-"),
            url:   `/admin.html?date=${date}`,
        });

        // 1) Admin della org: org_members con role owner/admin e status active.
        const { data: members, error: membersErr } = await supabase
            .from("org_members")
            .select("user_id")
            .eq("org_id", orgId)
            .in("role", ["owner", "admin"])
            .eq("status", "active");

        if (membersErr) throw membersErr;

        const adminIds = (members ?? []).map((m) => m.user_id);

        let sent = 0;
        if (adminIds.length > 0) {
            // 2) Push subscriptions di quegli admin, sempre scoping per org_id.
            const { data: subs, error: subsErr } = await supabase
                .from("push_subscriptions")
                .select("endpoint, p256dh, auth, user_id")
                .eq("org_id", orgId)
                .in("user_id", adminIds);

            if (subsErr) throw subsErr;

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
        }

        // Salva nel registro messaggi (scoping per org).
        await supabase.from("admin_messages").insert({
            org_id: orgId,
            kind: "booking",
            title,
            body,
        });

        console.log(`[notify-admin-booking] org=${orgId} ${sent} notifiche inviate per ${name} — ${date_display} ${startTime}`);
        return new Response(JSON.stringify({ ok: true, sent }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    } catch (e: any) {
        console.error("[notify-admin-booking] Errore:", e);
        return new Response(JSON.stringify({ ok: false, error: e.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    }
});
