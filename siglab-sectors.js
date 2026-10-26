(function(){
  const $=selector=>document.querySelector(selector);
  const safe=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  let auth=null,sectors=[],profiles=[],assignments=[],labs=[];

  function ensurePanel(){
    const section=$('#registrationsSection');
    if(!section||$('#siglabSectorManagement'))return;
    section.insertAdjacentHTML('afterbegin',`<section id="siglabSectorManagement" class="card sector-management">
      <div class="sector-management-head"><div><span class="eyebrow">ORGANIZAÇÃO DO SIGLAB</span><h2>Setores e responsabilidades</h2><p>Separe os laboratórios por área e defina exatamente quais técnicos podem administrar cada agenda.</p></div><span class="sector-security-pill">Permissões aplicadas no banco</span></div>
      <div id="sectorManagementContent"><p class="empty">Carregando setores…</p></div>
    </section>`);
  }

  async function load(){
    const db=window.siglabDb;if(!db||!auth?.staff)return;
    ensurePanel();
    const requests=[
      db.from('sectors').select('*').order('sort_order').order('name'),
      db.from('labs').select('id,name,sector_id,active').eq('active',true).order('name')
    ];
    if(auth.staff.is_admin)requests.push(
      db.from('profiles').select('id,full_name,email,role,active').eq('active',true).order('full_name'),
      db.from('profile_sectors').select('profile_id,sector_id')
    );
    const result=await Promise.all(requests),error=result.find(item=>item.error)?.error;
    if(error){$('#sectorManagementContent').innerHTML=`<p class="error-text">${safe(error.message)}</p>`;return}
    sectors=result[0].data||[];labs=result[1].data||[];profiles=result[2]?.data||[];assignments=result[3]?.data||[];
    window.siglabSectors=sectors;
    if(typeof window.registration==='function')window.registration();
    render();
  }

  function internalOptions(selected=''){
    return sectors.filter(item=>item.active&&item.reservation_mode==='internal').map(item=>`<option value="${item.id}" ${item.id===selected?'selected':''}>${safe(item.name)}</option>`).join('');
  }

  function render(){
    const box=$('#sectorManagementContent');if(!box)return;
    if(!auth.staff.is_admin){
      const mine=auth.staff.sectors||[];
      box.innerHTML=`<div class="sector-readonly"><strong>Setores sob sua responsabilidade</strong><p>${mine.length?mine.map(item=>safe(item.name)).join(' • '):'Nenhum setor atribuído. Solicite a vinculação a um administrador.'}</p></div>`;
      return;
    }
    const sectorRows=sectors.map(item=>`<article class="sector-row"><div><strong>${safe(item.name)}</strong><span>${item.reservation_mode==='external'?'Externo • '+safe(item.external_url):'Agenda interna do SIGLAB'}</span></div><small>${labs.filter(lab=>lab.sector_id===item.id).length} laboratório(s)</small></article>`).join('');
    const technicianRows=profiles.filter(profile=>profile.role!=='admin').map(profile=>{
      const selected=new Set(assignments.filter(item=>item.profile_id===profile.id).map(item=>item.sector_id));
      return `<article class="sector-assignment-row" data-profile="${profile.id}"><div><strong>${safe(profile.full_name)}</strong><small>${safe(profile.email)} • ${profile.role==='supervisor'?'Supervisor':'Técnico'}</small></div><div class="sector-checks">${sectors.filter(item=>item.active&&item.reservation_mode==='internal').map(item=>`<label><input type="checkbox" value="${item.id}" ${selected.has(item.id)?'checked':''}> ${safe(item.name)}</label>`).join('')||'<span>Cadastre um setor interno primeiro.</span>'}</div><button class="secondary save-sector-assignment" type="button">Salvar atribuições</button></article>`;
    }).join('')||'<p class="empty">Nenhum técnico cadastrado.</p>';
    const labRows=labs.map(lab=>`<label class="lab-sector-row"><span>${safe(lab.name)}</span><select data-lab-sector="${lab.id}"><option value="">Sem setor</option>${internalOptions(lab.sector_id||'')}</select></label>`).join('')||'<p class="empty">Nenhum laboratório cadastrado.</p>';
    box.innerHTML=`<div class="sector-management-grid"><form id="sectorForm" class="sector-form"><h3>Novo setor</h3><label>Nome<input name="name" required maxlength="120" placeholder="Ex.: Laboratórios de Física"></label><label>Identificador<input name="slug" required pattern="[a-z0-9-]+" placeholder="fisica"></label><label>Descrição<input name="description" maxlength="240"></label><label>Tipo<select name="mode"><option value="internal">Agenda interna no SIGLAB</option><option value="external">Redirecionamento externo</option></select></label><label id="sectorExternalUrl" hidden>Endereço externo<input name="external_url" type="url" placeholder="https://..."></label><label class="sector-active"><input name="active" type="checkbox" checked> Setor ativo</label><button class="primary" type="submit">Cadastrar setor</button></form><div class="sector-list"><h3>Setores cadastrados</h3>${sectorRows||'<p class="empty">Nenhum setor cadastrado.</p>'}</div></div><div class="sector-relations"><section><h3>Laboratórios por setor</h3><p>Todo laboratório com agenda interna precisa estar vinculado a um setor.</p>${labRows}</section><section><h3>Técnicos responsáveis</h3><p>Um técnico pode atender mais de um setor.</p>${technicianRows}</section></div>`;
    bind();
  }

  function bind(){
    const form=$('#sectorForm'),mode=form?.elements.mode,url=$('#sectorExternalUrl');
    if(mode)mode.onchange=()=>{url.hidden=mode.value!=='external';form.elements.external_url.required=mode.value==='external'};
    if(form)form.onsubmit=async event=>{
      event.preventDefault();const button=event.submitter,entry=Object.fromEntries(new FormData(form));button.disabled=true;button.textContent='Salvando…';
      const {error}=await window.siglabDb.rpc('admin_save_sector',{p_id:null,p_name:entry.name,p_slug:entry.slug,p_description:entry.description||null,p_mode:entry.mode,p_external_url:entry.mode==='external'?entry.external_url:null,p_active:entry.active==='on'});
      if(error){button.disabled=false;button.textContent='Cadastrar setor';return alert(error.message)}form.reset();await load();
    };
    document.querySelectorAll('[data-lab-sector]').forEach(select=>select.onchange=async()=>{
      select.disabled=true;const {error}=await window.siglabDb.from('labs').update({sector_id:select.value||null}).eq('id',select.dataset.labSector);select.disabled=false;if(error)alert(error.message);else await load();
    });
    document.querySelectorAll('.save-sector-assignment').forEach(button=>button.onclick=async()=>{
      const row=button.closest('[data-profile]'),ids=[...row.querySelectorAll('input:checked')].map(input=>input.value);button.disabled=true;
      const {error}=await window.siglabDb.rpc('admin_set_profile_sectors',{p_profile:row.dataset.profile,p_sectors:ids});button.disabled=false;if(error)alert(error.message);else{button.textContent='Salvo ✓';setTimeout(()=>button.textContent='Salvar atribuições',1400)}
    });
  }

  window.addEventListener('siglab:institutional-auth',event=>{auth=event.detail;if(auth.staff)load()});
  auth=window.siglabInstitutionalAuth?.getState?.()||null;if(auth?.staff)load();
})();
