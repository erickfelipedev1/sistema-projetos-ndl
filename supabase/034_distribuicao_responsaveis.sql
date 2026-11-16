-- =====================================================================
-- 034 — Atualização de 09/11/2026 (Jornada 4S)
-- Rodar DEPOIS do 001–033. Pode rodar mais de uma vez (não desfaz ajustes feitos depois
-- em Configurações: cada parte só age se ainda não foi aplicada).
--
--   1. Etapa "Distribuição" (Ana Clara) entre Onboarding e Projeto: ela escolhe UMA pessoa
--      para conduzir o projeto (Gabriella ou Giovanna no sourcing, Alycia na estimativa).
--      Ao direcionar, a Distribuição é concluída e o Projeto começa com essa pessoa.
--      Processos que ainda estão no Onboarding ganham a etapa; os demais não mudam.
--   2. Um responsável por etapa: Onboarding e Apresentação da estimativa = Fernando (CS);
--      Projeto deixa de ter o grupo inteiro como padrão (é definido na Distribuição).
--   3. Checklist da estimativa: Alycia monta e envia para a verificação da NLG
--      (Marta / Josivaldo / Ysabella), consolida a devolutiva e envia ao Fernando.
--   4. Títulos do checklist sem nome de empresa terceira.
--   5. "Encerrar sem ordem": resultado (deu preço / não deu preço) e motivo, para os
--      filtros da aba Concluídos. Concluído sem resultado = virou ordem.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Etapa Distribuição
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.etapas where nome = 'Distribuição') then
    update public.etapas set ordem = ordem + 1 where ordem >= 2;
    insert into public.etapas (ordem, area, nome, tipo, prazo_dias_uteis, responsaveis_label)
    values (2, 'Projetos', 'Distribuição', 'tarefa', 1, 'Ana Clara');
  end if;
end $$;

-- responsáveis padrão pelo nome (quem ainda não tem conta fica só no rótulo)
update public.etapas set responsaveis_label = 'Ana Clara',
       responsaveis_padrao = coalesce((select array_agg(p.id order by p.nome) from public.profiles p
          where p.tipo = 'equipe' and (public.pc_normaliza(p.nome) like 'ana clara%'
             or (public.pc_normaliza(split_part(trim(p.nome), ' ', 1)) = 'ana' and public.pc_normaliza(p.cargo) = 'projetos'))), '{}')
 where nome = 'Distribuição' and responsaveis_padrao = '{}';

update public.etapas set responsaveis_label = 'Fernando',
       responsaveis_padrao = coalesce((select array_agg(p.id order by p.nome) from public.profiles p
          where p.tipo = 'equipe' and public.pc_normaliza(split_part(trim(p.nome), ' ', 1)) = 'fernando'), '{}')
 where nome in ('Onboarding', 'Apresentação da estimativa') and responsaveis_label is distinct from 'Fernando';

-- Projeto: sem grupo padrão — quem conduz é escolhido na Distribuição
update public.etapas set responsaveis_label = 'Definido na Distribuição', responsaveis_padrao = '{}'
 where nome = 'Projeto (Flex / Premium / Full)' and responsaveis_label is distinct from 'Definido na Distribuição';

-- processos em andamento: Onboarding/Apresentação ainda não concluídos passam para o Fernando;
-- Projeto ainda não iniciado fica sem responsável até a Distribuição
update public.processo_etapas pe
   set responsaveis = e.responsaveis_padrao, responsaveis_label = e.responsaveis_label
  from public.etapas e, public.processos p
 where pe.etapa_id = e.id and p.id = pe.processo_id and p.status in ('ativo', 'pausado')
   and pe.status <> 'concluida' and e.nome in ('Onboarding', 'Apresentação da estimativa')
   and pe.responsaveis_label is distinct from e.responsaveis_label and e.responsaveis_label = 'Fernando';

update public.processo_etapas pe
   set responsaveis = '{}', responsaveis_label = 'Definido na Distribuição'
  from public.processos p
 where p.id = pe.processo_id and p.status in ('ativo', 'pausado')
   and pe.nome = 'Projeto (Flex / Premium / Full)' and pe.status = 'pendente'
   and pe.responsaveis_label is distinct from 'Definido na Distribuição';

-- quem ainda está no Onboarding ganha a etapa Distribuição logo depois dele
do $$
declare r record; v_et public.etapas;
begin
  select * into v_et from public.etapas where nome = 'Distribuição';
  for r in
    select pe.processo_id, pe.ordem from public.processo_etapas pe
      join public.processos p on p.id = pe.processo_id
     where pe.nome = 'Onboarding' and pe.status <> 'concluida' and p.status in ('ativo', 'pausado')
       and not exists (select 1 from public.processo_etapas x where x.processo_id = pe.processo_id and x.nome = 'Distribuição')
  loop
    update public.processo_etapas set ordem = ordem + 1000 where processo_id = r.processo_id and ordem > r.ordem;
    update public.processo_etapas set ordem = ordem - 999 where processo_id = r.processo_id and ordem > 1000;
    insert into public.processo_etapas (processo_id, etapa_id, ordem, area, nome, tipo, prazo_dias_uteis, prazo_editavel, responsaveis, responsaveis_label)
    values (r.processo_id, v_et.id, r.ordem + 1, v_et.area, v_et.nome, v_et.tipo, v_et.prazo_dias_uteis, v_et.prazo_editavel,
            v_et.responsaveis_padrao, v_et.responsaveis_label);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Direcionar: na Distribuição (conclui a etapa e abre o Projeto com a pessoa)
-- ou no Projeto (troca quem conduz). Sempre UMA pessoa.
-- ---------------------------------------------------------------------
create or replace function public.direcionar_projeto(p_processo_id uuid, p_responsavel uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_atual public.processo_etapas;
  v_pe public.processo_etapas;
  v_proc public.processos;
  v_nome text;
  v_autor uuid := auth.uid();
begin
  perform public.pc_exigir_processo(p_processo_id);   -- confere permissão e liga pc.rpc

  select * into v_proc from public.processos where id = p_processo_id;
  if v_proc.status <> 'ativo' then raise exception 'O processo não está ativo'; end if;

  select * into v_atual from public.processo_etapas
   where processo_id = p_processo_id and status = 'em_andamento' order by ordem limit 1;
  if v_atual.nome is distinct from 'Distribuição' and v_atual.nome is distinct from 'Projeto (Flex / Premium / Full)' then
    raise exception 'O processo não está na Distribuição nem no Projeto';
  end if;

  select * into v_pe from public.processo_etapas
   where processo_id = p_processo_id and nome = 'Projeto (Flex / Premium / Full)' and status <> 'concluida'
   order by ordem limit 1;
  if v_pe.id is null then raise exception 'O processo não tem a etapa de Projeto'; end if;

  select coalesce(nullif(trim(nome), ''), email) into v_nome
    from public.profiles where id = p_responsavel and tipo = 'equipe';
  if v_nome is null then raise exception 'Pessoa não encontrada na equipe'; end if;

  update public.processo_etapas
     set responsaveis = array[p_responsavel], responsaveis_label = v_nome
   where id = v_pe.id;

  -- itens sem responsável fixo no modelo passam para quem vai conduzir
  update public.processo_checklist c
     set responsavel_id = p_responsavel
    from public.checklist_modelo m
   where c.processo_etapa_id = v_pe.id and c.modelo_id = m.id and not c.feito
     and coalesce(array_length(m.responsaveis, 1), 0) = 0
     and m.responsaveis_label is null;

  insert into public.processo_eventos (processo_id, tipo, texto)
  values (p_processo_id, 'responsavel', 'Projeto direcionado para ' || v_nome);

  -- na Distribuição, direcionar conclui a etapa e já abre o Projeto
  if v_atual.nome = 'Distribuição' then
    perform public.avancar_processo(p_processo_id, null);
    select * into v_pe from public.processo_etapas where id = v_pe.id;
  end if;

  -- demanda no chat (não manda para si mesmo)
  if v_autor is not null and v_autor <> p_responsavel then
    insert into public.mensagens (conversa_id, autor, texto, processo_id, demanda_para, demanda_prazo, demanda_status)
    values (public.pc_conversa_entre(v_autor, p_responsavel), v_autor,
            v_proc.codigo || ' · ' || v_proc.cliente
              || E'\nProjeto direcionado para você' || coalesce(' (plano ' || v_proc.plano || ')', ''),
            p_processo_id, p_responsavel, v_pe.prazo_em, 'aberta');
  end if;

  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.direcionar_projeto(uuid, uuid) to authenticated;

-- a Distribuição só se conclui escolhendo quem conduz (pelo direcionar)
create or replace function public.avancar_etapa(p_processo_id uuid, p_obs text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.pc_exigir_processo(p_processo_id);
  if exists (select 1 from public.processo_etapas
              where processo_id = p_processo_id and status = 'em_andamento' and nome = 'Distribuição')
     and not exists (select 1 from public.processo_etapas
              where processo_id = p_processo_id and nome = 'Projeto (Flex / Premium / Full)'
                and coalesce(array_length(responsaveis, 1), 0) = 1) then
    raise exception 'Escolha quem vai conduzir o projeto para concluir a Distribuição';
  end if;
  perform public.avancar_processo(p_processo_id, p_obs);
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.avancar_etapa(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Checklist da estimativa (etapa Projeto)
-- ---------------------------------------------------------------------
update public.checklist_modelo m set
       titulo = v.titulo, descricao = v.descricao, responsaveis = '{}', responsaveis_label = v.resp, ativo = v.ativo
  from public.etapas e,
       (values
         (140, '14º Montagem da estimativa e envio para a verificação da NLG',
               'Montar a planilha de estimativa de custos e enviar para a equipe da NLG verificar.', 'Alycia', true),
         (145, '15º Verificação da estimativa pela NLG',
               E'• NCM dos produtos\n• Alíquotas e impostos aplicáveis\n• Necessidade de anuências\n• Necessidade de certificações\n• Valores e demais custos da importação', 'Marta / Josivaldo / Ysabella', true),
         (150, '16º Devolutiva da NLG recebida e consolidada',
               'Receber as devolutivas da NLG, consolidar as informações e formalizar a estimativa.', 'Alycia', true),
         (155, '17º Verificação da devolutiva', null, 'Alycia', false),
         (160, '17º Envio da estimativa de custos para o Fernando (CS)',
               'Encaminhar a estimativa formalizada ao Fernando, do CS, para a apresentação ao cliente.', 'Alycia', true)
       ) as v(ordem, titulo, descricao, resp, ativo)
 where m.etapa_id = e.id and e.nome = 'Projeto (Flex / Premium / Full)' and m.ordem = v.ordem
   -- só na primeira vez (depois disso, vale o que for ajustado em Configurações)
   and not exists (select 1 from public.checklist_modelo x where x.titulo = '15º Verificação da estimativa pela NLG');

-- ---------------------------------------------------------------------
-- 4. Sem nome de empresa terceira nos títulos do checklist
-- ---------------------------------------------------------------------
update public.checklist_modelo
   set titulo = replace(replace(titulo, 'à NTL', 'à trading parceira'), 'NTL', 'trading parceira')
 where titulo like '%NTL%';

-- leva títulos e descrições novos para os processos (etapas ainda não concluídas)
update public.processo_checklist c
   set titulo = m.titulo, descricao = m.descricao
  from public.checklist_modelo m, public.processo_etapas pe
 where c.modelo_id = m.id and pe.id = c.processo_etapa_id and pe.status <> 'concluida'
   and (c.titulo is distinct from m.titulo or c.descricao is distinct from m.descricao);

-- tira o item desativado (17º antigo) de quem ainda não o marcou e cria os que faltarem
select public.sincronizar_checklist(id) from public.processos where status in ('ativo', 'pausado');

-- ---------------------------------------------------------------------
-- 5. Encerrar sem ordem (resultado + motivo)
-- ---------------------------------------------------------------------
alter table public.processos add column if not exists resultado text;
alter table public.processos add column if not exists motivo_encerramento text;
do $$ begin
  alter table public.processos add constraint processos_resultado_check check (resultado in ('deu_preco', 'nao_deu_preco'));
exception when duplicate_object then null; end $$;

create or replace function public.encerrar_sem_ordem(p_processo_id uuid, p_resultado text, p_motivo text, p_obs text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  perform public.pc_exigir_processo(p_processo_id);   -- confere permissão e liga pc.rpc
  select status into v_status from public.processos where id = p_processo_id for update;
  if v_status is distinct from 'ativo' then raise exception 'Só dá para encerrar um processo ativo'; end if;
  if p_resultado is null or p_resultado not in ('deu_preco', 'nao_deu_preco') then raise exception 'Resultado inválido'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo'; end if;

  update public.processo_etapas set status = 'concluida', concluido_em = now(), concluido_por = auth.uid()
   where processo_id = p_processo_id and status = 'em_andamento';
  update public.processos
     set status = 'concluido', concluido_em = now(), resultado = p_resultado, motivo_encerramento = trim(p_motivo)
   where id = p_processo_id;

  insert into public.processo_eventos (processo_id, tipo, texto)
  values (p_processo_id, 'status',
          'Encerrado sem ordem (' || case p_resultado when 'deu_preco' then 'deu preço' else 'não deu preço' end || '): ' || trim(p_motivo)
          || coalesce(E'\n' || nullif(trim(p_obs), ''), ''));
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.encerrar_sem_ordem(uuid, text, text, text) to authenticated;

-- reabrir (admin) limpa o resultado do encerramento
create or replace function public.retornar_etapa(p_processo_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_concluido boolean;
begin
  v_concluido := exists (select 1 from public.processos where id = p_processo_id and status = 'concluido');
  if v_concluido then
    if not public.is_admin() then raise exception 'Só um administrador pode reabrir um processo concluído'; end if;
    perform set_config('pc.rpc', 'on', true);
  else
    perform public.pc_exigir_processo(p_processo_id);
  end if;
  perform public.retornar_processo(p_processo_id, p_motivo);
  if v_concluido then
    update public.processos set resultado = null, motivo_encerramento = null where id = p_processo_id;
  end if;
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.retornar_etapa(uuid, text) to authenticated;

notify pgrst, 'reload schema';
