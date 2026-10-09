create or replace function public.staff_upsert_server(
  p_siape text,
  p_full_name text,
  p_email text
) returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_role text;
  v_server public.servers;
  v_reactivated boolean := false;
begin
  select role into v_role
  from public.profiles
  where id = auth.uid() and active = true;

  if v_role not in ('tecnico', 'supervisor') then
    raise exception 'Acesso não autorizado.';
  end if;

  select * into v_server
  from public.servers
  where siape = btrim(p_siape)
  limit 1;

  if found and v_server.active then
    raise exception 'Este SIAPE já está cadastrado e ativo.';
  end if;

  if found then
    v_reactivated := true;
    update public.servers
       set full_name = btrim(p_full_name),
           email = lower(btrim(p_email)),
           active = true
     where id = v_server.id
     returning * into v_server;
  else
    insert into public.servers(siape, full_name, email, active)
    values (btrim(p_siape), btrim(p_full_name), lower(btrim(p_email)), true)
    returning * into v_server;
  end if;

  return jsonb_build_object('id', v_server.id, 'reactivated', v_reactivated);
end;
$$;

revoke all on function public.staff_upsert_server(text,text,text) from public, anon;
grant execute on function public.staff_upsert_server(text,text,text) to authenticated;
