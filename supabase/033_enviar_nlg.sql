-- =====================================================================
-- 033 — Jornada 4S termina na Ordem; a NLG (sistema separado) cuida do resto
-- Rodar DEPOIS do 001–032. Pode rodar mais de uma vez.
--
--   • As etapas de Booking até Chegou ficam INATIVAS: processos novos terminam na Ordem
--     (ao concluir a Ordem, o processo é encerrado aqui). Processos que já estão nessas
--     etapas continuam normalmente — eles guardam a própria cópia das etapas.
--   • Certificação: item opcional no fim da Ordem (a maioria dos processos não tem).
--   • "Enviar para a NLG": registra que o processo foi enviado (quando e com qual código).
-- =====================================================================

update public.etapas set ativo = false
 where nome in ('Booking + Coleta + Estufagem', 'Viagem', 'Desembaraço', 'Liberado', 'Transporte', 'Chegou');

insert into public.checklist_modelo (etapa_id, ordem, titulo, descricao)
select e.id, 990, 'Certificação (se o produto não precisar, marque e siga)',
       'A maioria dos processos não tem certificação. Marque este item mesmo quando não houver, para fechar a Ordem.'
  from public.etapas e
 where e.nome = 'Processo / Ordem / Pagamento'
   and not exists (select 1 from public.checklist_modelo m where m.etapa_id = e.id and m.titulo like 'Certificação%');

select public.sincronizar_checklist(id) from public.processos where status = 'ativo';

alter table public.processos add column if not exists enviado_nlg_em timestamptz;
alter table public.processos add column if not exists enviado_nlg_codigo text;

create or replace function public.marcar_enviado_nlg(p_processo_id uuid, p_codigo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_equipe() then raise exception 'Sem permissão'; end if;
  perform set_config('pc.rpc', 'on', true);
  update public.processos
     set enviado_nlg_em = now(), enviado_nlg_codigo = nullif(trim(p_codigo), '')
   where id = p_processo_id;
  if not found then raise exception 'Processo não encontrado'; end if;
  insert into public.processo_eventos (processo_id, tipo, texto)
  values (p_processo_id, 'comentario', 'Enviado para a NLG' || coalesce(' (' || nullif(trim(p_codigo), '') || ')', ''));
  perform set_config('pc.rpc', 'off', true);
end $$;
grant execute on function public.marcar_enviado_nlg(uuid, text) to authenticated;

notify pgrst, 'reload schema';
