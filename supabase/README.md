# Configuração do Supabase

1. Crie um projeto gratuito no Supabase.
2. Abra **SQL Editor**, cole todo o conteúdo de `schema.sql` e execute.
3. Execute, em ordem cronológica pelo nome do arquivo, todos os scripts da pasta `migrations/`. Em uma instalação já existente, execute somente os que ainda não foram aplicados. A migração `20260817_completion_confirmation_email.sql` é necessária para incluir a solução e o link de confirmação no e-mail de conclusão.
4. Em **Authentication → Users**, crie os usuários dos técnicos e supervisores com e-mail e senha.
5. No SQL Editor, execute o `insert into public.profiles...` indicado no fim do arquivo para cada usuário.
6. Copie `config.example.js` para `supabase-config.js` na raiz do site e preencha a URL e a chave pública do projeto.
7. Para permitir que um técnico crie novos logins pelo painel, instale o Supabase CLI e execute:

```bash
supabase link --project-ref SEU_PROJECT_REF
supabase functions deploy create-staff --no-verify-jwt
```

O próprio código da função valida o JWT e confirma que o solicitante possui perfil `tecnico` ativo. Técnicos e supervisores entram com e-mail e senha; apenas técnicos veem operações de alteração.

Nunca coloque a chave `service_role` no GitHub Pages. A chave pública/publishable é a única apropriada para o navegador; a segurança é aplicada pelas políticas RLS.
