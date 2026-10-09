create or replace function public.clear_closed_chat_history()
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_role text;
  v_count integer;
begin
  select role into v_role from public.profiles where id=auth.uid() and active=true;
  if v_role not in ('tecnico','supervisor') then raise exception 'Acesso não autorizado.'; end if;
  delete from public.chat_sessions where status='closed';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.clear_closed_chat_history() from public, anon;
grant execute on function public.clear_closed_chat_history() to authenticated;
