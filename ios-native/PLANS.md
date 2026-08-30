# Flight plans, gates, and the airport map

What the planning feature is, which half of it is Pro, and where each rule is
enforced. Same shape as [`PROFILES.md`](PROFILES.md) and [`PRO.md`](PRO.md).

## What was built

The tracker already kept two tenses. `pilot_live_status` is the present — where
an aeroplane is right now — and `pilot_logbook` is the past. Both are
**observed**: nobody types them, and every column in them is something the sim
or the feed actually reported.

This is the third tense, and the only one that is entirely a claim.

- **A plan**: where you are leaving from and where you are going, the **stand at
  each end**, and **when** you mean to be off blocks and on blocks. Plus the
  callsign, type and livery you mean to fly it in, and a line of remarks.
- **The airport map**, for picking a gate: the field on satellite imagery, its
  runways, taxiways and aprons outlined over the photograph, and every mapped
  stand as a marker you tap. This is the Pro half.
- **A list**, split into what is coming up and what has been. Flown and
  cancelled plans are kept rather than deleted, because the fastest way to plan
  a leg is to copy one you have already flown.

Reached from **Settings → Flying → Flight plans**, from **a field's own panel**
("Plan a flight from here", which fills the ICAO in for you), and from the
`plans` deep link.

## Which half is Pro, and where that is enforced

| | Free | Inflight Pro |
| --- | --- | --- |
| Filing a plan, both ends | yes | yes |
| Departure gate | **typed** | typed, **or tapped on the airport map** |
| Arrival gate | **typed** | typed, **or tapped on the airport map** |
| Scheduled off/on blocks | yes | yes |
| Callsign, type, livery, remarks | yes | yes |
| How many plans | 200 | 200 |

**The row that reaches the server is identical either way.** That is the whole
shape of this feature and it is deliberate. The tempting version — gates for
Pro, times for free — would have made the feature useless to most people in
order to sell it to a few. What is actually worth paying for is not the ability
to record a gate; it is not having to know, at a field you have never flown
into, whether the stand you want is called `543` or `B43`.

So **there is no Pro check in the database** (see
`supabase/migrations/20260830000000_flight_plans.sql`), and that is not an
oversight. A Pro gate in `pilot_flight_plans` would be a gate on typing a
string, which a modified client would walk straight past and which would protect
nothing. The gate is in `FlightPlanEditor`, on the button that opens
`GateMapPicker`, which is exactly as strong as it needs to be: skipping it
gains you a text field you already had.

This is the one place in the app where a Pro gate lives only in the client. Every
other one — the banner, the whole logbook, the watchlist — is enforced in
Postgres as well, because in every other case there is a *row* that differs.

## Where it lives

### Database

`public.pilot_flight_plans`, one row per plan.

- **Row-level security**, owner only, all four operations. Not readable by
  `anon` at all — unlike the rest of this schema, which is deliberately
  readable signed out. A plan says where somebody intends to be, and there is
  no reader for that yet who would justify publishing it.
- **A `before` trigger** (`pilot_flight_plans_guard`) forces `user_id` to the
  caller, upper-cases both ICAOs, trims every text column, clears a gate's
  coordinate when its name is cleared, and stamps `updated_at` off the server's
  clock. RLS already refuses a write into somebody else's list; the trigger
  makes it impossible rather than merely refused.
- **A cap** (`pilot_flight_plans_cap`) of 200 rows per account, checked on
  insert only so editing the two-hundredth plan still works and deleting is how
  you get back under. Not a limit anybody flying will meet — it is there
  because this table is writable by a client over a public API.
- **Gate coordinates are optional and stored whole.** A typed gate has a name
  and no position; a tapped one has both. A check constraint refuses half a
  coordinate, because a latitude with no longitude is a point nobody can draw.

`public.user_flights` is **not** this table and was deliberately left alone. It
is the website's hand-filed PIREP — a bigint key the client picks, fuel and
passenger counts, written by a dashboard this app does not talk to. Folding a
forward-looking plan into a backward-looking report would mean one table where
half the rows are claims about the past and half are intentions about the
future, with no column saying which.

### App

| File | What it is |
| --- | --- |
| `Models/PlannedFlight.swift` | The plan, its two `Stand`s, and how a row is read and written |
| `Services/FlightPlanBook.swift` | The list, and the four calls behind it |
| `Views/FlightPlansPanel.swift` | The list screen |
| `Views/FlightPlanEditor.swift` | The form, and where the Pro gate is |
| `Views/GateMapPicker.swift` | The airport map — Pro |
| `Services/StandDirectory.swift` | Stand *names* for fields nobody has mapped |
| `Services/SupabaseData.swift` | Gained `insert`, `select`, `patch` and `delete` |

**An account is required**, and this is the only store in the app that requires
one. Everything else the tracker shows belongs to the world — the traffic, the
fields, the weather, somebody else's public profile — and works signed out. A
plan belongs to a person, has to survive a new phone, and is worth nothing if it
lives only in this install's `UserDefaults`. The panel says so plainly rather
than presenting an empty list that quietly loses what is typed into it.

### Where the stands come from

Two sources, and the picker says which one it is showing.

**`GateStore`** — OpenStreetMap, over Overpass, one request per field per
install per month, cached on disk. It already existed: it is what the field
panel uses to say which stands are occupied. These rows have positions, so this
is the source that gets a map. `AirportLayoutStore` supplies the pavement the
same way.

**`StandDirectory`** — the backend's community stand list, `/api/gates/:icao` on
the ACARS API. Names, with no coordinates: somebody's export of a field's
numbering rather than a survey. It has been there since the web tracker, whose
gate board falls back to it when every Overpass mirror refuses, and the picker
asks for it only when the survey has come back empty. Parsed with the same
tolerance the backend's own `localAirportGates` applies, because the import
route takes whatever shape somebody uploads.

So a field is in one of three states, and none of them is a dead end:

1. **Mapped** — imagery, pavement, a marker per stand. The pick carries its
   position into the plan.
2. **Named only** — a grid of real stand names and no map, labelled as such.
   The pick carries its name, exactly as a typed one does.
3. **Neither** — the picker says so plainly, and typing the gate still works.
   That is why the free path is not a lesser feature so much as the one that
   always works.

**Mapping changes**, which is the other thing worth being plain about. A stand
picked in March may not exist in OpenStreetMap in September. That is why the
*name* is what the plan is really made of and the coordinate rides along beside
it: the plan still reads correctly, and the marker still draws where it was,
whatever the survey does next.

The picker draws over **imagery**, not cartography. What somebody is doing on
that screen is matching a stand number to a place they recognise, and they
recognise the terminal roof, not the polygon. The chart lines say which strip of
the picture is a runway; the picture says everything else.
