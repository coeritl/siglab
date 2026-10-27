-- SIGLAB — instalação inicial consolidada
-- Gerado automaticamente; execute somente em um projeto Supabase novo.
-- Projeto esperado: keesciertyonbfqlrqwt

-- -----------------------------------------------------------------------------
-- schema.sql
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- migrations/20260812_pending_servers.sql
-- -----------------------------------------------------------------------------
-- Permite abertura de chamados por servidores ainda não cadastrados.
alter table public.tickets alter column server_id drop not null;
alter table public.tickets add column if not exists guest_siape text;
alter table public.tickets add column if not exists guest_email text;

alter table public.tickets drop constraint if exists tickets_server_identity_check;
alter table public.tickets add constraint tickets_server_identity_check check (
  server_id is not null or (
    guest_siape ~ '^[0-9]{5,12}$'
    and lower(guest_email) ~ '^[^[:space:]@]+@ifms[.]edu[.]br$'
  )
);

create index if not exists tickets_guest_siape_idx
  on public.tickets(guest_siape, created_at desc) where server_id is null;

create or replace function public.create_public_ticket(
  p_siape text,p_email text,p_lab uuid,p_category uuid,p_title text,p_description text
)
returns table(id uuid,protocol text) language plpgsql security definer set search_path=public as $$
declare v_server uuid; v_id uuid; v_protocol text; v_email text;
begin
  select s.id into v_server from public.servers s where s.siape=btrim(p_siape) and s.active;
  v_email:=lower(btrim(coalesce(p_email,'')));
  if v_server is null and v_email !~ '^[^[:space:]@]+@ifms[.]edu[.]br$' then
    raise exception 'Informe um e-mail institucional @ifms.edu.br';
  end if;
  if btrim(p_siape) !~ '^[0-9]{5,12}$' then raise exception 'SIAPE inválido'; end if;
  if length(btrim(p_description))<5 then raise exception 'Descrição muito curta'; end if;
  v_protocol:=public.next_protocol(p_lab);
  insert into public.tickets(protocol,server_id,guest_siape,guest_email,lab_id,category_id,title,description)
  values(v_protocol,v_server,case when v_server is null then btrim(p_siape) end,
    case when v_server is null then v_email end,p_lab,p_category,left(btrim(p_title),100),left(btrim(p_description),2000))
  returning tickets.id into v_id;
  return query select v_id,v_protocol;
end $$;
revoke all on function public.create_public_ticket(text,text,uuid,uuid,text,text) from public;
grant execute on function public.create_public_ticket(text,text,uuid,uuid,text,text) to anon,authenticated;

create or replace function public.register_public_attachment(p_ticket uuid,p_siape text,p_path text,p_name text,p_type text,p_size bigint)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(
    select 1 from public.tickets t left join public.servers s on s.id=t.server_id
    where t.id=p_ticket and coalesce(s.siape,t.guest_siape)=p_siape and t.status<>'Concluído'
  ) then raise exception 'Chamado inválido'; end if;
  if (select count(*) from public.attachments where ticket_id=p_ticket)>=3 then raise exception 'Limite de anexos'; end if;
  insert into public.attachments(ticket_id,storage_path,file_name,mime_type,size_bytes)
  values(p_ticket,p_path,left(p_name,180),p_type,p_size);
end $$;

create or replace function public.my_tickets(p_siape text)
returns table(protocol text,title text,category text,lab text,status public.ticket_status,technician text,resolution text,created_at timestamptz,updated_at timestamptz)
language sql security definer set search_path=public as $$
 select t.protocol,t.title,c.name,l.name,t.status,p.full_name,t.resolution,t.created_at,t.updated_at
 from public.tickets t left join public.servers s on s.id=t.server_id
 left join public.categories c on c.id=t.category_id left join public.labs l on l.id=t.lab_id
 left join public.profiles p on p.id=t.assigned_to
 where coalesce(s.siape,t.guest_siape)=p_siape order by t.created_at desc limit 100
$$;

create or replace function public.link_pending_server_tickets() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.active then
    update public.tickets set server_id=new.id,guest_siape=null,guest_email=null,updated_at=now()
    where server_id is null and guest_siape=new.siape;
  end if;
  return new;
end $$;

drop trigger if exists link_pending_server_tickets on public.servers;
create trigger link_pending_server_tickets after insert or update of siape,active on public.servers
for each row execute function public.link_pending_server_tickets();

-- -----------------------------------------------------------------------------
-- migrations/20260812_multiple_assignees.sql
-- -----------------------------------------------------------------------------
-- Permite vários técnicos responsáveis por um mesmo chamado.
create table if not exists public.ticket_assignees (
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  profile_id uuid not null references public.profiles(id),
  assigned_at timestamptz not null default now(),
  assigned_by uuid references public.profiles(id),
  primary key (ticket_id, profile_id)
);

insert into public.ticket_assignees(ticket_id,profile_id)
select id,assigned_to from public.tickets where assigned_to is not null
on conflict do nothing;

alter table public.ticket_assignees enable row level security;
drop policy if exists ticket_assignees_read on public.ticket_assignees;
create policy ticket_assignees_read on public.ticket_assignees for select to authenticated
using(public.current_role() in ('tecnico','supervisor'));
drop policy if exists ticket_assignees_write on public.ticket_assignees;
create policy ticket_assignees_write on public.ticket_assignees for all to authenticated
using(public.current_role()='tecnico') with check(public.current_role()='tecnico');

create or replace function public.my_tickets(p_siape text)
returns table(protocol text,title text,category text,lab text,status public.ticket_status,technician text,resolution text,created_at timestamptz,updated_at timestamptz)
language sql security definer set search_path=public as $$
 select t.protocol,t.title,c.name,l.name,t.status,
   case when t.status<>'Recebido' then coalesce(
     (select string_agg(p.full_name, ', ' order by p.full_name)
      from public.ticket_assignees ta join public.profiles p on p.id=ta.profile_id
      where ta.ticket_id=t.id), 'Toda a equipe') end,
   t.resolution,t.created_at,t.updated_at
 from public.tickets t left join public.servers s on s.id=t.server_id
 left join public.categories c on c.id=t.category_id left join public.labs l on l.id=t.lab_id
 where coalesce(s.siape,t.guest_siape)=p_siape order by t.created_at desc limit 100
$$;

-- -----------------------------------------------------------------------------
-- migrations/20260812_service_hours.sql
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- migrations/20260813_google_apps_script.sql
-- -----------------------------------------------------------------------------
-- Integração segura entre Supabase e Google Apps Script.
-- O valor abaixo é somente o hash; o segredo original fica nas propriedades privadas do Apps Script.

create table if not exists public.integration_credentials (
  name text primary key,
  secret_hash text not null check (secret_hash ~ '^[a-f0-9]{64}$'),
  updated_at timestamptz not null default now()
);

create table if not exists public.email_outbox (
  id bigint generated always as identity primary key,
  ticket_id uuid references public.tickets(id) on delete cascade,
  recipient text not null check (lower(recipient) ~ '^[^[:space:]@]+@ifms[.]edu[.]br$'),
  event_type text not null check (event_type in ('recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido')),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','processing','sent','failed')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);

create index if not exists email_outbox_pending_idx
  on public.email_outbox(status, available_at, id);

create table if not exists public.email_inbox_log (
  gmail_message_id text primary key,
  sender text not null,
  subject text not null,
  ticket_id uuid references public.tickets(id),
  result text not null,
  created_at timestamptz not null default now()
);

alter table public.integration_credentials enable row level security;
alter table public.email_outbox enable row level security;
alter table public.email_inbox_log enable row level security;

insert into public.integration_credentials(name,secret_hash)
values ('google_apps_script','e7c4e9a71d1567a5bdee12e756d22b34b28d17f2b9dc3effe1e2d884854e5d62')
on conflict(name) do update set secret_hash=excluded.secret_hash,updated_at=now();

create or replace function public.integration_secret_valid(p_secret text)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.integration_credentials
    where name='google_apps_script'
      and secret_hash=encode(extensions.digest(coalesce(p_secret,''),'sha256'),'hex')
  )
$$;
revoke all on function public.integration_secret_valid(text) from public;

create or replace function public.ticket_email(t public.tickets)
returns text language sql stable security definer set search_path=public as $$
  select lower(coalesce(s.email,t.guest_email)) from public.servers s where s.id=t.server_id
  union all select lower(t.guest_email) where t.server_id is null limit 1
$$;

create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'protocol',t.protocol,'title',t.title,'description',t.description,'status',t.status,
    'server_name',coalesce(s.full_name,'Servidor'),'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),'created_at',t.created_at,
    'portal_url','https://coeritl.github.io/labinfo/'
  )
  from (select 1) x
  left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id
  left join public.categories c on c.id=t.category_id
$$;

create or replace function public.queue_ticket_email() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_email text; v_event text;
begin
  v_email:=public.ticket_email(new);
  if v_email is null then return new; end if;
  if tg_op='INSERT' then
    v_event:=case when new.source='Tecnico' then 'aberto_pelo_tecnico' else 'recebido' end;
  elsif new.status is distinct from old.status and new.status='Em atendimento' then v_event:='em_atendimento';
  elsif new.status is distinct from old.status and new.status='Concluído' then v_event:='concluido';
  else return new;
  end if;
  insert into public.email_outbox(ticket_id,recipient,event_type,payload)
  values(new.id,v_email,v_event,public.ticket_email_payload(new));
  return new;
end $$;

drop trigger if exists queue_ticket_email on public.tickets;
create trigger queue_ticket_email after insert or update of status on public.tickets
for each row execute function public.queue_ticket_email();

create or replace function public.queue_ticket_update_email() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_ticket public.tickets; v_email text; v_payload jsonb;
begin
  if not new.visible_to_server or new.kind<>'atualizacao' then return new; end if;
  select * into v_ticket from public.tickets where id=new.ticket_id;
  v_email:=public.ticket_email(v_ticket);
  if v_email is not null then
    v_payload:=public.ticket_email_payload(v_ticket)||jsonb_build_object('message',new.message);
    insert into public.email_outbox(ticket_id,recipient,event_type,payload)
    values(v_ticket.id,v_email,'atualizacao',v_payload);
  end if;
  return new;
end $$;

drop trigger if exists queue_ticket_update_email on public.ticket_updates;
create trigger queue_ticket_update_email after insert on public.ticket_updates
for each row execute function public.queue_ticket_update_email();

create or replace function public.apps_script_register_inbound(
  p_secret text,p_message_id text,p_sender text,p_subject text,p_body text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_server public.servers; v_lab uuid; v_title text; v_protocol text; v_ticket uuid; v_result jsonb;
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  if exists(select 1 from public.email_inbox_log where gmail_message_id=p_message_id) then
    return jsonb_build_object('duplicate',true);
  end if;
  select * into v_server from public.servers where lower(email)=lower(btrim(p_sender)) and active limit 1;
  if v_server.id is null then
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),null,'remetente_nao_cadastrado',now());
    return jsonb_build_object('accepted',false,'reason','remetente_nao_cadastrado');
  end if;
  select id into v_lab from public.labs
   where active and upper(p_subject) like '%'||upper(code)||'%' and code is not null
   order by length(code) desc limit 1;
  v_title:=btrim(regexp_replace(p_subject,'^\s*CHAMADO\s*:\s*','', 'i'));
  if v_title='' then v_title:='Chamado recebido por e-mail'; end if;
  v_protocol:=public.next_protocol(v_lab);
  insert into public.tickets(protocol,server_id,lab_id,title,description,source)
  values(v_protocol,v_server.id,v_lab,left(v_title,100),left(btrim(p_body),2000),'Email') returning id into v_ticket;
  insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_ticket,'criado',now());
  return jsonb_build_object('accepted',true,'ticket_id',v_ticket,'protocol',v_protocol,'siape',v_server.siape);
end $$;

create or replace function public.apps_script_pull_outbox(p_secret text,p_limit integer default 25)
returns setof public.email_outbox language plpgsql security definer set search_path=public as $$
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  return query
  with claimed as (
    select id from public.email_outbox
    where (status='pending' and available_at<=now())
       or (status='processing' and claimed_at<now()-interval '2 hours')
    order by id for update skip locked limit least(greatest(p_limit,1),50)
  )
  update public.email_outbox o set status='processing',claimed_at=now(),attempts=attempts+1
  from claimed where o.id=claimed.id returning o.*;
end $$;

create or replace function public.apps_script_finish_outbox(
  p_secret text,p_id bigint,p_success boolean,p_error text default null
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  update public.email_outbox set
    status=case when p_success then 'sent' when attempts>=5 then 'failed' else 'pending' end,
    sent_at=case when p_success then now() else sent_at end,
    available_at=case when p_success then available_at else now()+interval '30 minutes' end,
    last_error=case when p_success then null else left(coalesce(p_error,'Erro desconhecido'),1000) end
  where id=p_id;
end $$;

grant execute on function public.apps_script_register_inbound(text,text,text,text,text) to anon;
grant execute on function public.apps_script_pull_outbox(text,integer) to anon;
grant execute on function public.apps_script_finish_outbox(text,bigint,boolean,text) to anon;

-- -----------------------------------------------------------------------------
-- migrations/20260813_email_reply_updates.sql
-- -----------------------------------------------------------------------------
-- Respostas a notificações são incorporadas ao histórico do chamado correspondente.
create or replace function public.apps_script_register_inbound(
  p_secret text,p_message_id text,p_sender text,p_subject text,p_body text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_server public.servers; v_lab uuid; v_title text; v_protocol text; v_ticket uuid; v_existing public.tickets;
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  if exists(select 1 from public.email_inbox_log where gmail_message_id=p_message_id) then return jsonb_build_object('duplicate',true); end if;
  select * into v_server from public.servers where lower(email)=lower(btrim(p_sender)) and active limit 1;
  if v_server.id is null then
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),null,'remetente_nao_cadastrado',now());
    return jsonb_build_object('accepted',false,'reason','remetente_nao_cadastrado');
  end if;
  v_protocol:=(regexp_match(upper(p_subject),'(LAB[0-9]*-[0-9]+)'))[1];
  if v_protocol is not null then select * into v_existing from public.tickets where protocol=v_protocol and server_id=v_server.id and status<>'Concluído' limit 1; end if;
  if v_existing.id is not null then
    insert into public.ticket_updates(ticket_id,author_id,message,kind,visible_to_server) values(v_existing.id,null,left(btrim(p_body),2000),'resposta_servidor',true);
    update public.tickets set updated_at=now() where id=v_existing.id;
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_existing.id,'resposta_adicionada',now());
    return jsonb_build_object('accepted',true,'reply',true,'ticket_id',v_existing.id,'protocol',v_existing.protocol,'siape',v_server.siape);
  end if;
  select id into v_lab from public.labs where active and upper(p_subject) like '%'||upper(code)||'%' and code is not null order by length(code) desc limit 1;
  v_title:=btrim(regexp_replace(p_subject,'^\s*CHAMADO\s*:\s*','', 'i')); if v_title='' then v_title:='Chamado recebido por e-mail'; end if;
  v_protocol:=public.next_protocol(v_lab);
  insert into public.tickets(protocol,server_id,lab_id,title,description,source) values(v_protocol,v_server.id,v_lab,left(v_title,100),left(btrim(p_body),2000),'Email') returning id into v_ticket;
  insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_ticket,'criado',now());
  return jsonb_build_object('accepted',true,'reply',false,'ticket_id',v_ticket,'protocol',v_protocol,'siape',v_server.siape);
end $$;

-- -----------------------------------------------------------------------------
-- migrations/20260813_ticket_archiving.sql
-- -----------------------------------------------------------------------------
alter table public.tickets add column if not exists archived_at timestamptz;
create index if not exists tickets_active_queue_idx on public.tickets(created_at desc) where archived_at is null;

-- -----------------------------------------------------------------------------
-- migrations/20260813_ticket_deletion_audit.sql
-- -----------------------------------------------------------------------------
alter table public.tickets add column if not exists deleted_at timestamptz;
alter table public.tickets add column if not exists deleted_by uuid references public.profiles(id);
alter table public.tickets add column if not exists deletion_reason text;

create or replace function public.soft_delete_ticket(p_ticket uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'tecnico' then raise exception 'Sem permissão'; end if;
  if length(btrim(coalesce(p_reason,'')))<5 then raise exception 'Informe uma justificativa para a exclusão'; end if;
  update public.tickets set deleted_at=now(),deleted_by=auth.uid(),deletion_reason=left(btrim(p_reason),500),updated_at=now()
  where id=p_ticket and deleted_at is null;
end $$;
grant execute on function public.soft_delete_ticket(uuid,text) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260813_technician_opened_email.sql
-- -----------------------------------------------------------------------------
-- Diferencia o e-mail de chamado aberto pelo servidor daquele criado pela equipe técnica.
alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check
  check (event_type in ('recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido'));

create or replace function public.queue_ticket_email() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_email text; v_event text;
begin
  v_email:=public.ticket_email(new);
  if v_email is null then return new; end if;
  if tg_op='INSERT' then
    v_event:=case when new.source='Tecnico' then 'aberto_pelo_tecnico' else 'recebido' end;
  elsif new.status is distinct from old.status and new.status='Em atendimento' then v_event:='em_atendimento';
  elsif new.status is distinct from old.status and new.status='Concluído' then v_event:='concluido';
  else return new;
  end if;
  insert into public.email_outbox(ticket_id,recipient,event_type,payload)
  values(new.id,v_email,v_event,public.ticket_email_payload(new));
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- migrations/20260813_server_reply_notification.sql
-- -----------------------------------------------------------------------------
alter table public.tickets add column if not exists server_reply_pending boolean not null default false;
alter table public.tickets add column if not exists last_server_reply_at timestamptz;

create or replace function public.mark_server_reply_read(p_ticket uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'tecnico' then raise exception 'Acesso negado'; end if;
  update public.tickets set server_reply_pending=false where id=p_ticket;
end $$;
grant execute on function public.mark_server_reply_read(uuid) to authenticated;

create or replace function public.notify_server_reply() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.kind='resposta_servidor' then
    update public.tickets set server_reply_pending=true,last_server_reply_at=now(),updated_at=now() where id=new.ticket_id;
  end if;
  return new;
end $$;
drop trigger if exists notify_server_reply on public.ticket_updates;
create trigger notify_server_reply after insert on public.ticket_updates
for each row execute function public.notify_server_reply();

-- -----------------------------------------------------------------------------
-- migrations/20260813_public_ticket_timeline.sql
-- -----------------------------------------------------------------------------
drop function if exists public.my_tickets(text);
create function public.my_tickets(p_siape text)
returns table(protocol text,title text,category text,lab text,status public.ticket_status,technician text,resolution text,created_at timestamptz,updated_at timestamptz,timeline jsonb)
language sql security definer set search_path=public as $$
 select t.protocol,t.title,c.name,l.name,t.status,
   case when t.status<>'Recebido' then coalesce(
     (select string_agg(p.full_name, ', ' order by p.full_name) from public.ticket_assignees ta join public.profiles p on p.id=ta.profile_id where ta.ticket_id=t.id),
     'Toda a equipe') end,
   t.resolution,t.created_at,t.updated_at,
   jsonb_build_array(jsonb_build_object('type','abertura','label','Chamado aberto','at',t.created_at))
   || coalesce((select jsonb_agg(jsonb_build_object(
       'type',u.kind,
       'label',case u.kind when 'status' then 'Atendimento iniciado' when 'atualizacao' then 'Atualização enviada pela equipe' when 'resposta_servidor' then 'Resposta recebida pela equipe' when 'fechamento' then 'Atendimento concluído' else 'Andamento registrado' end,
       'at',u.created_at) order by u.created_at)
     from public.ticket_updates u where u.ticket_id=t.id),'[]'::jsonb)
 from public.tickets t left join public.servers s on s.id=t.server_id
 left join public.categories c on c.id=t.category_id left join public.labs l on l.id=t.lab_id
 where coalesce(s.siape,t.guest_siape)=p_siape order by t.created_at desc limit 100
$$;
grant execute on function public.my_tickets(text) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260813_production_stabilization.sql
-- -----------------------------------------------------------------------------
-- Estabilização para entrada em produção.
alter table public.tickets add column if not exists feedback_token uuid not null default gen_random_uuid();
alter table public.tickets add column if not exists feedback_confirmed_at timestamptz;
alter table public.tickets add column if not exists deleted_by_name text;
create unique index if not exists tickets_feedback_token_key on public.tickets(feedback_token);

create or replace function public.soft_delete_ticket(p_ticket uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare v_name text;
begin
  if public.current_role()<>'tecnico' then raise exception 'Sem permissão'; end if;
  if length(btrim(coalesce(p_reason,'')))<5 then raise exception 'Informe uma justificativa para a exclusão'; end if;
  select full_name into v_name from public.profiles where id=auth.uid();
  update public.tickets set deleted_at=now(),deleted_by=auth.uid(),deleted_by_name=v_name,
    deletion_reason=left(btrim(p_reason),500),updated_at=now()
  where id=p_ticket and deleted_at is null;
  if not found then raise exception 'Chamado não localizado ou já excluído'; end if;
end $$;

create or replace function public.confirm_ticket_feedback(p_token uuid)
returns table(protocol text,confirmed_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
  update public.tickets set feedback_confirmed_at=coalesce(feedback_confirmed_at,now()),updated_at=now()
  where feedback_token=p_token and status='Concluído' and deleted_at is null;
  if not found then raise exception 'Confirmação inválida ou chamado ainda não concluído'; end if;
  return query select t.protocol,t.feedback_confirmed_at from public.tickets t where t.feedback_token=p_token;
end $$;
grant execute on function public.confirm_ticket_feedback(uuid) to anon,authenticated;

create or replace function public.create_public_ticket(
  p_siape text,p_email text,p_lab uuid,p_category uuid,p_title text,p_description text
)
returns table(id uuid,protocol text) language plpgsql security definer set search_path=public as $$
declare v_server uuid; v_id uuid; v_protocol text; v_email text; v_identity text;
begin
  select s.id into v_server from public.servers s where s.siape=btrim(p_siape) and s.active;
  v_email:=lower(btrim(coalesce(p_email,'')));
  if v_server is null and v_email !~ '^[^[:space:]@]+@ifms[.]edu[.]br$' then raise exception 'Informe um e-mail institucional @ifms.edu.br'; end if;
  if btrim(p_siape) !~ '^[0-9]{5,12}$' then raise exception 'SIAPE inválido'; end if;
  if length(btrim(p_description))<5 then raise exception 'Descrição muito curta'; end if;
  v_identity:=coalesce(v_server::text,btrim(p_siape)||':'||v_email);
  if (select count(*) from public.tickets where coalesce(server_id::text,guest_siape||':'||guest_email)=v_identity and created_at>now()-interval '1 hour')>=10 then
    raise exception 'Limite temporário de solicitações atingido. Aguarde antes de tentar novamente';
  end if;
  if (select count(*) from public.tickets where coalesce(server_id::text,guest_siape||':'||guest_email)=v_identity and created_at>now()-interval '1 day')>=30 then
    raise exception 'Limite diário de solicitações atingido';
  end if;
  v_protocol:=public.next_protocol(p_lab);
  insert into public.tickets(protocol,server_id,guest_siape,guest_email,lab_id,category_id,title,description)
  values(v_protocol,v_server,case when v_server is null then btrim(p_siape) end,case when v_server is null then v_email end,
    p_lab,p_category,left(btrim(p_title),100),left(btrim(p_description),2000)) returning tickets.id into v_id;
  return query select v_id,v_protocol;
end $$;

create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'protocol',t.protocol,'title',t.title,'description',t.description,'status',t.status,
    'server_name',coalesce(s.full_name,'Servidor'),'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),'created_at',t.created_at,
    'portal_url','https://coeritl.github.io/labinfo/',
    'feedback_url','https://coeritl.github.io/labinfo/?feedback='||t.feedback_token::text
  )
  from (select 1) x left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id left join public.categories c on c.id=t.category_id
$$;

alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check (
  event_type in ('recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido','novo_chamado_tecnico','resposta_servidor_tecnico')
);

create or replace function public.queue_staff_new_ticket_email() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.email_outbox(ticket_id,recipient,event_type,payload)
  select new.id,lower(p.email),'novo_chamado_tecnico',public.ticket_email_payload(new)
  from public.profiles p where p.active and p.role='tecnico';
  return new;
end $$;
drop trigger if exists queue_staff_new_ticket_email on public.tickets;
create trigger queue_staff_new_ticket_email after insert on public.tickets
for each row execute function public.queue_staff_new_ticket_email();

create or replace function public.notify_server_reply() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_ticket public.tickets;
begin
  if new.kind='resposta_servidor' then
    update public.tickets set server_reply_pending=true,last_server_reply_at=now(),updated_at=now(),
      status=case when status='Concluído' then 'Em atendimento'::public.ticket_status else status end,
      closed_at=case when status='Concluído' then null else closed_at end,
      resolution=case when status='Concluído' then null else resolution end
    where id=new.ticket_id returning * into v_ticket;
    insert into public.email_outbox(ticket_id,recipient,event_type,payload)
    select v_ticket.id,lower(p.email),'resposta_servidor_tecnico',
      public.ticket_email_payload(v_ticket)||jsonb_build_object('message',new.message)
    from public.profiles p where p.active and p.role='tecnico';
  end if;
  return new;
end $$;

create or replace function public.apps_script_register_inbound(
  p_secret text,p_message_id text,p_sender text,p_subject text,p_body text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_server public.servers; v_lab uuid; v_title text; v_protocol text; v_ticket uuid; v_existing public.tickets;
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  if exists(select 1 from public.email_inbox_log where gmail_message_id=p_message_id) then return jsonb_build_object('duplicate',true); end if;
  select * into v_server from public.servers where lower(email)=lower(btrim(p_sender)) and active limit 1;
  if v_server.id is null then
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),null,'remetente_nao_cadastrado',now());
    return jsonb_build_object('accepted',false,'reason','remetente_nao_cadastrado');
  end if;
  v_protocol:=(regexp_match(upper(p_subject),'(LAB[0-9]*-[0-9]+)'))[1];
  if v_protocol is not null then select * into v_existing from public.tickets where protocol=v_protocol and server_id=v_server.id and deleted_at is null limit 1; end if;
  if v_existing.id is not null then
    insert into public.ticket_updates(ticket_id,author_id,message,kind,visible_to_server)
    values(v_existing.id,null,left(btrim(p_body),2000),'resposta_servidor',true);
    insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_existing.id,'resposta_adicionada',now());
    return jsonb_build_object('accepted',true,'reply',true,'ticket_id',v_existing.id,'protocol',v_existing.protocol,'siape',v_server.siape);
  end if;
  select id into v_lab from public.labs where active and upper(p_subject) like '%'||upper(code)||'%' and code is not null order by length(code) desc limit 1;
  v_title:=btrim(regexp_replace(p_subject,'^\s*CHAMADO\s*:\s*','', 'i')); if v_title='' then v_title:='Chamado recebido por e-mail'; end if;
  v_protocol:=public.next_protocol(v_lab);
  insert into public.tickets(protocol,server_id,lab_id,title,description,source)
  values(v_protocol,v_server.id,v_lab,left(v_title,100),left(btrim(p_body),2000),'Email') returning id into v_ticket;
  insert into public.email_inbox_log values(p_message_id,lower(p_sender),left(p_subject,300),v_ticket,'criado',now());
  return jsonb_build_object('accepted',true,'reply',false,'ticket_id',v_ticket,'protocol',v_protocol,'siape',v_server.siape);
end $$;

drop function if exists public.my_tickets(text);
create function public.my_tickets(p_siape text)
returns table(protocol text,title text,category text,lab text,status public.ticket_status,technician text,resolution text,created_at timestamptz,updated_at timestamptz,timeline jsonb)
language sql security definer set search_path=public as $$
 select t.protocol,t.title,c.name,l.name,t.status,
   case when t.status<>'Recebido' then coalesce((select string_agg(p.full_name, ', ' order by p.full_name) from public.ticket_assignees ta join public.profiles p on p.id=ta.profile_id where ta.ticket_id=t.id),'Toda a equipe') end,
   t.resolution,t.created_at,t.updated_at,
   jsonb_build_array(jsonb_build_object('type','abertura','label','Solicitação registrada','at',t.created_at))
   || coalesce((select jsonb_agg(jsonb_build_object('type',u.kind,'label',case u.kind when 'status' then 'Atendimento iniciado' when 'atualizacao' then 'Atualização enviada pela equipe' when 'resposta_servidor' then 'Resposta recebida pela equipe' when 'fechamento' then 'Atendimento concluído' else 'Andamento registrado' end,'at',u.created_at) order by u.created_at) from public.ticket_updates u where u.ticket_id=t.id),'[]'::jsonb)
   || case when t.feedback_confirmed_at is not null then jsonb_build_array(jsonb_build_object('type','feedback','label','Atendimento confirmado pelo servidor','at',t.feedback_confirmed_at)) else '[]'::jsonb end
 from public.tickets t left join public.servers s on s.id=t.server_id
 left join public.categories c on c.id=t.category_id left join public.labs l on l.id=t.lab_id
 where coalesce(s.siape,t.guest_siape)=p_siape and t.deleted_at is null order by t.created_at desc limit 100
$$;
grant execute on function public.my_tickets(text) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260813_maintenance_metrics.sql
-- -----------------------------------------------------------------------------
create table if not exists public.integration_runtime_metrics (
  id boolean primary key default true check(id),
  email_quota_remaining integer,
  sent_today integer not null default 0,
  sent_month integer not null default 0,
  inbox_runs_today integer not null default 0,
  outbox_runs_today integer not null default 0,
  metric_day date not null default current_date,
  metric_month date not null default date_trunc('month',current_date)::date,
  last_inbox_run timestamptz,
  last_outbox_run timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.integration_runtime_metrics enable row level security;
drop policy if exists integration_metrics_read on public.integration_runtime_metrics;
create policy integration_metrics_read on public.integration_runtime_metrics for select to authenticated
using(public.current_role() in ('tecnico','supervisor'));
insert into public.integration_runtime_metrics(id) values(true) on conflict do nothing;

create or replace function public.apps_script_report_metrics(p_secret text,p_kind text,p_sent integer,p_remaining integer)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  update public.integration_runtime_metrics set
    sent_today=case when metric_day=current_date then sent_today+greatest(p_sent,0) else greatest(p_sent,0) end,
    sent_month=case when metric_month=date_trunc('month',current_date)::date then sent_month+greatest(p_sent,0) else greatest(p_sent,0) end,
    inbox_runs_today=case when metric_day=current_date then inbox_runs_today+(p_kind='inbox')::int else (p_kind='inbox')::int end,
    outbox_runs_today=case when metric_day=current_date then outbox_runs_today+(p_kind='outbox')::int else (p_kind='outbox')::int end,
    metric_day=current_date,metric_month=date_trunc('month',current_date)::date,
    email_quota_remaining=p_remaining,
    last_inbox_run=case when p_kind='inbox' then now() else last_inbox_run end,
    last_outbox_run=case when p_kind='outbox' then now() else last_outbox_run end,updated_at=now()
  where id=true;
end $$;
grant execute on function public.apps_script_report_metrics(text,text,integer,integer) to anon;

create or replace function public.maintenance_metrics() returns jsonb
language plpgsql security definer set search_path=public as $$
declare m public.integration_runtime_metrics;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado'; end if;
  select * into m from public.integration_runtime_metrics where id=true;
  return jsonb_build_object(
    'database_bytes',pg_database_size(current_database()),
    'attachment_bytes',coalesce((select sum(size_bytes) from public.attachments),0),
    'attachment_count',(select count(*) from public.attachments),
    'ticket_count',(select count(*) from public.tickets),
    'outbox_pending',(select count(*) from public.email_outbox where status in ('pending','processing')),
    'outbox_failed',(select count(*) from public.email_outbox where status='failed'),
    'sent_today',m.sent_today,'sent_month',m.sent_month,'email_quota_remaining',m.email_quota_remaining,
    'inbox_runs_today',m.inbox_runs_today,'outbox_runs_today',m.outbox_runs_today,
    'last_inbox_run',m.last_inbox_run,'last_outbox_run',m.last_outbox_run,'updated_at',m.updated_at
  );
end $$;
grant execute on function public.maintenance_metrics() to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260814_lab_computer_count.sql
-- -----------------------------------------------------------------------------
alter table public.labs
  add column if not exists computer_count integer not null default 0;

alter table public.labs
  drop constraint if exists labs_computer_count_check;

alter table public.labs
  add constraint labs_computer_count_check check (computer_count >= 0);

-- -----------------------------------------------------------------------------
-- migrations/20260814_reservations.sql
-- -----------------------------------------------------------------------------
-- Módulo de reservas dos Laboratórios de Informática.
create table if not exists public.reservation_counter (
  singleton boolean primary key default true check(singleton),
  last_number bigint not null default 0
);
insert into public.reservation_counter(singleton,last_number) values(true,0) on conflict(singleton) do nothing;

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  protocol text not null unique,
  server_id uuid not null references public.servers(id),
  lab_id uuid not null references public.labs(id),
  subject text not null check(length(btrim(subject)) between 2 and 160),
  notes text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'Aguardando confirmação' check(status in ('Aguardando confirmação','Aguardando autorização','Autorizada','Cancelada')),
  source text not null default 'Publico' check(source in ('Publico','Equipe','CSV')),
  recurrence_group uuid not null default gen_random_uuid(),
  recurrence text not null default 'none' check(recurrence in ('none','weekly')),
  confirmation_token uuid not null default gen_random_uuid() unique,
  confirmed_at timestamptz,
  authorized_at timestamptz,
  authorized_by uuid references public.profiles(id),
  cancelled_at timestamptz,
  cancellation_reason text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(ends_at>starts_at),
  check(extract(epoch from (ends_at-starts_at))::integer % 2700=0)
);
create index if not exists reservations_schedule_idx on public.reservations(lab_id,starts_at,ends_at) where status<>'Cancelada';
create index if not exists reservations_server_idx on public.reservations(server_id,starts_at desc);

alter table public.reservations enable row level security;
drop policy if exists reservations_staff_read on public.reservations;
create policy reservations_staff_read on public.reservations for select to authenticated
using(public.current_role() in ('tecnico','supervisor'));

create or replace function public.next_reservation_protocol() returns text
language plpgsql security definer set search_path=public as $$
declare n bigint;
begin
  update public.reservation_counter set last_number=last_number+1 where singleton returning last_number into n;
  return 'RES-'||lpad(n::text,5,'0');
end $$;

create or replace function public.validate_reservation_slot(p_start timestamptz,p_end timestamptz)
returns void language plpgsql stable set search_path=public as $$
declare s timestamp:=p_start at time zone 'America/Cuiaba'; e timestamp:=p_end at time zone 'America/Cuiaba';
begin
  if extract(isodow from s) not between 1 and 6 or s::date<>e::date then raise exception 'Reservas são permitidas de segunda a sábado.'; end if;
  if extract(epoch from (p_end-p_start))::integer % 2700<>0 then raise exception 'A duração deve usar blocos de 45 minutos.'; end if;
  if not ((s::time>='07:00' and e::time<='12:35') or (s::time>='13:00' and e::time<='18:35') or (s::time>='18:45' and e::time<='22:50')) then
    raise exception 'Horário fora dos períodos de utilização dos laboratórios.';
  end if;
end $$;

create or replace function public.assert_reservation_available(p_lab uuid,p_start timestamptz,p_end timestamptz,p_ignore uuid default null)
returns void language plpgsql stable security definer set search_path=public as $$
begin
  perform public.validate_reservation_slot(p_start,p_end);
  if exists(select 1 from public.reservations where lab_id=p_lab and status<>'Cancelada' and id is distinct from p_ignore and starts_at<p_end and ends_at>p_start) then
    raise exception 'O laboratório já possui reserva neste horário.';
  end if;
end $$;

create or replace function public.reservation_payload(r public.reservations) returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('protocol',r.protocol,'reservation_id',r.id,'server_name',s.full_name,'title',r.subject,'lab',l.name,
 'starts_at',r.starts_at,'ends_at',r.ends_at,'status',r.status,'reason',r.cancellation_reason,
 'portal_url','https://coeritl.github.io/labinfo/','confirmation_url','https://coeritl.github.io/labinfo/?confirm_reservation='||r.confirmation_token::text)
 from public.servers s join public.labs l on l.id=r.lab_id where s.id=r.server_id
$$;

alter table public.email_outbox add column if not exists reservation_id uuid references public.reservations(id) on delete cascade;
alter table public.email_outbox alter column ticket_id drop not null;
alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check(event_type in (
 'recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido','novo_chamado_tecnico','resposta_servidor_tecnico',
 'reserva_confirmar','reserva_confirmada','reserva_autorizada','reserva_cancelada','reserva_alterada'
));

create or replace function public.create_public_reservation(p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_blocks integer,p_notes text default null,p_recurrence text default 'none',p_until date default null)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public as $$
declare s public.servers; r public.reservations; first_r public.reservations; finish timestamptz; occurrence timestamptz:=p_start; final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date); group_id uuid:=gen_random_uuid(); count_items integer:=0;
begin
 select * into s from public.servers where siape=btrim(p_siape) and active limit 1;
 if s.id is null then raise exception 'Servidor não localizado ou inativo.'; end if;
 if p_blocks not between 1 and 8 then raise exception 'Selecione entre 1 e 8 blocos de aula.'; end if;
 if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
 if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then raise exception 'A data final deve estar dentro dos próximos 180 dias.';end if;
 loop
   if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
     finish:=occurrence+(p_blocks*interval '45 minutes');perform public.assert_reservation_available(p_lab,occurrence,finish,null);
     insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
     values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence) returning * into r;
     if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
   end if;
   exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
   occurrence:=occurrence+interval '7 days';
   exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
 end loop;
 if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
 insert into public.email_outbox(reservation_id,recipient,event_type,payload) values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
 return query select first_r.id,first_r.protocol,first_r.status;
end $$;

create or replace function public.confirm_reservation(p_token uuid)
returns table(protocol text,status text,confirmed_at timestamptz) language plpgsql security definer set search_path=public as $$
declare r public.reservations; s public.servers;
begin
 select * into r from public.reservations where confirmation_token=p_token order by starts_at limit 1;
 if r.id is null then raise exception 'Link inválido ou reserva indisponível.'; end if;
 update public.reservations set status='Aguardando autorização',confirmed_at=coalesce(reservations.confirmed_at,now()),updated_at=now()
 where recurrence_group=r.recurrence_group and public.reservations.status in ('Aguardando confirmação','Aguardando autorização');
 select * into r from public.reservations where id=r.id;
 select * into s from public.servers where id=r.server_id;
 if not exists(select 1 from public.email_outbox where reservation_id=r.id and event_type='reserva_confirmada') then
   insert into public.email_outbox(reservation_id,recipient,event_type,payload) values(r.id,lower(s.email),'reserva_confirmada',public.reservation_payload(r));
 end if;
 return query select r.protocol,r.status,r.confirmed_at;
end $$;

create or replace function public.my_reservations(p_siape text)
returns table(id uuid,protocol text,subject text,lab text,starts_at timestamptz,ends_at timestamptz,status text,confirmed_at timestamptz,reason text)
language sql stable security definer set search_path=public as $$
 select r.id,r.protocol,r.subject,l.name,r.starts_at,r.ends_at,r.status,r.confirmed_at,r.cancellation_reason
 from public.reservations r join public.servers s on s.id=r.server_id join public.labs l on l.id=r.lab_id
 where s.siape=btrim(p_siape) and s.active order by r.starts_at desc limit 100
$$;

create or replace function public.public_reservation_schedule(p_lab uuid,p_from date,p_to date)
returns table(id uuid,subject text,server_name text,starts_at timestamptz,ends_at timestamptz,status text)
language plpgsql stable security definer set search_path=public as $$
begin
 if p_to<p_from or p_to>p_from+42 then raise exception 'Período de consulta inválido.';end if;
 return query select r.id,
   case when r.status='Autorizada' then r.subject else 'Horário em análise' end,
   case when r.status='Autorizada' then s.full_name else null end,
   r.starts_at,r.ends_at,r.status
 from public.reservations r join public.servers s on s.id=r.server_id
 where r.lab_id=p_lab and r.status<>'Cancelada'
   and (r.starts_at at time zone 'America/Cuiaba')::date between p_from and p_to
 order by r.starts_at;
end $$;

create or replace function public.staff_create_reservation(p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,p_blocks integer,p_notes text default null,p_source text default 'Equipe',p_recurrence text default 'none',p_until date default null)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare r public.reservations; first_r public.reservations; finish timestamptz; occurrence timestamptz:=p_start; final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);group_id uuid:=gen_random_uuid();
begin
 if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
 if p_blocks not between 1 and 8 then raise exception 'Quantidade de blocos inválida.'; end if;
 if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
 if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then raise exception 'Período inválido.';end if;
 loop
  if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
   finish:=occurrence+(p_blocks*interval '45 minutes');perform public.assert_reservation_available(p_lab,occurrence,finish,null);
   insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence)
   values(public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,'Autorizada',case when p_source='CSV' then 'CSV' else 'Equipe' end,now(),now(),auth.uid(),auth.uid(),group_id,p_recurrence) returning * into r;
   if first_r.id is null then first_r:=r;end if;
  end if;
  exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
  occurrence:=occurrence+interval '7 days';exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
 end loop;
 return first_r;
end $$;

create or replace function public.staff_update_reservation(p_id uuid,p_start timestamptz default null,p_lab uuid default null,p_status text default null,p_reason text default null)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare old public.reservations; r public.reservations; new_start timestamptz; new_end timestamptz; new_lab uuid; recipient text; event text;
begin
 if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
 select * into old from public.reservations where id=p_id for update;if old.id is null then raise exception 'Reserva não encontrada.';end if;
 new_start:=coalesce(p_start,old.starts_at);new_end:=new_start+(old.ends_at-old.starts_at);new_lab:=coalesce(p_lab,old.lab_id);
 if p_status is null then
   perform public.assert_reservation_available(new_lab,new_start,new_end,old.id);
   update public.reservations set starts_at=new_start,ends_at=new_end,lab_id=new_lab,updated_at=now() where id=p_id;
 else
   update public.reservations set status=p_status,
   authorized_at=case when p_status='Autorizada' then now() else authorized_at end,authorized_by=case when p_status='Autorizada' then auth.uid() else authorized_by end,
   cancelled_at=case when p_status='Cancelada' then now() else cancelled_at end,cancellation_reason=case when p_status='Cancelada' then nullif(btrim(p_reason),'') else cancellation_reason end,updated_at=now()
   where recurrence_group=old.recurrence_group;
 end if;
 select * into r from public.reservations where id=p_id;
 event:=case when p_status='Autorizada' then 'reserva_autorizada' when p_status='Cancelada' then 'reserva_cancelada' when p_start is not null or p_lab is not null then 'reserva_alterada' end;
 if event is not null then select lower(email) into recipient from public.servers where id=r.server_id;insert into public.email_outbox(reservation_id,recipient,event_type,payload) values(r.id,recipient,event,public.reservation_payload(r));end if;
 return r;
end $$;

grant execute on function public.create_public_reservation(text,uuid,text,timestamptz,integer,text,text,date) to anon,authenticated;
grant execute on function public.confirm_reservation(uuid) to anon,authenticated;
grant execute on function public.my_reservations(text) to anon,authenticated;
grant execute on function public.public_reservation_schedule(uuid,date,date) to anon,authenticated;
grant execute on function public.staff_create_reservation(uuid,uuid,text,timestamptz,integer,text,text,text,date) to authenticated;
grant execute on function public.staff_update_reservation(uuid,timestamptz,uuid,text,text) to authenticated;

do $$ begin alter publication supabase_realtime add table public.reservations; exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- migrations/20260814_drop_reservation_block_constraint.sql
-- -----------------------------------------------------------------------------
-- A duração real pode incluir intervalos entre aulas; a validação ocorre em
-- validate_reservation_slot, com mínimo de 45 minutos e máximo de 6 horas.
do $$
declare constraint_name text;
begin
  for constraint_name in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid=con.conrelid
    join pg_namespace ns on ns.oid=rel.relnamespace
    where ns.nspname='public'
      and rel.relname='reservations'
      and con.contype='c'
      and pg_get_constraintdef(con.oid) like '%2700%'
  loop
    execute format('alter table public.reservations drop constraint %I',constraint_name);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- migrations/20260814_fix_confirm_reservation_status.sql
-- -----------------------------------------------------------------------------
create or replace function public.confirm_reservation(p_token uuid)
returns table(protocol text,status text,confirmed_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare
  r public.reservations;
  s public.servers;
begin
  select reservation.* into r
  from public.reservations as reservation
  where reservation.confirmation_token=p_token
  order by reservation.starts_at
  limit 1;

  if r.id is null then
    raise exception 'Link inválido ou reserva indisponível.';
  end if;

  update public.reservations as reservation
  set status='Aguardando autorização',
      confirmed_at=coalesce(reservation.confirmed_at,now()),
      updated_at=now()
  where reservation.recurrence_group=r.recurrence_group
    and reservation.status in ('Aguardando confirmação','Aguardando autorização');

  select reservation.* into r
  from public.reservations as reservation
  where reservation.id=r.id;

  select server.* into s
  from public.servers as server
  where server.id=r.server_id;

  if not exists(
    select 1 from public.email_outbox as outbox
    where outbox.reservation_id=r.id
      and outbox.event_type='reserva_confirmada'
  ) then
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(r.id,lower(s.email),'reserva_confirmada',public.reservation_payload(r));
  end if;

  return query select r.protocol,r.status,r.confirmed_at;
end $$;

grant execute on function public.confirm_reservation(uuid) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260814_public_reservation_schedule.sql
-- -----------------------------------------------------------------------------
create or replace function public.public_reservation_schedule(p_lab uuid,p_from date,p_to date)
returns table(id uuid,subject text,server_name text,starts_at timestamptz,ends_at timestamptz,status text)
language plpgsql stable security definer set search_path=public as $$
begin
  if p_to<p_from or p_to>p_from+42 then raise exception 'Período de consulta inválido.'; end if;
  return query
  select r.id,
    case when r.status='Autorizada' then r.subject else 'Horário em análise' end,
    case when r.status='Autorizada' then s.full_name else null end,
    r.starts_at,r.ends_at,r.status
  from public.reservations r
  join public.servers s on s.id=r.server_id
  where r.lab_id=p_lab
    and r.status<>'Cancelada'
    and (r.starts_at at time zone 'America/Cuiaba')::date between p_from and p_to
  order by r.starts_at;
end $$;

grant execute on function public.public_reservation_schedule(uuid,date,date) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260814_reservation_admin_edit.sql
-- -----------------------------------------------------------------------------
-- Edição administrativa de uma ocorrência ou de toda a série recorrente.
create or replace function public.staff_edit_reservation(
  p_id uuid,p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,
  p_blocks integer,p_notes text default null,p_scope text default 'occurrence'
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  base public.reservations;
  item public.reservations;
  result public.reservations;
  target_start timestamptz;
  target_end timestamptz;
  shift interval;
  recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo inválido.'; end if;
  if p_blocks not between 1 and 8 then raise exception 'Quantidade de blocos inválida.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  shift:=p_start-base.starts_at;

  for item in
    select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+(p_blocks*interval '45 minutes');
    perform public.assert_reservation_available(p_lab,target_start,target_end,item.id);
    update public.reservations set server_id=p_server,lab_id=p_lab,subject=btrim(p_subject),notes=nullif(btrim(coalesce(p_notes,'')),''),starts_at=target_start,ends_at=target_end,updated_at=now() where id=item.id;
  end loop;

  select * into result from public.reservations where id=p_id;
  select lower(email) into recipient from public.servers where id=p_server and active;
  if recipient is null then raise exception 'Servidor não encontrado ou inativo.'; end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
  return result;
end $$;

grant execute on function public.staff_edit_reservation(uuid,uuid,uuid,text,timestamptz,integer,text,text) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260814_reservation_time_ranges.sql
-- -----------------------------------------------------------------------------
-- Permite informar inicio e fim reais, incluindo intervalos entre blocos de aula.
create or replace function public.validate_reservation_slot(p_start timestamptz,p_end timestamptz)
returns void language plpgsql stable set search_path=public as $$
declare
  s timestamp:=p_start at time zone 'America/Cuiaba';
  e timestamp:=p_end at time zone 'America/Cuiaba';
  duration_seconds integer:=extract(epoch from (p_end-p_start))::integer;
begin
  if extract(isodow from s) not between 1 and 6 or s::date<>e::date then
    raise exception 'Reservas são permitidas de segunda a sábado.';
  end if;
  if duration_seconds<2700 or duration_seconds>21600 then
    raise exception 'A reserva deve ter entre 45 minutos e 6 horas.';
  end if;
  if extract(minute from s)::integer%5<>0 or extract(minute from e)::integer%5<>0 then
    raise exception 'Informe início e fim em intervalos de 5 minutos.';
  end if;
  if not ((s::time>='07:00' and e::time<='12:35') or (s::time>='13:00' and e::time<='18:35') or (s::time>='18:45' and e::time<='22:50')) then
    raise exception 'Horário fora dos períodos de utilização dos laboratórios.';
  end if;
end $$;

create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public as $$
declare
  s public.servers; r public.reservations; first_r public.reservations;
  occurrence timestamptz:=p_start; finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid(); count_items integer:=0;
begin
  select * into s from public.servers where siape=btrim(p_siape) and active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos próximos 180 dias.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
      values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence)
      returning * into r;
      if count_items=0 then first_r:=r; end if;
      count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.'; end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
end $$;

grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260814_support_feedback_url.sql
-- -----------------------------------------------------------------------------
-- Mantém os links de acompanhamento na rota pública exclusiva de suporte.
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'protocol',t.protocol,'title',t.title,'description',t.description,'status',t.status,
    'server_name',coalesce(s.full_name,'Servidor'),'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),'created_at',t.created_at,
    'portal_url','https://coeritl.github.io/labinfo/suporte/',
    'feedback_url','https://coeritl.github.io/labinfo/suporte/?feedback='||t.feedback_token::text
  )
  from (select 1) x
  left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id
  left join public.categories c on c.id=t.category_id
$$;

-- -----------------------------------------------------------------------------
-- migrations/20260817_completion_confirmation_email.sql
-- -----------------------------------------------------------------------------
-- Inclui a solução registrada no e-mail de conclusão e mantém o link de
-- confirmação apontando diretamente para a página pública de suporte.
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'protocol',t.protocol,'title',t.title,'description',t.description,
    'status',t.status,'resolution',t.resolution,
    'server_name',coalesce(s.full_name,'Servidor'),
    'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),
    'created_at',t.created_at,'closed_at',t.closed_at,
    'portal_url','https://coeritl.github.io/labinfo/suporte/',
    'feedback_url','https://coeritl.github.io/labinfo/suporte/?feedback='||t.feedback_token::text
  )
  from (select 1) x
  left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id
  left join public.categories c on c.id=t.category_id
$$;

-- -----------------------------------------------------------------------------
-- migrations/20260818_lab_os_and_staff_edit.sql
-- -----------------------------------------------------------------------------
-- 1. Adiciona coluna de sistema operacional na tabela de laboratórios
alter table public.labs
  add column if not exists operating_system text;

-- 2. Função RPC segura para atualizar cadastro de técnicos e supervisores
drop function if exists public.update_staff_profile(uuid, text, text, text, text);

create or replace function public.update_staff_profile(
  p_user_id uuid,
  p_full_name text,
  p_siape text,
  p_role text,
  p_new_password text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_current_role text;
  v_clean_name text;
  v_clean_siape text;
  v_clean_role text;
begin
  -- Valida se quem está chamando é usuário autenticado
  select role into v_current_role from public.profiles where id = auth.uid() and active = true;
  if v_current_role is null then
    raise exception 'Apenas usuários autenticados podem editar perfis.';
  end if;

  v_clean_name := btrim(coalesce(p_full_name, ''));
  v_clean_siape := btrim(coalesce(p_siape, ''));
  v_clean_role := lower(btrim(coalesce(p_role, 'tecnico')));

  if length(v_clean_name) < 3 then
    raise exception 'Nome do técnico deve conter pelo menos 3 caracteres.';
  end if;

  if v_clean_siape !~ '^[0-9]{5,12}$' then
    raise exception 'SIAPE inválido (deve conter de 5 a 12 dígitos numéricos).';
  end if;

  if v_clean_role not in ('tecnico', 'supervisor') then
    v_clean_role := 'tecnico';
  end if;

  -- Impede duplicação de SIAPE entre usuários diferentes
  if exists (select 1 from public.profiles where siape = v_clean_siape and id <> p_user_id) then
    raise exception 'Este SIAPE já pertence a outro usuário cadastrado.';
  end if;

  -- Atualiza dados cadastrais em public.profiles
  update public.profiles
  set full_name = v_clean_name,
      siape = v_clean_siape,
      role = v_clean_role,
      active = true,
      updated_at = now()
  where id = p_user_id;

  if not found then
    raise exception 'Perfil de usuário não localizado.';
  end if;

  -- Se foi informada uma nova senha com pelo menos 8 dígitos, atualiza no auth.users
  if p_new_password is not null and length(btrim(p_new_password)) >= 8 then
    update auth.users
    set encrypted_password = crypt(btrim(p_new_password), gen_salt('bf')),
        updated_at = now()
    where id = p_user_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', p_user_id,
    'full_name', v_clean_name,
    'siape', v_clean_siape,
    'role', v_clean_role
  );
end $$;

grant execute on function public.update_staff_profile(uuid, text, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260818_live_chat.sql
-- -----------------------------------------------------------------------------
-- LabInfo TL — Migração para suporte a Chat ao Vivo entre Técnicos e Servidores
-- Execute no SQL Editor do Supabase para habilitar o módulo de chat em tempo real.

-- 1. Atualizar a constraint de tickets para aceitar 'Chat' como source
alter table public.tickets drop constraint if exists tickets_source_check;
alter table public.tickets add constraint tickets_source_check
  check (source in ('Formulario', 'Tecnico', 'Email', 'Chat'));

-- 2. Tabela de status online / disponibilidade dos técnicos
create table if not exists public.staff_chat_status (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  is_online boolean not null default false,
  last_heartbeat timestamptz not null default now()
);

-- 3. Tabela de sessões de chat
create table if not exists public.chat_sessions (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references servers(id),
  technician_id uuid references profiles(id),
  status text not null default 'waiting' check (status in ('waiting', 'active', 'closed', 'cancelled')),
  subject text,
  ticket_id uuid references tickets(id) on delete set null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  closed_at timestamptz,
  closed_by uuid references profiles(id),
  notes text
);

-- 4. Tabela de mensagens do chat
create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  sender_type text not null check (sender_type in ('server', 'technician', 'system')),
  sender_id uuid,
  sender_name text not null,
  message text not null,
  created_at timestamptz not null default now()
);

-- Índices para performance
create index if not exists chat_sessions_status_idx on public.chat_sessions(status, created_at desc);
create index if not exists chat_sessions_server_idx on public.chat_sessions(server_id, created_at desc);
create index if not exists chat_messages_session_idx on public.chat_messages(session_id, created_at asc);

-- 5. Habilitar Realtime
alter publication supabase_realtime add table public.staff_chat_status;
alter publication supabase_realtime add table public.chat_sessions;
alter publication supabase_realtime add table public.chat_messages;

alter table public.staff_chat_status replica identity full;
alter table public.chat_sessions replica identity full;
alter table public.chat_messages replica identity full;

-- 6. Habilitar RLS
alter table public.staff_chat_status enable row level security;
alter table public.chat_sessions enable row level security;
alter table public.chat_messages enable row level security;

-- Políticas de RLS
create policy "staff_status_read_all" on public.staff_chat_status
  for select using (true);

create policy "staff_status_write_auth" on public.staff_chat_status
  for all using (auth.role() = 'authenticated');

create policy "chat_sessions_read" on public.chat_sessions
  for select using (true);

create policy "chat_sessions_insert" on public.chat_sessions
  for insert with check (true);

create policy "chat_sessions_update" on public.chat_sessions
  for update using (auth.role() = 'authenticated' or status in ('waiting', 'active', 'closed'));

create policy "chat_messages_read" on public.chat_messages
  for select using (true);

create policy "chat_messages_insert" on public.chat_messages
  for insert with check (true);

-- 7. Funções RPC de Negócio

-- Obter disponibilidade geral (se há algum técnico online com heartbeat recente nos últimos 3 minutos)
drop function if exists public.get_chat_availability();
create or replace function public.get_chat_availability()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_online_count integer;
  v_technicians jsonb;
begin
  -- Marca como offline quem não deu heartbeat há mais de 3 minutos
  update public.staff_chat_status
  set is_online = false
  where is_online = true and last_heartbeat < (now() - interval '3 minutes');

  select count(*), jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name, 'role', p.role, 'email', p.email))
  into v_online_count, v_technicians
  from public.staff_chat_status s
  join public.profiles p on p.id = s.profile_id
  where s.is_online = true and p.active = true and p.role in ('tecnico', 'supervisor') and s.last_heartbeat >= (now() - interval '3 minutes');

  return jsonb_build_object(
    'available', (coalesce(v_online_count, 0) > 0),
    'online_count', coalesce(v_online_count, 0),
    'technicians', coalesce(v_technicians, '[]'::jsonb)
  );
end $$;
grant execute on function public.get_chat_availability() to anon, authenticated;

-- Atualizar status do técnico logado
drop function if exists public.set_staff_chat_status(boolean);
create or replace function public.set_staff_chat_status(p_online boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Apenas usuários autenticados podem alterar status.';
  end if;

  insert into public.staff_chat_status (profile_id, is_online, last_heartbeat)
  values (v_uid, p_online, now())
  on conflict (profile_id) do update
  set is_online = p_online,
      last_heartbeat = now();

  return p_online;
end $$;
grant execute on function public.set_staff_chat_status(boolean) to authenticated;

-- Heartbeat periódico do técnico logado para manter status ativo
drop function if exists public.staff_chat_heartbeat();
create or replace function public.staff_chat_heartbeat()
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then return false; end if;

  update public.staff_chat_status
  set last_heartbeat = now()
  where profile_id = v_uid and is_online = true;

  return true;
end $$;
grant execute on function public.staff_chat_heartbeat() to authenticated;

-- Solicitar uma nova sessão de chat pelo servidor/docente (validação por SIAPE)
drop function if exists public.request_chat_session(text, text);
create or replace function public.request_chat_session(p_siape text, p_subject text)
returns table(session_id uuid, server_id uuid, server_name text, server_email text, status text)
language plpgsql security definer set search_path = public as $$
declare
  v_server record;
  v_session_id uuid;
begin
  select s.id, s.full_name, s.email, s.active into v_server
  from public.servers s
  where s.siape = trim(p_siape) and s.active = true;

  if v_server.id is null then
    raise exception 'SIAPE não localizado ou cadastro inativo. Procure a equipe técnica.';
  end if;

  insert into public.chat_sessions(server_id, status, subject)
  values (v_server.id, 'waiting', left(coalesce(nullif(trim(p_subject), ''), 'Atendimento rápido via chat'), 160))
  returning chat_sessions.id into v_session_id;

  -- Mensagem automática do sistema de boas-vindas
  insert into public.chat_messages(session_id, sender_type, sender_name, message)
  values (v_session_id, 'system', 'Sistema LabInfo', 'Sua solicitação foi enviada aos técnicos de plantão. Aguarde um momento enquanto um técnico se conecta.');

  return query
  select v_session_id, v_server.id, v_server.full_name, v_server.email, 'waiting'::text;
end $$;
grant execute on function public.request_chat_session(text, text) to anon, authenticated;

-- Técnico aceita a sessão de chat
drop function if exists public.accept_chat_session(uuid);
create or replace function public.accept_chat_session(p_session_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_uid uuid;
  v_tech_name text;
  v_first_name text;
  v_session record;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Apenas técnicos autenticados podem aceitar chats.';
  end if;

  select coalesce(p.full_name, 'Técnico') into v_tech_name
  from public.profiles p
  where p.id = v_uid;

  if v_tech_name is null or length(trim(v_tech_name)) = 0 then
    v_tech_name := 'Técnico de Plantão';
  end if;

  v_first_name := coalesce(nullif(split_part(trim(v_tech_name), ' ', 1), ''), 'Técnico(a)');

  update public.chat_sessions cs
  set technician_id = coalesce(cs.technician_id, v_uid),
      status = 'active',
      started_at = coalesce(cs.started_at, now())
  where cs.id = p_session_id and cs.status in ('waiting', 'active');

  select cs.*, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  left join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  -- Insere aviso no chat informando quem atendeu (se ainda não houver aviso)
  if not exists (
    select 1 from public.chat_messages cm
    where cm.session_id = p_session_id and cm.sender_type = 'system' and cm.message like '%entrou na sala%'
  ) then
    insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
    values (p_session_id, 'system', v_uid, 'Sistema LabInfo', 'O(A) técnico(a) ' || v_tech_name || ' entrou na sala e iniciou o atendimento.');
  end if;

  -- Mensagem automática de boas-vindas personalizada em nome do próprio perfil que atendeu
  if not exists (
    select 1 from public.chat_messages cm
    where cm.session_id = p_session_id and cm.sender_type = 'technician'
  ) then
    insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
    values (p_session_id, 'technician', v_uid, v_tech_name, 'Olá, sou ' || v_first_name || '. Em que posso ajudar?');
  end if;

  return jsonb_build_object(
    'session_id', v_session.id,
    'technician_id', v_uid,
    'technician_name', v_tech_name,
    'status', v_session.status,
    'server_name', v_session.server_name,
    'server_siape', v_session.server_siape,
    'server_email', v_session.server_email,
    'subject', v_session.subject
  );
end $$;
grant execute on function public.accept_chat_session(uuid) to authenticated;

-- Enviar mensagem no chat (pelo servidor ou pelo técnico)
drop function if exists public.send_chat_message(uuid, text, text, text, text);
drop function if exists public.send_chat_message(uuid, text, text, text);
drop function if exists public.send_chat_message(uuid, text, text);
create or replace function public.send_chat_message(
  p_session_id uuid,
  p_sender_type text,
  p_message text,
  p_sender_name text default null,
  p_siape text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_session record;
  v_sender_name text := trim(coalesce(p_sender_name, ''));
  v_sender_id uuid := null;
  v_msg_id bigint;
  v_now timestamptz := now();
begin
  if length(trim(p_message)) < 1 then
    raise exception 'A mensagem não pode ser vazia.';
  end if;

  select cs.*, s.full_name as server_name, s.siape as server_siape
  into v_session
  from public.chat_sessions cs
  left join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  if v_session.status = 'closed' then
    raise exception 'Este atendimento já foi encerrado.';
  end if;

  if p_sender_type = 'technician' then
    v_sender_id := auth.uid();
    if v_sender_id is null then
      raise exception 'Acesso não autorizado.';
    end if;
    select coalesce(p.full_name, 'Técnico') into v_sender_name
    from public.profiles p
    where p.id = v_sender_id;

    if v_sender_name is null or length(trim(v_sender_name)) = 0 then
      v_sender_name := 'Técnico de Plantão';
    end if;
  elsif p_sender_type = 'server' then
    if length(v_sender_name) < 2 then
      v_sender_name := coalesce(v_session.server_name, 'Servidor');
    end if;
    v_sender_id := v_session.server_id;
  else
    p_sender_type := 'system';
    v_sender_name := 'Sistema LabInfo';
  end if;

  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message, created_at)
  values (p_session_id, p_sender_type, v_sender_id, v_sender_name, trim(p_message), v_now)
  returning chat_messages.id into v_msg_id;

  return jsonb_build_object(
    'id', v_msg_id,
    'session_id', p_session_id,
    'sender_type', p_sender_type,
    'sender_name', v_sender_name,
    'message', trim(p_message),
    'created_at', v_now
  );
end $$;
grant execute on function public.send_chat_message(uuid, text, text, text, text) to anon, authenticated;

-- Gerar chamado oficial a partir do chat ao vivo (ação assistida do técnico)
drop function if exists public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text);
drop function if exists public.create_ticket_from_chat(uuid, uuid, uuid, text, text);
create or replace function public.create_ticket_from_chat(
  p_session_id uuid,
  p_lab uuid default null,
  p_category uuid default null,
  p_title text default null,
  p_resolution text default null,
  p_status text default 'Concluído'
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_session record;
  v_tech_id uuid;
  v_protocol text;
  v_new_ticket_id uuid;
  v_chat_transcript text := '';
  v_msg record;
  v_title text;
  v_status text := coalesce(nullif(trim(p_status), ''), 'Concluído');
begin
  v_tech_id := auth.uid();
  if v_tech_id is null then
    raise exception 'Apenas técnicos autenticados podem gerar chamados a partir do chat.';
  end if;

  select cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  -- Monta a transcrição do diálogo formatada
  for v_msg in
    select cm.sender_name, cm.sender_type, cm.message, cm.created_at
    from public.chat_messages cm
    where cm.session_id = p_session_id
    order by cm.created_at asc
  loop
    v_chat_transcript := v_chat_transcript || '[' || to_char(v_msg.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '] ' || v_msg.sender_name || ': ' || v_msg.message || E'\n';
  end loop;

  -- Gera número de protocolo
  v_protocol := public.next_protocol(p_lab);
  v_title := coalesce(nullif(trim(p_title), ''), 'Atendimento via Chat: ' || coalesce(v_session.subject, 'Dúvida/Suporte'));

  -- Cria o chamado
  insert into public.tickets(
    protocol,
    server_id,
    lab_id,
    category_id,
    title,
    description,
    status,
    source,
    assigned_to,
    resolution,
    started_at,
    closed_at
  )
  values (
    v_protocol,
    v_session.server_id,
    p_lab,
    p_category,
    left(v_title, 100),
    E'Atendimento realizado via Chat ao Vivo com a equipe de TI.\n\n--- TRANSCRIÇÃO DA CONVERSA ---\n' || v_chat_transcript,
    v_status,
    'Chat',
    v_tech_id,
    case when v_status = 'Concluído' then coalesce(nullif(trim(p_resolution), ''), 'Atendimento concluído via Chat ao Vivo.') else null end,
    coalesce(v_session.started_at, now()),
    case when v_status = 'Concluído' then now() else null end
  )
  returning tickets.id into v_new_ticket_id;

  -- Registra no histórico do chamado
  insert into public.ticket_updates(ticket_id, author_id, message, kind)
  values (
    v_new_ticket_id,
    v_tech_id,
    case when v_status = 'Concluído'
      then 'Chamado gerado e concluído a partir do Chat ao Vivo. Solução registrada: ' || coalesce(nullif(trim(p_resolution), ''), 'Atendimento prestado em tempo real.')
      else 'Chamado gerado a partir do Chat ao Vivo e mantido em atendimento presencial pela equipe técnica.'
    end,
    case when v_status = 'Concluído' then 'fechamento' else 'status' end
  );

  -- Atualiza e encerra a sessão de chat vinculando ao chamado
  update public.chat_sessions cs
  set status = 'closed',
      ticket_id = v_new_ticket_id,
      closed_at = now(),
      closed_by = v_tech_id,
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  where cs.id = p_session_id;

  -- Notificação no chat para o docente
  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  values (
    p_session_id,
    'system',
    v_tech_id,
    'Sistema LabInfo',
    'Atendimento finalizado! Foi gerado o protocolo oficial de chamado: ' || v_protocol || '. Você também receberá os detalhes no seu e-mail institucional.'
  );

  return jsonb_build_object(
    'ticket_id', v_new_ticket_id,
    'protocol', v_protocol,
    'status', v_status
  );
end $$;
grant execute on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) to authenticated;

-- Encerrar chat simples (caso queira encerrar pelo docente ou sem formulário)
drop function if exists public.close_chat_session(uuid, text);
drop function if exists public.close_chat_session(uuid);
create or replace function public.close_chat_session(p_session_id uuid, p_notes text default null)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  update public.chat_sessions cs
  set status = 'closed',
      closed_at = now(),
      closed_by = auth.uid(),
      notes = coalesce(p_notes, cs.notes)
  where cs.id = p_session_id and cs.status in ('waiting', 'active');

  insert into public.chat_messages(session_id, sender_type, sender_name, message)
  values (p_session_id, 'system', 'Sistema LabInfo', 'Atendimento de chat encerrado.');

  return true;
end $$;
grant execute on function public.close_chat_session(uuid, text) to anon, authenticated;

-- Obter dados consolidados da sessao de chat (publico ou autenticado)
drop function if exists public.get_public_chat_session(uuid);
create or replace function public.get_public_chat_session(p_session_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_session record;
  v_tech_name text := null;
  v_protocol text := null;
begin
  select cs.*, s.full_name as server_name, s.siape as server_siape
  into v_session
  from public.chat_sessions cs
  left join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    return null;
  end if;

  if v_session.technician_id is not null then
    select p.full_name into v_tech_name
    from public.profiles p
    where p.id = v_session.technician_id;
  end if;

  if v_session.ticket_id is not null then
    select t.protocol into v_protocol
    from public.tickets t
    where t.id = v_session.ticket_id;
  end if;

  return jsonb_build_object(
    'id', v_session.id,
    'status', v_session.status,
    'subject', v_session.subject,
    'server_name', v_session.server_name,
    'server_siape', v_session.server_siape,
    'technician_name', coalesce(v_tech_name, 'Técnico de Plantão'),
    'protocol', v_protocol,
    'started_at', v_session.started_at,
    'closed_at', v_session.closed_at
  );
end $$;
grant execute on function public.get_public_chat_session(uuid) to anon, authenticated;

-- Obter lista consolidada de sessoes para o painel administrativo do tecnico
drop function if exists public.get_admin_chat_dashboard();
create or replace function public.get_admin_chat_dashboard()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_sessions jsonb;
begin
  -- Auto-encerra solicitações que ficaram esperando por mais de 20 minutos sem atendimento
  update public.chat_sessions
  set status = 'closed',
      closed_at = now(),
      notes = coalesce(notes, 'Expirado por inatividade na fila')
  where status = 'waiting' and created_at < (now() - interval '20 minutes');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cs.id,
    'status', cs.status,
    'subject', cs.subject,
    'created_at', cs.created_at,
    'started_at', cs.started_at,
    'closed_at', cs.closed_at,
    'notes', cs.notes,
    'server_id', cs.server_id,
    'server_name', coalesce(s.full_name, 'Servidor'),
    'server_siape', s.siape,
    'server_email', s.email,
    'technician_id', cs.technician_id,
    'technician_name', p.full_name,
    'ticket_id', cs.ticket_id,
    'ticket_protocol', t.protocol
  ) order by cs.created_at desc), '[]'::jsonb)
  into v_sessions
  from (
    select * from public.chat_sessions
    order by created_at desc
    limit 60
  ) cs
  left join public.servers s on s.id = cs.server_id
  left join public.profiles p on p.id = cs.technician_id
  left join public.tickets t on t.id = cs.ticket_id;

  return v_sessions;
end $$;
grant execute on function public.get_admin_chat_dashboard() to authenticated;

-- Limpar chamadas pendentes da fila de espera
drop function if exists public.clear_stale_chat_sessions();
create or replace function public.clear_stale_chat_sessions()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_count integer;
begin
  update public.chat_sessions
  set status = 'closed',
      closed_at = now(),
      notes = 'Fila limpa pelo técnico'
  where status = 'waiting';

  get diagnostics v_count = row_count;
  return v_count;
end $$;
grant execute on function public.clear_stale_chat_sessions() to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260818_fix_create_ticket_from_chat_ambiguity.sql
-- -----------------------------------------------------------------------------
-- Migration: Resolução de ambiguidade na função create_ticket_from_chat
-- Elimina sobrecargas duplicadas e estabelece uma assinatura única canônica

-- 1. Remove explicitamente todas as versões sobrecarregadas anteriores
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, uuid, uuid, text, text, public.ticket_status);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid, text, text);
DROP FUNCTION IF EXISTS public.create_ticket_from_chat(uuid);

-- 2. Cria a função canônica com assinatura única
CREATE OR REPLACE FUNCTION public.create_ticket_from_chat(
  p_session_id uuid,
  p_lab uuid default null,
  p_category uuid default null,
  p_title text default null,
  p_resolution text default null,
  p_status text default 'Concluído'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_session record;
  v_tech_id uuid;
  v_protocol text;
  v_new_ticket_id uuid;
  v_chat_transcript text := '';
  v_msg record;
  v_title text;
  v_status_clean text;
  v_status_enum public.ticket_status;
BEGIN
  -- Garante status válido
  v_status_clean := coalesce(nullif(trim(p_status), ''), 'Concluído');
  IF v_status_clean NOT IN ('Recebido', 'Em atendimento', 'Concluído') THEN
    v_status_clean := 'Concluído';
  END IF;
  v_status_enum := v_status_clean::public.ticket_status;

  SELECT cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  INTO v_session
  FROM public.chat_sessions cs
  JOIN public.servers s ON s.id = cs.server_id
  WHERE cs.id = p_session_id;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'Sessão de chat não encontrada.';
  END IF;

  -- Se já tiver chamado vinculado, apenas retorna os dados existentes
  IF v_session.ticket_id IS NOT NULL THEN
    SELECT protocol INTO v_protocol FROM public.tickets WHERE id = v_session.ticket_id;
    RETURN jsonb_build_object(
      'ticket_id', v_session.ticket_id,
      'protocol', v_protocol,
      'status', v_status_clean
    );
  END IF;

  -- Identifica o técnico responsável
  v_tech_id := auth.uid();
  IF v_tech_id IS NULL THEN
    v_tech_id := v_session.technician_id;
  END IF;

  -- Monta a transcrição do diálogo formatada
  FOR v_msg IN
    SELECT cm.sender_name, cm.sender_type, cm.message, cm.created_at
    FROM public.chat_messages cm
    WHERE cm.session_id = p_session_id
    ORDER BY cm.created_at ASC
  LOOP
    v_chat_transcript := v_chat_transcript || '[' || to_char(v_msg.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '] ' || v_msg.sender_name || ': ' || v_msg.message || E'\n';
  END LOOP;

  -- Gera número de protocolo
  v_protocol := public.next_protocol(p_lab);
  v_title := coalesce(nullif(trim(p_title), ''), 'Atendimento via Chat: ' || coalesce(v_session.subject, 'Dúvida/Suporte'));

  -- Cria o chamado oficial com feedback_token
  INSERT INTO public.tickets(
    protocol,
    server_id,
    lab_id,
    category_id,
    title,
    description,
    status,
    source,
    assigned_to,
    resolution,
    started_at,
    closed_at,
    feedback_token
  )
  VALUES (
    v_protocol,
    v_session.server_id,
    p_lab,
    p_category,
    left(v_title, 100),
    E'Atendimento realizado via Chat ao Vivo com a equipe de TI.\n\n--- TRANSCRIÇÃO DA CONVERSA ---\n' || v_chat_transcript,
    v_status_enum,
    'Chat',
    v_tech_id,
    CASE WHEN v_status_clean = 'Concluído' THEN coalesce(nullif(trim(p_resolution), ''), 'Atendimento concluído via Chat ao Vivo.') ELSE NULL END,
    coalesce(v_session.started_at, now()),
    CASE WHEN v_status_clean = 'Concluído' THEN now() ELSE NULL END,
    gen_random_uuid()
  )
  RETURNING tickets.id INTO v_new_ticket_id;

  -- Registra no histórico do chamado
  INSERT INTO public.ticket_updates(ticket_id, author_id, message, kind)
  VALUES (
    v_new_ticket_id,
    v_tech_id,
    CASE WHEN v_status_clean = 'Concluído'
      THEN 'Chamado gerado e concluído a partir do Chat ao Vivo. Solução registrada: ' || coalesce(nullif(trim(p_resolution), ''), 'Atendimento prestado em tempo real.')
      ELSE 'Chamado gerado a partir do Chat ao Vivo e mantido em atendimento presencial pela equipe técnica.'
    END,
    CASE WHEN v_status_clean = 'Concluído' THEN 'fechamento' ELSE 'status' END
  );

  -- Atualiza e encerra a sessão de chat vinculando ao chamado
  UPDATE public.chat_sessions cs
  SET status = 'closed',
      ticket_id = v_new_ticket_id,
      closed_at = now(),
      closed_by = coalesce(v_tech_id, cs.closed_by),
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  WHERE cs.id = p_session_id;

  -- Notificação no chat para o docente
  INSERT INTO public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  VALUES (
    p_session_id,
    'system',
    v_tech_id,
    'Sistema LabInfo',
    'Atendimento finalizado! Um e-mail com os detalhes do chamado (' || v_protocol || ') e o link de confirmação foi enviado para ' || v_session.server_email || '.'
  );

  RETURN jsonb_build_object(
    'ticket_id', v_new_ticket_id,
    'protocol', v_protocol,
    'status', v_status_clean
  );
END $$;

GRANT EXECUTE ON FUNCTION public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) TO anon, authenticated;

-- 3. Atualiza close_chat_session para usar a assinatura canônica
CREATE OR REPLACE FUNCTION public.close_chat_session(p_session_id uuid, p_notes text default null)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_sess record;
BEGIN
  SELECT * INTO v_sess FROM public.chat_sessions WHERE id = p_session_id;
  IF v_sess.id IS NULL THEN
    RETURN false;
  END IF;

  -- Se a sessão estava ativa e ainda não tinha chamado gerado, gera automaticamente o chamado concluído
  IF v_sess.status = 'active' AND v_sess.ticket_id IS NULL THEN
    PERFORM public.create_ticket_from_chat(
      p_session_id,
      null,
      null,
      null,
      coalesce(p_notes, 'Atendimento concluído via Chat ao Vivo.'),
      'Concluído'
    );
    RETURN true;
  END IF;

  UPDATE public.chat_sessions cs
  SET status = 'closed',
      closed_at = now(),
      closed_by = coalesce(auth.uid(), cs.technician_id),
      notes = coalesce(p_notes, cs.notes)
  WHERE cs.id = p_session_id AND cs.status IN ('waiting', 'active');

  INSERT INTO public.chat_messages(session_id, sender_type, sender_name, message)
  VALUES (p_session_id, 'system', 'Sistema LabInfo', 'Atendimento de chat encerrado.');

  RETURN true;
END $$;

GRANT EXECUTE ON FUNCTION public.close_chat_session(uuid, text) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260818_fix_ticket_feedback.sql
-- -----------------------------------------------------------------------------
-- Correção e robustez na confirmação de atendimento pelo servidor (feedback via e-mail)
drop function if exists public.confirm_ticket_feedback(uuid);
drop function if exists public.confirm_ticket_feedback(text);

create or replace function public.confirm_ticket_feedback(p_token text)
returns table(protocol text, confirmed_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_uuid uuid;
  v_ticket public.tickets;
begin
  if p_token is null or btrim(p_token) = '' then
    raise exception 'Token de confirmação não fornecido.';
  end if;

  begin
    v_uuid := btrim(p_token)::uuid;
  exception when others then
    raise exception 'Link de confirmação inválido.';
  end;

  select * into v_ticket
  from public.tickets
  where feedback_token = v_uuid and deleted_at is null
  limit 1;

  if v_ticket.id is null then
    raise exception 'Chamado não localizado ou link expirado.';
  end if;

  update public.tickets
  set feedback_confirmed_at = coalesce(feedback_confirmed_at, now()),
      updated_at = now()
  where id = v_ticket.id;

  return query
  select v_ticket.protocol, coalesce(v_ticket.feedback_confirmed_at, now());
end $$;

grant execute on function public.confirm_ticket_feedback(text) to anon, authenticated;

-- Garante que o link gerado no e-mail de conclusão aponte corretamente para /labinfo/suporte/?feedback=
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'protocol', t.protocol,
    'title', t.title,
    'description', t.description,
    'status', t.status,
    'resolution', coalesce(t.resolution, 'Atendimento concluído.'),
    'server_name', coalesce(s.full_name, 'Servidor'),
    'lab', coalesce(l.name, 'Não informado'),
    'category', coalesce(c.name, 'Não informada'),
    'created_at', t.created_at,
    'closed_at', t.closed_at,
    'portal_url', 'https://coeritl.github.io/labinfo/suporte/',
    'feedback_url', 'https://coeritl.github.io/labinfo/suporte/?feedback=' || t.feedback_token::text
  )
  from (select 1) x
  left join public.servers s on s.id = t.server_id
  left join public.labs l on l.id = t.lab_id
  left join public.categories c on c.id = t.category_id
$$;

-- -----------------------------------------------------------------------------
-- migrations/20260818_chat_feedback_email.sql
-- -----------------------------------------------------------------------------
-- Migration: Envio automático de e-mail de feedback e chamado ao finalizar chat ao vivo
-- Garante que todo atendimento de chat finalizado gere o chamado com histórico e link de feedback no e-mail do servidor

create or replace function public.create_ticket_from_chat(
  p_session_id uuid,
  p_lab uuid default null,
  p_category uuid default null,
  p_title text default null,
  p_resolution text default null,
  p_status text default 'Concluído'
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_session record;
  v_tech_id uuid;
  v_protocol text;
  v_new_ticket_id uuid;
  v_chat_transcript text := '';
  v_msg record;
  v_title text;
  v_status text := coalesce(nullif(trim(p_status), ''), 'Concluído');
begin
  select cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  -- Se já tiver chamado vinculado, apenas retorna os dados existentes
  if v_session.ticket_id is not null then
    select protocol into v_protocol from public.tickets where id = v_session.ticket_id;
    return jsonb_build_object(
      'ticket_id', v_session.ticket_id,
      'protocol', v_protocol,
      'status', v_status
    );
  end if;

  -- Identifica o técnico responsável
  v_tech_id := auth.uid();
  if v_tech_id is null then
    v_tech_id := v_session.technician_id;
  end if;

  -- Monta a transcrição do diálogo formatada
  for v_msg in
    select cm.sender_name, cm.sender_type, cm.message, cm.created_at
    from public.chat_messages cm
    where cm.session_id = p_session_id
    order by cm.created_at asc
  loop
    v_chat_transcript := v_chat_transcript || '[' || to_char(v_msg.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '] ' || v_msg.sender_name || ': ' || v_msg.message || E'\n';
  end loop;

  -- Gera número de protocolo
  v_protocol := public.next_protocol(p_lab);
  v_title := coalesce(nullif(trim(p_title), ''), 'Atendimento via Chat: ' || coalesce(v_session.subject, 'Dúvida/Suporte'));

  -- Cria o chamado oficial com feedback_token
  insert into public.tickets(
    protocol,
    server_id,
    lab_id,
    category_id,
    title,
    description,
    status,
    source,
    assigned_to,
    resolution,
    started_at,
    closed_at,
    feedback_token
  )
  values (
    v_protocol,
    v_session.server_id,
    p_lab,
    p_category,
    left(v_title, 100),
    E'Atendimento realizado via Chat ao Vivo com a equipe de TI.\n\n--- TRANSCRIÇÃO DA CONVERSA ---\n' || v_chat_transcript,
    v_status,
    'Chat',
    v_tech_id,
    case when v_status = 'Concluído' then coalesce(nullif(trim(p_resolution), ''), 'Atendimento concluído via Chat ao Vivo.') else null end,
    coalesce(v_session.started_at, now()),
    case when v_status = 'Concluído' then now() else null end,
    gen_random_uuid()
  )
  returning tickets.id into v_new_ticket_id;

  -- Registra no histórico do chamado
  insert into public.ticket_updates(ticket_id, author_id, message, kind)
  values (
    v_new_ticket_id,
    v_tech_id,
    case when v_status = 'Concluído'
      then 'Chamado gerado e concluído a partir do Chat ao Vivo. Solução registrada: ' || coalesce(nullif(trim(p_resolution), ''), 'Atendimento prestado em tempo real.')
      else 'Chamado gerado a partir do Chat ao Vivo e mantido em atendimento presencial pela equipe técnica.'
    end,
    case when v_status = 'Concluído' then 'fechamento' else 'status' end
  );

  -- Atualiza e encerra a sessão de chat vinculando ao chamado
  update public.chat_sessions cs
  set status = 'closed',
      ticket_id = v_new_ticket_id,
      closed_at = now(),
      closed_by = coalesce(v_tech_id, cs.closed_by),
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  where cs.id = p_session_id;

  -- Notificação no chat para o docente
  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  values (
    p_session_id,
    'system',
    v_tech_id,
    'Sistema LabInfo',
    'Atendimento finalizado! Um e-mail com os detalhes do chamado (' || v_protocol || ') e o link de confirmação foi enviado para ' || v_session.server_email || '.'
  );

  return jsonb_build_object(
    'ticket_id', v_new_ticket_id,
    'protocol', v_protocol,
    'status', v_status
  );
end $$;

grant execute on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) to anon, authenticated;

-- Encerrar chat garantindo criação de chamado e e-mail de feedback se for uma conversa ativa
create or replace function public.close_chat_session(p_session_id uuid, p_notes text default null)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare
  v_sess record;
begin
  select * into v_sess from public.chat_sessions where id = p_session_id;
  if v_sess.id is null then
    return false;
  end if;

  -- Se a sessão estava ativa e ainda não tinha chamado gerado, gera automaticamente o chamado concluído
  if v_sess.status = 'active' and v_sess.ticket_id is null then
    perform public.create_ticket_from_chat(
      p_session_id,
      null,
      null,
      null,
      coalesce(p_notes, 'Atendimento concluído via Chat ao Vivo.'),
      'Concluído'
    );
    return true;
  end if;

  update public.chat_sessions cs
  set status = 'closed',
      closed_at = now(),
      closed_by = coalesce(auth.uid(), cs.technician_id),
      notes = coalesce(p_notes, cs.notes)
  where cs.id = p_session_id and cs.status in ('waiting', 'active');

  insert into public.chat_messages(session_id, sender_type, sender_name, message)
  values (p_session_id, 'system', 'Sistema LabInfo', 'Atendimento de chat encerrado.');

  return true;
end $$;

grant execute on function public.close_chat_session(uuid, text) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260819_ifms_schedule_intervals.sql
-- -----------------------------------------------------------------------------
-- Atualização dos horários de funcionamento e cálculo de blocos oficiais do IFMS Campus Três Lagoas.
-- Matutino: 07:00-12:35 (Intervalo 09:15-09:35)
-- Vespertino: 13:00-18:35 (Intervalo 15:15-15:35)
-- Noturno: 18:50-22:50 (Intervalo 21:05-21:20)

create or replace function public.calculate_reservation_end(p_start timestamptz, p_blocks integer)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  v_local_start timestamp := p_start at time zone 'America/Cuiaba';
  v_time_str text := to_char(v_local_start, 'HH24:MI');
  v_slot_starts text[] := array[
    '07:00','07:45','08:30','09:35','10:20','11:05','11:50',
    '13:00','13:45','14:30','15:35','16:20','17:05','17:50',
    '18:50','19:35','20:20','21:20','22:05'
  ];
  v_slot_ends text[] := array[
    '07:45','08:30','09:15','10:20','11:05','11:50','12:35',
    '13:45','14:30','15:15','16:20','17:05','17:50','18:35',
    '19:35','20:20','21:05','22:05','22:50'
  ];
  v_idx integer;
  v_target_idx integer;
  v_end_time_str text;
  v_max_in_period integer;
begin
  if p_blocks is null or p_blocks < 1 then
    p_blocks := 1;
  end if;

  -- Localiza se o horário inicial corresponde a um dos 19 blocos padrão do IFMS
  for i in 1..array_length(v_slot_starts, 1) loop
    if v_slot_starts[i] = v_time_str then
      v_idx := i;
      exit;
    end if;
  end loop;

  if v_idx is not null then
    -- Determina o limite do período (matutino=7, vespertino=14, noturno=19)
    if v_idx <= 7 then
      v_max_in_period := 7;
    elsif v_idx <= 14 then
      v_max_in_period := 14;
    else
      v_max_in_period := 19;
    end if;

    v_target_idx := least(v_max_in_period, v_idx + p_blocks - 1);
    v_end_time_str := v_slot_ends[v_target_idx];

    return (v_local_start::date || ' ' || v_end_time_str || ':00')::timestamp at time zone 'America/Cuiaba';
  end if;

  -- Fallback para horários customizados fora da grade padrão
  return p_start + (p_blocks * interval '45 minutes');
end $$;

-- Atualiza validação de intervalos de funcionamento
create or replace function public.validate_reservation_slot(p_start timestamptz, p_end timestamptz)
returns void language plpgsql stable set search_path = public as $$
declare
  s timestamp := p_start at time zone 'America/Cuiaba';
  e timestamp := p_end at time zone 'America/Cuiaba';
  duration_seconds integer := extract(epoch from (p_end - p_start))::integer;
begin
  if extract(isodow from s) not between 1 and 6 or s::date <> e::date then
    raise exception 'Reservas são permitidas de segunda a sábado.';
  end if;
  if duration_seconds < 2400 or duration_seconds > 21600 then
    raise exception 'A reserva deve ter entre 40 minutos e 6 horas.';
  end if;
  if extract(minute from s)::integer % 5 <> 0 or extract(minute from e)::integer % 5 <> 0 then
    raise exception 'Informe início e fim em intervalos de 5 minutos.';
  end if;
  if not (
    (s::time >= '07:00' and e::time <= '12:35') or
    (s::time >= '13:00' and e::time <= '18:35') or
    (s::time >= '18:45' and e::time <= '22:50')
  ) then
    raise exception 'Horário fora dos períodos de funcionamento dos laboratórios.';
  end if;
end $$;

-- Atualiza criação de reserva pelo técnico para usar o cálculo oficial de blocos com intervalos
create or replace function public.staff_create_reservation(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_blocks integer,
  p_notes text default null, p_source text default 'Equipe', p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path = public as $$
declare
  r public.reservations; first_r public.reservations; finish timestamptz;
  occurrence timestamptz := p_start;
  final_date date := coalesce(p_until, (p_start at time zone 'America/Cuiaba')::date);
  group_id uuid := gen_random_uuid();
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_blocks not between 1 and 8 then raise exception 'Quantidade de blocos inválida.'; end if;
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date < (p_start at time zone 'America/Cuiaba')::date or final_date > (p_start at time zone 'America/Cuiaba')::date + interval '180 days' then
    raise exception 'Período inválido.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish := public.calculate_reservation_end(occurrence, p_blocks);
      perform public.validate_reservation_slot(occurrence, finish);
      perform public.assert_reservation_available(p_lab, occurrence, finish, null);
      insert into public.reservations(
        protocol, server_id, lab_id, subject, notes, starts_at, ends_at, recurrence_group, recurrence, source
      )
      values(
        public.next_reservation_protocol(), p_server, p_lab, btrim(p_subject), nullif(btrim(p_notes),''), occurrence, finish, group_id, p_recurrence, p_source
      )
      returning * into r;
      if first_r.id is null then first_r := r; end if;
    end if;
    exit when p_recurrence = 'none' or (occurrence at time zone 'America/Cuiaba')::date >= final_date;
    occurrence := occurrence + interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date > final_date;
  end loop;
  return first_r;
end $$;

-- Atualiza edição de reserva para usar o cálculo oficial de blocos com intervalos
create or replace function public.staff_edit_reservation(
  p_id uuid, p_server uuid, p_lab uuid, p_subject text, p_start timestamptz,
  p_blocks integer, p_notes text default null, p_scope text default 'occurrence'
)
returns public.reservations language plpgsql security definer set search_path = public as $$
declare
  base public.reservations;
  item public.reservations;
  result public.reservations;
  target_start timestamptz;
  target_end timestamptz;
  shift interval;
  recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo inválido.'; end if;
  if p_blocks not between 1 and 8 then raise exception 'Quantidade de blocos inválida.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  select * into base from public.reservations where id = p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  shift := p_start - base.starts_at;

  for item in
    select * from public.reservations
    where id = p_id or (p_scope = 'series' and recurrence_group = base.recurrence_group)
    order by starts_at for update
  loop
    target_start := case when p_scope = 'series' then item.starts_at + shift else p_start end;
    target_end := public.calculate_reservation_end(target_start, p_blocks);
    perform public.validate_reservation_slot(target_start, target_end);
    perform public.assert_reservation_available(p_lab, target_start, target_end, item.id);
    update public.reservations
    set server_id = p_server,
        lab_id = p_lab,
        subject = btrim(p_subject),
        notes = nullif(btrim(coalesce(p_notes,'')), ''),
        starts_at = target_start,
        ends_at = target_end,
        updated_at = now()
    where id = item.id;
  end loop;

  select * into result from public.reservations where id = p_id;
  select lower(email) into recipient from public.servers where id = p_server and active;
  if recipient is not null then
    insert into public.email_outbox(reservation_id, recipient, event_type, payload)
    values(result.id, recipient, 'reserva_alterada', public.reservation_payload(result));
  end if;
  return result;
end $$;

-- -----------------------------------------------------------------------------
-- migrations/20260820_staff_reservation_ranges.sql
-- -----------------------------------------------------------------------------
-- Permite que técnicos criem e editem reservas por horário inicial e final.
-- As funções antigas baseadas em blocos são preservadas para compatibilidade.
create or replace function public.staff_create_reservation_range(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_source text default 'Equipe',
  p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  r public.reservations; first_r public.reservations;
  occurrence timestamptz:=p_start; finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'Período inválido.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(
        protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
        confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence
      ) values (
        public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),
        occurrence,finish,'Autorizada',case when p_source='CSV' then 'CSV' else 'Equipe' end,
        now(),now(),auth.uid(),auth.uid(),group_id,p_recurrence
      ) returning * into r;
      if first_r.id is null then first_r:=r; end if;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if first_r.id is null then raise exception 'A série não possui nenhuma data válida.'; end if;
  return first_r;
end $$;

create or replace function public.staff_edit_reservation_range(
  p_id uuid, p_server uuid, p_lab uuid, p_subject text,
  p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_scope text default 'occurrence'
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  base public.reservations; item public.reservations; result public.reservations;
  target_start timestamptz; target_end timestamptz;
  requested_duration interval:=p_end-p_start; shift interval; recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo inválido.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  shift:=p_start-base.starts_at;
  for item in
    select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+requested_duration;
    perform public.validate_reservation_slot(target_start,target_end);
    perform public.assert_reservation_available(p_lab,target_start,target_end,item.id);
    update public.reservations set
      server_id=p_server,lab_id=p_lab,subject=btrim(p_subject),
      notes=nullif(btrim(coalesce(p_notes,'')),''),starts_at=target_start,
      ends_at=target_end,updated_at=now()
    where id=item.id;
  end loop;
  select * into result from public.reservations where id=p_id;
  select lower(email) into recipient from public.servers where id=p_server and active;
  if recipient is not null then
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
  end if;
  return result;
end $$;

grant execute on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) to authenticated;
grant execute on function public.staff_edit_reservation_range(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260820_optional_reservation_notifications.sql
-- -----------------------------------------------------------------------------
-- Permite editar ou cancelar reservas sem obrigar o envio de e-mail.
-- As funções existentes são preservadas para compatibilidade com outras telas.

create or replace function public.staff_edit_reservation_range_notification(
  p_id uuid, p_server uuid, p_lab uuid, p_subject text,
  p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_scope text default 'occurrence',
  p_notify boolean default true
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  base public.reservations; item public.reservations; result public.reservations;
  target_start timestamptz; target_end timestamptz;
  requested_duration interval:=p_end-p_start; shift interval; recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo inválido.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  shift:=p_start-base.starts_at;
  for item in
    select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+requested_duration;
    perform public.validate_reservation_slot(target_start,target_end);
    perform public.assert_reservation_available(p_lab,target_start,target_end,item.id);
    update public.reservations set
      server_id=p_server,lab_id=p_lab,subject=btrim(p_subject),
      notes=nullif(btrim(coalesce(p_notes,'')),''),starts_at=target_start,
      ends_at=target_end,updated_at=now()
    where id=item.id;
  end loop;
  select * into result from public.reservations where id=p_id;
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=p_server and active;
    if recipient is not null then
      insert into public.email_outbox(reservation_id,recipient,event_type,payload)
      values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
    end if;
  end if;
  return result;
end $$;

create or replace function public.staff_cancel_reservation_notification(
  p_id uuid, p_reason text, p_notify boolean default true
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  base public.reservations; result public.reservations; recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento.'; end if;
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  update public.reservations set
    status='Cancelada',cancelled_at=now(),cancellation_reason=btrim(p_reason),updated_at=now()
  where id=base.id or (base.recurrence_group is not null and recurrence_group=base.recurrence_group);
  select * into result from public.reservations where id=p_id;
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=result.server_id and active;
    if recipient is not null then
      insert into public.email_outbox(reservation_id,recipient,event_type,payload)
      values(result.id,recipient,'reserva_cancelada',public.reservation_payload(result));
    end if;
  end if;
  return result;
end $$;

grant execute on function public.staff_edit_reservation_range_notification(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text,boolean) to authenticated;
grant execute on function public.staff_cancel_reservation_notification(uuid,text,boolean) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260820_restore_completion_feedback_payload.sql
-- -----------------------------------------------------------------------------
-- Consolida o payload de e-mail após a liberação de remetentes não cadastrados.
-- Mantém guest_email e restaura os dados necessários ao e-mail de conclusão.
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'protocol', t.protocol,
    'title', t.title,
    'description', t.description,
    'status', t.status,
    'resolution', coalesce(t.resolution, 'Atendimento concluído.'),
    'server_name', coalesce(s.full_name, t.guest_email, 'Remetente por e-mail'),
    'lab', coalesce(l.name, 'Não informado'),
    'category', coalesce(c.name, 'Não informada'),
    'created_at', t.created_at,
    'closed_at', t.closed_at,
    'portal_url', 'https://labinfo.tl.ifms.edu.br/suporte/',
    'feedback_url', 'https://labinfo.tl.ifms.edu.br/suporte/?feedback=' || t.feedback_token::text
  )
  from (select 1) x
  left join public.servers s on s.id = t.server_id
  left join public.labs l on l.id = t.lab_id
  left join public.categories c on c.id = t.category_id
$$;

-- -----------------------------------------------------------------------------
-- migrations/20260821_reservation_production_hardening.sql
-- -----------------------------------------------------------------------------
-- Proteções finais do módulo de reservas para uso em produção.
create extension if not exists btree_gist with schema extensions;

alter table public.reservations add column if not exists confirmation_expires_at timestamptz;
update public.reservations set confirmation_expires_at=created_at+interval '72 hours' where confirmation_expires_at is null;
alter table public.reservations
  alter column confirmation_expires_at set default (now()+interval '72 hours'),
  alter column confirmation_expires_at set not null;

alter table public.reservations drop constraint if exists reservations_no_schedule_overlap;
alter table public.reservations add constraint reservations_no_schedule_overlap
  exclude using gist (lab_id with =,tstzrange(starts_at,ends_at,'[)') with &&)
  where (status<>'Cancelada');

create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;r public.reservations;first_r public.reservations;
  occurrence timestamptz:=p_start;finish timestamptz;requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();count_items integer:=0;
begin
  select * into s from public.servers where siape=btrim(p_siape) and active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para reservas públicas.';
  end if;
  if p_start<=now() then raise exception 'Não é possível solicitar uma reserva em data ou horário passado.';end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.';end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos próximos 180 dias.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
      values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence)
      returning * into r;
      if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
exception when exclusion_violation then
  raise exception 'O laboratório já possui reserva neste horário.';
end $$;

create or replace function public.confirm_reservation(p_token uuid)
returns table(protocol text,status text,confirmed_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare r public.reservations;s public.servers;
begin
  select reservation.* into r from public.reservations reservation
  where reservation.confirmation_token=p_token order by reservation.starts_at limit 1 for update;
  if r.id is null then raise exception 'Link inválido ou reserva indisponível.';end if;
  if r.status not in ('Aguardando confirmação','Aguardando autorização') then
    raise exception 'Esta reserva não está mais aguardando confirmação.';
  end if;
  if r.confirmed_at is null and r.confirmation_expires_at<now() then
    raise exception 'Este link de confirmação expirou. Entre em contato com a equipe técnica.';
  end if;
  if r.confirmed_at is null then
    update public.reservations reservation set status='Aguardando autorização',confirmed_at=now(),updated_at=now()
    where reservation.recurrence_group=r.recurrence_group and reservation.status='Aguardando confirmação';
  end if;
  select reservation.* into r from public.reservations reservation where reservation.id=r.id;
  select server.* into s from public.servers server where server.id=r.server_id and server.active;
  if r.confirmed_at is not null and s.id is not null and not exists(
    select 1 from public.email_outbox outbox where outbox.reservation_id=r.id and outbox.event_type='reserva_confirmada'
  ) then
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(r.id,lower(s.email),'reserva_confirmada',public.reservation_payload(r));
  end if;
  return query select r.protocol,r.status,r.confirmed_at;
end $$;

create or replace function public.public_reservation_schedule(p_lab uuid,p_from date,p_to date)
returns table(id uuid,subject text,server_name text,starts_at timestamptz,ends_at timestamptz,status text)
language plpgsql stable security definer set search_path=public as $$
begin
  if p_to<p_from or p_to>p_from+42 then raise exception 'Período de consulta inválido.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para consulta pública.';
  end if;
  return query select r.id,
    case when r.status='Autorizada' then r.subject else 'Horário em análise' end,
    case when r.status='Autorizada' then s.full_name else null end,
    r.starts_at,r.ends_at,r.status
  from public.reservations r join public.servers s on s.id=r.server_id
  where r.lab_id=p_lab and r.status<>'Cancelada'
    and (r.starts_at at time zone 'America/Cuiaba')::date between p_from and p_to order by r.starts_at;
end $$;

grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;
grant execute on function public.confirm_reservation(uuid) to anon,authenticated;
grant execute on function public.public_reservation_schedule(uuid,date,date) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260821_fix_public_reservation_id_ambiguity.sql
-- -----------------------------------------------------------------------------
-- Qualifica a coluna id nas funções que também retornam um campo chamado id.
create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;r public.reservations;first_r public.reservations;
  occurrence timestamptz:=p_start;finish timestamptz;requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();count_items integer:=0;
begin
  select server.* into s from public.servers server where server.siape=btrim(p_siape) and server.active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para reservas públicas.';
  end if;
  if p_start<=now() then raise exception 'Não é possível solicitar uma reserva em data ou horário passado.';end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.';end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos próximos 180 dias.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
      values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence)
      returning * into r;
      if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
exception when exclusion_violation then
  raise exception 'O laboratório já possui reserva neste horário.';
end $$;

create or replace function public.public_reservation_schedule(p_lab uuid,p_from date,p_to date)
returns table(id uuid,subject text,server_name text,starts_at timestamptz,ends_at timestamptz,status text)
language plpgsql stable security definer set search_path=public as $$
begin
  if p_to<p_from or p_to>p_from+42 then raise exception 'Período de consulta inválido.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para consulta pública.';
  end if;
  return query select r.id,
    case when r.status='Autorizada' then r.subject else 'Horário em análise' end,
    case when r.status='Autorizada' then s.full_name else null end,
    r.starts_at,r.ends_at,r.status
  from public.reservations r join public.servers s on s.id=r.server_id
  where r.lab_id=p_lab and r.status<>'Cancelada'
    and (r.starts_at at time zone 'America/Cuiaba')::date between p_from and p_to order by r.starts_at;
end $$;

grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;
grant execute on function public.public_reservation_schedule(uuid,date,date) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260821_lab_reservation_visibility.sql
-- -----------------------------------------------------------------------------
alter table public.labs
  add column if not exists reservation_enabled boolean not null default false;

comment on column public.labs.reservation_enabled is
  'Define se o laboratório aparece na agenda e nos formulários de reserva. Não interfere na abertura de chamados.';

-- Preserva na agenda os espaços que já eram administrados pelo LabInfo.
update public.labs
set reservation_enabled = true
where active = true
  and lower(name) in (
    'laboratório 01',
    'laboratório 02',
    'laboratório 03',
    'laboratório 04',
    'laboratório 05',
    'laboratório de hardware'
  );

-- -----------------------------------------------------------------------------
-- migrations/20260821_reservation_admin_pagination.sql
-- -----------------------------------------------------------------------------
-- Consultas compactas para o painel: resumo por série e contadores sem baixar ocorrências.
create or replace function public.staff_reservation_stats()
returns table(pending bigint,authorized bigint,cancelled bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.';end if;
  return query
  with series as (
    select recurrence_group,(array_agg(status order by starts_at))[1] series_status
    from public.reservations group by recurrence_group
  )
  select
    count(*) filter(where series_status in ('Aguardando confirmação','Aguardando autorização')),
    count(*) filter(where series_status='Autorizada'),
    count(*) filter(where series_status='Cancelada')
  from series;
end $$;

create or replace function public.staff_reservation_history_page(
  p_search text default null,p_offset integer default 0,p_limit integer default 20
)
returns table(
  id uuid,protocol text,recurrence_group uuid,server_id uuid,server_name text,
  lab_id uuid,lab_name text,subject text,notes text,starts_at timestamptz,
  ends_at timestamptz,last_at timestamptz,status text,source text,
  confirmed_at timestamptz,cancellation_reason text,occurrence_count bigint,total_count bigint
)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.';end if;
  return query
  with grouped as (
    select
      (array_agg(r.id order by r.starts_at))[1] id,
      (array_agg(r.protocol order by r.starts_at))[1] protocol,
      r.recurrence_group,
      (array_agg(r.server_id order by r.starts_at))[1] server_id,
      (array_agg(s.full_name order by r.starts_at))[1] server_name,
      (array_agg(r.lab_id order by r.starts_at))[1] lab_id,
      (array_agg(l.name order by r.starts_at))[1] lab_name,
      (array_agg(r.subject order by r.starts_at))[1] subject,
      (array_agg(r.notes order by r.starts_at))[1] notes,
      min(r.starts_at) starts_at,
      (array_agg(r.ends_at order by r.starts_at))[1] ends_at,
      max(r.starts_at) last_at,
      (array_agg(r.status order by r.starts_at))[1] status,
      (array_agg(r.source order by r.starts_at))[1] source,
      (array_agg(r.confirmed_at order by r.starts_at))[1] confirmed_at,
      (array_agg(r.cancellation_reason order by r.starts_at))[1] cancellation_reason,
      count(*) occurrence_count,
      lower(string_agg(concat_ws(' ',r.protocol,r.subject,s.full_name,l.name,r.status),' ')) search_text
    from public.reservations r
    join public.servers s on s.id=r.server_id
    join public.labs l on l.id=r.lab_id
    where r.status not in ('Aguardando confirmação','Aguardando autorização')
    group by r.recurrence_group
  ),filtered as (
    select * from grouped
    where nullif(btrim(coalesce(p_search,'')),'') is null
       or search_text like '%'||lower(btrim(p_search))||'%'
  )
  select f.id,f.protocol,f.recurrence_group,f.server_id,f.server_name,
    f.lab_id,f.lab_name,f.subject,f.notes,f.starts_at,f.ends_at,f.last_at,
    f.status,f.source,f.confirmed_at,f.cancellation_reason,f.occurrence_count,
    count(*) over() total_count
  from filtered f order by f.starts_at desc
  offset greatest(coalesce(p_offset,0),0)
  limit least(greatest(coalesce(p_limit,20),1),50);
end $$;

grant execute on function public.staff_reservation_stats() to authenticated;
grant execute on function public.staff_reservation_history_page(text,integer,integer) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260821_unified_ticket_protocol.sql
-- -----------------------------------------------------------------------------
-- Unifica todos os novos chamados no formato LAB-XXXXX, independentemente do laboratório.
-- Os protocolos históricos permanecem inalterados e continuam válidos para consultas e respostas.
do $$
declare
  v_max bigint;
begin
  select coalesce(max((substring(protocol from '([0-9]+)$'))::bigint),0)
    into v_max
    from public.tickets
   where protocol ~ '^LAB[0-9]*-[0-9]+$';

  insert into public.protocol_sequences(prefix,last_value)
  values('LAB',v_max)
  on conflict(prefix) do update
    set last_value=greatest(public.protocol_sequences.last_value,excluded.last_value);
end $$;

create or replace function public.next_protocol(p_lab uuid)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  v_next bigint;
begin
  insert into public.protocol_sequences(prefix,last_value)
  values('LAB',1)
  on conflict(prefix) do update
    set last_value=public.protocol_sequences.last_value+1
  returning last_value into v_next;

  return 'LAB-'||lpad(v_next::text,5,'0');
end $$;

revoke all on function public.next_protocol(uuid) from public;
grant execute on function public.next_protocol(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260821_email_payload_by_ticket_status.sql
-- -----------------------------------------------------------------------------
-- Dados de conclusão só devem existir no payload quando o chamado estiver concluído.
create or replace function public.ticket_email_payload(t public.tickets)
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  select jsonb_build_object(
    'protocol',t.protocol,
    'title',t.title,
    'description',t.description,
    'status',t.status,
    'resolution',case when t.status='Concluído' then coalesce(t.resolution,'Atendimento concluído.') else null end,
    'server_name',coalesce(s.full_name,t.guest_email,'Remetente por e-mail'),
    'lab',coalesce(l.name,'Não informado'),
    'category',coalesce(c.name,'Não informada'),
    'created_at',t.created_at,
    'closed_at',t.closed_at,
    'portal_url','https://labinfo.tl.ifms.edu.br/suporte/',
    'feedback_url',case when t.status='Concluído' then 'https://labinfo.tl.ifms.edu.br/suporte/?feedback='||t.feedback_token::text else null end
  )
  from (select 1) x
  left join public.servers s on s.id=t.server_id
  left join public.labs l on l.id=t.lab_id
  left join public.categories c on c.id=t.category_id
$$;

-- -----------------------------------------------------------------------------
-- migrations/20260821_email_operations_health.sql
-- -----------------------------------------------------------------------------
-- Observabilidade e reprocessamento seguro da fila de notificações.
alter table public.email_outbox
  add column if not exists manual_retry_at timestamptz,
  add column if not exists manual_retry_by uuid references public.profiles(id) on delete set null;

create or replace function public.apps_script_finish_outbox(
  p_secret text,p_id bigint,p_success boolean,p_error text default null
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.integration_secret_valid(p_secret) then raise exception 'Credencial inválida'; end if;
  if p_success then
    update public.email_outbox set status='sent',sent_at=coalesce(sent_at,now()),last_error=null
    where id=p_id and status<>'sent';
  else
    update public.email_outbox set
      status=case when attempts>=5 then 'failed' else 'pending' end,
      available_at=now()+interval '30 minutes',
      last_error=left(coalesce(p_error,'Erro desconhecido'),1000)
    where id=p_id and status='processing';
  end if;
end $$;

create or replace function public.retry_email_outbox(p_id bigint) returns void
language plpgsql security definer set search_path=public as $$
begin
  if public.current_role()<>'tecnico' then raise exception 'Apenas técnicos podem reenviar notificações'; end if;
  update public.email_outbox set status='pending',available_at=now(),claimed_at=null,
    attempts=0,last_error=null,manual_retry_at=now(),manual_retry_by=auth.uid()
  where id=p_id and (
    status='failed' or
    (status='pending' and available_at<now()-interval '5 minutes') or
    (status='processing' and claimed_at<now()-interval '10 minutes')
  );
  if not found then raise exception 'A notificação não está disponível para reenvio'; end if;
end $$;
grant execute on function public.retry_email_outbox(bigint) to authenticated;

create or replace function public.maintenance_metrics() returns jsonb
language plpgsql security definer set search_path=public as $$
declare m public.integration_runtime_metrics;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado'; end if;
  select * into m from public.integration_runtime_metrics where id=true;
  return jsonb_build_object(
    'database_bytes',pg_database_size(current_database()),
    'attachment_bytes',coalesce((select sum(size_bytes) from public.attachments),0),
    'attachment_count',(select count(*) from public.attachments),
    'ticket_count',(select count(*) from public.tickets),
    'outbox_pending',(select count(*) from public.email_outbox where status='pending'),
    'outbox_processing',(select count(*) from public.email_outbox where status='processing'),
    'outbox_failed',(select count(*) from public.email_outbox where status='failed'),
    'outbox_overdue',(select count(*) from public.email_outbox where (status='pending' and available_at<now()-interval '5 minutes') or (status='processing' and claimed_at<now()-interval '10 minutes')),
    'outbox_sent_today',(select count(*) from public.email_outbox where status='sent' and sent_at>=current_date),
    'outbox_last_error',(select last_error from public.email_outbox where last_error is not null order by id desc limit 1),
    'outbox_problems',coalesce((select jsonb_agg(to_jsonb(q)) from (
      select o.id,o.recipient,o.event_type,o.status,o.attempts,o.available_at,o.last_error,
             coalesce(t.protocol,r.protocol) protocol
      from public.email_outbox o
      left join public.tickets t on t.id=o.ticket_id
      left join public.reservations r on r.id=o.reservation_id
      where o.status='failed'
         or (o.status='pending' and o.available_at<now()-interval '5 minutes')
         or (o.status='processing' and o.claimed_at<now()-interval '10 minutes')
      order by o.id desc limit 25
    ) q),'[]'::jsonb),
    'sent_today',m.sent_today,'sent_month',m.sent_month,'email_quota_remaining',m.email_quota_remaining,
    'inbox_runs_today',m.inbox_runs_today,'outbox_runs_today',m.outbox_runs_today,
    'last_inbox_run',m.last_inbox_run,'last_outbox_run',m.last_outbox_run,'updated_at',m.updated_at
  );
end $$;
grant execute on function public.maintenance_metrics() to authenticated;

-- Chamados originados no chat já nascem no estado final escolhido pelo técnico.
-- Por isso devem gerar um único evento: conclusão ou permanência em atendimento.
create or replace function public.queue_ticket_email() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_email text; v_event text;
begin
  v_email:=public.ticket_email(new);
  if v_email is null then return new; end if;
  if tg_op='INSERT' then
    if new.source='Chat' then
      v_event:=case when new.status='Concluído' then 'concluido' else 'em_atendimento' end;
    else
      v_event:=case when new.source='Tecnico' then 'aberto_pelo_tecnico' else 'recebido' end;
    end if;
  elsif new.status is distinct from old.status and new.status='Em atendimento' then v_event:='em_atendimento';
  elsif new.status is distinct from old.status and new.status='Concluído' then v_event:='concluido';
  else return new;
  end if;
  insert into public.email_outbox(ticket_id,recipient,event_type,payload)
  values(new.id,v_email,v_event,public.ticket_email_payload(new));
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- migrations/20260826_chat_and_ticket_security_hardening.sql
-- -----------------------------------------------------------------------------
-- Correção dos achados críticos da auditoria de 26/08/2026:
-- 1) Leitura/escrita pública irrestrita em chat_sessions/chat_messages (RLS "using(true)").
-- 2) create_ticket_from_chat liberada para anon sem checagem de autenticação.
-- Execute este arquivo por último, depois de todas as migrations anteriores já aplicadas.

-- ============================================================
-- 1. Chat ao vivo: RLS deixa de ser pública, escrita passa a ser
--    exclusivamente pelas funções de segurança (RPCs) já existentes.
-- ============================================================

drop policy if exists "chat_sessions_read" on public.chat_sessions;
drop policy if exists "chat_sessions_insert" on public.chat_sessions;
drop policy if exists "chat_sessions_update" on public.chat_sessions;
drop policy if exists "chat_messages_read" on public.chat_messages;
drop policy if exists "chat_messages_insert" on public.chat_messages;

-- Somente técnicos/supervisores autenticados podem consultar as tabelas
-- diretamente. O público (anon) passa a acessar exclusivamente pelas
-- funções security definer (request_chat_session, send_chat_message,
-- get_public_chat_session, get_public_chat_messages, close_chat_session),
-- que já existiam e já validam o que cada chamador pode fazer.
create policy chat_sessions_staff_read on public.chat_sessions
  for select to authenticated
  using (public.current_role() in ('tecnico','supervisor'));

create policy chat_sessions_staff_update on public.chat_sessions
  for update to authenticated
  using (public.current_role() in ('tecnico','supervisor'))
  with check (public.current_role() in ('tecnico','supervisor'));

create policy chat_messages_staff_read on public.chat_messages
  for select to authenticated
  using (public.current_role() in ('tecnico','supervisor'));

-- Nenhuma policy de insert é recriada: toda inserção (pelo público ou pela
-- equipe) passa pelas funções security definer, que continuam funcionando
-- normalmente porque funções security definer não são afetadas por RLS.

-- Função pública equivalente a loadPublicChatMessages, para o docente/servidor
-- acompanhar a própria conversa sem precisar de leitura direta na tabela.
-- Conhecer o session_id (UUID aleatório de 128 bits) já é a prova de posse
-- da sessão nesse fluxo anônimo; o que a policy antiga permitia e que este
-- fix elimina é listar TODAS as sessões/mensagens sem informar nenhum id.
create or replace function public.get_public_chat_messages(p_session_id uuid)
returns setof public.chat_messages
language sql stable security definer set search_path = public as $$
  select * from public.chat_messages
  where session_id = p_session_id
  order by created_at asc
$$;
grant execute on function public.get_public_chat_messages(uuid) to anon, authenticated;

-- ============================================================
-- 2. create_ticket_from_chat volta a exigir técnico autenticado.
--    A migration 20260818_fix_create_ticket_from_chat_ambiguity.sql
--    removeu essa checagem e liberou a função para "anon" — isso permitia
--    que qualquer visitante criasse chamados oficiais e disparasse e-mails
--    de "conclusão" em nome da equipe para qualquer servidor cadastrado.
-- ============================================================

drop function if exists public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text);

create or replace function public.create_ticket_from_chat(
  p_session_id uuid,
  p_lab uuid default null,
  p_category uuid default null,
  p_title text default null,
  p_resolution text default null,
  p_status text default 'Concluído'
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth as $$
declare
  v_session record;
  v_tech_id uuid;
  v_protocol text;
  v_new_ticket_id uuid;
  v_chat_transcript text := '';
  v_msg record;
  v_title text;
  v_status_clean text;
  v_status_enum public.ticket_status;
begin
  -- Exige técnico/supervisor autenticado; nada de fallback silencioso.
  v_tech_id := auth.uid();
  if v_tech_id is null or public.current_role() not in ('tecnico','supervisor') then
    raise exception 'Apenas técnicos autenticados podem gerar chamados a partir do chat.';
  end if;

  v_status_clean := coalesce(nullif(trim(p_status), ''), 'Concluído');
  if v_status_clean not in ('Recebido', 'Em atendimento', 'Concluído') then
    v_status_clean := 'Concluído';
  end if;
  v_status_enum := v_status_clean::public.ticket_status;

  select cs.*, s.id as server_id, s.full_name as server_name, s.siape as server_siape, s.email as server_email
  into v_session
  from public.chat_sessions cs
  join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  if v_session.ticket_id is not null then
    select protocol into v_protocol from public.tickets where id = v_session.ticket_id;
    return jsonb_build_object('ticket_id', v_session.ticket_id, 'protocol', v_protocol, 'status', v_status_clean);
  end if;

  for v_msg in
    select cm.sender_name, cm.sender_type, cm.message, cm.created_at
    from public.chat_messages cm
    where cm.session_id = p_session_id
    order by cm.created_at asc
  loop
    v_chat_transcript := v_chat_transcript || '[' || to_char(v_msg.created_at at time zone 'America/Cuiaba', 'DD/MM/YYYY HH24:MI') || '] ' || v_msg.sender_name || ': ' || v_msg.message || E'\n';
  end loop;

  v_protocol := public.next_protocol(p_lab);
  v_title := coalesce(nullif(trim(p_title), ''), 'Atendimento via Chat: ' || coalesce(v_session.subject, 'Dúvida/Suporte'));

  insert into public.tickets(
    protocol, server_id, lab_id, category_id, title, description, status, source,
    assigned_to, resolution, started_at, closed_at, feedback_token
  ) values (
    v_protocol, v_session.server_id, p_lab, p_category, left(v_title, 100),
    E'Atendimento realizado via Chat ao Vivo com a equipe de TI.\n\n--- TRANSCRIÇÃO DA CONVERSA ---\n' || v_chat_transcript,
    v_status_enum, 'Chat', v_tech_id,
    case when v_status_clean = 'Concluído' then coalesce(nullif(trim(p_resolution), ''), 'Atendimento concluído via Chat ao Vivo.') else null end,
    coalesce(v_session.started_at, now()),
    case when v_status_clean = 'Concluído' then now() else null end,
    gen_random_uuid()
  ) returning tickets.id into v_new_ticket_id;

  insert into public.ticket_updates(ticket_id, author_id, message, kind)
  values (
    v_new_ticket_id, v_tech_id,
    case when v_status_clean = 'Concluído'
      then 'Chamado gerado e concluído a partir do Chat ao Vivo. Solução registrada: ' || coalesce(nullif(trim(p_resolution), ''), 'Atendimento prestado em tempo real.')
      else 'Chamado gerado a partir do Chat ao Vivo e mantido em atendimento presencial pela equipe técnica.'
    end,
    case when v_status_clean = 'Concluído' then 'fechamento' else 'status' end
  );

  update public.chat_sessions cs
  set status = 'closed', ticket_id = v_new_ticket_id, closed_at = now(),
      closed_by = coalesce(v_tech_id, cs.closed_by),
      notes = coalesce(nullif(trim(p_resolution), ''), cs.notes)
  where cs.id = p_session_id;

  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message)
  values (
    p_session_id, 'system', v_tech_id, 'Sistema LabInfo',
    'Atendimento finalizado! Um e-mail com os detalhes do chamado (' || v_protocol || ') e o link de confirmação foi enviado para ' || v_session.server_email || '.'
  );

  return jsonb_build_object('ticket_id', v_new_ticket_id, 'protocol', v_protocol, 'status', v_status_clean);
end $$;

-- Remove o acesso público concedido pela migration de ambiguidade e deixa
-- a função disponível somente para técnicos/supervisores autenticados.
revoke all on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) from public;
revoke all on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) from anon;
grant execute on function public.create_ticket_from_chat(uuid, uuid, uuid, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260827_public_rpc_rate_limiting.sql
-- -----------------------------------------------------------------------------
-- Achado P1 2.1 da auditoria de 26/08/2026:
-- identify_server e request_chat_session funcionam como um "oráculo" público de
-- SIAPE: bastava tentar números em sequência para descobrir quais são válidos e
-- obter nome/e-mail do servidor associado. create_public_reservation_range
-- também é um alvo de abuso (flood de solicitações de reserva).
-- Esta migration adiciona um limitador de taxa genérico por IP de origem,
-- reaproveitado nas três funções.
--
-- Observação de projeto: o identificador usado é o IP de origem (cabeçalho
-- x-forwarded-for, que a infraestrutura do Supabase preenche automaticamente).
-- Como os laboratórios do campus provavelmente saem para a internet por um
-- NAT/IP compartilhado, os limites abaixo foram definidos de forma generosa
-- (dezenas de tentativas por janela de minutos) para não bloquear uso legítimo
-- simultâneo de várias pessoas atrás do mesmo IP, mantendo ainda assim uma
-- barreira relevante contra varredura automatizada de milhares de SIAPEs.

-- ============================================================
-- 1. Estrutura genérica de rate limiting
-- ============================================================

create table if not exists public.rate_limit_log (
  id bigserial primary key,
  scope text not null,
  identity text not null,
  created_at timestamptz not null default now()
);

create index if not exists rate_limit_log_lookup_idx
  on public.rate_limit_log(scope, identity, created_at);

-- Índice para a limpeza oportunista por data, evitando scan completo da tabela.
create index if not exists rate_limit_log_created_at_idx
  on public.rate_limit_log(created_at);

comment on table public.rate_limit_log is
  'Registro de tentativas para limitação de taxa de RPCs públicas. Linhas com '
  'mais de 1 dia são removidas automaticamente pelas próprias chamadas de '
  'enforce_rate_limit (limpeza oportunista, sem necessidade de job agendado).';

-- Extrai o IP de origem do cabeçalho que o PostgREST/Supabase expõe em
-- request.headers. Retorna 'unknown' quando não disponível (ex.: chamada feita
-- fora do contexto HTTP, como em testes via SQL editor).
create or replace function public.request_ip()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(btrim(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1)), ''),
    'unknown'
  )
$$;

-- Registra uma tentativa no escopo informado e levanta exceção quando o total
-- de tentativas dentro da janela (contando a atual) ultrapassa p_max.
-- security definer + search_path fixo + revogado de anon/authenticated: só é
-- chamável a partir de outras funções security definer (que executam como o
-- dono da função, ignorando o revoke), nunca diretamente pelo público.
create or replace function public.enforce_rate_limit(
  p_scope text,
  p_identity text,
  p_max_per_window integer,
  p_window interval
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.rate_limit_log(scope, identity) values (p_scope, coalesce(nullif(btrim(p_identity), ''), 'unknown'));

  select count(*) into v_count
  from public.rate_limit_log
  where scope = p_scope
    and identity = coalesce(nullif(btrim(p_identity), ''), 'unknown')
    and created_at > now() - p_window;

  if v_count > p_max_per_window then
    raise exception 'Muitas tentativas em pouco tempo. Aguarde alguns minutos antes de tentar novamente.';
  end if;

  -- Limpeza oportunista: evita que a tabela cresça indefinidamente sem
  -- depender de um job agendado (pg_cron não é garantido no plano gratuito).
  if random() < 0.02 then
    delete from public.rate_limit_log where created_at < now() - interval '1 day';
  end if;
end $$;

revoke all on function public.enforce_rate_limit(text, text, integer, interval) from public;
revoke all on function public.enforce_rate_limit(text, text, integer, interval) from anon;
revoke all on function public.enforce_rate_limit(text, text, integer, interval) from authenticated;

revoke all on function public.request_ip() from public;
grant execute on function public.request_ip() to anon, authenticated;

-- ============================================================
-- 2. identify_server: era "language sql" sem nenhuma limitação; convertida
--    para plpgsql para poder aplicar o rate limit antes da consulta.
-- ============================================================

drop function if exists public.identify_server(text);

create or replace function public.identify_server(p_siape text)
returns table(id uuid, full_name text, email text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.enforce_rate_limit('identify_server', public.request_ip(), 30, interval '10 minutes');

  return query
  select s.id, s.full_name, s.email
  from public.servers s
  where s.siape = p_siape and s.active
  limit 1;
end $$;

revoke all on function public.identify_server(text) from public;
grant execute on function public.identify_server(text) to anon, authenticated;

-- ============================================================
-- 3. request_chat_session: mesmo padrão de oráculo de SIAPE.
-- ============================================================

create or replace function public.request_chat_session(p_siape text, p_subject text)
returns table(session_id uuid, server_id uuid, server_name text, server_email text, status text)
language plpgsql security definer set search_path = public as $$
declare
  v_server record;
  v_session_id uuid;
begin
  perform public.enforce_rate_limit('request_chat_session', public.request_ip(), 20, interval '10 minutes');

  select s.id, s.full_name, s.email, s.active into v_server
  from public.servers s
  where s.siape = trim(p_siape) and s.active = true;

  if v_server.id is null then
    raise exception 'SIAPE não localizado ou cadastro inativo. Procure a equipe técnica.';
  end if;

  insert into public.chat_sessions(server_id, status, subject)
  values (v_server.id, 'waiting', left(coalesce(nullif(trim(p_subject), ''), 'Atendimento rápido via chat'), 160))
  returning chat_sessions.id into v_session_id;

  -- Mensagem automática do sistema de boas-vindas
  insert into public.chat_messages(session_id, sender_type, sender_name, message)
  values (v_session_id, 'system', 'Sistema LabInfo', 'Sua solicitação foi enviada aos técnicos de plantão. Aguarde um momento enquanto um técnico se conecta.');

  return query
  select v_session_id, v_server.id, v_server.full_name, v_server.email, 'waiting'::text;
end $$;

revoke all on function public.request_chat_session(text, text) from public;
grant execute on function public.request_chat_session(text, text) to anon, authenticated;

-- ============================================================
-- 4. create_public_reservation_range: throttle contra flood de solicitações
--    de reserva (a validação de conflito de horário já existe via exclusion
--    constraint; isto complementa contra abuso volumétrico).
-- ============================================================

create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;r public.reservations;first_r public.reservations;
  occurrence timestamptz:=p_start;finish timestamptz;requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();count_items integer:=0;
begin
  perform public.enforce_rate_limit('create_public_reservation_range', public.request_ip(), 20, interval '1 hour');

  select server.* into s from public.servers server where server.siape=btrim(p_siape) and server.active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para reservas públicas.';
  end if;
  if p_start<=now() then raise exception 'Não é possível solicitar uma reserva em data ou horário passado.';end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.';end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos próximos 180 dias.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
      values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence)
      returning * into r;
      if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
exception when exclusion_violation then
  raise exception 'O laboratório já possui reserva neste horário.';
end $$;

revoke all on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) from public;
grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon, authenticated;

-- ============================================================
-- 5. send_chat_message: limite leve contra flood de mensagens dentro de uma
--    sessão de chat já existente (defesa em profundidade; item opcional do
--    achado P1 2.1).
-- ============================================================

create or replace function public.send_chat_message(
  p_session_id uuid,
  p_sender_type text,
  p_message text,
  p_sender_name text default null,
  p_siape text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_session record;
  v_sender_name text := trim(coalesce(p_sender_name, ''));
  v_sender_id uuid := null;
  v_msg_id bigint;
  v_now timestamptz := now();
begin
  if p_sender_type <> 'technician' then
    perform public.enforce_rate_limit('send_chat_message:' || p_session_id::text, public.request_ip(), 60, interval '5 minutes');
  end if;

  if length(trim(p_message)) < 1 then
    raise exception 'A mensagem não pode ser vazia.';
  end if;

  select cs.*, s.full_name as server_name, s.siape as server_siape
  into v_session
  from public.chat_sessions cs
  left join public.servers s on s.id = cs.server_id
  where cs.id = p_session_id;

  if v_session.id is null then
    raise exception 'Sessão de chat não encontrada.';
  end if;

  if v_session.status = 'closed' then
    raise exception 'Este atendimento já foi encerrado.';
  end if;

  if p_sender_type = 'technician' then
    v_sender_id := auth.uid();
    if v_sender_id is null then
      raise exception 'Acesso não autorizado.';
    end if;
    select coalesce(p.full_name, 'Técnico') into v_sender_name
    from public.profiles p
    where p.id = v_sender_id;

    if v_sender_name is null or length(trim(v_sender_name)) = 0 then
      v_sender_name := 'Técnico de Plantão';
    end if;
  elsif p_sender_type = 'server' then
    if length(v_sender_name) < 2 then
      v_sender_name := coalesce(v_session.server_name, 'Servidor');
    end if;
    v_sender_id := v_session.server_id;
  else
    p_sender_type := 'system';
    v_sender_name := 'Sistema LabInfo';
  end if;

  insert into public.chat_messages(session_id, sender_type, sender_id, sender_name, message, created_at)
  values (p_session_id, p_sender_type, v_sender_id, v_sender_name, trim(p_message), v_now)
  returning chat_messages.id into v_msg_id;

  return jsonb_build_object(
    'id', v_msg_id,
    'session_id', p_session_id,
    'sender_type', p_sender_type,
    'sender_name', v_sender_name,
    'message', trim(p_message),
    'created_at', v_now
  );
end $$;
grant execute on function public.send_chat_message(uuid, text, text, text, text) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260828_scope_storage_uploads_to_existing_tickets.sql
-- -----------------------------------------------------------------------------
-- Achado adicional (verificação ao vivo do painel do Supabase em 26/08/2026,
-- fora do escopo da auditoria estática original — políticas de Storage não
-- tinham sido inspecionadas antes):
--
-- A política `storage_public_upload` (definida em supabase/schema.sql) só
-- exigia que o caminho do arquivo começasse com "tickets/", sem checar se o
-- segundo segmento do caminho corresponde a um chamado (ticket) que
-- realmente existe:
--
--   with check(bucket_id='ticket-attachments' and (storage.foldername(name))[1]='tickets')
--
-- O bucket é privado (public=false) e já tem, na configuração do próprio
-- bucket, limite de 5 MB por arquivo e tipos MIME restritos a
-- image/jpeg, image/png e image/webp — isso já limitava bastante o dano
-- possível (não dá para subir executável, HTML, arquivo gigante, etc.).
-- Mas como a "anon key" é pública (fica embutida em supabase-config.js,
-- então qualquer visitante do site consegue vê-la), ainda era possível a
-- qualquer pessoa, sem nunca passar pelo formulário do site, enviar um
-- número ilimitado de imagens (até 5 MB cada) direto para a API de
-- Storage, para caminhos "tickets/<qualquer-string>/<nome>" arbitrários.
-- Esses arquivos nunca ficam vinculados à tabela `attachments` (isso só
-- acontece via `register_public_attachment`, que já valida SIAPE + chamado
-- + status), então nunca aparecem na interface — mas continuam ocupando a
-- cota de armazenamento do plano gratuito do Supabase, sem nenhum rate
-- limit, e só ficam visíveis para a equipe técnica se ela for olhar
-- diretamente dentro do bucket.
--
-- Esta migração fecha essa brecha exigindo que o segundo segmento do
-- caminho corresponda ao id de um chamado que já existe — exatamente o
-- formato que o próprio app já usa para montar o caminho
-- (`tickets/${ticketId}/${uuid}-${nomeSeguro}`, ver uploadFiles() em
-- supabase-integration.js). Como o id do chamado é um uuid gerado
-- aleatoriamente (não sequencial, não exposto na interface pública — o
-- app só mostra o número de protocolo, nunca o uuid, exceto para quem
-- acabou de criar o próprio chamado) e não é praticável de adivinhar, só
-- quem já tem um chamado real consegue montar um caminho aceito pela
-- política, o que elimina o vetor de abuso de cota descrito acima.
--
-- Não muda nada para o fluxo legítimo do site (uploadFiles() já usa
-- exatamente esse formato de caminho, com o id do chamado já criado antes
-- do upload).

drop policy if exists storage_public_upload on storage.objects;

create policy storage_public_upload on storage.objects for insert to anon,authenticated
with check(
  bucket_id = 'ticket-attachments'
  and (storage.foldername(name))[1] = 'tickets'
  and exists(
    select 1 from public.tickets t where t.id::text = (storage.foldername(name))[2]
  )
);

-- -----------------------------------------------------------------------------
-- migrations/20260831_reservation_cleanup.sql
-- -----------------------------------------------------------------------------
-- Limpeza oportunista de reservas expiradas
-- Evita que reservas públicas que nunca foram confirmadas por e-mail fiquem bloqueando horários para sempre.

create or replace function public.cleanup_expired_reservations()
returns void language plpgsql security definer set search_path=public as $$
begin
  -- Altera o status para 'Cancelada' das reservas que expiraram e ainda não foram confirmadas
  update public.reservations
     set status = 'Cancelada',
         cancelled_at = now(),
         cancellation_reason = 'Expirou o prazo de 72h para confirmação por e-mail.',
         updated_at = now()
   where status = 'Aguardando confirmação'
     and confirmation_expires_at < now();
end $$;

-- Atualizamos as funções de criação para chamarem a limpeza antes de tentarem criar/validar
create or replace function public.staff_create_reservation_range(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_source text default 'Equipe',
  p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  r public.reservations; first_r public.reservations;
  occurrence timestamptz:=p_start; finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
  conflict_info text;
  skipped_dates text[];
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  
  -- Limpa as expiradas ANTES de verificar conflitos
  perform public.cleanup_expired_reservations();

  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'Período inválido.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      select res.subject || ' (' || s.full_name || ', ' || res.status || ')'
        into conflict_info
        from public.reservations res
        join public.servers s on s.id = res.server_id
       where res.lab_id=p_lab and res.status<>'Cancelada'
         and res.starts_at<finish and res.ends_at>occurrence
       limit 1;
      if conflict_info is not null then
        skipped_dates := array_append(skipped_dates,
          to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM') || ': ' || conflict_info);
        conflict_info := null;
      else
        perform public.validate_reservation_slot(occurrence, finish);
        insert into public.reservations(
          protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
          confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence
        ) values (
          public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),
          occurrence,finish,'Autorizada',case when p_source='CSV' then 'CSV' else 'Equipe' end,
          now(),now(),auth.uid(),auth.uid(),group_id,p_recurrence
        ) returning * into r;
        if first_r.id is null then first_r:=r; end if;
      end if;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if first_r.id is null then
    if skipped_dates is not null and array_length(skipped_dates, 1) > 0 then
      raise exception 'Todas as datas possuem conflito: %. Nenhuma reserva foi criada.',
        array_to_string(skipped_dates, ' | ');
    else
      raise exception 'A série não possui nenhuma data válida.';
    end if;
  end if;
  return first_r;
end $$;

create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;r public.reservations;first_r public.reservations;
  occurrence timestamptz:=p_start;finish timestamptz;requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();count_items integer:=0;
begin
  perform public.enforce_rate_limit('create_public_reservation_range', public.request_ip(), 20, interval '1 hour');
  
  -- Limpa as expiradas ANTES de verificar conflitos
  perform public.cleanup_expired_reservations();

  select server.* into s from public.servers server where server.siape=btrim(p_siape) and server.active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para reservas públicas.';
  end if;
  if p_start<=now() then raise exception 'Não é possível solicitar uma reserva em data ou horário passado.';end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.';end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos próximos 180 dias.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
      values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence)
      returning * into r;
      if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
exception when exclusion_violation then
  raise exception 'Conflito de horário detectado em %. O laboratório já possui reserva neste horário.',
    to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM/YYYY');
end $$;

-- Grants
revoke all on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) from public;
grant execute on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) to authenticated;
grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260831_reservation_conflict_diagnostics.sql
-- -----------------------------------------------------------------------------
-- Corrige bug: reservas canceladas bloqueando horários + melhora diagnósticos
-- 1. Recria a exclusion constraint com filtro WHERE para ignorar canceladas
-- 2. assert_reservation_available agora informa a DATA e o HORÁRIO conflitante
-- 3. staff_create_reservation_range pula datas conflitantes em vez de abortar a série
-- 4. create_public_reservation_range informa a data conflitante na mensagem de erro

-- Garante extensão necessária para exclusion constraint com GiST
create extension if not exists btree_gist with schema extensions;

-- CORREÇÃO PRINCIPAL: recria a constraint filtrando reservas canceladas
alter table public.reservations drop constraint if exists reservations_no_schedule_overlap;
alter table public.reservations add constraint reservations_no_schedule_overlap
  exclude using gist (lab_id with =, tstzrange(starts_at, ends_at, '[)') with &&)
  where (status <> 'Cancelada');

-- Atualiza assert_reservation_available para informar a data conflitante
create or replace function public.assert_reservation_available(
  p_lab uuid, p_start timestamptz, p_end timestamptz, p_ignore uuid default null
)
returns void language plpgsql stable security definer set search_path=public as $$
declare
  conflict record;
begin
  perform public.validate_reservation_slot(p_start, p_end);
  select r.id, r.starts_at, r.ends_at, r.subject, s.full_name as server_name
    into conflict
    from public.reservations r
    join public.servers s on s.id = r.server_id
   where r.lab_id = p_lab
     and r.status <> 'Cancelada'
     and r.id is distinct from p_ignore
     and r.starts_at < p_end
     and r.ends_at > p_start
   limit 1;
  if conflict.id is not null then
    raise exception 'Conflito em %: % já reservado por % (%–%).',
      to_char(p_start at time zone 'America/Cuiaba', 'DD/MM/YYYY'),
      to_char(p_start at time zone 'America/Cuiaba', 'HH24:MI'),
      conflict.server_name,
      to_char(conflict.starts_at at time zone 'America/Cuiaba', 'HH24:MI'),
      to_char(conflict.ends_at at time zone 'America/Cuiaba', 'HH24:MI');
  end if;
end $$;

-- Staff: pula conflitos individuais em vez de abortar a série inteira
create or replace function public.staff_create_reservation_range(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_source text default 'Equipe',
  p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  r public.reservations; first_r public.reservations;
  occurrence timestamptz:=p_start; finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
  conflict_info text;
  skipped_dates text[];
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'Período inválido.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      -- Verifica conflito sem abortar, incluindo detalhes
      select res.subject || ' (' || s.full_name || ', ' || res.status || ')'
        into conflict_info
        from public.reservations res
        join public.servers s on s.id = res.server_id
       where res.lab_id=p_lab and res.status<>'Cancelada'
         and res.starts_at<finish and res.ends_at>occurrence
       limit 1;
      if conflict_info is not null then
        skipped_dates := array_append(skipped_dates,
          to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM') || ': ' || conflict_info);
        conflict_info := null;
      else
        perform public.validate_reservation_slot(occurrence, finish);
        insert into public.reservations(
          protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
          confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence
        ) values (
          public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),
          occurrence,finish,'Autorizada',case when p_source='CSV' then 'CSV' else 'Equipe' end,
          now(),now(),auth.uid(),auth.uid(),group_id,p_recurrence
        ) returning * into r;
        if first_r.id is null then first_r:=r; end if;
      end if;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if first_r.id is null then
    if skipped_dates is not null and array_length(skipped_dates, 1) > 0 then
      raise exception 'Todas as datas possuem conflito: %. Nenhuma reserva foi criada.',
        array_to_string(skipped_dates, ' | ');
    else
      raise exception 'A série não possui nenhuma data válida.';
    end if;
  end if;
  return first_r;
end $$;

-- Public: informa a data conflitante na mensagem de erro (preserva rate limit da 20260827)
create or replace function public.create_public_reservation_range(
  p_siape text,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text) language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;r public.reservations;first_r public.reservations;
  occurrence timestamptz:=p_start;finish timestamptz;requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();count_items integer:=0;
begin
  perform public.enforce_rate_limit('create_public_reservation_range', public.request_ip(), 20, interval '1 hour');
  select server.* into s from public.servers server where server.siape=btrim(p_siape) and server.active limit 1;
  if s.id is null then raise exception 'Servidor não localizado ou inativo.';end if;
  if not exists(select 1 from public.labs lab where lab.id=p_lab and lab.active and lab.reservation_enabled) then
    raise exception 'Laboratório indisponível para reservas públicas.';
  end if;
  if p_start<=now() then raise exception 'Não é possível solicitar uma reserva em data ou horário passado.';end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.';end if;
  perform public.validate_reservation_slot(p_start,p_end);
  if p_recurrence not in ('none','weekly') then raise exception 'Repetição inválida.';end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos próximos 180 dias.';
  end if;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish:=occurrence+requested_duration;
      perform public.assert_reservation_available(p_lab,occurrence,finish,null);
      insert into public.reservations(protocol,server_id,lab_id,subject,notes,starts_at,ends_at,recurrence_group,recurrence)
      values(public.next_reservation_protocol(),s.id,p_lab,btrim(p_subject),nullif(btrim(p_notes),''),occurrence,finish,group_id,p_recurrence)
      returning * into r;
      if count_items=0 then first_r:=r;end if;count_items:=count_items+1;
    end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  if count_items=0 then raise exception 'A série não possui nenhuma data válida.';end if;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(first_r.id,lower(s.email),'reserva_confirmar',public.reservation_payload(first_r)||jsonb_build_object('series_count',count_items,'series_until',final_date));
  return query select first_r.id,first_r.protocol,first_r.status;
exception when exclusion_violation then
  raise exception 'Conflito de horário detectado em %. O laboratório já possui reserva neste horário.',
    to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM/YYYY');
end $$;

-- Grants
revoke all on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) from public;
grant execute on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) to authenticated;
grant execute on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) to anon,authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260831_reservation_search_and_delete.sql
-- -----------------------------------------------------------------------------
-- Busca tolerante a espaços e exclusão administrativa protegida de reservas.
create or replace function public.staff_delete_reservation(
  p_id uuid,
  p_scope text default 'occurrence'
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_group uuid;
  v_deleted integer := 0;
begin
  if public.current_role() not in ('tecnico','supervisor') then
    raise exception 'Acesso negado.';
  end if;

  select r.recurrence_group into v_group
  from public.reservations r
  where r.id=p_id;

  if not found then return 0; end if;

  if lower(coalesce(p_scope,'occurrence'))='series' and v_group is not null then
    delete from public.reservations r where r.recurrence_group=v_group;
  else
    delete from public.reservations r where r.id=p_id;
  end if;

  get diagnostics v_deleted=row_count;
  return v_deleted;
end;
$$;

revoke all on function public.staff_delete_reservation(uuid,text) from public,anon;
grant execute on function public.staff_delete_reservation(uuid,text) to authenticated;

create or replace function public.staff_reservation_history_page(
  p_search text default null,p_offset integer default 0,p_limit integer default 20
)
returns table(
  id uuid,protocol text,recurrence_group uuid,server_id uuid,server_name text,
  lab_id uuid,lab_name text,subject text,notes text,starts_at timestamptz,
  ends_at timestamptz,last_at timestamptz,status text,source text,
  confirmed_at timestamptz,cancellation_reason text,occurrence_count bigint,total_count bigint
)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.';end if;
  return query
  with grouped as (
    select
      (array_agg(r.id order by r.starts_at))[1] id,
      (array_agg(r.protocol order by r.starts_at))[1] protocol,
      r.recurrence_group,
      (array_agg(r.server_id order by r.starts_at))[1] server_id,
      (array_agg(s.full_name order by r.starts_at))[1] server_name,
      (array_agg(r.lab_id order by r.starts_at))[1] lab_id,
      (array_agg(l.name order by r.starts_at))[1] lab_name,
      (array_agg(r.subject order by r.starts_at))[1] subject,
      (array_agg(r.notes order by r.starts_at))[1] notes,
      min(r.starts_at) starts_at,
      (array_agg(r.ends_at order by r.starts_at))[1] ends_at,
      max(r.starts_at) last_at,
      (array_agg(r.status order by r.starts_at))[1] status,
      (array_agg(r.source order by r.starts_at))[1] source,
      (array_agg(r.confirmed_at order by r.starts_at))[1] confirmed_at,
      (array_agg(r.cancellation_reason order by r.starts_at))[1] cancellation_reason,
      count(*) occurrence_count,
      lower(string_agg(concat_ws(' ',r.protocol,r.subject,s.full_name,l.name,r.status),' ')) search_text
    from public.reservations r
    join public.servers s on s.id=r.server_id
    join public.labs l on l.id=r.lab_id
    where r.status not in ('Aguardando confirmação','Aguardando autorização')
    group by r.recurrence_group
  ),filtered as (
    select * from grouped
    where nullif(btrim(coalesce(p_search,'')),'') is null
       or regexp_replace(search_text,'[^[:alnum:]]','','g') like
          '%'||regexp_replace(lower(btrim(p_search)),'[^[:alnum:]]','','g')||'%'
  )
  select f.id,f.protocol,f.recurrence_group,f.server_id,f.server_name,
    f.lab_id,f.lab_name,f.subject,f.notes,f.starts_at,f.ends_at,f.last_at,
    f.status,f.source,f.confirmed_at,f.cancellation_reason,f.occurrence_count,
    count(*) over() total_count
  from filtered f order by f.starts_at desc
  offset greatest(coalesce(p_offset,0),0)
  limit least(greatest(coalesce(p_limit,20),1),50);
end $$;

grant execute on function public.staff_reservation_history_page(text,integer,integer) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260831_reservation_cancel_scope.sql
-- -----------------------------------------------------------------------------
-- Corrige o cancelamento de reservas para respeitar o escopo (ocorrência ou série)

create or replace function public.staff_cancel_reservation_notification(
  p_id uuid, p_reason text, p_notify boolean default true, p_scope text default 'occurrence'
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  base public.reservations; result public.reservations; recipient text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento.'; end if;
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva não encontrada.'; end if;
  
  update public.reservations set
    status='Cancelada',cancelled_at=now(),cancellation_reason=btrim(p_reason),updated_at=now()
  where id=base.id or (p_scope='series' and base.recurrence_group is not null and recurrence_group=base.recurrence_group);
  
  select * into result from public.reservations where id=p_id;
  
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=result.server_id and active;
    if recipient is not null then
      insert into public.email_outbox(reservation_id,recipient,event_type,payload)
      values(result.id,recipient,'reserva_cancelada',public.reservation_payload(result));
    end if;
  end if;
  return result;
end $$;

revoke all on function public.staff_cancel_reservation_notification(uuid,text,boolean) from public;
grant execute on function public.staff_cancel_reservation_notification(uuid,text,boolean,text) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260831_remove_reservation_operating_hours.sql
-- -----------------------------------------------------------------------------
-- Permite reservas em qualquer horário do dia, inclusive atravessando os
-- antigos intervalos entre os períodos matutino, vespertino e noturno.
-- Mantém as validações de dia, duração, precisão e conflito de agenda.
create or replace function public.validate_reservation_slot(
  p_start timestamptz,
  p_end timestamptz
)
returns void
language plpgsql
stable
set search_path=public
as $$
declare
  s timestamp:=p_start at time zone 'America/Cuiaba';
  e timestamp:=p_end at time zone 'America/Cuiaba';
  duration_seconds integer:=extract(epoch from (p_end-p_start))::integer;
begin
  if extract(isodow from s) not between 1 and 6 or s::date<>e::date then
    raise exception 'Reservas são permitidas de segunda a sábado e devem começar e terminar na mesma data.';
  end if;
  if duration_seconds<2400 or duration_seconds>21600 then
    raise exception 'A reserva deve ter entre 40 minutos e 6 horas.';
  end if;
  if extract(minute from s)::integer%5<>0 or extract(minute from e)::integer%5<>0 then
    raise exception 'Informe início e fim em intervalos de 5 minutos.';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- migrations/20260831_staff_upsert_server.sql
-- -----------------------------------------------------------------------------
create or replace function public.staff_upsert_server(
  p_siape text,
  p_full_name text,
  p_email text
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_role text;
  v_server public.servers;
  v_reactivated boolean := false;
begin
  select role into v_role
  from public.profiles
  where id = auth.uid() and active = true;

  if v_role not in ('tecnico', 'supervisor') then
    raise exception 'Acesso não autorizado.';
  end if;

  select * into v_server
  from public.servers
  where siape = btrim(p_siape)
  limit 1;

  if found and v_server.active then
    raise exception 'Este SIAPE já está cadastrado e ativo.';
  end if;

  if found then
    v_reactivated := true;
    update public.servers
       set full_name = btrim(p_full_name),
           email = lower(btrim(p_email)),
           active = true
     where id = v_server.id
     returning * into v_server;
  else
    insert into public.servers(siape, full_name, email, active)
    values (btrim(p_siape), btrim(p_full_name), lower(btrim(p_email)), true)
    returning * into v_server;
  end if;

  return jsonb_build_object('id', v_server.id, 'reactivated', v_reactivated);
end;
$$;

revoke all on function public.staff_upsert_server(text,text,text) from public, anon;
grant execute on function public.staff_upsert_server(text,text,text) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260831_clear_closed_chat_history.sql
-- -----------------------------------------------------------------------------
create or replace function public.clear_closed_chat_history()
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_role text;
  v_count integer;
begin
  select role into v_role from public.profiles where id=auth.uid() and active=true;
  if v_role not in ('tecnico','supervisor') then raise exception 'Acesso não autorizado.'; end if;
  delete from public.chat_sessions where status='closed';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.clear_closed_chat_history() from public, anon;
grant execute on function public.clear_closed_chat_history() to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260901_public_reservation_cancellation_requests.sql
-- -----------------------------------------------------------------------------
-- Solicitação pública e auditável de cancelamento de reservas confirmadas.
-- O SIAPE apenas dispara um link de acesso para o e-mail cadastrado. O pedido
-- ainda exige uma segunda confirmação por e-mail antes de chegar à equipe.

create table if not exists public.reservation_access_tokens (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists reservation_access_tokens_expiry_idx
  on public.reservation_access_tokens(expires_at);

create table if not exists public.reservation_cancellation_requests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  scope text not null check (scope in ('occurrence','future','series')),
  reason text,
  status text not null default 'awaiting_email'
    check (status in ('awaiting_email','pending','approved','rejected','expired')),
  confirmation_token_hash text not null unique,
  confirmation_expires_at timestamptz not null,
  email_confirmed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists reservation_cancellation_active_request_key
  on public.reservation_cancellation_requests(reservation_id)
  where status in ('awaiting_email','pending');
create index if not exists reservation_cancellation_pending_idx
  on public.reservation_cancellation_requests(status,created_at);

alter table public.reservation_access_tokens enable row level security;
alter table public.reservation_cancellation_requests enable row level security;

drop policy if exists reservation_cancellation_staff_read on public.reservation_cancellation_requests;
create policy reservation_cancellation_staff_read
  on public.reservation_cancellation_requests for select to authenticated
  using (public.current_role() in ('tecnico','supervisor'));

alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check(event_type in (
  'recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido',
  'novo_chamado_tecnico','resposta_servidor_tecnico',
  'reserva_confirmar','reserva_confirmada','reserva_autorizada','reserva_cancelada','reserva_alterada',
  'reserva_acesso','reserva_cancelamento_confirmar',
  'reserva_cancelamento_aprovado','reserva_cancelamento_rejeitado'
));

create or replace function public.request_reservation_access(p_siape text)
returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare
  s public.servers;
  raw_token uuid:=gen_random_uuid();
  token_digest text:=encode(digest(raw_token::text,'sha256'),'hex');
begin
  perform public.enforce_rate_limit('reservation_access',public.request_ip(),10,interval '1 hour');
  delete from public.reservation_access_tokens where expires_at<now();

  select server.* into s
  from public.servers server
  where server.siape=btrim(p_siape) and server.active
  limit 1;

  -- Resposta deliberadamente genérica para não revelar SIAPEs cadastrados.
  if s.id is null then return true; end if;

  insert into public.reservation_access_tokens(server_id,token_hash,expires_at)
  values(s.id,token_digest,now()+interval '30 minutes');

  insert into public.email_outbox(recipient,event_type,payload)
  values(lower(s.email),'reserva_acesso',jsonb_build_object(
    'server_name',s.full_name,
    'access_url','https://labinfo.tl.ifms.edu.br/reservas/?manage_reservations='||raw_token::text
  ));
  return true;
end $$;

create or replace function public.list_my_reservations_secure(p_token uuid)
returns table(
  id uuid,protocol text,subject text,lab text,starts_at timestamptz,ends_at timestamptz,
  status text,recurrence text,recurrence_group uuid,occurrence_count bigint,request_pending boolean
) language plpgsql stable security definer set search_path=public,extensions as $$
declare owner_id uuid;
begin
  select access.server_id into owner_id
  from public.reservation_access_tokens access
  where access.token_hash=encode(digest(p_token::text,'sha256'),'hex')
    and access.expires_at>now();
  if owner_id is null then raise exception 'Este link é inválido ou expirou. Solicite um novo acesso.'; end if;

  return query
  select r.id,r.protocol,r.subject,l.name,r.starts_at,r.ends_at,r.status,r.recurrence,
    r.recurrence_group,
    count(*) over(partition by r.recurrence_group),
    exists(select 1 from public.reservation_cancellation_requests cr
      where cr.reservation_id=r.id and cr.status in ('awaiting_email','pending'))
  from public.reservations r
  join public.labs l on l.id=r.lab_id
  where r.server_id=owner_id
    and r.status in ('Aguardando autorização','Autorizada')
    and r.ends_at>now()
  order by r.starts_at;
end $$;

create or replace function public.request_reservation_cancellation(
  p_access_token uuid,p_reservation uuid,p_scope text,p_reason text default null
) returns table(protocol text,status text)
language plpgsql security definer set search_path=public,extensions as $$
declare
  owner_id uuid;
  r public.reservations;
  s public.servers;
  raw_token uuid:=gen_random_uuid();
begin
  if p_scope not in ('occurrence','future','series') then raise exception 'Selecione o alcance do cancelamento.'; end if;
  if length(btrim(coalesce(p_reason,'')))>500 then raise exception 'O motivo deve ter até 500 caracteres.'; end if;

  select access.server_id into owner_id
  from public.reservation_access_tokens access
  where access.token_hash=encode(digest(p_access_token::text,'sha256'),'hex')
    and access.expires_at>now();
  if owner_id is null then raise exception 'Este link é inválido ou expirou. Solicite um novo acesso.'; end if;

  select reservation.* into r from public.reservations reservation
  where reservation.id=p_reservation and reservation.server_id=owner_id for update;
  if r.id is null then raise exception 'Reserva não localizada.'; end if;
  if r.status not in ('Aguardando autorização','Autorizada') or r.ends_at<=now() then
    raise exception 'Esta reserva não aceita solicitação de cancelamento.';
  end if;
  update public.reservation_cancellation_requests cr set status='expired',updated_at=now()
  where cr.reservation_id=r.id and cr.status='awaiting_email' and cr.confirmation_expires_at<now();
  if exists(select 1 from public.reservation_cancellation_requests cr
    where cr.reservation_id=r.id and cr.status in ('awaiting_email','pending')) then
    raise exception 'Já existe uma solicitação de cancelamento em andamento para esta reserva.';
  end if;

  select server.* into s from public.servers server where server.id=owner_id;
  insert into public.reservation_cancellation_requests(
    reservation_id,server_id,scope,reason,confirmation_token_hash,confirmation_expires_at
  ) values (
    r.id,owner_id,p_scope,nullif(btrim(p_reason),''),
    encode(digest(raw_token::text,'sha256'),'hex'),now()+interval '2 hours'
  );

  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(r.id,lower(s.email),'reserva_cancelamento_confirmar',
    public.reservation_payload(r)||jsonb_build_object(
      'scope',p_scope,'request_reason',nullif(btrim(p_reason),''),
      'cancellation_request_url','https://labinfo.tl.ifms.edu.br/reservas/?confirm_cancel_request='||raw_token::text
    ));
  return query select r.protocol,'awaiting_email'::text;
end $$;

create or replace function public.confirm_reservation_cancellation_request(p_token uuid)
returns table(protocol text,status text)
language plpgsql security definer set search_path=public,extensions as $$
declare req public.reservation_cancellation_requests; r public.reservations;
begin
  update public.reservation_cancellation_requests cr set
    status='expired',updated_at=now()
  where cr.status='awaiting_email' and cr.confirmation_expires_at<now();

  select cr.* into req from public.reservation_cancellation_requests cr
  where cr.confirmation_token_hash=encode(digest(p_token::text,'sha256'),'hex') for update;
  if req.id is null then raise exception 'Link de confirmação inválido.'; end if;
  if req.status='expired' then raise exception 'Este link expirou. Solicite novamente pelo portal.'; end if;
  if req.status<>'awaiting_email' then
    select * into r from public.reservations where id=req.reservation_id;
    return query select r.protocol,req.status; return;
  end if;

  update public.reservation_cancellation_requests set
    status='pending',email_confirmed_at=now(),updated_at=now()
  where id=req.id;
  select * into r from public.reservations where id=req.reservation_id;
  return query select r.protocol,'pending'::text;
end $$;

create or replace function public.staff_review_reservation_cancellation(
  p_request uuid,p_approve boolean,p_notes text default null
) returns table(protocol text,status text,affected_count integer)
language plpgsql security definer set search_path=public as $$
declare
  req public.reservation_cancellation_requests;
  r public.reservations;
  s public.servers;
  affected integer:=0;
  result_status text;
  event_name text;
begin
  if public.current_role() not in ('tecnico','supervisor') then raise exception 'Acesso negado.'; end if;
  if length(btrim(coalesce(p_notes,'')))>500 then raise exception 'A observação deve ter até 500 caracteres.'; end if;

  select cr.* into req from public.reservation_cancellation_requests cr where cr.id=p_request for update;
  if req.id is null then raise exception 'Solicitação não localizada.'; end if;
  if req.status<>'pending' then raise exception 'Esta solicitação já foi analisada ou ainda não foi confirmada.'; end if;
  select * into r from public.reservations where id=req.reservation_id for update;
  select * into s from public.servers where id=req.server_id;

  if p_approve then
    update public.reservations reservation set
      status='Cancelada',cancelled_at=now(),updated_at=now(),
      cancellation_reason=coalesce(nullif(btrim(req.reason),''),'Cancelamento solicitado pelo servidor e aprovado pela equipe.')
    where reservation.status<>'Cancelada' and reservation.ends_at>now() and (
      (req.scope='occurrence' and reservation.id=r.id) or
      (req.scope='future' and reservation.recurrence_group=r.recurrence_group and reservation.starts_at>=r.starts_at) or
      (req.scope='series' and reservation.recurrence_group=r.recurrence_group)
    );
    get diagnostics affected=row_count;
    result_status:='approved';event_name:='reserva_cancelamento_aprovado';
  else
    result_status:='rejected';event_name:='reserva_cancelamento_rejeitado';
  end if;

  update public.reservation_cancellation_requests set
    status=result_status,reviewed_by=auth.uid(),reviewed_at=now(),
    review_notes=nullif(btrim(p_notes),''),updated_at=now()
  where id=req.id;

  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(r.id,lower(s.email),event_name,public.reservation_payload(r)||jsonb_build_object(
    'scope',req.scope,'request_reason',req.reason,'review_notes',nullif(btrim(p_notes),''),
    'affected_count',affected
  ));
  return query select r.protocol,result_status,affected;
end $$;

revoke all on function public.request_reservation_access(text) from public;
revoke all on function public.list_my_reservations_secure(uuid) from public;
revoke all on function public.request_reservation_cancellation(uuid,uuid,text,text) from public;
revoke all on function public.confirm_reservation_cancellation_request(uuid) from public;
revoke all on function public.staff_review_reservation_cancellation(uuid,boolean,text) from public;
grant execute on function public.request_reservation_access(text) to anon,authenticated;
grant execute on function public.list_my_reservations_secure(uuid) to anon,authenticated;
grant execute on function public.request_reservation_cancellation(uuid,uuid,text,text) to anon,authenticated;
grant execute on function public.confirm_reservation_cancellation_request(uuid) to anon,authenticated;
grant execute on function public.staff_review_reservation_cancellation(uuid,boolean,text) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.reservation_cancellation_requests;
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- migrations/20260901_direct_ticket_completion_and_reservation_cancel.sql
-- -----------------------------------------------------------------------------
-- Conclusão direta de chamados e cancelamento seguro pelo e-mail de confirmação.

alter table public.reservations
  add column if not exists cancellation_token uuid default gen_random_uuid();

update public.reservations
set cancellation_token=gen_random_uuid()
where cancellation_token is null;

alter table public.reservations
  alter column cancellation_token set default gen_random_uuid(),
  alter column cancellation_token set not null;

create unique index if not exists reservations_cancellation_token_key
  on public.reservations(cancellation_token);

create or replace function public.reservation_payload(r public.reservations) returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object(
   'protocol',r.protocol,'reservation_id',r.id,'server_name',s.full_name,
   'title',r.subject,'lab',l.name,'starts_at',r.starts_at,'ends_at',r.ends_at,
   'status',r.status,'reason',r.cancellation_reason,
   'portal_url','https://labinfo.tl.ifms.edu.br/reservas/',
   'confirmation_url','https://labinfo.tl.ifms.edu.br/reservas/?confirm_reservation='||r.confirmation_token::text,
   'cancellation_url','https://labinfo.tl.ifms.edu.br/reservas/?cancel_reservation='||r.cancellation_token::text
 )
 from public.servers s join public.labs l on l.id=r.lab_id where s.id=r.server_id
$$;

create or replace function public.cancel_reservation_from_email(p_token uuid)
returns table(protocol text,status text,cancelled_count integer)
language plpgsql security definer set search_path=public as $$
declare r public.reservations; affected integer:=0;
begin
  select reservation.* into r
  from public.reservations reservation
  where reservation.cancellation_token=p_token
  order by reservation.starts_at limit 1 for update;

  if r.id is null then raise exception 'Link de cancelamento inválido.'; end if;
  if r.status='Cancelada' then
    return query select r.protocol,r.status::text,0;
    return;
  end if;
  if r.status<>'Aguardando confirmação' or r.confirmed_at is not null then
    raise exception 'Esta solicitação já foi confirmada e não pode mais ser cancelada por este link.';
  end if;

  update public.reservations reservation set
    status='Cancelada',
    cancellation_reason='Cancelada pelo servidor através do e-mail de confirmação.',
    updated_at=now()
  where reservation.recurrence_group=r.recurrence_group
    and reservation.status='Aguardando confirmação';
  get diagnostics affected=row_count;

  return query select r.protocol,'Cancelada'::text,affected;
end $$;

revoke all on function public.cancel_reservation_from_email(uuid) from public;
grant execute on function public.cancel_reservation_from_email(uuid) to anon,authenticated;

create or replace function public.staff_complete_ticket(
  p_ticket uuid,p_resolution text,p_direct boolean default false
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare t public.tickets; actor uuid:=auth.uid(); closed_time timestamptz:=now();
begin
  if actor is null or public.current_role()<>'tecnico' then raise exception 'Acesso negado.'; end if;
  if length(btrim(coalesce(p_resolution,'')))<5 then raise exception 'Descreva a solução realizada.'; end if;

  select * into t from public.tickets where id=p_ticket for update;
  if t.id is null or t.deleted_at is not null then raise exception 'Chamado não localizado.'; end if;
  if t.status='Concluído' then raise exception 'Este chamado já foi concluído.'; end if;
  if t.category_id is null then raise exception 'Informe a categoria antes de concluir o chamado.'; end if;

  insert into public.ticket_assignees(ticket_id,profile_id,assigned_by)
  values(t.id,actor,actor)
  on conflict(ticket_id,profile_id) do nothing;

  update public.tickets set
    assigned_to=coalesce(assigned_to,actor),status='Concluído',
    resolution=btrim(p_resolution),started_at=coalesce(started_at,closed_time),
    closed_at=closed_time,server_reply_pending=false,updated_at=closed_time
  where id=t.id;

  insert into public.ticket_updates(ticket_id,author_id,message,kind)
  values(t.id,actor,btrim(p_resolution),'fechamento');

  return jsonb_build_object('protocol',t.protocol,'status','Concluído','direct',coalesce(p_direct,false));
end $$;

revoke all on function public.staff_complete_ticket(uuid,text,boolean) from public;
grant execute on function public.staff_complete_ticket(uuid,text,boolean) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260901_staff_series_atomic_conflict_check.sql
-- -----------------------------------------------------------------------------
-- Impede que séries cadastradas pela equipe sejam criadas parcialmente.
-- Todas as ocorrências são validadas antes da primeira inserção; se uma data
-- conflitar, a transação inteira é recusada com o diagnóstico da ocorrência.

create or replace function public.staff_create_reservation_range(
  p_server uuid, p_lab uuid, p_subject text, p_start timestamptz, p_end timestamptz,
  p_notes text default null, p_source text default 'Equipe',
  p_recurrence text default 'none', p_until date default null
)
returns public.reservations language plpgsql security definer set search_path=public as $$
declare
  r public.reservations;
  first_r public.reservations;
  occurrence timestamptz := p_start;
  finish timestamptz;
  requested_duration interval := p_end - p_start;
  final_date date := coalesce(p_until, (p_start at time zone 'America/Cuiaba')::date);
  group_id uuid := gen_random_uuid();
begin
  if public.current_role() not in ('tecnico', 'supervisor') then
    raise exception 'Acesso negado.';
  end if;

  perform public.cleanup_expired_reservations();
  perform public.validate_reservation_slot(p_start, p_end);

  if p_recurrence not in ('none', 'weekly') then
    raise exception 'Repetição inválida.';
  end if;
  if final_date < (p_start at time zone 'America/Cuiaba')::date
     or final_date > (p_start at time zone 'America/Cuiaba')::date + interval '180 days' then
    raise exception 'Período inválido.';
  end if;

  -- Primeira passagem: valida a série completa antes de gravar qualquer data.
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish := occurrence + requested_duration;
      perform public.assert_reservation_available(p_lab, occurrence, finish, null);
    end if;

    exit when p_recurrence = 'none'
      or (occurrence at time zone 'America/Cuiaba')::date >= final_date;
    occurrence := occurrence + interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date > final_date;
  end loop;

  -- Segunda passagem: somente ocorre se todas as datas estiverem livres.
  occurrence := p_start;
  loop
    if extract(isodow from occurrence at time zone 'America/Cuiaba') between 1 and 6 then
      finish := occurrence + requested_duration;
      insert into public.reservations(
        protocol, server_id, lab_id, subject, notes, starts_at, ends_at, status, source,
        confirmed_at, authorized_at, authorized_by, created_by, recurrence_group, recurrence
      ) values (
        public.next_reservation_protocol(), p_server, p_lab, btrim(p_subject),
        nullif(btrim(p_notes), ''), occurrence, finish, 'Autorizada',
        case when p_source = 'CSV' then 'CSV' else 'Equipe' end,
        now(), now(), auth.uid(), auth.uid(), group_id, p_recurrence
      ) returning * into r;

      if first_r.id is null then
        first_r := r;
      end if;
    end if;

    exit when p_recurrence = 'none'
      or (occurrence at time zone 'America/Cuiaba')::date >= final_date;
    occurrence := occurrence + interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date > final_date;
  end loop;

  if first_r.id is null then
    raise exception 'A série não possui nenhuma data válida.';
  end if;

  return first_r;
exception
  when exclusion_violation then
    raise exception 'Conflito de horário detectado em %. Nenhuma reserva da série foi criada.',
      to_char(occurrence at time zone 'America/Cuiaba', 'DD/MM/YYYY');
end $$;

revoke all on function public.staff_create_reservation_range(
  uuid,uuid,text,timestamptz,timestamptz,text,text,text,date
) from public;
grant execute on function public.staff_create_reservation_range(
  uuid,uuid,text,timestamptz,timestamptz,text,text,text,date
) to authenticated;

-- -----------------------------------------------------------------------------
-- migrations/20260903_chat_online_reminders_and_waiting_email.sql
-- -----------------------------------------------------------------------------
-- Lembretes de disponibilidade e alerta por e-mail para chats aguardando.
-- Cada sessão pode gerar no máximo um alerta para os técnicos que estavam
-- efetivamente online no momento em que o servidor entrou na fila.

alter table public.chat_sessions
  add column if not exists waiting_notification_sent_at timestamptz;

alter table public.email_outbox drop constraint if exists email_outbox_event_type_check;
alter table public.email_outbox add constraint email_outbox_event_type_check check(event_type in (
  'recebido','aberto_pelo_tecnico','em_atendimento','atualizacao','concluido',
  'novo_chamado_tecnico','resposta_servidor_tecnico','chat_aguardando_tecnico',
  'reserva_confirmar','reserva_confirmada','reserva_autorizada','reserva_cancelada','reserva_alterada',
  'reserva_acesso','reserva_cancelamento_confirmar',
  'reserva_cancelamento_aprovado','reserva_cancelamento_rejeitado'
));

create or replace function public.queue_waiting_chat_staff_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_server public.servers;
begin
  -- Só há alerta quando a sessão nasce aguardando atendimento. A marca na
  -- própria sessão torna a operação idempotente mesmo em caso de retry.
  if new.status <> 'waiting' or new.waiting_notification_sent_at is not null then
    return new;
  end if;

  update public.chat_sessions
  set waiting_notification_sent_at = now()
  where id = new.id
    and waiting_notification_sent_at is null;

  if not found then return new; end if;

  select * into v_server from public.servers where id = new.server_id;
  if v_server.id is null then return new; end if;

  insert into public.email_outbox(recipient, event_type, payload)
  select lower(p.email),
         'chat_aguardando_tecnico',
         jsonb_build_object(
           'protocol', 'CHAT-' || upper(left(replace(new.id::text, '-', ''), 8)),
           'title', coalesce(nullif(new.subject, ''), 'Atendimento via chat'),
           'lab', 'Chat ao vivo',
           'category', 'Atendimento imediato',
           'server_name', v_server.full_name,
           'server_email', v_server.email
         )
  from public.staff_chat_status scs
  join public.profiles p on p.id = scs.profile_id
  where scs.is_online = true
    and scs.last_heartbeat >= now() - interval '3 minutes'
    and p.active = true
    and p.role in ('tecnico', 'supervisor')
    and nullif(trim(p.email), '') is not null;

  return new;
end;
$$;

drop trigger if exists queue_waiting_chat_staff_email on public.chat_sessions;
create trigger queue_waiting_chat_staff_email
after insert on public.chat_sessions
for each row execute function public.queue_waiting_chat_staff_email();

-- -----------------------------------------------------------------------------
-- migrations/20261026_siglab_multisector_google_reservations.sql
-- -----------------------------------------------------------------------------
-- SIGLAB: reservas institucionais multi-setor.
--
-- Esta migration separa a administracao por setor, exige uma sessao Google
-- @ifms.edu.br para todas as operacoes identificadas e permite que um servidor
-- ativo reserve diretamente um horario livre. As permissoes sao verificadas no
-- banco; os filtros da interface nao sao considerados uma barreira de seguranca.

alter type public.app_role add value if not exists 'admin';

create table if not exists public.sectors (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(btrim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  description text,
  reservation_mode text not null default 'internal'
    check (reservation_mode in ('internal','external')),
  external_url text,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (reservation_mode='internal' and external_url is null)
    or
    (reservation_mode='external' and external_url is not null and external_url ~ '^https://')
  )
);

alter table public.labs add column if not exists sector_id uuid references public.sectors(id);
create index if not exists labs_sector_idx on public.labs(sector_id,name) where active;

create table if not exists public.profile_sectors (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  sector_id uuid not null references public.sectors(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  primary key(profile_id,sector_id)
);
create index if not exists profile_sectors_sector_idx on public.profile_sectors(sector_id,profile_id);

insert into public.sectors(name,slug,description,reservation_mode,external_url,sort_order)
values(
  'Laboratorios de Informatica',
  'informatica',
  'Reservas administradas pelo sistema LabInfo.',
  'external',
  'https://labinfo.tl.ifms.edu.br/reservas/',
  10
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  reservation_mode=excluded.reservation_mode,
  external_url=excluded.external_url,
  sort_order=excluded.sort_order,
  updated_at=now();

-- A copia inicial continha apenas laboratorios do LabInfo. Eles permanecem no
-- historico, mas deixam de aceitar reservas no SIGLAB e passam a apontar para o
-- setor externo de Informatica.
update public.labs l set
  sector_id=s.id,
  reservation_enabled=false
from public.sectors s
where s.slug='informatica'
  and l.sector_id is null
  and (lower(l.name) like '%labinfo%' or lower(coalesce(l.code,'')) like 'lab%');

create or replace function public.jwt_uses_google_ifms()
returns boolean
language sql
stable
security definer
set search_path=public,auth
as $$
  select auth.uid() is not null
    and split_part(lower(btrim(coalesce(auth.jwt()->>'email',''))),'@',2)='ifms.edu.br'
    and (
      coalesce(auth.jwt()->'app_metadata'->>'provider','')='google'
      or coalesce(auth.jwt()->'app_metadata'->'providers','[]'::jsonb) @> '["google"]'::jsonb
    )
$$;

create or replace function public.current_ifms_server_id()
returns uuid
language plpgsql
stable
security definer
set search_path=public,auth
as $$
declare
  login_email text:=lower(btrim(coalesce(auth.jwt()->>'email','')));
  server_id uuid;
begin
  if not public.jwt_uses_google_ifms() then
    raise exception 'Entre com sua conta Google institucional @ifms.edu.br.';
  end if;
  select s.id into server_id
  from public.servers s
  where lower(btrim(s.email))=login_email and s.active
  limit 1;
  if server_id is null then
    raise exception 'Seu e-mail nao esta vinculado a um servidor ativo no SIGLAB.';
  end if;
  return server_id;
end $$;

create or replace function public.current_ifms_server_id_or_null()
returns uuid
language sql
stable
security definer
set search_path=public,auth
as $$
  select s.id from public.servers s
  where public.jwt_uses_google_ifms()
    and lower(btrim(s.email))=lower(btrim(coalesce(auth.jwt()->>'email','')))
    and s.active
  limit 1
$$;

create or replace function public.current_staff_profile_id()
returns uuid
language plpgsql
stable
security definer
set search_path=public,auth
as $$
declare
  login_email text:=lower(btrim(coalesce(auth.jwt()->>'email','')));
  profile_id uuid;
begin
  if not public.jwt_uses_google_ifms() then return null; end if;
  select p.id into profile_id
  from public.profiles p
  where lower(btrim(p.email))=login_email and p.active
  limit 1;
  return profile_id;
end $$;

create or replace function public.current_role()
returns public.app_role
language sql
stable
security definer
set search_path=public
as $$
  select p.role from public.profiles p
  where p.id=public.current_staff_profile_id() and p.active
$$;

create or replace function public.is_siglab_admin()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select coalesce(public.current_role()::text='admin',false)
$$;

create or replace function public.can_manage_sector(p_sector uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.is_siglab_admin() or exists(
    select 1 from public.profile_sectors ps
    where ps.profile_id=public.current_staff_profile_id() and ps.sector_id=p_sector
  )
$$;

create or replace function public.can_manage_lab(p_lab uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1 from public.labs l
    where l.id=p_lab and public.can_manage_sector(l.sector_id)
  )
$$;

revoke all on function public.jwt_uses_google_ifms() from public,anon;
revoke all on function public.current_ifms_server_id() from public,anon,authenticated;
revoke all on function public.current_ifms_server_id_or_null() from public,anon;
revoke all on function public.current_staff_profile_id() from public,anon;
revoke all on function public.is_siglab_admin() from public,anon;
revoke all on function public.can_manage_sector(uuid) from public,anon;
revoke all on function public.can_manage_lab(uuid) from public,anon;
grant execute on function public.jwt_uses_google_ifms() to authenticated;
grant execute on function public.current_ifms_server_id_or_null() to authenticated;
grant execute on function public.current_staff_profile_id() to authenticated;
grant execute on function public.is_siglab_admin() to authenticated;
grant execute on function public.can_manage_sector(uuid) to authenticated;
grant execute on function public.can_manage_lab(uuid) to authenticated;

create or replace function public.get_my_ifms_identity()
returns table(id uuid,siape text,full_name text,email text)
language sql
stable
security definer
set search_path=public
as $$
  select s.id,s.siape,s.full_name,s.email
  from public.servers s where s.id=public.current_ifms_server_id()
$$;

create or replace function public.get_my_staff_profile()
returns table(
  id uuid,siape text,full_name text,email text,role public.app_role,
  is_admin boolean,sectors jsonb
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare profile_id uuid:=public.current_staff_profile_id();
begin
  if profile_id is null then
    raise exception 'Esta conta nao possui acesso a area interna do SIGLAB.';
  end if;
  return query
  select p.id,p.siape,p.full_name,p.email,p.role,public.is_siglab_admin(),
    coalesce(jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug)
      order by s.sort_order,s.name) filter(where s.id is not null),'[]'::jsonb)
  from public.profiles p
  left join public.profile_sectors ps on ps.profile_id=p.id
  left join public.sectors s on s.id=ps.sector_id and s.active
  where p.id=profile_id and p.active
  group by p.id;
end $$;

revoke all on function public.get_my_ifms_identity() from public,anon;
revoke all on function public.get_my_staff_profile() from public,anon;
grant execute on function public.get_my_ifms_identity() to authenticated;
grant execute on function public.get_my_staff_profile() to authenticated;

create or replace function public.list_manageable_labs()
returns table(id uuid,name text,code text,sector_id uuid,sector_name text)
language plpgsql
stable
security definer
set search_path=public
as $$
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  return query
  select l.id,l.name,l.code,l.sector_id,s.name
  from public.labs l join public.sectors s on s.id=l.sector_id
  where l.active and l.reservation_enabled and s.active and s.reservation_mode='internal'
    and public.can_manage_lab(l.id)
  order by s.sort_order,s.name,l.name;
end $$;

revoke all on function public.list_manageable_labs() from public,anon;
grant execute on function public.list_manageable_labs() to authenticated;

alter table public.sectors enable row level security;
alter table public.profile_sectors enable row level security;

drop policy if exists sectors_public_read on public.sectors;
create policy sectors_public_read on public.sectors for select to anon using(active);
drop policy if exists sectors_staff_read on public.sectors;
create policy sectors_staff_read on public.sectors for select to authenticated
using(active or public.is_siglab_admin() or public.can_manage_sector(id));
drop policy if exists sectors_admin_write on public.sectors;
create policy sectors_admin_write on public.sectors for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists profile_sectors_read on public.profile_sectors;
create policy profile_sectors_read on public.profile_sectors for select to authenticated
using(public.is_siglab_admin() or profile_id=public.current_staff_profile_id());
drop policy if exists profile_sectors_admin_write on public.profile_sectors;
create policy profile_sectors_admin_write on public.profile_sectors for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists labs_public_read on public.labs;
drop policy if exists labs_write on public.labs;
create policy labs_public_read on public.labs for select to anon using(active);
create policy labs_staff_read on public.labs for select to authenticated
using(active or public.is_siglab_admin() or public.can_manage_sector(sector_id));
create policy labs_sector_write on public.labs for all to authenticated
using(public.is_siglab_admin() or public.can_manage_sector(sector_id))
with check(public.is_siglab_admin() or public.can_manage_sector(sector_id));

-- Substitui as policies herdadas que conheciam apenas tecnico/supervisor.
drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_write on public.profiles;
create policy profiles_staff_read on public.profiles for select to authenticated
using(public.current_staff_profile_id() is not null);
create policy profiles_admin_write on public.profiles for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists servers_read on public.servers;
drop policy if exists servers_write on public.servers;
create policy servers_staff_read on public.servers for select to authenticated
using(public.current_staff_profile_id() is not null);
create policy servers_admin_write on public.servers for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists categories_public_read on public.categories;
drop policy if exists categories_write on public.categories;
create policy categories_public_read on public.categories for select to anon using(active);
create policy categories_staff_read on public.categories for select to authenticated
using(active or public.current_staff_profile_id() is not null);
create policy categories_admin_write on public.categories for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists reservations_staff_read on public.reservations;
create policy reservations_scoped_read on public.reservations for select to authenticated
using(
  server_id=(select public.current_ifms_server_id_or_null())
  or public.can_manage_lab(lab_id)
);

drop policy if exists reservation_cancellation_staff_read on public.reservation_cancellation_requests;
create policy reservation_cancellation_scoped_read
on public.reservation_cancellation_requests for select to authenticated
using(
  server_id=(select public.current_ifms_server_id_or_null())
  or exists(
    select 1 from public.reservations r
    where r.id=reservation_id and public.can_manage_lab(r.lab_id)
  )
);

create or replace function public.reservation_payload(r public.reservations)
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  select jsonb_build_object(
    'protocol',r.protocol,'reservation_id',r.id,'server_name',s.full_name,
    'title',r.subject,'lab',l.name,'starts_at',r.starts_at,'ends_at',r.ends_at,
    'status',r.status,'reason',r.cancellation_reason,
    'portal_url','https://laboratorios.tl.ifms.edu.br/reservas/'
  )
  from public.servers s join public.labs l on l.id=r.lab_id
  where s.id=r.server_id
$$;

create or replace function public.create_my_reservation_range(
  p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text,occurrence_count integer)
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  owner_id uuid:=public.current_ifms_server_id();
  owner_email text;
  first_r public.reservations;
  r public.reservations;
  occurrence timestamptz:=p_start;
  finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
  item_count integer:=0;
begin
  perform public.cleanup_expired_reservations();
  if not exists(
    select 1 from public.labs l join public.sectors s on s.id=l.sector_id
    where l.id=p_lab and l.active and l.reservation_enabled
      and s.active and s.reservation_mode='internal'
  ) then raise exception 'Laboratorio indisponivel para reservas no SIGLAB.'; end if;
  if p_start<=now() then raise exception 'Nao e possivel reservar uma data ou horario passado.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then
    raise exception 'Informe a disciplina ou atividade.';
  end if;
  if p_recurrence not in ('none','weekly') then raise exception 'Repeticao invalida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos proximos 180 dias.';
  end if;
  perform public.validate_reservation_slot(p_start,p_end);

  -- Primeira passagem: uma serie nunca e parcialmente cadastrada.
  loop
    finish:=occurrence+requested_duration;
    perform public.assert_reservation_available(p_lab,occurrence,finish,null);
    exit when p_recurrence='none'
      or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  occurrence:=p_start;
  loop
    finish:=occurrence+requested_duration;
    insert into public.reservations(
      protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
      confirmed_at,authorized_at,recurrence_group,recurrence
    ) values (
      public.next_reservation_protocol(),owner_id,p_lab,btrim(p_subject),
      nullif(btrim(coalesce(p_notes,'')),''),occurrence,finish,'Autorizada','Publico',
      now(),now(),group_id,p_recurrence
    ) returning * into r;
    item_count:=item_count+1;
    if first_r.id is null then first_r:=r; end if;
    exit when p_recurrence='none'
      or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  select lower(email) into owner_email from public.servers where id=owner_id;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(
    first_r.id,owner_email,'reserva_autorizada',
    public.reservation_payload(first_r)||jsonb_build_object('series_count',item_count,'series_until',final_date)
  );
  return query select first_r.id,first_r.protocol,'Autorizada'::text,item_count;
exception when exclusion_violation then
  raise exception 'Conflito em %. Nenhuma reserva da serie foi criada.',
    to_char(occurrence at time zone 'America/Cuiaba','DD/MM/YYYY');
end $$;

create or replace function public.list_my_reservations()
returns table(
  id uuid,protocol text,subject text,lab text,sector text,starts_at timestamptz,
  ends_at timestamptz,status text,recurrence text,recurrence_group uuid,
  occurrence_count bigint
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare owner_id uuid:=public.current_ifms_server_id();
begin
  return query
  select r.id,r.protocol,r.subject,l.name,s.name,r.starts_at,r.ends_at,r.status,
    r.recurrence,r.recurrence_group,count(*) over(partition by r.recurrence_group)
  from public.reservations r
  join public.labs l on l.id=r.lab_id
  join public.sectors s on s.id=l.sector_id
  where r.server_id=owner_id and r.status='Autorizada' and r.ends_at>now()
  order by r.starts_at;
end $$;

revoke all on function public.create_my_reservation_range(uuid,text,timestamptz,timestamptz,text,text,date) from public,anon;
revoke all on function public.list_my_reservations() from public,anon;
grant execute on function public.create_my_reservation_range(uuid,text,timestamptz,timestamptz,text,text,date) to authenticated;
grant execute on function public.list_my_reservations() to authenticated;

-- Desativa as rotas publicas antigas baseadas somente em SIAPE ou link por
-- e-mail. Os nomes sao mantidos para facilitar rollback, mas sem permissao.
revoke all on function public.identify_server(text) from public,anon,authenticated;
revoke all on function public.create_public_reservation(text,uuid,text,timestamptz,integer,text,text,date) from public,anon,authenticated;
revoke all on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) from public,anon,authenticated;
revoke all on function public.my_reservations(text) from public,anon,authenticated;
revoke all on function public.request_reservation_access(text) from public,anon,authenticated;
revoke all on function public.list_my_reservations_secure(uuid) from public,anon,authenticated;
revoke all on function public.request_reservation_cancellation(uuid,uuid,text,text) from public,anon,authenticated;

create or replace function public.staff_create_reservation_range(
  p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_source text default 'Equipe',
  p_recurrence text default 'none',p_until date default null
)
returns public.reservations
language plpgsql
security definer
set search_path=public
as $$
declare
  staff_id uuid:=public.current_staff_profile_id();
  r public.reservations;
  first_r public.reservations;
  occurrence timestamptz:=p_start;
  finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
begin
  if staff_id is null or not public.can_manage_lab(p_lab) then raise exception 'Acesso negado a este laboratorio.'; end if;
  if not exists(select 1 from public.servers where id=p_server and active) then raise exception 'Servidor inativo ou inexistente.'; end if;
  if p_recurrence not in ('none','weekly') then raise exception 'Repeticao invalida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then raise exception 'Periodo invalido.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  perform public.cleanup_expired_reservations();

  loop
    finish:=occurrence+requested_duration;
    perform public.assert_reservation_available(p_lab,occurrence,finish,null);
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  occurrence:=p_start;
  loop
    finish:=occurrence+requested_duration;
    insert into public.reservations(
      protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
      confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence
    ) values (
      public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),
      nullif(btrim(coalesce(p_notes,'')),''),occurrence,finish,'Autorizada',
      case when p_source='CSV' then 'CSV' else 'Equipe' end,
      now(),now(),staff_id,staff_id,group_id,p_recurrence
    ) returning * into r;
    if first_r.id is null then first_r:=r; end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  return first_r;
end $$;

create or replace function public.staff_delete_reservation(p_id uuid,p_scope text default 'occurrence')
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare v_group uuid;v_lab uuid;v_deleted integer:=0;
begin
  select r.recurrence_group,r.lab_id into v_group,v_lab from public.reservations r where r.id=p_id;
  if not found then return 0; end if;
  if not public.can_manage_lab(v_lab) then raise exception 'Acesso negado a este laboratorio.'; end if;
  if lower(coalesce(p_scope,'occurrence'))='series' and v_group is not null then
    delete from public.reservations r where r.recurrence_group=v_group and public.can_manage_lab(r.lab_id);
  else
    delete from public.reservations r where r.id=p_id;
  end if;
  get diagnostics v_deleted=row_count;
  return v_deleted;
end $$;

create or replace function public.staff_delete_cancelled_reservations()
returns integer
language plpgsql security definer set search_path=public as $$
declare deleted_count integer:=0;
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  delete from public.reservations r
  where r.status='Cancelada' and public.can_manage_lab(r.lab_id);
  get diagnostics deleted_count=row_count;
  return deleted_count;
end $$;

revoke all on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) from public,anon;
revoke all on function public.staff_delete_reservation(uuid,text) from public,anon;
revoke all on function public.staff_delete_cancelled_reservations() from public,anon;
revoke all on function public.staff_create_reservation(uuid,uuid,text,timestamptz,integer,text,text,text,date) from public,anon,authenticated;
revoke all on function public.staff_edit_reservation(uuid,uuid,uuid,text,timestamptz,integer,text,text) from public,anon,authenticated;
revoke all on function public.staff_edit_reservation_range(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text) from public,anon,authenticated;
revoke all on function public.staff_cancel_reservation_notification(uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) to authenticated;
grant execute on function public.staff_delete_reservation(uuid,text) to authenticated;
grant execute on function public.staff_delete_cancelled_reservations() to authenticated;

create or replace function public.staff_edit_reservation_range_notification(
  p_id uuid,p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_scope text default 'occurrence',p_notify boolean default true
)
returns public.reservations
language plpgsql security definer set search_path=public as $$
declare
  base public.reservations;item public.reservations;result public.reservations;
  target_start timestamptz;target_end timestamptz;requested_duration interval:=p_end-p_start;
  shift interval;recipient text;
begin
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva nao encontrada.'; end if;
  if not public.can_manage_lab(base.lab_id) or not public.can_manage_lab(p_lab) then
    raise exception 'Acesso negado ao laboratorio de origem ou destino.';
  end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo invalido.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  if not exists(select 1 from public.servers where id=p_server and active) then raise exception 'Servidor inativo ou inexistente.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  shift:=p_start-base.starts_at;
  for item in select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    if not public.can_manage_lab(item.lab_id) then raise exception 'A serie contem laboratorio fora do seu setor.'; end if;
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+requested_duration;
    perform public.assert_reservation_available(p_lab,target_start,target_end,item.id);
  end loop;
  for item in select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+requested_duration;
    update public.reservations set server_id=p_server,lab_id=p_lab,subject=btrim(p_subject),
      notes=nullif(btrim(coalesce(p_notes,'')),''),starts_at=target_start,ends_at=target_end,updated_at=now()
    where id=item.id;
  end loop;
  select * into result from public.reservations where id=p_id;
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=p_server and active;
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
  end if;
  return result;
end $$;

create or replace function public.staff_cancel_reservation_notification(
  p_id uuid,p_reason text,p_notify boolean default true,p_scope text default 'occurrence'
)
returns public.reservations
language plpgsql security definer set search_path=public as $$
declare base public.reservations;result public.reservations;recipient text;
begin
  if p_scope not in ('occurrence','series') then raise exception 'Escopo invalido.'; end if;
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento.'; end if;
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva nao encontrada.'; end if;
  if not public.can_manage_lab(base.lab_id) then raise exception 'Acesso negado a este laboratorio.'; end if;
  update public.reservations set status='Cancelada',cancelled_at=now(),
    cancellation_reason=btrim(p_reason),updated_at=now()
  where id=base.id or (p_scope='series' and recurrence_group=base.recurrence_group and public.can_manage_lab(lab_id));
  select * into result from public.reservations where id=p_id;
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=result.server_id and active;
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(result.id,recipient,'reserva_cancelada',public.reservation_payload(result));
  end if;
  return result;
end $$;

create or replace function public.staff_update_reservation(
  p_id uuid,p_start timestamptz default null,p_lab uuid default null,
  p_status text default null,p_reason text default null
)
returns public.reservations
language plpgsql security definer set search_path=public as $$
declare old public.reservations;result public.reservations;new_start timestamptz;new_end timestamptz;new_lab uuid;
begin
  select * into old from public.reservations where id=p_id for update;
  if old.id is null then raise exception 'Reserva nao encontrada.'; end if;
  new_lab:=coalesce(p_lab,old.lab_id);
  if not public.can_manage_lab(old.lab_id) or not public.can_manage_lab(new_lab) then raise exception 'Acesso negado a este laboratorio.'; end if;
  new_start:=coalesce(p_start,old.starts_at);new_end:=new_start+(old.ends_at-old.starts_at);
  if p_status is null then
    perform public.assert_reservation_available(new_lab,new_start,new_end,old.id);
    update public.reservations set lab_id=new_lab,starts_at=new_start,ends_at=new_end,updated_at=now() where id=p_id;
  elsif p_status='Autorizada' then
    update public.reservations set status='Autorizada',confirmed_at=coalesce(confirmed_at,now()),
      authorized_at=now(),authorized_by=public.current_staff_profile_id(),updated_at=now()
    where recurrence_group=old.recurrence_group and public.can_manage_lab(lab_id);
  elsif p_status='Cancelada' then
    if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento.'; end if;
    update public.reservations set status='Cancelada',cancelled_at=now(),cancellation_reason=btrim(p_reason),updated_at=now()
    where recurrence_group=old.recurrence_group and public.can_manage_lab(lab_id);
  else raise exception 'Status invalido.';
  end if;
  select * into result from public.reservations where id=p_id;
  return result;
end $$;

revoke all on function public.staff_edit_reservation_range_notification(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text,boolean) from public,anon;
revoke all on function public.staff_cancel_reservation_notification(uuid,text,boolean,text) from public,anon;
revoke all on function public.staff_update_reservation(uuid,timestamptz,uuid,text,text) from public,anon;
grant execute on function public.staff_edit_reservation_range_notification(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text,boolean) to authenticated;
grant execute on function public.staff_cancel_reservation_notification(uuid,text,boolean,text) to authenticated;
grant execute on function public.staff_update_reservation(uuid,timestamptz,uuid,text,text) to authenticated;

create or replace function public.staff_reservation_stats()
returns table(pending bigint,authorized bigint,cancelled bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  return query
  with series as (
    select r.recurrence_group,(array_agg(r.status order by r.starts_at))[1] series_status
    from public.reservations r
    where public.can_manage_lab(r.lab_id)
    group by r.recurrence_group
  )
  select
    count(*) filter(where series_status in ('Aguardando confirmação','Aguardando autorização')),
    count(*) filter(where series_status='Autorizada'),
    count(*) filter(where series_status='Cancelada')
  from series;
end $$;

create or replace function public.staff_reservation_history_page(
  p_search text default null,p_offset integer default 0,p_limit integer default 20
)
returns table(
  id uuid,protocol text,recurrence_group uuid,server_id uuid,server_name text,
  lab_id uuid,lab_name text,subject text,notes text,starts_at timestamptz,
  ends_at timestamptz,last_at timestamptz,status text,source text,
  confirmed_at timestamptz,cancellation_reason text,occurrence_count bigint,total_count bigint
)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  return query
  with grouped as (
    select (array_agg(r.id order by r.starts_at))[1] id,
      (array_agg(r.protocol order by r.starts_at))[1] protocol,r.recurrence_group,
      (array_agg(r.server_id order by r.starts_at))[1] server_id,
      (array_agg(s.full_name order by r.starts_at))[1] server_name,
      (array_agg(r.lab_id order by r.starts_at))[1] lab_id,
      (array_agg(l.name order by r.starts_at))[1] lab_name,
      (array_agg(r.subject order by r.starts_at))[1] subject,
      (array_agg(r.notes order by r.starts_at))[1] notes,min(r.starts_at) starts_at,
      (array_agg(r.ends_at order by r.starts_at))[1] ends_at,max(r.starts_at) last_at,
      (array_agg(r.status order by r.starts_at))[1] status,
      (array_agg(r.source order by r.starts_at))[1] source,
      (array_agg(r.confirmed_at order by r.starts_at))[1] confirmed_at,
      (array_agg(r.cancellation_reason order by r.starts_at))[1] cancellation_reason,
      count(*) occurrence_count,
      lower(string_agg(concat_ws(' ',r.protocol,r.subject,s.full_name,l.name,r.status),' ')) search_text
    from public.reservations r join public.servers s on s.id=r.server_id join public.labs l on l.id=r.lab_id
    where public.can_manage_lab(r.lab_id) and r.status not in ('Aguardando confirmação','Aguardando autorização')
    group by r.recurrence_group
  ),filtered as (
    select * from grouped where nullif(btrim(coalesce(p_search,'')),'') is null
      or regexp_replace(search_text,'[^[:alnum:]]','','g') like
        '%'||regexp_replace(lower(btrim(p_search)),'[^[:alnum:]]','','g')||'%'
  )
  select f.id,f.protocol,f.recurrence_group,f.server_id,f.server_name,f.lab_id,f.lab_name,
    f.subject,f.notes,f.starts_at,f.ends_at,f.last_at,f.status,f.source,f.confirmed_at,
    f.cancellation_reason,f.occurrence_count,count(*) over() total_count
  from filtered f order by f.starts_at desc
  offset greatest(coalesce(p_offset,0),0) limit least(greatest(coalesce(p_limit,20),1),50);
end $$;

create or replace function public.staff_review_reservation_cancellation(
  p_request uuid,p_approve boolean,p_notes text default null
) returns table(protocol text,status text,affected_count integer)
language plpgsql security definer set search_path=public as $$
declare req public.reservation_cancellation_requests;r public.reservations;s public.servers;
  affected integer:=0;result_status text;event_name text;
begin
  select * into req from public.reservation_cancellation_requests where id=p_request for update;
  if req.id is null or req.status<>'pending' then raise exception 'Solicitacao indisponivel para analise.'; end if;
  select * into r from public.reservations where id=req.reservation_id for update;
  if not public.can_manage_lab(r.lab_id) then raise exception 'Acesso negado a este laboratorio.'; end if;
  select * into s from public.servers where id=req.server_id;
  if p_approve then
    update public.reservations reservation set status='Cancelada',cancelled_at=now(),updated_at=now(),
      cancellation_reason=coalesce(nullif(btrim(req.reason),''),'Cancelamento solicitado pelo servidor.')
    where reservation.status<>'Cancelada' and reservation.ends_at>now() and public.can_manage_lab(reservation.lab_id) and (
      (req.scope='occurrence' and reservation.id=r.id) or
      (req.scope='future' and reservation.recurrence_group=r.recurrence_group and reservation.starts_at>=r.starts_at) or
      (req.scope='series' and reservation.recurrence_group=r.recurrence_group));
    get diagnostics affected=row_count;result_status:='approved';event_name:='reserva_cancelamento_aprovado';
  else result_status:='rejected';event_name:='reserva_cancelamento_rejeitado'; end if;
  update public.reservation_cancellation_requests set status=result_status,
    reviewed_by=public.current_staff_profile_id(),reviewed_at=now(),
    review_notes=nullif(btrim(coalesce(p_notes,'')),''),updated_at=now() where id=req.id;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(r.id,lower(s.email),event_name,public.reservation_payload(r)||jsonb_build_object(
    'scope',req.scope,'request_reason',req.reason,'review_notes',nullif(btrim(coalesce(p_notes,'')),''),'affected_count',affected));
  return query select r.protocol,result_status,affected;
end $$;

revoke all on function public.staff_reservation_history_page(text,integer,integer) from public,anon;
revoke all on function public.staff_review_reservation_cancellation(uuid,boolean,text) from public,anon;
grant execute on function public.staff_reservation_history_page(text,integer,integer) to authenticated;
grant execute on function public.staff_review_reservation_cancellation(uuid,boolean,text) to authenticated;

-- A administracao de setores e atribuicoes e feita por RPC para impedir que a
-- interface precise receber permissoes amplas sobre perfis.
create or replace function public.admin_save_sector(
  p_id uuid,p_name text,p_slug text,p_description text,p_mode text,p_external_url text,p_active boolean
)
returns public.sectors
language plpgsql security definer set search_path=public as $$
declare result public.sectors;
begin
  if not public.is_siglab_admin() then raise exception 'Somente administradores podem alterar setores.'; end if;
  if p_mode not in ('internal','external') then raise exception 'Modo de reserva invalido.'; end if;
  if p_mode='external' and coalesce(p_external_url,'') !~ '^https://' then raise exception 'Informe uma URL HTTPS.'; end if;
  if p_id is null then
    insert into public.sectors(name,slug,description,reservation_mode,external_url,active)
    values(btrim(p_name),lower(btrim(p_slug)),nullif(btrim(coalesce(p_description,'')),''),p_mode,
      case when p_mode='external' then btrim(p_external_url) else null end,coalesce(p_active,true))
    returning * into result;
  else
    update public.sectors set name=btrim(p_name),slug=lower(btrim(p_slug)),
      description=nullif(btrim(coalesce(p_description,'')),''),reservation_mode=p_mode,
      external_url=case when p_mode='external' then btrim(p_external_url) else null end,
      active=coalesce(p_active,true),updated_at=now()
    where id=p_id returning * into result;
  end if;
  return result;
end $$;

create or replace function public.admin_set_profile_sectors(p_profile uuid,p_sectors uuid[])
returns integer
language plpgsql security definer set search_path=public as $$
declare changed integer:=0;
begin
  if not public.is_siglab_admin() then raise exception 'Somente administradores podem atribuir setores.'; end if;
  if not exists(select 1 from public.profiles where id=p_profile and active) then raise exception 'Tecnico nao localizado.'; end if;
  delete from public.profile_sectors where profile_id=p_profile;
  insert into public.profile_sectors(profile_id,sector_id,created_by)
  select p_profile,s.id,public.current_staff_profile_id()
  from public.sectors s where s.id=any(coalesce(p_sectors,'{}'::uuid[])) and s.active;
  get diagnostics changed=row_count;
  return changed;
end $$;

revoke all on function public.admin_save_sector(uuid,text,text,text,text,text,boolean) from public,anon;
revoke all on function public.admin_set_profile_sectors(uuid,uuid[]) from public,anon;
grant execute on function public.admin_save_sector(uuid,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.admin_set_profile_sectors(uuid,uuid[]) to authenticated;
