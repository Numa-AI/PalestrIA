// Edge Function: notify-slot-available
// Chiamata dal client quando una prenotazione viene annullata.
// Manda una push notification a tutti gli utenti tranne chi ha annullato.

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
        const { date_display, time, exclude_user_id, date, spots_available, max_capacity } = await req.json();

        if (!date_display || !time) {
            return new Response(JSON.stringify({ ok: false, error: "date_display e time sono obbligatori" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // Recupera user_id di chi è già prenotato in questo slot (da non notificare)
        const { data: slotBookings } = await supabase
            .from("bookings")
            .select("user_id")
            .eq("date", date)
            .eq("time", time)
            .in("status", ["confirmed", "cancellation_requested"])
            .not("user_id", "is", null);

        const excludeIds = [...new Set(
            [exclude_user_id, ...(slotBookings?.map((b: any) => b.user_id) ?? [])]
            .filter(Boolean)
        )];

        // Tutte le subscription push tranne chi ha annullato e chi è già prenotato
        let query = supabase.from("push_subscriptions").select("endpoint, p256dh, auth, user_id");
        if (excludeIds.length > 0) {
            query = query.not("user_id", "in", `(${excludeIds.join(",")})`);
        }
        const { data: subs, error } = await query;
        if (error) throw error;

        const startTime = time.split(" - ")[0]?.trim() ?? time;
        const giorni = ["domenica","lunedì","martedì","mercoledì","giovedì","venerdì","sabato"];
        let dayName = "";
        if (date) {
            const dt = new Date(date + "T00:00:00");
            dayName = giorni[dt.getDay()];
        }
        const spotsInfo = spots_available && max_capacity ? ` (${spots_available}/${max_capacity})` : "";
        const bodyText = dayName
            ? `${dayName} ${date_display} alle ${startTime}${spotsInfo}`
            : `${date_display} alle ${startTime}${spotsInfo}`;
        const payload = JSON.stringify({
            title: "Slot libero disponibile",
            body:  bodyText,
            tag:   `slot-available-${date_display}-${startTime}`.replace(/\s/g, "-"),
            url:   date ? `/index.html?date=${date}` : "/index.html",
        });

        // Recupera nomi utenti per il log
        const subUserIds = [...new Set((subs ?? []).map((s: any) => s.user_id).filter(Boolean))];
        let nameMap: Record<string, { name: string; email: string }> = {};
        if (subUserIds.length > 0) {
            const { data: profiles } = await supabase.from("profiles").select("id, name, email").in("id", subUserIds);
            for (const p of profiles ?? []) {
                nameMap[p.id] = { name: p.name || "", email: p.email || "" };
            }
        }

        let sent = 0;
        const sentUserIds = new Set<string>();
        const failedUsers: { id: string; error: string }[] = [];
        for (const sub of subs ?? []) {
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
                if (sub.user_id && !sentUserIds.has(sub.user_id)) {
                    failedUsers.push({ id: sub.user_id, error: e.message });
                }
            }
        }

        // Log notifiche client
        const notifRows = [
            ...[...sentUserIds].map(uid => ({
                user_id: uid, user_name: nameMap[uid]?.name || "", user_email: nameMap[uid]?.email || "",
                type: "slot_available", title: "Slot libero disponibile", body: bodyText,
                status: "sent", booking_date: date || null, booking_time: time || null,
            })),
            ...failedUsers.filter(f => !sentUserIds.has(f.id)).map(f => ({
                user_id: f.id, user_name: nameMap[f.id]?.name || "", user_email: nameMap[f.id]?.email || "",
                type: "slot_available", title: "Slot libero disponibile", body: bodyText,
                status: "failed", error: f.error, booking_date: date || null, booking_time: time || null,
            })),
        ];
        if (notifRows.length > 0) {
            await supabase.from("client_notifications").insert(notifRows);
        }

        console.log(`[notify-slot-available] ${sent} notifiche inviate per ${date_display} ${startTime}`);
        return new Response(JSON.stringify({ ok: true, sent }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    } catch (e: any) {
        console.error("[notify-slot-available] Errore:", e);
        return new Response(JSON.stringify({ ok: false, error: e.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    }
});
