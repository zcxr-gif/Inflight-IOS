-- MARK: - The landing, published the moment it is measured
--
-- A touchdown is the one number in this whole app that only Infinite Flight
-- Connect can produce — the feed samples in seconds and a landing lasts a
-- fraction of one — and until now it went into the pilot's logbook and stopped
-- there, visible to anybody who thought to go and look at their profile.
--
-- Two things are needed to put it in front of people instead.

-- MARK: - When we found out, as distinct from when it happened
--
-- `landed_at` is when the aeroplane touched down. That is the right clock for a
-- logbook and the wrong one for a feed, because on a phone the landing is not
-- read at the moment it happens: iOS has this app suspended behind the
-- simulator, and `ConnectSession` collects the touchdown the next time the two
-- are both awake. A flight landed at 14:02 and recorded at 14:40 belongs at the
-- top of "just landed" at 14:40, not thirty-eight minutes down it.
--
-- Stamped by a trigger rather than by the client or by
-- `pilot_logbook_attach_landing`, because there are two ways a landing arrives
-- — attached afterwards by that function, or written with the row when Connect
-- was live for the whole flight — and a rule enforced in one of them is a rule
-- that holds half the time.

alter table public.pilot_logbook
  add column if not exists landing_recorded_at timestamptz;

comment on column public.pilot_logbook.landing_recorded_at is
  'When the landing measurement reached the server, which on a phone is well after landed_at: the app is suspended behind the simulator and collects the touchdown afterwards. Ordering a "just landed" feed by landed_at would bury exactly the rows it exists to show.';

create or replace function public.pilot_logbook_stamp_landing()
returns trigger
language plpgsql
-- Pinned like every other function here. A trigger function with a mutable
-- search_path resolves its names against whatever the caller's happens to be,
-- which is a way to have something other than `public.pilot_logbook` written to
-- by a statement that looks like it writes to `public.pilot_logbook`.
set search_path to 'public'
as $function$
begin
  -- Only the transition into having a landing, and only once. An edit that
  -- touches any other column must not move a row back to the top of the feed.
  if new.landing_vertical_speed_fpm is not null
     and new.landing_recorded_at is null
     and (tg_op = 'INSERT' or old.landing_vertical_speed_fpm is null) then
    new.landing_recorded_at := now();
  end if;
  return new;
end $function$;

drop trigger if exists pilot_logbook_stamp_landing on public.pilot_logbook;
create trigger pilot_logbook_stamp_landing
  before insert or update on public.pilot_logbook
  for each row execute function public.pilot_logbook_stamp_landing();

-- Newest first, over the rows that have a landing at all. Partial, because the
-- feed never looks at a flight without one and most rows have none.
create index if not exists pilot_logbook_landing_recorded_idx
  on public.pilot_logbook (landing_recorded_at desc)
  where landing_vertical_speed_fpm is not null;

-- MARK: - The feed itself
--
-- Deliberately stricter than `pilot_logbook_readable`, which every by-handle
-- reader uses. That function serves a followers-only logbook to a follower, and
-- that is right when somebody has gone to a profile and asked. A firehose is a
-- different thing: it is discovery rather than lookup, and a pilot who set
-- their logbook to followers did not ask to be surfaced to everybody who
-- happens to be a follower. So this one wants `public`, and nothing else.
--
-- Readable signed out, which `pilot_landing_board` is not. The two are opposite
-- kinds of thing: the board is your own circle, computed against `auth.uid()`
-- and meaningless without one, and this is the set of landings whose owners
-- have explicitly said "public". `pilot_live_public` already serves that
-- category to anonymous readers.

create or replace function public.pilot_recent_landings(
  p_limit integer default 25
)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  aircraft text,
  callsign text,
  origin_icao text,
  destination_icao text,
  vertical_speed_fpm integer,
  score integer,
  g_force numeric,
  landed_at timestamp with time zone,
  recorded_at timestamp with time zone,
  is_self boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
begin
  return query
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         public.is_pro_account(p.user_id),
         l.aircraft,
         l.callsign,
         l.origin_icao,
         l.destination_icao,
         l.landing_vertical_speed_fpm,
         l.landing_score,
         l.landing_g_force,
         l.landed_at,
         l.landing_recorded_at,
         p.user_id is not distinct from v_viewer
    from public.pilot_logbook l
    join public.pilot_profiles p on p.user_id = l.user_id
   where l.landing_vertical_speed_fpm is not null
     and l.landing_recorded_at is not null
     and (
       -- Your own always, so a pilot can see their landing arrive even while
       -- their profile is private -- and can tell that the feature worked.
       p.user_id is not distinct from v_viewer
       or (p.logbook_visibility = 'public'
           and public.pilot_profile_visible(p, v_viewer))
     )
   order by l.landing_recorded_at desc
   limit least(greatest(coalesce(p_limit, 25), 1), 100);
end $function$;

comment on function public.pilot_recent_landings(integer) is
  'Landings as they are measured, newest first, from pilots whose logbook is public. Ordered by when the measurement arrived rather than by when the aeroplane touched down, because on a phone those are very different times.';

revoke all on function public.pilot_recent_landings(integer) from public;
grant execute on function public.pilot_recent_landings(integer) to anon;
grant execute on function public.pilot_recent_landings(integer) to authenticated;
