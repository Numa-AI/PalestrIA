-- ══════════════════════════════════════════════════════════════════════════════
-- Fix: create_organization falliva con "could not determine polymorphic type
-- because input has type unknown" perché to_jsonb() riceveva stringhe letterali
-- non tipizzate (unknown). Cast esplicito a ::text.
-- ══════════════════════════════════════════════════════════════════════════════

create or replace function create_organization(p_name text, p_slug text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_slug text := lower(trim(p_slug));
begin
    if auth.uid() is null then raise exception 'not_authenticated'; end if;
    if v_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then raise exception 'invalid_slug'; end if;
    if exists (select 1 from organizations where slug = v_slug) then raise exception 'slug_taken'; end if;

    insert into organizations (name, slug, owner_user_id, status)
        values (trim(p_name), v_slug, auth.uid(), 'trialing') returning id into v_org;
    insert into org_members (org_id, user_id, role) values (v_org, auth.uid(), 'owner');

    insert into billing_settings (org_id) values (v_org);

    insert into subscriptions (org_id, plan_id, status, trial_end)
        values (v_org, (select id from plans where code = 'starter' limit 1),
                'trialing', now() + interval '30 days');

    insert into slot_types (org_id, key, label, color, default_capacity, default_price, sort_order) values
        (v_org, 'personal-training', 'Personal Training', '#8B5CF6', 1, 0, 0),
        (v_org, 'small-group',       'Small Group',        '#22C55E', 5, 0, 1),
        (v_org, 'group-class',       'Group Class',        '#F59E0B', 12, 0, 2);

    insert into org_settings (org_id, key, value) values
        (v_org, 'branding.studio_name', to_jsonb(trim(p_name))),
        (v_org, 'branding.primary_color', to_jsonb('#8B5CF6'::text)),
        (v_org, 'locale.timezone', to_jsonb('Europe/Rome'::text)),
        (v_org, 'locale.currency', to_jsonb('EUR'::text)),
        (v_org, 'booking.policy.free_cancel_hours', to_jsonb(24)),
        (v_org, 'booking.policy.penalty_pct', to_jsonb(50))
    on conflict do nothing;

    return v_org;
end;
$$;
revoke all on function create_organization from public;
grant execute on function create_organization to authenticated;
