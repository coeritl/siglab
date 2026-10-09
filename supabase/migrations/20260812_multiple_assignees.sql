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

