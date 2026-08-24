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
| `Views/Sky/SkyCamera.swift` | The capture session and its preview |
| `Views/Sky/SkyView.swift` | The screen: vantage, range, what is in the sky |
| `Views/Sky/SkyMarker.swift` | One aircraft |
| `Views/Sky/SkyComponents.swift` | The chips, and the card that says why there is no sky |

The way in is the camera button at the top of the map's own control stack, in
the bottom-right corner. Tapping an aircraft in the sky closes the view and
opens it on the map.
