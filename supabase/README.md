# Configuração do Supabase do SIGLAB

O SIGLAB deve usar um projeto Supabase próprio. Não reutilize a URL, a chave
pública, o banco, o Apps Script ou o cliente OAuth do LabInfo em produção.

## Banco

1. Crie um projeto Supabase exclusivo.
2. Para uma instalação nova, execute uma única vez
   `bootstrap.generated.sql` no SQL Editor. Ele consolida `schema.sql` e todas
   as migrações na ordem correta.
3. Para regenerar o arquivo após novas migrações, execute
   `node scripts/build-supabase-bootstrap.mjs`.
4. A migração `20261026_siglab_multisector_google_reservations.sql` instala
   setores, permissões por laboratório, autenticação Google e reservas diretas.
5. Preencha `supabase-config.js` somente com a URL e a chave pública do novo
   projeto.

## Google Workspace

No Google Auth Platform, crie um cliente Web exclusivo do SIGLAB:

- origem JavaScript: `https://laboratorios.tl.ifms.edu.br`;
- URI de redirecionamento: a URL `...supabase.co/auth/v1/callback` exibida pelo
  provedor Google no Supabase.

No Supabase, ative **Authentication → Providers → Google** com esse Client ID
e Client Secret. Em **URL Configuration**, use:

- Site URL: `https://laboratorios.tl.ifms.edu.br`;
- Redirect URL: `https://laboratorios.tl.ifms.edu.br/**`.

O domínio informado na interface não é a barreira de segurança. As funções do
banco também conferem o provedor Google, o domínio `@ifms.edu.br` e o cadastro
ativo em `servers` ou `profiles`.

## Primeiro administrador

Cadastre o servidor em `servers`, faça uma primeira entrada pelo Google e,
depois, vincule o usuário criado pelo Supabase:

```sql
insert into public.servers(siape,full_name,email,active)
values('SEU_SIAPE','Nome completo','nome@ifms.edu.br',true)
on conflict(siape) do update set
  full_name=excluded.full_name,email=excluded.email,active=true;

insert into public.profiles(id,siape,full_name,email,role,active)
select id,'SEU_SIAPE','Nome completo',lower(email),'admin',true
from auth.users where lower(email)='nome@ifms.edu.br'
on conflict(id) do update set role='admin',active=true;
```

Depois disso, o administrador pode criar setores, cadastrar a equipe e atribuir
um ou mais setores a cada técnico pela própria área interna.

## Edge Function

Implante a função que prepara os perfis internos. Ela gera uma credencial
aleatória não divulgada; o usuário sempre entra pelo Google:

```bash
supabase link --project-ref SEU_PROJECT_REF
supabase functions deploy create-staff --no-verify-jwt
```

A função aceita chamadas somente de um perfil `admin` ativo autenticado pelo
Google IFMS. Nunca exponha a chave `service_role` no site.

## Contas temporárias de homologação

Depois de criar as três identidades de teste no Supabase Auth, execute
`seeds/test-users.sql`. O seed cadastra os papéis de administrador, técnico de
Eletrotécnica e servidor solicitante, sem armazenar senhas no repositório.
