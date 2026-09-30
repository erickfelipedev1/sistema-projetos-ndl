-- =====================================================================
-- 018 — Importa o progresso do checklist de Projeto a partir do quadro
-- "Tarefas - Projetos" do Monday. Rodar DEPOIS do 017. Os dados ficam no
-- 019_dados_tarefas_projetos.sql. Não desmarca nada — só marca como feito
-- o que o Monday mostra como "Feito"; o resto fica como já estava.
-- =====================================================================

-- ---------------------------------------------------------------------
-- importar_progresso_projeto(itens jsonb): cada item =
--   { cnpj_digits: text|null, nome_busca: text|null, ordens: [int, ...] }
-- (ordens = itens do checklist de Projeto que o Monday mostra como "Feito")
-- Localiza o cliente pelo CNPJ (só dígitos) ou, sem CNPJ, por nome (casos
-- "sem empresa"); localiza o processo mais recente desse cliente que tenha
-- a etapa "Projeto (Flex / Premium / Full)" e marca esses itens como feitos.
-- ---------------------------------------------------------------------
create or replace function public.importar_progresso_projeto(p_itens jsonb)
returns table(processados int, sem_cliente int, sem_processo int) language plpgsql security definer set search_path = public as $$
declare
  it jsonb; v_ordem int;
  v_cli uuid; v_proc uuid; v_pe uuid;
  n_ok int := 0; n_semcli int := 0; n_semproc int := 0;
begin
  perform set_config('pc.rpc', 'on', true);

  for it in select * from jsonb_array_elements(p_itens) loop
    v_cli := null;
    if nullif(it->>'cnpj_digits', '') is not null then
      select id into v_cli from public.clientes
       where regexp_replace(coalesce(cnpj, ''), '\D', '', 'g') = it->>'cnpj_digits'
       limit 1;
    end if;
    if v_cli is null and nullif(it->>'nome_busca', '') is not null then
      select id into v_cli from public.clientes
       where lower(trim(nome)) = lower(trim(it->>'nome_busca')) || ' (sem empresa)'
       limit 1;
    end if;
    if v_cli is null then n_semcli := n_semcli + 1; continue; end if;

    select p.id into v_proc from public.processos p
     where p.cliente_id = v_cli
     order by (p.status in ('ativo', 'pausado')) desc, p.created_at desc
     limit 1;
    if v_proc is null then n_semproc := n_semproc + 1; continue; end if;

    select pe.id into v_pe from public.processo_etapas pe
      join public.etapas e on e.id = pe.etapa_id
     where pe.processo_id = v_proc and e.nome = 'Projeto (Flex / Premium / Full)'
     limit 1;
    if v_pe is null then n_semproc := n_semproc + 1; continue; end if;

    for v_ordem in select jsonb_array_elements_text(it->'ordens')::int loop
      update public.processo_checklist c
         set feito = true, feito_em = coalesce(feito_em, now())
        from public.checklist_modelo m
       where c.modelo_id = m.id and c.processo_etapa_id = v_pe
         and m.ordem = v_ordem and not c.feito;
    end loop;
    n_ok := n_ok + 1;
  end loop;

  perform set_config('pc.rpc', 'off', true);
  return query select n_ok, n_semcli, n_semproc;
end $$;
revoke all on function public.importar_progresso_projeto(jsonb) from public, anon, authenticated;

notify pgrst, 'reload schema';
