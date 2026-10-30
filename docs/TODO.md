# TailView launch work

Updated 2026-10-30.

## Verified

- The free trial, lifetime purchase, and Restore Purchases worked visibly on Alex’s physical iPhone in Xcode’s local StoreKit environment, without real charges. Five of six automated local StoreKit cases passed; the remaining case is described below.
- A backdated trial crossed its seven-day deadline during an active Mac session. The session stopped, the access screen said the trial had ended, reconnect returned to that screen, and the paired Mac remained available. This is a local StoreKit expiry check, not production purchase validation.
- The signed, notarized [Mac 1.0 download](https://github.com/alexmorris10x/tailview/releases/tag/v1.0.0-mac) is public and installed at `/Applications/TailViewMac.app` as version 1.0 (30). Its release digest, signature, and Gatekeeper acceptance were verified. Existing settings and pairing files were preserved.
- Required iPhone and 13-inch iPad listing screenshots and both genuine purchase-review images are processed in App Store Connect. Version 1.0 and both purchases passed Add for Review validation and share one unsubmitted review draft. Build `20261030110510` is selected; manual release remains enabled. No App Store submission or approval is claimed.

## Remaining

- [ ] Complete declined Ask to Buy retry. The automated local test replayed a verified, unrevoked transaction during restore and returned ASDServerErrorDomain 2010 on retry. A bounded UI attempt did not exercise a decline: changing the configuration during a running session still produced an ordinary successful test purchase. Use a fresh normal run with Ask to Buy configured before launch, decline through Transaction Manager, then restore and retry. Do not ignore valid signed entitlements to work around a test-service inconsistency. Apple's sandbox/TestFlight cannot approve or reject Ask to Buy; use Xcode for this case.
- [ ] Verify purchase restoration after an actual reinstall in Apple sandbox. Deletion/reinstall of the local test app was attempted, but Xcode’s StoreKit configuration detached, so that attempt is inconclusive. Run a development-signed Release build (`com.10x.tailview.ios`), StoreKit Configuration None, and a Sandbox Apple Account; buy the trial, delete/reinstall, restore, and verify its original deadline, then repeat with lifetime. Preserve purchase history.
- [ ] Finish first launch, permissions, and customer/reviewer setup with the distributed Mac 1.0 app. Native control returned `timeoutReached` twice for TailView after installation, preventing the visible permission/setup check. Previous screen streaming and audio-route checks used the older installed host; they do not establish the new download’s full setup. Exercise pairing before trial, screen/control consent, optional microphone and routing, pause/revoke, reconnect, and purchase/restore on an isolated Mac account or test Mac. Keep reviewer access separate from Alex’s personal desktop.
- [ ] Capture a connected-use store image after the isolated setup works. Existing setup/settings screenshots cover Apple’s required device sizes but do not establish remote-control acceptance.
- [ ] Investigate the Main Thread Checker warning observed during streaming: `UIApplication.applicationState` is read from `TailView.viewerNetwork` in `ViewerModel.receiveFrames`. No crash was observed in this check.
- [ ] Alex handles TestFlight/App Store submission and public release once the remaining checks are settled. Free/Paid Apps agreements are Active; listing, privacy, age rating, export compliance, content rights, pricing, review contact, and reviewer-owned setup notes are saved.
