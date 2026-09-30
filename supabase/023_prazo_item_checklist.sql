-- =====================================================================
-- 023 — Cada item de checklist passa a ter uma data de prazo própria,
-- editável dentro do processo (adiantar ou atrasar item por item, sem
-- afetar outros processos). O prazo padrão de cada item (em dias úteis,
-- editável em Configurações > Checklist) continua existindo e é usado
-- só para calcular a demanda no chat quando o item é liberado — este
-- prazo_em é a data que a equipe pode ajustar manualmente na tela do
-- processo. Rodar DEPOIS do 001–022.
-- =====================================================================

alter table public.processo_checklist add column if not exists prazo_em date;

notify pgrst, 'reload schema';
