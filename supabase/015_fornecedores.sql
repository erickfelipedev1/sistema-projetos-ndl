-- =====================================================================
-- 015 — Base de dados de fornecedores
-- Rodar DEPOIS do 001–014 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- Os dados em si (importados do Monday) ficam no 016_dados_fornecedores.sql.
-- =====================================================================

create table if not exists public.fornecedores (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  produto text,
  contato text,
  origem text,
  telefone text,
  email text,
  site text,
  avaliacao smallint check (avaliacao between 1 and 5),
  observacoes text,
  criado_por_nome text,        -- de onde veio (import) quando não há usuário do sistema vinculado
  monday_id text,
  created_at timestamptz not null default now()
);
create unique index if not exists fornecedores_monday_id_key on public.fornecedores (monday_id) where monday_id is not null;
create index if not exists fornecedores_nome_idx on public.fornecedores (lower(nome));
create index if not exists fornecedores_produto_idx on public.fornecedores (lower(produto));
create index if not exists fornecedores_origem_idx on public.fornecedores (origem);

alter table public.fornecedores enable row level security;
drop policy if exists pc_fornecedores_ler on public.fornecedores;
drop policy if exists pc_fornecedores_equipe on public.fornecedores;
create policy pc_fornecedores_ler on public.fornecedores for select to authenticated using (public.is_equipe());
create policy pc_fornecedores_equipe on public.fornecedores for all to authenticated using (public.is_equipe()) with check (public.is_equipe());

-- ---------------------------------------------------------------------
-- importar_fornecedores(itens jsonb): cada item =
--   { monday_id, nome, produto, contato, origem, telefone, email, site,
--     avaliacao: int|null, criado_por, observacoes }
-- Idempotente: item com monday_id já importado é ignorado.
-- ---------------------------------------------------------------------
create or replace function public.importar_fornecedores(p_itens jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
  n int := 0;
begin
  for it in select * from jsonb_array_elements(p_itens) loop
    if nullif(it->>'monday_id', '') is not null
       and exists (select 1 from public.fornecedores where monday_id = it->>'monday_id') then
      continue;
    end if;
    insert into public.fornecedores (nome, produto, contato, origem, telefone, email, site, avaliacao, observacoes, criado_por_nome, monday_id)
    values (
      trim(it->>'nome'), nullif(it->>'produto', ''), nullif(it->>'contato', ''), nullif(it->>'origem', ''),
      nullif(it->>'telefone', ''), nullif(it->>'email', ''), nullif(it->>'site', ''),
      nullif(it->>'avaliacao', '')::smallint, nullif(it->>'observacoes', ''), nullif(it->>'criado_por', ''),
      nullif(it->>'monday_id', '')
    );
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.importar_fornecedores(jsonb) from public, anon, authenticated;

notify pgrst, 'reload schema';
