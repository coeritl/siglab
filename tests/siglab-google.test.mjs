import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
const source=await readFile(new URL('../siglab-auth.js',import.meta.url),'utf8');
async function boot(user,stored=null,noServer=false){
  const values=new Map(stored?[['siglab_oauth_return',JSON.stringify(stored)]]:[]);
  const storage={getItem:k=>values.get(k),setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};
  const calls=[],urls=[];
  const session=user?{user}:null;
  const client={auth:{getSession:async()=>({data:{session}}),signOut:async()=>calls.push('signOut'),onAuthStateChange:()=>{},signInWithOAuth:async args=>{calls.push(args);return {}}},rpc:async name=>{calls.push(name);if(noServer&&name==='get_my_ifms_identity')return {data:null,error:{message:'Sem servidor'}};return {data:[name==='get_my_ifms_identity'?{id:'server',siape:'123',full_name:'Servidor'}:{id:'staff',role:noServer?'admin':'tecnico',is_admin:noServer}]}}};
  const window={SIGLAB_SUPABASE:{url:'https://siglab.supabase.co',anonKey:'public'},supabase:{createClient:()=>client},dispatchEvent:()=>{}};
  vm.runInNewContext(source,{window,location:{hostname:'laboratorios.tl.ifms.edu.br',origin:'https://laboratorios.tl.ifms.edu.br',pathname:'/reservas/',search:'?grupo=eletrotecnica',href:'https://laboratorios.tl.ifms.edu.br/reservas/?grupo=eletrotecnica'},history:{replaceState:(_a,_b,url)=>urls.push(url)},sessionStorage:storage,localStorage:storage,URL,CustomEvent:class{},setTimeout,console});
  await window.siglabAuthReady;
  return {window,calls,urls};
}
test('Google IFMS obtém identidade e perfil pelo banco',async()=>{
  const {window,calls}=await boot({email:'professor@ifms.edu.br',app_metadata:{provider:'google'}});
  assert.ok(window.siglabAuth.getState().identity);
  assert.ok(calls.includes('get_my_ifms_identity'));
  assert.ok(calls.includes('get_my_staff_profile'));
});
test('master institucional sem SIAPE recebe administração mas não identidade para reservar',async()=>{
  const {window}=await boot({email:'siglab.tl@ifms.edu.br',app_metadata:{provider:'google'}},null,true);
  const state=window.siglabAuth.getState();
  assert.equal(state.identity,null);assert.equal(state.staff.is_admin,true);assert.equal(state.error,null);
});
test('conta pessoal ou antiga senha não recebe identidade institucional',async()=>{
  for(const user of [{email:'p@gmail.com',app_metadata:{provider:'google'}},{email:'p@ifms.edu.br',app_metadata:{provider:'email'}}]){
    const {window,calls}=await boot(user);
    assert.equal(window.siglabAuth.getState().identity,null);
    assert.ok(calls.includes('signOut'));
    assert.ok(!calls.includes('get_my_ifms_identity'));
  }
});
test('OAuth retorna pela raiz preservando rota e grupo, sem redirecionamento externo',async()=>{
  const {window,calls}=await boot(null);
  await window.siglabAuth.signIn('/reservas/?grupo=eletrotecnica');
  const request=calls.find(x=>x.provider==='google'),url=new URL(request.options.redirectTo);
  assert.equal(url.pathname,'/');assert.equal(url.searchParams.get('route'),'reservas');assert.equal(url.searchParams.get('grupo'),'eletrotecnica');
  await window.siglabAuth.signIn('https://evil.example/');
  assert.equal(new URL(calls.at(-1).options.redirectTo).origin,'https://laboratorios.tl.ifms.edu.br');
});
test('retorno salvo restaura a agenda após criar a sessão',async()=>{
  const {urls}=await boot({email:'p@ifms.edu.br',app_metadata:{provider:'google'}},{path:'/reservas/?grupo=diversos',at:Date.now()});
  assert.ok(urls.includes('/reservas/?grupo=diversos'));
});
