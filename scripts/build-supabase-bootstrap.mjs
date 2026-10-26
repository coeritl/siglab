import { readdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const migrationDir = join(root, 'supabase', 'migrations');
const migrationNames = (await readdir(migrationDir))
  .filter((name) => name.endsWith('.sql'))
  .sort((a, b) => a.localeCompare(b));

const sources = [
  ['schema.sql', await readFile(join(root, 'supabase', 'schema.sql'), 'utf8')],
  ...(await Promise.all(
    migrationNames.map(async (name) => [
      `migrations/${name}`,
      await readFile(join(migrationDir, name), 'utf8'),
    ]),
  )),
];

const prelude = `-- SIGLAB — instalação inicial consolidada\n-- Gerado automaticamente; execute somente em um projeto Supabase novo.\n-- Projeto esperado: keesciertyonbfqlrqwt\n\n`;
const body = sources
  .map(([name, source]) => `-- -----------------------------------------------------------------------------\n-- ${name}\n-- -----------------------------------------------------------------------------\n${source.trim()}\n`)
  .join('\n');

await writeFile(join(root, 'supabase', 'bootstrap.generated.sql'), prelude + body, 'utf8');
console.log(`Bootstrap gerado com ${sources.length} etapas.`);
