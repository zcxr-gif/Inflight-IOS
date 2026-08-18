// Verifying what Apple signed, and turning it into a row.
//
// Everything the App Store says about a purchase arrives as a JWS: a JSON
// payload signed by a certificate chain rooted in Apple's own CA. The payload
// is trivially readable without the signature — which is exactly why the
// signature is the only thing worth checking. A client could post any JSON it
// liked at `apple-subscription-sync`; what it cannot do is forge Apple's
// signature over it.
//
// The verification itself is Apple's own library rather than a hand-rolled
// chain walk. Getting X.509 path validation subtly wrong is the standard way
// to build a verifier that verifies nothing, and this is the one place in the
// project where that would hand out free Pro.
//
// Environment:
//
//   APPLE_BUNDLE_ID       the app's bundle id (defaults to com.tracker.Inflight)
//   APPLE_APP_APPLE_ID    the App Store's numeric id for the app. Required for
//                         production verification — Apple's library refuses to
//                         verify a production payload without it.
//   APPLE_ROOT_CERTS      optional, comma-separated base64 DER. Supplied, the
//                         roots are read from here instead of fetched.

import { Buffer } from "node:buffer";
import {
  Environment,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@3.1.0";

export const BUNDLE_ID = Deno.env.get("APPLE_BUNDLE_ID") ?? "com.tracker.Inflight";

/// The lifetime unlock. Everything else the app sells auto-renews.
export const LIFETIME_PRODUCT_ID =
  Deno.env.get("APPLE_LIFETIME_PRODUCT_ID") ?? "com.tracker.Inflight.pro";

/// Apple's published roots. G3 is what signs App Store JWS today; G2 is
/// carried so a rotation doesn't take the endpoint down with it.
const ROOT_CERT_URLS = [
  "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer",
  "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer",
];

let rootCerts: Buffer[] | null = null;

async function appleRootCertificates(): Promise<Buffer[]> {
  if (rootCerts) return rootCerts;

  const configured = Deno.env.get("APPLE_ROOT_CERTS");
  if (configured) {
    rootCerts = configured
      .split(",")
      .map((entry) => entry.trim())
      .filter(Boolean)
      .map((entry) => Buffer.from(entry, "base64"));
    return rootCerts;
  }

  const fetched: Buffer[] = [];
  for (const url of ROOT_CERT_URLS) {
    try {
      const response = await fetch(url);
      if (!response.ok) continue;
      fetched.push(Buffer.from(await response.arrayBuffer()));
    } catch (error) {
      console.error("apple: could not fetch root certificate", url, error);
    }
  }

  if (fetched.length === 0) {
    throw new Error("No Apple root certificates available.");
  }

  rootCerts = fetched;
  return rootCerts;
}

const verifiers = new Map<Environment, SignedDataVerifier>();

async function verifier(environment: Environment): Promise<SignedDataVerifier> {
  const cached = verifiers.get(environment);
  if (cached) return cached;

  const appAppleId = Number(Deno.env.get("APPLE_APP_APPLE_ID") ?? "");

  // `enableOnlineChecks` fetches Apple's CRL so a revoked signing certificate
  // is actually rejected. It costs one request on a cold verifier and is the
  // difference between checking a signature and checking a valid signature.
  const built = new SignedDataVerifier(
    await appleRootCertificates(),
    true,
    environment,
    BUNDLE_ID,
    Number.isFinite(appAppleId) && appAppleId > 0 ? appAppleId : undefined,
  );

  verifiers.set(environment, built);
  return built;
}

/// Runs a verification against production, then sandbox.
///
/// The two are separate chains with separate payloads, and nothing in the JWS
/// can be trusted to say which it is before it has been verified — so the only
/// honest way to accept both is to try both and take whichever verifies.
async function eitherEnvironment<T>(
  attempt: (verifier: SignedDataVerifier) => Promise<T>,
): Promise<T> {
  let firstError: unknown;

  for (const environment of [Environment.PRODUCTION, Environment.SANDBOX]) {
    try {
      return await attempt(await verifier(environment));
    } catch (error) {
      firstError ??= error;
    }
  }

  throw firstError ?? new Error("Apple would not verify that.");
}

export interface AppleEntitlement {
  original_transaction_id: string;
  latest_transaction_id: string | null;
  product_id: string;
  kind: "subscription" | "lifetime";
  status: "active" | "grace" | "billing_retry" | "expired" | "revoked";
  purchased_at: string | null;
  expires_at: string | null;
  auto_renew: boolean;
  is_trial: boolean;
  environment: string;
  revoked_at: string | null;
  /// The account the app said it was buying for, when it said. Set from the
  /// signed-in Supabase user id at purchase time, which is what lets a
  /// notification arriving days later find its way to an account.
  app_account_token: string | null;
}

function iso(milliseconds: number | undefined | null): string | null {
  if (!milliseconds) return null;
  return new Date(milliseconds).toISOString();
}

/// Maps a verified transaction — plus the renewal info, when there is any —
/// onto the row shape `app_store_subscriptions` holds.
// deno-lint-ignore no-explicit-any
function toEntitlement(transaction: any, renewal: any | null): AppleEntitlement {
  const isLifetime = transaction.productId === LIFETIME_PRODUCT_ID ||
    transaction.type === "Non-Consumable";

  const expires = iso(transaction.expiresDate);
  const revoked = iso(transaction.revocationDate);

  let status: AppleEntitlement["status"];
  if (revoked) {
    status = "revoked";
  } else if (isLifetime) {
    status = "active";
  } else if (renewal?.gracePeriodExpiresDate > Date.now()) {
    status = "grace";
  } else if (expires && new Date(expires).getTime() > Date.now()) {
    status = "active";
  } else if (renewal?.isInBillingRetry) {
    status = "billing_retry";
  } else {
    status = "expired";
  }

  return {
    original_transaction_id: String(transaction.originalTransactionId),
    latest_transaction_id: transaction.transactionId
      ? String(transaction.transactionId)
      : null,
    product_id: String(transaction.productId),
    kind: isLifetime ? "lifetime" : "subscription",
    status,
    purchased_at: iso(transaction.purchaseDate),
    expires_at: isLifetime ? null : expires,
    // `autoRenewStatus` is 1 for on, 0 for off. Absent renewal info — a
    // lifetime unlock — there is nothing to renew, so nothing to turn off.
    auto_renew: isLifetime ? true : renewal?.autoRenewStatus === 1,
    // offerType 1 is an introductory offer, which is where a free trial lives.
    is_trial: transaction.offerType === 1,
    environment: transaction.environment === "Sandbox" ? "Sandbox" : "Production",
    revoked_at: revoked,
    app_account_token: transaction.appAccountToken
      ? String(transaction.appAccountToken)
      : null,
  };
}

/// Verifies one signed transaction, as handed over by the app.
export async function verifyTransaction(jws: string): Promise<AppleEntitlement> {
  const transaction = await eitherEnvironment((v) =>
    v.verifyAndDecodeTransaction(jws)
  );
  return toEntitlement(transaction, null);
}

/// Verifies an App Store Server Notification V2 payload.
///
/// Returns the entitlement it describes along with the notification's own type,
/// which is what says whether this is a renewal, a lapse or a refund.
export async function verifyNotification(signedPayload: string): Promise<{
  notificationType: string;
  subtype: string | null;
  entitlement: AppleEntitlement | null;
}> {
  const payload = await eitherEnvironment((v) =>
    v.verifyAndDecodeNotification(signedPayload)
  );

  const data = payload.data;
  if (!data?.signedTransactionInfo) {
    return {
      notificationType: String(payload.notificationType ?? ""),
      subtype: payload.subtype ? String(payload.subtype) : null,
      entitlement: null,
    };
  }

  // The two halves of the notification are separately signed, and each is
  // verified in its own right rather than trusted because its envelope was.
  const transaction = await eitherEnvironment((v) =>
    v.verifyAndDecodeTransaction(data.signedTransactionInfo!)
  );

  let renewal = null;
  if (data.signedRenewalInfo) {
    try {
      renewal = await eitherEnvironment((v) =>
        v.verifyAndDecodeRenewalInfo(data.signedRenewalInfo!)
      );
    } catch (error) {
      // Renewal info only sharpens the status — grace versus billing retry —
      // so a payload whose renewal half won't verify still tells us whether
      // the subscription is paid up.
      console.error("apple: renewal info failed to verify", error);
    }
  }

  const entitlement = toEntitlement(transaction, renewal);

  // A refund or a revoked family-sharing grant is the notification saying the
  // entitlement is gone, whatever the transaction's own dates say.
  const type = String(payload.notificationType ?? "");
  if (type === "REFUND" || type === "REVOKE") {
    entitlement.status = "revoked";
    entitlement.revoked_at ??= new Date().toISOString();
  }

  return {
    notificationType: type,
    subtype: payload.subtype ? String(payload.subtype) : null,
    entitlement,
  };
}
