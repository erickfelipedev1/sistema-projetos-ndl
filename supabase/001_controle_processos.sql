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
