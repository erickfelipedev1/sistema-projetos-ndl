-- =====================================================================
-- 024 — Dentro de cada processo: trocar o responsável de um item do
-- checklist (pessoa específica, substitui o padrão do modelo só nesse
-- processo) e adicionar/remover itens do checklist daquele processo
-- (sem afetar o modelo padrão nem outros processos).
-- Rodar DEPOIS do 001–023.
-- =====================================================================

alter table public.processo_checklist add column if not exists responsavel_id uuid references public.profiles(id) on delete set null;

-- avisa os itens liberados de uma etapa: agora também considera item com
-- responsável definido diretamente no processo (sem depender do modelo)
create or replace function public.pc_verificar_avisos(p_pe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select c.id from public.processo_checklist c
     left join public.checklist_modelo m on m.id = c.modelo_id
     where c.processo_etapa_id = p_pe_id and not c.feito and c.avisado_em is null
       and (c.responsavel_id is not null or coalesce(array_length(m.responsaveis, 1), 0) > 0 or m.responsaveis_label is not null)
       and coalesce((select a.feito from public.processo_checklist a
                      where a.processo_etapa_id = c.processo_etapa_id and a.ordem < c.ordem
                      order by a.ordem desc limit 1), true)
  loop
    perform public.pc_avisar_item(r.id);
  end loop;
end $$;

-- manda a demanda para os responsáveis do item (uma vez só) — prioriza o
-- responsável escolhido no processo; sem ele, cai no padrão do modelo
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
  if it.id is null or it.feito or it.avisado_em is not null then return 0; end if;
  select * into pe from public.processo_etapas where id = it.processo_etapa_id;
  if pe.status <> 'em_andamento' then return 0; end if;
  select * into pr from public.processos where id = pe.processo_id;
  if pr.status <> 'ativo' then return 0; end if;
  if it.modelo_id is not null then select * into m from public.checklist_modelo where id = it.modelo_id; end if;
  v_para := case when it.responsavel_id is not null then array[it.responsavel_id] else public.pc_item_responsaveis(it.modelo_id) end;
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

notify pgrst, 'reload schema';
