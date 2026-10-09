-- 1. Adiciona coluna de sistema operacional na tabela de laboratórios
alter table public.labs
  add column if not exists operating_system text;

-- 2. Função RPC segura para atualizar cadastro de técnicos e supervisores
drop function if exists public.update_staff_profile(uuid, text, text, text, text);

create or replace function public.update_staff_profile(
  p_user_id uuid,
  p_full_name text,
  p_siape text,
  p_role text,
  p_new_password text default null
)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_current_role text;
  v_clean_name text;
  v_clean_siape text;
  v_clean_role text;
begin
  -- Valida se quem está chamando é usuário autenticado
  select role into v_current_role from public.profiles where id = auth.uid() and active = true;
  if v_current_role is null then
    raise exception 'Apenas usuários autenticados podem editar perfis.';
  end if;

  v_clean_name := btrim(coalesce(p_full_name, ''));
  v_clean_siape := btrim(coalesce(p_siape, ''));
  v_clean_role := lower(btrim(coalesce(p_role, 'tecnico')));

  if length(v_clean_name) < 3 then
    raise exception 'Nome do técnico deve conter pelo menos 3 caracteres.';
  end if;

  if v_clean_siape !~ '^[0-9]{5,12}$' then
    raise exception 'SIAPE inválido (deve conter de 5 a 12 dígitos numéricos).';
  end if;

  if v_clean_role not in ('tecnico', 'supervisor') then
    v_clean_role := 'tecnico';
  end if;

  -- Impede duplicação de SIAPE entre usuários diferentes
  if exists (select 1 from public.profiles where siape = v_clean_siape and id <> p_user_id) then
    raise exception 'Este SIAPE já pertence a outro usuário cadastrado.';
  end if;

  -- Atualiza dados cadastrais em public.profiles
  update public.profiles
  set full_name = v_clean_name,
      siape = v_clean_siape,
      role = v_clean_role,
      active = true,
      updated_at = now()
  where id = p_user_id;

  if not found then
    raise exception 'Perfil de usuário não localizado.';
  end if;

  -- Se foi informada uma nova senha com pelo menos 8 dígitos, atualiza no auth.users
  if p_new_password is not null and length(btrim(p_new_password)) >= 8 then
    update auth.users
    set encrypted_password = crypt(btrim(p_new_password), gen_salt('bf')),
        updated_at = now()
    where id = p_user_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'id', p_user_id,
    'full_name', v_clean_name,
    'siape', v_clean_siape,
    'role', v_clean_role
  );
end $$;

grant execute on function public.update_staff_profile(uuid, text, text, text, text) to authenticated;
