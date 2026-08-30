-- Planned flights: which stand you are pushing back from, which one you mean
-- to shut down on, and when.
--
-- The tracker already knows two thirds of a flight. `pilot_live_status` is
-- what is happening right now, `pilot_logbook` is what happened -- both of them
-- observed, neither of them typed. What has never had a home is the part that
-- comes first: the intention. Somebody picks a stand at Heathrow, works out
-- what time they want to be off, and picks a stand at the other end, and until
-- now the only place to write that down was a piece of paper beside the iPad.
--
-- WHY NOT `public.user_flights`. That table exists, it has `dep_gate` and
-- `arr_gate` on it, and it is the wrong shape for this. It is the website's
-- hand-filed PIREP -- a record of a flight already made, keyed on a bigint the
-- client picks, with fuel and passenger counts on it -- and its rows are
-- written by a dashboard this app does not talk to. Folding a forward-looking
-- plan into a backward-looking report would mean one table where half the rows
-- are claims about the past and half are intentions about the future, with no
-- column that says which. So: a table of its own, and `user_flights` is left
-- exactly as the website expects to find it.
--
-- WHAT A FREE ACCOUNT GETS. All of it. The gates, the times, the aircraft, as
-- many plans as anybody sensibly keeps. Nothing on this table is gated, and
-- deliberately: what Inflight Pro sells here is the *airport map* -- opening a
-- field, seeing every mapped stand on the satellite image, and tapping the one
-- you want -- and a free account reaches the identical row by typing `B24`
-- into a text field. That distinction is honest only if the server treats the
-- two writes as the same write, which it does. There is no Pro check in this
-- file because there is nothing here for one to protect: a modified client
-- that skipped the paywall would gain the ability to type a gate name, which
-- it already has.

create table if not exists public.pilot_flight_plans (

  id uuid primary key default gen_random_uuid(),

  user_id uuid not null references auth.users (id) on delete cascade,

  -- Both ends are required. A plan with no destination is a wish, and the
  -- whole value of the row is the pair.
  origin_icao text not null check (origin_icao ~ '^[A-Z0-9]{3,4}$'),
  destination_icao text not null check (destination_icao ~ '^[A-Z0-9]{3,4}$'),

  -- The stand's own name, as the field paints it: `B24`, `501`, `Cargo 3`.
  -- Free text on purpose. It comes from OpenStreetMap when it was tapped on
  -- the map and from a keyboard when it was not, and neither source is a
  -- controlled vocabulary -- a field can and does rename a pier between
  -- surveys, and refusing a stand because nobody has mapped it yet would make
  -- the feature useless at exactly the airports that need it most.
  departure_gate text check (departure_gate is null
                             or char_length(departure_gate) between 1 and 12),
  arrival_gate text check (arrival_gate is null
                           or char_length(arrival_gate) between 1 and 12),

  -- Where that stand is, when the app knew. Stored alongside the name rather
  -- than looked up again, because the name is the only durable part: a stand
  -- picked today should still draw on the map next month even if OpenStreetMap
  -- has since moved, renamed or lost the node it came from.
  --
  -- Null is ordinary -- it means the gate was typed rather than tapped -- so
  -- these are never required. What is required is that a coordinate is whole:
  -- a latitude with no longitude is a point nobody can draw.
  departure_gate_latitude double precision
    check (departure_gate_latitude is null
           or departure_gate_latitude between -90 and 90),
  departure_gate_longitude double precision
    check (departure_gate_longitude is null
           or departure_gate_longitude between -180 and 180),
  arrival_gate_latitude double precision
    check (arrival_gate_latitude is null
           or arrival_gate_latitude between -90 and 90),
  arrival_gate_longitude double precision
    check (arrival_gate_longitude is null
           or arrival_gate_longitude between -180 and 180),

  constraint pilot_flight_plans_departure_point_whole
    check ((departure_gate_latitude is null) = (departure_gate_longitude is null)),
  constraint pilot_flight_plans_arrival_point_whole
    check ((arrival_gate_latitude is null) = (arrival_gate_longitude is null)),

  -- Off blocks and on blocks, the way an airline timetable means them.
  -- Both optional: plenty of people plan a route days before they decide what
  -- evening they are flying it.
  scheduled_out timestamptz,
  scheduled_in timestamptz,

  -- Not `scheduled_in > scheduled_out` on the nose: a flight that lands the
  -- same minute it leaves is nonsense, and one that lands *before* it leaves
  -- is a typo worth refusing. Equal is allowed through as "not filled in
  -- properly yet" rather than made into an error somebody has to decode.
  constraint pilot_flight_plans_arrives_after_departing
    check (scheduled_in is null
           or scheduled_out is null
           or scheduled_in >= scheduled_out),

  callsign text check (callsign is null or char_length(callsign) between 1 and 24),
  aircraft text check (aircraft is null or char_length(aircraft) between 1 and 60),
  livery text check (livery is null or char_length(livery) between 1 and 60),

  remarks text check (remarks is null or char_length(remarks) <= 240),

  -- Where the plan has got to. `flown` and `cancelled` are both kept rather
  -- than deleted: a plan you actually flew is the most useful thing to copy
  -- the next time you fly the same leg.
  status text not null default 'planned'
    check (status in ('planned', 'flown', 'cancelled')),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The order the app reads them in: what is coming up, soonest first, with the
-- undated ones behind. `nulls last` matches that -- a plan with no time on it
-- is not a plan for the distant future, it is a plan for whenever.
create index if not exists pilot_flight_plans_user_idx
  on public.pilot_flight_plans (user_id, scheduled_out desc nulls last, created_at desc);

comment on table public.pilot_flight_plans is
  'A pilot''s own intentions for a flight: both ends, the stand at each, and the schedule. Private to the account that wrote it. Not the same thing as public.user_flights, which is the website''s filed PIREP.';

-- MARK: - Keeping the row honest
--
-- Three jobs, one trigger, and every one of them is something a client could
-- otherwise get wrong or lie about:
--
-- 1. `user_id`. Defaulted from the caller's own token so the app never has to
--    send it, and forced to the caller on the way in so it cannot send
--    somebody else's. Row-level security refuses that write anyway; this makes
--    it impossible rather than merely refused.
-- 2. ICAOs are stored upper-case whatever case they were typed in, so `egll`
--    and `EGLL` are the same field rather than two.
-- 3. `updated_at` is the server's clock, never the client's.
create or replace function public.pilot_flight_plans_guard()
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
    -- A row does not change hands. Reassigning one would be a way to write
    -- into somebody else's list by updating a row you own into it.
    new.user_id := old.user_id;
    new.created_at := old.created_at;
  end if;

  new.origin_icao := upper(trim(new.origin_icao));
  new.destination_icao := upper(trim(new.destination_icao));

  -- Trimmed, and an empty string is a cleared gate rather than a gate called
  -- "". The app sends null for that, but a whitespace-only value from any
  -- other caller should mean the same thing rather than failing a length
  -- check that would read as gibberish.
  new.departure_gate := nullif(trim(coalesce(new.departure_gate, '')), '');
  new.arrival_gate := nullif(trim(coalesce(new.arrival_gate, '')), '');
  new.callsign := nullif(trim(coalesce(new.callsign, '')), '');
  new.aircraft := nullif(trim(coalesce(new.aircraft, '')), '');
  new.livery := nullif(trim(coalesce(new.livery, '')), '');
  new.remarks := nullif(trim(coalesce(new.remarks, '')), '');

  -- A coordinate with no gate name is a point with nothing to label it, and
  -- the app has no way to show it. Clearing the name clears the point.
  if new.departure_gate is null then
    new.departure_gate_latitude := null;
    new.departure_gate_longitude := null;
  end if;
  if new.arrival_gate is null then
    new.arrival_gate_latitude := null;
    new.arrival_gate_longitude := null;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists pilot_flight_plans_guard on public.pilot_flight_plans;
create trigger pilot_flight_plans_guard
  before insert or update on public.pilot_flight_plans
  for each row execute function public.pilot_flight_plans_guard();

-- Nobody calls this by hand. `create function` grants EXECUTE to PUBLIC unless
-- told otherwise, which puts a trigger function on the REST API as
-- `/rest/v1/rpc/pilot_flight_plans_guard` — see
-- `20260818000800_tighten_function_grants.sql`, which is the migration that
-- exists because this default was missed once already. Calling it would only
-- raise "trigger functions can only be called as triggers", and that is not
-- the point: a `security definer` function should be reachable by exactly the
-- callers that need it, and this one needs none.
revoke all on function public.pilot_flight_plans_guard() from public;
revoke all on function public.pilot_flight_plans_guard() from anon;
revoke all on function public.pilot_flight_plans_guard() from authenticated;

-- MARK: - How many is too many
--
-- Not a limit anybody flying will meet. It is here because this table is
-- writable by a client over a public API, and the difference between "a pilot
-- keeps their next dozen legs in here" and "a loop fills the table" is a
-- number somebody has to write down. Counted only on insert: editing the
-- hundredth plan must keep working, and deleting is how you get back under.
create or replace function public.pilot_flight_plans_cap()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.pilot_flight_plans
  where user_id = new.user_id;

  if v_count >= 200 then
    raise exception
      'That is 200 planned flights. Delete one you have already flown to make room.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists pilot_flight_plans_cap on public.pilot_flight_plans;
create trigger pilot_flight_plans_cap
  before insert on public.pilot_flight_plans
  for each row execute function public.pilot_flight_plans_cap();

-- Same again: a trigger, not an endpoint.
revoke all on function public.pilot_flight_plans_cap() from public;
revoke all on function public.pilot_flight_plans_cap() from anon;
revoke all on function public.pilot_flight_plans_cap() from authenticated;

-- MARK: - Who may read one
--
-- Nobody but its author, for now. A plan is a statement about what somebody
-- intends to do and where they intend to be, and there is no reader for it yet
-- that would justify publishing that by default. When there is one -- a
-- friends list showing what your friends have scheduled, say -- it goes
-- through a function with a visibility setting behind it, the way
-- `pilot_live_status` does, rather than by loosening this policy.
alter table public.pilot_flight_plans enable row level security;

drop policy if exists "Pilots read their own plans" on public.pilot_flight_plans;
create policy "Pilots read their own plans"
  on public.pilot_flight_plans for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Pilots file their own plans" on public.pilot_flight_plans;
create policy "Pilots file their own plans"
  on public.pilot_flight_plans for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Pilots amend their own plans" on public.pilot_flight_plans;
create policy "Pilots amend their own plans"
  on public.pilot_flight_plans for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Pilots delete their own plans" on public.pilot_flight_plans;
create policy "Pilots delete their own plans"
  on public.pilot_flight_plans for delete
  to authenticated
  using (auth.uid() = user_id);

grant select, insert, update, delete on public.pilot_flight_plans to authenticated;

-- Not to `anon`. Every other read surface in this schema is deliberately
-- reachable signed out, because a profile served to a stranger's browser has
-- to be. This one is not a public read surface, and an unauthenticated caller
-- has no business holding a row here.
revoke all on public.pilot_flight_plans from anon;
