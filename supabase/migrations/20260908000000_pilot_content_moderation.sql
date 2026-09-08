-- Seeing what pilots upload, taking it down, and saying so.
--
-- WHAT WAS ALREADY HERE. `20260818000100_pilot_profiles.sql` built the four
-- things App Review 1.2 asks for: a text filter, a way to report, a way to
-- block, and an address to write to. `moderation_state` already takes a profile
-- out of public view, and `profile_reports` already auto-hides one that three
-- people have complained about.
--
-- WHAT IT COULD NOT DO. All of that is about the profile as a whole, and all of
-- it starts from a report. Nothing addressed the picture itself:
--
--   * There was no way to LOOK. Avatars and banners live in two public buckets
--     under object paths; nothing lists them, so the only way to find a bad
--     one was for three strangers to report the profile carrying it first.
--     PROFILES.md calls images "the honest gap" — this is the half of that gap
--     that no classifier can close, because somebody still has to be able to
--     look at what got through.
--   * There was no way to REMOVE ONE. `moderation_state = 'blocked'` hides the
--     whole profile, which is right for a profile that is a problem and much
--     too much for a good profile with one bad picture on it. The only
--     narrower path — the `profile-image` function — needs the pilot's own
--     token, so a moderator could not use it.
--   * NOTHING WAS SAID, AND NOTHING WAS STOPPED. A removed avatar just
--     vanished, and the pilot could upload the same file again a minute later.
--
-- WHAT THIS ADDS, in the order the pieces are used:
--
--   1. `pilot_warnings` — a warning ladder for pilots, with the switch that
--      turns off uploading while a warning stands.
--   2. `pilot_content_actions` — the record of every picture taken down.
--   3. `pilot_upload_restriction()` / `pilot_upload_notice()` — is this pilot
--      allowed to upload, and the ONE sentence they are told if not.
--   4. `pilot_my_standing()` — what the app shows the pilot about all of this.
--   5. `admin_pilot_*()` — the four things the staff console does.
--
-- STORAGE OBJECTS ARE NOT DELETED HERE. SQL cannot remove a file from a
-- bucket. `admin_pilot_takedown()` clears the column, writes the record, and
-- RETURNS THE PATH IT ORPHANED; deleting the object is the caller's job, and
-- the returned path is how it knows what to delete. That order is deliberate:
-- the row is what makes the picture appear anywhere, so clearing it is what
-- actually takes the picture down, and an object nobody points at is litter
-- rather than a live problem.

-- MARK: - Warnings

-- The ladder. Shorter than a contract-termination ladder because a pilot is
-- not a partner: there is no agreement to terminate, only an account.
--
--   notice     on the record, no penalty. "Please don't."
--   first      formal. The thing was bad enough to count.
--   final      the next one costs them the account.
--   suspended  the profile is out of public view and staying there.
--
-- Kept as a check constraint rather than a lookup table on purpose: unlike
-- `moderation_terms`, which is maintained from the dashboard precisely because
-- publishing it is publishing the way around it, this list is not a secret and
-- every level needs matching copy in the app. A new level is a release, not a
-- row.
create table if not exists public.pilot_warnings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,

  level text not null
    check (level in ('notice', 'first', 'final', 'suspended')),

  -- What the pilot is told. Shown to them verbatim, so it is written to be
  -- read by the person it happened to rather than filed by the person who
  -- wrote it.
  reason text not null
    check (char_length(reason) between 1 and 2000),

  -- Same vocabulary as `profile_reports.reason`, so a warning that came out of
  -- a report can carry the report's own category without translation.
  category text
    check (category is null or category in
      ('sexual', 'hate', 'harassment', 'impersonation', 'spam', 'violence', 'other')),

  /* DOES THIS WARNING STOP THEM UPLOADING.
   *
   * A warning about a picture is a request until something enforces it. These
   * two columns are what make "stop putting this on the platform" hold:
   * `upload_block` refuses new pictures while the warning stands, and
   * `upload_block_until` optionally lets it lapse on its own.
   *
   * They live on the warning rather than in a restrictions table because the
   * restriction is not a separate decision — somebody issues a warning and
   * decides whether it has teeth. Rescinding the warning therefore lifts the
   * restriction for free, with no second switch to forget.
   *
   * A null `upload_block_until` with `upload_block` true is indefinite, and
   * means something different from a date: "not until we have talked", as
   * against a cooling-off period that ends by itself.
   */
  upload_block boolean not null default false,
  upload_block_until timestamptz,

  -- Set when staff switch uploading back on while leaving the warning
  -- standing. Different from rescinding, which says the warning itself was
  -- wrong. Both are needed: one is "you have served this", the other is "this
  -- should never have been issued".
  upload_block_lifted_at timestamptz,
  upload_block_lifted_by text,

  -- Free text rather than a foreign key into a staff table, because there is
  -- no staff table in this project — moderation is done with the service role.
  -- A name here is worth more than a null.
  issued_by text,

  -- The pilot's acknowledgement of receipt, which is not agreement.
  acknowledged_at timestamptz,

  -- Rescinded warnings are kept, not deleted. A warning issued in error and
  -- withdrawn is part of the record of how this pilot has been treated.
  rescinded_at timestamptz,
  rescinded_reason text,

  created_at timestamptz not null default now(),

  -- An expiry only means something on a block that exists.
  constraint pilot_warnings_block_shape
    check (upload_block or upload_block_until is null)
);

-- The question asked on every upload: has this pilot got a live block? Partial,
-- because the rows that matter are a small minority of the table for ever.
create index if not exists pilot_warnings_live_block_idx
  on public.pilot_warnings (user_id)
  where upload_block and rescinded_at is null;

create index if not exists pilot_warnings_user_idx
  on public.pilot_warnings (user_id, created_at desc);

comment on table public.pilot_warnings is
  'Warnings issued to a pilot about what they uploaded, and the switch that stops them uploading more. Written only by the service role; a pilot may read their own and acknowledge them.';

alter table public.pilot_warnings enable row level security;

-- A pilot may read their own warnings and nothing else. There is no insert,
-- update or delete policy at all: every write is the service role's, which
-- bypasses RLS. That is the whole access model, and it is the same shape as
-- `moderation_state` — a thing said TO the pilot, never BY them.
drop policy if exists "Pilots read their own warnings" on public.pilot_warnings;
create policy "Pilots read their own warnings"
  on public.pilot_warnings for select
  using (auth.uid() = user_id);

grant select on public.pilot_warnings to authenticated;

-- MARK: - What has been taken down

create table if not exists public.pilot_content_actions (
  id uuid primary key default gen_random_uuid(),

  -- Null once the account is gone. The record survives the pilot: "we removed
  -- three pictures from an account that has since been deleted" is a true
  -- statement somebody may need to make.
  user_id uuid references auth.users (id) on delete set null,

  -- Kept as text alongside the id so a deleted account's record still says who
  -- it was about. A handle is not unique over time, which is exactly why it is
  -- copied here at takedown rather than joined at read time.
  handle text,

  kind text not null check (kind in ('avatar', 'banner')),

  -- The object that was orphaned. Stored even though the file behind it is
  -- gone: it is the only handle on WHICH picture this was, and a dead path
  -- that identifies a file beats no record of which file it was.
  storage_bucket text not null,
  storage_path text not null,

  category text not null default 'other'
    check (category in
      ('sexual', 'hate', 'harassment', 'impersonation', 'spam', 'violence', 'other')),

  -- For colleagues, not for the pilot. What the pilot is told is the warning's
  -- `reason`.
  note text check (note is null or char_length(note) <= 2000),

  removed_by text,

  -- Set when the takedown also issued a warning, so the two are one story
  -- rather than two rows somebody has to correlate by timestamp.
  warning_id uuid references public.pilot_warnings (id) on delete set null,

  created_at timestamptz not null default now()
);

create index if not exists pilot_content_actions_user_idx
  on public.pilot_content_actions (user_id, created_at desc);

create index if not exists pilot_content_actions_recent_idx
  on public.pilot_content_actions (created_at desc);

comment on table public.pilot_content_actions is
  'Every profile picture taken down by moderation, and why. Service role only -- pilots are told through pilot_warnings, not from here.';

alter table public.pilot_content_actions enable row level security;

-- No policies at all. Nothing but the service role reads this: it holds the
-- names of the people who removed things and notes written for colleagues, and
-- the pilot's copy of the story is the warning they were sent.

-- MARK: - Is this pilot allowed to upload

/* The live upload restriction for one pilot, or no rows if they may upload.
 *
 * Where several live warnings block uploading, the one that lasts longest wins
 * — an indefinite block outranks any date, and a later date outranks an
 * earlier one. Anything else would let a pilot upload again because the
 * LIGHTEST of their restrictions happened to lapse first.
 *
 * `security definer` because the app calls this for itself through
 * `pilot_my_standing()` and the `profile-image` function calls it for the
 * caller: both need the same answer, and neither should need to read the whole
 * warnings table to get it.
 */
create or replace function public.pilot_upload_restriction(p_uid uuid)
returns table (
  warning_id uuid,
  level text,
  reason text,
  until timestamptz,
  since timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select w.id, w.level, w.reason, w.upload_block_until, w.created_at
    from public.pilot_warnings w
   where w.user_id = p_uid
     and w.upload_block
     and w.rescinded_at is null
     and (w.upload_block_until is null or w.upload_block_until > now())
   -- Indefinite first (nulls first on a descending sort), then the furthest
   -- out expiry. One row, and it is the one that actually holds.
   order by w.upload_block_until desc nulls first
   limit 1;
$function$;

revoke all on function public.pilot_upload_restriction(uuid) from public;
revoke all on function public.pilot_upload_restriction(uuid) from anon;
revoke all on function public.pilot_upload_restriction(uuid) from authenticated;
grant execute on function public.pilot_upload_restriction(uuid) to service_role;

/* THE AUTOMATIC MESSAGE.
 *
 * One function so the refusal at the upload button, the notice in the profile
 * editor, and anything added later cannot drift apart and start describing the
 * same restriction differently. Composed here rather than in the app because
 * the app is the thing that ships on Apple's schedule: a pilot running last
 * month's build must not be shown last month's wording for a restriction
 * applied today.
 *
 * Written to be read by the person it happened to — what they cannot do, until
 * when, and what to do about it. Empty string when there is nothing to say,
 * which is the common case and reads naturally at every call site.
 */
create or replace function public.pilot_upload_notice(p_uid uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- coalesce over a scalar subquery, so no restriction yields '' rather than
  -- NULL. A NULL here would be a banner drawn with no text in it.
  select coalesce((
    select case
      when r.until is null then
        'Adding pictures is paused on your account after a warning about something you uploaded. '
        || 'Your profile and everything else on it are untouched. '
        || 'It stays paused until we lift it — reply to the warning to get in touch.'
      else
        'Adding pictures is paused on your account until '
        -- FM applies only to the field it prefixes, so Month needs its own or
        -- it arrives blank-padded to nine characters ("8 September  2026").
        || to_char(r.until at time zone 'UTC', 'FMDD FMMonth YYYY')
        || ' after a warning about something you uploaded. '
        || 'Your profile and everything else on it are untouched.'
    end
      from public.pilot_upload_restriction(p_uid) r
  ), '');
$function$;

revoke all on function public.pilot_upload_notice(uuid) from public;
revoke all on function public.pilot_upload_notice(uuid) from anon;
revoke all on function public.pilot_upload_notice(uuid) from authenticated;
grant execute on function public.pilot_upload_notice(uuid) to service_role;

-- MARK: - What the pilot sees

/* Everything the app needs to tell a pilot where they stand, in one call.
 *
 * Takes no argument and reads `auth.uid()`: a pilot asking about anybody but
 * themselves is not a request this function knows how to express, which is
 * better than a parameter it would have to refuse.
 *
 * Signed out, this returns no rows rather than raising. The profile editor
 * asks for it on appear, and a signed-out reader getting an error where they
 * should get silence is how the `security definer` bug in
 * `20260818000100` (a function that returned NULL for signed-out readers and
 * so failed open) was found in the first place.
 */
create or replace function public.pilot_my_standing()
returns table (
  warnings jsonb,
  active_count integer,
  unacknowledged_count integer,
  uploads_restricted boolean,
  uploads_restricted_until timestamptz,
  uploads_notice text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    coalesce((
      select jsonb_agg(x order by x.created_at desc)
        from (
          select w.id, w.level, w.reason, w.category,
                 w.upload_block, w.upload_block_until,
                 w.acknowledged_at, w.rescinded_at, w.issued_by, w.created_at
            from public.pilot_warnings w
           where w.user_id = auth.uid()
           order by w.created_at desc
           limit 50
        ) x
    ), '[]'::jsonb),
    (select count(*)::integer from public.pilot_warnings w
      where w.user_id = auth.uid() and w.rescinded_at is null),
    (select count(*)::integer from public.pilot_warnings w
      where w.user_id = auth.uid() and w.rescinded_at is null and w.acknowledged_at is null),
    exists (select 1 from public.pilot_upload_restriction(auth.uid())),
    (select until from public.pilot_upload_restriction(auth.uid())),
    public.pilot_upload_notice(auth.uid())
  where auth.uid() is not null;
$function$;

revoke all on function public.pilot_my_standing() from public;
grant execute on function public.pilot_my_standing() to authenticated;
-- `anon` too, and deliberately. The function is self-scoped by construction —
-- it reads `auth.uid()` and can express no other question — so a signed-out
-- caller gets zero rows, which is the silence the profile editor expects on
-- appear. Withholding the grant instead would turn "nobody is signed in" into
-- a permission error the app has to special-case, and an error is the kind of
-- thing a client eventually learns to ignore.
grant execute on function public.pilot_my_standing() to anon;

/* Acknowledging receipt, which is not agreeing.
 *
 * Scoped to the caller's own warnings by the where clause rather than by a
 * policy, because this is `security definer` and a policy would not apply to
 * it. Acknowledging twice is a no-op rather than an error — the app calls this
 * from a button that a pilot can press again.
 */
create or replace function public.pilot_acknowledge_warning(p_warning_id uuid)
returns boolean
language sql
volatile
security definer
set search_path to 'public'
as $function$
  with touched as (
    update public.pilot_warnings
       set acknowledged_at = now()
     where id = p_warning_id
       and user_id = auth.uid()
       and acknowledged_at is null
    returning 1
  )
  select exists (select 1 from touched)
      or exists (select 1 from public.pilot_warnings
                  where id = p_warning_id and user_id = auth.uid());
$function$;

revoke all on function public.pilot_acknowledge_warning(uuid) from public;
revoke all on function public.pilot_acknowledge_warning(uuid) from anon;
grant execute on function public.pilot_acknowledge_warning(uuid) to authenticated;

-- MARK: - The staff console
--
-- Everything below is `service_role` only. There is no staff role in this
-- project and inventing one here would be inventing a second authentication
-- system to maintain; the console that calls these holds the service key and
-- does its own sign-in (the Inflight staff hub, which already has accounts and
-- roles). These functions are therefore written as if the caller is trusted,
-- and the grants are what make that true.

/* Every profile picture on the platform, newest first.
 *
 * This is the "way to look" that did not exist. Both buckets in one list,
 * because a moderator wants to see what has been uploaded and not to choose
 * between two half-answers first.
 *
 * Each row carries the pilot's standing — prior takedowns, whether they are
 * restricted, whether the profile is already hidden — so the console can show
 * "third takedown" beside the picture rather than making somebody go and look
 * it up before deciding.
 *
 * `updated_at` is the sort key and it is a lie of convenience: it is when the
 * profile row last changed, not when the picture was uploaded. Nothing records
 * the latter (the path is written into a column, and the column has no
 * history), and a profile whose last change was uploading a picture is the
 * common case. The console labels it "last changed" rather than "uploaded" for
 * exactly this reason. Making it true would mean a timestamp column per image,
 * written by `profile-image`, and that is a bigger change than this needed to
 * be.
 */
create or replace function public.admin_pilot_uploads(
  p_limit integer default 200,
  p_offset integer default 0,
  p_only_flagged boolean default false
)
returns table (
  user_id uuid,
  handle text,
  display_name text,
  kind text,
  storage_bucket text,
  storage_path text,
  moderation_state text,
  is_public boolean,
  autohidden boolean,
  open_reports integer,
  prior_takedowns integer,
  restricted boolean,
  restricted_until timestamptz,
  changed_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with pictures as (
    select p.user_id, p.handle, p.display_name, 'avatar' as kind,
           'pilot-avatars' as bucket, p.avatar_path as path,
           p.moderation_state, p.is_public, p.updated_at
      from public.pilot_profiles p
     where p.avatar_path is not null
    union all
    select p.user_id, p.handle, p.display_name, 'banner',
           'pilot-banners', p.banner_path,
           p.moderation_state, p.is_public, p.updated_at
      from public.pilot_profiles p
     where p.banner_path is not null
  ),
  counted as (
    select
      pic.*,
      public.profile_is_autohidden(pic.user_id) as autohidden,
      (select count(*)::integer from public.profile_reports r
        where r.profile_id = pic.user_id and r.resolved_at is null) as open_reports,
      (select count(*)::integer from public.pilot_content_actions a
        where a.user_id = pic.user_id) as prior_takedowns,
      (select until from public.pilot_upload_restriction(pic.user_id)) as restricted_until,
      exists (select 1 from public.pilot_upload_restriction(pic.user_id)) as restricted
      from pictures pic
  )
  select c.user_id, c.handle, c.display_name, c.kind, c.bucket, c.path,
         c.moderation_state, c.is_public, c.autohidden,
         c.open_reports, c.prior_takedowns,
         c.restricted, c.restricted_until, c.updated_at
    from counted c
   -- "Anything somebody has already flagged" — reported, auto-hidden, hidden
   -- by a moderator, previously taken down, or currently restricted. The
   -- queue you work when you do not have all day for the whole feed.
   where not p_only_flagged
      or c.open_reports > 0
      or c.autohidden
      or c.moderation_state <> 'ok'
      or c.prior_takedowns > 0
      or c.restricted
   order by c.updated_at desc
   limit greatest(1, least(coalesce(p_limit, 200), 1000))
  offset greatest(0, coalesce(p_offset, 0));
$function$;

revoke all on function public.admin_pilot_uploads(integer, integer, boolean) from public;
revoke all on function public.admin_pilot_uploads(integer, integer, boolean) from anon;
revoke all on function public.admin_pilot_uploads(integer, integer, boolean) from authenticated;
grant execute on function public.admin_pilot_uploads(integer, integer, boolean) to service_role;

/* Take a picture down, record why, and optionally warn and restrict.
 *
 * ONE FUNCTION BECAUSE IT IS ONE DECISION. Three separate calls would mean a
 * takedown where somebody meant to warn and did not, which is the exact
 * failure this migration exists to close: a record with a gap in it and a
 * pilot who was never actually told. It is also one transaction, so a warning
 * can never be issued for a removal that then failed.
 *
 * Returns the orphaned object's path. The caller deletes the file — see the
 * note at the top of this migration.
 *
 * The column is cleared with the service role, which the write guard on
 * `pilot_profiles` lets through untouched (`auth.uid()` is null, so
 * `v_from_client` is false and none of the client rules run). Clearing
 * `banner_path` therefore does not trip the Pro check either, which matters:
 * a lapsed-Pro pilot's banner must still be removable.
 */
create or replace function public.admin_pilot_takedown(
  p_user_id uuid,
  p_kind text,
  p_category text default 'other',
  p_note text default null,
  p_removed_by text default null,
  p_warn_level text default null,
  p_warn_reason text default null,
  p_block_uploads boolean default false,
  p_block_days integer default null
)
returns table (
  removed_bucket text,
  removed_path text,
  warning_id uuid,
  action_id uuid
)
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_bucket text;
  v_path text;
  v_handle text;
  v_warning uuid;
  v_action uuid;
  v_until timestamptz;
  v_reason text;
begin
  if p_kind not in ('avatar', 'banner') then
    raise exception 'kind must be avatar or banner' using errcode = 'check_violation';
  end if;

  v_bucket := case p_kind when 'avatar' then 'pilot-avatars' else 'pilot-banners' end;

  /* Read the path, THEN clear it — and hold the row across both.
   *
   * `update ... returning` cannot be used to learn what was removed: RETURNING
   * hands back the NEW row, whose path is null by definition, and the record
   * would store a null for the one field that says which picture this was.
   *
   * `for update` is what makes the read-then-write safe. Two moderators
   * pressing the button at the same moment would otherwise both read the path,
   * both delete the object, and both write a record for one removal. The
   * second now waits here, re-reads after the first commits, finds null, and
   * is told the truth.
   */
  select case when p_kind = 'avatar' then p.avatar_path else p.banner_path end,
         p.handle
    into v_path, v_handle
    from public.pilot_profiles p
   where p.user_id = p_user_id
   for update;

  if not found then
    raise exception 'No such profile.' using errcode = 'no_data_found';
  end if;

  if v_path is null then
    raise exception 'That picture has already been removed.' using errcode = 'no_data_found';
  end if;

  update public.pilot_profiles
     set avatar_path = case when p_kind = 'avatar' then null else avatar_path end,
         banner_path = case when p_kind = 'banner' then null else banner_path end
   where user_id = p_user_id;

  -- MARK: the warning, issued in the same transaction
  if p_warn_level is not null then
    if p_block_uploads and p_block_days is not null then
      v_until := now() + make_interval(days => greatest(1, least(p_block_days, 365)));
    end if;

    v_reason := nullif(btrim(coalesce(p_warn_reason, '')), '');
    if v_reason is null then
      -- A warning with no words is a warning nobody can act on. Composed from
      -- what is known rather than left blank.
      v_reason := 'We removed the ' || p_kind || ' from your profile because it did not meet our '
               || 'safe-for-work rules. Please choose a different picture.';
    end if;

    insert into public.pilot_warnings
      (user_id, level, reason, category, upload_block, upload_block_until, issued_by)
    values
      (p_user_id, p_warn_level, v_reason, nullif(p_category, 'other'),
       coalesce(p_block_uploads, false),
       case when coalesce(p_block_uploads, false) then v_until else null end,
       p_removed_by)
    returning id into v_warning;
  end if;

  insert into public.pilot_content_actions
    (user_id, handle, kind, storage_bucket, storage_path,
     category, note, removed_by, warning_id)
  values
    (p_user_id, v_handle, p_kind, v_bucket, v_path,
     coalesce(p_category, 'other'), nullif(btrim(coalesce(p_note, '')), ''),
     p_removed_by, v_warning)
  returning id into v_action;

  return query select v_bucket, v_path, v_warning, v_action;
end $function$;

revoke all on function public.admin_pilot_takedown(uuid, text, text, text, text, text, text, boolean, integer) from public;
revoke all on function public.admin_pilot_takedown(uuid, text, text, text, text, text, text, boolean, integer) from anon;
revoke all on function public.admin_pilot_takedown(uuid, text, text, text, text, text, text, boolean, integer) from authenticated;
grant execute on function public.admin_pilot_takedown(uuid, text, text, text, text, text, text, boolean, integer) to service_role;

/* Who currently cannot upload. One row per pilot: several live warnings can
 * block the same person, and the console is a list of people, not of warnings.
 */
create or replace function public.admin_pilot_restrictions()
returns table (
  user_id uuid,
  handle text,
  display_name text,
  warning_id uuid,
  level text,
  reason text,
  until timestamptz,
  since timestamptz,
  acknowledged_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select distinct on (w.user_id)
         w.user_id, p.handle, p.display_name,
         w.id, w.level, w.reason,
         w.upload_block_until, w.created_at, w.acknowledged_at
    from public.pilot_warnings w
    left join public.pilot_profiles p on p.user_id = w.user_id
   where w.upload_block
     and w.rescinded_at is null
     and (w.upload_block_until is null or w.upload_block_until > now())
   -- Same ordering rule as pilot_upload_restriction: the block that actually
   -- holds is the one shown, so the console and the gate agree about which
   -- warning is doing the work.
   order by w.user_id, w.upload_block_until desc nulls first;
$function$;

revoke all on function public.admin_pilot_restrictions() from public;
revoke all on function public.admin_pilot_restrictions() from anon;
revoke all on function public.admin_pilot_restrictions() from authenticated;
grant execute on function public.admin_pilot_restrictions() to service_role;

/* Switch uploading back on without rescinding the warning.
 *
 * These are different things and both are needed. Rescinding says the warning
 * should not have been issued; lifting says it stood, it was dealt with, and
 * the pilot can upload again. Collapsing them would mean the only way to let
 * somebody upload was to erase the reason they could not — which is exactly
 * the history worth keeping.
 */
create or replace function public.admin_pilot_lift_restriction(
  p_warning_id uuid,
  p_lifted_by text default null
)
returns boolean
language sql
volatile
security definer
set search_path to 'public'
as $function$
  with touched as (
    update public.pilot_warnings
       set upload_block = false,
           upload_block_until = null,
           upload_block_lifted_at = now(),
           upload_block_lifted_by = p_lifted_by
     where id = p_warning_id
       and upload_block
    returning 1
  )
  select exists (select 1 from touched);
$function$;

revoke all on function public.admin_pilot_lift_restriction(uuid, text) from public;
revoke all on function public.admin_pilot_lift_restriction(uuid, text) from anon;
revoke all on function public.admin_pilot_lift_restriction(uuid, text) from authenticated;
grant execute on function public.admin_pilot_lift_restriction(uuid, text) to service_role;

/* The record: what has been taken down, and why. */
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
  created_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select a.id, a.user_id, a.handle, a.kind, a.storage_bucket, a.storage_path,
         a.category, a.note, a.removed_by, a.warning_id, w.level, a.created_at
    from public.pilot_content_actions a
    left join public.pilot_warnings w on w.id = a.warning_id
   where p_user_id is null or a.user_id = p_user_id
   order by a.created_at desc
   limit greatest(1, least(coalesce(p_limit, 200), 1000));
$function$;

revoke all on function public.admin_pilot_actions(integer, uuid) from public;
revoke all on function public.admin_pilot_actions(integer, uuid) from anon;
revoke all on function public.admin_pilot_actions(integer, uuid) from authenticated;
grant execute on function public.admin_pilot_actions(integer, uuid) to service_role;
