-- LabInfo TL — execute integralmente no SQL Editor do Supabase.
create extension if not exists pgcrypto;

create type public.app_role as enum ('tecnico','supervisor');
create type public.ticket_status as enum ('Recebido','Em atendimento','Concluído');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  siape text not null unique check (siape ~ '^[0-9]{5,12}$'),
  full_name text not null,
  email text not null unique,
  role public.app_role not null default 'tecnico',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.servers (
  id uuid primary key default gen_random_uuid(),
  siape text not null unique check (siape ~ '^[0-9]{5,12}$'),
  full_name text not null,
  email text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.categories (
  id uuid primary key default gen_random_uuid(), name text not null unique,
  active boolean not null default true, created_at timestamptz not null default now()
);
create table public.labs (
  id uuid primary key default gen_random_uuid(), name text not null unique,
  code text unique, location text, computer_count integer not null default 0 check (computer_count >= 0), reservation_enabled boolean not null default false, active boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.protocol_sequences (
  prefix text primary key, last_value bigint not null default 0
);
create table public.system_settings (
  key text primary key, value jsonb not null,
  updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
create table public.tickets (
  id uuid primary key default gen_random_uuid(), protocol text not null unique,
  server_id uuid not null references public.servers(id),
  category_id uuid references public.categories(id), lab_id uuid references public.labs(id),
  title text not null, description text not null,
  status public.ticket_status not null default 'Recebido',
  source text not null default 'Formulario' check (source in ('Formulario','Tecnico','Email')),
  assigned_to uuid references public.profiles(id),
  resolution text, created_at timestamptz not null default now(),
  started_at timestamptz, closed_at timestamptz, updated_at timestamptz not null default now()
);
create table public.ticket_updates (
  id bigint generated always as identity primary key,
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  author_id uuid references public.profiles(id), message text not null,
  kind text not null default 'atualizacao', visible_to_server boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.attachments (
  id uuid primary key default gen_random_uuid(), ticket_id uuid not null references public.tickets(id) on delete cascade,
  storage_path text not null unique, file_name text not null, mime_type text not null,
  size_bytes bigint not null check (size_bytes between 1 and 5242880), created_at timestamptz not null default now()
);
create index tickets_server_idx on public.tickets(server_id, created_at desc);
create index tickets_status_idx on public.tickets(status, created_at desc);
create index updates_ticket_idx on public.ticket_updates(ticket_id, created_at);

create or replace function public.current_role() returns public.app_role language sql stable security definer
set search_path=public as $$ select role from public.profiles where id=auth.uid() and active $$;
revoke all on function public.current_role() from public; grant execute on function public.current_role() to anon,authenticated;

create or replace function public.next_protocol(p_lab uuid) returns text language plpgsql security definer set search_path=public as $$
declare v_next bigint;
begin
  insert into public.protocol_sequences(prefix,last_value) values('LAB',1)
  on conflict(prefix) do update set last_value=protocol_sequences.last_value+1
  returning last_value into v_next;
  return 'LAB-'||lpad(v_next::text,5,'0');
end $$;
revoke all on function public.next_protocol(uuid) from public;
grant execute on function public.next_protocol(uuid) to authenticated;

create or replace function public.identify_server(p_siape text)
returns table(id uuid, full_name text, email text) language sql security definer set search_path=public as $$
  select s.id,s.full_name,s.email from public.servers s where s.siape=p_siape and s.active limit 1
$$;
grant execute on function public.identify_server(text) to anon,authenticated;

create or replace function public.create_public_ticket(p_siape text,p_lab uuid,p_category uuid,p_title text,p_description text)
returns table(id uuid,protocol text) language plpgsql security definer set search_path=public as $$
declare v_server uuid; v_id uuid; v_protocol text;
begin
  select s.id into v_server from public.servers s where s.siape=p_siape and s.active;
  if v_server is null then raise exception 'SIAPE não cadastrado'; end if;
  if length(btrim(p_description))<5 then raise exception 'Descrição muito curta'; end if;
  v_protocol:=public.next_protocol(p_lab);
  insert into public.tickets(protocol,server_id,lab_id,category_id,title,description)
  values(v_protocol,v_server,p_lab,p_category,left(btrim(p_title),100),left(btrim(p_description),2000)) returning tickets.id into v_id;
  return query select v_id,v_protocol;
end $$;
grant execute on function public.create_public_ticket(text,uuid,uuid,text,text) to anon,authenticated;

create or replace function public.register_public_attachment(p_ticket uuid,p_siape text,p_path text,p_name text,p_type text,p_size bigint)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.tickets t join public.servers s on s.id=t.server_id where t.id=p_ticket and s.siape=p_siape and t.status<>'Concluído') then raise exception 'Chamado inválido'; end if;
  if (select count(*) from public.attachments where ticket_id=p_ticket)>=3 then raise exception 'Limite de anexos'; end if;
  insert into public.attachments(ticket_id,storage_path,file_name,mime_type,size_bytes) values(p_ticket,p_path,left(p_name,180),p_type,p_size);
end $$;
grant execute on function public.register_public_attachment(uuid,text,text,text,text,bigint) to anon,authenticated;

create or replace function public.my_tickets(p_siape text)
returns table(protocol text,title text,category text,lab text,status public.ticket_status,technician text,resolution text,created_at timestamptz,updated_at timestamptz)
language sql security definer set search_path=public as $$
 select t.protocol,t.title,c.name,l.name,t.status,p.full_name,t.resolution,t.created_at,t.updated_at
 from public.tickets t join public.servers s on s.id=t.server_id
 left join public.categories c on c.id=t.category_id left join public.labs l on l.id=t.lab_id
 left join public.profiles p on p.id=t.assigned_to where s.siape=p_siape and s.active order by t.created_at desc limit 100
$$;
grant execute on function public.my_tickets(text) to anon,authenticated;

alter table public.profiles enable row level security; alter table public.servers enable row level security;
alter table public.categories enable row level security; alter table public.labs enable row level security;
alter table public.tickets enable row level security; alter table public.ticket_updates enable row level security;
alter table public.attachments enable row level security; alter table public.protocol_sequences enable row level security;
alter table public.system_settings enable row level security;

create policy profiles_read on public.profiles for select to authenticated using(public.current_role() in ('tecnico','supervisor'));
create policy profiles_write on public.profiles for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
create policy servers_read on public.servers for select to authenticated using(public.current_role() in ('tecnico','supervisor'));
create policy servers_write on public.servers for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
create policy categories_public_read on public.categories for select to anon,authenticated using(active or public.current_role() in ('tecnico','supervisor'));
create policy categories_write on public.categories for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
create policy labs_public_read on public.labs for select to anon,authenticated using(active or public.current_role() in ('tecnico','supervisor'));
create policy labs_write on public.labs for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
create policy tickets_read on public.tickets for select to authenticated using(public.current_role() in ('tecnico','supervisor'));
create policy tickets_write on public.tickets for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
create policy updates_read on public.ticket_updates for select to authenticated using(public.current_role() in ('tecnico','supervisor'));
create policy updates_write on public.ticket_updates for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
create policy attachments_read on public.attachments for select to authenticated using(public.current_role() in ('tecnico','supervisor'));
create policy attachments_write on public.attachments for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');
create policy settings_public_read on public.system_settings for select to anon,authenticated using(true);
create policy settings_tech_write on public.system_settings for all to authenticated using(public.current_role()='tecnico') with check(public.current_role()='tecnico');

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('ticket-attachments','ticket-attachments',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy storage_public_upload on storage.objects for insert to anon,authenticated
with check(bucket_id='ticket-attachments' and (storage.foldername(name))[1]='tickets');
create policy storage_staff_read on storage.objects for select to authenticated
using(bucket_id='ticket-attachments' and public.current_role() in ('tecnico','supervisor'));
create policy storage_tech_delete on storage.objects for delete to authenticated
using(bucket_id='ticket-attachments' and public.current_role()='tecnico');

insert into public.categories(name) values ('Computador não liga'),('Internet ou rede'),('Projetor ou áudio'),('Software ou acesso'),('Periféricos'),('Outro') on conflict do nothing;
insert into public.labs(name,code,location) values ('LabInfo 01','LAB01','Bloco A'),('LabInfo 02','LAB02','Bloco A'),('LabInfo 03','LAB03','Bloco B'),('LabInfo 04','LAB04','Bloco B'),('Outro ambiente',null,'Campus') on conflict do nothing;
insert into public.system_settings(key,value) values ('service_hours','{"days":{"mon":{"enabled":true,"start":"07:00","end":"22:00"},"tue":{"enabled":true,"start":"07:00","end":"22:00"},"wed":{"enabled":true,"start":"07:00","end":"22:00"},"thu":{"enabled":true,"start":"07:00","end":"22:00"},"fri":{"enabled":true,"start":"07:00","end":"22:00"},"sat":{"enabled":false,"start":"07:00","end":"12:00"},"sun":{"enabled":false,"start":"07:00","end":"12:00"}},"note":""}'::jsonb) on conflict do nothing;

-- Após criar o usuário em Authentication > Users, vincule-o assim:
-- insert into public.profiles(id,siape,full_name,email,role)
-- select id,'SEU_SIAPE','Nome completo',email,'tecnico' from auth.users where email='tecnico@ifms.edu.br';
-- Troque 'tecnico' por 'supervisor' para acesso somente leitura.
