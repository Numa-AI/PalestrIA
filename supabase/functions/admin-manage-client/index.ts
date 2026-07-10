import { createClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const service = createClient(url, serviceKey);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});

const optionalText = (value: unknown, max: number) => {
  const result = String(value ?? "").trim();
  if (result.length > max) throw new Error("field_too_long");
  return result || null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  try {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    const { data: auth, error: authError } = await service.auth.getUser(token);
    if (authError || !auth.user) return json({ ok: false, error: "unauthorized" }, 401);
    const { data: member, error: memberError } = await service
      .from("org_members")
      .select("org_id")
      .eq("user_id", auth.user.id)
      .eq("status", "active")
      .in("role", ["owner", "admin"])
      .maybeSingle();
    if (memberError) throw memberError;
    if (!member?.org_id) return json({ ok: false, error: "forbidden" }, 403);

    const body = await req.json();
    const userId = String(body.user_id || "");
    const name = optionalText(body.name, 120);
    const email = String(body.email || "").trim().toLowerCase();
    if (!userId || !name) return json({ ok: false, error: "missing_client_or_name" }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return json({ ok: false, error: "invalid_email" }, 400);
    }
    const { data: profile, error: profileError } = await service
      .from("profiles")
      .select("id,email")
      .eq("id", userId)
      .eq("org_id", member.org_id)
      .maybeSingle();
    if (profileError) throw profileError;
    if (!profile) return json({ ok: false, error: "client_not_found" }, 404);

    // Use the caller JWT for the tenant-scoped transactional profile mutation.
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { error: detailsError } = await caller.rpc("admin_update_client_details", {
      p_user_id: userId,
      p_name: name,
      p_whatsapp: optionalText(body.whatsapp, 30),
      p_medical_cert_expiry: body.medical_cert_expiry || null,
      p_insurance_expiry: body.insurance_expiry || null,
      p_codice_fiscale: optionalText(body.codice_fiscale, 32),
      p_indirizzo_via: optionalText(body.indirizzo_via, 180),
      p_indirizzo_cap: optionalText(body.indirizzo_cap, 12),
      p_indirizzo_paese: optionalText(body.indirizzo_paese, 100),
      p_documento_firmato: body.documento_firmato === true,
    });
    if (detailsError) throw detailsError;

    if (email !== profile.email.toLowerCase()) {
      const { error: emailError } = await service.auth.admin.updateUserById(userId, {
        email,
        email_confirm: true,
      });
      if (emailError) {
        return json({ ok: false, error: "email_update_failed", details: emailError.message }, 409);
      }
      // Migration 30 syncs the confirmed Auth email to profile and bookings.
    }
    return json({ ok: true });
  } catch (error) {
    console.error("[admin-manage-client]", error);
    return json({ ok: false, error: error instanceof Error ? error.message : "internal_error" }, 500);
  }
});
