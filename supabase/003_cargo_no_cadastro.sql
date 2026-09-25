-- =====================================================================
-- 003 — Cargo no cadastro + vínculo automático com as etapas
-- Rodar DEPOIS do 001 e do 002. Pode rodar mais de uma vez.
--
-- Como funciona:
--   * No cadastro a pessoa informa nome e cargo (CS, Projetos, Agenciamento…).
--   * O sistema procura o primeiro nome dela no campo "responsável" de cada etapa
--     (ex.: "Isabella / Cris") e a vincula automaticamente como responsável padrão
--     dessas etapas e dos processos que já estão nelas.
--   * Por que pelo nome e não só pelo cargo: na mesma área há pessoas com etapas
--     diferentes (Projetos: Ana faz o Projeto, Alycia a Estimativa).
-- =====================================================================

alter table public.profiles add column if not exists cargo text;

-- lista de cargos para a tela de cadastro (liberada para quem ainda não está logado)
create or replace function public.cargos_disponiveis()
returns table (cargo text) language sql stable security definer set search_path = public as $$
  select area from (
    select area, min(ordem) as o from public.etapas
     where ativo and tipo <> 'final'
     group by area
  ) a
  order by o
$$;
revoke all on function public.cargos_disponiveis() from public;
grant execute on function public.cargos_disponiveis() to anon, authenticated;

create or replace function public.pc_normaliza(t text)
returns text language sql immutable as $$
  select translate(lower(trim(coalesce(t, ''))), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc')
$$;

-- vincula um usuário às etapas cujo "responsável" contém o primeiro nome dele
create or replace function public.vincular_usuario_etapas(p_user uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_nome text;
  v_ids int[];
begin
  select public.pc_normaliza(split_part(trim(nome), ' ', 1)) into v_nome from public.profiles where id = p_user;
  if v_nome is null or length(v_nome) < 2 then return 0; end if;

  select coalesce(array_agg(e.id), '{}') into v_ids
    from public.etapas e
   where e.responsaveis_label is not null
     and v_nome in (
       select trim(x) from regexp_split_to_table(public.pc_normaliza(e.responsaveis_label), '\s*[/,;&]\s*|\s+e\s+') x
     );

  if array_length(v_ids, 1) is null then return 0; end if;

  update public.etapas
     set responsaveis_padrao = array_append(responsaveis_padrao, p_user)
   where id = any(v_ids) and not (p_user = any(responsaveis_padrao));

  update public.processo_etapas
     set responsaveis = array_append(responsaveis, p_user)
   where etapa_id = any(v_ids) and status <> 'concluida' and not (p_user = any(responsaveis));

  return array_length(v_ids, 1);
end $$;
revoke all on function public.vincular_usuario_etapas(uuid) from public;

-- versão chamada pela tela (sempre para o próprio usuário logado)
create or replace function public.vincular_minhas_etapas()
returns int language sql security definer set search_path = public as $$
  select public.vincular_usuario_etapas(auth.uid())
$$;
revoke all on function public.vincular_minhas_etapas() from public;
grant execute on function public.vincular_minhas_etapas() to authenticated;

-- cadastro: grava nome + cargo e já vincula às etapas
create or replace function public.pc_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nome, email, cargo)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nome', new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.email,
    nullif(new.raw_user_meta_data->>'cargo', '')
  )
  on conflict (id) do update
    set email = excluded.email,
        nome  = coalesce(public.profiles.nome, excluded.nome),
        cargo = coalesce(public.profiles.cargo, excluded.cargo);

  perform public.vincular_usuario_etapas(new.id);
  return new;
end $$;

-- quem já tinha conta: tenta vincular agora
do $$
declare r record;
begin
  for r in select id from public.profiles loop
    perform public.vincular_usuario_etapas(r.id);
  end loop;
end $$;
