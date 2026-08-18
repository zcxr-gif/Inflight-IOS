-- Following, and what a friend is.
--
-- One relationship in the table, two in the product:
--
--   * a FOLLOW is one-way and needs nobody's permission. You follow a pilot
--     because you want to know when they are flying; they need not care.
--   * a FRIEND is a follow that is returned. There is no request, no accept
--     and no pending state, because a mutual follow already carries the only
--     information an accept would: both people chose this.
--
-- That choice is the whole design. A request/accept flow needs a third state,
-- a notification for it, a way to withdraw it, a way to re-request, and a rule
-- for what a rejected request means the second time. Mutual-follow needs a
-- unique index. Every friends list in this schema is the same self-join, and
-- there is no way for the two halves to disagree about whether two people are
-- friends.
--
-- The graph is NOT readable row by row. A client can read the follows it is one
-- end of, and nothing else; every public view of the graph goes through the
-- functions at the bottom of this file, which apply the profile's own
-- visibility rules and drop anybody who has been blocked. Handing PostgREST a
-- publicly selectable edge table would mean `?select=*` returns the entire
-- social graph of every private account on the platform.

create table if not exists public.pilot_follows (
  follower_id uuid not null references auth.users (id) on delete cascade,
  following_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint pilot_follows_not_self check (follower_id <> following_id)
);

-- Following a pilot is answered by the primary key. "Who follows this pilot"
-- is the other direction and is the one every profile view asks.
create index if not exists pilot_follows_following_idx
  on public.pilot_follows (following_id, created_at desc);

create index if not exists pilot_follows_follower_idx
  on public.pilot_follows (follower_id, created_at desc);

comment on table public.pilot_follows is
  'One-way follows. A mutual pair is a friendship; there is no separate friends table. Read publicly only through pilot_profile_* functions.';

-- MARK: - What a follow has to satisfy
--
-- In a trigger rather than in the RPC below, so that inserting straight into
-- PostgREST is guarded exactly as tightly as calling the function is. Anything
-- checked only in the convenience wrapper is not checked at all.

create or replace function public.pilot_follows_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_target public.pilot_profiles%rowtype;
  v_count  integer;
begin
  select * into v_target
    from public.pilot_profiles p
   where p.user_id = new.following_id;

  -- Nothing to follow. A profile is the thing being followed, not an account:
  -- somebody who has never claimed a handle has nothing for a follower to look
  -- at and no way to know they have one.
  if v_target.user_id is null then
    raise exception 'That pilot has no profile to follow.'
      using errcode = 'foreign_key_violation';
  end if;

  if not v_target.is_public or v_target.moderation_state <> 'ok' then
    raise exception 'That profile is not public.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Blocks are checked BOTH ways. A block stops the blocked account following
  -- the blocker, which is the point; it also stops the blocker following the
  -- account they blocked, because following somebody you have blocked is a
  -- state with no meaning and it would show them in your own friends list.
  if exists (
    select 1 from public.pilot_blocks b
     where (b.blocker_id = new.following_id and b.blocked_id = new.follower_id)
        or (b.blocker_id = new.follower_id and b.blocked_id = new.following_id)
  ) then
    raise exception 'That pilot cannot be followed.'
      using errcode = 'insufficient_privilege';
  end if;

  -- A ceiling, not a feature. Following is free and unlimited as far as anyone
  -- using the app is concerned; this is the number past which an account is a
  -- script rather than a person, and it exists so one can be stopped.
  select count(*) into v_count
    from public.pilot_follows f
   where f.follower_id = new.follower_id;

  if v_count >= 5000 then
    raise exception 'You are following as many pilots as one account can.'
      using errcode = 'check_violation';
  end if;

  return new;
end $function$;

drop trigger if exists pilot_follows_guard on public.pilot_follows;
create trigger pilot_follows_guard
  before insert on public.pilot_follows
  for each row execute function public.pilot_follows_guard();

-- MARK: - Row-level security

-- Supabase's default privileges usually cover a new table in `public`, but a
-- migration that relies on them is a migration that breaks silently on a
-- project where they were ever narrowed. RLS is the access control; these are
-- what let the policies be reached at all.
grant select, insert, delete on public.pilot_follows to authenticated;

alter table public.pilot_follows enable row level security;

-- Only the two people an edge is about can read it directly. Everything public
-- is served by the functions below.
drop policy if exists "Pilots read follows they are part of" on public.pilot_follows;
create policy "Pilots read follows they are part of"
  on public.pilot_follows for select
  to authenticated
  using (auth.uid() = follower_id or auth.uid() = following_id);

drop policy if exists "Pilots follow as themselves" on public.pilot_follows;
create policy "Pilots follow as themselves"
  on public.pilot_follows for insert
  to authenticated
  with check (auth.uid() = follower_id);

-- Either end may break the edge: you can stop following, and you can remove a
-- follower. The second is what stops "block them" being the only way to get
-- somebody off your profile.
drop policy if exists "Pilots unfollow, and remove followers" on public.pilot_follows;
create policy "Pilots unfollow, and remove followers"
  on public.pilot_follows for delete
  to authenticated
  using (auth.uid() = follower_id or auth.uid() = following_id);

-- Blocking somebody severs the follow in both directions. Doing it here rather
-- than in the client means it is true however the block was made.
create or replace function public.pilot_blocks_sever_follows()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  delete from public.pilot_follows f
   where (f.follower_id = new.blocker_id and f.following_id = new.blocked_id)
      or (f.follower_id = new.blocked_id and f.following_id = new.blocker_id);
  return new;
end $function$;

drop trigger if exists pilot_blocks_sever_follows on public.pilot_blocks;
create trigger pilot_blocks_sever_follows
  after insert on public.pilot_blocks
  for each row execute function public.pilot_blocks_sever_follows();

-- MARK: - Reading a profile the way a stranger sees it
--
-- `security definer`, and granted to anon as well as authenticated, because the
-- website serves these to people who have never signed in. Every one of them
-- re-derives visibility itself rather than leaning on RLS: they run as the
-- owner, so RLS is not applied to what they read, and the checks below ARE the
-- access control. Each starts from `pilot_profiles_visible_to`, so there is one
-- definition of "may this person see this profile" and not five.

create or replace function public.pilot_profile_visible(
  p_profile public.pilot_profiles,
  p_viewer uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- `coalesce(..., false)` and `is not distinct from` are not belt and braces
  -- here, they are the whole correctness of the function. `p_viewer` is NULL
  -- for every signed-out reader -- which is most of them, because these
  -- profiles are served to the open web -- and `user_id = NULL` is NULL, not
  -- false. An expression that evaluates to NULL then meets `if not ... then
  -- return; end if` in the callers, `not NULL` is NULL, the guard does not
  -- fire, and a private profile is served to exactly the people it was hidden
  -- from. Every comparison against `p_viewer` in this schema is null-safe for
  -- that reason.
  select coalesce(
    p_profile.user_id is not null
    and (
      -- Your own profile is always visible to you, hidden or not.
      p_profile.user_id is not distinct from p_viewer
      or (
        p_profile.is_public
        and p_profile.moderation_state = 'ok'
        -- Reports are read here rather than written into `moderation_state`;
        -- see `profile_is_autohidden`.
        and not public.profile_is_autohidden(p_profile.user_id)
        and not exists (
          select 1 from public.pilot_blocks b
           where b.blocker_id = p_profile.user_id
             and b.blocked_id is not distinct from p_viewer
        )
      )
    ), false);
$function$;

-- The shape every list of pilots comes back in.
--
-- A composite type rather than five functions each with their own column list:
-- the friends list, the followers list and a search result are the same thing
-- drawn the same way, and a column added to one has to appear in all three.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'pilot_summary') then
    create type public.pilot_summary as (
      handle text,
      display_name text,
      avatar_path text,
      if_username text,
      favourite_aircraft text,
      home_airport text,
      -- The Pro badge. It is the only thing about anybody's billing that is
      -- ever public, it is a boolean, and a badge nobody else can see is not
      -- a badge.
      is_pro boolean
    );
  end if;
end $$;

-- MARK: - The profile card

create or replace function public.pilot_profile_card(p_handle text)
returns table (
  handle text,
  display_name text,
  bio text,
  avatar_path text,
  banner_path text,
  banner_preset text,
  accent text,
  if_username text,
  if_username_verified boolean,
  favourite_aircraft text,
  favourite_livery text,
  home_airport text,
  is_pro boolean,
  friends_visibility text,
  follower_count integer,
  following_count integer,
  friend_count integer,
  joined_at timestamptz,
  viewer_follows boolean,
  follows_viewer boolean,
  is_friend boolean,
  is_self boolean,
  viewer_blocked boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
  v_pro boolean;
begin
  select * into v_p
    from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  -- One answer for "no such handle" and for "you may not see this one".
  -- Distinguishing them would turn this function into a way to enumerate who
  -- has blocked you and which handles are taken by private accounts.
  if not public.pilot_profile_visible(v_p, v_viewer) then
    return;
  end if;

  v_pro := public.is_pro_account(v_p.user_id);

  return query
  select
    v_p.handle,
    coalesce(v_p.display_name, v_p.handle),
    v_p.bio,
    v_p.avatar_path,
    -- The Pro columns are honoured only while Pro is. The values stay in the
    -- row -- a lapsed subscription does not delete the banner somebody made --
    -- but they stop being served, and come back the day the subscription does.
    -- This is the same rule the app applies to a Pro map style, in the one
    -- place a lapsed account cannot argue with it.
    case when v_pro then v_p.banner_path else null end,
    v_p.banner_preset,
    case when v_pro then v_p.accent else null end,
    v_p.if_username,
    v_p.if_username_verified,
    v_p.favourite_aircraft,
    v_p.favourite_livery,
    v_p.home_airport,
    v_pro,
    v_p.friends_visibility,
    (select count(*)::integer from public.pilot_follows f
      where f.following_id = v_p.user_id),
    (select count(*)::integer from public.pilot_follows f
      where f.follower_id = v_p.user_id),
    (select count(*)::integer from public.pilot_follows a
       join public.pilot_follows b
         on b.follower_id = a.following_id and b.following_id = a.follower_id
      where a.follower_id = v_p.user_id),
    v_p.created_at,
    v_viewer is not null and exists (
      select 1 from public.pilot_follows f
       where f.follower_id = v_viewer and f.following_id = v_p.user_id),
    v_viewer is not null and exists (
      select 1 from public.pilot_follows f
       where f.follower_id = v_p.user_id and f.following_id = v_viewer),
    v_viewer is not null and exists (
      select 1 from public.pilot_follows a
       where a.follower_id = v_viewer and a.following_id = v_p.user_id)
      and exists (
      select 1 from public.pilot_follows b
       where b.follower_id = v_p.user_id and b.following_id = v_viewer),
    v_viewer = v_p.user_id,
    v_viewer is not null and exists (
      select 1 from public.pilot_blocks b
       where b.blocker_id = v_viewer and b.blocked_id = v_p.user_id);
end $function$;

grant execute on function public.pilot_profile_card(text) to anon, authenticated;

-- The same card, found from the name on an aeroplane.
--
-- This is what turns a tapped sprite into a person. Unverified, so the caller
-- gets `if_username_verified` back and is expected to say "claims to be".
-- Oldest claim wins when two profiles name the same pilot: it is the least
-- rewarding rule for somebody who has just noticed a well-known handle is
-- unclaimed here.
create or replace function public.pilot_profile_by_if_username(p_username text)
returns table (
  handle text,
  display_name text,
  bio text,
  avatar_path text,
  banner_path text,
  banner_preset text,
  accent text,
  if_username text,
  if_username_verified boolean,
  favourite_aircraft text,
  favourite_livery text,
  home_airport text,
  is_pro boolean,
  friends_visibility text,
  follower_count integer,
  following_count integer,
  friend_count integer,
  joined_at timestamptz,
  viewer_follows boolean,
  follows_viewer boolean,
  is_friend boolean,
  is_self boolean,
  viewer_blocked boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_handle text;
begin
  select p.handle into v_handle
    from public.pilot_profiles p
   where lower(p.if_username) = lower(btrim(coalesce(p_username, '')))
     and p.is_public
     and p.moderation_state = 'ok'
   order by p.created_at asc
   limit 1;

  if v_handle is null then return; end if;

  return query select * from public.pilot_profile_card(v_handle);
end $function$;

grant execute on function public.pilot_profile_by_if_username(text) to anon, authenticated;

-- MARK: - The lists
--
-- Friends first, because it is the one that is shown by default and the one
-- with a visibility setting of its own.

create or replace function public.pilot_profile_friends(
  p_handle text,
  p_limit integer default 60
)
returns setof public.pilot_summary
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
begin
  select * into v_p from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if not public.pilot_profile_visible(v_p, v_viewer) then return; end if;

  -- The friends list is other people's names, so it has a control the rest of
  -- the profile does not.
  if v_p.friends_visibility = 'private' and v_viewer is distinct from v_p.user_id then
    return;
  end if;

  if v_p.friends_visibility = 'followers' and v_viewer is distinct from v_p.user_id then
    if v_viewer is null or not exists (
      select 1 from public.pilot_follows f
       where f.follower_id = v_viewer and f.following_id = v_p.user_id
    ) then
      return;
    end if;
  end if;

  return query
  select fp.handle,
         coalesce(fp.display_name, fp.handle),
         fp.avatar_path,
         fp.if_username,
         fp.favourite_aircraft,
         fp.home_airport,
         public.is_pro_account(fp.user_id)
    from public.pilot_follows a
    join public.pilot_follows b
      on b.follower_id = a.following_id and b.following_id = a.follower_id
    join public.pilot_profiles fp on fp.user_id = a.following_id
   where a.follower_id = v_p.user_id
     -- A friend whose own profile has gone private or been hidden drops off
     -- everybody else's list at the same moment it stops being readable.
     and fp.is_public
     and fp.moderation_state = 'ok'
     and not exists (
       select 1 from public.pilot_blocks bl
        where bl.blocker_id = fp.user_id and bl.blocked_id = v_viewer)
   order by greatest(a.created_at, b.created_at) desc
   limit least(greatest(coalesce(p_limit, 60), 1), 200);
end $function$;

grant execute on function public.pilot_profile_friends(text, integer) to anon, authenticated;

-- Followers and following, one function with a direction rather than two
-- functions that would drift apart.
create or replace function public.pilot_profile_connections(
  p_handle text,
  p_direction text default 'followers',
  p_limit integer default 60,
  p_offset integer default 0
)
returns setof public.pilot_summary
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
  v_dir text := lower(coalesce(p_direction, 'followers'));
begin
  if v_dir not in ('followers', 'following') then
    raise exception 'Direction must be followers or following.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_p from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if not public.pilot_profile_visible(v_p, v_viewer) then return; end if;

  return query
  select fp.handle,
         coalesce(fp.display_name, fp.handle),
         fp.avatar_path,
         fp.if_username,
         fp.favourite_aircraft,
         fp.home_airport,
         public.is_pro_account(fp.user_id)
    from (
      select case when v_dir = 'followers' then f.follower_id else f.following_id end as uid,
             f.created_at
        from public.pilot_follows f
       where (v_dir = 'followers' and f.following_id = v_p.user_id)
          or (v_dir = 'following' and f.follower_id = v_p.user_id)
    ) other
    join public.pilot_profiles fp on fp.user_id = other.uid
   where fp.is_public
     and fp.moderation_state = 'ok'
     and not exists (
       select 1 from public.pilot_blocks bl
        where bl.blocker_id = fp.user_id and bl.blocked_id = v_viewer)
   order by other.created_at desc
   limit least(greatest(coalesce(p_limit, 60), 1), 200)
  offset greatest(coalesce(p_offset, 0), 0);
end $function$;

grant execute on function public.pilot_profile_connections(text, text, integer, integer)
  to anon, authenticated;

-- Whether a handle can be claimed.
--
-- A separate function because the obvious client-side check -- "does
-- `pilot_profile_card` return anything?" -- is wrong in the one case that
-- matters: a handle held by a profile that is private, hidden, or has blocked
-- the person asking returns nothing, the editor says "available", and the
-- unique index then refuses the save with a constraint error nobody can act on.
-- This reads the table, so a taken handle is taken whoever is asking, and it
-- returns nothing else about the profile holding it.
create or replace function public.pilot_handle_available(p_handle text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select lower(btrim(coalesce(p_handle, ''))) ~ '^[a-z0-9](?:[a-z0-9_]{1,18})[a-z0-9]$'
     and lower(btrim(p_handle)) !~ '__'
     and not exists (
       select 1 from public.reserved_handles r
        where r.handle = lower(btrim(p_handle)))
     and not exists (
       select 1 from public.pilot_profiles p
        where p.handle = lower(btrim(p_handle))
          and p.user_id is distinct from auth.uid())
     and not public.moderation_rejects(lower(btrim(p_handle)));
$function$;

grant execute on function public.pilot_handle_available(text) to anon, authenticated;

-- MARK: - Finding somebody

create or replace function public.pilot_directory_search(
  p_query text,
  p_limit integer default 25
)
returns setof public.pilot_summary
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_q text := lower(btrim(coalesce(p_query, '')));
begin
  -- Two characters is the floor. One character would return the directory.
  if char_length(v_q) < 2 then return; end if;

  return query
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         p.if_username,
         p.favourite_aircraft,
         p.home_airport,
         public.is_pro_account(p.user_id)
    from public.pilot_profiles p
   where p.is_public
     and p.moderation_state = 'ok'
     and (p.handle like v_q || '%'
          or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
          or lower(coalesce(p.if_username, '')) like v_q || '%')
     and not exists (
       select 1 from public.pilot_blocks bl
        where bl.blocker_id = p.user_id and bl.blocked_id = v_viewer)
   -- An exact handle is what somebody typing a whole handle is looking for,
   -- and it should not be third behind two people whose bio mentions them.
   order by (p.handle = v_q) desc,
            (p.handle like v_q || '%') desc,
            p.handle asc
   limit least(greatest(coalesce(p_limit, 25), 1), 50);
end $function$;

grant execute on function public.pilot_directory_search(text, integer) to anon, authenticated;

-- MARK: - Following, by handle
--
-- The client never learns anybody's auth user id, so following is done by the
-- name it already has. The insert underneath is the same one RLS and the
-- trigger guard; this only saves the client a lookup it could not do.

create or replace function public.pilot_follow(p_handle text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_target uuid;
begin
  if v_viewer is null then
    raise exception 'Sign in to follow a pilot.' using errcode = 'insufficient_privilege';
  end if;

  select p.user_id into v_target
    from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if v_target is null then
    raise exception 'No pilot goes by that name.' using errcode = 'no_data_found';
  end if;

  if v_target = v_viewer then
    raise exception 'You already know yourself.' using errcode = 'check_violation';
  end if;

  insert into public.pilot_follows (follower_id, following_id)
  values (v_viewer, v_target)
  on conflict do nothing;

  -- Whether they are now friends, which is what the button needs to know to
  -- change what it says.
  return exists (
    select 1 from public.pilot_follows f
     where f.follower_id = v_target and f.following_id = v_viewer);
end $function$;

grant execute on function public.pilot_follow(text) to authenticated;

create or replace function public.pilot_unfollow(p_handle text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
begin
  if v_viewer is null then return; end if;

  delete from public.pilot_follows f
   using public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')))
     and f.follower_id = v_viewer
     and f.following_id = p.user_id;
end $function$;

grant execute on function public.pilot_unfollow(text) to authenticated;

-- Blocking and reporting by handle, for the same reason.

create or replace function public.pilot_block(p_handle text, p_blocked boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_target uuid;
begin
  if v_viewer is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  select p.user_id into v_target from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if v_target is null or v_target = v_viewer then return; end if;

  if p_blocked then
    insert into public.pilot_blocks (blocker_id, blocked_id)
    values (v_viewer, v_target)
    on conflict do nothing;
  else
    delete from public.pilot_blocks b
     where b.blocker_id = v_viewer and b.blocked_id = v_target;
  end if;
end $function$;

grant execute on function public.pilot_block(text, boolean) to authenticated;

create or replace function public.pilot_report(
  p_handle text,
  p_reason text,
  p_detail text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_target uuid;
begin
  if v_viewer is null then
    raise exception 'Sign in to report a profile.' using errcode = 'insufficient_privilege';
  end if;

  select p.user_id into v_target from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if v_target is null or v_target = v_viewer then return; end if;

  insert into public.profile_reports (profile_id, reporter_id, reason, detail)
  values (v_target, v_viewer, p_reason, nullif(btrim(coalesce(p_detail, '')), ''))
  on conflict do nothing;
end $function$;

grant execute on function public.pilot_report(text, text, text) to authenticated;

-- Who the signed-in pilot has blocked, so the app can offer to undo it.
create or replace function public.pilot_blocked_list()
returns setof public.pilot_summary
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         p.if_username,
         p.favourite_aircraft,
         p.home_airport,
         public.is_pro_account(p.user_id)
    from public.pilot_blocks b
    join public.pilot_profiles p on p.user_id = b.blocked_id
   where b.blocker_id = auth.uid()
   order by b.created_at desc;
$function$;

grant execute on function public.pilot_blocked_list() to authenticated;
