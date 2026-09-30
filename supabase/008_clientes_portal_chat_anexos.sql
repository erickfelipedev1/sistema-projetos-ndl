-- =====================================================================
-- 008 — Clientes + portal do cliente, chat interno com demandas, anexos
-- Rodar DEPOIS do 001–007 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tipo de usuário: equipe (padrão) ou cliente (portal)
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists tipo text not null default 'equipe';
do $$ begin
  alter table public.profiles add constraint profiles_tipo_chk check (tipo in ('equipe', 'cliente'));
exception when duplicate_object then null; end $$;
alter table public.profiles add column if not exists cliente_id uuid;

create or replace function public.is_equipe()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.tipo = 'equipe' from public.profiles p where p.id = auth.uid()), false)
$$;
grant execute on function public.is_equipe() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Clientes (um cliente tem vários processos; todo processo tem um cliente)
-- ---------------------------------------------------------------------
create table if not exists public.clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  cnpj text,
  contato text,
  email text,
  telefone text,
  observacoes text,
  created_at timestamptz not null default now()
);
create unique index if not exists clientes_nome_key on public.clientes (lower(trim(nome)));

do $$ begin
  alter table public.profiles add constraint profiles_cliente_fk foreign key (cliente_id) references public.clientes(id) on delete set null;
exception when duplicate_object then null; end $$;

alter table public.processos add column if not exists cliente_id uuid references public.clientes(id);

-- migração: um cliente por nome de empresa já usado nos processos
insert into public.clientes (nome, contato)
select distinct on (lower(trim(cliente))) trim(cliente), contato
  from public.processos
 where cliente_id is null and coalesce(trim(cliente), '') <> ''
 order by lower(trim(cliente)), created_at desc
on conflict do nothing;

update public.processos p set cliente_id = c.id
  from public.clientes c
 where p.cliente_id is null and lower(trim(c.nome)) = lower(trim(p.cliente));

-- garante o vínculo e mantém processos.cliente (nome) igual ao cadastro do cliente
create or replace function public.pc_processo_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.cliente_id is null then
    if coalesce(trim(new.cliente), '') = '' then
      raise exception 'Todo processo precisa de um cliente';
    end if;
    select id into new.cliente_id from public.clientes where lower(trim(nome)) = lower(trim(new.cliente));
    if new.cliente_id is null then
      insert into public.clientes (nome, contato) values (trim(new.cliente), new.contato) returning id into new.cliente_id;
    end if;
  end if;
  select nome into new.cliente from public.clientes where id = new.cliente_id;
  return new;
end $$;

drop trigger if exists pc_processo_cliente on public.processos;
create trigger pc_processo_cliente
  before insert or update of cliente_id, cliente on public.processos
  for each row execute function public.pc_processo_cliente();

create or replace function public.pc_cliente_renomeado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.nome is distinct from old.nome then
    update public.processos set cliente = new.nome where cliente_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists pc_cliente_renomeado on public.clientes;
create trigger pc_cliente_renomeado after update of nome on public.clientes
  for each row execute function public.pc_cliente_renomeado();

alter table public.processos alter column cliente_id set not null;
create index if not exists processos_cliente_idx on public.processos (cliente_id);

-- criar_processo agora aceita o cliente cadastrado
drop function if exists public.criar_processo(text, text, text, boolean);
create or replace function public.criar_processo(
  p_cliente text, p_plano text, p_descricao text default null, p_certificacao boolean default false, p_cliente_id uuid default null
) returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_primeira uuid;
  v_cert boolean := coalesce(p_certificacao, false);
begin
  if p_cliente_id is null and coalesce(trim(p_cliente), '') = '' then
    raise exception 'Informe o cliente';
  end if;

  insert into public.processos (cliente, cliente_id, plano, descricao, certificacao)
  values (coalesce(trim(p_cliente), ''), p_cliente_id, nullif(p_plano, ''), nullif(trim(p_descricao), ''), v_cert)
  returning id into v_id;

  insert into public.processo_etapas
    (processo_id, etapa_id, ordem, area, nome, tipo, prazo_dias_uteis, prazo_editavel, responsaveis, responsaveis_label)
  select v_id, e.id, row_number() over (order by e.ordem, e.id), e.area, e.nome, e.tipo,
         public.prazo_etapa(e, nullif(p_plano, ''), v_cert), e.prazo_editavel, e.responsaveis_padrao, e.responsaveis_label
  from public.etapas e
  where e.ativo;

  select id into v_primeira from public.processo_etapas where processo_id = v_id order by ordem limit 1;
  if v_primeira is null then
    raise exception 'Nenhuma etapa ativa configurada';
  end if;

  perform public.pc_iniciar_etapa(v_primeira);
  insert into public.processo_eventos (processo_id, tipo, texto) values (v_id, 'criado', 'Processo criado');
  return v_id;
end $$;
grant execute on function public.criar_processo(text, text, text, boolean, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Cadastro: tipo e cliente vindos do convite (contas de cliente são criadas pela equipe)
-- ---------------------------------------------------------------------
create or replace function public.pc_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tipo text := coalesce(nullif(new.raw_user_meta_data->>'tipo', ''), 'equipe');
begin
  if v_tipo not in ('equipe', 'cliente') then v_tipo := 'equipe'; end if;
  insert into public.profiles (id, nome, email, cargo, usuario, trocar_senha, tipo, cliente_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nome', new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.email,
    nullif(new.raw_user_meta_data->>'cargo', ''),
    nullif(new.raw_user_meta_data->>'usuario', ''),
    coalesce((new.raw_user_meta_data->>'trocar_senha')::boolean, false),
    v_tipo,
    case when v_tipo = 'cliente' then nullif(new.raw_user_meta_data->>'cliente_id', '')::uuid end
  )
  on conflict (id) do update
    set email   = excluded.email,
        nome    = coalesce(public.profiles.nome, excluded.nome),
        cargo   = coalesce(public.profiles.cargo, excluded.cargo),
        usuario = coalesce(public.profiles.usuario, excluded.usuario);

  if v_tipo = 'equipe' then
    perform public.vincular_usuario_etapas(new.id);
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Segurança: dados internos só para a equipe (clientes usam só o portal)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['etapas', 'feriados', 'processos', 'processo_etapas', 'processo_eventos',
                           'checklist_modelo', 'processo_checklist', 'email_modelos', 'textos', 'clientes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists pc_%1$s_all on public.%1$I', t);
    execute format('create policy pc_%1$s_all on public.%1$I for all to authenticated using (public.is_equipe()) with check (public.is_equipe())', t);
  end loop;
end $$;

-- ninguém muda o próprio tipo/cliente pelo app (só o servidor com a service role ou o SQL Editor)
create or replace function public.pc_profiles_protege_tipo()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and (new.tipo is distinct from old.tipo or new.cliente_id is distinct from old.cliente_id) then
    raise exception 'Não é permitido alterar o tipo de acesso';
  end if;
  return new;
end $$;
drop trigger if exists pc_profiles_protege_tipo on public.profiles;
create trigger pc_profiles_protege_tipo before update on public.profiles
  for each row execute function public.pc_profiles_protege_tipo();

drop policy if exists pc_profiles_select on public.profiles;
create policy pc_profiles_select on public.profiles for select to authenticated using (public.is_equipe() or id = auth.uid());

-- ---------------------------------------------------------------------
-- Portal do cliente: só etapas e datas (sem responsáveis, checklist, comentários, e-mails, anexos)
-- ---------------------------------------------------------------------
create or replace function public.previsao_processo(p_processo_id uuid)
returns date language sql stable security definer set search_path = public as $$
  select public.add_dias_uteis(
           greatest(coalesce(a.prazo_em, public.hoje_br()), public.hoje_br()),
           coalesce((select sum(coalesce(pe.prazo_dias_uteis, 0))::int from public.processo_etapas pe
                      where pe.processo_id = p_processo_id and pe.ordem > a.ordem), 0))
  from public.processo_etapas a
  where a.processo_id = p_processo_id and a.status = 'em_andamento'
  limit 1
$$;

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
                                  'iniciado_em', pe.iniciado_em, 'concluido_em', pe.concluido_em) order by pe.ordem)
                            from public.processo_etapas pe where pe.processo_id = p.id)
             ) order by (p.status = 'ativo') desc, p.created_at desc)
      from public.processos p
      where p.cliente_id = v_cliente and p.status <> 'cancelado'), '[]'::jsonb)
  );
end $$;
revoke all on function public.portal_processos(uuid) from public;
grant execute on function public.portal_processos(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Chat interno: canal Geral + conversas diretas; mensagens podem ser demandas
-- ---------------------------------------------------------------------
create table if not exists public.conversas (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('canal', 'direta')),
  nome text,
  created_at timestamptz not null default now()
);
create table if not exists public.conversa_membros (
  conversa_id uuid not null references public.conversas(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (conversa_id, user_id)
);
create table if not exists public.mensagens (
  id bigserial primary key,
  conversa_id uuid not null references public.conversas(id) on delete cascade,
  autor uuid not null references auth.users(id) default auth.uid(),
  texto text not null,
  processo_id uuid references public.processos(id) on delete set null,
  demanda_para uuid references auth.users(id),
  demanda_prazo date,
  demanda_status text check (demanda_status in ('aberta', 'concluida')),
  demanda_concluida_em timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists mensagens_conversa_idx on public.mensagens (conversa_id, created_at desc);
create index if not exists mensagens_demanda_idx on public.mensagens (demanda_para, demanda_status);
create table if not exists public.conversa_leituras (
  conversa_id uuid not null references public.conversas(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  lido_em timestamptz not null default now(),
  primary key (conversa_id, user_id)
);

insert into public.conversas (tipo, nome)
select 'canal', 'Geral' where not exists (select 1 from public.conversas where tipo = 'canal' and nome = 'Geral');

create or replace function public.chat_pode_ver(p_conversa uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_equipe() and exists (
    select 1 from public.conversas c
     where c.id = p_conversa
       and (c.tipo = 'canal' or exists (select 1 from public.conversa_membros m where m.conversa_id = c.id and m.user_id = auth.uid())))
$$;

-- abre (ou cria) a conversa direta com outra pessoa
create or replace function public.conversa_direta(p_outro uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public.is_equipe() then raise exception 'Sem acesso'; end if;
  if p_outro = auth.uid() then raise exception 'Escolha outra pessoa'; end if;
  select c.id into v from public.conversas c
   where c.tipo = 'direta'
     and exists (select 1 from public.conversa_membros m where m.conversa_id = c.id and m.user_id = auth.uid())
     and exists (select 1 from public.conversa_membros m where m.conversa_id = c.id and m.user_id = p_outro)
   limit 1;
  if v is null then
    insert into public.conversas (tipo) values ('direta') returning id into v;
    insert into public.conversa_membros values (v, auth.uid()), (v, p_outro);
  end if;
  return v;
end $$;
grant execute on function public.conversa_direta(uuid) to authenticated;

-- lista de conversas com última mensagem e não lidas
create or replace function public.chat_conversas()
returns table (id uuid, tipo text, nome text, outro_id uuid, ultima_texto text, ultima_em timestamptz, nao_lidas int)
language sql stable security definer set search_path = public as $$
  select c.id, c.tipo, c.nome,
         (select m.user_id from public.conversa_membros m where m.conversa_id = c.id and m.user_id <> auth.uid() limit 1),
         u.texto, u.created_at,
         (select count(*)::int from public.mensagens x
           where x.conversa_id = c.id and x.autor <> auth.uid()
             and x.created_at > coalesce((select l.lido_em from public.conversa_leituras l where l.conversa_id = c.id and l.user_id = auth.uid()), '-infinity'))
  from public.conversas c
  left join lateral (select texto, created_at from public.mensagens m where m.conversa_id = c.id order by created_at desc limit 1) u on true
  where public.chat_pode_ver(c.id)
  order by (c.tipo = 'canal') desc, u.created_at desc nulls last
$$;
grant execute on function public.chat_conversas() to authenticated;

alter table public.conversas enable row level security;
alter table public.conversa_membros enable row level security;
alter table public.mensagens enable row level security;
alter table public.conversa_leituras enable row level security;

drop policy if exists pc_conversas_select on public.conversas;
create policy pc_conversas_select on public.conversas for select to authenticated using (public.chat_pode_ver(id));
drop policy if exists pc_membros_select on public.conversa_membros;
create policy pc_membros_select on public.conversa_membros for select to authenticated using (public.chat_pode_ver(conversa_id));
drop policy if exists pc_mensagens_select on public.mensagens;
create policy pc_mensagens_select on public.mensagens for select to authenticated using (public.chat_pode_ver(conversa_id));
drop policy if exists pc_mensagens_insert on public.mensagens;
create policy pc_mensagens_insert on public.mensagens for insert to authenticated with check (public.chat_pode_ver(conversa_id) and autor = auth.uid());
drop policy if exists pc_mensagens_update on public.mensagens;
create policy pc_mensagens_update on public.mensagens for update to authenticated
  using (public.chat_pode_ver(conversa_id) and (autor = auth.uid() or demanda_para = auth.uid()))
  with check (public.chat_pode_ver(conversa_id));
drop policy if exists pc_leituras_all on public.conversa_leituras;
create policy pc_leituras_all on public.conversa_leituras for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- tempo real (Supabase Realtime), se disponível
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'mensagens') then
    execute 'alter publication supabase_realtime add table public.mensagens';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Anexos por etapa (arquivos no Supabase Storage, bucket privado "anexos")
-- ---------------------------------------------------------------------
create table if not exists public.anexos (
  id uuid primary key default gen_random_uuid(),
  processo_id uuid not null references public.processos(id) on delete cascade,
  processo_etapa_id uuid references public.processo_etapas(id) on delete set null,  -- null = arquivos gerais do cliente
  nome text not null,
  caminho text not null unique,
  tamanho bigint,
  tipo_mime text,
  autor uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists anexos_processo_idx on public.anexos (processo_id, created_at desc);
-- arquivos do cliente (sem processo): cliente_id preenchido e processo_id vazio
alter table public.anexos add column if not exists cliente_id uuid references public.clientes(id) on delete cascade;
alter table public.anexos alter column processo_id drop not null;
update public.anexos a set cliente_id = p.cliente_id from public.processos p where a.processo_id = p.id and a.cliente_id is null;
do $$ begin
  alter table public.anexos add constraint anexos_dono_chk check (processo_id is not null or cliente_id is not null);
exception when duplicate_object then null; end $$;
create index if not exists anexos_cliente_idx on public.anexos (cliente_id, created_at desc);

create or replace function public.pc_anexo_cliente()
returns trigger language plpgsql as $$
begin
  if new.processo_id is not null then
    select cliente_id into new.cliente_id from public.processos where id = new.processo_id;
  end if;
  return new;
end $$;
drop trigger if exists pc_anexo_cliente on public.anexos;
create trigger pc_anexo_cliente before insert or update of processo_id on public.anexos
  for each row execute function public.pc_anexo_cliente();
alter table public.anexos enable row level security;
drop policy if exists pc_anexos_all on public.anexos;
create policy pc_anexos_all on public.anexos for all to authenticated using (public.is_equipe()) with check (public.is_equipe());

do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public) values ('anexos', 'anexos', false) on conflict (id) do nothing;
    execute 'drop policy if exists pc_anexos_storage on storage.objects';
    execute $p$create policy pc_anexos_storage on storage.objects for all to authenticated
             using (bucket_id = 'anexos' and public.is_equipe())
             with check (bucket_id = 'anexos' and public.is_equipe())$p$;
  end if;
end $$;

notify pgrst, 'reload schema';
