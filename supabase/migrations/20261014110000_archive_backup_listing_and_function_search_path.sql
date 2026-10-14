create or replace function public.list_archive_recovery_snapshots()
returns table(
  snapshot_id bigint,
  created_at timestamptz,
  label text,
  snapshot_version text,
  row_counts jsonb,
  restorable boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if auth.uid() is null then
    raise exception 'Authentication required to list archive snapshots';
  end if;

  return query
  select
    s.id,
    s.created_at,
    s.label,
    s.snapshot->>'snapshot_version',
    s.snapshot->'row_counts',
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
  from public.archive_recovery_snapshots s
  order by s.created_at desc, s.id desc;
end;
$function$;

revoke all on function public.list_archive_recovery_snapshots() from public, anon;
grant execute on function public.list_archive_recovery_snapshots() to authenticated, service_role;

alter function public.update_updated_at() set search_path = pg_catalog, public;
alter function public.touch_building_updated_at() set search_path = pg_catalog, public;
