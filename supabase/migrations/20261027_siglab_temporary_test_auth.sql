-- Acesso temporario por e-mail e senha para homologacao do SIGLAB.
-- Remova esta excecao quando o Google OAuth institucional for ativado.
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
      or (
        coalesce(auth.jwt()->'app_metadata'->>'provider','')='email'
        and lower(btrim(coalesce(auth.jwt()->>'email',''))) in (
          'siglab.teste.admin@ifms.edu.br',
          'siglab.teste.tecnico@ifms.edu.br',
          'siglab.teste.servidor@ifms.edu.br'
        )
      )
    )
$$;

comment on function public.jwt_uses_google_ifms() is
  'Valida Google IFMS e, temporariamente, as tres contas de homologacao por senha.';
