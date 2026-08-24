# The sky view

Point the camera at the sky and the traffic is drawn where it is.

## What it is not

There is no ARKit session here, no plane detection, no anchors and no world
map. A sky full of aeroplanes needs three things — which way the phone is
pointing, where it is pointing *from*, and how wide the lens is — and all three
are cheap. What runs is a capture session with a preview layer, CoreMotion's
true-north attitude at 30 Hz, and a pinhole projection. That is the whole
engine.

## The vantage

The traffic in this app is flying in Infinite Flight, not over anybody's house.
So "point the phone at the sky" needs an answer to *from where*, and the view
makes it a choice:

| Vantage | What it is | Where it comes from |
|---|---|---|
| Where I am | The sky over your actual head, with the sim's traffic in it | `CLLocationManager`, when-in-use |
| One of my aircraft | Looking out of your own cockpit at what is around you | The pilot's own flights in the packet |
| Stand at ⟨ICAO⟩ | Somewhere busy, which is where this is worth having | The field the most aircraft are departing, counted from the packet |

The third one is what stops the feature being empty for anybody who does not
live under an approach path in the sim's busiest region. It is offered even
when the view has no vantage at all, because "there is nothing to look at from
here" and "here is somewhere with something to look at" are the same sentence.

The airport dataset carries no field elevation, so an airport vantage stands at
sea level. It costs a degree or so of elevation angle on traffic directly
overhead at a high-altitude field, and nothing at all further out.

## The arithmetic

`SkyGeometry` does it in two halves, split by how often each one has to run.

**Once per packet**, for every aircraft that survives a bounding-box test: a
local tangent plane gives east and north in metres, the earth's curve is
subtracted from the height difference (`d² / 2R` — this is what puts distant
traffic genuinely below the horizon), and the result is kept as a unit vector in
CoreMotion's reference frame: **X true north, Y west, Z up**.

**Thirty times a second**: the attitude matrix carries a vector from the
device's frame out into that reference frame, so its transpose brings the world
back into the device's frame, where the rear camera looks down −Z, +X is the
right-hand edge and +Y is the top. Divide by depth, multiply by the focal
length, done.

The focal length comes from `AVCaptureDevice.activeFormat.videoFieldOfView`,
which is the angle across the long axis of the picture. The preview is
`resizeAspectFill`, so on a phone that long axis is the one shown whole and the
sides are cropped — which is why the focal length is worked out from the long
side of the view, and why the projection assumes the device is upright. Held on
its side, the view says so instead of drawing.

## What is drawn

The same sprite the map paints its traffic with, from the same catalogue, keyed
off the aircraft type — a 380 in the sky is the 380 you would have tapped on the
map. The artwork points north at zero rotation, which is the convention
`TrackerMapView` rotates its annotations under, so the sky turns each one by
`heading − camera azimuth`: an aircraft crossing left to right is a sprite
pointing left to right. Your own aircraft keeps the accent ring. Under each one
is its callsign, distance and altitude, dimmed with distance so forty of them
still read front to back.

## Staying live

Two clocks, because two things move.

The **feed** lands every few seconds. Each packet re-runs the shortlist: a
bounding-box test over every aircraft on the server (a degree of latitude is 60
NM; a degree of longitude is 60 times the cosine of where you are), then the
real distance for the handful that survive, then the nearest forty. That is the
expensive pass and it runs once a packet.

Between packets the aircraft are **carried on along their own headings** at
their own ground speeds, and their altitudes along their vertical speeds. This
is what stops the sky hopping every few seconds. It is extrapolation, so it is
capped at 20 seconds — about two and a half miles of an airliner, which is
about as wrong as a guess about something that might have started a turn is
allowed to be. Past the cap an aircraft holds its last known position.

The re-placing runs on a `TimelineView` at 2 Hz *as well as* on every attitude
update. The attitude alone would be enough while the phone is in a hand — it
arrives thirty times a second — but a phone propped against something stops
producing one, and the traffic is still flying.

## The picture the right way up

The preview's rotation is the view's own business rather than SwiftUI state
handed down to it. A preview connection does not exist until the session has an
input, which is several async hops after the layer is built, so an angle applied
once on the way past lands on nothing and the picture stays on its side. The
view holds an `AVCaptureDevice.RotationCoordinator` built with the real preview
layer, applies what it says the moment it says it, and applies it again on every
`layoutSubviews` — by which time the connection is certainly there.

## Permissions

Three, all read while the view is open and stopped when it closes:

- **Camera** — the picture. The session has an input and a preview layer and no
  output: no frame is ever captured, kept or sent anywhere.
- **Location, when in use** — the vantage, and true north. CoreMotion cannot
  produce an `xTrueNorthZVertical` reference frame without it, because the
  angle between the magnetic pole and the real one depends on where you are
  standing.
- **Motion** — the gyroscope and compass.

None of it is stored, cached or transmitted, which is why none of it appears in
the privacy manifest's collected data types: on Apple's definition, data that
never leaves the device is not collected. The App Store Connect questionnaire
still has to agree with that.

## Where it lives

| File | What it holds |
|---|---|
| `Models/SkyGeometry.swift` | The positions, the projection, the focal length |
| `Services/SkyPose.swift` | CoreMotion attitude and CoreLocation, and what is wrong when nothing draws |
| `Views/Sky/SkyCamera.swift` | The capture session, and a preview that keeps itself level |
| `Views/Sky/SkyView.swift` | The screen: vantage, range, what is in the sky |
| `Views/Sky/SkyMarker.swift` | One aircraft: its sprite, turned, and what it reads |
| `Views/Sky/SkyComponents.swift` | The chips, and the card that says why there is no sky |

The way in is the camera button at the top of the map's own control stack, in
the bottom-right corner. Tapping an aircraft in the sky closes the view and
opens it on the map.

The app's mark sits at the top of the view, where a viewfinder wears one — this
is the one screen in the app with nothing of the app's own on it otherwise, and
it is the one people point at the sky and photograph.
