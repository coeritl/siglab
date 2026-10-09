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
