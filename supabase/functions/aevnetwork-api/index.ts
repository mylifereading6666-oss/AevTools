// AevNetwork API bridge. Deploy as a Supabase Edge Function named "aevnetwork-api".
// Required platform secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
// Never expose the service-role key to either browser application.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const authClient = createClient(supabaseUrl, anonKey, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});
const adminClient = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "method_not_allowed" });

  try {
    const body = await req.json();
    const action = String(body?.action ?? "");

    // Login is proxied through this API so AevNetwork does not need a direct
    // Supabase database client. The returned access token is a normal Supabase
    // Auth session token and must be kept private by the browser.
    if (action === "login") {
      const email = String(body?.email ?? "").trim();
      const password = String(body?.password ?? "");
      if (!email || !password || email.length > 320 || password.length > 1024) {
        return respond(400, { error: "invalid_credentials" });
      }
      const { data, error } = await authClient.auth.signInWithPassword({ email, password });
      if (error || !data.session || !data.user) return respond(401, { error: "login_failed" });
      return respond(200, {
        session: {
          access_token: data.session.access_token,
          refresh_token: data.session.refresh_token,
          expires_at: data.session.expires_at,
          token_type: data.session.token_type,
          user: { id: data.user.id, email: data.user.email },
        },
      });
    }

    if (action === "refresh") {
      const refreshToken = String(body?.refresh_token ?? "");
      if (!refreshToken) return respond(400, { error: "missing_refresh_token" });
      const { data, error } = await authClient.auth.refreshSession({ refresh_token: refreshToken });
      if (error || !data.session || !data.user) return respond(401, { error: "session_refresh_failed" });
      return respond(200, {
        session: {
          access_token: data.session.access_token,
          refresh_token: data.session.refresh_token,
          expires_at: data.session.expires_at,
          token_type: data.session.token_type,
          user: { id: data.user.id, email: data.user.email },
        },
      });
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
    if (!token) return respond(401, { error: "missing_session" });

    const { data: authData, error: authError } = await authClient.auth.getUser(token);
    if (authError || !authData.user) return respond(401, { error: "invalid_session" });
    const userId = authData.user.id;

    if (action === "get_data") {
      const { data, error } = await adminClient
        .from("aevnetwork_user_data")
        .select("data, updated_at")
        .eq("user_id", userId)
        .maybeSingle();
      if (error) return respond(500, { error: "data_read_failed" });
      return respond(200, { data: data?.data ?? {}, updated_at: data?.updated_at ?? null });
    }

    if (action === "save_data") {
      const incoming = body?.data;
      if (!incoming || typeof incoming !== "object" || Array.isArray(incoming)) {
        return respond(400, { error: "invalid_data" });
      }
      const encoded = JSON.stringify(incoming);
      if (encoded.length > 200_000) return respond(413, { error: "data_too_large" });

      const { error } = await adminClient
        .from("aevnetwork_user_data")
        .upsert({
          user_id: userId,
          data: incoming,
          updated_at: new Date().toISOString(),
        }, { onConflict: "user_id" });
      if (error) return respond(500, { error: "data_save_failed" });
      return respond(200, { saved: true, updated_at: new Date().toISOString() });
    }

    return respond(400, { error: "unknown_action" });
  } catch (_error) {
    return respond(400, { error: "invalid_request" });
  }
});
