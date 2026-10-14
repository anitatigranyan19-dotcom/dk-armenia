-- DK Armenia: layered archive recovery.
-- Additive and idempotent where practical. Does not delete current archive data.
-- Daily snapshots include operational records and a Storage manifest; binary files
-- themselves must be backed up separately outside the database.

create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.create_archive_recovery_snapshot_internal(p_reason text)
returns bigint
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $function$
declare
  new_snapshot_id bigint;
begin
  insert into public.archive_recovery_snapshots(label, snapshot)
  values (
    coalesce(nullif(p_reason, ''), 'manual'),
    jsonb_build_object(
      'snapshot_version', '2.0',
      'captured_at', now(),
      'row_counts', jsonb_build_object(
        'buildings', (select count(*) from public.buildings),
        'photos', (select count(*) from public.photos),
        'settings', (select count(*) from public.settings),
        'visits', (select count(*) from public.visits),
        'sources', (select count(*) from public.sources),
        'tags', (select count(*) from public.tags),
        'building_tags', (select count(*) from public.building_tags),
        'fieldwork_reports', (select count(*) from public.fieldwork_reports),
        'building_history', (select count(*) from public.building_history),
        'photo_recovery_history', (select count(*) from public.photo_recovery_history),
        'settings_recovery_history', (select count(*) from public.settings_recovery_history),
        'storage_objects', (select count(*) from storage.objects where bucket_id = 'archive-photos')
      ),
      'buildings', coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.buildings t), '[]'::jsonb),
      'photos', coalesce((select jsonb_agg(to_jsonb(t) order by t.building_id, t.sort_order, t.id) from public.photos t), '[]'::jsonb),
      'settings', coalesce((select jsonb_agg(to_jsonb(t) order by t.key) from public.settings t), '[]'::jsonb),
      'visits', coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.visits t), '[]'::jsonb),
      'sources', coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.sources t), '[]'::jsonb),
      'tags', coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.tags t), '[]'::jsonb),
      'building_tags', coalesce((select jsonb_agg(to_jsonb(t) order by t.building_id, t.tag_id) from public.building_tags t), '[]'::jsonb),
      'fieldwork_reports', coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.fieldwork_reports t), '[]'::jsonb),
      'storage_objects', coalesce((
        select jsonb_agg(jsonb_build_object(
          'bucket_id', o.bucket_id,
          'name', o.name,
          'owner_id', o.owner_id,
          'metadata', o.metadata,
          'created_at', o.created_at,
          'updated_at', o.updated_at,
          'last_accessed_at', o.last_accessed_at
        ) order by o.bucket_id, o.name)
        from storage.objects o
        where o.bucket_id = 'archive-photos'
      ), '[]'::jsonb)
    )
  )
  returning id into new_snapshot_id;

  return new_snapshot_id;
end;
$function$;

create or replace function public.create_archive_recovery_snapshot(p_reason text default 'before-cloud-sync')
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'Authentication required to create an archive snapshot';
  end if;

  return public.create_archive_recovery_snapshot_internal(
    coalesce(nullif(p_reason, ''), 'before-cloud-sync')
  );
end;
$function$;

create or replace function public.run_dk_armenia_daily_backup()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  new_snapshot_id bigint;
begin
  new_snapshot_id := public.create_archive_recovery_snapshot_internal(
    'scheduled-daily:' || to_char(timezone('utc', now()), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  -- Keep the 30 newest automatic snapshots. Manual and pre-restore checkpoints are retained.
  delete from public.archive_recovery_snapshots
  where label like 'scheduled-daily:%'
    and id not in (
      select id
      from public.archive_recovery_snapshots
      where label like 'scheduled-daily:%'
      order by created_at desc, id desc
      limit 30
    );

  return new_snapshot_id;
end;
$function$;

create or replace function public.restore_archive_recovery_snapshot(
  p_snapshot_id bigint,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $function$
declare
  v_snapshot jsonb;
  v_safety_snapshot_id bigint;
  v_buildings integer;
  v_photos integer;
  v_settings integer;
  v_visits integer;
  v_sources integer;
  v_tags integer;
  v_building_tags integer;
  v_fieldwork_reports integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required to restore an archive snapshot';
  end if;

  if p_confirmation is distinct from ('RESTORE DK ARMENIA ' || p_snapshot_id::text) then
    raise exception 'Confirmation text did not match. Expected: RESTORE DK ARMENIA %', p_snapshot_id;
  end if;

  select s.snapshot into v_snapshot
  from public.archive_recovery_snapshots s
  where s.id = p_snapshot_id;

  if v_snapshot is null then
    raise exception 'Archive snapshot % was not found', p_snapshot_id;
  end if;

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

  -- This checkpoint is created in the same transaction. If restoration fails,
  -- PostgreSQL rolls the entire operation back and leaves the current state intact.
  v_safety_snapshot_id := public.create_archive_recovery_snapshot_internal(
    'before-restore-of-' || p_snapshot_id::text || ':' || to_char(timezone('utc', now()), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  );

  -- Remove dependent rows first. The history tables remain intact and record the restore activity.
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

  -- Align identity sequences after restoring explicit IDs.
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
    'restored_snapshot_id', p_snapshot_id,
    'safety_snapshot_id', v_safety_snapshot_id,
    'buildings', v_buildings,
    'photos', v_photos,
    'settings', v_settings,
    'visits', v_visits,
    'sources', v_sources,
    'tags', v_tags,
    'building_tags', v_building_tags,
    'fieldwork_reports', v_fieldwork_reports,
    'storage_files_restored', false,
    'storage_note', 'Storage object binaries are not stored in database snapshots; this restore preserves existing Storage files but cannot recreate files deleted from Storage.'
  );
end;
$function$;

-- Trigger-only helpers must not be callable as public RPC endpoints.
revoke all on function public.archive_photo_before_change() from public, anon, authenticated;
revoke all on function public.archive_setting_before_change() from public, anon, authenticated;
revoke all on function public.log_building_history() from public, anon, authenticated;

-- The app uses this RPC after an explicit full sync, so keep it for signed-in users only.
revoke all on function public.repair_buildings_sequence() from public, anon;
grant execute on function public.repair_buildings_sequence() to authenticated, service_role;

revoke all on function public.create_archive_recovery_snapshot_internal(text) from public, anon, authenticated;
grant execute on function public.create_archive_recovery_snapshot_internal(text) to postgres;

revoke all on function public.create_archive_recovery_snapshot(text) from public, anon;
grant execute on function public.create_archive_recovery_snapshot(text) to authenticated, service_role;

revoke all on function public.run_dk_armenia_daily_backup() from public, anon, authenticated;
grant execute on function public.run_dk_armenia_daily_backup() to postgres;

revoke all on function public.restore_archive_recovery_snapshot(bigint, text) from public, anon;
grant execute on function public.restore_archive_recovery_snapshot(bigint, text) to authenticated, service_role;

-- Replace only this named job; unrelated cron jobs are untouched.
do $cron_setup$
declare
  existing_job record;
begin
  for existing_job in
    select jobid from cron.job where jobname = 'dk-armenia-daily-backup'
  loop
    perform cron.unschedule(existing_job.jobid);
  end loop;

  perform cron.schedule(
    'dk-armenia-daily-backup',
    '15 2 * * *',
    'select public.run_dk_armenia_daily_backup();'
  );
end;
$cron_setup$;
