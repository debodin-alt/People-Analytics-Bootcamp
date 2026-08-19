-- employees self-references via manager_employee_id and referrer_employee_id.
-- The source workbook does not guarantee a manager's row precedes their
-- reports', so these two FKs are deferred to transaction commit — lets a
-- bulk load insert all 920 rows in one transaction regardless of order,
-- while still enforcing referential integrity by the time the load ends.

alter table public.employees
  drop constraint employees_manager_employee_id_fkey,
  add constraint employees_manager_employee_id_fkey
    foreign key (manager_employee_id) references public.employees (employee_id)
    deferrable initially deferred;

alter table public.employees
  drop constraint employees_referrer_employee_id_fkey,
  add constraint employees_referrer_employee_id_fkey
    foreign key (referrer_employee_id) references public.employees (employee_id)
    deferrable initially deferred;
