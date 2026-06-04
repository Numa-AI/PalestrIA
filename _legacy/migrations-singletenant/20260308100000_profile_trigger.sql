-- Trigger: crea automaticamente il profilo quando un utente si registra.
-- Viene eseguito server-side (security definer) → bypassa RLS.
-- I dati nome/whatsapp arrivano da user_metadata passato nel signUp.

create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    insert into public.profiles (id, name, email, whatsapp)
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data->>'full_name',
            new.raw_user_meta_data->>'name',
            split_part(new.email, '@', 1)
        ),
        new.email,
        coalesce(new.raw_user_meta_data->>'whatsapp', '')
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute procedure handle_new_user();
