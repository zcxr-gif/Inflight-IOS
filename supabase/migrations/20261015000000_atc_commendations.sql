-- ATC commendations: a thumbs-up or a "Good Day" for a controller on frequency.
--
-- WHAT IT IS FOR. Controllers give up their evenings to open fields that would
-- otherwise be uncontrolled. The only feedback channel they have today is the
-- violation appeal thread, which by construction only ever hears complaints.
-- This is the other half: a signed-in pilot taps a button on a live
-- controller's row and, optionally, leaves a short note. The commendations
-- show on the airport window and on the controller's profile.
--
-- POSITIVE ONLY, ON PURPOSE. There is no thumbs-down and no rating scale. A
-- note is filtered like a profile field, and the app points anybody with a
-- grievance at the IFC thread for appealing violations and giving ATC
-- feedback, which is where Infinite Flight actually handles it. A complaint
-- box here would be one nobody at IF reads.
--
-- WHO IS COMMENDED. A controller is identified by their Infinite Flight user
-- id, as it arrives in the live ATC feed — not by an account here, because
-- most controllers will never have one. The username is stored beside it for
-- display only; IF lets people rename.
--
-- ONE PER SESSION. A pilot may commend a given controller once per controller
-- session (the session's start time, from the same feed). Changing your mind
-- between thumbs-up and Good Day updates the row rather than adding one.
-- Pressing it again withdraws it. A withdrawal is a timestamp, not a deleted
-- row, so the daily cap cannot be dodged by withdrawing and re-sending.
--
-- NO DIRECT TABLE ACCESS. Readers would otherwise see `user_id`, which says
-- who was flying where and when. Everything goes through the functions below,
-- which return a public handle only when the commender's profile is public.

-- MARK: - Table

create table if not exists public.atc_commendations (
  id uuid primary key default gen_random_uuid(),

  -- The pilot who left it.
  user_id uuid not null references auth.users (id) on delete cascade,

  -- The controller, as Infinite Flight knows them.
  controller_if_id text not null
    check (controller_if_id ~ '^[A-Za-z0-9-]{8,64}$'),
  controller_username text
    check (controller_username is null or char_length(controller_username) between 1 and 64),

  -- Where and what they were working. Centers have no airport.
  airport_icao text
    check (airport_icao is null or airport_icao ~ '^[A-Z0-9]{2,8}$'),
  facility_type smallint
    check (facility_type is null or facility_type between 0 and 15),

  -- The controller session this belongs to (`startTime` in the feed).
  session_started_at timestamptz not null,

  kind text not null check (kind in ('thumbs_up', 'good_day')),

  note text check (note is null or char_length(note) between 1 and 140),

  -- Set by staff with the service role. A hidden row counts towards
  -- nothing and shows nowhere.
  hidden boolean not null default false,

  -- Set when the pilot takes it back. Readers skip it; commending the same
  -- session again clears it.
  withdrawn_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atc_commendations_one_per_session
    unique (user_id, controller_if_id, session_started_at)
);

create index if not exists atc_commendations_controller_idx
  on public.atc_commendations (controller_if_id, created_at desc)
  where not hidden;

create index if not exists atc_commendations_airport_idx
  on public.atc_commendations (airport_icao, created_at desc)
  where not hidden and airport_icao is not null;

-- The kudos inbox asks "what has been left for the controller with my IF
-- username".
create index if not exists atc_commendations_controller_name_idx
  on public.atc_commendations (lower(controller_username), created_at desc)
  where not hidden and withdrawn_at is null;

-- The rate limit asks "how many has this pilot left today".
create index if not exists atc_commendations_user_idx
  on public.atc_commendations (user_id, created_at desc);

comment on table public.atc_commendations is
  'Positive-only commendations pilots leave for Infinite Flight ATC controllers. Read and written only through the atc_* functions.';

alter table public.atc_commendations enable row level security;

-- No policies: the functions below are security definer and are the only way
-- in. Supabase's default table grants must not leak user_id either.
revoke all on public.atc_commendations from anon, authenticated;

-- MARK: - Leaving one

create or replace function public.atc_commend(
  p_controller_if_id text,
  p_controller_username text,
  p_airport_icao text,
  p_facility_type integer,
  p_session_started_at timestamptz,
  p_kind text,
  p_note text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_note text := nullif(btrim(regexp_replace(coalesce(p_note, ''), '\s+', ' ', 'g')), '');
  v_icao text := nullif(upper(btrim(coalesce(p_airport_icao, ''))), '');
  v_session timestamptz := date_trunc('second', p_session_started_at);
  v_today integer;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'Sign in to commend a controller.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_kind is null or p_kind not in ('thumbs_up', 'good_day') then
    raise exception 'Unknown commendation.' using errcode = 'check_violation';
  end if;

  -- The feed only ever shows sessions that are running now. A start time in
  -- the future, or from days ago, is not a controller who is on frequency.
  if v_session is null
     or v_session > now() + interval '10 minutes'
     or v_session < now() - interval '48 hours' then
    raise exception 'That controller session is not active.'
      using errcode = 'check_violation';
  end if;

  if v_note is not null then
    if char_length(v_note) > 140 then
      raise exception 'Keep the note to 140 characters.'
        using errcode = 'check_violation';
    end if;
    if v_note ~* '(https?://|www\.|discord\.gg)' then
      raise exception 'Links are not allowed in a commendation.'
        using errcode = 'check_violation';
    end if;
    if public.moderation_rejects(v_note) then
      raise exception 'That note can''t be posted. Keep it kind.'
        using errcode = 'check_violation';
    end if;
  end if;

  -- Commending yourself is not a commendation.
  if p_controller_username is not null and exists (
    select 1 from public.pilot_profiles
     where user_id = v_uid
       and if_username is not null
       and lower(if_username) = lower(btrim(p_controller_username))
  ) then
    raise exception 'You can''t commend your own session.'
      using errcode = 'check_violation';
  end if;

  select count(*) into v_today
    from public.atc_commendations
   where user_id = v_uid and created_at > now() - interval '24 hours';
  if v_today >= 40 and not exists (
    select 1 from public.atc_commendations
     where user_id = v_uid
       and controller_if_id = p_controller_if_id
       and session_started_at = v_session
  ) then
    raise exception 'That''s plenty of commendations for one day. Thank you!'
      using errcode = 'check_violation';
  end if;

  insert into public.atc_commendations as c (
    user_id, controller_if_id, controller_username, airport_icao,
    facility_type, session_started_at, kind, note
  ) values (
    v_uid, p_controller_if_id, nullif(btrim(coalesce(p_controller_username, '')), ''),
    v_icao, p_facility_type, v_session, p_kind, v_note
  )
  on conflict (user_id, controller_if_id, session_started_at) do update
     set kind = excluded.kind,
         note = excluded.note,
         withdrawn_at = null,
         controller_username = coalesce(excluded.controller_username, c.controller_username),
         updated_at = now()
  returning id into v_id;

  return v_id;
end;
$function$;

-- MARK: - Taking it back

create or replace function public.atc_commendation_withdraw(
  p_controller_if_id text,
  p_session_started_at timestamptz
)
returns boolean
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  n integer;
begin
  if v_uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;
  update public.atc_commendations
     set withdrawn_at = now(), updated_at = now()
   where user_id = v_uid
     and controller_if_id = p_controller_if_id
     and session_started_at = date_trunc('second', p_session_started_at)
     and withdrawn_at is null;
  get diagnostics n = row_count;
  return n > 0;
end;
$function$;

-- MARK: - Reading

-- Who left it, as the public may see it: a handle only when the pilot's
-- profile is public and in good standing. Everybody else is "a pilot".
create or replace function public.atc_commender_label(p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select jsonb_build_object('handle', p.handle, 'display_name', p.display_name)
       from public.pilot_profiles p
      where p.user_id = p_uid and p.is_public and p.moderation_state = 'ok'),
    '{}'::jsonb
  );
$function$;

-- Counts for the controller rows on screen, plus what the caller has already
-- given each of them (so the button can show as pressed).
create or replace function public.atc_commendation_counts(p_controller_if_ids text[])
returns table (
  controller_if_id text,
  total integer,
  thumbs_up integer,
  good_day integer,
  my_session_started_at timestamptz,
  my_kind text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with ids as (
    select distinct unnest(p_controller_if_ids[1:100]) as id
  )
  select ids.id,
         count(c.id) filter (where not c.hidden and c.withdrawn_at is null)::integer,
         count(c.id) filter (where not c.hidden and c.withdrawn_at is null and c.kind = 'thumbs_up')::integer,
         count(c.id) filter (where not c.hidden and c.withdrawn_at is null and c.kind = 'good_day')::integer,
         mine.session_started_at,
         mine.kind
    from ids
    left join public.atc_commendations c on c.controller_if_id = ids.id
    left join lateral (
      select m.session_started_at, m.kind
        from public.atc_commendations m
       where m.controller_if_id = ids.id and m.user_id = auth.uid()
         and m.withdrawn_at is null
       order by m.session_started_at desc
       limit 1
    ) mine on true
   group by ids.id, mine.session_started_at, mine.kind;
$function$;

-- Recent notes left at one field, for the airport window.
create or replace function public.atc_commendations_for_airport(
  p_icao text,
  p_limit integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with rows as (
    select c.*
      from public.atc_commendations c
     where c.airport_icao = upper(btrim(p_icao))
       and not c.hidden and c.withdrawn_at is null
     order by c.created_at desc
     limit least(greatest(coalesce(p_limit, 20), 1), 50)
  )
  select jsonb_build_object(
    'icao', upper(btrim(p_icao)),
    'total', (select count(*) from public.atc_commendations
               where airport_icao = upper(btrim(p_icao)) and not hidden and withdrawn_at is null),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
               'controller_if_id', r.controller_if_id,
               'controller_username', r.controller_username,
               'facility_type', r.facility_type,
               'kind', r.kind,
               'note', r.note,
               'created_at', r.created_at,
               'by', public.atc_commender_label(r.user_id)
             ) order by r.created_at desc)
        from rows r), '[]'::jsonb)
  );
$function$;

-- Everything a controller's profile shows: totals, where they were earned, and
-- the latest notes.
create or replace function public.atc_commendation_profile(
  p_controller_if_id text,
  p_limit integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with mine as (
    select c.*
      from public.atc_commendations c
     where c.controller_if_id = p_controller_if_id and not c.hidden and c.withdrawn_at is null
  )
  select jsonb_build_object(
    'controller_if_id', p_controller_if_id,
    'total', (select count(*) from mine),
    'thumbs_up', (select count(*) from mine where kind = 'thumbs_up'),
    'good_day', (select count(*) from mine where kind = 'good_day'),
    'sessions', (select count(distinct session_started_at) from mine),
    'first_at', (select min(created_at) from mine),
    'airports', coalesce((
      select jsonb_agg(jsonb_build_object('icao', a.airport_icao, 'count', a.n)
                       order by a.n desc, a.airport_icao)
        from (select airport_icao, count(*) as n from mine
               where airport_icao is not null
               group by airport_icao
               order by count(*) desc, airport_icao
               limit 12) a), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
               'airport_icao', r.airport_icao,
               'facility_type', r.facility_type,
               'kind', r.kind,
               'note', r.note,
               'created_at', r.created_at,
               'by', public.atc_commender_label(r.user_id)
             ) order by r.created_at desc)
        from (select * from mine
               order by created_at desc
               limit least(greatest(coalesce(p_limit, 20), 1), 50)) r), '[]'::jsonb)
  );
$function$;

-- The signed-in controller's own kudos: what pilots have left for the IF
-- username on their pilot profile, so the app can show a badge and a toast
-- when a new one lands. Matched by username because a controller's account
-- here is not keyed by their IF user id; everything returned is already
-- public through atc_commendation_profile, so a mistyped or borrowed
-- username reveals nothing new.
create or replace function public.atc_kudos_inbox(
  p_since timestamptz default null,
  p_limit integer default 10
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with me as (
    select lower(btrim(p.if_username)) as uname
      from public.pilot_profiles p
     where p.user_id = auth.uid() and nullif(btrim(p.if_username), '') is not null
  ),
  mine as (
    select c.*
      from public.atc_commendations c
      join me on lower(c.controller_username) = me.uname
     where not c.hidden and c.withdrawn_at is null
       and c.user_id <> auth.uid()
  ),
  fresh as (
    select * from mine
     where p_since is null or created_at > p_since
     order by created_at desc
     limit least(greatest(coalesce(p_limit, 10), 1), 20)
  )
  select jsonb_build_object(
    'linked', exists (select 1 from me),
    'username', (select uname from me),
    'controller_if_id', (select controller_if_id from mine order by created_at desc limit 1),
    'total', (select count(*) from mine),
    'unseen', (select count(*) from mine where p_since is null or created_at > p_since),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
               'airport_icao', f.airport_icao,
               'facility_type', f.facility_type,
               'kind', f.kind,
               'note', f.note,
               'created_at', f.created_at,
               'by', public.atc_commender_label(f.user_id)
             ) order by f.created_at desc)
        from fresh f), '[]'::jsonb)
  );
$function$;

-- MARK: - Grants

revoke all on function public.atc_commend(text, text, text, integer, timestamptz, text, text) from public, anon;
revoke all on function public.atc_commendation_withdraw(text, timestamptz) from public, anon;
revoke all on function public.atc_kudos_inbox(timestamptz, integer) from public, anon;
revoke all on function public.atc_commender_label(uuid) from public, anon, authenticated;
revoke all on function public.atc_commendation_counts(text[]) from public;
revoke all on function public.atc_commendations_for_airport(text, integer) from public;
revoke all on function public.atc_commendation_profile(text, integer) from public;

grant execute on function public.atc_commend(text, text, text, integer, timestamptz, text, text) to authenticated;
grant execute on function public.atc_commendation_withdraw(text, timestamptz) to authenticated;
grant execute on function public.atc_kudos_inbox(timestamptz, integer) to authenticated;
grant execute on function public.atc_commendation_counts(text[]) to anon, authenticated;
grant execute on function public.atc_commendations_for_airport(text, integer) to anon, authenticated;
grant execute on function public.atc_commendation_profile(text, integer) to anon, authenticated;
