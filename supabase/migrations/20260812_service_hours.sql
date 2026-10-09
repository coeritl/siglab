create table if not exists public.system_settings (
  key text primary key, value jsonb not null,
  updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
alter table public.system_settings enable row level security;
drop policy if exists settings_public_read on public.system_settings;
drop policy if exists settings_tech_write on public.system_settings;
create policy settings_public_read on public.system_settings for select to anon,authenticated using(true);
create policy settings_tech_write on public.system_settings for all to authenticated
  using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
insert into public.system_settings(key,value) values (
  'service_hours',
  '{"days":{"mon":{"enabled":true,"start":"07:00","end":"22:00"},"tue":{"enabled":true,"start":"07:00","end":"22:00"},"wed":{"enabled":true,"start":"07:00","end":"22:00"},"thu":{"enabled":true,"start":"07:00","end":"22:00"},"fri":{"enabled":true,"start":"07:00","end":"22:00"},"sat":{"enabled":false,"start":"07:00","end":"12:00"},"sun":{"enabled":false,"start":"07:00","end":"12:00"}},"note":""}'::jsonb
) on conflict do nothing;
