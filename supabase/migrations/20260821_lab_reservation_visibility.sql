alter table public.labs
  add column if not exists reservation_enabled boolean not null default false;

comment on column public.labs.reservation_enabled is
  'Define se o laboratório aparece na agenda e nos formulários de reserva. Não interfere na abertura de chamados.';

-- Preserva na agenda os espaços que já eram administrados pelo LabInfo.
update public.labs
set reservation_enabled = true
where active = true
  and lower(name) in (
    'laboratório 01',
    'laboratório 02',
    'laboratório 03',
    'laboratório 04',
    'laboratório 05',
    'laboratório de hardware'
  );
