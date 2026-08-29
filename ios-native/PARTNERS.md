# Partner virtual airlines

The VA-Ads product, in the iOS app. Nothing here needs setting up outside the
repo — the endpoints are public and read-only — so this is a record of what the
app reads, where it surfaces, and the one rule that shapes all of it.

## Text only

The web tracker gives a partner artwork: an uploaded banner at the top of the
airport window, a logo chip beside a callsign, an animated WebP in the Partners
slide-over. **The app carries none of it.** `VirtualAirline` does not decode the
`logo` or `banner` keys at all, so there is nothing in the app that could draw
one even by accident, and the only decoration a VA gets anywhere is a word on a
pill set in the panel's own type.

That is a deliberate limit rather than a stage on the way to banners. A partner
reads as part of the tracker — a row of type in the same voice as a frequency or
a gate — instead of as an advert pasted into it. It is also what a VA is
actually selling: who they are, what they fly, where from, and how to join.

## Where it shows

| Surface | What it draws |
|---|---|
| Flight window (`FlightPartnerCard`) | The VA whose airline name the flight is flying under, and whether this pilot is a *registered member* of it or only flying its callsign. Absent for every callsign that is not a partner's, which is most of them. |
| Field panel (`AirportPanel`) | The partners advertising at that field, each a row into its page. Absent when no partner is based there, which is most fields. |
| Airports panel | One row into the directory, so a VA can be found without already standing on a field that happens to have one. |
| Partner directory (`PartnersPanel`) | The whole roster, searchable by name, callsign, hub, region or tag; then one VA in full — what they say about themselves, how they operate, their hubs, what they have coming up, and the ways to reach them. |

Every one of them is absent rather than empty when there is nothing to say, and
every request fails soft: a directory that will not load leaves the sections it
feeds simply missing, which is the same thing to look at as a server with no
partners on it.

## What it reads

All on the InGdo backend, the same service the community aircraft photos come
from. No auth, open CORS.

```
GET  /api/va-ads?limit=100&page=N     the directory, three pages deep
GET  /api/va-ads/banner/:icao         the partners advertising at a field
GET  /api/public/va/:id/events        that VA's scheduled events
GET  /api/public/va/:id/pilots?limit=1  its roster, for the count alone
POST /api/va-stats/track              the scorecard beacons, batched
```

The directory is held for an hour and a failed load is never cached as if it
were the answer — one bad network moment at launch would otherwise leave every
VA surface blank for the whole session, so a miss keeps the old list and arms a
twenty-second retry.

`VaAdsService.Impression` is what a partner's daily scorecard counts. Seen-type
events are deduplicated per launch per VA so a list scrolled back and forth does
not inflate anybody's numbers; a click is a real, separate action every time and
is never deduplicated. All of it fails silently — a blocked stats endpoint must
never change what the user sees.

## Matching a callsign to a VA

`VaCallsign` is a port of the vocabulary in the web tracker's `vaAds.js`, and it
is fiddlier than a prefix test for reasons that are all real bugs somebody hit:

- Pilots fly the **full airline callsign** — "United 123", never a short VA code
  — so a partner is matched on the leading airline *name*.
- The match must end on a **word boundary**, or a VA coded "UNI" (Uni Air)
  swallows every "United ###" on the server.
- The trailing flight-number token comes off before the VA's code is read, so
  "Air Canada 001VA" advertises as "AIRCANADA" rather than as "AIR" — which used
  to catch Air India and Airbus with it.
- A trailing "VIRTUAL" comes off too: members of "United Virtual" fly "United
  123", so the VA has to resolve to "UNITED" or it never matches a real flight.
- **Weight-class words** ("Heavy", "Super") are stripped from the end first, or a
  member flying a heavy reads as not a member.
- The **membership tag** — the suffix on the flight number, "United 123**UA**" —
  only counts as the whole token or glued onto a number, or "MOSKVA" and "NOVA"
  read as members of every VA tagged "VA".

Flying an airline's callsign is not the same as being on its roster, and the
flight window says which it is looking at rather than implying membership.
