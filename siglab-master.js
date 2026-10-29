(() => {
  const $=s=>document.querySelector(s),db=window.siglabDb;
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  let data={sectors:[],users:[],audit:[]},tab='sectors';
  const roles={master:'Master',gestor:'Gestor de setor',servidor:'Servidor'};
  const allowed=()=>window.siglabAuth?.getState().staff?.is_admin===true;
  async function open(){
    const box=$('#masterSection');
    if(!allowed())return window.toast('Acesso exclusivo do master.');
    document.querySelectorAll('#adminView .admin-section').forEach(s=>s.hidden=true);
    box.hidden=false;$('#adminMenuDropdown').hidden=true;
    $('#adminTitle').textContent='Administração geral';
    $('#adminSubtitle').textContent='Organize setores, contas institucionais e permissões do SIGLAB.';
    box.innerHTML='<div class="card siglab-loading" role="status">Carregando administração…</div>';
    try{
      const result=await db.rpc('master_dashboard');if(result.error)throw result.error;
      data=result.data||data;render();
    }catch(e){box.innerHTML=`<div class="card siglab-error" role="alert">${esc(e.message)}<p>Se o painel ainda não foi ativado, execute a migration master no Supabase exclusivo do SIGLAB.</p></div>`}
  }
  function render(){
    if(!allowed())return;
    $('#masterSection').innerHTML=`<div class="master-tabs" role="group" aria-label="Administração geral">${[['sectors','Setores'],['users','Usuários e perfis'],['audit','Auditoria']].map(([id,label])=>`<button class="secondary ${tab===id?'selected':''}" aria-pressed="${tab===id}" data-master-tab="${id}" type="button">${label}</button>`).join('')}</div><div id="masterContent"></div>`;
    document.querySelectorAll('[data-master-tab]').forEach(b=>b.onclick=()=>{tab=b.dataset.masterTab;render()});
    if(tab==='sectors')renderSectors();else if(tab==='users')renderUsers();else renderAudit();
  }
  async function save(form,rpc,args){
    const button=form.querySelector('[type="submit"]'),error=form.querySelector('[role="alert"]');
    button.disabled=true;error.textContent='';
    try{const result=await db.rpc(rpc,args);if(result.error)throw result.error;window.toast('Alterações salvas.');await window.siglabAuth.refresh();if(allowed())await open()}
    catch(e){error.textContent=e.message||'Não foi possível salvar.'}
    finally{button.disabled=false}
  }
  function renderSectors(){
    $('#masterContent').innerHTML=`<div class="siglab-registry-grid"><form id="masterSectorForm" class="card siglab-registry-form"><span class="eyebrow">SETOR RESPONSÁVEL</span><h2 id="sectorFormTitle">Cadastrar setor</h2><input name="id" type="hidden"><label>Nome<input name="name" maxlength="120" required></label><label>Identificador<input name="slug" maxlength="80" pattern="[a-z0-9]+(-[a-z0-9]+)*" placeholder="eletrotecnica" required></label><label>E-mail de notificação<input name="email" type="email" maxlength="180" placeholder="setor@ifms.edu.br"></label><p class="field-hint">Endereço institucional de contato. O cadastro não envia mensagens nem cria uma conta Google.</p><label class="siglab-check"><input name="active" type="checkbox" checked><span>Setor ativo</span></label><p role="alert" class="login-error"></p><div class="master-form-actions"><button class="primary" type="submit">Salvar setor</button><button class="secondary" id="resetSectorForm" type="button">Novo cadastro</button></div></form><section class="card siglab-registry-list"><header><h2>Setores cadastrados</h2><p>Eletrotécnica possui entrada própria; os outros setores internos aparecem em Demais laboratórios.</p></header>${data.sectors.map(s=>`<article><div><strong>${esc(s.name)}</strong><span>${esc(s.notification_email||'Sem e-mail de notificação')} · ${s.active?'Ativo':'Inativo'}${s.reservation_mode==='external'?' · Redirecionamento externo':''}</span></div>${s.reservation_mode==='internal'?`<button class="secondary" data-edit-sector="${s.id}" type="button">Editar</button>`:''}</article>`).join('')||'<p class="empty">Nenhum setor cadastrado.</p>'}</section></div>`;
    const form=$('#masterSectorForm');
    form.onsubmit=e=>{e.preventDefault();const f=form.elements;save(form,'master_save_sector',{p_id:f.id.value||null,p_name:f.name.value.trim(),p_slug:f.slug.value.trim(),p_email:f.email.value.trim()||null,p_active:f.active.checked})};
    $('#resetSectorForm').onclick=()=>{form.reset();form.elements.id.value='';$('#sectorFormTitle').textContent='Cadastrar setor'};
    document.querySelectorAll('[data-edit-sector]').forEach(b=>b.onclick=()=>{const s=data.sectors.find(x=>x.id===b.dataset.editSector),f=form.elements;f.id.value=s.id;f.name.value=s.name;f.slug.value=s.slug;f.email.value=s.notification_email||'';f.active.checked=s.active;$('#sectorFormTitle').textContent='Editar setor';form.scrollIntoView({behavior:'smooth',block:'start'})});
  }
  function renderUsers(){
    $('#masterContent').innerHTML=`<div class="siglab-registry-grid"><form id="masterUserForm" class="card siglab-registry-form"><span class="eyebrow">ACESSO INSTITUCIONAL</span><h2 id="userFormTitle">Cadastrar acesso</h2><label>Nome completo<input name="name" maxlength="160" required></label><label>E-mail Google IFMS<input name="email" type="email" maxlength="180" required></label><label>SIAPE<input name="siape" inputmode="numeric" pattern="[0-9]{5,12}" maxlength="12"></label><p class="field-hint">Obrigatório para gestores e servidores. Master sem matrícula pode administrar, mas não reservar como servidor.</p><label>Perfil<select name="role"><option value="servidor">Servidor — próprias reservas</option><option value="gestor">Gestor — setores vinculados</option><option value="master">Master — administração geral</option></select></label><fieldset id="masterUserSectors"><legend>Setores gerenciados</legend>${data.sectors.filter(s=>s.active&&s.reservation_mode==='internal').map(s=>`<label class="siglab-check"><input type="checkbox" name="sectors" value="${s.id}"><span>${esc(s.name)}</span></label>`).join('')||'<p>Nenhum setor interno ativo.</p>'}</fieldset><label class="siglab-check"><input name="active" type="checkbox" checked><span>Acesso ativo</span></label><p class="field-hint">O usuário entrará com a própria conta Google. Nenhuma senha é criada ou compartilhada.</p><p role="alert" class="login-error"></p><div class="master-form-actions"><button class="primary" type="submit">Salvar acesso</button><button class="secondary" id="resetUserForm" type="button">Novo cadastro</button></div></form><section class="card siglab-registry-list"><header><h2>Contas e permissões</h2><label>Pesquisar<input id="masterUserSearch" placeholder="Nome ou e-mail"></label></header><div id="masterUserRows"></div></section></div>`;
    const form=$('#masterUserForm'),f=form.elements;
    const changeRole=()=>{f.siape.required=f.role.value!=='master';$('#masterUserSectors').hidden=f.role.value!=='gestor'};
    f.role.onchange=changeRole;changeRole();
    form.onsubmit=e=>{e.preventDefault();if(f.role.value==='master'&&!confirm('Este perfil terá acesso à administração de todo o SIGLAB. Confirmar?'))return;
      save(form,'master_save_access',{p_email:f.email.value.trim(),p_name:f.name.value.trim(),p_siape:f.siape.value.trim()||null,p_role:f.role.value,p_sectors:[...form.querySelectorAll('[name="sectors"]:checked')].map(x=>x.value),p_active:f.active.checked})};
    $('#resetUserForm').onclick=()=>{form.reset();f.email.readOnly=false;$('#userFormTitle').textContent='Cadastrar acesso';changeRole()};
    const rows=()=>{
      const q=$('#masterUserSearch').value.toLocaleLowerCase('pt-BR');
      $('#masterUserRows').innerHTML=data.users.filter(u=>(u.full_name+' '+u.email).toLocaleLowerCase('pt-BR').includes(q)).map(u=>`<article><div><strong>${esc(u.full_name)}</strong><span>${esc(u.email)} · ${roles[u.access_role]} · ${u.active?'Ativo':'Inativo'}</span><span>${esc((u.sector_ids||[]).map(id=>data.sectors.find(s=>s.id===id)?.name||'Setor indisponível').join(', '))}</span></div><button class="secondary" data-edit-user="${esc(u.email)}" type="button">Editar</button></article>`).join('')||'<p class="empty">Nenhuma conta encontrada.</p>';
      document.querySelectorAll('[data-edit-user]').forEach(b=>b.onclick=()=>{const u=data.users.find(x=>x.email===b.dataset.editUser);f.name.value=u.full_name;f.email.value=u.email;f.email.readOnly=true;f.siape.value=u.siape||'';f.role.value=u.access_role;f.active.checked=u.active;form.querySelectorAll('[name="sectors"]').forEach(c=>c.checked=(u.sector_ids||[]).includes(c.value));$('#userFormTitle').textContent='Editar acesso';changeRole();form.scrollIntoView({behavior:'smooth',block:'start'})});
      decorateStatusActions();
    };$('#masterUserSearch').oninput=rows;rows();
    window.siglabUsersCsv?.mount($('#masterContent'),data,open);
    function decorateStatusActions(){
    document.querySelectorAll('[data-edit-user]').forEach(edit=>{
      const user=data.users.find(u=>u.email===edit.dataset.editUser),button=document.createElement('button');
      button.type='button';button.className=user.active?'danger-button':'secondary';button.textContent=user.active?'Desativar':'Reativar';
      button.onclick=async()=>{
        if(!confirm(`${user.active?'Desativar':'Reativar'} o acesso de ${user.full_name}? O histórico e as reservas existentes serão preservados.`))return;
        button.disabled=true;
        try{const result=await db.rpc('master_save_access',{p_email:user.email,p_name:user.full_name,p_siape:user.siape,p_role:user.access_role,p_sectors:user.sector_ids||[],p_active:!user.active});if(result.error)throw result.error;window.toast('Situação do acesso atualizada.');await window.siglabAuth.refresh();if(allowed())await open()}
        catch(e){window.toast(e.message);button.disabled=false}
      };const actions=document.createElement('div');actions.className='master-user-actions';edit.replaceWith(actions);actions.append(edit,button);
    });
    }
  }
  function renderAudit(){
    $('#masterContent').innerHTML=`<section class="card siglab-registry-list"><header><h2>Histórico administrativo</h2><p>Últimas 50 alterações. Os valores anteriores e novos são preservados no banco; não podem ser apagados por este painel.</p></header>${data.audit.map(a=>`<article><div><strong>${esc(a.actor_email||'Configuração inicial')}</strong><span>${esc(new Date(a.created_at).toLocaleString('pt-BR',{timeZone:'America/Cuiaba'}))} · ${esc(a.action)} · ${esc(a.entity)}</span><span>${esc(a.record_key)}</span></div></article>`).join('')||'<p class="empty">Nenhuma alteração registrada.</p>'}</section>`;
  }
  window.siglabMaster={open};
})();
