// Supabase Edge Function: support-email-notify
// Required secrets: RESEND_API_KEY, ADMIN_EMAIL, EMAIL_FROM
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const adminEmail = Deno.env.get("ADMIN_EMAIL");
  const fromEmail = Deno.env.get("EMAIL_FROM");
  if (!supabaseUrl || !serviceKey || !resendKey || !adminEmail || !fromEmail) {
    return json({ error: "email_secrets_missing" }, 500);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "login_required" }, 401);

  const callerClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "invalid_session" }, 401);
  const callerId = userData.user.id;

  let payload: { event?: string; ticket_id?: string };
  try { payload = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }
  if (!["ticket_created", "reply_created"].includes(payload.event ?? "") || !payload.ticket_id) {
    return json({ error: "invalid_request" }, 400);
  }

  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: ticket, error: ticketError } = await db
    .from("aevtools_support_tickets")
    .select("id,user_id,subject,message,category,created_at")
    .eq("id", payload.ticket_id)
    .maybeSingle();
  if (ticketError || !ticket) return json({ error: "ticket_not_found" }, 404);

  const { data: adminRow } = await db.from("aevtools_admin").select("user_id").eq("user_id", callerId).maybeSingle();
  const callerIsAdmin = !!adminRow;
  if (callerId !== ticket.user_id && !callerIsAdmin) return json({ error: "not_allowed" }, 403);

  let toEmail = adminEmail;
  let heading = "AevTools サポートに新しい問い合わせがあります";
  let content = `件名：${ticket.subject}\n種類：${ticket.category}\n\n${ticket.message}`;

  if (payload.event === "reply_created") {
    const { data: latestReply, error: replyError } = await db
      .from("aevtools_support_replies")
      .select("sender_user_id,message,created_at")
      .eq("ticket_id", ticket.id)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (replyError || !latestReply) return json({ error: "reply_not_found" }, 404);

    const { data: senderAdmin } = await db.from("aevtools_admin").select("user_id").eq("user_id", latestReply.sender_user_id).maybeSingle();
    const replyIsAdmin = !!senderAdmin;
    if (latestReply.sender_user_id !== callerId) return json({ error: "reply_sender_mismatch" }, 403);

    if (replyIsAdmin) {
      const { data: ownerData, error: ownerError } = await db.auth.admin.getUserById(ticket.user_id);
      if (ownerError || !ownerData.user?.email) return json({ error: "owner_email_unavailable" }, 500);
      toEmail = ownerData.user.email;
      heading = "AevTools サポートから返信が届きました";
    } else {
      heading = "AevTools サポートにユーザーから返信がありました";
    }
    content = `問い合わせ：${ticket.subject}\n\n返信内容：\n${latestReply.message}`;
  }

  const emailResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: fromEmail,
      to: [toEmail],
      subject: heading,
      text: `${heading}\n\n${content}\n\nAevTools サポートページで会話を確認してください。`,
    }),
  });
  if (!emailResponse.ok) {
    const errorText = await emailResponse.text();
    console.error("Resend error", errorText);
    return json({ error: "email_send_failed" }, 502);
  }
  return json({ ok: true });
});
