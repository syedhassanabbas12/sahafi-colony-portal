# Backups

Daily automated snapshots of the Sahafi Colony Portal's Supabase tables
(`users`, `residents`, `collections`, `expenses`), committed here by
`.github/workflows/backup-supabase.yml` (on `main`). Every run adds new
timestamped JSON files — nothing here is ever overwritten or deleted.

Pulled with the `service_role` key, which bypasses Row Level Security
entirely, so this includes every row the app's own anon-key access never
sees directly (e.g. `pin_hash`). Treat these files with the same care as
the database itself — this is a private repo backup, not something to
share or commit anywhere public.
