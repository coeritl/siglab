alter table public.labs
  add column if not exists computer_count integer not null default 0;

alter table public.labs
  drop constraint if exists labs_computer_count_check;

alter table public.labs
  add constraint labs_computer_count_check check (computer_count >= 0);
