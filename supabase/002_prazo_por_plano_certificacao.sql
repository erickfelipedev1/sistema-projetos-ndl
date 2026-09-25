-- =====================================================================
-- 002 — Fluxo v2: prazo por plano, certificação e nova etapa
-- Rodar DEPOIS do 001, no SQL Editor do Supabase. Pode rodar mais de uma vez.
-- =====================================================================

-- Prazos específicos por plano e com certificação (vazio = usa o prazo padrão)
alter table public.etapas add column if not exists prazo_flex int;
alter table public.etapas add column if not exists prazo_full int;
alter table public.etapas add column if not exists prazo_premium int;
alter table public.etapas add column if not exists prazo_com_certificacao int;

alter table public.processos add column if not exists certificacao boolean not null default false;

-- prazo efetivo de uma etapa para um processo
create or replace function public.prazo_etapa(e public.etapas, p_plano text, p_certificacao boolean)
returns int language sql stable as $$
  select case
    when p_certificacao and e.prazo_com_certificacao is not null then e.prazo_com_certificacao
    when p_plano = 'Flex'    and e.prazo_flex    is not null then e.prazo_flex
    when p_plano = 'Full'    and e.prazo_full    is not null then e.prazo_full
    when p_plano = 'Premium' and e.prazo_premium is not null then e.prazo_premium
    else e.prazo_dias_uteis
  end
$$;

-- ---------------------------------------------------------------------
-- Criação de processo (substitui a versão do 001)
-- ---------------------------------------------------------------------
drop function if exists public.criar_processo(text, text, text);

create or replace function public.criar_processo(
  p_cliente text, p_plano text, p_descricao text default null, p_certificacao boolean default false
) returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_primeira uuid;
  v_cert boolean := coalesce(p_certificacao, false);
begin
  if coalesce(trim(p_cliente), '') = '' then
    raise exception 'Informe o cliente';
  end if;

  insert into public.processos (cliente, plano, descricao, certificacao)
  values (trim(p_cliente), nullif(p_plano, ''), nullif(trim(p_descricao), ''), v_cert)
  returning id into v_id;

  insert into public.processo_etapas
    (processo_id, etapa_id, ordem, area, nome, tipo, prazo_dias_uteis, prazo_editavel, responsaveis, responsaveis_label)
  select v_id, e.id, row_number() over (order by e.ordem, e.id), e.area, e.nome, e.tipo,
         public.prazo_etapa(e, nullif(p_plano, ''), v_cert), e.prazo_editavel, e.responsaveis_padrao, e.responsaveis_label
  from public.etapas e
  where e.ativo;

  select id into v_primeira from public.processo_etapas where processo_id = v_id order by ordem limit 1;
  if v_primeira is null then
    raise exception 'Nenhuma etapa ativa configurada';
  end if;

  perform public.pc_iniciar_etapa(v_primeira);
  insert into public.processo_eventos (processo_id, tipo, texto) values (v_id, 'criado', 'Processo criado');
  return v_id;
end $$;

grant execute on function public.criar_processo(text, text, text, boolean) to authenticated;

-- Recalcula prazos quando o plano ou a certificação do processo mudam
-- (etapas pendentes e a etapa em andamento; etapas concluídas não mudam)
create or replace function public.recalcular_prazos(p_processo_id uuid)
returns void language plpgsql as $$
declare
  v_plano text;
  v_cert boolean;
begin
  select plano, certificacao into v_plano, v_cert from public.processos where id = p_processo_id;

  update public.processo_etapas pe
     set prazo_dias_uteis = public.prazo_etapa(e, v_plano, v_cert)
    from public.etapas e
   where pe.etapa_id = e.id
     and pe.processo_id = p_processo_id
     and pe.status <> 'concluida';

  update public.processo_etapas pe
     set prazo_em = public.add_dias_uteis((pe.iniciado_em at time zone 'America/Sao_Paulo')::date, pe.prazo_dias_uteis)
   where pe.processo_id = p_processo_id
     and pe.status = 'em_andamento'
     and not pe.prazo_editavel;
end $$;

grant execute on function public.recalcular_prazos(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Views (colunas novas no final)
-- ---------------------------------------------------------------------
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada,
       p.certificacao
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';

drop view if exists public.v_desempenho_etapas;
create view public.v_desempenho_etapas with (security_invoker = true) as
select e.id as etapa_id, e.ordem, e.area, e.nome, e.tipo, e.prazo_dias_uteis,
       count(pe.id) filter (where pe.status = 'concluida' and pe.tipo = 'tarefa')::int as concluidas,
       round(avg(public.dias_uteis_entre((pe.iniciado_em at time zone 'America/Sao_Paulo')::date,
                                         (pe.concluido_em at time zone 'America/Sao_Paulo')::date))
             filter (where pe.status = 'concluida' and pe.tipo = 'tarefa'), 1) as media_dias_uteis,
       count(pe.id) filter (where pe.status = 'concluida' and pe.prazo_em is not null
                              and (pe.concluido_em at time zone 'America/Sao_Paulo')::date > pe.prazo_em)::int as concluidas_com_atraso,
       count(pe.id) filter (where pe.status = 'em_andamento' and p.status = 'ativo')::int as em_andamento,
       count(pe.id) filter (where pe.status = 'em_andamento' and p.status = 'ativo'
                              and pe.prazo_em < public.hoje_br())::int as atrasadas_agora,
       e.prazo_flex, e.prazo_full, e.prazo_premium, e.prazo_com_certificacao
from public.etapas e
left join public.processo_etapas pe on pe.etapa_id = e.id
left join public.processos p on p.id = pe.processo_id
where e.ativo
group by e.id
order by e.ordem;

-- ---------------------------------------------------------------------
-- Atualiza o fluxo para o novo fluxograma
-- ---------------------------------------------------------------------
update public.etapas set ordem = 1, nome = 'Apresentação / Montagem do projeto (planilha)', prazo_dias_uteis = 1
 where area = 'CS' and nome in ('Apresentação', 'Apresentação / Montagem do projeto (planilha)');

update public.etapas set ordem = 2, prazo_dias_uteis = 25, prazo_flex = 10, prazo_full = 15, prazo_premium = 25
 where nome = 'Projeto (Flex / Premium / Full)';

update public.etapas set ordem = 3, prazo_dias_uteis = 1, prazo_com_certificacao = 2
 where nome = 'Cotação de frete';

update public.etapas set ordem = 4, prazo_dias_uteis = 2
 where nome = 'Estimativa de custo';

insert into public.etapas (ordem, area, nome, tipo, prazo_dias_uteis, responsaveis_label)
select 5, 'CS', 'Apresentação da estimativa', 'tarefa', 1, 'Larissa'
where not exists (select 1 from public.etapas where nome = 'Apresentação da estimativa');

update public.etapas set ordem = 6  where nome = 'Processo / Ordem / Pagamento';
update public.etapas set ordem = 7  where nome = 'Booking + Coleta + Estufagem';
update public.etapas set ordem = 8  where nome = 'Viagem';
update public.etapas set ordem = 9  where nome = 'Desembaraço';
update public.etapas set ordem = 10 where nome = 'Liberado';
update public.etapas set ordem = 11 where nome = 'Transporte';
update public.etapas set ordem = 12 where nome = 'Chegou';
