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
