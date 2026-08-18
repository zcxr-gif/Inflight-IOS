// Apple's own account of what happened to a subscription.
//
// `apple-subscription-sync` only hears from a phone that is running the app.
// Renewals, lapses, billing failures and refunds happen whether or not anybody
// opens it, and App Store Server Notifications V2 is how Apple says so: it
// posts a signed payload here, unprompted, every time a subscription changes
// state.
//
// This endpoint is public because Apple calls it — there is no Supabase token
// to present — so `verify_jwt` is off and the signature is the whole of the
// authentication. A payload that does not verify against Apple's roots is
// dropped without touching the database.
//
// Set the URL in App Store Connect under the app's App Information ->
// App Store Server Notifications, for both the production and sandbox
// environments:
//
//   https://lcgaoiqwwpyqndaucyzu.supabase.co/functions/v1/apple-notifications
//
// Deploy:
//
//   supabase functions deploy apple-notifications \
//     --project-ref lcgaoiqwwpyqndaucyzu --no-verify-jwt

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyNotification } from "../_shared/apple.ts";

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return json({ error: "Use POST." }, 405);
  }

  let signedPayload: string | undefined;
  try {
    const body = await request.json();
    signedPayload = typeof body?.signedPayload === "string"
      ? body.signedPayload
      : undefined;
  } catch {
    return json({ error: "Send a JSON body." }, 400);
  }

  if (!signedPayload) {
    return json({ error: "No signedPayload." }, 400);
  }

  let verified;
  try {
    verified = await verifyNotification(signedPayload);
  } catch (error) {
    console.error("apple-notifications: verification failed", error);
    // 401 rather than 400: this is a payload claiming to be Apple's that
    // Apple did not sign.
    return json({ error: "That payload did not verify." }, 401);
  }

  const { notificationType, subtype, entitlement } = verified;

  // TEST notifications, and anything without a transaction attached, verify
  // fine and describe nothing to write. Answering 200 is what stops Apple
  // retrying them.
  if (!entitlement) {
    console.log("apple-notifications:", notificationType, subtype ?? "", "(no transaction)");
    return json({ ok: true }, 200);
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  const { app_account_token: appAccountToken, ...row } = entitlement;

  // Which account this belongs to, in the order the answers can be trusted.
  //
  // A row already exists for almost every notification — the app links the
  // purchase the moment it is made — so the usual answer is simply "whoever
  // owns it already". `appAccountToken` covers the first notification for a
  // purchase this server has not seen yet: the app sets it to the signed-in
  // user id at purchase time, and Apple carries it on every transaction from
  // then on.
  const { data: existing } = await admin
    .from("app_store_subscriptions")
    .select("user_id")
    .eq("original_transaction_id", row.original_transaction_id)
    .maybeSingle();

  let userId = existing?.user_id ?? null;

  if (!userId && appAccountToken) {
    const { data: claimed } = await admin.auth.admin.getUserById(appAccountToken);
    if (claimed?.user) userId = claimed.user.id;
  }

  if (!userId) {
    // A purchase made while signed out. There is nothing to attach it to yet;
    // the app links it the next time it runs signed in, and Apple is told the
    // notification was received so it stops retrying.
    console.log(
      "apple-notifications:",
      notificationType,
      "unattached",
      row.original_transaction_id,
    );
    return json({ ok: true, attached: false }, 200);
  }

  const { error: writeError } = await admin
    .from("app_store_subscriptions")
    .upsert({ ...row, user_id: userId }, {
      onConflict: "original_transaction_id",
    });

  if (writeError) {
    console.error("apple-notifications: write failed", writeError.message);
    // A 500 asks Apple to retry, which is what we want when the write is the
    // thing that failed rather than the payload.
    return json({ error: "Could not record that." }, 500);
  }

  console.log(
    "apple-notifications:",
    notificationType,
    subtype ?? "",
    row.original_transaction_id,
    "->",
    row.status,
  );

  return json({ ok: true }, 200);
});
