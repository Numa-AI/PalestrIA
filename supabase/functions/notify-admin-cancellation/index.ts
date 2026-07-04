// Edge Function: notify-admin-cancellation
// Chiamata dal client dopo un annullamento.
// Manda una push notification AGLI ADMIN DELLA ORG della prenotazione cancellata
// (owner/admin attivi), con nome cliente e occupazione slot aggiornata.
//
// SICUREZZA (anti-spoofing H1): la org NON viene MAI dal body. Risoluzione:
//   1) bookings.org_id (server-authoritative) via booking_id;
//   2) se booking_id manca ma c'è un Bearer utente valido (getUser), si deriva
//      dal caller: profiles.org_id e poi org_members.

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
        // Caller opzionale: se c'è un Bearer utente valido lo usiamo come fallback
        // per derivare la org (mai dal body). booking_id resta la fonte preferita.
        const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
        let callerId: string | null = null;
        if (token) {
            const { data: userData } = await supabase.auth.getUser(token);
            callerId = userData?.user?.id ?? null;
        }

        // Dal body usiamo SOLO i dati di presentazione + booking_id. org_id ignorato.
        const {
            booking_id,
            name, date_display, time, date, slot_type, max_capacity,
        } = await req.json();

        if (!name || !date_display || !time) {
            return new Response(JSON.stringify({ ok: false, error: "name, date_display e time sono obbligatori" }), {
                status: 400,
                headers: { ...corsHeaders, "Content-Type": "application/json" },
            });
        }

        // ── Risoluzione della org dell'evento (mai dal body) ─────────────────
        // 1) dalla prenotazione cancellata (bookings.org_id, server-authoritative);
        // 2) fallback dal chiamante: profiles → org_members.
        let orgId: string | null = null;
        // Anti-spoofing: il `name` del body è forgiabile; preferisci il nome scritto da
        // book_slot sulla riga bookings (server-authoritative). Body come fallback.
        let bookingName: string | null = null;

        if (booking_id) {
            const { data: bk, error: bkErr } = await supabase
                .from("bookings")
                .select("org_id, name")
                .eq("id", booking_id)
                .maybeSingle();
            if (bkErr) throw bkErr;
            orgId = bk?.org_id ?? null;
            bookingName = bk?.name ?? null;
        }

        if (!orgId && callerId) {
            const { data: prof } = await supabase
                .from("profiles")
                .select("org_id")
                .eq("id", callerId)
                .maybeSingle();
            orgId = prof?.org_id ?? null;
            if (!orgId) {
                const { data: mem } = await supabase
                    .from("org_members")
                    .select("org_id")
                    .eq("user_id", callerId)
                    .eq("status", "active")
                    .maybeSingle();
                orgId = mem?.org_id ?? null;
            }
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

        const displayName = (bookingName && bookingName.trim()) ? bookingName : name;
        const title = "❌ " + displayName;
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

        let sent = 0, failed = 0;
        if (adminIds.length > 0) {
            // Push subscriptions degli admin di QUESTA org
            const { data: subs, error: subsErr } = await supabase
                .from("push_subscriptions")
                .select("endpoint, p256dh, auth, user_id")
                .eq("org_id", orgId)
                .in("user_id", adminIds);

            if (subsErr) throw subsErr;

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

        console.log(`[notify-admin-cancellation] org ${orgId}: ${sent} inviate, ${failed} fallite per ${title} — ${date_display} ${startTime}`);
        return new Response(JSON.stringify({ ok: true, sent, failed }), {
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
