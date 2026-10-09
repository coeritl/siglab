#!/usr/bin/env node
// Achado P2 3.3 da auditoria de 26/08/2026: o site é estático (sem build
// step, propositalmente — ver README) e até aqui o cache-busting da query
// string `?v=` em index.html era feito à mão a cada deploy, o que é fácil de
// esquecer (o navegador do usuário fica servindo a versão antiga do
// JS/CSS em cache até o `?v=` mudar).
//
// Este script substitui isso por uma versão baseada no conteúdo: calcula um
// hash sha256 (10 caracteres) de cada arquivo local referenciado em
// index.html e reescreve a query string `?v=...` correspondente. Rodar de
// novo sem nenhum arquivo ter mudado não altera nada (idempotente).
//
// Uso local, antes de um deploy manual:
//   node scripts/bump-cache-version.mjs
//
// Também roda automaticamente no GitHub Actions a cada push em main que
// altere um dos arquivos referenciados (ver .github/workflows/cache-bust.yml),
// então normalmente não é preciso rodar isto manualmente.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const rootDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const indexPath = join(rootDir, 'index.html');

function hashFile(relativePath) {
  const absolutePath = join(rootDir, relativePath);
  if (!existsSync(absolutePath)) {
    throw new Error(`Arquivo referenciado em index.html não encontrado: ${relativePath}`);
  }
  const content = readFileSync(absolutePath);
  return createHash('sha256').update(content).digest('hex').slice(0, 10);
}

function bump() {
  let html = readFileSync(indexPath, 'utf8');
  let changedCount = 0;

  // Casa src="arquivo.js?v=..." e href="arquivo.css?v=..." apenas para
  // arquivos locais (sem "://", ou seja, não mexe em CDNs externos).
  const pattern = /((?:src|href)=")([^":?]+\.(?:js|css))(?:\?v=[^"]*)?(")/g;

  html = html.replace(pattern, (match, prefix, relativePath, suffix) => {
    if (relativePath.includes('://')) return match;
    const hash = hashFile(relativePath);
    const replacement = `${prefix}${relativePath}?v=${hash}${suffix}`;
    if (replacement !== match) changedCount++;
    return replacement;
  });

  writeFileSync(indexPath, html);
  return changedCount;
}

const changed = bump();
if (changed > 0) {
  console.log(`bump-cache-version: ${changed} referência(s) de cache atualizada(s) em index.html.`);
  process.exitCode = 0;
} else {
  console.log('bump-cache-version: nenhuma mudança necessária (index.html já está com os hashes atuais).');
}
