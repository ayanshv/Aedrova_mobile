# Aedrova for iPhone

A native SwiftUI companion for Aedrova workspaces. This first build connects to Aedrova Staging. It lists workspaces, channels and existing direct messages, shows recent messages and saved agent replies for the signed-in account, and sends text through the same server function as the desktop app. Open conversations refresh while the app is active.

Open `Aedrova.xcodeproj` in Xcode, select an iPhone simulator, and run the `Aedrova` scheme. The Debug build includes **Open local demo**, with sample channels, a DM and a composer. Demo messages stay in the current view and never reach staging.

```sh
xcodebuild -project Aedrova.xcodeproj -scheme Aedrova -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Staging sign-in

In **Supabase → Aedrova Staging → Authentication → URL Configuration → Redirect URLs**, add exactly `com.aedrova.mobile://auth/callback`, preserving the existing entries. Then sign in on the simulator or device with a staging test account that already belongs to a workspace. The app uses the public project key and signed-in user session. Sessions stay in memory and message access follows existing database policies.

The target uses `com.aedrova.desktop` to match the existing App Store Connect record if iOS is added to that record. Device distribution still needs team signing and a production build configuration.

## Before TestFlight

- Verify live Google and Apple sign-in, two-way message sync, sending retries and workspace isolation with staging accounts.
- Add new DM creation, mentions and notifications, agent and Bud follow-up controls, and thread support.
- Configure production, sign an iOS build, and test it on real iPhones through TestFlight before App Review.
