-- =====================================================================
-- 029 — Recotação (volta para Projeto com a data da recotação) e Segmentos por sourcing
-- Rodar DEPOIS do 001–028. Pode rodar mais de uma vez.
--
-- RECOTAÇÃO
--   Depois de apresentar a estimativa, o CS recota: o processo volta para a etapa
--   Projeto, com novo prazo contado a partir de hoje (pelo plano), checklist de
--   Projeto desmarcado e datas dos itens recalculadas. A data e o número da
--   recotação ficam no processo (recotacoes / ultima_recotacao_em) e no histórico.
--   Pode recotar quantas vezes precisar. Permissão: a mesma de "voltar etapa"
--   (admin, responsável da etapa ou cargo da área — na Apresentação da estimativa, o CS).
--
-- SEGMENTOS POR SOURCING
--   Flex: 1 segmento, 1 fornecedor · Full: 1 segmento, 3 fornecedores ·
--   Premium: 6 segmentos, 12 fornecedores (2 por segmento).
--   Os segmentos nascem sozinhos quando o processo tem plano (nome editável na aba
--   Segmentos). Se o plano mudar, segmentos que faltam são criados; os existentes
--   nunca são apagados.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Recotação
-- ---------------------------------------------------------------------
alter table public.processos add column if not exists recotacoes int not null default 0;
alter table public.processos add column if not exists ultima_recotacao_em timestamptz;

create or replace function public.recotar_processo(p_processo_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_atual public.processo_etapas;
  v_proj public.processo_etapas;
  v_n int;
begin
  perform public.pc_exigir_processo(p_processo_id);   -- confere permissão e liga pc.rpc

  if not exists (select 1 from public.processos where id = p_processo_id and status = 'ativo') then
    raise exception 'Só dá para recotar um processo ativo';
  end if;

  select * into v_atual from public.processo_etapas
   where processo_id = p_processo_id and status = 'em_andamento' order by ordem limit 1;
  if v_atual.id is null or v_atual.nome <> 'Apresentação da estimativa' then
    raise exception 'A recotação é feita na etapa Apresentação da estimativa';
  end if;

  select pe.* into v_proj from public.processo_etapas pe
    join public.etapas e on e.id = pe.etapa_id
   where pe.processo_id = p_processo_id and e.nome = 'Projeto (Flex / Premium / Full)'
   limit 1;
  if v_proj.id is null then raise exception 'Processo sem etapa de Projeto'; end if;

  -- da apresentação em diante: volta a ficar pendente
  update public.processo_etapas
     set status = 'pendente', iniciado_em = null, prazo_em = null, concluido_em = null, concluido_por = null,
         aguardando_cliente = false, aguardando_desde = null, ultima_cobranca = null, retomado_em = null
   where processo_id = p_processo_id and ordem >= v_atual.ordem;

  -- checklist de Projeto desmarcado (as datas dos itens são recalculadas ao reabrir a etapa)
  update public.processo_checklist
     set feito = false, feito_em = null, feito_por = null, prazo_em = null
   where processo_etapa_id = v_proj.id;

  -- Projeto reabre agora, com novo prazo pelo plano
  update public.processo_etapas
     set status = 'em_andamento', iniciado_em = now(),
         prazo_em = public.add_dias_uteis(public.hoje_br(), prazo_dias_uteis),
         concluido_em = null, concluido_por = null
   where id = v_proj.id;

  update public.processos
     set recotacoes = recotacoes + 1, ultima_recotacao_em = now()
   where id = p_processo_id
   returning recotacoes into v_n;

  insert into public.processo_eventos (processo_id, tipo, texto)
  values (p_processo_id, 'recotacao',
          'Recotação ' || v_n || ' em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY')
          || ' — voltou para "' || v_proj.nome || '" com novo prazo'
          || coalesce(E'\n' || nullif(trim(p_motivo), ''), ''));

  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.recotar_processo(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Segmentos por sourcing
-- ---------------------------------------------------------------------
create table if not exists public.processo_segmentos (
  id uuid primary key default gen_random_uuid(),
  processo_id uuid not null references public.processos(id) on delete cascade,
  ordem int not null,
  nome text not null,
  meta_fornecedores int not null default 1,
  fornecedores text,                              -- um fornecedor por linha
  created_at timestamptz not null default now(),
  unique (processo_id, ordem)
);
create index if not exists processo_segmentos_proc_idx on public.processo_segmentos (processo_id, ordem);

alter table public.processo_segmentos enable row level security;
drop policy if exists pc_processo_segmentos_all on public.processo_segmentos;
create policy pc_processo_segmentos_all on public.processo_segmentos for all to authenticated
  using (public.is_equipe()) with check (public.is_equipe());

create or replace function public.pc_garantir_segmentos(p_processo_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_plano text; v_seg int; v_forn int;
begin
  select plano into v_plano from public.processos where id = p_processo_id;
  if v_plano is null then return; end if;
  v_seg  := case v_plano when 'Premium' then 6 else 1 end;
  v_forn := case v_plano when 'Premium' then 12 when 'Full' then 3 else 1 end;
  insert into public.processo_segmentos (processo_id, ordem, nome, meta_fornecedores)
  select p_processo_id, g, 'Segmento ' || g, v_forn / v_seg
    from generate_series(1, v_seg) g
  on conflict (processo_id, ordem) do nothing;
end $$;
revoke all on function public.pc_garantir_segmentos(uuid) from public, anon, authenticated;

create or replace function public.pc_tg_segmentos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.pc_garantir_segmentos(new.id);
  return null;
end $$;

drop trigger if exists pc_processo_segmentos on public.processos;
create trigger pc_processo_segmentos
  after insert or update of plano on public.processos
  for each row execute function public.pc_tg_segmentos();

-- processos que já existem (com plano) ganham os segmentos
select public.pc_garantir_segmentos(id) from public.processos where plano is not null;

notify pgrst, 'reload schema';
