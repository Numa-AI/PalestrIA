-- Enforce complete anagrafica for email/password signups.
-- OAuth users can still be created incomplete; the frontend blocks them behind
-- the "Completa profilo" modal before entering the app.

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_provider          text := coalesce(new.raw_app_meta_data->>'provider', 'email');
    v_is_email_signup   boolean := coalesce(new.raw_app_meta_data->>'provider', 'email') = 'email';
    v_name              text := coalesce(
        nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
        nullif(trim(new.raw_user_meta_data->>'name'), ''),
        split_part(new.email, '@', 1)
    );
    v_email             text := lower(trim(new.email));
    v_whatsapp          text := nullif(trim(coalesce(new.raw_user_meta_data->>'whatsapp', '')), '');
    v_codice_fiscale    text := upper(nullif(trim(coalesce(new.raw_user_meta_data->>'codice_fiscale', '')), ''));
    v_indirizzo_via     text := nullif(trim(coalesce(new.raw_user_meta_data->>'indirizzo_via', '')), '');
    v_indirizzo_paese   text := nullif(trim(coalesce(new.raw_user_meta_data->>'indirizzo_paese', '')), '');
    v_indirizzo_cap     text := nullif(trim(coalesce(new.raw_user_meta_data->>'indirizzo_cap', '')), '');
    v_taken             boolean := false;
begin
    if v_is_email_signup then
        if v_whatsapp is null
            or v_codice_fiscale is null
            or v_indirizzo_via is null
            or v_indirizzo_paese is null
            or v_indirizzo_cap is null then
            raise exception 'Registrazione non valida: anagrafica obbligatoria incompleta'
                using errcode = '23514';
        end if;

        if v_whatsapp !~ '^\+\d{10,15}$' then
            raise exception 'Registrazione non valida: numero WhatsApp non valido'
                using errcode = '23514';
        end if;

        if v_codice_fiscale !~ '^[A-Z]{6}[0-9]{2}[A-Z][0-9]{2}[A-Z][0-9]{3}[A-Z]$' then
            raise exception 'Registrazione non valida: codice fiscale non valido'
                using errcode = '23514';
        end if;

        if v_indirizzo_cap !~ '^[0-9]{5}$' then
            raise exception 'Registrazione non valida: CAP non valido'
                using errcode = '23514';
        end if;
    end if;

    if v_whatsapp is not null then
        select exists(
            select 1
            from profiles
            where whatsapp = v_whatsapp
              and id <> new.id
        ) into v_taken;

        if v_taken then
            if v_is_email_signup then
                raise exception 'Registrazione non valida: numero WhatsApp gia associato a un altro account'
                    using errcode = '23505';
            end if;
            v_whatsapp := '';
        end if;
    end if;

    insert into profiles (
        id,
        name,
        email,
        whatsapp,
        codice_fiscale,
        indirizzo_via,
        indirizzo_paese,
        indirizzo_cap
    )
    values (
        new.id,
        v_name,
        v_email,
        coalesce(v_whatsapp, ''),
        v_codice_fiscale,
        v_indirizzo_via,
        v_indirizzo_paese,
        v_indirizzo_cap
    )
    on conflict (id) do update set
        name = excluded.name,
        email = excluded.email,
        whatsapp = case
            when excluded.whatsapp <> '' then excluded.whatsapp
            else profiles.whatsapp
        end,
        codice_fiscale = coalesce(excluded.codice_fiscale, profiles.codice_fiscale),
        indirizzo_via = coalesce(excluded.indirizzo_via, profiles.indirizzo_via),
        indirizzo_paese = coalesce(excluded.indirizzo_paese, profiles.indirizzo_paese),
        indirizzo_cap = coalesce(excluded.indirizzo_cap, profiles.indirizzo_cap);

    return new;
exception
    when unique_violation then
        if v_is_email_signup then
            raise;
        end if;
        raise log 'handle_new_user unique_violation for provider %, email %: %', v_provider, new.email, sqlerrm;
        return new;
    when others then
        if v_is_email_signup then
            raise;
        end if;
        raise warning 'handle_new_user failed for provider %, email %: % (state %)', v_provider, new.email, sqlerrm, sqlstate;
        return new;
end;
$$;
