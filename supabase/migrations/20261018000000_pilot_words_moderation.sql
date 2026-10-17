-- Pilot-written words join the Pilot Content console, and everything pilots
-- put on the platform is announced to staff as it arrives.
--
-- WHAT CHANGES, in the order the pieces are used:
--
--   1. A rater chooses whether a RateMyATC comment carries their name.
--      `atc_ratings.anonymous` defaults the way the feature always worked —
--      anonymous on 1–3★ (the private note to the controller), named on 4–5★
--      (the public comment) — and the pilot can flip it either way. Every star
--      still counts toward the public average whatever is chosen; this is only
--      about the name beside the words. Staff always see who wrote what.
--
--   2. Words can be taken down like pictures. `admin_pilot_comments()` lists
--      every rating comment and kudos note, public and private, with the
--      author; `admin_pilot_comment_takedown()` removes the words (the stars
--      or the kudos stay) or the whole rating/kudos, records it in
--      `pilot_content_actions`, and can warn and pause the pilot in the same
--      transaction — the same one-decision shape as `admin_pilot_takedown()`.
--
--   3. A pause now covers words too. A live `upload_block` already refused
--      new pictures; a trigger now refuses a new or changed rating comment or
--      kudos note from the same pilot. Stars and plain kudos still go through:
--      what is paused is putting words and pictures in front of other people.
--
--   4. `pilot_content_queue` — one row for every new picture, name, bio,
--      rating comment and kudos note, written by triggers so no client can
--      forget to. The staff hub drains it into a Discord channel
--      (`admin_pilot_content_queue` / `admin_pilot_content_queue_ack`), so a
--      bad upload is in front of a moderator in seconds rather than whenever
--      somebody next opens the console.

-- The flight-window photo column arrived through the tracker repo's
-- supabase/sql/pilot-window-style.sql, not a migration here. Declared again
-- (a no-op on the live project) so the queue trigger below can name it on a
-- fresh database too.
alter table public.pilot_profiles add column if not exists window_bg_path text;

-- MARK: - 1. Anonymous or named

alter table public.atc_ratings
  add column if not exists anonymous boolean not null default false;

-- Existing rows keep the promise they were written under.
update public.atc_ratings set anonymous = (stars <= 3) where anonymous is distinct from (stars <= 3);

comment on column public.atc_ratings.anonymous is
  'Whether the rater''s name is withheld from the comment. Defaults to true for 1-3 stars, false for 4-5; the rater chooses. Staff always see the author.';

-- The old seven-argument signature goes, so PostgREST has one function to
-- resolve. Callers that do not send p_anonymous get the old behaviour.
drop function if exists public.atc_rate(text, text, text, integer, timestamptz, integer, text);

create or replace function public.atc_rate(
  p_controller_if_id text,
  p_controller_username text,
  p_airport_icao text,
  p_facility_type integer,
  p_session_started_at timestamptz,
  p_stars integer,
  p_comment text default null,
  p_anonymous boolean default null
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
    facility_type, session_started_at, stars, comment, anonymous
  ) values (
    v_uid, p_controller_if_id, nullif(btrim(coalesce(p_controller_username, '')), ''),
    v_icao, p_facility_type, v_session, p_stars, v_comment,
    coalesce(p_anonymous, p_stars <= 3)
  )
  on conflict (user_id, controller_if_id, session_started_at) do update
     set stars = excluded.stars,
         comment = excluded.comment,
         anonymous = excluded.anonymous,
         controller_username = coalesce(excluded.controller_username, r.controller_username),
         updated_at = now()
  returning id into v_id;

  return v_id;
end;
$function$;

-- Readers: a named comment carries the rater's public label, an anonymous one
-- carries none. Both carry the flag, so a client can say "anonymous".

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
               'anonymous', c.anonymous
             -- No "by" key at all when anonymous, rather than a null one.
             ) || case when c.anonymous then '{}'::jsonb
                       else jsonb_build_object('by', public.atc_commender_label(c.user_id)) end order by c.created_at desc)
        from (select * from mine
               where stars >= 4 and comment is not null
               order by created_at desc
               limit least(greatest(coalesce(p_limit, 10), 1), 50)) c), '[]'::jsonb)
  );
$function$;

create or replace function public.atc_site_stats(p_days integer default 30)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with since as (
    select case when coalesce(p_days, 0) <= 0 then '-infinity'::timestamptz
                else now() - make_interval(days => least(p_days, 3650)) end as t
  ),
  r as (
    select x.* from public.atc_ratings x, since
     where not x.hidden and x.created_at >= since.t
  ),
  k as (
    select x.* from public.atc_commendations x, since
     where not x.hidden and x.withdrawn_at is null and x.created_at >= since.t
  ),
  airports as (
    select icao,
           sum(kudos)::integer as kudos,
           sum(ratings)::integer as ratings,
           round(sum(star_sum)::numeric / nullif(sum(ratings), 0), 1) as rating_avg,
           count(distinct controller_if_id)::integer as controllers
      from (
        select airport_icao as icao, controller_if_id, 1 as kudos, 0 as ratings, 0 as star_sum from k
         where airport_icao is not null
        union all
        select airport_icao, controller_if_id, 0, 1, stars from r
         where airport_icao is not null
      ) a
     group by icao
  ),
  positions as (
    select facility_type,
           sum(kudos)::integer as kudos,
           sum(ratings)::integer as ratings,
           round(sum(star_sum)::numeric / nullif(sum(ratings), 0), 1) as rating_avg
      from (
        select facility_type, 1 as kudos, 0 as ratings, 0 as star_sum from k where facility_type is not null
        union all
        select facility_type, 0, 1, stars from r where facility_type is not null
      ) p
     group by facility_type
  ),
  days as (
    select d::date as day from generate_series(current_date - 29, current_date, interval '1 day') d
  )
  select jsonb_build_object(
    'days', case when coalesce(p_days, 0) <= 0 then null else least(p_days, 3650) end,
    'controllers', (select count(*) from (select controller_if_id from r union select controller_if_id from k) c),
    'pilots', (select count(*) from (select user_id from r union select user_id from k) u),
    'ratings', (select count(*) from r),
    'rating_avg', (select round(avg(stars), 2) from r),
    'kudos', (select count(*) from k),
    'thumbs_up', (select count(*) from k where kind = 'thumbs_up'),
    'good_day', (select count(*) from k where kind = 'good_day'),
    'notes', (select count(*) from k where note is not null),
    'airports_count', (select count(*) from airports),
    'dist', jsonb_build_object(
      '1', (select count(*) from r where stars = 1),
      '2', (select count(*) from r where stars = 2),
      '3', (select count(*) from r where stars = 3),
      '4', (select count(*) from r where stars = 4),
      '5', (select count(*) from r where stars = 5)),
    'airports', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.kudos + a.ratings desc, a.icao)
        from (select * from airports order by kudos + ratings desc, icao limit 12) a), '[]'::jsonb),
    'positions', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.kudos + p.ratings desc)
        from positions p), '[]'::jsonb),
    'daily', (
      select jsonb_agg(jsonb_build_object(
               'day', d.day,
               'kudos', (select count(*) from public.atc_commendations c
                          where not c.hidden and c.withdrawn_at is null and c.created_at::date = d.day),
               'ratings', (select count(*) from public.atc_ratings x
                            where not x.hidden and x.created_at::date = d.day)
             ) order by d.day)
        from days d),
    'recent_notes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'controller_if_id', n.controller_if_id,
               'controller_username', n.controller_username,
               'airport_icao', n.airport_icao,
               'facility_type', n.facility_type,
               'kind', n.kind,
               'note', n.note,
               'created_at', n.created_at,
               'by', public.atc_commender_label(n.user_id)
             ) order by n.created_at desc)
        from (select * from public.atc_commendations
               where not hidden and withdrawn_at is null and note is not null
               order by created_at desc limit 10) n), '[]'::jsonb),
    'recent_comments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'controller_if_id', c.controller_if_id,
               'controller_username', c.controller_username,
               'airport_icao', c.airport_icao,
               'facility_type', c.facility_type,
               'stars', c.stars,
               'comment', c.comment,
               'created_at', c.created_at,
               'anonymous', c.anonymous
             -- No "by" key at all when anonymous, rather than a null one.
             ) || case when c.anonymous then '{}'::jsonb
                       else jsonb_build_object('by', public.atc_commender_label(c.user_id)) end order by c.created_at desc)
        from (select * from public.atc_ratings
               where not hidden and stars >= 4 and comment is not null
               order by created_at desc limit 10) c), '[]'::jsonb)
  );
$function$;

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
    -- Anonymous unless the rater chose to put their name to it, and even then
    -- only the public label (atc_commender_label): never an id.
    'feedback', coalesce((
      select jsonb_agg(jsonb_build_object(
               'stars', b.stars,
               'comment', b.comment,
               'airport_icao', b.airport_icao,
               'facility_type', b.facility_type,
               'created_at', greatest(b.created_at, b.updated_at),
               'anonymous', b.anonymous
             -- No "by" key at all when anonymous, rather than a null one.
             ) || case when b.anonymous then '{}'::jsonb
                       else jsonb_build_object('by', public.atc_commender_label(b.user_id)) end order by greatest(b.created_at, b.updated_at) desc)
        from (select * from feedback
               order by greatest(created_at, updated_at) desc
               limit 20) b), '[]'::jsonb)
  );
$function$;

-- MARK: - 2. Taking words down

alter table public.pilot_content_actions alter column storage_bucket drop not null;
alter table public.pilot_content_actions alter column storage_path drop not null;
alter table public.pilot_content_actions add column if not exists content_id uuid;
-- A copy of the words that came down. The row they lived in no longer holds
-- them, and "what exactly did they write" is the first question an appeal asks.
alter table public.pilot_content_actions add column if not exists content_text text;

alter table public.pilot_content_actions drop constraint if exists pilot_content_actions_kind_check;
alter table public.pilot_content_actions add constraint pilot_content_actions_kind_check
  check (kind in ('avatar', 'banner', 'window', 'rating_comment', 'rating', 'kudos_note', 'kudos'));

/* Every rating comment and kudos note still standing, newest first, with who
 * wrote it — anonymous or not — and the author's standing, so "third
 * takedown" sits beside the words.
 */
create or replace function public.admin_pilot_comments(
  p_limit integer default 200,
  p_offset integer default 0,
  p_only_flagged boolean default false
)
returns table (
  kind text,
  id uuid,
  user_id uuid,
  handle text,
  display_name text,
  body text,
  stars smallint,
  anonymous boolean,
  is_private boolean,
  controller_if_id text,
  controller_username text,
  airport_icao text,
  written_at timestamptz,
  prior_takedowns integer,
  restricted boolean,
  restricted_until timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with words as (
    select 'rating_comment'::text as kind, r.id, r.user_id, r.comment as body, r.stars,
           r.anonymous, r.stars <= 3 as is_private,
           r.controller_if_id, r.controller_username, r.airport_icao,
           greatest(r.created_at, r.updated_at) as written_at
      from public.atc_ratings r
     where not r.hidden and r.comment is not null
    union all
    select 'kudos_note', c.id, c.user_id, c.note, null::smallint,
           false, false,
           c.controller_if_id, c.controller_username, c.airport_icao,
           greatest(c.created_at, c.updated_at)
      from public.atc_commendations c
     where not c.hidden and c.withdrawn_at is null and c.note is not null
  ),
  counted as (
    select w.*, p.handle, p.display_name,
           (select count(*)::integer from public.pilot_content_actions a
             where a.user_id = w.user_id) as prior_takedowns,
           (select until from public.pilot_upload_restriction(w.user_id)) as restricted_until,
           exists (select 1 from public.pilot_upload_restriction(w.user_id)) as restricted
      from words w
      left join public.pilot_profiles p on p.user_id = w.user_id
  )
  select c.kind, c.id, c.user_id, c.handle, c.display_name, c.body, c.stars,
         c.anonymous, c.is_private, c.controller_if_id, c.controller_username,
         c.airport_icao, c.written_at, c.prior_takedowns, c.restricted, c.restricted_until
    from counted c
   where not p_only_flagged or c.prior_takedowns > 0 or c.restricted
   order by c.written_at desc
   limit greatest(1, least(coalesce(p_limit, 200), 1000))
  offset greatest(0, coalesce(p_offset, 0));
$function$;

/* Take a comment or note down, record it, and optionally warn and pause.
 *
 * `p_kind` is 'rating' or 'kudos'. By default only the words go: the comment
 * or note is cleared and the stars or kudos keep counting, because a rude
 * sentence does not make the rating behind it untrue. `p_remove_all` hides the
 * whole row instead — for a rating that exists only to carry the abuse.
 */
create or replace function public.admin_pilot_comment_takedown(
  p_kind text,
  p_id uuid,
  p_remove_all boolean default false,
  p_category text default 'other',
  p_note text default null,
  p_removed_by text default null,
  p_warn_level text default null,
  p_warn_reason text default null,
  p_block_uploads boolean default false,
  p_block_days integer default null
)
returns table (
  warning_id uuid,
  action_id uuid
)
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_user uuid;
  v_text text;
  v_hidden boolean;
  v_handle text;
  v_kind text;
  v_warning uuid;
  v_action uuid;
  v_until timestamptz;
  v_reason text;
  v_what text;
begin
  if p_kind not in ('rating', 'kudos') then
    raise exception 'kind must be rating or kudos' using errcode = 'check_violation';
  end if;

  -- Read, then clear, holding the row across both: the same reasoning as
  -- admin_pilot_takedown, so two moderators cannot both "remove" one comment.
  if p_kind = 'rating' then
    select r.user_id, r.comment, r.hidden into v_user, v_text, v_hidden
      from public.atc_ratings r where r.id = p_id for update;
  else
    select c.user_id, c.note, c.hidden into v_user, v_text, v_hidden
      from public.atc_commendations c where c.id = p_id for update;
  end if;

  if not found then
    raise exception 'No such comment.' using errcode = 'no_data_found';
  end if;
  if v_hidden or (v_text is null and not coalesce(p_remove_all, false)) then
    raise exception 'That comment has already been removed.' using errcode = 'no_data_found';
  end if;

  if p_kind = 'rating' then
    if coalesce(p_remove_all, false) then
      update public.atc_ratings set hidden = true where id = p_id;
      v_kind := 'rating';
    else
      update public.atc_ratings set comment = null where id = p_id;
      v_kind := 'rating_comment';
    end if;
    v_what := 'a comment you left on RateMyATC';
  else
    if coalesce(p_remove_all, false) then
      update public.atc_commendations set hidden = true where id = p_id;
      v_kind := 'kudos';
    else
      update public.atc_commendations set note = null where id = p_id;
      v_kind := 'kudos_note';
    end if;
    v_what := 'a note you left with ATC kudos';
  end if;

  select p.handle into v_handle from public.pilot_profiles p where p.user_id = v_user;

  if p_warn_level is not null then
    if p_block_uploads and p_block_days is not null then
      v_until := now() + make_interval(days => greatest(1, least(p_block_days, 365)));
    end if;
    v_reason := nullif(btrim(coalesce(p_warn_reason, '')), '');
    if v_reason is null then
      v_reason := 'We removed ' || v_what || ' because it did not meet our community rules. '
               || 'Feedback is welcome; abuse is not.';
    end if;
    insert into public.pilot_warnings
      (user_id, level, reason, category, upload_block, upload_block_until, issued_by)
    values
      (v_user, p_warn_level, v_reason, nullif(p_category, 'other'),
       coalesce(p_block_uploads, false),
       case when coalesce(p_block_uploads, false) then v_until else null end,
       p_removed_by)
    returning id into v_warning;
  end if;

  insert into public.pilot_content_actions
    (user_id, handle, kind, content_id, content_text,
     category, note, removed_by, warning_id)
  values
    (v_user, v_handle, v_kind, p_id, v_text,
     coalesce(p_category, 'other'), nullif(btrim(coalesce(p_note, '')), ''),
     p_removed_by, v_warning)
  returning id into v_action;

  return query select v_warning, v_action;
end $function$;

-- The record, now with the words that came down.
drop function if exists public.admin_pilot_actions(integer, uuid);
create or replace function public.admin_pilot_actions(
  p_limit integer default 200,
  p_user_id uuid default null
)
returns table (
  id uuid,
  user_id uuid,
  handle text,
  kind text,
  storage_bucket text,
  storage_path text,
  category text,
  note text,
  removed_by text,
  warning_id uuid,
  warning_level text,
  created_at timestamptz,
  content_text text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select a.id, a.user_id, a.handle, a.kind, a.storage_bucket, a.storage_path,
         a.category, a.note, a.removed_by, a.warning_id, w.level, a.created_at,
         a.content_text
    from public.pilot_content_actions a
    left join public.pilot_warnings w on w.id = a.warning_id
   where p_user_id is null or a.user_id = p_user_id
   order by a.created_at desc
   limit greatest(1, least(coalesce(p_limit, 200), 1000));
$function$;

-- MARK: - 3. A pause covers words too

-- The notice the pilot reads, reworded now that it is about more than
-- pictures. Same shape and same empty-string contract as before.
create or replace function public.pilot_upload_notice(p_uid uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((
    select case
      when r.until is null then
        'Adding pictures and comments is paused on your account after a warning about something you posted. '
        || 'Your profile and everything else on it are untouched. '
        || 'It stays paused until we lift it — reply to the warning to get in touch.'
      else
        'Adding pictures and comments is paused on your account until '
        || to_char(r.until at time zone 'UTC', 'FMDD FMMonth YYYY')
        || ' after a warning about something you posted. '
        || 'Your profile and everything else on it are untouched.'
    end
      from public.pilot_upload_restriction(p_uid) r
  ), '');
$function$;

/* Refuse new words from a paused pilot.
 *
 * A trigger rather than a check in atc_rate/atc_commend so the two writers,
 * and any written later, cannot disagree. Only pilot writes are checked
 * (auth.uid() is set); the service role clearing a comment passes untouched.
 * Unchanged text passes too, so a paused pilot can still change their stars.
 */
create or replace function public.pilot_words_paused_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  -- One function for two tables whose text columns differ in name; read
  -- through jsonb so neither table's missing column is ever referenced.
  v_col text := case TG_TABLE_NAME when 'atc_ratings' then 'comment' else 'note' end;
  v_new text := to_jsonb(new) ->> v_col;
begin
  if auth.uid() is null or v_new is null then
    return new;
  end if;
  if TG_OP = 'UPDATE' and (to_jsonb(old) ->> v_col) is not distinct from v_new then
    return new;
  end if;
  if exists (select 1 from public.pilot_upload_restriction(new.user_id)) then
    raise exception '%', public.pilot_upload_notice(new.user_id)
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $function$;

revoke all on function public.pilot_words_paused_guard() from public, anon, authenticated;

drop trigger if exists atc_ratings_words_paused on public.atc_ratings;
create trigger atc_ratings_words_paused
  before insert or update of comment on public.atc_ratings
  for each row execute function public.pilot_words_paused_guard();

drop trigger if exists atc_commendations_words_paused on public.atc_commendations;
create trigger atc_commendations_words_paused
  before insert or update of note on public.atc_commendations
  for each row execute function public.pilot_words_paused_guard();

-- MARK: - 4. The queue staff are told from

create table if not exists public.pilot_content_queue (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users (id) on delete cascade,
  kind text not null check (kind in
    ('avatar', 'banner', 'window', 'handle', 'display_name', 'bio', 'rating_comment', 'kudos_note')),
  -- The rating or kudos row, for words; null for profile fields.
  content_id uuid,
  body text,
  storage_bucket text,
  storage_path text,
  -- Context for the message: stars, controller, airport, private/anonymous.
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  posted_at timestamptz
);

create index if not exists pilot_content_queue_pending_idx
  on public.pilot_content_queue (id) where posted_at is null;

comment on table public.pilot_content_queue is
  'Everything pilots put on the platform, as it arrives, for the staff hub to post to Discord. Written by triggers, drained by admin_pilot_content_queue / _ack. Service role only.';

alter table public.pilot_content_queue enable row level security;
revoke all on public.pilot_content_queue from anon, authenticated;

-- Security definer because it runs inside a pilot's own write, and the queue
-- has no policies a pilot could insert under.
create or replace function public.pilot_content_enqueue_profile()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ins boolean := TG_OP = 'INSERT';
begin
  if new.avatar_path is not null and (v_ins or new.avatar_path is distinct from old.avatar_path) then
    insert into public.pilot_content_queue (user_id, kind, storage_bucket, storage_path)
    values (new.user_id, 'avatar', 'pilot-avatars', new.avatar_path);
  end if;
  if new.banner_path is not null and (v_ins or new.banner_path is distinct from old.banner_path) then
    insert into public.pilot_content_queue (user_id, kind, storage_bucket, storage_path)
    values (new.user_id, 'banner', 'pilot-banners', new.banner_path);
  end if;
  if new.window_bg_path is not null and (v_ins or new.window_bg_path is distinct from old.window_bg_path) then
    insert into public.pilot_content_queue (user_id, kind, storage_bucket, storage_path)
    values (new.user_id, 'window', 'pilot-banners', new.window_bg_path);
  end if;
  if new.handle is not null and (v_ins or new.handle is distinct from old.handle) then
    insert into public.pilot_content_queue (user_id, kind, body) values (new.user_id, 'handle', new.handle);
  end if;
  if nullif(btrim(coalesce(new.display_name, '')), '') is not null
     and (v_ins or new.display_name is distinct from old.display_name) then
    insert into public.pilot_content_queue (user_id, kind, body) values (new.user_id, 'display_name', new.display_name);
  end if;
  if nullif(btrim(coalesce(new.bio, '')), '') is not null
     and (v_ins or new.bio is distinct from old.bio) then
    insert into public.pilot_content_queue (user_id, kind, body) values (new.user_id, 'bio', new.bio);
  end if;
  return null;
end $function$;

create or replace function public.pilot_content_enqueue_words()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rating boolean := TG_TABLE_NAME = 'atc_ratings';
  v_row jsonb := to_jsonb(new);
  v_col text := case when v_rating then 'comment' else 'note' end;
  v_new text := v_row ->> v_col;
begin
  if v_new is null then
    return null;
  end if;
  if TG_OP = 'UPDATE' and (to_jsonb(old) ->> v_col) is not distinct from v_new then
    return null;
  end if;
  insert into public.pilot_content_queue (user_id, kind, content_id, body, detail)
  values (
    new.user_id,
    case when v_rating then 'rating_comment' else 'kudos_note' end,
    new.id,
    v_new,
    jsonb_strip_nulls(jsonb_build_object(
      'controller_username', v_row ->> 'controller_username',
      'controller_if_id', v_row ->> 'controller_if_id',
      'airport_icao', v_row ->> 'airport_icao',
      'facility_type', (v_row ->> 'facility_type')::integer,
      'stars', (v_row ->> 'stars')::integer,
      'private', case when v_rating then (v_row ->> 'stars')::integer <= 3 end,
      'anonymous', (v_row ->> 'anonymous')::boolean,
      'kudos_kind', case when not v_rating then v_row ->> 'kind' end))
  );
  return null;
end $function$;

revoke all on function public.pilot_content_enqueue_profile() from public, anon, authenticated;
revoke all on function public.pilot_content_enqueue_words() from public, anon, authenticated;

drop trigger if exists pilot_profiles_content_queue on public.pilot_profiles;
create trigger pilot_profiles_content_queue
  after insert or update on public.pilot_profiles
  for each row execute function public.pilot_content_enqueue_profile();

drop trigger if exists atc_ratings_content_queue on public.atc_ratings;
create trigger atc_ratings_content_queue
  after insert or update of comment on public.atc_ratings
  for each row execute function public.pilot_content_enqueue_words();

drop trigger if exists atc_commendations_content_queue on public.atc_commendations;
create trigger atc_commendations_content_queue
  after insert or update of note on public.atc_commendations
  for each row execute function public.pilot_content_enqueue_words();

/* The next items to announce, oldest first, with who posted them.
 *
 * Does not mark anything: the caller acknowledges what it actually delivered,
 * so a Discord outage delays the message rather than losing it. Only the last
 * seven days are offered — a backlog older than that is history, not news.
 */
create or replace function public.admin_pilot_content_queue(p_limit integer default 25)
returns table (
  id bigint,
  user_id uuid,
  handle text,
  display_name text,
  kind text,
  content_id uuid,
  body text,
  storage_bucket text,
  storage_path text,
  detail jsonb,
  created_at timestamptz,
  prior_takedowns integer,
  restricted boolean
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select q.id, q.user_id, p.handle, p.display_name, q.kind, q.content_id, q.body,
         q.storage_bucket, q.storage_path, q.detail, q.created_at,
         (select count(*)::integer from public.pilot_content_actions a where a.user_id = q.user_id),
         exists (select 1 from public.pilot_upload_restriction(q.user_id))
    from public.pilot_content_queue q
    left join public.pilot_profiles p on p.user_id = q.user_id
   where q.posted_at is null
     and q.created_at > now() - interval '7 days'
   order by q.id
   limit greatest(1, least(coalesce(p_limit, 25), 100));
$function$;

-- Mark delivered, and sweep: delivered rows after 30 days, undelivered ones
-- after the 7 days they are offered for.
create or replace function public.admin_pilot_content_queue_ack(p_ids bigint[])
returns integer
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_n integer;
begin
  update public.pilot_content_queue
     set posted_at = now()
   where id = any (coalesce(p_ids, '{}')) and posted_at is null;
  get diagnostics v_n = row_count;

  delete from public.pilot_content_queue
   where (posted_at is not null and posted_at < now() - interval '30 days')
      or (posted_at is null and created_at < now() - interval '7 days');

  return v_n;
end $function$;

-- MARK: - Grants

revoke all on function public.atc_rate(text, text, text, integer, timestamptz, integer, text, boolean) from public, anon;
grant execute on function public.atc_rate(text, text, text, integer, timestamptz, integer, text, boolean) to authenticated;

revoke all on function public.admin_pilot_comments(integer, integer, boolean) from public, anon, authenticated;
revoke all on function public.admin_pilot_comment_takedown(text, uuid, boolean, text, text, text, text, text, boolean, integer) from public, anon, authenticated;
revoke all on function public.admin_pilot_actions(integer, uuid) from public, anon, authenticated;
revoke all on function public.admin_pilot_content_queue(integer) from public, anon, authenticated;
revoke all on function public.admin_pilot_content_queue_ack(bigint[]) from public, anon, authenticated;
revoke all on function public.pilot_upload_notice(uuid) from public, anon, authenticated;

grant execute on function public.admin_pilot_comments(integer, integer, boolean) to service_role;
grant execute on function public.admin_pilot_comment_takedown(text, uuid, boolean, text, text, text, text, text, boolean, integer) to service_role;
grant execute on function public.admin_pilot_actions(integer, uuid) to service_role;
grant execute on function public.admin_pilot_content_queue(integer) to service_role;
grant execute on function public.admin_pilot_content_queue_ack(bigint[]) to service_role;
grant execute on function public.pilot_upload_notice(uuid) to service_role;
