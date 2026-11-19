-- Public favorite achievement tags shared by AevTools and AevNetwork.
-- The list is owner-managed, limited to three, and restricted to earned achievement IDs.

create or replace function public.aevtools_preserve_favorite_achievement_tags()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if old.profile_data ? 'favorite_achievement_tags'
     and not (coalesce(new.profile_data, '{}'::jsonb) ? 'favorite_achievement_tags') then
    new.profile_data := coalesce(new.profile_data, '{}'::jsonb)
      || jsonb_build_object('favorite_achievement_tags', old.profile_data->'favorite_achievement_tags');
  end if;
  return new;
end;
$$;

drop trigger if exists aevtools_preserve_favorite_achievement_tags
  on public.aevtools_profiles;
create trigger aevtools_preserve_favorite_achievement_tags
before update of profile_data on public.aevtools_profiles
for each row execute function public.aevtools_preserve_favorite_achievement_tags();

create or replace function public.aevtools_update_my_favorite_achievement_tags(p_tags jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,auth
as $$
declare
  v_uid uuid := auth.uid();
  v_requested jsonb := case when jsonb_typeof(p_tags)='array' then p_tags else '[]'::jsonb end;
  v_earned jsonb := '[]'::jsonb;
  v_clean jsonb := '[]'::jsonb;
  v_raw text;
begin
  if v_uid is null then raise exception 'login_required'; end if;
  if jsonb_array_length(v_requested) > 3 then
    raise exception 'favorite_achievement_limit';
  end if;

  select data->'storage'->>'aev_secret_achievements'
    into v_raw
    from public.aevtools_user_data
    where user_id=v_uid;

  if coalesce(v_raw,'') <> '' then
    begin
      v_earned := v_raw::jsonb;
      if jsonb_typeof(v_earned) <> 'array' then v_earned := '[]'::jsonb; end if;
    exception when others then
      v_earned := '[]'::jsonb;
    end;
  end if;

  select coalesce(jsonb_agg(to_jsonb(x.id)), '[]'::jsonb)
    into v_clean
    from (
      select distinct f.value as id
      from jsonb_array_elements_text(v_requested) as f(value)
      where f.value in (
        'secret-discoverer','home-explorer','about-explorer','focus-explorer',
        'unlock-glitch','unlock-neon','night-explorer','youtube-supporter'
      )
      and exists (
        select 1 from jsonb_array_elements(v_earned) as e(item)
        where e.item->>'id'=f.value
      )
      limit 3
    ) as x;

  update public.aevtools_profiles
    set profile_data=jsonb_set(coalesce(profile_data,'{}'::jsonb),
      '{favorite_achievement_tags}',v_clean,true),
      updated_at=now()
    where user_id=v_uid;

  if not found then raise exception 'profile_not_found'; end if;
  return public.aevtools_profile_json(v_uid);
end;
$$;

revoke all on function public.aevtools_update_my_favorite_achievement_tags(jsonb) from public;
grant execute on function public.aevtools_update_my_favorite_achievement_tags(jsonb) to authenticated;
