-- =====================================================================
-- 032 — Comentários com anexos e @menções (aba Comentários do processo)
-- Rodar DEPOIS do 001–031. Pode rodar mais de uma vez.
--
--   • anexos.evento_id: liga um arquivo ao comentário em que foi enviado
--     (continua aparecendo também na aba Anexos do processo).
--   • comentar_processo(processo, texto, mencionados): grava o comentário e, para cada
--     pessoa da equipe mencionada com @, manda uma mensagem direta no chat
--     ("X mencionou você em PRC-0001 · Cliente") — ela recebe a notificação pelo
--     contador de não lidas do menu "Chat e demandas".
-- =====================================================================

alter table public.anexos add column if not exists evento_id bigint references public.processo_eventos(id) on delete set null;
create index if not exists anexos_evento_idx on public.anexos (evento_id) where evento_id is not null;

create or replace function public.comentar_processo(p_processo_id uuid, p_texto text, p_mencionados uuid[] default '{}')
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_id bigint;
  v_autor uuid := auth.uid();
  v_proc public.processos;
  v_nome_autor text;
  r uuid;
begin
  if not public.is_equipe() then raise exception 'Só a equipe pode comentar'; end if;
  if coalesce(trim(p_texto), '') = '' then raise exception 'Escreva o comentário'; end if;

  select * into v_proc from public.processos where id = p_processo_id;
  if v_proc.id is null then raise exception 'Processo não encontrado'; end if;

  insert into public.processo_eventos (processo_id, tipo, texto)
  values (p_processo_id, 'comentario', trim(p_texto))
  returning id into v_id;

  select coalesce(nullif(trim(nome), ''), email) into v_nome_autor from public.profiles where id = v_autor;

  for r in select distinct m from unnest(coalesce(p_mencionados, '{}')) m loop
    if r is distinct from v_autor
       and exists (select 1 from public.profiles where id = r and tipo = 'equipe') then
      insert into public.mensagens (conversa_id, autor, texto, processo_id)
      values (public.pc_conversa_entre(v_autor, r), v_autor,
              coalesce(v_nome_autor, 'Alguém') || ' mencionou você em ' || v_proc.codigo || ' · ' || v_proc.cliente
                || E'\n' || left(trim(p_texto), 600),
              p_processo_id);
    end if;
  end loop;

  return v_id;
end $$;
grant execute on function public.comentar_processo(uuid, text, uuid[]) to authenticated;

notify pgrst, 'reload schema';
