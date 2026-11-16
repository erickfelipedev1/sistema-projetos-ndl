-- =====================================================================
-- 036 — Habilitação de Radar (Siscomex), no cadastro do cliente (atualização de 09/11/2026)
-- Rodar DEPOIS do 035. Pode rodar mais de uma vez.
--
-- O Radar é da EMPRESA (vale para todos os processos dela), por isso fica no cliente:
--   • documentos pedidos ao cliente: RG/CNH do responsável legal, contrato social, e-CPF;
--   • andamento na Receita Federal, limite concedido, data do deferimento e validade;
--   • devolutiva enviada ao cliente (e-mail) e opção pelo DTE no e-CAC;
--   • procuração assinada com firma reconhecida (NLG representa nos procedimentos aduaneiros);
--   • histórico das comunicações e os arquivos (anexos com categoria 'radar').
-- O limite aparece também nas informações de cada processo do cliente.
-- =====================================================================

create table if not exists public.cliente_radar (
  cliente_id uuid primary key references public.clientes(id) on delete cascade,
  status text not null default 'documentos'
    check (status in ('documentos', 'em_analise', 'habilitado', 'indeferido', 'inativo')),
  doc_identidade boolean not null default false,     -- RG ou CNH do responsável legal
  doc_contrato_social boolean not null default false,
  doc_ecpf boolean not null default false,           -- certificado digital e-CPF do responsável legal
  modalidade text,                                   -- ex.: Limitada, Ilimitada, Expressa
  limite_usd numeric(14, 2),
  limite_periodo text default 'semestre',            -- o limite vale por semestre
  deferido_em date,
  validade_ate date,
  dte_ecac boolean not null default false,           -- optou pelo DTE (caixa postal do e-CAC)
  devolutiva_em date,                                -- e-mail com o resultado enviado ao cliente
  procuracao_assinada boolean not null default false,
  procuracao_firma boolean not null default false,   -- firma reconhecida
  procuracao_em date,
  historico text,
  atualizado_por uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.cliente_radar enable row level security;
drop policy if exists pc_cliente_radar_equipe on public.cliente_radar;
create policy pc_cliente_radar_equipe on public.cliente_radar
  for all to authenticated using (public.is_equipe()) with check (public.is_equipe());
grant select, insert, update, delete on public.cliente_radar to authenticated;

-- arquivos do Radar ficam com o cliente, separados dos outros
alter table public.anexos add column if not exists categoria text;
create index if not exists anexos_cliente_categoria_idx on public.anexos (cliente_id, categoria);

notify pgrst, 'reload schema';
