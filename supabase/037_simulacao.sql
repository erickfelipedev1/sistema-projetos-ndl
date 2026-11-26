-- =====================================================================
-- 037 — Estimativa de custos passa a se chamar SIMULAÇÃO + plano "Simulação" (14 dias úteis)
-- Rodar DEPOIS do 036. Pode rodar mais de uma vez.
--
--   1. Plano novo "Simulação", ao lado de Flex / Full / Premium: para o cliente que já tem
--      fornecedor e só quer a simulação. O processo pula o sourcing: o Projeto tem só os
--      6 passos da simulação e vence em 14 dias úteis.
--   2. Os 6 passos da simulação (valem nos 4 planos), no lugar dos passos 11º–17º:
--        Recebimento da solicitação · Cotação de frete internacional · Cotação de frete
--        rodoviário · Montagem · Verificação (NLG) · Envio ao CS
--      Dias úteis no plano Simulação: 1 · 2 · 1 · 6 · 2 · 2 = 14.
--      Nos planos de sourcing o Projeto continua com 25 / 27 / 35 dias úteis (os dias dos
--      passos antigos foram somados nos passos novos).
--      Itens já marcados como feitos em processos em andamento mantêm o título antigo.
--   3. "Estimativa" vira "Simulação" nos nomes: etapa "Apresentação da simulação",
--      checklist e modelos de e-mail.
--   4. Mudar o plano de um processo refaz o checklist das etapas ainda não concluídas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Plano Simulação
-- ---------------------------------------------------------------------
alter table public.processos drop constraint if exists processos_plano_check;
alter table public.processos add constraint processos_plano_check
  check (plano in ('Flex', 'Premium', 'Full', 'Simulação'));

alter table public.etapas add column if not exists prazo_simulacao int;
alter table public.checklist_modelo add column if not exists dias_simulacao int;
-- planos em que o item aparece (null = em todos)
alter table public.checklist_modelo add column if not exists planos text[];

update public.etapas set prazo_simulacao = 14
 where nome = 'Projeto (Flex / Premium / Full)' and prazo_simulacao is null;

create or replace function public.prazo_etapa(e public.etapas, p_plano text, p_certificacao boolean)
returns int language sql stable as $$
  select case
    when p_certificacao and e.prazo_com_certificacao is not null then e.prazo_com_certificacao
    when p_plano = 'Flex'      and e.prazo_flex      is not null then e.prazo_flex
    when p_plano = 'Full'      and e.prazo_full      is not null then e.prazo_full
    when p_plano = 'Premium'   and e.prazo_premium   is not null then e.prazo_premium
    when p_plano = 'Simulação' and e.prazo_simulacao is not null then e.prazo_simulacao
    else e.prazo_dias_uteis
  end
$$;

-- o item vale para o processo? (gerenciamento e plano)
create or replace function public.pc_item_vale(m public.checklist_modelo, p_ger text, p_plano text)
returns boolean language sql immutable as $$
  select (m.condicao is null or m.condicao = p_ger)
     and (m.planos is null or p_plano is null or p_plano = any(m.planos))
$$;

create or replace function public.pc_copiar_checklist()
returns trigger language plpgsql as $$
declare v_ger text; v_plano text;
begin
  if new.etapa_id is not null then
    select gerenciamento, plano into v_ger, v_plano from public.processos where id = new.processo_id;
    insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
    select new.id, m.id, m.ordem, m.titulo, m.descricao, m.aguarda_cliente, m.prazo_depois
      from public.checklist_modelo m
     where m.etapa_id = new.etapa_id and m.ativo and public.pc_item_vale(m, v_ger, v_plano)
    on conflict do nothing;
  end if;
  return new;
end $$;

create or replace function public.sincronizar_checklist(p_processo_id uuid)
returns void language plpgsql as $$
declare v_ger text; v_plano text;
begin
  select gerenciamento, plano into v_ger, v_plano from public.processos where id = p_processo_id;

  delete from public.processo_checklist c
   using public.processo_etapas pe, public.checklist_modelo m
   where c.processo_etapa_id = pe.id and c.modelo_id = m.id
     and pe.processo_id = p_processo_id and pe.status <> 'concluida'
     and not c.feito
     and (not public.pc_item_vale(m, v_ger, v_plano) or not m.ativo);

  insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
  select pe.id, m.id, m.ordem, m.titulo, m.descricao, m.aguarda_cliente, m.prazo_depois
    from public.processo_etapas pe
    join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
   where pe.processo_id = p_processo_id and pe.status <> 'concluida'
     and public.pc_item_vale(m, v_ger, v_plano)
  on conflict do nothing;
end $$;

-- data de cada item quando a etapa começa (agora com o plano Simulação)
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
             (sum(case v_plano when 'Flex' then m.dias_flex when 'Full' then m.dias_full
                               when 'Simulação' then m.dias_simulacao else m.dias_premium end)
                over (order by c2.ordem, c2.id))::int as acum
        from public.processo_checklist c2
        join public.checklist_modelo m on m.id = c2.modelo_id and (m.ativo or c2.feito)
       where c2.processo_etapa_id = p_pe_id
         and case v_plano when 'Flex' then m.dias_flex when 'Full' then m.dias_full
                          when 'Simulação' then m.dias_simulacao else m.dias_premium end is not null
    ) x
   where c.id = x.id and not c.feito;
end $$;
revoke all on function public.pc_prazos_itens(uuid) from public, anon, authenticated;

-- simulação não tem segmentos de sourcing
create or replace function public.pc_garantir_segmentos(p_processo_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_plano text; v_seg int; v_forn int;
begin
  select plano into v_plano from public.processos where id = p_processo_id;
  if v_plano is null or v_plano = 'Simulação' then return; end if;
  v_seg  := case v_plano when 'Premium' then 6 else 1 end;
  v_forn := case v_plano when 'Premium' then 12 when 'Full' then 3 else 1 end;
  insert into public.processo_segmentos (processo_id, ordem, nome, meta_fornecedores)
  select p_processo_id, g, 'Segmento ' || g, v_forn / v_seg
    from generate_series(1, v_seg) g
  on conflict (processo_id, ordem) do nothing;
end $$;
revoke all on function public.pc_garantir_segmentos(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Mudou o plano: refaz o checklist (sourcing entra/sai) e as datas dos itens em andamento
--    (o prazo da etapa é recalculado pelo app logo em seguida, em recalcular_prazos_seguro)
-- ---------------------------------------------------------------------
create or replace function public.pc_tg_plano_checklist()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  perform public.sincronizar_checklist(new.id);
  for r in select id from public.processo_etapas where processo_id = new.id and status = 'em_andamento' loop
    perform public.pc_prazos_itens(r.id);
  end loop;
  return null;
end $$;
revoke all on function public.pc_tg_plano_checklist() from public, anon, authenticated;

drop trigger if exists pc_processo_plano_checklist on public.processos;
create trigger pc_processo_plano_checklist
  after update of plano on public.processos
  for each row when (new.plano is distinct from old.plano)
  execute function public.pc_tg_plano_checklist();

-- ---------------------------------------------------------------------
-- 2. Os 6 passos da simulação no checklist do Projeto (só na primeira vez;
--    depois vale o que for ajustado em Configurações)
-- ---------------------------------------------------------------------
do $$
declare v_proj int;
begin
  select id into v_proj from public.etapas where nome = 'Projeto (Flex / Premium / Full)';
  if v_proj is null then return; end if;
  if exists (select 1 from public.checklist_modelo where etapa_id = v_proj and titulo like 'Simulação · %') then return; end if;

  -- passos do sourcing (antes da simulação): só nos planos de sourcing
  update public.checklist_modelo set planos = array['Flex', 'Full', 'Premium']
   where etapa_id = v_proj and ordem < 110;

  -- passos da simulação (ordem, título, descrição, responsável, dias flex/full/premium/simulação)
  update public.checklist_modelo m set
         titulo = v.titulo, descricao = v.descricao, ativo = true, planos = null,
         responsaveis = '{}', responsaveis_label = v.resp,
         dias_flex = v.f, dias_full = v.u, dias_premium = v.p, dias_simulacao = v.s
    from (values
      (110, 'Simulação · Recebimento da solicitação',
            E'• Receber a solicitação com PI e PL: Incoterm (se EXW, endereço da fábrica), porto de saída, peso bruto e líquido, volumes, caixas e dimensões, CBM, HS Code e valor da carga.\n• Conferir se falta alguma informação antes de pedir as cotações.',
            'Alycia', 1, 2, 1, 1),
      (115, 'Simulação · Cotação de frete internacional (Agenciamento)',
            'Agenciamento recebe a solicitação e devolve a cotação do frete internacional.',
            'Isabella / Cris', 1, 1, 1, 2),
      (125, 'Simulação · Cotação de frete rodoviário (Agenciamento)',
            'Agenciamento devolve a cotação do frete rodoviário.',
            'Isabella / Cris', 1, 1, 1, 1),
      (140, 'Simulação · Montagem',
            'Montar a planilha da simulação com as cotações de frete e enviar para a verificação da NLG.',
            'Alycia', 3, 3, 6, 6),
      (145, 'Simulação · Verificação pela NLG',
            E'• NCM dos produtos\n• Alíquotas e impostos aplicáveis\n• Necessidade de anuências\n• Necessidade de certificações\n• Valores e demais custos da importação',
            'Marta / Josivaldo / Ysabella', 2, 2, 2, 2),
      (160, 'Simulação · Envio ao Fernando (CS)',
            'Consolidar a devolutiva da NLG e encaminhar a simulação ao Fernando, do CS, para a apresentação ao cliente.',
            'Alycia', 2, 2, 2, 2)
    ) as v(ordem, titulo, descricao, resp, f, u, p, s)
   where m.etapa_id = v_proj and m.ordem = v.ordem;

  -- passos antigos que foram juntados nos novos
  update public.checklist_modelo set ativo = false
   where etapa_id = v_proj and ordem in (120, 130, 150, 155);
end $$;

-- prazo total do Projeto nos planos de sourcing continua 25 / 27 / 35 = soma dos itens

-- ---------------------------------------------------------------------
-- 3. "Estimativa" → "Simulação"
-- ---------------------------------------------------------------------
update public.etapas set nome = 'Apresentação da simulação' where nome = 'Apresentação da estimativa';
update public.processo_etapas set nome = 'Apresentação da simulação' where nome = 'Apresentação da estimativa';

-- funções que procuram a etapa pelo nome (recotação e importações)
do $$
declare r record; d text;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.prosrc like '%Apresentação da estimativa%'
  loop
    d := replace(pg_get_functiondef(r.oid), 'Apresentação da estimativa', 'Apresentação da simulação');
    execute d;
  end loop;
end $$;

-- textos do checklist e dos e-mails
update public.checklist_modelo
   set titulo = replace(replace(replace(titulo, 'estimativa de custos', 'simulação'), 'estimativa', 'simulação'), 'Estimativa', 'Simulação'),
       descricao = replace(replace(replace(descricao, 'estimativa de custos', 'simulação'), 'estimativa', 'simulação'), 'Estimativa', 'Simulação')
 where titulo ilike '%estimativa%' or descricao ilike '%estimativa%';

update public.email_modelos
   set titulo = replace(replace(replace(titulo, 'estimativa de custos', 'simulação'), 'estimativa', 'simulação'), 'Estimativa', 'Simulação'),
       assunto = replace(replace(replace(assunto, 'estimativa de custos', 'simulação'), 'estimativa', 'simulação'), 'Estimativa', 'Simulação'),
       corpo = replace(replace(replace(corpo, 'estimativa de custos', 'simulação'), 'estimativa', 'simulação'), 'Estimativa', 'Simulação')
 where titulo ilike '%estimativa%' or assunto ilike '%estimativa%' or corpo ilike '%estimativa%';

-- leva títulos e descrições novos para os itens ainda não feitos (feitos guardam o histórico)
update public.processo_checklist c
   set titulo = m.titulo, descricao = m.descricao
  from public.checklist_modelo m, public.processo_etapas pe
 where c.modelo_id = m.id and pe.id = c.processo_etapa_id and pe.status <> 'concluida' and not c.feito
   and (c.titulo is distinct from m.titulo or c.descricao is distinct from m.descricao);

-- tira os passos juntados de quem ainda não os marcou e cria os que faltarem
select public.sincronizar_checklist(id) from public.processos where status in ('ativo', 'pausado');

notify pgrst, 'reload schema';
