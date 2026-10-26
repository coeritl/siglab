-- SIGLAB: reservas institucionais multi-setor.
--
-- Esta migration separa a administracao por setor, exige uma sessao Google
-- @ifms.edu.br para todas as operacoes identificadas e permite que um servidor
-- ativo reserve diretamente um horario livre. As permissoes sao verificadas no
-- banco; os filtros da interface nao sao considerados uma barreira de seguranca.

alter type public.app_role add value if not exists 'admin';

create table if not exists public.sectors (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(btrim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  description text,
  reservation_mode text not null default 'internal'
    check (reservation_mode in ('internal','external')),
  external_url text,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (reservation_mode='internal' and external_url is null)
    or
    (reservation_mode='external' and external_url is not null and external_url ~ '^https://')
  )
);

alter table public.labs add column if not exists sector_id uuid references public.sectors(id);
create index if not exists labs_sector_idx on public.labs(sector_id,name) where active;

create table if not exists public.profile_sectors (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  sector_id uuid not null references public.sectors(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  primary key(profile_id,sector_id)
);
create index if not exists profile_sectors_sector_idx on public.profile_sectors(sector_id,profile_id);

insert into public.sectors(name,slug,description,reservation_mode,external_url,sort_order)
values(
  'Laboratorios de Informatica',
  'informatica',
  'Reservas administradas pelo sistema LabInfo.',
  'external',
  'https://labinfo.tl.ifms.edu.br/reservas/',
  10
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  reservation_mode=excluded.reservation_mode,
  external_url=excluded.external_url,
  sort_order=excluded.sort_order,
  updated_at=now();

-- A copia inicial continha apenas laboratorios do LabInfo. Eles permanecem no
-- historico, mas deixam de aceitar reservas no SIGLAB e passam a apontar para o
-- setor externo de Informatica.
update public.labs l set
  sector_id=s.id,
  reservation_enabled=false
from public.sectors s
where s.slug='informatica'
  and l.sector_id is null
  and (lower(l.name) like '%labinfo%' or lower(coalesce(l.code,'')) like 'lab%');

create or replace function public.jwt_uses_google_ifms()
returns boolean
language sql
stable
security definer
set search_path=public,auth
as $$
  select auth.uid() is not null
    and split_part(lower(btrim(coalesce(auth.jwt()->>'email',''))),'@',2)='ifms.edu.br'
    and (
      coalesce(auth.jwt()->'app_metadata'->>'provider','')='google'
      or coalesce(auth.jwt()->'app_metadata'->'providers','[]'::jsonb) @> '["google"]'::jsonb
    )
$$;

create or replace function public.current_ifms_server_id()
returns uuid
language plpgsql
stable
security definer
set search_path=public,auth
as $$
declare
  login_email text:=lower(btrim(coalesce(auth.jwt()->>'email','')));
  server_id uuid;
begin
  if not public.jwt_uses_google_ifms() then
    raise exception 'Entre com sua conta Google institucional @ifms.edu.br.';
  end if;
  select s.id into server_id
  from public.servers s
  where lower(btrim(s.email))=login_email and s.active
  limit 1;
  if server_id is null then
    raise exception 'Seu e-mail nao esta vinculado a um servidor ativo no SIGLAB.';
  end if;
  return server_id;
end $$;

create or replace function public.current_ifms_server_id_or_null()
returns uuid
language sql
stable
security definer
set search_path=public,auth
as $$
  select s.id from public.servers s
  where public.jwt_uses_google_ifms()
    and lower(btrim(s.email))=lower(btrim(coalesce(auth.jwt()->>'email','')))
    and s.active
  limit 1
$$;

create or replace function public.current_staff_profile_id()
returns uuid
language plpgsql
stable
security definer
set search_path=public,auth
as $$
declare
  login_email text:=lower(btrim(coalesce(auth.jwt()->>'email','')));
  profile_id uuid;
begin
  if not public.jwt_uses_google_ifms() then return null; end if;
  select p.id into profile_id
  from public.profiles p
  where lower(btrim(p.email))=login_email and p.active
  limit 1;
  return profile_id;
end $$;

create or replace function public.current_role()
returns public.app_role
language sql
stable
security definer
set search_path=public
as $$
  select p.role from public.profiles p
  where p.id=public.current_staff_profile_id() and p.active
$$;

create or replace function public.is_siglab_admin()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select coalesce(public.current_role()::text='admin',false)
$$;

create or replace function public.can_manage_sector(p_sector uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select public.is_siglab_admin() or exists(
    select 1 from public.profile_sectors ps
    where ps.profile_id=public.current_staff_profile_id() and ps.sector_id=p_sector
  )
$$;

create or replace function public.can_manage_lab(p_lab uuid)
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1 from public.labs l
    where l.id=p_lab and public.can_manage_sector(l.sector_id)
  )
$$;

revoke all on function public.jwt_uses_google_ifms() from public,anon;
revoke all on function public.current_ifms_server_id() from public,anon,authenticated;
revoke all on function public.current_ifms_server_id_or_null() from public,anon;
revoke all on function public.current_staff_profile_id() from public,anon;
revoke all on function public.is_siglab_admin() from public,anon;
revoke all on function public.can_manage_sector(uuid) from public,anon;
revoke all on function public.can_manage_lab(uuid) from public,anon;
grant execute on function public.jwt_uses_google_ifms() to authenticated;
grant execute on function public.current_ifms_server_id_or_null() to authenticated;
grant execute on function public.current_staff_profile_id() to authenticated;
grant execute on function public.is_siglab_admin() to authenticated;
grant execute on function public.can_manage_sector(uuid) to authenticated;
grant execute on function public.can_manage_lab(uuid) to authenticated;

create or replace function public.get_my_ifms_identity()
returns table(id uuid,siape text,full_name text,email text)
language sql
stable
security definer
set search_path=public
as $$
  select s.id,s.siape,s.full_name,s.email
  from public.servers s where s.id=public.current_ifms_server_id()
$$;

create or replace function public.get_my_staff_profile()
returns table(
  id uuid,siape text,full_name text,email text,role public.app_role,
  is_admin boolean,sectors jsonb
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare profile_id uuid:=public.current_staff_profile_id();
begin
  if profile_id is null then
    raise exception 'Esta conta nao possui acesso a area interna do SIGLAB.';
  end if;
  return query
  select p.id,p.siape,p.full_name,p.email,p.role,public.is_siglab_admin(),
    coalesce(jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug)
      order by s.sort_order,s.name) filter(where s.id is not null),'[]'::jsonb)
  from public.profiles p
  left join public.profile_sectors ps on ps.profile_id=p.id
  left join public.sectors s on s.id=ps.sector_id and s.active
  where p.id=profile_id and p.active
  group by p.id;
end $$;

revoke all on function public.get_my_ifms_identity() from public,anon;
revoke all on function public.get_my_staff_profile() from public,anon;
grant execute on function public.get_my_ifms_identity() to authenticated;
grant execute on function public.get_my_staff_profile() to authenticated;

create or replace function public.list_manageable_labs()
returns table(id uuid,name text,code text,sector_id uuid,sector_name text)
language plpgsql
stable
security definer
set search_path=public
as $$
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  return query
  select l.id,l.name,l.code,l.sector_id,s.name
  from public.labs l join public.sectors s on s.id=l.sector_id
  where l.active and l.reservation_enabled and s.active and s.reservation_mode='internal'
    and public.can_manage_lab(l.id)
  order by s.sort_order,s.name,l.name;
end $$;

revoke all on function public.list_manageable_labs() from public,anon;
grant execute on function public.list_manageable_labs() to authenticated;

alter table public.sectors enable row level security;
alter table public.profile_sectors enable row level security;

drop policy if exists sectors_public_read on public.sectors;
create policy sectors_public_read on public.sectors for select to anon using(active);
drop policy if exists sectors_staff_read on public.sectors;
create policy sectors_staff_read on public.sectors for select to authenticated
using(active or public.is_siglab_admin() or public.can_manage_sector(id));
drop policy if exists sectors_admin_write on public.sectors;
create policy sectors_admin_write on public.sectors for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists profile_sectors_read on public.profile_sectors;
create policy profile_sectors_read on public.profile_sectors for select to authenticated
using(public.is_siglab_admin() or profile_id=public.current_staff_profile_id());
drop policy if exists profile_sectors_admin_write on public.profile_sectors;
create policy profile_sectors_admin_write on public.profile_sectors for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists labs_public_read on public.labs;
drop policy if exists labs_write on public.labs;
create policy labs_public_read on public.labs for select to anon using(active);
create policy labs_staff_read on public.labs for select to authenticated
using(active or public.is_siglab_admin() or public.can_manage_sector(sector_id));
create policy labs_sector_write on public.labs for all to authenticated
using(public.is_siglab_admin() or public.can_manage_sector(sector_id))
with check(public.is_siglab_admin() or public.can_manage_sector(sector_id));

-- Substitui as policies herdadas que conheciam apenas tecnico/supervisor.
drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_write on public.profiles;
create policy profiles_staff_read on public.profiles for select to authenticated
using(public.current_staff_profile_id() is not null);
create policy profiles_admin_write on public.profiles for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists servers_read on public.servers;
drop policy if exists servers_write on public.servers;
create policy servers_staff_read on public.servers for select to authenticated
using(public.current_staff_profile_id() is not null);
create policy servers_admin_write on public.servers for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists categories_public_read on public.categories;
drop policy if exists categories_write on public.categories;
create policy categories_public_read on public.categories for select to anon using(active);
create policy categories_staff_read on public.categories for select to authenticated
using(active or public.current_staff_profile_id() is not null);
create policy categories_admin_write on public.categories for all to authenticated
using(public.is_siglab_admin()) with check(public.is_siglab_admin());

drop policy if exists reservations_staff_read on public.reservations;
create policy reservations_scoped_read on public.reservations for select to authenticated
using(
  server_id=(select public.current_ifms_server_id_or_null())
  or public.can_manage_lab(lab_id)
);

drop policy if exists reservation_cancellation_staff_read on public.reservation_cancellation_requests;
create policy reservation_cancellation_scoped_read
on public.reservation_cancellation_requests for select to authenticated
using(
  server_id=(select public.current_ifms_server_id_or_null())
  or exists(
    select 1 from public.reservations r
    where r.id=reservation_id and public.can_manage_lab(r.lab_id)
  )
);

create or replace function public.reservation_payload(r public.reservations)
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  select jsonb_build_object(
    'protocol',r.protocol,'reservation_id',r.id,'server_name',s.full_name,
    'title',r.subject,'lab',l.name,'starts_at',r.starts_at,'ends_at',r.ends_at,
    'status',r.status,'reason',r.cancellation_reason,
    'portal_url','https://laboratorios.tl.ifms.edu.br/reservas/'
  )
  from public.servers s join public.labs l on l.id=r.lab_id
  where s.id=r.server_id
$$;

create or replace function public.create_my_reservation_range(
  p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_recurrence text default 'none',p_until date default null
)
returns table(id uuid,protocol text,status text,occurrence_count integer)
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  owner_id uuid:=public.current_ifms_server_id();
  owner_email text;
  first_r public.reservations;
  r public.reservations;
  occurrence timestamptz:=p_start;
  finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
  item_count integer:=0;
begin
  perform public.cleanup_expired_reservations();
  if not exists(
    select 1 from public.labs l join public.sectors s on s.id=l.sector_id
    where l.id=p_lab and l.active and l.reservation_enabled
      and s.active and s.reservation_mode='internal'
  ) then raise exception 'Laboratorio indisponivel para reservas no SIGLAB.'; end if;
  if p_start<=now() then raise exception 'Nao e possivel reservar uma data ou horario passado.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then
    raise exception 'Informe a disciplina ou atividade.';
  end if;
  if p_recurrence not in ('none','weekly') then raise exception 'Repeticao invalida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then
    raise exception 'A data final deve estar dentro dos proximos 180 dias.';
  end if;
  perform public.validate_reservation_slot(p_start,p_end);

  -- Primeira passagem: uma serie nunca e parcialmente cadastrada.
  loop
    finish:=occurrence+requested_duration;
    perform public.assert_reservation_available(p_lab,occurrence,finish,null);
    exit when p_recurrence='none'
      or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  occurrence:=p_start;
  loop
    finish:=occurrence+requested_duration;
    insert into public.reservations(
      protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
      confirmed_at,authorized_at,recurrence_group,recurrence
    ) values (
      public.next_reservation_protocol(),owner_id,p_lab,btrim(p_subject),
      nullif(btrim(coalesce(p_notes,'')),''),occurrence,finish,'Autorizada','Publico',
      now(),now(),group_id,p_recurrence
    ) returning * into r;
    item_count:=item_count+1;
    if first_r.id is null then first_r:=r; end if;
    exit when p_recurrence='none'
      or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  select lower(email) into owner_email from public.servers where id=owner_id;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(
    first_r.id,owner_email,'reserva_autorizada',
    public.reservation_payload(first_r)||jsonb_build_object('series_count',item_count,'series_until',final_date)
  );
  return query select first_r.id,first_r.protocol,'Autorizada'::text,item_count;
exception when exclusion_violation then
  raise exception 'Conflito em %. Nenhuma reserva da serie foi criada.',
    to_char(occurrence at time zone 'America/Cuiaba','DD/MM/YYYY');
end $$;

create or replace function public.list_my_reservations()
returns table(
  id uuid,protocol text,subject text,lab text,sector text,starts_at timestamptz,
  ends_at timestamptz,status text,recurrence text,recurrence_group uuid,
  occurrence_count bigint
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare owner_id uuid:=public.current_ifms_server_id();
begin
  return query
  select r.id,r.protocol,r.subject,l.name,s.name,r.starts_at,r.ends_at,r.status,
    r.recurrence,r.recurrence_group,count(*) over(partition by r.recurrence_group)
  from public.reservations r
  join public.labs l on l.id=r.lab_id
  join public.sectors s on s.id=l.sector_id
  where r.server_id=owner_id and r.status='Autorizada' and r.ends_at>now()
  order by r.starts_at;
end $$;

revoke all on function public.create_my_reservation_range(uuid,text,timestamptz,timestamptz,text,text,date) from public,anon;
revoke all on function public.list_my_reservations() from public,anon;
grant execute on function public.create_my_reservation_range(uuid,text,timestamptz,timestamptz,text,text,date) to authenticated;
grant execute on function public.list_my_reservations() to authenticated;

-- Desativa as rotas publicas antigas baseadas somente em SIAPE ou link por
-- e-mail. Os nomes sao mantidos para facilitar rollback, mas sem permissao.
revoke all on function public.identify_server(text) from public,anon,authenticated;
revoke all on function public.create_public_reservation(text,uuid,text,timestamptz,integer,text,text,date) from public,anon,authenticated;
revoke all on function public.create_public_reservation_range(text,uuid,text,timestamptz,timestamptz,text,text,date) from public,anon,authenticated;
revoke all on function public.my_reservations(text) from public,anon,authenticated;
revoke all on function public.request_reservation_access(text) from public,anon,authenticated;
revoke all on function public.list_my_reservations_secure(uuid) from public,anon,authenticated;
revoke all on function public.request_reservation_cancellation(uuid,uuid,text,text) from public,anon,authenticated;

create or replace function public.staff_create_reservation_range(
  p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_source text default 'Equipe',
  p_recurrence text default 'none',p_until date default null
)
returns public.reservations
language plpgsql
security definer
set search_path=public
as $$
declare
  staff_id uuid:=public.current_staff_profile_id();
  r public.reservations;
  first_r public.reservations;
  occurrence timestamptz:=p_start;
  finish timestamptz;
  requested_duration interval:=p_end-p_start;
  final_date date:=coalesce(p_until,(p_start at time zone 'America/Cuiaba')::date);
  group_id uuid:=gen_random_uuid();
begin
  if staff_id is null or not public.can_manage_lab(p_lab) then raise exception 'Acesso negado a este laboratorio.'; end if;
  if not exists(select 1 from public.servers where id=p_server and active) then raise exception 'Servidor inativo ou inexistente.'; end if;
  if p_recurrence not in ('none','weekly') then raise exception 'Repeticao invalida.'; end if;
  if final_date<(p_start at time zone 'America/Cuiaba')::date
     or final_date>(p_start at time zone 'America/Cuiaba')::date+interval '180 days' then raise exception 'Periodo invalido.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  perform public.cleanup_expired_reservations();

  loop
    finish:=occurrence+requested_duration;
    perform public.assert_reservation_available(p_lab,occurrence,finish,null);
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;

  occurrence:=p_start;
  loop
    finish:=occurrence+requested_duration;
    insert into public.reservations(
      protocol,server_id,lab_id,subject,notes,starts_at,ends_at,status,source,
      confirmed_at,authorized_at,authorized_by,created_by,recurrence_group,recurrence
    ) values (
      public.next_reservation_protocol(),p_server,p_lab,btrim(p_subject),
      nullif(btrim(coalesce(p_notes,'')),''),occurrence,finish,'Autorizada',
      case when p_source='CSV' then 'CSV' else 'Equipe' end,
      now(),now(),staff_id,staff_id,group_id,p_recurrence
    ) returning * into r;
    if first_r.id is null then first_r:=r; end if;
    exit when p_recurrence='none' or (occurrence at time zone 'America/Cuiaba')::date>=final_date;
    occurrence:=occurrence+interval '7 days';
    exit when (occurrence at time zone 'America/Cuiaba')::date>final_date;
  end loop;
  return first_r;
end $$;

create or replace function public.staff_delete_reservation(p_id uuid,p_scope text default 'occurrence')
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare v_group uuid;v_lab uuid;v_deleted integer:=0;
begin
  select r.recurrence_group,r.lab_id into v_group,v_lab from public.reservations r where r.id=p_id;
  if not found then return 0; end if;
  if not public.can_manage_lab(v_lab) then raise exception 'Acesso negado a este laboratorio.'; end if;
  if lower(coalesce(p_scope,'occurrence'))='series' and v_group is not null then
    delete from public.reservations r where r.recurrence_group=v_group and public.can_manage_lab(r.lab_id);
  else
    delete from public.reservations r where r.id=p_id;
  end if;
  get diagnostics v_deleted=row_count;
  return v_deleted;
end $$;

create or replace function public.staff_delete_cancelled_reservations()
returns integer
language plpgsql security definer set search_path=public as $$
declare deleted_count integer:=0;
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  delete from public.reservations r
  where r.status='Cancelada' and public.can_manage_lab(r.lab_id);
  get diagnostics deleted_count=row_count;
  return deleted_count;
end $$;

revoke all on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) from public,anon;
revoke all on function public.staff_delete_reservation(uuid,text) from public,anon;
revoke all on function public.staff_delete_cancelled_reservations() from public,anon;
revoke all on function public.staff_create_reservation(uuid,uuid,text,timestamptz,integer,text,text,text,date) from public,anon,authenticated;
revoke all on function public.staff_edit_reservation(uuid,uuid,uuid,text,timestamptz,integer,text,text) from public,anon,authenticated;
revoke all on function public.staff_edit_reservation_range(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text) from public,anon,authenticated;
revoke all on function public.staff_cancel_reservation_notification(uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.staff_create_reservation_range(uuid,uuid,text,timestamptz,timestamptz,text,text,text,date) to authenticated;
grant execute on function public.staff_delete_reservation(uuid,text) to authenticated;
grant execute on function public.staff_delete_cancelled_reservations() to authenticated;

create or replace function public.staff_edit_reservation_range_notification(
  p_id uuid,p_server uuid,p_lab uuid,p_subject text,p_start timestamptz,p_end timestamptz,
  p_notes text default null,p_scope text default 'occurrence',p_notify boolean default true
)
returns public.reservations
language plpgsql security definer set search_path=public as $$
declare
  base public.reservations;item public.reservations;result public.reservations;
  target_start timestamptz;target_end timestamptz;requested_duration interval:=p_end-p_start;
  shift interval;recipient text;
begin
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva nao encontrada.'; end if;
  if not public.can_manage_lab(base.lab_id) or not public.can_manage_lab(p_lab) then
    raise exception 'Acesso negado ao laboratorio de origem ou destino.';
  end if;
  if p_scope not in ('occurrence','series') then raise exception 'Escopo invalido.'; end if;
  if length(btrim(coalesce(p_subject,''))) not between 2 and 160 then raise exception 'Informe a disciplina ou atividade.'; end if;
  if not exists(select 1 from public.servers where id=p_server and active) then raise exception 'Servidor inativo ou inexistente.'; end if;
  perform public.validate_reservation_slot(p_start,p_end);
  shift:=p_start-base.starts_at;
  for item in select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    if not public.can_manage_lab(item.lab_id) then raise exception 'A serie contem laboratorio fora do seu setor.'; end if;
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+requested_duration;
    perform public.assert_reservation_available(p_lab,target_start,target_end,item.id);
  end loop;
  for item in select * from public.reservations
    where id=p_id or (p_scope='series' and recurrence_group=base.recurrence_group)
    order by starts_at for update
  loop
    target_start:=case when p_scope='series' then item.starts_at+shift else p_start end;
    target_end:=target_start+requested_duration;
    update public.reservations set server_id=p_server,lab_id=p_lab,subject=btrim(p_subject),
      notes=nullif(btrim(coalesce(p_notes,'')),''),starts_at=target_start,ends_at=target_end,updated_at=now()
    where id=item.id;
  end loop;
  select * into result from public.reservations where id=p_id;
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=p_server and active;
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(result.id,recipient,'reserva_alterada',public.reservation_payload(result));
  end if;
  return result;
end $$;

create or replace function public.staff_cancel_reservation_notification(
  p_id uuid,p_reason text,p_notify boolean default true,p_scope text default 'occurrence'
)
returns public.reservations
language plpgsql security definer set search_path=public as $$
declare base public.reservations;result public.reservations;recipient text;
begin
  if p_scope not in ('occurrence','series') then raise exception 'Escopo invalido.'; end if;
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento.'; end if;
  select * into base from public.reservations where id=p_id for update;
  if base.id is null then raise exception 'Reserva nao encontrada.'; end if;
  if not public.can_manage_lab(base.lab_id) then raise exception 'Acesso negado a este laboratorio.'; end if;
  update public.reservations set status='Cancelada',cancelled_at=now(),
    cancellation_reason=btrim(p_reason),updated_at=now()
  where id=base.id or (p_scope='series' and recurrence_group=base.recurrence_group and public.can_manage_lab(lab_id));
  select * into result from public.reservations where id=p_id;
  if coalesce(p_notify,true) then
    select lower(email) into recipient from public.servers where id=result.server_id and active;
    insert into public.email_outbox(reservation_id,recipient,event_type,payload)
    values(result.id,recipient,'reserva_cancelada',public.reservation_payload(result));
  end if;
  return result;
end $$;

create or replace function public.staff_update_reservation(
  p_id uuid,p_start timestamptz default null,p_lab uuid default null,
  p_status text default null,p_reason text default null
)
returns public.reservations
language plpgsql security definer set search_path=public as $$
declare old public.reservations;result public.reservations;new_start timestamptz;new_end timestamptz;new_lab uuid;
begin
  select * into old from public.reservations where id=p_id for update;
  if old.id is null then raise exception 'Reserva nao encontrada.'; end if;
  new_lab:=coalesce(p_lab,old.lab_id);
  if not public.can_manage_lab(old.lab_id) or not public.can_manage_lab(new_lab) then raise exception 'Acesso negado a este laboratorio.'; end if;
  new_start:=coalesce(p_start,old.starts_at);new_end:=new_start+(old.ends_at-old.starts_at);
  if p_status is null then
    perform public.assert_reservation_available(new_lab,new_start,new_end,old.id);
    update public.reservations set lab_id=new_lab,starts_at=new_start,ends_at=new_end,updated_at=now() where id=p_id;
  elsif p_status='Autorizada' then
    update public.reservations set status='Autorizada',confirmed_at=coalesce(confirmed_at,now()),
      authorized_at=now(),authorized_by=public.current_staff_profile_id(),updated_at=now()
    where recurrence_group=old.recurrence_group and public.can_manage_lab(lab_id);
  elsif p_status='Cancelada' then
    if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo do cancelamento.'; end if;
    update public.reservations set status='Cancelada',cancelled_at=now(),cancellation_reason=btrim(p_reason),updated_at=now()
    where recurrence_group=old.recurrence_group and public.can_manage_lab(lab_id);
  else raise exception 'Status invalido.';
  end if;
  select * into result from public.reservations where id=p_id;
  return result;
end $$;

revoke all on function public.staff_edit_reservation_range_notification(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text,boolean) from public,anon;
revoke all on function public.staff_cancel_reservation_notification(uuid,text,boolean,text) from public,anon;
revoke all on function public.staff_update_reservation(uuid,timestamptz,uuid,text,text) from public,anon;
grant execute on function public.staff_edit_reservation_range_notification(uuid,uuid,uuid,text,timestamptz,timestamptz,text,text,boolean) to authenticated;
grant execute on function public.staff_cancel_reservation_notification(uuid,text,boolean,text) to authenticated;
grant execute on function public.staff_update_reservation(uuid,timestamptz,uuid,text,text) to authenticated;

create or replace function public.staff_reservation_stats()
returns table(pending bigint,authorized bigint,cancelled bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  return query
  with series as (
    select r.recurrence_group,(array_agg(r.status order by r.starts_at))[1] series_status
    from public.reservations r
    where public.can_manage_lab(r.lab_id)
    group by r.recurrence_group
  )
  select
    count(*) filter(where series_status in ('Aguardando confirmação','Aguardando autorização')),
    count(*) filter(where series_status='Autorizada'),
    count(*) filter(where series_status='Cancelada')
  from series;
end $$;

create or replace function public.staff_reservation_history_page(
  p_search text default null,p_offset integer default 0,p_limit integer default 20
)
returns table(
  id uuid,protocol text,recurrence_group uuid,server_id uuid,server_name text,
  lab_id uuid,lab_name text,subject text,notes text,starts_at timestamptz,
  ends_at timestamptz,last_at timestamptz,status text,source text,
  confirmed_at timestamptz,cancellation_reason text,occurrence_count bigint,total_count bigint
)
language plpgsql stable security definer set search_path=public as $$
begin
  if public.current_staff_profile_id() is null then raise exception 'Acesso negado.'; end if;
  return query
  with grouped as (
    select (array_agg(r.id order by r.starts_at))[1] id,
      (array_agg(r.protocol order by r.starts_at))[1] protocol,r.recurrence_group,
      (array_agg(r.server_id order by r.starts_at))[1] server_id,
      (array_agg(s.full_name order by r.starts_at))[1] server_name,
      (array_agg(r.lab_id order by r.starts_at))[1] lab_id,
      (array_agg(l.name order by r.starts_at))[1] lab_name,
      (array_agg(r.subject order by r.starts_at))[1] subject,
      (array_agg(r.notes order by r.starts_at))[1] notes,min(r.starts_at) starts_at,
      (array_agg(r.ends_at order by r.starts_at))[1] ends_at,max(r.starts_at) last_at,
      (array_agg(r.status order by r.starts_at))[1] status,
      (array_agg(r.source order by r.starts_at))[1] source,
      (array_agg(r.confirmed_at order by r.starts_at))[1] confirmed_at,
      (array_agg(r.cancellation_reason order by r.starts_at))[1] cancellation_reason,
      count(*) occurrence_count,
      lower(string_agg(concat_ws(' ',r.protocol,r.subject,s.full_name,l.name,r.status),' ')) search_text
    from public.reservations r join public.servers s on s.id=r.server_id join public.labs l on l.id=r.lab_id
    where public.can_manage_lab(r.lab_id) and r.status not in ('Aguardando confirmação','Aguardando autorização')
    group by r.recurrence_group
  ),filtered as (
    select * from grouped where nullif(btrim(coalesce(p_search,'')),'') is null
      or regexp_replace(search_text,'[^[:alnum:]]','','g') like
        '%'||regexp_replace(lower(btrim(p_search)),'[^[:alnum:]]','','g')||'%'
  )
  select f.id,f.protocol,f.recurrence_group,f.server_id,f.server_name,f.lab_id,f.lab_name,
    f.subject,f.notes,f.starts_at,f.ends_at,f.last_at,f.status,f.source,f.confirmed_at,
    f.cancellation_reason,f.occurrence_count,count(*) over() total_count
  from filtered f order by f.starts_at desc
  offset greatest(coalesce(p_offset,0),0) limit least(greatest(coalesce(p_limit,20),1),50);
end $$;

create or replace function public.staff_review_reservation_cancellation(
  p_request uuid,p_approve boolean,p_notes text default null
) returns table(protocol text,status text,affected_count integer)
language plpgsql security definer set search_path=public as $$
declare req public.reservation_cancellation_requests;r public.reservations;s public.servers;
  affected integer:=0;result_status text;event_name text;
begin
  select * into req from public.reservation_cancellation_requests where id=p_request for update;
  if req.id is null or req.status<>'pending' then raise exception 'Solicitacao indisponivel para analise.'; end if;
  select * into r from public.reservations where id=req.reservation_id for update;
  if not public.can_manage_lab(r.lab_id) then raise exception 'Acesso negado a este laboratorio.'; end if;
  select * into s from public.servers where id=req.server_id;
  if p_approve then
    update public.reservations reservation set status='Cancelada',cancelled_at=now(),updated_at=now(),
      cancellation_reason=coalesce(nullif(btrim(req.reason),''),'Cancelamento solicitado pelo servidor.')
    where reservation.status<>'Cancelada' and reservation.ends_at>now() and public.can_manage_lab(reservation.lab_id) and (
      (req.scope='occurrence' and reservation.id=r.id) or
      (req.scope='future' and reservation.recurrence_group=r.recurrence_group and reservation.starts_at>=r.starts_at) or
      (req.scope='series' and reservation.recurrence_group=r.recurrence_group));
    get diagnostics affected=row_count;result_status:='approved';event_name:='reserva_cancelamento_aprovado';
  else result_status:='rejected';event_name:='reserva_cancelamento_rejeitado'; end if;
  update public.reservation_cancellation_requests set status=result_status,
    reviewed_by=public.current_staff_profile_id(),reviewed_at=now(),
    review_notes=nullif(btrim(coalesce(p_notes,'')),''),updated_at=now() where id=req.id;
  insert into public.email_outbox(reservation_id,recipient,event_type,payload)
  values(r.id,lower(s.email),event_name,public.reservation_payload(r)||jsonb_build_object(
    'scope',req.scope,'request_reason',req.reason,'review_notes',nullif(btrim(coalesce(p_notes,'')),''),'affected_count',affected));
  return query select r.protocol,result_status,affected;
end $$;

revoke all on function public.staff_reservation_history_page(text,integer,integer) from public,anon;
revoke all on function public.staff_review_reservation_cancellation(uuid,boolean,text) from public,anon;
grant execute on function public.staff_reservation_history_page(text,integer,integer) to authenticated;
grant execute on function public.staff_review_reservation_cancellation(uuid,boolean,text) to authenticated;

-- A administracao de setores e atribuicoes e feita por RPC para impedir que a
-- interface precise receber permissoes amplas sobre perfis.
create or replace function public.admin_save_sector(
  p_id uuid,p_name text,p_slug text,p_description text,p_mode text,p_external_url text,p_active boolean
)
returns public.sectors
language plpgsql security definer set search_path=public as $$
declare result public.sectors;
begin
  if not public.is_siglab_admin() then raise exception 'Somente administradores podem alterar setores.'; end if;
  if p_mode not in ('internal','external') then raise exception 'Modo de reserva invalido.'; end if;
  if p_mode='external' and coalesce(p_external_url,'') !~ '^https://' then raise exception 'Informe uma URL HTTPS.'; end if;
  if p_id is null then
    insert into public.sectors(name,slug,description,reservation_mode,external_url,active)
    values(btrim(p_name),lower(btrim(p_slug)),nullif(btrim(coalesce(p_description,'')),''),p_mode,
      case when p_mode='external' then btrim(p_external_url) else null end,coalesce(p_active,true))
    returning * into result;
  else
    update public.sectors set name=btrim(p_name),slug=lower(btrim(p_slug)),
      description=nullif(btrim(coalesce(p_description,'')),''),reservation_mode=p_mode,
      external_url=case when p_mode='external' then btrim(p_external_url) else null end,
      active=coalesce(p_active,true),updated_at=now()
    where id=p_id returning * into result;
  end if;
  return result;
end $$;

create or replace function public.admin_set_profile_sectors(p_profile uuid,p_sectors uuid[])
returns integer
language plpgsql security definer set search_path=public as $$
declare changed integer:=0;
begin
  if not public.is_siglab_admin() then raise exception 'Somente administradores podem atribuir setores.'; end if;
  if not exists(select 1 from public.profiles where id=p_profile and active) then raise exception 'Tecnico nao localizado.'; end if;
  delete from public.profile_sectors where profile_id=p_profile;
  insert into public.profile_sectors(profile_id,sector_id,created_by)
  select p_profile,s.id,public.current_staff_profile_id()
  from public.sectors s where s.id=any(coalesce(p_sectors,'{}'::uuid[])) and s.active;
  get diagnostics changed=row_count;
  return changed;
end $$;

revoke all on function public.admin_save_sector(uuid,text,text,text,text,text,boolean) from public,anon;
revoke all on function public.admin_set_profile_sectors(uuid,uuid[]) from public,anon;
grant execute on function public.admin_save_sector(uuid,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.admin_set_profile_sectors(uuid,uuid[]) to authenticated;

