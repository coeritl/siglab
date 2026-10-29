# Ativar Google IFMS no SIGLAB

Esta configuração é exclusiva do projeto `keesciertyonbfqlrqwt`. Não executar SQL no projeto LabInfo.

1. Google Cloud → Google Auth Platform → Clientes → cliente Web existente: acrescentar a origem `https://laboratorios.tl.ifms.edu.br` e o redirecionamento `https://keesciertyonbfqlrqwt.supabase.co/auth/v1/callback`. Preservar todas as URLs atuais do LabInfo.
2. Supabase SIGLAB → Authentication → Sign In / Providers → Google: habilitar, preencher Client ID e Client Secret do cliente Web. Manter verificações de nonce ativas e não permitir usuários sem e-mail. Nunca publicar o segredo.
3. Authentication → URL Configuration: Site URL `https://laboratorios.tl.ifms.edu.br`; Redirect URLs `https://laboratorios.tl.ifms.edu.br/` (incluindo URLs com query string; usar `https://laboratorios.tl.ifms.edu.br/**` se necessário conforme o padrão de URLs do painel).
4. SQL Editor SIGLAB: executar `supabase/migrations/20261029_siglab_google_production.sql`, após o bootstrap multi-setor já instalado. Ela encerra a exceção temporária por senha e identifica pedidos de cancelamento pela sessão.
5. Conferir cadastros ativos em `servers` e perfis internos/setores. Conta Google sem servidor ativo não pode reservar; servidor não recebe acesso administrativo automaticamente.
6. Publicar o código e testar com servidor ativo, técnico com setor, conta pessoal, conta IFMS não cadastrada, saída da sessão e retorno OAuth em celular/desktop. Confirmar reserva, listagem e cancelamento sem acessar reservas de outra conta.

O frontend já prepara o retorno pela raiz física do Pages, persistindo a rota em sessão/localStorage por até 30 minutos. A URL original e o grupo de laboratórios são restaurados após a sessão estar disponível.
