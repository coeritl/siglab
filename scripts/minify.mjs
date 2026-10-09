#!/usr/bin/env node
// Achado P2 3.3 da auditoria de 26/08/2026 (item de baixa prioridade,
// endereçado a pedido em 26/08/2026): gera versões minificadas de
// app.js, supabase-integration.js, reservations.js e styles.css para
// reduzir o payload servido pelo GitHub Pages.
//
// IMPORTANTE — por que só remove espaços/comentários (minifyWhitespace) e
// NÃO renomeia identificadores (minifyIdentifiers) nem aplica otimizações
// de sintaxe/constant-folding (minifySyntax):
//
// Este site não usa módulos nem bundler: app.js, supabase-integration.js e
// reservations.js são carregados como <script> soltos que compartilham o
// mesmo escopo global de propósito (ver banner no topo de app.js).
// `supabase-integration.js` depende de reatribuir, em tempo de execução,
// funções globais que `app.js` declarou primeiro (`renderTickets`,
// `renderDetail`, `supervisor`, `registration`, etc.) — é assim que o modo
// produção sobrescreve o modo demonstração. Minificar cada arquivo
// isoladamente com renomeação de identificadores quebraria esse
// acoplamento (cada arquivo poderia renomear o mesmo símbolo global de um
// jeito diferente). Constant-folding/otimizações de sintaxe também mexem
// com a árvore do código de formas mais sutis do que só espaços em branco.
// Por isso este script usa apenas `minifyWhitespace`, que não altera
// nenhum identificador nem a lógica — só remove espaços e comentários.
//
// Os arquivos originais continuam sendo a fonte editável (é neles que se
// deve programar); os `.min.` são gerados e commitados automaticamente
// pelo workflow .github/workflows/cache-bust.yml a cada push relevante.
//
// Uso local: node scripts/minify.mjs

import { readFileSync, writeFileSync, statSync } from 'node:fs';
import { transformSync } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { dirname, join, extname } from 'node:path';

const rootDir = join(dirname(fileURLToPath(import.meta.url)), '..');

const targets = [
  { src: 'app.js', out: 'app.min.js' },
  { src: 'supabase-integration.js', out: 'supabase-integration.min.js' },
  { src: 'reservations.js', out: 'reservations.min.js' },
  { src: 'styles.css', out: 'styles.min.css' },
];

let totalBefore = 0;
let totalAfter = 0;

for (const { src, out } of targets) {
  const srcPath = join(rootDir, src);
  const outPath = join(rootDir, out);
  const code = readFileSync(srcPath, 'utf8');
  const loader = extname(src) === '.css' ? 'css' : 'js';

  const result = transformSync(code, {
    loader,
    minifyWhitespace: true,
    minifyIdentifiers: false,
    minifySyntax: false,
  });

  writeFileSync(outPath, result.code);

  const before = statSync(srcPath).size;
  const after = statSync(outPath).size;
  totalBefore += before;
  totalAfter += after;
  console.log(`${src} -> ${out}: ${before} -> ${after} bytes (-${Math.round((1 - after / before) * 100)}%)`);
}

console.log(`Total: ${totalBefore} -> ${totalAfter} bytes (-${Math.round((1 - totalAfter / totalBefore) * 100)}%)`);
