-- MARK: - Your own flight, announced by the only thing that can see all of it
--
-- The question this answers is why an airline's app can tell you the aircraft
-- has pushed back, is climbing, and is on final, while this app could tell you
-- nothing about the flight you are actually flying.
--
-- The answer is not that those apps talk to the aeroplane. Nothing in a phone's
-- pocket is attached to an airliner. A server watches a feed of the whole sky,
-- notices a state change on one row of it, and pushes a sentence to the phones
-- that asked about that row. The phone contributes nothing but an address.
--
-- Everything needed to do exactly that has been here for months and pointed the
-- wrong way. `friend_events.cjs` already diffs consecutive feed snapshots and
-- decides, with hysteresis, when an aircraft has left the ground; `push.
-- notifyAccount` already reaches the person flying rather than the people
-- watching them; `pilot_profiles.if_username` is already the join between a
-- feed row and an account. What was missing is that the detector only ever ran
-- for pilots *somebody else* was watching, and its notifications were addressed
-- to the watcher. Nobody was ever told about their own flight.
--
-- This adds the two pieces the backend needs to point it back at the pilot: a
-- switch, and a way to ask who has it on.
--
-- Note what it does NOT need. No Connect, no local network, no socket held open
-- behind the simulator, and no cooperation from the app while it is suspended —
-- which is the whole reason it works on a single phone, where Connect on its
-- own cannot see a flight it is not in front of.

-- MARK: - The switch

alter table public.pilot_profiles
  add column if not exists flight_alerts boolean not null default true;

comment on column public.pilot_profiles.flight_alerts is
  'Whether to announce this pilot''s OWN flight to them - airborne, top of descent, landed - from the live feed. Defaults on, matching connect_alerts: a pilot who has signed in and put their Infinite Flight handle on their profile has asked to be joined to the map, and this is the useful half of that. Off is one switch away and is honoured server-side.';

-- MARK: - Who has it on
--
-- Answered by the database rather than by a table read from the backend,
-- because one rule in it is easy to get wrong in a way nobody would notice
-- until a stranger's phone buzzed about somebody else's flight.
--
-- `if_username` is not unique and deliberately is not: it is a claim, checked
-- by nothing (`if_username_verified` exists and nothing sets it yet), and two
-- accounts can name the same pilot — an impersonator, a typo, or somebody who
-- changed handles and left the old profile behind. Addressed by username alone
-- they would both be told, and one of them would be a stranger being told the
-- movements of a pilot they merely claimed to be.
--
-- So a contested name is dropped, unless exactly one of the claimants has
-- actually been verified, in which case it is theirs. Silence for both is the
-- right failure: a notification nobody asked for is worse than a notification
-- that did not arrive, and the pilot who owns the name can still see everything
-- in the app.

create or replace function public.pilot_flight_alert_targets(
  p_limit integer default 5000
)
returns table (user_id uuid, handle text, if_username text)
language sql
security definer
set search_path to 'public'
as $function$
  with claimed as (
    select lower(p.if_username) as name,
           count(*) as claims,
           count(*) filter (where p.if_username_verified) as verified
      from public.pilot_profiles p
     where p.if_username is not null
       and length(btrim(p.if_username)) > 0
     group by lower(p.if_username)
  )
  select p.user_id,
         p.handle,
         lower(p.if_username) as if_username
    from public.pilot_profiles p
    join claimed c on c.name = lower(p.if_username)
   where p.flight_alerts
     and p.if_username is not null
     and length(btrim(p.if_username)) > 0
     -- Uncontested, or contested and this is the one claimant anybody has
     -- actually checked.
     and (c.claims = 1 or (c.verified = 1 and p.if_username_verified))
   order by p.user_id
   limit least(greatest(coalesce(p_limit, 5000), 1), 50000);
$function$;

comment on function public.pilot_flight_alert_targets(integer) is
  'Feed username -> account, for the backend''s own-flight announcer. Service role only: it is a list of who flies under which handle, which is not a public index to hand out.';

revoke all on function public.pilot_flight_alert_targets(integer) from public;
revoke all on function public.pilot_flight_alert_targets(integer) from anon;
revoke all on function public.pilot_flight_alert_targets(integer) from authenticated;
grant execute on function public.pilot_flight_alert_targets(integer) to service_role;
