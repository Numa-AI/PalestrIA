import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE_URL = Deno.env.get("SITE_URL") || "https://numa-ai.github.io/PalestrIA";
const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});

async function findUserByEmail(email: string) {
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const found = data.users.find((u) => u.email?.toLowerCase() === email);
    if (found) return found;
    if (data.users.length < 1000) break;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    const { data: auth, error: authError } = await supabase.auth.getUser(token);
    if (authError || !auth.user) return json({ ok: false, error: "unauthorized" }, 401);

    const { data: member, error: memberError } = await supabase
      .from("org_members")
      .select("org_id, role")
      .eq("user_id", auth.user.id)
      .eq("status", "active")
      .in("role", ["owner", "admin"])
      .maybeSingle();
    if (memberError) throw memberError;
    if (!member?.org_id) return json({ ok: false, error: "forbidden" }, 403);

    const body = await req.json();
    const email = String(body.email || "").trim().toLowerCase();
    const role = String(body.role || "staff");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return json({ ok: false, error: "invalid_email" }, 400);
    }
    if (!new Set(["admin", "staff"]).has(role)) {
      return json({ ok: false, error: "invalid_role" }, 400);
    }

    let user = await findUserByEmail(email);
    let invited = false;
    if (!user) {
      const { data, error } = await supabase.auth.admin.inviteUserByEmail(email, {
        redirectTo: `${SITE_URL}/login.html?staff_invite=1`,
        data: { signup_type: "staff" },
      });
      if (error) throw error;
      user = data.user;
      invited = true;
    }
    if (!user) throw new Error("invite_user_missing");

    const [{ data: otherMembership }, { data: otherProfile }] = await Promise.all([
      supabase.from("org_members").select("org_id")
        .eq("user_id", user.id).eq("status", "active")
        .neq("org_id", member.org_id).limit(1).maybeSingle(),
      supabase.from("profiles").select("org_id")
        .eq("id", user.id).neq("org_id", member.org_id).limit(1).maybeSingle(),
    ]);
    if (otherMembership || otherProfile) {
      return json({ ok: false, error: "user_in_other_org" }, 409);
    }

    const { error: upsertError } = await supabase.from("org_members").upsert({
      org_id: member.org_id,
      user_id: user.id,
      role,
      status: "active",
      invited_email: email,
    }, { onConflict: "org_id,user_id" });
    if (upsertError) throw upsertError;

    return json({ ok: true, invited, user_id: user.id });
  } catch (error) {
    console.error("[invite-org-member]", error);
    return json({ ok: false, error: error instanceof Error ? error.message : "internal_error" }, 500);
  }
});