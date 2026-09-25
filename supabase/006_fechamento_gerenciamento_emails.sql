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
