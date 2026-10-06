-- =====================================================================
-- 027 — Prazos dos itens do checklist de Projeto por plano (Flex / Full / Premium)
-- Fonte: imagens "Organização das datas para cada tarefa" (Sourcing Flex,
-- Full e Premium). Rodar DEPOIS do 001–026. Pode rodar mais de uma vez.
--
-- Como funciona: cada item do modelo ganha "dias úteis" por plano. Quando a
-- etapa Projeto começa num processo, a data de cada item (prazo_em) é a data
-- de início + a soma dos dias dos itens até ele (em dias úteis, sem feriados).
-- Itens de um mesmo bloco da imagem (ex.: busca por fornecedores, ou envio da
-- apresentação + reunião) vencem juntos: os dias ficam no primeiro item do
-- bloco e os demais têm 0. Só afeta processos NOVOS (ou etapas que começam
-- depois deste SQL); itens já marcados como feitos nunca são alterados.
-- =====================================================================

alter table public.checklist_modelo add column if not exists dias_flex int;
alter table public.checklist_modelo add column if not exists dias_full int;
alter table public.checklist_modelo add column if not exists dias_premium int;

-- ---------------------------------------------------------------------
-- Dias por item (etapa Projeto), por "ordem" do modelo
--   ordem  tarefa da imagem                                    flex full prem
--    10    Recebimento do projeto + Montagem das referências     1    1    1
--    20    Busca por fornecedores (20, 30 e 40 vencem juntos) 9   10   15
--    50    Escolha dos fornecedores (envio dos catálogos)        1    1    1
--    60    Montagem da apresentação                              1    1    2
--    70    Envio da apresentação + Reunião de sourcing (70, 80, 90)   2    2    2
--   100    Solicitação de PI e PL                                1    1    1
--   110    Solicitação de frete internacional (110, 115)          1    2    1
--   120    Solicitação de frete rodoviário (120, 125)            1    1    1
--   130    Solicitação de estimativa de custos                   1    1    1
--   140    Montagem da estimativa (sobra até o total da imagem)  3    3    6
--   145–160 verificações da estimativa                           1    1    1  (cada)
-- Total acumulado: Flex 25 · Full 27 · Premium 35 (= "Total de dias" das imagens)
-- ---------------------------------------------------------------------
with d(ordem, f, u, p) as (values
  (10, 1, 1, 1), (20, 9, 10, 15), (30, 0, 0, 0), (40, 0, 0, 0),
  (50, 1, 1, 1), (60, 1, 1, 2), (70, 2, 2, 2), (80, 0, 0, 0), (90, 0, 0, 0),
  (100, 1, 1, 1), (110, 1, 2, 1), (115, 0, 0, 0),
  (120, 1, 1, 1), (125, 0, 0, 0), (130, 1, 1, 1),
  (140, 3, 3, 6), (145, 1, 1, 1), (150, 1, 1, 1), (155, 1, 1, 1), (160, 1, 1, 1))
update public.checklist_modelo m
   set dias_flex = d.f, dias_full = d.u, dias_premium = d.p
  from d, public.etapas e
 where m.etapa_id = e.id and e.nome = 'Projeto (Flex / Premium / Full)' and m.ordem = d.ordem;

-- prazo total da etapa Projeto por plano (vale para processos novos)
update public.etapas set prazo_flex = 25, prazo_full = 27, prazo_premium = 35
 where nome = 'Projeto (Flex / Premium / Full)';

-- ---------------------------------------------------------------------
-- Calcula a data de cada item quando a etapa começa
-- ---------------------------------------------------------------------
create or replace function public.pc_prazos_itens(p_pe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_plano text; v_ini date;
begin
  select p.plano, (coalesce(pe.iniciado_em, now()) at time zone 'America/Sao_Paulo')::date
    into v_plano, v_ini
    from public.processo_etapas pe join public.processos p on p.id = pe.processo_id
   where pe.id = p_pe_id;
  if v_plano is null or v_ini is null then return; end if;

  update public.processo_checklist c
     set prazo_em = public.add_dias_uteis(v_ini, x.acum)
    from (
      select c2.id,
             (sum(case v_plano when 'Flex' then m.dias_flex when 'Full' then m.dias_full else m.dias_premium end)
                over (order by c2.ordem, c2.id))::int as acum
        from public.processo_checklist c2
        join public.checklist_modelo m on m.id = c2.modelo_id
       where c2.processo_etapa_id = p_pe_id
         and case v_plano when 'Flex' then m.dias_flex when 'Full' then m.dias_full else m.dias_premium end is not null
    ) x
   where c.id = x.id and not c.feito;
end $$;
revoke all on function public.pc_prazos_itens(uuid) from public, anon, authenticated;

create or replace function public.pc_tg_prazos_itens()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.pc_prazos_itens(new.id);
  return null;
end $$;

drop trigger if exists pc_etapa_prazos_itens on public.processo_etapas;
create trigger pc_etapa_prazos_itens
  after update of status on public.processo_etapas
  for each row when (new.status = 'em_andamento' and old.status is distinct from 'em_andamento')
  execute function public.pc_tg_prazos_itens();

notify pgrst, 'reload schema';
