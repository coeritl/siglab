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
