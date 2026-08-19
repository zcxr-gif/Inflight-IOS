# Profiles, following, and the logbook

What the profile feature is, where each half of it is enforced, and what has to
be true outside this repository before any of it works. Same shape as
[`PRO.md`](PRO.md) and [`NOTIFICATIONS.md`](NOTIFICATIONS.md).

## What was built

A name on the map used to be a string. It now leads to a person.

- **A public profile** — handle, picture, banner, bio, the aeroplane they love
  drawn on a photograph of it, where they fly out of, and whether they are in
  the air right now. Readable by anybody, in the app and on the open web at
  `inflight.info/pilot/<handle>`.
- **Following**, one-way. **Friends** are a follow that is returned; there is no
  request and no accept, because a mutual follow already carries everything an
  accept would. Both lists are public, subject to a setting of their own.
- **A logbook the tracker writes itself.** Every flight it watches you finish —
  route, aircraft, block time, distance actually flown, ceiling — recorded
  without anybody typing anything. **Badges** are derived from it.
- **Safe for work, enforced rather than promised.** See below.

## Which half is Pro, and where that is enforced

| | Free | Inflight Pro |
| --- | --- | --- |
| Profile, handle, picture | yes | yes |
| Banner | one of six painted gradients, still | **a photograph, a colour of your own, and motion** |
| Logbook | recorded in full; last 20 shown | recorded in full; **all of it shown** |
| Watchlist | 3 pilots | unlimited |
| Flight replay | — | yes |
| Satellite and globe | — | yes |
| Pilot colours | — | yes |

Two rules run through all of it.

### The colour, and the motion

A Pro pilot picks an accent — ten swatches or the colour wheel — and it is the
ring around their picture wherever they appear: their profile, a friends list, a
search result, the pilot line in the flight window. `pilot_profiles.accent` is
checked against `^#[0-9a-f]{6}$`, so `PilotAccent` is the one place that reads
and writes the format; a parser and an encoder that disagreed about the case of
`#AABBCC` would be a constraint violation nobody could read.

Their banner also moves: a band of light crossing a painted preset with a slow
bloom drifting the other way, or the gentlest push in and out of a photograph.
Reduce Motion turns all of it off, Pro or not — it is decoration, and decoration
is the first thing that should go. The sheen is not drawn at all under a
photograph, where nobody could see it.

**Nothing is taken away when a subscription ends.** The banner somebody uploaded
while paying stays in their row, stops being served, and is there again the day
they resubscribe. Every logbook entry is recorded for every account forever —
what Pro buys is reading the whole of it back. A career total that shrank when
somebody stopped paying would be a lie about how much they had flown.

**Every gate exists twice, and the server's copy is the real one.**
`Entitlements` in the app decides what to draw — a lock instead of a tick, a
paywall instead of an action. What actually makes Pro Pro is in the database:
the write guard on `pilot_profiles` refuses a banner from a free account, and
`pilot_logbook_entries()` serves twenty rows or all of them depending on the
**profile owner's** entitlement. PostgREST is a public API and a client is a
thing that can be modified, so anything enforced only in Swift is a suggestion.

The same principle produced the one real bug fix in the website: `supabaseCaller`
in the `database` repo used to read Pro as "signed in, unless
`user_metadata.is_pro === false`". `user_metadata` is writable by the account it
belongs to — that is what it is for — so any free account could clear its own
stamp and be Pro, and every account created in the iOS app (which never writes
that stamp) read as Pro by default. It now calls `pro_entitlement()`.

## Safe for work

Apple's Guideline 1.2 asks for four things from an app with user-generated
content. All four are here, and none of them is a promise in a policy document:

1. **A filter on what gets published.** `moderation_terms` is a table, read by a
   trigger on every insert and update of a profile. The check normalises
   leetspeak first, so `p0rn` and `p_o_r_n` fold onto the same word as `porn`.
   The list is deliberately short, deliberately not exhaustive, and meant to be
   maintained from the dashboard rather than from git — publishing the exact
   list is publishing the exact way around it.
2. **A way to report.** Any profile, from its own overflow menu. Three reports
   from three distinct accounts takes a profile out of public view immediately —
   derived at read time from `profile_reports` rather than written into a
   column, so resolving the reports puts it back with no second write to
   remember.
3. **A way to block.** One-directional and silent. A block severs the follow in
   both directions, hides each profile from the other, and stops either
   following the other again.
4. **Somebody to contact.** The address on the App Store listing.

**Images are the honest gap, and are handled honestly.** Nothing here classifies
a photograph. What the `profile-image` function does do is refuse anything that
is not really a JPEG, PNG or WebP (by magic number, not by the Content-Type the
caller claimed), cap the bytes and the dimensions, and store it under the
uploader's own id so a report leads straight to it. Re-encoding on the device
also drops the EXIF, which matters because a phone photograph carries the
coordinates it was taken at and a profile picture is a public file.

If you want more than report-and-block on images, set `MODERATION_IMAGE_URL` to
a classifier endpoint — the function will call it before storing anything, and
refuses the upload when the classifier is unreachable rather than publishing on
a failure.

## Where each piece lives

### Database — `supabase/migrations/`

| File | What it adds |
| --- | --- |
| `20260818000000_is_pro_account.sql` | `pro_entitlement_for(uuid)` and `is_pro_account(uuid)`. `pro_entitlement()` becomes a one-line wrapper — same five columns, so every existing caller is untouched. This is what lets a trigger ask "is the owner of this row Pro?" |
| `20260818000100_pilot_profiles.sql` | The profile, the moderation vocabulary, reserved handles, blocks, reports, the write guard, and the two storage buckets |
| `20260818000200_pilot_follows.sql` | Follows, the mutual-friend definition, and every public read function |
| `20260818000300_pilot_logbook.sql` | The logbook, its visibility, the free window, the summary and the badges |
| `20260819000000_pilot_accent_in_summary.sql` | `accent` on the `pilot_summary` type, so a pilot's colour reaches the lists and not only their own card. Recreates the four `setof pilot_summary` functions, which is not optional — a select list one column short of its return type fails at run time |

Run them in order. `supabase/tests/run.sh` applies all of them to a throwaway
PostgreSQL cluster and exercises the rules — worth running before applying to
the project, because the interesting half of this schema is its rules and none
of those are visible in a diff. Two of the tests exist because of bugs it found:
a `security definer` function that returned NULL for signed-out readers and so
failed open, and an auto-hide that the write guard silently reverted.

### Edge Functions — `supabase/functions/`

| Function | Called by | `verify_jwt` |
| --- | --- | --- |
| `profile-image` | the app, with its own access token | yes |

```sh
supabase functions deploy profile-image --project-ref lcgaoiqwwpyqndaucyzu
```

`delete-account` has been extended: deleting an account now also sweeps its
avatar and banner out of the buckets. Everything else cascades from
`auth.users`; Storage objects are files and do not.

Optional secrets: `MODERATION_IMAGE_URL`, `MODERATION_IMAGE_KEY`.

### Storage

Two buckets, created by the migration: `pilot-avatars` (2MB) and
`pilot-banners` (5MB), both **public to read and writable by nobody with an anon
key**. There is no client-side insert policy on either. The `profile-image`
function holds the service role and is the only writer — a public bucket a
client can write to is a public bucket a client can put anything into, at a URL
under our own domain.

### The app — `InflightTracker/`

| File | |
| --- | --- |
| `Models/PilotProfile.swift` | The card, the summary row, logbook entries, badges, the painted banners |
| `Services/SupabaseData.swift` | PostgREST, for everything that is not sign-in |
| `Services/ProfileStore.swift` | Your own row: claim, edit, upload, privacy |
| `Services/PilotDirectory.swift` | Everybody else: cards, lists, search, follow, block, report |
| `Services/LogbookRecorder.swift` | Watches the feed for your own aircraft and writes down what it sees |
| `Views/ProfileComponents.swift` | Avatar, banner, rows, strips, badges — shared by every screen |
| `Views/PublicProfileView.swift` | A pilot, as the world sees them |
| `Views/ProfileEditorView.swift` | Setting up your own |
| `Views/PilotListPanel.swift` | Followers, following, search, and reporting |

Ways in: the account panel, the friends panel (rows, and "Find a pilot"), and
the Profile chip on any open aircraft — which is the one that matters, because
it turns a tapped aeroplane into a person.

### The website — the `database` repo

- `pilotProfile.js` renders `/pilot/<handle>` server-side, with Open Graph tags.
  Server-side on purpose: forums, Discord and iMessage all fetch that URL for a
  link preview and none of them run JavaScript, so a client-rendered profile
  would unfurl as a blank card — for a page whose whole purpose is being pasted
  somewhere, that is the one failure that matters.
- The route is declared **above** the catch-all in `server.js`. Everything below
  that catch-all is behind the staff login, so being above it is the entire
  reason this page is reachable.

## What is deliberately not verified

`if_username` — the Infinite Flight handle a profile claims — is the join
between a profile and an aeroplane on the map, and **nothing checks it**. Anybody
can claim any name. Every surface that shows it says "says they fly as…" rather
than pretending at a verification we cannot perform. `if_username_verified`
exists, is always false, and is settable only by a server that has actually
checked; when there is a way to check, that is the column to set and the copy
changes on its own.

## Checking it works

1. `./supabase/tests/run.sh` — the schema's rules, against a real PostgreSQL.
2. Claim a handle in the app, then open `inflight.info/pilot/<handle>` in a
   private window. Signed out is the case that matters: the page is written for
   people who have never heard of us.
3. On a **free** account, try to set a banner. The picker should not open; if it
   does, the function returns 402 and the row write is refused by the trigger.
   All three should hold.
4. Paste the profile link into Discord. If it unfurls with the banner and the
   name, the server-side rendering is doing its job.
