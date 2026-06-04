// Edge Function: custom-access-token-hook
// Auth Hook "Custom Access Token" di Supabase. Viene invocata da GoTrue ad ogni
// emissione di un access token (login / refresh) e riceve un payload del tipo:
//   { "user_id": "<uuid>", "claims": { ... } }
// Il nostro compito è arricchire claims.app_metadata con:
//   - org_id   : la org a cui l'utente appartiene
//   - org_role : il ruolo (owner/admin/staff) se membro dello staff
// così che gli helper SQL current_org_id()/current_org_role() leggano direttamente
// dal JWT senza query aggiuntive.
//
// NB: verify_jwt=false per questa function — è chiamata da GoTrue (non da un client
// autenticato). La query usa la SERVICE ROLE KEY per bypassare la RLS.
//
// Spec hook: https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook
// Deve rispondere con l'INTERO payload (eventualmente con i claims modificati);
// in caso di errore non bloccante si ritorna il payload invariato.

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!SUPABASE_URL) console.error("[custom-access-token-hook] FATAL: SUPABASE_URL not configured");
if (!SUPABASE_KEY) console.error("[custom-access-token-hook] FATAL: SUPABASE_SERVICE_ROLE_KEY not configured");

// Service role: bypassa la RLS per leggere org_members/profiles in fase di login.
const supabase = (SUPABASE_URL && SUPABASE_KEY)
    ? createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { persistSession: false } })
    : null;

const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
    });

Deno.serve(async (req) => {
    // Leggiamo sempre il payload: in caso di errore vogliamo restituirlo invariato.
    let payload: any = {};
    try {
        payload = await req.json();
    } catch (_e) {
        // payload non valido: GoTrue si aspetta comunque un oggetto { claims }
        return json({ claims: {} });
    }

    try {
        const userId: string | undefined = payload?.user_id;
        const claims = payload?.claims ?? {};

        // Senza client o senza user_id non possiamo arricchire: payload invariato.
        if (!supabase || !userId) {
            return json(payload);
        }

        // 1) Staff: cerchiamo una membership attiva in org_members (priorità sul ruolo).
        //    Se l'utente è in più org prendiamo la più vecchia (coerente con current_org_id()).
        let orgId: string | null = null;
        let orgRole: string | null = null;

        const { data: membership, error: memberErr } = await supabase
            .from("org_members")
            .select("org_id, role")
            .eq("user_id", userId)
            .eq("status", "active")
            .order("created_at", { ascending: true })
            .limit(1)
            .maybeSingle();

        if (memberErr) {
            console.error("[custom-access-token-hook] org_members query error:", memberErr.message);
        } else if (membership) {
            orgId = membership.org_id;
            orgRole = membership.role;
        }

        // 2) Cliente finale: se non è staff, risolviamo la org da profiles.org_id.
        if (!orgId) {
            const { data: profile, error: profileErr } = await supabase
                .from("profiles")
                .select("org_id")
                .eq("id", userId)
                .maybeSingle();

            if (profileErr) {
                console.error("[custom-access-token-hook] profiles query error:", profileErr.message);
            } else if (profile) {
                orgId = profile.org_id;
                // i clienti non hanno un ruolo staff → nessun org_role
            }
        }

        // 3) Nessuna org trovata → claims invariati (utente appena registrato / pre-onboarding).
        if (!orgId) {
            return json(payload);
        }

        // 4) Inietta i claim in app_metadata preservando i metadati esistenti.
        const appMetadata = { ...(claims.app_metadata ?? {}) };
        appMetadata.org_id = orgId;
        if (orgRole) {
            appMetadata.org_role = orgRole;
        }

        return json({
            ...payload,
            claims: {
                ...claims,
                app_metadata: appMetadata,
            },
        });
    } catch (e) {
        // Mai bloccare il login: in caso di errore inatteso restituiamo i claims invariati.
        console.error("[custom-access-token-hook] unexpected error:", e);
        return json(payload);
    }
});
