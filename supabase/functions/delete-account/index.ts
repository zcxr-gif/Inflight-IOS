// Deletes the calling user's own account, and nothing else.
//
// App Store Guideline 5.1.1(v): an app that offers account creation has to
// offer account deletion from inside the app. `auth.admin.deleteUser` needs the
// `service_role` key, which bypasses row-level security entirely and so can
// never ship in a client — hence this function. It is the only thing standing
// between that key and the internet, so it does exactly one thing:
//
//   1. read the caller's own access token off the Authorization header
//   2. ask GoTrue who that token belongs to
//   3. delete that id — never an id taken from the request body
//
// There is deliberately no way to name a user to delete. The id comes from the
// verified token or the request fails.
//
// ORDER, AND WHY IT IS THIS WAY
// -----------------------------
// The auth row goes FIRST, and everything else follows from it. Every table
// that keys on an account declares `on delete cascade`, so one delete takes
// the lot — and if that delete fails, nothing has been destroyed and the
// account is exactly as it was. The earlier arrangement deleted the account's
// rows by hand and *then* the auth user, which meant a failure at the last
// step left a signed-in account with its watchlist and profile already gone.
//
// Two things do not follow from the cascade and are handled around it:
//
//   * `vas.ceo_user_id`, `va_staff.granted_by` and the two `reviewed_by`
//     columns reference `auth.users` with no delete rule at all, so Postgres
//     REFUSES the delete while any of them point at the account. This is what
//     made deletion appear to do nothing for anybody who had founded a VA: the
//     delete failed on a foreign key, every time, for good. They are cleared
//     first. `20260907000000_account_deletion_unblock.sql` re-points the same
//     four constraints so the database no longer needs the favour, but the
//     function does not assume that migration has been applied.
//   * Storage objects are files, not rows. They are removed after the account
//     is gone — see below.
//
// Deploy:
//
//   supabase functions deploy delete-account --project-ref lcgaoiqwwpyqndaucyzu
//
// `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the platform;
// neither needs setting by hand, and neither should ever be echoed back.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/// Buckets whose contents are filed under a folder named for the user id.
const PICTURE_BUCKETS = ["pilot-avatars", "pilot-banners"];

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/// True when a PostgREST error is only "that table isn't in this project".
///
/// The VA directory is not created by this repo's migrations — it belongs to
/// the website — so a project that has never had it is a normal state, not a
/// failure worth refusing a deletion over.
function isMissingTable(error: { code?: string; message?: string }): boolean {
  return error.code === "42P01" || error.code === "PGRST205" ||
    (error.message ?? "").includes("does not exist");
}

/// Clears every reference to the account that would otherwise block the delete.
///
/// Returns the message of the first real failure, or null. A blocked reference
/// left behind is not a warning: the delete after it cannot succeed, so this is
/// the one piece of cleanup whose errors are worth stopping for.
async function releaseBlockingReferences(
  admin: SupabaseClient,
  userId: string,
): Promise<string | null> {
  // The VA the account founded. There is no second administrator — RLS lets
  // only `ceo_user_id` (or site staff) touch the row — so a listing whose CEO
  // has erased their account is one nobody can edit, take down, or run an
  // event for. It goes with them, and its roster and events cascade from it.
  const owned: Array<[string, string]> = [["vas", "ceo_user_id"]];

  for (const [table, column] of owned) {
    const { error } = await admin.from(table).delete().eq(column, userId);
    if (error && !isMissingTable(error)) {
      console.error(`delete-account: clearing ${table}.${column} failed`, error.message);
      return error.message;
    }
  }

  // Audit columns: who reviewed an application, who granted a staff seat. The
  // record stays, the name on it does not — which is what deleting an account
  // is supposed to mean, and is why these are nullable.
  const audits: Array<[string, string]> = [
    ["va_applications", "reviewed_by"],
    ["va_events", "reviewed_by"],
    ["va_staff", "granted_by"],
  ];

  for (const [table, column] of audits) {
    const { error } = await admin.from(table).update({ [column]: null }).eq(column, userId);
    if (error && !isMissingTable(error)) {
      console.error(`delete-account: clearing ${table}.${column} failed`, error.message);
      return error.message;
    }
  }

  return null;
}

/// Removes the account's pictures.
///
/// These are the one thing deleting the auth user does NOT take with it. Every
/// row that references the account cascades, `pilot_profiles` included, but
/// Storage objects are files: they would sit in a public bucket, at a URL
/// somebody may well have pasted somewhere, after the account they belong to
/// had asked to be erased.
///
/// Paged rather than a single `list`, which answers with 100 objects at most —
/// a pilot who has changed their avatar a hundred times would have kept the
/// hundred-and-first. Each pass reads from the start of the folder because the
/// pass before it emptied what it read; the cap is there so a bucket that
/// refuses to shrink cannot spin forever. Failures are logged and not raised:
/// the account is already gone by the time this runs, and there is nothing the
/// pilot could do about a Storage error anyway.
async function removePictures(admin: SupabaseClient, userId: string): Promise<void> {
  for (const bucket of PICTURE_BUCKETS) {
    for (let pass = 0; pass < 50; pass++) {
      const { data: objects, error: listError } = await admin.storage
        .from(bucket)
        .list(userId, { limit: 100 });

      if (listError) {
        console.error(`delete-account: listing ${bucket} failed`, listError.message);
        break;
      }

      const paths = (objects ?? []).map((object) => `${userId}/${object.name}`);
      if (paths.length === 0) break;

      const { error: removeError } = await admin.storage.from(bucket).remove(paths);
      if (removeError) {
        console.error(`delete-account: clearing ${bucket} failed`, removeError.message);
        break;
      }

      if (paths.length < 100) break;
    }
  }
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }

  if (request.method !== "POST") {
    return json({ error: "Use POST." }, 405);
  }

  const header = request.headers.get("Authorization") ?? "";
  const token = header.toLowerCase().startsWith("bearer ")
    ? header.slice(7).trim()
    : "";

  if (!token) {
    return json({ error: "Missing access token." }, 401);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const admin = createClient(url, serviceRole, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // The whole security of this function is this line: the id that gets deleted
  // is the one GoTrue resolves from the caller's own token.
  const { data, error } = await admin.auth.getUser(token);

  if (error || !data?.user) {
    return json({ error: "That session is no longer valid." }, 401);
  }

  const userId = data.user.id;

  const blocked = await releaseBlockingReferences(admin, userId);

  if (blocked !== null) {
    return json(
      {
        error: "Your account could not be deleted. Please try again.",
        reason: blocked,
      },
      500,
    );
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);

  if (deleteError) {
    console.error("delete-account: deleteUser failed", deleteError.message);
    return json(
      {
        error: "Your account could not be deleted. Please try again.",
        reason: deleteError.message,
      },
      500,
    );
  }

  // Said plainly rather than assumed. `deleteUser` reporting no error is not
  // the same as the row being gone — a soft delete would leave it there — and
  // an app that says "your account is deleted" over a user that still exists
  // is the exact complaint this function is here to answer.
  const { data: after } = await admin.auth.admin.getUserById(userId);
  const survivor = after?.user as { deleted_at?: string } | null | undefined;

  if (survivor && !survivor.deleted_at) {
    console.error("delete-account: user still present after delete", userId);
    return json(
      { error: "Your account could not be deleted. Please try again." },
      500,
    );
  }

  await removePictures(admin, userId);

  // A last sweep, after the account is gone and so with nothing left to lose.
  // Every one of these tables cascades today; this is what catches the one
  // that is added tomorrow without a delete rule, and it is logged loudly
  // enough to notice rather than left to rot.
  for (const [table, column] of [
    ["user_watchlist", "user_id"],
    ["user_flights", "user_id"],
    ["user_preferences", "user_id"],
    ["subscriptions", "user_id"],
    ["app_store_subscriptions", "user_id"],
    ["profiles", "id"],
  ] as Array<[string, string]>) {
    const { error: sweepError, count } = await admin
      .from(table)
      .delete({ count: "exact" })
      .eq(column, userId);

    if (sweepError && !isMissingTable(sweepError)) {
      console.error(`delete-account: sweeping ${table} failed`, sweepError.message);
    } else if ((count ?? 0) > 0) {
      console.warn(`delete-account: ${table} did not cascade — swept ${count} row(s)`);
    }
  }

  return json({ deleted: true }, 200);
});
