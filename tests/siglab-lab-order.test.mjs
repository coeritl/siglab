import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const context={window:{},Intl};
vm.runInNewContext(fs.readFileSync(new URL('../siglab-lab-order.js',import.meta.url),'utf8'),context);
test('ordena espaços por números sem modificar cadastros',()=>{
  const labs=[{id:'10',name:'LAB 10 - CAD'},{id:'2',name:'LAB 2 - Elétrica'},{id:'11',name:'LAB 11 - Mecânica'},{id:'1',name:'LAB 1 - Automação'}];
  assert.deepEqual(Array.from(context.window.siglabOrderLabs(labs),r=>r.id),['1','2','10','11']);
  assert.equal(labs[0].id,'10');
});
test('aceita lista vazia e nomes com zeros iniciais',()=>{
  assert.equal(context.window.siglabOrderLabs(null).length,0);
  assert.deepEqual(Array.from(context.window.siglabOrderLabs([{name:'Laboratório 10'},{name:'Laboratório 02'}]),r=>r.name),['Laboratório 02','Laboratório 10']);
});
