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

async function hashTeamInvite(code: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code));
  return Array.from(new Uint8Array(digest)).map((x) => x.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "method_not_allowed" });

  try {
    const body = await req.json();
    const action = String(body?.action ?? "");

    if (action === "service_get_status") {
      const { data, error } = await adminClient.from("aevtools_service_control")
        .select("maintenance_enabled,updated_at").eq("singleton", true).maybeSingle();
      if (error) return respond(500, { error: "service_status_load_failed" });
      const authHeader = req.headers.get("Authorization") ?? "";
      const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
      let userId = "";
      let isAdmin = false;
      if (token) {
        const { data: auth } = await authClient.auth.getUser(token);
        if (auth.user) {
          userId = auth.user.id;
          const client = createClient(supabaseUrl, anonKey, {
            global: { headers: { Authorization: `Bearer ${token}` } },
            auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
          });
          const { data: flag } = await client.rpc("aevtools_is_admin");
          isAdmin = flag === true;
        }
      }
      const { data: helper } = await adminClient.from("aevtools_test_helper_assignment")
        .select("user_id").eq("singleton", true).maybeSingle();
      return respond(200, {
        maintenance_enabled: data?.maintenance_enabled === true,
        updated_at: data?.updated_at ?? null,
        is_admin: isAdmin,
        is_test_helper: !!userId && helper?.user_id === userId && !isAdmin,
        test_helper_assigned: !!helper?.user_id,
      });
    }


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

    if (action === "community_my_deletion_notices") {
      const { data, error } = await adminClient.from("aevnetwork_community_deletion_notices")
        .select("id,item_type,item_title,item_content,reason,created_at,read_at")
        .eq("user_id", userId).order("created_at", { ascending: false }).limit(100);
      if (error) return respond(500, { error: "deletion_notices_load_failed" });
      return respond(200, { items: data ?? [] });
    }

    if (action === "community_read_deletion_notice") {
      const noticeId = String(body?.notice_id ?? "");
      if (!noticeId) return respond(400, { error: "invalid_notice_id" });
      const { data, error } = await adminClient.from("aevnetwork_community_deletion_notices")
        .update({ read_at: new Date().toISOString() })
        .eq("id", noticeId).eq("user_id", userId)
        .select("id").maybeSingle();
      if (error) return respond(500, { error: "deletion_notice_update_failed" });
      if (!data) return respond(404, { error: "deletion_notice_not_found" });
      return respond(200, { read: true });
    }

    if (action === "community_list_posts") {
      const { data: posts, error: postsError } = await adminClient
        .from("aevnetwork_community_posts")
        .select("id,author_id,author_name,title,body,image_url,image_path,created_at,updated_at")
        .is("deleted_at", null).order("created_at", { ascending: false }).limit(50);
      if (postsError) return respond(500, { error: "community_posts_load_failed" });
      const postIds = (posts ?? []).map((p: any) => p.id);
      const { data: comments, error: commentsError } = postIds.length
        ? await adminClient.from("aevnetwork_community_comments")
            .select("id,post_id,author_id,author_name,body,created_at")
            .in("post_id", postIds).is("deleted_at", null)
            .order("created_at", { ascending: true }).limit(500)
        : { data: [], error: null };
      if (commentsError) return respond(500, { error: "community_comments_load_failed" });
      const ids = [...new Set([...(posts ?? []).map((p: any) => p.author_id), ...(comments ?? []).map((c: any) => c.author_id)])];
      const { data: profiles, error: profilesError } = ids.length
        ? await adminClient.from("aevtools_profiles").select("user_id,nickname").in("user_id", ids)
        : { data: [], error: null };
      if (profilesError) return respond(500, { error: "community_profiles_load_failed" });
      const names = new Map((profiles ?? []).map((p: any) => [p.user_id, p.nickname || "ユーザー"]));
      const commentRows = (comments ?? []).map((c: any) => ({ ...c, author_nickname: c.author_name || names.get(c.author_id) || "ユーザー" }));
      const byPost = new Map<string, any[]>();
      for (const c of commentRows) {
        const list = byPost.get(c.post_id) ?? []; list.push(c); byPost.set(c.post_id, list);
      }
      return respond(200, { items: (posts ?? []).map((p: any) => ({
        ...p, author_nickname: p.author_name || names.get(p.author_id) || "ユーザー", comments: byPost.get(p.id) ?? []
      })) });
    }

    if (action === "public_list_content") {
      const { data: maintenanceRow, error: maintenanceError } = await adminClient.from("aevtools_service_control")
        .select("maintenance_enabled").eq("singleton", true).maybeSingle();
      if (maintenanceError) return respond(500, { error: "service_status_load_failed" });
      if (maintenanceRow?.maintenance_enabled === true) {
        const publicTokenHeader = req.headers.get("Authorization") ?? "";
        const publicToken = publicTokenHeader.startsWith("Bearer ") ? publicTokenHeader.slice(7) : "";
        let publicAdmin = false;
        if (publicToken) {
          const { data: publicAuth } = await authClient.auth.getUser(publicToken);
          if (publicAuth.user) {
            const publicClient = createClient(supabaseUrl, anonKey, {
              global: { headers: { Authorization: `Bearer ${publicToken}` } },
              auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
            });
            const { data: publicAdminFlag } = await publicClient.rpc("aevtools_is_admin");
            publicAdmin = publicAdminFlag === true;
            if (!publicAdmin) {
              const { data: helper } = await adminClient.from("aevtools_test_helper_assignment")
                .select("user_id").eq("singleton", true).maybeSingle();
              publicAdmin = helper?.user_id === publicAuth.user.id;
            }
          }
        }
        if (!publicAdmin) return respond(503, { error: "service_maintenance", message: "現在メンテナンス中です。" });
      }
      const kind = String(body?.kind ?? "");
      const publicTables: Record<string, string> = {
        announcements: "aevtools_announcements",
        news: "aevnetwork_news",
        updates: "aevnetwork_updates"
      };
      const table = publicTables[kind];
      if (!table) return respond(400, { error: "invalid_content_kind" });
      let query = adminClient.from(table).select("*").order("created_at", { ascending: false }).limit(100);
      if (kind !== "announcements") query = query.eq("published", true);
      const { data, error } = await query;
      if (error) return respond(500, { error: "content_load_failed", detail: error.message, code: error.code, hint: error.hint });
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
    const { data: assignedTestHelper, error: testHelperLookupError } = await adminClient
      .from("aevtools_test_helper_assignment").select("user_id,code_hash,assigned_by,assigned_at").eq("singleton", true).maybeSingle();
    if (testHelperLookupError) return respond(500, { error: "test_helper_lookup_failed" });
    const isTestHelper = !isAdmin && assignedTestHelper?.user_id === userId;
    if (isAdmin) {
      const { error: registryError } = await adminClient.from("aevnetwork_team_admin_registry")
        .upsert({ singleton: true, user_id: userId }, { onConflict: "singleton" });
      if (registryError) return respond(500, { error: "admin_registry_sync_failed" });
    }

    if (action === "is_admin") {
      if (adminFlagError) return respond(500, { error: "admin_check_failed" });
      return respond(200, { is_admin: isAdmin, is_test_helper: isTestHelper });
    }

    if (action === "admin_test_helper_get") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const helper = assignedTestHelper?.user_id ? await adminClient.auth.admin.getUserById(assignedTestHelper.user_id) : null;
      return respond(200, {
        assigned: !!assignedTestHelper?.user_id,
        code_ready: !!assignedTestHelper && !assignedTestHelper.user_id && !!assignedTestHelper.code_hash,
        user: helper?.data?.user ? { id: helper.data.user.id, email: helper.data.user.email ?? "" } : null
      });
    }

    if (action === "admin_test_helper_generate_code") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      if (assignedTestHelper) return respond(409, { error: assignedTestHelper.user_id ? "test_helper_already_assigned" : "test_helper_code_already_generated" });
      const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      const code = Array.from(bytes, (b) => alphabet[b & 31]).join("");
      const codeHash = await hashTeamInvite(code);
      const { error } = await adminClient.from("aevtools_test_helper_assignment").insert({
        singleton: true, user_id: null, assigned_by: userId, assigned_at: null, code_hash: codeHash
      });
      if (error) return respond(409, { error: "test_helper_code_generation_failed" });
      return respond(200, { generated: true, code });
    }

    if (action === "test_helper_claim_code") {
      if (isAdmin) return respond(403, { error: "admin_cannot_be_test_helper" });
      if (isTestHelper) return respond(409, { error: "test_helper_already_claimed" });
      const code = String(body?.code ?? "").replace(/\s/g, "").toUpperCase();
      if (!/^[A-HJ-NP-Z2-9]{16}$/.test(code)) return respond(400, { error: "invalid_test_helper_code" });
      const codeHash = await hashTeamInvite(code);
      if (!assignedTestHelper || assignedTestHelper.user_id || assignedTestHelper.code_hash !== codeHash) {
        return respond(409, { error: "test_helper_code_invalid_or_used" });
      }
      const { data: claimed, error } = await adminClient.from("aevtools_test_helper_assignment")
        .update({ user_id: userId, assigned_at: new Date().toISOString() })
        .eq("singleton", true).is("user_id", null).eq("code_hash", codeHash)
        .select("user_id").maybeSingle();
      if (error || !claimed) return respond(409, { error: "test_helper_code_invalid_or_used" });
      return respond(200, { claimed: true, is_test_helper: true });
    }

    if (action === "service_set_maintenance") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const enabled = body?.enabled === true;
      const { data, error } = await adminClient.rpc("aevtools_set_maintenance_with_snapshot", {
        p_enabled: enabled,
        p_updated_by: userId
      });
      if (error) return respond(500, { error: "service_maintenance_update_failed", detail: error.message });
      return respond(200, {
        saved: true,
        maintenance_enabled: data?.maintenance_enabled === true,
        snapshot: data?.snapshot ?? {}
      });
    }

    const { data: serviceControl, error: serviceControlError } = await adminClient.from("aevtools_service_control")
      .select("maintenance_enabled").eq("singleton", true).maybeSingle();
    if (serviceControlError) return respond(500, { error: "service_status_load_failed" });
    if (serviceControl?.maintenance_enabled === true && !isAdmin && !isTestHelper) {
      return respond(503, { error: "service_maintenance", message: "現在メンテナンス中です。" });
    }

    // Snapshot access is always scoped to the authenticated user's own row.
    // The browser must acknowledge only after its merged data has been saved.
    if (action === "user_data_snapshot_get") {
      const appKey = String(body?.app_key ?? "");
      if (!["aevtools", "aevnetwork"].includes(appKey)) {
        return respond(400, { error: "invalid_app_key" });
      }
      if (serviceControl?.maintenance_enabled === true) {
        return respond(503, { error: "service_maintenance" });
      }
      const { data, error } = await adminClient.from("aev_user_data_snapshots")
        .select("data,source_updated_at,captured_at")
        .eq("user_id", userId).eq("app_key", appKey).maybeSingle();
      if (error) return respond(500, { error: "snapshot_load_failed" });
      return respond(200, {
        snapshot: data?.data ?? null,
        source_updated_at: data?.source_updated_at ?? null,
        captured_at: data?.captured_at ?? null
      });
    }

    if (action === "user_data_snapshot_ack") {
      const appKey = String(body?.app_key ?? "");
      if (!["aevtools", "aevnetwork"].includes(appKey)) {
        return respond(400, { error: "invalid_app_key" });
      }
      if (serviceControl?.maintenance_enabled === true) {
        return respond(503, { error: "service_maintenance" });
      }
      const { error } = await adminClient.from("aev_user_data_snapshots")
        .delete().eq("user_id", userId).eq("app_key", appKey);
      if (error) return respond(500, { error: "snapshot_ack_failed" });
      return respond(200, { acknowledged: true });
    }

    // AevNetwork blacklist is scoped to this service only. It never disables
    // the shared Supabase Auth account or access to AevTools.
    const { data: blockedRow, error: blockedError } = await adminClient
      .from("aevnetwork_blacklist").select("reason").eq("user_id", userId).maybeSingle();
    if (blockedError) return respond(500, { error: "blacklist_check_failed" });
    if (blockedRow && !isAdmin) return respond(403, { error: "aevnetwork_restricted", reason: blockedRow.reason });

    // Resolve public role badges from authoritative server-side records.
    // A leader badge exists while the user owns at least one active team.
    async function getBadgeMap(userIds: string[]) {
      const ids = [...new Set(userIds.filter((x) => typeof x === "string" && x.length > 0))].slice(0, 150);
      if (!ids.length) return new Map<string, any>();
      const [admins, blocked, leaders] = await Promise.all([
        adminClient.from("aevnetwork_team_admin_registry").select("user_id").in("user_id", ids),
        adminClient.from("aevnetwork_blacklist").select("user_id").in("user_id", ids),
        adminClient.from("aevnetwork_teams").select("owner_id").in("owner_id", ids)
      ]);
      if (admins.error || blocked.error || leaders.error) throw new Error("user_badges_load_failed");
      const adminSet = new Set((admins.data ?? []).map((x: any) => x.user_id));
      const blockedSet = new Set((blocked.data ?? []).map((x: any) => x.user_id));
      const leaderSet = new Set((leaders.data ?? []).map((x: any) => x.owner_id));
      return new Map(ids.map((id) => [id, {
        is_admin: adminSet.has(id),
        is_blacklisted: blockedSet.has(id),
        is_leader: leaderSet.has(id)
      }]));
    }

    if (action === "teams_invite_generate") {
      const teamId=String(body?.team_id??"");
      if(!teamId)return respond(400,{error:"invalid_team_id"});
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id,owner_id").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      if(team.owner_id!==userId)return respond(403,{error:"team_leader_required"});
      // The UNIQUE constraint on invite_code_hash is the final authority:
      // even if two leaders generate codes at the same time, duplicate codes
      // cannot be stored. Retry on unique-violation and return only after save.
      for(let attempt=0;attempt<20;attempt++){
        const random=new Uint8Array(4);crypto.getRandomValues(random);
        const value=new DataView(random.buffer).getUint32(0);
        const code=String(value%100000000).padStart(8,"0");
        const hash=await hashTeamInvite(code);
        const generatedAt=new Date().toISOString();
        const {error}=await adminClient.from("aevnetwork_teams")
          .update({invite_code_hash:hash,invite_code_updated_at:generatedAt})
          .eq("id",teamId);
        if(!error)return respond(200,{generated:true,code,generated_at:generatedAt,expires_at:new Date(new Date(generatedAt).getTime()+10*60*1000).toISOString()});
        if(error.code==="23505")continue;
        return respond(500,{error:"invite_code_save_failed"});
      }
      return respond(500,{error:"invite_code_generation_failed"});
    }

    if (action === "teams_join_code") {
      const code=String(body?.code??"").replace(/\s/g,"");
      if(!/^\d{8}$/.test(code))return respond(400,{error:"invalid_invite_code"});
      const hash=await hashTeamInvite(code);
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id,name,invite_code_updated_at").eq("invite_code_hash",hash).maybeSingle();
      if(!team)return respond(404,{error:"invite_code_not_found"});
      const issuedAt=team.invite_code_updated_at?new Date(team.invite_code_updated_at).getTime():0;
      if(!issuedAt||!Number.isFinite(issuedAt)||Date.now()-issuedAt>=10*60*1000)return respond(410,{error:"invite_code_expired"});
      const {data:existing}=await adminClient.from("aevnetwork_team_members").select("id,status,role").eq("team_id",team.id).eq("user_id",userId).maybeSingle();
      if(existing?.status==="approved"||existing?.role==="leader")return respond(409,{error:"already_team_member"});
      const result=existing
        ?await adminClient.from("aevnetwork_team_members").update({status:"approved",role:"member",reviewed_at:new Date().toISOString()}).eq("id",existing.id)
        :await adminClient.from("aevnetwork_team_members").insert({team_id:team.id,user_id:userId,role:"member",status:"approved",reviewed_at:new Date().toISOString()});
      if(result.error)return respond(result.error.message.includes("team_full")?409:500,{error:result.error.message.includes("team_full")?"team_full":"team_join_failed"});
      return respond(200,{joined:true,team_id:team.id,team_name:team.name});
    }

    if (action === "teams_list") {
      const { data: teams, error } = await adminClient.from("aevnetwork_teams")
        .select("id,name,description,game,owner_id,created_at").order("created_at",{ascending:false}).limit(100);
      if(error)return respond(500,{error:"teams_load_failed"});
      const ids=(teams??[]).map((t:any)=>t.id);
      const [members,profiles,mine]=await Promise.all([
        ids.length?adminClient.from("aevnetwork_team_members").select("team_id,user_id,status,role").in("team_id",ids):Promise.resolve({data:[],error:null}),
        adminClient.from("aevtools_profiles").select("user_id,nickname").in("user_id",[...new Set((teams??[]).map((t:any)=>t.owner_id))]),
        adminClient.from("aevnetwork_team_members").select("team_id,status,role").eq("user_id",userId)
      ]);
      if(members.error||profiles.error||mine.error)return respond(500,{error:"teams_details_load_failed"});
      const names=new Map((profiles.data??[]).map((p:any)=>[p.user_id,p.nickname||"ユーザー"]));
      const mineMap=new Map((mine.data??[]).map((m:any)=>[m.team_id,m]));
      const badges=await getBadgeMap((teams??[]).map((t:any)=>t.owner_id));
      return respond(200,{items:(teams??[]).map((t:any)=>({...t,owner_nickname:names.get(t.owner_id)||"ユーザー",owner_badges:badges.get(t.owner_id)||{},
        member_count:(members.data??[]).filter((m:any)=>m.team_id===t.id&&m.status==="approved").length,
        my_status:mineMap.get(t.id)?.status||null,my_role:mineMap.get(t.id)?.role||null}))});
    }

    if (action === "teams_create") {
      const name=String(body?.name??"").trim(),description=String(body?.description??"").trim(),game=String(body?.game??"").trim();
      if(name.length<2||name.length>32||description.length>1000||game.length>60)return respond(400,{error:"invalid_team"});
      const {data:team,error}=await adminClient.from("aevnetwork_teams").insert({name,description,game,owner_id:userId}).select("id").single();
      if(error)return respond(400,{error:"team_create_failed",detail:error.message});
      const {error:memberError}=await adminClient.from("aevnetwork_team_members").insert({team_id:team.id,user_id:userId,role:"leader",status:"approved",reviewed_at:new Date().toISOString()});
      if(memberError){await adminClient.from("aevnetwork_teams").delete().eq("id",team.id);return respond(500,{error:"team_owner_setup_failed"});}
      return respond(200,{created:true,team_id:team.id});
    }

    if (action === "teams_delete") {
      const teamId=String(body?.team_id??"");
      if(!teamId)return respond(400,{error:"invalid_team_id"});
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id,owner_id").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      if(team.owner_id!==userId&&!isAdmin)return respond(403,{error:"team_delete_forbidden"});
      const {error}=await adminClient.from("aevnetwork_teams").delete().eq("id",teamId);
      if(error)return respond(500,{error:"team_delete_failed",detail:error.message});
      return respond(200,{deleted:true});
    }

    if (action === "teams_apply") {
      const teamId=String(body?.team_id??"");
      if(!teamId)return respond(400,{error:"invalid_team_id"});
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      const {count}=await adminClient.from("aevnetwork_team_members").select("id",{count:"exact",head:true}).eq("team_id",teamId).eq("status","approved");
      if((count??0)>=4)return respond(409,{error:"team_full"});
      const {data:existing}=await adminClient.from("aevnetwork_team_members").select("id,status").eq("team_id",teamId).eq("user_id",userId).maybeSingle();
      if(existing&&existing.status!=="rejected")return respond(409,{error:"team_application_exists"});
      const result=existing
        ?await adminClient.from("aevnetwork_team_members").update({status:"pending",role:"member",created_at:new Date().toISOString(),reviewed_at:null}).eq("id",existing.id)
        :await adminClient.from("aevnetwork_team_members").insert({team_id:teamId,user_id:userId,role:"member",status:"pending"});
      if(result.error)return respond(500,{error:"team_apply_failed"});
      return respond(200,{applied:true});
    }

    if (action === "teams_my") {
      const {data:members,error}=await adminClient.from("aevnetwork_team_members")
        .select("team_id,user_id,role,status,created_at,reviewed_at").eq("user_id",userId).order("created_at",{ascending:false});
      if(error)return respond(500,{error:"my_teams_load_failed"});
      const ids=(members??[]).map((m:any)=>m.team_id);
      const {data:teams,error:teamsError}=ids.length?await adminClient.from("aevnetwork_teams")
        .select("id,name,description,game,owner_id,created_at").in("id",ids):{data:[],error:null};
      if(teamsError)return respond(500,{error:"my_teams_load_failed"});
      const byId=new Map((teams??[]).map((t:any)=>[t.id,t]));
      return respond(200,{items:(members??[]).map((m:any)=>({...m,team:byId.get(m.team_id)})).filter((m:any)=>m.team)});
    }

    if (action === "teams_members") {
      const teamId=String(body?.team_id??"");
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id,owner_id,invite_code_updated_at").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      const {data:mine}=await adminClient.from("aevnetwork_team_members").select("status,role").eq("team_id",teamId).eq("user_id",userId).maybeSingle();
      if(!mine||mine.status!=="approved")return respond(403,{error:"team_membership_required"});
      const {data:rows,error}=await adminClient.from("aevnetwork_team_members").select("id,user_id,role,status,created_at").eq("team_id",teamId).order("created_at",{ascending:true});
      if(error)return respond(500,{error:"team_members_load_failed"});
      const ids=[...new Set((rows??[]).map((m:any)=>m.user_id))];
      const {data:profiles}=ids.length?await adminClient.from("aevtools_profiles").select("user_id,nickname").in("user_id",ids):{data:[]};
      const names=new Map((profiles??[]).map((p:any)=>[p.user_id,p.nickname||"ユーザー"]));
      const badges=await getBadgeMap(ids);
      const isLeader=team.owner_id===userId;
      return respond(200,{is_leader:isLeader,is_owner:isLeader,invite_code_updated_at:isLeader?team.invite_code_updated_at:null,items:(rows??[]).filter((m:any)=>isLeader||m.status==="approved").map((m:any)=>({...m,nickname:names.get(m.user_id)||"ユーザー",...(badges.get(m.user_id)||{})}))});
    }

    if (action === "teams_kick") {
      const teamId=String(body?.team_id??""),memberId=String(body?.member_id??"");
      if(!teamId||!memberId)return respond(400,{error:"invalid_team_kick"});
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id,owner_id").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      if(team.owner_id!==userId)return respond(403,{error:"team_leader_required"});
      const {data:member}=await adminClient.from("aevnetwork_team_members").select("id,user_id,role,status").eq("id",memberId).eq("team_id",teamId).maybeSingle();
      if(!member)return respond(404,{error:"team_member_not_found"});
      if(member.user_id===team.owner_id||member.role==="leader")return respond(403,{error:"cannot_kick_leader"});
      const {data:protectedAdmin}=await adminClient.from("aevnetwork_team_admin_registry").select("user_id").eq("user_id",member.user_id).maybeSingle();
      if(protectedAdmin)return respond(403,{error:"cannot_kick_admin"});
      if(member.status!=="approved")return respond(409,{error:"team_member_not_active"});
      const {error}=await adminClient.from("aevnetwork_team_members").delete().eq("id",memberId);
      if(error)return respond(500,{error:"team_kick_failed"});
      return respond(200,{kicked:true});
    }

    if (action === "teams_review") {
      const memberId=String(body?.member_id??""),decision=String(body?.decision??"");
      if(!memberId||!["approved","rejected"].includes(decision))return respond(400,{error:"invalid_team_review"});
      const {data:membership}=await adminClient.from("aevnetwork_team_members").select("id,team_id,status").eq("id",memberId).maybeSingle();
      if(!membership)return respond(404,{error:"team_application_not_found"});
      const {data:team}=await adminClient.from("aevnetwork_teams").select("owner_id").eq("id",membership.team_id).maybeSingle();
      if(!team||team.owner_id!==userId)return respond(403,{error:"team_leader_required"});
      if(membership.status!=="pending")return respond(409,{error:"application_already_reviewed"});
      const {error}=await adminClient.from("aevnetwork_team_members").update({status:decision,reviewed_at:new Date().toISOString()}).eq("id",memberId);
      if(error)return respond(error.message.includes("team_full")?409:500,{error:error.message.includes("team_full")?"team_full":"team_review_failed"});
      return respond(200,{reviewed:true});
    }

    if (action === "teams_chat_list" || action === "teams_chat_send") {
      const teamId=String(body?.team_id??"");
      if(!teamId)return respond(400,{error:"invalid_team_id"});
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      const {data:membership}=await adminClient.from("aevnetwork_team_members").select("status").eq("team_id",teamId).eq("user_id",userId).maybeSingle();
      let mediation=false;
      if(isAdmin){
        const {data:grant}=await adminClient.from("aevnetwork_team_mediation_requests").select("id")
          .eq("team_id",teamId).eq("status","approved").limit(1).maybeSingle();
        mediation=!!grant;
      }
      if((!membership||membership.status!=="approved")&&!(isAdmin&&mediation))return respond(403,{error:"team_chat_members_only"});
      if(action==="teams_chat_send"){
        const message=String(body?.body??"").trim();
        if(!message||message.length>2000)return respond(400,{error:"invalid_team_message"});
        const {error}=await adminClient.from("aevnetwork_team_messages").insert({team_id:teamId,user_id:userId,body:message});
        if(error)return respond(500,{error:"team_message_send_failed"});
        return respond(200,{sent:true});
      }
      // Chat history is retained unless the team itself is permanently deleted.
      // Hiding a chat only removes the user's membership/list entry; rejoining restores access to history.
      const {data:messages,error}=await adminClient.from("aevnetwork_team_messages")
        .select("id,user_id,body,created_at").eq("team_id",teamId)
        .order("created_at",{ascending:false}).limit(100);
      if(error)return respond(500,{error:"team_chat_load_failed"});
      const ids=[...new Set((messages??[]).map((m:any)=>m.user_id))];
      const {data:profiles}=ids.length?await adminClient.from("aevtools_profiles").select("user_id,nickname").in("user_id",ids):{data:[]};
      const names=new Map((profiles??[]).map((p:any)=>[p.user_id,p.nickname||"ユーザー"]));
      const badges=await getBadgeMap(ids);
      return respond(200,{items:(messages??[]).reverse().map((m:any)=>({...m,nickname:names.get(m.user_id)||"ユーザー",mine:m.user_id===userId,...(badges.get(m.user_id)||{})}))});
    }

    if (action === "teams_leave" || action === "teams_chat_hide") {
      const teamId=String(body?.team_id??"");
      const {data:team}=await adminClient.from("aevnetwork_teams").select("owner_id").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      if(team.owner_id===userId)return respond(403,{error:"leader_cannot_leave"});
      const {data:currentMembership}=await adminClient.from("aevnetwork_team_members").select("status").eq("team_id",teamId).eq("user_id",userId).maybeSingle();
      if(!currentMembership||currentMembership.status!=="approved")return respond(403,{error:"team_membership_required"});
      if(action==="teams_chat_hide"){
        const now=new Date().toISOString();
        const {error:prefError}=await adminClient.from("aevnetwork_team_chat_preferences").upsert({team_id:teamId,user_id:userId,hidden_before:now,hidden_at:now,updated_at:now},{onConflict:"team_id,user_id"});
        if(prefError)return respond(500,{error:"team_chat_hide_failed"});
      }
      const {error}=await adminClient.from("aevnetwork_team_members").delete().eq("team_id",teamId).eq("user_id",userId);
      if(error)return respond(500,{error:"team_leave_failed"});
      return respond(200,{left:true,chat_hidden:action==="teams_chat_hide"});
    }

    if (action === "teams_mediation_request") {
      const teamId=String(body?.team_id??""),message=String(body?.message??"").trim();
      if(!teamId||message.length>1000)return respond(400,{error:"invalid_mediation_request"});
      const {data:member}=await adminClient.from("aevnetwork_team_members").select("status").eq("team_id",teamId).eq("user_id",userId).maybeSingle();
      if(!member||member.status!=="approved")return respond(403,{error:"team_membership_required"});
      const {error}=await adminClient.from("aevnetwork_team_mediation_requests").insert({team_id:teamId,requester_id:userId,message});
      if(error)return respond(409,{error:"mediation_request_exists"});
      return respond(200,{requested:true});
    }

    if (action === "teams_admin_list" || action === "teams_admin_mediation_list" || action === "teams_admin_mediation_approve" || action === "teams_admin_chat_list") {
      if(!isAdmin)return respond(403,{error:"admin_required"});
      if(action==="teams_admin_list"){
        const {data:teams,error}=await adminClient.from("aevnetwork_teams").select("id,name,owner_id,created_at").order("created_at",{ascending:false}).limit(200);
        if(error)return respond(500,{error:"admin_teams_load_failed"});
        return respond(200,{items:teams??[]});
      }
      if(action==="teams_admin_mediation_list"){
        const {data:rows,error}=await adminClient.from("aevnetwork_team_mediation_requests").select("id,team_id,requester_id,message,status,created_at").in("status",["pending","approved"]).order("created_at",{ascending:true});
        if(error)return respond(500,{error:"mediation_list_failed"});
        const ids=[...new Set((rows??[]).map((x:any)=>x.requester_id))],teamIds=[...new Set((rows??[]).map((x:any)=>x.team_id))];
        const [profiles,teams]=await Promise.all([
          ids.length?adminClient.from("aevtools_profiles").select("user_id,nickname").in("user_id",ids):Promise.resolve({data:[]}),
          teamIds.length?adminClient.from("aevnetwork_teams").select("id,name").in("id",teamIds):Promise.resolve({data:[]})
        ]);
        const names=new Map((profiles.data??[]).map((p:any)=>[p.user_id,p.nickname||"ユーザー"])),teamNames=new Map((teams.data??[]).map((t:any)=>[t.id,t.name]));
        return respond(200,{items:(rows??[]).map((x:any)=>({...x,requester_nickname:names.get(x.requester_id)||"ユーザー",team_name:teamNames.get(x.team_id)||"削除済み"}))});
      }
      if(action==="teams_admin_mediation_approve"){
        const requestId=String(body?.request_id??""),decision=String(body?.decision??"approved");
        if(!requestId||!["approved","closed"].includes(decision))return respond(400,{error:"invalid_mediation_decision"});
        let update=adminClient.from("aevnetwork_team_mediation_requests").update({status:decision,updated_at:new Date().toISOString()}).eq("id",requestId); update=decision==="approved"?update.eq("status","pending"):update.in("status",["pending","approved"]); const {data,error}=await update.select("id").maybeSingle();
        if(error)return respond(500,{error:"mediation_update_failed"});
        if(!data)return respond(404,{error:"mediation_request_not_found"});
        return respond(200,{updated:true});
      }
      const teamId=String(body?.team_id??"");
      if(!teamId)return respond(400,{error:"invalid_team_id"});
      const {data:team}=await adminClient.from("aevnetwork_teams").select("id,name").eq("id",teamId).maybeSingle();
      if(!team)return respond(404,{error:"team_not_found"});
      const {data:messages,error}=await adminClient.from("aevnetwork_team_messages").select("id,user_id,body,created_at").eq("team_id",teamId).order("created_at",{ascending:false}).limit(100);
      if(error)return respond(500,{error:"admin_team_chat_load_failed"});
      const ids=[...new Set((messages??[]).map((m:any)=>m.user_id))];
      const {data:profiles}=ids.length?await adminClient.from("aevtools_profiles").select("user_id,nickname").in("user_id",ids):{data:[]};
      const names=new Map((profiles??[]).map((p:any)=>[p.user_id,p.nickname||"ユーザー"]));
      const {data:mediationGrant}=await adminClient.from("aevnetwork_team_mediation_requests").select("id").eq("team_id",teamId).eq("status","approved").limit(1).maybeSingle();
      return respond(200,{team,items:(messages??[]).reverse().map((m:any)=>({...m,nickname:names.get(m.user_id)||"ユーザー"})),audit_only:true,mediation_allowed:!!mediationGrant});
    }

    if (action === "community_create_post") {
      const title = String(body?.title ?? "").trim();
      const content = String(body?.body ?? "").trim();
      const imageUrl = String(body?.image_url ?? "").trim();
      const imagePath = String(body?.image_path ?? "").trim();
      if (!title || title.length > 160 || !content || content.length > 6000 ||
          (imageUrl && !/^https:\/\//i.test(imageUrl)) ||
          (imagePath && !imagePath.startsWith(userId + "/")))
        return respond(400, { error: "invalid_community_post" });
      const { data, error } = await adminClient.from("aevnetwork_community_posts")
        .insert({ author_id: userId, title, body: content, image_url: imageUrl || null, image_path: imagePath || null }).select("id").single();
      if (error) return respond(500, { error: "community_post_create_failed" });
      return respond(200, { created: true, id: data.id });
    }

    if (action === "community_create_comment") {
      const postId = String(body?.post_id ?? "");
      const content = String(body?.body ?? "").trim();
      if (!postId || !content || content.length > 2000) return respond(400, { error: "invalid_community_comment" });
      const { data: post, error: postError } = await adminClient.from("aevnetwork_community_posts")
        .select("id").eq("id", postId).is("deleted_at", null).maybeSingle();
      if (postError || !post) return respond(404, { error: "community_post_not_found" });
      const { error } = await adminClient.from("aevnetwork_community_comments")
        .insert({ post_id: postId, author_id: userId, body: content });
      if (error) return respond(500, { error: "community_comment_create_failed" });
      return respond(200, { created: true });
    }

    if (action === "community_delete_post" || action === "community_delete_comment") {
      const type = action === "community_delete_post" ? "post" : "comment";
      const table = type === "post" ? "aevnetwork_community_posts" : "aevnetwork_community_comments";
      const id = String(body?.id ?? "");
      if (!id) return respond(400, { error: "invalid_community_target" });
      const targetQuery = type === "post"
        ? adminClient.from(table).select("id,author_id,title,body,image_path")
        : adminClient.from(table).select("id,author_id,body");
      const { data: target, error: targetError } = await targetQuery
        .eq("id", id).is("deleted_at", null).maybeSingle();
      if (targetError || !target) return respond(404, { error: "community_target_not_found" });
      if (target.author_id !== userId && !isAdmin) return respond(403, { error: "owner_or_admin_required" });

      const isModeratorRemoval = isAdmin && target.author_id !== userId;
      const reason = isModeratorRemoval ? String(body?.reason ?? "").trim().slice(0, 500) : null;
      if (isModeratorRemoval && (!reason || reason.length < 3))
        return respond(400, { error: "moderation_reason_required" });

      if (isModeratorRemoval) {
        const { error: noticeError } = await adminClient.from("aevnetwork_community_deletion_notices").insert({
          user_id: target.author_id,
          item_type: type,
          item_title: type === "post" ? target.title : null,
          item_content: String(target.body ?? ""),
          reason
        });
        if (noticeError) return respond(500, { error: "deletion_notice_create_failed" });
      }

      const deletedAt = new Date().toISOString();
      const { error } = await adminClient.from(table).update({
        deleted_at: deletedAt,
        moderated_by: isModeratorRemoval ? userId : null,
        moderation_reason: reason
      }).eq("id", id).is("deleted_at", null);
      if (error) return respond(500, { error: "community_delete_failed" });

      if (type === "post") {
        await adminClient.from("aevnetwork_community_comments")
          .update({ deleted_at: deletedAt, moderated_by: isModeratorRemoval ? userId : null, moderation_reason: reason })
          .eq("post_id", id).is("deleted_at", null);
        if (target.image_path) await adminClient.storage.from("aev-board-images").remove([target.image_path]);
      }
      if (isModeratorRemoval) {
        await adminClient.from("aevnetwork_community_moderation_logs").insert({
          target_type: type, target_id: id, action: "remove", reason, admin_id: userId
        });
      }
      return respond(200, { deleted: true, notice_created: isModeratorRemoval });
    }

    if (action === "community_report") {
      const type = String(body?.target_type ?? "");
      const targetId = String(body?.target_id ?? "");
      const reason = String(body?.reason ?? "").trim();
      if (!["post","comment"].includes(type) || !targetId || reason.length < 5 || reason.length > 500)
        return respond(400, { error: "invalid_community_report" });
      const table = type === "post" ? "aevnetwork_community_posts" : "aevnetwork_community_comments";
      const { data: target, error: targetError } = await adminClient.from(table)
        .select("id,author_id").eq("id", targetId).is("deleted_at", null).maybeSingle();
      if (targetError || !target) return respond(404, { error: "community_target_not_found" });
      if (target.author_id === userId) return respond(400, { error: "cannot_report_own_content" });
      const { error } = await adminClient.from("aevnetwork_community_reports")
        .insert({ target_type: type, target_id: targetId, reporter_id: userId, reason });
      if (error) return respond(400, { error: "community_report_duplicate_or_failed" });
      return respond(200, { reported: true });
    }

    if (action === "community_admin_list_reports") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const { data, error } = await adminClient.from("aevnetwork_community_reports")
        .select("id,target_type,target_id,reporter_id,reason,status,created_at")
        .eq("status","pending").order("created_at",{ascending:false}).limit(100);
      if (error) return respond(500, { error: "community_reports_load_failed" });
      const ids = [...new Set((data ?? []).map((r: any) => r.reporter_id))];
      const { data: profiles, error: profileError } = ids.length
        ? await adminClient.from("aevtools_profiles").select("user_id,nickname").in("user_id",ids)
        : { data: [], error: null };
      if (profileError) return respond(500, { error: "community_profiles_load_failed" });
      const names = new Map((profiles ?? []).map((p: any) => [p.user_id,p.nickname || "ユーザー"]));
      const rows = await Promise.all((data ?? []).map(async (r: any) => {
        const table = r.target_type === "post" ? "aevnetwork_community_posts" : "aevnetwork_community_comments";
        const { data: target } = await adminClient.from(table).select("title,body").eq("id",r.target_id).maybeSingle();
        return { ...r, reporter_nickname: names.get(r.reporter_id) ?? "ユーザー",
          target_preview: String(target?.title ?? target?.body ?? "対象コンテンツなし").slice(0,300) };
      }));
      return respond(200, { items: rows });
    }

    if (action === "community_admin_resolve_report") {
      if (!isAdmin) return respond(403, { error: "admin_required" });
      const reportId = String(body?.report_id ?? "");
      const remove = body?.remove === true;
      const reason = String(body?.reason ?? "").trim().slice(0,500);
      if (!reportId || (remove && reason.length < 3)) return respond(400, { error: "invalid_moderation_request" });
      const { data: report, error: reportError } = await adminClient.from("aevnetwork_community_reports")
        .select("id,target_type,target_id,status").eq("id",reportId).eq("status","pending").maybeSingle();
      if (reportError || !report) return respond(404, { error: "community_report_not_found" });

      if (remove) {
        const table = report.target_type === "post" ? "aevnetwork_community_posts" : "aevnetwork_community_comments";
        const columns = report.target_type === "post" ? "id,author_id,title,body,image_path" : "id,author_id,body";
        const { data: target, error: targetError } = await adminClient.from(table)
          .select(columns).eq("id",report.target_id).is("deleted_at",null).maybeSingle();
        if (targetError) return respond(500, { error: "community_target_load_failed" });
        if (target) {
          const { error: noticeError } = await adminClient.from("aevnetwork_community_deletion_notices").insert({
            user_id: target.author_id,
            item_type: report.target_type,
            item_title: report.target_type === "post" ? target.title : null,
            item_content: String(target.body ?? ""),
            reason
          });
          if (noticeError) return respond(500, { error: "deletion_notice_create_failed" });

          const deletedAt = new Date().toISOString();
          const { error } = await adminClient.from(table).update({
            deleted_at: deletedAt, moderated_by: userId, moderation_reason: reason
          }).eq("id",report.target_id).is("deleted_at",null);
          if (error) return respond(500, { error: "community_moderation_failed" });
          if (report.target_type === "post") {
            await adminClient.from("aevnetwork_community_comments")
              .update({ deleted_at: deletedAt, moderated_by: userId, moderation_reason: reason })
              .eq("post_id",report.target_id).is("deleted_at",null);
            if (target.image_path) await adminClient.storage.from("aev-board-images").remove([target.image_path]);
          }
        }
      }
      const { error: updateError } = await adminClient.from("aevnetwork_community_reports").update({
        status: "resolved", reviewed_by: userId, reviewed_at: new Date().toISOString()
      }).eq("id",reportId).eq("status","pending");
      if (updateError) return respond(500, { error: "community_report_update_failed" });
      const { error: logError } = await adminClient.from("aevnetwork_community_moderation_logs").insert({
        target_type: report.target_type, target_id: report.target_id,
        action: remove ? "remove" : "dismiss_report",
        reason: reason || "報告を確認し、対応不要と判断", admin_id: userId
      });
      if (logError) return respond(500, { error: "community_moderation_log_failed" });
      return respond(200, { resolved: true, removed: remove });
    }

    if (action === "friends_overview") {
      const [friendRows,received,sent]=await Promise.all([
        adminClient.from("aevnetwork_friendships").select("id,user_low,user_high,created_at").or(`user_low.eq.${userId},user_high.eq.${userId}`).order("created_at",{ascending:false}),
        adminClient.from("aevnetwork_friend_requests").select("id,sender_id,recipient_id,created_at").eq("recipient_id",userId).eq("status","pending").order("created_at",{ascending:false}),
        adminClient.from("aevnetwork_friend_requests").select("id,sender_id,recipient_id,created_at").eq("sender_id",userId).eq("status","pending").order("created_at",{ascending:false})
      ]);
      if(friendRows.error||received.error||sent.error)return respond(500,{error:"friends_load_failed"});
      const friendIds=(friendRows.data??[]).map((x:any)=>x.user_low===userId?x.user_high:x.user_low);
      const requestIds=[...(received.data??[]).map((x:any)=>x.sender_id),...(sent.data??[]).map((x:any)=>x.recipient_id)];
      const ids=[...new Set([...friendIds,...requestIds])];
      const {data:profiles,error}=ids.length?await adminClient.from("aevtools_profiles").select("user_id,nickname,profile_data").in("user_id",ids):{data:[],error:null};
      if(error)return respond(500,{error:"friends_profiles_load_failed"});
      const map=new Map((profiles??[]).map((p:any)=>[p.user_id,p]));
      const badges=await getBadgeMap(ids);
      const safe=(id:string)=>{const p:any=map.get(id)||{};return {user_id:id,nickname:p.nickname||"ユーザー",profile:p.profile_data||{},...(badges.get(id)||{})};};
      return respond(200,{friends:friendIds.map((id:string)=>safe(id)),received:(received.data??[]).map((x:any)=>({...x,user:safe(x.sender_id)})),sent:(sent.data??[]).map((x:any)=>({...x,user:safe(x.recipient_id)}))});
    }

    if (action === "friends_search") {
      const q=String(body?.query??"").trim().slice(0,40);
      if(q.length<2)return respond(200,{items:[]});
      const {data,error}=await adminClient.from("aevtools_profiles").select("user_id,nickname,profile_data").ilike("nickname",`%${q}%`).neq("user_id",userId).order("nickname",{ascending:true}).limit(30);
      if(error)return respond(500,{error:"friends_search_failed"});
      const [friendRows,requestRows]=await Promise.all([
        adminClient.from("aevnetwork_friendships").select("user_low,user_high").or(`user_low.eq.${userId},user_high.eq.${userId}`),
        adminClient.from("aevnetwork_friend_requests").select("sender_id,recipient_id").eq("status","pending").or(`sender_id.eq.${userId},recipient_id.eq.${userId}`)
      ]);
      if(friendRows.error||requestRows.error)return respond(500,{error:"friends_search_status_failed"});
      const friendSet=new Set((friendRows.data??[]).map((x:any)=>x.user_low===userId?x.user_high:x.user_low));
      const pendingMap=new Map<string,string>();
      for(const x of requestRows.data??[]){const other=x.sender_id===userId?x.recipient_id:x.sender_id;pendingMap.set(other,x.sender_id===userId?"sent":"received");}
      const badges=await getBadgeMap((data??[]).map((p:any)=>p.user_id));
      return respond(200,{items:(data??[]).map((p:any)=>({user_id:p.user_id,nickname:p.nickname||"ユーザー",profile:p.profile_data||{},...(badges.get(p.user_id)||{}),relationship:friendSet.has(p.user_id)?"friend":pendingMap.get(p.user_id)||"none"}))});
    }

    if (action === "profile_public_get") {
      const targetId=String(body?.user_id??"");
      if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetId))return respond(400,{error:"invalid_profile_id"});
      const {data,error}=await adminClient.from("aevtools_profiles").select("user_id,nickname,profile_data,updated_at").eq("user_id",targetId).maybeSingle();
      if(error)return respond(500,{error:"public_profile_load_failed"});
      if(!data)return respond(404,{error:"profile_not_found"});
      const badges=await getBadgeMap([data.user_id]);
      return respond(200,{profile:{user_id:data.user_id,nickname:data.nickname||"ユーザー",profile:data.profile_data||{},...(badges.get(data.user_id)||{}),updated_at:data.updated_at||null}});
    }

    if (action === "friends_request_send") {
      const targetId=String(body?.user_id??"");
      if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetId)||targetId===userId)return respond(400,{error:"invalid_friend_target"});
      const [{data:target},{data:friend}]=await Promise.all([
        adminClient.from("aevtools_profiles").select("user_id").eq("user_id",targetId).maybeSingle(),
        adminClient.from("aevnetwork_friendships").select("id").or(`and(user_low.eq.${userId},user_high.eq.${targetId}),and(user_low.eq.${targetId},user_high.eq.${userId})`).maybeSingle()
      ]);
      if(!target)return respond(404,{error:"friend_user_not_found"});
      if(friend)return respond(409,{error:"already_friends"});
      const {data:reverse}=await adminClient.from("aevnetwork_friend_requests").select("id").eq("sender_id",targetId).eq("recipient_id",userId).eq("status","pending").maybeSingle();
      if(reverse)return respond(409,{error:"friend_request_received"});
      const {error}=await adminClient.from("aevnetwork_friend_requests").insert({sender_id:userId,recipient_id:targetId,status:"pending"});
      if(error)return respond(error.code==="23505"?409:500,{error:error.code==="23505"?"friend_request_exists":"friend_request_send_failed"});
      return respond(200,{sent:true});
    }

    if (action === "friends_request_respond") {
      const requestId=String(body?.request_id??""),decision=String(body?.decision??"");
      if(!requestId||!["accepted","rejected"].includes(decision))return respond(400,{error:"invalid_friend_response"});
      const {data:request,error}=await adminClient.from("aevnetwork_friend_requests").update({status:decision,responded_at:new Date().toISOString()}).eq("id",requestId).eq("recipient_id",userId).eq("status","pending").select("id,sender_id,recipient_id").maybeSingle();
      if(error)return respond(500,{error:"friend_request_update_failed"});
      if(!request)return respond(404,{error:"friend_request_not_found"});
      if(decision==="accepted"){
        const [low,high]=[request.sender_id,request.recipient_id].sort();
        const {error:friendError}=await adminClient.from("aevnetwork_friendships").upsert({user_low:low,user_high:high},{onConflict:"user_low,user_high",ignoreDuplicates:true});
        if(friendError)return respond(500,{error:"friend_accept_failed"});
      }
      return respond(200,{responded:decision});
    }

    if (action === "friends_remove") {
      const targetId=String(body?.user_id??"");
      if(!targetId||targetId===userId)return respond(400,{error:"invalid_friend_target"});
      const [low,high]=[userId,targetId].sort();
      const {error}=await adminClient.from("aevnetwork_friendships").delete().eq("user_low",low).eq("user_high",high);
      if(error)return respond(500,{error:"friend_remove_failed"});
      return respond(200,{removed:true});
    }

    if (action === "profile_get") {
      const { data, error } = await userClient.rpc("aevtools_get_my_profile");
      if (error) return respond(500, { error: "profile_load_failed" });
      const badges=await getBadgeMap([userId]);
      return respond(200, { profile: {...(data||{}),...(badges.get(userId)||{})} });
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
        adminClient.from("aevtools_announcements").select("id", { count: "exact", head: true }),
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
      announcements: "aevtools_announcements",
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
      if (kind === "announcements" && item.video_url !== undefined) {
        const video = String(item.video_url ?? "").trim();
        if (video && !/^https?:\/\//i.test(video)) return respond(400, { error: "invalid_video_url" });
        record.video_url = video || null;
      }
      if (kind === "announcements" || kind === "news") {
        const link = String(item.link_url ?? "").trim();
        if (link && !/^https?:\/\//i.test(link)) return respond(400, { error: "invalid_link" });
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
