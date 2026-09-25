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
