# Enabling APNs Remote Push

The app ships with APNs plumbing wired but **dormant**: at launch it asks the
OS for a device token; without the push entitlement the request fails silently
and local (in-app) notifications continue as before. To turn on real remote
push — notifications that arrive with the app closed, the Mac asleep, or on
another device — do the following once:

## 1. Apple Developer portal

- Enable **Push Notifications** on both app IDs
  (`com.researchoors.HermesNative.macOS`, `com.researchoors.HermesNative.iOS`)
  under Certificates, Identifiers & Profiles → Identifiers.
- Create an **APNs Auth Key** (.p8) under Keys. Note the Key ID and Team ID.
- Regenerate/refresh provisioning profiles so they include the push capability
  (Xcode's automatic signing does this once the entitlement is present).

## 2. App entitlements

Add to `HermesNative-macOS.entitlements`:

```xml
<key>com.apple.developer.aps-environment</key>
<string>development</string>   <!-- "production" for notarized/TestFlight -->
```

And to `HermesNative-iOS.entitlements`:

```xml
<key>aps-environment</key>
<string>development</string>
```

> These are deliberately not committed: with automatic signing but no push
> capability on the team/app ID, the entitlement breaks local code-signing
> for everyone else. Add them alongside the portal setup.

## 3. Gateway credentials

Configure the hermes-agent gateway (see its `docs/api/apns-push.md`):

```bash
APNS_KEY_PATH=~/.hermes/AuthKey_ABC123.p8
APNS_KEY_ID=ABC123DEFG
APNS_TEAM_ID=TEAM456789
APNS_BUNDLE_ID=com.researchoors.HermesNative.macOS
APNS_ENV=sandbox   # for Xcode debug builds; unset for production
```

and install the HTTP/2 extra: `pip install 'hermes-agent[apns]'`.

## How it works after that

- On launch the OS grants a device token → `PushRegistrationService` stores it.
- On every gateway (re)connect — including multi-gateway switches — the app
  calls `push.register`, so the **current** gateway knows this device.
- The gateway pushes approval requests, turn completions, and cron results via
  APNs. Payloads carry `session_id`, so tapping a push routes through the
  exact same session-resolution path as local notification taps.
- Dead tokens are pruned server-side; token rotation re-registers automatically.
