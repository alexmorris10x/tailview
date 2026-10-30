# TailView

See and control your Mac from an iPhone or iPad over your own Tailscale network. The iOS app is a free download with an explicit seven-day trial, then a **$9.99 one-time permanent unlock** at the US launch price. Apple displays your local price before purchase. No subscription or automatic charge. The Mac companion is free, and both apps' original source is licensed under [Apache 2.0](LICENSE).

- [Setup](docs/site/setup.html), [support](docs/site/support.html), [privacy](docs/site/privacy.html)
- [Product specification](docs/SPEC.md) and [remaining launch work](docs/TODO.md)
- [Mac distribution](docs/release/distribution.md) and [App Store configuration](docs/release/app-store-metadata.md)

The public release is being prepared. An App Store record and working development builds do not mean the public download is available; use the website's actual download links when published.

## Set up and pair before starting the trial

Requires macOS 14 or later, iOS / iPadOS 17 or later, and Tailscale connected on both devices. The Mac must stay awake and signed in. Tailscale is a separate service with its own [plans](https://tailscale.com/pricing) and [terms](https://tailscale.com/terms).

1. Install the free Mac companion in Applications. Open it, allow Screen Recording, and choose **Start sharing**. Sharing is off on a fresh installation and remembers your choice afterward.
2. Choose **Pair a new device**. Enter the displayed address and temporary code on iOS and choose **Pair Mac**. A code lasts five minutes, closes after successful pairing, and can be closed manually. Pairing does not start the trial.
3. Once setup is ready, choose **Start 7-day free trial** and confirm the free **7-day Trial** item in Apple's purchase sheet, or buy the permanent unlock. Restore Purchases recovers an existing entitlement; it never restarts an expired trial.
4. For remote input, enable the control consent in both apps and grant TailView Mac Accessibility permission. Viewing remains available when control is disabled.
5. Microphone return is off initially. Enable it and grant iOS Microphone permission only if you want to send your voice to the Mac.

After the trial expires, screen viewing, control, and audio stop until you buy the permanent unlock. Saved Macs, setup, help, and purchase/restore remain available. The app loads both the free trial and local unlock price before allowing a new trial.

## Control your Mac

| Action | Control |
| --- | --- |
| Click / move pointer | Tap / slide one finger |
| Right-click / drag | Two-finger tap / press and hold, then move |
| Scroll / zoom | Two-finger swipe / pinch |
| Move around a zoomed screen | Enable **Pan view**, then move two fingers |
| Type / delete | **Keyboard**; software and hardware keyboard Backspace work |
| Paste text | **Paste** or hardware Command-V; sends plain text to the Mac clipboard and focused app |
| Modifier shortcut | Tap **fn**, Control, Option, or Command for the next action; double-tap to hold; tap again to release |
| Hold the Mac Fn key | Press and hold **fn**; useful for hold-to-talk shortcuts supported by the Mac app |
| Navigate / arrange windows | Space, Mission Control, App windows, Left half, Right half, and Fill screen buttons |

The toolbar scrolls horizontally when it does not fit. Text paste is limited to 1 MB and requires remote control. Fn+Delete sends forward delete; Fn+arrows sends Home/End/Page Up/Page Down; Fn+1–0, minus, and equals sends F1–F12. Software-generated keys may not work with apps that require physical keyboard input.

Up to two paired devices can view and control the same desktop. Their mouse and keyboard actions can interfere; they do not get separate Mac sessions. Update the Mac host before the iOS app when updating both.

## Audio, widgets, and background sessions

**Mic** and **Speaker** mute the two directions independently. Only one viewer owns audio at a time; use **Audio device** in iOS Settings to move ownership. An orange Mic status means the microphone is not currently sending despite being enabled. Bring the app to the foreground and toggle Mic to retry after an interruption.

Mac sound works without an extra driver. Sending the iOS microphone into a Mac app requires the separately installed [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole). TailView does not bundle it. The Mac's **Automatically route audio for the remote microphone** option is off initially. When enabled, it selects BlackHole as the default input and a physical playback output during the session, restoring the previous routes on disconnect, pause, quit, or disabling the option. A Mac app with its own input setting still needs BlackHole selected there.

Home Screen and Lock Screen widgets open your saved Mac, keyboard, or settings; they are launchers, not live status displays. An active session can show a Live Activity with Mic, Sound, Fn, and Return controls. These controls can affect the Mac without unlocking the phone; turn them off in Settings if unwanted. Lock-screen Fn latches until tapped again, and Return is disabled while Fn is held.

An audio-owning viewer can continue its session in the background. A viewer without active audio may be suspended and reconnect when opened. Muting an ongoing background microphone session suppresses transmission but may keep microphone capture running so iOS can retain the session; disconnect or disable microphone access to stop it. Long outages pause background recovery. Audio uses buffering to absorb network stalls, so video and audio are not synchronized.

## Stop access and manage display privacy

**Disconnect** ends one viewer's session. **Pause Access** on the Mac disconnects every viewer, stops capture and input, and persists until **Resume Access**. **Revoke** removes a device's permission. iOS **Forget** removes its local saved profile; revoke it on the Mac too when retiring the device. Pairing credentials are kept in the iOS Keychain; the Mac stores credential digests.

The Mac's advanced display controls can darken its built-in display while continuing the remote session. Display disconnection requires another active display and initially restores itself after a countdown unless explicitly retained. Optional local-input blocking prevents physical keyboard/mouse input while blacked out; **there is no physical-keyboard escape**. Restore the display remotely or quit TailView normally; restarting the Mac is the recovery fallback.

These controls use undocumented macOS interfaces and may need changes after OS updates. A darkened display is still an active desktop, not a locked Mac. They do not replace macOS security controls. Launch at Login is optional and off by default.

## Build and distribution

The project uses XcodeGen. Run `xcodegen generate`; schemes are **TailViewMac**, **TailViewIOS**, and the isolated **TailViewPurchases** test scheme. Device signing requires your own authorized Apple team. A fork must also update its bundle identities and identity-validation configuration consistently; the checked-in team grants no signing rights.

On the maintainer's Mac, builds run through `~/bin/ios-dev-build`. Debug builds have distinct Dev identities and full access unless launched through the purchase-test scheme. `TailView.storekit` belongs to local purchase testing and is not a production entitlement source. Release access uses verified StoreKit non-consumables:

- `com.10x.tailview.ios.trial7` — free **7-day Trial**.
- `com.10x.tailview.ios.lifetime` — paid permanent unlock.

For the public Mac package, use `scripts/package-mac-release.sh` with Developer ID signing and an existing notarization profile; see [distribution](docs/release/distribution.md). The iOS release is distributed through the App Store. TestFlight and App Store submission remain the owner's step.

## Limits and verification

TailView shares the main display as JPEG frames; it does not provide separate remote sessions, file transfer, or multi-monitor selection. It supports text clipboard paste. Image quality, latency, background operation, and audio continuity depend on the network and OS. The host binds to its Tailscale IPv4 address and relies on Tailscale transport encryption, which can use direct or encrypted relay paths. Open source is not a security-audit claim.

The launch change's pure trial, consent, transport, and audio tests passed. The iOS simulator build compiles; StoreKit runtime testing hit a system sandbox-initialization failure, so successful purchase, restore, and expiry behavior in Apple's runtime remains unverified. Historical device observations are not acceptance evidence for this release. The current release gates are in [TODO](docs/TODO.md).
