# Discord Rich Presence

"Playing Inflight" on someone's Discord profile while the app is open, saying
what they are doing in it.

| When | Card |
|---|---|
| Infinite Flight connected (Connect is live) | **Flying BAW117 · A350-900** / EGLL → KJFK · FL350, elapsed since take-off, counting down to arrival |
| A flight window is open | **Watching DAL42 · B767-300** / KATL → EGLL · FL370, counting down to arrival |
| Just the map | **Tracking live flights** / 412 aircraft up on Expert |

Buttons: the pilot's public profile when they have one, and the website.

The countdown is the same `EnrouteEstimator` ETE the app shows. It is only
re-sent when the estimate moves by more than two minutes, so Discord's rate
limit is not spent on seconds.

## Switching it on

The code is in the app and builds without Discord's SDK. Until the steps below
are done the settings row never appears and nothing runs.

1. **Create the application.** In the [Discord Developer Portal](https://discord.com/developers/applications)
   make an application called *Inflight* (the card's title is the
   application's name). Under **Social SDK**, enable it for the application.
2. **OAuth2 → Redirects:** add `discord-<APPLICATION_ID>:/authorize/callback`.
   Turn on **Public Client** — the app uses PKCE and has no client secret.
3. **Rich Presence → Art Assets:** upload three images with these keys
   (`AppConfig.discordLargeImageKey` and friends):
   - `inflight`: the app icon, 1024×1024.
   - `flying`: a small badge shown while flying.
   - `watching`: a small badge shown while watching a flight.
4. **Download the SDK.** From the portal's Social SDK downloads, take the
   Apple build and put `discord_partner_sdk.xcframework` in
   `ios-native/Vendor/`. Commit it: CI and Codemagic build from the repo and
   cannot log in to the portal to fetch it.
5. **`project.yml`:**
   - set `DISCORD_APP_ID` to the application id;
   - uncomment the `framework: Vendor/discord_partner_sdk.xcframework`
     dependency under the app target.

   The id reaches the app through Info.plist (`DiscordApplicationID`) and also
   names the URL scheme Discord returns to, so it is set in one place.

Then run `xcodegen generate`. `DiscordSDKClient` checks
`canImport(discord_partner_sdk)` and switches from its stub to the real client.

If the downloaded framework has no `Modules/module.modulemap`, add one:

```
framework module discord_partner_sdk {
  umbrella header "discord_partner_sdk.h"
  export *
}
```

## How it fits together

- `Services/Discord/DiscordSDKClient.swift` is a thin wrapper over the SDK's C
  interface (`cdiscord.h`). It handles PKCE linking, token exchange and
  refresh, the connection, and `UpdateRichPresence`. It runs entirely on the
  main thread: `Discord_RunCallbacks` is pumped by a 10 Hz main-thread timer,
  so every callback arrives there too.
- `Services/Discord/DiscordPresence.swift` works out what the card says. It
  composes on a 15-second tick, and immediately when a flight window opens or
  closes or the sim connects. It sends only when the card would read
  differently, and never more often than every 4 seconds. Tokens live in the
  Keychain (`DiscordTokenStore`), device-only, beside the app's own session.
- Settings → Flying holds the link button. Once linked it becomes an on/off
  switch plus **Unlink Discord**.

## The limit

Presence lasts as long as the app's connection to Discord, and iOS suspends an
app shortly after it leaves the screen. The card shows while Inflight is open,
including side by side with Infinite Flight on an iPad. Discord removes it a
little after the app is put away, and it comes back when the app is reopened.
The only way past this is a background mode Inflight has no honest claim to,
and App Review rejects apps that play silent audio to stay awake.
