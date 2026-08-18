// Sets the calling pilot's own avatar or banner, and nothing else.
//
// WHY THIS IS NOT A DIRECT UPLOAD. Supabase Storage will happily take a signed
// upload straight from the app, and for a private bucket that is the right
// answer. These two buckets are public — the whole point is that a stranger's
// browser can fetch the picture — and a public bucket that a client can write
// to is a public bucket that a client can put ANYTHING in, under our domain,
// served with our CORS headers, at a URL that looks like ours. The buckets
// therefore have no client-side insert policy at all (see
// `20260818000100_pilot_profiles.sql`), this function holds the service role,
// and it is the only writer.
//
// What it checks, in order, before a byte is stored:
//
//   1. the caller is signed in, and the id used is the one GoTrue resolves
//      from their token — never one from the request body
//   2. the payload is small enough
//   3. the bytes really are a JPEG, PNG or WebP, by magic number rather than
//      by the Content-Type the caller claimed
//   4. the image's own dimensions are sane, read out of its header
//   5. a banner needs Inflight Pro, asked of `pro_entitlement()` with the
//      caller's own token
//   6. if an image-moderation endpoint is configured, it agrees the picture is
//      safe for work
//
// The `pilot_profiles` row is then updated with the CALLER'S token, not the
// service role, so row-level security and the write guard apply to it exactly
// as they would to any other edit. The service role is used for the storage
// write and for nothing else.
//
// Deploy:
//
//   supabase functions deploy profile-image --project-ref lcgaoiqwwpyqndaucyzu
//
// Secrets:
//
//   MODERATION_IMAGE_URL    optional. A POST endpoint that takes
//                           { contentType, data } (base64) and answers
//                           { safe: boolean, reason?: string }. When it is not
//                           set, images are published on upload and rest on
//                           the report-and-block path instead; see PROFILES.md.
//   MODERATION_IMAGE_KEY    optional bearer token for the above.
//
// `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are
// injected by the platform.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/// The two kinds of picture a profile has, and what each is allowed to be.
///
/// The byte caps are the same numbers the buckets carry, kept here as well so
/// an oversized upload is refused with a sentence rather than with Storage's
/// own error. Avatars are drawn at 96pt and banners at full width, which is
/// the whole reason the two limits differ.
const KINDS = {
  avatar: {
    bucket: "pilot-avatars",
    column: "avatar_path",
    maxBytes: 2 * 1024 * 1024,
    minSide: 96,
    maxSide: 4096,
    pro: false,
  },
  banner: {
    bucket: "pilot-banners",
    column: "banner_path",
    maxBytes: 5 * 1024 * 1024,
    minSide: 320,
    maxSide: 8192,
    pro: true,
  },
} as const;

type Kind = keyof typeof KINDS;

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/// What the bytes actually are, and how big.
///
/// Read from the file's own header rather than taken from the request, because
/// a Content-Type is a claim and a magic number is evidence. Returns null for
/// anything that is not one of the three formats the buckets accept — which
/// covers the interesting case of a file that is a valid image AND a valid
/// something else, since a polyglot has to start with one of the two and this
/// only accepts the ones that start with an image.
function inspect(bytes: Uint8Array): { type: string; width: number; height: number } | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  // PNG: the 8-byte signature, then IHDR with width and height at 16 and 20.
  if (
    bytes.length > 24 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
    bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a
  ) {
    return {
      type: "image/png",
      width: view.getUint32(16, false),
      height: view.getUint32(20, false),
    };
  }

  // JPEG: SOI, then walk the segment chain to whichever SOFn carries the size.
  // Progressive JPEGs use SOF2 and baseline SOF0, and there are a dozen more,
  // so the test is "an SOF that is not one of the four markers in that range
  // which mean something else" rather than a list of the ones we like.
  if (bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xff) { offset += 1; continue; }
      const marker = bytes[offset + 1];
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        offset += 2;
        continue;
      }
      const length = view.getUint16(offset + 2, false);
      const isSOF = marker >= 0xc0 && marker <= 0xcf &&
        marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
      if (isSOF) {
        return {
          type: "image/jpeg",
          height: view.getUint16(offset + 5, false),
          width: view.getUint16(offset + 7, false),
        };
      }
      if (length < 2) return null;
      offset += 2 + length;
    }
    return null;
  }

  // WebP: RIFF….WEBP, then one of three chunk layouts.
  if (
    bytes.length > 30 &&
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50
  ) {
    const chunk = String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]);
    if (chunk === "VP8 ") {
      return {
        type: "image/webp",
        width: view.getUint16(26, true) & 0x3fff,
        height: view.getUint16(28, true) & 0x3fff,
      };
    }
    if (chunk === "VP8L") {
      const bits = view.getUint32(21, true);
      return {
        type: "image/webp",
        width: (bits & 0x3fff) + 1,
        height: ((bits >> 14) & 0x3fff) + 1,
      };
    }
    if (chunk === "VP8X") {
      const width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
      const height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
      return { type: "image/webp", width, height };
    }
  }

  return null;
}

/// Ask the configured classifier whether this picture belongs on a profile.
///
/// Absent by default, and its absence is not silently treated as approval —
/// see PROFILES.md, where what actually keeps these buckets safe for work with
/// no classifier attached is written down: report, auto-hide, block, and a
/// human. This is the hook for doing better than that, not a claim that it is
/// already being done.
async function classify(contentType: string, base64: string): Promise<string | null> {
  const endpoint = Deno.env.get("MODERATION_IMAGE_URL");
  if (!endpoint) return null;

  const key = Deno.env.get("MODERATION_IMAGE_KEY");
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(key ? { Authorization: `Bearer ${key}` } : {}),
      },
      body: JSON.stringify({ contentType, data: base64 }),
      signal: AbortSignal.timeout(10_000),
    });

    if (!response.ok) {
      // A classifier that is down must not become a way to publish anything.
      console.error("profile-image: classifier answered", response.status);
      return "Images can't be checked right now. Try again shortly.";
    }

    const verdict = await response.json();
    if (verdict?.safe === true) return null;
    return typeof verdict?.reason === "string" && verdict.reason
      ? verdict.reason
      : "That picture didn't pass our safe-for-work check.";
  } catch (error) {
    console.error("profile-image: classifier failed", (error as Error).message);
    return "Images can't be checked right now. Try again shortly.";
  }
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "Use POST." }, 405);

  const header = request.headers.get("Authorization") ?? "";
  const token = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  if (!token) return json({ error: "Missing access token." }, 401);

  let body: { kind?: string; contentType?: string; data?: string; remove?: boolean };
  try {
    body = await request.json();
  } catch {
    return json({ error: "Send JSON." }, 400);
  }

  const kind = body.kind as Kind;
  if (kind !== "avatar" && kind !== "banner") {
    return json({ error: "kind must be avatar or banner." }, 400);
  }
  const spec = KINDS[kind];

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const admin = createClient(url, serviceRole, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Everything that is allowed to be about "this pilot" goes through this
  // client, which carries the caller's own token and is therefore subject to
  // every policy a direct call from the app would be.
  const asCaller = createClient(url, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: who, error: whoError } = await admin.auth.getUser(token);
  if (whoError || !who?.user) {
    return json({ error: "That session is no longer valid." }, 401);
  }
  const userId = who.user.id;

  // The profile has to exist first. Claiming a handle is what creates it, and
  // a picture with no profile attached is an orphan in a public bucket.
  const { data: profile } = await asCaller
    .from("pilot_profiles")
    .select("avatar_path, banner_path")
    .eq("user_id", userId)
    .maybeSingle();

  if (!profile) {
    return json({ error: "Claim a handle before adding a picture." }, 409);
  }

  const previous = (profile as Record<string, string | null>)[spec.column];

  // MARK: - Taking one off

  if (body.remove === true) {
    const { error } = await asCaller
      .from("pilot_profiles")
      .update({ [spec.column]: null })
      .eq("user_id", userId);

    if (error) return json({ error: error.message }, 400);

    if (previous) await admin.storage.from(spec.bucket).remove([previous]);
    return json({ removed: true }, 200);
  }

  // MARK: - Putting one on

  if (typeof body.data !== "string" || body.data.length === 0) {
    return json({ error: "No image sent." }, 400);
  }

  // base64 is 4 characters per 3 bytes, so the cap can be applied to the
  // string before anything is decoded — which is the point, since decoding is
  // where a 50MB payload would cost us memory.
  if ((body.data.length * 3) / 4 > spec.maxBytes) {
    return json(
      { error: `That ${kind} is larger than ${Math.round(spec.maxBytes / 1024 / 1024)}MB.` },
      413,
    );
  }

  let bytes: Uint8Array;
  try {
    const binary = atob(body.data);
    bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  } catch {
    return json({ error: "That image couldn't be read." }, 400);
  }

  if (bytes.byteLength > spec.maxBytes) {
    return json({ error: `That ${kind} is too large.` }, 413);
  }

  const shape = inspect(bytes);
  if (!shape) {
    return json({ error: "Send a JPEG, PNG or WebP." }, 415);
  }

  // A caller that says PNG and sends a JPEG is not necessarily an attack, but
  // it is a caller whose Content-Type must not be the one we store the object
  // under — so the sniffed type wins and a mismatch is refused outright.
  if (body.contentType && body.contentType !== shape.type) {
    return json({ error: "That file isn't the format it claims to be." }, 415);
  }

  if (shape.width < spec.minSide || shape.height < spec.minSide) {
    return json(
      { error: `A ${kind} needs to be at least ${spec.minSide} pixels on its short side.` },
      422,
    );
  }

  if (shape.width > spec.maxSide || shape.height > spec.maxSide) {
    return json({ error: `That ${kind} is larger than ${spec.maxSide} pixels.` }, 422);
  }

  // Pro, before the upload rather than after it. The write guard on
  // `pilot_profiles` refuses a banner from a free account anyway, so this
  // cannot be the only check — but without it the file would already be in a
  // public bucket by the time the row write failed.
  if (spec.pro) {
    const { data: entitlement } = await asCaller.rpc("pro_entitlement");
    const isPro = Array.isArray(entitlement)
      ? entitlement[0]?.is_pro === true
      : (entitlement as { is_pro?: boolean } | null)?.is_pro === true;

    if (!isPro) {
      return json({ error: "A custom banner is part of Inflight Pro.", pro: true }, 402);
    }
  }

  const refusal = await classify(shape.type, body.data);
  if (refusal) return json({ error: refusal }, 422);

  const extension = shape.type === "image/png" ? "png"
    : shape.type === "image/webp" ? "webp"
    : "jpg";

  // Under the pilot's own id, with a random tail. The id makes an object easy
  // to attribute and easy to sweep when an account is deleted; the tail is
  // what stops a replaced picture being served from somebody's cache for the
  // next month.
  const path = `${userId}/${kind}-${crypto.randomUUID()}.${extension}`;

  const { error: uploadError } = await admin.storage
    .from(spec.bucket)
    .upload(path, bytes, {
      contentType: shape.type,
      cacheControl: "31536000",
      upsert: false,
    });

  if (uploadError) {
    console.error("profile-image: upload failed", uploadError.message);
    return json({ error: "That picture couldn't be saved. Try again." }, 500);
  }

  const { error: writeError } = await asCaller
    .from("pilot_profiles")
    .update({ [spec.column]: path })
    .eq("user_id", userId);

  if (writeError) {
    // The row is the record; an object nothing points at is litter. Take it
    // back out rather than leave it.
    await admin.storage.from(spec.bucket).remove([path]);
    return json({ error: writeError.message }, 400);
  }

  if (previous && previous !== path) {
    await admin.storage.from(spec.bucket).remove([previous]);
  }

  return json({
    path,
    url: `${url}/storage/v1/object/public/${spec.bucket}/${path}`,
    width: shape.width,
    height: shape.height,
  }, 200);
});
