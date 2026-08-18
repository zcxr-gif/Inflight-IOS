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
// Deploy:
//
//   supabase functions deploy delete-account --project-ref lcgaoiqwwpyqndaucyzu
//
// `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the platform;
// neither needs setting by hand, and neither should ever be echoed back.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
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

  // Rows that reference auth.users without ON DELETE CASCADE would block the
  // delete, so the account's own data goes first. Each is scoped to this user.
  // `pilot_profiles`, `pilot_follows`, `pilot_blocks`, `pilot_logbook` and
  // `profile_reports` all declare ON DELETE CASCADE against auth.users, so they
  // are not in this list — they go on their own. These are the older tables
  // that do not.
  for (const table of ["user_watchlist", "user_flights", "user_preferences", "subscriptions"]) {
    const { error: rowError } = await admin.from(table).delete().eq("user_id", userId);
    if (rowError) {
      console.error(`delete-account: ${table} failed`, rowError.message);
    }
  }

  // Keyed on `id` rather than `user_id` — profiles is one row per auth user.
  await admin.from("profiles").delete().eq("id", userId);

  // The public profile's pictures.
  //
  // These are the one thing deleting the auth user does NOT take with it.
  // Every row that references the account cascades, `pilot_profiles` included,
  // but Storage objects are files: they would sit in a public bucket, at a URL
  // somebody may well have pasted somewhere, after the account they belong to
  // had asked to be erased. Listed and removed before the row goes, because the
  // row is how we know which files are theirs — everything under a folder named
  // for the user id.
  for (const bucket of ["pilot-avatars", "pilot-banners"]) {
    const { data: objects, error: listError } = await admin.storage
      .from(bucket)
      .list(userId, { limit: 100 });

    if (listError) {
      console.error(`delete-account: listing ${bucket} failed`, listError.message);
      continue;
    }

    const paths = (objects ?? []).map((object) => `${userId}/${object.name}`);
    if (paths.length === 0) continue;

    const { error: removeError } = await admin.storage.from(bucket).remove(paths);
    if (removeError) {
      console.error(`delete-account: clearing ${bucket} failed`, removeError.message);
    }
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);

  if (deleteError) {
    console.error("delete-account: deleteUser failed", deleteError.message);
    return json({ error: "The account could not be deleted. Try again." }, 500);
  }

  return json({ deleted: true }, 200);
});
