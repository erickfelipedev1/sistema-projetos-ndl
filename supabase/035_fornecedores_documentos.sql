-- =====================================================================
-- 035 — Fornecedores do projeto e Documentos para o cliente (atualização de 09/11/2026)
-- Rodar DEPOIS do 034. Pode rodar mais de uma vez.
--
--   • Aba "Fornecedores" (no lugar de Anexos): cada projeto guarda os fornecedores que
--     negociou — fábrica, contato, e-mail, site, histórico da negociação, documentos
--     (Proforma, Packing List, datasheets, manuais) e qual o cliente escolheu, com as
--     condições acordadas. Pode vir do cadastro geral de Fornecedores.
--   • Documentos no portal: um arquivo do processo pode ser liberado para o cliente
--     (anexos.visivel_cliente). O cliente vê a lista no portal e baixa por um link
--     temporário gerado no servidor, só depois de conferir que o processo é dele.
-- =====================================================================

create table if not exists public.processo_fornecedores (
  id uuid primary key default gen_random_uuid(),
  processo_id uuid not null references public.processos(id) on delete cascade,
  fornecedor_id uuid references public.fornecedores(id) on delete set null,
  fabrica text not null,
  contato_nome text,
  telefone text,
  email text,
  site text,
  negociacao text,
  escolhido boolean not null default false,
  condicoes text,
  criado_por uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists processo_fornecedores_processo_idx on public.processo_fornecedores (processo_id);

alter table public.processo_fornecedores enable row level security;
drop policy if exists pc_processo_fornecedores_equipe on public.processo_fornecedores;
create policy pc_processo_fornecedores_equipe on public.processo_fornecedores
  for all to authenticated using (public.is_equipe()) with check (public.is_equipe());
grant select, insert, update, delete on public.processo_fornecedores to authenticated;

-- arquivos do fornecedor e arquivos liberados para o cliente
alter table public.anexos add column if not exists processo_fornecedor_id uuid references public.processo_fornecedores(id) on delete set null;
alter table public.anexos add column if not exists visivel_cliente boolean not null default false;
alter table public.anexos add column if not exists compartilhado_em timestamptz;
create index if not exists anexos_fornecedor_idx on public.anexos (processo_fornecedor_id);

-- liberar / tirar um arquivo do portal do cliente (equipe)
create or replace function public.compartilhar_anexo(p_anexo uuid, p_visivel boolean)
returns void language plpgsql security definer set search_path = public as $$
declare a public.anexos;
begin
  if not public.is_equipe() then raise exception 'Sem permissão'; end if;
  select * into a from public.anexos where id = p_anexo;
  if a.id is null or a.processo_id is null then raise exception 'Arquivo não encontrado'; end if;
  if a.visivel_cliente = p_visivel then return; end if;
  update public.anexos set visivel_cliente = p_visivel, compartilhado_em = case when p_visivel then now() end where id = p_anexo;
  insert into public.processo_eventos (processo_id, tipo, texto)
  values (a.processo_id, 'anexo', case when p_visivel then 'Liberado no portal do cliente: ' else 'Retirado do portal do cliente: ' end || a.nome);
end $$;
revoke all on function public.compartilhar_anexo(uuid, boolean) from public, anon;
grant execute on function public.compartilhar_anexo(uuid, boolean) to authenticated;

-- caminho de um documento liberado, só para o cliente dono do processo (ou a equipe)
create or replace function public.portal_documento(p_anexo uuid)
returns table (caminho text, nome text) language sql stable security definer set search_path = public as $$
  select a.caminho, a.nome
    from public.anexos a
    join public.processos p on p.id = a.processo_id
   where a.id = p_anexo and a.visivel_cliente and p.status <> 'cancelado'
     and (public.is_equipe()
          or p.cliente_id = (select pr.cliente_id from public.profiles pr where pr.id = auth.uid() and pr.tipo = 'cliente'))
$$;
revoke all on function public.portal_documento(uuid) from public, anon;
grant execute on function public.portal_documento(uuid) to authenticated;

-- Portal: igual à versão do 009, mais a lista de documentos liberados de cada processo
create or replace function public.portal_processos(p_cliente_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_cliente uuid;
begin
  if public.is_equipe() and p_cliente_id is not null then
    v_cliente := p_cliente_id;                         -- equipe visualizando "como o cliente vê"
  else
    select cliente_id into v_cliente from public.profiles where id = auth.uid() and tipo = 'cliente';
  end if;
  if v_cliente is null then return null; end if;

  return jsonb_build_object(
    'cliente', (select jsonb_build_object('id', c.id, 'nome', c.nome) from public.clientes c where c.id = v_cliente),
    'processos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'codigo', p.codigo, 'plano', p.plano, 'status', p.status, 'descricao', p.descricao,
               'aberto_em', p.created_at, 'concluido_em', p.concluido_em,
               'previsao', case when p.status = 'ativo' then public.previsao_processo(p.id) end,
               'etapas', (select jsonb_agg(jsonb_build_object(
                                  'ordem', pe.ordem, 'nome', pe.nome, 'area', pe.area, 'tipo', pe.tipo, 'status', pe.status,
                                  'iniciado_em', pe.iniciado_em, 'concluido_em', pe.concluido_em,
                                  'aguardando_cliente', pe.aguardando_cliente,
                                  'aguardando_o_que', case when pe.aguardando_cliente then (select replace(split_part(regexp_replace(c.titulo, '^Aguardando ', ''), ' — ', 1), ' do cliente', '') from public.processo_checklist c where c.processo_etapa_id = pe.id and not c.feito order by c.ordem limit 1) end) order by pe.ordem)
                            from public.processo_etapas pe where pe.processo_id = p.id),
               'documentos', coalesce((select jsonb_agg(jsonb_build_object(
                                  'id', a.id, 'nome', a.nome, 'tamanho', a.tamanho, 'tipo_mime', a.tipo_mime,
                                  'em', coalesce(a.compartilhado_em, a.created_at)) order by coalesce(a.compartilhado_em, a.created_at) desc)
                            from public.anexos a where a.processo_id = p.id and a.visivel_cliente), '[]'::jsonb)
             ) order by (p.status = 'ativo') desc, p.created_at desc)
      from public.processos p
      where p.cliente_id = v_cliente and p.status <> 'cancelado'), '[]'::jsonb)
  );
end $$;
revoke all on function public.portal_processos(uuid) from public;
grant execute on function public.portal_processos(uuid) to authenticated;

notify pgrst, 'reload schema';
