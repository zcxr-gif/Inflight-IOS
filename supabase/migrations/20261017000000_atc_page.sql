-- The ATC page (inflight.info/atc): finding a controller by name, and the
-- numbers for the page as a whole.
--
-- Both are public, like atc_leaderboard. Neither reads anything the existing
-- readers do not already show: star numbers, kudos counts, public kudos notes
-- and comments on 4–5★ ratings. Comments on 1–3★ ratings stay where they were,
-- in atc_kudos_inbox, for the controller alone. Raters are named only through
-- atc_commender_label, so only pilots with a public profile in good standing.

-- MARK: - Finding a controller

-- Controllers whose Infinite Flight name matches, best match first: an exact
-- name, then names that start with the query, then names that contain it.
-- The share link inflight.info/atc/<name> takes the first exact match.
--
-- A name is matched on what pilots filed against it. Someone who renamed in
-- Infinite Flight shows under their newest name, because each controller is
-- listed once, under the name on their latest kudos or rating.
create or replace function public.atc_controller_search(
  p_query text,
  p_limit integer default 10
)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with q as (
    select lower(btrim(coalesce(p_query, ''))) as t,
           least(greatest(coalesce(p_limit, 10), 1), 50) as n
  ),
  named as (
    select controller_if_id, controller_username, airport_icao, created_at
      from public.atc_ratings where not hidden and controller_username is not null
    union all
    select controller_if_id, controller_username, airport_icao, created_at
      from public.atc_commendations
     where not hidden and withdrawn_at is null and controller_username is not null
  ),
  latest as (
    select distinct on (controller_if_id)
           controller_if_id, controller_username as username, airport_icao as last_airport, created_at as last_at
      from named
     order by controller_if_id, created_at desc
  ),
  hits as (
    select l.*,
           case when lower(l.username) = q.t then 0
                when lower(l.username) like q.t || '%' then 1
                else 2 end as rank
      from latest l, q
     where length(q.t) >= 2
       and (lower(l.username) like '%' || replace(replace(replace(q.t, '\', '\\'), '%', '\%'), '_', '\_') || '%'
            or l.controller_if_id = btrim(p_query))
  ),
  scored as (
    select h.*,
           (select round(avg(r.stars), 1) from public.atc_ratings r
             where r.controller_if_id = h.controller_if_id and not r.hidden) as rating_avg,
           (select count(*) from public.atc_ratings r
             where r.controller_if_id = h.controller_if_id and not r.hidden)::integer as rating_count,
           (select count(*) from public.atc_commendations c
             where c.controller_if_id = h.controller_if_id and not c.hidden and c.withdrawn_at is null)::integer as kudos
      from hits h
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'controller_if_id', s.controller_if_id,
           'username', s.username,
           'last_airport', s.last_airport,
           'last_at', s.last_at,
           'rating_avg', s.rating_avg,
           'rating_count', s.rating_count,
           'kudos', s.kudos
         ) order by s.rank, s.rating_count + s.kudos desc, s.username), '[]'::jsonb)
    from (select * from scored order by rank, rating_count + kudos desc, username
           limit (select n from q)) s;
$function$;

revoke all on function public.atc_controller_search(text, integer) from public;
grant execute on function public.atc_controller_search(text, integer) to anon, authenticated;

-- MARK: - The page's numbers

-- Totals, where it happens, by position, a day-by-day count, and the latest
-- public words. `p_days` of 0 is all time; the day-by-day series is always the
-- last 30 days.
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
               'by', public.atc_commender_label(c.user_id)
             ) order by c.created_at desc)
        from (select * from public.atc_ratings
               where not hidden and stars >= 4 and comment is not null
               order by created_at desc limit 10) c), '[]'::jsonb)
  );
$function$;

revoke all on function public.atc_site_stats(integer) from public;
grant execute on function public.atc_site_stats(integer) to anon, authenticated;
