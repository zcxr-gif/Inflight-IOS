-- Who the platform is watching.
--
-- Every profile card has carried `follower_count` since follows existed, and
-- there has never been a query that asked the obvious next question: which
-- pilots have the most of them. This is that query, and it is one function
-- rather than three because the three tabs it feeds are the same ranking asked
-- three ways -- all time, the last few days, and only the pilots who are
-- actually flying. Splitting them would be three chances for the copy on a tab
-- and the ordering behind it to drift apart.
--
-- Counted on demand from `pilot_follows` rather than kept as a column. A stored
-- count is a trigger on both ends of every follow, a backfill the day the rule
-- changes, and a number that can be wrong; this is a grouped aggregate over an
-- index that already exists for the other direction of the same question. If
-- the follow graph ever gets big enough for that to hurt, the escape hatch is a
-- materialised view refreshed by `housekeeping()` -- not a counter column.
--
-- The visibility rule is the profile's own, unchanged: `pilot_profile_visible`
-- is what decides whether a pilot may be listed at all, so a private profile,
-- an auto-hidden one, or one whose owner has blocked the reader is absent from
-- the board exactly as it is absent from search. That matters more here than
-- elsewhere, because a leaderboard is the one screen that goes looking for
-- people the reader never asked about.

create or replace function public.pilot_most_watched(
  p_scope text default 'all',
  p_window_days integer default 7,
  p_limit integer default 10
)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  if_username text,
  is_pro boolean,
  follower_count integer,
  new_followers integer,
  is_flying boolean,
  viewer_follows boolean,
  is_self boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_scope  text := lower(btrim(coalesce(p_scope, 'all')));
  v_days   integer := least(greatest(coalesce(p_window_days, 7), 1), 365);
  v_limit  integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_since  timestamptz;
begin
  -- An unknown scope is the whole board rather than an error. This is read by
  -- a picker in a shipped app, and a client one version ahead of the database
  -- should show a sensible list instead of an empty one with a failure behind
  -- it.
  if v_scope not in ('all', 'rising', 'flying') then
    v_scope := 'all';
  end if;

  v_since := now() - make_interval(days => v_days);

  return query
  with counted as (
    -- Both numbers in one pass. The window count is a filtered aggregate rather
    -- than a second join, so `rising` costs the same as `all` and every row can
    -- carry "and this many of them this week" whichever tab asked for it.
    select f.following_id as user_id,
           count(*)::integer as total,
           count(*) filter (where f.created_at >= v_since)::integer as recent
      from public.pilot_follows f
     group by f.following_id
  )
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         p.if_username,
         public.is_pro_account(p.user_id),
         c.total,
         c.recent,
         coalesce(l.readable, false),
         (v_viewer is not null and exists (
            select 1
              from public.pilot_follows vf
             where vf.follower_id = v_viewer
               and vf.following_id = p.user_id)),
         p.user_id is not distinct from v_viewer
    from counted c
    join public.pilot_profiles p on p.user_id = c.user_id
    -- Flying is two conditions, and the second one is a permission. A row
    -- inside the live TTL says the simulator is reporting; `pilot_live_readable`
    -- says this reader is allowed to know that. Answering only the first would
    -- turn a followers-only live status into a public online indicator, which
    -- is the same leak the live functions were written to avoid -- so the check
    -- is the same function they use, not a copy of its conditions.
    left join lateral (
      select public.pilot_live_readable(p, v_viewer) as readable
        from public.pilot_live_status s
       where s.user_id = p.user_id
         and s.last_live_at > now() - public.live_status_ttl()
       limit 1
    ) l on true
   where public.pilot_profile_visible(p, v_viewer)
     and (v_scope <> 'flying' or coalesce(l.readable, false))
     -- Nobody joins a "rising" board on nought new followers. On the all-time
     -- board a long-standing count is the point, so it is not filtered there.
     and (v_scope <> 'rising' or c.recent > 0)
   order by
     case when v_scope = 'rising' then c.recent else c.total end desc,
     -- The all-time count breaks a tie on the window, and the handle breaks a
     -- tie on both: without a total order the rows shuffle between refreshes of
     -- the same unchanged board.
     c.total desc,
     p.handle asc
   limit v_limit;
end $function$;

comment on function public.pilot_most_watched(text, integer, integer) is
  'The most-followed pilots, by scope: all time, new followers inside the window, or only those whose simulator is reporting to a reader allowed to see it. Counted from pilot_follows on demand; obeys the same visibility rule as the profile card.';

-- Readable signed out, for the same reason `pilot_directory_search` and
-- `pilot_recent_landings` are: every row on this board is a public profile, and
-- `pilot_profile_card` already serves a follower count for each of them to
-- anonymous readers. What a signed-out reader loses is the two columns that are
-- about *them* -- `viewer_follows` is false and `is_self` is false throughout --
-- and any pilot whose live status is followers-only, who is simply not flying
-- as far as that reader is concerned.
revoke all on function public.pilot_most_watched(text, integer, integer) from public;
grant execute on function public.pilot_most_watched(text, integer, integer) to anon;
grant execute on function public.pilot_most_watched(text, integer, integer) to authenticated;
