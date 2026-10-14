# DK Armenia — Backup and Recovery

## What is active in Supabase

- A full baseline checkpoint was created on 2026-10-14 before the recovery changes.
- The database now creates a scheduled operational snapshot every day at **02:15 UTC** (06:15 Armenia time).
- The 30 newest snapshots with the `scheduled-daily:` label are retained. Manual and pre-restore checkpoints are not removed by that retention rule.
- Operational snapshots include buildings, photo records, settings, visits, sources, tags, building-tag relations, fieldwork reports, row counts, and a manifest of Storage objects.
- The existing history tables remain in place and continue recording changes. Their full contents are included in the one-time baseline checkpoint, but not duplicated into every daily snapshot to avoid uncontrolled database growth.

## Current checkpoints

- Snapshot #3 — `full-baseline-before-backup-hardening-2026-10-14`: includes 101 buildings, 161 photo records, 13,481 building-history rows, 4 settings, and a manifest of 233 Storage objects.
- Snapshot #4 — `scheduled-daily:2026-10-14T08:47:07Z`: operational snapshot; 101 buildings, 161 photo records, 4 settings, and 233 Storage manifest entries.

## Restore a database snapshot

The authenticated RPC `restore_archive_recovery_snapshot(p_snapshot_id, p_confirmation)` restores the operational database tables from a compatible version 2.0 snapshot.

1. Confirm the exact snapshot ID and its counts.
2. Before restoration, download the current browser JSON backup too.
3. The confirmation argument must exactly match `RESTORE DK ARMENIA <snapshot_id>`.
4. The restore routine creates a pre-restore safety checkpoint inside the same transaction.
5. It restores the operational records and aligns identity sequences. The operation is transactional: an error rolls back the data changes.
6. History tables are retained, so they continue to show the restore activity rather than being overwritten with an older history log.

A rollback rehearsal was run against snapshot #4 inside a transaction and then rolled back. It returned the expected 101 buildings, 161 photo records, and 4 settings; production data was not changed by the rehearsal.

## Important limitation: Storage files

A database snapshot stores the Storage object manifest and photo URLs, **not the binary contents of image files**. The database restore routine does not delete or recreate Storage files. If an image object itself is deleted from Supabase Storage, the database snapshot alone cannot recover that file.

For full disaster recovery, maintain an additional copy of the actual image files outside this Supabase project (for example, a dated local archive copied to a separate drive/cloud location). This is the next protection layer to implement and verify.

## Browser backups

The site's existing `DOWNLOAD FULL BACKUP` export preserves the browser's archive, settings, and workspace data. It does not embed Supabase Storage image binaries. Treat it as an additional layer, not as a replacement for database snapshots or an off-site photo-file backup.

## Safety rule

Do not run a full archive sync or a database restore as an experiment on production. Restore tests must use a separate test database, or a deliberate transaction that is rolled back after verification.
