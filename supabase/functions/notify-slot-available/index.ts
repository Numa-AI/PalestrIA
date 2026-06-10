// Edge Function: notify-slot-available
// Chiamata dal client quando una prenotazione viene annullata: notifica gli altri
// utenti DELLA STESSA ORG che lo slot è tornato disponibile.
//
// SICUREZZA (multi-tenant): l'org si deriva dal chiamante autenticato (profiles.org_id
// o org_members), MAI dal payload. Tutte le query (bookings, push_subscriptions,
// profiles, client_notifications) filtrano org_id → nessun broadcast cross-tenant.

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY  = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:palestra@palestria-demo.app", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

// Service role: bypassa RLS. Per questo OGNI query qui sotto filtra esplicitamente org_id.
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

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: corsHeaders });
    }
    try {
        // 1) Autenticazione del chiamante.
        const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
        if (!token) return jsonResponse({ ok: false, error: "Non autenticato" }, 401);
        const { data: userData, error: userErr } = await supabase.auth.getUser(token);
        if (userErr || !userData?.user) return jsonResponse({ ok: false, error: "Token non valido" }, 401);
        const callerId = userData.user.id;

        // 2) Org del chiamante: prima profiles (clienti), poi org_members (staff/admin).
        let orgId: string | null = null;
        const { data: prof } = await supabase.from("profiles").select("org_id").eq("id", callerId).maybeSingle();
        orgId = prof?.org_id ?? null;
        if (!orgId) {
            const { data: mem } = await supabase.from("org_members")
                .select("org_id").eq("user_id", callerId).eq("status", "active").maybeSingle();
            orgId = mem?.org_id ?? null;
        }
        if (!orgId) return jsonResponse({ ok: false, error: "Org del chiamante non risolvibile" }, 403);

        const { date_display, time, exclude_user_id, date, spots_available, max_capacity } = await req.json();

        if (!date_display || !time) {
            return jsonResponse({ ok: false, error: "date_display e time sono obbligatori" }, 400);
        }

        // Utenti già prenotati in questo slot (da non notificare) — scoping per org.
        const { data: slotBookings } = await supabase
            .from("bookings")
            .select("user_id")
            .eq("org_id", orgId)
            .eq("date", date)
            .eq("time", time)
            .in("status", ["confirmed", "cancellation_requested"])
            .not("user_id", "is", null);

        // Solo UUID validi (no filter-injection da exclude_user_id del body).
        const excludeIds = [...new Set(
            [exclude_user_id, ...(slotBookings?.map((b: any) => b.user_id) ?? [])]
            .filter((id: any) => typeof id === "string" && UUID_RE.test(id))
        )];

        // Subscription push della SOLA org, escludendo chi è già prenotato/ha annullato.
        let query = supabase.from("push_subscriptions")
            .select("endpoint, p256dh, auth, user_id")
            .eq("org_id", orgId);
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

        let sent = 0;
        const sentUserIds = new Set<string>();
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
                    await supabase.from("push_subscriptions").delete()
                        .eq("endpoint", sub.endpoint).eq("org_id", orgId);
                }
            }
        }

        // Log notifiche client (schema reale: org_id, user_id, title, body).
        const notifRows = [...sentUserIds].map(uid => ({
            org_id: orgId, user_id: uid, title: "Slot libero disponibile", body: bodyText,
        }));
        if (notifRows.length > 0) {
            const { error: notifErr } = await supabase.from("client_notifications").insert(notifRows);
            if (notifErr) console.error("[notify-slot-available] log notifiche fallito:", notifErr.message);
        }

        console.log(`[notify-slot-available] org=${orgId} ${sent} notifiche inviate per ${date_display} ${startTime}`);
        return jsonResponse({ ok: true, sent });
    } catch (e: any) {
        console.error("[notify-slot-available] Errore:", e);
        return jsonResponse({ ok: false, error: e.message }, 500);
    }
});
