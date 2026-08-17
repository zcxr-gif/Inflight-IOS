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
  for (const table of ["user_watchlist", "user_flights", "user_preferences", "subscriptions"]) {
    const { error: rowError } = await admin.from(table).delete().eq("user_id", userId);
    if (rowError) {
      console.error(`delete-account: ${table} failed`, rowError.message);
    }
  }

  // Keyed on `id` rather than `user_id` — profiles is one row per auth user.
  await admin.from("profiles").delete().eq("id", userId);

  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);

  if (deleteError) {
    console.error("delete-account: deleteUser failed", deleteError.message);
    return json({ error: "The account could not be deleted. Try again." }, 500);
  }

  return json({ deleted: true }, 200);
});
