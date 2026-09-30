-- =====================================================================
-- 010 — Cotação de frete e Estimativa de custo passam a ser itens do
--        checklist de Projetos (o prazo 10/15/25 já inclui tudo).
--        Itens do checklist podem ter responsáveis: quando o item anterior
--        é marcado, eles recebem uma DEMANDA automática no chat.
-- Rodar DEPOIS do 001–009 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- =====================================================================

-- responsáveis e prazo por item do checklist
alter table public.checklist_modelo add column if not exists responsaveis uuid[] not null default '{}';
alter table public.checklist_modelo add column if not exists responsaveis_label text;
alter table public.checklist_modelo add column if not exists prazo_item int;        -- dias úteis para o responsável
alter table public.checklist_modelo add column if not exists prazo_item_cert int;   -- idem, com certificação
alter table public.processo_checklist add column if not exists avisado_em timestamptz;

-- mensagem de demanda ligada a um item de checklist (concluir um conclui o outro)
alter table public.mensagens add column if not exists checklist_id uuid references public.processo_checklist(id) on delete set null;
create index if not exists mensagens_checklist_idx on public.mensagens (checklist_id);

-- ---------------------------------------------------------------------
-- Quem é avisado por um item: ids do modelo; se vazio, pelos nomes do rótulo
-- ---------------------------------------------------------------------
create or replace function public.pc_item_responsaveis(p_modelo_id int)
returns uuid[] language sql stable security definer set search_path = public as $$
  select case when coalesce(array_length(m.responsaveis, 1), 0) > 0 then m.responsaveis
         else coalesce((
           select array_agg(p.id) from public.profiles p
            where p.tipo = 'equipe' and m.responsaveis_label is not null
              and public.pc_normaliza(split_part(trim(p.nome), ' ', 1)) in (
                select trim(x) from regexp_split_to_table(public.pc_normaliza(m.responsaveis_label), '\s*[/,;&]\s*|\s+e\s+') x)
         ), '{}') end
  from public.checklist_modelo m where m.id = p_modelo_id
$$;

-- conversa direta entre duas pessoas (sem depender de quem está logado)
create or replace function public.pc_conversa_entre(p_a uuid, p_b uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if p_a = p_b then
    select id into v from public.conversas where tipo = 'canal' order by created_at limit 1;
    return v;
  end if;
  select c.id into v from public.conversas c
   where c.tipo = 'direta'
     and exists (select 1 from public.conversa_membros m where m.conversa_id = c.id and m.user_id = p_a)
     and exists (select 1 from public.conversa_membros m where m.conversa_id = c.id and m.user_id = p_b)
   limit 1;
  if v is null then
    insert into public.conversas (tipo) values ('direta') returning id into v;
    insert into public.conversa_membros values (v, p_a), (v, p_b);
  end if;
  return v;
end $$;

-- manda a demanda para os responsáveis do item (uma vez só)
create or replace function public.pc_avisar_item(p_item uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  it public.processo_checklist;
  pe public.processo_etapas;
  pr public.processos;
  m public.checklist_modelo;
  v_para uuid[];
  v_autor uuid;
  v_prazo int;
  r uuid;
  n int := 0;
begin
  select * into it from public.processo_checklist where id = p_item;
  if it.id is null or it.feito or it.avisado_em is not null or it.modelo_id is null then return 0; end if;
  select * into pe from public.processo_etapas where id = it.processo_etapa_id;
  if pe.status <> 'em_andamento' then return 0; end if;
  select * into pr from public.processos where id = pe.processo_id;
  if pr.status <> 'ativo' then return 0; end if;
  select * into m from public.checklist_modelo where id = it.modelo_id;
  v_para := public.pc_item_responsaveis(it.modelo_id);
  if coalesce(array_length(v_para, 1), 0) = 0 then return 0; end if;

  v_autor := coalesce(auth.uid(), pe.responsaveis[1], v_para[1]);
  v_prazo := case when pr.certificacao and m.prazo_item_cert is not null then m.prazo_item_cert else m.prazo_item end;

  foreach r in array v_para loop
    insert into public.mensagens (conversa_id, autor, texto, processo_id, demanda_para, demanda_prazo, demanda_status, checklist_id)
    values (public.pc_conversa_entre(v_autor, r), v_autor,
            pr.codigo || ' · ' || pr.cliente || E'\n' || regexp_replace(it.titulo, '^\d+º\s*', '')
              || coalesce(E'\n' || nullif(trim(it.descricao), ''), ''),
            pr.id, r,
            case when v_prazo is not null then public.add_dias_uteis(public.hoje_br(), v_prazo) end,
            'aberta', it.id);
    n := n + 1;
  end loop;

  update public.processo_checklist set avisado_em = now() where id = it.id;
  insert into public.processo_eventos (processo_id, tipo, texto)
  values (pr.id, 'demanda', 'Demanda enviada para ' ||
          (select string_agg(coalesce(p.nome, '?'), ', ') from public.profiles p where p.id = any(v_para)) ||
          ': ' || regexp_replace(it.titulo, '^\d+º\s*', ''));
  return n;
end $$;

-- avisa os itens liberados de uma etapa: item com responsáveis cujo item anterior já foi feito
create or replace function public.pc_verificar_avisos(p_pe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select c.id from public.processo_checklist c
     join public.checklist_modelo m on m.id = c.modelo_id
     where c.processo_etapa_id = p_pe_id and not c.feito and c.avisado_em is null
       and (coalesce(array_length(m.responsaveis, 1), 0) > 0 or m.responsaveis_label is not null)
       and coalesce((select a.feito from public.processo_checklist a
                      where a.processo_etapa_id = c.processo_etapa_id and a.ordem < c.ordem
                      order by a.ordem desc limit 1), true)
  loop
    perform public.pc_avisar_item(r.id);
  end loop;
end $$;

-- checklist mudou: conclui/reabre a demanda ligada e avisa o próximo
create or replace function public.pc_checklist_demandas()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.feito is distinct from old.feito then
    update public.mensagens
       set demanda_status = case when new.feito then 'concluida' else 'aberta' end,
           demanda_concluida_em = case when new.feito then now() end
     where checklist_id = new.id
       and demanda_status is distinct from (case when new.feito then 'concluida' else 'aberta' end);
  end if;
  perform public.pc_verificar_avisos(new.processo_etapa_id);
  return null;
end $$;

drop trigger if exists pc_checklist_demandas on public.processo_checklist;
create trigger pc_checklist_demandas
  after insert or update of feito on public.processo_checklist
  for each row execute function public.pc_checklist_demandas();

-- demanda concluída no chat marca o item do checklist
create or replace function public.pc_demanda_checklist()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.checklist_id is not null and new.demanda_status is distinct from old.demanda_status then
    if new.demanda_status = 'concluida' then
      update public.processo_checklist set feito = true, feito_em = now(), feito_por = coalesce(auth.uid(), new.demanda_para)
       where id = new.checklist_id and not feito;
    elsif new.demanda_status = 'aberta' then
      update public.processo_checklist set feito = false, feito_em = null, feito_por = null
       where id = new.checklist_id and feito;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists pc_demanda_checklist on public.mensagens;
create trigger pc_demanda_checklist
  after update of demanda_status on public.mensagens
  for each row execute function public.pc_demanda_checklist();

-- etapa começou: avisa quem já pode começar
create or replace function public.pc_etapa_espera()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'em_andamento' and new.iniciado_em is distinct from old.iniciado_em then
      update public.processo_etapas set aguardando_cliente = false, aguardando_desde = null, ultima_cobranca = null, retomado_em = null
       where id = new.id;
    end if;
    perform public.pc_avaliar_espera(new.id);
    if new.status = 'em_andamento' then perform public.pc_verificar_avisos(new.id); end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Novo checklist de Projetos (depois do 11º passo)
-- ---------------------------------------------------------------------
do $$
declare
  v_proj int; v_cot int; v_est int;
  v_cot_resp uuid[]; v_cot_label text; v_est_resp uuid[]; v_est_label text;
begin
  select id into v_proj from public.etapas where nome = 'Projeto (Flex / Premium / Full)';
  select id, responsaveis_padrao, responsaveis_label into v_cot, v_cot_resp, v_cot_label from public.etapas where nome = 'Cotação de frete';
  select id, responsaveis_padrao, responsaveis_label into v_est, v_est_resp, v_est_label from public.etapas where nome = 'Estimativa de custo';
  if v_proj is null then return; end if;

  -- passos 12, 13 e 14 vêm para dentro de Projetos
  update public.checklist_modelo set etapa_id = v_proj, ordem = 120 where etapa_id = v_cot and titulo like '12º%';
  update public.checklist_modelo set etapa_id = v_proj, ordem = 130 where etapa_id = v_cot and titulo like '13º%';
  update public.checklist_modelo set etapa_id = v_proj, ordem = 140,
         responsaveis = coalesce(v_est_resp, '{}'), responsaveis_label = coalesce(v_est_label, 'Alycia'), prazo_item = 2
   where etapa_id in (v_est, v_proj) and titulo like '14º%' and prazo_item is null;

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item, prazo_item_cert)
  select v_proj, 115, 'Cotação de frete internacional (Agenciamento)',
         E'• Agenciamento recebe a solicitação e devolve a cotação do frete internacional.\n• Prazo: 1 dia útil (2 com certificação).',
         coalesce(v_cot_resp, '{}'), coalesce(v_cot_label, 'Isabella / Cris'), 1, 2
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 115);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 125, 'Cotação de frete rodoviário (Agenciamento)',
         E'• Agenciamento devolve a cotação do frete rodoviário.\n• Prazo: 1 dia útil.',
         coalesce(v_cot_resp, '{}'), coalesce(v_cot_label, 'Isabella / Cris'), 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 125);

  -- as duas etapas deixam de existir no fluxo
  update public.etapas set ativo = false where id in (v_cot, v_est);
  update public.email_modelos set etapa_id = v_proj where etapa_id in (v_cot, v_est);

  -- -------------------------------------------------------------------
  -- Processos existentes
  -- -------------------------------------------------------------------
  if v_cot is null and v_est is null then return; end if;

  -- itens novos nas etapas de Projeto ainda não concluídas
  insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
  select pe.id, m.id, m.ordem, m.titulo, m.descricao, m.aguarda_cliente, m.prazo_depois
    from public.processo_etapas pe
    join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
   where pe.etapa_id = v_proj
  on conflict do nothing;

  -- Projeto concluído + etapa antiga concluída → itens correspondentes marcados, com a data real
  update public.processo_checklist c
     set feito = true, feito_em = old.concluido_em, feito_por = old.concluido_por, avisado_em = coalesce(c.avisado_em, old.iniciado_em)
    from public.processo_etapas pj, public.processo_etapas old, public.checklist_modelo m
   where c.processo_etapa_id = pj.id and pj.etapa_id = v_proj and c.modelo_id = m.id
     and old.processo_id = pj.processo_id and old.status = 'concluida'
     and ((old.etapa_id = v_cot and m.ordem in (115, 120, 125, 130)) or (old.etapa_id = v_est and m.ordem = 140))
     and not c.feito;

  -- quem estava EM Cotação/Estimativa: os passos anteriores de Projetos já foram feitos
  update public.processo_checklist c
     set feito = true, feito_em = coalesce(pj.concluido_em, now()), feito_por = pj.concluido_por
    from public.processo_etapas pj, public.processo_etapas old
   where c.processo_etapa_id = pj.id and pj.etapa_id = v_proj
     and old.processo_id = pj.processo_id and old.status = 'em_andamento'
     and ((old.etapa_id = v_cot and c.ordem < 115) or (old.etapa_id = v_est and c.ordem < 140))
     and not c.feito;

  -- quem estava EM Cotação/Estimativa volta para Projetos (mesmo prazo original)
  update public.processo_etapas pj
     set status = 'em_andamento', concluido_em = null, concluido_por = null
    from public.processo_etapas old
   where pj.processo_id = old.processo_id and pj.etapa_id = v_proj
     and old.etapa_id in (v_cot, v_est) and old.status = 'em_andamento';

  -- remove as etapas antigas dos processos e renumera
  delete from public.processo_etapas where etapa_id in (v_cot, v_est);
end $$;

-- renumera o fluxo (etapas ativas) e as etapas de cada processo
with n as (select id, row_number() over (order by ordem, id) as o from public.etapas where ativo)
update public.etapas e set ordem = n.o from n where e.id = n.id and e.ordem <> n.o;
update public.etapas set ordem = ordem + 100 where not ativo and ordem < 100;

with n as (select id, row_number() over (partition by processo_id order by ordem, id) as o from public.processo_etapas)
update public.processo_etapas pe set ordem = n.o from n where pe.id = n.id and pe.ordem <> n.o;

-- avisa quem já pode começar nos processos em andamento
do $$
declare r record;
begin
  for r in select pe.id from public.processo_etapas pe join public.processos p on p.id = pe.processo_id
            where pe.status = 'em_andamento' and p.status = 'ativo' loop
    perform public.pc_verificar_avisos(r.id);
  end loop;
end $$;

alter function public.pc_checklist_espera() security definer set search_path = public;

-- funções internas: não ficam expostas na API
revoke all on function public.pc_item_responsaveis(int) from public, anon, authenticated;
revoke all on function public.pc_conversa_entre(uuid, uuid) from public, anon, authenticated;
revoke all on function public.pc_avisar_item(uuid) from public, anon, authenticated;
revoke all on function public.pc_verificar_avisos(uuid) from public, anon, authenticated;
revoke all on function public.pc_avaliar_espera(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
