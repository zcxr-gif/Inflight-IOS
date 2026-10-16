-- RateMyATC: 1–5 star ratings for a controller session, and private feedback.
--
-- WHAT IS PUBLIC AND WHAT IS NOT. Every star is public: a controller's average,
-- count and distribution show on the airport window and their profile. A
-- comment on a 4–5 star rating is public too. A comment on a 1–3 star rating
-- is a complaint, and it goes to the controller only — never to the airport
-- window, never to the profile — and without the rater's name, so feedback
-- cannot turn into a feud. Official violation appeals still belong to the IFC
-- thread the app links to.
--
-- WHO "THE CONTROLLER" IS. Ratings are keyed by the controller's IF user id
-- from the live ATC feed. The private comments are delivered to the account
-- whose pilot profile claims that IF username, under the same rule as the
-- own-flight alerts (20260821000000): the claim counts only when it is
-- uncontested, or when exactly one claimant has been verified. A contested
-- name gets nothing — silence is the right failure for private text.

-- MARK: - Table

create table if not exists public.atc_ratings (
  id uuid primary key default gen_random_uuid(),

  user_id uuid not null references auth.users (id) on delete cascade,

  controller_if_id text not null
    check (controller_if_id ~ '^[A-Za-z0-9-]{8,64}$'),
  controller_username text
    check (controller_username is null or char_length(controller_username) between 1 and 64),
  airport_icao text
    check (airport_icao is null or airport_icao ~ '^[A-Z0-9]{2,8}$'),
  facility_type smallint
    check (facility_type is null or facility_type between 0 and 15),
  session_started_at timestamptz not null,

  stars smallint not null check (stars between 1 and 5),
  comment text check (comment is null or char_length(comment) between 1 and 280),

  -- Staff takedown, service role only.
  hidden boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atc_ratings_one_per_session
    unique (user_id, controller_if_id, session_started_at)
);

create index if not exists atc_ratings_controller_idx
  on public.atc_ratings (controller_if_id, created_at desc)
  where not hidden;

create index if not exists atc_ratings_controller_name_idx
  on public.atc_ratings (lower(controller_username), created_at desc)
  where not hidden;

create index if not exists atc_ratings_user_idx
  on public.atc_ratings (user_id, created_at desc);

comment on table public.atc_ratings is
  'RateMyATC: one 1-5 star rating per pilot per controller session. Stars and 4-5 star comments are public; 1-3 star comments go privately to the controller. Read and written only through the atc_* functions.';

alter table public.atc_ratings enable row level security;
revoke all on public.atc_ratings from anon, authenticated;

-- MARK: - Rating

create or replace function public.atc_rate(
  p_controller_if_id text,
  p_controller_username text,
  p_airport_icao text,
  p_facility_type integer,
  p_session_started_at timestamptz,
  p_stars integer,
  p_comment text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_comment text := nullif(btrim(regexp_replace(coalesce(p_comment, ''), '\s+', ' ', 'g')), '');
  v_icao text := nullif(upper(btrim(coalesce(p_airport_icao, ''))), '');
  v_session timestamptz := date_trunc('second', p_session_started_at);
  v_today integer;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'Sign in to rate a controller.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'Pick between 1 and 5 stars.' using errcode = 'check_violation';
  end if;

  if v_session is null
     or v_session > now() + interval '10 minutes'
     or v_session < now() - interval '48 hours' then
    raise exception 'That controller session is not active.'
      using errcode = 'check_violation';
  end if;

  if v_comment is not null then
    if char_length(v_comment) > 280 then
      raise exception 'Keep the comment to 280 characters.'
        using errcode = 'check_violation';
    end if;
    if v_comment ~* '(https?://|www\.|discord\.gg)' then
      raise exception 'Links are not allowed in a rating.'
        using errcode = 'check_violation';
    end if;
    if public.moderation_rejects(v_comment) then
      raise exception 'That comment can''t be posted. Keep it respectful.'
        using errcode = 'check_violation';
    end if;
  end if;

  if p_controller_username is not null and exists (
    select 1 from public.pilot_profiles
     where user_id = v_uid
       and if_username is not null
       and lower(if_username) = lower(btrim(p_controller_username))
  ) then
    raise exception 'You can''t rate your own session.'
      using errcode = 'check_violation';
  end if;

  select count(*) into v_today
    from public.atc_ratings
   where user_id = v_uid and created_at > now() - interval '24 hours';
  if v_today >= 40 and not exists (
    select 1 from public.atc_ratings
     where user_id = v_uid
       and controller_if_id = p_controller_if_id
       and session_started_at = v_session
  ) then
    raise exception 'That''s plenty of ratings for one day.'
      using errcode = 'check_violation';
  end if;

  insert into public.atc_ratings as r (
    user_id, controller_if_id, controller_username, airport_icao,
    facility_type, session_started_at, stars, comment
  ) values (
    v_uid, p_controller_if_id, nullif(btrim(coalesce(p_controller_username, '')), ''),
    v_icao, p_facility_type, v_session, p_stars, v_comment
  )
  on conflict (user_id, controller_if_id, session_started_at) do update
     set stars = excluded.stars,
         comment = excluded.comment,
         controller_username = coalesce(excluded.controller_username, r.controller_username),
         updated_at = now()
  returning id into v_id;

  return v_id;
end;
$function$;

-- MARK: - Public readers

-- Average and count for the controller rows on screen, plus the caller's own
-- stars (so the rate button can show them).
create or replace function public.atc_rating_counts(p_controller_if_ids text[])
returns table (
  controller_if_id text,
  rating_avg numeric,
  rating_count integer,
  my_session_started_at timestamptz,
  my_stars smallint
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
         round(avg(r.stars) filter (where not r.hidden), 1),
         (count(r.id) filter (where not r.hidden))::integer,
         mine.session_started_at,
         mine.stars
    from ids
    left join public.atc_ratings r on r.controller_if_id = ids.id
    left join lateral (
      select m.session_started_at, m.stars
        from public.atc_ratings m
       where m.controller_if_id = ids.id and m.user_id = auth.uid()
       order by m.session_started_at desc
       limit 1
    ) mine on true
   group by ids.id, mine.session_started_at, mine.stars;
$function$;

-- Everything public about a controller's ratings: average, count, the 1–5
-- distribution and the latest public (4–5 star) comments.
create or replace function public.atc_rating_profile(
  p_controller_if_id text,
  p_limit integer default 10
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with mine as (
    select r.*
      from public.atc_ratings r
     where r.controller_if_id = p_controller_if_id and not r.hidden
  )
  select jsonb_build_object(
    'controller_if_id', p_controller_if_id,
    'avg', (select round(avg(stars), 1) from mine),
    'count', (select count(*) from mine),
    'dist', jsonb_build_object(
      '1', (select count(*) from mine where stars = 1),
      '2', (select count(*) from mine where stars = 2),
      '3', (select count(*) from mine where stars = 3),
      '4', (select count(*) from mine where stars = 4),
      '5', (select count(*) from mine where stars = 5)),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'stars', c.stars,
               'comment', c.comment,
               'airport_icao', c.airport_icao,
               'facility_type', c.facility_type,
               'created_at', c.created_at,
               'by', public.atc_commender_label(c.user_id)
             ) order by c.created_at desc)
        from (select * from mine
               where stars >= 4 and comment is not null
               order by created_at desc
               limit least(greatest(coalesce(p_limit, 10), 1), 50)) c), '[]'::jsonb)
  );
$function$;

-- MARK: - The controller's own inbox

-- Is the caller's IF username claim one we will deliver private text to?
-- Same rule as pilot_flight_alert_targets: uncontested, or the one verified
-- claimant of a contested name.
create or replace function public.atc_my_controller_name()
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  with me as (
    select lower(btrim(p.if_username)) as uname, p.if_username_verified as verified
      from public.pilot_profiles p
     where p.user_id = auth.uid() and nullif(btrim(p.if_username), '') is not null
  ),
  claims as (
    select count(*) as n, count(*) filter (where p.if_username_verified) as v
      from public.pilot_profiles p, me
     where lower(btrim(p.if_username)) = me.uname
  )
  select me.uname
    from me, claims
   where claims.n = 1 or (claims.v = 1 and me.verified);
$function$;

-- Extends the kudos inbox with ratings: the caller's public rating summary as
-- a controller, and their private feedback (1–3 star comments), anonymous.
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
  owner as (
    select public.atc_my_controller_name() as uname
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
  ),
  feedback as (
    select r.*
      from public.atc_ratings r
      join owner on owner.uname is not null and lower(r.controller_username) = owner.uname
     where not r.hidden and r.stars <= 3 and r.comment is not null
       and r.user_id <> auth.uid()
  ),
  ratings as (
    select r.stars
      from public.atc_ratings r
      join me on lower(r.controller_username) = me.uname
     where not r.hidden and r.user_id <> auth.uid()
  )
  select jsonb_build_object(
    'linked', exists (select 1 from me),
    'owner', (select uname is not null from owner),
    'username', (select uname from me),
    'controller_if_id', coalesce(
      (select controller_if_id from mine order by created_at desc limit 1),
      (select r.controller_if_id from public.atc_ratings r, me
        where lower(r.controller_username) = me.uname order by r.created_at desc limit 1)),
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
        from fresh f), '[]'::jsonb),
    'rating_avg', (select round(avg(stars), 1) from ratings),
    'rating_count', (select count(*) from ratings),
    'feedback_unseen', (select count(*) from feedback
                         where p_since is null or greatest(created_at, updated_at) > p_since),
    -- Anonymous on purpose: no rater identity, ever, on private feedback.
    'feedback', coalesce((
      select jsonb_agg(jsonb_build_object(
               'stars', b.stars,
               'comment', b.comment,
               'airport_icao', b.airport_icao,
               'facility_type', b.facility_type,
               'created_at', greatest(b.created_at, b.updated_at)
             ) order by greatest(b.created_at, b.updated_at) desc)
        from (select * from feedback
               order by greatest(created_at, updated_at) desc
               limit 20) b), '[]'::jsonb)
  );
$function$;

-- MARK: - Grants

revoke all on function public.atc_rate(text, text, text, integer, timestamptz, integer, text) from public, anon;
revoke all on function public.atc_rating_counts(text[]) from public;
revoke all on function public.atc_rating_profile(text, integer) from public;
revoke all on function public.atc_my_controller_name() from public, anon, authenticated;
revoke all on function public.atc_kudos_inbox(timestamptz, integer) from public, anon;

grant execute on function public.atc_rate(text, text, text, integer, timestamptz, integer, text) to authenticated;
grant execute on function public.atc_rating_counts(text[]) to anon, authenticated;
grant execute on function public.atc_rating_profile(text, integer) to anon, authenticated;
grant execute on function public.atc_kudos_inbox(timestamptz, integer) to authenticated;
