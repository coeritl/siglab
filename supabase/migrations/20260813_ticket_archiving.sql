alter table public.tickets add column if not exists archived_at timestamptz;
create index if not exists tickets_active_queue_idx on public.tickets(created_at desc) where archived_at is null;
