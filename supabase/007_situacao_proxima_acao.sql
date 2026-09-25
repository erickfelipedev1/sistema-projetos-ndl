-- =====================================================================
-- 007 — Situação da etapa ("por que está parado") e próxima ação
-- Rodar DEPOIS do 001–006. Pode rodar mais de uma vez.
-- =====================================================================

-- texto livre da etapa atual, ex.: "aguardando confirmação do fornecedor"
alter table public.processo_etapas add column if not exists situacao text;

create index if not exists processo_eventos_recentes_idx on public.processo_eventos (created_at desc);

-- view: + situação, próxima ação (1º item pendente do checklist) e última atualização
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada,
       p.certificacao,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id) as checklist_total,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id and c.feito) as checklist_feitos,
       p.gerenciamento,
       pe.situacao,
       (select c.titulo from public.processo_checklist c
         where c.processo_etapa_id = pe.id and not c.feito order by c.ordem limit 1) as proxima_acao,
       greatest(pe.iniciado_em,
                (select max(ev.created_at) from public.processo_eventos ev where ev.processo_id = p.id),
                (select max(c.feito_em) from public.processo_checklist c where c.processo_etapa_id = pe.id)) as ultima_atualizacao,
       p.contato
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';
