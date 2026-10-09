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
