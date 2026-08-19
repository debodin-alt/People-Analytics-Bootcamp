-- Source data carries a fifth outcome not anticipated in the original
-- check: 'Filled (Internal Transfer)' — a real, distinct fill type
-- (internal move rather than an external hire), verified against
-- Reqs Master in meridian_recruiting_funnel.xlsx.

alter table public.requisitions drop constraint requisitions_outcome_check;
alter table public.requisitions add constraint requisitions_outcome_check
  check (outcome in ('Filled', 'Filled (Internal Transfer)', 'Open', 'On Hold', 'Cancelled'));
