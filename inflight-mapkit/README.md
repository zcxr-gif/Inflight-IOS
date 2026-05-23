# inflight-mapkit

Local Capacitor plugin wrapping `MKMapView` for the Inflight iOS app.

This package is consumed by the parent app via a `file:` dependency:

```json
"inflight-mapkit": "file:./inflight-mapkit"
```

It is **not** published to npm — it lives next to the app source so the
two evolve together.

See `../MIGRATION.md` for architecture and scope.
