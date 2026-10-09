# SIGLAB — Sistema Integrado de Gestão de Laboratórios

Projeto independente para gestão e reserva dos laboratórios do IFMS Campus
Três Lagoas, destinado ao domínio `laboratorios.tl.ifms.edu.br`.

## Estado desta cópia

- criado a partir de uma cópia somente-leitura do LabInfo;
- possui histórico Git próprio e não publica no repositório do LabInfo;
- não contém configuração ativa do Supabase de produção;
- o domínio e a publicação no GitHub Pages só devem ser ativados após a
  extração do módulo de reservas e a homologação;
- referências a chamados, chat e à identidade LabInfo ainda são legado da
  base original e serão removidas na etapa de extração.

> Segurança: nunca inserir neste projeto chaves, segredos ou URLs privadas do
> Supabase e do Apps Script usados pelo LabInfo em produção.

## Base de origem

O código inicial foi derivado do sistema LabInfo apenas para reaproveitar o
módulo de reservas já homologado. O projeto SIGLAB evolui em repositório,
banco de dados, implantação de e-mail e domínio separados.

## Documentação legada da base original

Interface responsiva para abertura e gerenciamento de chamados dos Laboratórios de Informática do IFMS Campus Três Lagoas.

## Protótipo atual

- formulário servidor com validação de e-mail institucional;
- categorias e laboratórios;
- consulta por protocolo;
- painel técnico responsivo;
- indicadores, filtros, atribuição e resposta;
- dados demonstrativos para validação da experiência.

## Próxima etapa

Conectar a interface a um Google Apps Script para persistência em Planilhas Google, validação do cadastro servidor e envio de notificações por e-mail.

## Publicação

O site é estático e pode ser publicado diretamente pelo GitHub Pages a partir da raiz da branch `main`.

`.github/workflows/cache-bust.yml` roda automaticamente sempre que `styles.css`, `app.js`, `supabase-integration.js` ou `reservations.js` mudam em um push para `main` e faz duas coisas, nessa ordem:

1. Gera `app.min.js`, `supabase-integration.min.js`, `reservations.min.js` e `styles.min.css` (`scripts/minify.mjs`) — é isso que `index.html` referencia em produção. Só remove espaços/comentários (nenhum identificador é renomeado, de propósito — o motivo está comentado no topo do script: os três arquivos JS compartilham escopo global entre si e renomear quebraria esse acoplamento).
2. Atualiza o `?v=...` (hash do conteúdo) de cada arquivo em `index.html` (`scripts/bump-cache-version.mjs`).

Desenvolvimento continua sendo feito editando os arquivos-fonte normalmente (`app.js`, `supabase-integration.js`, `reservations.js`, `styles.css`); os `.min.` nunca são editados à mão. Para rodar o mesmo processo localmente antes de um deploy manual: `npm install` (só na primeira vez, baixa o `esbuild` usado para minificar) e depois `npm run build`.

## Testes

Há uma suíte básica de testes automatizados (sem dependências, usa `node:test`) em `tests/` — cobre os helpers de escape contra XSS e simula as permissões finais das migrations do Supabase para pegar cedo uma regressão parecida com os achados críticos já corrigidos. Rode com `npm test`. Roda automaticamente em cada push/PR (`.github/workflows/tests.yml`). Detalhes em `tests/README.md`.

## Riscos operacionais e continuidade (achado P1 2.2 da auditoria de 26/08/2026)

O sistema depende de dois serviços de terceiros no plano gratuito/individual, o que traz riscos de continuidade que a equipe deve conhecer e mitigar administrativamente (nenhum deles se resolve só com código):

### Supabase — plano gratuito

- Projetos gratuitos do Supabase entram em pausa automática após um período sem nenhuma requisição (histórico do produto: cerca de 7 dias consecutivos de inatividade). Um projeto pausado deixa o site, a abertura de chamados e o Apps Script fora do ar até alguém reativá-lo manualmente pelo painel do Supabase.
- **Confirmado em 26/08/2026:** o projeto está no plano gratuito e não tinha nenhum mecanismo anti-pausa próprio (só dependia, incidentalmente, do Apps Script chamar o banco a cada 1–10 minutos — o que por si só já mantinha o projeto ativo, mas ficava exposto ao mesmo ponto único de falha da conta do Google descrito abaixo).
- **Mitigação implementada:** `.github/workflows/keep-supabase-awake.yml` roda uma vez por dia e faz uma única leitura pública sem efeitos colaterais (a mesma consulta de laboratórios que o próprio site público já faz) só para manter o projeto com atividade recente. Roda inteiramente na infraestrutura do GitHub Actions, então continua funcionando mesmo que o Apps Script pare por causa de um problema com a conta do Google — os dois pontos únicos de falha deixam de estar acoplados.
- Recomendações que continuam valendo (a automação acima reduz o risco de pausa por inatividade, mas não substitui):
  - Cadastrar um lembrete recorrente (ex.: mensal) para verificar no painel do Supabase se o projeto segue ativo e dentro dos limites gratuitos de banco de dados, armazenamento e requisições.
  - Considerar migrar para um plano pago caso o uso real (chamados, reservas, anexos) se aproxime dos limites do plano gratuito — o painel do Supabase mostra o consumo atual.
  - Manter um backup periódico do banco (o Supabase permite exportar via `pg_dump`/painel) para o caso de perda de acesso ao projeto gratuito.

### Google Apps Script — conta única (bus factor)

- Toda a integração de e-mail (recebimento de chamados por e-mail, fila de notificações, confirmações de reserva) roda como um script vinculado a uma única conta Google (`labinfo.tl@ifms.edu.br`), com segredos guardados nas Propriedades do Script daquela conta.
- Isso é um ponto único de falha organizacional: se a pessoa responsável perder acesso à conta, sair da instituição sem repassar as credenciais, ou a conta for suspensa/bloqueada pelo Google, a integração de e-mail para completamente e ninguém mais consegue reimplantar o script sem recriar as propriedades (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `INTEGRATION_SECRET`) do zero.
- Recomendações:
  - Garantir que a conta `labinfo.tl@ifms.edu.br` seja uma conta institucional (Google Workspace do IFMS), não uma conta pessoal, e que pelo menos duas pessoas da equipe técnica (ex.: o supervisor e um segundo técnico) tenham as credenciais de acesso, ou que a conta tenha um método de recuperação institucional administrado por mais de uma pessoa.
  - Guardar uma cópia segura (ex.: gerenciador de senhas da equipe, nunca em texto puro em chat ou planilha aberta) dos três valores de `SUPABASE_ANON_KEY`/`SUPABASE_URL`/`INTEGRATION_SECRET`, para permitir reimplantar o `Code.gs` em outra conta rapidamente se necessário.
  - Documentar, neste repositório ou em local acessível à equipe, o passo a passo de `google-apps-script/README.md` como runbook de recuperação.

## Storage — upload público vinculado a chamado existente (achado adicional, verificação ao vivo em 26/08/2026)

Durante uma verificação manual do painel do Supabase (fora do escopo da auditoria estática original, que não tinha inspecionado policies de Storage), encontramos que a policy `storage_public_upload` do bucket `ticket-attachments` só exigia que o caminho começasse com `tickets/`, sem checar se havia um chamado real por trás. O bucket já é privado e já tinha limite de 5 MB e tipos MIME restritos a imagens (`image/jpeg`, `image/png`, `image/webp`), então o dano possível já era limitado — mas, como a `anon key` é pública, ainda era possível enviar um número ilimitado de imagens para caminhos arbitrários, nunca vinculadas a nenhum chamado, consumindo a cota de armazenamento do plano gratuito sem nenhum rate limit.

**Mitigação implementada:** `supabase/migrations/20260828_scope_storage_uploads_to_existing_tickets.sql` aperta a policy para exigir que o segundo segmento do caminho corresponda ao `id` de um chamado que já existe — o mesmo formato que o próprio site já usa. Coberto por um teste em `tests/sql-security-invariants.test.mjs`.
