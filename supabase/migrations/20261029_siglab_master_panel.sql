-- SOMENTE SIGLAB keesciertyonbfqlrqwt. Requer bootstrap multi-setor e login Google.
begin;
alter table public.sectors add column if not exists notification_email text;
-- Uma conta administrativa institucional pode não possuir matrícula funcional.
alter table public.profiles alter column siape drop not null;

create table if not exists public.siglab_access (
  email text primary key check(email=lower(btrim(email)) and email ~ '^[^@[:space:]]+@ifms\.edu\.br$'),
  full_name text not null check(length(btrim(full_name)) between 2 and 160),
  siape text check(siape ~ '^[0-9]{5,12}$'),
  access_role text not null check(access_role in ('master','gestor','servidor')),
  active boolean not null default true,
  sector_ids uuid[] not null default '{}',
  updated_at timestamptz not null default now(),
  check(access_role='master' or siape is not null)
);
create table if not exists public.siglab_admin_audit (
  id bigint generated always as identity primary key,
  actor_email text, entity text not null, record_key text,
  action text not null, before_data jsonb, after_data jsonb,
  created_at timestamptz not null default now()
);
alter table public.siglab_access enable row level security;
alter table public.siglab_admin_audit enable row level security;
revoke all on public.siglab_access,public.siglab_admin_audit from anon,authenticated;

insert into public.siglab_access(email,full_name,access_role)
values('siglab.tl@ifms.edu.br','Administração SIGLAB','master') on conflict(email) do nothing;

create or replace function public.is_siglab_admin()
returns boolean language sql stable security definer set search_path=public,auth as $$
  select public.jwt_uses_google_ifms() and exists(select 1 from public.siglab_access a
    where a.email=lower(btrim(auth.jwt()->>'email')) and a.active and a.access_role='master')
$$;

create or replace function public.current_staff_profile_id()
returns uuid language sql stable security definer set search_path=public,auth as $$
  select p.id from public.profiles p join public.siglab_access a on lower(btrim(p.email))=a.email
  where public.jwt_uses_google_ifms() and a.email=lower(btrim(auth.jwt()->>'email'))
    and a.active and a.access_role in ('master','gestor') and p.active limit 1
$$;

create or replace function public.get_my_staff_profile()
returns table(id uuid,siape text,full_name text,email text,role public.app_role,is_admin boolean,sectors jsonb)
language plpgsql security definer set search_path=public,auth as $$
declare a public.siglab_access; v_profile_id uuid;
begin
  if not public.jwt_uses_google_ifms() then raise exception 'Entre com Google IFMS.'; end if;
  select * into a from public.siglab_access x where x.email=lower(btrim(auth.jwt()->>'email'));
  if a.email is null or not a.active or a.access_role='servidor' then raise exception 'Sem acesso à área interna.'; end if;
  if a.access_role='gestor' and not exists(select 1 from public.servers s where lower(btrim(s.email))=a.email and s.active) then raise exception 'Servidor inativo.'; end if;
  select p.id into v_profile_id from public.profiles p where lower(btrim(p.email))=a.email limit 1;
  if v_profile_id is null then
    insert into public.profiles(id,siape,full_name,email,role,active)
    values(auth.uid(),a.siape,a.full_name,a.email,case when a.access_role='master' then 'admin'::public.app_role else 'tecnico'::public.app_role end,true)
    on conflict on constraint profiles_email_key do update set email=excluded.email
    returning profiles.id into v_profile_id;
  end if;
  return query select p.id,p.siape,p.full_name,p.email,p.role,public.is_siglab_admin(),
    coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug) order by s.sort_order,s.name)
      from public.sectors s where s.id=any(a.sector_ids) and s.active),'[]'::jsonb)
  from public.profiles p where p.id=v_profile_id and p.active;
end $$;

create or replace function public.can_manage_sector(p_sector uuid)
returns boolean language sql stable security definer set search_path=public,auth as $$
  select public.is_siglab_admin() or (public.jwt_uses_google_ifms() and exists(
    select 1 from public.siglab_access a join public.sectors s on s.id=p_sector
    where a.email=lower(btrim(auth.jwt()->>'email')) and a.active and a.access_role='gestor'
      and p_sector=any(a.sector_ids) and s.active))
$$;

create or replace function public.siglab_audit_admin_change()
returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
  insert into public.siglab_admin_audit(actor_email,entity,record_key,action,before_data,after_data)
  values(lower(auth.jwt()->>'email'),tg_table_name,coalesce(to_jsonb(new)->>'email',to_jsonb(new)->>'id',to_jsonb(old)->>'email',to_jsonb(old)->>'id'),tg_op,
    case when tg_op<>'INSERT' then to_jsonb(old) end,case when tg_op<>'DELETE' then to_jsonb(new) end);
  return coalesce(new,old);
end $$;
drop trigger if exists siglab_access_audit on public.siglab_access;
create trigger siglab_access_audit after insert or update or delete on public.siglab_access for each row execute function public.siglab_audit_admin_change();
drop trigger if exists siglab_sector_audit on public.sectors;
create trigger siglab_sector_audit after insert or update or delete on public.sectors for each row execute function public.siglab_audit_admin_change();

create or replace function public.master_dashboard()
returns jsonb language plpgsql security definer set search_path=public,auth as $$
begin
  if not public.is_siglab_admin() then raise exception 'Acesso exclusivo do master.'; end if;
  return jsonb_build_object(
    'sectors',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order,s.name) from public.sectors s),'[]'),
    'users',coalesce((select jsonb_agg(to_jsonb(a) order by a.full_name) from public.siglab_access a),'[]'),
    'audit',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc,q.id desc) from
      (select id,actor_email,entity,record_key,action,created_at from public.siglab_admin_audit order by created_at desc,id desc limit 50) q),'[]'));
end $$;

create or replace function public.master_save_access(p_email text,p_name text,p_siape text,p_role text,p_sectors uuid[],p_active boolean)
returns void language plpgsql security definer set search_path=public,auth as $$
declare mail text:=lower(btrim(p_email)); old_row public.siglab_access; v_profile_id uuid;
begin
  perform pg_advisory_xact_lock(62831029);
  if not public.is_siglab_admin() then raise exception 'Acesso exclusivo do master.'; end if;
  if p_active is null or p_role is null or p_role not in ('master','gestor','servidor') then raise exception 'Perfil inválido.'; end if;
  if mail is null or mail !~ '^[^@[:space:]]+@ifms\.edu\.br$' then raise exception 'Use e-mail @ifms.edu.br.'; end if;
  if p_role<>'master' and coalesce(p_siape,'') !~ '^[0-9]{5,12}$' then raise exception 'Informe SIAPE válido.'; end if;
  if p_role='gestor' and coalesce(cardinality(p_sectors),0)=0 then raise exception 'Selecione ao menos um setor.'; end if;
  if exists(select 1 from unnest(coalesce(p_sectors,'{}')) x where not exists(select 1 from public.sectors s where s.id=x and s.active and s.reservation_mode='internal')) then raise exception 'Setor inexistente, inativo ou externo.'; end if;
  select * into old_row from public.siglab_access a where a.email=mail for update;
  if old_row.active and old_row.access_role='master' and (not p_active or p_role<>'master')
    and not exists(select 1 from public.siglab_access a where a.active and a.access_role='master' and a.email<>mail) then raise exception 'Não é permitido remover o último master ativo.'; end if;
  insert into public.siglab_access(email,full_name,siape,access_role,sector_ids,active)
  values(mail,btrim(p_name),nullif(btrim(p_siape),''),p_role,case when p_role='gestor' then p_sectors else '{}' end,p_active)
  on conflict(email) do update set full_name=excluded.full_name,siape=excluded.siape,access_role=excluded.access_role,sector_ids=excluded.sector_ids,active=excluded.active,updated_at=now();
  update public.profiles p set full_name=btrim(p_name),siape=nullif(btrim(p_siape),''),
    role=case when p_role='master' then 'admin'::public.app_role else 'tecnico'::public.app_role end,
    active=p_active and p_role<>'servidor' where lower(btrim(p.email))=mail returning p.id into v_profile_id;
  if v_profile_id is not null then
    delete from public.profile_sectors ps where ps.profile_id=v_profile_id;
    if p_role='gestor' then insert into public.profile_sectors(profile_id,sector_id,created_by)
      select v_profile_id,s.id,public.current_staff_profile_id() from public.sectors s where s.id=any(p_sectors); end if;
  end if;
  update public.servers set active=p_active where lower(btrim(email))=mail;
  if nullif(btrim(p_siape),'') is not null then
    if exists(select 1 from public.servers s where s.siape=btrim(p_siape) and lower(btrim(s.email))<>mail) then raise exception 'SIAPE já vinculado a outro e-mail.'; end if;
    update public.servers set full_name=btrim(p_name),siape=btrim(p_siape),active=p_active where lower(btrim(email))=mail;
    if not found then insert into public.servers(siape,full_name,email,active) values(btrim(p_siape),btrim(p_name),mail,p_active); end if;
  end if;
end $$;

create or replace function public.master_save_sector(p_id uuid,p_name text,p_slug text,p_email text,p_active boolean)
returns void language plpgsql security definer set search_path=public,auth as $$
begin
  if not public.is_siglab_admin() then raise exception 'Acesso exclusivo do master.'; end if;
  if p_active is null then raise exception 'Situação inválida.'; end if;
  if nullif(btrim(p_email),'') is not null and lower(btrim(p_email)) !~ '^[^@[:space:]]+@ifms\.edu\.br$' then raise exception 'Use e-mail institucional para o setor.'; end if;
  if p_id is null then
    insert into public.sectors(name,slug,notification_email,reservation_mode,active) values(btrim(p_name),lower(btrim(p_slug)),nullif(lower(btrim(p_email)),''),'internal',p_active);
  else
    if not exists(select 1 from public.sectors s where s.id=p_id and s.reservation_mode='internal') then raise exception 'Setor não encontrado ou externo; o vínculo com LabInfo é preservado.'; end if;
    update public.sectors set name=btrim(p_name),slug=lower(btrim(p_slug)),notification_email=nullif(lower(btrim(p_email)),''),active=p_active,updated_at=now() where id=p_id;
  end if;
end $$;

-- Nenhuma escrita direta de perfis/setores pelo navegador: usar RPC auditada.
revoke insert,update,delete on public.profiles,public.profile_sectors,public.sectors,public.servers from authenticated;
-- O e-mail de contato de cada setor só é retornado pela RPC master.
revoke select on public.sectors from anon,authenticated;
grant select(id,name,slug,description,reservation_mode,external_url,active,sort_order,created_at,updated_at) on public.sectors to anon,authenticated;
revoke all on function public.admin_save_sector(uuid,text,text,text,text,text,boolean) from public,anon,authenticated;
revoke all on function public.admin_set_profile_sectors(uuid,uuid[]) from public,anon,authenticated;
revoke all on function public.siglab_audit_admin_change() from public,anon,authenticated;
revoke all on function public.master_dashboard() from public,anon;
revoke all on function public.master_save_access(text,text,text,text,uuid[],boolean) from public,anon;
revoke all on function public.master_save_sector(uuid,text,text,text,boolean) from public,anon;
grant execute on function public.master_dashboard() to authenticated;
grant execute on function public.master_save_access(text,text,text,text,uuid[],boolean) to authenticated;
grant execute on function public.master_save_sector(uuid,text,text,text,boolean) to authenticated;
commit;
notify pgrst,'reload schema';
