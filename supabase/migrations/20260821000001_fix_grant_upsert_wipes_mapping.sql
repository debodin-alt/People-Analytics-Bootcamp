-- Fix: re-granting a role silently wiped the employee mapping.
--
-- grant_app_access upserts with
--     on conflict do update set employee_id = excluded.employee_id
-- so calling it without the optional arguments — say
--     grant_app_access('someone@example.com', 'executive')
-- to change only a role — wrote the parameter DEFAULT (null) over an
-- existing employee_id and notes. Nothing failed and nothing warned.
--
-- Reproduced end to end:
--   grant(email, 'admin', 'E10001', 'Platform owner')  -> E10001 / notes ok
--   grant(email, 'manager', 'E10022', 'reassigned')    -> E10022 / notes ok
--   grant(email, 'executive')                          -> NULL / NULL   <-- wipe
--
-- Worst case is a manager: with employee_id null, visible_employee_ids()
-- returns an empty set, so they see nothing at all. That presents as a
-- broken application rather than as a misconfigured grant, which is the
-- expensive kind of failure to diagnose. The original function tried to
-- prevent exactly this by requiring employee_id for manager and viewer —
-- but only on the argument, so the upsert path walked around the intent.
--
-- Correct semantics for a grant helper: an omitted optional argument
-- means LEAVE UNCHANGED, not "set to null". Clearing is now explicit,
-- via revoke_app_access or a deliberate update.

create or replace function public.grant_app_access(
  p_email text,
  p_app_role text,
  p_employee_id text default null,
  p_notes text default null
) returns text
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_existing_employee_id text;
  v_existing_notes text;
  v_effective_employee_id text;
  v_effective_notes text;
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

  select employee_id, notes into v_existing_employee_id, v_existing_notes
  from public.app_users where auth_user_id = v_uid;

  -- Omitted means unchanged.
  v_effective_employee_id := coalesce(p_employee_id, v_existing_employee_id);
  v_effective_notes       := coalesce(p_notes, v_existing_notes);

  -- Validate the EFFECTIVE value, not the argument: re-granting an
  -- existing manager a new role without restating their employee_id is
  -- legitimate and must not be rejected, while creating a manager with no
  -- mapping anywhere must still fail loudly.
  if p_app_role in ('manager', 'viewer') and v_effective_employee_id is null then
    raise exception 'Role % requires an employee_id to scope against', p_app_role
      using hint = 'Pass p_employee_id — without it this user would resolve to an empty reporting tree and see nothing.';
  end if;

  if v_effective_employee_id is not null
     and not exists (select 1 from public.employees where employee_id = v_effective_employee_id) then
    raise exception 'No employee with id %', v_effective_employee_id;
  end if;

  insert into public.app_users (auth_user_id, employee_id, app_role, notes)
  values (v_uid, v_effective_employee_id, p_app_role, v_effective_notes)
  on conflict (auth_user_id) do update
    set employee_id = v_effective_employee_id,
        app_role    = p_app_role,
        notes       = v_effective_notes,
        is_active   = true;

  return format('%s -> role=%s employee=%s', p_email, p_app_role,
                coalesce(v_effective_employee_id, '(none)'));
end;
$$;

revoke all on function public.grant_app_access(text, text, text, text) from public, anon, authenticated;

comment on function public.grant_app_access(text, text, text, text) is
  'Assigns an application role to an existing auth user. Omitted optional arguments leave the existing value unchanged rather than nulling it. Privileged connections only — never granted to anon or authenticated, because a browser-callable privilege grant is a privilege escalation.';
