-- Enough of a Supabase project for the migrations to apply against.
-- Nothing here ships; see tests/run.sh.

-- Enough of a Supabase project to apply the migrations against.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema if not exists auth;
create schema if not exists storage;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);

-- Supabase's auth.uid() reads the request JWT claims GUC.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  is_pro boolean not null default false,
  map_filters jsonb,
  legacy_pro boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete cascade,
  stripe_subscription_id text,
  status text not null default 'active',
  plan_name text default 'Pro Access',
  amount integer,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  canceled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);

create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid
);
alter table storage.objects enable row level security;

-- pg_cron itself cannot be installed against a plain Postgres -- run.sh skips
-- the `create extension` line -- but the `cron.schedule` calls beside it are
-- real SQL in the migrations and have to resolve, or the migration that
-- schedules housekeeping aborts halfway through and leaves the functions after
-- it unapplied. Which is what was happening: silently, and swallowed.
create schema if not exists cron;
create or replace function cron.schedule(text, text, text) returns bigint
language sql as $$ select 1::bigint $$;
create or replace function cron.unschedule(text) returns boolean
language sql as $$ select true $$;

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant select on all tables in schema public to anon, authenticated;
