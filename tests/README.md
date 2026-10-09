# Testes

Suíte básica adicionada no achado P2 3.4 da auditoria de 26/08/2026. Não
requer nenhuma dependência (usa apenas `node:test`, nativo do Node.js 18+) e
não precisa de acesso a um banco Supabase real.

Rodar localmente:

```bash
npm test
```

O que é coberto hoje:

- `escaping.test.mjs` — testa os helpers `esc()` (app.js) e `safe()`
  (supabase-integration.js) usados para evitar XSS persistente ao exibir
  título/descrição de chamados, reservas e mensagens de chat. Lê o código
  real dos arquivos (não uma cópia), então uma edição futura que enfraqueça
  o escape quebra o teste.
- `sql-security-invariants.test.mjs` — simula, a partir do texto de
  `supabase/schema.sql` + `supabase/migrations/*.sql` (na mesma ordem
  cronológica em que são aplicados), o estado final de GRANT/REVOKE de
  funções sensíveis e de policies de RLS em `chat_sessions`/`chat_messages`.
  Funciona como um "regression test" dos três achados críticos corrigidos em
  26/08/2026 — por exemplo, ele falha se uma futura migration voltar a
  conceder `create_ticket_from_chat` para o role `anon`, ou se uma policy
  `using (true)` aberta ao público voltar a existir nessas tabelas.

Limitações conhecidas: isto é análise estática do texto das migrations, não
um teste de integração contra um Postgres real. Ele não substitui testar
manualmente (ou em um projeto Supabase de homologação) depois de aplicar
migrations novas — mas pega de forma rápida e sem custo os erros mais
parecidos com os que já causaram os 3 achados críticos anteriores.

Para adicionar um teste novo, crie outro arquivo `tests/*.test.mjs` — o
script `npm test` (`node --test tests/*.test.mjs`) já pega automaticamente
qualquer arquivo com esse padrão de nome.
