-- Private bucket for published disguise GLBs. Only the API reads and writes it, with the
-- server-side secret key. No storage.objects policies are created, so publishable/anon and
-- signed-in client keys cannot list, read or write these files.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rally-disguises', 'rally-disguises', false, 20971520, array['model/gltf-binary'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
