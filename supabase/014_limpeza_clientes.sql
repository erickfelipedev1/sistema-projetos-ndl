-- =====================================================================
-- 014 — Limpeza de clientes criados manualmente antes da importação do Monday
-- Este arquivo é uma FERRAMENTA, não uma migração — rode só a parte 1 primeiro,
-- confira a lista, aí ajuste e rode a parte 2. Não faz parte do 000_tudo.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PARTE 1 — CONFERIR: lista todo cliente que NÃO tem nenhum processo vindo
-- do Monday (ou seja, não apareceu na importação), com quantos processos
-- ele tem hoje. É bom candidato a "cliente de teste" se:
--   - processos = 0  →  não tem nada vinculado, seguro remover
--   - processos > 0 mas nenhum tem "vindo do monday" = sim → provavelmente
--     um cadastro manual/teste que você fez antes de eu importar a planilha
-- ---------------------------------------------------------------------
select
  c.id,
  c.nome,
  c.cnpj,
  c.contato,
  c.created_at,
  count(p.id) as processos,
  count(p.id) filter (where p.monday_id is not null) as processos_do_monday
from public.clientes c
left join public.processos p on p.cliente_id = c.id
group by c.id, c.nome, c.cnpj, c.contato, c.created_at
having count(p.id) filter (where p.monday_id is not null) = 0
order by c.created_at asc;

-- ---------------------------------------------------------------------
-- PARTE 2 — REMOVER: depois de olhar a lista acima, cole aqui os IDs
-- (coluna "id") dos clientes que são mesmo de teste/antes do Monday e
-- rode este bloco. Ele apaga primeiro os processos desses clientes —
-- o que já leva junto (por cascata do banco) etapas, checklist,
-- eventos e anexos desses processos — e só depois o cliente (o que
-- também já leva junto, por cascata, os anexos soltos do cliente).
-- Mensagem de chat que citava algum desses processos não é apagada,
-- só perde o link (fica sem "processo relacionado").
--
-- NÃO mexe em nenhum cliente/processo que veio do Monday nem em
-- cliente que não estiver na lista de IDs.
--
-- Troque os IDs de exemplo abaixo pelos que você quer apagar (pegue
-- da coluna "id" do resultado da Parte 1).
-- ---------------------------------------------------------------------
/*
do $$
declare
  v_ids uuid[] := array[
    'COLE-AQUI-O-ID-1',
    'COLE-AQUI-O-ID-2'
  ]::uuid[];
begin
  delete from public.processos where cliente_id = any(v_ids);
  delete from public.clientes where id = any(v_ids);
end $$;
*/
