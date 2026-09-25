-- =====================================================================
-- 011 — Permissões por área
--   • Só quem é da área da etapa (cargo = área, ex.: CS no Onboarding), quem é
--     responsável pela etapa ou quem é administrador consegue marcar o checklist
--     e alterar a etapa (avançar, voltar, prazo, responsáveis, situação, cobrança).
--   • Itens com responsável próprio (ex.: cotação de frete → Isabella/Cris) só
--     podem ser marcados por esses responsáveis (ou administrador).
--   • Todos continuam vendo tudo.
-- Rodar DEPOIS do 001–010 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- =====================================================================

alter table public.profiles add column if not exists admin boolean not null default false;

-- administradores iniciais: cargo de gestão/diretoria/coordenação
update public.profiles set admin = true
 where tipo = 'equipe' and not admin
   and public.pc_normaliza(coalesce(cargo, '')) ~ '^(gestao|gerencia|diretor|coordena|admin)';
-- se ainda não houver nenhum, o Erick vira administrador
update public.profiles set admin = true
 where tipo = 'equipe'
   and not exists (select 1 from public.profiles where admin)
   and (usuario like 'erick%' or email ilike 'erick%');

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.admin and p.tipo = 'equipe' from public.profiles p where p.id = auth.uid()), false)
$$;
grant execute on function public.is_admin() to authenticated;

-- pode alterar a etapa? (admin, responsável da etapa ou cargo = área da etapa)
create or replace function public.pode_editar_etapa(p_pe_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.processo_etapas pe, public.profiles me
     where pe.id = p_pe_id and me.id = auth.uid() and me.tipo = 'equipe'
       and (auth.uid() = any(pe.responsaveis)
            or public.pc_normaliza(coalesce(me.cargo, '')) = public.pc_normaliza(pe.area)))
$$;
grant execute on function public.pode_editar_etapa(uuid) to authenticated;

-- pode marcar o item? (item com responsável próprio: só ele; senão, regra da etapa)
create or replace function public.pode_marcar_item(p_item uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare it public.processo_checklist; v_resp uuid[];
begin
  select * into it from public.processo_checklist where id = p_item;
  if it.id is null then return false; end if;
  if public.is_admin() then return true; end if;
  if it.modelo_id is not null then
    v_resp := public.pc_item_responsaveis(it.modelo_id);
    if coalesce(array_length(v_resp, 1), 0) > 0 then return auth.uid() = any(v_resp); end if;
  end if;
  return public.pode_editar_etapa(it.processo_etapa_id);
end $$;
grant execute on function public.pode_marcar_item(uuid) to authenticated;

-- pode alterar o processo? (admin ou quem pode alterar a etapa atual)
create or replace function public.pode_editar_processo(p_processo_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or coalesce((
    select public.pode_editar_etapa(pe.id) from public.processo_etapas pe
     where pe.processo_id = p_processo_id and pe.status = 'em_andamento' order by pe.ordem limit 1), false)
$$;
grant execute on function public.pode_editar_processo(uuid) to authenticated;

create or replace function public.pc_sem_permissao(p_area text)
returns void language plpgsql as $$
begin
  raise exception 'Sem permissão: só quem é de % (ou responsável/administrador) pode alterar isto', coalesce(p_area, 'da área');
end $$;

-- ---------------------------------------------------------------------
-- Travas no banco (valem para qualquer acesso, não só pela tela)
--   pg_trigger_depth() = 1 → alteração feita direto pelo usuário (não em cascata)
--   pc.rpc = on           → alteração feita por uma função que já conferiu a permissão
-- ---------------------------------------------------------------------
create or replace function public.pc_trava_checklist()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_area text;
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if new.feito is distinct from old.feito and not public.pode_marcar_item(old.id) then
    if old.modelo_id is not null and coalesce(array_length(public.pc_item_responsaveis(old.modelo_id), 1), 0) > 0 then
      raise exception 'Sem permissão: este item é de %', (select string_agg(p.nome, ' / ') from public.profiles p
                                                            where p.id = any(public.pc_item_responsaveis(old.modelo_id)));
    end if;
    select area into v_area from public.processo_etapas where id = old.processo_etapa_id;
    raise exception 'Sem permissão: só quem é de % (ou responsável/administrador) pode marcar este item', coalesce(v_area, '—');
  end if;
  return new;
end $$;
drop trigger if exists pc_trava_checklist on public.processo_checklist;
create trigger pc_trava_checklist before update on public.processo_checklist
  for each row execute function public.pc_trava_checklist();

create or replace function public.pc_trava_etapa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if not public.pode_editar_etapa(old.id) then perform public.pc_sem_permissao(old.area); end if;
  return new;
end $$;
drop trigger if exists pc_trava_etapa on public.processo_etapas;
create trigger pc_trava_etapa before update on public.processo_etapas
  for each row execute function public.pc_trava_etapa();

create or replace function public.pc_trava_processo()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_area text;
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if not public.pode_editar_processo(old.id) then
    select area into v_area from public.processo_etapas where processo_id = old.id and status = 'em_andamento' order by ordem limit 1;
    perform public.pc_sem_permissao(v_area);
  end if;
  return new;
end $$;
drop trigger if exists pc_trava_processo on public.processos;
create trigger pc_trava_processo before update on public.processos
  for each row execute function public.pc_trava_processo();

-- demanda ligada a checklist: só quem recebeu (ou admin) conclui/reabre
create or replace function public.pc_trava_demanda()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if new.checklist_id is not null and new.demanda_status is distinct from old.demanda_status
     and auth.uid() is distinct from old.demanda_para and not public.is_admin() then
    raise exception 'Sem permissão: só quem recebeu a demanda pode concluir';
  end if;
  return new;
end $$;
drop trigger if exists pc_trava_demanda on public.mensagens;
create trigger pc_trava_demanda before update on public.mensagens
  for each row execute function public.pc_trava_demanda();

-- ninguém se promove a administrador pelo app
create or replace function public.pc_profiles_protege_tipo()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and (new.tipo is distinct from old.tipo or new.cliente_id is distinct from old.cliente_id) then
    raise exception 'Não é permitido alterar o tipo de acesso';
  end if;
  if auth.uid() is not null and new.admin is distinct from old.admin and not public.is_admin() then
    raise exception 'Só um administrador pode mudar quem é administrador';
  end if;
  -- o cargo define o que a pessoa pode alterar: depois de definido, só administrador muda
  if auth.uid() is not null and old.cargo is not null and new.cargo is distinct from old.cargo and not public.is_admin() then
    raise exception 'Só um administrador pode mudar o cargo';
  end if;
  return new;
end $$;

-- administrador define cargo e acesso de administrador de uma pessoa da equipe
drop function if exists public.definir_admin(uuid, boolean);
create or replace function public.definir_pessoa(p_user uuid, p_cargo text, p_admin boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só um administrador pode fazer isso'; end if;
  if p_user = auth.uid() and not p_admin then raise exception 'Você não pode tirar o seu próprio acesso de administrador'; end if;
  update public.profiles set cargo = nullif(trim(p_cargo), ''), admin = p_admin where id = p_user and tipo = 'equipe';
end $$;
grant execute on function public.definir_pessoa(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Ações do processo com permissão conferida (usadas pela tela)
-- ---------------------------------------------------------------------
create or replace function public.pc_exigir_processo(p_processo_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_area text;
begin
  if not public.pode_editar_processo(p_processo_id) then
    select area into v_area from public.processo_etapas where processo_id = p_processo_id and status = 'em_andamento' order by ordem limit 1;
    perform public.pc_sem_permissao(v_area);
  end if;
  perform set_config('pc.rpc', 'on', true);
end $$;

create or replace function public.avancar_etapa(p_processo_id uuid, p_obs text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.pc_exigir_processo(p_processo_id);
  perform public.avancar_processo(p_processo_id, p_obs);
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.avancar_etapa(uuid, text) to authenticated;

create or replace function public.retornar_etapa(p_processo_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.processos where id = p_processo_id and status = 'concluido') then
    if not public.is_admin() then raise exception 'Só um administrador pode reabrir um processo concluído'; end if;
    perform set_config('pc.rpc', 'on', true);
  else
    perform public.pc_exigir_processo(p_processo_id);
  end if;
  perform public.retornar_processo(p_processo_id, p_motivo);
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.retornar_etapa(uuid, text) to authenticated;

-- editar dados / cancelar / reativar: admin ou quem pode alterar a etapa atual
create or replace function public.editar_dados_processo(p_processo_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.processos where id = p_processo_id and status <> 'ativo') then
    if not public.is_admin() then raise exception 'Só um administrador pode alterar um processo concluído ou cancelado'; end if;
  elsif not public.pode_editar_processo(p_processo_id) then
    perform public.pc_exigir_processo(p_processo_id);
  end if;
end $$;
grant execute on function public.editar_dados_processo(uuid) to authenticated;

create or replace function public.registrar_cobranca(p_pe_id uuid, p_obs text default null)
returns void language plpgsql as $$
declare pe public.processo_etapas;
begin
  select * into pe from public.processo_etapas where id = p_pe_id;
  if not public.pode_editar_etapa(p_pe_id) then perform public.pc_sem_permissao(pe.area); end if;
  update public.processo_etapas set ultima_cobranca = now()
   where id = p_pe_id and aguardando_cliente
  returning * into pe;
  if pe.id is null then raise exception 'Esta etapa não está aguardando o cliente'; end if;
  insert into public.processo_eventos (processo_id, tipo, texto)
  values (pe.processo_id, 'cobranca', 'Cliente cobrado' || coalesce(': ' || nullif(trim(p_obs), ''), ''));
end $$;

-- recalcular / sincronizar são chamados depois de editar dados: rodam como etapa do sistema
create or replace function public.recalcular_prazos_seguro(p_processo_id uuid)
returns void language plpgsql as $$
begin
  perform public.editar_dados_processo(p_processo_id);
  perform set_config('pc.rpc', 'on', true);
  perform public.recalcular_prazos(p_processo_id);
  perform public.sincronizar_checklist(p_processo_id);
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.recalcular_prazos_seguro(uuid) to authenticated;

-- criar processo (qualquer pessoa da equipe) já com contato e tipo de ordem
create or replace function public.criar_processo_completo(
  p_cliente text, p_plano text, p_descricao text default null, p_certificacao boolean default false,
  p_cliente_id uuid default null, p_contato text default null, p_gerenciamento text default null
) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  if not public.is_equipe() then raise exception 'Sem permissão'; end if;
  perform set_config('pc.rpc', 'on', true);
  v_id := public.criar_processo(p_cliente, p_plano, p_descricao, p_certificacao, p_cliente_id);
  if nullif(trim(p_contato), '') is not null or nullif(p_gerenciamento, '') is not null then
    update public.processos set contato = nullif(trim(p_contato), ''), gerenciamento = nullif(p_gerenciamento, '') where id = v_id;
    if nullif(p_gerenciamento, '') is not null then perform public.sincronizar_checklist(v_id); end if;
  end if;
  perform set_config('pc.rpc', 'off', true);
  return v_id;
end $$;
grant execute on function public.criar_processo_completo(text, text, text, boolean, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Configuração do fluxo (etapas, responsáveis padrão, checklists): só administrador altera
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['etapas', 'checklist_modelo'] loop
    execute format('drop policy if exists pc_%1$s_all on public.%1$I', t);
    execute format('drop policy if exists pc_%1$s_ler on public.%1$I', t);
    execute format('drop policy if exists pc_%1$s_admin on public.%1$I', t);
    execute format('create policy pc_%1$s_ler on public.%1$I for select to authenticated using (public.is_equipe())', t);
    execute format('create policy pc_%1$s_admin on public.%1$I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- vincular a pessoa às etapas (no cadastro/perfil) não esbarra na trava
create or replace function public.vincular_minhas_etapas()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('pc.rpc', 'on', true);
  n := public.vincular_usuario_etapas(auth.uid());
  perform set_config('pc.rpc', 'off', true);
  return n;
end $$;
revoke all on function public.vincular_minhas_etapas() from public;
grant execute on function public.vincular_minhas_etapas() to authenticated;

-- as versões antigas não ficam mais expostas (a tela usa as de cima)
revoke execute on function public.avancar_processo(uuid, text) from public, anon, authenticated;
revoke execute on function public.retornar_processo(uuid, text) from public, anon, authenticated;
revoke execute on function public.pc_exigir_processo(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
