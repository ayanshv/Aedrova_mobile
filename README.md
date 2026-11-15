# Aedrova for iPhone

A native SwiftUI companion for Aedrova workspaces. The Debug build connects to Aedrova Staging. It supports workspace and channel browsing, new direct messages, thread replies, teammate mentions, message search, and in-app activity. Open conversations refresh from private realtime events with polling as a fallback. The channel sidebar shows unread counts, and saved agent replies are visible to the signed-in account where permitted.

Open `Aedrova.xcodeproj` in Xcode, select an iPhone simulator, and run the `Aedrova` scheme. The Debug build includes **Open local demo**, with sample channels, a DM and a composer. Demo messages, threads, and direct conversations stay in memory until you sign out or relaunch.

```sh
xcodebuild -project Aedrova.xcodeproj -scheme Aedrova -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Staging sign-in

In **Supabase → Aedrova Staging → Authentication → URL Configuration → Redirect URLs**, add exactly `com.aedrova.mobile://auth/callback`, preserving the existing entries. Then sign in on the simulator or device with a staging test account that already belongs to a workspace. The app uses the public project key and signed-in user session. Sessions stay in memory and message access follows existing database policies.

## Production sign-in

Release builds use the production Supabase project and the managed API at `https://aedrova.com`. In **Supabase → Aedrova (production) → Authentication → URL Configuration → Redirect URLs**, make sure `com.aedrova.mobile://auth/callback` is listed. Keep the existing desktop and web redirects. Google and Apple use their existing production OAuth provider registrations and return to the app through the mobile callback.

The target uses `com.aedrova.desktop` to match the existing App Store Connect record if iOS is added to that record. Device distribution requires the app owner's Apple Developer team and an iOS provisioning profile.

## Before TestFlight

- Verify live Google and Apple sign-in, two-way message sync, sending retries and workspace isolation with staging accounts.
- Verify mentions, thread replies, message search, and the activity feed in staging. Verify signed-in realtime delivery, unread and reconnect behavior, and the managed Aedrova reply follow-up. Push notifications and Bud follow-ups are separate work.
- Sign an iOS Release build and verify both production sign-in providers on a real iPhone through TestFlight before App Review.

## Account deletion

Open **Account → Delete account** from the workspace picker or channel sidebar. A signed-in user can submit a request and return to see its reference. The request is handled by the privacy operator, who contacts the user at the registered address and confirms when deletion is complete.

Assign an operator to the private request queue. Before submission, verify fulfillment and Sign in with Apple revocation with disposable staging accounts. Follow `docs/account-deletion-requests.md` in the desktop repository.

## Security and request limits

The app uses OAuth with PKCE, validates the exact sign-in callback, and sends
workspace requests over HTTPS to the configured Supabase project. It accepts
only a publishable project key. Tokens are held in memory, refreshes share one
request, and sign-out clears the local session before requesting server
revocation. Workspace content is covered when the app goes inactive. The app
uses the signed-in user's permissions, including database checks for private
channels, DMs, and saved agent replies.

The app allows five sign-in starts per minute across Google and Apple, caps
concurrent API calls, and honors server throttling. The sign-in cap is a
device-side safeguard. Supabase Auth enforces its own limits independently.
The app bounds messages, search queries, and response sizes. A throttled send
keeps the draft, and retrying that draft uses the same message ID.

The shared Supabase backend already limits message creation to 120 per user
per minute. Apply the shared backend migration
`202611110001_chat_request_budgets.sql` to add per-account limits for opening
DMs (30/minute), loading message history (180/minute), and search/activity
(90/minute). The app still uses row-level security for direct channel and
saved-reply reads, which have no new custom database quota in this change.
Review hosted Supabase Auth settings and verify throttle behavior with signed-in
staging accounts before TestFlight.

Keep server credentials out of the app and its build settings. The companion
currently reads saved agent replies but does not run builds, call model providers,
authorize Bud connectors, record meetings, or process checkout. Those workflows
need their own server-side permissions and quotas if added to iOS.

## Responsiveness

The iPhone companion uses a short-lived, in-memory cache scoped to the signed-in
session and workspace. Recent conversations, chat rows and authorized mention
recipients can appear while the app refreshes them. Search shows cached chat
matches immediately and reconciles with the server after a 250 ms debounce.
Sign-out drops the cache. An access failure invalidates the affected workspace
cache.

Chat renders its own outgoing message immediately and keeps the composer
editable during delivery. The next send waits for the active send to finish.
Retry uses the same message ID. Foreground chat polling fetches new rows by
sequence, periodically reloads the latest page to pick up edits and unsends,
and backs off after network failures or server throttling.


Saved Aedrova replies in staging support a private follow-up through the existing
managed gateway. It uses the selected reply and question and checks the saved
reply's existing source permissions before storing the new answer. It uses the
workspace's included AI allowance. Retrying a failed save reuses the generated
answer.

## iPhone App Review checklist

- From a teammate’s message, long-press to report it or block the sender. In Account, open Blocked teammates to unblock. The Support and Privacy Policy links are available in Account. Verify the report queue and its staffed response process.
- An Aedrova follow-up requests permission each time before sending the question and selected reply to OpenAI. Verify that Cancel preserves the question and sends nothing. Verify Allow and send and retry saving separately.
- In App Store Connect, fill in App Privacy from the release configuration and its enabled services. Review name, email, user identifier, messages and AI prompts, uploaded photos, support content, and any usage or diagnostics retained by the production backend. Review purposes, linkage to identity and provider processing. Verify the production privacy and support URLs and the embedded privacy manifest before saving the listing.
- Give App Review a usable demo account with two teammates or a populated workspace, and directions for reporting, blocking, AI consent, and account deletion. Verify the final signed TestFlight build and submission metadata before requesting review.
