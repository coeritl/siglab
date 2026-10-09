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
