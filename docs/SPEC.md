# TailView blueprint

Version 1, 2026-10-30. Owner: Alex. Update this file when features, pricing, permissions, or distribution change.

## 1. The product in one minute

TailView lets an iPhone or iPad view and control the owner's Mac over Tailscale, with Mac sound and optional microphone return. It is for people who need to return to a running Mac app away from the keyboard. The Mac host is free; iOS is a free download with a seven-day trial and a $9.99 US one-time permanent unlock. Both sides use Apache 2.0 source. Public release is in preparation, not approved or available merely because an App Store record exists.

## 2. Premise and hook

- **Premise:** a task is still running on the Mac, but the owner is on their phone or iPad. Existing work on this tool demonstrates this personal need; external demand is still an assumption.
- **Hook:** show a real task being checked and completed on the actual Mac from an iPhone, with pairing and consent visible. Land on the setup page and let people try their own Mac before buying.

## 2a. The bet

The first audience is Mac owners already comfortable with Tailscale. The key result is useful control of the existing desktop without a hosted remote-desktop account. Risks are setup friction, variable audio/network behavior, and willingness to pay once; the feedback path tests those directly.

## 3. The offer and price

- Free iOS download. Pair and finish setup before choosing a trial.
- Explicit free non-consumable `com.10x.tailview.ios.trial7`, named **7-day Trial**. It starts on the original verified transaction, lasts seven days, and never auto-charges.
- Non-consumable `com.10x.tailview.ios.lifetime`, **Lifetime Unlock**, $9.99 US base price; use Apple's localized price in the app.
- Expiry stops viewing, remote input, and audio, including an active session. Saved configuration, pairing, help, purchase, and restore remain available. Restore never restarts the trial; refunded/revoked access must not remain unlocked.
- Free Mac companion. No subscription, RevenueCat, external checkout, or custom license service. Development access is separate and must not enter the release entitlement path. Family Sharing is not promised.

## 4. Unit costs and margin

Session processing and bandwidth run on the user's devices/network. No TailView-hosted relay, account backend, or usage billing is provisioned. Apple distribution fees, commissions, and taxes apply to the developer's actual agreement; no net-margin estimate is asserted here. Tailscale's plans are separate. Static Pages hosting and public source do not add a paid hosting platform.

## 5. Getting customers

Launch through the product/setup page, source repository, and intended App Store listing. The initial demonstration must show a useful remote task and the real setup. Broader outreach and growth campaigns are outside this launch implementation; no traffic or conversion target is invented.

## 6. Feedback path

Use the explicit seven-day trial on a person's own Mac. Ask where setup first became unclear and whether the remote task succeeded before asking whether they would buy. GitHub Issues is the public support route; no credentials, screen contents, or raw logs belong there. Alex owns outbound communication.

## 7. Platforms and infrastructure

macOS 14+ host, iOS/iPadOS 17+ viewer, Tailscale on both, TCP 47820 bound to Tailscale IPv4. Optional BlackHole 2ch is installed separately. Source: `MacHost/`, `IOSViewer/`, `Shared/`, widgets/live controls. Direct Mac distribution uses Developer ID, hardened runtime, notarization, and a stapled DMG. iOS uses App Store Connect record `6828728093`; a record is not a submitted build. Website: `https://alexmorris10x.github.io/tailview/`.

## 8. Brand and look

TailView uses the violet-screen/pointer icon, native SwiftUI controls, and plain labels such as **Start sharing**, **Pair Mac**, and **Start 7-day free trial**. The website's device illustration is labeled as an illustration, not an app screenshot.

## 9. Rules for anyone changing it

Sharing starts only after Mac consent; remote control also requires explicit consent on both sides and macOS Accessibility. Microphone return and automatic Mac audio routing start off. Pause persists, revocation removes access, and pairing codes expire after five minutes/first use. Never embed real credentials, claim always-direct networking, or treat source availability as an audit. Preserve Dev/Release identities and verify purchases through StoreKit.

## 10. Features

| Feature | Current state | Main source |
| --- | --- | --- |
| Setup, timed pairing, saved devices, pause/revoke | Implemented | `MacHost/HostModel.swift`, `HostConsent.swift`, `IOSViewer/ViewerModel.swift` |
| Trial, permanent unlock, restore, stream expiry | Implemented; Apple runtime acceptance pending | `PurchaseAccess.swift`, `Shared/TrialAccessRules.swift`, `StreamAccessGate.swift` |
| Main-screen view and two paired viewers | Implemented | `ScreenCapture.swift`, `VideoServer.swift`, `RemoteScreenView.swift` |
| Pointer, keyboard, modifiers, text paste, window controls | Implemented behind consent | `ControlInjector.swift`, `RemoteKeyboardInput.swift`, `ViewerView.swift` |
| One audio owner, Mac sound, optional microphone/route recovery | Implemented | `AudioRoutingController.swift`, `AudioSink.swift`, `ViewerModel.swift` |
| Widgets, Live Activity, advanced display controls | Implemented with OS limits | `LiveActivity/`, `LiveControls/`, `MacHost/DisplayControl/` |

## 11. Screens

Mac setup shows Tailscale, Screen Recording, **Start sharing**, control consent, optional audio routing, and paired-device revocation. iOS setup permits **Pair Mac** before access purchase. **TailView Access** contains trial, localized permanent price, and **Restore Purchases**. The connected viewer has the remote screen, toolbar, and audio controls; Settings owns consent, automatic audio, and lock-screen preferences.

## 12. Quality bar

A fresh setup must pair without spending trial time, disclose each permission, and stop sessions on pause/revoke/expiry. Purchase cancellation, pending approval, verification failure, restore, and revocation must not grant unintended access. Pure trial/consent/transport/audio checks passed for this change; simulator compilation passed. StoreKit runtime tests could not initialize the system sandbox and do not count as purchase acceptance. Real customer setup, purchase/restore, screenshots, and isolated review access remain in [TODO](TODO.md). No repeated simulator run is required until that environment changes.

## 13. Standard parts

| Part | Status |
| --- | --- |
| Dev/production; XcodeGen | Separate identities and schemes; implemented |
| Payments | Direct StoreKit non-consumables; deliberate exception to subscription defaults |
| Internal accounts; transactional email | No account or email backend; Dev access is not customer revenue |
| Public page | Live on GitHub Pages; notarized Mac download published; App Store link pending |
| Analytics; feedback pass; waitlist | No tracking SDK or waitlist; explicit free trial supplies evaluation access |
| Referrals; affiliates | Not now |
| Blueprint and backlog | This file and TODO are canonical |

## 14. Not now

Windows/Linux hosts, hosted accounts/relays, multi-monitor selection, file transfer, subscriptions, and growth-system integrations. Advanced display controls remain optional and do not replace a locked Mac.

## 15. Decisions and remaining questions

**Decided (2026-10-30):** free trial followed by one permanent purchase, free Mac host, setup before trial, explicit consent, Apache 2.0 source, direct notarized Mac distribution. **Assumptions:** Tailscale setup is acceptable and the remote result earns a purchase. **Release gates:** working Apple purchase runtime, published artifacts, review access, Apple agreement completion, and Alex's submission/release decision; see TODO.
