-- ScholarTrack MVP: Supabase PostgreSQL schema
-- Run this entire file once in Supabase Dashboard > SQL Editor.
-- It creates database records only. Create Auth users separately in
-- Authentication > Users (or through your app); never insert passwords here.

create extension if not exists pgcrypto;

create type public.app_role as enum ('scholar', 'staff');
create type public.verification_state as enum ('Pending', 'Verified', 'Returned');
create type public.compliance_state as enum ('Not evaluated', 'Compliant', 'With Deficiency');
create type public.renewal_state as enum ('Not decided', 'Approved', 'Held');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  student_id text unique,
  full_name text not null,
  role public.app_role not null default 'scholar',
  created_at timestamptz not null default now(),
  constraint scholar_requires_student_id check (role = 'staff' or student_id is not null)
);

create table public.programs (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  max_gwa numeric(3,2) not null check (max_gwa between 1.00 and 5.00),
  min_units integer not null check (min_units >= 0),
  max_failed integer not null check (max_failed >= 0),
  max_incomplete integer not null check (max_incomplete >= 0),
  max_dropped integer not null check (max_dropped >= 0),
  deadline timestamptz not null,
  created_at timestamptz not null default now()
);

create table public.scholar_assignments (
  id uuid primary key default gen_random_uuid(),
  scholar_id uuid unique not null references public.profiles(id) on delete cascade,
  program_id uuid not null references public.programs(id) on delete restrict,
  assigned_by uuid references public.profiles(id),
  assigned_at timestamptz not null default now()
);

create table public.submissions (
  id uuid primary key default gen_random_uuid(),
  scholar_id uuid not null references public.profiles(id) on delete cascade,
  -- Filled from the current assignment by trigger, to preserve policy selection.
  program_id uuid references public.programs(id) on delete restrict,
  academic_year text not null check (academic_year ~ '^20[0-9]{2}-20[0-9]{2}$'),
  semester text not null check (semester in ('1', '2', 'Summer')),
  gwa numeric(3,2) not null check (gwa between 1.00 and 5.00),
  enrolled_units integer not null check (enrolled_units >= 0),
  failed_count integer not null check (failed_count >= 0),
  incomplete_count integer not null check (incomplete_count >= 0),
  dropped_count integer not null check (dropped_count >= 0),
  evidence_reference text not null check (length(trim(evidence_reference)) > 0),
  submitted_at timestamptz not null default now(),
  verification_status public.verification_state not null default 'Pending',
  verification_reason text,
  compliance_result public.compliance_state not null default 'Not evaluated',
  compliance_reasons jsonb not null default '[]'::jsonb,
  renewal_decision public.renewal_state not null default 'Not decided',
  decision_notes text,
  unique (scholar_id, academic_year, semester),
  constraint return_needs_reason check (verification_status <> 'Returned' or length(trim(coalesce(verification_reason,''))) > 0),
  constraint approved_must_be_compliant check (renewal_decision <> 'Approved' or compliance_result = 'Compliant')
);

create table public.submission_history (
  id bigint generated always as identity primary key,
  submission_id uuid not null references public.submissions(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_name text not null,
  event_type text not null,
  details text,
  created_at timestamptz not null default now()
);

create index submissions_scholar_idx on public.submissions(scholar_id);
create index submissions_status_idx on public.submissions(verification_status, compliance_result);
create index history_submission_idx on public.submission_history(submission_id, created_at desc);

-- SECURITY DEFINER avoids recursion while checking staff privileges in policies.
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'staff');
$$;

create or replace function public.assigned_program_for(p_scholar uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select program_id from public.scholar_assignments where scholar_id = p_scholar;
$$;

-- Scholars cannot choose a different policy by submitting a program_id.
create or replace function public.set_submission_program()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.program_id := public.assigned_program_for(new.scholar_id);
  if new.program_id is null then
    raise exception 'Scholar has no program assignment';
  end if;
  return new;
end;
$$;
create trigger submission_program_before_write
before insert on public.submissions
for each row execute function public.set_submission_program();

-- Returned records may be corrected only by the owning scholar. A correction
-- always returns to Pending and clears prior evaluation/decision state.
create or replace function public.guard_scholar_correction()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() = old.scholar_id and not public.is_staff() then
    if old.verification_status <> 'Returned' then
      raise exception 'Only returned submissions may be corrected';
    end if;
    new.scholar_id := old.scholar_id;
    new.program_id := old.program_id;
    new.academic_year := old.academic_year;
    new.semester := old.semester;
    new.verification_status := 'Pending';
    new.verification_reason := null;
    new.compliance_result := 'Not evaluated';
    new.compliance_reasons := '[]'::jsonb;
    new.renewal_decision := 'Not decided';
    new.decision_notes := null;
    new.submitted_at := now();
  end if;
  return new;
end;
$$;
create trigger guard_scholar_correction_before_update
before update on public.submissions
for each row execute function public.guard_scholar_correction();

-- Append immutable audit entries for submissions and staff decisions.
create or replace function public.log_submission_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor text;
begin
  select coalesce(full_name, 'System') into actor from public.profiles where id = auth.uid();
  if tg_op = 'INSERT' then
    insert into public.submission_history(submission_id, actor_id, actor_name, event_type, details)
    values (new.id, auth.uid(), coalesce(actor,'System'), 'Submitted', 'Academic summary submitted');
  elsif new.verification_status is distinct from old.verification_status then
    insert into public.submission_history(submission_id, actor_id, actor_name, event_type, details)
    values (new.id, auth.uid(), coalesce(actor,'System'), 'Evidence ' || new.verification_status, new.verification_reason);
  elsif new.compliance_result is distinct from old.compliance_result then
    insert into public.submission_history(submission_id, actor_id, actor_name, event_type, details)
    values (new.id, auth.uid(), coalesce(actor,'System'), 'Evaluated: ' || new.compliance_result, array_to_string(array(select jsonb_array_elements_text(new.compliance_reasons)), '; '));
  elsif new.renewal_decision is distinct from old.renewal_decision then
    insert into public.submission_history(submission_id, actor_id, actor_name, event_type, details)
    values (new.id, auth.uid(), coalesce(actor,'System'), 'Renewal ' || new.renewal_decision, new.decision_notes);
  end if;
  return new;
end;
$$;
create trigger submission_history_after_write
after insert or update on public.submissions
for each row execute function public.log_submission_change();

alter table public.profiles enable row level security;
alter table public.programs enable row level security;
alter table public.scholar_assignments enable row level security;
alter table public.submissions enable row level security;
alter table public.submission_history enable row level security;

-- Profiles: users read themselves; staff manage profiles/assignments.
create policy "read own profile or staff" on public.profiles for select to authenticated using (id = auth.uid() or public.is_staff());
create policy "staff creates profiles" on public.profiles for insert to authenticated with check (public.is_staff());
create policy "staff updates profiles" on public.profiles for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "staff reads programs" on public.programs for select to authenticated using (true);
create policy "staff manages programs" on public.programs for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "read own assignment or staff" on public.scholar_assignments for select to authenticated using (scholar_id = auth.uid() or public.is_staff());
create policy "staff manages assignments" on public.scholar_assignments for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "read own submissions or staff" on public.submissions for select to authenticated using (scholar_id = auth.uid() or public.is_staff());
create policy "scholar creates own submission" on public.submissions for insert to authenticated with check (scholar_id = auth.uid() and not public.is_staff());
create policy "scholar corrects own returned submission or staff updates" on public.submissions for update to authenticated using (scholar_id = auth.uid() or public.is_staff()) with check (scholar_id = auth.uid() or public.is_staff());
create policy "read own history or staff" on public.submission_history for select to authenticated using (public.is_staff() or exists (select 1 from public.submissions s where s.id = submission_id and s.scholar_id = auth.uid()));

-- No history INSERT/UPDATE/DELETE policy: only the database audit trigger writes it.

insert into public.programs (name, max_gwa, min_units, max_failed, max_incomplete, max_dropped, deadline)
values
  ('Merit Scholar', 1.75, 18, 0, 0, 0, '2026-10-30 17:00:00 Asia/Manila'),
  ('Community Scholar', 2.25, 15, 0, 0, 1, '2026-10-30 17:00:00 Asia/Manila')
on conflict (name) do nothing;

-- After creating each Auth user, create their linked profile and assignment.
-- Example (replace the UUID with Authentication > Users > user ID):
-- insert into public.profiles (id, student_id, full_name, role)
-- values ('AUTH-USER-UUID', 'A01', 'Ariana Cruz', 'scholar');
-- insert into public.scholar_assignments (scholar_id, program_id, assigned_by)
-- select 'AUTH-USER-UUID', id, 'STAFF-AUTH-USER-UUID' from public.programs where name = 'Merit Scholar';

-- Synthetic test values after linked profiles/assignments exist. Use the IDs from
-- your profiles table. The current logged-in scholar can insert their own row;
-- a staff account should run these through a secure server/Edge Function.
-- A01 Merit: 1.75 / 18 / 0 / 0 / 0 / deadline
-- A02 Merit: 1.76 / 18 / 0 / 0 / 0 / one day before deadline
-- A03 Community: 2.25 / 15 / 0 / 0 / 1 / one day before deadline
-- A04 Community: 2.25 / 14 / 0 / 1 / 0 / one day before deadline
-- A05 Merit: 1.50 / 18 / 1 / 0 / 0 / one minute late
-- A06 Community: 2.00 / 15 / 0 / 0 / 0 / Pending verification

-- Optional seed: run this block AFTER you have created/auth-linked A01–A06 and
-- their assignments. It is safe to run again because of ON CONFLICT.
-- insert into public.submissions
--   (scholar_id, academic_year, semester, gwa, enrolled_units, failed_count,
--    incomplete_count, dropped_count, evidence_reference, submitted_at, verification_status)
-- select p.id, '2026-2027', '1', v.gwa, v.units, v.failed, v.inc, v.dropped,
--        'GRADE-' || v.student_id || '-2026.pdf', v.submitted_at, v.verification
-- from (values
--   ('A01', 1.75::numeric, 18, 0, 0, 0, '2026-10-30 17:00:00 Asia/Manila'::timestamptz, 'Verified'::public.verification_state),
--   ('A02', 1.76::numeric, 18, 0, 0, 0, '2026-10-29 17:00:00 Asia/Manila'::timestamptz, 'Verified'::public.verification_state),
--   ('A03', 2.25::numeric, 15, 0, 0, 1, '2026-10-29 17:00:00 Asia/Manila'::timestamptz, 'Verified'::public.verification_state),
--   ('A04', 2.25::numeric, 14, 0, 1, 0, '2026-10-29 17:00:00 Asia/Manila'::timestamptz, 'Verified'::public.verification_state),
--   ('A05', 1.50::numeric, 18, 1, 0, 0, '2026-10-30 17:01:00 Asia/Manila'::timestamptz, 'Verified'::public.verification_state),
--   ('A06', 2.00::numeric, 15, 0, 0, 0, '2026-10-29 17:00:00 Asia/Manila'::timestamptz, 'Pending'::public.verification_state)
-- ) as v(student_id, gwa, units, failed, inc, dropped, submitted_at, verification)
-- join public.profiles p on p.student_id = v.student_id
-- on conflict (scholar_id, academic_year, semester) do nothing;
