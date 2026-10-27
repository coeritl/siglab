import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = file => readFile(new URL(`../${file}`, import.meta.url), 'utf8');

test('espaços do SIGLAB não exibem especificações exclusivas de informática', async () => {
  const [app, reservations] = await Promise.all([read('siglab-app.js'), read('reservations.js')]);
  assert.doesNotMatch(app, /name="computer_count"|name="operating_system"|computador\(es\)/);
  const cards = reservations.slice(reservations.indexOf('function renderPublicLabCards'), reservations.indexOf('async function loadPublicLabs'));
  assert.doesNotMatch(cards, /computer_count|operating_system|lab-spec-pc|lab-spec-os/);
});

test('a página publicada carrega apenas a aplicação SIGLAB e o módulo de reservas', async () => {
  const html = await read('index.html');
  assert.match(html, /src="siglab-app\.js(?:\?v=[^"]+)?"/);
  assert.match(html, /src="reservations\.js(?:\?v=[^"]+)?"/);
  assert.doesNotMatch(html, /src="app\.js"/);
  assert.doesNotMatch(html, /src="supabase-integration\.js"/);
  assert.doesNotMatch(html, /id="chatPublicView"|id="ticketForm"|Fila de atendimento/);
});

test('a página inicial separa Informática, Eletrotécnica e laboratórios diversos', async () => {
  const [html, reservations] = await Promise.all([read('index.html'), read('reservations.js')]);
  assert.match(html, /id="openReservations"/);
  assert.match(html, /href="https:\/\/labinfo\.tl\.ifms\.edu\.br\/reservas\/"/);
  assert.match(html, /Laboratórios de<\/span> Informática/);
  assert.match(html, /data-reservation-group="eletrotecnica"/);
  assert.match(html, /Laboratórios de<\/span> Eletrotécnica/);
  assert.match(html, /data-reservation-group="diversos"/);
  assert.match(html, /Demais<\/span> laboratórios/);
  assert.match(reservations, /publicLabMatchesGroup/);
  assert.match(reservations, /sectors\(name,slug,reservation_mode\)/);
});

test('a identidade visual usa a marca Laboratórios TL fornecida', async () => {
  const [html, logo] = await Promise.all([read('index.html'), read('assets/laboratorios-logo.png')]);
  assert.match(html, /assets\/laboratorios-logo\.png/);
  assert.doesNotMatch(html, /class="siglab-wordmark"|class="siglab-home-wordmark"/);
  assert.ok(logo.length > 1000);
});

test('as rotas do GitHub Pages usam a base independente /siglab', async () => {
  const [app, reservations, notFound] = await Promise.all([
    read('siglab-app.js'),
    read('reservations.js'),
    read('404.html')
  ]);
  assert.match(app, /\?\s*'\/siglab'\s*:\s*''/);
  assert.match(reservations, /\?\s*'\/siglab'\s*:\s*''/);
  assert.match(notFound, /\?\s*'\/siglab'\s*:\s*''/);
  assert.doesNotMatch(`${app}\n${reservations}\n${notFound}`, /\?\s*'\/labinfo'\s*:\s*''/);
});

test('a configuração publicada aponta somente para o Supabase exclusivo do SIGLAB', async () => {
  const config = await read('supabase-config.js');
  assert.match(config, /window\.SIGLAB_SUPABASE/);
  assert.match(config, /keesciertyonbfqlrqwt\.supabase\.co/);
  assert.match(config, /sb_publishable_m5L9IkzHlYIuwsbcwJ80Hg_B_4QGGXz/);
  assert.doesNotMatch(config, /jvoeaqiusjivyofbyzvi/);
});
