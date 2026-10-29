# Administração geral SIGLAB

Executar **somente** no SQL Editor do projeto `keesciertyonbfqlrqwt`:
`supabase/migrations/20261029_siglab_master_panel.sql`.

Pré-requisitos: bootstrap multi-setor e migration do login Google. A operação é transacional; não altera usuários, credenciais ou configurações no LabInfo.

O primeiro master é `siglab.tl@ifms.edu.br`. O acesso é vinculado ao e-mail autenticado pelo Google e ao registro ativo no banco, não a um endereço informado pelo navegador. Nenhuma conta Google ou senha é criada. Faça logout/login após executar o SQL.

## Operações

- Setores: nome, identificador, e-mail institucional de contato/notificação e situação. O endereço é cadastrado; este painel não implementa novos disparos de e-mail.
- Usuários: nome, e-mail, SIAPE, perfil e setores do gestor. Cadastro pode preceder o primeiro login; o perfil interno é provisionado pela RPC no primeiro acesso Google autorizado.
- Master: administração global; pode não ter SIAPE. Sem vínculo em servidores ativos, não recebe identidade para criar reservas pessoais.
- Gestor: exige SIAPE e ao menos um setor interno ativo; gerencia apenas os espaços desses setores.
- Servidor: exige SIAPE; próprias reservas. Cadastros já existentes em servidores continuam podendo reservar; não viram gestores automaticamente.
- Auditoria: exibe 50 registros recentes; valores anteriores/novos preservados no banco. Não há exclusão pelo navegador.

A migration bloqueia escrita direta nos cadastros de acesso/perfis/setores/servidores e desativa RPCs antigas de atribuição não auditada. O formulário antigo de Servidores não é usado; a administração central é feita em Usuários e perfis. Laboratórios continuam sendo cadastrados no menu Laboratórios e vinculados ao setor responsável.

## Validação após executar

1. Login Google com `siglab.tl@ifms.edu.br`: Administração geral deve abrir sem SIAPE fictício.
2. Cadastrar setor e gestor de teste autorizado com SIAPE real; validar os limites de setor.
3. Conta servidor não acessa RPC master nem reservas de outros usuários.
4. Tentar desativar/rebaixar o único master: banco deve rejeitar.
5. Verificar auditoria após edição e saída/retorno da sessão.

Não compartilhar credenciais nem colocar chaves secretas no código.
