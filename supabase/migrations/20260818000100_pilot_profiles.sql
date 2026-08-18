-- The public pilot profile.
--
-- Until now an Inflight account was a login and an entitlement: it proved who
-- you were to the server and nothing to anybody else. The map is full of names
-- — every aircraft carries its pilot's Infinite Flight handle — and none of
-- them led anywhere. This is the table that makes a name on the map a person:
-- a picture, a banner, the aeroplane they love, where they fly out of.
--
-- Everything here is meant to be READ BY STRANGERS, and that shapes all of it:
--
--   * it is opt-out, not opt-in-by-accident. A row exists only once somebody
--     claims a handle, and `is_public` turns the whole thing off again.
--   * a client may write its own row and no other, and may not write the
--     columns that decide whether the row is visible or Pro.
--   * it is safe for work, and that is enforced here rather than promised in
--     a policy document. See `moderation_terms` below and the reports table.
--
-- Storage for the two images lives in buckets that are PUBLIC TO READ and
-- writable by nobody with an anon key: the `profile-image` Edge Function holds
-- the service role and is the only writer. A client that can PUT into an
-- avatar bucket can PUT anything into it, and "anything" on a public bucket
-- under our domain is somebody else's problem to explain.

-- MARK: - Moderation vocabulary
--
-- A table rather than a constant in a trigger, because a word list is
-- operational data: it gets added to the week somebody finds a way around it,
-- and that should not need a migration and a deploy. Nothing but the service
-- role can read it — publishing the exact list is publishing the exact way
-- through it.

create table if not exists public.moderation_terms (
  term text primary key,

  -- 'word' matches only as a whole word, which is what stops a legitimate
  -- name being refused for containing four letters of something else.
  -- 'substring' matches anywhere, for the handful of terms that have no
  -- innocent embedding and are usually smuggled in the middle of one.
  match text not null default 'word' check (match in ('word', 'substring')),

  note text,
  created_at timestamptz not null default now()
);

alter table public.moderation_terms enable row level security;
-- No policies at all: RLS with no policy denies everyone, and the service role
-- bypasses RLS. That is exactly the access this table should have.

-- The starting list. Deliberately short, deliberately unambiguous, and
-- deliberately not exhaustive — it is seeded so the filter is not a no-op on
-- day one, and is expected to be maintained from the dashboard rather than
-- from git. Slurs are handled the same way and are not written down here.
insert into public.moderation_terms (term, match, note) values
  ('porn',    'substring', 'adult'),
  ('pornhub', 'substring', 'adult'),
  ('xxx',     'substring', 'adult'),
  ('nsfw',    'substring', 'adult'),
  ('onlyfans','substring', 'adult'),
  ('hentai',  'substring', 'adult'),
  ('nudes',   'substring', 'adult'),
  ('nude',    'word',      'adult'),
  ('sex',     'word',      'adult'),
  ('sexy',    'word',      'adult'),
  ('escort',  'word',      'adult'),
  ('camgirl', 'substring', 'adult'),
  ('fetish',  'substring', 'adult')
on conflict (term) do nothing;

-- Folds the tricks people use to walk a word past a filter.
--
-- Lowercases, maps the usual digit and symbol substitutions back onto letters,
-- collapses runs of the same letter, and throws away everything that is not a
-- letter or a space — so `p_o_r_n`, `P0RN` and `pooorn` all normalise onto the
-- same thing the list holds. Not a solved problem and not claimed to be one;
-- it raises the effort past "type it in".
create or replace function public.moderation_normalize(p_text text)
returns text
language sql
immutable
as $function$
  select regexp_replace(
           regexp_replace(
             regexp_replace(
               translate(lower(coalesce(p_text, '')),
                         '4310$!5|@+',
                         'aeiosisita'),
               '[^a-z ]+', '', 'g'),
             '(.)\1+', '\1', 'g'),
           ' +', ' ', 'g');
$function$;

-- Whether a piece of user-written text trips the list.
create or replace function public.moderation_rejects(p_text text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
      from public.moderation_terms t
     where case t.match
             when 'substring'
               then position(public.moderation_normalize(t.term)
                             in public.moderation_normalize(p_text)) > 0
             else public.moderation_normalize(p_text)
                    ~ ('(^| )' || public.moderation_normalize(t.term) || '( |$)')
           end
  );
$function$;

revoke all on function public.moderation_rejects(text) from public;
revoke all on function public.moderation_rejects(text) from anon;
revoke all on function public.moderation_rejects(text) from authenticated;

-- MARK: - Reserved handles
--
-- Names that must not be somebody's personal handle: the app's own routes, the
-- words a scam would want, and the ones that would let a profile URL read as
-- an official page.

create table if not exists public.reserved_handles (
  handle text primary key
);

alter table public.reserved_handles enable row level security;

insert into public.reserved_handles (handle) values
  ('inflight'), ('inflightinfo'), ('admin'), ('administrator'), ('root'),
  ('staff'), ('team'), ('support'), ('help'), ('billing'), ('payments'),
  ('security'), ('moderator'), ('mod'), ('official'), ('verified'),
  ('api'), ('www'), ('app'), ('login'), ('signin'), ('signup'), ('account'),
  ('accounts'), ('settings'), ('pro'), ('subscribe'), ('pilot'), ('pilots'),
  ('profile'), ('profiles'), ('null'), ('undefined'), ('me'), ('you'),
  ('infiniteflight'), ('infinite_flight')
on conflict (handle) do nothing;

-- MARK: - The profile

create table if not exists public.pilot_profiles (

  user_id uuid primary key references auth.users (id) on delete cascade,

  -- The name in the URL, and the thing people search for. Lowercase, because
  -- two handles that differ only in case are two ways to impersonate one
  -- person. Short enough to say out loud.
  handle text not null,

  -- Free text, and what is actually drawn. Somebody whose handle has to be
  -- `ba_speedbird_49` can still be called "Speedbird".
  display_name text,

  bio text,

  -- The Infinite Flight community handle, mirrored from the account's
  -- `user_metadata.if_username`.
  --
  -- This is the join between a profile and the map. The live feed names an
  -- aircraft's pilot by this handle and knows nothing about Inflight accounts,
  -- so without a copy here there is no way to get from a tapped aeroplane to
  -- the person flying it — which is the single most useful thing the whole
  -- feature does.
  --
  -- Unverified on purpose, and marked as such everywhere it is shown: nothing
  -- stops somebody claiming a handle that is not theirs, and the honest fix is
  -- to say "claims to be" rather than to pretend at a verification we cannot
  -- perform. `if_username_verified` is set only by a server that has actually
  -- checked, and nothing sets it yet.
  if_username text,
  if_username_verified boolean not null default false,

  -- Object paths inside the storage buckets below, not URLs. The public URL is
  -- built at read time, so moving the bucket or putting a CDN in front of it is
  -- not a data migration.
  avatar_path text,
  banner_path text,

  -- What a free account's banner is: one of a curated set of gradients drawn by
  -- the client. Everyone gets a banner; Pro gets to make it a photograph.
  banner_preset text not null default 'dusk',

  -- Pro. A hex colour the profile is drawn in.
  accent text,

  -- The aeroplane they would fly if they could only fly one, and the livery
  -- they would wear. Free-text against the Infinite Flight fleet rather than a
  -- foreign key: the fleet gains aircraft between our releases, and a profile
  -- that cannot name a new one until we ship is a worse answer than a typo.
  favourite_aircraft text,
  favourite_livery text,

  -- Where they fly out of, ICAO.
  home_airport text,

  -- The whole profile, on or off. Off leaves the row intact and readable by
  -- its owner, which is what makes this a switch rather than a deletion.
  is_public boolean not null default true,

  -- Who may see the friends list. It is other people's names, so it gets its
  -- own control rather than riding on `is_public`.
  friends_visibility text not null default 'public'
    check (friends_visibility in ('public', 'followers', 'private')),

  -- Set by moderation, never by the client -- see the trigger below.
  --
  --   ok       visible
  --   review   hidden from everyone but its owner, pending a look
  --   blocked  hidden, and the owner has been told why
  moderation_state text not null default 'ok'
    check (moderation_state in ('ok', 'review', 'blocked')),
  moderation_note text,

  -- When the handle last changed, for the cooldown below.
  handle_changed_at timestamptz not null default now(),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Lowercase, letters, digits and underscores. No leading or trailing
  -- underscore and no double underscore, because `_ba_` and `b__a` are the
  -- cheapest way to make two handles look like one.
  constraint pilot_profiles_handle_shape
    check (handle ~ '^[a-z0-9](?:[a-z0-9_]{1,18})[a-z0-9]$' and handle !~ '__'),

  constraint pilot_profiles_display_name_length
    check (display_name is null or char_length(display_name) between 1 and 32),

  constraint pilot_profiles_bio_length
    check (bio is null or char_length(bio) <= 200),

  constraint pilot_profiles_home_airport_shape
    check (home_airport is null or home_airport ~ '^[A-Z0-9]{3,4}$'),

  constraint pilot_profiles_accent_shape
    check (accent is null or accent ~ '^#[0-9a-f]{6}$'),

  constraint pilot_profiles_favourite_lengths
    check ((favourite_aircraft is null or char_length(favourite_aircraft) <= 60)
       and (favourite_livery  is null or char_length(favourite_livery)  <= 60)),

  constraint pilot_profiles_if_username_shape
    check (if_username is null or if_username ~ '^[A-Za-z0-9_.-]{1,40}$')
);

create unique index if not exists pilot_profiles_handle_key
  on public.pilot_profiles (handle);

-- Finding a profile from a name on the map. Case-insensitive because the feed
-- spells a handle however the pilot typed it into Infinite Flight.
create index if not exists pilot_profiles_if_username_idx
  on public.pilot_profiles (lower(if_username))
  where if_username is not null;

comment on table public.pilot_profiles is
  'Public pilot profiles. Readable by anyone when is_public and moderation_state = ''ok''; writable only by the account they belong to, and never for the moderation or Pro-only columns.';

-- MARK: - Blocking
--
-- Required of any app with user-generated content (App Review 1.2), and worth
-- having regardless. A block is one-directional and silent: the blocked
-- account is not told, it simply stops being able to see or follow.

create table if not exists public.pilot_blocks (
  blocker_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint pilot_blocks_not_self check (blocker_id <> blocked_id)
);

create index if not exists pilot_blocks_blocked_idx
  on public.pilot_blocks (blocked_id);

grant select, insert, delete on public.pilot_blocks to authenticated;

alter table public.pilot_blocks enable row level security;

drop policy if exists "Pilots read their own blocks" on public.pilot_blocks;
create policy "Pilots read their own blocks"
  on public.pilot_blocks for select
  using (auth.uid() = blocker_id);

drop policy if exists "Pilots block for themselves" on public.pilot_blocks;
create policy "Pilots block for themselves"
  on public.pilot_blocks for insert
  with check (auth.uid() = blocker_id);

drop policy if exists "Pilots unblock for themselves" on public.pilot_blocks;
create policy "Pilots unblock for themselves"
  on public.pilot_blocks for delete
  using (auth.uid() = blocker_id);

-- MARK: - Reports
--
-- The other half of App Review 1.2: a way for anyone looking at a profile to
-- say it should not be there. Reports are write-only from the client — a
-- reporter cannot read back who else reported, and the reported account is
-- never told who reported it.

create table if not exists public.profile_reports (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references auth.users (id) on delete cascade,

  -- Null once the reporter's account is gone. The report survives them: a
  -- profile reported by five people who then deleted their accounts is still a
  -- profile five people reported.
  reporter_id uuid references auth.users (id) on delete set null,

  reason text not null
    check (reason in ('sexual', 'hate', 'harassment', 'impersonation',
                      'spam', 'violence', 'other')),
  detail text check (detail is null or char_length(detail) <= 500),

  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolution text
);

-- One standing report per person per profile. Re-reporting is not a vote.
create unique index if not exists profile_reports_one_per_reporter
  on public.profile_reports (profile_id, reporter_id)
  where reporter_id is not null and resolved_at is null;

create index if not exists profile_reports_open_idx
  on public.profile_reports (profile_id) where resolved_at is null;

grant insert on public.profile_reports to authenticated;

alter table public.profile_reports enable row level security;

drop policy if exists "Pilots file their own reports" on public.profile_reports;
create policy "Pilots file their own reports"
  on public.profile_reports for insert
  with check (auth.uid() = reporter_id and auth.uid() <> profile_id);

-- No select policy on purpose. A reporter does not get to watch the queue.

-- Enough independent complaints takes a profile out of public view until
-- somebody has looked at it.
--
-- DERIVED, NOT STORED, and that is not a stylistic preference. The obvious
-- implementation -- an AFTER INSERT trigger that sets `moderation_state` --
-- writes to a table whose BEFORE UPDATE guard exists precisely to stop
-- anything but the server changing that column, and the guard wins: the
-- auto-hide runs, the guard puts the old value back, and the profile stays up
-- while every count says it should be down. Reading the reports at visibility
-- time instead has no such fight to lose, needs no backfill when the threshold
-- changes, and un-hides a profile the moment its reports are resolved rather
-- than needing a second write to remember to undo the first.
--
-- Three, and from distinct reporters: one person cannot hide somebody by
-- filing the same complaint from one account (the unique index below already
-- stops that) and three friends cannot be one person unless they are three
-- accounts, which is a harder thing to be.
create or replace function public.profile_autohide_threshold()
returns integer language sql immutable as $function$ select 3 $function$;

create or replace function public.profile_is_autohidden(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((
    select count(distinct r.reporter_id) >= public.profile_autohide_threshold()
      from public.profile_reports r
     where r.profile_id = p_uid
       and r.resolved_at is null
  ), false);
$function$;

revoke all on function public.profile_is_autohidden(uuid) from public;
revoke all on function public.profile_is_autohidden(uuid) from anon;
revoke all on function public.profile_is_autohidden(uuid) from authenticated;

-- MARK: - What a client may write
--
-- RLS already says "your own row". This says "and not these columns", which
-- RLS cannot express. Three separate jobs, in one trigger because they all
-- have to happen between the client's values and the stored row:
--
--   1. Moderation columns are the server's. A client that can set its own
--      `moderation_state` can un-hide itself.
--   2. Pro columns need Pro, checked against the entitlement the rest of the
--      product uses rather than against a flag the client sent.
--   3. Text has to pass the filter, and a handle has to be allowed at all.

create or replace function public.pilot_profiles_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_is_pro boolean;

  -- Whether this write came from somebody signed in.
  --
  -- Every client path to this table goes through an RLS policy that requires
  -- `auth.uid() = user_id`, so a write with no `auth.uid()` at all cannot be a
  -- client: it is the service role, a dashboard query, or an Edge Function --
  -- in a word, us. Those are allowed to set the moderation columns and are not
  -- asked to hold a Pro subscription, because the alternative is that nobody
  -- can moderate anything and support cannot fix a profile by hand.
  v_from_client boolean := auth.uid() is not null;
begin
  -- Normalised before anything is checked, so the checks see what will
  -- actually be stored.
  new.handle := lower(trim(coalesce(new.handle, '')));
  new.display_name := nullif(btrim(coalesce(new.display_name, '')), '');
  new.bio := nullif(btrim(coalesce(new.bio, '')), '');
  new.if_username := nullif(btrim(coalesce(new.if_username, '')), '');
  new.home_airport := nullif(upper(btrim(coalesce(new.home_airport, ''))), '');
  new.favourite_aircraft := nullif(btrim(coalesce(new.favourite_aircraft, '')), '');
  new.favourite_livery := nullif(btrim(coalesce(new.favourite_livery, '')), '');
  new.accent := nullif(lower(btrim(coalesce(new.accent, ''))), '');

  -- 1. Moderation is not the client's to set.
  if tg_op = 'INSERT' then
    if v_from_client then
      new.moderation_state := 'ok';
      new.moderation_note := null;
      new.if_username_verified := false;
    end if;
    new.created_at := now();
    new.handle_changed_at := now();
  else
    if v_from_client then
      new.moderation_state := old.moderation_state;
      new.moderation_note := old.moderation_note;
      new.if_username_verified := old.if_username_verified;
    end if;
    new.created_at := old.created_at;

    -- A handle may move, but not constantly. Somebody who can change theirs
    -- hourly can wear a different person's name for an hour at a time, and
    -- everybody who linked to the old one lands on a stranger.
    if new.handle is distinct from old.handle then
      if old.handle_changed_at > now() - interval '30 days' then
        raise exception
          'A handle can only be changed once every 30 days. Yours last changed on %.',
          to_char(old.handle_changed_at, 'FMDD Month YYYY')
          using errcode = 'check_violation';
      end if;
      new.handle_changed_at := now();
    else
      new.handle_changed_at := old.handle_changed_at;
    end if;
  end if;

  new.updated_at := now();

  -- 2. Pro columns.
  --
  -- Only checked when they are actually being set to something new, so a free
  -- account whose Pro has lapsed can still edit its bio: the banner it uploaded
  -- while paying stays in the row, stops being shown by the read functions, and
  -- comes back the day they resubscribe. Taking it away instead would delete
  -- something they made because their card expired.
  if v_from_client
     and ((tg_op = 'INSERT' and (new.banner_path is not null or new.accent is not null))
      or (tg_op = 'UPDATE' and (new.banner_path is distinct from old.banner_path
                                or new.accent is distinct from old.accent))) then

    -- Clearing one is always allowed. Only setting one needs Pro.
    if coalesce(new.banner_path, '') <> '' or coalesce(new.accent, '') <> '' then
      v_is_pro := public.is_pro_account(new.user_id);
      if not v_is_pro then
        raise exception
          'A custom banner and profile colour are part of Inflight Pro.'
          using errcode = 'insufficient_privilege';
      end if;
    end if;
  end if;

  -- 3. Safe for work, and a handle that is allowed to exist.
  --
  -- Client writes only, again: a moderator renaming a profile has already made
  -- the judgement this filter exists to approximate.
  if not v_from_client then return new; end if;

  if exists (select 1 from public.reserved_handles r where r.handle = new.handle) then
    raise exception 'That handle is reserved.' using errcode = 'check_violation';
  end if;

  if public.moderation_rejects(new.handle)
     or public.moderation_rejects(coalesce(new.display_name, ''))
     or public.moderation_rejects(coalesce(new.bio, ''))
     or public.moderation_rejects(coalesce(new.favourite_livery, '')) then
    raise exception
      'Inflight profiles are safe for work. Please choose different wording.'
      using errcode = 'check_violation';
  end if;

  return new;
end $function$;

drop trigger if exists pilot_profiles_guard on public.pilot_profiles;
create trigger pilot_profiles_guard
  before insert or update on public.pilot_profiles
  for each row execute function public.pilot_profiles_guard();

-- MARK: - Row-level security

-- Supabase's default privileges usually cover a new table in `public`, but a
-- migration that relies on them is a migration that breaks silently on a
-- project where they were ever narrowed. RLS is the access control; these are
-- what let the policies be reached at all.
grant select on public.pilot_profiles to anon, authenticated;
grant insert, update, delete on public.pilot_profiles to authenticated;

alter table public.pilot_profiles enable row level security;

-- Anyone, signed in or not, may read a public profile that is not hidden --
-- except somebody its owner has blocked.
--
-- Signed-out callers are included deliberately: the website serves these
-- profiles to strangers, and a profile nobody can see without an account is
-- not a public profile.
drop policy if exists "Public profiles are public" on public.pilot_profiles;
create policy "Public profiles are public"
  on public.pilot_profiles for select
  to anon, authenticated
  using (
    is_public
    and moderation_state = 'ok'
    and not exists (
      select 1 from public.pilot_blocks b
       where b.blocker_id = pilot_profiles.user_id
         and b.blocked_id = auth.uid()
    )
  );

drop policy if exists "Pilots read their own profile" on public.pilot_profiles;
create policy "Pilots read their own profile"
  on public.pilot_profiles for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Pilots create their own profile" on public.pilot_profiles;
create policy "Pilots create their own profile"
  on public.pilot_profiles for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Pilots edit their own profile" on public.pilot_profiles;
create policy "Pilots edit their own profile"
  on public.pilot_profiles for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Pilots delete their own profile" on public.pilot_profiles;
create policy "Pilots delete their own profile"
  on public.pilot_profiles for delete
  to authenticated
  using (auth.uid() = user_id);

-- MARK: - Storage
--
-- Public to read, and written only by the `profile-image` Edge Function, which
-- holds the service role. There is no client-side insert, update or delete
-- policy on `storage.objects` for these buckets, so an anon key cannot put
-- anything in them however it is pointed at them.
--
-- The byte caps are the second line rather than the first: the function checks
-- the size before it uploads and gives a readable answer. This is what stops a
-- bug there becoming a bucket full of video.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('pilot-avatars', 'pilot-avatars', true, 2097152,
   array['image/jpeg', 'image/png', 'image/webp']),
  ('pilot-banners', 'pilot-banners', true, 5242880,
   array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Read is what `public = true` already grants through the render endpoint; the
-- explicit policy is what lets the same object be read through the object API,
-- which is what the app and the website actually call.
drop policy if exists "Profile images are readable" on storage.objects;
create policy "Profile images are readable"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id in ('pilot-avatars', 'pilot-banners'));
