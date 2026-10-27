(function(){
  const cfg=window.SIGLAB_SUPABASE||window.LABINFO_SUPABASE||{};
  if(!cfg.url||!cfg.anonKey||!window.supabase)return;
  const testMode=cfg.testAuthEnabled===true;

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

  async function signInWithPassword(email,password){
    if(!testMode)throw new Error('O acesso temporário por senha está desativado.');
    const normalizedEmail=String(email||'').trim().toLowerCase();
    if(!/^siglab\.teste\.(admin|tecnico|servidor)@ifms\.edu\.br$/.test(normalizedEmail)){
      throw new Error('Use uma das contas temporárias de homologação do SIGLAB.');
    }
    const {error}=await client.auth.signInWithPassword({email:normalizedEmail,password:String(password||'')});
    if(error)throw new Error('Usuário ou senha de teste inválidos.');
    return refresh();
  }

  async function signOut(){await client.auth.signOut();clearReturn();await refresh()}

  function renderHeader(){
    const login=document.querySelector('#publicAuthButton');
    const session=document.querySelector('#publicSessionStatus');
    if(!login||!session)return;
    if(testMode&&login.textContent.includes('@ifms.edu.br'))login.innerHTML='<span aria-hidden="true">T</span> Entrar para teste';
    login.hidden=Boolean(state.identity);
    session.hidden=!state.identity;
    if(state.identity){
      session.innerHTML=`<span>${safe(state.identity.full_name)}</span><small>${safe(state.identity.email)}</small><button id="publicSessionLogout" type="button">Sair</button>`;
      session.querySelector('#publicSessionLogout').onclick=signOut;
    }
  }

  function openTestLogin(){
    let modal=document.querySelector('#publicTestLoginModal');
    if(!modal){
      document.body.insertAdjacentHTML('beforeend',`<div id="publicTestLoginModal" class="modal-backdrop" hidden><div class="card login-card"><div class="modal-heading"><div><span class="eyebrow">AMBIENTE DE HOMOLOGAÇÃO</span><h2>Entrar com usuário de teste</h2><p>Use uma das contas temporárias definidas para validar o SIGLAB.</p></div><button class="modal-close" type="button" aria-label="Fechar">×</button></div><form><label>E-mail de teste<input name="email" type="email" autocomplete="username" required></label><label>Senha temporária<input name="password" type="password" autocomplete="current-password" required></label><p class="login-error" role="alert"></p><button class="primary" type="submit">Entrar no ambiente de teste</button></form></div></div>`);
      modal=document.querySelector('#publicTestLoginModal');
      const close=()=>{modal.hidden=true;document.body.classList.remove('modal-open')};
      modal.querySelector('.modal-close').onclick=close;
      modal.onclick=event=>{if(event.target===modal)close()};
      modal.querySelector('form').onsubmit=async event=>{
        event.preventDefault();
        const form=event.currentTarget,errorBox=form.querySelector('.login-error'),button=form.querySelector('[type="submit"]');
        errorBox.textContent='';button.disabled=true;
        try{await signInWithPassword(form.elements.email.value,form.elements.password.value);form.reset();close()}
        catch(error){errorBox.textContent=error?.message||'Não foi possível entrar.'}
        finally{button.disabled=false}
      };
    }
    modal.hidden=false;document.body.classList.add('modal-open');modal.querySelector('input')?.focus();
  }

  window.siglabInstitutionalAuth={signIn,signInWithPassword,signOut,refresh,getState:snapshot,sitePath,testMode};
  document.querySelector('#publicAuthButton')?.addEventListener('click',event=>{
    if(testMode){openTestLogin();return}
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
