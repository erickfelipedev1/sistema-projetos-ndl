-- =====================================================================
-- 012 — Status "pausado" + função de importação do quadro do Monday
-- Rodar DEPOIS do 001–011 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- Os dados em si ficam no 013_dados_monday.sql.
-- =====================================================================

alter table public.processos drop constraint if exists processos_status_check;
alter table public.processos add constraint processos_status_check check (status in ('ativo', 'pausado', 'concluido', 'cancelado'));
alter table public.processos add column if not exists monday_id text;
create unique index if not exists processos_monday_id_key on public.processos (monday_id) where monday_id is not null;

-- ---------------------------------------------------------------------
-- importar_monday(itens jsonb): cada item =
--   { grupo: ativo|finalizado|pausado, monday_id, empresa, cnpj, contato, plano, produto,
--     inicio: 'YYYY-MM-DD', termino: 'YYYY-MM-DD', ordem: bool, responsavel, detalhes }
-- ativo/pausado → etapa Projeto (prazo = término do Monday)
-- finalizado com ordem → CX · Ordem (ativo); finalizado sem ordem → Concluído (histórico)
-- Não repete: itens com monday_id já importado são ignorados.
-- ---------------------------------------------------------------------
create or replace function public.importar_monday(p_itens jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
  n int := 0;
  v_cli uuid; v_id uuid;
  v_ini date; v_fim date;
  v_proj int; v_apres int; v_cx int; v_alvo int;
  v_grupo text; v_ordem boolean;
  v_resp uuid[];
begin
  perform set_config('pc.rpc', 'on', true);

  for it in select * from jsonb_array_elements(p_itens) loop
    if exists (select 1 from public.processos where monday_id = it->>'monday_id') then continue; end if;

    v_grupo := it->>'grupo';
    v_ordem := coalesce((it->>'ordem')::boolean, false);
    v_ini := coalesce((it->>'inicio')::date, public.hoje_br());
    v_fim := coalesce((it->>'termino')::date, v_ini);

    -- cliente: pelo CNPJ, senão pelo nome; cria se não existir
    v_cli := null;
    if nullif(it->>'cnpj', '') is not null then
      select id into v_cli from public.clientes where cnpj = it->>'cnpj' limit 1;
    end if;
    if v_cli is null then
      select id into v_cli from public.clientes where lower(trim(nome)) = lower(trim(it->>'empresa')) limit 1;
    end if;
    if v_cli is null then
      insert into public.clientes (nome, cnpj, contato)
      values (trim(it->>'empresa'), nullif(it->>'cnpj', ''), nullif(it->>'contato', ''))
      returning id into v_cli;
    else
      update public.clientes set cnpj = coalesce(cnpj, nullif(it->>'cnpj', '')), contato = coalesce(contato, nullif(it->>'contato', ''))
       where id = v_cli;
    end if;

    v_id := public.criar_processo(null, nullif(it->>'plano', ''), nullif(it->>'produto', ''), false, v_cli);
    update public.processos
       set monday_id = it->>'monday_id', contato = nullif(it->>'contato', ''),
           created_at = v_ini::timestamp at time zone 'America/Sao_Paulo'
     where id = v_id;

    -- posições das etapas deste processo
    select min(ordem) filter (where nome = 'Projeto (Flex / Premium / Full)'),
           min(ordem) filter (where nome = 'Apresentação da estimativa'),
           min(ordem) filter (where nome = 'Processo / Ordem / Pagamento')
      into v_proj, v_apres, v_cx
      from public.processo_etapas where processo_id = v_id;

    v_alvo := case when v_grupo = 'finalizado' and v_ordem then v_cx
                   when v_grupo = 'finalizado' then null
                   else v_proj end;

    -- responsáveis do Projeto = quem estava no Monday (se tiver conta, vincula; senão fica o nome)
    select coalesce(array_agg(p.id), '{}') into v_resp
      from public.profiles p
     where p.tipo = 'equipe' and nullif(it->>'responsavel', '') is not null
       and public.pc_normaliza(split_part(trim(p.nome), ' ', 1)) in (
             select public.pc_normaliza(split_part(trim(x), ' ', 1)) from regexp_split_to_table(it->>'responsavel', '\s*,\s*') x);
    if nullif(it->>'responsavel', '') is not null then
      update public.processo_etapas
         set responsaveis = case when array_length(v_resp, 1) > 0 then v_resp else responsaveis end,
             responsaveis_label = it->>'responsavel'
       where processo_id = v_id and ordem = v_proj;
    end if;

    -- etapas antes do alvo: concluídas com as datas do Monday
    update public.processo_etapas pe
       set status = 'concluida',
           iniciado_em = (case when pe.ordem < v_proj then v_ini when pe.ordem = v_proj then v_ini else v_fim end)::timestamp at time zone 'America/Sao_Paulo' + interval '9 hours',
           concluido_em = (case when pe.ordem < v_proj then v_ini else v_fim end)::timestamp at time zone 'America/Sao_Paulo' + interval '18 hours',
           prazo_em = null
     where pe.processo_id = v_id
       and pe.ordem < coalesce(v_alvo, v_apres + 1);

    -- etapa atual
    if v_alvo is not null then
      update public.processo_etapas pe
         set status = 'em_andamento',
             iniciado_em = (case when v_alvo = v_proj then v_ini else v_fim end)::timestamp at time zone 'America/Sao_Paulo' + interval '9 hours',
             prazo_em = case when v_alvo = v_proj then v_fim else public.add_dias_uteis(v_fim, coalesce(pe.prazo_dias_uteis, 15)) end,
             concluido_em = null
       where pe.processo_id = v_id and pe.ordem = v_alvo;
    end if;
    update public.processo_etapas set status = 'pendente', iniciado_em = null, prazo_em = null, concluido_em = null
     where processo_id = v_id and ordem > coalesce(v_alvo, v_apres);

    -- checklist das etapas concluídas marcado
    update public.processo_checklist c set feito = true, feito_em = pe.concluido_em
      from public.processo_etapas pe
     where c.processo_etapa_id = pe.id and pe.processo_id = v_id and pe.status = 'concluida' and not c.feito;

    update public.processos
       set status = case when v_grupo = 'pausado' then 'pausado'
                         when v_grupo = 'finalizado' and not v_ordem then 'concluido' else 'ativo' end,
           concluido_em = case when v_grupo = 'finalizado' and not v_ordem then v_fim::timestamp at time zone 'America/Sao_Paulo' + interval '18 hours' end
     where id = v_id;

    update public.processo_eventos set created_at = v_ini::timestamp at time zone 'America/Sao_Paulo' + interval '9 hours'
     where processo_id = v_id and tipo = 'criado';
    insert into public.processo_eventos (processo_id, tipo, texto)
    values (v_id, 'importado', 'Importado do Monday' || coalesce(E'\n' || nullif(it->>'detalhes', ''), ''));
    n := n + 1;
  end loop;

  perform set_config('pc.rpc', 'off', true);
  return n;
end $$;
revoke all on function public.importar_monday(jsonb) from public, anon, authenticated;

-- pausar / retomar: mesma regra de quem pode alterar o processo
create or replace function public.pausar_processo(p_processo_id uuid, p_pausar boolean, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_editar_processo(p_processo_id) then
    raise exception 'Sem permissão: só quem é da etapa atual ou um administrador pode pausar/retomar';
  end if;
  perform set_config('pc.rpc', 'on', true);
  update public.processos set status = case when p_pausar then 'pausado' else 'ativo' end
   where id = p_processo_id and status in ('ativo', 'pausado');
  insert into public.processo_eventos (processo_id, tipo, texto)
  values (p_processo_id, 'status', case when p_pausar then 'Processo pausado' else 'Processo retomado' end || coalesce(': ' || nullif(trim(p_motivo), ''), ''));
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.pausar_processo(uuid, boolean, text) to authenticated;

notify pgrst, 'reload schema';
