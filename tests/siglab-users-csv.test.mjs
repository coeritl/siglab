import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const code=await readFile(new URL('../siglab-users-csv.js',import.meta.url),'utf8'),window={};
vm.runInNewContext(code,{window});
const {parse,validate}=window.siglabUsersCsv;
const header='nome;email;siape;perfil;setores;ativo\r\n';
const data={sectors:[{id:'s1',slug:'eletrotecnica',active:true,reservation_mode:'internal'},{id:'s2',slug:'fisica',active:false,reservation_mode:'internal'}],users:[{email:'existente@ifms.edu.br',siape:'77777'}]};
test('lê BOM, ponto e vírgula, aspas escapadas e zeros iniciais',()=>{
  const rows=validate('\uFEFF'+header+'"Maria; ""Silva""";maria@ifms.edu.br;0012345;servidor;;sim',data);
  assert.equal(rows[0].args.p_name,'Maria; "Silva"');assert.equal(rows[0].args.p_siape,'0012345');assert.equal(rows[0].errors.length,0);
});
test('lê vírgula e nome com quebra de linha entre aspas',()=>{
  const rows=parse('nome,email,siape,perfil,setores,ativo\n"Maria\nSilva",m@ifms.edu.br,12345,servidor,,sim');
  assert.equal(rows.length,1);assert.equal(rows[0].fields.nome,'Maria\nSilva');
});
test('valida domínio, SIAPE, perfil, situação e setor do gestor',()=>{
  for(const csv of ['Maria;m@gmail.com;12345;servidor;;sim','Maria;m@ifms.edu.br;;servidor;;sim','Maria;m@ifms.edu.br;12345;admin;;sim','Maria;m@ifms.edu.br;12345;gestor;fisica;sim','Maria;m@ifms.edu.br;12345;servidor;;talvez'])assert.ok(validate(header+csv,data)[0].errors.length);
  assert.equal(validate(header+'Maria;m@ifms.edu.br;12345;gestor;eletrotecnica;nao',data)[0].errors.length,0);
});
test('detecta duplicatas e não permite importar a própria conta',()=>{
  const rows=validate(header+'Maria;m@ifms.edu.br;12345;servidor;;sim\nMaria;m@ifms.edu.br;12345;servidor;;sim',data,'m@ifms.edu.br');
  assert.ok(rows[0].errors.some(e=>e.includes('própria conta')));assert.ok(rows[1].errors.some(e=>e.includes('duplicado')));
});
test('rejeita cabeçalho incorreto, aspas abertas e excesso de linhas',()=>{
  assert.throws(()=>parse('nome;email\nA;a@ifms.edu.br'),/ausente/);
  assert.throws(()=>parse(header+'"aberto'),/aspas/);
  assert.throws(()=>parse(header+Array(501).fill('Maria;m@ifms.edu.br;12345;servidor;;sim').join('\n')),/500/);
});
test('marca contas existentes e conflito de SIAPE antes de gravar',()=>{
  assert.ok(validate(header+'Maria;existente@ifms.edu.br;77777;servidor;;sim',data)[0].existing);
  assert.ok(validate(header+'Maria;outra@ifms.edu.br;77777;servidor;;sim',data)[0].errors.some(e=>e.includes('outra conta')));
});
test('confirma importação na própria página e chama a RPC sem janela nativa',async()=>{
  const nodes=new Map();
  const node=id=>{if(!nodes.has(id))nodes.set(id,{disabled:false,hidden:true,checked:false,files:[],insertAdjacentHTML(){},scrollIntoView(){}});return nodes.get(id)};
  const target={insertAdjacentHTML(){},querySelector:node};let calls=[];
  const browserWindow={siglabAuth:{getState:()=>({session:{user:{email:'master@ifms.edu.br'}}})},siglabDb:{rpc:async(name,args)=>{calls.push({name,args});return {error:null}}}};
  vm.runInNewContext(code,{window:browserWindow,document:{querySelectorAll:()=>[...nodes.values()]}});
  browserWindow.siglabUsersCsv.mount(target,data,()=>{});
  node('#usersCsvFile').files=[{size:100,text:async()=>header+'Maria;maria@ifms.edu.br;0012345;servidor;;sim'}];
  await node('#usersCsvFile').onchange();
  node('#importUsersCsv').onclick();
  assert.equal(node('#usersCsvConfirmation').hidden,false);
  assert.equal(calls.length,0);
  await node('#executeUsersCsv').onclick();
  assert.equal(calls.length,1);
  assert.equal(calls[0].name,'master_save_access');
  assert.match(node('#usersCsvProgress').textContent,/1 salvo\(s\), 0 falha/);
});
