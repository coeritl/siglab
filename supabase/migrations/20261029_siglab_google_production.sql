-- Executar SOMENTE no projeto SIGLAB keesciertyonbfqlrqwt.
-- Pré-requisito: bootstrap multi-setor já instalado.
begin;
create or replace function public.jwt_uses_google_ifms()
returns boolean language sql stable security definer set search_path=public,auth
as $$
  select auth.uid() is not null
    and split_part(lower(btrim(coalesce(auth.jwt()->>'email',''))),'@',2)='ifms.edu.br'
    and (coalesce(auth.jwt()->'app_metadata'->>'provider','')='google'
      or coalesce(auth.jwt()->'app_metadata'->'providers','[]'::jsonb) @> '["google"]'::jsonb)
$$;
revoke all on function public.jwt_uses_google_ifms() from public,anon;
grant execute on function public.jwt_uses_google_ifms() to authenticated;

-- O solicitante é determinado pela sessão, nunca por SIAPE recebido do navegador.
create or replace function public.request_my_reservation_cancellation(
  p_reservation uuid,p_scope text default 'occurrence',p_reason text default null
) returns table(protocol text)
language plpgsql security definer set search_path=public,auth
as $$
declare owner_id uuid:=public.current_ifms_server_id();
  reservation_row public.reservations;
begin
  if p_scope not in ('occurrence','future','series') then raise exception 'Alcance inválido.'; end if;
  if length(coalesce(p_reason,''))>500 then raise exception 'Motivo muito longo.'; end if;
  select r.* into reservation_row from public.reservations r
    where r.id=p_reservation and r.server_id=owner_id for update;
  if reservation_row.id is null then raise exception 'Reserva não encontrada para esta conta.'; end if;
  if reservation_row.status<>'Autorizada' or reservation_row.ends_at<=now() then raise exception 'Esta reserva não pode receber solicitação de cancelamento.'; end if;
  if exists(select 1 from public.reservation_cancellation_requests c where c.reservation_id=p_reservation and c.status='pending') then raise exception 'Já existe uma solicitação pendente.'; end if;
  insert into public.reservation_cancellation_requests(reservation_id,server_id,scope,reason,status,email_confirmed_at,confirmation_token_hash,confirmation_expires_at)
    values(p_reservation,owner_id,p_scope,nullif(btrim(p_reason),''),'pending',now(),md5(gen_random_uuid()::text),now());
  return query select reservation_row.protocol;
end $$;
revoke all on function public.request_my_reservation_cancellation(uuid,text,text) from public,anon;
grant execute on function public.request_my_reservation_cancellation(uuid,text,text) to authenticated;
commit;
notify pgrst,'reload schema';
