-- =====================================================================
-- 031 — Direcionar projeto (aba Sourcing): a coordenação escolhe quem conduz cada projeto
-- Rodar DEPOIS do 001–030. Pode rodar mais de uma vez.
--
-- direcionar_projeto(processo, pessoa):
--   • define a pessoa como responsável da etapa Projeto do processo;
--   • passa para ela os itens do checklist ainda não feitos que não têm responsável
--     fixo no modelo (os de Agenciamento e da estimativa seguem com os responsáveis
--     do modelo);
--   • registra no histórico e manda uma demanda no chat para a pessoa (aparece em
--     Minhas tarefas › Demandas para você), com o prazo da etapa.
-- Permissão: a mesma de alterar o processo (administrador, responsável da etapa ou
-- quem tem o cargo da área — em Projeto, o time de Projetos).
-- =====================================================================

create or replace function public.direcionar_projeto(p_processo_id uuid, p_responsavel uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_pe public.processo_etapas;
  v_proc public.processos;
  v_nome text;
  v_autor uuid := auth.uid();
begin
  perform public.pc_exigir_processo(p_processo_id);   -- confere permissão e liga pc.rpc

  select * into v_proc from public.processos where id = p_processo_id;
  select pe.* into v_pe from public.processo_etapas pe
    join public.etapas e on e.id = pe.etapa_id
   where pe.processo_id = p_processo_id and pe.status = 'em_andamento'
     and e.nome = 'Projeto (Flex / Premium / Full)';
  if v_pe.id is null then raise exception 'O processo não está na etapa de Projeto'; end if;

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

notify pgrst, 'reload schema';
