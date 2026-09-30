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
