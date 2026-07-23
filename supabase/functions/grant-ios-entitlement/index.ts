// grant-ios-entitlement — Supabase Edge Function (Deno)
//
// Called by the iOS app (www/iapService.js) after a StoreKit purchase or
// restore to mirror the Apple entitlement into `profiles.is_pro`, so the web
// app and the user's other devices see the same Pro state.
//
// Trust model: the client sends the transactionId (and the StoreKit 2 JWS).
// We DO NOT trust the client — we re-fetch the transaction from Apple's
// App Store Server API and verify bundle id, product id, and expiry before
// granting. On-device StoreKit already gates Pro locally, so this function is
// the cross-platform mirror, not the primary gate.
//
// ── Required environment variables (set with `supabase secrets set`) ─────────
//   APPLE_ISSUER_ID     – App Store Connect API issuer id (Users & Access → Integrations → In-App Purchase)
//   APPLE_KEY_ID        – the In-App Purchase key id
//   APPLE_PRIVATE_KEY   – contents of the downloaded .p8 (PEM, keep the BEGIN/END lines; \n-escaped is fine)
//   APPLE_BUNDLE_ID     – com.tracker.Inflight
//   APPLE_ENVIRONMENT   – "Production" or "Sandbox" (defaults to trying Production then Sandbox)
//   PRO_PRODUCT_ID      – com.tracker.Inflight.pro.monthly
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY – injected automatically by Supabase
//
// Deploy: supabase functions deploy grant-ios-entitlement
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const APPLE_ISSUER_ID   = Deno.env.get('APPLE_ISSUER_ID')  ?? '';
const APPLE_KEY_ID      = Deno.env.get('APPLE_KEY_ID')     ?? '';
const APPLE_PRIVATE_KEY = Deno.env.get('APPLE_PRIVATE_KEY') ?? '';
const APPLE_BUNDLE_ID   = Deno.env.get('APPLE_BUNDLE_ID')  ?? 'com.tracker.Inflight';
const PRO_PRODUCT_ID    = Deno.env.get('PRO_PRODUCT_ID')   ?? 'com.tracker.Inflight.pro.monthly';

const HOSTS = {
  Production: 'https://api.storekit.itunes.apple.com',
  Sandbox: 'https://api.storekit-sandbox.itunes.apple.com',
};

function b64urlToBytes(s: string): Uint8Array {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function decodeJwsPayload(jws: string): any {
  try {
    const parts = jws.split('.');
    if (parts.length !== 3) return null;
    return JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  } catch {
    return null;
  }
}

// Build the ES256 JWT App Store Server API requires for auth.
async function appleApiToken(): Promise<string> {
  const header = { alg: 'ES256', kid: APPLE_KEY_ID, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: APPLE_ISSUER_ID,
    iat: now,
    exp: now + 60 * 20,
    aud: 'appstoreconnect-v1',
    bid: APPLE_BUNDLE_ID,
  };
  const enc = (o: unknown) =>
    btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const signingInput = `${enc(header)}.${enc(payload)}`;

  // Import the PEM PKCS#8 private key.
  const pem = APPLE_PRIVATE_KEY.replace(/\\n/g, '\n');
  const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const keyData = b64urlToBytes(b64.replace(/\+/g, '-').replace(/\//g, '_'));
  const key = await crypto.subtle.importKey(
    'pkcs8',
    keyData,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(signingInput)),
  );
  const sigB64 = btoa(String.fromCharCode(...sig))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${signingInput}.${sigB64}`;
}

// Fetch + verify the transaction straight from Apple. Returns the decoded,
// Apple-signed transaction payload, or null if it can't be verified.
async function verifyWithApple(transactionId: string): Promise<any | null> {
  const token = await appleApiToken();
  const envs = (Deno.env.get('APPLE_ENVIRONMENT') as keyof typeof HOSTS) || null;
  const hostsToTry = envs ? [HOSTS[envs]] : [HOSTS.Production, HOSTS.Sandbox];

  for (const host of hostsToTry) {
    const res = await fetch(`${host}/inApps/v1/transactions/${transactionId}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.status === 404) continue; // try the other environment
    if (!res.ok) continue;
    const body = await res.json();
    // signedTransactionInfo is a JWS signed by Apple; its payload is authoritative.
    const info = decodeJwsPayload(body.signedTransactionInfo);
    if (info) return info;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );

    // Identify the calling user from their JWT.
    const { data: userData, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userData?.user) {
      return json({ error: 'Not authenticated.' }, 401);
    }
    const userId = userData.user.id;

    const { transactionId, jws } = await req.json().catch(() => ({}));
    const txId = transactionId || decodeJwsPayload(jws || '')?.transactionId;
    if (!txId) return json({ error: 'transactionId or jws is required.' }, 400);

    // Verify against Apple (falls back to reading the client JWS only if the
    // App Store Server API keys are not configured — logged, never trusted for
    // granting in production; deploy the keys to close this gap).
    let tx = null;
    if (APPLE_ISSUER_ID && APPLE_KEY_ID && APPLE_PRIVATE_KEY) {
      tx = await verifyWithApple(String(txId));
    } else {
      console.warn('[grant-ios-entitlement] Apple API keys not set — cannot verify. Refusing to grant.');
      return json({ error: 'Server not configured for Apple verification.' }, 500);
    }

    if (!tx) return json({ error: 'Could not verify the transaction with Apple.' }, 400);

    // Validate the verified transaction.
    if (tx.bundleId && tx.bundleId !== APPLE_BUNDLE_ID) {
      return json({ error: 'Bundle id mismatch.' }, 400);
    }
    if (tx.productId && tx.productId !== PRO_PRODUCT_ID) {
      return json({ error: 'Unexpected product.' }, 400);
    }
    const expiresMs = Number(tx.expiresDate || 0);
    const active = !tx.revocationDate && (!expiresMs || expiresMs > Date.now());
    if (!active) return json({ error: 'Subscription is not active.' }, 400);

    // Grant Pro.
    const { error: upErr } = await supabase
      .from('profiles')
      .update({ is_pro: true })
      .eq('id', userId);
    if (upErr) return json({ error: `Failed to update profile: ${upErr.message}` }, 500);

    return json({ ok: true, is_pro: true, expiresDate: expiresMs || null });
  } catch (e) {
    return json({ error: (e as Error).message || 'Unexpected error.' }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}
