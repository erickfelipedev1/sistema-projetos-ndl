-- =====================================================================
-- 017 — Detalha o checklist de Projeto com os passos de verificação da
-- estimativa que existem no Monday mas não existiam no sistema (a devolutiva
-- de verificação e o envio final para o Matheus). Rodar DEPOIS do 001–016.
-- =====================================================================

do $$
declare
  v_proj int;
  v_resp uuid[];
  v_label text;
begin
  select id into v_proj from public.etapas where nome = 'Projeto (Flex / Premium / Full)';
  if v_proj is null then return; end if;

  -- mesmo responsável do item 140 (Montagem da estimativa)
  select responsaveis, responsaveis_label into v_resp, v_label
    from public.checklist_modelo where etapa_id = v_proj and ordem = 140;
  v_label := coalesce(v_label, 'Alycia');

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 145, '15º Verificação da estimativa de custos',
         'Conferência da estimativa montada antes de devolver para quem solicitou.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 145);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 150, '16º Devolutiva da verificação da estimativa',
         'Devolutiva de quem verificou para quem montou a estimativa, com ajustes se precisar.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 150);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 155, '17º Verificação da devolutiva',
         'Última conferência depois da devolutiva, antes de fechar a estimativa.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 155);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 160, '18º Envio da estimativa de custos para o Matheus',
         'Estimativa fechada e enviada para o Matheus.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 160);

  -- processos com a etapa de Projeto ainda não concluída recebem os itens novos
  perform public.sincronizar_checklist(pe.processo_id)
    from public.processo_etapas pe
   where pe.etapa_id = v_proj and pe.status <> 'concluida';
end $$;

notify pgrst, 'reload schema';
