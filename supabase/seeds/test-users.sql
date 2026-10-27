-- Vinculos temporarios para as contas de homologacao criadas no Supabase Auth.
-- Este arquivo nao cria credenciais nem armazena senhas.

insert into public.sectors(name,slug,description,reservation_mode,external_url,sort_order,active)
values
  ('Laboratorios de Eletrotecnica','eletrotecnica','Laboratorios administrados pela equipe de Eletrotecnica.','internal',null,20,true),
  ('Laboratorios de Fisica','fisica','Laboratorios administrados pela equipe de Fisica.','internal',null,30,true),
  ('Laboratorios de Quimica','quimica','Laboratorios administrados pela equipe de Quimica.','internal',null,40,true)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  reservation_mode=excluded.reservation_mode,
  external_url=excluded.external_url,
  sort_order=excluded.sort_order,
  active=excluded.active,
  updated_at=now();

insert into public.profiles(id,siape,full_name,email,role,active)
select id,'9900001','Administrador de Teste',lower(email),'admin'::public.app_role,true
from auth.users where lower(email)='siglab.teste.admin@ifms.edu.br'
on conflict(id) do update set
  siape=excluded.siape,full_name=excluded.full_name,email=excluded.email,
  role=excluded.role,active=true;

insert into public.profiles(id,siape,full_name,email,role,active)
select id,'9900002','Tecnico de Eletrotecnica - Teste',lower(email),'tecnico'::public.app_role,true
from auth.users where lower(email)='siglab.teste.tecnico@ifms.edu.br'
on conflict(id) do update set
  siape=excluded.siape,full_name=excluded.full_name,email=excluded.email,
  role=excluded.role,active=true;

insert into public.servers(siape,full_name,email,active)
values('9900003','Servidor Solicitante - Teste','siglab.teste.servidor@ifms.edu.br',true)
on conflict(siape) do update set
  full_name=excluded.full_name,email=excluded.email,active=true;

insert into public.profile_sectors(profile_id,sector_id,created_by)
select technician.id,sector.id,administrator.id
from public.profiles technician
join public.profiles administrator on administrator.email='siglab.teste.admin@ifms.edu.br'
join public.sectors sector on sector.slug='eletrotecnica'
where technician.email='siglab.teste.tecnico@ifms.edu.br'
on conflict(profile_id,sector_id) do nothing;

do $$
begin
  if not exists(select 1 from public.profiles where email='siglab.teste.admin@ifms.edu.br' and role='admin') then
    raise exception 'Conta Auth do administrador de teste nao localizada.';
  end if;
  if not exists(select 1 from public.profiles where email='siglab.teste.tecnico@ifms.edu.br' and role='tecnico') then
    raise exception 'Conta Auth do tecnico de teste nao localizada.';
  end if;
  if not exists(select 1 from public.servers where email='siglab.teste.servidor@ifms.edu.br' and active) then
    raise exception 'Servidor solicitante de teste nao localizado.';
  end if;
end $$;
