-- Four foreign keys that quietly made account deletion impossible.
--
-- WHAT WENT WRONG
-- ---------------
-- "Delete my account" appeared to do nothing. It was not doing nothing: it was
-- failing, at the last step, every time, for anybody who had founded a virtual
-- airline. `auth.admin.deleteUser` ends in a `delete from auth.users`, and four
-- columns referenced that table with NO delete rule at all —
--
--   vas.ceo_user_id             the VA you founded
--   va_staff.granted_by         who gave somebody a staff seat
--   va_applications.reviewed_by who reviewed an application
--   va_events.reviewed_by       who reviewed an event
--
-- — which means Postgres refuses the delete while any of them point at the
-- account. Every other table that keys on an account already declares
-- `on delete cascade` and was never the problem; these four are the whole of
-- it. The user saw "The account could not be deleted. Try again", and trying
-- again could never work, because nothing about the answer was going to change.
--
-- WHY EACH ONE GETS THE RULE IT GETS
-- ----------------------------------
-- `vas.ceo_user_id` cascades. It is `not null`, so there is no orphaned state
-- to leave it in, and row-level security lets only the CEO (or site staff)
-- update the row — so a listing whose CEO has erased their account is one that
-- nobody can edit, take down, or run an event for. The roster and the events
-- cascade from the VA in turn, as they already did.
--
-- The other three are audit columns, already nullable, and are set null. The
-- record of an application having been reviewed is not the reviewer's personal
-- data to take with them; the name on it is. Keeping the row and dropping the
-- name is what deleting an account is supposed to mean.
--
-- WHY THIS IS GUARDED
-- -------------------
-- The VA directory is the website's, not this app's: no migration in this
-- folder creates these tables, and a project that has never had them is a
-- normal state. So each block checks the table is there and does nothing if it
-- is not, rather than failing a deploy over a table it does not own.
--
-- `supabase/functions/delete-account/index.ts` also clears these four
-- references by hand before it deletes anybody. That is deliberate belt and
-- braces: the function must work against a project where this migration has
-- not been applied, and this migration must hold whether or not somebody later
-- edits the function.

do $$
begin
  if to_regclass('public.vas') is null then
    raise notice 'account_deletion_unblock: public.vas absent, nothing to do';
    return;
  end if;

  alter table public.vas drop constraint if exists vas_ceo_user_id_fkey;

  alter table public.vas
    add constraint vas_ceo_user_id_fkey
    foreign key (ceo_user_id) references auth.users (id) on delete cascade;
end $$;

do $$
begin
  if to_regclass('public.va_staff') is null then
    return;
  end if;

  alter table public.va_staff drop constraint if exists va_staff_granted_by_fkey;

  alter table public.va_staff
    add constraint va_staff_granted_by_fkey
    foreign key (granted_by) references auth.users (id) on delete set null;
end $$;

do $$
begin
  if to_regclass('public.va_applications') is null then
    return;
  end if;

  alter table public.va_applications drop constraint if exists va_applications_reviewed_by_fkey;

  alter table public.va_applications
    add constraint va_applications_reviewed_by_fkey
    foreign key (reviewed_by) references auth.users (id) on delete set null;
end $$;

do $$
begin
  if to_regclass('public.va_events') is null then
    return;
  end if;

  alter table public.va_events drop constraint if exists va_events_reviewed_by_fkey;

  alter table public.va_events
    add constraint va_events_reviewed_by_fkey
    foreign key (reviewed_by) references auth.users (id) on delete set null;
end $$;

-- MARK: - The check that would have caught this
--
-- Not a constraint — there is nothing to constrain — but a function that names
-- every reference to `auth.users` that would refuse a delete. One row back is a
-- table that will break account deletion the day somebody's account holds a
-- row in it, and it costs one query to know.
--
--   select * from public.account_deletion_blockers();
--
-- `security definer` because `pg_constraint` is readable by anyone but the
-- point is that it can be called from a check that runs as nobody in
-- particular. Granted to no role by default: staff read it through the SQL
-- editor, which runs as the owner.
create or replace function public.account_deletion_blockers()
returns table (table_name text, constraint_name text, definition text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select c.conrelid::regclass::text,
         c.conname::text,
         pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.confrelid
    join pg_namespace tn on tn.oid = t.relnamespace
    join pg_class r on r.oid = c.conrelid
    join pg_namespace rn on rn.oid = r.relnamespace
   where c.contype = 'f'
     and tn.nspname = 'auth'
     and t.relname = 'users'
     -- 'a' is NO ACTION and 'r' is RESTRICT: both refuse the delete. 'c', 'n'
     -- and 'd' — cascade, set null, set default — all let it through.
     and c.confdeltype in ('a', 'r')
     -- GoTrue's own tables are its business, and it clears them itself.
     and rn.nspname <> 'auth'
   order by 1, 2
$function$;

revoke all on function public.account_deletion_blockers() from public, anon, authenticated;

comment on function public.account_deletion_blockers() is
  'Foreign keys to auth.users that would refuse a user delete. Should be empty; '
  'anything listed will break in-app account deletion (App Store 5.1.1(v)).';
