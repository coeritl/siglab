(function(){
  const cfg=window.SIGLAB_SUPABASE||window.LABINFO_SUPABASE||{};
  if(!cfg.url||!cfg.anonKey||!window.supabase)return;

  const siteBase=location.hostname.endsWith('.github.io')?'/siglab':'';
  const sitePath=route=>`${siteBase}/${route?String(route).replace(/^\/+|\/+$/g,'')+'/':''}`;
  const returnKey='siglab_oauth_return_path';
  const maxAge=30*60*1000;
  const stores=()=>[sessionStorage,localStorage];
  const normalize=value=>{
    try{
      const url=new URL(value||sitePath(''),location.origin);
      return url.origin===location.origin?url.pathname+url.search:sitePath('');
    }catch{return sitePath('')}
  };
  const saveReturn=path=>{
    const value=JSON.stringify({path:normalize(path),createdAt:Date.now()});
    stores().forEach(storage=>{try{storage.setItem(returnKey,value)}catch{}});
  };
  const readReturn=()=>{
    let newest=null;
    stores().forEach(storage=>{try{
      const saved=JSON.parse(storage.getItem(returnKey)||'null');
      const age=Date.now()-Number(saved?.createdAt);
      if(saved?.path&&age>=0&&age<=maxAge&&(!newest||saved.createdAt>newest.createdAt))newest=saved;
      else if(saved)storage.removeItem(returnKey);
    }catch{try{storage.removeItem(returnKey)}catch{}}});
    return newest?normalize(newest.path):'';
  };
  const clearReturn=()=>stores().forEach(storage=>{try{storage.removeItem(returnKey)}catch{}});

  const client=window.siglabDb||window.supabase.createClient(cfg.url,cfg.anonKey,{
    auth:{flowType:'pkce',detectSessionInUrl:true,persistSession:true,autoRefreshToken:true}
  });
  window.siglabDb=client;
  window.labinfoDb=client; // compatibilidade temporaria com os modulos herdados

  const state={session:null,identity:null,staff:null,error:null,ready:false};
  const snapshot=()=>({...state});
  const emit=()=>window.dispatchEvent(new CustomEvent('siglab:institutional-auth',{detail:snapshot()}));
  const safe=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));

  async function refresh(){
    const {data:{session}}=await client.auth.getSession();
    state.session=session||null;state.identity=null;state.staff=null;state.error=null;
    if(session){
      const [identity,staff]=await Promise.all([
        client.rpc('get_my_ifms_identity'),client.rpc('get_my_staff_profile')
      ]);
      state.identity=identity.data?.[0]||null;
      state.staff=staff.data?.[0]||null;
      if(identity.error)state.error=identity.error.message;
    }
    state.ready=true;renderHeader();emit();return snapshot();
  }

  async function signIn(returnPath=location.pathname+location.search){
    const requested=new URL(normalize(returnPath),location.origin);
    saveReturn(requested.pathname+requested.search);
    const callback=new URL(sitePath(''),location.origin);
    requested.searchParams.forEach((value,key)=>callback.searchParams.set(key,value));
    const route=requested.pathname.slice(siteBase.length).replace(/^\/+|\/+$/g,'');
    if(route&&!callback.searchParams.has('route'))callback.searchParams.set('route',route);
    callback.searchParams.set('auth_refresh',Date.now().toString());
    const {error}=await client.auth.signInWithOAuth({
      provider:'google',
      options:{redirectTo:callback.href,queryParams:{hd:'ifms.edu.br',prompt:'select_account'}}
    });
    if(error){clearReturn();throw error}
  }

  async function signOut(){await client.auth.signOut();clearReturn();await refresh()}

  function renderHeader(){
    const login=document.querySelector('#publicAuthButton');
    const session=document.querySelector('#publicSessionStatus');
    if(!login||!session)return;
    login.hidden=Boolean(state.identity);
    session.hidden=!state.identity;
    if(state.identity){
      session.innerHTML=`<span>${safe(state.identity.full_name)}</span><small>${safe(state.identity.email)}</small><button id="publicSessionLogout" type="button">Sair</button>`;
      session.querySelector('#publicSessionLogout').onclick=signOut;
    }
  }

  window.siglabInstitutionalAuth={signIn,signOut,refresh,getState:snapshot,sitePath};
  document.querySelector('#publicAuthButton')?.addEventListener('click',event=>{
    event.currentTarget.disabled=true;signIn(location.pathname+location.search).catch(error=>{
      event.currentTarget.disabled=false;alert(error?.message||'Nao foi possivel iniciar o login institucional.');
    });
  });

  let refreshTimer=null;
  client.auth.onAuthStateChange(()=>{
    clearTimeout(refreshTimer);refreshTimer=setTimeout(()=>refresh(),0);
  });
  refresh().then(auth=>{
    const pending=readReturn();
    if(auth.session&&pending){clearReturn();history.replaceState({},'',pending)}
  });
})();
