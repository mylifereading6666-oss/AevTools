-- AevTools: admin-only permanent deletion of individual chats
-- Deletes the chat row; its messages are deleted automatically by ON DELETE CASCADE.

create or replace function public.aevtools_admin_delete_direct_chat(p_chat_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
     or not exists (
       select 1 from public.aevtools_admin
       where user_id = auth.uid()
     ) then
    raise exception 'admin_required';
  end if;

  if p_chat_id is null then
    raise exception 'invalid_chat_id';
  end if;

  delete from public.aevtools_admin_direct_chats
  where id = p_chat_id;

  if not found then
    raise exception 'chat_not_found';
  end if;

  return true;
end;
$$;

revoke all on function public.aevtools_admin_delete_direct_chat(uuid) from public;
grant execute on function public.aevtools_admin_delete_direct_chat(uuid) to authenticated;
