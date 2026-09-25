-- =====================================================================
-- 020 — Completa o checklist das etapas de Ordem/Produção/Viagem com os
-- passos que existem no quadro "Ordens" do Monday mas não existiam no
-- sistema (documentação da fábrica, auditoria, chegada no Brasil).
-- Rodar DEPOIS do 001–019.
-- =====================================================================

do $$
declare
  v_ordem_etapa int;
  v_chegou int;
begin
  select id into v_ordem_etapa from public.etapas where nome = 'Processo / Ordem / Pagamento';
  select id into v_chegou from public.etapas where nome = 'Chegou';

  if v_ordem_etapa is not null then
    insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
    select v_ordem_etapa, 15, 'Documentação e verificação',
           'Documentação da fábrica conferida logo após o recebimento da ordem.'
    where not exists (select 1 from public.checklist_modelo where etapa_id = v_ordem_etapa and ordem = 15);

    insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
    select v_ordem_etapa, 25, 'Auditoria de fábrica',
           'Auditoria do fornecedor/fábrica antes de seguir com a produção.'
    where not exists (select 1 from public.checklist_modelo where etapa_id = v_ordem_etapa and ordem = 25);

    perform public.sincronizar_checklist(pe.processo_id)
      from public.processo_etapas pe
     where pe.etapa_id = v_ordem_etapa and pe.status <> 'concluida';
  end if;

  if v_chegou is not null then
    insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
    select v_chegou, 10, 'Chegada no Brasil confirmada',
           'Confirmação de que a carga chegou no Brasil.'
    where not exists (select 1 from public.checklist_modelo where etapa_id = v_chegou and ordem = 10);

    perform public.sincronizar_checklist(pe.processo_id)
      from public.processo_etapas pe
     where pe.etapa_id = v_chegou and pe.status <> 'concluida';
  end if;
end $$;

notify pgrst, 'reload schema';
