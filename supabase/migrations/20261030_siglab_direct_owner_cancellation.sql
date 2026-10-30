-- Executar SOMENTE no Supabase SIGLAB (keesciertyonbfqlrqwt).
-- RPC própria: a interface só informa cancelamento após executar este fluxo.
begin;
create or replace function public.cancel_my_reservation(
  p_reservation uuid,p_scope text default 'occurrence',p_reason text default null
) returns table(protocol text)
language plpgsql security definer set search_path=public,auth
as $$
declare owner_id uuid:=public.current_ifms_server_id();
  base public.reservations;
  cancelled public.reservations;
  affected integer;
  recipient_email text;
begin
  if owner_id is null then raise exception 'Entre com uma conta institucional ativa.'; end if;
  if p_scope is null or p_scope not in ('occurrence','future','series') then raise exception 'Alcance inválido.'; end if;
  if length(coalesce(p_reason,''))>500 then raise exception 'Motivo muito longo.'; end if;
  select r.* into base from public.reservations r
    where r.id=p_reservation and r.server_id=owner_id for update;
  if base.id is null then raise exception 'Reserva não encontrada para esta conta.'; end if;
  if base.status<>'Autorizada' or base.starts_at<=now() then
    raise exception 'Somente reservas autorizadas que ainda não começaram podem ser canceladas.';
  end if;
  update public.reservations as r set status='Cancelada',cancelled_at=now(),updated_at=now(),
    cancellation_reason=coalesce(nullif(btrim(p_reason),''),'Cancelada pelo próprio servidor autenticado.')
  where r.server_id=owner_id and r.status='Autorizada' and r.starts_at>now() and (
    (p_scope='occurrence' and r.id=base.id) or
    (p_scope in ('future','series') and base.recurrence_group is not null and
      r.recurrence_group=base.recurrence_group and
      (p_scope='series' or r.starts_at>=base.starts_at)) or
    (base.recurrence_group is null and r.id=base.id)
  );
  get diagnostics affected=row_count;
  select r.* into cancelled from public.reservations r where r.id=base.id;
  -- Pedidos anteriores deixam de aguardar análise após o cancelamento direto.
  update public.reservation_cancellation_requests as cr set
    status='approved',reviewed_at=now(),updated_at=now(),
    review_notes='Reserva cancelada diretamente pelo próprio servidor autenticado.'
  where cr.server_id=owner_id and cr.status in ('pending','awaiting_email') and exists(
    select 1 from public.reservations r where r.id=cr.reservation_id and r.status='Cancelada'
  );
  select lower(s.email) into recipient_email from public.servers s where s.id=owner_id;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(base.id,recipient_email,'reserva_cancelada',public.reservation_payload(cancelled)||
      jsonb_build_object('scope',p_scope,'affected_count',affected));
  return query select base.protocol;
end $$;
revoke all on function public.cancel_my_reservation(uuid,text,text) from public,anon;
grant execute on function public.cancel_my_reservation(uuid,text,text) to authenticated;
commit;
notify pgrst,'reload schema';
