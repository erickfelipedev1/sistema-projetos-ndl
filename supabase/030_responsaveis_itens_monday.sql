-- =====================================================================
-- 030 — Responsável por item do checklist de Projeto, com base na lista do Monday
-- ("Tarefas - Projetos", exportada em 07/10/2026). Rodar DEPOIS do 001–029.
-- Pode rodar mais de uma vez (só preenche itens que ainda não têm responsável).
--
-- Para cada processo importado da ata (ata-2026-09-29-NN), o responsável de cada
-- item do checklist de Projeto é quem aparecia na tarefa correspondente no Monday:
--   10 Análise                     ← Recebimento do projeto
--   20/30/40/45 Pesquisa, Contato,
--      Acompanhamento, INPI        ← Busca por fornecedores
--   50 Envio dos catálogos         ← Escolha dos fornecedores
--   60 Montagem do sourcing        ← Montagem da apresentação
--   70 Envio do sourcing           ← Envio da apresentação para o cliente e os catálogos
--   80/90 Reunião / envio final    ← Reunião de sourcing
--   100 PI e PL                    ← Solicitação de PI e PL
--   110 Frete internacional        ← Solicitação de frete internacional
--   120 Frete rodoviário           ← Solicitação de frete rodoviário
--   130 Estimativa                 ← Solicitação de estimativa de custos
-- Não mexe nos itens de Agenciamento (115, 125) nem na estimativa (140–160): esses
-- já têm responsável fixo no modelo (Isabelle / Cris e Alycia).
-- Quem não tem conta no NowTrace (ex.: Misaell, que só existe no Monday) fica de
-- fora: o item continua sem responsável próprio e vale o responsável da etapa.
-- ATENÇÃO: com responsável no item, só essa pessoa (ou um administrador) consegue marcá-lo.
-- =====================================================================

create or replace function public.importar_responsaveis_itens(p_itens jsonb)
returns table(processos int, itens_atualizados int, sem_conta int) language plpgsql security definer set search_path = public as $$
declare
  it jsonb; k text; v_pe uuid; v_proc uuid; v_resp uuid; v_nome1 text;
  n_proc int := 0; n_item int := 0; n_sem int := 0; n_lin int;
begin
  perform set_config('pc.rpc', 'on', true);

  for it in select * from jsonb_array_elements(p_itens) loop
    select id into v_proc from public.processos where monday_id = it->>'ref';
    if v_proc is null then continue; end if;
    select pe.id into v_pe from public.processo_etapas pe
      join public.etapas e on e.id = pe.etapa_id
     where pe.processo_id = v_proc and e.nome = 'Projeto (Flex / Premium / Full)' limit 1;
    if v_pe is null then continue; end if;
    n_proc := n_proc + 1;

    for k in select jsonb_object_keys(it->'itens') loop
      v_nome1 := public.pc_normaliza(split_part(trim(it->'itens'->>k), ' ', 1));
      select p.id into v_resp from public.profiles p
       where p.tipo = 'equipe' and public.pc_normaliza(coalesce(p.nome, '')) like v_nome1 || '%'
       order by length(p.nome), p.nome limit 1;
      if v_resp is null then n_sem := n_sem + 1; continue; end if;

      update public.processo_checklist c set responsavel_id = v_resp
       where c.processo_etapa_id = v_pe and c.ordem = k::int and c.responsavel_id is null;
      get diagnostics n_lin = row_count;
      n_item := n_item + n_lin;
    end loop;
  end loop;

  perform set_config('pc.rpc', 'off', true);
  return query select n_proc, n_item, n_sem;
end $$;
revoke all on function public.importar_responsaveis_itens(jsonb) from public, anon, authenticated;

select * from public.importar_responsaveis_itens($resp$[
{"ref": "ata-2026-09-29-01", "itens": {"10": "Ana Clara Ré Rosa"}},
{"ref": "ata-2026-09-29-02", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-03", "itens": {"10": "Alycia Pistoia", "20": "Alycia Pistoia", "30": "Alycia Pistoia", "40": "Alycia Pistoia", "45": "Alycia Pistoia", "50": "Alycia Pistoia", "60": "Alycia Pistoia", "70": "Alycia Pistoia", "80": "Alycia Pistoia", "90": "Alycia Pistoia", "100": "Alycia Pistoia", "110": "Alycia Pistoia", "120": "Alycia Pistoia", "130": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-04", "itens": {"10": "Alycia Pistoia", "20": "Alycia Pistoia", "30": "Alycia Pistoia", "40": "Alycia Pistoia", "45": "Alycia Pistoia", "50": "Alycia Pistoia", "60": "Alycia Pistoia", "70": "Alycia Pistoia", "80": "Alycia Pistoia", "90": "Alycia Pistoia", "100": "Alycia Pistoia", "110": "Alycia Pistoia", "120": "Alycia Pistoia", "130": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-05", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-06", "itens": {"10": "Alycia Pistoia", "20": "Alycia Pistoia", "30": "Alycia Pistoia", "40": "Alycia Pistoia", "45": "Alycia Pistoia", "50": "Alycia Pistoia", "60": "Alycia Pistoia", "70": "Alycia Pistoia", "80": "Alycia Pistoia", "90": "Alycia Pistoia", "100": "Alycia Pistoia", "110": "Alycia Pistoia", "120": "Alycia Pistoia", "130": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-07", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-08", "itens": {"10": "Alycia Pistoia", "20": "Alycia Pistoia", "30": "Alycia Pistoia", "40": "Alycia Pistoia", "45": "Alycia Pistoia", "50": "Alycia Pistoia", "60": "Alycia Pistoia", "70": "Alycia Pistoia", "80": "Alycia Pistoia", "90": "Alycia Pistoia", "100": "Alycia Pistoia", "110": "Alycia Pistoia", "120": "Alycia Pistoia", "130": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-09", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-10", "itens": {"10": "Alycia Pistoia", "20": "Alycia Pistoia", "30": "Alycia Pistoia", "40": "Alycia Pistoia", "45": "Alycia Pistoia", "50": "Alycia Pistoia", "60": "Alycia Pistoia", "70": "Alycia Pistoia", "80": "Alycia Pistoia", "90": "Alycia Pistoia", "100": "Alycia Pistoia", "110": "Alycia Pistoia", "120": "Alycia Pistoia", "130": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-11", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-12", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-13", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-14", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-15", "itens": {"10": "Ana Clara Ré Rosa"}},
{"ref": "ata-2026-09-29-16", "itens": {"10": "Alycia Pistoia", "20": "Alycia Pistoia", "30": "Alycia Pistoia", "40": "Alycia Pistoia", "45": "Alycia Pistoia", "50": "Alycia Pistoia", "60": "Alycia Pistoia", "70": "Alycia Pistoia", "80": "Alycia Pistoia", "90": "Alycia Pistoia", "100": "Alycia Pistoia", "110": "Alycia Pistoia", "120": "Alycia Pistoia", "130": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-17", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-19", "itens": {"10": "Alycia Pistoia", "20": "Alycia Pistoia", "30": "Alycia Pistoia", "40": "Alycia Pistoia", "45": "Alycia Pistoia", "50": "Alycia Pistoia", "60": "Alycia Pistoia", "70": "Alycia Pistoia", "80": "Alycia Pistoia", "90": "Alycia Pistoia", "100": "Alycia Pistoia", "110": "Alycia Pistoia", "120": "Alycia Pistoia", "130": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-20", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-21", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-22", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-23", "itens": {"110": "Alycia Pistoia", "120": "Alycia Pistoia"}},
{"ref": "ata-2026-09-29-24", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-25", "itens": {"100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-26", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-27", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-28", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-29", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-30", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-31", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-32", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-34", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-35", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-36", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-37", "itens": {"10": "Misaell Henrique da Silva Lopes", "20": "Misaell Henrique da Silva Lopes", "30": "Misaell Henrique da Silva Lopes", "40": "Misaell Henrique da Silva Lopes", "45": "Misaell Henrique da Silva Lopes", "50": "Misaell Henrique da Silva Lopes", "60": "Misaell Henrique da Silva Lopes", "70": "Misaell Henrique da Silva Lopes", "80": "Misaell Henrique da Silva Lopes", "90": "Misaell Henrique da Silva Lopes", "100": "Misaell Henrique da Silva Lopes", "110": "Misaell Henrique da Silva Lopes", "120": "Misaell Henrique da Silva Lopes", "130": "Misaell Henrique da Silva Lopes"}},
{"ref": "ata-2026-09-29-38", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-39", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-40", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-41", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-42", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-43", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-44", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-46", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-47", "itens": {"10": "Gabriella Bucki", "20": "Gabriella Bucki", "30": "Gabriella Bucki", "40": "Gabriella Bucki", "45": "Gabriella Bucki", "50": "Gabriella Bucki", "60": "Gabriella Bucki", "70": "Gabriella Bucki", "80": "Gabriella Bucki", "90": "Gabriella Bucki", "100": "Gabriella Bucki", "110": "Gabriella Bucki", "120": "Gabriella Bucki", "130": "Gabriella Bucki"}},
{"ref": "ata-2026-09-29-48", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-49", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-50", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-51", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-52", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-53", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-54", "itens": {"10": "Ana Clara Ré Rosa"}},
{"ref": "ata-2026-09-29-55", "itens": {"10": "Ana Clara Ré Rosa"}},
{"ref": "ata-2026-09-29-56", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-57", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-59", "itens": {"10": "Giovanna Souza de Andrade", "20": "Giovanna Souza de Andrade", "30": "Giovanna Souza de Andrade", "40": "Giovanna Souza de Andrade", "45": "Giovanna Souza de Andrade", "50": "Giovanna Souza de Andrade", "60": "Giovanna Souza de Andrade", "70": "Giovanna Souza de Andrade", "80": "Giovanna Souza de Andrade", "90": "Giovanna Souza de Andrade", "100": "Giovanna Souza de Andrade", "110": "Giovanna Souza de Andrade", "120": "Giovanna Souza de Andrade", "130": "Giovanna Souza de Andrade"}},
{"ref": "ata-2026-09-29-61", "itens": {"10": "Rodrigo Cruz", "20": "Rodrigo Cruz", "30": "Rodrigo Cruz", "40": "Rodrigo Cruz", "45": "Rodrigo Cruz", "50": "Rodrigo Cruz", "60": "Rodrigo Cruz", "70": "Rodrigo Cruz", "80": "Rodrigo Cruz", "90": "Rodrigo Cruz", "100": "Rodrigo Cruz", "110": "Rodrigo Cruz", "120": "Rodrigo Cruz", "130": "Rodrigo Cruz"}},
{"ref": "ata-2026-09-29-62", "itens": {"10": "Ana Clara Ré Rosa"}}
]$resp$::jsonb);

notify pgrst, 'reload schema';
