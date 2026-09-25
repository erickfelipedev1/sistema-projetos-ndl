-- =====================================================================
-- Controle de Processos — estrutura do fluxo (substitui a estrutura de projetos)
-- Rodar no Supabase: SQL Editor > New query > colar tudo > Run
-- Pode rodar mais de uma vez sem quebrar (idempotente).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Perfis (um por usuário do Supabase Auth)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists nome text;
alter table public.profiles add column if not exists email text;

create or replace function public.pc_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nome, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nome', new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do update
    set email = excluded.email,
        nome  = coalesce(public.profiles.nome, excluded.nome);
  return new;
end $$;

drop trigger if exists pc_on_auth_user_created on auth.users;
create trigger pc_on_auth_user_created
  after insert on auth.users
  for each row execute function public.pc_handle_new_user();

-- usuários que já existiam antes desta migração
insert into public.profiles (id, nome, email)
select u.id,
       coalesce(u.raw_user_meta_data->>'nome', u.raw_user_meta_data->>'full_name', split_part(u.email, '@', 1)),
       u.email
from auth.users u
on conflict (id) do update
  set email = excluded.email,
      nome  = coalesce(public.profiles.nome, excluded.nome);

-- ---------------------------------------------------------------------
-- Configuração do fluxo
-- ---------------------------------------------------------------------
create table if not exists public.etapas (
  id serial primary key,
  ordem int not null,
  area text not null,
  nome text not null,
  tipo text not null default 'tarefa' check (tipo in ('tarefa', 'marco', 'final')),
  prazo_dias_uteis int check (prazo_dias_uteis is null or prazo_dias_uteis >= 0),
  prazo_editavel boolean not null default false,   -- ex.: Viagem (data de chegada varia)
  responsaveis_label text,                           -- texto exibido quando ainda não há usuário vinculado
  responsaveis_padrao uuid[] not null default '{}',  -- usuários atribuídos automaticamente
  ativo boolean not null default true
);

create table if not exists public.feriados (
  data date primary key,
  descricao text not null
);

-- ---------------------------------------------------------------------
-- Processos
-- ---------------------------------------------------------------------
create sequence if not exists public.processo_codigo_seq;

create table if not exists public.processos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique default ('PRC-' || lpad(nextval('public.processo_codigo_seq')::text, 4, '0')),
  cliente text not null,
  plano text check (plano in ('Flex', 'Premium', 'Full')),
  descricao text,
  status text not null default 'ativo' check (status in ('ativo', 'concluido', 'cancelado')),
  criado_por uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now(),
  concluido_em timestamptz
);

-- cada processo recebe uma "cópia" das etapas no momento da criação,
-- assim mudar a configuração depois não bagunça processos antigos
create table if not exists public.processo_etapas (
  id uuid primary key default gen_random_uuid(),
  processo_id uuid not null references public.processos(id) on delete cascade,
  etapa_id int references public.etapas(id) on delete set null,
  ordem int not null,
  area text not null,
  nome text not null,
  tipo text not null,
  prazo_dias_uteis int,
  prazo_editavel boolean not null default false,
  responsaveis uuid[] not null default '{}',
  responsaveis_label text,
  status text not null default 'pendente' check (status in ('pendente', 'em_andamento', 'concluida')),
  iniciado_em timestamptz,
  prazo_em date,
  concluido_em timestamptz,
  concluido_por uuid references auth.users(id),
  unique (processo_id, ordem)
);
create index if not exists processo_etapas_status_idx on public.processo_etapas (status);
create index if not exists processo_etapas_resp_idx on public.processo_etapas using gin (responsaveis);

create table if not exists public.processo_eventos (
  id bigserial primary key,
  processo_id uuid not null references public.processos(id) on delete cascade,
  autor uuid references auth.users(id) default auth.uid(),
  tipo text not null default 'comentario',  -- comentario | criado | avanco | retorno | prazo | responsavel | status
  texto text not null,
  created_at timestamptz not null default now()
);
create index if not exists processo_eventos_proc_idx on public.processo_eventos (processo_id, created_at desc);

-- ---------------------------------------------------------------------
-- Dias úteis
-- ---------------------------------------------------------------------
create or replace function public.hoje_br()
returns date language sql stable as $$
  select (now() at time zone 'America/Sao_Paulo')::date
$$;

create or replace function public.eh_dia_util(d date)
returns boolean language sql stable as $$
  select extract(isodow from d) < 6
     and not exists (select 1 from public.feriados f where f.data = d)
$$;

-- soma N dias úteis a uma data (a própria data de início não conta)
create or replace function public.add_dias_uteis(inicio date, n int)
returns date language plpgsql stable as $$
declare
  d date := inicio;
  c int := 0;
begin
  if inicio is null or n is null then return null; end if;
  while c < n loop
    d := d + 1;
    if public.eh_dia_util(d) then c := c + 1; end if;
  end loop;
  return d;
end $$;

-- quantidade de dias úteis no intervalo (a, b]; negativo se b < a
create or replace function public.dias_uteis_entre(a date, b date)
returns int language sql stable as $$
  select case
    when a is null or b is null then null
    when b >= a then (select count(*)::int from generate_series(a + 1, b, interval '1 day') g(d) where public.eh_dia_util(g.d::date))
    else -(select count(*)::int from generate_series(b + 1, a, interval '1 day') g(d) where public.eh_dia_util(g.d::date))
  end
$$;

-- ---------------------------------------------------------------------
-- Regras do fluxo
-- ---------------------------------------------------------------------
create or replace function public.pc_iniciar_etapa(p_pe_id uuid)
returns void language plpgsql as $$
begin
  update public.processo_etapas
     set status = 'em_andamento',
         iniciado_em = now(),
         prazo_em = public.add_dias_uteis(public.hoje_br(), prazo_dias_uteis),
         concluido_em = null,
         concluido_por = null
   where id = p_pe_id;
end $$;

create or replace function public.criar_processo(p_cliente text, p_plano text, p_descricao text default null)
returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_primeira uuid;
begin
  if coalesce(trim(p_cliente), '') = '' then
    raise exception 'Informe o cliente';
  end if;

  insert into public.processos (cliente, plano, descricao)
  values (trim(p_cliente), nullif(p_plano, ''), nullif(trim(p_descricao), ''))
  returning id into v_id;

  insert into public.processo_etapas
    (processo_id, etapa_id, ordem, area, nome, tipo, prazo_dias_uteis, prazo_editavel, responsaveis, responsaveis_label)
  select v_id, e.id, row_number() over (order by e.ordem, e.id), e.area, e.nome, e.tipo,
         e.prazo_dias_uteis, e.prazo_editavel, e.responsaveis_padrao, e.responsaveis_label
  from public.etapas e
  where e.ativo;

  select id into v_primeira from public.processo_etapas
   where processo_id = v_id order by ordem limit 1;

  if v_primeira is null then
    raise exception 'Nenhuma etapa ativa configurada';
  end if;

  perform public.pc_iniciar_etapa(v_primeira);

  insert into public.processo_eventos (processo_id, tipo, texto)
  values (v_id, 'criado', 'Processo criado');

  return v_id;
end $$;

-- conclui a etapa atual e inicia a próxima; ao chegar na etapa final, encerra o processo
create or replace function public.avancar_processo(p_processo_id uuid, p_obs text default null)
returns void language plpgsql as $$
declare
  v_atual public.processo_etapas;
  v_prox public.processo_etapas;
  v_txt text;
begin
  select * into v_atual from public.processo_etapas
   where processo_id = p_processo_id and status = 'em_andamento'
   order by ordem limit 1
   for update;

  if v_atual.id is null then
    raise exception 'Processo sem etapa em andamento';
  end if;

  update public.processo_etapas
     set status = 'concluida', concluido_em = now(), concluido_por = auth.uid()
   where id = v_atual.id;

  select * into v_prox from public.processo_etapas
   where processo_id = p_processo_id and status = 'pendente' and ordem > v_atual.ordem
   order by ordem limit 1;

  v_txt := 'Concluiu "' || v_atual.nome || '"';

  if v_prox.id is null or v_prox.tipo = 'final' then
    if v_prox.id is not null then
      update public.processo_etapas
         set status = 'concluida', iniciado_em = now(), concluido_em = now(), concluido_por = auth.uid()
       where id = v_prox.id;
    end if;
    update public.processos set status = 'concluido', concluido_em = now() where id = p_processo_id;
    v_txt := v_txt || ' — processo finalizado';
  else
    perform public.pc_iniciar_etapa(v_prox.id);
    v_txt := v_txt || ' → iniciou "' || v_prox.nome || '"';
  end if;

  if coalesce(trim(p_obs), '') <> '' then
    v_txt := v_txt || E'\n' || trim(p_obs);
  end if;

  insert into public.processo_eventos (processo_id, tipo, texto) values (p_processo_id, 'avanco', v_txt);
end $$;

-- desfaz o último avanço (para corrigir cliques errados)
create or replace function public.retornar_processo(p_processo_id uuid, p_motivo text default null)
returns void language plpgsql as $$
declare
  v_atual public.processo_etapas;
  v_ant public.processo_etapas;
  v_status text;
begin
  select status into v_status from public.processos where id = p_processo_id for update;

  if v_status = 'concluido' then
    -- reabre: volta para a última etapa não-final
    update public.processo_etapas set status = 'pendente', iniciado_em = null, concluido_em = null, concluido_por = null
     where processo_id = p_processo_id and tipo = 'final';
    select * into v_ant from public.processo_etapas
     where processo_id = p_processo_id and status = 'concluida' order by ordem desc limit 1;
    update public.processos set status = 'ativo', concluido_em = null where id = p_processo_id;
  else
    select * into v_atual from public.processo_etapas
     where processo_id = p_processo_id and status = 'em_andamento' order by ordem limit 1;
    if v_atual.id is null then raise exception 'Nada para retornar'; end if;
    select * into v_ant from public.processo_etapas
     where processo_id = p_processo_id and status = 'concluida' and ordem < v_atual.ordem order by ordem desc limit 1;
    if v_ant.id is null then raise exception 'Já está na primeira etapa'; end if;
    update public.processo_etapas set status = 'pendente', iniciado_em = null, prazo_em = null, concluido_em = null, concluido_por = null
     where id = v_atual.id;
  end if;

  update public.processo_etapas set status = 'em_andamento', concluido_em = null, concluido_por = null
   where id = v_ant.id;

  insert into public.processo_eventos (processo_id, tipo, texto)
  values (p_processo_id, 'retorno',
          'Retornou para "' || v_ant.nome || '"' || coalesce(E'\n' || nullif(trim(p_motivo), ''), ''));
end $$;

-- ---------------------------------------------------------------------
-- Views (respeitam o RLS de quem consulta)
-- ---------------------------------------------------------------------
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';

drop view if exists public.v_desempenho_etapas;
create view public.v_desempenho_etapas with (security_invoker = true) as
select e.id as etapa_id, e.ordem, e.area, e.nome, e.tipo, e.prazo_dias_uteis,
       count(pe.id) filter (where pe.status = 'concluida' and pe.tipo = 'tarefa')::int as concluidas,
       round(avg(public.dias_uteis_entre((pe.iniciado_em at time zone 'America/Sao_Paulo')::date,
                                         (pe.concluido_em at time zone 'America/Sao_Paulo')::date))
             filter (where pe.status = 'concluida' and pe.tipo = 'tarefa'), 1) as media_dias_uteis,
       count(pe.id) filter (where pe.status = 'concluida' and pe.prazo_em is not null
                              and (pe.concluido_em at time zone 'America/Sao_Paulo')::date > pe.prazo_em)::int as concluidas_com_atraso,
       count(pe.id) filter (where pe.status = 'em_andamento' and p.status = 'ativo')::int as em_andamento,
       count(pe.id) filter (where pe.status = 'em_andamento' and p.status = 'ativo'
                              and pe.prazo_em < public.hoje_br())::int as atrasadas_agora
from public.etapas e
left join public.processo_etapas pe on pe.etapa_id = e.id
left join public.processos p on p.id = pe.processo_id
where e.ativo
group by e.id
order by e.ordem;

-- ---------------------------------------------------------------------
-- Segurança (RLS): qualquer usuário logado da equipe pode ler e editar
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.etapas enable row level security;
alter table public.feriados enable row level security;
alter table public.processos enable row level security;
alter table public.processo_etapas enable row level security;
alter table public.processo_eventos enable row level security;

drop policy if exists pc_profiles_select on public.profiles;
create policy pc_profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists pc_profiles_update on public.profiles;
create policy pc_profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

do $$
declare t text;
begin
  foreach t in array array['etapas', 'feriados', 'processos', 'processo_etapas', 'processo_eventos'] loop
    execute format('drop policy if exists pc_%1$s_all on public.%1$I', t);
    execute format('create policy pc_%1$s_all on public.%1$I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

grant usage on sequence public.processo_codigo_seq to authenticated;
grant execute on function public.criar_processo(text, text, text) to authenticated;
grant execute on function public.avancar_processo(uuid, text) to authenticated;
grant execute on function public.retornar_processo(uuid, text) to authenticated;
grant execute on function public.add_dias_uteis(date, int) to authenticated;
grant execute on function public.dias_uteis_entre(date, date) to authenticated;
grant select on public.v_etapas_atuais, public.v_desempenho_etapas to authenticated;

-- ---------------------------------------------------------------------
-- Dados iniciais: fluxo atual (só insere se a tabela estiver vazia)
-- ---------------------------------------------------------------------
insert into public.etapas (ordem, area, nome, tipo, prazo_dias_uteis, prazo_editavel, responsaveis_label)
select * from (values
  (1,  'CS',            'Apresentação',                         'tarefa', 1,    false, 'Larissa'),
  (2,  'Projetos',      'Projeto (Flex / Premium / Full)',      'tarefa', 25,   false, 'Ana'),
  (3,  'Agenciamento',  'Cotação de frete',                     'tarefa', 1,    false, 'Isabella / Cris'),
  (4,  'Projetos',      'Estimativa de custo',                  'tarefa', 1,    false, 'Alycia'),
  (5,  'CX',            'Processo / Ordem / Pagamento',         'tarefa', 15,   false, 'Rodrigo'),
  (6,  'Agenciamento',  'Booking + Coleta + Estufagem',         'tarefa', 15,   false, 'Isabella'),
  (7,  'Logística',     'Viagem',                               'tarefa', 30,   true,  'Depende da viagem'),
  (8,  'Desembaraço',   'Desembaraço',                          'tarefa', 3,    false, 'Leonardo'),
  (9,  'Desembaraço',   'Liberado',                             'marco',  0,    false, null),
  (10, 'Transporte',    'Transporte',                           'tarefa', 5,    false, 'Cris'),
  (11, 'Entrega',       'Chegou',                               'final',  null, false, null)
) v(ordem, area, nome, tipo, prazo_dias_uteis, prazo_editavel, responsaveis_label)
where not exists (select 1 from public.etapas);

-- Feriados (nacionais + SP + Santos). Edite na tela Configurações.
insert into public.feriados (data, descricao) values
  ('2026-01-01', 'Confraternização Universal'),
  ('2026-01-26', 'Aniversário de Santos'),
  ('2026-02-16', 'Carnaval'),
  ('2026-02-17', 'Carnaval'),
  ('2026-04-03', 'Sexta-feira Santa'),
  ('2026-04-21', 'Tiradentes'),
  ('2026-05-01', 'Dia do Trabalho'),
  ('2026-06-04', 'Corpus Christi'),
  ('2026-07-09', 'Revolução Constitucionalista (SP)'),
  ('2026-09-07', 'Independência do Brasil'),
  ('2026-09-08', 'N. Sra. do Monte Serrat (Santos)'),
  ('2026-10-12', 'Nossa Senhora Aparecida'),
  ('2026-11-02', 'Finados'),
  ('2026-11-15', 'Proclamação da República'),
  ('2026-11-20', 'Consciência Negra'),
  ('2026-12-25', 'Natal'),
  ('2027-01-01', 'Confraternização Universal'),
  ('2027-01-26', 'Aniversário de Santos'),
  ('2027-02-08', 'Carnaval'),
  ('2027-02-09', 'Carnaval'),
  ('2027-03-26', 'Sexta-feira Santa'),
  ('2027-04-21', 'Tiradentes'),
  ('2027-05-01', 'Dia do Trabalho'),
  ('2027-05-27', 'Corpus Christi'),
  ('2027-07-09', 'Revolução Constitucionalista (SP)'),
  ('2027-09-07', 'Independência do Brasil'),
  ('2027-09-08', 'N. Sra. do Monte Serrat (Santos)'),
  ('2027-10-12', 'Nossa Senhora Aparecida'),
  ('2027-11-02', 'Finados'),
  ('2027-11-15', 'Proclamação da República'),
  ('2027-11-20', 'Consciência Negra'),
  ('2027-12-25', 'Natal')
on conflict (data) do nothing;
-- =====================================================================
-- 002 — Fluxo v2: prazo por plano, certificação e nova etapa
-- Rodar DEPOIS do 001, no SQL Editor do Supabase. Pode rodar mais de uma vez.
-- =====================================================================

-- Prazos específicos por plano e com certificação (vazio = usa o prazo padrão)
alter table public.etapas add column if not exists prazo_flex int;
alter table public.etapas add column if not exists prazo_full int;
alter table public.etapas add column if not exists prazo_premium int;
alter table public.etapas add column if not exists prazo_com_certificacao int;

alter table public.processos add column if not exists certificacao boolean not null default false;

-- prazo efetivo de uma etapa para um processo
create or replace function public.prazo_etapa(e public.etapas, p_plano text, p_certificacao boolean)
returns int language sql stable as $$
  select case
    when p_certificacao and e.prazo_com_certificacao is not null then e.prazo_com_certificacao
    when p_plano = 'Flex'    and e.prazo_flex    is not null then e.prazo_flex
    when p_plano = 'Full'    and e.prazo_full    is not null then e.prazo_full
    when p_plano = 'Premium' and e.prazo_premium is not null then e.prazo_premium
    else e.prazo_dias_uteis
  end
$$;

-- ---------------------------------------------------------------------
-- Criação de processo (substitui a versão do 001)
-- ---------------------------------------------------------------------
drop function if exists public.criar_processo(text, text, text);

create or replace function public.criar_processo(
  p_cliente text, p_plano text, p_descricao text default null, p_certificacao boolean default false
) returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_primeira uuid;
  v_cert boolean := coalesce(p_certificacao, false);
begin
  if coalesce(trim(p_cliente), '') = '' then
    raise exception 'Informe o cliente';
  end if;

  insert into public.processos (cliente, plano, descricao, certificacao)
  values (trim(p_cliente), nullif(p_plano, ''), nullif(trim(p_descricao), ''), v_cert)
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

grant execute on function public.criar_processo(text, text, text, boolean) to authenticated;

-- Recalcula prazos quando o plano ou a certificação do processo mudam
-- (etapas pendentes e a etapa em andamento; etapas concluídas não mudam)
create or replace function public.recalcular_prazos(p_processo_id uuid)
returns void language plpgsql as $$
declare
  v_plano text;
  v_cert boolean;
begin
  select plano, certificacao into v_plano, v_cert from public.processos where id = p_processo_id;

  update public.processo_etapas pe
     set prazo_dias_uteis = public.prazo_etapa(e, v_plano, v_cert)
    from public.etapas e
   where pe.etapa_id = e.id
     and pe.processo_id = p_processo_id
     and pe.status <> 'concluida';

  update public.processo_etapas pe
     set prazo_em = public.add_dias_uteis((pe.iniciado_em at time zone 'America/Sao_Paulo')::date, pe.prazo_dias_uteis)
   where pe.processo_id = p_processo_id
     and pe.status = 'em_andamento'
     and not pe.prazo_editavel;
end $$;

grant execute on function public.recalcular_prazos(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Views (colunas novas no final)
-- ---------------------------------------------------------------------
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada,
       p.certificacao
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';

drop view if exists public.v_desempenho_etapas;
create view public.v_desempenho_etapas with (security_invoker = true) as
select e.id as etapa_id, e.ordem, e.area, e.nome, e.tipo, e.prazo_dias_uteis,
       count(pe.id) filter (where pe.status = 'concluida' and pe.tipo = 'tarefa')::int as concluidas,
       round(avg(public.dias_uteis_entre((pe.iniciado_em at time zone 'America/Sao_Paulo')::date,
                                         (pe.concluido_em at time zone 'America/Sao_Paulo')::date))
             filter (where pe.status = 'concluida' and pe.tipo = 'tarefa'), 1) as media_dias_uteis,
       count(pe.id) filter (where pe.status = 'concluida' and pe.prazo_em is not null
                              and (pe.concluido_em at time zone 'America/Sao_Paulo')::date > pe.prazo_em)::int as concluidas_com_atraso,
       count(pe.id) filter (where pe.status = 'em_andamento' and p.status = 'ativo')::int as em_andamento,
       count(pe.id) filter (where pe.status = 'em_andamento' and p.status = 'ativo'
                              and pe.prazo_em < public.hoje_br())::int as atrasadas_agora,
       e.prazo_flex, e.prazo_full, e.prazo_premium, e.prazo_com_certificacao
from public.etapas e
left join public.processo_etapas pe on pe.etapa_id = e.id
left join public.processos p on p.id = pe.processo_id
where e.ativo
group by e.id
order by e.ordem;

-- ---------------------------------------------------------------------
-- Atualiza o fluxo para o novo fluxograma
-- ---------------------------------------------------------------------
update public.etapas set ordem = 1, nome = 'Apresentação / Montagem do projeto (planilha)', prazo_dias_uteis = 1
 where area = 'CS' and nome in ('Apresentação', 'Apresentação / Montagem do projeto (planilha)');

update public.etapas set ordem = 2, prazo_dias_uteis = 25, prazo_flex = 10, prazo_full = 15, prazo_premium = 25
 where nome = 'Projeto (Flex / Premium / Full)';

update public.etapas set ordem = 3, prazo_dias_uteis = 1, prazo_com_certificacao = 2
 where nome = 'Cotação de frete';

update public.etapas set ordem = 4, prazo_dias_uteis = 2
 where nome = 'Estimativa de custo';

insert into public.etapas (ordem, area, nome, tipo, prazo_dias_uteis, responsaveis_label)
select 5, 'CS', 'Apresentação da estimativa', 'tarefa', 1, 'Larissa'
where not exists (select 1 from public.etapas where nome = 'Apresentação da estimativa');

update public.etapas set ordem = 6  where nome = 'Processo / Ordem / Pagamento';
update public.etapas set ordem = 7  where nome = 'Booking + Coleta + Estufagem';
update public.etapas set ordem = 8  where nome = 'Viagem';
update public.etapas set ordem = 9  where nome = 'Desembaraço';
update public.etapas set ordem = 10 where nome = 'Liberado';
update public.etapas set ordem = 11 where nome = 'Transporte';
update public.etapas set ordem = 12 where nome = 'Chegou';
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
-- =====================================================================
-- 004 — Login por usuário (primeiro nome) + troca de senha no 1º acesso
-- Rodar DEPOIS do 001, 002 e 003. Pode rodar mais de uma vez.
-- =====================================================================

alter table public.profiles add column if not exists usuario text;
alter table public.profiles add column if not exists trocar_senha boolean not null default false;
create unique index if not exists profiles_usuario_key on public.profiles (usuario);

create or replace function public.pc_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nome, email, cargo, usuario, trocar_senha)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nome', new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.email,
    nullif(new.raw_user_meta_data->>'cargo', ''),
    nullif(new.raw_user_meta_data->>'usuario', ''),
    coalesce((new.raw_user_meta_data->>'trocar_senha')::boolean, false)
  )
  on conflict (id) do update
    set email   = excluded.email,
        nome    = coalesce(public.profiles.nome, excluded.nome),
        cargo   = coalesce(public.profiles.cargo, excluded.cargo),
        usuario = coalesce(public.profiles.usuario, excluded.usuario);

  perform public.vincular_usuario_etapas(new.id);
  return new;
end $$;
-- =====================================================================
-- 005 — Checklists por etapa + manual de Sourcing (14 passos)
-- Rodar DEPOIS do 001–004. Pode rodar mais de uma vez.
-- =====================================================================

-- modelo: itens de checklist de cada etapa (editável em Configurações)
create table if not exists public.checklist_modelo (
  id serial primary key,
  etapa_id int not null references public.etapas(id) on delete cascade,
  ordem int not null,
  titulo text not null,
  descricao text,
  ativo boolean not null default true
);
create index if not exists checklist_modelo_etapa_idx on public.checklist_modelo (etapa_id, ordem);

-- cópia do checklist em cada processo
create table if not exists public.processo_checklist (
  id uuid primary key default gen_random_uuid(),
  processo_etapa_id uuid not null references public.processo_etapas(id) on delete cascade,
  modelo_id int references public.checklist_modelo(id) on delete set null,
  ordem int not null,
  titulo text not null,
  descricao text,
  feito boolean not null default false,
  feito_por uuid references auth.users(id),
  feito_em timestamptz,
  unique (processo_etapa_id, modelo_id)
);
create index if not exists processo_checklist_pe_idx on public.processo_checklist (processo_etapa_id, ordem);

alter table public.checklist_modelo enable row level security;
alter table public.processo_checklist enable row level security;
drop policy if exists pc_checklist_modelo_all on public.checklist_modelo;
create policy pc_checklist_modelo_all on public.checklist_modelo for all to authenticated using (true) with check (true);
drop policy if exists pc_processo_checklist_all on public.processo_checklist;
create policy pc_processo_checklist_all on public.processo_checklist for all to authenticated using (true) with check (true);

-- toda etapa nova de processo recebe o checklist da etapa-modelo
create or replace function public.pc_copiar_checklist()
returns trigger language plpgsql as $$
begin
  if new.etapa_id is not null then
    insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao)
    select new.id, m.id, m.ordem, m.titulo, m.descricao
      from public.checklist_modelo m
     where m.etapa_id = new.etapa_id and m.ativo
    on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists pc_processo_etapa_checklist on public.processo_etapas;
create trigger pc_processo_etapa_checklist
  after insert on public.processo_etapas
  for each row execute function public.pc_copiar_checklist();

-- view: etapa atual + progresso do checklist (colunas novas no final)
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada,
       p.certificacao,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id) as checklist_total,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id and c.feito) as checklist_feitos
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';

-- ---------------------------------------------------------------------
-- Conteúdo: manual "Apresentação Sourcing — Bem-vindo ao time de projetos"
-- Passos 1–11 na etapa Projeto · 12–13 na Cotação de frete · 14 na Estimativa
-- (só insere se a etapa ainda não tiver checklist)
-- ---------------------------------------------------------------------
insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
select e.id, v.ordem, v.titulo, v.descricao
from public.etapas e
cross join (values
  (1, '1º Análise — início da busca de fornecedores',
      E'• Usar a planilha de apoio recebida do cliente para identificar as necessidades específicas do produto.\n• Analisar as fotos e especificações do produto para entender as características desejadas.\n• Identificar os critérios-chave: tipo de produto, tamanho, material, se há customização, tipo de embalagem, target price etc.'),
  (2, '2º Pesquisa de fornecedores online',
      E'• Usar plataformas chinesas: Alibaba, Made in China, Global Sources.\n• Pesquisar o nome do produto em português e em inglês (também dá para buscar por imagem).\n• Analisar os resultados e identificar fornecedores que atendam aos critérios da planilha de apoio.\n• Avaliar reputação, reviews, produtos oferecidos, dados da empresa e demais informações da conta do fornecedor.'),
  (3, '3º Contato com os fornecedores',
      E'• Selecionar os fornecedores que mais se adequam ao que o cliente solicitou.\n• Enviar a mensagem de saudação (modelo no Manual).\n• Informar especificações técnicas, quantidades necessárias e prazos de entrega esperados, de forma clara e organizada.\n• Solicitar cotação, catálogo, business license e certificados de conformidade.\n• Registrar os fornecedores e seus dados na planilha de fornecedores.'),
  (4, '4º Acompanhamento das respostas',
      E'• Monitorar diariamente os retornos (atenção ao fuso horário) e responder os questionamentos dos fornecedores.\n• Registrar os pontos discutidos no sistema e fazer upload dos arquivos.\n• Skybox: criar a pasta do cliente e organizar os documentos.\n• Alternativa: solicitar orçamento via RFQ ("Pedir uma cotação") para vários fornecedores de uma vez.\n• Comparar as cotações (preço, qualidade, quantidade, prazo de entrega e termos de pagamento) e colocar os melhores na planilha de fornecedores.'),
  (5, '5º Envio dos catálogos ao cliente',
      E'• Após a seleção dos fornecedores (quantidade conforme o tipo de sourcing), enviar ao cliente os catálogos editados, sem a marca dos fornecedores.'),
  (6, '6º Montagem do sourcing',
      E'• Passar a cotação dos fornecedores selecionados para a apresentação do cliente.'),
  (7, '7º Envio do sourcing ao cliente por e-mail',
      E'• Enviar o documento de sourcing por e-mail.\n• Verificar com o CS a disponibilidade do cliente para a reunião de sourcing.'),
  (8, '8º Reunião de sourcing',
      E'• Realizar a reunião de sourcing com todas as informações sobre os fornecedores.'),
  (9, '9º Envio do sourcing final por e-mail',
      E'• Após a reunião, passar a cotação do fornecedor escolhido para a apresentação e enviar ao cliente por e-mail.'),
  (10, '10º Solicitar Proforma Invoice e Packing List',
      E'Pedir ao fornecedor PI e PL com:\n• Incoterm (FOB - porto / EXW)\n• Total gross weight\n• Quantidade de caixas ou pallets (total)\n• Dimensões das caixas ou pallets\n• CBM (total)\n• HS Code'),
  (11, '11º Solicitar cotação de frete internacional',
      E'• Solicitar a cotação conforme o formulário do agenciamento e informar o número da referência.')
) v(ordem, titulo, descricao)
where e.nome = 'Projeto (Flex / Premium / Full)'
  and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
select e.id, v.ordem, v.titulo, v.descricao
from public.etapas e
cross join (values
  (12, '12º Recebimento do frete internacional e solicitação do rodoviário',
       E'• Após receber o frete internacional, solicitar a cotação do frete rodoviário.'),
  (13, '13º Recebimento do rodoviário e solicitação da estimativa de custos',
       E'• Preencher o formulário de estimativa de custos.\n• Enviar por e-mail junto com o formulário preenchido, PI, PL e planilha de apoio.')
) v(ordem, titulo, descricao)
where e.nome = 'Cotação de frete'
  and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
select e.id, 14, '14º Montagem da estimativa',
       E'• Classificação / verificação de NCM.\n• Montagem da estimativa.\n• Verificação da estimativa.\n• Envio da estimativa para o CS.'
from public.etapas e
where e.nome = 'Estimativa de custo'
  and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

-- processos que já existem recebem o checklist nas etapas ainda não concluídas
insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao)
select pe.id, m.id, m.ordem, m.titulo, m.descricao
  from public.processo_etapas pe
  join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
 where pe.status <> 'concluida'
on conflict do nothing;

-- Mensagem de saudação (usada no Manual, com o nome de quem está logado)
create table if not exists public.textos (
  chave text primary key,
  conteudo text not null
);
alter table public.textos enable row level security;
drop policy if exists pc_textos_all on public.textos;
create policy pc_textos_all on public.textos for all to authenticated using (true) with check (true);

insert into public.textos (chave, conteudo) values ('mensagem_saudacao',
'This is {nome} from Now Logistics Group from Santos - Brazil. I am responsible for searching and purchasing products because we help customers to buy from China. We are a custom clearance and logistics company, but we also have agents in Shenzhen. We have a customer who is looking for your products. Could you send me a quotation, catalog and business license, please?')
on conflict (chave) do nothing;
-- =====================================================================
-- 006 — Fechamento da ordem, com/sem gerenciamento e modelos de e-mail
-- Rodar DEPOIS do 001–005. Pode rodar mais de uma vez.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Novos campos do processo
-- ---------------------------------------------------------------------
alter table public.processos add column if not exists contato text;          -- nome da pessoa do cliente
alter table public.processos add column if not exists gerenciamento text;    -- 'ntl' (com gerenciamento) | 'proprio' (sem)
do $$ begin
  alter table public.processos add constraint processos_gerenciamento_chk check (gerenciamento in ('ntl', 'proprio'));
exception when duplicate_object then null; end $$;

-- item de checklist que só vale para um tipo de ordem
alter table public.checklist_modelo add column if not exists condicao text;  -- null = sempre | 'ntl' | 'proprio'
do $$ begin
  alter table public.checklist_modelo add constraint checklist_modelo_condicao_chk check (condicao in ('ntl', 'proprio'));
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Cópia do checklist respeitando o tipo de ordem
-- ---------------------------------------------------------------------
create or replace function public.pc_copiar_checklist()
returns trigger language plpgsql as $$
declare v_ger text;
begin
  if new.etapa_id is not null then
    select gerenciamento into v_ger from public.processos where id = new.processo_id;
    insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao)
    select new.id, m.id, m.ordem, m.titulo, m.descricao
      from public.checklist_modelo m
     where m.etapa_id = new.etapa_id and m.ativo
       and (m.condicao is null or m.condicao = v_ger)
    on conflict do nothing;
  end if;
  return new;
end $$;

-- quando o tipo de ordem muda: tira itens (não marcados) que não valem mais e inclui os que passaram a valer
create or replace function public.sincronizar_checklist(p_processo_id uuid)
returns void language plpgsql as $$
declare v_ger text;
begin
  select gerenciamento into v_ger from public.processos where id = p_processo_id;

  delete from public.processo_checklist c
   using public.processo_etapas pe, public.checklist_modelo m
   where c.processo_etapa_id = pe.id and c.modelo_id = m.id
     and pe.processo_id = p_processo_id and pe.status <> 'concluida'
     and not c.feito
     and m.condicao is not null and m.condicao is distinct from v_ger;

  insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao)
  select pe.id, m.id, m.ordem, m.titulo, m.descricao
    from public.processo_etapas pe
    join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
   where pe.processo_id = p_processo_id and pe.status <> 'concluida'
     and (m.condicao is null or m.condicao = v_ger)
  on conflict do nothing;
end $$;
grant execute on function public.sincronizar_checklist(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Projeto: consulta INPI (entre o 4º e o 5º passo)
-- ---------------------------------------------------------------------
do $$
declare v_etapa int;
begin
  select id into v_etapa from public.etapas where nome = 'Projeto (Flex / Premium / Full)';
  if v_etapa is null then return; end if;

  -- abre espaço na numeração (1,2,3… → 10,20,30…), só na primeira vez
  if (select max(ordem) from public.checklist_modelo where etapa_id = v_etapa) < 100 then
    update public.checklist_modelo set ordem = ordem * 10 where etapa_id = v_etapa;
    update public.processo_checklist c set ordem = m.ordem
      from public.checklist_modelo m where c.modelo_id = m.id and m.etapa_id = v_etapa;
  end if;

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
  select v_etapa, 45, 'Consulta de marca/patente no INPI (se o produto vier com marca ou logo)',
         E'• Quando o produto vem com a marca ou o logo do fabricante, confirmar se a empresa tem patente no Brasil ou representantes comerciais — mesmo que o fornecedor diga que não.\n• Consulta: busca.inpi.gov.br → Marca → Pesquisa básica → digitar a marca → pesquisar.'
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_etapa and ordem = 45);
end $$;

-- ---------------------------------------------------------------------
-- Checklists pós-fechamento (CX, Booking, Viagem, Transporte)
-- ---------------------------------------------------------------------
insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, condicao)
select e.id, v.ordem, v.titulo, v.descricao, v.condicao
from public.etapas e
cross join (values
  (10, 'Formalização de fechamento recebida (Matheus)',
       E'• O Matheus envia o e-mail "FORMALIZAÇÃO DE FECHAMENTO – EMPRESA – CLIENTE" ao responsável do projeto, com cópia para o time de projetos.\n• Deve conter a estimativa fechada, os detalhes relevantes da ordem e se tem gerenciamento com a NTL ou próprio (modelo em "E-mails").', null),
  (20, 'Conferir o projeto e encaminhar ao Rodrigo',
       E'• Verificar todas as informações do projeto (produto e personalizações) antes de enviar, para não perder nem enviar nada errado.\n• Complementar o e-mail do Matheus e encaminhar ao Rodrigo com PI, PL e demais documentos relevantes (peças de reposição, garantia, equipamentos, dados do fornecedor).', null),
  (30, 'Enviar o Formulário de Fechamento para a NTL',
       E'• Preencher o "Formulário de Fechamento" (Drive › Documentos) com todas as informações.\n• Enviar para trading@ntlimports.com e pedidosntlimport@gmail.com (a Natalia) com: Formulário de Fechamento, Proforma Invoice, Packing List, Swift do pagamento à NTL e outros documentos importantes.\n• Criar o grupo no WeChat.\n• Solicitar a CI (Commercial Invoice) à NTL.', 'ntl'),
  (30, 'Solicitar Commercial Invoice / Packing List ao fornecedor',
       E'• Solicitar CI e PL ao fornecedor.\n• Alinhar com o fornecedor o que deve ser produzido.\n• Confirmar o tempo de produção.', 'proprio'),
  (40, 'Validação da CI com a Marta ou o Leonardo',
       E'• Enviar a CI para leonardo@nlgcomex.com.br e marta.carvalho@nowlogistics.com.br com as informações do cliente, do fornecedor e da carga (modelo em "E-mails").\n• Só depois do "Okay" de um deles a CI pode ir para o cliente.', null),
  (50, 'Enviar a CI ao cliente para o pagamento inicial',
       E'• Enviar a CI em PDF solicitando o pagamento da porcentagem inicial (30% antes da produção, 70% antes do envio).\n• Informar o prazo de produção (10–14 dias úteis após o pagamento da primeira parte) e o contato da Karen (Advance) para câmbio.', null),
  (60, 'Swift e contrato de câmbio — pagamento à NTL',
       E'• Formalizar por e-mail o swift e o contrato de câmbio.\n• Enviar o swift para a NTL e pedir o contrato de câmbio (será necessário depois).\n• Verificar o recebimento do pagamento e o início da produção.', 'ntl'),
  (60, 'Swift e contrato de câmbio — pagamento ao fornecedor',
       E'• Formalizar por e-mail o swift e o contrato de câmbio.\n• Enviar o swift para o fornecedor.\n• Verificar o recebimento do pagamento.', 'proprio')
) v(ordem, titulo, descricao, condicao)
where e.nome = 'Processo / Ordem / Pagamento'
  and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, condicao)
select e.id, v.ordem, v.titulo, v.descricao, v.condicao
from public.etapas e
cross join (values
  (10, 'Fechamento do frete internacional',
       E'• O agenciamento atualiza a cotação se estiver vencida; se preciso, atualizar a estimativa de custos e reenviar ao cliente.\n• O fechamento é feito sobre a última cotação de frete internacional feita ou a que foi fechada.\n• E-mail com: contrato, PI, PL, Documento de Solicitação de Fechamento de Frete (Drive › Ordens › Documentos) e swift, além de endereço da fábrica, contato da fornecedora e Incoterm.', null),
  (15, 'Agenciamento em contato com o pessoal da NTL', E'• Verificar se está tudo certo com o fechamento.', 'ntl'),
  (15, 'Confirmar que o agenciamento conseguiu contato com o fornecedor', E'• Verificar se está tudo certo com o fechamento de frete.', 'proprio'),
  (20, 'Acompanhamento da produção', E'• Verificar sempre se está acontecendo como planejado.', null),
  (30, 'Data de produção e inspeção de qualidade',
       E'• Verificar se a data de produção não mudou.\n• Verificar a data marcada da inspeção de qualidade.\n• Enviar por e-mail o documento de inspeção para aprovação do cliente.', 'ntl'),
  (30, 'Fotos e vídeos do produto finalizado',
       E'• Com a produção finalizada, solicitar fotos e vídeos de cada produto.\n• Enviar as fotos e vídeos ao cliente por e-mail.', 'proprio'),
  (40, 'Aprovação do cliente e pagamento do restante (NTL)',
       E'• Formalizar para a NTL a aprovação do cliente.\n• Solicitar o pagamento do restante da CI.\n• Enviar o swift do pagamento para a NTL.', 'ntl'),
  (40, 'Aprovação do cliente e pagamento do restante (fornecedor)',
       E'• Solicitar o pagamento do restante da CI.\n• Enviar o swift para o fornecedor.', 'proprio'),
  (50, 'Packing List e shipping marks',
       E'• Verificar se a PL precisa de alteração e se as caixas têm shipping marks corretas.\n• Enviar a PL atualizada para o agenciamento, se houver.', 'ntl'),
  (50, 'Packing List, shipping marks e certificado de exportação',
       E'• Verificar se a PL precisa de alteração e se as caixas têm shipping marks corretas.\n• Enviar a PL atualizada para o agenciamento, se houver.\n• Verificar se o fornecedor tem certificado de exportação.', 'proprio'),
  (60, 'Draft do BL e envio do BL', E'• Acompanhar a aprovação do Draft do BL.\n• Acompanhar o envio do BL.', 'ntl'),
  (60, 'Draft do BL e envio do BL',
       E'• Acompanhar a aprovação do Draft do BL e pedir que o fornecedor envie para nós também.\n• Pedir cópia frente e verso do BL.\n• Acompanhar o envio do BL.', 'proprio')
) v(ordem, titulo, descricao, condicao)
where e.nome = 'Booking + Coleta + Estufagem'
  and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
select e.id, 10, 'Documentação e embarque',
       E'• Verificar se está tudo certo para o envio das documentações para o Brasil.\n• Acompanhar o embarque até a mercadoria chegar no Brasil.'
from public.etapas e
where e.nome = 'Viagem' and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
select e.id, v.ordem, v.titulo, v.descricao
from public.etapas e
cross join (values
  (10, 'Feedback do cliente sobre a chegada', E'• Verificar o feedback do cliente com relação à chegada da mercadoria no Brasil.'),
  (20, 'Cotar possível recompra', E'• Cotar uma possível recompra do cliente.')
) v(ordem, titulo, descricao)
where e.nome = 'Transporte' and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

-- processos existentes recebem os itens novos (sem condição) nas etapas não concluídas
insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao)
select pe.id, m.id, m.ordem, m.titulo, m.descricao
  from public.processo_etapas pe
  join public.processos p on p.id = pe.processo_id
  join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
 where pe.status <> 'concluida'
   and (m.condicao is null or m.condicao = p.gerenciamento)
on conflict do nothing;

-- ---------------------------------------------------------------------
-- Modelos de e-mail
-- Variáveis: {empresa} {contato} {plano} {meu_nome} {codigo}
--            {x_ntl} {x_proprio} (marcam "X" conforme o tipo de ordem)
-- ---------------------------------------------------------------------
create table if not exists public.email_modelos (
  id serial primary key,
  chave text unique not null,
  etapa_id int references public.etapas(id) on delete set null,
  ordem int not null default 0,
  titulo text not null,
  para text,
  assunto text,
  corpo text not null,
  condicao text check (condicao in ('ntl', 'proprio')),
  ativo boolean not null default true
);
alter table public.email_modelos enable row level security;
drop policy if exists pc_email_modelos_all on public.email_modelos;
create policy pc_email_modelos_all on public.email_modelos for all to authenticated using (true) with check (true);

insert into public.email_modelos (chave, etapa_id, ordem, titulo, para, assunto, corpo, condicao)
select v.chave, (select id from public.etapas where nome = v.etapa), v.ordem, v.titulo, v.para, v.assunto, v.corpo, v.condicao
from (values
  ('sourcing_entrega', 'Projeto (Flex / Premium / Full)', 10, 'Entrega do sourcing + agendamento da reunião', 'Cliente',
   'APRESENTAÇÃO DE SOURCING ({plano}) - {contato} - {empresa} - RES.:',
   E'Boa tarde/Bom dia, {contato}! Tudo bem?\n\nEu me chamo {meu_nome}, sou da equipe de Projetos, e estou responsável pelo seu projeto.\nEm anexo deixo o arquivo de Sourcing {plano}, com as cotações de três fornecedores, dos produtos do documento de referência.\n\nConforme combinado, nossa reunião está marcada para o dia XX/XX, às XXh. Durante o encontro, explicaremos os detalhes do documento e esclareceremos eventuais dúvidas.\n\nQualquer dúvida, estou à disposição.',
   null),
  ('sourcing_formalizacao_reuniao', 'Projeto (Flex / Premium / Full)', 20, 'Formalização da reunião de sourcing', 'Cliente',
   'FORMALIZAÇÃO DE REUNIÃO DE SOURCING - {empresa}',
   E'Bom dia a todos!\n\nSegue formalização da reunião realizada dia XX/XX/XXXX às XXhXX, com os clientes {empresa}.\n\n• Os clientes ficaram de analisar novamente o documento e nos passar um retorno em relação aos produtos e ao fornecedor escolhido.\n\nComo solicitado, estou enviando novamente o documento de Sourcing {plano}.\n\nQualquer dúvida, estou à disposição!',
   null),
  ('fechamento_formalizacao', 'Processo / Ordem / Pagamento', 10, 'Formalização de fechamento de ordem (Matheus)', 'Responsável do projeto · cópia: time de projetos',
   'FORMALIZAÇÃO DE FECHAMENTO - {empresa} - {contato}',
   E'Bom dia/Boa tarde, a todos! Tudo bem?\n\nGostaria de formalizar o fechamento do cliente {contato}, empresa {empresa}, que aprovou a estimativa de custos em anexo e realizou o pagamento pelos serviços da NTL (comprovante também em anexo).\n\nSegue abaixo o detalhamento do processo acordado:\n\n• Gerenciamento com a NTL: ({x_ntl})\n• Inspeção de qualidade com a NTL: ( )\n• Gerenciamento próprio da NLG: ({x_proprio})\n• Trading Company Turin: ( )\n• Desembaraço com a NLG: ( )\n• Frete internacional com a NLG: ( )\n• Frete rodoviário com a NLG: ( )\n\nDetalhes complementares sobre exigências ou critérios do cliente:\n• \n\nDetalhes de personalização que devem ser ressaltados:\n• ',
   null),
  ('fechamento_rodrigo', 'Processo / Ordem / Pagamento', 20, 'Encaminhamento ao Rodrigo', 'Rodrigo',
   'FORMALIZAÇÃO DE FECHAMENTO - {empresa} - {contato}',
   E'Boa tarde, Rodrigo! Tudo bem?\n\nConforme informado pelo CS, o cliente {contato}, da empresa {empresa}.\nDeixo em anexo a PI e PL que foram enviadas pelo fornecedor.\n\nSegue abaixo o detalhamento do processo acordado:\n• Gerenciamento com a NTL: ({x_ntl})\n• Gerenciamento próprio da NLG: ({x_proprio})\n• Trading Company Turin: ( )\n• Desembaraço com a NLG: ( )\n• Frete internacional com a NLG: ( )\n• Frete rodoviário com a NLG: ( )\n\nInformações importantes:\n• Peças de reposição:\n• Garantia:\n• Equipamentos:\n\nInformações do fornecedor:\nNome:\nEmpresa:\nTelefone:\nE-mail:',
   null),
  ('fechamento_ntl', 'Processo / Ordem / Pagamento', 30, 'Formulário de fechamento para a NTL', 'trading@ntlimports.com; pedidosntlimport@gmail.com',
   'FORMULÁRIO DE FECHAMENTO - {empresa}',
   E'Olá, Natalia! Tudo bem?\n\nSegue em anexo o Formulário de Fechamento da ordem da empresa {empresa}, junto com:\n• Formulário de Fechamento;\n• Proforma Invoice;\n• Packing List;\n• Swift do pagamento efetuado para a NTL;\n• (outros documentos importantes para o processo)\n\nPodemos seguir com a Commercial Invoice?\n\nQualquer dúvida, estou à disposição.',
   'ntl'),
  ('fechamento_validacao_ci', 'Processo / Ordem / Pagamento', 40, 'Validação da CI (Marta / Leonardo)', 'leonardo@nlgcomex.com.br; marta.carvalho@nowlogistics.com.br',
   'VALIDAÇÃO DA CI - {empresa}',
   E'Bom dia, a todos! Tudo bem?\n\nVenho por esse e-mail solicitar uma validação da CI.\nAbaixo tem informações relativas tanto ao cliente quanto ao fornecedor e a carga:\n\nInformações do cliente:\nNome da empresa: {empresa}\nEndereço do cliente:\nCNPJ do cliente:\nNome do contato: {contato}\nNúmero de contato:\nE-mail do responsável:\n\nInformações do fornecedor:\nNome da empresa:\nNome do fornecedor:\nNúmero do fornecedor:\nE-mail:\nEndereço da fábrica:\n\nInformações da carga:\nProduto:\nPeso líquido total:\nPeso bruto total:\nCBM total:\nValor total:\nIncoterm:\nHS code:\nNCM utilizado:',
   null),
  ('fechamento_pagamento_cliente', 'Processo / Ordem / Pagamento', 50, 'CI para pagamento do cliente (30/70)', 'Cliente',
   'COMMERCIAL INVOICE - {empresa}',
   E'Bom dia, {contato}! Tudo bem?\n\nSegue a Commercial Invoice para a realização dos trâmites de pagamento da ordem.\nOs termos de pagamento são de 30% antes da produção e 70% do valor restante antes do envio.\n\nInformações sobre os termos de pagamento embarque marítimo:\n• Valor de 30%:\n• Valor de 70%:\n• Valor total:\n\nPedimos que verifique as informações dos custos e produtos que constam no documento anexado (CI), em caso de dúvida estamos à disposição!\n\nAlém disso, encaminho o contato da Karen, da Advance, nossos parceiros para câmbio:\nKaren – Advance\nTelefone: (11) 91371-2581.\n\nInformações sobre os prazos de produção:\n10 – 14 dias úteis após o recebimento do pagamento da primeira parte.',
   null),
  ('frete_fechamento', 'Booking + Coleta + Estufagem', 10, 'Fechamento do frete internacional', 'Agenciamento',
   'FECHAMENTO DE FRETE INTERNACIONAL - {empresa}',
   E'Boa tarde, pessoal. Tudo bem?\n\nPor meio deste e-mail, venho formalizar o fechamento do frete internacional referente à empresa: {empresa}\n\nEm anexo, estou enviando:\n• Contrato;\n• Proforma Invoice;\n• Packing List;\n• Documento de solicitação de fechamento de frete;\n• Swift;\n\nSegue abaixo algumas informações do fornecedor:\nEndereço da fábrica:\nContato da fornecedora:\nIncoterm:',
   null)
) v(chave, etapa, ordem, titulo, para, assunto, corpo, condicao)
on conflict (chave) do nothing;

-- view: etapa atual com o tipo de ordem (coluna nova no final)
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada,
       p.certificacao,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id) as checklist_total,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id and c.feito) as checklist_feitos,
       p.gerenciamento
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';
-- =====================================================================
-- 007 — Situação da etapa ("por que está parado") e próxima ação
-- Rodar DEPOIS do 001–006. Pode rodar mais de uma vez.
-- =====================================================================

-- texto livre da etapa atual, ex.: "aguardando confirmação do fornecedor"
alter table public.processo_etapas add column if not exists situacao text;

create index if not exists processo_eventos_recentes_idx on public.processo_eventos (created_at desc);

-- view: + situação, próxima ação (1º item pendente do checklist) e última atualização
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada,
       p.certificacao,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id) as checklist_total,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id and c.feito) as checklist_feitos,
       p.gerenciamento,
       pe.situacao,
       (select c.titulo from public.processo_checklist c
         where c.processo_etapa_id = pe.id and not c.feito order by c.ordem limit 1) as proxima_acao,
       greatest(pe.iniciado_em,
                (select max(ev.created_at) from public.processo_eventos ev where ev.processo_id = p.id),
                (select max(c.feito_em) from public.processo_checklist c where c.processo_etapa_id = pe.id)) as ultima_atualizacao,
       p.contato
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';
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
-- =====================================================================
-- 009 — "Aguardando cliente": itens de checklist que pausam o prazo da etapa
--        + cobrança semanal + novos checklists de Onboarding (CS) e
--        Apresentação da estimativa (CS)
-- Rodar DEPOIS do 001–008 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- =====================================================================

-- item de espera: enquanto for o próximo item pendente, o prazo da etapa fica pausado.
-- quando o cliente responde (item marcado), a etapa ganha "prazo_depois" dias úteis para terminar.
alter table public.checklist_modelo  add column if not exists aguarda_cliente boolean not null default false;
alter table public.checklist_modelo  add column if not exists prazo_depois int;
alter table public.processo_checklist add column if not exists aguarda_cliente boolean not null default false;
alter table public.processo_checklist add column if not exists prazo_depois int;

alter table public.processo_etapas add column if not exists aguardando_cliente boolean not null default false;
alter table public.processo_etapas add column if not exists aguardando_desde timestamptz;
alter table public.processo_etapas add column if not exists ultima_cobranca timestamptz;
alter table public.processo_etapas add column if not exists retomado_em timestamptz;

-- cópia do checklist leva as colunas novas
create or replace function public.pc_copiar_checklist()
returns trigger language plpgsql as $$
begin
  if new.etapa_id is not null then
    insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
    select new.id, m.id, m.ordem, m.titulo, m.descricao, m.aguarda_cliente, m.prazo_depois
      from public.checklist_modelo m
     where m.etapa_id = new.etapa_id and m.ativo
       and (m.condicao is null or m.condicao = (select p.gerenciamento from public.processos p where p.id = new.processo_id))
    on conflict do nothing;
  end if;
  return new;
end $$;

create or replace function public.sincronizar_checklist(p_processo_id uuid)
returns void language plpgsql as $$
declare v_ger text;
begin
  select gerenciamento into v_ger from public.processos where id = p_processo_id;

  delete from public.processo_checklist c
   using public.processo_etapas pe, public.checklist_modelo m
   where c.processo_etapa_id = pe.id and c.modelo_id = m.id
     and pe.processo_id = p_processo_id and pe.status <> 'concluida'
     and not c.feito
     and ((m.condicao is not null and m.condicao is distinct from v_ger) or not m.ativo);

  insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
  select pe.id, m.id, m.ordem, m.titulo, m.descricao, m.aguarda_cliente, m.prazo_depois
    from public.processo_etapas pe
    join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
   where pe.processo_id = p_processo_id and pe.status <> 'concluida'
     and (m.condicao is null or m.condicao = v_ger)
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------
-- Estado de espera da etapa, calculado a partir do checklist
-- ---------------------------------------------------------------------
create or replace function public.pc_avaliar_espera(p_pe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  pe public.processo_etapas;
  v_prox public.processo_checklist;
  v_resp public.processo_checklist;
begin
  select * into pe from public.processo_etapas where id = p_pe_id;
  if pe.id is null then return; end if;

  if pe.status <> 'em_andamento' then
    if pe.aguardando_cliente or pe.retomado_em is not null then
      update public.processo_etapas set aguardando_cliente = false, aguardando_desde = null, retomado_em = null where id = pe.id;
    end if;
    return;
  end if;

  select * into v_prox from public.processo_checklist
   where processo_etapa_id = pe.id and not feito order by ordem limit 1;
  select * into v_resp from public.processo_checklist
   where processo_etapa_id = pe.id and feito and aguarda_cliente order by feito_em desc nulls last limit 1;

  if v_prox.id is not null and v_prox.aguarda_cliente then
    -- esperando o cliente: prazo pausado, cobrança semanal
    if not pe.aguardando_cliente then
      update public.processo_etapas
         set aguardando_cliente = true, aguardando_desde = now(), ultima_cobranca = null, retomado_em = null,
             prazo_em = case when prazo_editavel then prazo_em else null end
       where id = pe.id;
      insert into public.processo_eventos (processo_id, tipo, texto)
      values (pe.processo_id, 'espera', split_part(regexp_replace(v_prox.titulo, '^\d+º\s*', ''), ' — ', 1));
    end if;

  elsif v_resp.id is not null then
    -- cliente respondeu: novo prazo a partir da resposta
    if pe.aguardando_cliente or pe.retomado_em is distinct from v_resp.feito_em then
      update public.processo_etapas
         set aguardando_cliente = false, aguardando_desde = null, retomado_em = v_resp.feito_em,
             prazo_em = case when prazo_editavel then prazo_em
                             else public.add_dias_uteis((coalesce(v_resp.feito_em, now()) at time zone 'America/Sao_Paulo')::date,
                                                        coalesce(v_resp.prazo_depois, 1)) end
       where id = pe.id;
      if pe.aguardando_cliente then
        insert into public.processo_eventos (processo_id, tipo, texto)
        values (pe.processo_id, 'espera', 'Cliente respondeu — ' || case when coalesce(v_resp.prazo_depois, 1) = 1 then '1 dia útil' else coalesce(v_resp.prazo_depois, 1) || ' dias úteis' end || ' para concluir a etapa');
      end if;
    end if;

  elsif pe.aguardando_cliente or pe.retomado_em is not null then
    -- voltou para antes da espera: prazo original da etapa
    update public.processo_etapas
       set aguardando_cliente = false, aguardando_desde = null, retomado_em = null,
           prazo_em = case when prazo_editavel then prazo_em
                           else public.add_dias_uteis((iniciado_em at time zone 'America/Sao_Paulo')::date, prazo_dias_uteis) end
     where id = pe.id;
  end if;
end $$;

create or replace function public.pc_checklist_espera()
returns trigger language plpgsql as $$
begin
  perform public.pc_avaliar_espera(coalesce(new.processo_etapa_id, old.processo_etapa_id));
  return null;
end $$;

drop trigger if exists pc_checklist_espera on public.processo_checklist;
create trigger pc_checklist_espera
  after insert or delete or update of feito on public.processo_checklist
  for each row execute function public.pc_checklist_espera();

create or replace function public.pc_etapa_espera()
returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'em_andamento' and new.iniciado_em is distinct from old.iniciado_em then
      update public.processo_etapas set aguardando_cliente = false, aguardando_desde = null, ultima_cobranca = null, retomado_em = null
       where id = new.id;
    end if;
    perform public.pc_avaliar_espera(new.id);
  end if;
  return null;
end $$;

drop trigger if exists pc_etapa_espera on public.processo_etapas;
create trigger pc_etapa_espera
  after update of status on public.processo_etapas
  for each row execute function public.pc_etapa_espera();

-- recalcular prazos não mexe em etapa esperando o cliente ou já retomada
create or replace function public.recalcular_prazos(p_processo_id uuid)
returns void language plpgsql as $$
declare
  v_plano text;
  v_cert boolean;
begin
  select plano, certificacao into v_plano, v_cert from public.processos where id = p_processo_id;

  update public.processo_etapas pe
     set prazo_dias_uteis = public.prazo_etapa(e, v_plano, v_cert)
    from public.etapas e
   where pe.etapa_id = e.id
     and pe.processo_id = p_processo_id
     and pe.status <> 'concluida';

  update public.processo_etapas pe
     set prazo_em = public.add_dias_uteis((pe.iniciado_em at time zone 'America/Sao_Paulo')::date, pe.prazo_dias_uteis)
   where pe.processo_id = p_processo_id
     and pe.status = 'em_andamento'
     and not pe.prazo_editavel
     and not pe.aguardando_cliente
     and pe.retomado_em is null;
end $$;

-- registrar que o cliente foi cobrado (próxima cobrança = +7 dias)
create or replace function public.registrar_cobranca(p_pe_id uuid, p_obs text default null)
returns void language plpgsql as $$
declare pe public.processo_etapas;
begin
  update public.processo_etapas set ultima_cobranca = now()
   where id = p_pe_id and aguardando_cliente
  returning * into pe;
  if pe.id is null then raise exception 'Esta etapa não está aguardando o cliente'; end if;
  insert into public.processo_eventos (processo_id, tipo, texto)
  values (pe.processo_id, 'cobranca', 'Cliente cobrado' || coalesce(': ' || nullif(trim(p_obs), ''), ''));
end $$;
grant execute on function public.registrar_cobranca(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- View: + espera e cobrança
-- ---------------------------------------------------------------------
drop view if exists public.v_etapas_atuais;
create view public.v_etapas_atuais with (security_invoker = true) as
select pe.id, pe.processo_id, pe.etapa_id, pe.ordem, pe.area, pe.nome, pe.tipo,
       pe.prazo_dias_uteis, pe.prazo_editavel, pe.responsaveis, pe.responsaveis_label,
       pe.iniciado_em, pe.prazo_em,
       p.codigo, p.cliente, p.plano, p.descricao, p.created_at as processo_criado_em,
       public.dias_uteis_entre(public.hoje_br(), pe.prazo_em) as dias_restantes,
       (pe.prazo_em is not null and pe.prazo_em < public.hoje_br()) as atrasada,
       p.certificacao,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id) as checklist_total,
       (select count(*)::int from public.processo_checklist c where c.processo_etapa_id = pe.id and c.feito) as checklist_feitos,
       p.gerenciamento,
       pe.situacao,
       (select c.titulo from public.processo_checklist c
         where c.processo_etapa_id = pe.id and not c.feito order by c.ordem limit 1) as proxima_acao,
       greatest(pe.iniciado_em,
                (select max(ev.created_at) from public.processo_eventos ev where ev.processo_id = p.id),
                (select max(c.feito_em) from public.processo_checklist c where c.processo_etapa_id = pe.id)) as ultima_atualizacao,
       p.contato,
       pe.aguardando_cliente,
       pe.aguardando_desde,
       pe.ultima_cobranca,
       case when pe.aguardando_cliente
            then (coalesce(pe.ultima_cobranca, pe.aguardando_desde) at time zone 'America/Sao_Paulo')::date + 7 end as proxima_cobranca,
       (pe.aguardando_cliente
        and (coalesce(pe.ultima_cobranca, pe.aguardando_desde) at time zone 'America/Sao_Paulo')::date + 7 <= public.hoje_br()) as cobrar_hoje,
       p.cliente_id
from public.processo_etapas pe
join public.processos p on p.id = pe.processo_id
where pe.status = 'em_andamento' and p.status = 'ativo';
grant select on public.v_etapas_atuais to authenticated;

-- ---------------------------------------------------------------------
-- Fluxo: etapa 1 vira "Onboarding"
-- ---------------------------------------------------------------------
update public.etapas set nome = 'Onboarding'
 where ordem = 1 and area = 'CS' and nome in ('Apresentação', 'Apresentação / Montagem do projeto (planilha)');
update public.processo_etapas set nome = 'Onboarding'
 where area = 'CS' and nome in ('Apresentação', 'Apresentação / Montagem do projeto (planilha)');

-- Checklist do Onboarding (CS)
insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
select e.id, v.ordem, v.titulo, v.descricao, v.aguarda, v.depois
from public.etapas e
cross join (values
  (10, 'Criar e enviar o onboarding ao cliente',
       E'• Prazo: 1 dia útil a partir da abertura do processo.', false, null::int),
  (20, 'Enviar o formulário para o cliente preencher',
       E'• Enviar junto com o onboarding.', false, null),
  (30, 'Aguardando o formulário do cliente — cobrar toda semana',
       E'• Enquanto o cliente não devolve, o prazo fica pausado.\n• Toda semana o sistema avisa para cobrar o cliente (use "Registrar cobrança").\n• Marque este item quando o cliente enviar o formulário.', true, 1),
  (40, 'Enviar e-mail para Projetos com as informações do formulário',
       E'• Encaminhar ao time de Projetos as informações recebidas no formulário (modelo na aba E-mails).', false, null)
) v(ordem, titulo, descricao, aguarda, depois)
where e.nome = 'Onboarding'
  and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

-- Checklist da Apresentação da estimativa (CS)
insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
select e.id, v.ordem, v.titulo, v.descricao, v.aguarda, v.depois
from public.etapas e
cross join (values
  (10, 'Entrar em contato com o cliente e marcar a reunião de sourcing',
       E'• Prazo: 1 dia útil a partir do início da etapa.', false, null::int),
  (20, 'Aguardando a devolutiva do cliente — cobrar toda semana',
       E'• Enquanto o cliente não dá a devolutiva, o prazo fica pausado.\n• Toda semana o sistema avisa para cobrar o cliente (use "Registrar cobrança").\n• Marque este item quando o cliente responder.', true, 1),
  (30, 'Enviar a devolutiva do cliente para o CX',
       E'• Prazo: 1 dia útil depois da resposta do cliente (modelo na aba E-mails).', false, null)
) v(ordem, titulo, descricao, aguarda, depois)
where e.nome = 'Apresentação da estimativa'
  and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id);

-- processos que já estão nessas etapas (ou antes delas) recebem o checklist
insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
select pe.id, m.id, m.ordem, m.titulo, m.descricao, m.aguarda_cliente, m.prazo_depois
  from public.processo_etapas pe
  join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
  join public.etapas e on e.id = pe.etapa_id and e.nome in ('Onboarding', 'Apresentação da estimativa')
 where pe.status <> 'concluida'
on conflict do nothing;

-- Modelos de e-mail
insert into public.email_modelos (chave, etapa_id, ordem, titulo, para, assunto, corpo)
select v.chave, e.id, v.ordem, v.titulo, v.para, v.assunto, v.corpo
from (values
  ('onboarding_cobranca_formulario', 'Onboarding', 10, 'Cobrança do formulário (semanal)', 'Cliente',
   'Formulário do projeto — {empresa}',
   E'Olá, {contato}! Tudo bem?\n\nPassando para lembrar do formulário que enviamos junto com o onboarding. Com ele preenchido já conseguimos dar início ao seu projeto.\n\nQualquer dúvida, estou à disposição.\n\nAtenciosamente,\n{meu_nome}'),
  ('onboarding_projetos', 'Onboarding', 20, 'Formulário recebido → Projetos', 'Time de Projetos',
   'Formulário recebido — {empresa} ({codigo})',
   E'Olá, time de Projetos!\n\nO cliente {empresa} ({contato}) enviou o formulário. Seguem as informações para iniciarmos o projeto {codigo} — plano {plano}:\n\n[cole aqui as respostas do formulário / anexe o arquivo]\n\nAtenciosamente,\n{meu_nome}'),
  ('estimativa_reuniao_sourcing', 'Apresentação da estimativa', 10, 'Agendar reunião de sourcing', 'Cliente',
   'Reunião de sourcing — {empresa}',
   E'Olá, {contato}! Tudo bem?\n\nA estimativa de custos do seu projeto está pronta. Gostaria de agendar a reunião de sourcing para apresentarmos os resultados.\n\nQual o melhor dia e horário para você?\n\nAtenciosamente,\n{meu_nome}'),
  ('estimativa_cobranca_devolutiva', 'Apresentação da estimativa', 20, 'Cobrança da devolutiva (semanal)', 'Cliente',
   'Devolutiva do sourcing — {empresa}',
   E'Olá, {contato}! Tudo bem?\n\nPassando para saber se já tem uma devolutiva sobre a estimativa e o sourcing que apresentamos. Assim que tivermos o seu retorno, seguimos com as próximas etapas.\n\nFico à disposição.\n\nAtenciosamente,\n{meu_nome}'),
  ('estimativa_devolutiva_cx', 'Apresentação da estimativa', 30, 'Devolutiva do cliente → CX', 'Rodrigo (CX)',
   'Devolutiva do cliente — {empresa} ({codigo})',
   E'Olá, Rodrigo!\n\nO cliente {empresa} ({contato}) deu a devolutiva sobre a estimativa do processo {codigo}:\n\n[resumo da devolutiva do cliente]\n\nSegue para o processo/ordem/pagamento.\n\nAtenciosamente,\n{meu_nome}')
) v(chave, etapa, ordem, titulo, para, assunto, corpo)
join public.etapas e on e.nome = v.etapa
on conflict (chave) do nothing;

-- Portal: o cliente vê quando a etapa está esperando algo dele
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
                            from public.processo_etapas pe where pe.processo_id = p.id)
             ) order by (p.status = 'ativo') desc, p.created_at desc)
      from public.processos p
      where p.cliente_id = v_cliente and p.status <> 'cancelado'), '[]'::jsonb)
  );
end $$;
revoke all on function public.portal_processos(uuid) from public;
grant execute on function public.portal_processos(uuid) to authenticated;

-- recalcula o estado de espera das etapas em andamento
do $$
declare r record;
begin
  for r in select id from public.processo_etapas where status = 'em_andamento' loop
    perform public.pc_avaliar_espera(r.id);
  end loop;
end $$;

notify pgrst, 'reload schema';
-- =====================================================================
-- 010 — Cotação de frete e Estimativa de custo passam a ser itens do
--        checklist de Projetos (o prazo 10/15/25 já inclui tudo).
--        Itens do checklist podem ter responsáveis: quando o item anterior
--        é marcado, eles recebem uma DEMANDA automática no chat.
-- Rodar DEPOIS do 001–009 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- =====================================================================

-- responsáveis e prazo por item do checklist
alter table public.checklist_modelo add column if not exists responsaveis uuid[] not null default '{}';
alter table public.checklist_modelo add column if not exists responsaveis_label text;
alter table public.checklist_modelo add column if not exists prazo_item int;        -- dias úteis para o responsável
alter table public.checklist_modelo add column if not exists prazo_item_cert int;   -- idem, com certificação
alter table public.processo_checklist add column if not exists avisado_em timestamptz;

-- mensagem de demanda ligada a um item de checklist (concluir um conclui o outro)
alter table public.mensagens add column if not exists checklist_id uuid references public.processo_checklist(id) on delete set null;
create index if not exists mensagens_checklist_idx on public.mensagens (checklist_id);

-- ---------------------------------------------------------------------
-- Quem é avisado por um item: ids do modelo; se vazio, pelos nomes do rótulo
-- ---------------------------------------------------------------------
create or replace function public.pc_item_responsaveis(p_modelo_id int)
returns uuid[] language sql stable security definer set search_path = public as $$
  select case when coalesce(array_length(m.responsaveis, 1), 0) > 0 then m.responsaveis
         else coalesce((
           select array_agg(p.id) from public.profiles p
            where p.tipo = 'equipe' and m.responsaveis_label is not null
              and public.pc_normaliza(split_part(trim(p.nome), ' ', 1)) in (
                select trim(x) from regexp_split_to_table(public.pc_normaliza(m.responsaveis_label), '\s*[/,;&]\s*|\s+e\s+') x)
         ), '{}') end
  from public.checklist_modelo m where m.id = p_modelo_id
$$;

-- conversa direta entre duas pessoas (sem depender de quem está logado)
create or replace function public.pc_conversa_entre(p_a uuid, p_b uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if p_a = p_b then
    select id into v from public.conversas where tipo = 'canal' order by created_at limit 1;
    return v;
  end if;
  select c.id into v from public.conversas c
   where c.tipo = 'direta'
     and exists (select 1 from public.conversa_membros m where m.conversa_id = c.id and m.user_id = p_a)
     and exists (select 1 from public.conversa_membros m where m.conversa_id = c.id and m.user_id = p_b)
   limit 1;
  if v is null then
    insert into public.conversas (tipo) values ('direta') returning id into v;
    insert into public.conversa_membros values (v, p_a), (v, p_b);
  end if;
  return v;
end $$;

-- manda a demanda para os responsáveis do item (uma vez só)
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
  if it.id is null or it.feito or it.avisado_em is not null or it.modelo_id is null then return 0; end if;
  select * into pe from public.processo_etapas where id = it.processo_etapa_id;
  if pe.status <> 'em_andamento' then return 0; end if;
  select * into pr from public.processos where id = pe.processo_id;
  if pr.status <> 'ativo' then return 0; end if;
  select * into m from public.checklist_modelo where id = it.modelo_id;
  v_para := public.pc_item_responsaveis(it.modelo_id);
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

-- avisa os itens liberados de uma etapa: item com responsáveis cujo item anterior já foi feito
create or replace function public.pc_verificar_avisos(p_pe_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select c.id from public.processo_checklist c
     join public.checklist_modelo m on m.id = c.modelo_id
     where c.processo_etapa_id = p_pe_id and not c.feito and c.avisado_em is null
       and (coalesce(array_length(m.responsaveis, 1), 0) > 0 or m.responsaveis_label is not null)
       and coalesce((select a.feito from public.processo_checklist a
                      where a.processo_etapa_id = c.processo_etapa_id and a.ordem < c.ordem
                      order by a.ordem desc limit 1), true)
  loop
    perform public.pc_avisar_item(r.id);
  end loop;
end $$;

-- checklist mudou: conclui/reabre a demanda ligada e avisa o próximo
create or replace function public.pc_checklist_demandas()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.feito is distinct from old.feito then
    update public.mensagens
       set demanda_status = case when new.feito then 'concluida' else 'aberta' end,
           demanda_concluida_em = case when new.feito then now() end
     where checklist_id = new.id
       and demanda_status is distinct from (case when new.feito then 'concluida' else 'aberta' end);
  end if;
  perform public.pc_verificar_avisos(new.processo_etapa_id);
  return null;
end $$;

drop trigger if exists pc_checklist_demandas on public.processo_checklist;
create trigger pc_checklist_demandas
  after insert or update of feito on public.processo_checklist
  for each row execute function public.pc_checklist_demandas();

-- demanda concluída no chat marca o item do checklist
create or replace function public.pc_demanda_checklist()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.checklist_id is not null and new.demanda_status is distinct from old.demanda_status then
    if new.demanda_status = 'concluida' then
      update public.processo_checklist set feito = true, feito_em = now(), feito_por = coalesce(auth.uid(), new.demanda_para)
       where id = new.checklist_id and not feito;
    elsif new.demanda_status = 'aberta' then
      update public.processo_checklist set feito = false, feito_em = null, feito_por = null
       where id = new.checklist_id and feito;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists pc_demanda_checklist on public.mensagens;
create trigger pc_demanda_checklist
  after update of demanda_status on public.mensagens
  for each row execute function public.pc_demanda_checklist();

-- etapa começou: avisa quem já pode começar
create or replace function public.pc_etapa_espera()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'em_andamento' and new.iniciado_em is distinct from old.iniciado_em then
      update public.processo_etapas set aguardando_cliente = false, aguardando_desde = null, ultima_cobranca = null, retomado_em = null
       where id = new.id;
    end if;
    perform public.pc_avaliar_espera(new.id);
    if new.status = 'em_andamento' then perform public.pc_verificar_avisos(new.id); end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Novo checklist de Projetos (depois do 11º passo)
-- ---------------------------------------------------------------------
do $$
declare
  v_proj int; v_cot int; v_est int;
  v_cot_resp uuid[]; v_cot_label text; v_est_resp uuid[]; v_est_label text;
begin
  select id into v_proj from public.etapas where nome = 'Projeto (Flex / Premium / Full)';
  select id, responsaveis_padrao, responsaveis_label into v_cot, v_cot_resp, v_cot_label from public.etapas where nome = 'Cotação de frete';
  select id, responsaveis_padrao, responsaveis_label into v_est, v_est_resp, v_est_label from public.etapas where nome = 'Estimativa de custo';
  if v_proj is null then return; end if;

  -- passos 12, 13 e 14 vêm para dentro de Projetos
  update public.checklist_modelo set etapa_id = v_proj, ordem = 120 where etapa_id = v_cot and titulo like '12º%';
  update public.checklist_modelo set etapa_id = v_proj, ordem = 130 where etapa_id = v_cot and titulo like '13º%';
  update public.checklist_modelo set etapa_id = v_proj, ordem = 140,
         responsaveis = coalesce(v_est_resp, '{}'), responsaveis_label = coalesce(v_est_label, 'Alycia'), prazo_item = 2
   where etapa_id in (v_est, v_proj) and titulo like '14º%' and prazo_item is null;

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item, prazo_item_cert)
  select v_proj, 115, 'Cotação de frete internacional (Agenciamento)',
         E'• Agenciamento recebe a solicitação e devolve a cotação do frete internacional.\n• Prazo: 1 dia útil (2 com certificação).',
         coalesce(v_cot_resp, '{}'), coalesce(v_cot_label, 'Isabella / Cris'), 1, 2
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 115);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 125, 'Cotação de frete rodoviário (Agenciamento)',
         E'• Agenciamento devolve a cotação do frete rodoviário.\n• Prazo: 1 dia útil.',
         coalesce(v_cot_resp, '{}'), coalesce(v_cot_label, 'Isabella / Cris'), 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 125);

  -- as duas etapas deixam de existir no fluxo
  update public.etapas set ativo = false where id in (v_cot, v_est);
  update public.email_modelos set etapa_id = v_proj where etapa_id in (v_cot, v_est);

  -- -------------------------------------------------------------------
  -- Processos existentes
  -- -------------------------------------------------------------------
  if v_cot is null and v_est is null then return; end if;

  -- itens novos nas etapas de Projeto ainda não concluídas
  insert into public.processo_checklist (processo_etapa_id, modelo_id, ordem, titulo, descricao, aguarda_cliente, prazo_depois)
  select pe.id, m.id, m.ordem, m.titulo, m.descricao, m.aguarda_cliente, m.prazo_depois
    from public.processo_etapas pe
    join public.checklist_modelo m on m.etapa_id = pe.etapa_id and m.ativo
   where pe.etapa_id = v_proj
  on conflict do nothing;

  -- Projeto concluído + etapa antiga concluída → itens correspondentes marcados, com a data real
  update public.processo_checklist c
     set feito = true, feito_em = old.concluido_em, feito_por = old.concluido_por, avisado_em = coalesce(c.avisado_em, old.iniciado_em)
    from public.processo_etapas pj, public.processo_etapas old, public.checklist_modelo m
   where c.processo_etapa_id = pj.id and pj.etapa_id = v_proj and c.modelo_id = m.id
     and old.processo_id = pj.processo_id and old.status = 'concluida'
     and ((old.etapa_id = v_cot and m.ordem in (115, 120, 125, 130)) or (old.etapa_id = v_est and m.ordem = 140))
     and not c.feito;

  -- quem estava EM Cotação/Estimativa: os passos anteriores de Projetos já foram feitos
  update public.processo_checklist c
     set feito = true, feito_em = coalesce(pj.concluido_em, now()), feito_por = pj.concluido_por
    from public.processo_etapas pj, public.processo_etapas old
   where c.processo_etapa_id = pj.id and pj.etapa_id = v_proj
     and old.processo_id = pj.processo_id and old.status = 'em_andamento'
     and ((old.etapa_id = v_cot and c.ordem < 115) or (old.etapa_id = v_est and c.ordem < 140))
     and not c.feito;

  -- quem estava EM Cotação/Estimativa volta para Projetos (mesmo prazo original)
  update public.processo_etapas pj
     set status = 'em_andamento', concluido_em = null, concluido_por = null
    from public.processo_etapas old
   where pj.processo_id = old.processo_id and pj.etapa_id = v_proj
     and old.etapa_id in (v_cot, v_est) and old.status = 'em_andamento';

  -- remove as etapas antigas dos processos e renumera
  delete from public.processo_etapas where etapa_id in (v_cot, v_est);
end $$;

-- renumera o fluxo (etapas ativas) e as etapas de cada processo
with n as (select id, row_number() over (order by ordem, id) as o from public.etapas where ativo)
update public.etapas e set ordem = n.o from n where e.id = n.id and e.ordem <> n.o;
update public.etapas set ordem = ordem + 100 where not ativo and ordem < 100;

with n as (select id, row_number() over (partition by processo_id order by ordem, id) as o from public.processo_etapas)
update public.processo_etapas pe set ordem = n.o from n where pe.id = n.id and pe.ordem <> n.o;

-- avisa quem já pode começar nos processos em andamento
do $$
declare r record;
begin
  for r in select pe.id from public.processo_etapas pe join public.processos p on p.id = pe.processo_id
            where pe.status = 'em_andamento' and p.status = 'ativo' loop
    perform public.pc_verificar_avisos(r.id);
  end loop;
end $$;

alter function public.pc_checklist_espera() security definer set search_path = public;

-- funções internas: não ficam expostas na API
revoke all on function public.pc_item_responsaveis(int) from public, anon, authenticated;
revoke all on function public.pc_conversa_entre(uuid, uuid) from public, anon, authenticated;
revoke all on function public.pc_avisar_item(uuid) from public, anon, authenticated;
revoke all on function public.pc_verificar_avisos(uuid) from public, anon, authenticated;
revoke all on function public.pc_avaliar_espera(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
-- =====================================================================
-- 011 — Permissões por área
--   • Só quem é da área da etapa (cargo = área, ex.: CS no Onboarding), quem é
--     responsável pela etapa ou quem é administrador consegue marcar o checklist
--     e alterar a etapa (avançar, voltar, prazo, responsáveis, situação, cobrança).
--   • Itens com responsável próprio (ex.: cotação de frete → Isabella/Cris) só
--     podem ser marcados por esses responsáveis (ou administrador).
--   • Todos continuam vendo tudo.
-- Rodar DEPOIS do 001–010 (já incluído no 000_tudo.sql). Pode rodar mais de uma vez.
-- =====================================================================

alter table public.profiles add column if not exists admin boolean not null default false;

-- administradores iniciais: cargo de gestão/diretoria/coordenação
update public.profiles set admin = true
 where tipo = 'equipe' and not admin
   and public.pc_normaliza(coalesce(cargo, '')) ~ '^(gestao|gerencia|diretor|coordena|admin)';
-- se ainda não houver nenhum, o Erick vira administrador
update public.profiles set admin = true
 where tipo = 'equipe'
   and not exists (select 1 from public.profiles where admin)
   and (usuario like 'erick%' or email ilike 'erick%');

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.admin and p.tipo = 'equipe' from public.profiles p where p.id = auth.uid()), false)
$$;
grant execute on function public.is_admin() to authenticated;

-- pode alterar a etapa? (admin, responsável da etapa ou cargo = área da etapa)
create or replace function public.pode_editar_etapa(p_pe_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.processo_etapas pe, public.profiles me
     where pe.id = p_pe_id and me.id = auth.uid() and me.tipo = 'equipe'
       and (auth.uid() = any(pe.responsaveis)
            or public.pc_normaliza(coalesce(me.cargo, '')) = public.pc_normaliza(pe.area)))
$$;
grant execute on function public.pode_editar_etapa(uuid) to authenticated;

-- pode marcar o item? (item com responsável próprio: só ele; senão, regra da etapa)
create or replace function public.pode_marcar_item(p_item uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare it public.processo_checklist; v_resp uuid[];
begin
  select * into it from public.processo_checklist where id = p_item;
  if it.id is null then return false; end if;
  if public.is_admin() then return true; end if;
  if it.modelo_id is not null then
    v_resp := public.pc_item_responsaveis(it.modelo_id);
    if coalesce(array_length(v_resp, 1), 0) > 0 then return auth.uid() = any(v_resp); end if;
  end if;
  return public.pode_editar_etapa(it.processo_etapa_id);
end $$;
grant execute on function public.pode_marcar_item(uuid) to authenticated;

-- pode alterar o processo? (admin ou quem pode alterar a etapa atual)
create or replace function public.pode_editar_processo(p_processo_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or coalesce((
    select public.pode_editar_etapa(pe.id) from public.processo_etapas pe
     where pe.processo_id = p_processo_id and pe.status = 'em_andamento' order by pe.ordem limit 1), false)
$$;
grant execute on function public.pode_editar_processo(uuid) to authenticated;

create or replace function public.pc_sem_permissao(p_area text)
returns void language plpgsql as $$
begin
  raise exception 'Sem permissão: só quem é de % (ou responsável/administrador) pode alterar isto', coalesce(p_area, 'da área');
end $$;

-- ---------------------------------------------------------------------
-- Travas no banco (valem para qualquer acesso, não só pela tela)
--   pg_trigger_depth() = 1 → alteração feita direto pelo usuário (não em cascata)
--   pc.rpc = on           → alteração feita por uma função que já conferiu a permissão
-- ---------------------------------------------------------------------
create or replace function public.pc_trava_checklist()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_area text;
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if new.feito is distinct from old.feito and not public.pode_marcar_item(old.id) then
    if old.modelo_id is not null and coalesce(array_length(public.pc_item_responsaveis(old.modelo_id), 1), 0) > 0 then
      raise exception 'Sem permissão: este item é de %', (select string_agg(p.nome, ' / ') from public.profiles p
                                                            where p.id = any(public.pc_item_responsaveis(old.modelo_id)));
    end if;
    select area into v_area from public.processo_etapas where id = old.processo_etapa_id;
    raise exception 'Sem permissão: só quem é de % (ou responsável/administrador) pode marcar este item', coalesce(v_area, '—');
  end if;
  return new;
end $$;
drop trigger if exists pc_trava_checklist on public.processo_checklist;
create trigger pc_trava_checklist before update on public.processo_checklist
  for each row execute function public.pc_trava_checklist();

create or replace function public.pc_trava_etapa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if not public.pode_editar_etapa(old.id) then perform public.pc_sem_permissao(old.area); end if;
  return new;
end $$;
drop trigger if exists pc_trava_etapa on public.processo_etapas;
create trigger pc_trava_etapa before update on public.processo_etapas
  for each row execute function public.pc_trava_etapa();

create or replace function public.pc_trava_processo()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_area text;
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if not public.pode_editar_processo(old.id) then
    select area into v_area from public.processo_etapas where processo_id = old.id and status = 'em_andamento' order by ordem limit 1;
    perform public.pc_sem_permissao(v_area);
  end if;
  return new;
end $$;
drop trigger if exists pc_trava_processo on public.processos;
create trigger pc_trava_processo before update on public.processos
  for each row execute function public.pc_trava_processo();

-- demanda ligada a checklist: só quem recebeu (ou admin) conclui/reabre
create or replace function public.pc_trava_demanda()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if new.checklist_id is not null and new.demanda_status is distinct from old.demanda_status
     and auth.uid() is distinct from old.demanda_para and not public.is_admin() then
    raise exception 'Sem permissão: só quem recebeu a demanda pode concluir';
  end if;
  return new;
end $$;
drop trigger if exists pc_trava_demanda on public.mensagens;
create trigger pc_trava_demanda before update on public.mensagens
  for each row execute function public.pc_trava_demanda();

-- ninguém se promove a administrador pelo app
create or replace function public.pc_profiles_protege_tipo()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and (new.tipo is distinct from old.tipo or new.cliente_id is distinct from old.cliente_id) then
    raise exception 'Não é permitido alterar o tipo de acesso';
  end if;
  if auth.uid() is not null and new.admin is distinct from old.admin and not public.is_admin() then
    raise exception 'Só um administrador pode mudar quem é administrador';
  end if;
  -- o cargo define o que a pessoa pode alterar: depois de definido, só administrador muda
  if auth.uid() is not null and old.cargo is not null and new.cargo is distinct from old.cargo and not public.is_admin() then
    raise exception 'Só um administrador pode mudar o cargo';
  end if;
  return new;
end $$;

-- administrador define cargo e acesso de administrador de uma pessoa da equipe
drop function if exists public.definir_admin(uuid, boolean);
create or replace function public.definir_pessoa(p_user uuid, p_cargo text, p_admin boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Só um administrador pode fazer isso'; end if;
  if p_user = auth.uid() and not p_admin then raise exception 'Você não pode tirar o seu próprio acesso de administrador'; end if;
  update public.profiles set cargo = nullif(trim(p_cargo), ''), admin = p_admin where id = p_user and tipo = 'equipe';
end $$;
grant execute on function public.definir_pessoa(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Ações do processo com permissão conferida (usadas pela tela)
-- ---------------------------------------------------------------------
create or replace function public.pc_exigir_processo(p_processo_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_area text;
begin
  if not public.pode_editar_processo(p_processo_id) then
    select area into v_area from public.processo_etapas where processo_id = p_processo_id and status = 'em_andamento' order by ordem limit 1;
    perform public.pc_sem_permissao(v_area);
  end if;
  perform set_config('pc.rpc', 'on', true);
end $$;

create or replace function public.avancar_etapa(p_processo_id uuid, p_obs text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.pc_exigir_processo(p_processo_id);
  perform public.avancar_processo(p_processo_id, p_obs);
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.avancar_etapa(uuid, text) to authenticated;

create or replace function public.retornar_etapa(p_processo_id uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.processos where id = p_processo_id and status = 'concluido') then
    if not public.is_admin() then raise exception 'Só um administrador pode reabrir um processo concluído'; end if;
    perform set_config('pc.rpc', 'on', true);
  else
    perform public.pc_exigir_processo(p_processo_id);
  end if;
  perform public.retornar_processo(p_processo_id, p_motivo);
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.retornar_etapa(uuid, text) to authenticated;

-- editar dados / cancelar / reativar: admin ou quem pode alterar a etapa atual
create or replace function public.editar_dados_processo(p_processo_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.processos where id = p_processo_id and status <> 'ativo') then
    if not public.is_admin() then raise exception 'Só um administrador pode alterar um processo concluído ou cancelado'; end if;
  elsif not public.pode_editar_processo(p_processo_id) then
    perform public.pc_exigir_processo(p_processo_id);
  end if;
end $$;
grant execute on function public.editar_dados_processo(uuid) to authenticated;

create or replace function public.registrar_cobranca(p_pe_id uuid, p_obs text default null)
returns void language plpgsql as $$
declare pe public.processo_etapas;
begin
  select * into pe from public.processo_etapas where id = p_pe_id;
  if not public.pode_editar_etapa(p_pe_id) then perform public.pc_sem_permissao(pe.area); end if;
  update public.processo_etapas set ultima_cobranca = now()
   where id = p_pe_id and aguardando_cliente
  returning * into pe;
  if pe.id is null then raise exception 'Esta etapa não está aguardando o cliente'; end if;
  insert into public.processo_eventos (processo_id, tipo, texto)
  values (pe.processo_id, 'cobranca', 'Cliente cobrado' || coalesce(': ' || nullif(trim(p_obs), ''), ''));
end $$;

-- recalcular / sincronizar são chamados depois de editar dados: rodam como etapa do sistema
create or replace function public.recalcular_prazos_seguro(p_processo_id uuid)
returns void language plpgsql as $$
begin
  perform public.editar_dados_processo(p_processo_id);
  perform set_config('pc.rpc', 'on', true);
  perform public.recalcular_prazos(p_processo_id);
  perform public.sincronizar_checklist(p_processo_id);
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.recalcular_prazos_seguro(uuid) to authenticated;

-- criar processo (qualquer pessoa da equipe) já com contato e tipo de ordem
create or replace function public.criar_processo_completo(
  p_cliente text, p_plano text, p_descricao text default null, p_certificacao boolean default false,
  p_cliente_id uuid default null, p_contato text default null, p_gerenciamento text default null
) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  if not public.is_equipe() then raise exception 'Sem permissão'; end if;
  perform set_config('pc.rpc', 'on', true);
  v_id := public.criar_processo(p_cliente, p_plano, p_descricao, p_certificacao, p_cliente_id);
  if nullif(trim(p_contato), '') is not null or nullif(p_gerenciamento, '') is not null then
    update public.processos set contato = nullif(trim(p_contato), ''), gerenciamento = nullif(p_gerenciamento, '') where id = v_id;
    if nullif(p_gerenciamento, '') is not null then perform public.sincronizar_checklist(v_id); end if;
  end if;
  perform set_config('pc.rpc', 'off', true);
  return v_id;
end $$;
grant execute on function public.criar_processo_completo(text, text, text, boolean, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Configuração do fluxo (etapas, responsáveis padrão, checklists): só administrador altera
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['etapas', 'checklist_modelo'] loop
    execute format('drop policy if exists pc_%1$s_all on public.%1$I', t);
    execute format('drop policy if exists pc_%1$s_ler on public.%1$I', t);
    execute format('drop policy if exists pc_%1$s_admin on public.%1$I', t);
    execute format('create policy pc_%1$s_ler on public.%1$I for select to authenticated using (public.is_equipe())', t);
    execute format('create policy pc_%1$s_admin on public.%1$I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- vincular a pessoa às etapas (no cadastro/perfil) não esbarra na trava
create or replace function public.vincular_minhas_etapas()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('pc.rpc', 'on', true);
  n := public.vincular_usuario_etapas(auth.uid());
  perform set_config('pc.rpc', 'off', true);
  return n;
end $$;
revoke all on function public.vincular_minhas_etapas() from public;
grant execute on function public.vincular_minhas_etapas() to authenticated;

-- as versões antigas não ficam mais expostas (a tela usa as de cima)
revoke execute on function public.avancar_processo(uuid, text) from public, anon, authenticated;
revoke execute on function public.retornar_processo(uuid, text) from public, anon, authenticated;
revoke execute on function public.pc_exigir_processo(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
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
-- =====================================================================
-- 013 — Importação do quadro "Clientes | Projetos" do Monday (97 itens)
-- Rodar DEPOIS do 012. Pode rodar mais de uma vez (não duplica).
-- =====================================================================
select public.importar_monday($monday$[
{
"grupo": "ativo",
"monday_id": "11526300792",
"empresa": "AGROPECUARIA INOVACAO LTDA",
"cnpj": "32..411.713/0001-34",
"contato": "Fernando",
"plano": "Full",
"produto": "Pneu",
"inicio": "2026-03-17",
"termino": "2026-04-27",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 12:21 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: TBR-Quotation to Misaell.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868941351/TBR-Quotation to Misaell.pdf\n• Fornecedor 1: TBR-Thailand Quotation.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868941370/TBR-Thailand Quotation.pdf\n• Fornecedor 2: TBR QUOTATION-Frico.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868942727/TBR QUOTATION-Frico.pdf\n• Fornecedor 3: FRICO TIRE BRAZIL -FORLANDER -COMBODIA price list 2026.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868943412/FRICO TIRE BRAZIL -FORLANDER -COMBODIA price list 2026.xlsx\n• Fornecedor 4: Price List - Misaell Henrique 20260331.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868944201/Price List - Misaell Henrique 20260331.pdf"
},
{
"grupo": "ativo",
"monday_id": "11660048842",
"empresa": "LYRA COMERCIO E SERVICOS DE MATERIAIS ELETRICOS, ELETRONICOS E FERRAMENTAS LTDA",
"cnpj": "42.679.362/0001-09",
"contato": "Marivania",
"plano": "Full",
"produto": "Headset, fones, câmeras e carregadores",
"inicio": "2026-04-02",
"termino": "2026-05-14",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM"
},
{
"grupo": "ativo",
"monday_id": "11722555222",
"empresa": "GASNOW INTELIGENCIA DIGITAL LTDA",
"cnpj": "64.486.034/0001-10",
"contato": "Álvaro",
"plano": null,
"produto": "Balança para monitorar o peso do gás",
"inicio": "2026-04-13",
"termino": "2026-04-24",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - REMESSA EXPRESSA - 100 - FEDEX.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951850553/DOCUMENTO DE ESTIMATIVA DE CUSTOS - REMESSA EXPRESSA - 100 - FEDEX.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - REMESSA EXPRESSA - 300 - FEDEX.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951850896/DOCUMENTO DE ESTIMATIVA DE CUSTOS - REMESSA EXPRESSA - 300 - FEDEX.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - REMESSA EXPRESSA - 1000 - FEDEX.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951851263/DOCUMENTO DE ESTIMATIVA DE CUSTOS - REMESSA EXPRESSA - 1000 - FEDEX.xlsx"
},
{
"grupo": "ativo",
"monday_id": "11954586374",
"empresa": "WSM IMPORT EXPORT CONSULTING LTDA",
"cnpj": "41.865.179/0001-27",
"contato": "William",
"plano": "Full",
"produto": "Acessórios de moto, bicicleta de equilíbrio e máscaras LED",
"inicio": "2026-05-07",
"termino": "2026-06-05",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM"
},
{
"grupo": "ativo",
"monday_id": "12061888733",
"empresa": "SETE INDUSTRIA E COMERCIO LTDA",
"cnpj": "48.135.251/0001-00",
"contato": "Fabio",
"plano": "Premium",
"produto": "QUIMICOS E ADITIVOS RELACIONADOS",
"inicio": "2026-05-19",
"termino": "2026-07-02",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Gabriella Bucki\nServiço: Premium\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 12:24 PM"
},
{
"grupo": "ativo",
"monday_id": "12105360850",
"empresa": "DRI FOLHEADOS E ACESSORIOS",
"cnpj": "48.392.117/0001-94",
"contato": "Adriana",
"plano": "Premium",
"produto": "Semi-joias",
"inicio": "2026-05-25",
"termino": "2026-08-27",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 14, 2026 11:52 AM"
},
{
"grupo": "ativo",
"monday_id": "12155383330",
"empresa": "JS COMERCIO E ASSISTENCIA TECNICA FERRAMENTAS ELETRICAS LTDA",
"cnpj": "36.098.755/0001-18",
"contato": "Jairo",
"plano": "Full",
"produto": "Ferramentas e peças elétricas",
"inicio": "2026-05-29",
"termino": "2026-07-10",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 3:53 PM"
},
{
"grupo": "ativo",
"monday_id": "12229884874",
"empresa": "GMS COMERCIO DE MOTOS E ACESSORIOS LTDA",
"cnpj": "63.240.217/0001-99",
"contato": "Gustavo Machado",
"plano": "Full",
"produto": "Carregador para bicicleta, motor scooter moto, Pneu bike e scooter, pedais, triciclo, patinete, painel digital, bicicleta elétrica e ergométrica",
"inicio": "2026-06-08",
"termino": "2026-07-20",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 12, 2026 4:19 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: PI - SCOOTERS - 1.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3175267068/PI - SCOOTERS - 1.xlsx\n• Fornecedor 2: The parts quotation (3).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3175273263/The parts quotation (3).xlsx\n• Fornecedor 3: UPDATED QUOTATION (1).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3175278617/UPDATED QUOTATION (1).xlsx"
},
{
"grupo": "ativo",
"monday_id": "12241163337",
"empresa": "TRANSBEM INDUSTRIA E COMERCIO DE PECAS PARA VEICULOS LTDA",
"cnpj": "11.487.007/0001-04",
"contato": "LUCIANO",
"plano": "Full",
"produto": "Cinta amarrar carga, farol, presilha e lanterna",
"inicio": "2026-06-09",
"termino": "2026-07-21",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 24, 2026 2:21 PM"
},
{
"grupo": "ativo",
"monday_id": "12294146945",
"empresa": "IMPERIO DAS REDES LTDA",
"cnpj": "65.887.673/0001-50",
"contato": "Eduardo Martins",
"plano": "Full",
"produto": "Fio em multifilamento polipropileno",
"inicio": "2026-06-16",
"termino": "2026-06-28",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Ana Clara Ré Rosa\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 3:53 PM"
},
{
"grupo": "ativo",
"monday_id": "12419681239",
"empresa": "JARDIX COMERCIO DE PECAS E ACESSORIOS LTDA",
"cnpj": "40.691.322/0001-49",
"contato": "Vanessa",
"plano": "Full",
"produto": "vela de ignição, carburador, embreagem, conjunto de combustível, carretel de nylon, acelerador completo, tanque de combustível, porca lamina, filtro de combustível, carretel manual.",
"inicio": "2026-06-30",
"termino": "2026-07-27",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 14, 2026 11:52 AM"
},
{
"grupo": "ativo",
"monday_id": "12516278633",
"empresa": "ELYON DELIVERY IMPORTS & MARKETING - LTDA",
"cnpj": "56.422.757/0001-28",
"contato": "Diego Cruz",
"plano": "Full",
"produto": "Refletor, Plafon, Parafusa eira",
"inicio": "2026-07-13",
"termino": "2026-08-19",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 15, 2026 4:59 PM"
},
{
"grupo": "ativo",
"monday_id": "12519094418",
"empresa": "G D RUFINO LTDA",
"cnpj": "00.425.586/0001-36",
"contato": "Jesse",
"plano": "Full",
"produto": "Parafuso, Arruela, Porca, Chave combinada, Barras de Fibra de Carbono",
"inicio": "2026-07-13",
"termino": "2026-08-19",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 15, 2026 4:59 PM"
},
{
"grupo": "ativo",
"monday_id": "12543931680",
"empresa": "GIGA BIKE MOBILIDADE LTDA",
"cnpj": "66.326.467/0001-34",
"contato": "Marlon Vicentini",
"plano": "Full",
"produto": "motos elétricas",
"inicio": "2026-07-15",
"termino": "2026-08-25",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 15, 2026 5:02 PM"
},
{
"grupo": "ativo",
"monday_id": "12543943759",
"empresa": "IPBF COMERCIO LTDA",
"cnpj": "61.733.855/0001-16",
"contato": "Isabela e Patrícia",
"plano": "Premium",
"produto": "Abridor de Latas Elétrico Recarregável",
"inicio": "2026-07-15",
"termino": "2026-09-08",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 12, 2026 4:31 PM"
},
{
"grupo": "ativo",
"monday_id": "12561747140",
"empresa": "PORTAS CAPIXABA LTDA",
"cnpj": "09.449.880/0001-52",
"contato": "Cristiano de Sales Roldi",
"plano": "Full",
"produto": "Porta com montante em madeira",
"inicio": "2026-07-17",
"termino": "2026-08-28",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 12, 2026 4:32 PM"
},
{
"grupo": "ativo",
"monday_id": "12649040181",
"empresa": "ELPLAY MOBILIDADE LTDA",
"cnpj": "23.610.374/0001-24",
"contato": "Sergio",
"plano": null,
"produto": "electric mountain bike",
"inicio": "2026-07-28",
"termino": "2026-08-14",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nPessoas: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 28, 2026 10:21 AM"
},
{
"grupo": "ativo",
"monday_id": "12649377841",
"empresa": "SABRIMAR MATERIAIS DE CONSTRUCAO LTDA",
"cnpj": "05.886.568/0001-75",
"contato": "Marcio",
"plano": "Full",
"produto": "Hikvision NVR, CCTV, Switch Hikvision, HIKVISION HUB",
"inicio": "2026-07-28",
"termino": "2026-09-07",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 28, 2026 10:55 AM"
},
{
"grupo": "ativo",
"monday_id": "12676895559",
"empresa": "CARBUS PECAS E ACESSORIOS LTDA",
"cnpj": "05.060.510/0001-78",
"contato": "Robson Silva",
"plano": "Premium",
"produto": "Piso vinílico, autopeças e chapa de alumínio",
"inicio": "2026-07-30",
"termino": "2026-09-18",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 30, 2026 5:37 PM"
},
{
"grupo": "ativo",
"monday_id": "12677019283",
"empresa": "TRATORUNO PECAS E SERVICOS PARA TRATORES LTDA",
"cnpj": "02.819.698/0001-05",
"contato": "Bruno",
"plano": "Full",
"produto": "Chapa de aço",
"inicio": "2026-07-30",
"termino": "2026-08-30",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Aug 6, 2026 12:16 PM"
},
{
"grupo": "ativo",
"monday_id": "12736189331",
"empresa": "WEVOLTS IMPORTACAO E COMERCIO LTDA",
"cnpj": "67.112.674/0001-59",
"contato": "Leandro",
"plano": "Full",
"produto": "Moto Elétrica",
"inicio": "2026-08-06",
"termino": "2026-09-15",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:44 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190990376/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190990465/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2.xlsx"
},
{
"grupo": "ativo",
"monday_id": "12749331517",
"empresa": "WALKRUNNER FITNESS LTDA",
"cnpj": "67.517.564/0001-77",
"contato": "Leonildo Alves de Lima",
"plano": null,
"produto": "Academia",
"inicio": "2026-08-07",
"termino": "2026-08-28",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:44 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - LEONILDO - FOB.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190989164/DOCUMENTO DE ESTIMATIVA DE CUSTOS - LEONILDO - FOB.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - LEONILDO - EXW.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190989693/DOCUMENTO DE ESTIMATIVA DE CUSTOS - LEONILDO - EXW.xlsx"
},
{
"grupo": "ativo",
"monday_id": "12788688399",
"empresa": "KAWA7 COMERCIO VREJISTA DE MATERIAIS ELETRICOS HIDRAULICOS FERRAGENS E FERRAMENTAS LTDA",
"cnpj": "53.998.583/0001-58",
"contato": "Cristiano",
"plano": "Premium",
"produto": "Peças hidráulicas",
"inicio": "2026-08-12",
"termino": "2026-10-09",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Aug 12, 2026 5:30 PM"
},
{
"grupo": "ativo",
"monday_id": "12789000122",
"empresa": "UNI3 SOLUCOES PROMOCIONAIS IMPORTADORA E EXPORTADORA LTDA",
"cnpj": "65.768.388/0001-10",
"contato": "Mauricio",
"plano": "Full",
"produto": "Marca texto, garrafa e caneca",
"inicio": "2026-08-12",
"termino": "2026-09-22",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Aug 12, 2026 6:06 PM"
},
{
"grupo": "ativo",
"monday_id": "12808266720",
"empresa": "FAMILIA BILINGUE IDIOMAS LTDA",
"cnpj": "37.837.735/0001-84",
"contato": "Abdaliana",
"plano": "Full",
"produto": "Livros",
"inicio": "2026-08-14",
"termino": "2026-09-24",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Aug 14, 2026 5:20 PM"
},
{
"grupo": "ativo",
"monday_id": "12853417924",
"empresa": "DIAMOND CAR ELETRICOS LTDA",
"cnpj": "44.989.477/0001-17",
"contato": "Thalita",
"plano": "Premium",
"produto": "carrinho elétrico para criança",
"inicio": "2026-08-20",
"termino": "2026-10-05",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 24, 2026 2:40 PM"
},
{
"grupo": "ativo",
"monday_id": "12945356698",
"empresa": "SAFE BRASIL COMERCIO E LOCACAO DE EQUIPAMENTOS LTDA",
"cnpj": "18.074.238/0001-27",
"contato": "André",
"plano": "Full",
"produto": "Motor e mecanismo que reduz velocidade",
"inicio": "2026-09-01",
"termino": "2026-09-30",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 9:47 AM"
},
{
"grupo": "ativo",
"monday_id": "12946717749",
"empresa": "M & F MÁQUINAS E FERRAMENTAS",
"cnpj": "23.875.559/0001-60",
"contato": "Felipe",
"plano": "Premium",
"produto": "partes e peças",
"inicio": "2026-09-01",
"termino": "2026-10-12",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 1:04 PM"
},
{
"grupo": "ativo",
"monday_id": "12950668260",
"empresa": "STOFF-CAR BANCOS PARA VANS LTDA",
"cnpj": "47.431.596/0001-48",
"contato": "Jomar Souza Santos",
"plano": "Premium",
"produto": "Máquina e bancos",
"inicio": "2026-09-01",
"termino": "2026-10-15",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 4:05 PM"
},
{
"grupo": "ativo",
"monday_id": "12951078173",
"empresa": "OTZ GESTAO EMPRESARIAL LTDA",
"cnpj": "37.241.683/0001-89",
"contato": "Tigmos",
"plano": "Full",
"produto": "Motos elétricas",
"inicio": "2026-09-01",
"termino": "2026-10-01",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 4:33 PM"
},
{
"grupo": "ativo",
"monday_id": "12951345739",
"empresa": "BRUNO RAFAEL GRISOTTO",
"cnpj": "31.542.063/0001-01",
"contato": "Cesar",
"plano": "Full",
"produto": "chapas de vidro",
"inicio": "2026-09-01",
"termino": "2026-10-01",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 4:56 PM"
},
{
"grupo": "ativo",
"monday_id": "12951505208",
"empresa": "DIAS & PARIZOTTO MULTIMARCAS LTDA",
"cnpj": "42.514.980/0001-90",
"contato": "Ivanir A. D. Parizotto",
"plano": "Premium",
"produto": "Utensílios domésticos",
"inicio": "2026-09-01",
"termino": "2026-10-15",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 5:43 PM"
},
{
"grupo": "ativo",
"monday_id": "12951856895",
"empresa": "APPARATUS BRASIL INDUSTRIA IMPORTACAO EXPORTACAO E COMERCIO DE EQUIPAMENTOS ESPORTIVOS LTDA",
"cnpj": "45.894.140/0001-99",
"contato": "Luciano",
"plano": null,
"produto": "Equipamento de ginastica",
"inicio": "2026-09-01",
"termino": "2026-09-23",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 5:43 PM"
},
{
"grupo": "ativo",
"monday_id": "12952048552",
"empresa": "SOLICITAÇÃO DE PESQUISA - CANTON FAIR - PESQUISA HOSPITALAR - ALEXANDRE E CARLA",
"cnpj": null,
"contato": null,
"plano": null,
"produto": "SOLICITAÇÃO DE PESQUISA",
"inicio": "2026-09-01",
"termino": "2026-09-30",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 1, 2026 6:02 PM"
},
{
"grupo": "ativo",
"monday_id": "12956284392",
"empresa": "TIINK COSMETICOS LTDA",
"cnpj": "35.612.594/0001-76",
"contato": "Camila Oliveira Marcelino",
"plano": "Full",
"produto": "produtos de beleza",
"inicio": "2026-09-02",
"termino": "2026-10-01",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 2, 2026 9:16 AM"
},
{
"grupo": "ativo",
"monday_id": "13006481669",
"empresa": "MAGAZINE CAMARGOS VALLE LTDA",
"cnpj": "37.281.514/0001-72",
"contato": "Bruno",
"plano": null,
"produto": "Panela",
"inicio": "2026-09-09",
"termino": "2026-09-23",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 15, 2026 5:58 PM"
},
{
"grupo": "ativo",
"monday_id": "13039612128",
"empresa": "ASSOCIACAO DA GINASTICA DE TRAMPOLIM DE CONTAGEM",
"cnpj": "32.026.741/0001-38",
"contato": "Luciano",
"plano": null,
"produto": "TELA DE SALTO PARA TRAMPOLIN",
"inicio": "2026-09-14",
"termino": "2026-09-28",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 15, 2026 6:01 PM"
},
{
"grupo": "ativo",
"monday_id": "13054513576",
"empresa": "GL INFO SOM LTDA",
"cnpj": "13.687.627/0001-04",
"contato": "Gustavo",
"plano": null,
"produto": "iluminação",
"inicio": "2026-09-09",
"termino": "2026-09-24",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 15, 2026 5:58 PM"
},
{
"grupo": "ativo",
"monday_id": "13064558615",
"empresa": "Alfredo e Laertes (sem empresa)",
"cnpj": null,
"contato": "Alfredo e Laertes",
"plano": "Premium",
"produto": "PET, Utensílios, Organização de Cozinha, Decoração e Organização da Casa",
"inicio": "2026-09-14",
"termino": "2026-10-28",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 16, 2026 6:49 PM"
},
{
"grupo": "ativo",
"monday_id": "13064602780",
"empresa": "Ronney e Fabricio (sem empresa)",
"cnpj": null,
"contato": "Ronney e Fabricio",
"plano": "Premium",
"produto": "Acessórios para carros elétricos",
"inicio": "2026-09-11",
"termino": "2026-10-26",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 16, 2026 6:58 PM"
},
{
"grupo": "ativo",
"monday_id": "13064759462",
"empresa": "K. FERREIRA COMERCIO E SERVICO DE MAQUINAS E EQUIPAMENTOS LTDA",
"cnpj": "31.392.907/0001-77",
"contato": "KAIO ALEXANDRE FERREIRA",
"plano": null,
"produto": "Furo serrilhado de dois lados com duas bordas Faca",
"inicio": "2026-09-16",
"termino": "2026-09-30",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 16, 2026 7:22 PM"
},
{
"grupo": "ativo",
"monday_id": "13064734855",
"empresa": "ALBERICI PELLETS LTDA",
"cnpj": "01.130.505/0001-33",
"contato": "Fabio",
"plano": "Premium",
"produto": "Chapas",
"inicio": "2026-09-11",
"termino": "2026-10-26",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 16, 2026 7:24 PM"
},
{
"grupo": "ativo",
"monday_id": "13103017737",
"empresa": "MAURO PEREIRA DOS REIS",
"cnpj": "05.293.905/0001-10",
"contato": "Moacir e Guilherme",
"plano": "Premium",
"produto": "Fone de ouvido, parafusadeira, patinete e roda",
"inicio": "2026-09-17",
"termino": "2026-10-28",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 22, 2026 8:46 AM"
},
{
"grupo": "ativo",
"monday_id": "13109308280",
"empresa": "AMOCHUVA COMERCIO DE ARTIGOS DO VESTUARIO E ACESSORIOS LTDA",
"cnpj": "57.961.069/0001-07",
"contato": "Carina",
"plano": "Full",
"produto": "Fone de ouvido, parafusadeira, patinete e roda",
"inicio": "2026-09-22",
"termino": "2026-10-21",
"ordem": false,
"responsavel": "Rodrigo Cruz",
"detalhes": "Responsável no Monday: Rodrigo Cruz\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 22, 2026 5:47 PM"
},
{
"grupo": "ativo",
"monday_id": "13118847418",
"empresa": "ROYAL ELETRIC MOTORS ASSESSORIA EM IMPORTACAO E EXPORTACAO LTDA",
"cnpj": "37.683.876/0001-90",
"contato": "Leonardo",
"plano": "Full",
"produto": "Produtos de academia",
"inicio": "2026-09-23",
"termino": "2026-10-22",
"ordem": false,
"responsavel": "Rodrigo Cruz",
"detalhes": "Responsável no Monday: Rodrigo Cruz\nServiço: Full\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Sep 23, 2026 3:32 PM"
},
{
"grupo": "finalizado",
"monday_id": "11422790512",
"empresa": "SANTOS MAGNO EMPREENDIMENTO",
"cnpj": "56.441.450/0001-74",
"contato": "NELIO",
"plano": null,
"produto": "Parede esculpida de metal / \nPainel Pvc parede oca Painel",
"inicio": "2026-02-12",
"termino": "2026-02-25",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: PI  for Nelio Magno .pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861276379/PI  for Nelio Magno .pdf\n• Fornecedor 1: PL.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861276929/PL.pdf\n• Fornecedor 1: PI  for Nelio Magno 40HQ (1).pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861277871/PI  for Nelio Magno 40HQ (1).pdf\n• Fornecedor 1: PL.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861278346/PL.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - NÉLIO - VITÓRIA.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861181105/DOCUMENTO DE ESTIMATIVA DE CUSTOS - NÉLIO - VITÓRIA.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - NÉLIO - SANTOS.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861181687/DOCUMENTO DE ESTIMATIVA DE CUSTOS - NÉLIO - SANTOS.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - NÉLIO - VITÓRIA.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861181884/DOCUMENTO DE ESTIMATIVA DE CUSTOS - NÉLIO - VITÓRIA.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422800169",
"empresa": "MAXI FERRO COMERCIAL LTDA",
"cnpj": "05.847.304/0001-02",
"contato": "Elismar",
"plano": null,
"produto": "Máquinas",
"inicio": "2026-02-09",
"termino": "2026-02-25",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: 3.11Tubos Quadrados e Retangulares QO-tiffany.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861280809/3.11Tubos Quadrados e Retangulares QO-tiffany.pdf\n• Fornecedor 1: 9.25polished mirror 430 PI-tiffany.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861281326/9.25polished mirror 430 PI-tiffany.pdf\n• Fornecedor 1: Bussines License .pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861281820/Bussines License .pdf\n• Fornecedor 1: Catálogo .pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861282229/Catálogo .pdf\n• Fornecedor 1: 3.6polished mirror 430 PI-tiffany.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861283417/3.6polished mirror 430 PI-tiffany.pdf\n• Fornecedor 1: 3.11Tubos Quadrados e Retangulares QO-tiffany.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861284462/3.11Tubos Quadrados e Retangulares QO-tiffany.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ELISMAR - CIF.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861184252/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ELISMAR - CIF.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - CIF.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861185023/DOCUMENTO DE ESTIMATIVA DE CUSTOS - CIF.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ELISMAR - CIF.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861185530/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ELISMAR - CIF.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11424065377",
"empresa": "MAGONI COMERCIO DE VEICULOS E SERVICOS AUTOMOTIVOS LTDA",
"cnpj": "9.980.975/0001-69",
"contato": "NILSON",
"plano": "Full",
"produto": "Veículos Autopropelidos",
"inicio": "2026-01-16",
"termino": "2026-02-27",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: 浩洋 60V18Ah - X1 MINI - MSDS.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864514427/浩洋 60V18Ah - X1 MINI - MSDS.pdf\n• Fornecedor 1: Inquiry List - Bryna.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2864514443/Inquiry List - Bryna.xlsx\n• Fornecedor 1: 浩洋 60V18Ah -X1 MINI - 海运3556 - 闪耀 中性标.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864514424/浩洋 60V18Ah -X1 MINI - 海运3556 - 闪耀 中性标.pdf\n• Fornecedor 1: 浩洋 60V18Ah -X1 MINI- UN38.3.pdf.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864514423/浩洋 60V18Ah -X1 MINI- UN38.3.pdf.pdf\n• Fornecedor 1: 浩洋 60V20Ah - X18 海运 UN3556.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864514421/浩洋 60V20Ah - X18 海运 UN3556.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - NILSON.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861243915/DOCUMENTO DE ESTIMATIVA DE CUSTOS - NILSON.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11426635987",
"empresa": "RENOVA PROTECT LTDA",
"cnpj": "45.250.558/0001-63",
"contato": "Dênio",
"plano": "Flex",
"produto": "Capinhas e Películas",
"inicio": "2026-01-21",
"termino": "2026-02-25",
"ordem": false,
"responsavel": "Rodrigo Cruz",
"detalhes": "Responsável no Monday: Rodrigo Cruz\nServiço: Flex\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 33.000 UNIDADES.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861245478/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 33.000 UNIDADES.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 66.000 UNIDADES.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861245635/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 66.000 UNIDADES.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422977835",
"empresa": "FH - GESTAO OCUPACIONAL SAUDE E SEGURANCA DO TRABALHO LTDA",
"cnpj": "49.834.277/0001-09",
"contato": "FAGNER",
"plano": "Full",
"produto": "Moveis eletrificados",
"inicio": "2026-01-16",
"termino": "2026-02-27",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RIO DE JANEIRO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861248139/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RIO DE JANEIRO.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - SALVADOR.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861248286/DOCUMENTO DE ESTIMATIVA DE CUSTOS - SALVADOR.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422775301",
"empresa": "SILVA & LOPES COMERCIO DE PECAS LTDA",
"cnpj": "13.060.341/0001-02",
"contato": "José Ribeiro",
"plano": "Flex",
"produto": "Cabeça de cilindro",
"inicio": "2026-02-24",
"termino": "2026-03-30",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Flex\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: PI E PL .pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861288472/PI E PL .pdf\n• Fornecedor 1: SILVA&MSC26043.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861288833/SILVA&MSC26043.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - FOB - MAIOR.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861178778/DOCUMENTO DE ESTIMATIVA DE CUSTOS - FOB - MAIOR.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - FOB - MENOR.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861178976/DOCUMENTO DE ESTIMATIVA DE CUSTOS - FOB - MENOR.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11631788765",
"empresa": "Rodrigo (sem empresa)",
"cnpj": null,
"contato": "Rodrigo",
"plano": null,
"produto": "Maquinário",
"inicio": "2026-01-19",
"termino": "2026-01-30",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: bca2c892faaf95c829de8fb7003a7b45.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2865435008/bca2c892faaf95c829de8fb7003a7b45.pdf\n• Fornecedor 1: 43196a48f8e7a45b3e8592f4d3627300.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2865435028/43196a48f8e7a45b3e8592f4d3627300.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS -.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2884012370/DOCUMENTO DE ESTIMATIVA DE CUSTOS -.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11631798206",
"empresa": "REGAL PRODUCOES FOTOGRAFICAS LTDA",
"cnpj": "07.012.796/0001-41",
"contato": "Cassio",
"plano": null,
"produto": "Power bank",
"inicio": "2026-01-12",
"termino": "2026-01-25",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 3:52 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: 2025-12-31  PACKING LIST.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2865432162/2025-12-31  PACKING LIST.pdf\n• Fornecedor 1: 2025-12-31 ONEDAY TO Cassio Regal PI.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2865432161/2025-12-31 ONEDAY TO Cassio Regal PI.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS DE REMESSA EXPRESSA - MINI FAN.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2884016090/DOCUMENTO DE ESTIMATIVA DE CUSTOS DE REMESSA EXPRESSA - MINI FAN.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS DE REMESSA EXPRESSA - POWER BANK.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2884016240/DOCUMENTO DE ESTIMATIVA DE CUSTOS DE REMESSA EXPRESSA - POWER BANK.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422706209",
"empresa": "65.051.947 WILSON DOS SANTOS",
"cnpj": "65.051.947/0001-77",
"contato": "Bruno",
"plano": null,
"produto": "Equipamentos de Ginastica",
"inicio": "2026-03-05",
"termino": "2026-03-18",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: WhatsApp Image 2026-03-02 at 22.57.03.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2802040701/WhatsApp Image 2026-03-02 at 22.57.03.jpeg\n• Fornecedor 1: PI--AB Wheel jump （0304）rope(2026-03-03 17_09_00) (1).pdf — https://gruponow.monday.com/protected_static/31595300/resources/2802040671/PI--AB Wheel jump （0304）rope(2026-03-03 17_09_00) (1).pdf\n• Fornecedor 1: WhatsApp Image 2026-03-03 at 22.40.39.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2802040707/WhatsApp Image 2026-03-03 at 22.40.39.jpeg\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - BRUNO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861177481/DOCUMENTO DE ESTIMATIVA DE CUSTOS - BRUNO.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11631792819",
"empresa": "ADAM INFORMATICA, ELETRONICOS E UTENSILIOS LTDA",
"cnpj": "50.652.413/0001-29",
"contato": "Claudinei",
"plano": null,
"produto": "Teclados",
"inicio": "2026-01-07",
"termino": "2026-01-20",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:26 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: Packing List_260105.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2951443205/Packing List_260105.pdf\n• Fornecedor 1: PI for Adamantiun Gamer-250620-01 assinado (4).pdf — https://gruponow.monday.com/protected_static/31595300/resources/2951443403/PI for Adamantiun Gamer-250620-01 assinado (4).pdf\n• Fornecedor 1: MSDS.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2951443535/MSDS.pdf\n• Fornecedor 1: Documento de Solicitação- Projetos.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951443743/Documento de Solicitação- Projetos.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - CLAUDINEI.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2884013763/DOCUMENTO DE ESTIMATIVA DE CUSTOS - CLAUDINEI.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11761259585",
"empresa": "TOBIAS ESTRUTURAS METALICA LTDA",
"cnpj": "43.176.921/0001-12",
"contato": "Anderson",
"plano": null,
"produto": "Máquinas",
"inicio": "2026-04-15",
"termino": "2026-04-26",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:29 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: 巴西 （Siemens）TP40形式发票 2026.4.15.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2918701352/巴西 （Siemens）TP40形式发票 2026.4.15.pdf\n• Fornecedor 2: 巴西 （Siemens）TP40形式发票 2026.4.15.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2951439723/巴西 （Siemens）TP40形式发票 2026.4.15.pdf\n• Fornecedor 2: 装箱单Packing list.pdf 2026.4.10.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2951439831/装箱单Packing list.pdf 2026.4.10.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2918697377/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951440194/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON - EXW.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951980394/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON - EXW.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON - FOB.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951980535/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ANDERSON - FOB.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11616062378",
"empresa": "PRIME COMERCIO, INDUSTRIA E IMPORTACAO LTDA",
"cnpj": "38.280.716/0001-62",
"contato": "Renato",
"plano": null,
"produto": "Produtos diversos",
"inicio": "2026-03-26",
"termino": "2026-04-08",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Alta · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 3:34 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: 8f393a896bb2d7630201e589785cbf02.JPG — https://gruponow.monday.com/protected_static/31595300/resources/2861313490/8f393a896bb2d7630201e589785cbf02.JPG\n• Fornecedor 1: CompanyAPPISCINACOMBRLTDA (1).pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861313670/CompanyAPPISCINACOMBRLTDA (1).pdf\n• Fornecedor 1: invoice catracas com HS CODE.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861314243/invoice catracas com HS CODE.pdf\n• Fornecedor 1: PI CATRACAS 250326  (2).JPG — https://gruponow.monday.com/protected_static/31595300/resources/2861314802/PI CATRACAS 250326  (2).JPG\n• Fornecedor 2: 3.25 Efftool Brand PI To Renato Appiscina(1).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861315841/3.25 Efftool Brand PI To Renato Appiscina(1).xlsx\n• Fornecedor 3: PI LIANGYOU 250326 CMB HS CODE.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861318112/PI LIANGYOU 250326 CMB HS CODE.pdf\n• Fornecedor 3: PICKING LIST 190326 Quotation- tianjin 2026.3.3 17(2).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861318658/PICKING LIST 190326 Quotation- tianjin 2026.3.3 17(2).xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO - 1X40 HC.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868925492/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO - 1X40 HC.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO - 2X40 NOR (003).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868925657/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO - 2X40 NOR (003).xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11879434280",
"empresa": "MARIN BRASIL TURBONET LTDA",
"cnpj": "24.839.614/0001-20",
"contato": "Fabiano",
"plano": null,
"produto": "Motos elétricas",
"inicio": "2026-04-30",
"termino": "2026-05-15",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:30 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: PI for eletric bicycle  0427  RSD-EB-0427-3 .pdf — https://gruponow.monday.com/protected_static/31595300/resources/2951436611/PI for eletric bicycle  0427  RSD-EB-0427-3 .pdf\n• Fornecedor 1: CTG2511396851E_SR13AB锂离子电池组20S-H60V20Ah-SLFP- MSDS_扫描版.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2951437152/CTG2511396851E_SR13AB锂离子电池组20S-H60V20Ah-SLFP- MSDS_扫描版.pdf\n• Fornecedor 1: RSD-EB-0427-3 Packing list.xls — https://gruponow.monday.com/protected_static/31595300/resources/2951437223/RSD-EB-0427-3 Packing list.xls\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - FABIANO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951437593/DOCUMENTO DE ESTIMATIVA DE CUSTOS - FABIANO.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11955066605",
"empresa": "JULIANA GUELERE BUENO LTDA",
"cnpj": "51.283.930/0001-30",
"contato": "Marcos",
"plano": null,
"produto": "Carros de Lego NIFELIZ",
"inicio": "2026-05-07",
"termino": "2026-05-18",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:30 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: PI-BR-JGB-260507.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2961863945/PI-BR-JGB-260507.pdf\n• Fornecedor 1: Packing List 260507 (1).xls — https://gruponow.monday.com/protected_static/31595300/resources/2961864392/Packing List 260507 (1).xls\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - EXW.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2961866356/DOCUMENTO DE ESTIMATIVA DE CUSTOS - EXW.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - FOB.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2961866527/DOCUMENTO DE ESTIMATIVA DE CUSTOS - FOB.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422788614",
"empresa": "PONTUAL CONSULTORIA IMOBILIARIA LTDA",
"cnpj": "28.222.166/0001-71",
"contato": "Adenir",
"plano": "Full",
"produto": "Peças para material de construção",
"inicio": "2026-02-27",
"termino": "2026-09-04",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:30 PM"
},
{
"grupo": "finalizado",
"monday_id": "12011565283",
"empresa": "66.454.015 ADHAM ROBERT DE ANDRADE MARQUES",
"cnpj": "66.454.015/0001-38",
"contato": "Adham",
"plano": null,
"produto": "Escorva para polimento e acessórios de limpeza veicular",
"inicio": "2026-05-14",
"termino": "2026-05-16",
"ordem": true,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Crítico ⚠️️ · Score: Satisfeito · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa May 22, 2026 3:26 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: BL.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2987076404/BL.pdf\n• Fornecedor 1: Commercial invoice e Packing List.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2987076627/Commercial invoice e Packing List.xlsx\n• Fornecedor 1: Procuração (1).pdf — https://gruponow.monday.com/protected_static/31595300/resources/2987078029/Procuração (1).pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ADHAM - FECHADA.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2987074618/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ADHAM - FECHADA.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422977211",
"empresa": "F. L. KUNRATH COMERCIO DE ELETRODOMESTICOS LTDA",
"cnpj": "30.883.212/0001-25",
"contato": "Fabio",
"plano": "Full",
"produto": "Luminária solar",
"inicio": "2026-01-19",
"termino": "2026-02-03",
"ordem": true,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 12, 2026 5:06 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861212463/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861212621/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12441585894",
"empresa": "GUSTAVO RICHARD MIRANDA SILVA 40717573885",
"cnpj": "20.937.329/0001-90",
"contato": "Gustavo Richard",
"plano": null,
"produto": null,
"inicio": "2026-07-02",
"termino": "2026-07-23",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:36 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - GUSTAVO - DUPLICADA.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190970798/DOCUMENTO DE ESTIMATIVA DE CUSTOS - GUSTAVO - DUPLICADA.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - GUSTAVO - TRIPLICADA.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190970920/DOCUMENTO DE ESTIMATIVA DE CUSTOS - GUSTAVO - TRIPLICADA.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - GUSTAVO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190971067/DOCUMENTO DE ESTIMATIVA DE CUSTOS - GUSTAVO.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12078352469",
"empresa": "REGAL PRODUCOES FOTOGRAFICAS LTDA",
"cnpj": "01.012.796/0001-41",
"contato": "Cassio",
"plano": null,
"produto": "Filamento de impressora 3D",
"inicio": "2026-05-21",
"termino": "2026-06-21",
"ordem": true,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:36 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - CÁSSIO - COM DESCONTO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190971612/DOCUMENTO DE ESTIMATIVA DE CUSTOS - CÁSSIO - COM DESCONTO.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - CÁSSIO - SEPARADO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190971692/DOCUMENTO DE ESTIMATIVA DE CUSTOS - CÁSSIO - SEPARADO.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - CÁSSIO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190971868/DOCUMENTO DE ESTIMATIVA DE CUSTOS - CÁSSIO.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12206521330",
"empresa": "PRIME COMERCIO, INDUSTRIA E IMPORTACAO LTDA",
"cnpj": "38.280.716/0001-62",
"contato": "Renato",
"plano": null,
"produto": "Ferramentas",
"inicio": "2026-06-05",
"termino": "2026-06-19",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:37 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO - 11 FORNECEDORES.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190972621/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO - 11 FORNECEDORES.xlsx\n• Estimativa: PL.xls — https://gruponow.monday.com/protected_static/31595300/resources/3190972638/PL.xls\n• Estimativa: PI.html — https://gruponow.monday.com/protected_static/31595300/resources/3190972627/PI.html\n• Estimativa: PL.png — https://gruponow.monday.com/protected_static/31595300/resources/3190972703/PL.png\n• Estimativa: 872315050-waffle_k_ltr.css — https://gruponow.monday.com/protected_static/31595300/resources/3190972796/872315050-waffle_k_ltr.css\n• Estimativa: bscframe.html — https://gruponow.monday.com/protected_static/31595300/resources/3190972748/bscframe.html\n• Estimativa: building_blocks_sidebar_prom.svg — https://gruponow.monday.com/protected_static/31595300/resources/3190972721/building_blocks_sidebar_prom.svg\n• Estimativa: iframeapi.html — https://gruponow.monday.com/protected_static/31595300/resources/3190972815/iframeapi.html\n• Estimativa: invalid_attribution_warning_.svg — https://gruponow.monday.com/protected_static/31595300/resources/3190972805/invalid_attribution_warning_.svg\n• Estimativa: proxy.html — https://gruponow.monday.com/protected_static/31595300/resources/3190972856/proxy.html\n• Estimativa: RotateCookiesPage.html — https://gruponow.monday.com/protected_static/31595300/resources/3190972867/RotateCookiesPage.html\n• Estimativa: saved_resource(1).html — https://gruponow.monday.com/protected_static/31595300/resources/3190972887/saved_resource(1).html\n• Estimativa: saved_resource(2).html — https://gruponow.monday.com/protected_static/31595300/resources/3190972892/saved_resource(2).html\n• Estimativa: saved_resource.html — https://gruponow.monday.com/protected_static/31595300/resources/3190972906/saved_resource.html"
},
{
"grupo": "finalizado",
"monday_id": "11641969825",
"empresa": "UNITEC SOLUCOES VOLVO LTDA",
"cnpj": "46.604.136.0001.01",
"contato": "IGOR",
"plano": "Full",
"produto": "PEÇAS PARA EQUIPAMENTO DE RETROESCAVADEIRA",
"inicio": "2026-04-01",
"termino": "2026-05-12",
"ordem": true,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 14, 2026 11:55 AM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - IGOR.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951841349/DOCUMENTO DE ESTIMATIVA DE CUSTOS - IGOR.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422978540",
"empresa": "UBALDO SERVICOS CIVIS LTDA",
"cnpj": "27.723.891/0001-60",
"contato": "GABRIEL",
"plano": "Premium",
"produto": "Produtos de iluminação,  EPI, Ferramentas, Relogios",
"inicio": "2026-02-13",
"termino": "2026-04-24",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:38 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - GABRIEL - LUMINÁRIAS.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190976578/DOCUMENTO DE ESTIMATIVA DE CUSTOS - GABRIEL - LUMINÁRIAS.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11422960644",
"empresa": "ANTONIO FERREIRA DA SILVA-JOSE BONIFACIO",
"cnpj": "71.599.450/0001-90",
"contato": "Antônio",
"plano": "Premium",
"produto": "Guarda-chuva e capas",
"inicio": "2026-02-24",
"termino": "2026-04-27",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 12, 2026 5:07 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - DOBRADA.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861204934/DOCUMENTO DE ESTIMATIVA DE CUSTOS - DOBRADA.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS -.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861205186/DOCUMENTO DE ESTIMATIVA DE CUSTOS -.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2X40.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861205452/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2X40.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 3X40.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861205633/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 3X40.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11855114019",
"empresa": "ALTA CONQUISTA SOLUCOES AQUATICAS",
"cnpj": "05.314.730/0001-80",
"contato": "Renato",
"plano": "Premium",
"produto": "Diversos",
"inicio": "2026-04-25",
"termino": "2026-06-12",
"ordem": false,
"responsavel": "Gabriella Bucki, Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Gabriella Bucki, Misaell Henrique da Silva Lopes\nPessoas: Alycia Pistoia\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:39 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190977115/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11929988295",
"empresa": "SALUSTIO CONSTRUTORA LTDA",
"cnpj": "60.954.728/0001-84",
"contato": "Claudio",
"plano": "Full",
"produto": "Caminhão betoneira autocarregável Euro 5 Modelo do produto 3.5m³",
"inicio": "2026-05-05",
"termino": "2026-06-09",
"ordem": true,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 12, 2026 5:05 PM"
},
{
"grupo": "finalizado",
"monday_id": "11799376673",
"empresa": "58.669.366 GUILHERME DRIGO COELHO DE OLIVEIRA",
"cnpj": "58.669.366/0001-38",
"contato": "Paulo",
"plano": "Full",
"produto": "Peças de WPC",
"inicio": "2026-04-20",
"termino": "2026-06-01",
"ordem": true,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 12, 2026 5:05 PM"
},
{
"grupo": "finalizado",
"monday_id": "11422762425",
"empresa": "AM MOVE LTD",
"cnpj": "16758490",
"contato": "ANA",
"plano": "Full",
"produto": "Roupas de Academia",
"inicio": "2026-02-03",
"termino": "2026-10-04",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 12:11 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: Gym bag catalog-251219 (3).pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861296657/Gym bag catalog-251219 (3).pdf\n• Fornecedor 2: HARES PRODUCT CATALOGUE 2026 72dpi (1).pdf — https://gruponow.monday.com/protected_static/31595300/resources/2861298889/HARES PRODUCT CATALOGUE 2026 72dpi (1).pdf"
},
{
"grupo": "finalizado",
"monday_id": "11424058132",
"empresa": "UBALDO SERVICOS CIVIS LTDA",
"cnpj": "27.723.891/0001-60",
"contato": "GABRIEL",
"plano": "Premium",
"produto": "Produtos de iluminação, EPI, Ferramentas, talheres, potes de vidro e relógios.",
"inicio": "2026-02-13",
"termino": "2026-04-25",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 12:21 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: Zena - Sinotools.txt — https://gruponow.monday.com/protected_static/31595300/resources/2860970667/Zena - Sinotools.txt\n• Fornecedor 1: Catálogo 1 - Zena.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2860970660/Catálogo 1 - Zena.pdf\n• Fornecedor 1: Catálogo 3 - Zena.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2860970666/Catálogo 3 - Zena.pdf\n• Fornecedor 1: Catálogo 2 - Zena.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2860970663/Catálogo 2 - Zena.pdf\n• Fornecedor 1: Sinotools-price list.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2860970665/Sinotools-price list.xlsx\n• Fornecedor 2: Inquiry List 1 - Anna.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868900520/Inquiry List 1 - Anna.xlsx\n• Fornecedor 2: Catálogo - ANNA.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868900512/Catálogo - ANNA.pdf\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.32 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910111/WhatsApp Image 2026-02-25 at 10.38.32 (1).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.32 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910108/WhatsApp Image 2026-02-25 at 10.38.32 (2).jpeg\n• Fornecedor 3: Cópia de stainless steel cutlery quotation-Guangdong Ideal-Echo 20260305(1).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868910104/Cópia de stainless steel cutlery quotation-Guangdong Ideal-Echo 20260305(1).xlsx\n• Fornecedor 3: Cópia de Inquiry List - cutlery set.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868910136/Cópia de Inquiry List - cutlery set.xlsx\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.32 (3).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910116/WhatsApp Image 2026-02-25 at 10.38.32 (3).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.32.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910226/WhatsApp Image 2026-02-25 at 10.38.32.jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.33 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910204/WhatsApp Image 2026-02-25 at 10.38.33 (1).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.33 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910263/WhatsApp Image 2026-02-25 at 10.38.33 (2).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.33 (3).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910322/WhatsApp Image 2026-02-25 at 10.38.33 (3).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.33 (4).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910329/WhatsApp Image 2026-02-25 at 10.38.33 (4).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.33.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910337/WhatsApp Image 2026-02-25 at 10.38.33.jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.34 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910345/WhatsApp Image 2026-02-25 at 10.38.34 (1).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.34 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910384/WhatsApp Image 2026-02-25 at 10.38.34 (2).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.34 (3).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910415/WhatsApp Image 2026-02-25 at 10.38.34 (3).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.34 (4).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910416/WhatsApp Image 2026-02-25 at 10.38.34 (4).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.34.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910413/WhatsApp Image 2026-02-25 at 10.38.34.jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.35 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910439/WhatsApp Image 2026-02-25 at 10.38.35 (1).jpeg\n• Fornecedor 3: WhatsApp Image 2026-02-25 at 10.38.35.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868910473/WhatsApp Image 2026-02-25 at 10.38.35.jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.36 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912684/WhatsApp Image 2026-02-25 at 10.38.36 (1).jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.35 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912702/WhatsApp Image 2026-02-25 at 10.38.35 (1).jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.36 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912784/WhatsApp Image 2026-02-25 at 10.38.36 (2).jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.36 (3).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912789/WhatsApp Image 2026-02-25 at 10.38.36 (3).jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.35.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912820/WhatsApp Image 2026-02-25 at 10.38.35.jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.36 (4).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912862/WhatsApp Image 2026-02-25 at 10.38.36 (4).jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.36 (5).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912863/WhatsApp Image 2026-02-25 at 10.38.36 (5).jpeg\n• Fornecedor 4: Catálogo - Tony.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868912687/Catálogo - Tony.pdf\n• Fornecedor 4: Inquiry List - Tony.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868912679/Inquiry List - Tony.xlsx\n• Fornecedor 4: Inquiry List - Tony.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868912679/Inquiry List - Tony.xlsx\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.36.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912908/WhatsApp Image 2026-02-25 at 10.38.36.jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.37 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912936/WhatsApp Image 2026-02-25 at 10.38.37 (1).jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.37 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912943/WhatsApp Image 2026-02-25 at 10.38.37 (2).jpeg\n• Fornecedor 4: WhatsApp Image 2026-02-25 at 10.38.37.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868912992/WhatsApp Image 2026-02-25 at 10.38.37.jpeg\n• Fornecedor 5: Catálogo - Melody.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868923699/Catálogo - Melody.pdf\n• Fornecedor 5: Inquiry List - from Rookie Mar-10-2026(1).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868923698/Inquiry List - from Rookie Mar-10-2026(1).xlsx\n• Fornecedor 5: Inquiry List - from Rookie Mar-10-2026(1).xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868923698/Inquiry List - from Rookie Mar-10-2026(1).xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - GABRIEL.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861217965/DOCUMENTO DE ESTIMATIVA DE CUSTOS - GABRIEL.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11424066603",
"empresa": "ADENILSON DEOLINDO DA SILVA",
"cnpj": "31.022.768/0001-90",
"contato": "ADENILSON",
"plano": "Premium",
"produto": "Presto barba e fita adesiva",
"inicio": "2026-02-13",
"termino": "2026-04-25",
"ordem": true,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 3:49 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: WhatsApp Image 2026-03-16 at 15.55.20 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860929348/WhatsApp Image 2026-03-16 at 15.55.20 (2).jpeg\n• Fornecedor 1: WhatsApp Image 2026-03-16 at 15.55.20 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860929335/WhatsApp Image 2026-03-16 at 15.55.20 (1).jpeg\n• Fornecedor 1: JESSIE - CONTATO.txt — https://gruponow.monday.com/protected_static/31595300/resources/2860929320/JESSIE - CONTATO.txt\n• Fornecedor 1: PI&PL - Jessie.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2860929297/PI&PL - Jessie.pdf\n• Fornecedor 1: PI-PL JESSIE.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2860929302/PI-PL JESSIE.xlsx\n• Fornecedor 1: WhatsApp Image 2026-03-16 at 15.55.20.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860929509/WhatsApp Image 2026-03-16 at 15.55.20.jpeg\n• Fornecedor 1: WhatsApp Image 2026-03-16 at 15.55.21 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860929528/WhatsApp Image 2026-03-16 at 15.55.21 (1).jpeg\n• Fornecedor 1: WhatsApp Image 2026-03-16 at 15.55.21 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860929557/WhatsApp Image 2026-03-16 at 15.55.21 (2).jpeg\n• Fornecedor 1: WhatsApp Image 2026-03-16 at 15.55.21.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860929558/WhatsApp Image 2026-03-16 at 15.55.21.jpeg\n• Fornecedor 2: WhatsApp Image 2026-03-16 at 15.55.45 (1).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860946209/WhatsApp Image 2026-03-16 at 15.55.45 (1).jpeg\n• Fornecedor 2: Packing_List-HYD2026030108.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2860946189/Packing_List-HYD2026030108.pdf\n• Fornecedor 2: Proforma_Invoice-2025_(1)-HYD2026030108.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2860946195/Proforma_Invoice-2025_(1)-HYD2026030108.pdf\n• Fornecedor 2: ROSIE.txt — https://gruponow.monday.com/protected_static/31595300/resources/2860946190/ROSIE.txt\n• Fornecedor 2: WhatsApp Image 2026-03-16 at 15.55.45 (2).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860946255/WhatsApp Image 2026-03-16 at 15.55.45 (2).jpeg\n• Fornecedor 2: WhatsApp Image 2026-03-16 at 15.55.45 (3).jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860946354/WhatsApp Image 2026-03-16 at 15.55.45 (3).jpeg\n• Fornecedor 2: WhatsApp Image 2026-03-16 at 15.55.45.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2860946406/WhatsApp Image 2026-03-16 at 15.55.45.jpeg\n• Fornecedor 3: Cotação - Rachel.xls — https://gruponow.monday.com/protected_static/31595300/resources/2931888407/Cotação - Rachel.xls\n• Fornecedor 4: Inquiry List - Gimy.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2931889115/Inquiry List - Gimy.xlsx\n• Fornecedor 4: Quotation of razors from Gimy.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2931891731/Quotation of razors from Gimy.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS -.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861213322/DOCUMENTO DE ESTIMATIVA DE CUSTOS -.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS -ADENILSON.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861213597/DOCUMENTO DE ESTIMATIVA DE CUSTOS -ADENILSON.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11615811028",
"empresa": "PRIME COMERCIO, INDUSTRIA E IMPORTACAO LTDA",
"cnpj": "65.385.498/0001-01",
"contato": "Giordano",
"plano": "Premium",
"produto": "Pets, Utensílios de cozinha e fechaduras eletrônicas",
"inicio": "2026-03-30",
"termino": "2026-05-29",
"ordem": true,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nServiço: Premium\nPrioridade: Média · Score: Satisfeito · 1 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:41 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: Catálogo - Lina.pptx — https://gruponow.monday.com/protected_static/31595300/resources/2934410943/Catálogo - Lina.pptx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1000.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190983250/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1000.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2000.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190983381/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2000.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11597112986",
"empresa": "NUTRIBEM PRODUTOS AGROPECUARIOS LTDA",
"cnpj": "02.987.556/0001-49",
"contato": "JUCINEY",
"plano": "Premium",
"produto": "Ração para cachorro e gato, arame galvanizado.",
"inicio": "2026-03-26",
"termino": "2026-05-27",
"ordem": true,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nServiço: Premium\nPrioridade: Crítico ⚠️️ · Score: Satisfeito · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 2:42 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: WhatsApp Image 2026-03-27 at 13.12.57.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868884566/WhatsApp Image 2026-03-27 at 13.12.57.jpeg\n• Fornecedor 1: Inquiry List - MIKEY.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868884553/Inquiry List - MIKEY.xlsx\n• Fornecedor 1: WhatsApp Image 2026-03-27 at 13.13.24.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868884599/WhatsApp Image 2026-03-27 at 13.13.24.jpeg\n• Fornecedor 1: WhatsApp Video 2026-03-27 at 13.12.56.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2868884554/WhatsApp Video 2026-03-27 at 13.12.56.mp4\n• Fornecedor 1: ~$Inquiry List - MIKEY.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2868884557/~$Inquiry List - MIKEY.xlsx\n• Fornecedor 2: WhatsApp Image 2026-03-30 at 10.14.12.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868884771/WhatsApp Image 2026-03-30 at 10.14.12.jpeg\n• Fornecedor 2: QUANTONG STEEL - PI.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868884742/QUANTONG STEEL - PI.pdf\n• Fornecedor 2: QUANTONG STEEL - PI20.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868884746/QUANTONG STEEL - PI20.pdf\n• Fornecedor 2: WhatsApp Image 2026-03-30 at 10.14.13.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868884773/WhatsApp Image 2026-03-30 at 10.14.13.jpeg\n• Fornecedor 2: WhatsApp Video 2026-03-30 at 10.14.00.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2868884747/WhatsApp Video 2026-03-30 at 10.14.00.mp4\n• Fornecedor 3: WhatsApp Image 2026-03-30 at 22.44.58.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868884978/WhatsApp Image 2026-03-30 at 22.44.58.jpeg\n• Fornecedor 3: 20260330 For Misaell Henrique CIF【Galvanized Wire】Delong.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868884946/20260330 For Misaell Henrique CIF【Galvanized Wire】Delong.pdf\n• Fornecedor 3: 20260327 For Misaell Henrique EXW【Galvanized Steel Wire】Delong.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2868884942/20260327 For Misaell Henrique EXW【Galvanized Steel Wire】Delong.pdf\n• Fornecedor 3: WhatsApp Image 2026-03-30 at 22.44.57.jpeg — https://gruponow.monday.com/protected_static/31595300/resources/2868884997/WhatsApp Image 2026-03-30 at 22.44.57.jpeg\n• Fornecedor 3: WhatsApp Video 2026-03-30 at 22.44.41.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2868884972/WhatsApp Video 2026-03-30 at 22.44.41.mp4\n• Fornecedor 3: WhatsApp Video 2026-03-30 at 22.44.47.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2868885043/WhatsApp Video 2026-03-30 at 22.44.47.mp4\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - JUCINEY - 1 CONTAINER.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951834959/DOCUMENTO DE ESTIMATIVA DE CUSTOS - JUCINEY - 1 CONTAINER.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - JUCINEY - 2 CONTAINERS.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951835130/DOCUMENTO DE ESTIMATIVA DE CUSTOS - JUCINEY - 2 CONTAINERS.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "11575279257",
"empresa": "REBONATTO REPRESENTACOES E SERVICOS LTDA",
"cnpj": "29.457.767/0001-26",
"contato": "Marcelo",
"plano": "Full",
"produto": "Motos, patins, bikes e hoverboard elétricos",
"inicio": "2026-03-20",
"termino": "2026-05-01",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 2:42 PM"
},
{
"grupo": "finalizado",
"monday_id": "11761561678",
"empresa": "CEREALISTA HEINRICH LTDA",
"cnpj": "33.301.384/0001-31",
"contato": "Juliano",
"plano": "Premium",
"produto": "Pneus",
"inicio": "2026-04-15",
"termino": "2026-06-16",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nServiço: Premium\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 2:43 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: Inquiry List - Juliano.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2957115824/Inquiry List - Juliano.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - JULIANO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2965864088/DOCUMENTO DE ESTIMATIVA DE CUSTOS - JULIANO.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12552065235",
"empresa": "AGROPECUARIA INOVACAO LTDA",
"cnpj": "32.411.713/0001-34",
"contato": "Fernando",
"plano": "Full",
"produto": "Pneu",
"inicio": "2026-03-17",
"termino": "2026-04-27",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:41 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - FERNANDO 2.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190984191/DOCUMENTO DE ESTIMATIVA DE CUSTOS - FERNANDO 2.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - FERNANDO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190984303/DOCUMENTO DE ESTIMATIVA DE CUSTOS - FERNANDO.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12001647438",
"empresa": "NSB PRODUTOS MEDICOS E HOSPITALARES LTDA",
"cnpj": "24.854.393/0001-69",
"contato": "Narrayan",
"plano": "Full",
"produto": "Aparelhos Auditivos",
"inicio": "2026-05-13",
"termino": "2026-06-11",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:42 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - NARRAYAN.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190984893/DOCUMENTO DE ESTIMATIVA DE CUSTOS - NARRAYAN.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12563710118",
"empresa": "MATHEUS RODRIGUES VERAS",
"cnpj": "41.346.526/0001-05",
"contato": "Matheus",
"plano": "Premium",
"produto": "HD, Alicate, escova sanitária, faca tática e ferro de solda",
"inicio": "2026-07-17",
"termino": "2026-09-19",
"ordem": false,
"responsavel": "Giovanna Souza de Andrade",
"detalhes": "Responsável no Monday: Giovanna Souza de Andrade\nServiço: Premium\nPrioridade: Média · Score: Insatisfeito⚠️️ · 3 Trimestre\nÚltima atualização no Monday: Giovanna Souza de Andrade Aug 14, 2026 3:23 PM"
},
{
"grupo": "finalizado",
"monday_id": "11860201053",
"empresa": "Stéfano (sem empresa)",
"cnpj": null,
"contato": "Stéfano",
"plano": "Full",
"produto": "Moto elétrica",
"inicio": "2026-04-25",
"termino": "2026-05-20",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Alycia Pistoia\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 31, 2026 3:59 PM"
},
{
"grupo": "finalizado",
"monday_id": "12803397460",
"empresa": "AIRMAQ COMERCIAL IMPORTADORA E EXPORTADORA LTDA",
"cnpj": "23.250.563/0001-33",
"contato": "Rafael",
"plano": null,
"produto": "Compressor de ar",
"inicio": "2026-08-14",
"termino": "2026-09-02",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 31, 2026 4:00 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RAFAEL.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190988529/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RAFAEL.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12806959949",
"empresa": "MARIN BRASIL TURBONET LTDA",
"cnpj": "24.839.614/0001-20",
"contato": "Fabio Davi",
"plano": null,
"produto": "Motos elétricas",
"inicio": "2026-08-14",
"termino": "2026-09-02",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 31, 2026 4:00 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190987019/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 1.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190987188/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 2.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - 3.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190987301/DOCUMENTO DE ESTIMATIVA DE CUSTOS - 3.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12798220076",
"empresa": "MAXFIX COMERCIO DE FITAS ADESIVAS LTDA",
"cnpj": "10.908.041/0001-34",
"contato": "Marcos",
"plano": null,
"produto": "Acrílico",
"inicio": "2026-08-13",
"termino": "2026-08-28",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 3 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 31, 2026 4:00 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - MARCOS.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190988252/DOCUMENTO DE ESTIMATIVA DE CUSTOS - MARCOS.xlsx"
},
{
"grupo": "finalizado",
"monday_id": "12371548102",
"empresa": "ANDRADE COMERCIO DE AREIA E PEDRA LTDA",
"cnpj": "13.347.012/0001-39",
"contato": "Danilo Andrade e Tiago Andrade",
"plano": "Full",
"produto": "Palete de bloco GMT",
"inicio": "2026-06-22",
"termino": "2026-07-21",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 31, 2026 4:35 PM"
},
{
"grupo": "finalizado",
"monday_id": "11422985252",
"empresa": "EDUART (sem empresa)",
"cnpj": null,
"contato": "EDUART",
"plano": "Premium",
"produto": "Produtos hospitalares",
"inicio": "2026-02-27",
"termino": "2026-04-30",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nPessoas: Gabriella Bucki\nServiço: Premium\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Gabriella Bucki Aug 31, 2026 4:35 PM"
},
{
"grupo": "pausado",
"monday_id": "11422977470",
"empresa": "EVOLVE FITNESS LTDA",
"cnpj": "46.731.165/0001-34",
"contato": "JHONES",
"plano": "Full",
"produto": "Equipamentos de Academia",
"inicio": "2026-02-01",
"termino": "2026-03-20",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 12:06 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - CLIENTE JHONES.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861209711/DOCUMENTO DE ESTIMATIVA DE CUSTOS - CLIENTE JHONES.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - JHONES.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2951836592/DOCUMENTO DE ESTIMATIVA DE CUSTOS - JHONES.xlsx"
},
{
"grupo": "pausado",
"monday_id": "11484961646",
"empresa": "RAPPI 10 RAPIDEZ E CONFIANCA",
"cnpj": "26.454.968/0001-81",
"contato": "Li Santos",
"plano": "Full",
"produto": "Materiais de construção",
"inicio": "2026-03-11",
"termino": "2026-04-30",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:30 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - PLACAS DRYWALL E PERFIL.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190956607/DOCUMENTO DE ESTIMATIVA DE CUSTOS - PLACAS DRYWALL E PERFIL.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - PLACAS DRYWALL.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190956671/DOCUMENTO DE ESTIMATIVA DE CUSTOS - PLACAS DRYWALL.xlsx"
},
{
"grupo": "pausado",
"monday_id": "11424051928",
"empresa": "ON LED ILUMINACAO E MATERIAIS ELETRICOS LTDA",
"cnpj": "17.146.063/0001-53",
"contato": "THIAGO",
"plano": "Flex",
"produto": "Fitas LED",
"inicio": "2026-02-20",
"termino": "2026-02-26",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Gabriella Bucki\nServiço: Flex\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:31 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: Cotação - Allen.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2931893156/Cotação - Allen.xlsx\n• Fornecedor 2: Cotação - Chris.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2931893260/Cotação - Chris.xlsx\n• Fornecedor 3: Cotação - Chuck.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2931893360/Cotação - Chuck.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - THIAGO.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190957357/DOCUMENTO DE ESTIMATIVA DE CUSTOS - THIAGO.xlsx"
},
{
"grupo": "pausado",
"monday_id": "11637599497",
"empresa": "ROYAL ATACADISTA LTDA",
"cnpj": "39.678.603/0001-82",
"contato": "Victor",
"plano": "Full",
"produto": "Portas",
"inicio": "2026-03-28",
"termino": "2026-05-11",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:33 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - PORTAS COMPLETAS.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190962328/DOCUMENTO DE ESTIMATIVA DE CUSTOS - PORTAS COMPLETAS.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - PORTAS.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190962439/DOCUMENTO DE ESTIMATIVA DE CUSTOS - PORTAS.xlsx"
},
{
"grupo": "pausado",
"monday_id": "11761480558",
"empresa": "IMEX 360 COMERCIO EXTERIOR LTDA",
"cnpj": "11.101.705/0001-11",
"contato": "Alexandre",
"plano": "Full",
"produto": "Luva",
"inicio": "2026-04-15",
"termino": "2026-05-28",
"ordem": false,
"responsavel": "Gabriella Bucki",
"detalhes": "Responsável no Monday: Gabriella Bucki\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 12:08 PM"
},
{
"grupo": "pausado",
"monday_id": "11732681189",
"empresa": "ROBSON LUIZ MICHELETTO",
"cnpj": "53.416.494/0001-56",
"contato": "Robson",
"plano": "Full",
"produto": "Máquina de cortar grama",
"inicio": "2026-04-13",
"termino": "2026-05-22",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Ana Clara Ré Rosa\nServiço: Full\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:33 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: 220DB0646C2E1A0EA7590EFFBC317D50 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113699/220DB0646C2E1A0EA7590EFFBC317D50 (1).jpg\n• Fornecedor 1: 06C3CEE9CEF76ED8B0ADD2A0AF761ACD (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113746/06C3CEE9CEF76ED8B0ADD2A0AF761ACD (1).jpg\n• Fornecedor 1: 35AF8E6333B246438E00FA4EB430449B (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113740/35AF8E6333B246438E00FA4EB430449B (1).jpg\n• Fornecedor 1: 35fb283a-34a0-4e44-bc7d-c6e050578b4c.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957113804/35fb283a-34a0-4e44-bc7d-c6e050578b4c.mp4\n• Fornecedor 1: 3C78893BC3A574DBB34FF36F44FAD84C (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113743/3C78893BC3A574DBB34FF36F44FAD84C (1).jpg\n• Fornecedor 1: 3F518F6DCD710C8D78904FB96781A947 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113847/3F518F6DCD710C8D78904FB96781A947 (1).jpg\n• Fornecedor 1: 40868611D968F002FC2405838B28866A (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113868/40868611D968F002FC2405838B28866A (1).jpg\n• Fornecedor 1: 4107FE5DF2087F525B9F2617BE63B307 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113869/4107FE5DF2087F525B9F2617BE63B307 (1).jpg\n• Fornecedor 1: 51464D019CEB2AE8A2F6054C55F08DAA (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113864/51464D019CEB2AE8A2F6054C55F08DAA (1).jpg\n• Fornecedor 1: 5987648B247AD638B191D4BD044B6FA7 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957113933/5987648B247AD638B191D4BD044B6FA7 (1).jpg\n• Fornecedor 1: 74039B902DDED832ACFCED720ACE2114 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114059/74039B902DDED832ACFCED720ACE2114 (1).jpg\n• Fornecedor 1: 77CF35B391C2B4FC531CA60DEEB75331 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114011/77CF35B391C2B4FC531CA60DEEB75331 (1).jpg\n• Fornecedor 1: 8B846294B91958D3FF7193D4B14DD250 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114080/8B846294B91958D3FF7193D4B14DD250 (1).jpg\n• Fornecedor 1: 8dab42b3-d1ce-4191-b3e9-99069effaf8f.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957114244/8dab42b3-d1ce-4191-b3e9-99069effaf8f.mp4\n• Fornecedor 1: 7dc4de89-a896-4ebe-a8b1-ec3623b87571.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957114396/7dc4de89-a896-4ebe-a8b1-ec3623b87571.mp4\n• Fornecedor 1: 949ADA7C2B24A3CB41F592646C6050EC (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114204/949ADA7C2B24A3CB41F592646C6050EC (1).jpg\n• Fornecedor 1: 78be2641-9b25-4959-b728-a59044da006e.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957114429/78be2641-9b25-4959-b728-a59044da006e.mp4\n• Fornecedor 1: 9617CF86D1287B9B88F4FFDF143EE2F1 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114284/9617CF86D1287B9B88F4FFDF143EE2F1 (1).jpg\n• Fornecedor 1: A0E5F2ABE8E97EBADDADD8F59DF863D2 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114405/A0E5F2ABE8E97EBADDADD8F59DF863D2 (1).jpg\n• Fornecedor 1: A664C6D9EFA3EC8B06F772B4C4BB2A27 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114481/A664C6D9EFA3EC8B06F772B4C4BB2A27 (1).jpg\n• Fornecedor 1: A6F845A20A6C53242142AE5097EE699C (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114374/A6F845A20A6C53242142AE5097EE699C (1).jpg\n• Fornecedor 1: B571641A7240C365A5BE64F78C49745C (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114533/B571641A7240C365A5BE64F78C49745C (1).jpg\n• Fornecedor 1: C3012CA4250182AED3CDEDB0E3964955 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114510/C3012CA4250182AED3CDEDB0E3964955 (1).jpg\n• Fornecedor 1: C5B2FC67A354B1162E258DC15F06E8FA (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114584/C5B2FC67A354B1162E258DC15F06E8FA (1).jpg\n• Fornecedor 1: bf03e668-cdf2-440b-b851-a3b08748639b.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957114827/bf03e668-cdf2-440b-b851-a3b08748639b.mp4\n• Fornecedor 1: d6270fb5-3c73-4b12-a233-c476db1ca0b8.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957114615/d6270fb5-3c73-4b12-a233-c476db1ca0b8.mp4\n• Fornecedor 1: DC8672ECC340374BB136917D2122F480.jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114616/DC8672ECC340374BB136917D2122F480.jpg\n• Fornecedor 1: de4a7013-483d-453b-b0af-87f262bc13e6.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957114992/de4a7013-483d-453b-b0af-87f262bc13e6.mp4\n• Fornecedor 1: e0f9d077-b236-43b9-8c2f-ca6cc5c6cde1.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957114842/e0f9d077-b236-43b9-8c2f-ca6cc5c6cde1.mp4\n• Fornecedor 1: e2d36800-6fc3-4461-b7ae-58bf3ec748cc.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115121/e2d36800-6fc3-4461-b7ae-58bf3ec748cc.mp4\n• Fornecedor 1: F3CFEE510CDD04F11C49D7E7CFAB5F26 (1).jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957114756/F3CFEE510CDD04F11C49D7E7CFAB5F26 (1).jpg\n• Fornecedor 1: Inquiry List - Grace.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2957114897/Inquiry List - Grace.xlsx\n• Fornecedor 2: Cotação - Fucheng.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2957115064/Cotação - Fucheng.pdf\n• Fornecedor 2: WhatsApp Video 2026-04-20 at 19.20.31 (1).mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115456/WhatsApp Video 2026-04-20 at 19.20.31 (1).mp4\n• Fornecedor 2: WhatsApp Video 2026-04-20 at 19.20.31.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115524/WhatsApp Video 2026-04-20 at 19.20.31.mp4\n• Fornecedor 2: WhatsApp Video 2026-04-24 at 10.03.03.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115618/WhatsApp Video 2026-04-24 at 10.03.03.mp4\n• Fornecedor 2: WhatsApp Video 2026-04-24 at 10.02.39.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115664/WhatsApp Video 2026-04-24 at 10.02.39.mp4\n• Fornecedor 2: WhatsApp Video 2026-04-24 at 10.02.43.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115662/WhatsApp Video 2026-04-24 at 10.02.43.mp4\n• Fornecedor 2: WhatsApp Video 2026-04-24 at 10.03.04.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115692/WhatsApp Video 2026-04-24 at 10.03.04.mp4\n• Fornecedor 3: Quotation Chart ( Misaell Henrique)2026.4.23.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2957115666/Quotation Chart ( Misaell Henrique)2026.4.23.pdf\n• Fornecedor 3: Upgraded one.png — https://gruponow.monday.com/protected_static/31595300/resources/2957115805/Upgraded one.png\n• Fornecedor 3: Standard one.jpg — https://gruponow.monday.com/protected_static/31595300/resources/2957115821/Standard one.jpg\n• Fornecedor 3: RTK+VISION AI version.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957115847/RTK+VISION AI version.mp4\n• Fornecedor 3: 爆款割草机 Standard one.mp4 — https://gruponow.monday.com/protected_static/31595300/resources/2957116007/爆款割草机 Standard one.mp4\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - ROBSON.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190963348/DOCUMENTO DE ESTIMATIVA DE CUSTOS - ROBSON.xlsx"
},
{
"grupo": "pausado",
"monday_id": "12290711760",
"empresa": "67.176.355 TIAGO RODRIGO SAVAJO ETO",
"cnpj": "67.176.355/0001-07",
"contato": "Tiago",
"plano": null,
"produto": "Column",
"inicio": "2026-06-16",
"termino": "2026-07-03",
"ordem": false,
"responsavel": "Alycia Pistoia",
"detalhes": "Responsável no Monday: Alycia Pistoia\nServiço: Estimativa de custos\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:34 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - TIAGO - EXW.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190963994/DOCUMENTO DE ESTIMATIVA DE CUSTOS - TIAGO - EXW.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - TIAGO - FOB.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190964170/DOCUMENTO DE ESTIMATIVA DE CUSTOS - TIAGO - FOB.xlsx"
},
{
"grupo": "pausado",
"monday_id": "11424065896",
"empresa": "LIVA SERVICES LTDA",
"cnpj": "63.943.092/0001-63",
"contato": "RENATO",
"plano": "Flex",
"produto": "Baterias",
"inicio": "2026-01-01",
"termino": "2026-02-10",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Ana Clara Ré Rosa\nServiço: Flex\nPrioridade: Média · Score: Indiferente · 1 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:32 PM\nArquivos (abrir logado no Monday):\n• Fornecedor 1: PI 1 FOB.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507678/PI 1 FOB.pdf\n• Fornecedor 1: PI 2 FOB.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507660/PI 2 FOB.pdf\n• Fornecedor 1: PI 1.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507665/PI 1.pdf\n• Fornecedor 1: PI 2.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507657/PI 2.pdf\n• Fornecedor 1: PL 1.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2864507671/PL 1.xlsx\n• Fornecedor 1: PL 2.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2864507826/PL 2.xlsx\n• Fornecedor 1: GSL ENERGY 5kwh 10kwh Powerbrick_bluetooth_datasheet.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507831/GSL ENERGY 5kwh 10kwh Powerbrick_bluetooth_datasheet.pdf\n• Fornecedor 1: interver datasheet.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507828/interver datasheet.pdf\n• Fornecedor 1: S03A24010503U00101 GSL10000U UN38.3.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507840/S03A24010503U00101 GSL10000U UN38.3.pdf\n• Fornecedor 1: S03A25121125S01701 ©±╩ó┴ª GSL10000U MSDS.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507857/S03A25121125S01701 ©±╩ó┴ª GSL10000U MSDS.pdf\n• Fornecedor 1: SEKGZ2025122531670A600001 ©±╩ó┴ª GSL10000U ║úÈ╦.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507956/SEKGZ2025122531670A600001 ©±╩ó┴ª GSL10000U ║úÈ╦.pdf\n• Fornecedor 2: Inquiry List - Jessie.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2864506930/Inquiry List - Jessie.xlsx\n• Fornecedor 2: AT1811C503390126-驰普达-锂电池-51.2V 100Ah-CE-EMC报备-证书.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864506933/AT1811C503390126-驰普达-锂电池-51.2V 100Ah-CE-EMC报备-证书.pdf\n• Fornecedor 2: DGM certificates--51.2v280ah.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864506926/DGM certificates--51.2v280ah.pdf\n• Fornecedor 2: LCSA07304035SA-驰普-51.2V280Ah-柯杰 -张玲 UN.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864506958/LCSA07304035SA-驰普-51.2V280Ah-柯杰 -张玲 UN.pdf\n• Fornecedor 2: MSDS---51.2V280Ah.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864506924/MSDS---51.2V280Ah.pdf\n• Fornecedor 2: Inquiry List - JESSIE.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2864507103/Inquiry List - JESSIE.xlsx\n• Fornecedor 2: Proforma Invoice Of CTECHI Battery.pdf — https://gruponow.monday.com/protected_static/31595300/resources/2864507117/Proforma Invoice Of CTECHI Battery.pdf\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO 1.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/2861242604/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO 1.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO 1.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190960809/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO 1.xlsx\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO 2.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190961050/DOCUMENTO DE ESTIMATIVA DE CUSTOS - RENATO 2.xlsx"
},
{
"grupo": "pausado",
"monday_id": "11720515376",
"empresa": "J.J ELETRICIDADE IMPORTS LTDA",
"cnpj": "65.354.116/0001-74",
"contato": "Guilherme",
"plano": "Premium",
"produto": "Luminárias: Arandelas, luminárias pendentes, plafons, spots, lâmpadas led, pista de dança 4x4/ 2X. Fones; Interruptor; Alexia; Projetor;",
"inicio": "2026-04-10",
"termino": "2026-06-11",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Ana Clara Ré Rosa\nServiço: Premium\nPrioridade: Alta · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Ana Clara Ré Rosa Jul 16, 2026 3:06 PM"
},
{
"grupo": "pausado",
"monday_id": "12001670788",
"empresa": "LED BRASIL MINAS LTDA",
"cnpj": "24.112.565/0001-29",
"contato": "Ferrera",
"plano": "Full",
"produto": "Painel LED",
"inicio": "2026-05-13",
"termino": "2026-06-11",
"ordem": false,
"responsavel": "Misaell Henrique da Silva Lopes",
"detalhes": "Responsável no Monday: Misaell Henrique da Silva Lopes\nPessoas: Ana Clara Ré Rosa\nServiço: Full\nPrioridade: Média · Score: Indiferente · 2 Trimestre\nÚltima atualização no Monday: Alycia Pistoia Aug 19, 2026 4:34 PM\nArquivos (abrir logado no Monday):\n• Estimativa: DOCUMENTO DE ESTIMATIVA DE CUSTOS - FERRERA - 50 UNIDADES.xlsx — https://gruponow.monday.com/protected_static/31595300/resources/3190966692/DOCUMENTO DE ESTIMATIVA DE CUSTOS - FERRERA - 50 UNIDADES.xlsx"
}
]$monday$::jsonb) as importados;
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
-- 016 — dados dos fornecedores importados do Monday (rodar depois do 015)
select public.importar_fornecedores($fornec$[{"monday_id": "11949587643", "nome": "Jiangsu Hongmao Sports Co., Ltd", "produto": "Grama sintética", "contato": "Lucky Zhang", "origem": "Canton Fair", "telefone": "8651385016676", "email": "alice@hmgrass.com", "site": "www.hmgrass.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949643467", "nome": "Luckyman Tecnology Co., Ltd", "produto": "Produtos portáteis para fazer café", "contato": "Serena", "origem": "Canton Fair", "telefone": "867563353269", "email": "sale03@luckychina.net", "site": "www.luckychina.net / www.ceraplus.net", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949635909", "nome": "Foshan Zcamp Inteligent Equipment Co., Ltd", "produto": "Cabines/ casa", "contato": "Yufu Yang", "origem": "Canton Fair", "telefone": "8615007611144", "email": "yangyufu@zcamp.com", "site": "www.zcamp.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949636237", "nome": "Yuyao City Yisheng Metal Products Co., Ltd", "produto": "Varão de cortina", "contato": "Zoe", "origem": "Canton Fair", "telefone": "8615180402548", "email": "zoechou@yyaly.com", "site": "www.yyaly.com / www.alyhomeus.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949603238", "nome": "Zhumadian Yicheng Yonche Arts & Crafts Co., Ltd", "produto": "Bolsas", "contato": "Wei Huang", "origem": "Canton Fair", "telefone": "863962880081", "email": "huangtq@vip.163.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949591219", "nome": "Hangzhou DOZ Import & Exporte Co., Ltd", "produto": "Válvula", "contato": null, "origem": "Canton Fair", "telefone": "86057128181688", "email": "marketing@doztrade.com", "site": "https://doztrade.en.alibaba.com/", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949621773", "nome": "Bada Mechanical & Eletronic Co., Ltd", "produto": "Guincho Manual", "contato": null, "origem": "Canton Fair", "telefone": "8657765156622", "email": "bada@cn-bada.com", "site": "www.cn-bada.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949625393", "nome": "Shandong Huatai New Energy Battery Co., Ltd", "produto": "Pilha", "contato": null, "origem": "Canton Fair", "telefone": null, "email": null, "site": "www.huataibattery.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "michael@huataibattery.com/ nicole@huataibattery.com/ john@huataibattery.com"}, {"monday_id": "11949621707", "nome": "Double-Lin", "produto": "Pex- Al- Pex Pipe System", "contato": null, "origem": "Canton Fair", "telefone": "8657687116882", "email": "ADN@DOUBLE-LIN.NET", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949643852", "nome": "ForeVer", "produto": "Óculos", "contato": null, "origem": "Canton Fair", "telefone": "8613695801660", "email": "cindy@forever-eyewear.com", "site": "www.forever-eyewear.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949611274", "nome": "Ningbo Meijia (Meiqi) Tool Co., Ltd/ Meijiaqi (Vietnam) Mold Auto Pats RB & Plastic Co., Ltd", "produto": "Ferramentas", "contato": null, "origem": "Canton Fair", "telefone": "8657465520100", "email": "sales11@meijiatools.com", "site": "www.meijiatool.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949626809", "nome": "Jiangxi Avonflow HVAC Tech Co., Ltd", "produto": "Aquecimento e hidráulica", "contato": null, "origem": "Canton Fair", "telefone": "86057128181688", "email": "marketing@avonflow.com.cn", "site": "https://avonflow.en.alibaba.com/?src=sem_ggl&field=UG&from=sem_ggl&cmpgn=23600732559&adgrp=&fditm=&tgt=&locintrst=&locphyscl=9197894&mtchtyp=&ntwrk=x&device=c&dvcmdl=&creative=&plcmnt=&plcmntcat=&aceid=&position=&gad_source=1&gad_campaignid=23610879097&gbraid=0AAAAAD8m77qXmQnQ1U8_1-HzlXqXEW2wS&gclid=CjwKCAjwzevPBhBaEiwAplAxvkiyjF7TAa8nYF_KDbVxwolSujlQJYaavl1dAm2DXTlVriCm5fgsURoCYPUQAvD_BwE", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949638099", "nome": "Shandong Jinguan Net Co., Ltd", "produto": "Rede de proteção", "contato": null, "origem": "Canton Fair", "telefone": "8618905437521", "email": "mary@bzjinguan.com", "site": "https://sdjinguan.en.alibaba.com/", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949629251", "nome": "Guangdong Weilong Stainless Steel Industrail Co., Ltd", "produto": "Formas de alumínio", "contato": null, "origem": "Canton Fair", "telefone": "867686679888", "email": "weilong@cnweilong.com", "site": "www.cnweilong.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949626827", "nome": "Zhangjiagang City Daking Jewellery Co., Ltd", "produto": "Joias", "contato": null, "origem": "Canton Fair", "telefone": "8618915586665", "email": null, "site": "www.zhuji-pearl.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11949653968", "nome": "Simto Group Co., Ltd", "produto": "Portas", "contato": null, "origem": "Canton Fair", "telefone": "8618657198515", "email": null, "site": "www.simtodoor.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950795435", "nome": "ZHEJIANG LINGHONG INDUSTRY & TRADE CO., LTD", "produto": "Copos e garrafas térmicas", "contato": "Danly", "origem": "Canton Fair", "telefone": null, "email": null, "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950250228", "nome": "ZHENGMING SCIENCE AND TECHNOLOGY CO., LTD", "produto": "Luminárias de papel", "contato": "Vikin Chen", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618718512201", "email": "vikin.c@zbole.net", "site": "szzmkj.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950250760", "nome": "DONGGUAN YUEQUAN TOYS., LIMITED", "produto": "Brinquedos/ ursos de pelúcia", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613737830909", "email": "anbiyo@sina.com", "site": "www.yuequantoys.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950242249", "nome": "HUIZHOU CAILANG PRINTING PRODUCTS CO., LTD", "produto": "Embalagens (papelão)", "contato": "Sienna Bai", "origem": "CHINA HOME LIFE - 2025", "telefone": "8616616797848", "email": "sienna@cailang.com.cn", "site": "cailangprinting.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950255443", "nome": "ACCESSORIES FOR ALUMINUM WINDOORS", "produto": "Partes e peças para a montagem de moveis", "contato": "Lam Zhang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613923158114", "email": "uhitcn@gmail.com", "site": "www.uhitacc.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "uhitcn@gmail.com/ uhitcn@163.com"}, {"monday_id": "11950240253", "nome": "LINHAI HONGTENG LIGHT FACTORY", "produto": "Iluminação", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8618815268988", "email": "hongtenglight@163.com", "site": "htlight.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 188 1526 1188/ +86188 1526 8988 | 425235030@qq.com/ hongtenglight@163.com"}, {"monday_id": "11950241129", "nome": "FOSHAN WISDOM HOUSEWARE CO., LTD", "produto": "utensílios usados para fazer café", "contato": "Hobson Shen", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613928808876", "email": "hobson@wisdomhouseware.com", "site": "www.wisdomhouseware.com / wisdomhouseware.en.alibaba.com / wisdomhouseware.en.made-in-china.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950254540", "nome": "YIWU GANGCHEN IMPORT & EXPORT CO., LTD", "produto": "Copos e Garrafas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615105558361", "email": "15105558361@163.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950261783", "nome": "GUANGDONG YUANFU LIGHTING TECHNOLOGY CO., LTD", "produto": "Lustres", "contato": "Merry Zhou", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613422766906", "email": "zhongyi@zhongyilighting.com", "site": "zhongyilighting.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 138 2804 6122/ +86 134 2276 6906"}, {"monday_id": "11950278096", "nome": "EXPORT COMPRESSION SOFA", "produto": "Sofás de espuma", "contato": "He Jianglong", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613958261701", "email": "jianglonghe98@gmail.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950242386", "nome": "NINGBO CHUANYUESHIKONG TECHNOLGY CO., LTD", "produto": "Canetas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613958261701", "email": "manager02@nbcysk.com", "site": "www.chotunestationery.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950251455", "nome": "GUANGZHOU REFEN COSMETICS CO., LTD", "produto": "Cosméticos", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": null, "email": null, "site": "www.ryepeak.cn / www.stegner.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950271877", "nome": "YUEYANG BAOLI TEXTILES CO., LTD", "produto": "Toalhas", "contato": "Sandy Huang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8617749670305", "email": "sandy@sunnytextiles.net", "site": "www.bltowel.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950223074", "nome": "PATENT PROFESSIONAL", "produto": "Produtos elétricos para cozinha", "contato": "Steven Yin/ Lyan", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613570072068", "email": "stevenyin@sun-bon.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 136 0277 1248/ +86 135 7007 2068 | stevenyin@sun-bon.com/ lyan@sun-bon.com"}, {"monday_id": "11950240907", "nome": "YUYAO L&F INDUSTRY CO., LTD", "produto": "produtos para bebê (feitos de tecido)", "contato": "Keven Wei", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613957897316", "email": "3acards@163.com", "site": "www.flywei.com/ www.lf1518.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "lf@flywei.com/ 3acards@163.com | dennis@fanshengelec.com/ dennischan27@168.com"}, {"monday_id": "11950241050", "nome": "ZHONGSHAN FANSHENG ELETRIC APPLIANCES CO., LTD", "produto": "Fogão de indução", "contato": "Dennis Chen", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613923299072", "email": "dennischan27@168.com", "site": "www.fanshengelec.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950262268", "nome": "ZHONGSHAN F5 ELECTRIC APPLIANCES CO., LTD", "produto": "Fogão de indução", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": null, "email": "MC@fanshengelec.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950242303", "nome": "GUANG DONG KOSMO SMART HOME DEVICES CO., LTD", "produto": "Espelhos", "contato": "Sunnie Peng", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613539032990", "email": "business0104@kosmo-gd.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 0769 868 83568/ +86 135 3903 2990 | marketing@kosmo-gd.com/ business0104@kosmo-gd.com"}, {"monday_id": "11950261945", "nome": "ZHEJIANG UCCLIFE COOKWARE CO., LTD", "produto": "Panelas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615757944444", "email": "keke@ucc-life.com", "site": "zhejiangyouke.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950241730", "nome": "GUANDONG JUNYANG ELECTRONIC TECHNOLOGY CO., LTD/ HUANAN ZHOUYE ELECTRONICS CO., LTD", "produto": "Isqueiro", "contato": "Jacky Soo", "origem": "CHINA HOME LIFE - 2025", "telefone": "8675727380259", "email": "sales10@zhuoyelighter.com", "site": "www.zhuoyelighter.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 139 2770 4025/ +86 757 2738 1723/ +86 757 2738 0259"}, {"monday_id": "11950272537", "nome": "ZHEJIANG HUANGYAN HUIFENG STATIONERY CO., LTD", "produto": "Cadernos e agendas", "contato": "Justin Jia", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618057690111", "email": "justinjia@hfstationery.com", "site": "www.zjstationery.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950795468", "nome": "LIAONING PROVINCE YAOSHENG LATEX PRODUCTS CO., LTD", "produto": "Balão e bexiga", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": null, "email": "max@ysqy8888.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950799501", "nome": "ZHONGSHAN AILIYOU ELETRIC APPLIANCE CO., LTD", "produto": "Panelas elétricas", "contato": "Ivy Qin", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613640453332", "email": "ivy@ailiyoudq.com", "site": "ailiyo.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950799648", "nome": "GUANGZHOU BEST LEATHER & CASE CO., LTD", "produto": "Bolsas", "contato": "Eric Li", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613926067926", "email": "eric@best-leather.cn", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "1716054984@qq.com / eric@best-leather.cn"}, {"monday_id": "11950803376", "nome": "HANGZHOU TOPWIN IMPORT & PORT CO., LTD", "produto": "Bolsas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613777571275", "email": "chenyuhz@vip.163.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950796126", "nome": "YUYAO ARTISANS COMMODITY CO., LTD", "produto": "Escovas", "contato": "Daisy Xiao", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613252281306", "email": "admin@yyyijiang.com", "site": "www.cnhairbrush.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950799453", "nome": "GUANGDONG CANDEAR TECHNOLOGY INNOVATION CO., LTD", "produto": "Embalagem de Cosmético", "contato": "Mon Hu/ Rosalie Chen", "origem": "CHINA HOME LIFE - 2025", "telefone": "8617620074579", "email": "2294261413@qq.com", "site": "www.containpacking.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "contain2010@qq.com/ 2294261413@qq.com | +86 135 4348 7694/ +86176 2007 4579"}, {"monday_id": "11950795858", "nome": "WENZHOU SWISOK ELECRIC CO., LTD", "produto": "Organizador de escritório", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613587778282", "email": "newspring@swisok.cn", "site": "www.swisok.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950790144", "nome": "XINJIANG TANGJIN TEXTILE CO., LTD", "produto": "Meia", "contato": "Ryan Wang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613968566688", "email": "gm@hlifeco.com", "site": "www.soxcustom.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950801660", "nome": "YUYI SILICONE PRODUCTS CO., LTD", "produto": "Moldes de silicone", "contato": "Ding Jingjie", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618969359395", "email": null, "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950795608", "nome": "ZHEJIANG LINGHONG INDUSTRY & TRADE CO., LTD", "produto": "Copos e garrafas térmicas", "contato": "Danly", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615157970274", "email": "sales5@raisuncup.com", "site": "http://www.swisok.cn/", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950801532", "nome": "PRODUTOS DE SILICONE AIRUI CO., LTD", "produto": "silicone", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8617349872240", "email": "wiweaverhl@hotmail.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950801535", "nome": "ZHONGSHAN FIRE KITCHEN AND SANITARY APPLIANCES CO., LTD", "produto": "Fogão", "contato": "Menling", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613822793737", "email": "646798297@qq.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 189 2812 2750/ +86 138 2279 3737"}, {"monday_id": "11950801235", "nome": "GUANGZHOU ZENGXING COMMERCIAL EQUIPMENT MANUFACTURING CO., LTD", "produto": "Maquinário industrial para cozinha", "contato": "Kin", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613416142228", "email": "muserci@kinzx.com", "site": "www.kinzx.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11950795794", "nome": "GUANGDONG GUIBAO ELETRIC APPLIANCE CO., LTD", "produto": "Produtos elétricos para cozinha", "contato": "Frank Fu", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615872248826", "email": "fffrank@gmail.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 189 0084 0982/ +86 158 7224 8826 | huaxiangjack@gmail.com/ fffrank@gmail.com"}, {"monday_id": "11950803543", "nome": "NOEL FURNITURE FOSHAN, CHINA", "produto": "Cadeiras para escritório", "contato": "Amanda Cho", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618038894581", "email": "amanda.c@noel-space.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11951008577", "nome": "WENZHOU JINMING HOLDINGS CO., LTD", "produto": "Parafusos para veículos", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8618857742351", "email": "387600380@q9.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 139 5886 8573/ +86 188 5774 2351"}, {"monday_id": "11951008921", "nome": "KERUN INTELEC CO., LTD", "produto": "Aparelhos de alta tenção", "contato": "Wade Wang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615397185869", "email": "marketing@krintelec.com", "site": "www.krintelec.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "rfq@krintelec.com/ marketing@krintelec.com"}, {"monday_id": "11951008838", "nome": "NINGBO HEHAI ELETRIC CO., LTD", "produto": "Produtos Magnéticos", "contato": "Peter Tang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618968394469", "email": "cherish@magnetcup.com", "site": "www.gmcmagnet.com/ www.magnetcup.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "cherish@gmcmagnet.com/ cherish@magnetcup.com"}, {"monday_id": "11951016932", "nome": "ZHEJIANG KEDI KITCHENWARE CO., LTD", "produto": "Panelas", "contato": "Jessica Zhang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615867790689", "email": "jessica@kedi-kitchenware.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 138 5893 3207/ +86 158 6779 0689 | jaana@kedi-kitchenware.com/ jessica@kedi-kitchenware.com"}, {"monday_id": "11951013105", "nome": "JINHUA LINGHANG KITCHEN INDUSTRY CO., LTD", "produto": "Panelas", "contato": "Mary", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618358902185", "email": "sales6@cook-lover.com", "site": "cooklover.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "winnie@nbjiyicooker.com/ chourenhuan@nbjiyicooker.cn"}, {"monday_id": "11951022986", "nome": "NINGBO JIYI PRESSURE COOKER CO., LTD/ NINGBO QIAO MAMA COOKWARE CO., LTD", "produto": "Panelas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613506880522", "email": "chourenhuan@nbjiyicooker.cn", "site": "www.nbjiyicooker.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "+86 158 8851 0058/ +86 135 0688 0522"}, {"monday_id": "11988489433", "nome": "ZHEJIANG JIAXIN COMMODITY CO., LTD", "produto": "Produtos para limpeza", "contato": "6ATYP", "origem": "CHINA HOME LIFE - 2025", "telefone": "8657685198668", "email": "kathy@zjjiaxin.com", "site": "www.jiaxin.cc", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 576 8939 5878/ 86 576 8519 8668"}, {"monday_id": "11988532032", "nome": "CREATING DIGITAL BUSINESS BAGS INTERNATIONAL FAMOUS BRAND", "produto": "Bolsas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "862031477658", "email": "ebf@eboxgz.com", "site": "www.eboxgd.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988489715", "nome": "ZHEJIANG KEDI KITCHENWARE CO., LTD", "produto": "Panelas", "contato": "Jessica Zhang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615867790689", "email": "jessica@kedi-kitchenware.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988493851", "nome": "NINGBO TONGYUE INTERNATIONAL TRADE CO., LTD", "produto": "Pinceis, espelhos, escovas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615888052318", "email": "kevindai@nbtongyue.com", "site": "tongyue2010.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988514329", "nome": "BOTHIDEA TOYS CO., LTD", "produto": "Brinquedos e massinhas", "contato": "Li Hao", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618663790032", "email": "info@bothideatoys.com", "site": "www.bothideatoys.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "lihao@bothideatoys.com/ info@bothideatoys.com"}, {"monday_id": "11988489728", "nome": "YIWU LANSON COSMETIC CO., LTD", "produto": "Cílios", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615669580300", "email": null, "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988493906", "nome": "YONGKANG MITCMOLARD TECHNOLOGY CO., LTD", "produto": "Produtos elíticos, panelas, fritadeiras...,", "contato": "Doris", "origem": "CHINA HOME LIFE - 2025", "telefone": "8617758067682", "email": "mld4@mitcmolard.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988489823", "nome": "HAIMEN SHENGYUAN BEDDING ARTICLES CO., LTD", "produto": "Roupa de cama", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615162733666", "email": null, "site": "www.bedding-factory.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988514528", "nome": "CANING (HK) CO., LTD/ HANGZHOU RUNLONG OUTDOOR EQUIPMENT CO., LTD", "produto": "Roupa automotiva", "contato": "XueSong Lee", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615925675757", "email": "runlong@caning.cn", "site": "www.caninghk.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988521155", "nome": "YONGKANG NOW POWER INDUSTRY AND TRADE CO., LTD", "produto": "Panelas", "contato": "Alli Du", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615058586202", "email": "sales@cnfashionhouse.com", "site": "phisma.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988516410", "nome": "YONGKANG FASHION HOUSE CO., LTD", "produto": "Panelas e utensílios", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615058586202", "email": "sales@cnfashionhouse.com", "site": "www.cnfhco.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988489946", "nome": "G- POWER STAINLESS STEEL COOKWARE (JIANGMEN) CO., LTD", "produto": "Panelas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8607506565131", "email": "keyond@g-power.com.cn", "site": "www.g-power.com.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "herbert@g-power.com.cn/ keyond@g-power.com.cn"}, {"monday_id": "11988513349", "nome": "FOSHAN HUAXING THERMOS CO., LTD", "produto": "Garrafas térmicas alta de qualidade", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "86075786858868", "email": "sales@nhhuaxing.com", "site": "www.nhhuaxing.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988503070", "nome": "ZHEJIANG HONGHAI COMMODITY CO., LTD", "produto": "Panelas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613758981607", "email": "sales7@hhcookware.com", "site": "www.hhcookware.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 197 0117 7867/ 86 137 5898 1607"}, {"monday_id": "11988514707", "nome": "NINGBO SAIAN INTELLIGENT TECHNOLOGY CO., LTD", "produto": "Produtos elétricos para cozinha", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615258252976", "email": "ningboyoulkang@163.com", "site": "ningbosaisn.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988532043", "nome": "YUYAO QIHANG VALVE TECHNOLOGY CO., LTD", "produto": "Válvula", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613386669817", "email": "312030317@qq.com", "site": "jjdcf88..1688.com/ www.qh-fm.com/ www.qh-fm.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 135 6638 1488/ 86 133 8666 9817"}, {"monday_id": "11988521987", "nome": "NINGBO JIUBAO TRANSMISSION MACHINERY CO., LTD", "produto": "Partes e peças", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8619012923508", "email": "mas@jubocast.com", "site": "www.jubocast.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988544463", "nome": "NINGBO BEIYE TRACTOR MANUFACTURING CO., LTD", "produto": "Trator", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8657422691669", "email": "info@bytlj.com", "site": "www.bytlj.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988517104", "nome": "HANGZHOU DEJI AUTO PARTS CO., LTD", "produto": "Partes e peças de caminhões", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613386532590", "email": null, "site": "xiangling.top/ hzxlqp.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988517112", "nome": "GUANGDONG CAMEN CHEMICAL CO., LTD/ GUANGDONG SHIBANG CAMEN CHEMICAL CO., LTD", "produto": "Fabricante especializado em pesquisa e desenvolvimento de aditivos para revestimentos", "contato": "Silvain", "origem": "CHINA HOME LIFE - 2025", "telefone": "8675726620881", "email": "sales@cmadditive.com", "site": "www.camen.cn/ www.cmadditive.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 751 3836 368/ 86 757 2662 0881"}, {"monday_id": "11988634648", "nome": "NINGBO MATCHING CO., LTD", "produto": "Tecidos e roupas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615957488962", "email": "sophia@nb-matching.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988804532", "nome": "HANGZHOU XIANRUI DIGITAL TECHNOLOGY CO., LTD", "produto": "Projetores e armações", "contato": "Nicole", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618768127113", "email": "nicole@timcee.com", "site": "www.cnxianrui.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988765214", "nome": "NINGBO ONE PLUS TWO COFFEE MACHINE TECH. CO., LTD", "produto": "Produtos para fazer café", "contato": "Shirley Zhang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615257489319", "email": "shirley@oneptwo.com", "site": "www.oneptwo.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 152 5748 9319 (wechat) 86 574 6258 3326 | info@oneptwo.com/ shirley@oneptwo.com"}, {"monday_id": "11988765423", "nome": "ZHONGSHAN NASENTONS TECHNOLOGY CO., LTD", "produto": "Fechaduras eletrônicas", "contato": "Jessie Pan", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615975327687", "email": "jessie@nasentons.com", "site": "www.nasentons.com/ www.beslock.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "jessie@beslock.com/ jessie@nasentons.com"}, {"monday_id": "11988762325", "nome": "NINGBO CONG YAO ELECTRIC APPLIANCE CO., LTD", "produto": "Air fryer", "contato": "Wendy Yang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613566582971", "email": "wendy@nbcongyao.com", "site": "congyaozha.wz.hwdlszywz.net", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988765631", "nome": "ZHONGSHAN NASENTONS TECHNOLOGY CO., LTD", "produto": "Partes e peças de fechaduras", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8615975327687", "email": "sales@nasentons.com", "site": "www.nasetons.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988775912", "nome": "TAIZHOU XIANYA CO., LTD", "produto": "Tábuas de corte de plástico e outros utensílios domésticos", "contato": "Jack Ying", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615167677660", "email": "jack@chinaplasticproducts.com", "site": "https://chinaplasticproducts.com/", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 576 8276 6020/ 86 151 6767 7660"}, {"monday_id": "11988765597", "nome": "NANHAI KRD ELECTRIC MANUFACTURING CO., LTD", "produto": "Partes e peças de ventiladores", "contato": "Jack Ying", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613316300595", "email": "richardyu8888@hotmail.com", "site": "www.gdkrd.net", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 133 1630 0595/ 8801759088881 | richardyu333@129.com/ richardyu8888@hotmail.com"}, {"monday_id": "11988751422", "nome": "NINGBO NEW SPEED ELECTRIC CO., LTD/ NINGBO NEW SPEED ELECTRIC CO., LTD", "produto": "Air fryer, batedeira, mix, moedor de café...", "contato": "Wong", "origem": "CHINA HOME LIFE - 2025", "telefone": "8657462757307", "email": "wong@nbnewspeed.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 574 6269 9099/ 86 574 6275 7307"}, {"monday_id": "11988804396", "nome": "FOSHAN VOLSUN ELECTRIC APPLIANCE CO., LTD", "produto": "Air fryer, batedeira, mix...", "contato": "Alfred", "origem": "CHINA HOME LIFE - 2025", "telefone": "86075786661770", "email": "alfred.luo@volsuncn.com", "site": "www.volsuncn.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 136 3007 1133/ 86 0757 8666 1770"}, {"monday_id": "11988765931", "nome": "CHINA JIANGSU YOUCHENG ZHIXIN ELETROMECHANICAL EQUIPMENT CO., LTD", "produto": "Estação de tanque, bomba de ar, motor de eixo longo de ventilador, compressor de ar.", "contato": "Vicky", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618106255893", "email": "jiangyuqing1@youchengzhixin.com", "site": "www.youchengzhixin.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988776654", "nome": "ANHUI YOUNGLIFT INTELLIGENT EQUIPMENT CO., LTD", "produto": "Empilhadeira", "contato": "Jane Jia", "origem": "CHINA HOME LIFE - 2025", "telefone": "8619032974610", "email": "jane@ahyounglift.com", "site": "www.yongjieli.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988779603", "nome": "SHENZHEN HUICHI TECHNOLOGY CO., LTD", "produto": "Carregadores de carro", "contato": "Freya Fu", "origem": "CHINA HOME LIFE - 2025", "telefone": "8640003032687", "email": "freyafu2011@foxmail.com", "site": "www.hci123.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 133 1651 8280/ 86 755 2699 5658/ 86 400 0303 268"}, {"monday_id": "11988762359", "nome": "ANJI CHUNYUN FURNITURE CO., LTD", "produto": "Sofás e poltronas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613065823738", "email": "mandy@cyrecliners.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988779768", "nome": "CIXI WAYLEAD ELECTRIC MOTOR MANUFACTURING CO., LTD", "produto": "Motor", "contato": "Cherry Cen", "origem": "CHINA HOME LIFE - 2025", "telefone": "86057458580503", "email": "cherry@waylead.com.cn", "site": "www.waylead.com.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 0574 5858 0503/ 5858 0502/ 5858 0505"}, {"monday_id": "11988766059", "nome": "TAIZHOU TENGZHI HOME PRODUCTS CO., LTD", "produto": "Vassouras, escovas sanitárias, escovas para roupas, escovas para cama, escovas para sapatos, escovas para garrafas, produtos para banho e aspiradores de pó", "contato": "Lynn", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613968655582", "email": "qs@zjqssy.com", "site": "www.tenzipc.com / zjqsbrush.1688.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 576 8222 9999/ 86 139 6865 5582 | qs@zjqssy.com/ tz@tenzipc.com"}, {"monday_id": "11988779929", "nome": "JINHUA SYNMORE KITCHENWARE CO., LTD", "produto": "Panelas", "contato": "Vincent", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618867959868", "email": "sales02@china-cookware.com", "site": "www.cnsnmore.en.alibaba.com/ www.synmore.en.alibaba.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988779899", "nome": "ZHEJANG XINSUDU VEHICLE INDUSTRY CO., LTD", "produto": "Carrinhos elétricos", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613858900396", "email": null, "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988779673", "nome": "GUANGDONG BALLON PACKAGING INDUSTRIAL CO., LTD (SHANTOU ZHONGHUI TECHNOLOGY CO., LTD)", "produto": "Decoração de festa", "contato": "Linda Pan", "origem": "CHINA HOME LIFE - 2025", "telefone": "13322796144", "email": "linda@boluen.com", "site": "www.boluen.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988779903", "nome": "Hangzhou Yicheng Textile Co., Ltd", "produto": "Produtos têxteis", "contato": "Candy", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615111336678", "email": "candy@sunnytextiles.net", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11988804579", "nome": "HUAXIN ELECTRONIC TECHNOLOGY (JIANG SU) CO., LTD", "produto": "Produtos relacionados a tecnologia", "contato": "Joyce Mao", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613868175661", "email": "joyce@huaxkj.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989143575", "nome": "ZHEJIANG EAST INDUSTRIAL CO., LTD", "produto": "Garrafas", "contato": "Jerry Yu", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613735620995", "email": "radiator@vip.136.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989143577", "nome": "ZHEJIANG EVERBRIGHT METAL TECHNOLOGY CO., LTD", "produto": "Maquinas", "contato": "Evan Ye", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618267391314", "email": "evan@everbrightpipe.com", "site": "www.everbrightpipe.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989150834", "nome": "Ningbo Chuanyueshikong Stationery Co., Ltd", "produto": "Canetas e materiais escolares", "contato": "Yu Jieqing", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613958261701", "email": "manager02@nbcysk.com", "site": "www.chotunestationery.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 135 8661 2026/ 86 139 5826 1701"}, {"monday_id": "11989152473", "nome": "NINGBO BELL GREEN FASHION CO., LTD", "produto": null, "contato": "Cao Xiuling", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615869382153", "email": "jhchaoxiuling@126.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989170276", "nome": "SUZHOU JUYUHONG TEXTILE CO., LTD", "produto": "Tecido", "contato": "Sun Jian", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613758081808", "email": null, "site": "www.juyuhong.com.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989168262", "nome": "GUANGZHOU HAPPY CREDIT APPAREL CO., LTD", "produto": "Roupas de criança", "contato": "Suki Tang", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618126759807", "email": "suki@happycreditapparel.com", "site": "lezonkids.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989164615", "nome": "QUANZHOU RUOXIN MACHINERY CO., LTD", "produto": "Maquinas de fralda", "contato": "Tristan Xiao", "origem": "CHINA HOME LIFE - 2025", "telefone": "8617306990595", "email": "tristan@rxhygiene.com", "site": "www.rxhygiene.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989170353", "nome": "HGV TECHNOLOGY (HK) CO., LIMITED", "produto": "Produtos elétricos", "contato": "Ada Xu", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618088886639", "email": "ada.xu@hgvtech.com", "site": "www.rca.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989164712", "nome": "GUANGZHOU EMILYFOTO CO., LTD", "produto": "Equipamentos para fotos e iluminação", "contato": "Emily", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613302293473", "email": null, "site": "www.enujoy.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989168082", "nome": "HANGZHOU TIANYE PACKAGING TECHNOLOGY CO., LTD", "produto": "Frascos e potes", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8657189150699", "email": "contact@tianyepkg.com", "site": "www.tianyepkg.com/ tianyepkg.en.made-in-china.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989170478", "nome": "ZHONGSHAN QINGSHUO PLASTIC PRODUCTS CO., LTD", "produto": "Embalagens para maquiagem", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "86013924979427", "email": "sales803@qingshuo.net.cn", "site": "www.qingshuo.net.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989168273", "nome": "YIWU GLOBAL PARTY CRAFTS CO., LTD", "produto": "Artigos para festa", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613676829300", "email": "clara-globalparty@foxmail.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989151248", "nome": "JINHUA CITY ZIHENG CRAFTS CO., LTD/ JIN HUA ZIHENG HANDICRAFT LTD", "produto": "Flores e buques", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8613957975332", "email": "445144532@qq.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989153032", "nome": "Su Zhou Rokii Intelligence and Technology Co.ltd", "produto": "Barracas", "contato": null, "origem": "CHINA HOME LIFE - 2025", "telefone": "8618852079837", "email": "julia.zhu@rokiitent.com", "site": "https://www.rokiitent.com/contactus", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989153124", "nome": "ZHEJIANG MERSCO INDUSTRY & TRADE CO., LTD", "produto": "Camas elásticas", "contato": "AMY GAO", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615867950288", "email": "sales01@zjmersco.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989165096", "nome": "TONG CHENG LIMITED / SHENZHEN CAROLINE CO., LTD", "produto": "Produtos de vidro e plástico (potes...)", "contato": "FEIFEI CHENG", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613825240434", "email": "feifei@hktongcheng.cn", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989159101", "nome": "FOSHAN TIANZHILI HARDWARE CO., LTD", "produto": "Joias e semi joias", "contato": "COCO", "origem": "CHINA HOME LIFE - 2025", "telefone": "8613829119939", "email": "yiran552184@qq.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989159108", "nome": "JINHUA SINOCLEAN CO., LTD", "produto": "Produtos de esponja de celulose flexível, pano de limpeza de esponja de cozinha pano de limpeza de microfibra, toalha de limpeza de microfibra pano de esponja, produtos suecos da série do dishcloth para a finalidade doméstica da limpeza que encontram ou excedem as necessidades de nossos clientes", "contato": "Tina", "origem": "CHINA HOME LIFE - 2025", "telefone": "8618258904936", "email": "tina@sinocleangroup.com", "site": "www.sinocleans.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989168491", "nome": "ANHUI RONGYAO IMPORT AND EXPORT CO., LTD", "produto": "Produtos pets", "contato": "Diameter Zhao", "origem": "CHINA HOME LIFE - 2025", "telefone": "8619355063070", "email": "tczbf2008@126.com", "site": "xiaxiang2000.1688.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "11989151416", "nome": "ZHEJIANG QIMEI COSMETICS CO., LTD", "produto": "Lenços umedecidos de qualidade para diversas aplicações, desde cuidados pessoais até usos industriais e comerciais", "contato": "Austin Tu", "origem": "CHINA HOME LIFE - 2025", "telefone": "8615906835102", "email": "austin@qimeiwetwipes.com", "site": "www.qimeiwetwipes.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12044664753", "nome": "NINGBO HONG LING INTERNATIONAL TRADE CO., LTD/ NINGBO HONG LING TEXTILE MANUFACTURING CO., LTD", "produto": "Importante exportadora e fabricante especializada em produtos têxteis para casa e bebês", "contato": "Jane Wu", "origem": "CHINA HOME LIFE - 2025", "telefone": "8657429900901", "email": "janewu@hlhometex.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049577012", "nome": "Foshan Simple Techonology", "produto": "Alto falantes e karaokê portátil", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8618902818875", "email": "Tsaipin@163.com", "site": "www.simple-tv.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049608710", "nome": "Shanzen Input Technology | Shenzen Jinmeiyi Technology", "produto": "Adaptadores para carro", "contato": "Adm Duan", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613632607982", "email": "sales7@inputcn.com", "site": "www.inputcn.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049608848", "nome": "Shenzhen MAXCO Technology", "produto": "Alto falantes", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8675582773499", "email": null, "site": "www.lanex.com.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049606845", "nome": "Cixi Shuangfu Eletrical Appliance", "produto": "Ar condicionado e Air fryer", "contato": "Wakin", "origem": "ELETROLAR SHOW - 2025", "telefone": "8657463563338", "email": "wakin-fang@126.com", "site": "www.china-shuangfu.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049627777", "nome": "Wenzhou Insun Crafts", "produto": "Aspirador de pó", "contato": "Louis Liu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618106797586", "email": "marketingdirector@insuncrafts.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049565793", "nome": "Ningbo Zhe Kai Eletric Appliance", "produto": "Aspiradores/ partes e peças", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8657463616127", "email": "manager@cnhansheng.com", "site": "www.i-hassan.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049623431", "nome": "SHENZHEN INPUT TECCHOLOGY CO., LTD / SHENZHEN JINMEIYI TECCHNOLOGY CO., LTD", "produto": "Carregador portátil", "contato": "Adm Duan", "origem": "ELETROLAR SHOW - 2025", "telefone": "8675589812186", "email": "sales7@inputcn.com", "site": "www.inputcn.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049623465", "nome": "Ningbo Alline Eletronic Technology", "produto": "Cabos", "contato": "Ciciliar Lee", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613429268210", "email": "sales5@lancom-cn.com", "site": "www.cabletimetech.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049623470", "nome": "Dogguan Qinghai Eletronics Technology", "produto": "Cabos", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "76982867983806", "email": "xinmao898@163.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049623835", "nome": "Changzhou LEMI eletronic", "produto": "Cabos", "contato": "Daniel", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618762820036", "email": "av1080@avitronic.com", "site": "www.avitronic.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049637520", "nome": "CHANGZHOU X ELETRONIC AND NEW MATERIAL CO., LTD", "produto": "Cabos", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8615061128020", "email": null, "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049566102", "nome": "Dogguan Jiadian Eletronics Technology", "produto": "Caixas de Som", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8676988558328", "email": "toby@kasung.com.cn", "site": "www.kasung.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049622489", "nome": "Yinkesong Biye R&D Center Shenzhen", "produto": "Canetas Touch", "contato": "Elephant Wen", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618988836183", "email": "elephant.wen@touchpentech.com.cn", "site": "www.touchpentech.com.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049627741", "nome": "Shenzhen Jingsu Technology", "produto": "Computadores", "contato": "Amber Pan", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618824594983", "email": "admin@jspcomputer.com", "site": "www.jspcomputer.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049627749", "nome": "Dongguan World Pass Industrial", "produto": "Conectores/Cabos", "contato": "Way Yeung", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618589099644", "email": "way@worldtypec.com", "site": "www.worldtypec.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "86 1858 9099 644/ 852 6187 9687"}, {"monday_id": "12049623283", "nome": "Wuye Tech", "produto": "Cuidados de cabelo", "contato": "Connie Gu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618046970218", "email": "connie@wuyekeji.com", "site": "www.wuyekeji.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049637695", "nome": "Zhejiang Senling Eletronics Technology", "produto": "Eletronicos", "contato": "Tobey Song", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618767121647", "email": "tobey@snnlnn.cn", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049627787", "nome": "Ningbo Chendian Eletrical Appliance Technology", "produto": "Eletronicos para cozinha", "contato": "Van Char", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615924366009", "email": "manager@ramllykitchen.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049622759", "nome": "Elecpro Group Holding", "produto": "Eletronicos para cozinha", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8675788374867", "email": null, "site": "www.elecpro.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049624318", "nome": "Jiangmen HomeMaster Electric Motors & Appliances Manufacturing Co., Ltd.", "produto": "Eletronicos para cozinha", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": null, "email": "kiki@jmhomemaster.com", "site": "www.jmhomemaster.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": "katy@jmhomemaster.com/kiki@jmhomemaster.com"}, {"monday_id": "12049963206", "nome": "Sarepo Technology (HK)", "produto": "Equipamentos gamer", "contato": "Laura Zou", "origem": "ELETROLAR SHOW - 2025", "telefone": "8675523115789", "email": "laura@sarepo.net", "site": "www.sarepo.net", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049963295", "nome": "Shenzhen Jianyuanda Mirror Technology", "produto": "Espelhos", "contato": "Betty Liu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615817342280", "email": "betty@jydmirror.com", "site": "www.jydmirror.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049955753", "nome": "Shenzhen Xiangxiangyu Teconology", "produto": "Fones de ouvido", "contato": "Paris He", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615813730819", "email": null, "site": "www.skjaudio.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049942388", "nome": "Mcurve Technology (Dongguan)", "produto": "Fones de ouvido", "contato": "Jaycee", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618779864606", "email": "jaycee@marscurve.com", "site": "www.marscurve.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049945971", "nome": "Shantou Sunrise Eletronics", "produto": "Fones de ouvido", "contato": "Thompson Ji", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618029568087", "email": "thompson@sunriselec.com", "site": "sunriselec.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049944292", "nome": "Dogguan Honghe Industry", "produto": "Fonte de energia", "contato": "Yillia Wang", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613875795504", "email": "ezmax.09@ezmax.com.cn", "site": "www.ezmax.com.cn", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049963395", "nome": "Yongkang Ganghong Industry e Trading", "produto": "Garrafas térmicas", "contato": "Jack Wang", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618397976200", "email": "jack@cngangrui.com", "site": null, "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049963633", "nome": "Wuyi Shua", "produto": "Garrafas térmicas", "contato": "Sharon Chan", "origem": "ELETROLAR SHOW - 2025", "telefone": "8657989092636", "email": "shuangli03@shuanglicup.com - shuangli03@shuanglicup.com7", "site": "www.shuanglicup.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049963638", "nome": "HPRT", "produto": "Impressora", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": null, "email": "os6@hprt.com", "site": "www.hprt.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049959091", "nome": "Shenzhen Aiduoduo Technology", "produto": "Impressora Térmica", "contato": "May Zhou", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615581005415", "email": "sales2@coolinbo.com", "site": "www.coolinbo.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049946395", "nome": "QUANZHOU MENEED COMMODITY CO., LTD", "produto": "Jogo de pratos", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "595221669973", "email": "sales@meneed.cn", "site": "www.meneed-melamine.com", "avaliacao": 4, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049946055", "nome": "Quanzhou Meneed Commodity", "produto": "Louça e talheres", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": null, "email": "sales@meneed.cn", "site": "www.meneed-melanine.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049963841", "nome": "Suining Festalight", "produto": "Luzes", "contato": "David Liu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618382520984", "email": "sales1@festalight.com", "site": "www.festalight.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "sales1@festalight.com/ rojar@188.com"}, {"monday_id": "12049956022", "nome": "Xinmingli Lighting", "produto": "Luzes", "contato": "Betty Zhi", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613655871491", "email": "xml@xml-lighting.com", "site": "www.xml-lighting.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049946104", "nome": "Ningbo Fayuan Beauty Instrument", "produto": "Máquinas para beleza", "contato": "Kelly", "origem": "ELETROLAR SHOW - 2025", "telefone": "86057462055024", "email": "nbyyfyc@vip.sina.com", "site": "www.fychairclipper.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049946238", "nome": "Shenzhen Future Eletronic", "produto": "Massageadores Portátil", "contato": "Alice Shi", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613554979069", "email": "sales09@futuresz.com", "site": "www.massagerschina.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049968656", "nome": "Shenzhen Furui Jie Eletronic Technology", "produto": "Microfones", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8615905749527", "email": "l3422677135@outlook.com", "site": "tansuodianzi.1688.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049944300", "nome": "Shaan Xi Succeed Trading", "produto": "Mosqueteiras", "contato": "Krystal Wu", "origem": "ELETROLAR SHOW - 2025", "telefone": null, "email": "mostrap@hotmail.com", "site": "www.mostrap.net www.mostrap.cn", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "mostrap@vip.com /mostrap@hotmail.com"}, {"monday_id": "12049955862", "nome": "Keli Motor Group", "produto": "Motores", "contato": "Linna Zeng", "origem": "ELETROLAR SHOW - 2025", "telefone": "8675581958899", "email": "linna@kelimotor.com", "site": "www.kelimotor.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12049959445", "nome": "GUANGZHOU PINSHUN MEDICAL ROBOT CO., LTD", "produto": "Malas motorizadas", "contato": "Beke", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613424128470", "email": "172892566@qq.com", "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051576712", "nome": "Taly Metal Technology Limited", "produto": "Produtos de montagem", "contato": "Richard Chen", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613968323449", "email": "sker01@sker-tvstand.com", "site": "www.sker-office.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051581639", "nome": "Fifine products", "produto": "Produtos Gamer", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8618026151148", "email": "marketing@fifinedesign.com", "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051580333", "nome": "Yumyth Eletronic Tech", "produto": "Produtos/seladores para cozinha", "contato": "Nancy", "origem": "ELETROLAR SHOW - 2025", "telefone": "8676922287440", "email": "nancy@yumyth.com", "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051569079", "nome": "Shenzhen Shadow Crown Technology", "produto": "Projetores", "contato": "Macy Ma", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613737588889", "email": "macy.ma@hiao.com", "site": "www.hiao.com www.shadowcrowntech.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "xiefx@wireking.com / wireking@wireking.com"}, {"monday_id": "12051580337", "nome": "GUANGDONG WIREKING HOUSEWARES & HARDWARE CO., LTD", "produto": "Produtos de cozinha", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": null, "email": "wireking@wireking.com", "site": "wireking.en.alibaba.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "Wechat ID Lovelife2020W"}, {"monday_id": "12051600418", "nome": "Zhongshan Yehos Eletrical Appliance", "produto": "Refrigeradores", "contato": "Vicky", "origem": "ELETROLAR SHOW - 2025", "telefone": "8676023772852", "email": "vicky@yehos.com", "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "17170892606/86 760 2377 2852"}, {"monday_id": "12051577756", "nome": "GUANGDONG ZHANGONG ELECTRICAL TECHNOLOGY CO., LTD", "produto": "Tomadas", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8613760900028", "email": null, "site": "www.zhangongsocket.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "0757 26363652/ 86 137 6090 0028"}, {"monday_id": "12051580404", "nome": "XIAMEN HANIN CO., LTD", "produto": "Seladora a Vácuo Portátil", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8613799841091", "email": "os@hprt.com", "site": "www.hprt.com", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051580409", "nome": "NINGBO RUNCHEW / NINGBO CHENDIAN", "produto": "Air fryer", "contato": "Van Char", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615924366009", "email": "manager@ramllykitchen.com", "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051547395", "nome": "Wuxi Qihao Metal Co.,Ltd", "produto": "Aço inoxidável", "contato": "Henry Yang", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613358106555", "email": "wxqh@qihaometal.com", "site": "https://www.wxqhmetal.com/product-200004?gad_source=1&gad_campaignid=21874535988&gbraid=0AAAAA-dEdnVWqNSOOpaVDx4GaMnDmAd4z&gclid=Cj0KCQjwl5jHBhDHARIsAB0YqjxsQOSmmR0Y7b-iaR1XKGSZV4UPqPDPx4R_x25r1ZXwLkkueOwzNoUaAmMgEALw_wcB", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051569508", "nome": "Shenzhen Minengge Technology Co., Ltd.", "produto": "Power Bank e Fones", "contato": "Joanne", "origem": "ELETROLAR SHOW - 2025", "telefone": "8675582773499", "email": "hr@maxcotech.com", "site": "http://www.lanex.com.cn/", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051561503", "nome": "Gaobeidian Restar Electrical Applicances Manufacture Co., Ltd.", "produto": "MOP", "contato": "Vivian Wang", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618911628020", "email": "18911628020@163.com", "site": "https://gbdrsd.en.alibaba.com/", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051610682", "nome": "GUANGZHOU BEAUTY ELECTRONICS CO.,LTD", "produto": "Battery", "contato": "Leon", "origem": "ELETROLAR SHOW - 2025", "telefone": "862087422645", "email": "121335569@qq.com", "site": "http://www.btybattery.com/en/contact.asp", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051574703", "nome": "AMGRA", "produto": "Power Bank e Fones", "contato": "Angelia", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615521023557", "email": null, "site": "https://www.amgras.com/", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051561586", "nome": "Dongguan Zhenghao Electronic Technology Co., Ltd.", "produto": "Teclados e mouses", "contato": "Stephan Wu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618681048295", "email": null, "site": "https://www.szforter.com/", "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051577156", "nome": "16", "produto": "Suporte para colocar em motas ou bicicletas contra chuva, barraca.", "contato": "Adham", "origem": "Fornecedor do Matheus", "telefone": "8613314335471", "email": null, "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051577407", "nome": "17", "produto": "Talheres", "contato": "Echo", "origem": "Fornecedor do Matheus", "telefone": null, "email": null, "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "Wechat ID: ideal-flatware"}, {"monday_id": "12051569551", "nome": "18", "produto": "Costa Vento", "contato": "ki", "origem": "Fornecedor do Matheus", "telefone": null, "email": null, "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12051589274", "nome": "19", "produto": "Panela", "contato": "Vincent", "origem": "Fornecedor do Matheus", "telefone": null, "email": null, "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": "Wechat Id: xm18867959868"}, {"monday_id": "12051569703", "nome": "20", "produto": "Fogão de indução", "contato": "Cherry/ Cherie", "origem": "Fornecedor do Matheus", "telefone": "8615398822575", "email": null, "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12099226375", "nome": "Ebox bags factory", "produto": "Bolsa/ mochila", "contato": "Jelly", "origem": "Fornecedor do Matheus", "telefone": null, "email": null, "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12099226337", "nome": "22", "produto": "Tábua de corte plástica", "contato": "Jacky", "origem": "Fornecedor do Matheus", "telefone": null, "email": null, "site": null, "avaliacao": null, "criado_por": "Ana Clara Ré Rosa", "observacoes": null}, {"monday_id": "12648394702", "nome": "Orangeknow Technology Co.,Ltd", "produto": "Humidificadores e difusores", "contato": "Jeremy", "origem": "ELETROLAR SHOW", "telefone": "8613590612603", "email": "s01@orangekw.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648410360", "nome": "Shenzhen Welkousi Technology Co.,Ltd", "produto": "Fones, suportes de computador", "contato": "YOYO", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613726387715", "email": "YOYO@sayroseshop.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648433346", "nome": "Dogguan Rainbow Tech Electonic & Plastic Products Co.,Ltd", "produto": "Relógios", "contato": "Ken Qiu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613416833913", "email": "ken@rainbowtech-industrial.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648443391", "nome": "JER Education Technology Co., Ltd", "produto": "Canetas 3D", "contato": "Justin Hu", "origem": "ELETROLAR SHOW - 2025", "telefone": "862085578797", "email": "sales1@jereducation.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648555252", "nome": "darkbeacon. ai", "produto": "Teclados e mouses", "contato": "Moon", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613510023290", "email": "moon.ni@darkbeacon.ai", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648577633", "nome": "Fly Sonic Electronics Co.,Ltd", "produto": "Fones de ouvido", "contato": "Matt Zhuang", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613928974567", "email": "matt@flysonico.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648580822", "nome": "JUFU Animation Technoly Co.,Ltd", "produto": "Brindes", "contato": "Kai Deng", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613712982666", "email": "cg_27@126.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648560897", "nome": "Zhongshan Auramor Smart Technology Co.,Ltd", "produto": "Lustres", "contato": "Jennie", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618576064191", "email": "Jennie@longshane.com", "site": "www.aromartime.com", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648640807", "nome": "Shenzhen Vimai Technology Co.,Ltd", "produto": "Fones de ouvido", "contato": "Helen", "origem": "ELETROLAR SHOW - 2025", "telefone": "86075586520860", "email": "helen@vimai.net", "site": "www.vimai.hk", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648651505", "nome": "Shenzhen Colmi Technology Co,.Ltd", "produto": "Relógios", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8613724306469", "email": "sales@colmi.com", "site": "www.oemwatchco.com", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648687463", "nome": "Yiwu Yuyi Silicone Products Co.,Ltd", "produto": "Produtos de cozinha", "contato": "Ding Jingjie", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618969359395", "email": null, "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648732936", "nome": "Shenzhen Kingwear Technology Development Co.,Ltd", "produto": "Relógios", "contato": "Jet", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618126241932", "email": "sunwd@king-world.cn", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648731094", "nome": "EYKI WATCH", "produto": "Relógios", "contato": "Doris Zheng", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613826120251", "email": "doriszhheng@eyki.com", "site": "jiusko.en.alibaba.com", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648745215", "nome": "Zhongshan Jianqi Tongfang Electronic Co.,Ltd", "produto": "Caixas de Som", "contato": "Leap Zheng", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613549944027", "email": "jqtf4@jqtf.com", "site": "www.jqtf.com", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648823611", "nome": "Shenzhen Top Micro Technology Co.,Ltd", "produto": "Power Bank", "contato": "Anita", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613926526179", "email": "anita@tomicro.com.cn", "site": "www.topmicro.com.cn", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648833498", "nome": "Guangzhou Ruliu Technology Co.,Ltd", "produto": "Câmera", "contato": "Leah Mak", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615627787237", "email": "leah@thelectronic.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648888945", "nome": "Guangdong Kooling Technology Co.,Ltd", "produto": "Humidificadores e difusores", "contato": "Michiko You", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615625820287", "email": "sales01@coolwhist.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648924192", "nome": "Shenzhen SoundSOUL Information Co.,Ltd", "produto": "Fones de ouvido", "contato": "Jasmine Yu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618727400600", "email": "sales08@soundpeatsaudio.com", "site": "www.soundpeats.com", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12648992362", "nome": "Shenzhen Chenyun Electronics Industrial Co.,Ltd", "produto": "Fones de ouvido", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8675523729089", "email": "sales@szchenyu.cn", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649039080", "nome": "Shenzhen XinShuoYa Electronics Co.,Ltd", "produto": "Fones de ouvido", "contato": "Fayne Han", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613418482535", "email": "fayne@ovtech.cn", "site": "www.ovtech.cn", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649113667", "nome": "Foshan Simple Technology Co.,Ltd", "produto": "Caixas de som, tvs", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8618902818875", "email": "tsaipin@163.com", "site": "www.simple-tv.cn", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649198892", "nome": "Shenzhen Shike Kan Wah Electronics Co.,Ltd", "produto": "Fones de ouvido", "contato": "Sadila Yu", "origem": "ELETROLAR SHOW - 2025", "telefone": "8675529538997", "email": "sales3@china-headphone.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649219512", "nome": "Shenzhen Vip Technology Co.,Ltd", "produto": "Suporte para celular", "contato": "Qiao", "origem": "ELETROLAR SHOW - 2025", "telefone": "8618124513140", "email": "499532736@qq.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649252687", "nome": "Shenzhen Sulian Industrial Co.,Ltd", "produto": "Carregadores", "contato": "Yolanda", "origem": "ELETROLAR SHOW - 2025", "telefone": "8619879404486", "email": "Yolanda@sulian-link.com", "site": "www.sulian-link.com", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649283481", "nome": "Guangzhou Mai Guan Electronic Technology Co.,Ltd", "produto": "Power Bank e Fones", "contato": null, "origem": "ELETROLAR SHOW - 2025", "telefone": "8613249632867", "email": null, "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649286068", "nome": "Shenzhen Meihuibao Eletronics Technology Co.,Ltd", "produto": "Carregadores", "contato": "jJinglai Chen", "origem": "ELETROLAR SHOW - 2025", "telefone": "8615814462493", "email": null, "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649344675", "nome": "Enping City Aidi Technology Co.,Ltd", "produto": "Microfones", "contato": "Selina", "origem": "ELETROLAR SHOW - 2025", "telefone": "8613316763335", "email": "salina@aidiaudio.cn", "site": "www.aidiaudio.com", "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}, {"monday_id": "12649367362", "nome": "Zhongshan Jianqi Tongfang Electronics Co.,Ltd", "produto": "Caixas de Som", "contato": "Leap Zheng", "origem": "ELETROLAR SHOW - 2025", "telefone": "86076028176020", "email": "jqtf4@jqtf.com", "site": null, "avaliacao": null, "criado_por": "Alycia Pistoia", "observacoes": null}]$fornec$::jsonb) as importados;
-- =====================================================================
-- 017 — Detalha o checklist de Projeto com os passos de verificação da
-- estimativa que existem no Monday mas não existiam no sistema (a devolutiva
-- de verificação e o envio final para o Matheus). Rodar DEPOIS do 001–016.
-- =====================================================================

do $$
declare
  v_proj int;
  v_resp uuid[];
  v_label text;
begin
  select id into v_proj from public.etapas where nome = 'Projeto (Flex / Premium / Full)';
  if v_proj is null then return; end if;

  -- mesmo responsável do item 140 (Montagem da estimativa)
  select responsaveis, responsaveis_label into v_resp, v_label
    from public.checklist_modelo where etapa_id = v_proj and ordem = 140;
  v_label := coalesce(v_label, 'Alycia');

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 145, '15º Verificação da estimativa de custos',
         'Conferência da estimativa montada antes de devolver para quem solicitou.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 145);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 150, '16º Devolutiva da verificação da estimativa',
         'Devolutiva de quem verificou para quem montou a estimativa, com ajustes se precisar.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 150);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 155, '17º Verificação da devolutiva',
         'Última conferência depois da devolutiva, antes de fechar a estimativa.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 155);

  insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao, responsaveis, responsaveis_label, prazo_item)
  select v_proj, 160, '18º Envio da estimativa de custos para o Matheus',
         'Estimativa fechada e enviada para o Matheus.', coalesce(v_resp, '{}'), v_label, 1
  where not exists (select 1 from public.checklist_modelo where etapa_id = v_proj and ordem = 160);

  -- processos com a etapa de Projeto ainda não concluída recebem os itens novos
  perform public.sincronizar_checklist(pe.processo_id)
    from public.processo_etapas pe
   where pe.etapa_id = v_proj and pe.status <> 'concluida';
end $$;

notify pgrst, 'reload schema';
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
-- 019 — progresso do checklist de Projeto importado do Monday (rodar depois do 018)
select public.importar_progresso_projeto($tp$[{"cnpj_digits": "41346526000105", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70]}, {"cnpj_digits": "27723891000160", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70]}, {"cnpj_digits": "65354116000174", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10]}, {"cnpj_digits": "05314730000180", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "48135251000100", "nome_busca": null, "ordens": [10]}, {"cnpj_digits": "48392117000194", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "61733855000116", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 110, 120, 100]}, {"cnpj_digits": "05060510000178", "nome_busca": null, "ordens": [10, 20, 30, 40, 50]}, {"cnpj_digits": "53998583000158", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60]}, {"cnpj_digits": "23875559000160", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70]}, {"cnpj_digits": "47431596000148", "nome_busca": null, "ordens": [10, 20]}, {"cnpj_digits": "42514980000190", "nome_busca": null, "ordens": [20, 10]}, {"cnpj_digits": null, "nome_busca": "Alfredo e Laertes", "ordens": [10, 20, 30, 40]}, {"cnpj_digits": null, "nome_busca": "Ronney e Fabricio", "ordens": [10, 20]}, {"cnpj_digits": "01130505000133", "nome_busca": null, "ordens": [10, 20, 30]}, {"cnpj_digits": "05293905000110", "nome_busca": null, "ordens": [10, 20]}, {"cnpj_digits": "17146063000153", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70]}, {"cnpj_digits": "46731165000134", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 110, 120, 100]}, {"cnpj_digits": "26454968000181", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "29457767000126", "nome_busca": null, "ordens": [30, 40, 20, 10]}, {"cnpj_digits": "35364253000129", "nome_busca": null, "ordens": [30, 40, 50, 20, 10]}, {"cnpj_digits": "39678603000182", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10]}, {"cnpj_digits": "42679362000109", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "53416494000156", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70]}, {"cnpj_digits": "11101705000111", "nome_busca": null, "ordens": [30, 60, 40, 20, 10, 70]}, {"cnpj_digits": "41865179000127", "nome_busca": null, "ordens": [20, 10]}, {"cnpj_digits": "24112565000129", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "63240217000199", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "11487007000104", "nome_busca": null, "ordens": [20, 10]}, {"cnpj_digits": "40691322000149", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70]}, {"cnpj_digits": "56422757000128", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70]}, {"cnpj_digits": "00425586000136", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70, 100, 110, 120, 130]}, {"cnpj_digits": "66326467000134", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70, 100, 110, 120, 130]}, {"cnpj_digits": "09449880000152", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70, 100, 110, 120]}, {"cnpj_digits": "05886568000175", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60]}, {"cnpj_digits": "02819698000105", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60]}, {"cnpj_digits": "67112674000159", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70, 100, 110, 120, 130]}, {"cnpj_digits": "65768388000110", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 100, 70, 110, 120, 130]}, {"cnpj_digits": "37837735000184", "nome_busca": null, "ordens": [10, 20, 30, 40, 50, 60, 70]}, {"cnpj_digits": "18074238000127", "nome_busca": null, "ordens": [10]}, {"cnpj_digits": "37241683000189", "nome_busca": null, "ordens": [10, 20, 30, 40, 50]}, {"cnpj_digits": "31542063000101", "nome_busca": null, "ordens": [10, 20]}, {"cnpj_digits": "35612594000176", "nome_busca": null, "ordens": [10, 20]}, {"cnpj_digits": "60954728000184", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "58669366000138", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "30883212000125", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "05847304000102", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "39980975000169", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "63943092000163", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "45250558000163", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "56441450000174", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "49834277000109", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "13060341000102", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "15542067000125", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 145, 155]}, {"cnpj_digits": "65051947000177", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "43740473000138", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 145, 155]}, {"cnpj_digits": "50652413000129", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": null, "nome_busca": "Rodrigo", "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "38280716000162", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "31022768000190", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "07012796000141", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "63943092000163", "nome_busca": null, "ordens": [130, 110, 120, 100]}, {"cnpj_digits": "64486034000110", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "24839614000120", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "02987556000149", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "51283930000130", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "43176921000112", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "66454015000138", "nome_busca": null, "ordens": [110, 120]}, {"cnpj_digits": "65385498000101", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "33301384000131", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "32411713000134", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "67176355000107", "nome_busca": null, "ordens": [130]}, {"cnpj_digits": "01012796000141", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "46604136000101", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10]}, {"cnpj_digits": "38280716000162", "nome_busca": null, "ordens": [140, 130, 110, 120]}, {"cnpj_digits": "20937329000190", "nome_busca": null, "ordens": [155, 160, 140, 130, 110, 120, 145]}, {"cnpj_digits": "27723891000160", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 110, 120, 100]}, {"cnpj_digits": "05314730000180", "nome_busca": null, "ordens": [30, 40, 20, 10]}, {"cnpj_digits": "71599450000190", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "24854393000169", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "64965122000103", "nome_busca": null, "ordens": [30, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "28222166000171", "nome_busca": null, "ordens": [30, 40, 50, 20, 10]}, {"cnpj_digits": "16758490", "nome_busca": null, "ordens": [30, 40, 50, 20, 10]}, {"cnpj_digits": null, "nome_busca": "Stéfano", "ordens": [30, 60, 40, 20, 10]}, {"cnpj_digits": "36098755000118", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": "67517564000177", "nome_busca": null, "ordens": [130, 110, 120, 140, 145, 155, 160]}, {"cnpj_digits": "10908041000134", "nome_busca": null, "ordens": [130, 110, 120, 140, 145, 155, 160]}, {"cnpj_digits": "23250563000133", "nome_busca": null, "ordens": [130, 110, 120, 140, 145, 155, 160]}, {"cnpj_digits": "24839614000120", "nome_busca": null, "ordens": [130, 110, 120, 140, 145, 155, 160]}, {"cnpj_digits": "65887673000150", "nome_busca": null, "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100, 155, 145]}, {"cnpj_digits": null, "nome_busca": "EDUART", "ordens": [30, 150, 60, 160, 40, 50, 20, 140, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "13347012000139", "nome_busca": null, "ordens": [30, 150, 60, 40, 50, 20, 10, 70, 130, 110, 120, 100]}, {"cnpj_digits": "39428231000136", "nome_busca": null, "ordens": [20, 10]}]$tp$::jsonb) as resultado;
-- =====================================================================
-- 020 — Completa o checklist das etapas de Ordem/Produção/Viagem com os
-- passos que existem no quadro "Ordens" do Monday mas não existiam no
-- sistema (documentação da fábrica, auditoria, chegada no Brasil).
-- Rodar DEPOIS do 001–019.
-- =====================================================================

do $$
declare
  v_ordem_etapa int;
  v_chegou int;
begin
  select id into v_ordem_etapa from public.etapas where nome = 'Processo / Ordem / Pagamento';
  select id into v_chegou from public.etapas where nome = 'Chegou';

  if v_ordem_etapa is not null then
    insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
    select v_ordem_etapa, 15, 'Documentação e verificação',
           'Documentação da fábrica conferida logo após o recebimento da ordem.'
    where not exists (select 1 from public.checklist_modelo where etapa_id = v_ordem_etapa and ordem = 15);

    insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
    select v_ordem_etapa, 25, 'Auditoria de fábrica',
           'Auditoria do fornecedor/fábrica antes de seguir com a produção.'
    where not exists (select 1 from public.checklist_modelo where etapa_id = v_ordem_etapa and ordem = 25);

    perform public.sincronizar_checklist(pe.processo_id)
      from public.processo_etapas pe
     where pe.etapa_id = v_ordem_etapa and pe.status <> 'concluida';
  end if;

  if v_chegou is not null then
    insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
    select v_chegou, 10, 'Chegada no Brasil confirmada',
           'Confirmação de que a carga chegou no Brasil.'
    where not exists (select 1 from public.checklist_modelo where etapa_id = v_chegou and ordem = 10);

    perform public.sincronizar_checklist(pe.processo_id)
      from public.processo_etapas pe
     where pe.etapa_id = v_chegou and pe.status <> 'concluida';
  end if;
end $$;

notify pgrst, 'reload schema';
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
-- 022 — progresso das ordens importado do Monday (rodar depois do 021)
select public.importar_progresso_ordens($ord$[{"cnpj_digits": "62877346000120", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 15}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 25}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 50}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 20}]}, {"cnpj_digits": "47525780000157", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 15}]}, {"cnpj_digits": "30883212000125", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 15}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 25}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 50}]}, {"cnpj_digits": "40795471000158", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 15}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 25}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 20}]}, {"cnpj_digits": "02987556000149", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}]}, {"cnpj_digits": "61182138000143", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}]}, {"cnpj_digits": "65385498000101", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}]}, {"cnpj_digits": "60954728000184", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}]}, {"cnpj_digits": "66937314000123", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}]}, {"cnpj_digits": "39848375000141", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 15}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 25}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 20}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 50}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 30}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 40}]}, {"cnpj_digits": "66454015000138", "marcar": [{"etapa": "Processo / Ordem / Pagamento", "ordem": 10}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 15}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 25}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 20}, {"etapa": "Processo / Ordem / Pagamento", "ordem": 50}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 30}, {"etapa": "Booking + Coleta + Estufagem", "ordem": 40}, {"etapa": "Viagem", "ordem": 10}]}]$ord$::jsonb) as resultado;
