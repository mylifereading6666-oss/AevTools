-- AevNetwork per-user relational data snapshots and safe restore.
-- Does not snapshot or restore admin registries, blacklists, service controls, or invite-code hashes.

create or replace function public.aevnetwork_capture_user_snapshot(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data jsonb;
begin
  if p_user_id is null then
    return;
  end if;

  v_data := jsonb_build_object(
    'user_data', coalesce((select d.data from public.aevnetwork_user_data d where d.user_id = p_user_id), '{}'::jsonb),
    'profile', coalesce((select to_jsonb(p) from public.aevtools_profiles p where p.user_id = p_user_id), '{}'::jsonb),
    'teams', coalesce((select jsonb_agg(to_jsonb(t) - 'invite_code_hash' - 'invite_code_updated_at') from public.aevnetwork_teams t where t.owner_id = p_user_id), '[]'::jsonb),
    'team_members', coalesce((select jsonb_agg(to_jsonb(m)) from public.aevnetwork_team_members m where m.user_id = p_user_id), '[]'::jsonb),
    'team_messages', coalesce((
      select jsonb_agg(to_jsonb(m)) from public.aevnetwork_team_messages m
      where m.user_id = p_user_id
         or m.team_id in (select tm.team_id from public.aevnetwork_team_members tm where tm.user_id = p_user_id)
    ), '[]'::jsonb),
    'team_chat_preferences', coalesce((select jsonb_agg(to_jsonb(p)) from public.aevnetwork_team_chat_preferences p where p.user_id = p_user_id), '[]'::jsonb),
    'team_mediation_requests', coalesce((select jsonb_agg(to_jsonb(r)) from public.aevnetwork_team_mediation_requests r where r.requester_id = p_user_id), '[]'::jsonb),
    'friend_requests', coalesce((select jsonb_agg(to_jsonb(r)) from public.aevnetwork_friend_requests r where r.sender_id = p_user_id or r.recipient_id = p_user_id), '[]'::jsonb),
    'friendships', coalesce((select jsonb_agg(to_jsonb(f)) from public.aevnetwork_friendships f where f.user_low = p_user_id or f.user_high = p_user_id), '[]'::jsonb),
    'community_posts', coalesce((select jsonb_agg(to_jsonb(p)) from public.aevnetwork_community_posts p where p.author_id = p_user_id), '[]'::jsonb),
    'community_comments', coalesce((select jsonb_agg(to_jsonb(c)) from public.aevnetwork_community_comments c where c.author_id = p_user_id), '[]'::jsonb),
    'community_deletion_notices', coalesce((select jsonb_agg(to_jsonb(n)) from public.aevnetwork_community_deletion_notices n where n.user_id = p_user_id), '[]'::jsonb),
    'community_reports', coalesce((select jsonb_agg(to_jsonb(r)) from public.aevnetwork_community_reports r where r.reporter_id = p_user_id), '[]'::jsonb)
  );

  insert into public.aev_user_data_snapshots(user_id, app_key, data, source_updated_at, captured_at)
  values (p_user_id, 'aevnetwork', v_data, now(), now())
  on conflict (user_id, app_key) do update
    set data = excluded.data,
        source_updated_at = excluded.source_updated_at,
        captured_at = excluded.captured_at;
end;
$$;

create or replace function public.aevnetwork_refresh_snapshot_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team_id uuid;
  v_uid uuid;
begin
  if not coalesce((select maintenance_enabled from public.aevtools_service_control where singleton = true), false) then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  if tg_table_name = 'aevnetwork_teams' then
    v_team_id := case when tg_op = 'DELETE' then old.id else new.id end;
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.owner_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.owner_id); end if;
    for v_uid in
      select user_id from public.aevnetwork_team_members where team_id = v_team_id
    loop perform public.aevnetwork_capture_user_snapshot(v_uid); end loop;

  elsif tg_table_name = 'aevnetwork_team_members' then
    v_team_id := case when tg_op = 'DELETE' then old.team_id else new.team_id end;
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.user_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.user_id); end if;
    for v_uid in
      select owner_id from public.aevnetwork_teams where id = v_team_id
      union
      select user_id from public.aevnetwork_team_members where team_id = v_team_id
    loop perform public.aevnetwork_capture_user_snapshot(v_uid); end loop;

  elsif tg_table_name = 'aevnetwork_team_messages' then
    v_team_id := case when tg_op = 'DELETE' then old.team_id else new.team_id end;
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.user_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.user_id); end if;
    for v_uid in select user_id from public.aevnetwork_team_members where team_id = v_team_id
    loop perform public.aevnetwork_capture_user_snapshot(v_uid); end loop;

  elsif tg_table_name = 'aevnetwork_team_chat_preferences' then
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.user_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.user_id); end if;

  elsif tg_table_name = 'aevnetwork_team_mediation_requests' then
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.requester_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.requester_id); end if;

  elsif tg_table_name = 'aevnetwork_friend_requests' then
    if tg_op <> 'DELETE' then
      perform public.aevnetwork_capture_user_snapshot(new.sender_id);
      perform public.aevnetwork_capture_user_snapshot(new.recipient_id);
    end if;
    if tg_op <> 'INSERT' then
      perform public.aevnetwork_capture_user_snapshot(old.sender_id);
      perform public.aevnetwork_capture_user_snapshot(old.recipient_id);
    end if;

  elsif tg_table_name = 'aevnetwork_friendships' then
    if tg_op <> 'DELETE' then
      perform public.aevnetwork_capture_user_snapshot(new.user_low);
      perform public.aevnetwork_capture_user_snapshot(new.user_high);
    end if;
    if tg_op <> 'INSERT' then
      perform public.aevnetwork_capture_user_snapshot(old.user_low);
      perform public.aevnetwork_capture_user_snapshot(old.user_high);
    end if;

  elsif tg_table_name in ('aevnetwork_community_posts','aevnetwork_community_comments') then
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.author_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.author_id); end if;

  elsif tg_table_name = 'aevnetwork_community_deletion_notices' then
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.user_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.user_id); end if;

  elsif tg_table_name = 'aevnetwork_community_reports' then
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.reporter_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.reporter_id); end if;

  elsif tg_table_name = 'aevtools_profiles' or tg_table_name = 'aevnetwork_user_data' then
    if tg_op <> 'DELETE' then perform public.aevnetwork_capture_user_snapshot(new.user_id); end if;
    if tg_op <> 'INSERT' then perform public.aevnetwork_capture_user_snapshot(old.user_id); end if;
  end if;

  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

-- Replace the earlier raw-JSON trigger so the structured Network snapshot is preserved.
drop trigger if exists aevnetwork_snapshot_user_data on public.aevnetwork_user_data;
create trigger aevnetwork_snapshot_user_data after insert or update or delete on public.aevnetwork_user_data
for each row execute function public.aevnetwork_refresh_snapshot_trigger();

drop trigger if exists aevnetwork_snapshot_teams on public.aevnetwork_teams;
create trigger aevnetwork_snapshot_teams after insert or update or delete on public.aevnetwork_teams
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_team_members on public.aevnetwork_team_members;
create trigger aevnetwork_snapshot_team_members after insert or update or delete on public.aevnetwork_team_members
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_team_messages on public.aevnetwork_team_messages;
create trigger aevnetwork_snapshot_team_messages after insert or update or delete on public.aevnetwork_team_messages
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_team_chat_preferences on public.aevnetwork_team_chat_preferences;
create trigger aevnetwork_snapshot_team_chat_preferences after insert or update or delete on public.aevnetwork_team_chat_preferences
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_team_mediation on public.aevnetwork_team_mediation_requests;
create trigger aevnetwork_snapshot_team_mediation after insert or update or delete on public.aevnetwork_team_mediation_requests
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_friend_requests on public.aevnetwork_friend_requests;
create trigger aevnetwork_snapshot_friend_requests after insert or update or delete on public.aevnetwork_friend_requests
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_friendships on public.aevnetwork_friendships;
create trigger aevnetwork_snapshot_friendships after insert or update or delete on public.aevnetwork_friendships
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_community_posts on public.aevnetwork_community_posts;
create trigger aevnetwork_snapshot_community_posts after insert or update or delete on public.aevnetwork_community_posts
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_community_comments on public.aevnetwork_community_comments;
create trigger aevnetwork_snapshot_community_comments after insert or update or delete on public.aevnetwork_community_comments
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_deletion_notices on public.aevnetwork_community_deletion_notices;
create trigger aevnetwork_snapshot_deletion_notices after insert or update or delete on public.aevnetwork_community_deletion_notices
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_community_reports on public.aevnetwork_community_reports;
create trigger aevnetwork_snapshot_community_reports after insert or update or delete on public.aevnetwork_community_reports
for each row execute function public.aevnetwork_refresh_snapshot_trigger();
drop trigger if exists aevnetwork_snapshot_profiles on public.aevtools_profiles;
create trigger aevnetwork_snapshot_profiles after insert or update or delete on public.aevtools_profiles
for each row execute function public.aevnetwork_refresh_snapshot_trigger();

create or replace function public.aevtools_capture_maintenance_snapshots()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  tools_count integer := 0;
  network_count integer := 0;
  v_user_id uuid;
begin
  insert into public.aev_user_data_snapshots(user_id, app_key, data, source_updated_at, captured_at)
  select user_id, 'aevtools', data, updated_at, now()
  from public.aevtools_user_data
  on conflict (user_id, app_key) do update
    set data = excluded.data,
        source_updated_at = excluded.source_updated_at,
        captured_at = excluded.captured_at;
  get diagnostics tools_count = row_count;

  for v_user_id in select id from auth.users loop
    perform public.aevnetwork_capture_user_snapshot(v_user_id);
    network_count := network_count + 1;
  end loop;

  return jsonb_build_object('aevtools_users', tools_count, 'aevnetwork_users', network_count);
end;
$$;

create or replace function public.aevnetwork_restore_user_snapshot(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data jsonb;
  v_row public.aevnetwork_teams%rowtype;
  v_member public.aevnetwork_team_members%rowtype;
  v_count integer := 0;
  v_total integer := 0;
begin
  if p_user_id is null then raise exception 'user_required'; end if;
  if coalesce((select maintenance_enabled from public.aevtools_service_control where singleton = true), false) then
    raise exception 'service_maintenance';
  end if;

  select data into v_data from public.aev_user_data_snapshots
  where user_id = p_user_id and app_key = 'aevnetwork'
  for update;
  if not found then return jsonb_build_object('restored', false, 'reason', 'snapshot_not_found'); end if;

  -- Restore only the caller's own account blob; current cloud keys win on conflicts.
  insert into public.aevnetwork_user_data(user_id, data, updated_at)
  values (p_user_id, coalesce(v_data->'user_data','{}'::jsonb), now())
  on conflict (user_id) do update
    set data = excluded.data || public.aevnetwork_user_data.data,
        updated_at = now();
  get diagnostics v_count = row_count;
  v_total := v_total + v_count;

  -- Restore owned teams first. Invite codes are intentionally not restored.
  for v_row in
    select * from jsonb_populate_recordset(null::public.aevnetwork_teams, coalesce(v_data->'teams','[]'::jsonb))
  loop
    insert into public.aevnetwork_teams
    (id,name,description,game,owner_id,created_at)
    values (v_row.id,v_row.name,v_row.description,v_row.game,v_row.owner_id,v_row.created_at)
    on conflict (id) do nothing;
    get diagnostics v_count = row_count;
    v_total := v_total + v_count;
  end loop;

  -- Restore this user's memberships without exceeding the four-member team limit.
  for v_member in
    select * from jsonb_populate_recordset(null::public.aevnetwork_team_members, coalesce(v_data->'team_members','[]'::jsonb))
  loop
    if v_member.user_id = p_user_id
       and exists(select 1 from public.aevnetwork_teams where id = v_member.team_id)
       and not exists(select 1 from public.aevnetwork_team_members where team_id=v_member.team_id and user_id=p_user_id)
       and (v_member.status <> 'approved' or
            (select count(*) from public.aevnetwork_team_members where team_id=v_member.team_id and status='approved') < 4) then
      insert into public.aevnetwork_team_members
      (id,team_id,user_id,role,status,created_at,reviewed_at)
      values (v_member.id,v_member.team_id,v_member.user_id,v_member.role,v_member.status,v_member.created_at,v_member.reviewed_at)
      on conflict do nothing;
      get diagnostics v_count = row_count;
      v_total := v_total + v_count;
    end if;
  end loop;

  insert into public.aevnetwork_team_messages
  select * from jsonb_populate_recordset(null::public.aevnetwork_team_messages, coalesce(v_data->'team_messages','[]'::jsonb)) x
  where exists(select 1 from public.aevnetwork_teams t where t.id=x.team_id)
  on conflict (id) do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_team_chat_preferences
  select * from jsonb_populate_recordset(null::public.aevnetwork_team_chat_preferences, coalesce(v_data->'team_chat_preferences','[]'::jsonb)) x
  where x.user_id=p_user_id and exists(select 1 from public.aevnetwork_teams t where t.id=x.team_id)
  on conflict (team_id,user_id) do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_team_mediation_requests
  select * from jsonb_populate_recordset(null::public.aevnetwork_team_mediation_requests, coalesce(v_data->'team_mediation_requests','[]'::jsonb)) x
  where x.requester_id=p_user_id and exists(select 1 from public.aevnetwork_teams t where t.id=x.team_id)
  on conflict (id) do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_friend_requests
  select * from jsonb_populate_recordset(null::public.aevnetwork_friend_requests, coalesce(v_data->'friend_requests','[]'::jsonb)) x
  where (x.sender_id=p_user_id or x.recipient_id=p_user_id)
    and exists(select 1 from auth.users u where u.id=x.sender_id)
    and exists(select 1 from auth.users u where u.id=x.recipient_id)
  on conflict do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_friendships
  select * from jsonb_populate_recordset(null::public.aevnetwork_friendships, coalesce(v_data->'friendships','[]'::jsonb)) x
  where (x.user_low=p_user_id or x.user_high=p_user_id)
    and exists(select 1 from auth.users u where u.id=x.user_low)
    and exists(select 1 from auth.users u where u.id=x.user_high)
  on conflict (user_low,user_high) do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_community_posts
  select * from jsonb_populate_recordset(null::public.aevnetwork_community_posts, coalesce(v_data->'community_posts','[]'::jsonb)) x
  where x.author_id=p_user_id
  on conflict (id) do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_community_comments
  select * from jsonb_populate_recordset(null::public.aevnetwork_community_comments, coalesce(v_data->'community_comments','[]'::jsonb)) x
  where x.author_id=p_user_id and exists(select 1 from public.aevnetwork_community_posts p where p.id=x.post_id)
  on conflict (id) do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_community_deletion_notices
  select * from jsonb_populate_recordset(null::public.aevnetwork_community_deletion_notices, coalesce(v_data->'community_deletion_notices','[]'::jsonb)) x
  where x.user_id=p_user_id
  on conflict (id) do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  insert into public.aevnetwork_community_reports
  select * from jsonb_populate_recordset(null::public.aevnetwork_community_reports, coalesce(v_data->'community_reports','[]'::jsonb)) x
  where x.reporter_id=p_user_id
  on conflict do nothing;
  get diagnostics v_count = row_count; v_total := v_total + v_count;

  -- Restore profile appearance data only; never restore roles or administrator state.
  if jsonb_typeof(v_data->'profile') = 'object' and v_data->'profile' <> '{}'::jsonb then
    update public.aevtools_profiles
    set profile_data = coalesce(v_data->'profile'->'profile_data','{}'::jsonb) || coalesce(profile_data,'{}'::jsonb)
    where user_id=p_user_id;
  end if;

  delete from public.aev_user_data_snapshots where user_id=p_user_id and app_key='aevnetwork';
  return jsonb_build_object('restored', true, 'rows_restored', v_total);
end;
$$;

revoke all on function public.aevnetwork_capture_user_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.aevnetwork_refresh_snapshot_trigger() from public, anon, authenticated;
revoke all on function public.aevnetwork_restore_user_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.aevnetwork_capture_user_snapshot(uuid) to service_role;
grant execute on function public.aevnetwork_restore_user_snapshot(uuid) to service_role;
