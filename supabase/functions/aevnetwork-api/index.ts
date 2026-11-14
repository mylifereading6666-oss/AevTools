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

    if (action === "public_list_content") {
      const kind = String(body?.kind ?? "");
      const publicTables: Record<string, string> = {
        announcements: "aevnetwork_announcements",
        news: "aevnetwork_news",
        updates: "aevnetwork_updates"
      };
      const table = publicTables[kind];
      if (!table) return respond(400, { error: "invalid_content_kind" });
      let query = adminClient.from(table).select("*").order("created_at", { ascending: false }).limit(100);
      if (kind !== "announcements") query = query.eq("published", true);
      const { data, error } = await query;
      if (error) return respond(500, { error: "content_load_failed" });
      return respond(200, { items: data ?? [] });
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
    if (!token) return respond(401, { error: "missing_session" });

    const { data: authData, error: authError } = await authClient.auth.getUser(token);
    if (authError || !authData.user) return respond(401, { error: "invalid_session" });
    const userId = authData.user.id;

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const { data: adminFlag, error: adminFlagError } = await userClient.rpc("aevtools_is_admin");
    const isAdmin = !adminFlagError && adminFlag === true;

    if (action === "is_admin") {
      if (adminFlagError) return respond(500, { error: "admin_check_failed" });
      return respond(200, { is_admin: isAdmin });
    }

    // AevNetwork blacklist is scoped to this service only. It never disables
    // the shared Supabase Auth account or access to AevTools.
    const { data: blockedRow, error: blockedError } = await adminClient
      .from("aevnetwork_blacklist").select("reason").eq("user_id", userId).maybeSingle();
    if (blockedError) return respond(500, { error: "blacklist_check_failed" });
    if (blockedRow && !isAdmin) return respond(403, { error: "aevnetwork_restricted", reason: blockedRow.reason });

    if (action === "profile_get") {
      const { data, error } = await userClient.rpc("aevtools_get_my_profile");
      if (error) return respond(500, { error: "profile_load_failed" });
      return respond(200, { profile: data });
    }

    if (action === "profile_save") {
      const nickname = String(body?.nickname ?? "").trim();
      const profile = body?.profile && typeof body.profile === "object" && !Array.isArray(body.profile) ? body.profile : {};
      if (!nickname || nickname.length > 20) return respond(400, { error: "nickname_length_invalid" });
      const { data, error } = await userClient.rpc("aevtools_update_my_profile", {
        p_nickname: nickname,
        p_profile: profile
      });
      if (error) return respond(400, { error: error.message || "profile_save_failed" });
      return respond(200, { profile: data });
    }

    if (action === "admin_dashboard") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      let userCount = 0;
      for (let page = 1; page <= 100; page++) {
        const batch = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
        if (batch.error) return respond(500, { error: "dashboard_load_failed" });
        userCount += batch.data.users.length;
        if (batch.data.users.length < 1000) break;
      }
      const [announcements, news, updates, blacklist] = await Promise.all([
        adminClient.from("aevnetwork_announcements").select("id", { count: "exact", head: true }),
        adminClient.from("aevnetwork_news").select("id", { count: "exact", head: true }),
        adminClient.from("aevnetwork_updates").select("id", { count: "exact", head: true }),
        adminClient.from("aevnetwork_blacklist").select("user_id", { count: "exact", head: true }),
      ]);
      if (announcements.error || news.error || updates.error || blacklist.error)
        return respond(500, { error: "dashboard_load_failed" });
      return respond(200, { metrics: {
        users: userCount, announcements: announcements.count ?? 0, news: news.count ?? 0,
        updates: updates.count ?? 0, blacklist: blacklist.count ?? 0
      }});
    }

    if (action === "admin_list_users") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const page = Math.max(1, Math.min(100, Number(body?.page) || 1));
      const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 100 });
      if (error) return respond(500, { error: "users_load_failed" });
      return respond(200, { users: data.users.map((u: any) => ({
        id: u.id, email: u.email ?? "", created_at: u.created_at ?? null,
        last_sign_in_at: u.last_sign_in_at ?? null
      })), page });
    }

    const contentTables: Record<string, string> = {
      announcements: "aevnetwork_announcements",
      news: "aevnetwork_news",
      updates: "aevnetwork_updates"
    };
    if (action === "admin_list_content" || action === "public_list_content") {
      const kind = String(body?.kind ?? "");
      const table = contentTables[kind];
      if (!table) return respond(400, { error: "invalid_content_kind" });
      if (action === "admin_list_content" && !isAdmin) return respond(403, { error: "admin_required" });
      let query = adminClient.from(table).select("*").order("created_at", { ascending: false }).limit(100);
      if (action === "public_list_content") query = query.eq("published", true);
      const { data, error } = await query;
      if (error) return respond(500, { error: "content_load_failed" });
      return respond(200, { items: data ?? [] });
    }

    if (action === "admin_save_content") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const kind = String(body?.kind ?? "");
      const table = contentTables[kind];
      if (!table) return respond(400, { error: "invalid_content_kind" });
      const item = body?.item;
      if (!item || typeof item !== "object") return respond(400, { error: "invalid_content" });
      const record: Record<string, unknown> = {
        title: String(item.title ?? "").trim(),
        body: String(item.body ?? ""),
        created_by: userId,
        updated_at: new Date().toISOString()
      };
      if (!record.title || String(record.title).length > 160 || String(record.body).length > (kind === "announcements" ? 6000 : 10000))
        return respond(400, { error: "invalid_content" });
      if (kind === "news") record.category = String(item.category ?? "GAMING").trim().slice(0, 40) || "GAMING";
      if (kind !== "announcements") record.published = item.published !== false;
      if (kind === "announcements" || kind === "news") {
        const link = String(item.link_url ?? "").trim();
        if (link && !/^https:\/\//i.test(link)) return respond(400, { error: "invalid_link" });
        record.link_url = link || null;
      }
      const id = String(item.id ?? "");
      const result = id
        ? await adminClient.from(table).update(record).eq("id", id).select().single()
        : await adminClient.from(table).insert(record).select().single();
      if (result.error) return respond(500, { error: "content_save_failed" });
      return respond(200, { item: result.data });
    }

    if (action === "admin_delete_content") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const kind = String(body?.kind ?? "");
      const table = contentTables[kind];
      const id = String(body?.id ?? "");
      if (!table || !id) return respond(400, { error: "invalid_content_target" });
      const { error } = await adminClient.from(table).delete().eq("id", id);
      if (error) return respond(500, { error: "content_delete_failed" });
      return respond(200, { deleted: true });
    }

    if (action === "admin_list_blacklist") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const { data, error } = await adminClient.from("aevnetwork_blacklist")
        .select("user_id, reason, created_at, created_by").order("created_at", { ascending: false });
      if (error) return respond(500, { error: "blacklist_load_failed" });
      const { data: authUsers, error: authUsersError } = await adminClient.auth.admin.listUsers({ page: 1, perPage: 1000 });
      if (authUsersError) return respond(500, { error: "users_load_failed" });
      const byId = new Map(authUsers.users.map((u: any) => [u.id, u.email ?? ""]));
      return respond(200, { items: (data ?? []).map((x: any) => ({ ...x, email: byId.get(x.user_id) ?? "" })) });
    }

    if (action === "admin_add_blacklist") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const targetId = String(body?.user_id ?? "");
      const reason = String(body?.reason ?? "").trim();
      if (!targetId || !reason || reason.length > 1000) return respond(400, { error: "invalid_blacklist_entry" });
      if (targetId === userId) return respond(400, { error: "cannot_blacklist_self" });
      const { data: target, error: targetError } = await adminClient.auth.admin.getUserById(targetId);
      if (targetError || !target.user) return respond(404, { error: "user_not_found" });
      const { error } = await adminClient.from("aevnetwork_blacklist").upsert({
        user_id: targetId, reason, created_by: userId
      }, { onConflict: "user_id" });
      if (error) return respond(500, { error: "blacklist_save_failed" });
      return respond(200, { saved: true });
    }

    if (action === "admin_remove_blacklist") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const targetId = String(body?.user_id ?? "");
      if (!targetId) return respond(400, { error: "invalid_user_id" });
      const { error } = await adminClient.from("aevnetwork_blacklist").delete().eq("user_id", targetId);
      if (error) return respond(500, { error: "blacklist_remove_failed" });
      return respond(200, { removed: true });
    }


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
