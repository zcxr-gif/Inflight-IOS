-- =============================================================
-- InFlight Virtual Airline Partnership Program
--
-- Run this in the Supabase SQL editor against the project that
-- already hosts auth + profiles for InFlight. Idempotent-ish:
-- uses `if not exists` where possible. Re-running policies is
-- not safe; drop them first if you need to re-run.
-- =============================================================

-- -----------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------

create table if not exists public.va_staff (
    user_id uuid primary key references auth.users(id) on delete cascade,
    granted_at timestamptz not null default now(),
    granted_by uuid references auth.users(id)
);

create table if not exists public.va_applications (
    id uuid primary key default gen_random_uuid(),
    applicant_id uuid not null references auth.users(id) on delete cascade,
    va_name text not null,
    callsign text not null,
    ceo_ifc_handle text not null,
    hub text not null,
    fleet text,
    region text,
    website text,
    discord text,
    logo_url text,
    pitch text,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    reject_reason text,
    reviewed_by uuid references auth.users(id),
    reviewed_at timestamptz,
    created_at timestamptz not null default now()
);

create index if not exists va_applications_status_idx on public.va_applications(status, created_at desc);
create index if not exists va_applications_applicant_idx on public.va_applications(applicant_id);

create table if not exists public.vas (
    id uuid primary key default gen_random_uuid(),
    slug text unique not null,
    name text not null,
    callsign text not null,
    ceo_user_id uuid not null references auth.users(id),
    ceo_ifc_handle text not null,
    hub text,
    fleet text,
    region text,
    website text,
    discord text,
    logo_url text,
    description text,
    trusted boolean not null default false,
    last_event_at timestamptz,
    tombstone boolean not null default false,
    created_at timestamptz not null default now()
);

create index if not exists vas_ceo_idx on public.vas(ceo_user_id);
create index if not exists vas_tombstone_idx on public.vas(tombstone);

create table if not exists public.va_pilots (
    id uuid primary key default gen_random_uuid(),
    va_id uuid not null references public.vas(id) on delete cascade,
    ifc_handle text not null,
    rank text,
    position int not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists va_pilots_va_idx on public.va_pilots(va_id, position);

create table if not exists public.va_events (
    id uuid primary key default gen_random_uuid(),
    va_id uuid not null references public.vas(id) on delete cascade,
    name text not null,
    start_at timestamptz not null,
    end_at timestamptz,
    server text not null check (server in ('casual', 'training', 'expert')),
    origin_icao text,
    destination_icao text,
    route text,
    aircraft text,
    livery text,
    briefing text,
    signup_url text,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    reject_reason text,
    reviewed_by uuid references auth.users(id),
    reviewed_at timestamptz,
    created_at timestamptz not null default now()
);

create index if not exists va_events_status_idx on public.va_events(status, start_at);
create index if not exists va_events_va_idx on public.va_events(va_id, start_at desc);

-- -----------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------

create or replace function public.is_va_staff()
returns boolean
language sql
stable
security definer
as $$
    select exists(select 1 from public.va_staff where user_id = auth.uid());
$$;

-- -----------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------

alter table public.va_staff enable row level security;
alter table public.va_applications enable row level security;
alter table public.vas enable row level security;
alter table public.va_pilots enable row level security;
alter table public.va_events enable row level security;

-- staff
drop policy if exists "staff self read" on public.va_staff;
create policy "staff self read" on public.va_staff for select using (
    auth.uid() = user_id or public.is_va_staff()
);
drop policy if exists "staff manage" on public.va_staff;
create policy "staff manage" on public.va_staff for all using (public.is_va_staff());

-- applications
drop policy if exists "app applicant read" on public.va_applications;
create policy "app applicant read" on public.va_applications for select using (
    auth.uid() = applicant_id or public.is_va_staff()
);
drop policy if exists "app applicant insert" on public.va_applications;
create policy "app applicant insert" on public.va_applications for insert with check (
    auth.uid() = applicant_id
);
drop policy if exists "app staff update" on public.va_applications;
create policy "app staff update" on public.va_applications for update using (public.is_va_staff());
drop policy if exists "app staff delete" on public.va_applications;
create policy "app staff delete" on public.va_applications for delete using (public.is_va_staff());

-- vas (public read, CEO and staff write)
drop policy if exists "vas public read" on public.vas;
create policy "vas public read" on public.vas for select using (true);
drop policy if exists "vas ceo update" on public.vas;
create policy "vas ceo update" on public.vas for update using (
    auth.uid() = ceo_user_id or public.is_va_staff()
);
drop policy if exists "vas staff insert" on public.vas;
create policy "vas staff insert" on public.vas for insert with check (public.is_va_staff());
drop policy if exists "vas staff delete" on public.vas;
create policy "vas staff delete" on public.vas for delete using (public.is_va_staff());

-- pilots (public read, CEO + staff write)
drop policy if exists "pilots public read" on public.va_pilots;
create policy "pilots public read" on public.va_pilots for select using (true);
drop policy if exists "pilots ceo manage" on public.va_pilots;
create policy "pilots ceo manage" on public.va_pilots for all using (
    public.is_va_staff() or exists (
        select 1 from public.vas v where v.id = va_id and v.ceo_user_id = auth.uid()
    )
);

-- events (approved public, all visible to CEO + staff)
drop policy if exists "events public read" on public.va_events;
create policy "events public read" on public.va_events for select using (
    status = 'approved' or public.is_va_staff() or exists (
        select 1 from public.vas v where v.id = va_id and v.ceo_user_id = auth.uid()
    )
);
drop policy if exists "events ceo insert" on public.va_events;
create policy "events ceo insert" on public.va_events for insert with check (
    exists (select 1 from public.vas v where v.id = va_id and v.ceo_user_id = auth.uid() and v.tombstone = false)
);
drop policy if exists "events ceo update" on public.va_events;
create policy "events ceo update" on public.va_events for update using (
    public.is_va_staff() or exists (
        select 1 from public.vas v where v.id = va_id and v.ceo_user_id = auth.uid()
    )
);
drop policy if exists "events ceo delete" on public.va_events;
create policy "events ceo delete" on public.va_events for delete using (
    public.is_va_staff() or exists (
        select 1 from public.vas v where v.id = va_id and v.ceo_user_id = auth.uid()
    )
);

-- -----------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------

-- Auto-approve events for trusted VAs on insert.
create or replace function public.va_event_auto_approve()
returns trigger
language plpgsql
security definer
as $$
declare
    is_trusted boolean;
begin
    select trusted into is_trusted from public.vas where id = new.va_id;
    if is_trusted then
        new.status := 'approved';
        new.reviewed_at := now();
    end if;
    return new;
end;
$$;

drop trigger if exists va_events_auto_approve on public.va_events;
create trigger va_events_auto_approve
before insert on public.va_events
for each row execute function public.va_event_auto_approve();

-- After approval / rejection: bump last_event_at, flip trusted flag.
create or replace function public.va_event_post_review()
returns trigger
language plpgsql
security definer
as $$
declare
    approved_count int;
begin
    if new.status = 'approved' then
        update public.vas set last_event_at = now() where id = new.va_id;

        select count(*) into approved_count
        from public.va_events
        where va_id = new.va_id and status = 'approved';

        if approved_count >= 5 then
            update public.vas set trusted = true where id = new.va_id;
        end if;
    end if;

    if new.status = 'rejected' then
        update public.vas set trusted = false where id = new.va_id;
    end if;

    return new;
end;
$$;

drop trigger if exists va_events_post_review_insert on public.va_events;
create trigger va_events_post_review_insert
after insert on public.va_events
for each row when (new.status in ('approved', 'rejected'))
execute function public.va_event_post_review();

drop trigger if exists va_events_post_review_update on public.va_events;
create trigger va_events_post_review_update
after update of status on public.va_events
for each row when (old.status is distinct from new.status)
execute function public.va_event_post_review();

-- Approve a VA application: creates the VA row, marks the application reviewed.
create or replace function public.va_approve_application(app_id uuid, va_slug text)
returns uuid
language plpgsql
security definer
as $$
declare
    app record;
    new_va_id uuid;
begin
    if not public.is_va_staff() then
        raise exception 'not authorized';
    end if;

    select * into app from public.va_applications where id = app_id;
    if not found then
        raise exception 'application not found';
    end if;
    if app.status <> 'pending' then
        raise exception 'application not pending';
    end if;

    insert into public.vas (
        slug, name, callsign, ceo_user_id, ceo_ifc_handle,
        hub, fleet, region, website, discord, logo_url, description
    ) values (
        va_slug, app.va_name, app.callsign, app.applicant_id, app.ceo_ifc_handle,
        app.hub, app.fleet, app.region, app.website, app.discord, app.logo_url, app.pitch
    )
    returning id into new_va_id;

    update public.va_applications
    set status = 'approved',
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = app_id;

    return new_va_id;
end;
$$;

-- Reject an application with a reason.
create or replace function public.va_reject_application(app_id uuid, reason text)
returns void
language plpgsql
security definer
as $$
begin
    if not public.is_va_staff() then
        raise exception 'not authorized';
    end if;

    update public.va_applications
    set status = 'rejected',
        reject_reason = reason,
        reviewed_by = auth.uid(),
        reviewed_at = now()
    where id = app_id and status = 'pending';
end;
$$;

-- -----------------------------------------------------------------
-- Cleanup (run nightly via pg_cron or a Supabase scheduled function)
-- -----------------------------------------------------------------

create or replace function public.va_cleanup_old_events()
returns int
language plpgsql
security definer
as $$
declare
    n int;
begin
    delete from public.va_events
    where (end_at is not null and end_at < now() - interval '2 months')
       or (end_at is null and start_at < now() - interval '2 months');
    get diagnostics n = row_count;
    return n;
end;
$$;

-- Tombstone (soft-delete) VAs that have not posted an event in 60 days.
create or replace function public.va_cleanup_inactive_vas()
returns int
language plpgsql
security definer
as $$
declare
    n int;
begin
    update public.vas
    set tombstone = true
    where tombstone = false
      and created_at < now() - interval '60 days'
      and (last_event_at is null or last_event_at < now() - interval '60 days');
    get diagnostics n = row_count;
    return n;
end;
$$;

-- -----------------------------------------------------------------
-- Storage bucket for VA logos (run separately in Supabase Storage UI
-- if you prefer, or uncomment when service_role connection is used):
--
--   insert into storage.buckets (id, name, public)
--     values ('va-logos', 'va-logos', true) on conflict do nothing;
--
-- Public read; authenticated upload limited to own user folder.
-- -----------------------------------------------------------------

-- -----------------------------------------------------------------
-- Bootstrap: grant the first staff user.
-- Replace the UUID below with the auth.users.id of the owner
-- (look it up in the Supabase Auth dashboard) and run this once:
--
--   insert into public.va_staff (user_id)
--     values ('00000000-0000-0000-0000-000000000000');
--
-- After that, additional staff can be granted from va-admin.html.
-- -----------------------------------------------------------------
