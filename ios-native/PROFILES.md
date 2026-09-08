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
| Banner | one of six painted gradients | **a photograph, and a profile colour** |
| Logbook | recorded in full; last 20 shown | recorded in full; **all of it shown** |
| Watchlist | 3 pilots | unlimited |
| Flight replay | — | yes |
| Satellite and globe | — | yes |
| Pilot colours | — | yes |

Two rules run through all of it.

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

### 5. Somebody can look, remove it, and say so

The four things above all start from a report, and all of them act on the
profile as a whole. That left three holes, and
`20260908000000_pilot_content_moderation.sql` closes them:

* **A way to look.** `admin_pilot_uploads()` lists every avatar and banner on
  the platform with the uploader's standing beside it — open reports, prior
  takedowns, whether they are already restricted. Before this, an image nobody
  had reported three times was an image nobody could find.
* **A way to remove one picture.** `admin_pilot_takedown()` clears the column,
  writes a `pilot_content_actions` row saying which file and why, and — in the
  same transaction — optionally issues the warning. One call, because a
  takedown where somebody meant to warn and did not is a record with a gap in
  it. It returns the orphaned object's path; deleting the file is the caller's
  job, in that order, so the worst failure is litter in a bucket rather than a
  profile pointing at a 404.
* **A way to make it stick.** A `pilot_warnings` row can carry
  `upload_block`, with or without an expiry. `profile-image` asks
  `pilot_upload_notice()` before it stores anything and refuses with the
  sentence that function returns — the same sentence the app draws in the
  profile editor, so a pilot cannot be told two different things about one
  restriction. Removing a picture is deliberately still allowed: that is them
  complying.

Rescinding a warning lifts its block; `admin_pilot_lift_restriction()` lifts
the block and leaves the warning standing. Two verbs because they mean
different things, and collapsing them would make "you may upload again" require
erasing the reason you could not.

**Moderating is done from the Inflight staff hub**, not from here — the
`admin_pilot_*` functions are granted to `service_role` and nothing else, and
the hub already has staff accounts, roles, and a way to revoke both. See
`pilotModeration.js` and `/pilot-content` in the backend repo. This project
deliberately has no staff role of its own.

## Where each piece lives

### Database — `supabase/migrations/`

| File | What it adds |
| --- | --- |
| `20260818000000_is_pro_account.sql` | `pro_entitlement_for(uuid)` and `is_pro_account(uuid)`. `pro_entitlement()` becomes a one-line wrapper — same five columns, so every existing caller is untouched. This is what lets a trigger ask "is the owner of this row Pro?" |
| `20260818000100_pilot_profiles.sql` | The profile, the moderation vocabulary, reserved handles, blocks, reports, the write guard, and the two storage buckets |
| `20260818000200_pilot_follows.sql` | Follows, the mutual-friend definition, and every public read function |
| `20260818000300_pilot_logbook.sql` | The logbook, its visibility, the free window, the summary and the badges |
| `20260908000000_pilot_content_moderation.sql` | Warnings, upload restrictions, the takedown record, and the five functions the staff console calls |

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
| `Views/ProfileSetupView.swift` | Making one, in one sitting — see below |
| `Views/ProfileEditorView.swift` | Changing one you already have |
| `Views/PilotListPanel.swift` | Followers, following, search, and reporting |
| `Views/FlightPilotCard.swift` | The pilot block in the flight window |
| `Models/IFPilotStats.swift` | Grade and virtual airline, from the game rather than from us |
| `Services/PilotStatsService.swift` | Fetches and caches that block |

Ways in: the account panel, the friends panel (rows, and "Find a pilot"), and
the pilot block on any open aircraft — which is the one that matters, because
it turns a tapped aeroplane into a person.

## Setting one up

`ProfileSetupView` opens by itself the first time an account appears on a
device, and is what the account panel's own row leads to. It exists because the
old path was four errands nobody was told about: make an account, find the
editor, claim a handle, come back for a picture — and the Infinite Flight
username, which is the join that makes any of this work, was on a different
panel under a different heading and was nobody's idea of part of signing up.
The result was accounts with a handle and no picture, and profiles joined to
nothing.

Three steps. The handle and the display name, both suggested from what is
already known — the Infinite Flight name already on the device, Apple's full
name, the local part of the email. Then the Infinite Flight username, **checked
against Infinite Flight** rather than merely typed: the backend resolves it and
hands back the grade and virtual airline, which is a confirmation of the only
kind worth having, because it is the server reading something back that nobody
entered. Then a picture.

The row is written when the second step is left, not at the end. A picture has
to be attached to something, and it makes the failure mode the right way round:
somebody who closes the sheet on the last step still has a profile, a handle
and a working join, and is missing only the photograph.

Nothing on this screen is a paywall. The photographic banner is Pro and is
offered in the editor instead — the last screen of somebody's first two minutes
is the wrong place to explain what they cannot have.

## The pilot in the flight window

`FlightPilotCard` sits directly under the aircraft's identity in the open
window, shaped like the PARKED AT block, and it is three sources kept apart on
purpose:

| | Where from | Is it a claim? |
| --- | --- | --- |
| The name | the live feed | it is what the server says |
| Picture, banner, display name | `PilotDirectory` — Inflight's own profiles | **yes** — nothing verifies `if_username` |
| Grade, virtual airline | Infinite Flight, via `PilotStatsService` | no — nobody types it |

Only the third is drawn as a flat statement, and it is the only one that gets
colour: `IFGrade` carries a fixed cool-to-warm ramp ending in gold, which is the
one exception to the window's monochrome, because a grade is the only number on
the card that is read comparatively.

The pilot's banner goes behind the block — their photograph if they are Pro,
the gradient they picked if not, which needs no entitlement check here because
the server already blanks `banner_path` for a lapsed account. Whether pictures
are drawn there at all is the reader's own setting, under Flight window › The
pilot.

Two backend routes feed it, both on the live-flights service and both cached
five minutes there and ten minutes in the app:

| Route | Answers |
| --- | --- |
| `GET /api/users/:userId/stats` | by the id the feed sends on every aircraft |
| `GET /api/pilots/:username/stats` | by the name somebody types — the setup's check |

The second is new. It resolves a Discourse handle through `POST /users` and then
answers exactly as the first does, which makes a 404 from it the one thing the
app could never establish before: that a typed Infinite Flight username is not
anybody's.

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
