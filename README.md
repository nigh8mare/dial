# Field Notes (iPhone app)

A native Swift app for Field Notes. It runs the live log
(claude.ai/artifact/Xeu3iUpNy86GWTd1MncezR) inside the app, so everything the
web version does keeps working: Today, Calendar, New referrals, Patients,
Calls, search, visit notes and wound measurements, the Gaya report, Check
email, chat and voice memos. Data stays synced with the web version.

What the app adds on top:

- Call and Text open the Phone and Messages apps directly, with no dialer page in between.
- Map links open Apple Maps; other links open in Safari.
- **Record visit**: records the visit with the phone's own recorder. It keeps
  going with the screen locked or another app open, and survives a phone call
  (it picks back up when you hang up). A red bar with a Stop button stays on
  every screen while it records.
- **Note drafting**: when you stop, the phone turns the recording into text
  (on the phone itself when the phone supports it), and Field Notes drafts the
  visit note from it: what you did, vitals you said out loud, changes, wounds,
  and follow-up. It fills the same visit note you'd type, never overwrites what
  you already typed, and leaves it unfinished for you to check and Save. The
  transcript is kept on the visit, and the audio file is deleted from the phone
  once the note has it.
- Its own Home Screen icon. You stay signed in between launches.

## Build it (on the Mac)

You need Xcode (free, Mac App Store) and your Apple ID.

1. Get XcodeGen: `brew install xcodegen`
2. In this folder: `xcodegen`. That creates `FieldNotes.xcodeproj`.
3. `open FieldNotes.xcodeproj`
4. Xcode → Settings → Accounts: add your Apple ID.
5. Click the **FieldNotes** project, then **Signing & Capabilities**, and choose your team (Personal Team).
6. Plug in the iPhone and pick it as the run destination. Press ▶︎.

On the iPhone, the first time only:
- Settings → Privacy & Security → **Developer Mode** → on (the phone restarts).
- Settings → General → VPN & Device Management → trust your Apple ID.

Sign in to claude.ai inside the app with your **email code**. Google sign-in is
blocked inside apps.

With a free Apple ID the app stops opening after 7 days. Press ▶︎ in Xcode
again to renew it. A paid developer account ($99/yr) makes it last a year.
