// Links an App Store purchase to the account that made it.
//
// StoreKit already tells the *app* whether this Apple Account owns Inflight
// Pro — that is `Transaction.currentEntitlements`, it is signed, and the app
// trusts it on its own. This function exists for the other half: so the
// website unlocks too, and so the entitlement survives a reinstall on a phone
// that is signed into the account but not yet into the App Store.
//
// The app posts the signed transactions StoreKit gave it. The signature is
// verified against Apple's roots before anything is written; the body is never
// believed on its own.
//
//   POST /functions/v1/apple-subscription-sync
//   Authorization: Bearer <the caller's own Supabase access token>
//   { "transactions": ["<jws>", …] }
//
// Deploy:
//
//   supabase functions deploy apple-subscription-sync --project-ref lcgaoiqwwpyqndaucyzu

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyTransaction } from "../_shared/apple.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/// How many signed transactions one call may carry.
///
/// An account has a handful at most — the lifetime unlock, and whatever
/// subscriptions it has held. The cap is there so a caller cannot make the
/// function do unbounded certificate work on one request.
const MAX_TRANSACTIONS = 12;

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

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  // The account written to is the one the token belongs to, resolved by
  // GoTrue. Never an id out of the request body.
  const { data: caller, error: callerError } = await admin.auth.getUser(token);
  if (callerError || !caller?.user) {
    return json({ error: "That session is no longer valid." }, 401);
  }

  const userId = caller.user.id;

  let body: { transactions?: unknown };
  try {
    body = await request.json();
  } catch {
    return json({ error: "Send a JSON body." }, 400);
  }

  const submitted = Array.isArray(body.transactions) ? body.transactions : [];
  const jwsList = submitted
    .filter((entry): entry is string => typeof entry === "string" && entry.length > 0)
    .slice(0, MAX_TRANSACTIONS);

  if (jwsList.length === 0) {
    return json({ error: "No transactions to check." }, 400);
  }

  const linked: string[] = [];
  const rejected: string[] = [];

  for (const jws of jwsList) {
    let entitlement;
    try {
      entitlement = await verifyTransaction(jws);
    } catch (error) {
      // A transaction that will not verify is not a server error — it is
      // somebody sending something Apple did not sign. Counted, not written.
      console.error("apple-subscription-sync: verification failed", error);
      rejected.push("unverified");
      continue;
    }

    // A purchase already claimed by a different account is not moved. Two
    // accounts sharing one Apple Account is a real situation — a family, a
    // handed-down phone — and the first to claim it keeps it, rather than the
    // entitlement ping-ponging every time either of them opens the app.
    const { data: existing } = await admin
      .from("app_store_subscriptions")
      .select("user_id")
      .eq("original_transaction_id", entitlement.original_transaction_id)
      .maybeSingle();

    if (existing && existing.user_id !== userId) {
      rejected.push("claimed");
      continue;
    }

    const { app_account_token: _ignored, ...row } = entitlement;

    const { error: writeError } = await admin
      .from("app_store_subscriptions")
      .upsert({ ...row, user_id: userId }, {
        onConflict: "original_transaction_id",
      });

    if (writeError) {
      console.error("apple-subscription-sync: write failed", writeError.message);
      return json({ error: "That purchase could not be saved." }, 500);
    }

    linked.push(entitlement.original_transaction_id);
  }

  if (linked.length === 0) {
    return json({ linked: 0, rejected }, 400);
  }

  return json({ linked: linked.length, rejected }, 200);
});
