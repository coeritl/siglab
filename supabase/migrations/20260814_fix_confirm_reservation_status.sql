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
