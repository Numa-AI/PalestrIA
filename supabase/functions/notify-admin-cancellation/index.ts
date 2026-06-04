// Edge Function: notify-admin-cancellation
// Chiamata dal client dopo un annullamento.
// Manda una push notification AGLI ADMIN DELLA ORG della prenotazione cancellata
// (owner/admin attivi), con nome cliente e occupazione slot aggiornata.
//
// Multi-tenant: niente più ADMIN_IDS hardcoded. La org si ricava dal payload
// (org_id) oppure, se assente, dalla prenotazione collegata via service role.

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY  = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails("mailto:palestra@palestria-demo.app", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

// Client con SERVICE ROLE KEY: bypassa RLS per leggere membership e subscriptions
// di tutta la org (operazione server-side, mai esposta al client).
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
        const {
            org_id: orgIdIn,   // opzionale: se il client lo passa lo usiamo direttamente
            booking_id,        // opzionale: per risolvere la org in modo deterministico
            name, date_display, time, date, slot_type, max_capacity, with_bonus, with_mora,
        } = await req.json();

        if (!name || !date_display || !time) {
            return new Response(JSON.stringify({ ok: false, error: "name, date_display e time sono obbligatori" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // ── Risoluzione della org dell'evento ────────────────────────────────
        // 1) se il payload porta org_id, lo usiamo;
        // 2) altrimenti lo ricaviamo dalla prenotazione cancellata (per id, oppure
        //    cercando un booking che combaci con lo slot via service role).
        let orgId: string | null = orgIdIn ?? null;

        if (!orgId && booking_id) {
            const { data: bk, error: bkErr } = await supabase
                .from("bookings")
                .select("org_id")
                .eq("id", booking_id)
                .maybeSingle();
            if (bkErr) throw bkErr;
            orgId = bk?.org_id ?? null;
        }

        if (!orgId) {
            // Fallback: derivo la org da una prenotazione dello stesso slot.
            // Prendo la più recente che combaci (incluse quelle cancellate).
            const { data: bk, error: bkErr } = await supabase
                .from("bookings")
                .select("org_id")
                .eq("date", date)
                .eq("time", time)
                .eq("slot_type", slot_type)
                .order("created_at", { ascending: false })
                .limit(1)
                .maybeSingle();
            if (bkErr) throw bkErr;
            orgId = bk?.org_id ?? null;
        }

        if (!orgId) {
            return new Response(JSON.stringify({ ok: false, error: "Impossibile determinare la org della prenotazione cancellata" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // Conta prenotazioni attive per questo slot NELLA ORG (dopo la cancellazione)
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

        // Titolo con suffisso bonus/mora
        let title = "❌ " + name;
        if (with_bonus) title += " con bonus";
        else if (with_mora) title += " con mora";

        const body = `${date_display} alle ${startTime} (${occupancy}/${capacity})`;
        const payload = JSON.stringify({
            title,
            body,
            tag:   `admin-cancel-${date}-${startTime}-${occupancy}`.replace(/\s/g, "-"),
            url:   `/admin.html?date=${date}`,
        });

        // ── Destinatari: admin/owner ATTIVI della org ────────────────────────
        const { data: members, error: memErr } = await supabase
            .from("org_members")
            .select("user_id")
            .eq("org_id", orgId)
            .in("role", ["owner", "admin"])
            .eq("status", "active");

        if (memErr) throw memErr;

        const adminIds = (members ?? []).map((m) => m.user_id);

        let sent = 0;
        if (adminIds.length > 0) {
            // Push subscriptions degli admin di QUESTA org
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
        } else {
            console.warn(`[notify-admin-cancellation] Nessun admin attivo per org ${orgId}`);
        }

        // Salva nel registro messaggi (scoped alla org)
        await supabase.from("admin_messages").insert({
            org_id: orgId,
            kind: "cancellation",
            title,
            body,
        });

        console.log(`[notify-admin-cancellation] org ${orgId}: ${sent} notifiche inviate per ${title} — ${date_display} ${startTime}`);
        return new Response(JSON.stringify({ ok: true, sent }), {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    } catch (e: any) {
        console.error("[notify-admin-cancellation] Errore:", e);
        return new Response(JSON.stringify({ ok: false, error: e.message }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
    }
});
