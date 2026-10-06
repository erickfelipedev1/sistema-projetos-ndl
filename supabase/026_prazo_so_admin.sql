-- =====================================================================
-- 026 — Prazo só pode ser alterado por administrador
-- Vale para o prazo da etapa e para o prazo de cada item do checklist.
-- Exceção: etapas com "data de chegada" (prazo_editavel = sim, ex.: ETA da
-- viagem) — não têm prazo pré-definido, então quem edita a etapa preenche.
-- As funções do sistema (avançar, voltar, recalcular, importar) e os
-- gatilhos de espera do cliente continuam ajustando prazo normalmente.
-- =====================================================================

create or replace function public.pc_trava_etapa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 or current_setting('pc.rpc', true) = 'on' then return new; end if;
  if not public.pode_editar_etapa(old.id) then perform public.pc_sem_permissao(old.area); end if;
  if new.prazo_em is distinct from old.prazo_em and not old.prazo_editavel and not public.is_admin() then
    raise exception 'Sem permissão: o prazo desta etapa é definido pelo plano e só um administrador pode alterá-lo';
  end if;
  return new;
end $$;

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
  if new.prazo_em is distinct from old.prazo_em and not public.is_admin() then
    raise exception 'Sem permissão: só um administrador pode alterar o prazo de um item';
  end if;
  return new;
end $$;

notify pgrst, 'reload schema';
