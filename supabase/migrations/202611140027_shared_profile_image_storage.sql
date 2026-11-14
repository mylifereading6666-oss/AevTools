-- Shared public profile image storage for AevTools and AevNetwork.
-- Uploads are restricted to the authenticated user's own UUID folder.
-- Public read is intentional so profile images can be viewed by all visitors.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('aev-profile-images','aev-profile-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public=true,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "Aev profile images public read" on storage.objects;
create policy "Aev profile images public read" on storage.objects for select to public using (bucket_id='aev-profile-images');
drop policy if exists "Aev profile images owner insert" on storage.objects;
create policy "Aev profile images owner insert" on storage.objects for insert to authenticated with check (bucket_id='aev-profile-images' and split_part(name,'/',1)=auth.uid()::text);
drop policy if exists "Aev profile images owner update" on storage.objects;
create policy "Aev profile images owner update" on storage.objects for update to authenticated using (bucket_id='aev-profile-images' and split_part(name,'/',1)=auth.uid()::text) with check (bucket_id='aev-profile-images' and split_part(name,'/',1)=auth.uid()::text);
drop policy if exists "Aev profile images owner delete" on storage.objects;
create policy "Aev profile images owner delete" on storage.objects for delete to authenticated using (bucket_id='aev-profile-images' and split_part(name,'/',1)=auth.uid()::text);
