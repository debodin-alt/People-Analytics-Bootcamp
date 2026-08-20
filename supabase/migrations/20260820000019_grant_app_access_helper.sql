-- Administrative helper for assigning roles.
--
-- Deliberately NOT granted to anon or authenticated. It is callable only
-- by a privileged connection (the SQL editor, or the service role), which
-- is the correct shape for a privilege-granting operation: a user who
-- could call this from the browser could make themselves an admin.
--
-- Role assignment stays a deliberate administrative act, performed
-- against the database, with no self-service path.

create function public.grant_app_access(
  p_email text,
  p_app_role text,
  p_employee_id text default null,
  p_notes text default null
) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare v_uid uuid;
begin
  if p_app_role not in ('admin', 'executive', 'manager', 'viewer') then
    raise exception 'Invalid role: %', p_app_role
      using hint = 'One of: admin, executive, manager, viewer';
  end if;

  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is null then
    raise exception 'No auth user with email %', p_email
      using hint = 'Create the account first (Supabase Dashboard > Authentication > Users), then re-run.';
  end if;

  -- A manager whose employee_id is unset would resolve to an empty
  -- reporting tree and silently see nothing, which reads as a broken app
  -- rather than a misconfiguration. Fail loudly instead.
  if p_app_role in ('manager', 'viewer') and p_employee_id is null then
    raise exception 'Role % requires an employee_id to scope against', p_app_role;
  end if;

  if p_employee_id is not null
     and not exists (select 1 from public.employees where employee_id = p_employee_id) then
    raise exception 'No employee with id %', p_employee_id;
  end if;

  insert into public.app_users (auth_user_id, employee_id, app_role, notes)
  values (v_uid, p_employee_id, p_app_role, p_notes)
  on conflict (auth_user_id) do update
    set employee_id = excluded.employee_id,
        app_role    = excluded.app_role,
        notes       = excluded.notes,
        is_active   = true;

  return format('%s -> role=%s employee=%s', p_email, p_app_role, coalesce(p_employee_id, '(none)'));
end;
$$;

revoke all on function public.grant_app_access(text, text, text, text) from public, anon, authenticated;

comment on function public.grant_app_access(text, text, text, text) is
  'Assigns an application role to an existing auth user. Privileged connections only — never granted to anon or authenticated, because a browser-callable privilege grant is a privilege escalation.';

create function public.revoke_app_access(p_email text)
returns text language plpgsql volatile security definer set search_path = ''
as $$
declare v_uid uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is null then
    raise exception 'No auth user with email %', p_email;
  end if;
  update public.app_users set is_active = false where auth_user_id = v_uid;
  return format('%s -> access revoked', p_email);
end;
$$;

revoke all on function public.revoke_app_access(text) from public, anon, authenticated;

comment on function public.revoke_app_access(text) is
  'Deactivates a user''s access without deleting the mapping, so the assignment history survives the revocation.';
