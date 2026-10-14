create table if not exists public.archive_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  label text not null default 'DK Armenia administrator',
  created_at timestamptz not null default now()
);
alter table public.archive_admins enable row level security;
revoke all on table public.archive_admins from public, anon, authenticated, service_role;
grant all on table public.archive_admins to postgres;

insert into public.archive_admins(user_id, label)
select u.id, 'Primary DK Armenia administrator'
from auth.users u order by u.created_at asc limit 1
on conflict (user_id) do nothing;

create or replace function public.assert_archive_admin()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.archive_admins a where a.user_id = auth.uid()
  ) then
    raise exception 'Archive administrator access required';
  end if;
end;
$function$;
revoke all on function public.assert_archive_admin() from public, anon, authenticated, service_role;
grant execute on function public.assert_archive_admin() to postgres;

create or replace function public.create_archive_recovery_snapshot(p_reason text default 'before-cloud-sync')
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  perform public.assert_archive_admin();
  return public.create_archive_recovery_snapshot_internal(coalesce(nullif(p_reason, ''), 'before-cloud-sync'));
end;
$function$;
revoke all on function public.create_archive_recovery_snapshot(text) from public, anon;
grant execute on function public.create_archive_recovery_snapshot(text) to authenticated, service_role;

create or replace function public.list_archive_recovery_snapshots()
returns table(snapshot_id bigint, created_at timestamptz, label text, snapshot_version text, row_counts jsonb, restorable boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  perform public.assert_archive_admin();
  return query
  select s.id, s.created_at, s.label, s.snapshot->>'snapshot_version', s.snapshot->'row_counts',
    (
      s.snapshot->>'snapshot_version' = '2.0'
      and jsonb_typeof(s.snapshot->'buildings') = 'array'
      and jsonb_typeof(s.snapshot->'photos') = 'array'
      and jsonb_typeof(s.snapshot->'settings') = 'array'
      and jsonb_typeof(s.snapshot->'visits') = 'array'
      and jsonb_typeof(s.snapshot->'sources') = 'array'
      and jsonb_typeof(s.snapshot->'tags') = 'array'
      and jsonb_typeof(s.snapshot->'building_tags') = 'array'
      and jsonb_typeof(s.snapshot->'fieldwork_reports') = 'array'
    ) as restorable
  from public.archive_recovery_snapshots s order by s.created_at desc, s.id desc;
end;
$function$;
revoke all on function public.list_archive_recovery_snapshots() from public, anon;
grant execute on function public.list_archive_recovery_snapshots() to authenticated, service_role;

create or replace function public.repair_buildings_sequence()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare seq_name text; max_id bigint;
begin
  perform public.assert_archive_admin();
  select pg_get_serial_sequence('public.buildings', 'id') into seq_name;
  select coalesce(max(id), 0) into max_id from public.buildings;
  if seq_name is not null and max_id > 0 then perform setval(seq_name::regclass, max_id, true); end if;
end;
$function$;
revoke all on function public.repair_buildings_sequence() from public, anon;
grant execute on function public.repair_buildings_sequence() to authenticated, service_role;

-- The restore function is redefined to call assert_archive_admin() before any write.
-- Keep its transaction, typed confirmation, pre-restore checkpoint, dependency ordering,
-- sequence alignment, and Storage-binary limitation from the prior migration.
create or replace function public.restore_archive_recovery_snapshot(p_snapshot_id bigint, p_confirmation text)
returns jsonb
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $function$
declare
  v_snapshot jsonb;
  v_safety_snapshot_id bigint;
  v_buildings integer; v_photos integer; v_settings integer; v_visits integer;
  v_sources integer; v_tags integer; v_building_tags integer; v_fieldwork_reports integer;
begin
  perform public.assert_archive_admin();
  if p_confirmation is distinct from ('RESTORE DK ARMENIA ' || p_snapshot_id::text) then
    raise exception 'Confirmation text did not match. Expected: RESTORE DK ARMENIA %', p_snapshot_id;
  end if;
  select s.snapshot into v_snapshot from public.archive_recovery_snapshots s where s.id = p_snapshot_id;
  if v_snapshot is null then raise exception 'Archive snapshot % was not found', p_snapshot_id; end if;
  if v_snapshot->>'snapshot_version' is distinct from '2.0' then
    raise exception 'This snapshot is not a complete version 2.0 operational snapshot and cannot be restored by this function';
  end if;
  if jsonb_typeof(v_snapshot->'buildings') is distinct from 'array'
     or jsonb_typeof(v_snapshot->'photos') is distinct from 'array'
     or jsonb_typeof(v_snapshot->'settings') is distinct from 'array'
     or jsonb_typeof(v_snapshot->'visits') is distinct from 'array'
     or jsonb_typeof(v_snapshot->'sources') is distinct from 'array'
     or jsonb_typeof(v_snapshot->'tags') is distinct from 'array'
     or jsonb_typeof(v_snapshot->'building_tags') is distinct from 'array'
     or jsonb_typeof(v_snapshot->'fieldwork_reports') is distinct from 'array' then
    raise exception 'Snapshot is missing one or more required operational data sections';
  end if;
  v_safety_snapshot_id := public.create_archive_recovery_snapshot_internal(
    'before-restore-of-' || p_snapshot_id::text || ':' || to_char(timezone('utc', now()), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );
  delete from public.fieldwork_reports;
  delete from public.visits;
  delete from public.sources;
  delete from public.building_tags;
  delete from public.photos;
  delete from public.buildings;
  delete from public.tags;
  delete from public.settings;
  insert into public.buildings select * from jsonb_populate_recordset(null::public.buildings, v_snapshot->'buildings');
  insert into public.tags select * from jsonb_populate_recordset(null::public.tags, v_snapshot->'tags');
  insert into public.photos select * from jsonb_populate_recordset(null::public.photos, v_snapshot->'photos');
  insert into public.visits select * from jsonb_populate_recordset(null::public.visits, v_snapshot->'visits');
  insert into public.sources select * from jsonb_populate_recordset(null::public.sources, v_snapshot->'sources');
  insert into public.building_tags select * from jsonb_populate_recordset(null::public.building_tags, v_snapshot->'building_tags');
  insert into public.fieldwork_reports select * from jsonb_populate_recordset(null::public.fieldwork_reports, v_snapshot->'fieldwork_reports');
  insert into public.settings select * from jsonb_populate_recordset(null::public.settings, v_snapshot->'settings');
  perform setval(pg_get_serial_sequence('public.buildings', 'id'), coalesce((select max(id) from public.buildings), 1), (select max(id) is not null from public.buildings));
  perform setval(pg_get_serial_sequence('public.photos', 'id'), coalesce((select max(id) from public.photos), 1), (select max(id) is not null from public.photos));
  perform setval(pg_get_serial_sequence('public.settings', 'id'), coalesce((select max(id) from public.settings), 1), (select max(id) is not null from public.settings));
  perform setval(pg_get_serial_sequence('public.visits', 'id'), coalesce((select max(id) from public.visits), 1), (select max(id) is not null from public.visits));
  perform setval(pg_get_serial_sequence('public.sources', 'id'), coalesce((select max(id) from public.sources), 1), (select max(id) is not null from public.sources));
  perform setval(pg_get_serial_sequence('public.tags', 'id'), coalesce((select max(id) from public.tags), 1), (select max(id) is not null from public.tags));
  select count(*) into v_buildings from public.buildings;
  select count(*) into v_photos from public.photos;
  select count(*) into v_settings from public.settings;
  select count(*) into v_visits from public.visits;
  select count(*) into v_sources from public.sources;
  select count(*) into v_tags from public.tags;
  select count(*) into v_building_tags from public.building_tags;
  select count(*) into v_fieldwork_reports from public.fieldwork_reports;
  return jsonb_build_object(
    'restored_snapshot_id', p_snapshot_id, 'safety_snapshot_id', v_safety_snapshot_id,
    'buildings', v_buildings, 'photos', v_photos, 'settings', v_settings,
    'visits', v_visits, 'sources', v_sources, 'tags', v_tags,
    'building_tags', v_building_tags, 'fieldwork_reports', v_fieldwork_reports,
    'storage_files_restored', false,
    'storage_note', 'Storage object binaries are not stored in database snapshots; this restore preserves existing Storage files but cannot recreate files deleted from Storage.'
  );
end;
$function$;
revoke all on function public.restore_archive_recovery_snapshot(bigint, text) from public, anon;
grant execute on function public.restore_archive_recovery_snapshot(bigint, text) to authenticated, service_role;
