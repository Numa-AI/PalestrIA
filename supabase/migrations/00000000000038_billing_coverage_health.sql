-- Enrich the financial summary with model-specific, actually usable coverage.

alter function get_client_financial_summary(uuid)
  rename to get_client_financial_summary_base;
revoke all on function get_client_financial_summary_base(uuid) from public,anon,authenticated;

create function get_client_financial_summary(p_user_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id();
  v_summary jsonb;
  v_model text;
  v_membership_active boolean;
  v_missing boolean;
begin
  v_summary:=get_client_financial_summary_base(p_user_id);
  v_model:=coalesce(v_summary#>>'{billing_profile,model}','pay_per_session');

  select exists(
    select 1 from client_memberships m
    where m.org_id=v_org and m.user_id=p_user_id and m.status='active'
      and m.period_start<=current_date
      and m.period_end>=current_date-make_interval(days=>coalesce(
        (select grace_days from billing_settings where org_id=v_org),0))
      and (m.lessons_quota is null or m.lessons_used<m.lessons_quota)
  ) into v_membership_active;

  v_summary:=jsonb_set(
    v_summary,
    '{health,active_membership}',
    to_jsonb(v_membership_active),
    true
  );
  v_missing:=case
    when v_model='package' then not coalesce(
      (v_summary#>>'{health,active_package}')::boolean,false)
    when v_model='monthly' then not v_membership_active
    else false
  end;
  return jsonb_set(
    v_summary,
    '{health,billing_coverage_missing}',
    to_jsonb(v_missing),
    true
  );
end;
$$;
revoke all on function get_client_financial_summary(uuid) from public,anon;
grant execute on function get_client_financial_summary(uuid) to authenticated;