-- 1) Servidores que poderão abrir e consultar chamados pelo SIAPE.
insert into public.servers(siape,full_name,email) values
('1234567','Servidor de Teste','servidor.teste@ifms.edu.br')
on conflict(siape) do update set full_name=excluded.full_name,email=excluded.email,active=true;

-- 2) Primeiro crie o usuário em Authentication > Users; depois vincule o login.
-- Técnico (pode operar e cadastrar):
insert into public.profiles(id,siape,full_name,email,role)
select id,'9000001','Técnico Administrador',email,'tecnico'
from auth.users where email='tecnico@ifms.edu.br'
on conflict(id) do update set siape=excluded.siape,full_name=excluded.full_name,role=excluded.role,active=true;

-- Supervisor (somente leitura):
insert into public.profiles(id,siape,full_name,email,role)
select id,'9000002','Supervisor LabInfo',email,'supervisor'
from auth.users where email='supervisor@ifms.edu.br'
on conflict(id) do update set siape=excluded.siape,full_name=excluded.full_name,role=excluded.role,active=true;

-- 3) Conferência rápida.
select id,siape,full_name,email,role,active from public.profiles order by full_name;
select id,siape,full_name,email,active from public.servers order by full_name;
