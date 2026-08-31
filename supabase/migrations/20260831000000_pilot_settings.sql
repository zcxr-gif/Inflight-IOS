-- Everything the app knows about you that is not a flight: one row, one blob,
-- one account.
--
-- The tracker was built to work signed out, and it still does. Every
-- preference in it therefore lives in `UserDefaults` -- the watchlist, the
-- colours you paint your friends, which map you like, which units you read
-- weather in -- and that was the right default for an app with no accounts.
-- It stopped being right the moment there were accounts, because it means a
-- new phone is a new start: `FriendsStore`'s own header admits it, in as many
-- words, and so does `AccountStore.deleteAccount`.
--
-- This is where it goes instead, for anyone signed in. Signed out, nothing
-- changes and nothing here is touched.
--
-- WHY ONE BLOB RATHER THAN COLUMNS. Because none of it is queried. The server
-- never reads inside this JSON, never sorts by it, never joins on it and never
-- makes a decision from it -- the whole contract is "give the app back exactly
-- what it last handed you". A column per preference would be forty columns of
-- write-only storage plus a migration every time somebody adds a switch, and
-- the check constraints would be a second copy of validation the client has
-- already done. What actually matters -- that it belongs to one account, that
-- it cannot grow without bound, and that nobody else can read it -- is all
-- below and none of it needs the shape.
--
-- WHY NOT `user_preferences`. That table exists and the website writes it. It
-- holds a handful of named columns -- `notification_watchlist_enabled` among
-- them, which push.cjs reads on every alert -- and it is a table with server
-- side readers. Folding an opaque client blob into it would put something
-- nobody may interpret next to columns the backend interprets on every push,
-- and the first person to confuse the two would break notifications. Left
-- exactly as the website expects to find it.
--
-- WHAT IS NOT IN HERE. Anything about the *device* rather than the person: the
-- APNs token, which is what a push is addressed to; the widget's pinned
-- flight, which is a choice about one home screen; and the terms acceptance,
-- which already has `record_terms_acceptance` and is a legal record rather
-- than a preference. Those stay where they are, deliberately.

create table if not exists public.pilot_settings (

  -- One row per account, so the primary key is the account. No surrogate id:
  -- there is nothing to have two of, and a unique index on user_id plus a
  -- separate key would be the same constraint written twice.
  user_id uuid primary key references auth.users (id) on delete cascade,

  -- The app's own snapshot. An object, always -- a bare array or a string
  -- would decode into something the client cannot merge, and it is cheaper to
  -- refuse it here than to defend against it in four places on the way out.
  settings jsonb not null default '{}'::jsonb
    check (jsonb_typeof(settings) = 'object'),

  -- Which shape the writer used. Not read by anything today; it is here so a
  -- future build that changes the meaning of a key can tell a blob it wrote
  -- from one an older build did, without having to guess from the contents.
  revision integer not null default 1 check (revision between 1 and 1000),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- A ceiling, because this is a client-writable JSON column on a public API and
-- "how big may it get" is a question somebody has to answer. 64 KB is roughly
-- fifty times what a full snapshot measures -- a watchlist of two hundred
-- names with a colour each is a few kilobytes -- so nobody flying will meet
-- it, and a client looping on a growing key will.
--
-- Its own constraint rather than a clause on the column so the error names the
-- actual problem: a violation here reads as `pilot_settings_within_size`
-- rather than as a failed check on `settings`, which would be indis-
-- tinguishable from the type check above.
alter table public.pilot_settings
  drop constraint if exists pilot_settings_within_size;
alter table public.pilot_settings
  add constraint pilot_settings_within_size
  check (octet_length(settings::text) <= 65536);

comment on table public.pilot_settings is
  'One row per account holding the app''s own preference snapshot as an opaque blob: the watchlist, notification switches, traffic colours, and the appearance, map, weather and instrument settings. Written and read only by the owning client; the server never interprets it.';

-- MARK: - Keeping the row honest
--
-- The same three jobs as every other table here, and for the same reasons.
-- `user_id` is defaulted from the caller's token so the app never sends it and
-- forced to the caller so it cannot send somebody else's; a row never changes
-- hands, which would otherwise be a way to write into another account's
-- settings by updating one of your own into it; and `updated_at` is the
-- server's clock, because it is what the client compares against to decide
-- whether the account knows something this device does not.
create or replace function public.pilot_settings_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.user_id := coalesce(auth.uid(), new.user_id);
    new.created_at := now();
  else
    new.user_id := old.user_id;
    new.created_at := old.created_at;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists pilot_settings_guard on public.pilot_settings;
create trigger pilot_settings_guard
  before insert or update on public.pilot_settings
  for each row execute function public.pilot_settings_guard();

-- A trigger, not an endpoint. `create function` grants EXECUTE to PUBLIC
-- unless told otherwise, which would publish this at
-- `/rest/v1/rpc/pilot_settings_guard` -- see
-- `20260818000800_tighten_function_grants.sql`, the migration that exists
-- because this default was missed once already.
revoke all on function public.pilot_settings_guard() from public;
revoke all on function public.pilot_settings_guard() from anon;
revoke all on function public.pilot_settings_guard() from authenticated;

-- MARK: - Who may read one
--
-- Its owner, and nobody else, ever. This is the most personal row in the
-- schema: it names every pilot somebody watches, which is a social graph, and
-- there is no reader for it but the app that wrote it. Unlike a profile or a
-- logbook there is no future version of this that becomes public, so there is
-- no visibility setting to leave room for.
alter table public.pilot_settings enable row level security;

drop policy if exists "Pilots read their own settings" on public.pilot_settings;
create policy "Pilots read their own settings"
  on public.pilot_settings for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Pilots write their own settings" on public.pilot_settings;
create policy "Pilots write their own settings"
  on public.pilot_settings for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Pilots update their own settings" on public.pilot_settings;
create policy "Pilots update their own settings"
  on public.pilot_settings for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Pilots delete their own settings" on public.pilot_settings;
create policy "Pilots delete their own settings"
  on public.pilot_settings for delete
  to authenticated
  using (auth.uid() = user_id);

grant select, insert, update, delete on public.pilot_settings to authenticated;

-- Never to `anon`. A signed-out caller has no settings row and no business
-- holding anybody else's.
revoke all on public.pilot_settings from anon;
