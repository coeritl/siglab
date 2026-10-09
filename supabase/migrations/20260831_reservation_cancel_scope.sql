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
