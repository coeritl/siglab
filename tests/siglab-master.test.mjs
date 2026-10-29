import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const sql=await readFile(new URL('../supabase/migrations/20261029_siglab_master_panel.sql',import.meta.url),'utf8');
const ui=await readFile(new URL('../siglab-master.js',import.meta.url),'utf8');
test('bootstrap concede primeiro master somente ao endereço autorizado',()=>{
  assert.match(sql,/values\('siglab\.tl@ifms\.edu\.br','Administração SIGLAB','master'\)/);
  assert.match(sql,/public\.jwt_uses_google_ifms\(\)/);
  assert.match(sql,/a\.email=lower\(btrim\(auth\.jwt\(\)->>'email'\)\)/);
});
test('todas as operações master exigem autorização no banco',()=>{
  for(const name of ['master_dashboard','master_save_access','master_save_sector']){
    const body=sql.slice(sql.indexOf(`function public.${name}(`));
    assert.match(body.slice(0,650),/if not public\.is_siglab_admin\(\) then raise exception/);
  }
  assert.match(sql,/revoke all on public\.siglab_access,public\.siglab_admin_audit from anon,authenticated/);
  assert.match(sql,/revoke insert,update,delete on public\.profiles,public\.profile_sectors,public\.sectors,public\.servers from authenticated/);
});
test('último master é preservado com serialização de alterações de perfil',()=>{
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/Não é permitido remover o último master ativo/);
  assert.match(sql,/a\.active and a\.access_role='master' and a\.email<>mail/);
});
test('auditoria guarda valores anteriores e novos e e-mails de setor não são públicos',()=>{
  assert.match(sql,/before_data jsonb, after_data jsonb/);
  assert.match(sql,/create trigger siglab_access_audit/);
  assert.match(sql,/create trigger siglab_sector_audit/);
  assert.match(sql,/revoke select on public\.sectors from anon,authenticated/);
});
test('painel usa RPCs e oferece setores, perfis e auditoria',()=>{
  for(const name of ['master_dashboard','master_save_access','master_save_sector'])assert.ok(ui.includes(name));
  assert.doesNotMatch(ui,/\.from\(['"](?:profiles|siglab_access|sectors)['"]\)\.(?:insert|update|delete)/);
  assert.match(ui,/staff\?\.is_admin===true/);
});
