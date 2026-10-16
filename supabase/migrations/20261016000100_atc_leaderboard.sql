-- RateMyATC board: who pilots rate highest and thank most.
--
-- One function, three ranked lists, so the board's tabs switch without a
-- round trip:
--
--   top_rated   ranked by a Bayesian average, so one 5★ rating cannot beat
--               forty 4.9★ ones. Each controller's stars are blended with the
--               board-wide average as if they had 5 extra ratings at that
--               average. Needs at least 3 ratings to appear.
--   most_kudos  ranked by kudos count.
--   most_rated  ranked by number of ratings.
--
-- Everything here is already public through atc_rating_profile and
-- atc_commendation_profile; this only aggregates it. Low-star comments are not
-- touched at all — only star numbers are read from atc_ratings.

create or replace function public.atc_leaderboard(
  p_days integer default 30,
  p_limit integer default 25
)
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
  lim as (
    select least(greatest(coalesce(p_limit, 25), 1), 100) as n
  ),
  r as (
    select x.controller_if_id, count(*) as n, avg(x.stars)::numeric as a, sum(x.stars) as s
      from public.atc_ratings x, since
     where not x.hidden and x.created_at >= since.t
     group by x.controller_if_id
  ),
  k as (
    select x.controller_if_id, count(*) as n,
           count(*) filter (where x.kind = 'thumbs_up') as tu,
           count(*) filter (where x.kind = 'good_day') as gd
      from public.atc_commendations x, since
     where not x.hidden and x.withdrawn_at is null and x.created_at >= since.t
     group by x.controller_if_id
  ),
  g as (
    select coalesce((select sum(s)::numeric / nullif(sum(n), 0) from r), 4.0) as m
  ),
  latest as (
    select distinct on (y.controller_if_id)
           y.controller_if_id, y.controller_username, y.airport_icao, y.created_at
      from (
        select controller_if_id, controller_username, airport_icao, created_at
          from public.atc_ratings where not hidden and controller_username is not null
        union all
        select controller_if_id, controller_username, airport_icao, created_at
          from public.atc_commendations
         where not hidden and withdrawn_at is null and controller_username is not null
      ) y
     order by y.controller_if_id, y.created_at desc
  ),
  board as (
    select ids.controller_if_id,
           l.controller_username as username,
           l.airport_icao as last_airport,
           l.created_at as last_at,
           coalesce(r.n, 0)::integer as rating_count,
           round(r.a, 2) as rating_avg,
           round(((r.s + 5 * g.m) / (r.n + 5))::numeric, 3) as score,
           coalesce(k.n, 0)::integer as kudos,
           coalesce(k.tu, 0)::integer as thumbs_up,
           coalesce(k.gd, 0)::integer as good_day
      from (select controller_if_id from r union select controller_if_id from k) ids
      cross join g
      left join r on r.controller_if_id = ids.controller_if_id
      left join k on k.controller_if_id = ids.controller_if_id
      left join latest l on l.controller_if_id = ids.controller_if_id
  ),
  row_json as (
    select b.*, jsonb_build_object(
             'controller_if_id', b.controller_if_id,
             'username', b.username,
             'last_airport', b.last_airport,
             'last_at', b.last_at,
             'rating_avg', b.rating_avg,
             'rating_count', b.rating_count,
             'kudos', b.kudos,
             'thumbs_up', b.thumbs_up,
             'good_day', b.good_day) as j
      from board b
  )
  select jsonb_build_object(
    'days', case when coalesce(p_days, 0) <= 0 then null else least(p_days, 3650) end,
    'board_avg', (select round(m, 2) from g),
    'controllers', (select count(*) from board),
    'ratings', (select coalesce(sum(n), 0) from r),
    'kudos', (select coalesce(sum(n), 0) from k),
    'top_rated', coalesce((
      select jsonb_agg(t.j order by t.score desc, t.rating_count desc, t.controller_if_id)
        from (select * from row_json where rating_count >= 3
               order by score desc, rating_count desc, controller_if_id
               limit (select n from lim)) t), '[]'::jsonb),
    'most_kudos', coalesce((
      select jsonb_agg(t.j order by t.kudos desc, t.rating_avg desc nulls last, t.controller_if_id)
        from (select * from row_json where kudos > 0
               order by kudos desc, rating_avg desc nulls last, controller_if_id
               limit (select n from lim)) t), '[]'::jsonb),
    'most_rated', coalesce((
      select jsonb_agg(t.j order by t.rating_count desc, t.rating_avg desc nulls last, t.controller_if_id)
        from (select * from row_json where rating_count > 0
               order by rating_count desc, rating_avg desc nulls last, controller_if_id
               limit (select n from lim)) t), '[]'::jsonb)
  );
$function$;

revoke all on function public.atc_leaderboard(integer, integer) from public;
grant execute on function public.atc_leaderboard(integer, integer) to anon, authenticated;
