/* Sessão Google institucional única do projeto SIGLAB. */
(() => {
  const cfg=window.SIGLAB_SUPABASE||{},base=location.hostname.endsWith('.github.io')?'/siglab':'',root=base+'/',key='siglab_oauth_return';
  const stores=()=>[sessionStorage,localStorage];
  const normalize=value=>{try{const u=new URL(value||root,location.origin);return u.origin===location.origin&&(!base||u.pathname.startsWith(root))?u.pathname+u.search:root}catch{return root}};
  const state={session:null,identity:null,staff:null,error:null,ready:false};
  const sb=cfg.url&&cfg.anonKey&&window.supabase?window.supabase.createClient(cfg.url,cfg.anonKey):null;
  window.siglabDb=sb;window.labinfoDb=sb;
  let pending='',refreshing;
  for(const storage of stores())try{const saved=JSON.parse(storage.getItem(key)||'null');if(saved&&Date.now()-saved.at>=0&&Date.now()-saved.at<1800000)pending=normalize(saved.path)}catch{}
  const clear=()=>{for(const storage of stores())try{storage.removeItem(key)}catch{}};
  const emit=()=>window.dispatchEvent(new CustomEvent('siglab:auth',{detail:{...state}}));
  async function refresh(){
    if(refreshing)return refreshing;
    refreshing=(async()=>{
      state.identity=null;state.staff=null;state.error=null;
      if(sb){
        const {data,error}=await sb.auth.getSession();state.session=data?.session||null;if(error)state.error=error.message;
        if(state.session){
          const user=state.session.user,providers=user.app_metadata?.providers||[user.app_metadata?.provider];
          if(!providers.includes('google')||!String(user.email).toLowerCase().endsWith('@ifms.edu.br')){
            state.error='Use sua conta Google institucional @ifms.edu.br.';await sb.auth.signOut();state.session=null;
          }else{
            const [identity,staff]=await Promise.all([sb.rpc('get_my_ifms_identity'),sb.rpc('get_my_staff_profile')]);
            state.identity=identity.data?.[0]||null;state.staff=state.identity?staff.data?.[0]||null:null;
            if(!state.identity)state.error=identity.error?.message||'Conta sem vínculo com servidor ativo no SIGLAB.';
          }
        }
      }
      state.ready=true;
      if(pending&&state.session){history.replaceState({},'',pending);pending='';clear()}
      else if(state.session){const u=new URL(location.href);for(const p of ['code','auth_refresh'])u.searchParams.delete(p);if(/access_token|refresh_token/.test(u.hash))u.hash='';history.replaceState({},'',u.pathname+u.search)}
      emit();return {...state};
    })().finally(()=>{refreshing=null});return refreshing;
  }
  async function signIn(path=location.pathname+location.search){
    if(!sb)throw new Error('Login institucional indisponível.');
    const requested=new URL(normalize(path),location.origin);
    for(const storage of stores())try{storage.setItem(key,JSON.stringify({path:requested.pathname+requested.search,at:Date.now()}))}catch{}
    const callback=new URL(root,location.origin);requested.searchParams.forEach((v,k)=>callback.searchParams.set(k,v));
    const route=requested.pathname.slice(base.length).replace(/^\/+|\/+$/g,'');if(route)callback.searchParams.set('route',route);callback.searchParams.set('auth_refresh',String(Date.now()));
    const {error}=await sb.auth.signInWithOAuth({provider:'google',options:{redirectTo:callback.href,queryParams:{hd:'ifms.edu.br',prompt:'select_account'}}});
    if(error){clear();throw error}
  }
  async function signOut(){if(sb)await sb.auth.signOut();clear();await refresh()}
  window.siglabAuth={signIn,signOut,refresh,getState:()=>({...state})};
  if(sb)sb.auth.onAuthStateChange(()=>setTimeout(()=>refresh().catch(e=>{state.error=e.message;emit()}),0));
  window.siglabAuthReady=refresh();
})();
