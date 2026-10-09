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

