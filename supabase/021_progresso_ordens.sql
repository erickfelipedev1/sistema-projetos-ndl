-- =====================================================================
-- 021 — Importa o progresso das ordens a partir do quadro "Ordens" do
-- Monday, distribuindo as tarefas pelas etapas certas do fluxo (Ordem,
-- Booking/Produção, Viagem, Chegou). Rodar DEPOIS do 020. Os dados ficam
-- no 022_dados_ordens.sql. Só marca como feito — nunca desmarca.
-- ---------------------------------------------------------------------
-- importar_progresso_ordens(itens jsonb): cada item =
--   { cnpj_digits: text, marcar: [{ etapa: text, ordem: int }, ...] }
-- =====================================================================
create or replace function public.importar_progresso_ordens(p_itens jsonb)
returns table(processados int, sem_cliente int, sem_processo int) language plpgsql security definer set search_path = public as $$
declare
  it jsonb; alvo jsonb;
  v_cli uuid; v_proc uuid; v_pe uuid;
  n_ok int := 0; n_semcli int := 0; n_semproc int := 0;
  v_algum boolean;
begin
  perform set_config('pc.rpc', 'on', true);

  for it in select * from jsonb_array_elements(p_itens) loop
    v_cli := null;
    if nullif(it->>'cnpj_digits', '') is not null then
      select id into v_cli from public.clientes
       where regexp_replace(coalesce(cnpj, ''), '\D', '', 'g') = it->>'cnpj_digits'
       limit 1;
    end if;
    if v_cli is null then n_semcli := n_semcli + 1; continue; end if;

    select p.id into v_proc from public.processos p
     where p.cliente_id = v_cli
     order by (p.status in ('ativo', 'pausado')) desc, p.created_at desc
     limit 1;
    if v_proc is null then n_semproc := n_semproc + 1; continue; end if;

    v_algum := false;
    for alvo in select * from jsonb_array_elements(it->'marcar') loop
      select pe.id into v_pe from public.processo_etapas pe
        join public.etapas e on e.id = pe.etapa_id
       where pe.processo_id = v_proc and e.nome = alvo->>'etapa'
       limit 1;
      if v_pe is not null then
        update public.processo_checklist c
           set feito = true, feito_em = coalesce(feito_em, now())
          from public.checklist_modelo m
         where c.modelo_id = m.id and c.processo_etapa_id = v_pe
           and m.ordem = (alvo->>'ordem')::int and not c.feito;
        v_algum := true;
      end if;
    end loop;
    if v_algum then n_ok := n_ok + 1; else n_semproc := n_semproc + 1; end if;
  end loop;

  perform set_config('pc.rpc', 'off', true);
  return query select n_ok, n_semcli, n_semproc;
end $$;
revoke all on function public.importar_progresso_ordens(jsonb) from public, anon, authenticated;

notify pgrst, 'reload schema';
