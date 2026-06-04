// Edge Function: send-reminders
// Inviata da cron ogni 5 minuti.
// Invia due tipi di promemoria: 24h prima e 60 min prima della lezione.

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY  = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:palestra@palestria-demo.app", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// Estrae i minuti dall'inizio del giorno dall'orario "HH:MM - HH:MM"
function parseStartMin(timeStr: string): number | null {
    const m = timeStr.match(/^(\d{1,2}):(\d{2})/);
    return m ? parseInt(m[1]) * 60 + parseInt(m[2]) : null;
}

// Calcola data e ora in fuso Europe/Rome a partire da un offset in ms
function targetItaly(offsetMs: number): { date: string; totalMin: number } {
    const target = new Date(Date.now() + offsetMs);
    const fmt = new Intl.DateTimeFormat("en-CA", {
        timeZone: "Europe/Rome",
        year: "numeric", month: "2-digit", day: "2-digit",
        hour: "2-digit", minute: "2-digit", hour12: false,
    });
    const parts = fmt.formatToParts(target);
    const pv = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
    return {
        date:     `${pv("year")}-${pv("month")}-${pv("day")}`,
        totalMin: parseInt(pv("hour")) * 60 + parseInt(pv("minute")),
    };
}

async function sendPush(userId: string, payload: string, notifMeta?: { type: string; title: string; body: string; date?: string; time?: string }) {
    const { data: subs } = await supabase
        .from("push_subscriptions")
        .select("endpoint, p256dh, auth")
        .eq("user_id", userId);

    // Recupera nome utente per il log
    let userName = "";
    let userEmail = "";
    if (notifMeta) {
        const { data: profile } = await supabase.from("profiles").select("name, email").eq("id", userId).single();
        userName = profile?.name || "";
        userEmail = profile?.email || "";
    }

    if (!subs?.length) {
        // Nessuna subscription — log come non raggiungibile
        if (notifMeta) {
            await supabase.from("client_notifications").insert({
                user_id: userId, user_name: userName, user_email: userEmail,
                type: notifMeta.type, title: notifMeta.title, body: notifMeta.body,
                status: "no_subscription", booking_date: notifMeta.date || null, booking_time: notifMeta.time || null,
            });
        }
        return 0;
    }

    let sent = 0;
    let lastError = "";
    for (const sub of subs) {
        try {
            await webpush.sendNotification(
                { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
                payload,
            );
            sent++;
        } catch (e: any) {
            lastError = e.message;
            console.error(`[Push] Errore ${sub.endpoint.slice(-30)}:`, e.message);
            if (e.statusCode === 410 || e.statusCode === 404) {
                await supabase.from("push_subscriptions").delete().eq("endpoint", sub.endpoint);
            }
        }
    }

    // Log notifica client
    if (notifMeta) {
        await supabase.from("client_notifications").insert({
            user_id: userId, user_name: userName, user_email: userEmail,
            type: notifMeta.type, title: notifMeta.title, body: notifMeta.body,
            status: sent > 0 ? "sent" : "failed",
            error: sent === 0 ? lastError : null,
            booking_date: notifMeta.date || null, booking_time: notifMeta.time || null,
        });
    }

    return sent;
}

Deno.serve(async (_req) => {
    try {
        const WINDOW = 12; // ±12 min
        let totalSent = 0;

        // ── Promemoria 25h ────────────────────────────────────────────────────
        const { date: date24h, totalMin: min24h } = targetItaly(25 * 60 * 60 * 1000);
        const { data: bookings24h, error: err24h } = await supabase
            .from("bookings")
            .select("id, user_id, time")
            .eq("reminder_24h_sent", false)
            .in("status", ["confirmed", "cancellation_requested"])
            .eq("date", date24h);

        if (err24h) throw err24h;

        for (const b of bookings24h ?? []) {
            if (!b.user_id) continue;
            const start = parseStartMin(b.time);
            if (start === null || Math.abs(start - min24h) > WINDOW) continue;

            // Marca PRIMA di inviare per evitare invii doppi da cron concorrenti
            const { data: claimed } = await supabase
                .from("bookings")
                .update({ reminder_24h_sent: true })
                .eq("id", b.id)
                .eq("reminder_24h_sent", false)
                .select("id");
            // Se nessuna riga aggiornata, un'altra invocazione l'ha già presa
            if (!claimed?.length) continue;

            const startTime = b.time.split(" - ")[0]?.trim() ?? b.time;
            const payload = JSON.stringify({
                title: "Promemoria Allenamento",
                body:  `Lezione domani alle ${startTime}`,
                tag:   `reminder-24h-${b.id}`,
                url:   "/prenotazioni.html",
            });

            totalSent += await sendPush(b.user_id, payload, {
                type: "reminder_24h", title: "Promemoria Allenamento",
                body: `Lezione domani alle ${startTime}`, date: date24h, time: b.time,
            });
        }

        // ── Promemoria 1h ─────────────────────────────────────────────────────
        const { date: date1h, totalMin: min1h } = targetItaly(60 * 60 * 1000);
        const { data: bookings1h, error: err1h } = await supabase
            .from("bookings")
            .select("id, user_id, time")
            .eq("reminder_1h_sent", false)
            .in("status", ["confirmed", "cancellation_requested"])
            .eq("date", date1h);

        if (err1h) throw err1h;

        for (const b of bookings1h ?? []) {
            if (!b.user_id) continue;
            const start = parseStartMin(b.time);
            if (start === null || Math.abs(start - min1h) > WINDOW) continue;

            // Marca PRIMA di inviare per evitare invii doppi da cron concorrenti
            const { data: claimed1h } = await supabase
                .from("bookings")
                .update({ reminder_1h_sent: true })
                .eq("id", b.id)
                .eq("reminder_1h_sent", false)
                .select("id");
            if (!claimed1h?.length) continue;

            const startTime = b.time.split(" - ")[0]?.trim() ?? b.time;
            const payload = JSON.stringify({
                title: "Promemoria Allenamento",
                body:  `Lezione fra 60 minuti (${startTime})`,
                tag:   `reminder-1h-${b.id}`,
                url:   "/prenotazioni.html",
            });

            totalSent += await sendPush(b.user_id, payload, {
                type: "reminder_1h", title: "Promemoria Allenamento",
                body: `Lezione fra 60 minuti (${startTime})`, date: date1h, time: b.time,
            });
        }

        console.log(`[send-reminders] ${totalSent} notifiche inviate`);
        return new Response(JSON.stringify({ ok: true, sent: totalSent }), {
            headers: { "Content-Type": "application/json" },
        });
    } catch (e: any) {
        console.error("[send-reminders] Errore:", e);
        return new Response(JSON.stringify({ ok: false, error: e.message }), {
            status: 500,
            headers: { "Content-Type": "application/json" },
        });
    }
});
