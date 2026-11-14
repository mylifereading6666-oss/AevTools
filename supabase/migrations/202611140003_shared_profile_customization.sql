-- Shared AevTools / AevNetwork profile customization.
-- Adds fields to the existing AevTools profile without replacing account or admin data.
alter table public.aevtools_profiles
  add column if not exists profile_data jsonb not null default '{}'::jsonb,
  add column if not exists nickname_changed_at timestamptz;

create or replace function public.aevtools_profile_json(p_user_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,auth
as $$
declare v_nickname text; v_admin boolean; v_profile jsonb;
begin
 if p_user_id is null then return null; end if;
 select nickname, coalesce(profile_data,'{}'::jsonb)
 into v_nickname,v_profile from public.aevtools_profiles where user_id=p_user_id;
 select exists(select 1 from public.aevtools_admin where user_id=p_user_id) into v_admin;
 if v_nickname is null then
   select case when v_admin then 'Aev0rnJP' else 'ユーザー' || upper(substr(replace(p_user_id::text,'-',''),1,6)) end
   into v_nickname;
 end if;
 return jsonb_build_object(
   'user_id',p_user_id,'nickname',v_nickname,'is_admin',v_admin,
   'role_label',case when v_admin then '👑 管理者 / 🛠 開発者' else null end,
   'profile',v_profile
 );
end;
$$;

create or replace function public.aevtools_update_my_profile(p_nickname text, p_profile jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path=public,auth
as $$
declare
 v_uid uuid:=auth.uid();
 v_name text:=trim(coalesce(p_nickname,''));
 v_old_name text;
 v_changed_at timestamptz;
 v_clean jsonb;
 v_key text;
 v_value text;
begin
 if v_uid is null then raise exception 'login_required'; end if;
 if char_length(v_name) not between 1 and 20 or v_name ~ '[[:cntrl:]]' then
   raise exception 'nickname_length_invalid';
 end if;
 if lower(v_name)='aev0rnjp' and not exists(select 1 from public.aevtools_admin where user_id=v_uid) then
   raise exception 'nickname_reserved';
 end if;
 insert into public.aevtools_profiles(user_id,nickname)
 values(v_uid,case when exists(select 1 from public.aevtools_admin where user_id=v_uid) then 'Aev0rnJP'
                   else 'ユーザー' || upper(substr(replace(v_uid::text,'-',''),1,6)) end)
 on conflict(user_id) do nothing;
 select nickname,nickname_changed_at into v_old_name,v_changed_at
 from public.aevtools_profiles where user_id=v_uid for update;
 if v_name<>v_old_name and v_changed_at is not null and v_changed_at>now()-interval '14 days' then
   raise exception 'nickname_cooldown';
 end if;
 v_clean:=jsonb_build_object(
   'bio',left(coalesce(p_profile->>'bio',''),240),
   'favorite_game',left(coalesce(p_profile->>'favorite_game',''),60),
   'play_style',left(coalesce(p_profile->>'play_style',''),60),
   'avatar_url',left(coalesce(p_profile->>'avatar_url',''),1000),
   'banner_url',left(coalesce(p_profile->>'banner_url',''),1000),
   'accent_color',case when coalesce(p_profile->>'accent_color','') ~ '^#[0-9A-Fa-f]{6}$' then p_profile->>'accent_color' else '#8b7cff' end,
   'theme',case when p_profile->>'theme' in ('midnight','neon','aurora') then p_profile->>'theme' else 'midnight' end,
   'name_color',case when coalesce(p_profile->>'name_color','') ~ '^#[0-9A-Fa-f]{6}$' then p_profile->>'name_color' else '#ffffff' end,
   'name_effect',case when p_profile->>'name_effect' in ('none','glow','gradient','glitch') then p_profile->>'name_effect' else 'glow' end,
   'font_style',case when p_profile->>'font_style' in ('default','serif','mono') then p_profile->>'font_style' else 'default' end
 );
 if (v_clean->>'avatar_url')<>'' and (v_clean->>'avatar_url') !~ '^https://'
   then raise exception 'invalid_avatar_url'; end if;
 if (v_clean->>'banner_url')<>'' and (v_clean->>'banner_url') !~ '^https://'
   then raise exception 'invalid_banner_url'; end if;
 update public.aevtools_profiles
 set nickname=v_name,profile_data=v_clean,updated_at=now(),
     nickname_changed_at=case when v_name<>v_old_name then now() else nickname_changed_at end
 where user_id=v_uid;
 if v_name<>v_old_name then
   update public.aevtools_roulette_participants p set nickname=v_name
   from public.aevtools_roulette_rounds r
   where p.round_id=r.id and p.user_id=v_uid and r.status='open';
   perform public.aevtools_roulette_notify();
 end if;
 return public.aevtools_profile_json(v_uid);
exception when unique_violation then
 raise exception 'nickname_taken';
end;
$$;

create or replace function public.aevtools_update_my_nickname(p_nickname text)
returns jsonb language plpgsql security definer
set search_path=public
as $$
declare v_profile jsonb;
begin
 select coalesce(profile_data,'{}'::jsonb) into v_profile
 from public.aevtools_profiles where user_id=auth.uid();
 return public.aevtools_update_my_profile(p_nickname,coalesce(v_profile,'{}'::jsonb));
end;
$$;

revoke all on function public.aevtools_update_my_profile(text,jsonb) from public;
grant execute on function public.aevtools_update_my_profile(text,jsonb) to authenticated;
revoke all on function public.aevtools_get_my_profile() from public;
grant execute on function public.aevtools_get_my_profile() to authenticated;
revoke all on function public.aevtools_update_my_nickname(text) from public;
grant execute on function public.aevtools_update_my_nickname(text) to authenticated;
